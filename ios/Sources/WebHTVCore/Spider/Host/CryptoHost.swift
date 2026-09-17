import CommonCrypto
import Foundation
import JavaScriptCore

/// `host.crypto` — the algorithms the audited spiders actually use.
///
/// The audit found no bespoke ciphers: every `csp_*` class in the portable set reaches for stock
/// AES/DES/MD5/SHA/HMAC through `javax.crypto` or `MessageDigest`. That is why a native `.so` doing
/// "signing" is reimplemented here rather than carried over — the algorithm is the contract, not
/// the binary that happened to compute it on Android.
enum CryptoHost {
    static func install(into context: JSContext) {
        let symmetric: @convention(block) (String, Bool, String, String, String, String, String) -> String = {
            algorithm, encrypt, input, key, iv, mode, inputEncoding in
            run(algorithm: algorithm, encrypt: encrypt, input: input, key: key,
                iv: iv, mode: mode, inputEncoding: inputEncoding)
        }

        let digestBlock: @convention(block) (String, String) -> String = { algorithm, input in
            hex(CryptoHost.digest(algorithm, Data(input.utf8)))
        }

        let hmac: @convention(block) (String, String, String) -> String = { algorithm, input, key in
            var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            let (cc, length): (Int, Int) = switch algorithm.lowercased() {
            case "md5": (kCCHmacAlgMD5, Int(CC_MD5_DIGEST_LENGTH))
            case "sha1": (kCCHmacAlgSHA1, Int(CC_SHA1_DIGEST_LENGTH))
            default: (kCCHmacAlgSHA256, Int(CC_SHA256_DIGEST_LENGTH))
            }
            let keyData = Data(key.utf8), message = Data(input.utf8)
            keyData.withUnsafeBytes { k in
                message.withUnsafeBytes { m in
                    CCHmac(CCHmacAlgorithm(cc), k.baseAddress, keyData.count, m.baseAddress, message.count, &out)
                }
            }
            return hex(Data(out.prefix(length)))
        }

        /// `App99` ships `base64(iv‖ciphertext)` under a random IV per request, which no string
        /// `iv` argument can express. The algorithm is stock AES-CBC/PKCS7, so it belongs here
        /// rather than inside the spider.
        let symmetricIV: @convention(block) (Bool, String, String) -> String = { encrypt, input, key in
            ivPrefixed(encrypt: encrypt, input: input, key: key)
        }

        let b64encode: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        let b64decode: @convention(block) (String) -> String = {
            String(decoding: Data(base64Encoded: $0, options: [.ignoreUnknownCharacters]) ?? Data(), as: UTF8.self)
        }

        let crypto = JSValue(newObjectIn: context)
        crypto?.setObject(symmetric, forKeyedSubscript: "symmetric" as NSString)
        crypto?.setObject(symmetricIV, forKeyedSubscript: "symmetricIV" as NSString)
        crypto?.setObject(digestBlock, forKeyedSubscript: "digest" as NSString)
        crypto?.setObject(hmac, forKeyedSubscript: "hmac" as NSString)
        crypto?.setObject(b64encode, forKeyedSubscript: "b64encode" as NSString)
        crypto?.setObject(b64decode, forKeyedSubscript: "b64decode" as NSString)
        context.setObject(crypto, forKeyedSubscript: "__crypto" as NSString)
    }

    /// `AES/CBC/PKCS7Padding` and `AES/CBC/PKCS5Padding` are identical for a 16-byte block, which is
    /// why the decompiled helpers use the names interchangeably.
    static func run(algorithm: String, encrypt: Bool, input: String, key: String,
                    iv: String, mode: String, inputEncoding: String) -> String {
        let keyData = Data(key.utf8)
        let ivData = Data(iv.utf8)
        guard !keyData.isEmpty else { return "" }
        let source: Data? = encrypt
            ? Data(input.utf8)
            : (inputEncoding.lowercased() == "hex"
               ? Data(hex: input)
               : Data(base64Encoded: input, options: [.ignoreUnknownCharacters]))
        guard let source else { return "" }

        let (cc, blockSize) = algorithm.lowercased().hasPrefix("des")
            ? (algorithm.lowercased() == "des3" ? (kCCAlgorithm3DES, kCCBlockSize3DES) : (kCCAlgorithmDES, kCCBlockSizeDES))
            : (kCCAlgorithmAES, kCCBlockSizeAES128)
        var options = CCOptions(kCCOptionPKCS7Padding)
        if mode.uppercased() == "ECB" { options |= CCOptions(kCCOptionECBMode) }

        guard let out = transform(source, key: keyData, iv: ivData, encrypt: encrypt,
                                  algorithm: cc, options: options, blockSize: blockSize) else { return "" }
        return encrypt ? out.base64EncodedString() : String(decoding: out, as: UTF8.self)
    }

    /// AES-CBC/PKCS7 where the IV travels in front of the ciphertext: encryption picks a fresh IV
    /// and returns `base64(iv‖ct)`, decryption takes the first block back off.
    static func ivPrefixed(encrypt: Bool, input: String, key: String) -> String {
        let keyData = Data(key.utf8)
        let block = kCCBlockSizeAES128
        guard !keyData.isEmpty else { return "" }
        let options = CCOptions(kCCOptionPKCS7Padding)
        if encrypt {
            let iv = Data((0..<block).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
            guard let out = transform(Data(input.utf8), key: keyData, iv: iv, encrypt: true,
                                      algorithm: kCCAlgorithmAES, options: options, blockSize: block)
            else { return "" }
            return (iv + out).base64EncodedString()
        }
        guard let source = Data(base64Encoded: input, options: [.ignoreUnknownCharacters]),
              source.count > block else { return "" }
        let iv = source.prefix(block), body = source.dropFirst(block)
        guard let out = transform(Data(body), key: keyData, iv: Data(iv), encrypt: false,
                                  algorithm: kCCAlgorithmAES, options: options, blockSize: block)
        else { return "" }
        // `App99.c()` runs the plaintext through `java.util.zip.Inflater` and falls back to the raw
        // bytes when that throws. It is not decoration: 剧圈99 answers `systemInit` with 36 KB of
        // zlib, and reading it as text produces replacement characters, not JSON. Inflating here
        // rather than in the spider is also what keeps it correct — the bytes never become a String
        // first, which would have destroyed them.
        return String(decoding: inflated(out) ?? out, as: UTF8.self)
    }

    /// zlib (RFC 1950) — a 2-byte header, raw DEFLATE, then an Adler-32 the decoder does not need.
    /// `NSData.decompressed(using: .zlib)` is that raw DEFLATE body, so the header comes off first.
    static func inflated(_ data: Data) -> Data? {
        guard data.count > 6, data[data.startIndex] == 0x78 else { return nil }
        return try? (Data(data.dropFirst(2)) as NSData).decompressed(using: .zlib) as Data
    }

    private static func transform(_ source: Data, key: Data, iv: Data, encrypt: Bool,
                                  algorithm: Int, options: CCOptions, blockSize: Int) -> Data? {
        var out = Data(count: source.count + blockSize)
        let capacity = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            source.withUnsafeBytes { s in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { i in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(algorithm), options,
                                k.baseAddress, key.count, iv.isEmpty ? nil : i.baseAddress,
                                s.baseAddress, source.count, o.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(moved...)
        return out
    }

    static func digest(_ algorithm: String, _ data: Data) -> Data {
        switch algorithm.lowercased() {
        case "md5":
            var out = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
            _ = data.withUnsafeBytes { CC_MD5($0.baseAddress, CC_LONG(data.count), &out) }
            return Data(out)
        case "sha1":
            var out = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            _ = data.withUnsafeBytes { CC_SHA1($0.baseAddress, CC_LONG(data.count), &out) }
            return Data(out)
        default:
            var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            _ = data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &out) }
            return Data(out)
        }
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

extension Data {
    init(hex: String) {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            if let byte = UInt8(hex[index..<next], radix: 16) { data.append(byte) }
            index = next
        }
        self = data
    }
}
