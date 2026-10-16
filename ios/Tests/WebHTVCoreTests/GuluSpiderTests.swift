import CommonCrypto
import CryptoKit
import Foundation
import Testing
import zlib
@testable import WebHTVCore

// IOS-POC-57B-3 / QIST-GULU Stage 2 (design: qist-gulu-native-gate-2026-10-08.md §7, §8.5): Gulu.js
// against a server written here with CryptoKit, CommonCrypto and zlib — sharing no code with the
// adapter — that speaks Gulu.java's protocol with a fixed P-256 key, session id and GCM nonce, and
// answers with the plaintext listing and detail the live API returned on 2026-10-08.

/// The Gulu API's server side. One test at a time (the suite is serialized): `reset` sets the replies
/// and the fault, and every handshake and call is remembered.
final class GuluServer: URLProtocol, @unchecked Sendable {
    enum Fault { case none, cbcPadding, gcmTag, deflate, protobuf, http500, emptyBody }
    struct Call { let group: Int; let method: Int; let headers: [String: String]; let fields: [Int: [Any]] }

    static let host = "103.45.132.22"
    static let sessionId = "gulu-test-session"
    static let key = try! P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
    static let nonce = Data((1...12).map { UInt8($0) })
    static let replyIV = Data((0..<16).map { UInt8($0 * 3) })

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Data] = [:]
    nonisolated(unsafe) private static var fault = Fault.none
    nonisolated(unsafe) private static var sessionKey: SymmetricKey?
    nonisolated(unsafe) private static var handshakeHeaders: [[String: String]] = []
    nonisolated(unsafe) private static var calls: [Call] = []
    nonisolated(unsafe) private static var hosts: [String] = []

    static func reset(_ served: [String: Data] = [:], fault: Fault = .none) {
        lock.withLock {
            replies = served; Self.fault = fault; sessionKey = nil
            handshakeHeaders = []; calls = []; hosts = []
        }
    }
    static func serve(_ served: [String: Data]) { lock.withLock { served.forEach { replies[$0.key] = $0.value } } }
    static var handshakes: [[String: String]] { lock.withLock { handshakeHeaders } }
    static var made: [Call] { lock.withLock { calls } }
    static var asked: [String] { lock.withLock { hosts } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host || request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let url = request.url!, headers = request.allHTTPHeaderFields ?? [:]
        let (status, reply) = Self.lock.withLock { () -> (Int, Data) in
            Self.hosts.append(url.host ?? "")
            guard url.host == Self.host, url.path == "/app/bn/v2" else { return (404, Data()) }
            return headers["X-Handshake-Key"].map { Self.handshake($0, headers, body) } ?? Self.call(headers, body)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [:])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply)
        client?.urlProtocolDidFinishLoading(self)
    }

    // Gulu.java:223–301 from the other end: open the CBC-sealed, zlib-wrapped hello, agree on the key.
    private static func handshake(_ keyText: String, _ headers: [String: String], _ body: Data) -> (Int, Data) {
        handshakeHeaders.append(headers)
        let key = Data(keyText.utf8)
        guard let sealed = Data(base64Encoded: String(decoding: body, as: UTF8.self)), sealed.count > 16,
              let packed = cbc(false, key, Data(sealed.prefix(16)), Data(sealed.dropFirst(16))),
              let hello = zlibUnwrap(packed), let peer = fields(hello)[1]?.first as? Data,
              let client = try? P256.KeyAgreement.PublicKey(x963Representation: peer),
              let secret = try? Self.key.sharedSecretFromKeyAgreement(with: client) else { return (400, Data()) }
        sessionKey = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(sessionId.utf8),
                                                    sharedInfo: Data("v2-session".utf8), outputByteCount: 32)
        var plain = zlibWrap(pb([(1, sessionId), (2, Self.key.publicKey.x963Representation)]))
        let sealedReply: Data?
        if fault == .cbcPadding {
            // A last byte of 0x11 claims more padding than a block holds: CommonCrypto would accept it.
            let pad = 16 - plain.count % 16
            plain.append(contentsOf: [UInt8](repeating: UInt8(pad), count: pad - 1) + [0x11])
            sealedReply = cbc(true, key, replyIV, plain, padding: false)
        } else {
            sealedReply = cbc(true, key, replyIV, plain)
        }
        return (200, Data((replyIV + sealedReply!).base64EncodedString().utf8))
    }

    // Gulu.java:161–221 from the other end: open the GCM call, answer field 4 under a fixed nonce.
    private static func call(_ headers: [String: String], _ body: Data) -> (Int, Data) {
        guard headers["X-Session-Id"] == sessionId, let key = sessionKey,
              let combined = fields(body)[2]?.first as? Data, let box = try? AES.GCM.SealedBox(combined: combined),
              let packed = try? AES.GCM.open(box, using: key),
              let inner = try? (packed as NSData).decompressed(using: .zlib) as Data else { return (400, Data()) }
        let f = fields(inner), group = f[2]?.first as? Int ?? -1, method = f[3]?.first as? Int ?? -1
        calls.append(Call(group: group, method: method, headers: headers, fields: f))
        switch fault {
        case .http500: return (500, Data())
        case .emptyBody: return (200, Data())
        default: break
        }
        var reply = rawDeflate(pb([(4, replies["\(group)/\(method)"] ?? Data())]))
        if fault == .deflate { reply = Data("this is not deflate".utf8) }
        if fault == .protobuf { reply = rawDeflate(Data([0x22, 0x05, 0x01])) } // field 4 claims 5 bytes, holds 1
        var sealed = try! AES.GCM.seal(reply, using: key, nonce: AES.GCM.Nonce(data: nonce)).combined!
        if fault == .gcmTag { sealed[sealed.count - 1] ^= 1 }
        return (200, pb([(1, 0), (2, sealed)]))
    }
}

// ---- the server's own codecs: system zlib, Foundation raw deflate, CommonCrypto, a protobuf writer ----

private func zlibWrap(_ data: Data) -> Data {
    var out = Data(count: Int(compressBound(uLong(data.count))))
    var size = uLongf(out.count)
    let status = out.withUnsafeMutableBytes { o in
        data.withUnsafeBytes { i in
            compress2(o.bindMemory(to: Bytef.self).baseAddress, &size, i.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), 6)
        }
    }
    precondition(status == Z_OK)
    return out.prefix(Int(size))
}

private func zlibUnwrap(_ data: Data) -> Data? {
    var out = Data(count: 1 << 20)
    var size = uLongf(out.count)
    let status = out.withUnsafeMutableBytes { o in
        data.withUnsafeBytes { i in
            uncompress(o.bindMemory(to: Bytef.self).baseAddress, &size, i.bindMemory(to: Bytef.self).baseAddress, uLong(data.count))
        }
    }
    return status == Z_OK ? out.prefix(Int(size)) : nil
}

private func rawDeflate(_ data: Data) -> Data { try! (data as NSData).compressed(using: .zlib) as Data }

private func cbc(_ encrypt: Bool, _ key: Data, _ iv: Data, _ data: Data, padding: Bool = true) -> Data? {
    var out = Data(count: data.count + kCCBlockSizeAES128)
    var moved = 0
    let status = out.withUnsafeMutableBytes { o in
        key.withUnsafeBytes { k in
            iv.withUnsafeBytes { v in
                data.withUnsafeBytes { d in
                    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(padding ? kCCOptionPKCS7Padding : 0), k.baseAddress, key.count, v.baseAddress,
                            d.baseAddress, data.count, o.baseAddress, o.count, &moved)
                }
            }
        }
    }
    return status == kCCSuccess ? out.prefix(moved) : nil
}

private func varint(_ value: UInt64) -> Data {
    var v = value, out = Data()
    while v > 127 { out.append(UInt8(v & 127) | 128); v >>= 7 }
    out.append(UInt8(v))
    return out
}

/// proto3 for the server: an Int is a varint, a String or Data is length-delimited.
private func pb(_ fields: [(Int, Any)]) -> Data {
    var out = Data()
    for (n, value) in fields {
        switch value {
        case let int as Int: out += varint(UInt64(n << 3)) + varint(UInt64(int))
        case let text as String: out += varint(UInt64(n << 3 | 2)) + varint(UInt64(text.utf8.count)) + Data(text.utf8)
        case let data as Data: out += varint(UInt64(n << 3 | 2)) + varint(UInt64(data.count)) + data
        default: preconditionFailure("\(value)")
        }
    }
    return out
}

/// Field number → values: an Int for a varint, Data for a length-delimited field.
private func fields(_ data: Data) -> [Int: [Any]] {
    let bytes = [UInt8](data)
    var at = 0, out: [Int: [Any]] = [:]
    func read() -> UInt64? {
        var value: UInt64 = 0, shift: UInt64 = 0
        while at < bytes.count, shift < 64 {
            let b = bytes[at]; at += 1
            value |= UInt64(b & 127) << shift
            if b < 128 { return value }
            shift += 7
        }
        return nil
    }
    while at < bytes.count, let key = read() {
        switch key & 7 {
        case 0:
            guard let value = read() else { return out }
            out[Int(key >> 3), default: []].append(Int(value))
        case 2:
            guard let length = read(), at + Int(length) <= bytes.count else { return out }
            out[Int(key >> 3), default: []].append(Data(bytes[at..<at + Int(length)]))
            at += Int(length)
        default:
            return out
        }
    }
    return out
}

private func text(_ value: Any?) -> String { (value as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "" }

private struct FixtureMismatch: Error {}

/// The live replies saved on 2026-10-08 (field 4 of an opened call, design §3), raw-deflated and
/// base64-encoded here; the SHA-256 is the one recorded when they were fetched.
private func fixture(_ sha256: String, _ base64: String) throws -> Data {
    guard let packed = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { throw FixtureMismatch() }
    let data = try (packed as NSData).decompressed(using: .zlib) as Data
    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else { throw FixtureMismatch() }
    return data
}

private func listTv() throws -> Data { try fixture("c5fc72ae92ee23269fa198fc8748b35eecdf3e68eac8e834d2163b0be73eaf33", listTvPage1) }
private func detail902056() throws -> Data { try fixture("3aeee602c4289e3d1e0b18aef89b9941ffdd9e10aa7122dc5c39d0d566f8a0e3", detail902056Reply) }

private func gulu(_ session: URLSession? = nil) async throws -> JavaScriptSpiderRuntime {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GuluServer.self]
    let registry = SpiderRegistry.bundled(bundle: .repoSpiders)
    let runtime = try JavaScriptSpiderRuntime(
        name: "Gulu", script: try #require(registry.entry(for: "csp_Gulu")?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: "Gulu-test", defaults: UserDefaults(suiteName: "Gulu-test")!),
        session: session ?? URLSession(configuration: configuration))
    try await runtime.initialize(extend: "")
    return runtime
}

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func list(_ text: String) throws -> [[String: Any]] {
    try #require(try object(text)["list"] as? [[String: Any]])
}

/// One listing entry whose id is `id`, written last so a truncated varint ends the message.
private func listing(id: [UInt8]) -> Data {
    var item = pb([(2, 2026), (3, "边界测试影片"), (6, "https://p.invalid/poster.jpg")])
    item.append(0x08)
    item.append(contentsOf: id)
    return pb([(1, item)])
}

@Suite(.serialized) struct GuluSpiderTests {
    // W-112: the server ignores the year and sort it is sent (W-70), so the home offers no filter rows.
    @Test func homeOffersTheJARsTwelveClassesAndNoFiltersWithoutTouchingTheNetwork() async throws {
        GuluServer.reset()
        let home = try object(try await gulu().homeContent(filter: true))
        let classes = try #require(home["class"] as? [[String: String]])
        #expect(classes.count == 12)
        #expect(classes.first == ["type_id": "movie", "type_name": "电影"])
        #expect(classes.last == ["type_id": "jp", "type_name": "日剧"])
        #expect(home["filters"] == nil)
        #expect(GuluServer.asked.isEmpty)
    }

    @Test func aCategoryHandshakesBootsOnceAndReadsTheSavedListing() async throws {
        GuluServer.reset(["3/66": try listTv(),
                          "1/0": pb([(7, pb([(2, "咕噜4K"), (3, "https://template.invalid/api?url=")]))])])
        let spider = try await gulu()
        let page = try object(try await spider.categoryContent(tid: "tv", page: "1", filter: true,
                                                               extend: ["year": "2026", "sort": "vod_time"]))
        let items = try #require(page["list"] as? [[String: Any]])
        #expect(items.count == 21)
        #expect(items.first?["vod_id"] as? String == "902056")
        #expect(items.first?["vod_name"] as? String == "兰香如故")
        #expect(items.first?["vod_remarks"] as? String == "更新至第43集")
        #expect((items.first?["vod_pic"] as? String)?.hasPrefix("https://vcover-vt-pic.puui.qpic.cn/") == true)
        #expect(page["page"] as? Int == 1 && page["pagecount"] as? Int == 2)

        let hello = try #require(GuluServer.handshakes.first)
        #expect(hello["X-Handshake-Key"]?.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil)
        #expect(hello["Content-Type"] == "text/plain")
        #expect(hello["User-Agent"] == "Dalvik/2.1.0 (Linux; U; Android 11; Pixel 4)")
        #expect(hello["X-Player-Page-Protection"] == "1")

        let calls = GuluServer.made
        #expect(calls.map { [$0.group, $0.method] } == [[1, 0], [3, 66]])
        #expect(calls.allSatisfy { $0.headers["X-Session-Id"] == GuluServer.sessionId && $0.headers["Content-Type"] == "application/x-protobuf" })
        let device = text(calls[0].fields[4]?.first)
        #expect(device.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil)
        let boot = fields(try #require(calls[0].fields[6]?.first as? Data))
        let app = fields(try #require(boot[4]?.first as? Data))
        #expect(text(app[3]?.first) == "com.jymqfh.xee" && text(app[4]?.first) == device)
        let query = fields(try #require(calls[1].fields[6]?.first as? Data))
        // W-112: a year or sort that still arrives (an old saved filter) is not sent; the server ignored it.
        #expect(query[1]?.first as? Int == 9 && query[2]?.first as? Int == 1 && query[3] == nil && query[5] == nil)

        // The session holds: page 2 is one more call, no second handshake; the boot template is never fetched.
        _ = try await spider.categoryContent(tid: "doc", page: "2", filter: false, extend: [:])
        #expect(GuluServer.handshakes.count == 1)
        let second = fields(try #require(GuluServer.made.last?.fields[6]?.first as? Data))
        #expect(second[1]?.first as? Int == 6 && second[2]?.first as? Int == 2)
        #expect(!GuluServer.asked.contains("template.invalid"))
    }

    @Test func aDetailOffersOnlyTheDirectLines() async throws {
        GuluServer.reset(["3/62": try detail902056()])
        let spider = try await gulu()
        let vod = try #require(try list(try await spider.detailContent(ids: ["902056"])).first)
        #expect(vod["vod_id"] as? String == "902056")
        #expect(vod["vod_name"] as? String == "兰香如故")
        #expect(vod["type_name"] as? String == "古装/爱情/国产/电视")
        #expect(vod["vod_actor"] as? String == "刘学义、谭松韵、牛骏峰、李梦、郑合惠子、郭柯宇")
        #expect(vod["vod_director"] as? String == "黄颖湘、陈丹")
        #expect(vod["vod_area"] as? String == "大陆" && vod["vod_year"] as? String == "2026")
        #expect(vod["vod_remarks"] as? String == "更新至第43集")
        // W-112: 腾讯视频's episodes are v.qq.com pages no parse service opened (W-70); only m3u8 lines stay.
        #expect(vod["vod_play_from"] as? String == "电影天堂$$$暴风资源$$$量子资源$$$非凡资源")
        let lines = try #require(vod["vod_play_url"] as? String).components(separatedBy: "$$$")
        #expect(lines.map { $0.components(separatedBy: "#").count } == [47, 47, 47, 47])
        #expect(!lines.joined().contains("v.qq.com"))
        #expect(lines[0].hasPrefix("第01集$https://vip.dytt-tvs.com/20260911/36662_4031da8c/index.m3u8#"))
        // The prefixed lines (xfy-, CO4K_, rose_, NBY-, qsvip-, …) and pylg's bare ids are gone.
        let episodes = lines.flatMap { $0.components(separatedBy: "#") }
        #expect(episodes.allSatisfy { $0.components(separatedBy: "$").count == 2 && $0.components(separatedBy: "$")[1].hasPrefix("http") })
        let query = fields(try #require(GuluServer.made.last?.fields[6]?.first as? Data))
        #expect(query[1]?.first as? Int == 902056 && text(query[4]?.first) == "APP_PLATFORM_ANDROID_TV")

        GuluServer.reset()
        #expect(try list(try await spider.detailContent(ids: ["902056|||9"])).isEmpty)
        #expect(GuluServer.asked.isEmpty)
    }

    // W-112: the rule is the episode, not the line's code (W-114 found mgtv, bilibili and rrmj pages too):
    // a page episode goes, and a line left with no m3u8 (or m.php) episode goes with it.
    @Test func aDetailKeepsOnlyEpisodesThatPlayDirectly() async throws {
        func episode(_ no: Int, _ url: String) -> Data { pb([(1, no), (3, url), (4, "第\(no)集")]) }
        func line(_ code: String, _ urls: [String]) -> Data {
            pb([(1, code)] + urls.enumerated().map { (2, episode($0.offset + 1, $0.element)) as (Int, Any) })
        }
        GuluServer.reset(["3/62": pb([(5, "手做"),
            (75, line("mgtv", ["https://www.mgtv.com/b/1/2.html"])),
            (75, line("dyttm3u8", ["https://v.invalid/a/index.m3u8", "https://www.bilibili.com/bangumi/play/ep1"])),
            (75, line("rrmj", ["https://m.yichengwlkj.com/drama/58134?episodeNo=1"])),
            (75, line("lzm3u8", ["https://relay.invalid/m.php?id=7"]))])])
        let vod = try #require(try list(try await gulu().detailContent(ids: ["5"])).first)
        #expect(vod["vod_play_from"] as? String == "电影天堂$$$量子资源")
        #expect(vod["vod_play_url"] as? String == "第1集$https://v.invalid/a/index.m3u8$$$第1集$https://relay.invalid/m.php?id=7")
    }

    @Test func searchReadsAListingAndTreatsAShortReplyAsNone() async throws {
        GuluServer.reset(["3/61": try listTv()])
        let spider = try await gulu()
        let page = try object(try await spider.searchContent(key: "兰香", quick: false, page: "1"))
        #expect((page["list"] as? [[String: Any]])?.count == 21 && page["pagecount"] as? Int == 2)
        let query = fields(try #require(GuluServer.made.last?.fields[6]?.first as? Data))
        #expect(text(query[1]?.first) == "兰香" && query[2]?.first as? Int == 1)
        #expect(text(fields(try #require(query[5]?.first as? Data))[3]?.first) == "vod_hits_week")

        GuluServer.serve(["3/61": listing(id: [0x07])])
        #expect(try list(try await spider.searchContent(key: "兰香", quick: false, page: "1")).isEmpty)
    }

    @Test func playPlaysAnM3u8DirectlyAtTheJARsBitrateAndSniffsAPage() async throws {
        GuluServer.reset()
        let spider = try await gulu()
        let m3u8 = try object(try await spider.playerContent(flag: "电影天堂", id: "https://v.invalid/720p/index.m3u8", vipFlags: []))
        #expect(m3u8["url"] as? String == "https://v.invalid/1080p/index.m3u8" && m3u8["parse"] as? Int == 0)
        #expect((m3u8["header"] as? [String: String])?["User-Agent"] == "Dalvik/2.1.0 (Linux; U; Android 11; Pixel 4)")
        let page = try object(try await spider.playerContent(flag: "腾讯视频", id: "https://v.qq.com/x/cover/a/b.html", vipFlags: []))
        #expect(page["url"] as? String == "https://v.qq.com/x/cover/a/b.html" && page["parse"] as? Int == 1)
        let keyed = try object(try await spider.playerContent(flag: "咕噜4K", id: "xfy-abc", vipFlags: []))
        #expect(keyed["url"] as? String == "")
        #expect(GuluServer.asked.isEmpty)
    }

    @Test(arguments: [GuluServer.Fault.cbcPadding, .gcmTag, .deflate, .protobuf, .http500, .emptyBody])
    func everyBrokenReplyGivesAnEmptyListing(_ fault: GuluServer.Fault) async throws {
        GuluServer.reset(["3/66": try listTv()], fault: fault)
        let spider = try await gulu()
        let category = { try await spider.categoryContent(tid: "tv", page: "1", filter: false, extend: [:]) }
        if fault == .http500 {
            // The adapter answers nothing; the runtime reports the failed request behind it.
            await #expect(throws: SiteUnreachable(.httpStatus(500), host: GuluServer.host)) { _ = try await category() }
        } else {
            #expect(try list(try await category()).isEmpty)
        }
        #expect(GuluServer.made.count == (fault == .cbcPadding ? 0 : 2))
    }

    @Test func varintsAboveTheSafeIntegerAreMalformed() async throws {
        GuluServer.reset(["3/66": listing(id: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f])])
        let spider = try await gulu()
        func category() async throws -> [[String: Any]] {
            try list(try await spider.categoryContent(tid: "tv", page: "1", filter: false, extend: [:]))
        }
        #expect(try await category().map { $0["vod_id"] as? String } == ["9007199254740991"])
        let malformed: [[UInt8]] = [[0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x10],  // 2^53
                                    [0x81, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x10],  // 2^53 + 1
                                    [UInt8](repeating: 0x80, count: 10) + [0x00],      // 11 bytes
                                    [0x80, 0x80]]                                      // ends mid-varint
        for id in malformed {
            GuluServer.serve(["3/66": listing(id: id)])
            #expect(try await category().isEmpty, "\(id)")
        }
    }

    // Live: GULU_LIVE=1 swift test --filter GuluSpiderTests — a real handshake, listing, detail and m3u8.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GULU_LIVE"] == "1"))
    func liveHandshakeListingDetailAndM3u8() async throws {
        let spider = try await gulu(URLSession(configuration: .ephemeral))
        let first = try #require(try list(try await spider.categoryContent(tid: "tv", page: "1", filter: false, extend: [:])).first)
        let id = try #require(first["vod_id"] as? String)
        let vod = try #require(try list(try await spider.detailContent(ids: [id])).first)
        let line = try #require((vod["vod_play_url"] as? String)?.components(separatedBy: "$$$").first { $0.contains(".m3u8") })
        let url = try #require(line.components(separatedBy: "#").first?.components(separatedBy: "$").last)
        let play = try object(try await spider.playerContent(flag: "", id: url, vipFlags: []))
        let media = try #require((play["url"] as? String).flatMap(URL.init(string:)))
        let (_, response) = try await URLSession(configuration: .ephemeral).data(from: media)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
}

// ---- fixtures ----

// list-tv-p1.pb: raw deflate, base64
private let listTvPage1 = """
rXwJcFzHmZ6HBwzQsqV41xXFSa0RVqWyu2UScx90UjEpS5Fp2XIs7a7NpIo7AAYUbJKAQZCWsOWqGQzmxlw45sAMMMAAc+CYC+fcw42TWsbxJi5XJd54
q7wVabrfe95k5XVVsna8W8n/dw+GIEVZlh3ViOx506+7X7////7vP5q9fc/8s49/7C1zgPrmxLVZmo6/ZQ4SV0aK2c/33hsbvn5z9M7kpR5+5cXf/MNn
X382KZMpvi2Tyf9Mdu7Hsms/ld0xnzoXOSVLnuqhsX2ysfTg1LPfPS37wekeaclP41Xx9LM/Of1vT/3R+cGx189f+qPzptvGwZum6zcmjMOjptuT5y+N
GG/eMX3y/OitG9fvTtw8f+n8ef5lbNw4NDr5xvlLik+eP9keGrs5NsG7HQ9yffKNcdP5S/KHV3Am1vEO73lncmy80xw03Ri9ff6S+pOwlOHzl7Tf/OYn
zw8bJ76Gt7yfNZ5c0+Pr/f+/xm9+03xG5j7zoV7ZMx979k/+Qf9/jJyZO/Ots71Zh+6ZHz398aeIrSiloyQ9TRdt/aeU/+q1ycnxO5cGBu4Njd0zTVy4
N3lhfHTo4vjdu6MXv46todudn67fm7wOFwbkA7emhuRypVyul6uGJ7SDCp1er1IqdFqFVq4fkF/69PGQo7eMN0wXJ28ND14cm7gxMDkwPvANhVIPA1x7
xfSNr//+za+oX1C+oLz8+i3da6P/Uvu5Ky9fGb/41fEbV84pdAaFWqPUyRXX/h4ICw0VRceesLOjVoF0mZaifZcn+ogzQnLpdsU10ScWc3S5KSUOJvoE
V0za8pO94kQPXfbRZHriKckaJAEnta6SXGCiT7LmaKJA8o6pPqk2IyVDtBKZ6pGizna5Mi3rIRsZKWp3Q8O/Ia7boCE4S9SKDRJrtKsZvLJwIGagz2l+
XWytCLUcfIW1YTe7jcSLc7JzSrlSe0FuuKBQJGU7p8RCCpSDrlaoNy+kmzTqJ6USKfrFwv5bZjd/K0I98pbZQxcqQj30lnka1gJPSNa3STUuLbZILkpS
e3TXSSIu6N8u+0jAL1mzpLjUrqTpSpjkD4WlGd4TvkoLaZqqi/lku+whm0tCNf12fVaYORTNszS+TFanpXVfuxoUtizEH8GfUiHBeYjjH88rJreJc0Ms
eiSzvV3xCI0t6IYd8ofUmpUsOcGSk8JZWCqfvV2utqt20bHVbi1DT1gh7yyZzbAAuEL8aVx2c424vPhS9w/EgwNcdm2+Xd3FcdjTFWXrh79Rlh39k/uy
7y6cfiD71o96vis7NXcmcLb3LxfOMjGm4VXiL9BYq11bBzFWocyByN26+MbXQMcuDo3dGpBr5M/L4T/t5SuXVTqtXqF6waCVK9TPqRU6tdagu/TcLxDU
sYlR0CzjzYEbLw1Ofv6lrw9+QTty4yt3Xr374gv3pq7e1b04Nj76qKxqlVevtMteGimQADy6uV3eetVk6u+HbyTghV+gwS589p/e6ofGJ/s/b+p/dWwM
elSPqHURtoHEctc+1JV3hcb0gQ/0Xn5EKEGCUOYek7yuRD6UUeIt0r0iNCRrg5Snu9LJpZlLp5xJpz4pW+9Ip5jfFVtFEEqS8JFMkGQjpBkQWwl405LF
QXwJYSGBy6zmoDMIDQn4UG4yLjprEWrL8IwgMe1aqF2t8jcD4ghtuEsI2EnrQGzFiC1F5rJiAYRyqSMisSaOHz0i+T1SOSTOQ5JfIhveds0h5teIcw4G
EXaboqcEWtyuR2FA4j9st9ZAIonNScpO0pyDleCvjTgKWTzbrs4RdxamkyIglDlhoUSXMjSSEQuL1JeEvYWJpM2m1AhImyWU6bhZqDmpq0mcxZOSBVOT
Rp3mNkA0i7KVv5WVZf/7w/dlTuMD2Q+/I2My+V97e3/+1wYmk+1GVKgmaTjTrnpAJl8+Fi9ATe3F0a+PvjHKABVEkwncAAKE3KA0DIwMD+hHBozXFYip
CrlWe/3WdZDU67c01zU6w3WdTnlx/PYjsHj1t/hk/QP9ksMnWLZpJAXqDF/bVR/d33oUNlVqhE0UJsC/zZ123S0EvICVPk+7sQcfANP6KpnfJV4fNANB
engAmzvR065FROcW60g2NsVmES/VSGMHIDe4TvLLQmKPAXG7sSkE0nDV1WyXGyRrm+gRza12BfAWFFxqRsXSFo68SCMJHKZPnPOIhbAYmJ3oIfGEWLJP
9eDCj+pPkvYewV0A7Hl3CO7INp3eEULBrl7MyZ49hmCl4bdBDOBuPvbvJGXus6QxD2+4XY6T2TANOdCW1NbFtSwKrGvzLbMFYJnWtwFOUQpy66J7GsGZ
9RRyIRRMfw7sCKiFGAyjEAWq1OURog3Bh/gMMgVbC0iOjwGmqOGAMflDopAW7aAWdL/GFy2UamTFQ/wg3R7qy8Jrk7YjtJHHnrY6sR3xdZK6HxdTaUi1
CKiO6PEShwtVcNksxOs0fAiPAG+fHljgcRFpgw2xFRCbVuLehRtpNC+Zl0C/+TPi4HOzqK+1HXj1BF4iqBqoeLAhrOxQSwGkvh9oAqyJI4NS3i6HhOqW
QU4q+93NA6wj1QzdXRMDDVzdUQp0m4MI03AzvI52eVf0zomFFSFdIykHdgs26JrzTfMCfIi9Rp0BYi9KsUW0YLY5aQc3CYwMAAoN5cTpJN6ynqclfFxY
vhTeF+fKxB/E6/Ei2dgXY443zWn4CHFPu16nhW3UZNueaFnAB82vEGeU74fgK+AnVqaudTaLjc4kuJ4L1VUxGIOLsGZpwfKmOU5n/GQjRHO1dnXtTfOy
aJ3lqEfdjXZ5mbhS4myGOKoAWHR5GoHPnEHEgc0ub9KlEPbMeyTbEe5rLkL3FmEZYJBx2WXAnRhDFv93AVlc5+7Lmv/mgew7VY4s/+ds74+/e4khi5Sz
kUZJSK1Q7yIgy5ceGq4bF29OdWHl7vjNMePwANBxhi0AJ8oLigGTdnBQoTKZhrQm1bBiWKWSD5kMBpNRp1Ko9SaV8uI3TIPjv5wxHHrl86PKGy/dMtz9
nOne8zdGvqa7/fKXx1/88ssa3aPGUC9/FIEUOkSgP/3OU4BAQiOMtMMeneijoYpkLrfrAB1g+YVmg+5bJvrajUW6N08yYYY89OBISKUYcEnhmtiKA5A0
AzS3TquIKf5D4C0wD3SI2oHZCQ4rDhYFdGpX84BDBwei1wxkzxps1xOgvicRposYD+3mMe3jNO6d9I4jzzG2KMCGKh/Hlp1TUrkFctYuu4gXNNEK2oLv
eyOD6gNPFEd2RLx7AAJiy0eXU6hC4AHNzwDXIke77YoN+otrZimWFW0I7Nh/2kxm1oRMhMZBMS2ISwsJKbcA2wlfhZZN9FVoYU6MbrNf46K7RIv7NO6E
r6SRBNFEg1l2gtwLtYzgAwIZYrq0BmsHtYRxEMFyGyD07eoC2HOxsAZzgdCD9AsW0DEvbC6uxAmMbhWEHpZN1zbxY3VLWw6xdQQqjcS1UhaWHHTZKoCj
V1rhckv8ZdjTdi0l1Xw0VACuKKVD8JhF2ffsIP1rT92X/ZcvPMAvTPr/XU/v9+aYXX2aOoMdYgXEtOz8Nb2Wr6p1X9PcVIHXYpAbFFqtWqszDMgfMa4q
2FzYdPHgCAwqInWsDA1aSnQaziAsBvidkA8DogAJgTfxqLwr1V1H5YMA/rDb/RMf6ocW27JA/0Qv8MJ94lzCy+jJ2FelaoL1WYlLyyEpHmJfDo5QNDY2
8QaatHRaZHePhst8xCx2yFrYOPVVGj0EKe9+mReLafwCng66GotN/CKGYmCYiGMZv+BbBwUL1NkXkM3dmJCeYffk/MRrFVoL7B4XeCzzQmCrf+JcP8l7
SApN+RT4WFlh3f2I0e5oUoeiPmaTH1OjpOzBqXbZTfIRsbBEIz5iy3Z9C3hWhOj9pphvkpKZuxoosLUQmQ0BpaaNeLvuZ1dSgisqtiLwZ+drvI5f42hE
AP/BLIvVbaCYdC9Fj0LEu0/cLTFtAbcGZgF/Cy0eIHYpIa2vCI5FtKgLWVyxryBthWF24veS6A5QUro42zFqRwXqz0nxXegAWiLVgqSy2KWSwnxazKx3
HwGXkVmni0HiD1NfRjTbmN3ZpJZD6tohoRm4hTSK0ACWzKwu8wHBk6KReVTbYz/xiaIHtIRZkW9XT5Vlrd77sp9//oHMUed69Bc9vZmfMte/D1YtzBeA
Kb6nw3RZZfiMRqOTX1arPqNQKxXPKVUqzQkd0aqv9ark8CbhhYGUyy4DzubLxFEAOhfMtiuJiR7gQbQJJFMKH8CMIDzgkCcK4G8jUDvBqgLJhN71VSF4
CHd7wiRu5cg+WxAbmxPoncNdJJuAq4VZlK9mFOnkNrjx0nwO7/HTdQ+zEWAC4OFgOHB8C0A+gaOgHejBF+AsTfTg20HnHyU3HxPdZdakO+tob1CIxcYh
WI1EoV2xtqtOZo1gctAMZlakLT+usg860iMHrQY4YfYuIUtmza2YNFeceEpyBGFKDK7M+Bn1BSUhXhf0ySzRhRYYOLhqXRPNESkCE0tRdJnh0sIa8c5L
SKaFTTswaJDBqT7aiJC8C9Z9Ur0eRiO6hqprupjP9F4WC10+3eMWK30KnfDVfTQS1TW0VUUQ533chcM0cESxmCTVOPA7aalJqocktQdXaBkspJ2ZEPBA
DqTcNF0Kk4040p9YGRxGxrAOUZmA9DmBjh3yAUFBcRYni1bMH5KyBXqKB6vYs5omqQaoJmrYwRHwYwxe+GoYGgCGWNkH8tWdmsRWSGOOrw31KVoFh1Fs
OeApUOG25lk8Yo0WvHQ/TOwbb9djnSc62oXRJIdXdCABJCkXDWfFaSsMS7NbZC0C07XLG0gzHV7JnATAAAN08eLFoqzpOV2Wfe/Mfdn3/vED2eIoU7F4
T2/6j9WdsMQmk3awu2HQst/raJlCrrqo1lxUANlSKi8plVqd/HGyJterFEDWVOphhdqoViNpM+p1I8P6EZ3OqNaZDMMjSnANkWZd+tfH5u/mqPH2jSH4
/8It46RpYtR486Lx5ujQ8G2mz+MTMHZnGrVmeGREqTZphk1Dau2g0WBSmkxag06pUygGR/RaRgIf4XBqtfbqM6++Zup/3jhx843+V8YnRm/fuNYLGs+N
m0p1Gshcu7pIE35h5pApHxgMUJhGAFE1us9jdOAIzIbhV2dEWLSxqBw5Wmaa365HmPbQ6ALTTtSXWQzN8SgdKP/mEXTMW0gLdbmRA/0DJXSCEARZAA+8
SKAyQAWfqCHHkY/3DNx1uR4qTDdwp7+g1CKXQ/ewPg0+M8kw1o7RNg9ds2LoYsUCrhm6xgf4ExAn8Fuoy4uUabUJUC54cmAnUBvMSZApwZoTrE7iASuS
fGSoaprmQCfS4qEHFiLGgSxFUEIXWyjXcztC0teu2vmYQNvAJyPLS8LaDg7SskqRXaaFczARCZRJfZHFXdBNIvEs34Z2OUZXwFXLwZqlaIB6XNSFNJI4
7fgJOOGDK2Sbx/zTEhgasILEBj3NNO7CZReZK2X3gmclWcLU3uS3ME4Yhf5F2Z/P9pZlNtCP4iceyOxfYPqROdu7uq5F/QAnf0Na8Py6DG7yzuvy4TsK
HTA3pUar02sUDxmcWqeSK6/1gYqT/KxQmzeNjPQACcMQhqPAiBEYqOYySCzjVDsZsbTFLoN4RUogooxWOQN0ryg43NgH5JnuJFlrusQY2IcYeQsUwGnu
MDnx0H2SmEHX7YgU3O60qPcIW2ClyB4QwQ/2Y/TEAwKMZgHEfK/4JAbVIxa91Bk5QaI6ctuN9p0EehRV7qsLCyXkhPkwd9ZBxGDXkd7szZACEJ4MkHTR
PAvwisLlWidu4JAbZLeMPAd40YyLBliYITALkM184Qj1bYphv7Bs5p4KSVrBKYbOxB1DPQBWEqqgrC0FxIUGLFqotoDXIb7POeGFi02r5PAzVHUfr2oZ
fCMeRqDxbZhFCjfI0QqIKhqm/CGaPmCDJTZjoQJuNV0FUpci9WnmO2PUD+UutkrjVaEeIUcZEGEeWADfC26nvjlG1TAmTWwleBxUi0YLOsCaizIbBSj/
y1P3Zf/57z+QZS8xUb3f21vfYVD+NE5hA6dtS8juEUvq/aK5Ug5oPqIeVhmHjXL50JBmRK5QDaoUg1q9dsQ4pNQY5cOaXxXNjQq93DhsUmsMKo16SG4w
Dg0ZVHL1kEpvNGnVppHH0FylNciVqqu/C++p81T5FXhb3WeDDQK35ot3b97sf2USYf4Ow3nG8Di966OLISG4IlWA1gDOC0CH0+hcu5pCaY/9iqzMXJ5g
YTygYOiu08UdJHksfBhxUYcHiNlCEUzqFHPxm16SeCTl0q5F283VJ3Kbx5CbpBykUns3CIc/SSiOF0GyG9gQMkBnaiegXWFIyu6fIS4vommkAGsSwg46
vQ7MHDVl2YdZlEKLB3/w14UEhob3t0TvHAow8wLADQG3AgUMRDTghU2BNfL4GYb6wGXdbaJ8rsQZ2PvhI0zXAUTJ+jaXTLG6K1lagCmSZV5KzohZM48d
wRXkPeDuurc5QRHXZsG88NcF5gWUGm7hnghYAGrdQzcKqGc1J3owrMjHB2+ee0z8Rjrv5SFyzEa4s3gxPS2aLYInzBYM6p/FWRJ7wAXRhlvdMFfH51pe
arfWqGseP8tm+OBGsYgjYK1Q8wPxAqKGcAEGZzmIIUaWEoCeHUIG172LsGOd6xZPx3SknCgOi8xezc0KTR82gEM38rS4LzpBiGbpcoovgyVWvLiZ8NTO
AKabWgEhVyHlI1KZYcHRRUwGbGTajR0WZTnClMPGEgKUd4nUnYiH5RyDtQDsBhrtZpSG/XwD+fMKC0sYgp1eP/kiwK0h7lXJzCRhOcVcrnLrbFk2c/q+
7PsfeyB7c4BhiKent/aWHjHkH2K4b7YmZNLg2+Ira0aFxS3SNPMEwUvHii9HD+y10cl7HUU33Rs1fWPgzvh1Fou7wxBlQG6Av49zBnLAIIAYnV6l0evl
jyVNDVfl6Fs650CaMYAB/AT2kbUfW1D3p2s9HWv5p9/5209PnGuDWln80IcZNf+ukAsdxwfAK4pmj6MWsDuNAAsWbO6QQAI+eIM4a5ViR6xPZgmBuDXN
beYie3ssVgGshK5NA4s7vjviAqeuE3eASdrlOLunWAFaL/hmOuETMTALH/ZLLgpoRGtZjEhgfH0XTHZj6pw0nZQW8tJcpn/qXD+Qr3Y1CE79LxOh6GYZ
nmhfuxiTlIVPoaoAf63OchsGOILKsFsBeCNHKbRDtgxKJ2ig1U2nl/BXFkEGJSdBN4gOGGDoI7gcaCYXjtDxqjE6l9sEJIU2122hucFNF+LRRubhLLkA
qSeYfO+LyW0+FCnaOwHu/Qx+qqtCHZ0qjJxZDoHxvF1PsCgavnRoo13HYAKz6BvIJIVMQYxiSF0sekBvsf8JgRFbUbqzRvxOzBamp0FpibMKSCG2jqRY
EzoXZT99tSz7G9l92dxHH8iWf5epw78/2/v2j7S89sC+QxI+YdZHHIfvHYNQKq9oL6tUOo3yikJ15Xm54oXnNdpL73LTc52b5GBllc/pLr/wwgsK1eUX
NJfVz6muHFNDvUGhudr33NjN4f4X796eZEZOoe/mxnraZYc4Gwcr5fNIkT0MREdpyMHSWCiIIYcYKDEPRqgWMBqA9QXw8lgTbBmLSqA/0/TyyEYghiEI
zIazuIhkPmDxaDb2ibwY2kd4n+gVYSzDBisAgghUdKpPaFnwJ5trqoc0A6RVekSQncF2M/3EMPZj9rIr2icl+mSJgjwpc52C8cRcGrWstN2u7mD235wQ
i1bi9RP3Jjr9uTQy3Og+rBVmJu4VTjSFPfDvw2SmJWynqCdAvCGgmAij2wluQYFsUF+SJlJgJIQs4i9mbnxFXi1AjkoKVUeNan7MoQFP4/7/rIUmi9Sd
BPiFITE9VW0J+0mmHOif85ybeJQFAs7G4EZJCu/jZ2mBdXTT+gLMhKHX/AHxz/IOOBKMt7ZDV8tiqwEiyekzw/WY7VRZFgFu+MOnH8hSXJC/39d7aP8U
F+RQnLgyWBLhezzTq3j3TK9KPmA0DJhMPNOrMeg0OsVxplfdzfQiJfylkjHq8S/fvSL/3PBnX3tFec8w/Irqrv4LX752z/DySzdOGgS5XK26+psnV/zb
0BJczt+59pFuyLpfz/MzZy6zKJd4aIMNBTGcQ5vFhJnUY4+kbTt+PBPeWpVljpHyhXOA3BM90vyhFNviOhIxSwsbPDa3nJ3qjDmFPwnTe6RenXo4xhQL
C1ST+GsTg3dri09MCL9nKU6H/9njdDl4LO0PMzbax+Nf0lnYBp59FR37wFtBW2kkIW0WQSCJrfzZLzKe0iB+D8KxM4Y5EhB9RxUuUqefsQYL3XXRA3C/
/e3GvLSFfI3vOvKyWBL6kNgKrIcGVmAeXv+gAOdbmkvo2+UtmgwzaZ2nuzUSmBEyrGakjvQOHaeGF8NsaT9sFN1tYcwebUGUHoDCBhllKUEH6CY08sQC
bAzDdTxVySom1umBhWyAZ5gCOovu1nKyXd7H8f1BsmjHaKu5Rv0BeCYc2QO8ykI3Z2h6hq4gJcKFF4OYKXZnadCB++EAZ9JBfSniD2N8bjkoOdDFkiIt
oMJv151dQeqXUsW36y4gd2Q+hZ+IC4APenC56vzcsVTFIF0sUs8csES+CkbIcfIOA6zttKsu4g8BDcPcGtDUeLVdXxIWslhIdULO3zIjknz2i0ICTLKX
VNMAxO2GHwYDTMU9ZYNRVxMzcFU7vGp4a+1ykRRmmR+ZJf4CLJIL7MNnENeyJBOgK2GhZifpCu/B1eK4UzlPWlFMhLExcJ+9JdgljNh79wX3IbEfIAMO
IQ2V0iG6lwQplpJBwWkXqhhuFLYsmAIpWogfvXQ+jmR3Sba5DqLWF8Ee0bCN2PboXpa51mbidGD0tLGDXDNq4/QAK2tsqXbzgC5bpXXwe//46bKsffY+
/P0A/mfQ9q2zvX/i4BFM0V0CoZAW0gIrrHpfPi9akoERo0qrGTbJFQqNaXhEqRxS6/Um3dDw0LBOpRsxmBjADR8DHHDeR2I+k/dYoOf65D1Ofq+PTIzd
njTdHr4+rNGrVIYLqusKrUEt12p1musKnV6rlKvleq1Go9ArVBgnuq4Advy6Xi4/jgjBatRaDXdotYhyLCDUBzxUSFeILQ8gVd4keylyEOFlLWBvHWuA
fcUcJjT6pOl5atlk6WpS3JCWQ+Js5WF6A2taovNSPMRAkiGj2EqI81giM2sFqcDQKDZpxQWfqR4YDrzRX7/S8IQzKwdn9n/KQKMEZwOUG/qiYctYhFhA
3Ec6iUV2jlkxCkYOXM5t0esSfQ0uHehGmc1kHQQ23HEVa/NiwQ76AAIIyCEWdkCCYDTJvMTscgiDM6BOWzH0wjIBMm1Dr9NdRpcquS22trntlsxWILwM
fhgC+VDBMLuHrpYPKxBriGEYYXd4RbMVdI8XhHEOS91hUHMEtpoTqTQgRcohugqsRhIs9N9tfrAs+3Ogmo6PPJD97DwT4x+f6f3eX2mYGGNu3JwkNpju
8DELrXl3Cy1XDOgHu7VYWoVcr+rWYunepRZL2fWdPvCBD2BdKihkdJ40NrrELuXg4e/AHhhGa44exo4D3MxWEhsmHuBG+5FQ3YJvLF8Fzgz8HfdKy3NT
PVhemfb+YlPIC/OwwYJqTHowEvDuDs1pVgnYTQvJVY+bxdlTxLbdDdMR5zKzG3M0mYFXLy06AEyFZTOfmGbXwPLBToCe8WJHfLmNAP46N0tjFWiglUgE
mE+9waQIqZhYABbpgQ7t1hpWLjQCcBF7sivdZKt4gE43uo1gI/KH6A/512G9/Z8izm2UL1b8yt2n/k91K12BOgu+AvP5PSjuGQ/IU7sO3BCXLjgP29Vd
JtYp0RMT0xZamubeGegJnV4HNSezISFsY4UKb+0DK/wxyNzhhx/I/tsneMTwbG/jf7A6hWdOVg7ipv7ylTrg0esBOjWDGgXg1aBBq9UApA0qRnRG/ciQ
yShXqMHlN7Gw3sMEjfKx6miFhrsyKIWg8u2aW6qmQdRyfgxgeDzMCWHSiI9lL7JcJGZiw5hFXSiKjU2St8AN2xFxdpquBVhqVPD5uUe0gPna1BKNg/ii
QIL25zHQB87HtofGPYh8KwwyhVhIAFpQnuWeEagA1mNjog7knHlC8xauHQAi/sIUZoTBeRK2V1kTMWZv5hdI+wnPRalPyrZO8fI0IW2mrhbQLnBU0Xde
SACHIIUK1qVaG6yYebtbmgp0jBelotSk9mBHpKSdl7vyGlLRAn9WwXvAwBbodGgT/OsOQtl2sJrlHeWonbIA5pMQX5550Me1pTwacEJCWFyeca1jt6Mf
Y1G1oOjbBSOMdJGtBubDmNxuU/AEBE8Zr3fnYykf6joEPwnccqzscZbwCk5skRxBwTXLCxCRaB15QTWLsr82lGU/BBn+q6ceyL7PcXPhg70/+5GKJ2gq
y1I4+z4Nv46lLrUjI4ahYf2IQaMz6oZ0QybNkN5o0msUw8YRk9Go+lWD3TqDZsgI46rkaoMa9EKvAZNvNOpUBoNxyDiofkewW6fUq66eE80W/jDKE8Hs
kZGPXGYFCO16QorbMQXv5Kn9WFN0xml0hculexccENYETRAXeZOkFjEjiTLdrliBfsFIDjdCIVYmkOoCjbjF2TBGyNfF6dCxhonmCC9/7Vat9YCkgxUA
XE8AG3U9Iun2OSm6edKnB+ILUv9+guEc3Z/i0W8+YFdjdBdU4Ov7TwNV5rsDJJlrD1r8xRa4FPxYALF7wYhjfpLlgFCAAgVSKgHd7W5fh+6ykwj7PI6M
tP94K4/ZcL0KH16G0y2TBcvWrkVJJsjHg3fwcDC+MLFQRt2ylcSDff4Q+KAlM6e6dG1TLVdI1qwUSSDbSa0ImQj4N2J5C52rGis7cB2gNxNtYmyhGAE2
jdpmxTAvdBabWHuJNjJXo24X9WDNL+ZG6gl8aqsNjVE4S/eb1GPDYmF4SizRR/PYrrhAzUD9MLNWc+CS2Jrb9TCrd88K1py4ZsZotqsquHZZAaqTujd4
kT+r6i3R8hqWU9j2GJ/5T/sfLcv+F+hlGPSy+o+YXkb6emmE8ZmnpfUVDDs7g0DYAJN+pdoC7ciwSqcwKlXDBuOgdtBkGBwaMarlSqNBoVGrFLy24L1P
7xi/MvkHv39Vc+v3vvbFL71w47WJ514cHFJ9VnlP/QfPn4g7qA0Gufzq01LUC35od90nQg7HJXKYXUITNb8rldd5NXk1xu3Q5g4tL1PvEW8m02ShwJRL
aILAbaP2IU0SLFhrs18B+cQRMMKGxQf4t2Bzc71LHrBqUczFxqLACcAKTdvoUZ1lpATfLny3F6TYES9ZsO/QXQsPcXhbXN/rq0I9y4qS4N2TrIUXlJZD
oPpPLll/nMv/otxtl4TpL6gUj5Ow/3umc2ioFQG/u1sJ9tjGnjw3JEXyFKxEdp/GdzoB3oAXWD71rwPnAUkS18CjjMCGUuseKs9mtV2JdPyB2Cq1YIpL
dG7BdXCz6aGzewtJVMR8jh/LQHLlD9NZTFDhgb7YKqouu5G4CtRcE9ctuMkRQBOM3ImFAnjptGBDYtZcAfOKDkNjh/hqJJeGKZhiu3iNDxLN46fAer6d
nc5TOANCbbNd83WWBDdGk7SwyKMp3MiCEsLm4TL8ZYwUbKCRBRogltbQJQfL3moAzaPxKuLd8SZgqqDsPjkvP/WCyWMWjem6KJg5ZQQANlxa3uTJpO6T
tiuJTmhlYwl9m0hNSHq79UQYCGUzwl4JviLJrwC8CskinVvh4/BidMkcoOUA8TrANe28F78TdrizEraT6ETNBqkzgue5ygE8lAl/tuJInRnl6AZJYVKO
VnShAEwBpw7Yxcw6nxH5cNXHxQkfrVGnhQVeWMLkCrDJsga89yeATd//0APZTz7OsKnY02u1KBhnIF6rlI6+T0jSMsarHDKN6PU6zYhOb1AY9QrdiFyp
GRkZNsDvOv3QCIOkL3Yh6Y7iwp07Ny/emrozaZx8xH+bfO3urcGB15UXbo9fefEz8rtjL9/4zI3Lr74xOXH5xgDGCF5XKNT6OxMPKbTcoIXLyqvP8uWT
+iLmylgbTcbW0gmsUnXOHf7s07yGMGthJl9aWSWbGSHl43XosRg7S0PjJTwEs7vEwARet+jOs6J2VGx2wgZsaStMDzYZj8bS2j3H48cU0WX3+lh1INb9
zvkx396HUhYCt8g9hXOLGVe7mn9ydeAxJ3hnKv2J1YEYMo01ujikvaDUvbOqnYJTH8WzKSiStSoFsfIVsd0M86+YUcyv8OpW4LmkudYuO/hBEzD2aF7T
IbSquQVQdBYHqLJIFQaowFyCLKNF5vaaY0DsqN3Kg1Ajd14MohQ3l6HN63XRq5lPMYrtQjfGlxJbQfBP2+UIyW0AqQewpOtzNDOLocYMcGuftLzCI42g
TEI9IkVtTJM8XFEYxszyU2pSzE8cG+0KAgysoV1ZZRHDFE4NDNu9wXP66AHU94VaFHHieArQv6JsvQ5K86X7Mse5B7K/6WU6898/3Nv6+Zln3nz647/F
YpJp/idjjgWh1hKnU0I1KUTS71OXVEo85zEkV+rVQ2rdsHFoWDk0qB6S643qYYNuWKEfAdnn/PsXpc80Lyjlz3/meY328vNXtFr58xq94cplleHKwzga
qMsf8jW/XU90G09Y/0A/q+Yugt2ENu/ZbXS/YnXhK5NjE2/0j430f3709o3+l4y3r/Xq9N3K4r6OK1tusMphMNJCzYveJNcyM8tO0FBDLISZXmFhO1AH
DLdIc5kTYZftiBTf5UfeahYSiPEm8MjUKjfwzWVWo8y4KKf7UmWDHqY7FYpYSc/TGftbLIBDYxWhtSq6d3hZcKjI2AsGDct4qooRChoNAcHIpIUZcH+R
hkyn+ZGWYpnuudhwoifFFiwlNgVrljEU0H+6i0yoeiQ0N2i0Cr9ugv3jj0V29/gYyXkRPRCaSws7QawsxtCi6PMx90aKAVDMc6gJbLOT0YhF4L1bdvgB
m8giwhKLLG0sMvxC97+xwXlTBg/z7TfRP9+K8YptoF/o0KNL5NqjSRunSvCw2AH3aH1LCOCx68N5RLBjggV4acFDcw/jYXTNPMUWVjeT/Huxpw589XGY
gg4noKyPN9jFPg5rvMPD47DsnyM4Jl99/PybWFjGnyyHxOrHMtHlORpJnQygvYOaKcBUKS8oNY9D4t+dBczH22w5fly2I/Q1H9I0yxbIrLiLBS2dSDw/
RruNFckY/rehicYIaroCjgDP1fOIFPyKQdGMnSV2EtAfoxf5PeBKWH0EyBMrkiTmhUiqIob94KnBdNSWQTD0bZKEB4vu3KxAruUVmyVxP8FKme1wV7ew
FA/Klh1YYOOaJ6ANLEjGayNFx5aw7cHcbL3KOQLx2UmxIbqKsFRE44KXulNt5vswShVlB/062V2WysGt6AaTQQoQxpsFUo1j3QQQqFxAWmtiENiK6Ytu
m5QB8B38djQclQRx1sTQzCMXayExY+leERsFYa8grmWFpTw/W8d3Q1oIEOcmH4T3h+0iziV4KF5PyKutxBk7qZfQZHjxBAdQRehGw5tYQ2pu8vwbj1d3
XGN/BIwr38DuslnSLEWd+7AAJLbsXDsNW4BzkXyY5Dd4yQYWa2x70IRtbMEVtHHHI1BPC6Opng1UsYIfTA9OsZHBWiy/V9xnh1nMePwQJsKQW6hIystd
2gtfYZEdpuxO8NJ2YTEF6EiOMsjZs4dYRMxFFBaQZlX17CvZXIJhBeiDh/iXwEbTxX3+stBez++SVLndWMF2FHzYAxBvGLwo+/airCzbBWJIex/I/sNv
MCN3cKY3/hefQGL4Ua7G1AwevVNo1cRCEAzb+DGbG7p15+It0+jN0dv3xu90qNyNi+Ovjf+LuxM3//mJwKnq4vDY3UHj7dEx1osVR42/NjY5NnDn+gTw
wLHr42N3Jk0TA+N3B2+ODg2MKw1KvU6l1fJsOmd7Oowc6a6dVSh5kPSZy8x/JPl1MerjuGuziPsrE09hknV9W/R4aanYcf7ctJEDJNtfaDeAcQemEPpE
T4laNgG+ALp5gOa4cfoxEDuGo3P8ykV29SlgU2Qj9A5/sIeGUzDQcQ77aXYko8qH5ljGin0bMvy3ICI+PFDdSIuz04I9ihGKVAXRwb8Oew3+Gs/EsEQp
1iyC+0DiRQpPFpxhMZR1Pr3onhZi+a6/wL0PMcCgB/0RVq3YsAOtQZxiL5I5dDkxyyKclgA1LyIFOK4e55lV0drAQxvuBLAAuC42m5i7DIRZpdAPDWXZ
l+/L/gwE5wcfZILzg57eOj9G0SPZ5+hy6lcKcugGdcPDOp1OOzwyCI1ho16uU+sVQ0NyjXpIaVA/GoV8Z8HGV0fv3D0u4dUNKMBFMQ5ojYMjuhGVWqse
GRzRqrWqQYVcrTNqMe2oGBnWXYcFya/r1OqH4sacC9XJcIeyG5zv4VXnE0+BdSPuGMnGqcv3KLkpJYSQnzSw2ihpYYeUpNoM8H32NylmwDrny6J7T5ov
scSjNO97JNBBzFukMAeA3TW6y9ZHAionzlFhzVEuxElFKQFyMcW8j/wyICWTdEBAaL6vQgyhsUXXnCfFulvMflyLdHxo35cFb7SbtjoRClG+o0xj45TC
oFagd2DH+jiseouVSRkDiEAmQGLQfy078WQRC7t1yh9q68R2KB7sYyUQHqj0gRJgOsi2hMULG/uIq0cFMM1gQcB3B0EWnSvEZ4OfBNcsui35FQRMe0yo
JQRXhRylWOISwGP5OB5wiDl/NxaLYriCLUxK2xGWfZsY9wOuU1rkJxaZNUlI4f1ushWriGsN1E5e3A6eSy7Aj8bT0la7vgWTUmBjQQAdP4vZWjDwY1vC
TQUrDC5+MIL/dIrNA4SsKPO0AZbnAZbroF12hOX/Bw==
"""

// detail-902056.pb: raw deflate, base64
private let detail902056Reply = """
7L1ZrGTXeS6GJim6TcuW1PIg07It05anUvfZa17b8XVc8zzP9dLYw9o1V+2aB+SBsgaSkkVJtmzNli1LlK5kSrQtyRQ10M95CoIAAYTkJe7Tww0uEuQp
uEGA/KuqTvfppm/7lJuPAZo81XX+tda//uH7v39V71WXv/6cePtjv//W0w+9cuelz56+9Cc3/+JDf/DWgTVad61Re7poL/74UupSxn7y9ONfuf23H7Kf
vPX839/8APw8/fyPbrz2Nfj7p757+2sfth/fvXn79b+69YOX7cfvfP7DIPHhD51+4ZVesTOf+7M/ODlZOuOlml5dzq/6Xeeav1h0r030K2d0+NX15fw6
vHFinAy3jmFgw5AGcafcRkJKgpHgiBvyxJg+OGVn+1+dsrN92JSYUMQROTG2f3w2ZXdotdW1+dC1r42n7ZP5iX+yQljCBK2yWk1qgyaN4RgOroei043z
dCgf8q/1/PZHLv306fOfOX35pRvffwFe337l5Ztf/PGdL30XXt964fN3vvHx03985SOXnrz5xRdvfvmlj1x6650PfPL0E8/f/MBfn778CZC584GXb37p
26ffeu7P4PUPPnjny3958/uf+bNLT9757PM3Xv3+Ny793WO3v/3V0xe+dvOvv3/zY9+69dKPb37246d///enr3z89re/8y/PfmTvv1s//My/PPvRm5/6
/q0f/uW/PPsnp1/5Gih0+rffPH3tC3f+4vXTlz97+tV/vPkPz59+5gWQv/Hqi6ef+PidD3z99JXP3fj+Szf/6tOn3/rerc99cC8Jf73zqZdufvWHt7/1
5RuvfvT0P37u1msv/R8//NNbH/ze7Wf/9OYXvnj6139y529fvPHaJ2994/2nH/+M/tVX//LW89/T85+te/vL3zx9/iu3X/nonWc/fOP7H731o2+AmBb4
1vdufuDrd97/8q33v3zn018HVfer33j1tRuvffj2c9+48foXQRI03AvfefZZUADeOf34S1rtH//N6Qsfu/mXr9z+zndvf/e7Wu0f/PmN1/5Bz7Pb3T9c
esfNz39HCzz3j7f+7u8ogYB87dJT2MD8qmFeReifLz3+3196HBnsf7v0JGh757Mf/k+XdEjf/vbL/9elJ7TcfwE/fPMzN1/90K0Xnv+Tx568+fLf3nrh
uVceu/TPjz15+7Gb33vn//nYf3nv//3Yn//F488+/uH//clPPH75M49f+urjn/vsTwe//viLNx5/5fH/4S2vPv6f3vbP8N9rT/znJ//Q/6P/34EXdyDs
7ua3PwbvnH7nUzdf+fjNz//45otfvfndF2+//hxscL+W/vPV79z+1qs3Xn3u9ENfP/3KN09feu7Wp75++vznbn36Qzde+xuQBHOdfvB1kNmb9+bnX9em
2M2vzbs34w9evPnyV+78zfduffHZu5Iw9vZr37zxgx/p/T7/CdiXXvS1L8D7N1599vQTH7vx6gu3Xn7hxqvfvPN3X9JTfeHrt1945c7nfqwX/fIH7rz/
uRuvvqz3u1/3H/7m5hdeOP3EJ08/+aPbr3/ixo9ePP3Kd/Rvv/bRWz+ABH8NLHb6T39/+md/qm342mt6ku+/euulj9/61JdufucHpx/5xulHPg/q7Qz4
sZsf+bTW4XlY4mOnH/o7bc8XP3r79W9q633hWZjw7rqnz718+uyX9pPrOf/yg7df+DbI337/N25+6Gva4994/62//s6dz3zv1mtf2+9Xm/eLX7r1Q+2s
29/98umPP303kE6f/fHp6x/Q83ziT29++ns3vv+l2y/+EwiAx8+8/xEwrzbR67Dfj2nFXvnInec+dp8NdyF6+qM/3+9Uq/rKh/dmufXCl+HPzRf/9OaL
X9P2PFP75gsf3RtTz7CPve98+vT5fzr98FdO//7529/6+unn/wrscOf9fw4W+MMT/4/+xyfeduXJK09cvvT2S+/6X/7fH/7Pn6Q/eeLPxFOXR2q19jaL
0ZVPXnr6g5fg5VV7ljdKpcgiazSN9jQVtsP9Tnk0QE4i12gm2jm3kivk23xTt6aJTXkVOsme4HmCtEf2MDAL1i3LTLOSr+zxaDaPjzKeaLXscI2vWr3+
LCRXnYyPknJszWNbNmB+ZlOOV8pi2Ch6k2SuHjUSz1wGeDIQwNOVP790+aFadVeZk1S2V7cGZmKUWlZKKl4KF+dLJqTfEoH0qkFXaF23Kr1oepFzU3xR
Nuuhk1ZzopZsso6vqrlOYJicbs1o2mn1QoFNA5PsqD73T5aBwGZW9QTmsTBqzIp7rfBBq8ceplUnWC+Gu9Id9XNTu9QsLzPWtnQSMFCwNJmHTyog6MRi
qrFaeEFkNRKqkfbCsfViSMzaokIjEVmcdDeJRC/TyVjVFe7jUiLOkuUtTg5O8JAbOMhDVtSL5xZ7rchBq8cfptWymaPNWtkMVgeDqMqVw017Ht00u9v2
qBBR6UQjPisFciO3OfTDtfp2XVyz1jLWSy/zZDmno2ptG4mbs2V0FitsS7jOlCpE8oXReGSFSaoeiHiJjUNPqqscTe21ogetnniYVn7HC/qZ1DYfzdcS
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
9Z/+z/f/y1f/66v/Bw==
"""
