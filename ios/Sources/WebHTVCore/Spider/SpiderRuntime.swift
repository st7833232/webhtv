import Foundation

/// The CatVod Spider ABI, ported from `catvod/src/main/java/com/github/catvod/crawler/Spider.java`.
///
/// Every method there is text in, text out — JSON strings, two bools and an `Object[]` for `proxy`.
/// The Android app never inspects a spider's internals, only those strings. That is precisely why
/// this port is possible: a spider reimplemented in JavaScript is indistinguishable, from the app's
/// side, from the original DEX class. Reimplementing this ABI is the goal; executing DEX is not.
public protocol SpiderRuntime: AnyObject, Sendable {
    func initialize(extend: String) async throws
    func homeContent(filter: Bool) async throws -> String
    func homeVideoContent() async throws -> String
    func categoryContent(tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> String
    func detailContent(ids: [String]) async throws -> String
    func searchContent(key: String, quick: Bool, page: String) async throws -> String
    func playerContent(flag: String, id: String, vipFlags: [String]) async throws -> String
    func liveContent(url: String) async throws -> String
    func isVideoFormat(url: String) async throws -> Bool
    func manualVideoCheck() async throws -> Bool
    func proxy(params: [String: String]) async throws -> [String]
    func action(_ action: String) async throws -> String
    func destroy() async
}

/// Matches `Spider.java`, where every method has a do-nothing body a subclass may override.
public extension SpiderRuntime {
    func homeVideoContent() async throws -> String { "" }
    func liveContent(url: String) async throws -> String { "" }
    func isVideoFormat(url: String) async throws -> Bool { false }
    func manualVideoCheck() async throws -> Bool { false }
    func proxy(params: [String: String]) async throws -> [String] { [] }
    func action(_ action: String) async throws -> String { "" }
    func destroy() async {}
}

public enum SpiderError: Error, Equatable, LocalizedError {
    case notRegistered(String)
    case scriptFailed(String)
    case methodMissing(String)

    public var errorDescription: String? {
        switch self {
        case .notRegistered(let key): "No spider registered for \(key)"
        case .scriptFailed(let message): "Spider script error: \(message)"
        case .methodMissing(let name): "Spider does not implement \(name)"
        }
    }
}
