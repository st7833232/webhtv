import Foundation
import Python
import WebHTVCore
import Openhongguo

/// A CatVod Python spider, driven through the same `SpiderRuntime` contract the JavaScript ones use.
///
/// Above this class nothing knows the difference: `SpiderSession`, `SourceClient` and the UI see the
/// same thirteen text-in/text-out methods they already see from `JavaScriptSpiderRuntime`. That is
/// the whole point of porting the ABI rather than the implementation.
///
/// It lives in the app target because it links CPython, which has no macOS slice — see `PythonBoot`.
///
/// IOS-POC-7G.
final class PythonSpiderRuntime: SpiderRuntime, @unchecked Sendable {
    /// Identifies this spider's instance inside `webhtv_runtime`. Python owns the objects; Swift
    /// only ever holds this string, so there is no `PyObject` lifetime to get wrong here.
    private let handle: String
    private let siteKey: String

    /// Runs every call into Python, one at a time, off Swift concurrency's cooperative pool.
    ///
    /// One at a time for the reason the lock it replaces had: a spider's own instance state must not
    /// be re-entered mid-method. Off the pool since IOS-POC-20: a call holds the GIL throughout and
    /// blocks for as long as its spider waits on the network, and on the pool — which has only as
    /// many threads as the device has cores — a search across dozens of Python sites would pin them
    /// all. Apple's guidance is to move such work to a Dispatch queue and bridge it with a
    /// continuation (WWDC21 10254, WWDC22 110350), which is also how `JavaScriptSpiderRuntime` already
    /// runs. CPython releases the GIL during socket I/O, so different sites' calls still overlap
    /// their network waits.
    private let queue: DispatchQueue

    /// Loads the script. Throws rather than returning a half-built runtime, so a caller that gets an
    /// instance back has one that ran.
    /// Where `getCache`/`setCache` keep a site's JSON file. Defaults to the app's caches directory,
    /// which is where a derived, re-fetchable thing belongs.
    static let defaultCacheDirectory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("python-spider")

    init(script: String, siteKey: String, cacheDirectory: URL = PythonSpiderRuntime.defaultCacheDirectory) throws {
        self.handle = UUID().uuidString
        self.siteKey = siteKey
        self.queue = DispatchQueue(label: "webhtv.python.\(siteKey)")
        try PythonBoot.ensureStarted()
        do {
            _ = try Self.bridge("load", [handle, siteKey, cacheDirectory.path, script])
        } catch let failure as PythonFailure {
            throw Self.surfaced(failure, siteKey: siteKey, method: "load")
        }
    }

    // MARK: - SpiderRuntime

    func initialize(extend: String) async throws {
        _ = try await call("init", [extend])
    }

    func homeContent(filter: Bool) async throws -> String {
        try await call("homeContent", [filter])
    }

    func homeVideoContent() async throws -> String {
        try await call("homeVideoContent", [])
    }

    func categoryContent(tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> String {
        try await call("categoryContent", [tid, page, filter, extend])
    }

    func detailContent(ids: [String]) async throws -> String {
        try await call("detailContent", [ids])
    }

    func searchContent(key: String, quick: Bool, page: String) async throws -> String {
        try await call("searchContent", [key, quick, page])
    }

    func playerContent(flag: String, id: String, vipFlags: [String]) async throws -> String {
        // Keep public-web lines and every other spider on the existing path.
        if siteKey == "红果短剧", let request = HongguoSDKPlayback.Request(token: id) {
            return try await HongguoSDKPlayback.shared.resolve(request)
        }
        return try await call("playerContent", [flag, id, vipFlags])
    }

    func liveContent(url: String) async throws -> String {
        try await call("liveContent", [url])
    }

    func isVideoFormat(url: String) async throws -> Bool {
        try await call("isVideoFormat", [url]) == "true"
    }

    func manualVideoCheck() async throws -> Bool {
        try await call("manualVideoCheck", []) == "true"
    }

    func action(_ action: String) async throws -> String {
        try await call("action", [action])
    }

    /// W-202: `localProxy`, through `webhtv_runtime.proxy`, which sends the body base64-encoded.
    func proxy(params: [String: String]) async throws -> SpiderProxyResponse? {
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)
        let text = try await call(bridging: "proxy", encoded, method: "localProxy")
        struct Answer: Decodable { let code: Int; let mime: String; let headers: [String: String]; let body: String }
        let answer = try JSONDecoder().decode(Answer.self, from: Data(text.utf8))
        return SpiderProxyResponse(status: answer.code, mime: answer.mime, headers: answer.headers,
                                   body: Data(base64Encoded: answer.body) ?? Data())
    }

    /// Queued behind any call still running, so the instance is never unloaded under a method in
    /// progress. Not awaited: callers go on at once, as they did when this ran in place.
    func destroy() async {
        queue.async { [handle] in
            _ = try? PythonSpiderRuntime.bridge("unload", [handle])
        }
    }

    // MARK: - The bridge

    private func call(_ name: String, _ arguments: [Any]) async throws -> String {
        try await call(bridging: "invoke", name, try Self.jsonArray(arguments), method: name)
    }

    /// One bridge function on this site's queue: `invoke(handle, name, args)` or `proxy(handle, params)`.
    private func call(bridging function: String, _ arguments: String..., method: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [handle, siteKey] in
                do {
                    continuation.resume(returning: try PythonSpiderRuntime.bridge(function, [handle] + arguments))
                } catch let failure as PythonFailure {
                    continuation.resume(throwing: PythonSpiderRuntime.surfaced(failure, siteKey: siteKey, method: method))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// A spider's own failure, carrying Python's whole traceback. It becomes the one-line
    /// `SpiderError` a person sees only at the edge of this class, in `surfaced`.
    struct PythonFailure: Error { let detail: String }

    /// The whole traceback goes to the log, where it is worth having, and one line goes to the
    /// person, who is looking at a screen and not debugging an interpreter.
    private static func surfaced(_ failure: PythonFailure, siteKey: String, method: String) -> SpiderError {
        print("[spider] python failure\n\(failure.detail)")
        #if DEBUG
        failuresLock.withLock { failures[siteKey] = (method, failure.detail) }
        #endif
        return .scriptFailed(summarised(failure.detail))
    }

    #if DEBUG
    /// The last failure per site: which method, and Python's full traceback. IOS-POC-37's per-site
    /// matrix needs it to tell a missing module from a site that timed out or answered 403 — the
    /// one line a person sees cannot carry that.
    nonisolated(unsafe) private static var failures = [String: (method: String, detail: String)]()
    nonisolated(unsafe) private static let failuresLock = NSLock()

    static func takeFailure(siteKey: String) -> (method: String, detail: String)? {
        failuresLock.withLock { failures.removeValue(forKey: siteKey) }
    }
    #endif

    private static func jsonArray(_ values: [Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    /// Calls one `webhtv_runtime` function with string arguments and returns its string answer.
    ///
    /// Every argument and the result are text, so this never converts a Python container in Swift.
    /// The envelope Python returns carries the failure, which is why a raised exception in a spider
    /// arrives here as a named error rather than as a crash or a silent empty page.
    static func bridge(_ function: String, _ arguments: [String]) throws -> String {
        let gil = PyGILState_Ensure()
        defer { PyGILState_Release(gil) }

        guard let module = PyImport_ImportModule("webhtv_runtime") else {
            throw SpiderError.scriptFailed("webhtv_runtime did not import — \(PythonBoot.takePythonError())")
        }
        defer { Py_DecRef(module) }
        guard let callable = PyObject_GetAttrString(module, function) else {
            _ = PythonBoot.takePythonError()
            throw SpiderError.methodMissing("webhtv_runtime.\(function)")
        }
        defer { Py_DecRef(callable) }

        let tuple = PyTuple_New(arguments.count)
        for (index, argument) in arguments.enumerated() {
            // PyTuple_SetItem steals the reference it is given, so the string is not released here.
            PyTuple_SetItem(tuple, index, PyUnicode_FromString(argument))
        }
        defer { Py_DecRef(tuple) }

        guard let answer = PyObject_CallObject(callable, tuple) else {
            throw SpiderError.scriptFailed("webhtv_runtime.\(function) raised — \(PythonBoot.takePythonError())")
        }
        defer { Py_DecRef(answer) }
        guard let utf8 = PyUnicode_AsUTF8(answer) else {
            _ = PythonBoot.takePythonError()
            throw SpiderError.scriptFailed("webhtv_runtime.\(function) did not answer with text")
        }
        return try unwrap(String(cString: utf8))
    }

    private static func unwrap(_ envelope: String) throws -> String {
        guard let data = envelope.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpiderError.scriptFailed("the runtime answered with something that is not an envelope")
        }
        if object["ok"] as? Bool == true { return object["value"] as? String ?? "" }
        throw PythonFailure(detail: object["error"] as? String ?? "unknown Python failure")
    }

    /// One readable line out of a Python traceback.
    ///
    /// Without this the failure reaches `ContentUnavailableView` in full: twenty lines of frames and
    /// absolute simulator paths, as a user-facing message. The traceback is still printed; this is
    /// only what gets shown.
    static func summarised(_ traceback: String) -> String {
        let last = traceback.split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? traceback
        // A missing module is the common case by a wide margin — 34 of the 42 configured Python
        // sites are blocked on one (IOS-POC-7L) — and naming it is the whole of the useful answer.
        if let range = last.range(of: "No module named ") {
            let module = last[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            return "這個來源需要 \(module) 模組，App 內建的 Python 沒有它"
        }
        return last.isEmpty ? traceback : last
    }
}


/// Experimental native provider. Only directly playable SDK-returned streams
/// are accepted; access refusals never trigger device resets.
private actor HongguoSDKPlayback {
    static let shared = HongguoSDKPlayback()
    private var client: OpenhongguoClient?
    private var cooldownUntil = Date.distantPast

    struct Request: Sendable {
        let episodeID: String
        let height: Int
        init?(token: String) {
            let pieces = token.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count == 3, pieces[0] == "hg-episode-v1",
                  let quality = Int(pieces[1]), [360, 480, 540, 720, 1080].contains(quality),
                  (1...30).contains(pieces[2].count),
                  pieces[2].utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            episodeID = String(pieces[2])
            height = quality
        }
    }

    func resolve(_ request: Request) async throws -> String {
        guard Date() >= cooldownUntil else {
            throw SpiderError.scriptFailed("紅果 SDK 暫時限流，請稍後再試")
        }
        let sdk: OpenhongguoClient
        if let client {
            sdk = client
        } else {
            sdk = try OpenhongguoClient.create(options: ClientOptions(retryAttempts: 1, deviceResets: 0))
            client = sdk
        }
        let result: PlaybackResult
        do {
            result = try await sdk.resolvePlayback(request.episodeID)
        } catch let error as OpenhongguoError {
            if error.code == .anonymousLimited || error.code == .rateLimited {
                cooldownUntil = Date().addingTimeInterval(max(60, Double(error.retryAfterMs) / 1000))
            }
            throw SpiderError.scriptFailed("紅果 SDK 取源失敗（\(error.code.rawValue)）")
        }
        try Task.checkCancellation()
        let model = result.playback
        guard model.episodeId == request.episodeID else {
            throw SpiderError.scriptFailed("紅果 SDK 回傳的分集不符")
        }
        guard model.expiresAt <= 0 || Double(model.expiresAt) > Date().timeIntervalSince1970 + 5 else {
            throw SpiderError.scriptFailed("紅果 SDK 片源已過期")
        }
        guard !model.protected else {
            throw SpiderError.scriptFailed("本集需要受支援的授權播放機制，尚無可直接播放的 SDK 片源")
        }
        // A vertical 1080 x 1920 stream is 1080P, not 1920P.
        let codecs = Set(["h264", "avc", "avc1", "hevc", "h265", "hvc1", "hev1", "bytevc1"])
        let candidates = model.streams.filter {
            !$0.protected && !$0.dash &&
            min($0.width, $0.height) == request.height &&
            codecs.contains($0.codec.lowercased())
        }.sorted { $0.bitrate > $1.bitrate }
        let domains = ["fqnovelvod.com", "qznovelvod.com", "douyinvod.com"]
        func allowed(_ value: String) -> Bool {
            guard let url = URLComponents(string: value), url.scheme?.lowercased() == "https",
                  url.user == nil, url.password == nil, url.port == nil || url.port == 443,
                  let host = url.host?.lowercased() else { return false }
            return domains.contains { host == $0 || host.hasSuffix("." + $0) }
        }
        guard let media = candidates.flatMap({ [$0.url, $0.backupUrl] }).first(where: allowed) else {
            throw SpiderError.scriptFailed("本集暫無可直接播放的 \(request.height)P SDK 片源")
        }
        let response: [String: Any] = [
            "parse": 0, "jx": 0, "playUrl": "", "url": media,
            "header": ["User-Agent": "okhttp/4.12.0"],
            "sourceProvider": "openhongguo", "quality": "\(request.height)P"
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
    }
}
