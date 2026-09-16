import Foundation
import JavaScriptCore

/// `host.local` — the key/value store drpy spiders already expect, namespaced per site so two sites
/// running the same spider class cannot read each other's tokens.
enum StorageHost {
    static func install(into context: JSContext, storage: SpiderStorage) {
        let get: @convention(block) (String) -> String = { storage.get($0) }
        let set: @convention(block) (String, String) -> Void = { storage.set($0, $1) }
        let remove: @convention(block) (String) -> Void = { storage.remove($0) }
        let store = JSValue(newObjectIn: context)
        store?.setObject(get, forKeyedSubscript: "get" as NSString)
        store?.setObject(set, forKeyedSubscript: "set" as NSString)
        store?.setObject(remove, forKeyedSubscript: "del" as NSString)
        context.setObject(store, forKeyedSubscript: "__store" as NSString)
    }
}

public final class SpiderStorage: @unchecked Sendable {
    private let prefix: String
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(siteKey: String, defaults: UserDefaults = .standard) {
        prefix = "spider_\(siteKey)_"
        self.defaults = defaults
    }

    public func get(_ key: String) -> String { lock.withLock { defaults.string(forKey: prefix + key) ?? "" } }
    public func set(_ key: String, _ value: String) { lock.withLock { defaults.set(value, forKey: prefix + key) } }
    public func remove(_ key: String) { lock.withLock { defaults.removeObject(forKey: prefix + key) } }
}
