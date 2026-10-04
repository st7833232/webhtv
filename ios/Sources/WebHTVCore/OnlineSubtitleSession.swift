import Foundation
import Observation
import os

/// IOS-POC-45 — which video the online subtitles belong to.
///
/// A titled episode is its title, line and episode address (`WatchHistory.key`, `vodFlag`,
/// `episodeUrl`): a quality switch, a reload or a re-resolve of the same episode keeps all three,
/// so its subtitles stay; the next episode changes the address, so they go. A playback with no
/// record (a WebHome page's bare URL or inline playlist item) is its address.
public struct OnlineSubtitleIdentity: Sendable, Equatable, Hashable {
    let value: String

    public init(titleKey: String?, line: String?, episode: String?, address: String) {
        if let titleKey, !titleKey.isEmpty {
            value = ["title", titleKey, line ?? "", episode ?? ""].joined(separator: "\u{1F}")
        } else {
            value = ["address", address].joined(separator: "\u{1F}")
        }
    }
}

/// IOS-POC-45 — the online subtitle state of one playback session: what the panel's 線上字幕
/// section shows, and the files downloaded for this video.
///
/// **The query is the viewer's.** `queryText` is prefilled from `keywords` once; after that only
/// the viewer changes it — a later keyword update replaces it only while it still holds the old
/// prefill. Searching sends exactly the field's text (`SubtitleSearchQuery` trims its ends).
///
/// **The latest search wins.** A new search cancels the one in flight, and every answer carries
/// the generation it was asked in: an older search answering late is dropped, never shown over the
/// newer one. The same query already in flight is not asked again, so repeated taps on 搜尋 make
/// one request.
///
/// **One download at a time, the latest tap wins**, and a file this session already has is used
/// again without a download. Nothing here can stop or reset playback: a failure is a state of this
/// object, shown in the panel, and the player keeps its embedded subtitles and its picture.
@MainActor @Observable
public final class OnlineSubtitleSession {
    public enum Phase: Equatable, Sendable {
        case idle
        case searching(SubtitleSearchQuery)
        case results(SubtitleSearchQuery)
        /// The provider found nothing — or found results with no file ready to download.
        case noResults(SubtitleSearchQuery)
        case failed(SubtitleSearchQuery, SubtitleProviderError)
    }

    public enum DownloadState: Equatable, Sendable {
        case downloading
        /// Downloaded into this session; the id is the `PlaybackExternalSubtitle`'s.
        case ready(String)
        case failed(SubtitleProviderError)
    }

    public struct ProviderEntry: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let availability: SubtitleProviderAvailability
    }

    public let identity: OnlineSubtitleIdentity
    public let providerEntries: [ProviderEntry]
    public var selectedProviderID: String
    /// The editable search field.
    public var queryText: String
    public private(set) var keywords: SubtitleSearchKeywords
    public private(set) var phase = Phase.idle
    public private(set) var results = [RemoteSubtitleTrack]()
    /// How many results the last search listed and opened (`SubtitleSearchResult`).
    public private(set) var listedCount = 0
    public private(set) var openedCount = 0
    public private(set) var downloads = [RemoteSubtitleTrack.ID: DownloadState]()
    /// Everything downloaded in this session, in the order it was.
    public private(set) var attached = [PlaybackExternalSubtitle]()

    /// A file is ready; `OnlineSubtitleCoordinator` hands it to the player.
    @ObservationIgnored var onAttach: ((PlaybackExternalSubtitle) -> Void)?
    /// IOS-POC-45H: one of the source's own subtitles is ready, and whether to show it.
    @ObservationIgnored var onSourceAttach: ((PlaybackExternalSubtitle, Bool) -> Void)?
    /// The viewer picked a subtitle for this video — in the panel, or by downloading one — so a
    /// source's default is no longer shown in its place.
    @ObservationIgnored public private(set) var viewerChoseSubtitle = false
    @ObservationIgnored private var sourceTask: Task<Void, Never>?
    @ObservationIgnored private var sourceGeneration = 0
    @ObservationIgnored private var sourceAttached = false
    @ObservationIgnored private var sourceShown = false
    @ObservationIgnored public let cache: SubtitleSessionCache
    @ObservationIgnored private let providers: [any SubtitleProvider]
    @ObservationIgnored private let downloader: SubtitleDownloadService
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var downloadGeneration = 0
    @ObservationIgnored public private(set) var hasEnded = false

    static let log = Logger(subsystem: "com.webhtv.ios.poc", category: "subtitle")

    public init(identity: OnlineSubtitleIdentity, keywords: SubtitleSearchKeywords,
                providers: [any SubtitleProvider], downloader: SubtitleDownloadService,
                cache: SubtitleSessionCache) {
        self.identity = identity
        self.keywords = keywords
        self.providers = providers
        self.downloader = downloader
        self.cache = cache
        queryText = keywords.prefill
        providerEntries = providers.map { ProviderEntry(id: $0.id, name: $0.name, availability: $0.availability) }
        selectedProviderID = providers.first(where: { $0.availability == .available })?.id
            ?? providers.first?.id ?? ""
    }

    public var selectedProvider: ProviderEntry? { providerEntries.first { $0.id == selectedProviderID } }

    public var isSearching: Bool {
        if case .searching = phase { return true }
        return false
    }

    // MARK: Search

    /// Searches the field's text with the selected provider.
    public func search() {
        let query = SubtitleSearchQuery(text: queryText)
        guard !hasEnded, let provider = providers.first(where: { $0.id == selectedProviderID }),
              provider.availability == .available else { return }
        guard !query.isEmpty else {
            cancelSearch()
            phase = .idle
            return
        }
        // The same text already on its way: one request, however many taps.
        if case .searching(let current) = phase, current == query { return }
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        phase = .searching(query)
        results = []
        listedCount = 0
        openedCount = 0
        let started = ContinuousClock.now
        searchTask = Task { [weak self] in
            let outcome: Result<SubtitleSearchResult, SubtitleProviderError>
            do {
                outcome = .success(try await provider.search(query))
            } catch {
                outcome = .failure(.classify(error))
            }
            self?.finishSearch(outcome, query: query, provider: provider.name, generation: generation,
                               milliseconds: Int((ContinuousClock.now - started) / .milliseconds(1)))
        }
    }

    /// A candidate chip: it becomes the field's text, and is searched.
    public func search(candidate: String) {
        queryText = candidate
        search()
    }

    /// Stops the search in flight. Its answer, if it still arrives, is dropped.
    public func cancelSearch() {
        guard let searchTask else { return }
        searchTask.cancel()
        self.searchTask = nil
        searchGeneration += 1
        if case .searching(let query) = phase { phase = .failed(query, .cancelled) }
    }

    private func finishSearch(_ outcome: Result<SubtitleSearchResult, SubtitleProviderError>,
                              query: SubtitleSearchQuery, provider: String, generation: Int, milliseconds: Int) {
        // A newer search, a cancel, or the end of the session got here first.
        guard generation == searchGeneration, !hasEnded else { return }
        searchTask = nil
        switch outcome {
        case .success(let result):
            results = result.tracks
            listedCount = result.listedCount
            openedCount = result.openedCount
            phase = result.tracks.isEmpty ? .noResults(query) : .results(query)
            Self.log.notice("[subtitle] search provider=\(provider, privacy: .public) query=\"\(query.text, privacy: .public)\" listed=\(result.listedCount) opened=\(result.openedCount) files=\(result.tracks.count) in \(milliseconds)ms")
        case .failure(let error):
            phase = .failed(query, error)
            Self.log.notice("[subtitle] search provider=\(provider, privacy: .public) query=\"\(query.text, privacy: .public)\" failed=\(error.category, privacy: .public) in \(milliseconds)ms")
        }
    }

    /// New keywords for the same video. The field follows only if the viewer has not touched it.
    public func updateKeywords(_ keywords: SubtitleSearchKeywords) {
        if queryText == self.keywords.prefill { queryText = keywords.prefill }
        self.keywords = keywords
    }

    // MARK: Download

    /// Downloads the track, checks it, keeps it for this session and hands it to the player —
    /// or, for a file this session already has, hands that over at once.
    public func choose(_ track: RemoteSubtitleTrack) {
        guard !hasEnded else { return }
        viewerChoseSubtitle = true
        if downloads[track.id] == .downloading { return }
        downloadTask?.cancel()
        for (id, state) in downloads where state == .downloading { downloads[id] = nil }
        downloadGeneration += 1
        let generation = downloadGeneration
        guard let provider = providers.first(where: { $0.id == track.providerID }) else {
            downloads[track.id] = .failed(.unconfigured)
            return
        }
        downloads[track.id] = .downloading
        let downloader = downloader, cache = cache
        downloadTask = Task { [weak self] in
            let outcome: Result<PlaybackExternalSubtitle, SubtitleProviderError>
            do {
                outcome = .success(try await downloader.download(track, from: provider, into: cache))
            } catch {
                outcome = .failure(.classify(error))
            }
            self?.finishDownload(outcome, track: track, generation: generation)
        }
    }

    private func finishDownload(_ outcome: Result<PlaybackExternalSubtitle, SubtitleProviderError>,
                                track: RemoteSubtitleTrack, generation: Int) {
        guard generation == downloadGeneration, !hasEnded else { return }
        downloadTask = nil
        let file = track.fileName
        switch outcome {
        case .success(let subtitle):
            downloads[track.id] = .ready(subtitle.id)
            if !attached.contains(where: { $0.id == subtitle.id }) { attached.append(subtitle) }
            let size = (try? subtitle.fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            Self.log.notice("[subtitle] download provider=\(track.providerName, privacy: .public) file=\(file, privacy: .public) language=\(track.language.code ?? "unknown", privacy: .public) bytes=\(size) cues=\(subtitle.cues.cues.count)")
            onAttach?(subtitle)
        case .failure(.cancelled):
            downloads[track.id] = nil
        case .failure(let error):
            downloads[track.id] = .failed(error)
            Self.log.notice("[subtitle] download provider=\(track.providerName, privacy: .public) file=\(file, privacy: .public) failed=\(error.category, privacy: .public)")
        }
    }

    // MARK: Source subtitles (IOS-POC-45H)

    /// The viewer chose a subtitle track in the panel.
    public func noteSubtitleChoice() { viewerChoseSubtitle = true }

    /// The subtitles the source listed with this item's play result: downloaded through the same
    /// checks as an online file, the default one first, then the rest one at a time. Once one of a
    /// list's files is here, later lists for this video are ignored — a quality switch or the
    /// prefetch retry opens the same video again, often with freshly signed copies of the same
    /// files. Until then a later list replaces the earlier one: the prefetch retry's live answer is
    /// exactly what comes after a list whose signed links had expired. The default is shown once,
    /// and only while the viewer has not picked a subtitle for this video. Separate from `choose`,
    /// so neither cancels the other.
    public func loadSourceSubtitles(_ subtitles: [SourceSubtitle], provider: SourceSubtitleProvider,
                                    preferredLanguage: String?) {
        guard !hasEnded, !sourceAttached, !subtitles.isEmpty else { return }
        sourceTask?.cancel()
        sourceGeneration += 1
        let generation = sourceGeneration
        let plan = SourceSubtitles.plan(subtitles, preferredLanguage: preferredLanguage)
        Self.log.notice("[subtitle] source listed=\(plan.listed) usable=\(plan.tracks.count) skipped=\(plan.skipped) default=\(plan.chosenID == nil ? "none" : "yes", privacy: .public)")
        guard !plan.tracks.isEmpty else { return }
        let downloader = downloader, cache = cache
        sourceTask = Task { [weak self] in
            for track in plan.tracks {
                guard !Task.isCancelled else { return }
                let outcome: Result<PlaybackExternalSubtitle, SubtitleProviderError>
                do {
                    // A source that names no language is most likely Chinese: GB 18030 or Big5,
                    // not Windows-1252, when the file is not UTF-8.
                    outcome = .success(try await downloader.download(
                        track, from: provider, into: cache, label: track.title,
                        decodingLanguage: track.language.code == nil ? SubtitleLanguage(code: "zh") : nil))
                } catch {
                    outcome = .failure(.classify(error))
                }
                guard let self, generation == self.sourceGeneration else { return }
                self.finishSourceDownload(outcome, track: track, chosen: track.id == plan.chosenID)
            }
        }
    }

    /// IOS-POC-47: a downloaded episode's own subtitle files, already on the device. Handed to the
    /// engines like the source's files — nothing is fetched, and the files are not this session's
    /// to delete (they live with the download, not in `cache`). The first is shown unless the
    /// viewer has picked one.
    public func attachOffline(_ subtitles: [PlaybackExternalSubtitle]) {
        guard !hasEnded, !sourceAttached, !subtitles.isEmpty else { return }
        sourceAttached = true
        for (index, subtitle) in subtitles.enumerated() where !attached.contains(where: { $0.id == subtitle.id }) {
            attached.append(subtitle)
            let show = index == 0 && !viewerChoseSubtitle && !sourceShown
            if show { sourceShown = true }
            onSourceAttach?(subtitle, show)
        }
        Self.log.notice("[subtitle] offline files=\(subtitles.count)")
    }

    private func finishSourceDownload(_ outcome: Result<PlaybackExternalSubtitle, SubtitleProviderError>,
                                      track: RemoteSubtitleTrack, chosen: Bool) {
        guard !hasEnded else { return }
        let language = track.language.code ?? "unknown"
        switch outcome {
        case .success(let subtitle):
            if !attached.contains(where: { $0.id == subtitle.id }) { attached.append(subtitle) }
            sourceAttached = true
            let show = chosen && !viewerChoseSubtitle && !sourceShown
            if show { sourceShown = true }
            // Never the address or the file name: either can carry a source's token.
            Self.log.notice("[subtitle] source file language=\(language, privacy: .public) cues=\(subtitle.cues.cues.count) default=\(chosen ? "yes" : "no", privacy: .public) shown=\(show ? "yes" : "no", privacy: .public)")
            onSourceAttach?(subtitle, show)
        case .failure(.cancelled):
            break
        case .failure(let error):
            Self.log.notice("[subtitle] source file language=\(language, privacy: .public) failed=\(error.category, privacy: .public)")
        }
    }

    // MARK: End

    /// The playback session is over: work in flight stops and the files are deleted.
    func end() {
        hasEnded = true
        searchTask?.cancel()
        downloadTask?.cancel()
        sourceTask?.cancel()
        searchTask = nil
        downloadTask = nil
        sourceTask = nil
        onAttach = nil
        onSourceAttach = nil
        cache.end()
    }
}

/// IOS-POC-45 — the one place a subtitle session starts and ends.
///
/// `PlaybackSession` reports every item it opens and the player closing; this decides. The same
/// video keeps its session — a quality switch, a reload, the prefetch retry, all of which open an
/// item again. A different video, or the player closing (or the WebHome bridge's stop), ends it:
/// its downloads are deleted and the player is told it has no online subtitles any more. Pause,
/// seek, the background, Picture in Picture and an engine switch never reach here at all, which is
/// why none of them can lose a subtitle.
@MainActor
public final class OnlineSubtitleCoordinator {
    public private(set) var session: OnlineSubtitleSession?
    /// What the player should have now: the session's files, and the one just chosen (nil when
    /// the list was emptied because the session ended).
    public var onAttachmentsChange: (([PlaybackExternalSubtitle], String?) -> Void)?
    /// IOS-POC-45H: the session's files after one of the source's own arrived, and the one to show
    /// (nil keeps whatever is shown now). Not a choice of the viewer's: no notice, no panel change.
    public var onSourceAttachmentsChange: (([PlaybackExternalSubtitle], String?) -> Void)?

    private let makeProviders: @MainActor () -> [any SubtitleProvider]
    private let downloader: SubtitleDownloadService
    private let root: URL

    public init(providers: @escaping @MainActor () -> [any SubtitleProvider] = { [SubtitleCatProvider()] },
                downloader: SubtitleDownloadService = SubtitleDownloadService(),
                root: URL = SubtitleSessionCache.defaultRoot) {
        makeProviders = providers
        self.downloader = downloader
        self.root = root
    }

    /// An item was opened. Answers the session the panel should show.
    @discardableResult
    public func playbackOpened(_ identity: OnlineSubtitleIdentity, title: String,
                               alternatives: [String] = []) -> OnlineSubtitleSession {
        let keywords = SubtitleSearchKeywords.make(title: title, alternatives: alternatives)
        if let session, session.identity == identity {
            session.updateKeywords(keywords)
            return session
        }
        endSession()
        let made = OnlineSubtitleSession(identity: identity, keywords: keywords, providers: makeProviders(),
                                         downloader: downloader, cache: SubtitleSessionCache(root: root))
        made.onAttach = { [weak self, weak made] subtitle in
            guard let self, let made, self.session === made else { return }
            self.onAttachmentsChange?(made.attached, subtitle.id)
        }
        made.onSourceAttach = { [weak self, weak made] subtitle, show in
            guard let self, let made, self.session === made else { return }
            self.onSourceAttachmentsChange?(made.attached, show ? subtitle.id : nil)
        }
        session = made
        return made
    }

    /// The player closed, or the bridge stopped playback.
    public func playbackClosed() { endSession() }

    private func endSession() {
        guard let session else { return }
        self.session = nil
        let hadFiles = !session.attached.isEmpty
        session.end()
        OnlineSubtitleSession.log.notice("[subtitle] session ended, files deleted=\(hadFiles ? "yes" : "none", privacy: .public)")
        onAttachmentsChange?([], nil)
    }
}
