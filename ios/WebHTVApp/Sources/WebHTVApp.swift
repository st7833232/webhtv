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
                    HomeView(sites: sites, selectedSiteID: $selectedSiteID)
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
                            onUseRemote: { url in Task { await load(remote: url) } },
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
        .task { restore() }
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
    private func load(remote url: URL, showHome: Bool = true) async {
        refreshing = true
        defer { refreshing = false }
        do {
            let (data, config) = try await ConfigLoader.fetch(from: url)
            try adopt(data, config: config, from: .remote(url))
            if showHome { selectedTab = 0 }
        } catch {
            // The cached configuration and the live source list are untouched by a failed fetch.
            self.error = "遠端設定載入失敗：\(error.localizedDescription)"
        }
    }

    private func refreshRemote() async {
        guard case .remote(let url) = source else { return }
        await load(remote: url, showHome: false)
    }

    /// Write, then publish. Callers validate first and hand the result in, so nothing that failed
    /// validation reaches the cached file — that is what makes a failed refresh safe.
    private func adopt(_ data: Data, config: WebHTVConfig, from source: ConfigSource) throws {
        let loaded = config.supportedSites
        try data.write(to: configURL(), options: .atomic)
        let now = Date()
        UserDefaults.standard.set(source.baseURL?.absoluteString, forKey: configSourceURLKey)
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: configUpdatedAtKey)
        self.source = source
        updatedAt = now
        sites = loaded
        selectedSiteID = loaded.first { $0.id == selectedSiteID }?.id ?? loaded.first?.id
    }

    private func restore() {
        if let stored = UserDefaults.standard.string(forKey: configSourceURLKey), let url = URL(string: stored) {
            source = .remote(url)
        }
        let stamp = UserDefaults.standard.double(forKey: configUpdatedAtKey)
        if stamp > 0 { updatedAt = Date(timeIntervalSince1970: stamp) }
        do {
            let url = try configURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let loaded = try ConfigLoader.validate(Data(contentsOf: url)).supportedSites
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

    private var selectedSite: Site {
        sites.first { $0.id == selectedSiteID } ?? sites[0]
    }

    var body: some View {
        NavigationStack {
            CMSView(site: selectedSite)
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
    var initialQuery: String?
    @State private var items = [Vod]()
    @State private var groups = [CategoryGroup]()
    @State private var selectedCategory: String?
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
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items) { vod in
                        NavigationLink {
                            VodView(site: site, summary: vod)
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

    @ViewBuilder private var parentChips: some View {
        // A type-4 home is really its first category, so it has no separate "all" listing.
        if site.type != 4 { chip("全部", id: nil) }
        ForEach(groups) { group in
            // A parent with no children lists by its own id; otherwise open its first child.
            chip(group.parent.name, id: group.children.first?.id ?? group.parent.id, active: activeGroup?.id == group.id)
        }
    }

    private func categoryRow<Content: View>(_ content: Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    /// `active` overrides the default match so a parent chip can stay lit while a child is listed.
    private func chip(_ title: String, id: String?, active: Bool? = nil) -> some View {
        let isActive = !searching && (active ?? (selectedCategory == id))
        return Button(title) {
            searching = false
            selectedCategory = id
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
        let client = try CMSClient(site: site)
        if searching, !query.isEmpty { return try await client.search(query, page: page) }
        if let selectedCategory { return try await client.category(id: selectedCategory, page: page) }
        return try await client.home(page: page)
    }

    private func load(search: String? = nil, category: String? = nil) async {
        loading = true
        error = nil
        page = 1
        canLoadMore = true
        defer { loading = false }
        do {
            let client = try CMSClient(site: site)
            let response = if let search, !search.isEmpty {
                try await client.search(search)
            } else if let category {
                try await client.category(id: category)
            } else {
                try await client.home()
            }
            items = response.list
            // A category listing usually omits `class`, so keep the set the home call established.
            if !response.classes.isEmpty { groups = response.categoryGroups }
            // A type-4 home already lists its first category, so highlight that chip.
            if site.type == 4, selectedCategory == nil { selectedCategory = response.firstListableCategory?.id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct VodCard: View {
    let vod: Vod

    var body: some View {
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
        .aspectRatio(2 / 3, contentMode: .fit)
        .frame(maxWidth: .infinity)
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
    let onUseRemote: (URL) -> Void
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
                    NavigationLink("WebHome 橋接驗證") { WebHomeView(site: site) }
                }
            }

            sourceSection
        }
        .alert("從網址載入設定", isPresented: $askingRemote) {
            TextField("https://…/wang-movie.json", text: $remoteText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("載入") {
                if let url = URL(string: remoteText.trimmingCharacters(in: .whitespacesAndNewlines)),
                   url.scheme == "http" || url.scheme == "https" { onUseRemote(url) }
            }
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
            Text("目前支援 \(sites.count) 個 type-1／type-4 CMS 來源。遠端更新失敗時會保留上一份可用設定。")
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
            do { detail = try await CMSClient(site: site).detail(id: summary.id) }
            catch { self.error = error.localizedDescription }
        }
        .sheet(item: $pendingPlayback) { PlayerPickerView(mediaURL: $0.url) }
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
            guard let url = try await CMSClient(site: site).playbackURL(for: episode, flag: flag) else {
                playbackError = "這一集沒有可播放的網址。"
                return
            }
            pendingPlayback = Playback(url: url)
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
    var id: String { url.absoluteString }
}

private struct PlayerPickerView: View {
    let mediaURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    PlayerView(url: mediaURL)
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

private struct PlayerView: View {
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear { player.play() }
            .onDisappear { player.pause() }
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
    @State private var pendingPlayback: Playback?
    @State private var pendingSearch: SearchRequest?

    var body: some View {
        Group {
            if let page = Bundle.main.url(forResource: "app-capabilities-showcase", withExtension: "html") {
                WebHomeWebView(
                    pageURL: page,
                    onPlay: { url, _ in pendingPlayback = Playback(url: url) },
                    onSearch: { pendingSearch = SearchRequest(keyword: $0) }
                )
            } else {
                ContentUnavailableView("找不到頁面", systemImage: "doc.questionmark", description: Text("WebHome 展示頁沒有打包進 App。"))
                    .appWallpaper()
            }
        }
        .navigationTitle("WebHome 橋接")
        .navigationBarTitleDisplayMode(.inline)
        .appNavigationBar()
        .sheet(item: $pendingPlayback) { PlayerPickerView(mediaURL: $0.url) }
        .sheet(item: $pendingSearch) { request in
            NavigationStack { CMSView(site: site, initialQuery: request.keyword) }
        }
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

private struct SearchRequest: Identifiable {
    let keyword: String
    var id: String { keyword }
}

/// Hosts the WebHome page and carries the string-RPC contract between it and `WebHomeBridge`.
private struct WebHomeWebView: UIViewRepresentable {
    let pageURL: URL
    let onPlay: @MainActor @Sendable (URL, String) -> Void
    let onSearch: @MainActor @Sendable (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: WebHomeBridge(actions: .init(play: onPlay, search: onSearch)))
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
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler {
        private let bridge: WebHomeBridge
        weak var webView: WKWebView?

        init(bridge: WebHomeBridge) { self.bridge = bridge }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let call = WebHomeBridge.decodeMessage(message.body) else { return }
            Task {
                let script: String
                do {
                    let json = try await bridge.handle(method: call.method, payload: call.payload)
                    script = WebHomeBridge.resolveScript(id: call.id, json: json)
                } catch {
                    script = WebHomeBridge.rejectScript(id: call.id, message: error.localizedDescription)
                }
                webView?.evaluateJavaScript(script, completionHandler: nil)
            }
        }
    }
}
