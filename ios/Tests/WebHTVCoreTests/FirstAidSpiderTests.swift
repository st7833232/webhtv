import Foundation
import Testing
@testable import WebHTVCore

final class FirstAidMockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: (Data, Int)] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        routes.removeAll()
        recorded.removeAll()
    }

    static func route(path: String, body: String, status: Int = 200) {
        lock.lock()
        defer { lock.unlock() }
        routes[path] = (Data(body.utf8), status)
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return url.host == "m.youlai.cn"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let matched = Self.routes[request.url?.path ?? ""]
        Self.lock.unlock()

        guard let (data, status) = matched else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct FirstAidSpiderTests {
    private func makeRuntime() async throws -> JavaScriptSpiderRuntime {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FirstAidMockProtocol.self]
        let registry = SpiderRegistry.bundled()
        let entry = try #require(registry.entry(for: "FirstAid"))
        let runtime = try JavaScriptSpiderRuntime(
            name: "FirstAid",
            script: entry.script,
            prelude: registry.prelude,
            storage: SpiderStorage(siteKey: "FirstAid-test", defaults: UserDefaults(suiteName: "FirstAid-test")!),
            session: URLSession(configuration: config)
        )
        try await runtime.initialize(extend: "")
        return runtime
    }

    private func parseJson(_ string: String) throws -> [String: Any] {
        let data = Data(string.utf8)
        let obj = try JSONSerialization.jsonObject(with: data)
        return try #require(obj as? [String: Any])
    }

    @Test
    func testFirstAidSpiderFullFlow() async throws {
        FirstAidMockProtocol.reset()

        // 1. homeContent
        let runtime = try await makeRuntime()
        let homeStr = try await runtime.homeContent(filter: false)
        let homeJson = try parseJson(homeStr)
        let classes = try #require(homeJson["class"] as? [[String: Any]])
        #expect(classes.count == 8)
        #expect(classes[0]["type_id"] as? String == "jijiu|0")
        #expect(classes[0]["type_name"] as? String == "急救技能")
        #expect(classes[7]["type_id"] as? String == "jijiu|7")
        #expect(classes[7]["type_name"] as? String == "意外事故")

        // 2. categoryContent (default and override)
        let jijiuHtml = """
        <html>
          <div class="block100"><img src="//pic.invalid/skill.jpg"></div>
          <div class="block100"><img src="/pic/family.jpg"></div>
          <div class="jj-title-li">
            <div class="list-br3">
              <a href="/video/101.html">心肺复苏</a>
            </div>
            <div class="list-br3">
              <a href="/video/102.html">海姆立克</a>
            </div>
          </div>
          <div class="jj-title-li">
            <div class="list-br3">
              <a href="/video/301.html">烫伤处理</a>
            </div>
          </div>
        </html>
        """
        let customHtml = """
        <html>
          <div class="block100" src="/pic.invalid/custom.jpg"></div>
          <div class="jj-title-li">
            <div class="list-br3">
              <a href="https://m.youlai.cn/video/201.html">包扎止血</a>
            </div>
          </div>
        </html>
        """
        FirstAidMockProtocol.route(path: "/jijiu", body: jijiuHtml)
        FirstAidMockProtocol.route(path: "/custom_cate", body: customHtml)

        let cat1Str = try await runtime.categoryContent(tid: "jijiu|0", page: "1", filter: false, extend: [:])
        let cat1Json = try parseJson(cat1Str)
        let list1 = try #require(cat1Json["list"] as? [[String: Any]])
        #expect(cat1Json["pagecount"] as? Int == 1)
        #expect(list1.count == 2)
        #expect(list1[0]["vod_id"] as? String == "https://m.youlai.cn/video/101.html")
        #expect(list1[0]["vod_name"] as? String == "心肺复苏")
        #expect(list1[0]["vod_pic"] as? String == "https://pic.invalid/skill.jpg")

        let cat2Str = try await runtime.categoryContent(tid: "jijiu|0", page: "1", filter: false, extend: ["cateId": "custom_cate"])
        let cat2Json = try parseJson(cat2Str)
        let list2 = try #require(cat2Json["list"] as? [[String: Any]])
        #expect(list2.count == 1)
        #expect(list2[0]["vod_id"] as? String == "https://m.youlai.cn/video/201.html")
        #expect(list2[0]["vod_name"] as? String == "包扎止血")
        #expect(list2[0]["vod_pic"] as? String == "https://m.youlai.cn/pic.invalid/custom.jpg")

        // The index after "|" picks the matching cover block and list group on the same page.
        let cat3Str = try await runtime.categoryContent(tid: "jijiu|1", page: "1", filter: false, extend: [:])
        let cat3Json = try parseJson(cat3Str)
        let list3 = try #require(cat3Json["list"] as? [[String: Any]])
        #expect(cat3Json["pagecount"] as? Int == 1)
        #expect(list3.count == 1)
        #expect(list3.first?["vod_id"] as? String == "https://m.youlai.cn/video/301.html")
        #expect(list3.first?["vod_name"] as? String == "烫伤处理")
        #expect(list3.first?["vod_pic"] as? String == "https://m.youlai.cn/pic/family.jpg")

        // 3. detailContent (#video source and #video fallback)
        let detail1Html = """
        <html>
          <div class="video-title h1-title">心肺复苏教学</div>
          <div class="video-cover list-flex-in"><img src="http://pic.invalid/cover1.jpg"></div>
          <span class="doc-name">张医生</span>
          <div class="img-text-con">标准急救胸外按压</div>
          <video id="video"><source src="/media/cpr.mp4"></video>
        </html>
        """
        let detail2Html = """
        <html>
          <div class="video-title h1-title">海姆立克手法</div>
          <div class="video-cover list-flex-in"><img src="//pic.invalid/cover2.jpg"></div>
          <span class="doc-name">李医生</span>
          <div class="img-text-con">气道异物梗阻急救</div>
          <video id="video" src="https://media.invalid/heimlich.mp4"></video>
        </html>
        """
        FirstAidMockProtocol.route(path: "/video/101.html", body: detail1Html)
        FirstAidMockProtocol.route(path: "/video/102.html", body: detail2Html)

        let detail1Str = try await runtime.detailContent(ids: ["https://m.youlai.cn/video/101.html"])
        let detail1Json = try parseJson(detail1Str)
        let dList1 = try #require(detail1Json["list"] as? [[String: Any]])
        #expect(dList1.count == 1)
        #expect(dList1[0]["vod_name"] as? String == "心肺复苏教学")
        #expect(dList1[0]["vod_pic"] as? String == "http://pic.invalid/cover1.jpg")
        #expect(dList1[0]["type_name"] as? String == "张医生")
        #expect(dList1[0]["vod_year"] as? String == "中国")
        #expect(dList1[0]["vod_content"] as? String == "标准急救胸外按压")
        #expect(dList1[0]["vod_play_from"] as? String == "Qile")
        #expect(dList1[0]["vod_play_url"] as? String == "心肺复苏教学$https://m.youlai.cn/media/cpr.mp4")

        let detail2Str = try await runtime.detailContent(ids: ["https://m.youlai.cn/video/102.html"])
        let detail2Json = try parseJson(detail2Str)
        let dList2 = try #require(detail2Json["list"] as? [[String: Any]])
        #expect(dList2.count == 1)
        #expect(dList2[0]["vod_name"] as? String == "海姆立克手法")
        #expect(dList2[0]["vod_pic"] as? String == "https://pic.invalid/cover2.jpg")
        #expect(dList2[0]["vod_play_url"] as? String == "海姆立克手法$https://media.invalid/heimlich.mp4")

        // 4. searchContent
        let searchHtml = """
        <html>
          <div class="search-video-li list-br2">
            <a href="/video/search1.html"></a>
            <h5 class="line-clamp1">溺水急救</h5>
            <dt class="logo-bg"><img src="//pic.invalid/search1.jpg"></dt>
          </div>
        </html>
        """
        FirstAidMockProtocol.route(path: "/cse/search", body: searchHtml)

        let searchStr = try await runtime.searchContent(key: "溺水", quick: false, page: "1")
        let searchJson = try parseJson(searchStr)
        let sList = try #require(searchJson["list"] as? [[String: Any]])
        #expect(sList.count == 1)
        #expect(sList[0]["vod_name"] as? String == "溺水急救")
        #expect(sList[0]["vod_id"] as? String == "https://m.youlai.cn/video/search1.html")
        #expect(sList[0]["vod_pic"] as? String == "https://pic.invalid/search1.jpg")

        // 5. playerContent
        let playStr = try await runtime.playerContent(flag: "Qile", id: "https://m.youlai.cn/media/cpr.mp4", vipFlags: [])
        let playJson = try parseJson(playStr)
        #expect(playJson["url"] as? String == "https://m.youlai.cn/media/cpr.mp4")
        #expect(playJson["parse"] as? Int == 0)
        let playHeaders = try #require(playJson["header"] as? [String: String])
        #expect(playHeaders["User-Agent"]?.contains("Chrome/151.0.0.0") == true)

        // 6. Verify recorded requests and User-Agent: 3 category + 2 detail + 1 search; home/play fetch nothing.
        let requests = FirstAidMockProtocol.requests()
        #expect(requests.count == 6)
        let search = try #require(requests.first { $0.url?.path == "/cse/search" }?.url)
        let query = URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "q" }?.value == "溺水")
        for req in requests {
            let ua = req.value(forHTTPHeaderField: "User-Agent")
            #expect(ua?.contains("Chrome/151.0.0.0") == true)
        }
    }
}
