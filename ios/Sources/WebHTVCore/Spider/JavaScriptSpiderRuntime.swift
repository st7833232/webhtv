import Foundation
import JavaScriptCore

/// Runs a CatVod spider that has been reimplemented in JavaScript.
///
/// Each instance owns its own `JSContext` on its own serial queue, so two sites driving the same
/// spider class share no globals, cookies or tokens — the isolation Android gets by constructing one
/// `Spider` per site. The queue is deliberately a plain `DispatchQueue`, not a Swift-concurrency
/// executor, because the host's HTTP is synchronous and blocking a cooperative thread would starve
/// the pool.
public final class JavaScriptSpiderRuntime: SpiderRuntime, @unchecked Sendable {
    private let queue: DispatchQueue
    private let context: JSContext
    private let spider: JSValue
    private let timeout: TimeInterval
    public let cookies: CookieJar

    public init(name: String, script: String, prelude: String, storage: SpiderStorage,
                cookies: CookieJar = CookieJar(), session: URLSession = .webHTV,
                timeout: TimeInterval = 30) throws {
        queue = DispatchQueue(label: "webhtv.spider.\(name)")
        self.timeout = timeout
        self.cookies = cookies
        guard let context = JSContext() else { throw SpiderError.scriptFailed("no JSContext") }
        self.context = context

        var thrown: String?
        context.exceptionHandler = { _, value in thrown = value?.toString() ?? "unknown" }
        CatVodHost.install(into: context, storage: storage, cookies: cookies, session: session)
        context.evaluateScript(prelude)
        if let thrown { throw SpiderError.scriptFailed("host.js: \(thrown)") }

        context.evaluateScript("var module = { exports: {} };")
        context.evaluateScript(script)
        if let thrown { throw SpiderError.scriptFailed("\(name): \(thrown)") }

        guard let exports = context.objectForKeyedSubscript("module")?.objectForKeyedSubscript("exports"),
              exports.isObject,
              // An empty object is the default `module.exports`, so a script that never assigned one
              // would otherwise load as a spider with no methods and fail only at the first call.
              let keys = context.objectForKeyedSubscript("Object")?
                  .invokeMethod("keys", withArguments: [exports])?.toArray(), !keys.isEmpty else {
            throw SpiderError.scriptFailed("\(name) did not assign module.exports")
        }
        spider = exports
    }

    /// Invokes a spider method and returns its result already serialised to text.
    ///
    /// `JSValue` never leaves `queue`: it is not `Sendable`, and Swift 6 rejects sending one across
    /// the continuation. Serialising inside the queue is also what the ABI wanted anyway — every
    /// `Spider.java` method is text in, text out — so the conversion moved here rather than a
    /// wrapper being invented to carry the value out.
    private func text(_ method: String, _ arguments: [Any]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let function = spider.objectForKeyedSubscript(method), !function.isUndefined else {
                    continuation.resume(throwing: SpiderError.methodMissing(method)); return
                }
                var thrown: String?
                context.exceptionHandler = { _, value in thrown = value?.toString() ?? "unknown" }
                // invokeMethod, not function.call: a spider is an object and may keep state on
                // `this` between calls, exactly as the Java original keeps instance fields.
                let result = spider.invokeMethod(method, withArguments: arguments)
                if let thrown {
                    continuation.resume(throwing: SpiderError.scriptFailed("\(method): \(thrown)"))
                    return
                }
                // A spider may return a JSON string, like the Java original, or a plain object,
                // which is far more natural to write in JavaScript. Both arrive as the same JSON.
                guard let result, !result.isUndefined, !result.isNull else {
                    continuation.resume(returning: ""); return
                }
                if result.isString {
                    continuation.resume(returning: result.toString() ?? ""); return
                }
                let encoded = context.objectForKeyedSubscript("JSON")?
                    .invokeMethod("stringify", withArguments: [result])?.toString() ?? ""
                continuation.resume(returning: encoded)
            }
        }
    }

    public func initialize(extend: String) async throws { _ = try await text("init", [extend]) }
    public func homeContent(filter: Bool) async throws -> String { try await text("homeContent", [filter]) }
    public func homeVideoContent() async throws -> String {
        (try? await text("homeVideoContent", [])) ?? ""
    }
    public func categoryContent(tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> String {
        try await text("categoryContent", [tid, page, filter, extend])
    }
    public func detailContent(ids: [String]) async throws -> String { try await text("detailContent", [ids]) }
    public func searchContent(key: String, quick: Bool, page: String) async throws -> String {
        try await text("searchContent", [key, quick, page])
    }
    public func playerContent(flag: String, id: String, vipFlags: [String]) async throws -> String {
        try await text("playerContent", [flag, id, vipFlags])
    }
    public func liveContent(url: String) async throws -> String { (try? await text("liveContent", [url])) ?? "" }
    // `JSON.stringify(true)` is "true", so the text path already carries a boolean out of the
    // context — no second helper is needed to keep JSValue off the continuation.
    public func isVideoFormat(url: String) async throws -> Bool {
        (try? await text("isVideoFormat", [url])) == "true"
    }
    public func manualVideoCheck() async throws -> Bool {
        (try? await text("manualVideoCheck", [])) == "true"
    }
    public func action(_ action: String) async throws -> String { (try? await text("action", [action])) ?? "" }
    public func destroy() async { _ = try? await text("destroy", []) }
}
