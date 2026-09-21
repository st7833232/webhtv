import Foundation
import Python
import WebHTVCore

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

    /// Serialises every call into Python. The GIL would serialise them anyway; doing it here means
    /// one place decides, and a spider's own instance state cannot be re-entered mid-method.
    private let lock = NSLock()

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
        try PythonBoot.ensureStarted()
        _ = try Self.bridge("load", [handle, siteKey, cacheDirectory.path, script])
    }

    // MARK: - SpiderRuntime

    func initialize(extend: String) async throws {
        _ = try call("init", [extend])
    }

    func homeContent(filter: Bool) async throws -> String {
        try call("homeContent", [filter])
    }

    func homeVideoContent() async throws -> String {
        try call("homeVideoContent", [])
    }

    func categoryContent(tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> String {
        try call("categoryContent", [tid, page, filter, extend])
    }

    func detailContent(ids: [String]) async throws -> String {
        try call("detailContent", [ids])
    }

    func searchContent(key: String, quick: Bool, page: String) async throws -> String {
        try call("searchContent", [key, quick, page])
    }

    func playerContent(flag: String, id: String, vipFlags: [String]) async throws -> String {
        try call("playerContent", [flag, id, vipFlags])
    }

    func liveContent(url: String) async throws -> String {
        try call("liveContent", [url])
    }

    func isVideoFormat(url: String) async throws -> Bool {
        try call("isVideoFormat", [url]) == "true"
    }

    func manualVideoCheck() async throws -> Bool {
        try call("manualVideoCheck", []) == "true"
    }

    func action(_ action: String) async throws -> String {
        try call("action", [action])
    }

    func destroy() async {
        _ = try? Self.bridge("unload", [handle])
    }

    // MARK: - The bridge

    private func call(_ name: String, _ arguments: [Any]) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let encoded = try Self.jsonArray(arguments)
        return try Self.bridge("invoke", [handle, name, encoded])
    }

    private static func jsonArray(_ values: [Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    /// Calls one `webhtv_runtime` function with string arguments and returns its string answer.
    ///
    /// Every argument and the result are text, so this never converts a Python container in Swift.
    /// The envelope Python returns carries the failure, which is why a raised exception in a spider
    /// arrives here as a named error rather than as a crash or a silent empty page.
    private static func bridge(_ function: String, _ arguments: [String]) throws -> String {
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
        let detail = object["error"] as? String ?? "unknown Python failure"
        // The whole traceback goes to the log, where it is worth having, and one line goes to the
        // person, who is looking at a screen and not debugging an interpreter.
        print("[spider] python failure\n\(detail)")
        throw SpiderError.scriptFailed(summarised(detail))
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
