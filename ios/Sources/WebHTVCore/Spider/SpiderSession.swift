import Foundation

/// One running spider bound to one site. Guarantees `init` runs exactly once before any content
/// call — the ordering `SiteApi` relies on for type-3 — and keeps the site's raw `ext` intact.
public actor SpiderSession {
    public let site: Site
    private let runtime: SpiderRuntime
    /// What `init` receives. Normally the site's raw `ext`, but a rule-engine site points `ext` at a
    /// rule file (`./json/农民影视.json`), which the resolver turns into an absolute URL first.
    private let extend: String
    private var started = false

    public init(site: Site, runtime: SpiderRuntime, extend: String? = nil) {
        self.site = site
        self.runtime = runtime
        self.extend = extend ?? site.rawExtJSON
    }

    private func start() async throws {
        guard !started else { return }
        started = true
        try await runtime.initialize(extend: extend)
    }

    public func home(filter: Bool = true) async throws -> String {
        try await start()
        let home = try await runtime.homeContent(filter: filter)
        // SiteApi.homeContent replaces the list with homeVideoContent's when that returns one.
        let videos = try await runtime.homeVideoContent()
        return videos.isEmpty ? home : merge(home: home, videos: videos)
    }

    public func category(tid: String, page: String, filter: Bool = false,
                         extend: [String: String] = [:]) async throws -> String {
        try await start()
        return try await runtime.categoryContent(tid: tid, page: page, filter: filter, extend: extend)
    }

    public func detail(ids: [String]) async throws -> String {
        try await start()
        return try await runtime.detailContent(ids: ids)
    }

    public func search(key: String, quick: Bool = false, page: String = "1") async throws -> String {
        try await start()
        return try await runtime.searchContent(key: key, quick: quick, page: page)
    }

    public func player(flag: String, id: String, vipFlags: [String] = []) async throws -> String {
        try await start()
        return try await runtime.playerContent(flag: flag, id: id, vipFlags: vipFlags)
    }

    public func destroy() async {
        await runtime.destroy()
        started = false
    }

    private func merge(home: String, videos: String) -> String {
        guard var object = json(home), let list = json(videos)?["list"] else { return home }
        object["list"] = list
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return home }
        return String(decoding: data, as: UTF8.self)
    }

    private func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
