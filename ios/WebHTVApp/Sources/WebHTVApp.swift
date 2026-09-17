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
    @State private var source = ConfigSource.importedFile
    @State private var updatedAt: Date?
    @State private var refreshing = false

    var body: some View {
        Group {
            if sites.isEmpty {
                NavigationStack {
                    ContentUnavailableView(
                        "尚未載入設定",
                        systemImage: "play.rectangle.on.rectangle",
                        description: Text("匯入 wang-movie.json 以顯示 iOS 可用站點。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .appWallpaper()
                    .navigationTitle("WebHTV")
                    .toolbar { Button("匯入設定") { importing = true } }
                    .appNavigationBar()
                }
            } else {
                TabView(selection: $selectedTab) {
                    HomeView(sites: sites, selectedSiteID: $selectedSiteID, source: source)
                        .tag(0)
                        .tabItem { Label("首頁", systemImage: "play.rectangle.fill") }

                    NavigationStack {
                        SettingsView(
                            sites: sites,
                            selectedSiteID: $selectedSiteID,
                            source: source,
                            updatedAt: updatedAt,
                            refreshing: refreshing,
                            onImport: { importing = true },
                            onUseRemote: { text in useRemote(text) },
                            onRefresh: { Task { await refreshRemote() } },
                            onOpenHome: { selectedTab = 0 }
                        )
                    }
                    .tag(1)
                    .tabItem { Label("設定", systemImage: "gearshape.fill") }
                }
                .toolbarBackground(.hidden, for: .tabBar)
                .appWallpaper()
            }
        }
        .appWallpaper()
        .task {
            restore()
            // Every launch re-fetches a remote configuration, so the app opens on the current one
            // rather than on whatever happened to be cached.
            await refreshRemote(quiet: true)
        }
        .onChange(of: selectedSiteID) { _, id in
            UserDefaults.standard.set(id, forKey: selectedSiteKey)
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

    private var selectedSite: Site {
        sites.first { $0.id == selectedSiteID } ?? sites[0]
    }

    var body: some View {
        NavigationStack {
            CMSView(site: selectedSite, source: source)
                .id(selectedSite.id)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            ForEach(sites) { site in
                                Button {
                                    selectedSiteID = site.id
                                } label: {
                                    if site.id == selectedSite.id {
                                        Label(site.name, systemImage: "checkmark")
                                    } else {
                                        Text(site.name)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(selectedSite.name).font(.headline)
                                Image(systemName: "chevron.down").font(.caption2)
                            }
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(minHeight: 44)
                        }
                        .accessibilityLabel("切換內容來源，目前為 \(selectedSite.name)")
                    }
                }
        }
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
    @State private var searching = false
    @State private var query = ""
    @State private var page = 1
    @State private var canLoadMore = true
    @State private var loadingMore = false
    @State private var loading = false
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            if !groups.isEmpty {
                categoryRow(parentChips)
                if let children = activeGroup?.children, !children.isEmpty {
                    categoryRow(ForEach(children) { chip($0.name, id: $0.id) })
                }
                // Filter rows belong to a category, so they only appear once one is listed, and
                // only for a source whose API publishes them at all.
                ForEach(activeFilterRows) { row in
                    filterRow(row)
                }
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items) { vod in
                        NavigationLink {
                            VodView(site: site, summary: vod, source: source)
                        } label: {
                            VodCard(vod: vod)
                        }
                        .buttonStyle(.plain)
                        .onAppear { if vod.id == items.last?.id { Task { await loadMore() } } }
                    }
                }
                .padding(12)
                if loadingMore { ProgressView().padding(.bottom, 16) }
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
        .searchable(text: $query, prompt: "搜尋影片")
        .onSubmit(of: .search) { searching = true; Task { await load(search: query) } }
        .task {
            guard items.isEmpty else { return }
            guard let initialQuery, !initialQuery.isEmpty else { return await load() }
            query = initialQuery
            searching = true
            await load(search: initialQuery)
        }
        .appNavigationBar()
    }

    /// The group whose parent or child is currently listed, so the parent row can highlight it.
    private var activeGroup: CategoryGroup? {
        groups.first { $0.id == selectedCategory || $0.children.contains { $0.id == selectedCategory } }
    }

    /// True when the source's own category list already opens with an "all" entry, as every
    /// 苹果CMS App-API site does (`type_id: 0, type_name: 全部`). Adding ours on top of it showed
    /// two 全部 chips side by side.
    private var providerSuppliesAllChip: Bool {
        groups.first.map { $0.parent.name == "全部" || $0.parent.id == "0" } ?? false
    }

    @ViewBuilder private var parentChips: some View {
        // A type-4 home is really its first category, so it has no separate "all" listing.
        if site.type != 4 && !providerSuppliesAllChip { chip("全部", id: nil) }
        ForEach(groups) { group in
            // A parent with no children lists by its own id; otherwise open its first child.
            chip(group.parent.name, id: group.children.first?.id ?? group.parent.id, active: activeGroup?.id == group.id)
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

    private func chip(_ title: String, id: String?, active: Bool? = nil) -> some View {
        let isActive = !searching && (active ?? (selectedCategory == id))
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
                            Text(site.name).foregroundStyle(.primary)
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
            Text("目前支援 \(sites.count) 個來源：type-0／type-1／type-4 CMS，以及已移植的 csp_* Spider。遠端更新失敗時會保留上一份可用設定。")
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
                            Text(site.name)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(appSurface, in: Capsule())
                        }
                    }

                    ForEach(detail.flags, id: \.name) { flag in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(flag.name).font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                                ForEach(Array(flag.episodes.enumerated()), id: \.offset) { _, episode in
                                    Button(episode.name) {
                                        Task { await play(episode, flag: flag.name) }
                                    }
                                    .buttonStyle(.bordered)
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
            do {
                let client = try await SourceClient.make(site: site, resolver: CSPSourceResolver(source: source))
                detail = try await client.detail(id: summary.id)
            } catch { self.error = error.localizedDescription }
        }
        .sheet(item: $pendingPlayback) { PlayerPickerView(mediaURL: $0.url, title: $0.title, artwork: $0.artwork) }
        .alert("無法播放", isPresented: Binding(get: { playbackError != nil }, set: { if !$0 { playbackError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(playbackError ?? "")
        }
    }

    private func play(_ episode: Episode, flag: String) async {
        resolving = true
        defer { resolving = false }
        do {
            let client = try await SourceClient.make(site: site, resolver: CSPSourceResolver(source: source))
            guard let url = try await client.playbackURL(for: episode, flag: flag) else {
                playbackError = "這一集沒有可播放的網址。"
                return
            }
            pendingPlayback = Playback(url: url, title: "\(summary.name) \(episode.name)", artwork: summary.picture)
        } catch {
            playbackError = error.localizedDescription
        }
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
    var title = ""
    /// Android hands VideoActivity the poster, so player.status can report it.
    var artwork = ""
    var id: String { url.absoluteString }
}

private struct PlayerPickerView: View {
    let mediaURL: URL
    var title = ""
    var artwork = ""
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var playing = false

    var body: some View {
        NavigationStack {
            List {
                Button {
                    PlaybackSession.shared.open(url: mediaURL, title: title, artwork: artwork)
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

    private func open(_ player: ExternalPlayer) {
        guard let url = player.playbackURL(for: mediaURL) else {
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
    private var started = false
    /// Resolves an episode the page kept for itself. Set while a WebHome page owns the web view.
    var resolveEpisode: ((String) async -> URL?)?

    private init() {
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.finished() }
        }
    }

    /// One media URL: the CMS path, `player.playUrl`, and an episode picked in `VodView`.
    /// The item carries no name: the caller's title already names the episode, and `status()`
    /// appends the item name, which would otherwise report it twice.
    func open(url: URL, title: String, artwork: String = "") {
        items = [.init(name: "", url: url)]
        self.title = title
        self.artwork = artwork
        start(at: 0)
    }

    /// A whole inline vod, so `control("next")` and `("prev")` have somewhere to go.
    func open(_ vod: WebHomeBridge.InlineVod) {
        items = vod.items
        title = vod.title
        artwork = vod.picture
        start(at: vod.startIndex)
    }

    func control(_ action: String) {
        switch action {
        case "play": player.play()
        case "pause": player.pause()
        case "stop":
            // No foreground service to stop, so the equivalent is to drop what is loaded.
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
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
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
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .padding(.leading, 16)
            .padding(.top, 8)
        }
        .statusBarHidden()
        // Closing the screen pauses rather than tears down, so a page can read the position it
        // reached and resume it with player.control.
        .onDisappear { session.player.pause() }
    }
}

private extension View {
    func appWallpaper() -> some View {
        background {
            bundledImage("wallpaper_1")
                .resizable()
                .scaledToFill()
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
