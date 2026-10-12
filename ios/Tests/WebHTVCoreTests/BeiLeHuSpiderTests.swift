import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-57B-4 (W-58): BeiLeHu.js against the category reply the live API returned on 2026-10-12 (W-48 gate) and
// hand-made edge items, following the W-56 design (qist-beilehu-gate-2026-10-12.md D3–D5).

/// Answers every request to vd.ubestkid.com with one status and body, and remembers each request's body and headers.
final class BeiLeHuSite: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reply = (status: 200, body: Data())
    nonisolated(unsafe) private static var seen: [(body: String, headers: [String: String])] = []

    static func serve(_ body: Data, status: Int = 200) { lock.withLock { reply = (status, body); seen = [] } }
    static var requests: [(body: String, headers: [String: String])] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "vd.ubestkid.com" }
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
        let reply = Self.lock.withLock { () -> (status: Int, body: Data) in
            Self.seen.append((String(decoding: body, as: UTF8.self), request.allHTTPHeaderFields ?? [:]))
            return Self.reply
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                                               headerFields: ["Content-Type": "application/json;charset=UTF-8"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct FixtureMismatch: Error {}

/// `cat56-t0.json` from the W-48 gate (38 items), raw-deflated and base64-encoded; checked against its recorded SHA-256.
private func category56() throws -> Data {
    guard let packed = Data(base64Encoded: category56Packed, options: .ignoreUnknownCharacters) else { throw FixtureMismatch() }
    let data = try (packed as NSData).decompressed(using: .zlib) as Data
    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
            == "679afa1ea566e1b6ec1005c9aa2dd6756a7bd7f4695534c66ccb3e4eac7e14b7" else { throw FixtureMismatch() }
    return data
}

private let chrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"

private func beiLeHu() async throws -> JavaScriptSpiderRuntime {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BeiLeHuSite.self]
    let registry = SpiderRegistry.bundled()
    let runtime = try JavaScriptSpiderRuntime(
        name: "BeiLeHu", script: try #require(registry.entry(for: "csp_BeiLeHu")?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: "BeiLeHu-test", defaults: UserDefaults(suiteName: "BeiLeHu-test")!),
        session: URLSession(configuration: configuration))
    try await runtime.initialize(extend: "")
    return runtime
}

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func list(_ text: String) throws -> [[String: Any]] {
    try #require(try object(text)["list"] as? [[String: Any]])
}

private func reply(_ items: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["errorCode": 0, "errorMessage": "", "result": ["items": items]])
}

@Suite(.serialized) struct BeiLeHuSpiderTests {
    @Test func homeOffersTheSixClassesWithoutTouchingTheNetwork() async throws {
        BeiLeHuSite.serve(Data())
        let home = try object(try await beiLeHu().homeContent(filter: false))
        #expect((home["class"] as? [[String: String]])?.map { $0["type_id"]! + $0["type_name"]! } ==
                ["56儿歌", "63故事", "62少儿", "61古诗", "64认知", "65习惯"])
        #expect(BeiLeHuSite.requests.isEmpty)
    }

    @Test func homeRecommendsTheFirstTwentyOfCategory56WithTheUpstreamBody() async throws {
        BeiLeHuSite.serve(try category56())
        let items = try list(try await beiLeHu().homeVideoContent())
        #expect(items.count == 20)
        #expect(items.first?["vod_id"] as? String == "https://res1.ubestkid.com/blk/m/001_xtzgg.mp4@@小兔子乖乖@@" +
                "https://res1.ubestkid.com/blk/t/001_xtzgg.png@c_1,x_120,y_0,w_720,h_540%7Cs_0,w_300,f_png")
        #expect(items.first?["vod_remarks"] as? String == "贝乐虎")
        let sent = try #require(BeiLeHuSite.requests.first)
        #expect(sent.body == #"{"age":1,"appver":"6.1.9","egvip_status":0,"svip_status":0,"vps":60,"subcateId":56,"p":1}"#)
        #expect(sent.headers["Content-Type"] == "application/json" && sent.headers["User-Agent"] == chrome)
    }

    @Test func aCategoryPostsItsIdAndPageAndRefusesANonNumericOne() async throws {
        BeiLeHuSite.serve(try category56())
        let spider = try await beiLeHu()
        let page = try object(try await spider.categoryContent(tid: "63", page: "2", filter: false, extend: [:]))
        #expect((page["list"] as? [Any])?.count == 38 && page["page"] as? Int == 2 && page["pagecount"] as? Int == 3)
        #expect(BeiLeHuSite.requests.last?.body.hasSuffix(#""subcateId":63,"p":2}"#) == true)
        _ = try await spider.categoryContent(tid: "56", page: "x", filter: false, extend: [:])
        #expect(BeiLeHuSite.requests.last?.body.hasSuffix(#""subcateId":56,"p":1}"#) == true)

        BeiLeHuSite.serve(try category56())
        #expect(try list(try await spider.categoryContent(tid: "abc", page: "1", filter: false, extend: [:])).isEmpty)
        #expect(BeiLeHuSite.requests.isEmpty)
    }

    @Test func anErrorEnvelopeOrBrokenBodyIsEmptyAndAServerErrorIsReported() async throws {
        let spider = try await beiLeHu()
        BeiLeHuSite.serve(Data(#"{"errorMessage":"系统错误","errorCode":-100002,"result":null}"#.utf8))
        #expect(try list(try await spider.homeVideoContent()).isEmpty)
        BeiLeHuSite.serve(Data("<html>not json</html>".utf8))
        #expect(try list(try await spider.categoryContent(tid: "56", page: "1", filter: false, extend: [:])).isEmpty)
        BeiLeHuSite.serve(Data(), status: 500)
        await #expect(throws: SiteUnreachable(.httpStatus(500), host: "vd.ubestkid.com")) {
            _ = try await spider.categoryContent(tid: "56", page: "1", filter: false, extend: [:])
        }
    }

    @Test func itemsWithoutAPlayableAddressAreSkippedAndRemarksAreTheBrand() async throws {
        BeiLeHuSite.serve(try reply([
            ["title": "无网址"],
            ["url": "ftp://res1.ubestkid.com/a.mp4", "title": "ftp"],
            ["url": "https://res1.ubestkid.com/a$b.mp4", "title": "带美元"],
            ["url": "https://res1.ubestkid.com/a#b.mp4", "title": "带井号"],
            ["url": "https://res1.ubestkid.com/c.mp4", "title": "a@@b"],
            ["url": "https://res1.ubestkid.com/1.mp4", "endInterval": 0, "brand": "贝乐虎"],
            ["url": "https://res1.ubestkid.com/2.mp4", "title": "", "endInterval": "abc", "brand": "品牌"],
            ["url": "https://res1.ubestkid.com/3.mp4", "title": "一分钟", "endInterval": 605],
            ["url": "https://res1.ubestkid.com/4.mp4", "title": "九秒", "endInterval": 95, "image": "https://i/4.png"],
        ]))
        let items = try list(try await beiLeHu().categoryContent(tid: "56", page: "1", filter: false, extend: [:]))
        #expect(items.map { $0["vod_id"] as? String } == [
            "https://res1.ubestkid.com/1.mp4@@贝乐虎@@", "https://res1.ubestkid.com/2.mp4@@贝乐虎@@",
            "https://res1.ubestkid.com/3.mp4@@一分钟@@", "https://res1.ubestkid.com/4.mp4@@九秒@@https://i/4.png",
        ])
        // endInterval is ignored: it is not the length.
        #expect(items.map { $0["vod_remarks"] as? String } == ["贝乐虎", "品牌", "", ""])
    }

    @Test func aDetailIsBuiltFromItsIdWithoutARequest() async throws {
        BeiLeHuSite.serve(Data())
        let spider = try await beiLeHu()
        let vod = try #require(try list(try await spider.detailContent(
            ids: ["https://resvd.ubestkid.com/blk/m/20230504171841_bingo.mp4@@Bingo@@https://i/b.png@c_1"])).first)
        #expect(vod["vod_name"] as? String == "Bingo" && vod["vod_pic"] as? String == "https://i/b.png@c_1")
        #expect(vod["type_name"] as? String == "少儿" && vod["vod_play_from"] as? String == "贝乐虎")
        #expect(vod["vod_play_url"] as? String == "播放$https://resvd.ubestkid.com/blk/m/20230504171841_bingo.mp4")
        #expect(try list(try await spider.detailContent(ids: ["https://r/a.mp4@@"])).first?["vod_name"] as? String == "贝乐虎")
        for broken in ["not-a-url@@x@@y", "https://r/a$b.mp4@@x@@y", "https://r/a#b.mp4@@x@@y"] {
            #expect(try list(try await spider.detailContent(ids: [broken])).isEmpty, "\(broken)")
        }
        #expect(BeiLeHuSite.requests.isEmpty)
    }

    @Test func playFollowsUpstreamsTwoSteps() async throws {
        BeiLeHuSite.serve(Data())
        let spider = try await beiLeHu()
        func play(_ id: String) async throws -> [String: Any] { try object(try await spider.playerContent(flag: "贝乐虎", id: id, vipFlags: [])) }
        let direct = try await play("https://res1.ubestkid.com/blk/m/001_xtzgg.mp4")
        #expect(direct["url"] as? String == "https://res1.ubestkid.com/blk/m/001_xtzgg.mp4" && direct["parse"] as? Int == 0)
        #expect((direct["header"] as? [String: String])?["User-Agent"] == chrome)
        #expect(try await play("名称$https://res1.ubestkid.com/a.mp4")["url"] as? String == "https://res1.ubestkid.com/a.mp4")
        #expect(try await play("播放$https://res1.ubestkid.com/a.mp4")["url"] as? String == "")
        #expect(try await play("not-a-url")["url"] as? String == "")
        #expect(BeiLeHuSite.requests.isEmpty)
    }

    @Test func searchHasNothingAndAsksNothing() async throws {
        BeiLeHuSite.serve(Data())
        #expect(try list(try await beiLeHu().searchContent(key: "小兔子", quick: false, page: "1")).isEmpty)
        #expect(BeiLeHuSite.requests.isEmpty)
    }
}

// ---- fixture: cat56-t0.json (W-48 gate, 2026-10-12T05:58:58Z), raw deflate, base64 ----
private let category56Packed = """
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
"""
