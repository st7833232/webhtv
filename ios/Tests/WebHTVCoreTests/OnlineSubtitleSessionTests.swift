import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-45. The online subtitle session against the real `PlayerRouter`: searches racing each
// other, a file surviving everything that keeps the same video playing, and nothing a provider
// does reaching the player.

// MARK: - Fakes

/// A provider whose searches wait until the test answers them, so their order is the test's.
private final class HeldProvider: SubtitleProvider, @unchecked Sendable {
    let id = "held"
    let name = "Held"
    let availability = SubtitleProviderAvailability.available
    private let lock = NSLock()
    private var waiting = [String: CheckedContinuation<SubtitleSearchResult, Error>]()
    private var queries = [String]()

    var asked: [String] {
        lock.lock(); defer { lock.unlock() }
        return queries
    }

    func isWaiting(_ text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return waiting[text] != nil
    }

    func search(_ query: SubtitleSearchQuery) async throws -> SubtitleSearchResult {
        try await withCheckedThrowingContinuation { continuation in hold(query.text, continuation) }
    }

    private func hold(_ text: String, _ continuation: CheckedContinuation<SubtitleSearchResult, Error>) {
        lock.lock(); defer { lock.unlock() }
        queries.append(text)
        waiting[text] = continuation
    }

    func answer(_ text: String, with result: Result<SubtitleSearchResult, Error>) {
        lock.lock()
        let continuation = waiting.removeValue(forKey: text)
        lock.unlock()
        continuation?.resume(with: result)
    }

    func downloadRequest(for track: RemoteSubtitleTrack) async throws -> URLRequest { URLRequest(url: track.downloadURL) }
}

/// An engine that keeps what the router hands it, embedded tracks included.
@MainActor
private final class SubtitleEngine: PlaybackEngine {
    let kind: PlaybackEngineKind
    var loads = [PlaybackLoadRequest]()
    var external = [PlaybackExternalSubtitle]()
    var selectedExternal: String?
    var tornDown = false
    var paused = false
    let embedded = PlaybackMediaTrack(options: [
        .init(id: PlaybackMediaOption.subtitleOffID, title: "關閉", isOff: true, fallbackName: "關閉"),
        .init(id: "embedded-0", title: "English", fallbackName: "字幕 1"),
    ], selectedID: "embedded-0")
    var embeddedSelection = "embedded-0"
    var currentTime: Double = 0
    var duration: Double = 0
    var rate: Float = 1
    var volume: Float = 1
    var isLoaded: Bool { !loads.isEmpty && !tornDown }
    var isPlaying: Bool { isLoaded && !paused }
    var state: PlaybackEngineState { isPlaying ? .playing : .ready }
    var bufferedUntil: Double?
    var onFailure: ((Error, Int?) -> Void)?
    var onEnded: (() -> Void)?
    var onMediaSelectionChange: ((PlaybackMediaSelection) -> Void)?

    init(kind: PlaybackEngineKind) { self.kind = kind }
    func load(_ request: PlaybackLoadRequest) { loads.append(request); paused = !request.autoplay }
    func play() { paused = false }
    func pause() { paused = true }
    func seek(toSeconds seconds: Double, landed: @escaping @MainActor () -> Void) { currentTime = seconds; landed() }
    func setRate(_ rate: Float) { self.rate = rate }
    func mediaSelection() async -> PlaybackMediaSelection {
        let embedded = PlaybackMediaTrack(options: embedded.options, selectedID: embeddedSelection)
        return PlaybackMediaSelection(subtitle: .subtitles(embedded: embedded, external: external,
                                                           selectedExternalID: selectedExternal))
    }
    func selectMedia(_ kind: PlaybackMediaKind, id: String) async {
        if external.contains(where: { $0.id == id }) {
            selectedExternal = id
            embeddedSelection = PlaybackMediaOption.subtitleOffID
        } else {
            selectedExternal = nil
            embeddedSelection = id
        }
    }
    func setExternalSubtitles(_ subtitles: [PlaybackExternalSubtitle], selectedID: String?) {
        external = subtitles
        if let selectedID { selectedExternal = selectedID; embeddedSelection = PlaybackMediaOption.subtitleOffID }
        if subtitles.isEmpty { selectedExternal = nil }
    }
    func teardown() { tornDown = true }
}

@MainActor
private final class Rig {
    let router: PlayerRouter
    let coordinator: OnlineSubtitleCoordinator
    let root: URL
    let provider: SubtitleCatProvider
    let fetch: SubtitleFetch

    init(pages: [String: String] = [:], files: [String: SubtitleHTTPResponse] = [:]) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("online-subtitle-session-\(UUID().uuidString)", isDirectory: true)
        let fetch: SubtitleFetch = { request, _ in
            let key = request.url?.absoluteString ?? ""
            if let file = files[key] { return file }
            if let page = pages[key] { return SubtitleHTTPResponse(status: 200, data: Data(page.utf8)) }
            throw URLError(.cannotFindHost)
        }
        self.fetch = fetch
        provider = SubtitleCatProvider(fetch: fetch, retryDelay: .zero)
        router = PlayerRouter(globalDefault: .native) { kind in SubtitleEngine(kind: kind) }
        let provider = self.provider
        coordinator = OnlineSubtitleCoordinator(providers: { [provider] },
                                                downloader: SubtitleDownloadService(fetch: fetch, retryDelay: .zero),
                                                root: root)
        coordinator.onAttachmentsChange = { [router] subtitles, selected in
            router.setExternalSubtitles(subtitles, selectedID: selected)
        }
    }

    var engine: SubtitleEngine? { router.engine as? SubtitleEngine }

    deinit { try? FileManager.default.removeItem(at: root) }
}

private let episode = OnlineSubtitleIdentity(titleKey: "site@@@vod", line: "線路一", episode: "https://x/ep1", address: "https://cdn/ep1.m3u8")
private let nextEpisode = OnlineSubtitleIdentity(titleKey: "site@@@vod", line: "線路一", episode: "https://x/ep2", address: "https://cdn/ep2.m3u8")

private let searchQuery = SubtitleSearchQuery(text: "FC2-PPV-4159457")
private let resultPage = "https://www.subtitlecat.com/subs/1234/FC2-PPV-4159457.html"
private let zhTWFile = "https://www.subtitlecat.com/subs/1234/FC2-PPV-4159457-zh-TW.srt"

@MainActor
private func subtitleCatRig() -> Rig {
    Rig(pages: [SubtitleCatProvider.searchURL(for: searchQuery).absoluteString: SubtitleCatFixture.searchPage,
                resultPage: SubtitleCatFixture.detailPage],
        files: [zhTWFile: SubtitleHTTPResponse(status: 200, mimeType: "application/x-subrip",
                                               data: Data(SubtitleCatFixture.srt.utf8))])
}

/// Waits for the main actor to settle what an answered task hands back.
@MainActor
private func settle(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<500 where !condition() {
        try? await Task.sleep(for: .milliseconds(2))
    }
}

private func result(_ name: String) -> SubtitleSearchResult {
    let track = RemoteSubtitleTrack(providerID: "held", providerName: "Held", language: SubtitleLanguage(code: "ja"),
                                    fileName: name, title: nil,
                                    downloadURL: URL(string: "https://www.subtitlecat.com/subs/1/\(name)")!, detailURL: nil)
    return SubtitleSearchResult(tracks: [track], listedCount: 1, openedCount: 1)
}

@MainActor
private func heldSession(_ provider: HeldProvider, title: String = "FC2PPV-1234567") -> OnlineSubtitleSession {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("held-\(UUID().uuidString)")
    return OnlineSubtitleSession(identity: episode, keywords: .make(title: title), providers: [provider],
                                 downloader: SubtitleDownloadService(fetch: { _, _ in throw URLError(.cannotFindHost) }),
                                 cache: SubtitleSessionCache(root: root))
}

// MARK: - The query (case 6) and racing searches (case 24)

/// Case 6. Recognition prefills; the viewer's text replaces it entirely and is what is searched;
/// a later keyword update does not overwrite what the viewer typed.
@MainActor @Test func theViewersTextIsSearchedAndNeverOverwrittenByRecognition() async {
    let provider = HeldProvider()
    let session = heldSession(provider)
    #expect(session.queryText == "FC2-PPV-1234567")
    #expect(session.keywords.candidates.contains("1234567"))
    session.queryText = "  完全自訂的 片名 & 演員 "
    session.updateKeywords(.make(title: "DLDSS-553"))
    #expect(session.queryText == "  完全自訂的 片名 & 演員 ")
    session.search()
    await settle { provider.isWaiting("完全自訂的 片名 & 演員") }
    #expect(provider.asked == ["完全自訂的 片名 & 演員"])
    provider.answer("完全自訂的 片名 & 演員", with: .success(.empty))
    await settle { !session.isSearching }
    // Untouched, the field does follow a keyword update.
    let untouched = heldSession(HeldProvider())
    untouched.updateKeywords(.make(title: "DLDSS553"))
    #expect(untouched.queryText == "DLDSS-553")
}

/// Case 24. The first search answering after the second is dropped: the field's latest query is
/// what the results are for.
@MainActor @Test func aLateAnswerToAnOlderSearchNeverReplacesTheNewerOne() async {
    let provider = HeldProvider()
    let session = heldSession(provider)
    session.queryText = "first"
    session.search()
    await settle { provider.isWaiting("first") }
    session.queryText = "second"
    session.search()
    await settle { provider.isWaiting("second") }
    provider.answer("second", with: .success(result("second.srt")))
    await settle { session.phase == .results(SubtitleSearchQuery(text: "second")) }
    provider.answer("first", with: .success(result("first.srt")))
    // Give the late answer every chance to land.
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
    #expect(session.phase == .results(SubtitleSearchQuery(text: "second")))
    #expect(session.results.map(\.fileName) == ["second.srt"])
}

/// Repeated taps on 搜尋 with the same text are one request; a cancelled search's answer is dropped.
@MainActor @Test func repeatedTapsAreOneRequestAndACancelledAnswerIsDropped() async {
    let provider = HeldProvider()
    let session = heldSession(provider)
    session.queryText = "same"
    session.search()
    session.search()
    session.search()
    await settle { provider.isWaiting("same") }
    #expect(provider.asked == ["same"])
    session.cancelSearch()
    #expect(session.phase == .failed(SubtitleSearchQuery(text: "same"), .cancelled))
    provider.answer("same", with: .success(result("late.srt")))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(session.results.isEmpty)
}

/// Every provider failure is a state of the panel, in the panel's own terms.
@MainActor @Test func aProviderFailureIsAStateNotARawError() async {
    let provider = HeldProvider()
    let session = heldSession(provider)
    session.search()
    await settle { provider.isWaiting("FC2-PPV-1234567") }
    provider.answer("FC2-PPV-1234567", with: .failure(URLError(.notConnectedToInternet)))
    await settle { !session.isSearching }
    #expect(session.phase == .failed(SubtitleSearchQuery(text: "FC2-PPV-1234567"), .unreachable))
    #expect(SubtitleProviderError.unreachable.message(provider: "Subtitle Cat") == "Subtitle Cat 暫時無法使用（連線失敗）")
}

// MARK: - The whole path, and the player (cases 20–22, 25)

/// Search, pick, download into the session folder, and the player is handed the file at once.
@MainActor @Test func pickingAResultDownloadsItAndHandsItToThePlayer() async throws {
    let rig = subtitleCatRig()
    rig.router.open(PlaybackLoadRequest(target: PlaybackTarget(url: URL(string: "https://cdn/ep1.m3u8")!)))
    let session = rig.coordinator.playbackOpened(episode, title: "FC2PPV-4159457 某標題")
    session.search()
    await settle { !session.isSearching }
    #expect(session.phase == .results(searchQuery))
    #expect(session.results.first?.language.code == "zh-TW")
    // Searching downloaded nothing.
    #expect((try? FileManager.default.contentsOfDirectory(atPath: session.cache.directory.path)) == nil)
    let zhTW = try #require(session.results.first)
    session.choose(zhTW)
    await settle { session.attached.count == 1 }
    let subtitle = try #require(session.attached.first)
    #expect(session.downloads[zhTW.id] == .ready(subtitle.id))
    #expect(FileManager.default.fileExists(atPath: subtitle.fileURL.path))
    #expect(rig.router.externalSubtitles == [subtitle])
    #expect(rig.router.selectedExternalSubtitleID == subtitle.id)
    #expect(rig.engine?.external == [subtitle])
    #expect(await rig.engine?.mediaSelection().subtitle?.selectedID == subtitle.id)
    // The same file again: the session's copy, no second file.
    session.choose(zhTW)
    await settle { session.downloads[zhTW.id] == .ready(subtitle.id) }
    #expect(session.attached.count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: session.cache.directory.path).count == 1)
}

/// Case 20. An engine switch, either way, keeps the file and the choice: the engine taking over is
/// handed both before it loads — no second download, no lost subtitle.
@MainActor @Test func anEngineSwitchKeepsTheDownloadedSubtitle() async throws {
    let rig = subtitleCatRig()
    rig.router.open(PlaybackLoadRequest(target: PlaybackTarget(url: URL(string: "https://cdn/ep1.m3u8")!)))
    let session = rig.coordinator.playbackOpened(episode, title: "FC2-PPV-4159457")
    session.search()
    await settle { !session.isSearching }
    session.choose(try #require(session.results.first))
    await settle { session.attached.count == 1 }
    let subtitle = try #require(session.attached.first)
    let native = try #require(rig.engine)

    #expect(rig.router.select(.mpv))
    let mpv = try #require(rig.engine)
    #expect(mpv !== native && mpv.kind == .mpv)
    #expect(native.tornDown)
    #expect(mpv.external == [subtitle])
    #expect(mpv.selectedExternal == subtitle.id)
    #expect(await mpv.mediaSelection().subtitle?.selectedID == subtitle.id)

    #expect(rig.router.select(.native))
    let back = try #require(rig.engine)
    #expect(back.kind == .native && back.external == [subtitle] && back.selectedExternal == subtitle.id)
    #expect(FileManager.default.fileExists(atPath: subtitle.fileURL.path))
    #expect(rig.coordinator.session === session)
}

/// Choosing an embedded track or 「關閉」 forgets the online choice for the next engine, and keeps
/// the file listed.
@MainActor @Test func choosingAnEmbeddedTrackIsRememberedAcrossASwitchToo() async throws {
    let rig = subtitleCatRig()
    rig.router.open(PlaybackLoadRequest(target: PlaybackTarget(url: URL(string: "https://cdn/ep1.m3u8")!)))
    let session = rig.coordinator.playbackOpened(episode, title: "FC2-PPV-4159457")
    session.search()
    await settle { !session.isSearching }
    session.choose(try #require(session.results.first))
    await settle { session.attached.count == 1 }
    await rig.router.selectMedia(.subtitle, id: "embedded-0")
    #expect(rig.router.selectedExternalSubtitleID == nil)
    #expect(rig.router.select(.mpv))
    #expect(rig.engine?.selectedExternal == nil)
    #expect(rig.engine?.external.count == 1)
}

/// Case 21. Pause, the background and coming back (the paused reload IOS-POC-23 makes), a seek, a
/// quality switch and a reopen of the same episode all keep the session and its file — none of
/// them ends a subtitle session; only the identity or the player closing does.
@MainActor @Test func pauseBackgroundForegroundAndReloadsKeepTheSubtitle() async throws {
    let rig = subtitleCatRig()
    rig.router.open(PlaybackLoadRequest(target: PlaybackTarget(url: URL(string: "https://cdn/ep1.m3u8")!)))
    let session = rig.coordinator.playbackOpened(episode, title: "FC2-PPV-4159457")
    session.search()
    await settle { !session.isSearching }
    session.choose(try #require(session.results.first))
    await settle { session.attached.count == 1 }
    let subtitle = try #require(session.attached.first)
    let engine = try #require(rig.engine)

    engine.pause()                                       // pause
    rig.router.setIntendsToPlay(false)
    engine.seek(toSeconds: 120)                          // seek
    rig.router.reload(at: 120, autoplay: false)          // background → suspended → foreground reload
    // A quality switch and the prefetch retry open the same episode again.
    rig.router.open(PlaybackLoadRequest(target: PlaybackTarget(url: URL(string: "https://cdn/ep1-720.m3u8")!)))
    #expect(rig.coordinator.playbackOpened(episode, title: "FC2-PPV-4159457") === session)

    #expect(rig.engine === engine && engine.loads.count == 3)
    #expect(engine.external == [subtitle])
    #expect(rig.router.externalSubtitles == [subtitle])
    #expect(FileManager.default.fileExists(atPath: subtitle.fileURL.path))
    #expect(!session.hasEnded)
}

/// Case 22. The player closing ends the session: the folder is gone and the player is told it has
/// no online subtitles any more. Moving to the next episode does the same for the previous one.
@MainActor @Test func endingThePlaybackSessionDeletesItsSubtitles() async throws {
    let rig = subtitleCatRig()
    rig.router.open(PlaybackLoadRequest(target: PlaybackTarget(url: URL(string: "https://cdn/ep1.m3u8")!)))
    let first = rig.coordinator.playbackOpened(episode, title: "FC2-PPV-4159457")
    first.search()
    await settle { !first.isSearching }
    first.choose(try #require(first.results.first))
    await settle { first.attached.count == 1 }
    let folder = first.cache.directory
    #expect(FileManager.default.fileExists(atPath: folder.path))

    // The next episode: a new session, the old files gone, the player emptied.
    let second = rig.coordinator.playbackOpened(nextEpisode, title: "FC2-PPV-4159457")
    #expect(second !== first && first.hasEnded)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(rig.router.externalSubtitles.isEmpty && rig.engine?.external.isEmpty == true)
    #expect(second.queryText == "FC2-PPV-4159457")

    second.search()
    await settle { !second.isSearching }
    second.choose(try #require(second.results.first))
    await settle { second.attached.count == 1 }
    let secondFolder = second.cache.directory
    rig.router.endSession()
    rig.coordinator.playbackClosed()
    #expect(rig.coordinator.session == nil)
    #expect(!FileManager.default.fileExists(atPath: secondFolder.path))
    #expect(rig.router.externalSubtitles.isEmpty)
    // A download finishing after the end is not kept.
    let late = try #require(second.results.first)
    #expect(throws: SubtitleProviderError.cancelled) {
        try second.cache.store(text: SubtitleCatFixture.srt, cues: SubRip.parse(SubtitleCatFixture.srt), for: late)
    }
}

/// Case 25. A provider failing — search or download — leaves the player exactly as it was: the
/// same engine, still loaded, never reloaded, its embedded subtitles listed and still selected.
@MainActor @Test func aProviderFailureLeavesThePlayerAndItsEmbeddedSubtitlesAlone() async throws {
    let rig = Rig(pages: [SubtitleCatProvider.searchURL(for: searchQuery).absoluteString: SubtitleCatFixture.searchPage,
                          resultPage: SubtitleCatFixture.detailPage],
                  files: [zhTWFile: SubtitleHTTPResponse(status: 200, mimeType: "text/html",
                                                         data: Data(SubtitleCatFixture.cloudflareChallenge.utf8))])
    rig.router.open(PlaybackLoadRequest(target: PlaybackTarget(url: URL(string: "https://cdn/ep1.m3u8")!)))
    let engine = try #require(rig.engine)
    let before = await engine.mediaSelection()
    let session = rig.coordinator.playbackOpened(episode, title: "FC2-PPV-4159457")

    // A search that cannot reach the site at all.
    session.queryText = "unreachable query"
    session.search()
    await settle { !session.isSearching }
    #expect(session.phase == .failed(SubtitleSearchQuery(text: "unreachable query"), .unreachable))

    // A search that works, and a download that turns out to be a challenge page.
    session.queryText = searchQuery.text
    session.search()
    await settle { !session.isSearching }
    let zhTW = try #require(session.results.first)
    session.choose(zhTW)
    await settle { session.downloads[zhTW.id] != .downloading }
    #expect(session.downloads[zhTW.id] == .failed(.blockedByChallenge))
    #expect(session.attached.isEmpty)

    #expect(rig.engine === engine && !engine.tornDown && engine.loads.count == 1 && !engine.paused)
    #expect(rig.router.externalSubtitles.isEmpty && rig.router.failure == nil)
    #expect(await engine.mediaSelection() == before)
    #expect(before.subtitle?.selectedID == "embedded-0")
}
