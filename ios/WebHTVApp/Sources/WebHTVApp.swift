import AVKit
import AudioToolbox
import CoreMedia
import os
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebHTVCore
import WebKit

private let appSurface = Color(red: 0.075, green: 0.14, blue: 0.16)
private let appAccent = Color.white
private let selectedSiteKey = "selectedSiteKey"
/// IOS-POC-19: `[ConfigSource.identity: SiteSelection.token]`, the site each source was left on.
private let siteBySourceKey = "selectedSiteBySource"
private let configSourceURLKey = "configSourceURL"
private let configUpdatedAtKey = "configUpdatedAt"

@main
struct WebHTVApp: App {
    init() {
        // IOS-POC-10H. Picture in Picture will not start without an active `.playback` session,
        // and it is also what lets audio continue when the app is not in front. Failing here is
        // not fatal — playback still works, PiP simply will not arm — so it is reported rather
        // than trapped.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[audio] session unavailable: \(error.localizedDescription)")
        }
        // IOS-POC-10M. IOS-POC-10L stopped this app caching HTTP responses, which leaves whatever
        // the old configuration already wrote sitting in `Cache.db` — read by nothing, deletable
        // by nobody short of reinstalling the app. Clearing it here hands that back rather than
        // making it the viewer's problem. After the first launch it is a no-op, because nothing
        // writes there any more. Only this app's own cache is touched; the sandbox sees to that.
        URLCache.shared.removeAllCachedResponses()
        // Says out loud whether PiP can arm at all. The simulator does not implement it, so an
        // absent PiP button there is the platform rather than a defect — and without this line
        // that is a guess every time somebody looks.
        print("[pip] supported \(AVPictureInPictureController.isPictureInPictureSupported())")

        // IOS-POC-7F: start the interpreter and say what came up. Debug-only for now — the Spider
        // runtime will own initialisation once it exists, and nothing in a Release build needs
        // CPython until it does.
        // IOS-POC-7H: hand core the interpreter it cannot build for itself. Until this runs, a
        // Python site is not offered at all, which is why it happens before any view exists.
        PythonSpiderSupport.makeRuntime = { script, siteKey in
            try PythonSpiderRuntime(script: script, siteKey: siteKey)
        }
        #if DEBUG
        // IOS-POC-9B: does libmpv link and initialise inside this app? Debug-only, and nothing
        // downstream depends on it yet — AVPlayer is still the only playback core.
        print("[mpv] boot \(MPVBoot.start())")
        print("[python] boot \(PythonBoot.start())")
        Task {
            print("[python] selfcheck \(await PythonBoot.selfCheck())")
            // IOS-POC-7J: give the configuration a moment to land, then drive a real source.
            try? await Task.sleep(for: .seconds(6))
            print("[python] live \(await PythonLiveCheck.run())")
            print("[python] survey \(await PythonLiveCheck.survey())")
        }
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
    @State private var remoteName = ""

    @State private var source = ConfigSource.importedFile
    /// IOS-POC-10D: the named sources the viewer kept. The active one is `source`; this is the
    /// list they can come back to without retyping an address.
    @State private var saved = SavedSourceList()
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
                    HomeView(sites: sites, selectedSiteID: pickedSite, source: source)
                        .tag(0)
                        .tabItem { Label("首頁", systemImage: "play.rectangle.fill") }

                    // IOS-POC-20. Tag 3 rather than renumbering: the other tabs keep the tags code
                    // already switches to.
                    AggregateSearchView(sites: sites, source: source)
                        .tag(3)
                        .tabItem { Label("搜尋", systemImage: "magnifyingglass") }

                    NavigationStack {
                        HistoryView(sites: sites, source: source)
                    }
                    .tag(1)
                    .tabItem { Label("記錄", systemImage: "clock.arrow.circlepath") }

                    NavigationStack {
                        SettingsView(
                            sites: sites,
                            selectedSiteID: pickedSite,
                            source: source,
                            updatedAt: updatedAt,
                            refreshing: refreshing,
                            packStatus: packStatus,
                            onImport: { importing = true },
                            onUseRemote: { text, name in useRemote(text, named: name) },
                            onRefresh: { Task { await refreshRemote() } },
                            onOpenHome: { selectedTab = 0 },
                            saved: saved,
                            onUseSaved: { entry in use(entry) },
                            onRename: { entry, name in rename(entry, to: name) },
                            onForget: { entry in forget(entry) }
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
            await WatchHistoryStore.shared.migrateSiteIdentities(in: sites)
            // The cached pack is adopted before anything is fetched, so an offline launch runs on
            // the last known good scripts rather than waiting for the network.
            await adoptCachedSpiderPack()
            // Every launch re-fetches a remote configuration, so the app opens on the current one
            // rather than on whatever happened to be cached.
            await refreshRemote(quiet: true)
            await refreshSpiderPack()
        }
        .alert("加入設定來源", isPresented: $askingRemote) {
            TextField("名稱", text: $remoteName)
            TextField("https://…/wang-movie.json", text: $remoteText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("載入") { useRemote(remoteText, named: remoteName) }
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
    private func useRemote(_ text: String, named name: String = "") {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https", url.host?.isEmpty == false else {
            error = "請輸入 http:// 或 https:// 開頭的完整設定網址。"
            return
        }
        // Remember it before fetching, so a source that is briefly unreachable is still saved and
        // can be retried from the list instead of retyped.
        saved.upsert(SavedSource(name: name, url: url))
        persistSaved()
        Task { await load(remote: url) }
    }

    /// Switching to an already-saved source. No re-typing, and its own cache means a provider that
    /// is down right now still shows what it last served rather than nothing.
    private func use(_ entry: SavedSource) {
        Task { await load(remote: entry.url) }
    }

    private func rename(_ entry: SavedSource, to name: String) {
        var renamed = entry
        renamed.name = name
        saved.upsert(renamed)
        persistSaved()
    }

    private func forget(_ entry: SavedSource) {
        saved.remove(id: entry.id)
        persistSaved()
        // And the site it was left on: added back, it starts from its first site again.
        var memory = siteMemory()
        memory[ConfigSource.remote(entry.url).identity] = nil
        UserDefaults.standard.set(memory, forKey: siteBySourceKey)
        // The cached copy goes with it; leaving it behind would be an orphan nobody can reach.
        if let url = try? configURL(for: .remote(entry.url)) { try? FileManager.default.removeItem(at: url) }
    }

    private func persistSaved() {
        guard let url = try? savedSourcesURL(), let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func savedSourcesURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("saved-sources.json")
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
        guard let url = try? configURL(for: source), let data = try? Data(contentsOf: url),
              let config = try? ConfigLoader.validate(data) else { return }
        sites = config.drivableSites(resolvedBy: CSPSourceResolver(source: source))
        adoptAdBlocking(from: config)
        selectedSiteID = SiteSelection.choose(remembered: siteMemory()[source.identity], current: selectedSiteID,
                                              in: sites)
    }

    /// Point the sniffer at **this** configuration's ad rules and sniffer rules, and at nothing else
    /// (IOS-POC-5S-1, IOS-POC-5S-3).
    ///
    /// Called from every path that adopts a configuration — the launch restore, a fetched refresh
    /// and a pack rebuild — because both belong to whichever configuration is active, and a source
    /// switch that left the previous one's behind would block the wrong hosts or sniff by the wrong
    /// rules. A configuration with no `ads` and no `rules` sets nil for both, which is the same as
    /// having neither.
    ///
    /// **One seam, deliberately.** `rules` could have had its own adopt function, but then a fourth
    /// adopt path added later would have to remember two calls instead of one — and the failure that
    /// causes is silent, because stale rules still sniff, just by the wrong configuration's rules.
    private func adoptAdBlocking(from config: WebHTVConfig) {
        MediaSniffer.shared.adBlockList = AdBlockList.make(ads: config.ads)
        let ruleset = SnifferRules.make(rules: config.rules)
        MediaSniffer.shared.snifferRules = ruleset
        // Once per adopted configuration, never per candidate: a malformed pattern would otherwise
        // print on every URL of every sniff.
        if let bad = ruleset?.uncompilablePatterns, !bad.isEmpty {
            print("[sniffer] \(bad.count) rule pattern(s) will not compile and are treated as "
                  + "non-matching: \(bad.prefix(5).joined(separator: ", "))")
        }
    }

    /// Write, then publish. Callers validate first and hand the result in, so nothing that failed
    /// validation reaches the cached file — that is what makes a failed refresh safe.
    private func adopt(_ data: Data, config: WebHTVConfig, from source: ConfigSource) throws {
        let loaded = config.drivableSites(resolvedBy: CSPSourceResolver(source: source))
        try data.write(to: configURL(for: source), options: .atomic)
        let now = Date()
        UserDefaults.standard.set(source.baseURL?.absoluteString, forKey: configSourceURLKey)
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: configUpdatedAtKey)
        self.source = source
        updatedAt = now
        sites = loaded
        adoptAdBlocking(from: config)
        // Reclaim the spider sessions this configuration orphaned. Correctness does not depend on
        // this landing first — `SpiderSessionStore` keys on the site's `ext`, so a redefined site
        // misses the cache regardless.
        Task { await SpiderSessionStore.shared.reset() }
        selectedSiteID = SiteSelection.choose(remembered: siteMemory()[source.identity], current: selectedSiteID,
                                              in: loaded)
    }

    /// IOS-POC-19 — the pickers' binding. Only a site the viewer picks is remembered, for the source
    /// it was picked in. The automatic choices (`adopt`, `restore`, `rebuildSites`) never write, so
    /// a remembered site that is missing for now — a spider pack that has not arrived yet — is not
    /// overwritten by the first site shown in its place.
    private var pickedSite: Binding<Site.ID?> {
        Binding(get: { selectedSiteID }, set: { id in
            selectedSiteID = id
            // IOS-POC-10C: never the raw id. `Site.id` embeds a NUL and CFPreferences truncates
            // there, which is what made every launch reopen on the first source.
            let token = id.map(SiteSelection.token(for:))
            var memory = siteMemory()
            memory[source.identity] = token
            UserDefaults.standard.set(memory, forKey: siteBySourceKey)
            // Still written so that a build from before IOS-POC-19 reopens on the last pick.
            UserDefaults.standard.set(token, forKey: selectedSiteKey)
        })
    }

    private func siteMemory() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: siteBySourceKey) as? [String: String] ?? [:]
    }

    private func restore() {
        if let url = try? savedSourcesURL(), let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode(SavedSourceList.self, from: data) {
            saved = list
        }
        var restored = ConfigSource.importedFile
        if let stored = UserDefaults.standard.string(forKey: configSourceURLKey), let url = URL(string: stored) {
            restored = .remote(url)
            source = restored
            // An install from before IOS-POC-10D has a remembered URL and no saved entry, so the
            // list would come up empty for someone who is plainly using a remote source. Adopt it
            // under its host name; they can rename it.
            if saved.source(id: url.absoluteString) == nil {
                saved.upsert(SavedSource(name: url.host ?? "", url: url))
                persistSaved()
            }
        }
        // IOS-POC-19: an install from before it kept one site for whichever source was active, and
        // that source keeps it. Once: the memory's existence is the marker.
        if UserDefaults.standard.object(forKey: siteBySourceKey) == nil,
           let legacy = UserDefaults.standard.string(forKey: selectedSiteKey) {
            UserDefaults.standard.set([restored.identity: legacy], forKey: siteBySourceKey)
        }
        let stamp = UserDefaults.standard.double(forKey: configUpdatedAtKey)
        if stamp > 0 { updatedAt = Date(timeIntervalSince1970: stamp) }
        do {
            migrateLegacyCache(to: restored)
            let url = try configURL(for: restored)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            // Read the local value, not the `@State` just written: a spider's relative `ext` is
            // resolved against it, and resolving against the wrong base silently breaks those sites.
            let restoredConfig = try ConfigLoader.validate(Data(contentsOf: url))
            let loaded = restoredConfig.drivableSites(resolvedBy: CSPSourceResolver(source: restored))
            sites = loaded
            adoptAdBlocking(from: restoredConfig)
            selectedSiteID = SiteSelection.choose(remembered: siteMemory()[restored.identity], current: nil, in: loaded)
        } catch {
            self.error = "已保存的設定無法載入：\(error.localizedDescription)。請重新匯入。"
        }
    }

    /// Where a given source's configuration is cached.
    ///
    /// IOS-POC-10D gave each remote source its own file. With one shared cache, switching to B
    /// overwrote A's copy, so the next time A was unreachable the app would have shown B's sites
    /// under A's name. An imported file keeps the original filename, which is also what makes the
    /// upgrade path below work.
    private func configURL(for source: ConfigSource) throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        switch source {
        case .importedFile:
            return directory.appendingPathComponent("wang-movie.json")
        case .remote(let url):
            return directory.appendingPathComponent(SavedSource(name: "", url: url).cacheFileName)
        }
    }

    /// Carries an existing install's single cache over to its per-source home, once.
    ///
    /// Without this, upgrading looks like losing the configuration: the remembered URL is still
    /// there but its cache is under the old name, so the app would start empty and re-fetch — and
    /// show nothing at all if the provider happened to be down that minute.
    private func migrateLegacyCache(to source: ConfigSource) {
        guard case .remote = source,
              let destination = try? configURL(for: source),
              !FileManager.default.fileExists(atPath: destination.path),
              let legacy = try? configURL(for: .importedFile),
              FileManager.default.fileExists(atPath: legacy.path) else { return }
        try? FileManager.default.copyItem(at: legacy, to: destination)
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
                Text(row.displayName)
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
        // Simplified as Android does, since IOS-POC-20: the sources index simplified titles.
        if searching, !query.isEmpty { return try await client.search(TraditionalSimplified.toSimplified(query), page: page) }
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
                try await client.search(TraditionalSimplified.toSimplified(search))
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
        // IOS-POC-28: clipping hides the overflow of a filled poster but does not stop it taking
        // touches, so a wide artwork reached into the card beside it and a tap there opened this
        // title. The tappable area is the card's own shape.
        .contentShape(.rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// Searches every searchable site of the configuration in use at once (IOS-POC-20).
///
/// Its own tab, so the results stay while the user looks elsewhere, and a sheet over WebHome for
/// `app.search`. Only a submitted keyword is searched, never each keystroke: every search can leave
/// spider calls running that nothing can stop (`AggregateSearch`).
private struct AggregateSearchView: View {
    let sites: [Site]
    let source: ConfigSource
    var initialQuery: String?
    /// Presented as a sheet: closing it stops the search. A tab keeps searching while another is shown.
    var isSheet = false

    @State private var query = ""
    /// The keyword of the results on screen, which is what 載入更多 pages through.
    @State private var keyword = ""
    /// Bumped by every search, so an answer from an earlier one is never applied.
    @State private var generation = 0
    @State private var task: Task<Void, Never>?
    @State private var searching = false
    @State private var total = 0
    @State private var answered = 0
    @State private var failed = 0
    @State private var timedOut = 0
    @State private var busy = 0
    /// Sites that found something, in the order they answered: the chip order, as on Android.
    @State private var groups = [SiteHits]()
    /// The chip in use: a site's position in the searched list, or nil for 全部.
    @State private var selected: Int?

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 12)]

    private struct SiteHits {
        let index: Int
        let site: Site
        var vods: [Vod]
        var page = 1
        var canLoadMore = true
        var loadingMore = false
    }

    private struct Hit: Identifiable {
        let site: Site
        let vod: Vod
        let id: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if !groups.isEmpty { chipRow }
                if searching || answered > 0 { progressRow }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(hits) { hit in
                        NavigationLink {
                            VodView(site: hit.site, summary: hit.vod, source: source)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                VodCard(vod: hit.vod)
                                Text(hit.site.name.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            // Only a site's own chip pages, as on Android: 全部 shows first pages only.
                            if let selected, hit.id == hits.last?.id { Task { await loadMore(selected) } }
                        }
                    }
                }
                .padding(12)
                if selectedGroup?.loadingMore == true { ProgressView().padding(.bottom, 16) }
            }
            .appWallpaper()
            .overlay { emptyState }
            .navigationTitle("全站台搜尋")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜尋所有站台")
            .onSubmit(of: .search) { submit() }
            .appNavigationBar()
        }
        .task {
            guard keyword.isEmpty, let initialQuery, !initialQuery.isEmpty else { return }
            query = initialQuery
            submit()
        }
        .onDisappear { if isSheet { stop() } }
        // Results belong to the configuration they came from: a site of another one must not be paged
        // or opened through this one's resolver and watch history.
        .onChange(of: source) {
            stop()
            clear()
            keyword = ""
            generation += 1
        }
    }

    private var engine: AggregateSearch { AggregateSearch(search: Self.search(in: source)) }

    /// One page of one site, through the same client the home screen uses.
    private static func search(in source: ConfigSource) -> AggregateSearch.Search {
        { site, keyword, page in
            let client = try await SourceClient.make(site: site, resolver: CSPSourceResolver(source: source))
            return try await client.search(keyword, page: page).list
        }
    }

    private var hits: [Hit] {
        let shown = selected.map { index in groups.filter { $0.index == index } } ?? groups
        return shown.flatMap { group in
            group.vods.map { Hit(site: group.site, vod: $0, id: "\(group.index)\u{0}\($0.id)") }
        }
    }

    private var selectedGroup: SiteHits? {
        selected.flatMap { index in groups.first { $0.index == index } }
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("全部 \(groups.reduce(0) { $0 + $1.vods.count })", index: nil)
                ForEach(groups, id: \.index) { group in
                    chip("\(group.site.name.displayName) \(group.vods.count)", index: group.index)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func chip(_ title: String, index: Int?) -> some View {
        let isActive = selected == index
        return Button(title) { selected = index }
            .buttonStyle(.plain)
            .font(.subheadline.weight(isActive ? .bold : .regular))
            .foregroundStyle(isActive ? appSurface : .white)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(isActive ? .white : appSurface.opacity(0.85), in: Capsule())
    }

    private var progressRow: some View {
        HStack(spacing: 8) {
            if searching { ProgressView().controlSize(.small) }
            Text("已完成 \(answered)/\(total)")
            if !problems.isEmpty { Text(problems).foregroundStyle(.secondary) }
            Spacer()
            if searching { Button("停止") { stop() }.fontWeight(.semibold) }
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    /// The failed, timed-out and still-busy counts, leaving out the ones that are zero.
    private var problems: String {
        [("失敗", failed), ("逾時", timedOut), ("上一輪仍在執行", busy)]
            .filter { $0.1 > 0 }
            .map { "\($0.0) \($0.1)" }
            .joined(separator: "、")
    }

    @ViewBuilder private var emptyState: some View {
        if keyword.isEmpty {
            ContentUnavailableView(
                "全站台搜尋", systemImage: "magnifyingglass",
                description: Text("輸入關鍵字後按搜尋，會同時搜尋這個資訊源的 \(AggregateSearch.sites(from: sites).count) 個站台。")
            )
        } else if !groups.isEmpty {
            EmptyView()
        } else if searching {
            ProgressView("搜尋中 \(answered)/\(total)")
        } else if total == 0 {
            ContentUnavailableView("沒有可搜尋的站台", systemImage: "magnifyingglass",
                                   description: Text("這個資訊源的站台都沒有開放搜尋。"))
        } else if answered < total {
            ContentUnavailableView("已停止搜尋", systemImage: "stop.circle",
                                   description: Text("已完成 \(answered)/\(total) 個站台，還沒有結果。"))
        } else if failed + timedOut + busy == total {
            ContentUnavailableView {
                Label("搜尋失敗", systemImage: "exclamationmark.triangle")
            } description: {
                Text("\(total) 個站台都失敗、逾時或仍在執行上一輪。")
            } actions: {
                Button("重試") {
                    query = keyword
                    submit()
                }
            }
        } else {
            ContentUnavailableView("沒有找到「\(keyword)」", systemImage: "magnifyingglass",
                                   description: Text("\(total) 個站台都沒有結果。"))
        }
    }

    private func submit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stop()
        clear()
        generation += 1
        let current = generation
        keyword = text
        let targets = AggregateSearch.sites(from: sites)
        total = targets.count
        searching = true
        let reports = engine.run(targets, keyword: text)
        task = Task {
            for await report in reports {
                guard current == generation else { return }
                apply(report)
            }
            if current == generation { searching = false }
        }
    }

    /// Ending the iteration stops the search itself (`AggregateSearch.run`).
    private func stop() {
        task?.cancel()
        task = nil
        searching = false
    }

    private func clear() {
        groups = []
        selected = nil
        total = 0
        answered = 0
        failed = 0
        timedOut = 0
        busy = 0
    }

    private func apply(_ report: AggregateSearch.Report) {
        answered += 1
        switch report.outcome {
        case .found(let vods) where !vods.isEmpty:
            groups.append(SiteHits(index: report.index, site: report.site, vods: vods))
        case .found:
            break
        case .failed:
            failed += 1
        case .timedOut:
            timedOut += 1
        case .busy:
            busy += 1
        }
    }

    /// The next page of one site, for its own chip. Pagination stops when a page adds nothing or
    /// fails, as it does on the home screen.
    private func loadMore(_ index: Int) async {
        guard let position = groups.firstIndex(where: { $0.index == index }),
              groups[position].canLoadMore, !groups[position].loadingMore else { return }
        groups[position].loadingMore = true
        let current = generation
        let site = groups[position].site
        let next = groups[position].page + 1
        let page = try? await engine.page(next, of: site, keyword: keyword)
        guard current == generation, let at = groups.firstIndex(where: { $0.index == index }) else { return }
        groups[at].loadingMore = false
        let merged = groups[at].vods.merging(newTitlesFrom: page ?? [])
        guard merged.count > groups[at].vods.count else {
            groups[at].canLoadMore = false
            return
        }
        groups[at].vods = merged
        groups[at].page = next
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
    let onUseRemote: (String, String) -> Void
    let onRefresh: () -> Void
    let onOpenHome: () -> Void
    /// IOS-POC-10D
    let saved: SavedSourceList
    let onUseSaved: (SavedSource) -> Void
    let onRename: (SavedSource, String) -> Void
    let onForget: (SavedSource) -> Void

    @State private var askingRemote = false
    @State private var remoteText = ""
    @State private var remoteName = ""
    @State private var renaming: SavedSource?
    @State private var renameText = ""
    /// IOS-POC-17: `globalDefaultEngine`. Mirrored here only so the checkmark redraws.
    @State private var defaultEngine = PlaybackSession.shared.globalDefaultEngine
    /// IOS-POC-25: Android's 智慧去廣. Mirrored here only so the switch redraws.
    @State private var adSkip = PlaybackSession.shared.adSkipEnabled
    /// IOS-POC-29: the speed a new title starts at. Mirrored here only so the checkmark redraws.
    @State private var defaultSpeed = PlaybackSpeedPreference().defaultSpeed

    var body: some View {
        List {
            // IOS-POC-17. Where a new playback starts; the player's own bar can switch one session
            // without touching this. An engine that is not offered yet is listed but not choosable.
            Section {
                ForEach(PlaybackEngineKind.allCases, id: \.self) { kind in
                    let available = PlaybackSession.shared.isEngineAvailable(kind)
                    Button {
                        PlaybackSession.shared.setGlobalDefaultEngine(kind)
                        defaultEngine = kind
                    } label: {
                        HStack {
                            Text(available ? kind.displayName : "\(kind.displayName)（尚未開放）")
                                .foregroundStyle(available ? .primary : .secondary)
                            Spacer()
                            if kind == defaultEngine {
                                Image(systemName: "checkmark").foregroundStyle(appAccent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .disabled(!available)
                }
            } header: {
                Text("預設播放器")
            }

            // IOS-POC-29. Read by the next title opened; a playing one keeps its speed.
            Section {
                ForEach(PlaybackSpeedPreference.choices, id: \.self) { speed in
                    Button {
                        PlaybackSpeedPreference().setDefaultSpeed(speed)
                        defaultSpeed = speed
                    } label: {
                        HStack {
                            Text(speed.formatted(.number.precision(.fractionLength(0...2))) + "×")
                                .foregroundStyle(.primary)
                            Spacer()
                            if speed == defaultSpeed {
                                Image(systemName: "checkmark").foregroundStyle(appAccent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(speed.formatted(.number.precision(.fractionLength(0...2))) + " 倍")
                    .accessibilityAddTraits(speed == defaultSpeed ? .isSelected : [])
                }
            } header: {
                Text("預設播放速度")
            } footer: {
                Text("開新的影片時使用。同一部片換集沿用播放中調整的速度；播放中調整不會改變這裡的設定。2.5×、3× 在原生播放器不支援的影片上會改用 MPV。")
            }

            // IOS-POC-25: Android's 智慧去廣 (`Setting.isAdblock()`), on by default.
            Section {
                Toggle("智慧去廣", isOn: $adSkip)
                    .onChange(of: adSkip) { _, enabled in PlaybackSession.shared.setAdSkipEnabled(enabled) }
            } footer: {
                Text("HLS 點播影片偵測到插入的廣告片段時自動跳過。判斷不確定時照常播放。")
            }

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
                    // IOS-POC-9C: a Debug-only surface for the MPV spike. Not a player — nothing
                    // downstream routes here, and AVPlayer is still the only playback core.
                    #if DEBUG
                    NavigationLink("MPV 算繪驗證") { MPVProbeView() }
                    #endif
                }
            }

            savedSection
            sourceSection
        }
        .alert("加入設定來源", isPresented: $askingRemote) {
            TextField("名稱", text: $remoteName)
            TextField("https://…/wang-movie.json", text: $remoteText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("載入") { onUseRemote(remoteText, remoteName) }
            Button("取消", role: .cancel) {}
        }
        .alert("重新命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名稱", text: $renameText)
            Button("儲存") {
                if let entry = renaming { onRename(entry, renameText) }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
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
            Button("加入設定來源") {
                remoteText = ""
                remoteName = ""
                askingRemote = true
            }
            if isRemote {
                Button(refreshing ? "更新中…" : "重新整理", action: onRefresh).disabled(refreshing)
            }
            Button("匯入本機檔案", action: onImport)
        } header: {
            Text("設定來源")
        } footer: {
            Text("目前支援 \(sites.count) 個來源：type-0／type-1／type-4 CMS，已移植的 csp_* Spider，drpy 與 Python 腳本。腳本只從設定檔自己的來源、且必須是 HTTPS 才會載入。遠端更新失敗時會保留上一份可用設定。Spider 腳本可由設定檔旁的 ./spiders/manifest.json 熱更新，驗過 SHA-256 才會採用。")
        }
    }

    /// IOS-POC-10D. Names, not addresses — the address is what the viewer had to read before.
    @ViewBuilder var savedSection: some View {
        if !saved.sources.isEmpty {
            Section("已存來源") {
                ForEach(saved.sources) { entry in
                    Button {
                        onUseSaved(entry)
                        onOpenHome()
                    } label: {
                        HStack {
                            Text(entry.displayName).foregroundStyle(.primary)
                            Spacer()
                            if entry.id == activeSourceID {
                                Image(systemName: "checkmark").foregroundStyle(appAccent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .swipeActions(edge: .trailing) {
                        Button("刪除", role: .destructive) { onForget(entry) }
                        Button("改名") {
                            renameText = entry.name
                            renaming = entry
                        }
                        .tint(.blue)
                    }
                }
            }
        }
    }

    /// Which saved entry the live configuration came from, so the list can tick it.
    var activeSourceID: SavedSource.ID? {
        guard case .remote(let url) = source else { return nil }
        return url.absoluteString
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
    /// The episode the built-in player is on, so an auto-advance knows where it is in the line
    /// (IOS-POC-14). Held here rather than in `PlaybackSession`, which deliberately knows nothing
    /// about sites, flags or how an episode becomes a URL.
    @State private var playingEpisode: Episode?
    @State private var resolving = false
    /// What was watched last, if anything. Marks the episode in the grid (R4) and supplies the
    /// remembered quality playback starts on (R6).
    @State private var watched: WatchHistory?
    /// Which 100-episode block each flag is showing. Keyed by flag name because the lines
    /// carry different episode counts.
    @State private var episodeChunk: [String: Int] = [:]
    /// IOS-POC-10G: the line on show. Every line used to be stacked down the page with its own
    /// full grid, so a title with four lines and eighty episodes meant scrolling past three
    /// hundred buttons to reach the bottom one.
    @State private var selectedFlag: String?

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

                    if let flag = currentFlag(in: detail.flags) {
                        let blocks = episodeBlocks(of: flag)
                        // Clamped: a stale index survives a reload that returned fewer episodes.
                        let chunk = min(episodeChunk[flag.name] ?? defaultChunk(for: flag), blocks.count - 1)
                        VStack(alignment: .leading, spacing: 12) {
                            // The lines, in one row at the top. With only one there is nothing to
                            // choose, so it stays the plain heading it has always been — the same
                            // rule the block chips below already follow.
                            if detail.flags.count > 1 {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(detail.flags, id: \.name) { line in
                                            Button(line.name) { selectedFlag = line.name }
                                                .buttonStyle(.bordered)
                                                .tint(line.name == flag.name ? .accentColor : nil)
                                                .fontWeight(line.name == flag.name ? .bold : nil)
                                                .frame(minHeight: 44)
                                        }
                                    }
                                }
                            } else {
                                Text(flag.name).font(.headline)
                            }
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
            await WatchHistoryStore.shared.migrateSiteIdentities(in: [site])
            watched = await WatchHistoryStore.shared.record(forKey: historyKey)
            do {
                let client = try await SourceClient.make(site: site, resolver: CSPSourceResolver(source: source))
                detail = try await client.detail(id: summary.id)
            } catch { self.error = error.localizedDescription }
        }
        // An episode goes straight to the player (2026-09-23, the user's request): the picker page
        // in between held one button, plus a quality menu no source in this configuration fills.
        .fullScreenCover(item: $pendingPlayback, onDismiss: {
            // The hook belongs to this playback. Closing the player must not leave this screen
            // answering for a player it does not own.
            PlaybackSession.shared.onPlaylistFinished = nil
            PlaybackSession.shared.advance = nil
            // IOS-POC-15C follows `advance` exactly: same owner, same lifetime. Anything resolved
            // ahead belongs to a playback that is over, so it goes with it.
            PlaybackSession.shared.prefetchNext = nil
            PlaybackSession.shared.prefetch.invalidate()
            playingEpisode = nil
            Task { watched = await WatchHistoryStore.shared.record(forKey: historyKey) }
        }) { _ in PlayerView() }
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
    /// The line to show: the viewer's pick, else the one they last watched, else the first.
    ///
    /// Resolved against the flags actually present rather than trusted, so a reload that drops a
    /// line cannot leave the screen pointing at nothing.
    private func currentFlag(in flags: [Flag]) -> Flag? {
        if let selectedFlag, let match = flags.first(where: { $0.name == selectedFlag }) { return match }
        if let watchedFlag = watched?.vodFlag, let match = flags.first(where: { $0.name == watchedFlag }) {
            return match
        }
        return flags.first
    }

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

    /// The watch-history record for one episode of this title.
    ///
    /// One builder, because both the first play and an auto-advance need the identical nine fields
    /// and a copy that drifted in one of them would be invisible until a record went to the wrong
    /// title. `Site.id` rather than `site.key`: this configuration has four duplicate keys
    /// (IOS-POC-5L) and two providers must not share one record. `sourceID` stamps the configuration
    /// so the history list can show only what was watched on the one that is loaded (IOS-POC-10E).
    private func record(for episode: Episode, flag: String) -> WatchHistory {
        WatchHistory(key: historyKey, siteKey: site.key, siteName: site.name,
                     sourceID: source.identity, vodId: summary.id,
                     vodName: summary.name, vodPic: summary.picture,
                     vodFlag: flag, vodRemarks: episode.name, episodeUrl: episode.url)
    }

    /// What has to still be true for a pre-resolved next episode to be the right one (IOS-POC-15C).
    ///
    /// Every field is an identity this project already has: the configuration, `Site.id` rather than
    /// the site key because four keys in this configuration are duplicated, the title, the line, the
    /// episode's **address** (IOS-POC-14's rule, because a line here may print one name twice), and
    /// the quality playing now — the session's, which the control bar's quality menu updates, rather
    /// than the one this screen last read from the store (IOS-POC-15D).
    private func identity(for episode: Episode, flag: String) -> PlaybackTargetIdentity {
        PlaybackTargetIdentity(configID: source.identity, siteID: site.id, vodId: summary.id,
                               flag: flag, episodeURL: episode.url,
                               quality: PlaybackSession.shared.record?.quality ?? watched?.quality ?? "")
    }

    private func play(_ episode: Episode, flag: String) async {
        resolving = true
        defer { resolving = false }
        // A new episode, line or quality was picked by hand, so anything resolved for the old one is
        // about a playback that is no longer happening.
        PlaybackSession.shared.prefetch.invalidate()
        let began = Date()
        do {
            let client = try await SourceClient.make(site: site, resolver: CSPSourceResolver(source: source))
            guard let target = try await client.playbackURL(for: episode, flag: flag) else {
                playbackError = "這一集沒有可播放的網址。"
                return
            }
            PlaybackSession.shared.noteResolution(seconds: Date().timeIntervalSince(began),
                                                  how: "live", episode: episode.name)
            let record = record(for: episode, flag: flag)
            let playback = Playback(url: target.url, headers: target.headers,
                                    title: "\(summary.name) \(episode.name)", artwork: summary.picture,
                                    qualities: target.qualities, position: target.position,
                                    defaultIndex: target.defaultIndex,
                                    preferredQuality: watched?.quality ?? "", history: record)
            // Closing the player is this screen's to do, so the session asks rather than reaching
            // for a dismiss it has no handle on (IOS-POC-14).
            PlaybackSession.shared.onPlaylistFinished = { pendingPlayback = nil }
            playback.start()
            pendingPlayback = playback
            // What the player asks when this episode ends. This screen owns the episode list and
            // the resolving, so it is the only place that can answer (IOS-POC-14).
            playingEpisode = episode
            PlaybackSession.shared.advance = { await playNext(flag: flag) }
            // IOS-POC-15C. The session decides *when* — it holds the position, the runtime and the
            // network state; this screen decides *what*, because it holds the episode list.
            PlaybackSession.shared.prefetchNext = { await prefetchNextEpisode(flag: flag) }
        } catch {
            playbackError = error.localizedDescription
        }
    }

    /// Resolves the episode after the one playing, in the background, and keeps the result.
    ///
    /// **The same pipeline as a real play, not a copy of it.** `SourceClient.playbackURL` is the one
    /// place an episode becomes an address, so this gets `playerContent`, the CSP/Python/drpy
    /// routing, the probe, the sniff, the quality menu and the request headers by using it rather
    /// than by reimplementing any of them.
    ///
    /// Nothing is played, nothing is downloaded, and a failure is silent: `playNext` resolves
    /// normally when the episode actually ends.
    private func prefetchNextEpisode(flag: String) async {
        guard let current = playingEpisode,
              let line = detail?.flags.first(where: { $0.name == flag }),
              let next = line.episode(after: current) else { return }
        let wanted = identity(for: next, flag: flag)
        guard PlaybackSession.shared.prefetch.beginResolving(for: wanted) else { return }
        let began = Date()
        do {
            let client = try await SourceClient.make(site: site, resolver: CSPSourceResolver(source: source))
            guard let target = try await client.playbackURL(for: next, flag: flag) else {
                PlaybackSession.shared.prefetch.failed()
                PlaybackSession.log.notice("[playback] prefetch \(next.name, privacy: .public) found no address after \(Self.milliseconds(since: began))ms — an optimization miss")
                return
            }
            PlaybackSession.shared.prefetch.store(NextPlaybackTarget(identity: wanted, target: target,
                                                                     episodeName: next.name))
            PlaybackSession.log.notice("[playback] prefetched \(next.name, privacy: .public) in \(Self.milliseconds(since: began))ms")
        } catch {
            PlaybackSession.shared.prefetch.failed()
            PlaybackSession.log.notice("[playback] prefetch \(next.name, privacy: .public) failed after \(Self.milliseconds(since: began))ms: \(error.localizedDescription, privacy: .public) — an optimization miss")
        }
    }

    private static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// Resolves and starts the episode after the one playing, or answers false when the line is
    /// finished. **False is what closes the player**, so a failure to resolve must answer false too:
    /// stopping on a dead episode with the player still up would look like a freeze.
    private func playNext(flag: String) async -> Bool {
        guard let current = playingEpisode,
              let line = detail?.flags.first(where: { $0.name == flag }),
              let next = line.episode(after: current) else { return false }
        return await start(next, flag: flag, usingPrefetch: true)
    }

    /// Starts `next`, from the pre-resolved target when one is held for exactly it (IOS-POC-15C).
    ///
    /// **A prefetch can only ever save time, never cost the episode** (IOS-POC-15D). A miss of any
    /// kind resolves normally, and a pre-resolved target that then fails to load — an address that
    /// expired between the prefetch and the handoff — is resolved again, live, once.
    private func start(_ next: Episode, flag: String, usingPrefetch: Bool) async -> Bool {
        let began = Date()
        do {
            // `take` hands the address back only when every part of the identity still matches and
            // it is still fresh, and consumes it either way — a target for an episode we are no
            // longer about to play is simply wrong.
            let wanted = identity(for: next, flag: flag)
            let session = PlaybackSession.shared
            let miss = usingPrefetch ? session.prefetch.miss(for: wanted, now: began) : nil
            let prefetched = usingPrefetch ? session.prefetch.take(matching: wanted, now: began)?.target : nil
            let target: PlaybackTarget
            if let prefetched {
                target = prefetched
            } else {
                let client = try await SourceClient.make(site: site, resolver: CSPSourceResolver(source: source))
                guard let resolved = try await client.playbackURL(for: next, flag: flag) else { return false }
                target = resolved
            }
            session.noteResolution(seconds: Date().timeIntervalSince(began),
                                   how: prefetched != nil ? "prefetched"
                                       : miss.map { "live, prefetch miss: \($0.rawValue)" }
                                       ?? "live, retrying an unplayable prefetch",
                                   episode: next.name)
            let record = record(for: next, flag: flag)
            playingEpisode = next
            // The quality the viewer last chose in the bar, which `finished()` has just persisted.
            let remembered = await WatchHistoryStore.shared.record(forKey: historyKey)?.quality ?? ""
            // `resuming: false` — this is a new episode, not a reopened title, and the two share one
            // history record.
            session.open(target, preferredQuality: remembered,
                         title: "\(summary.name) \(next.name)",
                         artwork: summary.picture, history: record, resuming: false,
                         retry: prefetched == nil ? nil : { await start(next, flag: flag, usingPrefetch: false) })
            watched = await WatchHistoryStore.shared.record(forKey: historyKey)
            return true
        } catch {
            return false
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
                        // IOS-POC-30: off this source's list only, like 清除.
                        let sourceID = source.identity
                        Task {
                            for record in removing {
                                await WatchHistoryStore.shared.remove(key: record.key, for: sourceID)
                            }
                        }
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
                    // IOS-POC-30: this source's list only; another source's history stays.
                    Task { await WatchHistoryStore.shared.clear(for: source.identity) }
                }
            }
        }
        // .task runs again whenever the tab is re-entered, which is what keeps the list current
        // after a viewing without any notification plumbing.
        .task {
            await WatchHistoryStore.shared.migrateSiteIdentities(in: sites)
            records = await WatchHistoryStore.shared.records(for: source.identity)
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
    /// The headers the source says this stream needs; both internal engines send them.
    var headers: [String: String] = [:]
    var title = ""
    /// Android hands VideoActivity the poster, so player.status can report it.
    var artwork = ""
    /// The source's quality menu. One entry for every source in this configuration today.
    var qualities: [PlaybackQuality] = []
    var position = 0
    var defaultIndex = 0
    /// The quality name this title was last watched at, which outranks the source's default
    /// (D8, R6). Empty when nothing is remembered.
    var preferredQuality = ""
    /// Identity for the watch history. Nil for `player.playUrl`, which names no site or title.
    var history: WatchHistory?
    var id: String { url.absoluteString }
}

extension Playback {
    /// Starts this playback on the session — what the 播放 page's button did, without the page.
    /// The quality menu, and its remembered-or-default start, now belong to the control bar
    /// (IOS-POC-17E, `PlaybackQualityChoice`).
    @MainActor func start() {
        PlaybackSession.shared.open(
            PlaybackTarget(url: url, headers: headers, qualities: qualities, position: position,
                           defaultIndex: defaultIndex),
            preferredQuality: preferredQuality, title: title, artwork: artwork, history: history)
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

    /// What to play when this item ends and the session has no playlist of its own (IOS-POC-14).
    ///
    /// The app's own path opens **one** resolved address — a site's episode needs a `playerContent`
    /// call and possibly a sniff to become a URL, so a whole season cannot be handed over up front.
    /// The detail screen owns the episode list and the resolving, and answers here: `true` when it
    /// started the next one, `false` when there was none. Nil means the caller never had a list,
    /// which is the WebHome bridge's inline playlist and the bare-URL paths.
    var advance: (() async -> Bool)?

    /// How the presenting view closes the player once nothing is left to play.
    var onPlaylistFinished: (() -> Void)?

    /// What this playback writes into the watch history, with the position kept up to date. Nil for
    /// a path that names no title: `player.playUrl` and an inline vod both hand over bare media.
    ///
    /// Readable since IOS-POC-5S-2 so the player's opening/ending controls can show what this title
    /// is already set to. The setter stays private: `setOpening`/`setEnding` below are the only ways
    /// in, because they clamp and persist.
    private(set) var record: WatchHistory?
    /// Where to resume to, consumed by the next `load`. Resolved before playback starts so the item
    /// is never created twice or seeked after it is already running.
    private var resumeTo: Double?
    /// Whether the last sample was already past the viewer's ending, so the handoff fires once per
    /// crossing rather than once every five seconds while the advance resolves.
    private var endingReached = false
    private var sampler: Task<Void, Never>?
    /// The playback speed the viewer chose, carried across an episode change **of the same title**
    /// (IOS-POC-14A, narrowed at the user's request in IOS-POC-14B).
    ///
    /// **Why the last non-zero `rate` and not `defaultRate`.** Measured on 2026-09-22:
    /// `defaultRate` survives `replaceCurrentItem` and `play()` honours it, so if AVKit's speed menu
    /// set that property the speed would already carry over — and the viewer reported that it does
    /// not. So the chosen speed is only ever visible as `rate` while something is playing, and the
    /// end of an episode has already put that back to zero by the time the next one is asked for.
    /// Observing it is the only place the value can be caught.
    private var chosenRate: Float = 1
    private var rateObserver: NSKeyValueObservation?

    // MARK: IOS-POC-15 — what the network is doing, and what was done about it

    /// The state model. Reset with every item, because none of one stream's evidence applies to
    /// the next one.
    private var network = PlaybackNetworkMonitor()
    /// The last policy written to the item, so an unchanged one is not written again every tick.
    private var appliedPolicy: PlaybackBufferPolicy?
    /// How many variants the current asset really offers. Zero until `AVURLAsset` answers, which is
    /// the conservative reading: no resolution ceiling may be applied.
    private var variantCount = 0
    /// Stalls on the current item, from `AVPlayerItem.playbackStalledNotification` — the platform's
    /// own signal rather than anything inferred from the buffer.
    private var stalls = 0
    /// IOS-POC-27B: sampler ticks on this item, so the buffer line is written every thirtieth second.
    private var bufferReportTicks = 0
    /// Whether the next episode has already been asked for on this item. One per item is the whole
    /// of IOS-POC-15C's "pre-resolve **one**".
    private var prefetchRequested = false

    /// How long the last episode-to-address resolution took. Kept so the diagnostics can say the
    /// viewer was waiting on `playerContent`/probe/sniff rather than on the network.
    ///
    /// **Consumed by the first reading that uses it**, rather than held: it describes how this
    /// episode started, so once the first state transition has reported it the number has said
    /// everything it can. Left standing it would still be claiming, twenty minutes in, that a slow
    /// `playerContent` is what the buffer is short of — and it would leak into the bridge's bare-URL
    /// playback, which never sets one.
    private var lastResolutionSeconds: Double?

    /// Resolves the next episode in the background and keeps the result. Set by the screen that owns
    /// the episode list, alongside `advance`, and nil for every path that has no list.
    ///
    /// It answers nothing: a prefetch that fails is an optimization miss, and `advance` still
    /// resolves normally when the episode actually ends.
    var prefetchNext: (() async -> Void)?

    /// The pre-resolved next episode itself (IOS-POC-15C), held **here** since IOS-POC-15D.
    ///
    /// It used to live in the detail screen's view state, out of reach of the things that must be
    /// able to drop it — the control bar's quality menu above all. The session still knows nothing
    /// about sites, lines or how an episode becomes a URL: the identity is opaque to it, and the
    /// detail screen is still the only thing that builds one, resolves one or takes one.
    var prefetch = PlaybackTargetPrefetch()
    /// Resolves the episode just opened again, live, if its pre-resolved address turns out not to
    /// play (IOS-POC-15D). Set only by an open that used a prefetched target; spent on the first
    /// unrecoverable failure, and dropped once playback actually starts — after that a failure is
    /// the stream's, and re-opening the episode from the start would be wrong.
    private var retryWithoutPrefetch: (() async -> Bool)?

    /// The `[playback]` diagnostics (IOS-POC-15D). `Logger`, not `print`: a SideStore Release build
    /// has no debugger attached, and stdout goes nowhere there, while the unified log reaches
    /// Console.app on a Mac the phone is connected to. `.public` because every value in these lines
    /// is a timing, a count, a bitrate, an episode label, an engine or AVFoundation status, a waiting
    /// reason or an error domain and code — or, since IOS-POC-27A, something passed through
    /// `PlaybackLogRedaction`: a media address only as host and extension, and an error-log comment
    /// flattened to one line and cut to 80 characters, not otherwise redacted. Redacted numbers
    /// would measure nothing.
    static let log = Logger(subsystem: "com.webhtv.ios.poc", category: "playback")

    // IOS-POC-15D: what one item did, reported once when it is replaced or closed.
    private var itemTitle = ""
    private var loadedAt: ContinuousClock.Instant?
    private var startupMilliseconds: Int?
    private var startupWatch: Task<Void, Never>?
    /// When the engine now under the item was handed it (IOS-POC-17F): the open, or the last engine
    /// change — so an engine the viewer just picked gets its own timeout. Since IOS-POC-27A it counts
    /// only the time the viewer means it to play (`PlaybackStartupWatch`).
    private var startupClock = PlaybackStartupWatch()
    /// The zero the startup watch's seconds are counted from.
    private let clockOrigin = ContinuousClock.now
    private var monotonicSeconds: Double { (ContinuousClock.now - clockOrigin) / .seconds(1) }
    /// The prefetch in flight, so the handoff can wait for it instead of racing it.
    private var prefetchTask: Task<Void, Never>?
    /// How this item became an address. The detail screen reports it just *before* opening the
    /// item, so it waits in `nextResolution` until `load` has reported the item it replaces.
    private var resolution = ""
    private var nextResolution = ""
    private var worstState = PlaybackNetworkState.normal
    private var droppedFrames = 0
    private var limitSamples = [PlaybackLimit: Int]()

    private init() {
        // IOS-POC-15A. Stated rather than inherited: the player may wait for enough media to play
        // through, which is the behaviour every source here wants. `preferredForwardBufferDuration`
        // is deliberately **not** set at this point — see `load`.
        player.automaticallyWaitsToMinimizeStalling = true
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification, object: nil, queue: .main
        ) { note in
            // Only the item playing now (IOS-POC-15D). A stall the outgoing item posts can land after
            // the next one has reset the count, and would drop a fresh item straight to `poor`.
            // Its identity crosses to the main actor, not the item, which is not `Sendable`.
            let stalled = (note.object as AnyObject?).map(ObjectIdentifier.init)
            Task { @MainActor in
                let session = PlaybackSession.shared
                guard stalled == session.player.currentItem.map(ObjectIdentifier.init) else { return }
                session.stalls += 1
            }
        }
        rateObserver = player.observe(\.rate, options: [.new]) { player, _ in
            let rate = player.rate
            guard rate > 0 else { return }
            Task { @MainActor in PlaybackSession.shared.chosenRate = rate }
        }
        // The 5-second sampler cannot be relied on for the last few seconds before the app is
        // suspended, and those are the ones a viewer notices losing.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                PlaybackSession.shared.noteEnteredBackground()
                await PlaybackSession.shared.persist()
            }
        }
        // IOS-POC-23: the return from the background.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in PlaybackSession.shared.noteBecameActive() }
        }
        // IOS-POC-24: a call, Siri or another app's audio interrupting the session silences mpv's
        // audio unit without pausing mpv, which would go on reading as playing with its picture
        // frozen. AVPlayer pauses itself. Pausing here too makes the next play activate the session
        // and restart the audio unit.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in PlaybackSession.shared.engine?.pause() }
        }
        // IOS-POC-17. The engines sit under this session, not beside it: everything above — the
        // record, resume, the ending, auto-next, the prefetch — stays here and asks `engine`.
        // The end-of-item observer that used to be registered here lives in `AVPlayerEngine` now,
        // so an ended item reaches `finished()` the same way whichever engine played it.
        router = PlayerRouter(globalDefault: PlaybackEnginePreference().globalDefaultEngine,
                              available: PlaybackEngines.offered) { [unowned self] kind in
            kind == .native ? AVPlayerEngine(session: self) as PlaybackEngine : MPVEngine()
        }
        router.onEnded = { [weak self] in self?.finished() }
        router.onEngineChange = { [weak self] kind in
            guard let self else { return }
            // IOS-POC-26: where the engine taking over was asked to start, and how precisely.
            if let request = self.router.request {
                Self.log.notice("[playback] \(self.itemTitle, privacy: .public) on \(kind.shortName, privacy: .public) from \(request.startSeconds)s exact=\(request.exactStart ? "yes" : "no", privacy: .public)")
            }
            self.startupClock.restart(at: self.monotonicSeconds)
            // IOS-POC-25: which ads were skipped belongs to the engine that skipped them.
            self.adSkip.engineReloaded()
            // Track ids belong to one engine adapter; the other engine's would match nothing.
            self.tracksToRestore = nil
            self.mediaSelection = PlaybackMediaSelection()
            self.onMediaSelectionChange?(self.mediaSelection)
            self.onEngineChange?(kind)
        }
        router.onMediaSelectionChange = { [weak self] selection in
            guard let self else { return }
            self.mediaSelection = selection
            self.onMediaSelectionChange?(selection)
            self.restoreTracksAfterReload(selection)
        }
        router.onUnrecoverable = { [weak self] failure in
            guard let self else { return }
            // A pre-resolved address that does not play is an optimization miss, not the episode's
            // failure (IOS-POC-15D): resolve it again, live, once — and show the failure only if that
            // does not produce a playback either.
            guard let retry = self.retryWithoutPrefetch else { self.onFailure?(failure); return }
            self.retryWithoutPrefetch = nil
            Self.log.notice("[playback] prefetched address failed (\(failure.message, privacy: .public)) — resolving live")
            Task { @MainActor in
                if await retry() == false { self.onFailure?(failure) }
            }
        }
    }

    // MARK: - IOS-POC-17: the engine under the session

    private(set) var router: PlayerRouter!

    // MARK: IOS-POC-23 — paused, suspended, reloaded

    private var pausedBackground = PausedBackgroundReload()
    /// Beats while a paused player is in the background, so a suspension shows up as a gap.
    private var heartbeat: Task<Void, Never>?
    /// The embedded tracks from before a reload, selected again once the reloaded item lists its own.
    private var tracksToRestore: PlaybackMediaSelection?
    /// Kept by the player screen: AVKit or MPV has the video in a Picture in Picture window.
    var pictureInPictureActive = false

    /// The player screen's hooks: which engine is drawing, and a failure to show.
    var onEngineChange: ((PlaybackEngineKind) -> Void)?
    var onFailure: ((PlaybackFailure) -> Void)?
    /// IOS-POC-27A: a short message the player screen shows for a few seconds — why a start was
    /// handed to the other engine.
    var onNotice: ((String) -> Void)?
    var onMediaSelectionChange: ((PlaybackMediaSelection) -> Void)?
    private(set) var mediaSelection = PlaybackMediaSelection()

    var engine: PlaybackEngine? { router.engine }
    /// The engine actually playing — what the control bar shows, never the configured default.
    var engineKind: PlaybackEngineKind { router.selection.currentSessionEngine }
    var globalDefaultEngine: PlaybackEngineKind { router.selection.globalDefaultEngine }
    func isEngineAvailable(_ kind: PlaybackEngineKind) -> Bool { router.selection.isAvailable(kind) }
    /// IOS-POC-27A: whether the viewer means it to play — also while it waits for data, which
    /// `isPlaying` does not count. A switch or a quality change mid-stall used to arrive paused.
    private var intendsToPlay: Bool { (engine?.rate ?? 0) != 0 }
    /// IOS-POC-27A: what the bar's play/pause button and the spinner show.
    var activity: PlaybackActivity {
        PlaybackActivity(state: engine?.state ?? .idle, rate: engine?.rate ?? 0,
                         failed: router.failure != nil)
    }
    /// The control bar's switch: this session only, playing or paused as the viewer left it.
    func selectEngine(_ kind: PlaybackEngineKind) { router.select(kind, playing: intendsToPlay) }

    /// IOS-POC-22 — AVPlayer cannot play this item at the viewer's speed (2.5× or 3× on an item
    /// that cannot fast-forward): MPV takes it over for the rest of this session through the same
    /// hand-off as the control bar's switch — same target, episode, line and quality, where the
    /// viewer is, at that speed, playing or paused as they left it. No buffer can make AVPlayer do
    /// it (`PlaybackRateSupport`).
    func nativeCannotPlayRate(playing: Bool) {
        guard engineKind == .native, router.select(.mpv, playing: playing) else { return }
        Self.log.notice("[playback] \(self.itemTitle, privacy: .public) at \(self.chosenRate)× — AVPlayer cannot play above 2× on this item; moved to MPV")
    }
    func refreshMediaSelection() async -> PlaybackMediaSelection {
        let selection = await engine?.mediaSelection() ?? PlaybackMediaSelection()
        mediaSelection = selection
        return selection
    }

    func selectMedia(_ kind: PlaybackMediaKind, id: String) async {
        await engine?.selectMedia(kind, id: id)
    }

    /// The settings page's choice, stored for the next session.
    func setGlobalDefaultEngine(_ kind: PlaybackEngineKind) {
        PlaybackEnginePreference().setGlobalDefaultEngine(kind)
        router.setGlobalDefault(kind)
    }
    /// The player screen closed (and is not in Picture in Picture): the session override ends.
    func closePlayer() {
        // A retry belongs to a player that is open; a late failure after closing must not reopen it.
        retryWithoutPrefetch = nil
        reportItem()
        router.endSession()
    }

    /// Seconds, from whichever engine is playing. Zero when nothing is loaded.
    var position: Double { engine?.currentTime ?? 0 }
    var duration: Double { engine?.duration ?? 0 }
    var isPlaying: Bool { engine?.isPlaying ?? false }
    var bufferedUntil: Double? { engine?.bufferedUntil }
    var volume: Float {
        get { engine?.volume ?? 1 }
        set { engine?.volume = newValue }
    }

    /// One media URL: the CMS path, `player.playUrl`, and an episode picked in `VodView`.
    /// The item carries no name: the caller's title already names the episode, and `status()`
    /// appends the item name, which would otherwise report it twice.
    /// `resuming` is false when the caller is starting the **next** episode rather than reopening a
    /// title (IOS-POC-14). One record covers a whole title — `WatchHistory.key` is site plus vod,
    /// not the episode — so resuming there would seek the new episode to where the previous one
    /// stopped. The near-ending rule usually hides that; a source with no duration would not.
    func open(url: URL, headers: [String: String] = [:], title: String, artwork: String = "",
              history: WatchHistory? = nil, resuming: Bool = true,
              quality: PlaybackQualityChoice? = nil, retry: (() async -> Bool)? = nil) {
        self.quality = quality
        retryWithoutPrefetch = retry
        // The chosen speed belongs to the **title**, not to the app session (IOS-POC-14B). The
        // history key is site plus vod, so it is exactly the identity "the same film or series" —
        // which means a hand-picked episode carries the speed the same way an auto-advance does,
        // while opening something else starts over. No key at all (a bare URL from the bridge)
        // carries nothing, because there is no title to carry it within. Starting over used to mean
        // 1×; since IOS-POC-29 it is the settings page's default speed, which is 1× until changed.
        if history?.key == nil || history?.key != record?.key {
            chosenRate = PlaybackSpeedPreference().defaultSpeed
        }
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
        // The store has to be read before playback begins, and it is an actor. Resolve first and
        // start afterwards: the read is from an in-memory cache, and starting first would mean
        // seeking a stream that has already begun.
        //
        // **The read happens whether or not this is a resume** (IOS-POC-5S-2). The caller builds its
        // record template fresh from the detail screen, so the opening and ending the viewer set for
        // this title exist only in the stored copy. Carrying them over here is what stops `persist()`
        // writing the empty template back over them, and it is the one place that covers both the
        // reopen and the auto-advance — which is also why the next episode inherits the same title's
        // settings and cannot inherit the previous title's.
        Task { @MainActor in
            // IOS-POC-21: the stored position only when it is this episode's — picking another
            // episode by hand used to seek it to where the previous one stopped.
            let merged = await WatchHistoryStore.shared.record(forKey: history.key)
                .map { history.carryingOver(from: $0) } ?? history
            record = merged
            let from = merged.startPosition(resuming: resuming)
            resumeTo = from > 0 ? from : nil
            start(at: 0)
        }
    }

    /// A resolved episode: its quality menu goes to the control bar (IOS-POC-17E), starting on the
    /// remembered quality or the source's default.
    func open(_ target: PlaybackTarget, preferredQuality: String, title: String, artwork: String = "",
              history: WatchHistory?, resuming: Bool = true, retry: (() async -> Bool)? = nil) {
        let choice = PlaybackQualityChoice(target: target, preferred: preferredQuality)
        var record = history
        record?.quality = choice.name
        open(url: choice.url, headers: target.headers, title: title, artwork: artwork,
             history: record, resuming: resuming, quality: choice, retry: retry)
    }

    /// What the control bar's quality menu shows. Nil for a bare URL, which has no menu.
    private(set) var quality: PlaybackQualityChoice?

    /// The control bar's quality menu: the same episode, another entry, from where it is now and
    /// in the same play/pause state. The choice is written into the record, so the history
    /// remembers it the way the old 播放 page's menu did (5R R6).
    func selectQuality(_ entry: Int) {
        guard started, var quality, quality.select(entry) else { return }
        self.quality = quality
        record?.quality = quality.name
        // IOS-POC-15D: anything resolved ahead was resolved while the old quality played, so it goes
        // now, and the gate may resolve the next episode again if the handoff is still close. A
        // quality the viewer just chose is also not a pre-resolved address that could need a retry.
        prefetch.invalidate()
        prefetchRequested = false
        retryWithoutPrefetch = nil
        resumeTo = position > 0 ? position * 1000 : nil
        let playing = intendsToPlay
        items = [.init(name: "", url: quality.url)]
        index = 0
        load(quality.url, autoplay: playing)
    }

    /// Marks how much of this title's start to skip — Android's OP button, in the same milliseconds
    /// (IOS-POC-5S-2). The value is clamped against the runtime by `WatchHistory`.
    ///
    /// Written through `persist()` rather than saved directly, because the store drops a record with
    /// no position (`History.canSave()`) and this copy only learns the position from the player.
    func setOpening(_ value: Double) {
        guard var record else { return }
        record.setOpening(value, duration: status().duration)
        self.record = record
        Task { @MainActor in await persist() }
    }

    /// The playback speed the viewer picked, for the control bar's menu (IOS-POC-16).
    var rate: Float { chosenRate }

    /// Sets the speed and remembers it, which is the whole of 14A/14B's contract in one place.
    ///
    /// `defaultRate` is what `play()` reads, so it has to be set whether or not anything is playing
    /// — otherwise choosing a speed while paused would be forgotten the moment playback resumed.
    /// `chosenRate` is assigned directly rather than left to the `rate` observer, because that
    /// observer only ever sees a **non-zero** rate and a paused player never produces one.
    func setRate(_ value: Float) {
        chosenRate = value
        router.setRate(value)
        reapplyBufferPolicy()
    }

    /// IOS-POC-27B: a new speed moves the read-ahead target now, not at the next five-second tick.
    ///
    /// Computed from the state the monitor is already in rather than by taking a sample: `ingest`
    /// would count one more reading into the hysteresis and shorten the documented recovery. Only
    /// once the first tick has applied a policy, so the start-up path stays as IOS-POC-15 left it.
    private func reapplyBufferPolicy() {
        guard started, engineKind == .native, appliedPolicy != nil, let item = player.currentItem
        else { return }
        // IOS-POC-22: a speed this item cannot play is about to move it to MPV; its target is moot.
        if item.status == .readyToPlay,
           PlaybackRateSupport.needsOtherEngine(rate: chosenRate,
                                                canPlayFastForward: item.canPlayFastForward) { return }
        let runtime = item.duration.seconds
        let kind: PlaybackItemKind = runtime.isFinite && runtime > 0 ? .onDemand : .liveOrUnknown
        let viewerQuality = quality?.offersChoice ?? false
        let policy = PlaybackBufferPolicy.policy(
            for: network.state, kind: kind, variantCount: variantCount,
            viewerChoseQuality: viewerQuality, rate: Double(chosenRate))
        guard apply(policy, to: item) else { return }
        // Everything the transition line carries: this write can also carry a change of kind or of
        // ceiling that the next tick, finding the policy already applied, would not report.
        let line = "[playback] speed \(Self.oneDecimal(Double(chosenRate)))x → forward="
            + "\(Self.oneDecimal(policy.forwardBufferSeconds))s state=\(network.state) \(kind)"
            + " variants=\(variantCount)\(viewerQuality ? " viewer-quality" : "")"
            + " cap=\(policy.maximumResolutionHeight.map { "\($0)p" } ?? "none")"
        Self.log.notice("\(line, privacy: .public)")
    }

    /// Seeks, in seconds, clamped to the item. The control bar's scrubber and its ±10 s.
    ///
    /// Exact tolerances: a scrubber that lands somewhere other than where it was dropped reads as
    /// broken, and the ±10 s buttons are the one place a viewer counts.
    func seek(toSeconds seconds: Double) {
        guard let engine, engine.isLoaded else { return }
        let limit = engine.duration > 0 ? engine.duration : .greatestFiniteMagnitude
        engine.seek(toSeconds: adSeekTarget(min(max(seconds, 0), limit)))
    }

    /// The same for the end — Android's ED button. Milliseconds counted back from the runtime.
    func setEnding(_ value: Double) {
        guard var record else { return }
        record.setEnding(value, duration: status().duration)
        self.record = record
        Task { @MainActor in await persist() }
    }

    /// `VideoActivity.onOpening()`: mark the opening at wherever playback is **now**.
    ///
    /// The live read belongs here rather than in the view. A SwiftUI body is evaluated when the
    /// layout needs it, not when the viewer taps, so a position captured there is however old the
    /// last render is. `PlayerManager.canSetOpening` then refuses a position too deep into the
    /// runtime to be an opening, and the caller sees the refusal as a value that did not move.
    func markOpening() {
        let status = status()
        guard WatchHistory.canSetOpening(position: status.position, duration: status.duration)
        else { return }
        setOpening(status.position)
    }

    /// `VideoActivity.onEnding()`: `duration - position`, measured now and guarded the same way.
    func markEnding() {
        let status = status()
        guard WatchHistory.canSetEnding(position: status.position, duration: status.duration)
        else { return }
        setEnding(status.duration - status.position)
    }

    /// A whole inline vod, so `control("next")` and `("prev")` have somewhere to go.
    ///
    /// Not recorded: an inline vod is a page's own playlist addressed under the pseudo-site
    /// `webhome_inline`, so it has no site or vod identity the history could be keyed on.
    func open(_ vod: WebHomeBridge.InlineVod) {
        // A page's own playlist has no title identity the speed could belong to (IOS-POC-14B), so it
        // starts at the settings page's default (IOS-POC-29).
        chosenRate = PlaybackSpeedPreference().defaultSpeed
        quality = nil
        retryWithoutPrefetch = nil
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
        guard var record, started, let engine, engine.isLoaded else { return }
        if onlyWhilePlaying, engine.rate == 0 { return }
        let position = Self.milliseconds(engine.currentTime)
        guard position > 0 else { return }
        record.position = position
        record.duration = Self.milliseconds(engine.duration)
        self.record = record
        await WatchHistoryStore.shared.save(record)
    }

    /// The one timer this playback has. IOS-POC-15 rides it rather than adding a second.
    ///
    /// **The `record != nil` guard is gone (IOS-POC-15).** It stood here while the loop's only job
    /// was writing history, and a bare URL has no title to write. The loop now also carries the
    /// buffering policy, which the WebHome bridge's inline playlist and `player.playUrl` need every
    /// bit as much as a titled episode does. Nothing extra is written: `persist()` and
    /// `reachedEnding()` each already refuse without a record, and `prefetchNextIfDue()` does
    /// nothing without a `prefetchNext` closure, which only the detail screen sets.
    private func startSampling() {
        sampler?.cancel()
        sampler = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                await PlaybackSession.shared.persist(onlyWhilePlaying: true)
                // IOS-POC-15A/15B: one reading of the player, into the policy, onto the item.
                PlaybackSession.shared.observeNetwork()
                // IOS-POC-15C, before the ending check so the tick that hands over is never also
                // the tick that starts resolving.
                await PlaybackSession.shared.prefetchNextIfDue()
                // The viewer's ending is reached on the same tick that records the position, which
                // is exactly where Android checks it (IOS-POC-5S-2). `finished()` is the existing
                // end-of-episode path, so the ending gets the auto-advance, the history write and
                // the player close that a real end already got — there is no second ended pipeline.
                if PlaybackSession.shared.reachedEnding() { PlaybackSession.shared.finished() }
            }
        }
    }

    // MARK: - IOS-POC-15A/15B: measure, decide, apply

    /// Takes one reading of the player, feeds it to the state model, and writes back whatever the
    /// model asks for.
    private func observeNetwork() {
        // IOS-POC-15's policy is AVPlayer's own: it writes AVPlayerItem properties. mpv keeps its
        // own demuxer cache and is left to it.
        guard started, engineKind == .native, let item = player.currentItem else { return }
        let runtime = item.duration.seconds
        // The last access-log event is the platform's own throughput evidence: what was actually
        // observed off the wire, and what the variant currently selected costs.
        let events = item.accessLog()?.events ?? []
        let event = events.last
        // Dropped frames are counted per access-log event; the new ones since the last tick are what
        // this reading says about the decoder (IOS-POC-15D).
        let dropped = events.reduce(0) { $0 + max($1.numberOfDroppedVideoFrames, 0) }
        let newlyDropped = max(dropped - droppedFrames, 0)
        droppedFrames = dropped
        let sample = PlaybackNetworkSample(
            kind: runtime.isFinite && runtime > 0 ? .onDemand : .liveOrUnknown,
            bufferAhead: bufferAhead(of: item),
            likelyToKeepUp: item.isPlaybackLikelyToKeepUp,
            bufferEmpty: item.isPlaybackBufferEmpty,
            playing: player.timeControlStatus == .playing,
            waitingToPlay: player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
            // A paused player reports zero, but the speed the viewer chose is what the cushion will
            // be spent at the moment they press play again.
            rate: Double(player.rate > 0 ? player.rate : chosenRate),
            observedBitrate: event?.observedBitrate ?? 0,
            indicatedBitrate: event?.indicatedBitrate ?? 0,
            stalls: stalls,
            variantCount: variantCount,
            // IOS-POC-15D: a quality from the control bar's menu is the viewer's, and is never capped.
            viewerChoseQuality: quality?.offersChoice ?? false,
            droppedFrames: newlyDropped
        )

        let was = network.state
        let changed = apply(network.ingest(sample), to: item)
        worstState = min(worstState, network.state)
        let reading = PlaybackNetworkMonitor.limit(of: sample)
        if reading != .healthy { limitSamples[reading, default: 0] += 1 }

        // IOS-POC-27A: every tick the player is waiting for data, one line — why, and what it holds —
        // so a stall's cause and, to five seconds, its length reach the log. Only while waiting, so a
        // stream that plays still writes nothing here.
        if sample.waitingToPlay {
            let waiting = "[playback] waiting reason=\(player.reasonForWaitingToPlay?.rawValue ?? "none")"
                + " buffer=\(Self.oneDecimal(sample.bufferAhead))s@\(Self.oneDecimal(sample.rate))x"
                + " keepUp=\(sample.likelyToKeepUp) stalls=\(sample.stalls)"
                + " observed=\(Self.kbps(sample.observedBitrate))"
                + " indicated=\(Self.kbps(sample.indicatedBitrate)) state=\(network.state)"
            Self.log.notice("\(waiting, privacy: .public)")
        }

        // IOS-POC-27B: every thirtieth second of playback, what is actually held against the target.
        // The one measurement 27B's ceiling rests on — whether AVPlayer really reads ahead as far as
        // it is asked at 2× — and whether stalls come before or after the first one.
        bufferReportTicks += 1
        if bufferReportTicks % 6 == 0, sample.playing, let policy = appliedPolicy {
            let holding = "[playback] holding buffer=\(Self.oneDecimal(sample.bufferAhead))s"
                + "/\(Self.oneDecimal(sample.bufferAheadPlaybackSeconds))s@\(Self.oneDecimal(sample.rate))x"
                + " target=\(Self.oneDecimal(policy.forwardBufferSeconds))s state=\(network.state)"
                + " stalls=\(sample.stalls) observed=\(Self.kbps(sample.observedBitrate))"
                + " indicated=\(Self.kbps(sample.indicatedBitrate))"
            Self.log.notice("\(holding, privacy: .public)")
        }

        // **A change of policy or of state, and nothing else** — apart from the waiting line above,
        // which is the stall itself rather than a reading of it, and the half-minute buffer line
        // (IOS-POC-27B), which is the measurement a ceiling needs. A line every tick would be a
        // permanent verbose network logger in release; a transition has to get through the
        // hysteresis first, so even a genuinely flapping source cannot produce one more often than
        // every two samples. The first application counts as a change, which is the only record
        // that the VOD policy was applied at all — and, since IOS-POC-15D, so does the switch from
        // "duration unknown" to on-demand once the item becomes ready, which used to go unlogged.
        guard changed || network.state != was, let policy = appliedPolicy else { return }
        // Consumed: it describes how this episode started, and the next transition is not about that.
        let resolution = lastResolutionSeconds
        lastResolutionSeconds = nil
        let limit = PlaybackNetworkMonitor.limit(of: sample, resolutionSeconds: resolution)
        let line = "[playback] \(was) → \(network.state) \(sample.kind) limit=\(limit)"
            + " buffer=\(Self.oneDecimal(sample.bufferAhead))s"
            + "/\(Self.oneDecimal(sample.bufferAheadPlaybackSeconds))s@\(Self.oneDecimal(sample.rate))x"
            + " keepUp=\(sample.likelyToKeepUp) stalls=\(sample.stalls) dropped=\(dropped)"
            + " observed=\(Self.kbps(sample.observedBitrate))"
            + " indicated=\(Self.kbps(sample.indicatedBitrate))"
            + " variants=\(sample.variantCount)\(sample.viewerChoseQuality ? " viewer-quality" : "")"
            + " → forward=\(Self.oneDecimal(policy.forwardBufferSeconds))s"
            + " cap=\(policy.maximumResolutionHeight.map { "\($0)p" } ?? "none")"
        Self.log.notice("\(line, privacy: .public)")
    }

    /// Seconds of media held in front of the playhead.
    ///
    /// The loaded range **containing the playhead**, not `loadedTimeRanges.first`. After a seek the
    /// player keeps more than one range, and the first is often the part already watched — which
    /// would report a comfortable cushion at the exact moment there is none.
    private func bufferAhead(of item: AVPlayerItem) -> Double {
        let now = player.currentTime()
        guard let range = item.loadedTimeRanges
            .map(\.timeRangeValue)
            .first(where: { $0.containsTime(now) }) else { return 0 }
        let ahead = (range.end - now).seconds
        return ahead.isFinite && ahead > 0 ? ahead : 0
    }

    /// Writes a changed policy onto the item, and answers whether it changed. An unchanged one is not
    /// rewritten every five seconds.
    private func apply(_ policy: PlaybackBufferPolicy, to item: AVPlayerItem) -> Bool {
        guard policy != appliedPolicy else { return false }
        appliedPolicy = policy
        item.preferredForwardBufferDuration = policy.forwardBufferSeconds
        item.preferredPeakBitRate = policy.peakBitRate
        // `preferredMaximumResolution` is a pixel box, so a height ceiling is written as the width
        // 16:9 implies. AVPlayer picks the largest variant that **fits inside** the box, so a 4:3
        // variant of the same height (960×720 inside 1280×720) is still allowed — the ceiling stays
        // a ceiling on height, which is what the policy means.
        item.preferredMaximumResolution = policy.maximumResolutionHeight
            .map { CGSize(width: CGFloat($0) * 16 / 9, height: CGFloat($0)) } ?? .zero
        return true
    }

    /// How many variants this asset genuinely offers — the only thing that may unlock a resolution
    /// ceiling, and the platform's own answer rather than a guess from the URL or a parse of the
    /// playlist.
    ///
    /// Asked once per item, and **only the count crosses back**: `AVAssetVariant` is not `Sendable`
    /// and the policy needs nothing else from it. Until it answers the count stays zero, which is
    /// the conservative reading — a direct MP4 and a single-variant HLS are never capped.
    private func loadVariantCount(of asset: AVURLAsset) {
        Task { @MainActor in
            let count = (try? await asset.load(.variants))?.count ?? 0
            // The viewer may have moved on while the playlist loaded.
            guard player.currentItem?.asset === asset else { return }
            variantCount = count
            let kind = count > 1 ? "adaptive, a ceiling may apply" : "single stream, never capped"
            Self.log.notice("[playback] item variants=\(count) \(kind, privacy: .public)")
        }
    }

    /// Records how long an episode took to become an address, for the diagnostics (IOS-POC-15B).
    ///
    /// `how` is `live`, `prefetched`, or — since IOS-POC-15D — `live` with the reason the prefetch
    /// missed, so a slow handoff can be told apart as "never asked", "asked too late", "the source
    /// failed" or "no longer the right episode".
    func noteResolution(seconds: Double, how: String, episode: String) {
        lastResolutionSeconds = seconds
        nextResolution = "\(Int(seconds * 1000))ms (\(how))"
        Self.log.notice("[playback] resolve \(episode, privacy: .public) \(how, privacy: .public) \(Int(seconds * 1000))ms")
    }

    // MARK: - IOS-POC-15C: ask for the next episode, once

    /// Asks the screen that owns the episode list to resolve the next one — once per item, only
    /// when this one is stable and only when the handoff is close.
    private func prefetchNextIfDue() async {
        guard started, let prefetchNext, let engine, engine.isLoaded else { return }
        guard PlaybackPrefetchGate.shouldPrefetch(
            position: engine.currentTime,
            duration: engine.duration,
            // The viewer's own ending is where this episode actually hands over (IOS-POC-5S-2), so
            // it is what the lead window is measured back from.
            endingSeconds: (record?.endingOffset ?? 0) / 1000,
            // The network model is fed by AVPlayer alone; under MPV it would still hold the last
            // native item's verdict and could keep MPV from ever prefetching (IOS-POC-15D).
            state: engineKind == .native ? network.state : .normal,
            // One gate, not two: "already asked on this item" is what `alreadyHolding` means, and
            // the tested rule is the one running.
            alreadyHolding: prefetchRequested
        ) else { return }
        // Set before starting: this loop ticks again in five seconds, and a slow source would
        // otherwise be asked twice.
        prefetchRequested = true
        // Not awaited (IOS-POC-15D): a resolve that sniffs can take seconds, and the sampler must
        // keep checking the viewer's ending while it runs.
        prefetchTask = Task { await prefetchNext() }
    }

    private static func kbps(_ bits: Double) -> String {
        bits.isFinite && bits > 0 ? "\(Int(bits / 1000))k" : "?"
    }

    private static func oneDecimal(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f", value) : "?"
    }

    /// Whether the viewer's ending has *just* been reached — `VideoActivity.onTimeChanged()`'s
    /// `ending > 0 && duration > 0 && ending + position >= duration`, on this project's five-second
    /// sampler instead of Android's one-second clock.
    ///
    /// True on the rising edge only. Handing off is asynchronous — resolving the next episode costs
    /// a `playerContent` call and sometimes a sniff — so without the edge a second sample five
    /// seconds later would ask for the episode after that one. Replaying or advancing puts the
    /// position back below the threshold, which clears the flag by itself, so looping still works.
    ///
    /// ponytail: up to five seconds of the ending can play before the skip, because this rides the
    /// sampler that was already measuring both numbers. A one-second `addPeriodicTimeObserver`, or
    /// `AVPlayerItem.forwardPlaybackEndTime` set once the duration is known, buys exact timing if
    /// that lag is ever worth its own machinery.
    private func reachedEnding() -> Bool {
        guard let record, started, let engine, engine.rate > 0, engine.isLoaded else {
            endingReached = false
            return false
        }
        let reached = record.hasReachedEnding(position: Self.milliseconds(engine.currentTime),
                                              duration: Self.milliseconds(engine.duration))
        defer { endingReached = reached }
        return reached && !endingReached
    }

    // MARK: - IOS-POC-23: paused in the background, suspended, loaded again on return

    /// A paused player the viewer is looking at: open, loaded or still loading, paused, not in
    /// Picture in Picture, and not showing a failure — the one state a reload on return puts back
    /// exactly as it was. MPV reports a load in progress as not loaded yet, hence `.preparing`.
    private var isPausedOnScreen: Bool {
        guard router.sessionActive, router.failure == nil, started, let engine,
              engine.isLoaded || engine.state == .preparing else { return false }
        return engine.rate == 0 && !pictureInPictureActive
    }

    /// Where a reload starts. An item still preparing has not reached its own start yet, so it keeps
    /// the one it was asked for; a live stream (no duration) goes back to its live edge.
    private var reloadPosition: Double {
        guard let engine else { return 0 }
        if engine.state == .preparing { return router.request?.startSeconds ?? 0 }
        return engine.duration > 0 ? engine.currentTime : 0
    }

    private func noteEnteredBackground() {
        let eligible = isPausedOnScreen
        pausedBackground.enteredBackground(eligible: eligible, position: reloadPosition, at: .now)
        heartbeat?.cancel()
        heartbeat = nil
        guard eligible else { return }
        heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: PausedBackgroundReload.heartbeat)
                if Task.isCancelled { return }
                self.pausedBackground.stillRunning(at: .now)
            }
        }
    }

    private func noteBecameActive() {
        heartbeat?.cancel()
        heartbeat = nil
        guard let seconds = pausedBackground.becameActive(at: .now) else { return }
        reloadPaused(at: seconds)
    }

    /// Loads the paused item again where the viewer left it — what closing and reopening the player
    /// did for them: the same engine, address and headers, still paused. The startup watch is not
    /// re-armed. It was left out because its timeout hands over with autoplay and a paused reload
    /// must never start playing by itself; since IOS-POC-27A a paused player no longer times out at
    /// all, but this path was accepted on the device without the watch (IOS-POC-23) and re-arming
    /// it is listed under IOS-POC-27C. A pre-resolved address's live retry would start it too, so it
    /// goes.
    private func reloadPaused(at seconds: Double) {
        guard isPausedOnScreen, let engine else { return }
        var line = "[lifecycle] \(itemTitle) suspended while paused: reloading on \(engineKind.shortName)"
            + " at \(Int(seconds))s state=\(engine.state)"
        if engineKind == .native {
            line += " control=\(player.timeControlStatus.rawValue)"
                + " waiting=\(player.reasonForWaitingToPlay?.rawValue ?? "none")"
        }
        Self.log.notice("\(line, privacy: .public)")
        startupWatch?.cancel()
        retryWithoutPrefetch = nil
        tracksToRestore = mediaSelection
        adSkip.engineReloaded()
        router.reload(at: seconds, autoplay: false)
    }

    /// A reloaded item picks its own default tracks. The viewer's choice goes back once the item has
    /// listed what it offers — the first listing with any tracks settles it.
    private func restoreTracksAfterReload(_ selection: PlaybackMediaSelection) {
        guard let saved = tracksToRestore, selection.audio != nil || selection.subtitle != nil
        else { return }
        tracksToRestore = nil
        let choices = saved.reselections(after: selection)
        guard !choices.isEmpty else { return }
        Task { @MainActor in
            for (kind, id) in choices { await self.selectMedia(kind, id: id) }
        }
    }

    /// IOS-POC-24: the app is the one owner of the audio session both engines share; mpv is told to
    /// leave it alone (`MPVPlayerCore`). The system deactivates it when it suspends the app or a call
    /// or Siri interrupts it, and mpv's audio unit, unlike AVPlayer, does not activate it again, so every
    /// start of playback does. Deferred to the play itself, as Apple advises, so returning to a
    /// paused player does not interrupt another app's audio (IOS-POC-23). Activating an active
    /// session is harmless, and a failure is tried again on the next play.
    /// mpv used to set the category on every audio output it made; now only launch does, so a reset
    /// of the media services (which falls back to the default category) is repaired here too.
    static func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playback || session.mode != .moviePlayback
                || !session.categoryOptions.isEmpty {
                try session.setCategory(.playback, mode: .moviePlayback)
            }
            try session.setActive(true)
        } catch {
            log.notice("[audio] session not activated: \(error.localizedDescription, privacy: .public)")
        }
    }

    func control(_ action: String) {
        switch action {
        case "play":
            // IOS-POC-23: playing again leaves nothing to reload.
            pausedBackground.cancel()
            Self.activateAudioSession()
            engine?.play()
        case "pause": engine?.pause()
        case "stop":
            // No foreground service to stop, so the equivalent is to drop what is loaded.
            retryWithoutPrefetch = nil
            reportItem()
            Task { @MainActor in await persist() }
            sampler?.cancel()
            adWatch?.cancel()
            router.stop()
            started = false
        case "prev": start(at: index - 1)
        case "next": start(at: index + 1)
        case "loop": looping.toggle()
        case "replay":
            Self.activateAudioSession()
            // Android's repeat seeks to 0 as a viewer's seek: a pre-roll is skipped again.
            engine?.seek(toSeconds: adSeekTarget(0))
            engine?.play()
        default: break
        }
    }

    /// `server/process/Media.java`. Durations and positions are milliseconds, as Media3 reports them.
    func status() -> WebHomeBridge.PlaybackStatus {
        guard started, let engine, engine.isLoaded else { return .idleStatus }
        return .init(
            state: Self.androidState(engine.state),
            speed: Double(engine.rate),
            duration: Self.milliseconds(engine.duration),
            position: Self.milliseconds(engine.currentTime),
            url: url,
            title: [title, items.indices.contains(index) ? items[index].name : ""]
                .filter { !$0.isEmpty }.joined(separator: " "),
            artwork: artwork
        )
    }

    /// Media3's state numbers, which is what `player.status` reports.
    private static func androidState(_ state: PlaybackEngineState) -> Int {
        switch state {
        case .playing: return 3
        case .buffering: return 6
        case .ready: return 2
        case .idle, .preparing: return 1
        }
    }

    private static func milliseconds(_ seconds: Double) -> Double {
        seconds.isFinite ? (seconds * 1000).rounded() : 0
    }

    private func finished() {
        if looping { control("replay"); return }
        Task { @MainActor in
            // Record the end **before** moving on, and await it. The comment here always claimed
            // this ordering; the code did not, and an un-awaited write races whatever reads the
            // store next — which since IOS-POC-14 includes the resume lookup for the episode about
            // to start.
            await persist()
            // No prefetch may start from here on (IOS-POC-15D). The sampler keeps ticking while the
            // next episode resolves, and a prefetch it started now would be for the same episode:
            // the sniffer runs one page at a time and cancels the older one, which is the handoff's.
            prefetchRequested = true
            // And one already running is waited for: a second resolve of the same episode would
            // have its sniff cancelled by, or cancel, the first one's.
            await prefetchTask?.value
            // An inline playlist knows its own next item. This is the WebHome bridge's path and is
            // unchanged.
            if items.indices.contains(index + 1) { start(at: index + 1); return }
            // Otherwise ask whoever opened the player. No answer, or no next episode, ends it.
            if await advance?() == true { return }
            onPlaylistFinished?()
        }
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

    /// IOS-POC-17: what every path opens, engine-agnostic. The engine the router picks does the
    /// media part; the position to resume at and the speed travel in the request.
    private func load(_ url: URL, autoplay: Bool = true) {
        // IOS-POC-23: a position or tracks kept for the previous item mean nothing for this one, and
        // an item that starts playing needs the audio session active.
        pausedBackground.cancel()
        tracksToRestore = nil
        if autoplay { Self.activateAudioSession() }
        reportItem()
        itemTitle = title
        resolution = nextResolution
        nextResolution = ""
        worstState = .normal
        droppedFrames = 0
        limitSamples = [:]
        watchStartup()
        self.url = url.absoluteString
        started = true
        prefetchRequested = false
        prefetchTask = nil
        let start = resumeTo.map { $0 / 1000 } ?? 0
        resumeTo = nil
        router.open(PlaybackLoadRequest(target: PlaybackTarget(url: url, headers: headers),
                                        startSeconds: start, rate: chosenRate, autoplay: autoplay,
                                        title: title, history: record))
        startSampling()
        watchAds(url)
    }

    // MARK: - IOS-POC-25: HLS mid-stream ads

    /// The item's ad plan and every skip decision over it, one for both engines (`HLSAdSkipper`).
    private var adSkip = HLSAdSkipper()
    private var adWatch: Task<Void, Never>?
    /// Android's 智慧去廣 switch, on by default; the settings page changes it.
    private(set) var adSkipEnabled = HLSAdSkipPreference().enabled

    func setAdSkipEnabled(_ enabled: Bool) {
        HLSAdSkipPreference().setEnabled(enabled)
        adSkipEnabled = enabled
    }

    /// Where the viewer's own ending hands over, in seconds, when they set one (IOS-POC-5S-2).
    private var adEndingThreshold: Double? {
        guard let ending = record?.endingOffset, ending > 0, let engine, engine.duration > 0 else { return nil }
        return max(engine.duration - ending / 1000, 0)
    }

    /// A new item: its playlist is read once the engine has opened it, then the playhead is
    /// followed and each range the plan trusts is seeked past. An address that is not HLS, or a
    /// plan with nothing to skip, ends the watch at once — that item plays exactly as before.
    private func watchAds(_ url: URL) {
        adWatch?.cancel()
        adWatch = nil
        let generation = adSkip.begin(url: url)
        guard !adSkip.isSettled else { return }
        let headers = self.headers
        adWatch = Task { @MainActor in
            while !Task.isCancelled, let pause = self.adTick(generation: generation, url: url, headers: headers) {
                try? await Task.sleep(for: pause)
            }
        }
    }

    /// One reading of whichever engine is playing. Answers when to read again, or nil to stop.
    private func adTick(generation: Int, url: URL, headers: [String: String]) -> Duration? {
        guard adSkip.generation == generation, !adSkip.isSettled else { return nil }
        guard started, let engine else { return .milliseconds(250) }
        let duration = engine.duration
        if let planned = adSkip.planRequest(enabled: adSkipEnabled, duration: duration) {
            // Off the main actor: two readings of a playlist, and a detector pass over each.
            Task.detached(priority: .utility) {
                let plan = await HLSAdPlanner.plan(for: url, fetch: HLSAdPlanner.fetcher(headers: headers))
                await MainActor.run { PlaybackSession.shared.adoptAdPlan(plan, for: planned) }
            }
        }
        guard adSkip.plan != nil else { return .milliseconds(250) }
        let position = engine.currentTime
        let rate = engine.rate
        let wasSuspended = adSkip.suspensionReason != nil
        let target = adSkip.automaticTarget(position: position, duration: duration, rate: rate,
                                            playing: engine.isPlaying, engine: engine.kind,
                                            enabled: adSkipEnabled, endingThreshold: adEndingThreshold,
                                            now: .now)
        if !wasSuspended, let reason = adSkip.suspensionReason {
            Self.log.notice("[adskip] \(self.itemTitle, privacy: .public) stopped on \(engine.kind.shortName, privacy: .public): \(reason, privacy: .public)")
        }
        if let target {
            Self.log.notice("[adskip] \(self.itemTitle, privacy: .public) skip from=\(Int(position * 1000))ms to=\(Int(target * 1000))ms on \(engine.kind.shortName, privacy: .public)")
            engine.seek(toSeconds: target)
            return .milliseconds(100)
        }
        // Paused or stalled: read often enough that playing again is seen at once.
        guard engine.isPlaying else { return .milliseconds(100) }
        // Wake at the next range's start rather than a tick after it.
        guard let until = adSkip.secondsUntilNextRange(position: position, rate: rate, engine: engine.kind,
                                                       duration: duration, enabled: adSkipEnabled)
        else { return .milliseconds(250) }
        return .milliseconds(Int((until > 0 ? min(max(until, 0.01), 0.1) : 0.1) * 1000))
    }

    private func adoptAdPlan(_ plan: HLSAdPlan, for generation: Int) {
        guard adSkip.adopt(plan, for: generation) else { return }
        let ranges = plan.timeline.ranges.map { "\($0.startMs)-\($0.endMs)" }.joined(separator: ",")
        Self.log.notice("[adskip] \(self.itemTitle, privacy: .public) plan \(plan.timeline.reason, privacy: .public) ranges=\(ranges.isEmpty ? "none" : ranges, privacy: .public) discontinuity=\(plan.hasDiscontinuity ? "yes" : "no", privacy: .public)")
    }

    /// A seek the viewer makes into a detected ad lands at its end; any other is left alone.
    private func adSeekTarget(_ seconds: Double) -> Double {
        guard let engine else { return seconds }
        let target = adSkip.manualTarget(seconds, duration: engine.duration, engine: engine.kind,
                                         enabled: adSkipEnabled, endingThreshold: adEndingThreshold, now: .now)
        if target != seconds {
            Self.log.notice("[adskip] \(self.itemTitle, privacy: .public) seek into an ad at \(Int(seconds * 1000))ms lands at \(Int(target * 1000))ms")
        }
        return target
    }

    /// How long this item took from being opened to actually playing (IOS-POC-15D) — the number to
    /// compare before and after a prefetch, beside the resolve time. Engine-agnostic: it asks the
    /// engine whether it is playing, so MPV is measured the same way. Reaching playback is also what
    /// retires the retry of a pre-resolved address.
    ///
    /// ponytail: a tenth-of-a-second poll that ends when playback starts or the item is replaced,
    /// stopped or closed (`reportItem` cancels it); an engine callback for "started" would be exact
    /// if this is ever too coarse. Under MPV "playing" is read from mpv's pause state, so it can come
    /// slightly before the first frame.
    ///
    /// IOS-POC-17F: the same watch is what notices a start that never comes. An engine still
    /// preparing or buffering `PlayerRouter.startupTimeout(for:)` after it was handed the item is
    /// replaced by the other engine — once per attempt, never as an error. `ready` (loaded but
    /// paused) is not a stuck start and is left alone.
    ///
    /// IOS-POC-27A: only the time the viewer means it to play counts, so a viewer who pauses a slow
    /// start is not switched and played anyway; and a native start that is given up on says why.
    private func watchStartup() {
        startupWatch?.cancel()
        loadedAt = .now
        startupClock.restart(at: monotonicSeconds)
        startupMilliseconds = nil
        startupWatch = Task { @MainActor in
            while !Task.isCancelled {
                if let engine, !engine.isPlaying {
                    let stuck = engineKind
                    // On AirPlay or in AVKit's PiP window, MPV would take the video off the TV or
                    // out of the window, so a native start keeps the pre-27A 20 s there.
                    let presentedElsewhere = stuck == .native
                        && (player.isExternalPlaybackActive || pictureInPictureActive)
                    let timeout = PlayerRouter.startupTimeout(for: presentedElsewhere ? .mpv : stuck)
                    // The switch restarts the clock for the engine taking over, through `onEngineChange`.
                    if startupClock.timedOut(now: monotonicSeconds, intends: engine.rate != 0,
                                             stuck: [.preparing, .buffering].contains(engine.state),
                                             timeout: timeout) {
                        // Read before the switch: handing over tears the native item down, and its
                        // error log with it.
                        let diagnosis = stuck == .native ? nativeStartupDiagnosis() : nil
                        if router.startupTimedOut() {
                            Self.log.notice("[playback] \(self.itemTitle, privacy: .public) not started on \(stuck.shortName, privacy: .public) after \(Int(timeout))s — trying \(self.engineKind.shortName, privacy: .public)")
                            if let diagnosis {
                                Self.log.notice("\(diagnosis.line, privacy: .public)")
                                onNotice?(diagnosis.reason.notice(from: stuck, to: engineKind))
                            }
                        }
                    }
                }
                if let engine, engine.isPlaying, let loadedAt {
                    let milliseconds = Int((ContinuousClock.now - loadedAt) / .milliseconds(1))
                    startupMilliseconds = milliseconds
                    retryWithoutPrefetch = nil
                    Self.log.notice("[playback] started \(self.itemTitle, privacy: .public) on \(self.engineKind.shortName, privacy: .public) in \(milliseconds)ms after open; resolve \(self.resolution, privacy: .public)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// IOS-POC-27A: what the native item holds when its start is given up on — its status, why the
    /// player waits, and the last error-log entry — as one log line and the reason the screen shows.
    /// The line is public, and a media address carries tokens, so addresses and free text go through
    /// `PlaybackLogRedaction`; the entry's `uri` and `serverAddress` never go in whole.
    private func nativeStartupDiagnosis() -> (line: String, reason: PlaybackStartupReason)? {
        guard let item = player.currentItem else { return nil }
        let events = item.errorLog()?.events ?? []
        let status = events.reversed().lazy
            .compactMap { PlaybackFailure.httpStatus(statusCode: $0.errorStatusCode, comment: $0.errorComment) }
            .first
        let last = events.last
        let waiting = player.reasonForWaitingToPlay
        let reason = PlaybackStartupReason(httpStatus: status, ready: item.status == .readyToPlay,
                                           tooSlow: waiting == .toMinimizeStalls,
                                           evaluating: waiting == .evaluatingBufferingRate)
        let itemError = item.error as NSError?
        let line = "[playback] native start given up: reason=\(reason) item=\(item.status.rawValue)"
            + " control=\(player.timeControlStatus.rawValue)"
            + " waiting=\(waiting?.rawValue ?? "none")"
            + " error-log=\(events.count)"
            + " last=\(last.map { "\($0.errorDomain) \($0.errorStatusCode)" } ?? "none")"
            + " comment=\(PlaybackLogRedaction.comment(last?.errorComment))"
            + " uri=\(PlaybackLogRedaction.urlSummary(last?.uri))"
            + " item-error=\(itemError.map { "\($0.domain) \($0.code)" } ?? "none")"
            + " buffer=\(Self.oneDecimal(bufferAhead(of: item)))s"
        return (line, reason)
    }

    /// One line per item when it is replaced, stopped or closed (IOS-POC-15D): how it started, and
    /// what held it back — enough to tell a slow provider or resolver, a thin buffer, a weak CDN, too
    /// large a variant and a struggling decoder apart without reading every transition.
    private func reportItem() {
        guard loadedAt != nil else { return }
        startupWatch?.cancel()
        loadedAt = nil
        let startup = startupMilliseconds.map { "\($0)ms" } ?? "never"
        var line = "[playback] summary \(itemTitle) engine=\(engineKind.shortName)"
            + " resolve=\(resolution.isEmpty ? "n/a" : resolution) startup=\(startup)"
        // The network reading is AVPlayer's; MPV's cache is measured in its own parity stage.
        if engineKind == .native {
            let limits = limitSamples.isEmpty ? "none"
                : limitSamples.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ",")
            line += " stalls=\(stalls) worst=\(worstState) final=\(network.state)"
                + " dropped=\(droppedFrames) limits=\(limits) variants=\(variantCount)"
        }
        Self.log.notice("\(line, privacy: .public)")
    }

    /// The AVPlayer half of what `load` used to do, unchanged apart from reading the request.
    /// `AVPlayerEngine.load` is its only caller.
    fileprivate func loadNative(_ request: PlaybackLoadRequest) {
        let asset = Self.asset(for: request.target.url, headers: request.target.headers)
        let item = AVPlayerItem(asset: asset)

        // **The viewer's silent 2.5× and 3×, reported 2026-09-23.**
        //
        // `AVAudioTimePitchAlgorithmLowQualityZeroLatency` supports exactly 0.5, 0.666, 0.8, 1,
        // 1.25, 1.5 and 2 — and **drops the audio entirely at any other rate**. That list is the
        // viewer's report: the speeds that go silent are precisely the two IOS-POC-16 added which
        // are not on it. `.timeDomain` covers 1/32× to 32×, keeps pitch, and is the cheaper of the
        // two algorithms that do, which matters for speech at 3× on a phone.
        //
        // Set on the item because that is where the property lives; a player-level default would
        // not survive `replaceCurrentItem`.
        item.audioTimePitchAlgorithm = .timeDomain

        // IOS-POC-15A. `preferredPeakBitRate` is **0 and stays 0**: it is a ceiling on what AVPlayer
        // may download, not a way to make it download faster, so a fixed low value would pin a good
        // connection to a bad picture for the whole episode. Nothing `PlaybackBufferPolicy` returns
        // can raise it off zero — `noStateEverCapsPeakBitRate` is that assertion.
        item.preferredPeakBitRate = 0
        // `preferredForwardBufferDuration` is deliberately **not** set here. Until the item is ready
        // its duration is unknown, and live playback must not inherit a minute of VOD buffering; the
        // first sampler tick applies the policy once the runtime can actually be read. That also
        // keeps the start-up path exactly as it was, so nothing that opened before can open slower.

        // A new item is a new network. None of the previous stream's evidence applies to it.
        network = PlaybackNetworkMonitor()
        appliedPolicy = nil
        variantCount = 0
        stalls = 0
        bufferReportTicks = 0

        player.replaceCurrentItem(with: item)
        loadVariantCount(of: asset)
        // Carry the viewer's speed into the next episode. `defaultRate` is what `play()` reads, and
        // setting it before the call is what makes the new item start at that speed rather than
        // starting at 1× and being corrected a moment later.
        player.defaultRate = request.rate
        if request.startSeconds > 0 {
            // A seek issued now is honoured once the item is ready, which is why it goes before
            // play() rather than behind a readiness observer.
            let start = CMTime(seconds: request.startSeconds, preferredTimescale: 1000)
            if request.exactStart {
                // IOS-POC-26: a switch, fallback or reload lands where the viewer was, as mpv's
                // `start` and Android's ExoPlayer do. The default tolerance lands on the keyframe
                // before it; exact costs the decode from that keyframe, which mpv already pays.
                player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
            } else {
                player.seek(to: start)
            }
        }
        // A manual engine switch from a paused player loads paused (IOS-POC-17).
        guard request.autoplay else { return }
        player.play()
        // `play()` uses `defaultRate`, but AVKit is free to set `rate` directly, so state it once
        // more against the player that is now running.
        if request.rate != 1 { player.rate = request.rate }
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

/// IOS-POC-17 — which engines a viewer may be offered.
///
/// **Both, in every build, at the user's decision on 2026-09-23 (IOS-POC-17E).** Until then a
/// release build offered AVPlayer alone because MPV's first frame had been seen on the simulator
/// (IOS-POC-9G) and not on a device. What still guards a viewer from a black screen is
/// `MPVEngine`'s first-frame watchdog: a file that loads without a frame is a capability failure,
/// and the router hands the same target back to AVPlayer.
enum PlaybackEngines {
    static let offered: Set<PlaybackEngineKind> = [.native, .mpv]
}

/// IOS-POC-17 — AVPlayer as an engine: the one `AVPlayer` `PlaybackSession` has always owned.
///
/// **A thin adapter on purpose.** Item creation, the 2.5×/3× audio fix and IOS-POC-15's buffer
/// policy stay in `PlaybackSession.loadNative` and its sampler exactly where they were; this answers
/// the engine contract with the same `AVPlayer` calls the session used to make directly.
@MainActor
final class AVPlayerEngine: PlaybackEngine {
    let kind = PlaybackEngineKind.native
    var onFailure: ((Error, Int?) -> Void)?
    var onEnded: (() -> Void)?
    var onMediaSelectionChange: ((PlaybackMediaSelection) -> Void)?

    private unowned let session: PlaybackSession
    private var player: AVPlayer { session.player }
    private var observers = [NSObjectProtocol]()
    private var itemStatus: NSKeyValueObservation?
    /// `.failed` is terminal and the failure notification can follow it: one report per item.
    private weak var reportedItem: AVPlayerItem?
    private var lastAudioDiagnostic = ""

    init(session: PlaybackSession) {
        self.session = session
        let center = NotificationCenter.default
        // Moved here from `PlaybackSession.init`, unchanged: any item of the one player ending.
        observers.append(center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onEnded?() }
        })
        // Until IOS-POC-17 a failed item was a silent black screen. Now it is classified: shown,
        // or — when it is the media AVFoundation cannot handle — handed to the other engine.
        observers.append(center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in self?.report(error) }
        })
        itemStatus = session.player.observe(\.currentItem?.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                switch self.player.currentItem?.status {
                case .failed:
                    self.report(self.player.currentItem?.error)
                case .readyToPlay:
                    self.checkRate()
                    await self.refreshMediaSelection()
                default:
                    break
                }
            }
        }
    }

    func load(_ request: PlaybackLoadRequest) {
        lastAudioDiagnostic = ""
        onMediaSelectionChange?(PlaybackMediaSelection())
        session.loadNative(request)
    }
    func play() { player.play() }
    func pause() { player.pause() }

    /// Exact tolerances, as the control bar's scrubber and ±10 s always had.
    func seek(toSeconds seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    var currentTime: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    var duration: Double {
        guard let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0
        else { return 0 }
        return seconds
    }

    var rate: Float { player.rate }

    /// `defaultRate` is what `play()` reads, so it is set whether or not anything is playing.
    func setRate(_ rate: Float) {
        player.defaultRate = rate
        if player.rate > 0 { player.rate = rate }
        checkRate()
    }

    /// IOS-POC-22 — above 2× AVPlayer needs the item's `canPlayFastForward` (`PlaybackRateSupport`).
    /// Checked once the item is ready, since the property means nothing before, and on every speed
    /// change after that. `player.rate` is the viewer's intent: non-zero while playing or waiting
    /// for data, zero when paused.
    private func checkRate() {
        guard let item = player.currentItem, item.status == .readyToPlay,
              PlaybackRateSupport.needsOtherEngine(rate: player.defaultRate,
                                                   canPlayFastForward: item.canPlayFastForward)
        else { return }
        let playing = player.rate != 0
        // Not from inside this engine's own call: moving the playback tears this engine down.
        Task { @MainActor [weak self] in
            guard let self, self.session.engine === self else { return }
            self.session.nativeCannotPlayRate(playing: playing)
        }
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var isLoaded: Bool { player.currentItem != nil }
    var isPlaying: Bool { player.timeControlStatus == .playing }

    var state: PlaybackEngineState {
        guard let item = player.currentItem else { return .idle }
        if player.timeControlStatus == .playing { return .playing }
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate { return .buffering }
        return item.status == .readyToPlay ? .ready : .preparing
    }

    /// The loaded range **containing the playhead**, as IOS-POC-15 established.
    var bufferedUntil: Double? {
        let now = player.currentTime()
        return player.currentItem?.loadedTimeRanges
            .map(\.timeRangeValue)
            .first { $0.containsTime(now) }
            .map { ($0.start + $0.duration).seconds }
    }

    func mediaSelection() async -> PlaybackMediaSelection {
        guard let item = player.currentItem else { return PlaybackMediaSelection() }
        let audioFacts = await Self.audioFacts(for: item.asset)
        return PlaybackMediaSelection(
            subtitle: await mediaTrack(item: item, characteristic: .legible, kind: .subtitle,
                                       audioFacts: []),
            audio: await mediaTrack(item: item, characteristic: .audible, kind: .audio,
                                    audioFacts: audioFacts)
        )
    }

    func selectMedia(_ kind: PlaybackMediaKind, id: String) async {
        guard let item = player.currentItem else { return }
        let characteristic: AVMediaCharacteristic = kind == .audio ? .audible : .legible
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: characteristic) else { return }

        if kind == .subtitle, id == PlaybackMediaOption.subtitleOffID {
            item.select(nil, in: group)
            await refreshMediaSelection()
            return
        }

        let prefix = "native-\(kind.rawValue)-"
        guard id.hasPrefix(prefix), let index = Int(id.dropFirst(prefix.count)),
              group.options.indices.contains(index) else { return }
        // Preserve the existing AVFoundation selection path exactly; only the UI model changed.
        item.select(group.options[index], in: group)
        await refreshMediaSelection()
    }

    private func refreshMediaSelection() async {
        let selection = await mediaSelection()
        onMediaSelectionChange?(selection)
        await reportAudioDiagnostics(selection)
    }

    private func mediaTrack(item: AVPlayerItem, characteristic: AVMediaCharacteristic,
                            kind: PlaybackMediaKind,
                            audioFacts: [NativeAudioTrackFacts]) async -> PlaybackMediaTrack? {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: characteristic),
              !group.options.isEmpty else { return nil }

        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        var options = [PlaybackMediaOption]()
        if kind == .subtitle, group.allowsEmptySelection {
            options.append(.init(id: PlaybackMediaOption.subtitleOffID, title: "關閉",
                                 isOff: true, fallbackName: "關閉"))
        }

        for (index, option) in group.options.enumerated() {
            let id = "native-\(kind.rawValue)-\(index)"
            var codecs = [String]()
            for subtype in option.mediaSubTypes {
                guard let raw = Self.fourCC(subtype.uint32Value) else { continue }
                let normalized = PlaybackMediaOption.normalizedCodec(raw) ?? raw
                if !codecs.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
                    codecs.append(normalized)
                }
            }
            let matching = kind == .audio
                ? Self.matchingAudioFacts(for: option, index: index, optionCount: group.options.count,
                                          all: audioFacts)
                : []
            let channels = Self.common(matching.compactMap(\.channelCount))
            let layout = Self.common(matching.compactMap(\.channelLayout))
            let preciseCodec = Self.common(matching.compactMap(\.codec))
            options.append(.init(
                id: id,
                title: option.displayName,
                language: option.extendedLanguageTag ?? option.locale?.identifier,
                codec: preciseCodec ?? (codecs.isEmpty ? nil : codecs.joined(separator: "/")),
                channelCount: channels,
                channelLayout: layout,
                fallbackName: kind == .audio ? "音軌 \(index + 1)" : "字幕 \(index + 1)"
            ))
        }

        let selectedID: String?
        if let selected, let index = group.options.firstIndex(of: selected) {
            selectedID = "native-\(kind.rawValue)-\(index)"
        } else if kind == .subtitle, group.allowsEmptySelection {
            selectedID = PlaybackMediaOption.subtitleOffID
        } else {
            selectedID = nil
        }
        return PlaybackMediaTrack(options: options, selectedID: selectedID)
    }

    private func reportAudioDiagnostics(_ selection: PlaybackMediaSelection) async {
        guard let selected = selection.audio?.selectedOption else { return }
        let active = await Self.activeAudioFacts(in: player.currentItem)
        let actual = active.count == 1 ? active[0] : nil
        let codec = actual?.codec ?? selected.codecDisplayName ?? "unknown"
        let count = actual?.channelCount ?? selected.channelCount
        let layout = actual?.channelLayout ?? selected.channelLayout ?? selected.channelDescription ?? "unknown"
        let line = "[audio] engine=AVPlayer selected=\(selected.displayName)"
            + " id=\(selected.id) language=\(selected.language ?? "n/a")"
            + " codec=\(codec) channels=\(count.map(String.init) ?? "unknown") layout=\(layout)"
        guard line != lastAudioDiagnostic else { return }
        lastAudioDiagnostic = line
        PlaybackSession.log.notice("\(line, privacy: .public)")
    }

    private struct NativeAudioTrackFacts {
        let language: String?
        let subtype: UInt32?
        let codec: String?
        let channelCount: Int?
        let channelLayout: String?
    }

    private static func audioFacts(for asset: AVAsset) async -> [NativeAudioTrackFacts] {
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        var facts = [NativeAudioTrackFacts]()
        for track in tracks {
            if let fact = await audioFact(for: track) { facts.append(fact) }
        }
        return facts
    }

    private static func activeAudioFacts(in item: AVPlayerItem?) async -> [NativeAudioTrackFacts] {
        guard let item else { return [] }
        var facts = [NativeAudioTrackFacts]()
        for itemTrack in item.tracks where itemTrack.isEnabled {
            guard let track = itemTrack.assetTrack, track.mediaType == .audio,
                  let fact = await audioFact(for: track) else { continue }
            facts.append(fact)
        }
        return facts
    }

    private static func audioFact(for track: AVAssetTrack) async -> NativeAudioTrackFacts? {
        let extendedLanguage = try? await track.load(.extendedLanguageTag)
        let languageCode = try? await track.load(.languageCode)
        let language = extendedLanguage ?? languageCode
        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        guard let description = descriptions.first else {
            return NativeAudioTrackFacts(language: language, subtype: nil, codec: nil,
                                         channelCount: nil, channelLayout: nil)
        }
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        let codec = PlaybackMediaOption.normalizedCodec(fourCC(subtype))
        let channelCount = CMAudioFormatDescriptionGetStreamBasicDescription(description)
            .map { Int($0.pointee.mChannelsPerFrame) }
        var layoutSize = 0
        let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize)
            .map { String(format: "tag:0x%08X", $0.pointee.mChannelLayoutTag) }
        return NativeAudioTrackFacts(language: language, subtype: subtype, codec: codec,
                                     channelCount: channelCount, channelLayout: layout)
    }

    private static func matchingAudioFacts(for option: AVMediaSelectionOption, index: Int,
                                           optionCount: Int,
                                           all: [NativeAudioTrackFacts]) -> [NativeAudioTrackFacts] {
        let wantedLanguage = PlaybackMediaOption.canonicalLanguageCode(
            option.extendedLanguageTag ?? option.locale?.identifier
        )
        let wantedSubtypes = Set(option.mediaSubTypes.map(\.uint32Value))
        let exact = all.filter { fact in
            let languageMatches = wantedLanguage == nil
                || PlaybackMediaOption.canonicalLanguageCode(fact.language) == wantedLanguage
            let subtypeMatches = wantedSubtypes.isEmpty
                || fact.subtype.map(wantedSubtypes.contains) == true
            return languageMatches && subtypeMatches
        }
        if !exact.isEmpty { return exact }

        // Some containers omit language metadata. Fall back to positional pairing only when the
        // option and physical audio-track counts agree; otherwise leaving channels unknown is safer
        // than labelling one language with another track's layout.
        if optionCount == all.count, all.indices.contains(index) { return [all[index]] }
        return []
    }

    private static func common<T: Hashable>(_ values: [T]) -> T? {
        let unique = Set(values)
        return unique.count == 1 ? unique.first : nil
    }

    private static func fourCC(_ code: UInt32) -> String? {
        let bytes = [
            UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff), UInt8(code & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func teardown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        itemStatus?.invalidate()
        itemStatus = nil
        onFailure = nil
        onEnded = nil
        onMediaSelectionChange = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    /// The failure and the HTTP status the item's error log holds, if any — the evidence that
    /// keeps a 403 served as an HTML page from reading as "format not recognized".
    private func report(_ error: Error?) {
        guard let item = player.currentItem, item !== reportedItem else { return }
        reportedItem = item
        let status = item.errorLog()?.events.reversed().lazy
            .compactMap { PlaybackFailure.httpStatus(statusCode: $0.errorStatusCode, comment: $0.errorComment) }
            .first
        onFailure?(error ?? item.error ?? NSError(domain: "AVFoundationErrorDomain", code: -11800), status)
    }
}

/// The playback bar, drawn by this app rather than by AVKit (IOS-POC-16).
///
/// It exists because AVKit's own transport bar cannot be extended on iOS and its visibility cannot
/// be observed there either — both sets of API are tvOS-only. Owning the bar is what lets the
/// opening and ending controls live **in** it and disappear **with** it, instead of sitting on the
/// video permanently the way IOS-POC-5S-2's first attempt did.
///
/// **Its second-level choices are panels it draws itself (IOS-POC-16B), not SwiftUI `Menu`s.** A
/// `Menu` reports neither opening nor closing, so the five-second auto-hide faded the bar — and the
/// menu's anchor with it — out from under a viewer mid-choice, and the quarter-second redraws made
/// it flicker (reported on the device). `PlayerChrome` says which panel is open: one at most, and
/// while one is, the bar does not hide.
///
/// Everything here drives `PlaybackSession`. No second playback state, no second player, and the
/// same bar and panels whichever engine is playing.
private struct PlayerControlBar: View {
    let session: PlaybackSession
    /// Seconds. Owned by `PlayerView`, which runs the periodic observer.
    let position: Double
    let duration: Double
    /// Seconds already buffered ahead, or nil when nothing has been reported yet.
    let buffered: Double?
    /// IOS-POC-27A: whether the viewer means it to play — also while it waits for data. The toggle
    /// follows this, not `isPlaying`, so a stall offers pause instead of a ▶ that does nothing.
    let intendsToPlay: Bool
    /// The chosen speed, observed rather than read from the session on each render: a plain class
    /// publishes nothing, so a label reading it directly would only refresh when something else
    /// happened to redraw the body.
    let rate: Float
    /// The title's opening/ending, mirrored by `PlayerView`.
    let watching: WatchHistory?
    let media: PlaybackMediaSelection
    /// IOS-POC-17: the engine **actually** playing — not the settings page's default.
    let engine: PlaybackEngineKind
    let isAvailable: (PlaybackEngineKind) -> Bool
    let selectEngine: (PlaybackEngineKind) -> Void
    /// The open panel, if any. `PlayerView`'s `PlayerChrome` owns it.
    let panel: PlayerPanel?
    /// A bar button: opens its panel, or closes it when it is the one already open.
    let toggle: (PlayerPanel) -> Void
    let dismissPanel: () -> Void
    /// Any control being touched restarts the auto-hide countdown, so the bar cannot vanish under
    /// a finger that is using it.
    let interacted: () -> Void
    /// An opening/ending edit landed — refresh the mirror, so the panel shows what was actually
    /// kept (the clamp and Android's markable window can both keep a different number).
    let skipEdited: () -> Void
    /// A subtitle or audio track was selected; the loaded selection has to be read again for the
    /// checkmark to move.
    let mediaChanged: () -> Void
    let close: () -> Void

    /// Seconds, while a drag owns the scrubber. Nil means the observer's value is authoritative.
    @State private var scrubbing: Double?
    /// VoiceOver lands on a panel's title when it opens, instead of staying on the bar…
    @AccessibilityFocusState private var panelFocused: Bool
    /// …and back on the button that opened it when it closes, however it closed, instead of falling
    /// to the first element on the screen.
    @AccessibilityFocusState private var barFocus: PlayerPanel?
    /// The open panel's rows, measured, so a short list gets a short sheet.
    @State private var rowsHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The speeds the viewer picked (2026-09-23). `AVPlaybackSpeed.systemDefaultSpeeds` is AVKit's
    /// and is not reachable once its bar is gone, so this list is ours to choose. It lives in
    /// `PlaybackSpeedPreference.choices` since IOS-POC-29, so the settings page's default speed can
    /// only ever name a speed this menu shows.
    private static let speeds = PlaybackSpeedPreference.choices

    /// Every control answers a 48 pt square (Apple's minimum is 44) while drawing exactly what it
    /// drew before: the square is the touch area, not the glyph.
    static let hitTarget: CGFloat = 48
    /// Where the top row ends. A landscape drawer starts below it, so the buttons that open, switch
    /// and close panels stay reachable while one is open.
    private static let topRowHeight: CGFloat = 8 + hitTarget

    /// `2` rather than `2.0`, `1.25` rather than `1.2500001`.
    ///
    /// Interpolating a `Float` prints its own idea of the value — `2.0×` for a whole number, and
    /// binary-rounding artefacts for anything that is not exact. Two fraction digits at most, and
    /// no trailing zeros.
    private static func label(_ speed: Float) -> String {
        speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    /// The same speed for VoiceOver, which reads 「×」 as 「乘」.
    private static func spoken(_ speed: Float) -> String {
        speed.formatted(.number.precision(.fractionLength(0...2))) + " 倍"
    }

    private static func selectedName(_ track: PlaybackMediaTrack) -> String {
        track.selectedOption?.displayName ?? ""
    }

    private var shown: Double { scrubbing ?? position }

    var body: some View {
        VStack(spacing: 0) {
            topRow
            Spacer(minLength: 0)
            transport
            scrubber
        }
        // Stated, not inferred. An overlay proposes the parent's size, but a `Spacer` only pushes
        // within a container that actually took it — and one child with no intrinsic size is enough
        // to leave the stack sized to its content instead, which puts the transport and the
        // scrubber wherever the stack happens to end rather than at the bottom of the screen.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .foregroundStyle(.white)
        .background {
            // Legibility over bright video, without hiding it: dark at the edges, clear in the
            // middle where the picture matters.
            LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        // After the padding, so a panel spans the whole safe area rather than the bar's margins.
        .overlay { panelHost }
        .onChange(of: panel) { old, new in
            if new == nil, let old { barFocus = old }
        }
    }

    // MARK: Top row — the way out, and the routes

    private var topRow: some View {
        // 6 pt between 48 pt targets is the 54 pt pitch the 36 pt glyphs always had.
        HStack(spacing: 6) {
            // **The only way out of the player.** IOS-POC-10I deleted the swipe-to-dismiss after
            // measuring that AVKit's own X did the job; with AVKit's bar gone that X is gone too,
            // so this button is what stops the viewer being trapped on this screen.
            Button(action: { interacted(); close() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.4), in: Circle())
                    .playerHitTarget()
            }
            .accessibilityLabel("關閉播放器")

            Spacer()

            // What the running engine cannot do is not drawn, rather than drawn and dead. A choice
            // of one decides nothing, so a track button needs more than one option (IOS-POC-5Q).
            if engine.capabilities.trackSelection {
                if let subtitle = media.subtitle, subtitle.options.count > 1 {
                    panelButton(.subtitle, value: Self.selectedName(subtitle)) {
                        Image(systemName: "captions.bubble").font(.system(size: 17))
                    }
                }
                if let audio = media.audio, audio.options.count > 1 {
                    panelButton(.audio, value: Self.selectedName(audio)) {
                        Image(systemName: "waveform").font(.system(size: 17))
                    }
                }
            }
            // IOS-POC-17E: only when the source offers more than one entry.
            if let quality = session.quality, quality.offersChoice {
                panelButton(.quality, value: quality.name) {
                    Text(quality.name.isEmpty ? "畫質" : quality.name)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: 80)
                }
            }
            panelButton(.speed, value: Self.spoken(rate)) {
                Text(Self.label(rate)).font(.footnote.weight(.semibold))
            }
            // IOS-POC-17: the label is the engine playing now.
            panelButton(.engine, value: engine.displayName) {
                Text(engine.shortName).font(.footnote.weight(.semibold))
            }

            // AirPlay. `AVRoutePickerView` is public and is the whole control, so there is nothing
            // to reimplement — AVKit's bar was only ever hosting the same view.
            if engine.capabilities.airPlay {
                RoutePickerButton()
                    .frame(width: Self.hitTarget, height: Self.hitTarget)
                    .accessibilityLabel("AirPlay")
            }
        }
        // `topRowHeight` is where a landscape drawer starts; past this size the row would outgrow it.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private func panelButton<Glyph: View>(_ target: PlayerPanel, value: String = "",
                                          @ViewBuilder glyph: () -> Glyph) -> some View {
        Button { toggle(target) } label: { glyph().playerHitTarget() }
            .accessibilityLabel(target.title)
            .accessibilityValue(value)
            .accessibilityAddTraits(panel == target ? .isSelected : [])
            // VoiceOver comes back here when the panel this button opened closes.
            .accessibilityFocused($barFocus, equals: target)
    }

    // MARK: Transport

    private var transport: some View {
        // 36 pt between 48 pt targets keeps the glyph centres where 44 pt between bare glyphs had them.
        HStack(spacing: 36) {
            Button(action: { interacted(); session.seek(toSeconds: shown - 10) }) {
                Image(systemName: "gobackward.10").font(.system(size: 28)).playerHitTarget()
            }
            .accessibilityLabel("倒退 10 秒")

            Button(action: { interacted(); session.control(intendsToPlay ? "pause" : "play") }) {
                Image(systemName: intendsToPlay ? "pause.fill" : "play.fill")
                    .font(.system(size: 40))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(intendsToPlay ? "暫停" : "播放")

            Button(action: { interacted(); session.seek(toSeconds: shown + 10) }) {
                Image(systemName: "goforward.10").font(.system(size: 28)).playerHitTarget()
            }
            .accessibilityLabel("前進 10 秒")
        }
        .padding(.bottom, 14)
    }

    // MARK: Scrubber, and the opening/ending beside it

    private var scrubber: some View {
        // 10 pt, so the opening/ending buttons' enlarged touch area (10 pt above the capsule) ends
        // where the slider's begins instead of overlapping it.
        VStack(spacing: 10) {
            PlaybackSlider(value: shown, bounds: duration, buffered: buffered,
                           onChange: { scrubbing = $0; interacted() },
                           onCommit: { seconds in
                               scrubbing = nil
                               session.seek(toSeconds: seconds)
                               interacted()
                           })
                .frame(height: 44)
                .accessibilityLabel("播放進度")
                .accessibilityValue("\(PlayerView.clock(shown)) / \(PlayerView.clock(duration))")

            HStack(spacing: 10) {
                Text(PlayerView.clock(shown))
                    .monospacedDigit()
                Spacer(minLength: 8)
                // IOS-POC-5S-2's four operations, unchanged. This is what the whole stage was for:
                // they are in the bar, so they leave with it.
                if watching != nil {
                    skipButton(.opening, offset: \.openingOffset)
                    skipButton(.ending, offset: \.endingOffset)
                }
                Spacer(minLength: 8)
                Text(PlayerView.clock(duration))
                    .monospacedDigit()
            }
            .font(.caption)
        }
    }

    /// The opening or ending capsule, which opens its panel. The capsule stays its drawn size; the
    /// touch area reaches 10 pt above and below it, 44 pt in all, without moving the scrubber.
    private func skipButton(_ target: PlayerPanel, offset: KeyPath<WatchHistory, Double>) -> some View {
        let current = watching?[keyPath: offset] ?? 0
        return Button { toggle(target) } label: {
            Text(current > 0 ? "\(target.title) \(PlayerView.clock(current / 1000))" : target.title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(panel == target ? 0.32 : 0.18), in: Capsule())
                // Taller only: widening it too would hand the gap between the two capsules to
                // whichever is drawn last.
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        // The 10 pt above and below are touch area, not layout: the row keeps the capsule's height.
        .padding(.vertical, -10)
        .accessibilityLabel(target.title)
        .accessibilityValue(PlayerView.skipLabel(current))
        .accessibilityAddTraits(panel == target ? .isSelected : [])
        .accessibilityFocused($barFocus, equals: target)
    }

    // MARK: Panels (IOS-POC-16B)

    /// Where the open panel goes: a sheet from the bottom in portrait, a drawer on the trailing side
    /// in landscape — `PlayerPanelPlacement` decides, from the safe area this bar is laid out in.
    ///
    /// One view whose frame and alignment change with the placement, not one view per placement, so
    /// rotating with a panel open moves it instead of tearing it down and rebuilding it.
    private var panelHost: some View {
        GeometryReader { proxy in
            let placement = PlayerPanelPlacement.placement(in: proxy.size)
            let trailing: Double? = if case .trailing(let width) = placement { width } else { nil }
            let limit: Double = switch placement {
            case .bottom(let maxHeight, _): maxHeight
            case .trailing: max(Double(proxy.size.height - Self.topRowHeight) - 10, 0)
            }
            let clearance: Double = if case .bottom(_, let clearance) = placement { clearance } else { 0 }
            ZStack {
                if let panel {
                    // The header is one 48 pt row plus its divider; the rows get the rest.
                    panelCard(panel, trailing: trailing != nil,
                              rowsLimit: max(CGFloat(limit) - Self.hitTarget - 1, Self.hitTarget * 2))
                        .frame(width: trailing.map { CGFloat($0) })
                        .transition(reduceMotion
                                    ? .opacity
                                    : .move(edge: trailing != nil ? .trailing : .bottom)
                                        .combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: trailing != nil ? .topTrailing : .bottom)
            .padding(.top, trailing != nil ? Self.topRowHeight : 0)
            .padding(.bottom, CGFloat(clearance))
            // Scoped to the panel, not to the quarter-second values redrawing around it.
            .animation(.easeOut(duration: 0.2), value: panel)
        }
    }

    /// The card: a header, then the rows. Short lists size to their content; long ones — seven
    /// speeds, a source's qualities, a large text size — scroll inside `rowsLimit`.
    ///
    /// The rows are measured and the scroll view is given a definite height — the rows' own, or
    /// the room there is, whichever is less. Both `ViewThatFits` and a `fixedSize` card were tried
    /// first and each left the scroll view sized to all of its content, drawn past the bottom of
    /// the sheet (seen on the simulator), so the height is stated rather than negotiated.
    private func panelCard(_ panel: PlayerPanel, trailing: Bool, rowsLimit: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(panel.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($panelFocused)
                Spacer()
                Button(action: dismissPanel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .playerHitTarget()
                }
                .accessibilityLabel("關閉\(panel.title)")
            }
            .padding(.leading, 20)
            .padding(.trailing, 6)
            // The header's height is what `rowsLimit` subtracts; past this size it would outgrow it.
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            Divider().overlay(.white.opacity(0.2))
            ScrollView {
                panelRows(panel)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: rowsHeight > 0 ? min(rowsHeight, rowsLimit) : rowsLimit)
            // A different panel starts at its own top, not at the last one's scroll offset.
            .id(panel)
        }
        .foregroundStyle(.white)
        .background {
            // A drawer is attached to the trailing edge and a sheet to the bottom one, so each
            // rounds only the corners that face the picture and runs out under the edge it sits on.
            // Opaque: the bar's own controls are underneath and must not read through.
            let corner: CGFloat = 16
            (trailing
             ? UnevenRoundedRectangle(topLeadingRadius: corner, bottomLeadingRadius: corner)
             : UnevenRoundedRectangle(topLeadingRadius: corner, topTrailingRadius: corner))
                .fill(Color(white: 0.08))
                .ignoresSafeArea(edges: trailing ? .trailing : .bottom)
        }
        // The gaps between rows belong to the panel: a tap there must not fall through to the tap
        // surface underneath and close it.
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { dismissPanel() }
        .onAppear { panelFocused = true }
    }

    private func panelRows(_ panel: PlayerPanel) -> some View {
        VStack(spacing: 0) {
            switch panel {
            case .speed:
                ForEach(Self.speeds, id: \.self) { speed in
                    choiceRow(speed == 1 ? "正常" : Self.label(speed), selected: rate == speed,
                              spoken: speed == 1 ? nil : Self.spoken(speed)) {
                        session.setRate(speed)
                    }
                }
            case .quality:
                if let quality = session.quality {
                    ForEach(Array(quality.qualities.enumerated()), id: \.offset) { entry, option in
                        choiceRow(option.name.isEmpty ? "畫質 \(entry + 1)" : option.name,
                                  selected: entry == quality.selected) {
                            session.selectQuality(entry)
                        }
                    }
                }
            case .engine:
                // An engine that is not offered is listed but cannot be picked, so nobody lands on
                // a black screen.
                ForEach(PlaybackEngineKind.allCases, id: \.self) { kind in
                    choiceRow(isAvailable(kind) ? kind.displayName : "\(kind.displayName)（尚未開放）",
                              selected: kind == engine, enabled: isAvailable(kind)) {
                        selectEngine(kind)
                    }
                }
            case .subtitle:
                trackRows(media.subtitle, kind: .subtitle)
            case .audio:
                trackRows(media.audio, kind: .audio)
            case .opening:
                skipControls(offset: \.openingOffset, mark: session.markOpening,
                             apply: session.setOpening)
            case .ending:
                skipControls(offset: \.endingOffset, mark: session.markEnding,
                             apply: session.setEnding)
            }
        }
    }

    /// One full-width single-choice row. Choosing applies and closes the panel.
    private func choiceRow(_ title: String, selected: Bool, enabled: Bool = true, spoken: String? = nil,
                           action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismissPanel()
        } label: {
            HStack(spacing: 12) {
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
                // Always laid out, only shown when selected, so the titles do not shift.
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            // A minimum, not a height: a larger text size makes the row taller.
            .frame(maxWidth: .infinity, minHeight: Self.hitTarget)
            .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(spoken ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Subtitles and audio share one engine-neutral row model. Selection goes back through the
    /// active engine adapter, which turns the opaque id into AVMediaSelectionOption or mpv aid/sid.
    @ViewBuilder
    private func trackRows(_ track: PlaybackMediaTrack?, kind: PlaybackMediaKind) -> some View {
        if let track {
            ForEach(track.options) { option in
                choiceRow(option.displayName, selected: option.id == track.selectedID) {
                    Task { @MainActor in
                        await session.selectMedia(kind, id: option.id)
                        mediaChanged()
                    }
                }
            }
        }
    }

    /// The opening or ending: what it is set to now, then Android's four operations. It stays open
    /// — ±1 s is meant to be pressed more than once.
    ///
    /// `mark` reads the live position from the session, because a SwiftUI body is evaluated when the
    /// layout needs it rather than when the viewer taps, and ±1 s reads the session's record for the
    /// same reason.
    private func skipControls(offset: KeyPath<WatchHistory, Double>,
                              mark: @escaping () -> Void,
                              apply: @escaping (Double) -> Void) -> some View {
        let current = watching?[keyPath: offset] ?? 0
        // The value the session kept — the clamp and Android's markable window can both keep a
        // different one — refreshed on screen and spoken, since the focused button is not the label.
        let edited = {
            skipEdited()
            AccessibilityNotification.Announcement(
                "目前：\(PlayerView.skipLabel(session.record?[keyPath: offset] ?? 0))").post()
        }
        let nudge = { (delta: Double) in
            apply((session.record?[keyPath: offset] ?? 0) + delta)
            edited()
        }
        return VStack(spacing: 10) {
            Text("目前：\(PlayerView.skipLabel(current))")
                .font(.subheadline.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                skipAction("−1 秒") { nudge(-1000) }
                skipAction("設為目前位置") { mark(); edited() }
                skipAction("＋1 秒") { nudge(1000) }
            }
            // Disabled rather than hidden, so the panel does not reflow when it is set.
            skipAction("清除") { apply(0); edited() }
                .disabled(current <= 0)
                .opacity(current > 0 ? 1 : 0.45)
        }
        .padding(16)
    }

    private func skipAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: Self.hitTarget)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }
    }
}

private extension View {
    /// IOS-POC-16B: a control's touch area, not its drawing — at least 48 × 48 around whatever the
    /// label draws.
    func playerHitTarget() -> some View {
        frame(minWidth: PlayerControlBar.hitTarget, minHeight: PlayerControlBar.hitTarget)
            .contentShape(Rectangle())
    }
}

/// The scrubber. A `Slider` cannot draw the buffered range, and the buffered range is the one thing
/// a viewer on a flaky source actually wants to see — so this is a bar, a drag, and nothing else.
///
/// ponytail: no tick marks, no chapter marks, no haptics. They are additions, not omissions.
private struct PlaybackSlider: View {
    let value: Double
    let bounds: Double
    let buffered: Double?
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void

    private static let track: CGFloat = 5
    /// The bar is thin; the gesture must not be. The control bar gives it 44 pt of height (IOS-POC-16B);
    /// the paint is 5.
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let usable = bounds.isFinite && bounds > 0 ? bounds : 0
            let progress = usable > 0 ? min(max(value / usable, 0), 1) : 0
            let ahead = usable > 0 ? min(max((buffered ?? 0) / usable, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28)).frame(height: Self.track)
                Capsule().fill(.white.opacity(0.45))
                    .frame(width: width * ahead, height: Self.track)
                Capsule().fill(.white).frame(width: width * progress, height: Self.track)
                Circle().fill(.white).frame(width: 13, height: 13)
                    .offset(x: width * progress - 6.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { move in
                        guard usable > 0 else { return }
                        onChange(seconds(at: move.location.x, width: width, of: usable))
                    }
                    .onEnded { move in
                        guard usable > 0 else { return }
                        onCommit(seconds(at: move.location.x, width: width, of: usable))
                    }
            )
        }
    }

    private func seconds(at x: CGFloat, width: CGFloat, of usable: Double) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1) * usable
    }
}

/// `AVRoutePickerView` is the AirPlay control; there is nothing to reimplement around it.
///
/// It draws at 36 pt and answers a 48 pt square (IOS-POC-16B). A SwiftUI `contentShape` cannot
/// enlarge a UIKit view's touch area, and whether the picker scales its glyph with its bounds was
/// not measured — so the picker keeps its 36 pt bounds and a 48 pt host hands it every touch that
/// lands inside the host. The picker's own button still decides what a tap is; a touch a few points
/// outside it is well within the slop UIKit already allows a button.
///
/// `sizeThatFits` fixes the host at `PlayerControlBar.hitTarget` square whatever SwiftUI proposes:
/// the host has no intrinsic content size, and one greedy child is enough to change how the whole
/// row — and the stack around it — lays out.
private struct RoutePickerButton: UIViewRepresentable {
    final class Host: UIView {
        private let picker = AVRoutePickerView()
        private static let glyph: CGFloat = 36

        override init(frame: CGRect) {
            super.init(frame: frame)
            picker.tintColor = .white
            picker.activeTintColor = .white
            addSubview(picker)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            picker.frame = CGRect(x: (bounds.width - Self.glyph) / 2, y: (bounds.height - Self.glyph) / 2,
                                  width: Self.glyph, height: Self.glyph)
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            // UIKit's own answer first, so a hidden, transparent or disabled host takes nothing.
            guard super.hitTest(point, with: event) != nil else { return nil }
            return picker.hitTest(CGPoint(x: picker.bounds.midX, y: picker.bounds.midY), with: event)
        }
    }

    func makeUIView(context: Context) -> Host { Host() }

    func updateUIView(_ view: Host, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Host, context: Context) -> CGSize? {
        CGSize(width: PlayerControlBar.hitTarget, height: PlayerControlBar.hitTarget)
    }
}

/// `AVPlayerViewController` directly, rather than SwiftUI's `VideoPlayer`, for one reason: the
/// delegate. `VideoPlayer` wraps the same controller but hands out no delegate, and the control
/// visibility this screen needs has no other public source.
private struct PlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    /// True while AVKit has the video in a Picture in Picture window. The screen must not tear
    /// playback down in that state — the whole point of PiP is that it outlives this view.
    @Binding var pictureInPicture: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = context.coordinator
        context.coordinator.attach(controller)
        // IOS-POC-16. AVKit draws no controls; `PlayerControlBar` does.
        //
        // **This is the only way to put anything in the playback bar on iOS.** Every hook AVKit
        // offers for extending its own transport bar — `transportBarCustomMenuItems`,
        // `customOverlayViewController`, `contextualActions`, `infoViewActions` — is
        // `API_UNAVAILABLE(ios)`, and so is the delegate method that would report when its bar is
        // showing. An overlay that cannot know when the bar is up can only sit on the video
        // forever, which is exactly what the close button did until 2026-09-23.
        //
        // The video, the playback pipeline and Picture in Picture stay AVKit's: this hides controls,
        // it does not replace the player. Automatic PiP on leaving the app is a property of the
        // controller, not of its bar, so it survives. There is **no manual PiP button** by decision
        // — `AVPlayerViewController` exposes no public `startPictureInPicture()`, and the viewer
        // asked not to have one drawn.
        controller.showsPlaybackControls = false
        // IOS-POC-10H. Both flags are needed and they do different jobs: the first puts the PiP
        // button in AVKit's control bar, the second hands the video to a PiP window when the
        // viewer leaves the app instead of freezing it.
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        // One `AVPlayer` lives for the whole app, so this normally does nothing; it matters only
        // if the session ever swaps the player object rather than its item.
        if controller.player !== player { controller.player = player }
        // Re-asserted every update, not just at creation. Setting it once in `makeUIViewController`
        // was measured on the simulator on 2026-09-23 **not to stick**: AVKit's own transport bar,
        // AirPlay and mute buttons all came back on a tap. Assigning it here is idempotent and
        // survives whatever puts them back.
        if controller.showsPlaybackControls { controller.showsPlaybackControls = false }
    }

    func makeCoordinator() -> Coordinator { Coordinator(active: $pictureInPicture) }

    @MainActor final class Coordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
        private let active: Binding<Bool>
        private weak var playerViewController: AVPlayerViewController?
        private var foregroundRestore = PictureInPictureForegroundRestoreState()

        init(active: Binding<Bool>) {
            self.active = active
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(
                self,
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
        }

        func attach(_ controller: AVPlayerViewController) {
            playerViewController = controller
        }

        @objc private func appDidBecomeActive() {
            guard let controller = playerViewController,
                  foregroundRestore.consumeForegroundRequest(
                    isPictureInPictureActive: active.wrappedValue
                  ) else { return }

            // AVPlayerViewController has no public stopPictureInPicture(). Toggling its public
            // entitlement off asks AVKit to end the active session; restore it on the next main
            // runloop so later PiP sessions remain available. The controller keeps the same player.
            controller.allowsPictureInPicturePlayback = false
            DispatchQueue.main.async { [weak controller] in
                controller?.allowsPictureInPicturePlayback = true
            }
        }

        func playerViewControllerWillStartPictureInPicture(_ controller: AVPlayerViewController) {
            foregroundRestore.pictureInPictureWillStart()
            active.wrappedValue = true
        }

        func playerViewControllerDidStopPictureInPicture(_ controller: AVPlayerViewController) {
            foregroundRestore.pictureInPictureDidStop()
            active.wrappedValue = false
        }

        /// AVKit calls this while an already-stopping PiP asks where to restore its UI. The player
        /// screen remains presented underneath, so no controller needs rebuilding. Returning to
        /// the app is a separate lifecycle path handled by `appDidBecomeActive()` above.
        func playerViewController(
            _ controller: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void
        ) {
            completion(true)
        }
    }
}

private struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    /// The item is already loaded by the caller, because playback has to outlive this screen for
    /// `player.status` and `player.control` to mean anything.
    private let session = PlaybackSession.shared

    /// IOS-POC-10H: AVKit has the video in a PiP window.
    ///
    /// IOS-POC-10A's close button used to live here. It is gone at the viewer's request, along
    /// with the control-visibility plumbing that existed only to fade it.
    @State private var pictureInPicture = false

    /// IOS-POC-10J: what the current drag is doing. Decided once, on the first few points of
    /// movement, and held until the finger lifts — an axis that can change mid-drag makes the
    /// gesture feel like it is fighting back.
    @State private var drag: DragKind?
    /// The value the drag started from, so the whole gesture is measured against one origin
    /// rather than accumulating rounding from frame to frame.
    @State private var dragOrigin: Double = 0
    @State private var hud: String?
    /// The title's opening and ending, mirrored for the labels (IOS-POC-5S-2). `PlaybackSession` is
    /// a plain class every other screen drives imperatively; making it observable so two capsules
    /// could redraw would put a dependency on every one of those callers.
    @State private var watching: WatchHistory?
    /// IOS-POC-16: **our** control-bar visibility, not a guess at AVKit's — and since IOS-POC-16B,
    /// which of its panels is open.
    ///
    /// IOS-POC-10A tried to track AVKit's bar and could not — the delegate method it used is not a
    /// member of `AVPlayerViewControllerDelegate` on any platform, so it was never called and the
    /// button it faded sat on the video forever. Now AVKit draws no bar, this is the only truth
    /// there is, and nothing can fall out of phase with it.
    @State private var chrome = PlayerChrome()
    @State private var hideTimer: Task<Void, Never>?
    /// A VoiceOver user moves through the bar one element at a time; it must not fade under them.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    /// Seconds, from the periodic observer.
    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var buffered: Double?
    /// IOS-POC-27A: the bar's toggle, from `PlaybackActivity`.
    @State private var intendsToPlay = false
    /// IOS-POC-27A: consecutive quarter-second ticks with something on its way. The spinner shows
    /// from the second, so a seek that lands at once does not flash it.
    @State private var spinnerTicks = 0
    /// IOS-POC-27A: why a start was handed to the other engine, shown for a few seconds.
    @State private var notice: String?
    @State private var noticeTimer: Task<Void, Never>?
    /// The chosen speed. Observed alongside position, because `PlaybackSession` is a plain class
    /// and the speed can also change without the menu — `load` re-applies it on the next episode.
    @State private var rate: Float = 1
    @State private var media = PlaybackMediaSelection()
    @State private var timeObserver: Any?
    /// IOS-POC-17: which engine is drawing, and what failed if nothing can.
    @State private var engineKind = PlaybackEngineKind.native
    @State private var failure: String?
    /// The quarter-second tick the bar's state is read on — MPV's snapshot, and since IOS-POC-27A
    /// AVPlayer's state too, whose periodic observer stops with the item's clock in a stall.
    @State private var engineTicker: Task<Void, Never>?

    private enum DragKind { case seek, volume, brightness }

    /// A full screen-width drag moves two minutes. Chosen so a thumb-width nudge is a few seconds
    /// — fine enough to skip an advert, coarse enough to cross an episode.
    private static let seekSpan: Double = 120
    /// A full screen-height drag covers the whole 0…1 range, halved so the usable part of the
    /// screen is enough.
    private static let levelSpan: Double = 400

    var body: some View {
        ZStack {
            // The player owns the whole screen, so letterbox bars are black instead of showing
            // whatever is behind the presentation.
            Color.black.ignoresSafeArea()
            if engineKind == .mpv, let mpv = session.engine as? MPVEngine {
                MPVVideoSurface(engine: mpv, pictureInPicture: $pictureInPicture)
                    .id(ObjectIdentifier(mpv))
                    .ignoresSafeArea()
            } else {
                PlayerSurface(player: session.player, pictureInPicture: $pictureInPicture)
                    .ignoresSafeArea()
            }
        }
        .overlay {
            // The real reason, classified — IOS-POC-17. A failed item used to be a silent black
            // screen with the bar still offering play.
            if let failure {
                Text(failure)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                    .padding(32)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            // IOS-POC-27A: a start or a stall is on its way. Never takes a touch, so the bar and the
            // tap layer stay usable under it.
            if spinnerTicks >= 2 {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            // IOS-POC-27A: below the bar's top row, so it covers neither the close button nor the
            // spinner of the engine that just took over.
            if let notice {
                Text(notice)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 32)
                    .padding(.top, 72)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let hud {
                Text(hud)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.black.opacity(0.65), in: Capsule())
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            // Our own tap surface, above AVKit's view rather than beside it.
            //
            // A `simultaneousGesture` on the composed view was **measured not to work** on
            // 2026-09-23: with `showsPlaybackControls = false` AVKit draws nothing, but its view
            // still swallows the touch, so the bar could never be summoned back and the player had
            // no way out at all. A transparent SwiftUI layer in the overlay sits above that view
            // and gets the tap first, which is a placement rather than a gesture-priority fight.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { chrome.tapBackground() }
        }
        .overlay {
            PlayerControlBar(
                session: session, position: position, duration: duration, buffered: buffered,
                intendsToPlay: intendsToPlay, rate: rate, watching: watching, media: media,
                engine: engineKind,
                isAvailable: { session.isEngineAvailable($0) },
                selectEngine: { session.selectEngine($0) },
                panel: chrome.panel,
                toggle: { panel in
                    chrome.toggle(panel)
                    // Read when the panel opens rather than trusted from when the player opened:
                    // the next episode is a new item with its own groups, and selecting an option
                    // of the previous item's group would change nothing.
                    if chrome.panel == .subtitle || chrome.panel == .audio { reloadMedia() }
                },
                dismissPanel: { chrome.dismissPanel() },
                interacted: { scheduleHide() },
                // The panel shows the value the session actually kept, so no readout is flashed.
                skipEdited: { watching = session.record },
                mediaChanged: { reloadMedia() },
                close: { dismiss() }
            )
            .opacity(chrome.controlsVisible ? 1 : 0)
            // Gone means gone: a hidden bar must not eat the tap that brings it back.
            .allowsHitTesting(chrome.controlsVisible)
            .animation(.easeInOut(duration: 0.25), value: chrome.controlsVisible)
        }
        // IOS-POC-10J. `simultaneousGesture` again, for the reason IOS-POC-10A2 found: AVKit's
        // recognisers live in the UIKit view underneath and a plain SwiftUI gesture loses to
        // them. Observing alongside means the scrubber still works if the viewer grabs it.
        //
        // No swipe-to-dismiss here — AVKit's own X does that, as IOS-POC-10I measured.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { move in dragChanged(move) }
                .onEnded { move in dragEnded(move) }
        )
        .statusBarHidden()
        // IOS-POC-16B. Every change to the bar or its panels restarts the countdown — or stops it,
        // when a panel has just opened. One place, so no path can open or close a panel and forget.
        .onChange(of: chrome) { scheduleHide() }
        // IOS-POC-23: a player in Picture in Picture is never reloaded on return.
        .onChange(of: pictureInPicture) { session.pictureInPictureActive = pictureInPicture }
        // The tap that brings a hidden bar back is not something VoiceOver can reach, so turning it
        // on brings the bar back instead.
        .onChange(of: voiceOver) { if voiceOver { chrome.show() } }
        // Closing the screen pauses rather than tears down, so a page can read the position it
        // reached and resume it with player.control.
        .onDisappear {
            // The screen is gone either way, so its bar's ticker and observer go with it — PiP
            // playback needs neither (IOS-POC-27A: the ticker now runs for AVPlayer too, and one
            // left behind by each dismissal in PiP would poll for the rest of the app's life). One
            // `AVPlayer` outlives this screen, so an observer left on it would outlive it too.
            stopObserving()
            // Unless PiP has the video: pausing there would stop the little window the viewer
            // just asked for, which is the one thing PiP must survive.
            guard !pictureInPicture else { return }
            session.control("pause")
            // The sampler skips a paused player, so the moment of leaving is the last chance to
            // record where the viewer actually got to. The session ends only after that write:
            // ending it can release an MPV engine, and its position with it.
            Task {
                await session.persist()
                session.closePlayer()
            }
            hideTimer?.cancel()
            session.onEngineChange = nil
            session.onFailure = nil
            session.onNotice = nil
            noticeTimer?.cancel()
            session.onMediaSelectionChange = nil
        }
        .task {
            engineKind = session.engineKind
            failure = session.router.failure?.message
            session.pictureInPictureActive = pictureInPicture
            session.onMediaSelectionChange = { selection in
                media = selection
                reconcileTrackPanel()
            }
            session.onEngineChange = { kind in
                engineKind = kind
                failure = nil
                // Track ids belong to one engine adapter, so an open panel closes across a handoff.
                chrome.dismissPanel()
                startObserving()
                reloadMedia()
            }
            session.onFailure = { failure = $0.message }
            session.onNotice = { showNotice($0) }
            startObserving()
            scheduleHide()
            media = await session.refreshMediaSelection()
            reconcileTrackPanel()
            // The session merges the stored opening and ending in a task of its own, so ask the
            // store rather than racing it. The session's record is already keyed by then, because
            // `open` sets that part synchronously.
            guard let key = session.record?.key else { return }
            watching = await WatchHistoryStore.shared.record(forKey: key) ?? session.record
        }
    }

    // MARK: - IOS-POC-16: the bar's own state

    /// A quarter-second tick. Fine enough that the scrubber does not visibly step, coarse enough
    /// that it costs nothing — AVKit's own bar reads about the same.
    ///
    /// IOS-POC-27A: **one tick for both engines.** AVPlayer's periodic observer runs on the item's
    /// timeline, which stops in a stall (`AVPlayer.h`), so the bar froze exactly when it mattered:
    /// the toggle kept ▶ and the total never arrived for an item that became ready while waiting.
    /// The observer now only moves AVPlayer's playhead, the one value it reports better than a poll.
    private func startObserving() {
        stopObserving()
        let native = engineKind != .mpv
        engineTicker = Task { @MainActor in
            while !Task.isCancelled {
                if !native { position = session.position }
                duration = session.duration
                // The session's remembered speed, not the engine's rate: a paused player reports zero
                // and the menu must still show what the viewer picked.
                rate = session.rate
                // What is already on the device, from the range **containing the playhead** — the
                // same reading IOS-POC-15's policy takes, so the bar and the policy never disagree.
                buffered = session.bufferedUntil
                let activity = session.activity
                intendsToPlay = activity.showsPause
                // Held at two: past the half second nothing changes, so nothing redraws.
                spinnerTicks = activity.showsSpinner ? min(spinnerTicks + 1, 2) : 0
                try? await Task.sleep(for: .seconds(0.25))
            }
        }
        guard native else { return }
        timeObserver = session.player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { time in
            Task { @MainActor in
                // No guard against an in-flight drag is needed: `PlayerControlBar` holds the
                // dragged value itself and prefers it over this one until the finger lifts.
                position = time.seconds.isFinite ? time.seconds : 0
            }
        }
    }

    private func stopObserving() {
        if let timeObserver { session.player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        engineTicker?.cancel()
        engineTicker = nil
    }

    private func reloadMedia() {
        Task {
            media = await session.refreshMediaSelection()
            reconcileTrackPanel()
        }
    }

    private func reconcileTrackPanel() {
        // The item or engine may have changed under an open panel. A panel with no actual choice
        // closes instead of showing stale ids from the previous engine/item.
        let track = chrome.panel == .subtitle ? media.subtitle : chrome.panel == .audio ? media.audio : nil
        if chrome.panel == .subtitle || chrome.panel == .audio, (track?.options.count ?? 0) < 2 {
            chrome.dismissPanel()
        }
    }

    /// Five seconds, restarted by every interaction — close to AVKit's own, and now ours to state
    /// rather than to guess at. The longer end of the usual 3–5 s because the close button lives in
    /// this bar and is the only way out of the player.
    ///
    /// **It only counts while no panel is open** (IOS-POC-16B): a panel stops it, and closing one
    /// starts a fresh five seconds. **A paused player keeps its bar**, and so does a VoiceOver user.
    private func scheduleHide() {
        hideTimer?.cancel()
        guard chrome.autoHideArmed else { return }
        hideTimer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(PlayerChrome.autoHideSeconds))
            // Read when the timer fires, not when it was set: VoiceOver can have been switched on in
            // the five seconds between.
            guard !Task.isCancelled, !UIAccessibility.isVoiceOverRunning else { return }
            chrome.autoHideFired(isPlaying: session.isPlaying)
        }
    }

    // MARK: - IOS-POC-10J gestures

    private func dragChanged(_ move: DragGesture.Value) {
        // A scroll inside an open panel is not a seek, volume or brightness drag (IOS-POC-16B).
        // Refused here rather than by switching the gesture off: changing a gesture's mask mid-drag
        // cancels it without `onEnded`, which would strand `drag` and the readout.
        if drag == nil, chrome.panel != nil { return }
        let kind = drag ?? classify(move)
        if drag == nil {
            drag = kind
            switch kind {
            case .seek: dragOrigin = session.position
            case .volume: dragOrigin = Double(session.volume)
            case .brightness: dragOrigin = Double(UIScreen.main.brightness)
            }
        }
        switch kind {
        case .seek:
            // Shown, not applied: seeking on every frame of the drag makes a network stream
            // stutter for the whole gesture. The seek happens once, when the finger lifts.
            hud = seekLabel(for: seekTarget(move))
        case .volume:
            let value = level(from: move)
            session.volume = Float(value)
            hud = "🔊 \(Int(value * 100))%"
        case .brightness:
            // Floored rather than allowed to reach zero. A downward drag that blacks the screen
            // leaves the viewer unable to see the gesture that would undo it — Control Center can
            // go that dark because it is deliberate and reversible; a swipe is neither.
            let value = max(level(from: move), 0.05)
            UIScreen.main.brightness = CGFloat(value)
            hud = "☀️ \(Int(value * 100))%"
        }
    }

    private func dragEnded(_ move: DragGesture.Value) {
        if drag == .seek {
            session.seek(toSeconds: seekTarget(move))
        }
        drag = nil
        flashHUD()
    }

    /// IOS-POC-27A: a message long enough to read — four seconds — on its own state, so a gesture's
    /// readout neither replaces it nor is replaced by it.
    private func showNotice(_ text: String) {
        notice = text
        noticeTimer?.cancel()
        noticeTimer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    /// Shows a readout, or leaves the one already up, and takes it away a moment later. Vanishing
    /// the instant the finger lifts reads as a glitch rather than a confirmation.
    private func flashHUD() {
        let shown = hud
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            if hud == shown { hud = nil }
        }
    }

    /// Horizontal or vertical, and if vertical, which half of the screen the finger started in.
    ///
    /// The half is decided by where the drag **began**, not where it is now, so a gesture that
    /// wanders across the middle does not switch from brightness to volume underneath the viewer.
    private func classify(_ move: DragGesture.Value) -> DragKind {
        if abs(move.translation.width) > abs(move.translation.height) { return .seek }
        return move.startLocation.x < UIScreen.main.bounds.width / 2 ? .brightness : .volume
    }

    private func seekTarget(_ move: DragGesture.Value) -> Double {
        let duration = session.duration
        let span = duration > 0 ? duration : .greatestFiniteMagnitude
        let moved = move.translation.width / UIScreen.main.bounds.width * Self.seekSpan
        return min(max(dragOrigin + moved, 0), span)
    }

    /// Up is more, which means subtracting: a drag upward has a negative height.
    private func level(from move: DragGesture.Value) -> Double {
        min(max(dragOrigin - move.translation.height / Self.levelSpan, 0), 1)
    }

    private func seekLabel(for target: Double) -> String {
        let delta = target - dragOrigin
        let sign = delta < 0 ? "−" : "+"
        return "\(Self.clock(target))  \(sign)\(Int(abs(delta).rounded()))s"
    }

    /// An opening or ending for the panel and VoiceOver: a clock, or plainly unset. Zero is not
    /// `0:00` here — `0:00` reads like a value somebody chose.
    static func skipLabel(_ milliseconds: Double) -> String {
        milliseconds > 0 ? clock(milliseconds / 1000) : "未設定"
    }

    /// Shared with `PlayerControlBar`, which is why it is not private.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let formatted = String(format: "%02d:%02d", (total % 3600) / 60, total % 60)
        return hours > 0 ? "\(hours):\(formatted)" : formatted
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
                    onPlay: { url, title in
                        let playback = Playback(url: url, title: title)
                        PlaybackSession.shared.onPlaylistFinished = { pendingPlayback = nil }
                        playback.start()
                        pendingPlayback = playback
                    },
                    onPlayVod: { site, vod in pendingVod = VodRequest(site: site, vod: vod) },
                    onPlayInline: { vod in
                        // Straight to the player, like every other path: an inline vod carries its
                        // own playlist and player.control semantics.
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
        .fullScreenCover(item: $pendingPlayback, onDismiss: {
            PlaybackSession.shared.onPlaylistFinished = nil
        }) { _ in PlayerView() }
        .sheet(item: $pendingVod) { request in
            NavigationStack { VodView(site: request.site, summary: request.vod, source: source) }
        }
        // Every site at once since IOS-POC-20, as Android's `app.search` does.
        .sheet(item: $pendingSearch) { request in
            AggregateSearchView(sites: sites, source: source, initialQuery: request.keyword, isSheet: true)
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
