import Foundation

/// W-315 A4 (docs/W-312-ios-search-improvements.md §5): the keywords searched lately, newest first, at most
/// twelve, kept in this device's `UserDefaults` only — never sent anywhere, so it outlives a relaunch and goes
/// with 初始化 like every other preference.
public struct SearchHistory {
    public static let limit = 12
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "webhtv.searchHistory") {
        self.defaults = defaults
        self.key = key
    }

    public var entries: [String] { defaults.stringArray(forKey: key) ?? [] }

    /// Puts the keyword first, without repeating it, and drops the oldest beyond `limit`. A blank one is ignored.
    @discardableResult public func add(_ keyword: String) -> [String] {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return entries }
        return save([keyword] + entries.filter { $0 != keyword })
    }

    @discardableResult public func remove(_ keyword: String) -> [String] {
        save(entries.filter { $0 != keyword })
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }

    private func save(_ list: [String]) -> [String] {
        let list = Array(list.prefix(Self.limit))
        defaults.set(list, forKey: key)
        return list
    }
}
