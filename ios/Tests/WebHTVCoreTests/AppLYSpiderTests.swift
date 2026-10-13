import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-57B-6 (W-73): AppLY.js against the replies the live API returned on 2026-10-12 (W-50 gate: home, category,
// detail1, playurl1) and hand-made edge replies, following the W-60 design (qist-aply-gate-2026-10-12.md D2–D5).

/// Answers fly.daoran.tv by path and remembers every request's path, body and headers.
final class DaoranSite: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) private static var seen: [(path: String, body: String, headers: [String: String])] = []

    static func serve(_ served: [String: Data], status: Int = 200) {
        lock.withLock { replies = served.mapValues { (status, $0) }; seen = [] }
    }
    static var requests: [(path: String, body: String, headers: [String: String])] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fly.daoran.tv" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
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
            Self.seen.append((url.path, String(decoding: body, as: UTF8.self), request.allHTTPHeaderFields ?? [:]))
            return Self.replies[url.path] ?? (404, Data())
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil,
                                                               headerFields: ["Content-Type": "application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct FixtureMismatch: Error {}

/// A gate reply, raw-deflated and base64-encoded, checked against the SHA-256 the gate recorded.
private func fixture(_ packed: String, sha256: String) throws -> Data {
    guard let deflated = Data(base64Encoded: packed, options: .ignoreUnknownCharacters) else { throw FixtureMismatch() }
    let data = try (deflated as NSData).decompressed(using: .zlib) as Data
    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else { throw FixtureMismatch() }
    return data
}

private func home() throws -> Data { try fixture(homePacked, sha256: "7becbcb6c95c5da363f8c915aba3c1758e7e2961b8f2bd04d15cc66267f5b2a8") }
private func category() throws -> Data { try fixture(categoryPacked, sha256: "078250ce65aea23ec6011986381406e4e92db53379c12c3fad16e593f1c351b7") }
private func detail1() throws -> Data { try fixture(detailPacked, sha256: "8867521011be3b6f05bee4630cee148fcd7d36c63534d5d4e1d9449039ffaccd") }
private func playurl1() throws -> Data { try fixture(playurlPacked, sha256: "d4c09076d5c22289dfd8dfa5a2d436f652d738bc593c4bf6d1e12dce477715bb") }

private let api = "/API_ROP/"
/// Upstream's three headers (AppLY.java:16–26), compared whole: the host fills in its own UA and a form type if one is missing.
private let headers = ["Content-Type": "application/json;charset=utf-8", "User-Agent": "okhttp/3.9.1",
                       "md5": "SkvyrWqK9QHTdCT12Rhxunjx+WwMTe9y4KwgeASFDhbYabRSPskR0Q=="]
private let image = "https://ottphoto.daoran.tv/HD/OPERATE/PAGE_IMAGE/album/C/69e70ddfe4b08084d5f60041.jpg"

private func appLY() async throws -> JavaScriptSpiderRuntime {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DaoranSite.self]
    let registry = SpiderRegistry.bundled()
    let runtime = try JavaScriptSpiderRuntime(
        name: "AppLY", script: try #require(registry.entry(for: "csp_AppLY")?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: "AppLY-test", defaults: UserDefaults(suiteName: "AppLY-test")!),
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

private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

/// Only the three upstream headers, whole values (the session may add its own Accept-* and the like).
private func sentUpstreamHeaders(_ sent: [String: String]) -> Bool {
    headers.allSatisfy { sent[$0.key] == $0.value } && sent["Referer"] == nil
}

@Suite(.serialized) struct AppLYSpiderTests {
    @Test func homeListsTheServersSectsWithUpstreamsBodyAndHeaders() async throws {
        DaoranSite.serve([api + "page/setinf/get": try home()])
        let home = try object(try await appLY().homeContent(filter: false))
        let classes = try #require(home["class"] as? [[String: String]])
        #expect(classes.count == 77 && classes.prefix(3).map { $0["type_id"]! + $0["type_name"]! } == ["zaobang枣梆", "yuju豫剧", "hmx黄梅戏"])
        #expect(classes.last?["type_id"] == "bdld" && home["list"] == nil)
        let sent = try #require(DaoranSite.requests.last)
        #expect(sent.path == api + "page/setinf/get")
        #expect(sent.body == #"{"leastNum":"0","memberId":"yszyz","project":"lyhxcx","userId":"yszyz"}"#)
        #expect(sentUpstreamHeaders(sent.headers))
    }

    // A89-01: upstream's optString keeps a numeric code or name as text; an empty or missing code is no class.
    @Test func homeKeepsNumericSectsAsTextAndAnEmptyReplyHasNoClasses() async throws {
        let spider = try await appLY()
        DaoranSite.serve([api + "page/setinf/get": try json(["sects": [
            ["code": "zaobang", "name": "枣梆"], ["code": 7, "name": "七"], ["code": "x", "name": 8],
            ["code": "", "name": "空"], ["name": "缺 code"], "不是对象",
        ] as [Any]])])
        let classes = try #require(try object(try await spider.homeContent(filter: false))["class"] as? [[String: String]])
        #expect(classes.map { $0["type_id"]! + "/" + $0["type_name"]! } == ["zaobang/枣梆", "7/七", "x/8"])
        DaoranSite.serve([api + "page/setinf/get": Data("{}".utf8)])
        #expect((try object(try await spider.homeContent(filter: false))["class"] as? [Any])?.isEmpty == true)
    }

    @Test func aCategoryPostsItsPageAndSectAndMapsTheSavedReply() async throws {
        DaoranSite.serve([api + "search/album/list": try category()])
        let page = try object(try await appLY().categoryContent(tid: "zaobang", page: "1", filter: false, extend: [:]))
        let items = try #require(page["list"] as? [[String: Any]])
        #expect(items.map { $0["vod_id"] as? String } == ["0dOTNN3xWq505829", "0dOTPfeHnm484017"])
        #expect(items.first?["vod_name"] as? String == "枣梆宋德靖经典唱段" && items.first?["vod_pic"] as? String == image)
        #expect(items.first?["vod_remarks"] as? String == "2026-03-12" && page["pagecount"] as? Int == 1)
        #expect(items.last?["vod_name"] as? String == "枣梆《生日》潘海英版" && items.last?["vod_remarks"] as? String == "2026-03-12")
        #expect(items.last?["vod_pic"] as? String == "https://ottphoto.daoran.tv/HD/OPERATE/PAGE_IMAGE/album/E/69e70ddfe4b08084d5f60043.jpg")
        // 9d: the host's defaults for what upstream leaves unset.
        #expect(page["limit"] as? Int == 20 && page["total"] as? Int == 999999)
        let sent = try #require(DaoranSite.requests.last)
        #expect(sent.body == #"{"cur":"1","free":"0","item":"o5","pageSize":"20","sect":["zaobang"]}"#)
        #expect(sentUpstreamHeaders(sent.headers))
    }

    @Test func aBrokenCategoryReplyIsEmptyAndABadTidSendsNothing() async throws {
        let spider = try await appLY()
        for body in [#"{"code":10000000}"#, #"{"pb":{"dataList":"none"}}"#] {
            DaoranSite.serve([api + "search/album/list": Data(body.utf8)])
            #expect(try list(try await spider.categoryContent(tid: "zaobang", page: "1", filter: false, extend: [:])).isEmpty)
        }
        DaoranSite.serve([api + "search/album/list": try json(["pb": ["totalPage": "x", "dataList": [
            ["name": "缺 code"], ["code": "a-b", "name": "坏 code"], "不是对象",
            ["code": "k1", "name": "好", "img": 7, "publishTime": "2026"],
        ] as [Any]]])])
        let page = try object(try await spider.categoryContent(tid: "zaobang", page: "0", filter: false, extend: [:]))
        let items = try #require(page["list"] as? [[String: Any]])
        #expect(items.map { $0["vod_id"] as? String } == ["k1"] && items.first?["vod_pic"] as? String == "")
        #expect(page["page"] as? Int == 1 && page["pagecount"] as? Int == 2)
        #expect(DaoranSite.requests.last?.body.hasPrefix(#"{"cur":"1","#) == true)
        // 9e: a category id may hold an underscore, unlike album and resource codes.
        _ = try await spider.categoryContent(tid: "a_b", page: "1", filter: false, extend: [:])
        #expect(DaoranSite.requests.last?.body == #"{"cur":"1","free":"0","item":"o5","pageSize":"20","sect":["a_b"]}"#)
        DaoranSite.serve([api + "search/album/list": try category()])
        #expect(try list(try await spider.categoryContent(tid: "zao bang", page: "1", filter: false, extend: [:])).isEmpty)
        #expect(DaoranSite.requests.isEmpty)
    }

    @Test func aDetailCarriesTheAlbumAndItsFiveResources() async throws {
        DaoranSite.serve([api + "album/res/list": try detail1()])
        let vod = try #require(try list(try await appLY().detailContent(ids: ["0dOTNN3xWq505829"])).first)
        #expect(vod["vod_id"] as? String == "0dOTNN3xWq505829" && vod["vod_name"] as? String == "枣梆宋德靖经典唱段")
        #expect(vod["vod_pic"] as? String == image && vod["type_name"] as? String == "zaobang")
        #expect((vod["vod_content"] as? String)?.hasPrefix("汇集枣梆新秀宋德靖代表唱段") == true)
        #expect(vod["vod_actor"] as? String == "宋德靖" && vod["vod_director"] as? String == "" && vod["vod_year"] as? String == "2026-03-12")
        #expect(vod["vod_play_from"] as? String == "在线播放")
        #expect(vod["vod_play_url"] as? String == "宋德靖枣梆经典唱段1$11084070000629#宋德靖枣梆经典唱段2$11084070000630#"
                + "宋德靖枣梆经典唱段3$11084070000631#枣梆《生日》选段-宋德靖唱段$11084070000632#枣梆《草根大师》宋德靖版唱段$11084070000633")
        let sent = try #require(DaoranSite.requests.last)
        #expect(sent.body == #"{"albumCode":"0dOTNN3xWq505829","cur":"1","project":"lyhxcx","pageSize":"2147483647","selectFlag":"0","userId":"yszyz"}"#)
        #expect(sentUpstreamHeaders(sent.headers))
    }

    // W60-01: resource codes mix letters and digits; anything else is dropped, a "$" or "#" in a name becomes a space.
    @Test func aDetailKeepsOnlyCleanResourceCodesAndCleanNames() async throws {
        let spider = try await appLY()
        DaoranSite.serve([api + "album/res/list": try json(["album": ["name": "专辑"], "pb": ["dataList": [
            ["code": "a-b", "name": "横线"], ["code": "a b", "name": "空白"], ["code": "a$b", "name": "美元"], ["code": "", "name": "空"],
            ["code": "0dOT1a", "name": "第$一#段"], ["code": "77", "name": ""],
        ]]])])
        let vod = try #require(try list(try await spider.detailContent(ids: ["0dOTNN3xWq505829"])).first)
        #expect(vod["vod_play_url"] as? String == "第 一 段$0dOT1a#第2集$77")
        #expect(vod["vod_director"] as? String == "" && vod["vod_pic"] as? String == "")

        // 9b: every resource dropped still answers the album, with an empty play list (as upstream A:76–78).
        DaoranSite.serve([api + "album/res/list": Data(#"{"album":{"name":"n"},"pb":null}"#.utf8)])
        let bare = try #require(try list(try await spider.detailContent(ids: ["0dOTNN3xWq505829"])).first)
        #expect(bare["vod_play_from"] as? String == "在线播放" && bare["vod_play_url"] as? String == "")

        DaoranSite.serve([api + "album/res/list": Data(#"{"pb":{"dataList":[]}}"#.utf8)])
        #expect(try list(try await spider.detailContent(ids: ["0dOTNN3xWq505829"])).isEmpty)
        DaoranSite.serve([:])
        for id in ["a/b", "a b", ""] {
            #expect(try list(try await spider.detailContent(ids: [id])).isEmpty)
        }
        #expect(DaoranSite.requests.isEmpty)
    }

    @Test func playFetchesAFreshAddressAndAddsNoHeader() async throws {
        DaoranSite.serve([api + "play/get/playurl": try playurl1()])
        let spider = try await appLY()
        let played = try object(try await spider.playerContent(flag: "在线播放", id: "11084070000629", vipFlags: []))
        #expect(played["url"] as? String == "http://flytx.daoran.tv/sv/90f8e48-19cf7c479c8/90f8e48-19cf7c479c8.m3u8?auth_key="
                + "1791786466-a8efe6f6895f43fc8dcd4781871ba1eb-0-55f0b469f1fbec82befe46a882e660fe&t=6acd0956&us=1da22a290190bfc43f2"
                + "&sign=cecc7ad64c57bb93db0e89155ae425cc0a187e53")
        #expect(played["parse"] as? Int == 0 && played["header"] == nil)
        let sent = try #require(DaoranSite.requests.last)
        #expect(sent.body == #"{"item":"y9","nodeCode":"001000","project":"lyhxcx","px":"2","resCode":"11084070000629","userId":"92315ec6e58a45ba7f47fd143b3d7956"}"#)
        #expect(sentUpstreamHeaders(sent.headers))

        _ = try await spider.playerContent(flag: "", id: "0dOT1a", vipFlags: [])
        #expect(DaoranSite.requests.last?.body.contains(#""resCode":"0dOT1a""#) == true)
        for body in [#"{"code":1}"#, #"{"playres":{}}"#, #"{"playres":{"playurl":"ftp://x/a.m3u8"}}"#] {
            DaoranSite.serve([api + "play/get/playurl": Data(body.utf8)])
            #expect(try object(try await spider.playerContent(flag: "", id: "11084070000629", vipFlags: []))["url"] as? String == "")
        }
        DaoranSite.serve([:])
        for id in ["a/b", "a b"] {
            #expect(try object(try await spider.playerContent(flag: "", id: id, vipFlags: []))["url"] as? String == "")
        }
        #expect(DaoranSite.requests.isEmpty)
    }

    @Test func aServerErrorOnACategoryIsReported() async throws {
        let spider = try await appLY()
        DaoranSite.serve([api + "search/album/list": Data()], status: 500)
        await #expect(throws: SiteUnreachable(.httpStatus(500), host: "fly.daoran.tv")) {
            _ = try await spider.categoryContent(tid: "zaobang", page: "1", filter: false, extend: [:])
        }
    }

    @Test func searchIsEmptyWithoutARequest() async throws {
        DaoranSite.serve([:])
        #expect(try list(try await appLY().searchContent(key: "枣梆", quick: false, page: "1")).isEmpty)
        #expect(DaoranSite.requests.isEmpty)
    }
}

/// `home.json` from the W-50 gate (10227 bytes), raw-deflated.
private let homePacked = """
vVpbUxpZEP4vPO1WWQG8IPoGiAYvqIjJxq2tqYGZhSFcHYhoKlW6idfVlWxMoSDrei8TNYJGBTX+GWYY/sUenFXOcZ9yarZ50Rlmunu6z/f112d4rRPjozwb
ckZ07ToD+rSN2j1tEYvX5jc2GluaWnUNOm+E43XtRoP6adDF+WQcXS3PpaSFDfR9nPXp2sOJYBD9K4R4Z2QMXd3aZmw1m5pNTS3GxgZdlPXxDu7+KpH3xkVd
+8+v/zWtm2AjHjbsQ7bCbKh2Qv5rW96aQcdCyCfe3yaIIo8cG9Sz3UP9zodvQsg+ug3dwAY9iZA7EmeDd1f6WdHJo3h+ZYMijzxHRmsW3jQ8uB5PBBJ1v0r+
szS//91++wfsLovbrh+y29yMo8/SZdfb9Fa9ao3p6rS7nwSiPoro/KFkPbjq1Tt5a1qeW9Yivg69Rf9gkDGbzSOUIY4neCKD5wsaZbAWoWqN6e0dbqQMLyCE
fXh85dKhRvFZUIVVa4zRNOCgjC/6KD7lyzstV+CdNabX9JOdMr4YgQ85W9Csula9ao0ZcTW30uIjPDFRj07K/S0dpbSIzoqyp1pjeq2dZtrcCeFYPbrK/p4y
vaJNZW161Roz8tTsos2dx4PlTi6cSotpRLqaZbBDj9tkjM6hZspIvX42QqzCm2MNMaJaYwY7nX2U8fk4DqPpSmGHIjr14LtrSKKz8EmzvNj0qjWme9AySJkX
PpDEiXdR2ilK13taxfdgkDGZ2mhL9zIRjuEZXJ1BpKRVd1CtMa6egU5qfouJJEaX0pXUWbm4p12V6zYZR+uz57QYZQUE06SAyZXZWWXxnEau3P0V9Y2GRpOh
5Q6jhvtPc7PLOdzv7hm2WigDFWtk8gqD69USDWhoiplgBQKuF8dAnpN+DhPXyu5treo7+9XrDxDePUG80aCOoFx8oWw0VOTsD2Dei7fly3U5Pw+U+TGCoKWD
EpBfUUgKbBhj38scDfVSeA5ikqdcTNFIHgqvfSMvXmDIOnkvp5erG6coABBkhznff3haBRgNVdNNYRwxhCknbyH8eh8pkN0M0AKPJnASV/4sQFEptrxRb6NR
CzTlZckpUZ4/BHreEC/4MceV9Xl57gKkwOO4ps4cSzd5Gi1BI1vReWLkVeZL8lqmfJ2B8D4xgT23fLQtHaWBnluMYhQiZbNS8RSIRZ73YFCenJKKZ4g8pSMQ
5uRQnySgdTULBK3hLlvdLTpQ9meqW+8hPAc4XA+WS4dIE8HpQR8S4AI5KnxerawUgJY5x4ZJbSQtfQTSRtEkhm3lj5ny1RrQQweFRAznlY1TNPIB+R7qsI7g
SnRBms7A6f8xD1bp4yzQa4WYECE7diV1DUQraBJHnBbBnvrmAIjHOaKDIAoH6yD4jAc33SWJeb66sgnkN/gKF79S6iOUGCT2EeStaWUhD9g3cCTn87U5no5F
Hu8vdeD7S4Oulm5H36Cz7Uk0TLO/FCQn/lIKbneJfI+UA3Jsd7mJXd5yqSQtn4AsCAz0ytdtKBDEk+MY6Et7lZWTcnGzuvENqMw+XEQs5BH6gBo5GvZJrSxd
5DR82ata+8H4I/OsyfGUcns3iTeC4irQmoi/5GJ45/sklS6qUx/kt9Mga8JLrgh5PQe0Impvr0U/+foaaMcrHhAJsXEgn+3K6XMgvZHE1bSye1vZ3wNKeUgg
IFhN3wCt8QDpWF77Hcrx+KNptbrxFfDtBb4fU1m7AdyPwYleymaV3zaB5tQAoWulFJyeJn4FVsleStsgSsKPSUt5chJoSPRwQYzCyrc56TijTE79rxT2y5t/
AA==
"""

/// `category.json` from the W-50 gate (2541 bytes), raw-deflated.
private let categoryPacked = """
vZbbUxpXGMD/l30mYRcQWN6sY9t0LLGJM32Imc4Ci267XMpCjXGc2WqWizbItHjFFBOlmMkIwnhBQP1j3HN296n/Qr+zi6iZcUxr232A75z97ud8P5ihpGSC
5yL+GOWjaHjYxHBg8JvUiDjldNNuh5uyUcFYiKd8DG09NirJv0iCNs4W0EIZ3ie5CcoXTYkiiEKE98emQNvDMh6v2+V20V6XjYoHKN8MFRYSElgysE7w5ncw
lTC/o6ZLEESupyEluQRIEC7OTfBPhZdg4CDBY0lOHIUtU8tcDcVSUVB1mO5Gr7RtVIhLciMC8fhsplcGRYcej/n9zhff/jhAD3gdLBQQ5SLkDf59G79Lo9oi
Ojs23qxonSWktFCxgWuHoCREoErq8ejwk8GxYfvo4BfD3z36Gj7tnBhIRexDdjfLe+hQKMy7ArQXqg4NhN007WIefh+fsOwl0oTJ0GWzpL40Ncm42Xt5n5p0
uj7BAc+6bzrwBPsOGAYcmNKAh0izVs588F5+wUVyUrA8CxE4nK+kWBSWM+NmoHHKN06NU7Zxs4LrK4a5sXKzveUsOArxEjmvRsYopa1Twyv7WlXun53a2dbf
7lpn92f3F3x0qJVWLuQF/XUOb52gnSpqZS/kRdjRimW8WgFZ28uhXFUr1S7kuas7sPEKnOhKESldpBxbsYwPa2r7HT6X8drchfyzfrCLNw+MdAblN0Bfy53o
uSYERYUC2lvFLQWv74Manlfwq7JRaeDOW3irNc9QJq12twz5V7WdxvUlSBWXmpCAvnyACh/AlWWitvIorUAJYAX1qq091FjW8vvEyswHNPVcG2/WjT0FLZSI
/rX8cbcIJRjyll7fJq1Yq/essg1UOdVlheRsXnVcPNJXl6B86HA4wfOfi2SwYebCl0Jc5KbHBDIsvXEn4+dPRSjfgDl8pgh6cGkIIV5ysQAXJbcgngqIgjRp
2VIO2uF+QDsfMA4yfPxUP1CU50OfpaZNOcGHrH0rVFAUgj8Qe4lwgPUSBWlsOm5xAFgBYz5kTrilb+34rcnu9wPiSbEeV6SnQnRC5OPcNKECqZngqZ+LlAqM
CUnxCgw4d46WdoyyeaFaCtreh9NTWxlUOwJjThSt6ljWabVvRIgIVqT+6nrvpGCMQJB+SJsElfo95SZI1v31TxHpUQ8Us7YbFBsN819GIy6vi2Y8H1Ps+s3G
p2v48FhfbGi57N0gG74NNc5/A2R3er8LZIO3AYe/AbLLdAjKrNZ9Aszu9H0bzPpI0usVgIjaqeD1miFvwNVA7T0yYOZZoM02Xq+rrTbKZpBS0eZO4CrptaZ+
ToZZbQG/jtR2G23u9vRPf0M77wlKSltk56CjFQpqe5FApzqHzg/RcQ1159R2Fd5q5ZJWOoPh1+t1tbtBrPJpGGy1ncOQUiuPm2VIiVzeTVnrZPXqNurKxkbR
MClmZF7jxTPceg/QIdRYVsxA/4QFzP/JAsbpYv8WC/rTYMdv8vCboeeb9nvywTotYCc6n4eumXwgfSQt3l/T5v+4zgeGZZzMf0aI52Yvev95npulXy5mZ/8C
"""

/// `detail1.json` from the W-50 gate (3206 bytes), raw-deflated.
private let detailPacked = """
1VZtT9tWFP4v/gzNvX4331iWIhCkqI1WaaOanMRJ3DpxZjtAQEhZ2wRCN0ATBVa6QcsQlSpeRVsKrPsxxE7yaX9h59rGONU20Jim1R+Sc3zPPfec55zz+E5S
pmUocj6uUz0UgkcyYsne0fjtAUFkBIbjqC4qpacVqgcj7+miLGXcAmtnZsGeXYN1S85SPYWSpoGo5pW4PgbWgoQFkWd5lmO4LkrWkqU81TPp+6JQ+lYiHmfG
737DIU6kJfBSkPNkxfl5w3lZs3ee2B/etX9aap7M29Uje3Hf2XkDRmoejqJuDcdu9yZikeHevtjX/UPwG3EPiEQjvKQIKJ3OKGwSiUhk01yGR4jFN+4Xs95+
k4SRS59HbAbSWA7z0rW8j+UY9goOFInvdCCkAgcYgwNX4gQiTXkxK6lr+QUXVk71PKt5OasMmHoB1MkR96ARqmeEGqG6RtwMwhrGHRov+eoUOEorJqnX/nR7
teZVzVnaa25Vgto1TjZaL155tfv99Dvn7Zvm6tJZZbb1fd1Zf2//smUfzZxVnsCb5uKas7wJcnO7bte3mqs7Z5WHFz3w7DE4aVUX7eqpXX3nndV+vdI4fun8
VnFWHp5Vvm0dvnKeH7Zr0/bcM7Bv1t+36gdwqL2wYG8vO0dV58c9MHMeVZ3Ha+3NfefkBaw2Dz7Y07XG6Xq78kPjuObszkOozuoBBNB6emgvvAZX3pbG0Zxd
q0IKsAvybRxt2/tPm3N7ZJcbD1i26sfO8932dtWeXSX2ofid00VIoV1Zb+1uEChWdv1dM/v25q+tSpXE7La6s/i2tTwP6QPCGUNRbmpkumDqMudCUZPLCZUM
iz9zuiVrcTJeMGipkuGKYAdNQ8Z0QtaTcoF0QbGU1FQz5+2laETz3YjpxjQZPmUsOKigKOnPSmVXNpS09947KqWpqQdkP1SexkggBmaiXCT0AENuWKppRb0J
512yEEUakeH2luLeiAfAwIKpG5YX7R21kNWUolwm9ECSVw3TCoIyS8mEamlB0rKmeXkgD6ZBNa9anVoYIzOlG8T4BnLpygywk7MkqEAfzZv9PiHA5BWThCvc
QNwEi4aXKIDs/hdcIgRBk30L05L9fIowZXfUCYUAxQqsyPCs4NdqGJZca1eL6qWCdV674WAX6GnZkgdV4vmrSY9Bo3/Jnj6vYgzDjwQCPR9m1QByv+1CrIr/
rjwuWcA7IUIjhCMSioDnCIciIh1xC6zeHBqPfTGsZ2jMcTTt841XVRzuYBzq4KB4WOT8pjLJJ4PjAUr1ASkHKSSUTM0W/KiojuJ4iUXjYS2RU41gGfpS10qW
SmjOe5PPqJoy9DmX0M3zAv8TVBl0JVTpa6Pa14fKWOAx4vgOVOlLURWlC1BpWvoEMMVXwpS5Nqb9wv1yP81KPI07MGUu71SWDXeq8AmASn98qQp/aNuVOiDa
HSAY3LCuB/DA6IQcpUVexKgDYPZSgFkUBpjwwv8eYOZPAP7obnNxB6jP/EsQD36ZzMd4WmSYToi5y3tYwCFi+I8hvuea+Z+zey4I58rU1B8=
"""

/// `playurl1.json` from the W-50 gate (1108 bytes), raw-deflated.
private let playurlPacked = """
5VLNjtMwEH4XH/bUbu008U+lCq1WIMGhQmjhiib2uInWTaLE2d2y4o448QY8HTwH44ZmWcQb4JNnxjPz+fu+RzbEHuGwa9mGcTqmf1lef3in0KyN5EaxBbOt
Q7YRfDoLFvEh0uufX779+Pqd6hH2bNOMIdC1PuCuvafXygilZS4Lo/MF6wIcexzY5pH5OuD1aSITguucqzRVZobzbF72V4nyB3Q13By7hGSaN/aBHlYxdpvV
yodjfLh00PbQXMa71XC3MtxrzPVSGOuVzZWx+l+5y8N61C9gjNXHWzxuZ+ByCRo9Si+1KXy+9lY763KlhVaiBIHlki+LwvMyl8YLX6LVWUkduQStM5SSe7yI
WwnWcVPIi3HYCgdZBvRVYXjpLQ3NLoZ632wtWqvAydwWqizN2pUctRFFAZhnhbUcaCsWayIi9PbMNoRwQ4QTI7ogTvxvWokzNknxTAdDOlQIbmpJOkId5sBW
aG9344H6qZkUxmao2+a8ihJvhqcwkhCv3Tmiwn6ShvFkGN8jvgrJFSTVUH+iglqbTEkhF8y1981cvK9drOhmMp7A1fsqJqfpE7r9MK+D/Q4OOMdJ/rfQwwT2
rnbYXnUOIvanv5DT2jDGP+DbLqFlyVTJY12aNtU+T9Pe92Fy59On5lvl/kefDbfPCOqgbuKZkRPjT/qn+tWYhDw1/AI=
"""
