import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebHTVCore
import WebKit

private let appSurface = Color(red: 0.075, green: 0.14, blue: 0.16)
private let appAccent = Color.white
private let selectedSiteKey = "selectedSiteKey"
private let configSourceURLKey = "configSourceURL"
private let configUpdatedAtKey = "configUpdatedAt"

@main
struct WebHTVApp: App {
    init() {
        // IOS-POC-7F: start the interpreter and say what came up. Debug-only for now — the Spider
        // runtime will own initialisation once it exists, and nothing in a Release build needs
        // CPython until it does.
        #if DEBUG
        print("[python] boot \(PythonBoot.start())")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ConfigView()
                .preferredColorScheme(.dark)
                .tint(appAccent)
        }
    }
}

private struct ConfigView: View {
    @State private var sites = [Site]()
    @State private var selectedSiteID: Site.ID?
    @State private var selectedTab = 0
    @State private var error: String?
    @State private var importing = false
    /// The remote-URL prompt, which the empty state needs as much as the settings page does.
    @State private var askingRemote = false
    @State private var remoteText = ""

    @State private var source = ConfigSource.importedFile
    @State private var updatedAt: Date?
    @State private var refreshing = false
    /// What the compatibility pack is doing, shown in settings so a refused pack is visible rather
    /// than silent. Empty means "bundled scripts", which is the normal state until a pack is served.
    @State private var packStatus = ""

    var body: some View {
        Group {
            if sites.isEmpty {
                NavigationStack {
                    ContentUnavailableView(
                        "尚未載入設定",
                        systemImage: "play.rectangle.on.rectangle",
                        description: Text("匯入 wang-movie.json，或直接貼上它的 HTTPS 網址。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .appWallpaper()
                    .navigationTitle("WebHTV")
                    // Both ways in, because the settings page that offers the URL lives inside the
                    // tab bar, and the tab bar only exists once a configuration has loaded. A fresh
                    // install could otherwise only ever import a file — found on the first
                    // real-device run, IOS-POC-8A.
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("使用網址") { askingRemote = true }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("匯入設定") { importing = true }
                        }
                    }
                    .appNavigationBar()
                }
            } else {
                TabView(selection: $selectedTab) {
                    HomeView(sites: sites, selectedSiteID: $selectedSiteID, source: source)
                        .tag(0)
                        .tabItem { Label("首頁", systemImage: "play.rectangle.fill") }

                    NavigationStack {
                        HistoryView(sites: sites, source: source)
                    }
                    .tag(1)
                    .tabItem { Label("記錄", systemImage: "clock.arrow.circlepath") }

                    NavigationStack {
                        SettingsView(
                            sites: sites,
                            selectedSiteID: $selectedSiteID,
                            source: source,
                            updatedAt: updatedAt,
                            refreshing: refreshing,
                            packStatus: packStatus,
                            onImport: { importing = true },
                            onUseRemote: { text in useRemote(text) },
                            onRefresh: { Task { await refreshRemote() } },
                            onOpenHome: { selectedTab = 0 }
                        )
                    }
                    .tag(2)
                    .tabItem { Label("設定", systemImage: "gearshape.fill") }
                }
                .toolbarBackground(.hidden, for: .tabBar)
                .appWallpaper()
            }
        }
        .appWallpaper()
        .task {
            restore()
            // The cached pack is adopted before anything is fetched, so an offline launch runs on
            // the last known good scripts rather than waiting for the network.
            await adoptCachedSpiderPack()
            // Every launch re-fetches a remote configuration, so the app opens on the current one
            // rather than on whatever happened to be cached.
            await refreshRemote(quiet: true)
            await refreshSpiderPack()
        }
        .onChange(of: selectedSiteID) { _, id in
            UserDefaults.standard.set(id, forKey: selectedSiteKey)
        }
        .alert("從網址載入設定", isPresented: $askingRemote) {
            TextField("https://…/wang-movie.json", text: $remoteText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("載入") { useRemote(remoteText) }
            Button("取消", role: .cancel) {}
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): load(url)
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        .alert("無法載入", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("確定", role: .cancel) {}
        } message: {
            Text(error ?? "未知錯誤")
        }
    }

    private func load(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            error = "無法取得所選檔案的存取權。"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            try adopt(data, config: try ConfigLoader.validate(data), from: .importedFile)
            selectedTab = 0
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// `showHome` is false for a refresh: re-fetching the same source should not yank the user out
    /// of Settings, while pointing the app at a new source should show what it loaded.
    /// `reportFailure` is false only on launch — see `refreshRemote(quiet:)`.
    /// Returns whether the configuration was replaced, so the launch path can decide to retry.
    @discardableResult
    private func load(remote url: URL, showHome: Bool = true, reportFailure: Bool = true) async -> Bool {
        refreshing = true
        defer { refreshing = false }
        do {
            let (data, config) = try await ConfigLoader.fetch(from: url)
            try adopt(data, config: config, from: .remote(url))
            if showHome { selectedTab = 0 }
            return true
        } catch {
            // The cached configuration and the live source list are untouched by a failed fetch.
            if reportFailure { self.error = "遠端設定載入失敗：\(error.localizedDescription)" }
            return false
        }
    }

    /// Re-fetches the current remote source. `quiet` is used on launch: `restore()` has already put
    /// the last known good configuration on screen and the 上次更新 row shows how old it is, so an
    /// alert on every offline launch would add nothing. A manual refresh still reports failures.
    ///
    /// The launch attempt also retries. A launch can land before the network is ready, and the host
    /// itself can blip — during this stage's testing the Raw host refused connections for about a
    /// minute and then recovered on its own. A manual refresh does not retry, because the user is
    /// watching and can simply tap again rather than wait through the gaps.
    /// Parsing lives here rather than in the dialog because this is where the error surface is;
    /// silently doing nothing was the previous behaviour and gave the user no idea why.
    private func useRemote(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https", url.host?.isEmpty == false else {
            error = "請輸入 http:// 或 https:// 開頭的完整設定網址。"
            return
        }
        Task { await load(remote: url) }
    }

    private func refreshRemote(quiet: Bool = false) async {
        guard case .remote(let url) = source else { return }
        let gaps: [Duration] = quiet ? [.seconds(2), .seconds(5), .seconds(15)] : []
        for gap in gaps {
            if await load(remote: url, showHome: false, reportFailure: false) { return }
            // Cancelled when the view goes away, which ends the retry with it.
            guard (try? await Task.sleep(for: gap)) != nil else { return }
        }
        await load(remote: url, showHome: false, reportFailure: !quiet)
    }

    /// Reads whatever pack is already on disk. Verification happens inside the store, so a cache
    /// that no longer matches its manifest is simply not adopted.
    private func adoptCachedSpiderPack() async {
        guard let pack = await SpiderPackStore.shared.installedPack() else { return }
        packStatus = Self.describe(pack)
        rebuildSites()
    }

    /// Fetches a pack in the background. A failure is deliberately quiet in the UI beyond the
    /// status line: the app keeps running on the pack or the bundled scripts it already had.
    private func refreshSpiderPack() async {
        guard let url = SpiderPackStore.url(for: source) else { return }
        do {
            let pack = try await SpiderPackStore.shared.refresh(from: url)
            packStatus = Self.describe(pack)
            await SpiderSessionStore.shared.reset()
            rebuildSites()
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let current = await SpiderPackStore.shared.installedPack()
            packStatus = current.map { "\(Self.describe($0))（更新失敗：\(reason)）" }
                ?? "內建腳本（更新失敗：\(reason)）"
        }
    }

    private static func describe(_ pack: SpiderPack) -> String {
        let skipped = pack.rejected.isEmpty ? "" : "，略過 \(pack.rejected.count)："
            + pack.rejected.map { "\($0.className)（\($0.reason)）" }.joined(separator: "、")
        return "相容性套件 \(pack.version)，\(pack.scripts.count) 支腳本\(skipped)"
    }

    /// A pack can add or replace a driveable class, so the listed sites are recomputed from the
    /// configuration already on disk rather than re-fetched.
    private func rebuildSites() {
        guard let url = try? configURL(), let data = try? Data(contentsOf: url),
              let config = try? ConfigLoader.validate(data) else { return }
        sites = config.drivableSites(resolvedBy: CSPSourceResolver(source: source))
        selectedSiteID = sites.first { $0.id == selectedSiteID }?.id ?? selectedSiteID ?? sites.first?.id
    }

    /// Write, then publish. Callers validate first and hand the result in, so nothing that failed
    /// validation reaches the cached file — that is what makes a failed refresh safe.
    private func adopt(_ data: Data, config: WebHTVConfig, from source: ConfigSource) throws {
        let loaded = config.drivableSites(resolvedBy: CSPSourceResolver(source: source))
        try data.write(to: configURL(), options: .atomic)
        let now = Date()
        UserDefaults.standard.set(source.baseURL?.absoluteString, forKey: configSourceURLKey)
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: configUpdatedAtKey)
        self.source = source
        updatedAt = now
        sites = loaded
        // Reclaim the spider sessions this configuration orphaned. Correctness does not depend on
        // this landing first — `SpiderSessionStore` keys on the site's `ext`, so a redefined site
        // misses the cache regardless.
        Task { await SpiderSessionStore.shared.reset() }
        selectedSiteID = loaded.first { $0.id == selectedSiteID }?.id ?? loaded.first?.id
    }

    private func restore() {
        var restored = ConfigSource.importedFile
        if let stored = UserDefaults.standard.string(forKey: configSourceURLKey), let url = URL(string: stored) {
            restored = .remote(url)
            source = restored
        }
        let stamp = UserDefaults.standard.double(forKey: configUpdatedAtKey)
        if stamp > 0 { updatedAt = Date(timeIntervalSince1970: stamp) }
        do {
            let url = try configURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            // Read the local value, not the `@State` just written: a spider's relative `ext` is
            // resolved against it, and resolving against the wrong base silently breaks those sites.
            let loaded = try ConfigLoader.validate(Data(contentsOf: url))
                .drivableSites(resolvedBy: CSPSourceResolver(source: restored))
            let key = UserDefaults.standard.string(forKey: selectedSiteKey)
            sites = loaded
            selectedSiteID = loaded.first { $0.id == key }?.id ?? loaded.first?.id
        } catch {
            self.error = "已保存的設定無法載入：\(error.localizedDescription)。請重新匯入。"
        }
    }

    private func configURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("wang-movie.json")
    }
}

private struct HomeView: View {
    let sites: [Site]
    @Binding var selectedSiteID: Site.ID?
    /// Needed only so a rule-engine spider can resolve a relative `ext` such as
    /// `./json/农民影视.json` against the configuration's own directory.
    let source: ConfigSource

    @State private var picking = false

    private var selectedSite: Site {
        sites.first { $0.id == selectedSiteID } ?? sites[0]
    }

    /// The source list, opened on the source in use. `scrollTo` runs from `onAppear` on the list
    /// itself, which is after the rows exist — doing it on the sheet would scroll nothing.
    private var sourcePicker: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(sites) { site in
                    Button {
                        selectedSiteID = site.id
                        picking = false
                    } label: {
                        HStack {
                            Text(site.name.displayName).foregroundStyle(.primary)
                            Spacer()
                            if site.id == selectedSite.id {
                                Image(systemName: "checkmark").foregroundStyle(appAccent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .id(site.id)
                }
                .onAppear { proxy.scrollTo(selectedSite.id, anchor: .center) }
            }
            .navigationTitle("內容來源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("關閉") { picking = false }
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            CMSView(site: selectedSite, source: source)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        // A sheet rather than a `Menu`: a menu is a `UIMenu` and cannot be scrolled
                        // to an item, so with 67 sources it always opened at the first one and the
                        // source in use was somewhere off screen.
                        Button {
                            picking = true
                        } label: {
                            HStack(spacing: 8) {
                                Text(selectedSite.name.displayName).font(.headline)
                                Image(systemName: "chevron.down").font(.caption2)
                            }
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(minHeight: 44)
                        }
                        .accessibilityLabel("切換內容來源，目前為 \(selectedSite.name)")
                    }
                }
                .sheet(isPresented: $picking) { sourcePicker }
        }
        // The identity sits on the whole `NavigationStack`, not on `CMSView` inside it, and that is
        // what lets the search field keep hiding on scroll.
        //
        // The field's hidden state belongs to the navigation bar rather than to the grid, and a bar
        // that outlives the switch keeps the collapse it learned from the listing the user just
        // scrolled — so the field was simply gone, and only an over-scroll brought it back. Three
        // ways of making that bar change its mind were measured at IOS-POC-8F and **none worked**:
        // hoisting `.searchable` above the grid's `.id`, resetting the listing in place so the
        // scroll view was never replaced, and scrolling the old listing to the top before swapping
        // it. Rebuilding the stack sidesteps all of it, because a new stack is a new navigation bar
        // with nothing to remember. Do not repeat those three.
        .id(selectedSite.id)
    }
}

private struct CMSView: View {
    let site: Site
    let source: ConfigSource
    var initialQuery: String?
    @State private var items = [Vod]()
    @State private var groups = [CategoryGroup]()
    @State private var selectedCategory: String?
    /// Filter rows for the listed category, and the value chosen in each, keyed by the row's own
    /// `key` so it can be handed straight to the source as `extend`.
    @State private var filterRows = [String: [CMSFilter]]()
    @State private var chosenFilters = [String: String]()
    /// Parent categories whose child row the user has folded away, by group id. Empty means every
    /// child row is shown, which is how it behaved before.
    @State private var collapsedGroups = Set<String>()
    /// Whether the grid is scrolled to the very top, so the Top button can stay out of the way
    /// until it is useful.
    @State private var atTop = true

    private static let topAnchor = "grid-top"
    @State private var searching = false
    @State private var query = ""
    @State private var page = 1
    @State private var canLoadMore = true
    @State private var loadingMore = false
    @State private var loading = false
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 12)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Just an anchor for `scrollTo`. Whether we are at the top is decided by the
                // first grid cell below, because `LazyVGrid` really does load and unload its cells
                // — a plain ScrollView does not, which is why a marker's own onDisappear never fires.
                Color.clear
                    .frame(height: 0)
                    .id(Self.topAnchor)

                // The category and filter rows scroll away with the grid rather than pinning to
                // the top: they cost four rows of height on a phone, and the Top button below is
                // what brings them back.
                if !groups.isEmpty {
                    categoryRow(parentChips)
                    if showsChildRow, let children = activeGroup?.children, !children.isEmpty {
                        categoryRow(ForEach(children) { chip($0.name, id: $0.id) })
                    }
                    // Filter rows belong to a category, so they only appear once one is listed, and
                    // only for a source whose API publishes them at all.
                    ForEach(activeFilterRows) { row in
                        filterRow(row)
                    }
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items) { vod in
                        NavigationLink {
                            VodView(site: site, summary: vod, source: source)
                        } label: {
                            VodCard(vod: vod)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if vod.id == items.first?.id { atTop = true }
                            if vod.id == items.last?.id { Task { await loadMore() } }
                        }
                        .onDisappear { if vod.id == items.first?.id { atTop = false } }
                    }
                }
                .padding(12)
                if loadingMore { ProgressView().padding(.bottom, 16) }
            }
            .overlay(alignment: .bottomTrailing) { topButton(proxy) }
            // Refetches whatever is on screen — the search results while searching, otherwise the
            // listed category, or the home listing when none is picked. `loadMore`'s paging state
            // is reset by `load` itself, so a refresh also drops back to page one.
            .refreshable {
                if searching, !query.isEmpty { await load(search: query) }
                else { await load(category: selectedCategory) }
            }
        }
        .appWallpaper()
        .overlay {
            if loading && items.isEmpty {
                ProgressView("載入中")
            } else if let error, items.isEmpty {
                ContentUnavailableView("載入失敗", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if items.isEmpty {
                // A source can answer normally with nothing; say so instead of showing a blank screen.
                ContentUnavailableView("沒有內容", systemImage: "tray", description: Text("這個來源或分類沒有回傳任何項目。"))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // Plain `.searchable`, so the field hides on scroll the way it always did. What keeps it
        // from disappearing across a source switch is the `.id` on `HomeView`'s `NavigationStack`,
        // not anything here (IOS-POC-8F).
        .searchable(text: $query, prompt: "搜尋影片")
        .onSubmit(of: .search) { searching = true; Task { await load(search: query) } }
        .task {
            guard items.isEmpty else { return }
            guard let initialQuery, !initialQuery.isEmpty else { return await load() }
            query = initialQuery
            searching = true
            await load(search: initialQuery)
        }
        // Dropping this to give the bar a material behind the pinned search field was tried at
        // IOS-POC-8E and changed nothing on screen: iOS 26 draws this bar as per-control glass, not
        // as a full-width background, so there is no material to opt into. Scrolling content shows
        // through the search field either way. Do not repeat it.
        .appNavigationBar()
    }

    /// The group whose parent or child is currently listed, so the parent row can highlight it.
    private var activeGroup: CategoryGroup? {
        groups.first { $0.id == selectedCategory || $0.children.contains { $0.id == selectedCategory } }
    }

    @ViewBuilder private var parentChips: some View {
        // IOS-POC-8I: no synthetic 全部. The row is the source's own category list and nothing else.
        // csp_JPianAmns offers exactly five, and the app's extra chip re-listed the first of them
        // anyway, because an empty home falls back to the first browsable category.
        ForEach(groups) { group in
            parentChip(group)
        }
    }

    /// The rows for whatever category is listed. A child category inherits its parent's rows,
    /// because the API keys them by the parent's `type_id`.
    private var activeFilterRows: [CMSFilter] {
        guard !searching else { return [] }
        if let selectedCategory, let rows = filterRows[selectedCategory] { return rows }
        if let parent = activeGroup?.parent.id, let rows = filterRows[parent] { return rows }
        return []
    }

    private func filterRow(_ row: CMSFilter) -> some View {
        categoryRow(
            HStack(spacing: 8) {
                Text(row.name)
                    .font(.caption).bold()
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(minWidth: 34, alignment: .leading)
                ForEach(row.options) { option in
                    filterChip(row: row.key, option: option)
                }
            }
        )
    }

    private func filterChip(row: String, option: CMSFilter.Option) -> some View {
        // An unset row means the empty value, which is what "全部" carries.
        let isActive = (chosenFilters[row] ?? "") == option.value
        return Button {
            if option.value.isEmpty { chosenFilters.removeValue(forKey: row) }
            else { chosenFilters[row] = option.value }
            Task { await load(category: selectedCategory) }
        } label: {
            Text(option.name)
                .font(.footnote)
                .foregroundStyle(isActive ? appSurface : .white)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(isActive ? .white : appSurface.opacity(0.85), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The child row is shown unless this group was folded away.
    private var showsChildRow: Bool {
        guard let group = activeGroup else { return false }
        return !collapsedGroups.contains(group.id)
    }

    @ViewBuilder private func topButton(_ proxy: ScrollViewProxy) -> some View {
        if !atTop {
            Button {
                withAnimation { proxy.scrollTo(Self.topAnchor, anchor: .top) }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(appSurface.opacity(0.9), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .padding(.bottom, 24)
            .accessibilityLabel("回到頂部")
        }
    }

    /// A parent with children is also a disclosure control: tapping the one already listed folds
    /// its child row away, and tapping a different one switches to it and unfolds it.
    private func parentChip(_ group: CategoryGroup) -> some View {
        let isActive = activeGroup?.id == group.id
        let hasChildren = !group.children.isEmpty
        let isCollapsed = collapsedGroups.contains(group.id)
        return Button {
            searching = false
            if isActive && hasChildren {
                if isCollapsed { collapsedGroups.remove(group.id) } else { collapsedGroups.insert(group.id) }
                return
            }
            collapsedGroups.remove(group.id)
            let target = group.children.first?.id ?? group.parent.id
            selectCategory(target)
            Task { await load(category: target) }
        } label: {
            HStack(spacing: 4) {
                Text(group.parent.name)
                if hasChildren {
                    // Points down when the children are hidden, up when they are showing.
                    Image(systemName: isActive && !isCollapsed ? "chevron.up" : "chevron.down")
                        .font(.caption2.bold())
                }
            }
            .font(.subheadline.weight(isActive ? .bold : .regular))
            .foregroundStyle(isActive ? appSurface : .white)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(isActive ? .white : appSurface.opacity(0.85), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func categoryRow<Content: View>(_ content: Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    /// `active` overrides the default match so a parent chip can stay lit while a child is listed.
    /// Choosing a different category drops the filters chosen for the previous one: their rows
    /// belong to that category, and sending 剧情 to a category that has no such class empties the
    /// listing for no visible reason.
    private func selectCategory(_ id: String?) {
        guard selectedCategory != id else { return }
        chosenFilters.removeAll()
        selectedCategory = id
    }

    /// Plain chip for the 全部 entry and the child row. A parent is `parentChip`, which also folds
    /// its children away.
    private func chip(_ title: String, id: String?) -> some View {
        let isActive = !searching && selectedCategory == id
        return Button(title) {
            searching = false
            selectCategory(id)
            Task { await load(category: id) }
        }
        .buttonStyle(.plain)
        .font(.subheadline.weight(isActive ? .bold : .regular))
        .foregroundStyle(isActive ? appSurface : .white)
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(isActive ? .white : appSurface.opacity(0.85), in: Capsule())
    }

    private func loadMore() async {
        guard canLoadMore, !loadingMore, !loading else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let next = page + 1
            let response = try await listing(page: next)
            let merged = items.merging(newTitlesFrom: response.list)
            guard merged.count > items.count else { canLoadMore = false; return }
            items = merged
            page = next
        } catch {
            // Keep what is already on screen and stop rather than retrying a failing page on every scroll.
            canLoadMore = false
        }
    }

    private func listing(page: Int) async throws -> CMSResponse {
        let client = try await SourceClient.make(site: site, resolver: CSPSourceResolver(source: source))
        if searching, !query.isEmpty { return try await client.search(query, page: page) }
        if let selectedCategory {
            return try await client.category(id: selectedCategory, page: page, extend: chosenFilters)
        }
        return try await client.home(page: page)
    }

    private func load(search: String? = nil, category: String? = nil) async {
        loading = true
        error = nil
        page = 1
        canLoadMore = true
        defer { loading = false }
        do {
            let client = try await SourceClient.make(site: site, resolver: CSPSourceResolver(source: source))
            let response = if let search, !search.isEmpty {
                try await client.search(search)
            } else if let category {
                try await client.category(id: category, extend: chosenFilters)
            } else {
                try await client.home()
            }
            items = response.list
            // A category listing usually omits `class`, so keep the set the home call established.
            if !response.classes.isEmpty { groups = response.categoryGroups }
            // Same for the filter rows: only the home call carries them.
            if !response.filters.isEmpty { filterRows = response.filters }
            // A type-4 home already lists its first category, and a spider home falls back to the
            // same behaviour because most spiders return no home list at all — highlight that chip.
            if site.type == 4 || site.isCSPSpider, selectedCategory == nil {
                selectedCategory = response.firstListableCategory?.id
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct VodCard: View {
    let vod: Vod

    var body: some View {
        // The empty container fixes the cell to one poster ratio and the artwork fills it as an
        // overlay, so a landscape image is cropped instead of stretching its cell past the column.
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                AsyncImage(url: URL(string: vod.picture)) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default:
                        ZStack {
                            appSurface
                            Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .clipped()
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
                .frame(height: 86)
                .overlay(alignment: .bottomLeading) {
                    Text(vod.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(10)
                }
        }
        .overlay(alignment: .topTrailing) {
            if !vod.remarks.isEmpty {
                Text(vod.remarks)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(8)
            }
        }
        .clipShape(.rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsView: View {
    let sites: [Site]
    @Binding var selectedSiteID: Site.ID?
    let source: ConfigSource
    let updatedAt: Date?
    let refreshing: Bool
    let packStatus: String
    let onImport: () -> Void
    let onUseRemote: (String) -> Void
    let onRefresh: () -> Void
    let onOpenHome: () -> Void

    @State private var askingRemote = false
    @State private var remoteText = ""

    var body: some View {
        List {
            Section("內容來源") {
                ForEach(sites) { site in
                    Button {
                        selectedSiteID = site.id
                        onOpenHome()
                    } label: {
                        HStack {
                            Text(site.name.displayName).foregroundStyle(.primary)
                            Spacer()
                            if site.id == selectedSiteID {
                                Image(systemName: "checkmark").foregroundStyle(appAccent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            }

            if let site = sites.first(where: { $0.id == selectedSiteID }) ?? sites.first {
                Section("開發者") {
                    NavigationLink("WebHome 橋接驗證") { WebHomeView(site: site, sites: sites, source: source) }
                }
            }

            sourceSection
        }
        .alert("從網址載入設定", isPresented: $askingRemote) {
            TextField("https://…/wang-movie.json", text: $remoteText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("載入") { onUseRemote(remoteText) }
            Button("取消", role: .cancel) {}
        }
        .scrollContentBackground(.hidden)
        .appWallpaper()
        .listRowBackground(Color.black.opacity(0.22))
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .appNavigationBar()
    }
}

private extension SettingsView {
    @ViewBuilder var sourceSection: some View {
        Section {
            LabeledContent("來源", value: sourceLabel)
            LabeledContent("上次更新", value: updatedLabel)
            LabeledContent("Spider 腳本", value: packStatus.isEmpty ? "內建" : packStatus)
            Button("從網址載入設定") {
                remoteText = source.baseURL?.absoluteString ?? ""
                askingRemote = true
            }
            if isRemote {
                Button(refreshing ? "更新中…" : "重新整理", action: onRefresh).disabled(refreshing)
            }
            Button("匯入本機檔案", action: onImport)
        } header: {
            Text("設定來源")
        } footer: {
            Text("目前支援 \(sites.count) 個來源：type-0／type-1／type-4 CMS，以及已移植的 csp_* Spider。遠端更新失敗時會保留上一份可用設定。Spider 腳本可由設定檔旁的 ./spiders/manifest.json 熱更新，驗過 SHA-256 才會採用。")
        }
    }

    var isRemote: Bool {
        if case .remote = source { return true }
        return false
    }

    var sourceLabel: String {
        switch source {
        case .importedFile: "本機匯入檔案"
        case .remote(let url): url.absoluteString
        }
    }

    var updatedLabel: String {
        guard let updatedAt else { return "尚未記錄" }
        return updatedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct VodView: View {
    let site: Site
    let summary: Vod
    let source: ConfigSource
    @State private var detail: Vod?
    @State private var pendingPlayback: Playback?
    @State private var error: String?
    @State private var playbackError: String?
    @State private var resolving = false
    /// What was watched last, if anything. Marks the episode in the grid (R4) and supplies the
    /// remembered quality when the picker opens (R6).
    @State private var watched: WatchHistory?
    /// Which 100-episode block each flag is showing. Keyed by flag name because the lines
    /// carry different episode counts.
    @State private var episodeChunk: [String: Int] = [:]

    var body: some View {
        ScrollView {
            if let detail {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 16) {
                        VodPoster(vod: summary)
                            .frame(width: 112, height: 168)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(summary.name).font(.title2.weight(.bold))
                            if !summary.remarks.isEmpty {
                                Text(summary.remarks).foregroundStyle(.secondary)
                            }
                            Text(site.name.displayName)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(appSurface, in: Capsule())
                        }
                    }

                    ForEach(detail.flags, id: \.name) { flag in
                        let blocks = episodeBlocks(of: flag)
                        // Clamped: a stale index survives a reload that returned fewer episodes.
                        let chunk = min(episodeChunk[flag.name] ?? defaultChunk(for: flag), blocks.count - 1)
                        VStack(alignment: .leading, spacing: 12) {
                            Text(flag.name).font(.headline)
                            // A few hundred buttons in one grid is unnavigable. Offer the 100-episode
                            // blocks the numbering already follows, and only when there is more than one.
                            if blocks.count > 1 {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(Array(blocks.indices), id: \.self) { index in
                                            Button(blockLabel(flag, blocks[index])) {
                                                episodeChunk[flag.name] = index
                                            }
                                            .buttonStyle(.bordered)
                                            .tint(index == chunk ? .accentColor : nil)
                                            .fontWeight(index == chunk ? .bold : nil)
                                            .frame(minHeight: 44)
                                        }
                                    }
                                }
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                                ForEach(Array(flag.episodes.enumerated())[blocks[max(0, chunk)]], id: \.offset) { _, episode in
                                    let lastWatched = watched?.vodFlag == flag.name
                                        && watched?.episodeUrl == episode.url
                                    Button(episode.name) {
                                        Task { await play(episode, flag: flag.name) }
                                    }
                                    .buttonStyle(.bordered)
                                    // Marks where the viewer left off. Android puts the same cue on
                                    // the episode its History points at.
                                    .tint(lastWatched ? .accentColor : nil)
                                    .fontWeight(lastWatched ? .bold : nil)
                                    .frame(minHeight: 44)
                                    .disabled(episode.mediaURL == nil || resolving)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            } else if let error {
                ContentUnavailableView("詳情載入失敗", systemImage: "exclamationmark.triangle", description: Text(error))
                    .padding(.top, 80)
            } else {
                ProgressView("載入詳情")
                    .padding(.top, 80)
            }
        }
        .appWallpaper()
        .navigationTitle(summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .appNavigationBar()
        .task {
            watched = await WatchHistoryStore.shared.record(forKey: historyKey)
            do {
                let client = try await SourceClient.make(site: site, resolver: CSPSourceResolver(source: source))
                detail = try await client.detail(id: summary.id)
            } catch { self.error = error.localizedDescription }
        }
        .sheet(item: $pendingPlayback, onDismiss: { Task { watched = await WatchHistoryStore.shared.record(forKey: historyKey) } }) {
            PlayerPickerView(mediaURL: $0.url, headers: $0.headers, title: $0.title, artwork: $0.artwork,
                             qualities: $0.qualities, position: $0.position, defaultIndex: $0.defaultIndex,
                             preferredQuality: $0.preferredQuality, history: $0.history)
        }
        .alert("無法播放", isPresented: Binding(get: { playbackError != nil }, set: { if !$0 { playbackError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(playbackError ?? "")
        }
    }

    private var historyKey: String { WatchHistory.key(siteID: site.id, vodId: summary.id) }

    /// Episodes per block in the picker. Sources number long dramas in the hundreds, and 100 is
    /// the step their own numbering follows.
    private let episodeChunkSize = 100

    /// The number a source printed in an episode's name. Entries merge episodes (`第1-8集`) and
    /// carry stray punctuation (`-第98集`), so this takes the first run of digits and nothing else.
    private static func leadingNumber(_ name: String) -> Int? {
        var digits = ""
        for character in name {
            if character.isNumber { digits.append(character) }
            else if !digits.isEmpty { break }
        }
        return Int(digits)
    }

    /// The blocks as index ranges, split on the **printed episode number** rather than on position.
    /// A merged entry counts as the episode it starts at, so the block labelled 1-100 ends at 第100集
    /// instead of running to the 100th entry — which on a line holding `第1-8集` would be 第109集.
    /// An entry with no number joins the block before it, and a line that prints no numbers at all
    /// falls back to fixed blocks of `episodeChunkSize` entries.
    private func episodeBlocks(of flag: Flag) -> [Range<Int>] {
        var bounds = [0]
        var current = 0
        var sawNumber = false
        for (index, episode) in flag.episodes.enumerated() {
            guard let number = Self.leadingNumber(episode.name) else { continue }
            sawNumber = true
            let block = max(0, (number - 1) / episodeChunkSize)
            if block > current { bounds.append(index); current = block }
        }
        if !sawNumber {
            bounds = Array(stride(from: 0, to: max(flag.episodes.count, 1), by: episodeChunkSize))
        }
        return zip(bounds, Array(bounds.dropFirst()) + [flag.episodes.count]).map { $0..<$1 }
    }

    /// Names a block by the episode numbers actually inside it, so the chip cannot disagree with
    /// the grid under it. Falls back to the entry positions when the line prints no numbers.
    private func blockLabel(_ flag: Flag, _ range: Range<Int>) -> String {
        let numbers = flag.episodes[range].compactMap { Self.leadingNumber($0.name) }
        guard let first = numbers.first, let last = numbers.max() else {
            return "\(range.lowerBound + 1)-\(range.upperBound)"
        }
        return first == last ? "\(first)" : "\(first)-\(last)"
    }

    /// Opens on the block holding the remembered episode, so resuming episode 380 of a 600-episode
    /// drama does not start at the first block.
    private func defaultChunk(for flag: Flag) -> Int {
        guard watched?.vodFlag == flag.name,
              let index = flag.episodes.firstIndex(where: { $0.url == watched?.episodeUrl })
        else { return 0 }
        return episodeBlocks(of: flag).firstIndex { $0.contains(index) } ?? 0
    }

    private func play(_ episode: Episode, flag: String) async {
        resolving = true
        defer { resolving = false }
        do {
            let client = try await SourceClient.make(site: site, resolver: CSPSourceResolver(source: source))
            guard let target = try await client.playbackURL(for: episode, flag: flag) else {
                playbackError = "這一集沒有可播放的網址。"
                return
            }
            // The identity the watch history is keyed on. `Site.id` rather than `site.key`, because
            // this configuration has four duplicate keys (IOS-POC-5L) and two providers must not
            // share one record.
            let record = WatchHistory(
                key: historyKey, siteKey: site.key, siteName: site.name, vodId: summary.id,
                vodName: summary.name, vodPic: summary.picture,
                vodFlag: flag, vodRemarks: episode.name, episodeUrl: episode.url)
            pendingPlayback = Playback(url: target.url, headers: target.headers,
                                       title: "\(summary.name) \(episode.name)", artwork: summary.picture,
                                       qualities: target.qualities, position: target.position,
                                       defaultIndex: target.defaultIndex,
                                       preferredQuality: watched?.quality ?? "", history: record)
        } catch {
            playbackError = error.localizedDescription
        }
    }
}

/// What has been watched, newest first. Android's equivalent is the History screen behind the same
/// 60-day window.
///
/// A row reopens the title's own detail screen rather than resuming straight into the player: the
/// detail screen is where the remembered episode is marked, and it is the screen a viewer needs
/// anyway to pick a different one.
private struct HistoryView: View {
    let sites: [Site]
    let source: ConfigSource
    @State private var records = [WatchHistory]()
    @State private var loaded = false

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView(
                    "還沒有觀看記錄",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(loaded ? "播放任何一集之後，這裡會記住看到哪裡。" : "載入中…")
                )
            } else {
                List {
                    ForEach(records) { record in
                        row(for: record)
                    }
                    .onDelete { offsets in
                        let removing = offsets.map { records[$0] }
                        records.remove(atOffsets: offsets)
                        Task { for record in removing { await WatchHistoryStore.shared.remove(key: record.key) } }
                    }
                    .listRowBackground(appSurface)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .appWallpaper()
        .navigationTitle("觀看記錄")
        .navigationBarTitleDisplayMode(.inline)
        .appNavigationBar()
        .toolbar {
            if !records.isEmpty {
                Button("清除") {
                    records = []
                    Task { await WatchHistoryStore.shared.clear() }
                }
            }
        }
        // .task runs again whenever the tab is re-entered, which is what keeps the list current
        // after a viewing without any notification plumbing.
        .task {
            records = await WatchHistoryStore.shared.records()
            loaded = true
        }
    }

    @ViewBuilder
    private func row(for record: WatchHistory) -> some View {
        // Matched on the whole key rather than by splitting it: `Site.id` embeds the site's ext,
        // which may contain anything, and two sites here really do share a key.
        if let site = sites.first(where: { WatchHistory.key(siteID: $0.id, vodId: record.vodId) == record.key }) {
            NavigationLink {
                VodView(site: site,
                        summary: Vod(id: record.vodId, name: record.vodName, picture: record.vodPic),
                        source: source)
            } label: {
                label(for: record)
            }
        } else {
            // The configuration changed under the record. Show it, greyed, rather than dropping it:
            // deleting someone's history because a site was renamed is worse than a dead row.
            label(for: record).foregroundStyle(.secondary)
        }
    }

    private func label(for record: WatchHistory) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: record.vodPic)) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: appSurface.overlay { Image(systemName: "film").foregroundStyle(.secondary) }
                }
            }
            .frame(width: 48, height: 72)
            .clipShape(.rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(record.vodName).font(.headline).lineLimit(2)
                Text([record.siteName.displayName, record.vodFlag, record.vodRemarks]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(progress(of: record)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func progress(of record: WatchHistory) -> String {
        guard record.duration > 0 else { return "看到 " + clock(record.position) }
        if record.isNearEnding { return "已看完" }
        return "看到 \(clock(record.position)) / \(clock(record.duration))"
    }

    private func clock(_ milliseconds: Double) -> String {
        let total = Int(milliseconds / 1000)
        let minutes = total / 60, seconds = total % 60
        if minutes < 60 { return String(format: "%d:%02d", minutes, seconds) }
        return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, seconds)
    }
}

private struct VodPoster: View {
    let vod: Vod

    var body: some View {
        AsyncImage(url: URL(string: vod.picture)) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            default: appSurface.overlay { Image(systemName: "film").foregroundStyle(.secondary) }
            }
        }
        .clipShape(.rect(cornerRadius: 10))
    }
}

private struct Playback: Identifiable {
    let url: URL
    /// The headers the source says this stream needs. Only the built-in player can send them.
    var headers: [String: String] = [:]
    var title = ""
    /// Android hands VideoActivity the poster, so player.status can report it.
    var artwork = ""
    /// The source's quality menu. One entry for every source in this configuration today, which is
    /// why the picker only shows it when there is more than one.
    var qualities: [PlaybackQuality] = []
    var position = 0
    var defaultIndex = 0
    /// The quality name this title was last watched at, so the menu opens on the viewer's own choice
    /// rather than on the default (D8, R6). Empty when nothing is remembered.
    var preferredQuality = ""
    /// Identity for the watch history. Nil for `player.playUrl`, which names no site or title.
    var history: WatchHistory?
    var id: String { url.absoluteString }
}

private struct PlayerPickerView: View {
    let mediaURL: URL
    /// Headers the stream needs. The built-in player sends them; an external player cannot be told
    /// about them at all, because a URL scheme is the whole interface those apps expose.
    var headers: [String: String] = [:]
    var title = ""
    var artwork = ""
    /// The source's quality menu, in the source's own order.
    var qualities: [PlaybackQuality] = []
    /// The source's own preferred index, so the same decision can be re-run here with a preference.
    var position = 0
    /// The entry `mediaURL` was resolved from.
    var defaultIndex = 0
    /// What this title was last watched at, which outranks the default (D8).
    var preferredQuality = ""
    var history: WatchHistory?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var playing = false
    @State private var selected: Int?

    /// A single-URL source is every source in this configuration today, and a one-item menu is a
    /// control that decides nothing. Show it only where there is a choice to make.
    private var offersChoice: Bool { qualities.count > 1 }

    /// Where the menu opens. The same pure function core used, re-run with the remembered choice —
    /// which is why that choice is a parameter rather than something core looks up.
    private var initialIndex: Int {
        PlaybackQuality.defaultIndex(in: qualities, position: position,
                                     preferred: preferredQuality.isEmpty ? nil : preferredQuality)
    }

    private var chosen: Int { selected ?? initialIndex }

    /// The default entry is the one that went through the probe and the sniffer, so it is handed on
    /// resolved. Any other entry is opened exactly as the source gave it.
    ///
    /// ponytail: that asymmetry is the cost of resolving one URL instead of all of them. Thread a
    /// resolver in here if a real multi-value source ever needs the hop on a non-default entry.
    private var playURL: URL {
        guard chosen != defaultIndex, chosen < qualities.count else { return mediaURL }
        return qualities[chosen].url
    }

    var body: some View {
        NavigationStack {
            List {
                if offersChoice {
                    Section("畫質") {
                        ForEach(Array(qualities.enumerated()), id: \.offset) { index, quality in
                            Button {
                                selected = index
                            } label: {
                                HStack {
                                    Text(quality.name.isEmpty ? "線路 \(index + 1)" : quality.name)
                                    Spacer()
                                    if index == chosen {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }

                Button {
                    PlaybackSession.shared.open(url: playURL, headers: headers, title: title,
                                                artwork: artwork, history: record)
                    playing = true
                } label: {
                    Label("內建播放器", systemImage: "play.rectangle.fill")
                }

                ForEach(ExternalPlayer.allCases, id: \.self) { player in
                    Button {
                        open(player)
                    } label: {
                        Label(player.displayName, systemImage: "arrow.up.forward.app")
                    }
                }
            }
            .navigationTitle("選擇影片播放器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("取消") { dismiss() } }
            .appNavigationBar()
            .alert("無法開啟播放器", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("確定", role: .cancel) {}
            } message: {
                Text(error ?? "未知錯誤")
            }
        }
        // Full screen rather than a push inside this sheet: a page sheet is inset and rounded, so the
        // player inherited those bounds and the app wallpaper showed through around the video.
        .fullScreenCover(isPresented: $playing) { PlayerView() }
    }

    /// The history entry this playback would write, with the quality actually chosen. Nil for a
    /// path that names no title — `player.playUrl` hands over a bare URL.
    private var record: WatchHistory? {
        guard var record = history else { return nil }
        record.quality = qualities.indices.contains(chosen) ? qualities[chosen].name : ""
        return record
    }

    /// An external player is opened and forgotten: a URL scheme carries no way back, so nothing it
    /// plays can ever be recorded (K6). Only the built-in player writes history.
    private func open(_ player: ExternalPlayer) {
        guard let url = player.playbackURL(for: playURL) else {
            error = "無法建立 \(player.displayName) 播放連結。"
            return
        }
        UIApplication.shared.open(url) { opened in
            if !opened {
                Task { @MainActor in
                    error = "請先安裝或更新 \(player.displayName)，也可改用內建播放器。"
                }
            }
        }
    }
}

/// The persistent half of playback. Android reaches its player through a process-wide
/// `PlaybackService` (`HomeWebBridge.control`, `Server.get().getService()`); this is the same idea at
/// the smallest size that can answer `player.status` and obey `player.control` after the player
/// screen has been dismissed — which is the only time a WebHome page is on screen to ask.
///
/// One `AVPlayer` for the app's lifetime with items swapped into it, so no view has to observe a
/// changing player object. Everything else Android tracks — the playlist, the page-supplied title
/// and artwork, the repeat flag — is what `AVPlayer` has no concept of.
@MainActor final class PlaybackSession {
    static let shared = PlaybackSession()

    let player = AVPlayer()
    private var items = [WebHomeBridge.PlaybackItem]()
    private var index = 0
    private var title = ""
    private var artwork = ""
    private var url = ""
    private var looping = false
    /// Request headers for whatever is loaded now. Cleared by every `open`, because they belong to
    /// the source that resolved the URL and mean nothing for the next one.
    private var headers = [String: String]()
    private var started = false
    /// Resolves an episode the page kept for itself. Set while a WebHome page owns the web view.
    var resolveEpisode: ((String) async -> URL?)?

    /// What this playback writes into the watch history, with the position kept up to date. Nil for
    /// a path that names no title: `player.playUrl` and an inline vod both hand over bare media.
    private var record: WatchHistory?
    /// Where to resume to, consumed by the next `load`. Resolved before playback starts so the item
    /// is never created twice or seeked after it is already running.
    private var resumeTo: Double?
    private var sampler: Task<Void, Never>?

    private init() {
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.finished() }
        }
        // The 5-second sampler cannot be relied on for the last few seconds before the app is
        // suspended, and those are the ones a viewer notices losing.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await PlaybackSession.shared.persist() }
        }
    }

    /// One media URL: the CMS path, `player.playUrl`, and an episode picked in `VodView`.
    /// The item carries no name: the caller's title already names the episode, and `status()`
    /// appends the item name, which would otherwise report it twice.
    func open(url: URL, headers: [String: String] = [:], title: String, artwork: String = "",
              history: WatchHistory? = nil) {
        items = [.init(name: "", url: url)]
        self.headers = headers
        self.title = title
        self.artwork = artwork
        record = history
        guard let history else {
            resumeTo = nil
            start(at: 0)
            return
        }
        // Resuming has to know where the last viewing stopped, and the store is an actor. Resolve
        // it first and start afterwards: the read is from an in-memory cache, and starting first
        // would mean seeking a stream that has already begun.
        Task { @MainActor in
            resumeTo = await WatchHistoryStore.shared.record(forKey: history.key)?.resumePosition
            start(at: 0)
        }
    }

    /// A whole inline vod, so `control("next")` and `("prev")` have somewhere to go.
    ///
    /// Not recorded: an inline vod is a page's own playlist addressed under the pseudo-site
    /// `webhome_inline`, so it has no site or vod identity the history could be keyed on.
    func open(_ vod: WebHomeBridge.InlineVod) {
        items = vod.items
        title = vod.title
        artwork = vod.picture
        record = nil
        resumeTo = nil
        start(at: vod.startIndex)
    }

    /// Writes where the viewer got to.
    ///
    /// `onlyWhilePlaying` is what the sampler passes: the history file is rewritten whole, so a
    /// paused player must not keep rewriting it every five seconds.
    ///
    /// ponytail: whole-file writes at 5 s are fine for a few hundred records. Coalesce them, or
    /// flush only on pause and background, if the file ever grows enough to matter.
    func persist(onlyWhilePlaying: Bool = false) async {
        guard var record, started, let item = player.currentItem else { return }
        if onlyWhilePlaying, player.rate == 0 { return }
        let position = milliseconds(player.currentTime())
        guard position > 0 else { return }
        record.position = position
        record.duration = milliseconds(item.duration)
        self.record = record
        await WatchHistoryStore.shared.save(record)
    }

    private func startSampling() {
        sampler?.cancel()
        guard record != nil else { return }
        sampler = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                await PlaybackSession.shared.persist(onlyWhilePlaying: true)
            }
        }
    }

    func control(_ action: String) {
        switch action {
        case "play": player.play()
        case "pause": player.pause()
        case "stop":
            // No foreground service to stop, so the equivalent is to drop what is loaded.
            Task { @MainActor in await persist() }
            sampler?.cancel()
            player.pause()
            player.replaceCurrentItem(with: nil)
            started = false
        case "prev": start(at: index - 1)
        case "next": start(at: index + 1)
        case "loop": looping.toggle()
        case "replay":
            player.seek(to: .zero)
            player.play()
        default: break
        }
    }

    /// `server/process/Media.java`. Durations and positions are milliseconds, as Media3 reports them.
    func status() -> WebHomeBridge.PlaybackStatus {
        guard started, let item = player.currentItem else { return .idleStatus }
        return .init(
            state: state(of: item),
            speed: Double(player.rate),
            duration: milliseconds(item.duration),
            position: milliseconds(player.currentTime()),
            url: url,
            title: [title, items.indices.contains(index) ? items[index].name : ""]
                .filter { !$0.isEmpty }.joined(separator: " "),
            artwork: artwork
        )
    }

    private func state(of item: AVPlayerItem) -> Int {
        if player.timeControlStatus == .playing { return 3 }
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate { return 6 }
        return item.status == .readyToPlay ? 2 : 1
    }

    private func milliseconds(_ time: CMTime) -> Double {
        let seconds = time.seconds
        return seconds.isFinite ? (seconds * 1000).rounded() : 0
    }

    private func finished() {
        // Record the end before moving on, so a title watched through reads as near-ending rather
        // than as stopped wherever the last sample happened to land.
        Task { @MainActor in await persist() }
        if looping { control("replay") } else { start(at: index + 1) }
    }

    private func start(at index: Int) {
        guard items.indices.contains(index) else { return }
        self.index = index
        let item = items[index]
        if let url = item.url {
            load(url)
            return
        }
        // The page kept this episode's URL to itself; ask it, the way Android's inline store does.
        guard let payload = item.resolvePayload, let resolveEpisode else { return }
        Task { @MainActor in
            guard let url = await resolveEpisode(payload), self.index == index else { return }
            self.load(url)
        }
    }

    private func load(_ url: URL) {
        self.url = url.absoluteString
        started = true
        player.replaceCurrentItem(with: AVPlayerItem(asset: Self.asset(for: url, headers: headers)))
        if let resumeTo {
            self.resumeTo = nil
            // A seek issued now is honoured once the item is ready, which is why it goes before
            // play() rather than behind a readiness observer.
            player.seek(to: CMTime(value: CMTimeValue(resumeTo), timescale: 1000))
        }
        player.play()
        startSampling()
    }

    /// `AVPlayer` sends request headers only through `AVURLAsset` options, and the key for them —
    /// `AVURLAssetHTTPHeaderFieldsKey` — is not in Apple's public headers, which is why it is spelled
    /// out here rather than referenced. It is what every player on the platform uses for this, and
    /// the failure mode if it ever stops working is the one we already had: the stream 403s. With no
    /// headers the asset is built exactly as before, so nothing that worked can regress.
    private static func asset(for url: URL, headers: [String: String]) -> AVURLAsset {
        guard !headers.isEmpty else { return AVURLAsset(url: url) }
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }
}

private struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    /// The item is already loaded by the caller, because playback has to outlive this screen for
    /// `player.status` and `player.control` to mean anything.
    private let session = PlaybackSession.shared

    var body: some View {
        ZStack {
            // The player owns the whole screen, so letterbox bars are black instead of showing
            // whatever is behind the presentation.
            Color.black.ignoresSafeArea()
            VideoPlayer(player: session.player)
                .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            // A full-screen cover has no navigation bar, so it needs its own way out.
            //
            // Sat level with AVKit's own top row until IOS-POC-8B, where the device put its video
            // output control in the same corner and the two crowded each other. The simulator lays
            // that row out differently, so it only showed on hardware. Dropped below the row rather
            // than moved to another corner, because AVKit owns both top corners and the bottom.
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .padding(.leading, 16)
            .padding(.top, 64)
        }
        .statusBarHidden()
        // Closing the screen pauses rather than tears down, so a page can read the position it
        // reached and resume it with player.control.
        .onDisappear {
            session.player.pause()
            // The sampler skips a paused player, so the moment of leaving is the last chance to
            // record where the viewer actually got to.
            Task { await session.persist() }
        }
    }
}

private extension View {
    /// The wallpaper behind one screen's content.
    ///
    /// Deliberately a `.background` and **not** a `ZStack`. IOS-POC-8B briefly made it a ZStack to
    /// cure a black band under the tab bar, and that put every screen inside a container whose
    /// other child ignores the safe area: content then laid out against the full window instead of
    /// the safe area, so row labels were clipped at the left edge and the grid ran under the
    /// navigation bar. A background decorates without relayouting, which is what every content view
    /// needs.
    ///
    /// The black band behind the tab bar that this comment used to call permanent is **fixed**, and
    /// it never needed a `ZStack` at all — see the body. The diagnosis it rested on was wrong: the
    /// bar is not outside the content view's frame, and a background modifier does reach there.
    ///
    /// Four other things were built and measured first, and all four failed (IOS-POC-8G): colouring
    /// `UIWindow.appearance()`, colouring `UITabBar.appearance()`, inserting a wallpaper image view
    /// under the tab bar controller's own container, and clearing the opaque `systemBackground` that
    /// every hosting view above it paints. The first two never appeared at all, and the last two
    /// lost to backgrounds SwiftUI re-applies on its next layout pass. **Do not reach into UIKit for
    /// this.**
    func appWallpaper() -> some View {
        background {
            // `.ignoresSafeArea()` belongs on a view that fills, and `scaledToFill` does not: it
            // sizes the image to its own aspect-filled bounds, so the modifier had nothing to
            // expand and the wallpaper stopped at the safe area — the black band under the tab bar
            // (IOS-POC-8G). `Color.clear` fills, ignores the safe area, and the image fills that
            // instead. Still a `.background`, so it still cannot relayout anything.
            Color.clear
                .overlay {
                    bundledImage("wallpaper_1")
                        .resizable()
                        .scaledToFill()
                }
                .ignoresSafeArea()
        }
    }

    func appNavigationBar() -> some View {
        toolbarBackground(.hidden, for: .navigationBar)
    }
}

private func bundledImage(_ name: String) -> Image {
    guard let path = Bundle.main.path(forResource: name, ofType: "png"),
          let image = UIImage(contentsOfFile: path) else {
        fatalError("Missing bundled image: \(name).png")
    }
    return Image(uiImage: image)
}

private struct WebHomeView: View {
    let site: Site
    /// `player.playVod` names a site by key, so the whole configured list has to be reachable.
    let sites: [Site]
    let source: ConfigSource
    @Environment(\.dismiss) private var dismiss
    @State private var pendingPlayback: Playback?
    @State private var pendingVod: VodRequest?
    @State private var pendingSearch: SearchRequest?
    @State private var playingInline = false
    @State private var toast: String?
    @State private var toolbarVisible = true

    var body: some View {
        Group {
            if let page = Bundle.main.url(forResource: "app-capabilities-showcase", withExtension: "html") {
                WebHomeWebView(
                    pageURL: page,
                    site: site,
                    sites: sites,
                    source: source,
                    onPlay: { url, title in pendingPlayback = Playback(url: url, title: title) },
                    onPlayVod: { site, vod in pendingVod = VodRequest(site: site, vod: vod) },
                    onPlayInline: { vod in
                        // Straight to the built-in player: an inline vod carries a playlist and
                        // player.control semantics that an external player cannot honour.
                        PlaybackSession.shared.open(vod)
                        playingInline = true
                    },
                    onSearch: { pendingSearch = SearchRequest(keyword: $0) },
                    onToast: { message in
                        toast = message
                        Task { try? await Task.sleep(for: .seconds(2)); toast = nil }
                    },
                    onSetToolbar: { toolbarVisible = $0 },
                    onBack: { dismiss() }
                )
            } else {
                ContentUnavailableView("找不到頁面", systemImage: "doc.questionmark", description: Text("WebHome 展示頁沒有打包進 App。"))
                    .appWallpaper()
            }
        }
        .navigationTitle("WebHome 橋接")
        .navigationBarTitleDisplayMode(.inline)
        .appNavigationBar()
        .toolbar(toolbarVisible ? .visible : .hidden, for: .navigationBar)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.82), in: Capsule())
                    .padding(.bottom, 28)
            }
        }
        .sheet(item: $pendingPlayback) { PlayerPickerView(mediaURL: $0.url, title: $0.title, artwork: $0.artwork) }
        .sheet(item: $pendingVod) { request in
            NavigationStack { VodView(site: request.site, summary: request.vod, source: source) }
        }
        .sheet(item: $pendingSearch) { request in
            NavigationStack { CMSView(site: site, source: source, initialQuery: request.keyword) }
        }
        .fullScreenCover(isPresented: $playingInline) { PlayerView() }
    }
}

extension String {
    /// Site names in this configuration start with an emoji (🏆, 🎡, 🎖︎ …), and the simulator draws
    /// every one of them as a `.notdef` box.
    ///
    /// **It is not this app.** The iOS 26.3 simulator runtime ships a reduced font set: no PingFang
    /// at all, and although `AppleColorEmoji-160px.ttc` is on disk it is never picked up. Safari on
    /// the same simulator renders 🎡, 蓮花樓 and even the fullwidth ｜ as boxes, which is how we know
    /// the gap is the runtime's. The app's own CJK survives only because SwiftUI falls back to the
    /// Hiragino faces that *are* installed. A real device has the full set and renders these names
    /// exactly as the configuration writes them.
    ///
    /// So this is a **screenshot-legibility fix and nothing more**: Debug builds on the simulator
    /// drop the characters that cannot be drawn, every other build shows the name verbatim. It is
    /// the same shape as the Debug-only CJK fallback IOS-POC-2C added to the web view for the same
    /// underlying reason.
    ///
    /// ponytail: delete this the day the simulator ships a complete font set. Nothing depends on it
    /// — the stored, bridged and searched name is always the real one.
    var displayName: String {
        #if DEBUG && targetEnvironment(simulator)
        let cleaned = unicodeScalars.filter { scalar in
            // Variation selectors, and the ranges the emoji font owns.
            if scalar.properties.isVariationSelector { return false }
            return !(0x1F000...0x1FAFF).contains(scalar.value)
                && !(0x2600...0x27BF).contains(scalar.value)
        }
        return String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: CharacterSet(charactersIn: " \u{FF5C}|\u{00B7}-"))
        #else
        return self
        #endif
    }
}

#if DEBUG
private let cjkFallbackScript = #"""
(function(){
  var style=document.createElement('style');
  style.textContent='*{font-family:"PingFang SC","PingFang TC","Hiragino Sans","Hiragino Kaku Gothic ProN",sans-serif!important}'
    +'pre,code,.log{font-family:ui-monospace,Menlo,"PingFang SC","Hiragino Sans",monospace!important}';
  (document.head||document.documentElement).appendChild(style);
})();
"""#
#endif

/// Built once per bridge because `UIDevice` cannot cross into `WebHTVCore`, which also builds for macOS.
private func deviceInfo() -> [String: String] {
    let bundle = Bundle.main.infoDictionary ?? [:]
    return [
        "model": UIDevice.current.model,
        "systemName": UIDevice.current.systemName,
        "systemVersion": UIDevice.current.systemVersion,
        "appVersion": bundle["CFBundleShortVersionString"] as? String ?? "",
        "appBuild": bundle["CFBundleVersion"] as? String ?? "",
    ]
}

private struct SearchRequest: Identifiable {
    let keyword: String
    var id: String { keyword }
}

private struct VodRequest: Identifiable {
    let site: Site
    let vod: Vod
    var id: String { site.key + "/" + vod.id }
}

/// Hosts the WebHome page and carries the string-RPC contract between it and `WebHomeBridge`.
private struct WebHomeWebView: UIViewRepresentable {
    let pageURL: URL
    let site: Site
    let sites: [Site]
    let source: ConfigSource
    let onPlay: @MainActor @Sendable (URL, String) -> Void
    let onPlayVod: @MainActor @Sendable (Site, Vod) -> Void
    let onPlayInline: @MainActor @Sendable (WebHomeBridge.InlineVod) -> Void
    let onSearch: @MainActor @Sendable (String) -> Void
    let onToast: @MainActor @Sendable (String) -> Void
    let onSetToolbar: @MainActor @Sendable (Bool) -> Void
    let onBack: @MainActor @Sendable () -> Void

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        // The page owns the resolver for its own inline episodes, so the session can only reach it
        // while this web view is alive.
        PlaybackSession.shared.resolveEpisode = { [weak coordinator] payload in
            await coordinator?.resolveInlineEpisode(payload)
        }
        coordinator.bridge = WebHomeBridge(
            actions: .init(
                play: onPlay,
                playVod: onPlayVod,
                playInline: onPlayInline,
                control: { PlaybackSession.shared.control($0) },
                status: { PlaybackSession.shared.status() },
                search: onSearch,
                toast: onToast,
                setToolbar: onSetToolbar,
                back: onBack,
                reload: { [weak coordinator] in coordinator?.webView?.reload() },
                viewport: { [weak coordinator] in coordinator?.viewport() ?? .init(width: 0, height: 0, safeTop: 0, safeRight: 0, safeBottom: 0, safeLeft: 0) }
            ),
            site: site,
            sites: sites,
            source: source,
            device: deviceInfo()
        )
        return coordinator
    }

    func makeUIView(context: Context) -> WKWebView {
        let content = WKUserContentController()
        // At document start, so a page that calls the bridge during parsing still finds window.fm.
        content.addUserScript(WKUserScript(source: WebHomeBridge.sdkScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.add(context.coordinator, name: WebHomeBridge.messageHandlerName)
        #if DEBUG
        // Simulator readability only. The simulator keeps PingFang as a private system-UI font that
        // the web content process cannot reach, so every CJK glyph in a page renders as tofu and the
        // controls become impossible to identify while verifying. Naming a stack restores them.
        // Debug-only on purpose: a release build must render WebHome pages exactly as Android does.
        content.addUserScript(WKUserScript(source: cjkFallbackScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        #endif
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.webView = webView
        webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// The content controller retains the handler, which would otherwise keep the whole web view alive.
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: WebHomeBridge.messageHandlerName)
        PlaybackSession.shared.resolveEpisode = nil
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler {
        var bridge: WebHomeBridge?
        weak var webView: WKWebView?

        /// Points are CSS pixels on iOS, so the page receives the same units Android reports.
        func viewport() -> WebHomeBridge.Viewport {
            let insets = webView?.safeAreaInsets ?? .zero
            let size = webView?.bounds.size ?? .zero
            return .init(
                width: size.width, height: size.height,
                safeTop: insets.top, safeRight: insets.right,
                safeBottom: insets.bottom, safeLeft: insets.left
            )
        }

        /// `HomeWebBridge.resolveInlineEpisode`. iOS awaits the page's promise directly, so the
        /// Android side's `inlineResult` callback, UUID-keyed map and `CompletableFuture` have no
        /// equivalent here and are not ported.
        func resolveInlineEpisode(_ payload: String) async -> URL? {
            guard let webView,
                  let episode = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) else { return nil }
            let script = """
            const resolver = window.__fmWebHomeInlineResolver || window.__fmYmvidResolveEpisode;
            if (typeof resolver !== 'function') return '';
            const result = await resolver(episode);
            return (result && result.url) || '';
            """
            let value = try? await webView.callAsyncJavaScript(
                script, arguments: ["episode": episode], contentWorld: .page
            )
            guard let text = value as? String else { return nil }
            return URL(string: text)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let call = WebHomeBridge.decodeMessage(message.body), let bridge else { return }
            // Swift 6 region isolation: `[String: Any]` is not Sendable, and `handle` is
            // nonisolated, so the decoded payload cannot be sent out of this @MainActor method.
            // The page sends the payload as JSON text to begin with, so the text crosses and the
            // dictionary is rebuilt inside the task, where it has no other alias.
            let payloadJSON = (message.body as? [String: Any])?["payload"] as? String ?? "{}"
            let id = call.id
            let method = call.method
            Task {
                let script = await Self.respond(bridge: bridge, id: id, method: method, payloadJSON: payloadJSON)
                webView?.evaluateJavaScript(script, completionHandler: nil)
            }
        }

        /// Runs the bridge call off the main actor so the `[String: Any]` payload is created and
        /// consumed inside one nonisolated region and never crosses an isolation boundary — only
        /// the JSON text in and the script text out, both `Sendable`.
        private nonisolated static func respond(
            bridge: WebHomeBridge, id: String, method: String, payloadJSON: String
        ) async -> String {
            let payload = (try? JSONSerialization.jsonObject(with: Data(payloadJSON.utf8))) as? [String: Any] ?? [:]
            do {
                return WebHomeBridge.resolveScript(id: id, json: try await bridge.handle(method: method, payload: payload))
            } catch {
                return WebHomeBridge.rejectScript(id: id, message: error.localizedDescription)
            }
        }
    }
}
