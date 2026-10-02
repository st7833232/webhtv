import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-45C. The API providers against canned answers: the viewer's key goes only where the
// API asks for it and nowhere else, a provider without one never sends a request, and the API's
// own refusals reach the panel as what they are.

/// Answers every request from `answer` and keeps what was asked.
private final class APIRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = [URLRequest]()
    private let answer: @Sendable (URLRequest) throws -> SubtitleHTTPResponse

    init(_ answer: @escaping @Sendable (URLRequest) throws -> SubtitleHTTPResponse) { self.answer = answer }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    var fetch: SubtitleFetch {
        { [self] request, _ in
            record(request)
            return try answer(request)
        }
    }

    private func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        seen.append(request)
    }
}

private final class MemoryCredentials: SubtitleCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SubtitleCredentialKey: String]

    init(_ values: [SubtitleCredentialKey: String] = [:]) { self.values = values }

    func value(for key: SubtitleCredentialKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func setValue(_ value: String?, for key: SubtitleCredentialKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
        return true
    }
}

private func json(_ object: Any, status: Int = 200) -> SubtitleHTTPResponse {
    SubtitleHTTPResponse(status: status, mimeType: "application/json",
                         data: try! JSONSerialization.data(withJSONObject: object))
}

private let srt = "1\n00:00:01,000 --> 00:00:02,000\n台詞\n"
private let osKey = "os-key-for-tests"
private let assrtToken = "assrt-token-for-tests"
private let query = SubtitleSearchQuery(text: "Movie 2024")

private func osSearchAnswer() -> [String: Any] { ["data": [
    ["id": "1", "attributes": ["language": "en", "release": "Movie.2024.1080p",
                               "files": [["file_id": 11, "file_name": "Movie.2024.en.srt"]]]],
    ["id": "2", "attributes": ["language": "zh-tw", "release": "Movie.2024.WEB",
                               "files": [["file_id": 22, "file_name": "Movie.2024.zh-tw.srt"]]]],
    ["id": "3", "attributes": ["language": "ja", "files": [["file_name": "no-id.srt"]]]],
]] }

// MARK: - No key

/// A viewer who has set up nothing sees the two API providers listed as not set up, Subtitle
/// Cat chosen, and searching an API provider anyway sends nothing anywhere.
@MainActor @Test func aProviderWithoutItsKeyIsListedAsNotSetUpAndNeverCalled() async {
    let providers = OnlineSubtitleProviders.make(credentials: MemoryCredentials(), userAgent: "WebHTV v1")
    #expect(providers.map(\.id) == [SubtitleCatProvider.providerID, OpenSubtitlesProvider.providerID,
                                    AssrtProvider.providerID])
    #expect(providers[0].availability == .available)
    for provider in providers.dropFirst() {
        guard case .unconfigured(let reason) = provider.availability else {
            Issue.record("\(provider.id) offered without a key"); continue
        }
        #expect(reason.contains("設定"))
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("api-\(UUID().uuidString)")
    let session = OnlineSubtitleSession(identity: OnlineSubtitleIdentity(titleKey: "k", line: nil, episode: nil, address: "a"),
                                        keywords: .make(title: "Movie 2024"), providers: providers,
                                        downloader: SubtitleDownloadService(fetch: { _, _ in throw URLError(.cannotFindHost) }),
                                        cache: SubtitleSessionCache(root: root))
    #expect(session.selectedProviderID == SubtitleCatProvider.providerID)

    let recorder = APIRecorder { _ in json([:]) }
    for provider in [OpenSubtitlesProvider(apiKey: "  ", fetch: recorder.fetch) as any SubtitleProvider,
                     AssrtProvider(token: nil, fetch: recorder.fetch)] {
        await #expect(throws: SubtitleProviderError.unconfigured) { _ = try await provider.search(query) }
    }
    #expect(recorder.requests.isEmpty)

    let configured = OnlineSubtitleProviders.make(credentials: MemoryCredentials([.openSubtitlesAPIKey: osKey,
                                                                                   .assrtToken: assrtToken]))
    #expect(configured.allSatisfy { $0.availability == .available })
}

// MARK: - OpenSubtitles

/// The key goes in the `Api-Key` header with an application User-Agent, the parameters in the
/// order the API wants, and the results come back Traditional Chinese first; a result without a
/// file id is not offered, and no track carries the key.
@Test func openSubtitlesSearchesWithTheKeyInItsHeaderOnly() async throws {
    let recorder = APIRecorder { _ in json(osSearchAnswer()) }
    let provider = OpenSubtitlesProvider(apiKey: osKey, userAgent: "WebHTV v9", fetch: recorder.fetch, retryDelay: .zero)
    let result = try await provider.search(query)

    let request = try #require(recorder.requests.first)
    #expect(recorder.requests.count == 1)
    #expect(request.url?.absoluteString
        == "https://api.opensubtitles.com/api/v1/subtitles?languages=en%2Cja%2Czh-cn%2Czh-tw&query=Movie%202024")
    #expect(request.value(forHTTPHeaderField: "Api-Key") == osKey)
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "WebHTV v9")
    #expect(result.tracks.map(\.language.code) == ["zh-TW", "en"])
    #expect(result.tracks.map(\.fileName) == ["Movie.2024.zh-tw.srt", "Movie.2024.en.srt"])
    #expect(result.listedCount == 3)
    #expect(result.tracks.allSatisfy { !$0.downloadURL.absoluteString.contains(osKey) && $0.detailURL == nil })
}

/// A download asks the API once for a link (never twice: an answered request can count against
/// the day's downloads), then fetches the link without the key. The same file picked twice in one
/// session is one request to the API.
@Test func openSubtitlesDownloadAsksForOneLinkAndKeepsTheKeyAway() async throws {
    let recorder = APIRecorder { request in
        if request.httpMethod == "POST" { return json(["link": "https://dl.opensubtitles.example/file/22.srt"]) }
        if request.url?.host == "dl.opensubtitles.example" {
            return SubtitleHTTPResponse(status: 200, mimeType: "application/x-subrip", data: Data(srt.utf8),
                                        url: request.url)
        }
        return json(osSearchAnswer())
    }
    let provider = OpenSubtitlesProvider(apiKey: osKey, fetch: recorder.fetch, retryDelay: .zero)
    let track = try #require(try await provider.search(query).tracks.first)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("os-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = SubtitleSessionCache(root: root)
    let downloader = SubtitleDownloadService(fetch: recorder.fetch, retryDelay: .zero)

    let first = try await downloader.download(track, from: provider, into: cache)
    let again = try await downloader.download(track, from: provider, into: cache)
    #expect(first == again)

    let posts = recorder.requests.filter { $0.httpMethod == "POST" }
    #expect(posts.count == 1)
    let body = try #require(posts.first?.httpBody)
    let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(sent["file_id"] as? Int == 22 && sent["sub_format"] as? String == "srt")
    #expect(posts.first?.value(forHTTPHeaderField: "Api-Key") == osKey)
    let file = try #require(recorder.requests.last)
    #expect(file.url?.host == "dl.opensubtitles.example")
    #expect(file.value(forHTTPHeaderField: "Api-Key") == nil)
}

/// The API's refusals are named: the day's downloads used up, a key it does not accept. A server
/// error on the link request is not retried.
@Test func openSubtitlesRefusalsAreNamedAndTheLinkRequestIsNotRetried() async throws {
    let track = try #require(OpenSubtitlesProvider.tracks(in: (osSearchAnswer()["data"] as! [[String: Any]])[1]).first)
    for (status, expected) in [(406, SubtitleProviderError.quotaExceeded), (401, .unauthorized),
                               (503, .httpStatus(503))] {
        let recorder = APIRecorder { _ in json(["message": "no"], status: status) }
        let provider = OpenSubtitlesProvider(apiKey: osKey, fetch: recorder.fetch, retryDelay: .zero)
        await #expect(throws: expected) { _ = try await provider.downloadRequest(for: track) }
        #expect(recorder.requests.count == 1)
    }
    let recorder = APIRecorder { _ in json(["message": "Forbidden"], status: 403) }
    let provider = OpenSubtitlesProvider(apiKey: osKey, fetch: recorder.fetch, retryDelay: .zero)
    await #expect(throws: SubtitleProviderError.unauthorized) { _ = try await provider.search(query) }
}

// MARK: - Assrt

private func assrtSearchAnswer() -> [String: Any] { ["status": 0, "sub": ["subs": [
    ["id": 101, "videoname": "Movie.2024.1080p", "lang": ["langlist": ["langcht": true]]],
    ["id": 102, "videoname": "不知道", "native_name": ["電影"], "lang": ["langlist": ["langchs": true, "langeng": true]]],
]]] }

private func assrtDetail(_ id: String) -> [String: Any] {
    switch id {
    case "101":
        return ["status": 0, "sub": ["subs": [["filelist": [
            ["f": "Movie.2024.chs.srt", "url": "https://file.assrt.example/101/chs.srt"],
            ["f": "Movie.2024.ass", "url": "https://file.assrt.example/101/a.ass"],
            ["f": "Movie.2024.繁體.srt", "url": "https://file.assrt.example/101/cht.srt"],
            ["f": "Movie.2024.srt", "url": "https://file.assrt.example/101/plain.srt"],
        ]]]]]
    default:
        return ["status": 0, "sub": ["subs": [["filelist": [] as [Any], "filename": "電影.srt",
                                               "url": "https://file.assrt.example/102/one.srt"]]]]
    }
}

/// The token is a query parameter of the API calls and of nothing else: not of a file link, not
/// of a referrer. Only SubRip files are offered; a file's name decides its language, and the
/// result's language list covers a name that says nothing.
@Test func assrtListsTheSubRipFilesOfEachResultAndKeepsTheTokenToTheAPI() async throws {
    let recorder = APIRecorder { request in
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if request.url?.path == "/v1/sub/detail" {
            return json(assrtDetail(items.first { $0.name == "id" }?.value ?? ""))
        }
        return json(assrtSearchAnswer())
    }
    let provider = AssrtProvider(token: assrtToken, fetch: recorder.fetch, retryDelay: .zero)
    let result = try await provider.search(query)

    #expect(recorder.requests.map { $0.url?.path } == ["/v1/sub/search", "/v1/sub/detail", "/v1/sub/detail"])
    #expect(recorder.requests.allSatisfy {
        URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "token" && $0.value == assrtToken } == true
    })
    #expect(recorder.requests.first?.url?.query?.hasPrefix("q=Movie%202024&") == true)
    #expect(result.tracks.map(\.fileName) == ["Movie.2024.繁體.srt", "Movie.2024.srt", "Movie.2024.chs.srt", "電影.srt"])
    #expect(result.tracks.map(\.language.code) == ["zh-TW", "zh-TW", "zh-CN", "zh-CN"])
    #expect(result.tracks.last?.title == "電影")
    #expect(result.tracks.allSatisfy { !$0.downloadURL.absoluteString.contains(assrtToken) && $0.detailURL == nil })

    let download = try await provider.downloadRequest(for: try #require(result.tracks.first))
    #expect(download.url?.absoluteString == "https://file.assrt.example/101/cht.srt")
    #expect(download.value(forHTTPHeaderField: "Referer") == nil)
}

/// The API's own error code is reported as a refusal, not as "no subtitles"; a rate limit on one
/// result stops the rest, which would be refused too.
@Test func assrtErrorsAreRefusalsAndARateLimitStopsTheDetailRequests() async throws {
    let refusing = APIRecorder { _ in json(["status": 101, "errmsg": "invalid token"]) }
    await #expect(throws: SubtitleProviderError.rejected(101)) {
        _ = try await AssrtProvider(token: assrtToken, fetch: refusing.fetch, retryDelay: .zero).search(query)
    }

    let limited = APIRecorder { request in
        request.url?.path == "/v1/sub/detail" ? json([:], status: 429) : json(assrtSearchAnswer())
    }
    await #expect(throws: SubtitleProviderError.rateLimited) {
        _ = try await AssrtProvider(token: assrtToken, fetch: limited.fetch, retryDelay: .zero).search(query)
    }
    #expect(limited.requests.count == 2)
}
