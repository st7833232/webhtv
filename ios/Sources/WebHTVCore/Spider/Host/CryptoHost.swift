import CommonCrypto
import CryptoKit
import Foundation
import JavaScriptCore
import Security
import zlib

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

        // js.host 1.5 (W-97): the key and message may be hex or base64 bytes; a 1.4 caller's three
        // arguments arrive with the encodings undefined, which reads as UTF-8 as before.
        let hmac: @convention(block) (String, String, String, String, String) -> String = {
            algorithm, input, key, inputEncoding, keyEncoding in
            guard let keyData = strictBytes(key, keyEncoding), let message = strictBytes(input, inputEncoding)
            else { return "" }
            let key = SymmetricKey(data: keyData)
            return switch algorithm.lowercased() {
            case "md5": hex(Data(HMAC<Insecure.MD5>.authenticationCode(for: message, using: key)))
            case "sha1": hex(Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key)))
            default: hex(Data(HMAC<SHA256>.authenticationCode(for: message, using: key)))
            }
        }

        /// `App99` ships `base64(iv‖ciphertext)` under a random IV per request, which no string
        /// `iv` argument can express. The algorithm is stock AES-CBC/PKCS7, so it belongs here
        /// rather than inside the spider.
        let symmetricIV: @convention(block) (Bool, String, String) -> String = { encrypt, input, key in
            ivPrefixed(encrypt: encrypt, input: input, key: key)
        }

        /// IOS-POC-44G: RSA PKCS#1 v1.5, split into blocks the way Java's "分段" helpers do.
        let rsa: @convention(block) (Bool, String, String, String, String) -> String = {
            encrypt, input, key, inputEncoding, outputEncoding in
            CryptoHost.rsa(encrypt: encrypt, input: input, key: key,
                           inputEncoding: inputEncoding, outputEncoding: outputEncoding)
        }

        let b64encode: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        let b64decode: @convention(block) (String) -> String = {
            String(decoding: Data(base64Encoded: $0, options: [.ignoreUnknownCharacters]) ?? Data(), as: UTF8.self)
        }

        // js.host 1.4 (QIST-GULU A, artifacts/qist-gulu-native-gate-2026-10-08.md §8.3): binary in and
        // out as standard base64, every failure "". Private keys never leave native code, and each
        // context keeps its own (`install` runs once per JSContext).
        let handles = ECDHHandles()
        let randomBytes: @convention(block) (JSValue) -> String = { n in
            guard let n = integer(n, in: 1...1024), let bytes = secureRandom(n) else { return "" }
            return bytes.base64EncodedString()
        }
        let ecdhP256Generate: @convention(block) () -> String = { handles.generate() }
        let ecdhP256Derive: @convention(block) (String, String) -> String = { handles.derive($0, peer: $1) }
        let hkdfSha256: @convention(block) (String, String, String, JSValue) -> String = { ikm, salt, info, length in
            guard let ikm = Data(base64Encoded: ikm), let salt = Data(base64Encoded: salt),
                  let info = Data(base64Encoded: info), let length = integer(length, in: 1...8160) else { return "" }
            let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info,
                                             outputByteCount: length)
            return key.withUnsafeBytes { Data($0) }.base64EncodedString()
        }
        let aesGcmSeal: @convention(block) (String, String) -> String = { key, plain in
            guard let key = aesKey(key), let plain = Data(base64Encoded: plain),
                  let combined = (try? AES.GCM.seal(plain, using: key))?.combined else { return "" }
            return combined.base64EncodedString()
        }
        let aesGcmOpen: @convention(block) (String, String) -> String = { key, combined in
            guard let key = aesKey(key), let combined = Data(base64Encoded: combined), combined.count >= 28,
                  let box = try? AES.GCM.SealedBox(combined: combined),
                  let plain = try? AES.GCM.open(box, using: key) else { return "" }
            return plain.base64EncodedString()
        }
        // Decryption checks PKCS7 itself: CommonCrypto hands back a block ending in 0x11 as if it were valid.
        let aesCbc: @convention(block) (JSValue, String, String, String) -> String = { encrypt, key, iv, data in
            guard encrypt.isBoolean, let key = Data(base64Encoded: key), [16, 24, 32].contains(key.count),
                  let iv = Data(base64Encoded: iv), iv.count == kCCBlockSizeAES128, let data = Data(base64Encoded: data),
                  let out = transform(data, key: key, iv: iv, encrypt: encrypt.toBool(), algorithm: kCCAlgorithmAES,
                                      options: encrypt.toBool() ? CCOptions(kCCOptionPKCS7Padding) : 0,
                                      blockSize: kCCBlockSizeAES128),
                  let result = encrypt.toBool() ? out : pkcs7Unpadded(out)
            else { return "" }
            return result.base64EncodedString()
        }
        let deflateBlock: @convention(block) (String, Bool) -> String = { data, wrapped in
            guard let data = Data(base64Encoded: data), let out = zlibDeflate(data, wrapped: wrapped) else { return "" }
            return out.base64EncodedString()
        }
        let inflateBlock: @convention(block) (String, Bool, JSValue) -> String = { data, wrapped, maxBytes in
            let cap = maxBytes.isUndefined ? 8 << 20 : integer(maxBytes, in: 1...(16 << 20))
            guard let cap, let data = Data(base64Encoded: data),
                  let out = zlibInflate(data, wrapped: wrapped, maxBytes: cap) else { return "" }
            return out.base64EncodedString()
        }

        let crypto = JSValue(newObjectIn: context)
        crypto?.setObject(symmetric, forKeyedSubscript: "symmetric" as NSString)
        crypto?.setObject(symmetricIV, forKeyedSubscript: "symmetricIV" as NSString)
        crypto?.setObject(rsa, forKeyedSubscript: "rsa" as NSString)
        crypto?.setObject(digestBlock, forKeyedSubscript: "digest" as NSString)
        crypto?.setObject(hmac, forKeyedSubscript: "hmac" as NSString)
        crypto?.setObject(b64encode, forKeyedSubscript: "b64encode" as NSString)
        crypto?.setObject(b64decode, forKeyedSubscript: "b64decode" as NSString)
        crypto?.setObject(randomBytes, forKeyedSubscript: "randomBytes" as NSString)
        crypto?.setObject(ecdhP256Generate, forKeyedSubscript: "ecdhP256Generate" as NSString)
        crypto?.setObject(ecdhP256Derive, forKeyedSubscript: "ecdhP256Derive" as NSString)
        crypto?.setObject(hkdfSha256, forKeyedSubscript: "hkdfSha256" as NSString)
        crypto?.setObject(aesGcmSeal, forKeyedSubscript: "aesGcmSeal" as NSString)
        crypto?.setObject(aesGcmOpen, forKeyedSubscript: "aesGcmOpen" as NSString)
        crypto?.setObject(aesCbc, forKeyedSubscript: "aesCbc" as NSString)
        crypto?.setObject(deflateBlock, forKeyedSubscript: "deflate" as NSString)
        crypto?.setObject(inflateBlock, forKeyedSubscript: "inflate" as NSString)
        context.setObject(crypto, forKeyedSubscript: "__crypto" as NSString)
    }

    /// `AES/CBC/PKCS7Padding` and `AES/CBC/PKCS5Padding` are identical for a 16-byte block, which is
    /// why the decompiled helpers use the names interchangeably.
    ///
    /// `inputEncoding` names the ciphertext's encoding in both directions: what decryption reads, and
    /// since IOS-POC-44G what encryption writes (`hex` for `AppDrama`'s CBC signature; anything else
    /// is base64, which is all a 1.2 caller ever passed).
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
        if encrypt { return inputEncoding.lowercased() == "hex" ? hex(out) : out.base64EncodedString() }
        return String(decoding: out, as: UTF8.self)
    }

    /// RSA/ECB/PKCS1Padding as Java runs it: a public key encrypts, a private key decrypts, and data
    /// longer than one block is processed block by block (k−11 bytes in, k bytes out). `key` is a
    /// PEM or base64 DER key — X.509 SubjectPublicKeyInfo or PKCS#1 for a public key, PKCS#8 or
    /// PKCS#1 for a private one. Text is UTF-8 unless an encoding says `base64` or `hex`. Any failure
    /// is "", like every other primitive here.
    static func rsa(encrypt: Bool, input: String, key: String, inputEncoding: String,
                    outputEncoding: String) -> String {
        guard let der = Data(base64Encoded: key.replacingOccurrences(of: #"-----[^-]+-----|\s"#, with: "",
                                                                     options: .regularExpression)),
              let secKey = rsaKey(der, isPublic: encrypt),
              let source = decode(input, inputEncoding)
        else { return "" }
        let size = SecKeyGetBlockSize(secKey)
        let chunk = encrypt ? size - 11 : size
        guard chunk > 0, encrypt || source.count % size == 0 else { return "" }
        var out = Data()
        var offset = 0
        while offset < source.count {
            let block = source.subdata(in: offset..<min(offset + chunk, source.count)) as CFData
            let result = encrypt
                ? SecKeyCreateEncryptedData(secKey, .rsaEncryptionPKCS1, block, nil)
                : SecKeyCreateDecryptedData(secKey, .rsaEncryptionPKCS1, block, nil)
            guard let result else { return "" }
            out.append(result as Data)
            offset += chunk
        }
        return encode(out, outputEncoding)
    }

    private static func decode(_ text: String, _ encoding: String) -> Data? {
        switch encoding.lowercased() {
        case "base64": Data(base64Encoded: text, options: [.ignoreUnknownCharacters])
        case "hex": Data(hex: text)
        default: Data(text.utf8)
        }
    }

    /// `decode` without its leniency: hex must be whole ASCII pairs and base64 must be padded and clean,
    /// so a typo is "" rather than a signature over whatever bytes survived parsing.
    private static func strictBytes(_ text: String, _ encoding: String) -> Data? {
        switch encoding.lowercased() {
        case "hex": text.count.isMultiple(of: 2) && text.allSatisfy { $0.isASCII && $0.isHexDigit } ? Data(hex: text) : nil
        case "base64": Data(base64Encoded: text)
        default: Data(text.utf8)
        }
    }

    private static func encode(_ data: Data, _ encoding: String) -> String {
        switch encoding.lowercased() {
        case "base64": data.base64EncodedString()
        case "hex": hex(data)
        default: String(decoding: data, as: UTF8.self)
        }
    }

    /// `SecKeyCreateWithData` takes PKCS#1 only, so an X.509 or PKCS#8 wrapper comes off first: the
    /// key is the BIT STRING (public) or OCTET STRING (private) after the algorithm identifier.
    private static func rsaKey(_ der: Data, isPublic: Bool) -> SecKey? {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: isPublic ? kSecAttrKeyClassPublic : kSecAttrKeyClassPrivate,
        ]
        return [unwrapped(der, isPublic: isPublic), der].compactMap { $0 }.lazy
            .compactMap { SecKeyCreateWithData($0 as CFData, attributes as CFDictionary, nil) }.first
    }

    /// The PKCS#1 key inside SubjectPublicKeyInfo / PrivateKeyInfo, or nil when `der` is not one.
    private static func unwrapped(_ der: Data, isPublic: Bool) -> Data? {
        let bytes = [UInt8](der)
        var index = 0
        func header() -> (tag: UInt8, length: Int)? {
            guard index + 2 <= bytes.count else { return nil }
            let tag = bytes[index]
            var length = Int(bytes[index + 1])
            index += 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count <= 4, index + count <= bytes.count else { return nil }
                length = bytes[index..<index + count].reduce(0) { $0 << 8 | Int($1) }
                index += count
            }
            return (tag, length)
        }
        guard header()?.tag == 0x30 else { return nil }               // outer SEQUENCE
        if !isPublic {
            guard let version = header(), version.tag == 0x02 else { return nil }
            index += version.length                                   // INTEGER version
        }
        guard let algorithm = header(), algorithm.tag == 0x30 else { return nil }
        index += algorithm.length                                     // AlgorithmIdentifier
        guard let wrapper = header(), wrapper.tag == (isPublic ? 0x03 : 0x04),
              index + wrapper.length <= bytes.count else { return nil }
        let start = isPublic ? index + 1 : index                      // BIT STRING's unused-bits byte
        return Data(bytes[start..<index + wrapper.length])
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
        // QIST-CRYPTO-IV: CommonCryptor.h — an IV, if present, must be one block long and is ignored in
        // ECB. A shorter one would be read past its end, so CBC refuses it; empty stays the all-zero IV
        // and a longer one keeps using its first block, as before (option B).
        let ecb = options & CCOptions(kCCOptionECBMode) != 0
        guard ecb || iv.isEmpty || iv.count >= blockSize else { return nil }
        let ivInUse = !ecb && !iv.isEmpty
        var out = Data(count: source.count + blockSize)
        let capacity = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            source.withUnsafeBytes { s in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { i in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(algorithm), options,
                                k.baseAddress, key.count, ivInUse ? i.baseAddress : nil,
                                s.baseAddress, source.count, o.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(moved...)
        return out
    }

    /// A JS number that is a whole value inside `range`; 1.5, NaN, strings and out-of-range numbers are not.
    private static func integer(_ value: JSValue, in range: ClosedRange<Int>) -> Int? {
        guard value.isNumber else { return nil }
        let number = value.toDouble()
        guard number.rounded() == number, number >= Double(range.lowerBound), number <= Double(range.upperBound)
        else { return nil }
        return Int(number)
    }

    fileprivate static func secureRandom(_ count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        return SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess ? Data(bytes) : nil
    }

    private static func pkcs7Unpadded(_ data: Data) -> Data? {
        guard let last = data.last, (1...kCCBlockSizeAES128).contains(Int(last)), data.count >= Int(last),
              data.suffix(Int(last)).allSatisfy({ $0 == last }) else { return nil }
        return data.dropLast(Int(last))
    }

    private static func aesKey(_ base64: String) -> SymmetricKey? {
        guard let key = Data(base64Encoded: base64), [16, 24, 32].contains(key.count) else { return nil }
        return SymmetricKey(data: key)
    }

    /// System zlib (§8.3, GULU-A-05): windowBits 15 adds and checks the zlib header and Adler-32, -15 is
    /// raw DEFLATE. An output buffer of `deflateBound` lets one `Z_FINISH` call finish (`zlib.h`).
    static func zlibDeflate(_ input: Data, wrapped: Bool) -> Data? {
        var stream = z_stream()
        guard deflateInit2_(&stream, 6, Z_DEFLATED, wrapped ? 15 : -15, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        var source = [UInt8](input)
        var out = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(source.count))))
        let status = source.withUnsafeMutableBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                stream.next_in = s.baseAddress
                stream.avail_in = uInt(s.count)
                stream.next_out = o.baseAddress
                stream.avail_out = uInt(o.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        return status == Z_STREAM_END ? Data(out.prefix(Int(stream.total_out))) : nil
    }

    /// 64 KiB at a time with `Z_NO_FLUSH`, where `Z_OK` always means progress. Only `Z_STREAM_END` with
    /// every input byte consumed succeeds: trailing bytes, truncation, a bad header or Adler-32, a
    /// preset dictionary, or more than `maxBytes` of output all fail, without ever holding more than
    /// `maxBytes` plus one chunk.
    static func zlibInflate(_ input: Data, wrapped: Bool, maxBytes: Int) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, wrapped ? 15 : -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { return nil }
        defer { inflateEnd(&stream) }
        var source = [UInt8](input), chunk = [UInt8](repeating: 0, count: 64 * 1024), out = Data()
        return source.withUnsafeMutableBufferPointer { s -> Data? in
            stream.next_in = s.baseAddress
            stream.avail_in = uInt(s.count)
            while true {
                let status = chunk.withUnsafeMutableBufferPointer { o in
                    stream.next_out = o.baseAddress
                    stream.avail_out = uInt(o.count)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    out.append(o.baseAddress!, count: o.count - Int(stream.avail_out))
                    return status
                }
                if out.count > maxBytes { return nil }
                if status == Z_STREAM_END { return stream.avail_in == 0 ? out : nil }
                if status != Z_OK { return nil }
            }
        }
    }

    static func digest(_ algorithm: String, _ data: Data) -> Data {
        switch algorithm.lowercased() {
        case "md5": Data(Insecure.MD5.hash(data: data))
        case "sha1": Data(Insecure.SHA1.hash(data: data))
        default: Data(SHA256.hash(data: data))
        }
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

/// One JSContext's unused P-256 private keys (§8.3 #2, #3), which never leave native code: at most four,
/// a fifth evicting the oldest. A handle names a key only in the context that made it.
private final class ECDHHandles: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [(handle: String, key: P256.KeyAgreement.PrivateKey)] = []

    /// `{"handle":"<32 hex>","publicKey":"<base64 x9.63, 65 bytes>"}`, or "" on failure.
    func generate() -> String {
        guard let raw = CryptoHost.secureRandom(16) else { return "" }
        let key = P256.KeyAgreement.PrivateKey(), handle = CryptoHost.hex(raw)
        lock.lock()
        keys.append((handle, key))
        if keys.count > 4 { keys.removeFirst() }
        lock.unlock()
        let object = ["handle": handle, "publicKey": key.publicKey.x963Representation.base64EncodedString()]
        guard let json = try? JSONSerialization.data(withJSONObject: object) else { return "" }
        return String(decoding: json, as: UTF8.self)
    }

    /// The handle is spent before the peer is looked at, so a bad peer leaves nothing to retry with.
    func derive(_ handle: String, peer: String) -> String {
        lock.lock()
        let key = keys.firstIndex { $0.handle == handle }.map { keys.remove(at: $0).key }
        lock.unlock()
        guard let key, let peer = Data(base64Encoded: peer), peer.count == 65, peer.first == 0x04,
              let peerKey = try? P256.KeyAgreement.PublicKey(x963Representation: peer),
              let secret = try? key.sharedSecretFromKeyAgreement(with: peerKey) else { return "" }
        return secret.withUnsafeBytes { Data($0) }.base64EncodedString()
    }
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
