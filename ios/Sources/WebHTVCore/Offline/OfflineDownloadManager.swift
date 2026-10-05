import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif

/// IOS-POC-47 — what the downloads screens see: every record, the folders that could not be read,
/// and how much the offline root occupies.
public struct OfflineSnapshot: Equatable, Sendable {
    public var assets: [OfflineAsset]
    public var unreadable: [String]
    public var usageBytes: Int64
    /// Increases with every snapshot, so a late one never replaces a newer one.
    public var sequence: Int

    public init(assets: [OfflineAsset] = [], unreadable: [String] = [], usageBytes: Int64 = 0, sequence: Int = 0) {
        self.assets = assets
        self.unreadable = unreadable
        self.usageBytes = usageBytes
        self.sequence = sequence
    }
}

public enum OfflineEnqueueResult: Equatable, Sendable {
    /// A new download was queued.
    case created(OfflineAsset)
    /// This episode already has a download — finished, running or waiting for a decision. Nothing
    /// new was created; the screen shows that one.
    case existing(OfflineAsset)
    /// Refused before anything was stored (no room, DRM).
    case refused(OfflineFailure)
}

public struct OfflineDeletionResult: Equatable, Sendable {
    public var deleted: Int
    /// What the deleted folders occupied on disk.
    public var releasedBytes: Int64
}

/// Download logging: asset id (a UUID, no address), counts, bytes, status codes and failure kinds
/// only — never a URL, a header, a cookie or a token.
enum OfflineLog {
    #if canImport(os)
    static let logger = Logger(subsystem: "com.webhtv.ios.poc", category: "offline")
    static func notice(_ line: String) { logger.notice("\(line, privacy: .public)") }
    #else
    static func notice(_ line: String) {}
    #endif

    static func short(_ id: String) -> String { String(id.prefix(8)) }
}

/// IOS-POC-47 — the one owner of offline downloads: scheduling, start, pause, resume, retry,
/// delete, the playback-completion rule, and recovery after a relaunch.
///
/// **One entry for deleting** (`delete(_:)`): the downloads screen, a failed download's 刪除下載,
/// a swipe, the bulk actions, the watch-history delete and the watched-auto-delete all come here,
/// and it always does the whole job — cancel the transfers, remove the folder (record, media,
/// audio, subtitles, keys, partial data), forget the record, remeasure the space.
///
/// **Generations, not hopes.** Every pause, resume, retry, failure and delete bumps the asset's
/// generation and every transfer carries the generation it started under, so a callback that
/// arrives late — a segment finishing after the viewer deleted the episode — is recognised and
/// dropped. A deleted asset has no record to update, so nothing can bring it back.
///
/// At most `concurrentDownloads` assets prepare or download at once (IOS-POC-50); the rest wait
/// as `queued`.
public actor OfflineDownloadManager {
    public struct Dependencies: Sendable {
        public var layout: OfflineStorageLayout
        public var transport: any OfflineTransport
        public var capacity: @Sendable () -> Int64?
        /// Builds the foreground fetcher used for playlists and the progressive probe.
        public var fetcher: @Sendable (_ origin: URL, _ headers: [String: String]) -> OfflineFetch
        public var subtitles: SubtitleDownloadService
        public var retryDelay: Duration
        public var now: @Sendable () -> Date

        public init(layout: OfflineStorageLayout, transport: any OfflineTransport,
                    capacity: @escaping @Sendable () -> Int64?,
                    fetcher: @escaping @Sendable (URL, [String: String]) -> OfflineFetch,
                    subtitles: SubtitleDownloadService, retryDelay: Duration = .seconds(2),
                    now: @escaping @Sendable () -> Date = { .now }) {
            self.layout = layout
            self.transport = transport
            self.capacity = capacity
            self.fetcher = fetcher
            self.subtitles = subtitles
            self.retryDelay = retryDelay
            self.now = now
        }
    }

    /// A transfer that failed is tried again this many times before the download is failed.
    static let transferRetries = 2
    /// IOS-POC-52 (F10): the same for a connectivity failure — the connection, not the request.
    static let connectivityRetries = 10
    /// IOS-POC-52 (F10): credentialed units in flight at once. Their session queues the rest behind
    /// four connections, and a queued request's 30 s timer is already running.
    static let credentialedWindow = 6

    public let layout: OfflineStorageLayout
    let store: OfflineAssetStore
    private let deps: Dependencies
    private var started = false
    private var observer: (@Sendable (OfflineSnapshot) -> Void)?
    private var resolver: (@Sendable (OfflineAsset) async -> PlaybackTarget?)?
    private var plans = [String: OfflinePackagePlan]()
    private var done = [String: Set<Int>]()
    /// IOS-POC-51: each finished unit's size, for projecting the package's size as it arrives.
    private var sizes = [String: [Int: Int64]]()
    private var attempts = [OfflineTransferTag: Int]()
    /// What the folders no record could be read for occupy, measured at launch and after a delete.
    private var unreadableUsage: Int64 = 0
    /// IOS-POC-52 (F13): 設定 › 看完後自動刪除. Off, nothing is auto-deleted, whatever a download was
    /// set to when it was made.
    private var autoDeleteEnabled = true
    /// IOS-POC-52 (F10): credentialed units waiting for room in the window, and those in flight.
    private var waitingCredentialed = [String: [OfflineDownloadUnit]]()
    private var credentialedInFlight = [String: Set<Int>]()
    private var lastPublish = Date.distantPast
    private var trailingPublish: Task<Void, Never>?
    private var unitsSinceFlush = 0
    private var sequence = 0

    public init(_ dependencies: Dependencies) {
        deps = dependencies
        layout = dependencies.layout
        store = OfflineAssetStore(layout: dependencies.layout)
    }

    // MARK: - Hooks

    public func setObserver(_ observer: @escaping @Sendable (OfflineSnapshot) -> Void) {
        self.observer = observer
        observer(snapshot())
    }

    /// Resolves an episode again for a retry whose addresses expired. The app supplies it: only the
    /// app knows the loaded configuration and its sites.
    public func setResolver(_ resolver: @escaping @Sendable (OfflineAsset) async -> PlaybackTarget?) {
        self.resolver = resolver
    }

    public func snapshot() -> OfflineSnapshot {
        sequence += 1
        let assets = store.all()
        return OfflineSnapshot(assets: assets, unreadable: store.unreadable.keys.sorted(), usageBytes: usage(of: assets),
                               sequence: sequence)
    }

    // MARK: - Launch

    /// Reads the records, finishes what a crash interrupted, and reconnects to the transfers a
    /// background session kept going. Called once at launch (and again by tests).
    public func start() async {
        guard !started else { return }
        started = true
        let report = store.load()
        OfflineLog.notice("[offline] launch loaded=\(report.loaded) migrated=\(report.migrated) unreadable=\(report.unreadable.count) orphans=\(report.removedOrphans) temporaries=\(report.removedTemporaries)")
        cleanTemporary()
        await deps.transport.attach({ [weak self] tag, event in await self?.handle(tag, event) },
                                    settle: { [weak self] in await self?.settle() })

        // IOS-POC-52 (F13): with the setting off, an auto-delete armed before is not one any more.
        if !autoDeleteEnabled { disarmAutoDeletes() }
        // A delete or an auto-delete a crash interrupted is finished now: no player holds anything
        // this early in a launch.
        let pending = store.all().filter { $0.state == .deleting || $0.pendingAutoDelete }.map(\.id)
        if !pending.isEmpty { _ = await deleteNow(pending, reason: "launch") }

        // IOS-POC-52 (F3): transfers left running for an asset that is gone, stopped or a
        // generation on would download for nothing until they end.
        let stale = await deps.transport.activeTags().filter { tag in
            guard let asset = store.asset(tag.assetID) else { return true }
            return asset.state != .downloading || asset.generation != tag.generation
        }
        if !stale.isEmpty {
            OfflineLog.notice("[offline] launch cancelled stale transfers=\(stale.count)")
            await deps.transport.cancel(tags: stale)
        }

        for asset in store.all() {
            switch asset.state {
            case .preparing:
                // Preparing is network work in the app's own process: nothing kept it going.
                _ = store.update(asset.id, now: deps.now()) { $0.state = .queued }
            case .downloading:
                await adoptStaged(asset)
                await reconnect(asset)
            case .completed:
                if let package = asset.package,
                   !FileManager.default.fileExists(atPath: layout.folder(for: asset.id).appendingPathComponent(package.entryPath).path) {
                    _ = store.update(asset.id, now: deps.now()) {
                        $0.state = .failed
                        $0.failure = OfflineFailure(.integrity, detail: "檔案遺失")
                    }
                }
            default:
                break
            }
        }
        measureUnreadable()
        publish(force: true)
        await pump()
    }

    /// IOS-POC-52 (F11): bodies the session delivered but the app never handled — it was suspended
    /// or ended first — are taken up instead of downloaded again.
    private func adoptStaged(_ asset: OfflineAsset) async {
        guard let plan = loadPlan(asset.id) else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.stagingDirectory.path)) ?? []
        for name in names {
            guard isCurrent(asset.id, asset.generation, .downloading), let staged = OfflineStagedBody.parse(name),
                  staged.tag.assetID == asset.id, staged.tag.generation == asset.generation, let status = staged.status,
                  plan.units.indices.contains(staged.tag.unit) else { continue }
            await accept(layout.stagingDirectory.appendingPathComponent(name), status: status,
                         unit: plan.units[staged.tag.unit], tag: staged.tag)
        }
    }

    /// IOS-POC-52 (F11): what a background wake started — the next download's preparing — gets up
    /// to 20 s to finish before the transport tells iOS the wake is done.
    func settle() async {
        let deadline = ContinuousClock.now + .seconds(20)
        while store.all().contains(where: { $0.state == .preparing }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// IOS-POC-52 (F10): back in the foreground, everything a download lost while the app was
    /// suspended — a credentialed transfer stops with the app — is sent again.
    public func resubmitRunning() async {
        for asset in store.all() where asset.state == .downloading {
            if let plan = loadPlan(asset.id) { await submitMissing(asset.id, plan: plan) }
        }
    }

    /// Only this feature's staging files go, and only the ones no current transfer will claim.
    private func cleanTemporary() {
        let manager = FileManager.default
        try? manager.createDirectory(at: layout.stagingDirectory, withIntermediateDirectories: true)
        let files = (try? manager.contentsOfDirectory(atPath: layout.stagingDirectory.path)) ?? []
        for name in files {
            let tag = OfflineTransferTag(description: name.components(separatedBy: ".").first)
            if let tag, let asset = store.asset(tag.assetID), asset.state == .downloading,
               asset.generation == tag.generation { continue }
            try? manager.removeItem(at: layout.stagingDirectory.appendingPathComponent(name))
        }
    }

    /// A download the record says is running: whatever the session no longer has is sent again.
    private func reconnect(_ asset: OfflineAsset) async {
        guard let plan = loadPlan(asset.id) else {
            _ = store.update(asset.id, now: deps.now()) {
                $0.state = .failed
                $0.failure = OfflineFailure(.interrupted)
                $0.generation += 1
            }
            return
        }
        await submitMissing(asset.id, plan: plan)
    }

    // MARK: - The sheet

    /// Reads the stream once — master, one media playlist — and answers what each mode would
    /// download. Nothing is stored.
    public func options(for target: PlaybackTarget, preferredAudioLanguage: String? = nil,
                        preferredAudioName: String? = nil, preferredSubtitleLanguage: String? = nil,
                        allowHighFrameRate: Bool = false) async throws -> OfflineDownloadOptions {
        let sidecars = OfflineOptionsBuilder.sidecars(target.subtitles)
        let fetch = deps.fetcher(target.url, target.headers)
        switch try await probe(target.url, headers: target.headers, fetch: fetch) {
        case .progressive(let size, _):
            return OfflineOptionsBuilder.progressive(size: size, sidecars: sidecars,
                                                     preferredSubtitleLanguage: preferredSubtitleLanguage)
        case .playlist(let text, let base):
            switch try HLSPlaylist.parse(text, base: base) {
            case .media(let media):
                do { try OfflinePackageBuilder.validate([media]) } catch let error as OfflinePackageError {
                    return OfflineOptionsBuilder.refused(error.failure, compatibility: error == .drmProtected ? .avPlayerOnly : .bothEngines)
                }
                let variant = HLSVariant(uri: base, bandwidth: 0, averageBandwidth: nil, width: nil, height: nil, codecs: [],
                                         frameRate: nil, videoRange: nil, audioGroup: nil, subtitlesGroup: nil,
                                         closedCaptions: nil, attributes: [:])
                let master = HLSMasterPlaylist(version: nil, independentSegments: false, variants: [variant],
                                               renditions: [], sessionKeys: [])
                let options = OfflineOptionsBuilder.options(
                    master: master, duration: media.duration, sidecars: sidecars, allowHighFrameRate: allowHighFrameRate,
                    preferredAudioLanguage: preferredAudioLanguage, preferredAudioName: preferredAudioName,
                    preferredSubtitleLanguage: preferredSubtitleLanguage)
                return Self.withExactSize(options, media: media)
            case .master(let master):
                if master.sessionKeys.contains(where: \.isDRM) {
                    return OfflineOptionsBuilder.refused(OfflineFailure(.drmProtected), compatibility: .avPlayerOnly)
                }
                guard let smart = OfflineMediaSelector.chooseVideo(from: master, mode: .smart, allowHighFrameRate: allowHighFrameRate)
                    ?? OfflineMediaSelector.chooseVideo(from: master, mode: .saver) else {
                    return OfflineOptionsBuilder.refused(OfflineFailure(.unsupported, detail: "沒有 1080p 以下的版本"),
                                                         compatibility: .bothEngines)
                }
                let media = try await mediaPlaylist(smart.variant.uri, fetch: fetch, headers: target.headers, origin: target.url)
                do { try OfflinePackageBuilder.validate([media], sessionKeys: master.sessionKeys) } catch let error as OfflinePackageError {
                    return OfflineOptionsBuilder.refused(error.failure, compatibility: error == .drmProtected ? .avPlayerOnly : .bothEngines)
                }
                return OfflineOptionsBuilder.options(
                    master: master, duration: media.duration, sidecars: sidecars, allowHighFrameRate: allowHighFrameRate,
                    preferredAudioLanguage: preferredAudioLanguage, preferredAudioName: preferredAudioName,
                    preferredSubtitleLanguage: preferredSubtitleLanguage)
            }
        }
    }

    /// A media playlist whose segments all carry byte ranges knows its exact size.
    static func withExactSize(_ options: OfflineDownloadOptions, media: HLSMediaPlaylist) -> OfflineDownloadOptions {
        guard media.segments.allSatisfy({ $0.byteRange != nil }) else { return options }
        let bytes = media.segments.reduce(Int64(0)) { $0 + ($1.byteRange?.length ?? 0) }
        var modes = options.modes
        for (mode, option) in modes {
            modes[mode] = OfflineModeOption(video: option.video, variant: option.variant,
                                            estimate: OfflineSizeEstimate(bytes: bytes, basis: .exact),
                                            hdrOnly: option.hdrOnly, resolutionUnknown: option.resolutionUnknown,
                                            audio: option.audio, defaultAudioID: option.defaultAudioID,
                                            subtitles: option.subtitles, defaultSubtitleIDs: option.defaultSubtitleIDs)
        }
        return OfflineDownloadOptions(kind: options.kind, durationSeconds: options.durationSeconds, modes: modes,
                                      refusal: options.refusal, compatibility: options.compatibility)
    }

    // MARK: - Queue

    /// Queues one episode. An episode that already has a download — in any state — gets that one
    /// back instead of a second: a double tap, another quality, a refreshed signature or another
    /// engine never makes two.
    public func enqueue(identity: OfflineIdentity, title: OfflineTitleInfo, target: PlaybackTarget,
                        choice: OfflineDownloadChoice, estimate: OfflineSizeEstimate,
                        autoDeleteAfterWatching: Bool, allowsCellular: Bool) -> OfflineEnqueueResult {
        let sidecars = OfflineOptionsBuilder.sidecars(target.subtitles).filter { choice.subtitleIDs.contains($0.id) }
        let request = OfflineDownloadRequest(mediaURL: target.url, headers: target.headers, choice: choice, sidecars: sidecars)
        return queue(identity: identity, title: title, request: request, estimate: estimate,
                     autoDeleteAfterWatching: autoDeleteAfterWatching, allowsCellular: allowsCellular)
    }

    /// IOS-POC-49 全部下載: queues an episode nobody opened the sheet for. Its address is resolved
    /// when its turn comes — a long queue would otherwise outlive signed addresses — and preparing
    /// then picks what the sheet would have preselected for `mode`.
    public func enqueueAutomatic(identity: OfflineIdentity, title: OfflineTitleInfo, mode: OfflineQualityMode,
                                 allowHighFrameRate: Bool, preferredSubtitleLanguage: String?,
                                 autoDeleteAfterWatching: Bool, allowsCellular: Bool) -> OfflineEnqueueResult {
        // Never fetched: `needsFreshSource` replaces it before anything is read.
        let unresolved = URL(string: "about:blank")!
        let request = OfflineDownloadRequest(
            mediaURL: unresolved, headers: [:], choice: OfflineDownloadChoice(mode: mode, allowHighFrameRate: allowHighFrameRate),
            sidecars: [], needsFreshSource: true,
            automatic: OfflineAutomaticChoice(preferredSubtitleLanguage: preferredSubtitleLanguage))
        return queue(identity: identity, title: title, request: request, estimate: .unknown,
                     autoDeleteAfterWatching: autoDeleteAfterWatching, allowsCellular: allowsCellular)
    }

    private func queue(identity: OfflineIdentity, title: OfflineTitleInfo, request: OfflineDownloadRequest,
                       estimate: OfflineSizeEstimate, autoDeleteAfterWatching: Bool, allowsCellular: Bool) -> OfflineEnqueueResult {
        let choice = request.choice
        if let existing = store.asset(for: identity) { return .existing(existing) }
        guard OfflineStorage.hasRoom(estimate: estimate.bytes, available: deps.capacity()) else {
            OfflineLog.notice("[offline] refused: insufficient storage estimate=\(estimate.bytes ?? -1)")
            return .refused(OfflineFailure(.insufficientStorage))
        }
        var asset = OfflineAsset(identity: identity, title: title, mode: choice.mode,
                                 autoDeleteAfterWatching: autoDeleteAfterWatching, allowsCellular: allowsCellular,
                                 now: deps.now())
        asset.estimate = estimate
        do {
            try store.save(asset)
            try store.saveRequest(request, for: asset.id)
        } catch {
            _ = store.removeFolder(asset.id)
            return .refused(OfflineFailure(OfflineStorage.isOutOfSpace(error) ? .insufficientStorage : .unknown,
                                           detail: "無法建立下載"))
        }
        OfflineLog.notice("[offline] \(OfflineLog.short(asset.id)) queued mode=\(choice.mode.rawValue) estimate=\(estimate.bytes ?? -1) basis=\(estimate.basis.rawValue)")
        publish(force: true)
        Task { await self.pump() }
        return .created(asset)
    }

    /// IOS-POC-50: at most this many downloads prepare or download at once.
    public static let concurrentDownloads = 3

    /// Starts the oldest queued downloads while fewer than `concurrentDownloads` are running. Each
    /// is marked preparing before anything is awaited, so a pump that runs meanwhile counts it.
    func pump() async {
        guard started else { return }
        store.flushUnwritten()
        let all = store.all()
        let running = all.filter { $0.state == .preparing || $0.state == .downloading }.count
        let next = all.filter { $0.state == .queued }.sorted { $0.createdAt < $1.createdAt }
            .prefix(max(Self.concurrentDownloads - running, 0))
        let starting = next.compactMap { asset in
            store.update(asset.id, now: deps.now(), { $0.state = .preparing; $0.failure = nil })
        }
        guard !starting.isEmpty else { return }
        publish(force: true)
        await withTaskGroup(of: Void.self) { group in
            for asset in starting {
                group.addTask { await self.prepare(asset.id, generation: asset.generation) }
            }
        }
    }

    // MARK: - Preparing

    private enum Probe {
        case playlist(String, base: URL)
        case progressive(size: Int64?, ext: String)
    }

    /// Whether the address is a playlist or a file, and how big the file is. One small request:
    /// the first kilobyte, which is either `#EXTM3U` or media.
    private func probe(_ url: URL, headers: [String: String], fetch: OfflineFetch) async throws -> Probe {
        var request = URLRequest(url: url)
        for (name, value) in OfflineRequestPolicy.headers(headers, for: url, origin: url) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let looksLikePlaylist = url.pathExtension.lowercased() == "m3u8" || url.absoluteString.lowercased().contains(".m3u8")
        if !looksLikePlaylist { request.setValue("bytes=0-1023", forHTTPHeaderField: "Range") }
        let response = try await fetch(request, looksLikePlaylist ? OfflineHTTP.playlistLimit : OfflineHTTP.probeLimit)
        guard (200...299).contains(response.status) else { throw OfflineFetchError.http(response.status) }
        let head = String(decoding: response.data.prefix(16), as: UTF8.self)
        if head.hasPrefix("#EXTM3U") || head.hasPrefix("\u{FEFF}#EXTM3U") {
            var whole = response
            if !looksLikePlaylist && (response.status == 206 || response.truncated) {
                var full = URLRequest(url: url)
                for (name, value) in OfflineRequestPolicy.headers(headers, for: url, origin: url) {
                    full.setValue(value, forHTTPHeaderField: name)
                }
                whole = try await fetch(full, OfflineHTTP.playlistLimit)
            }
            guard !whole.truncated else { throw OfflineFetchError.notMedia }
            let text = String(decoding: whole.data, as: UTF8.self)
            return .playlist(text.replacingOccurrences(of: "\u{FEFF}", with: ""), base: response.url ?? url)
        }
        if OfflineStorage.looksLikeHTMLText(response.data) { throw OfflineFetchError.notMedia }
        let size: Int64?
        if let range = response.headers["content-range"], let total = range.split(separator: "/").last, let value = Int64(total) {
            size = value
        } else if response.status == 200, let length = response.headers["content-length"].flatMap({ Int64($0) }) {
            size = length
        } else {
            size = nil
        }
        return .progressive(size: size, ext: Self.fileExtension(url: response.url ?? url,
                                                                 contentType: response.headers["content-type"]))
    }

    static func fileExtension(url: URL, contentType: String?) -> String {
        let ext = url.pathExtension.lowercased()
        if ["mp4", "m4v", "mov", "mkv", "webm", "flv", "avi", "ts", "wmv", "rmvb", "3gp"].contains(ext) { return ext }
        switch contentType?.lowercased().split(separator: ";").first.map(String.init) ?? "" {
        case "video/x-matroska": return "mkv"
        case "video/webm": return "webm"
        case "video/quicktime": return "mov"
        case "video/x-flv": return "flv"
        case "video/mp2t": return "ts"
        default: return "mp4"
        }
    }

    // MARK: - Measured size (IOS-POC-51)

    /// The size a download with `choice` will have, read the way preparing reads it: for the sheet,
    /// so the number shown before 下載 is the one the space check then uses. Nothing is stored.
    public func sizeEstimate(for target: PlaybackTarget, choice: OfflineDownloadChoice) async -> OfflineSizeEstimate? {
        let request = OfflineDownloadRequest(mediaURL: target.url, headers: target.headers, choice: choice, sidecars: [])
        guard let estimate = try? await build(request).estimate, estimate.bytes != nil else { return nil }
        return estimate
    }

    /// How many segments of a playlist a measurement reads the size of.
    static let sampledSegments = 5

    /// The package's size from the real sizes of a few segments of each playlist it downloads, at
    /// the bytes per second they came to, over the whole duration. A source's BANDWIDTH can be far
    /// from what it serves: one declared under half. Nil when a playlist gave no sizes.
    private func sampledEstimate(video: HLSMediaPlaylist, audio: HLSMediaPlaylist?, fetch: @escaping OfflineFetch,
                                 headers: [String: String], origin: URL) async -> OfflineSizeEstimate? {
        guard video.duration > 0,
              let videoRate = await Self.sampledRate(video, fetch: fetch, headers: headers, origin: origin) else { return nil }
        var rate = videoRate
        if let audio {
            guard let audioRate = await Self.sampledRate(audio, fetch: fetch, headers: headers, origin: origin) else { return nil }
            rate += audioRate
        }
        return OfflineSizeEstimate.bytes(rate * video.duration).map { OfflineSizeEstimate(bytes: $0, basis: .sampled) }
    }

    /// Bytes per second of `media`, from the segments at the middle of `sampledSegments` equal
    /// stretches of it — not the first few, which are often the opening — read at the same time.
    static func sampledRate(_ media: HLSMediaPlaylist, fetch: @escaping OfflineFetch, headers: [String: String],
                            origin: URL) async -> Double? {
        let segments = media.segments.filter { $0.duration > 0 && !$0.isGap }
        guard !segments.isEmpty else { return nil }
        let count = min(sampledSegments, segments.count)
        let picks: [HLSSegment] = (0..<count).map { (slot: Int) -> HLSSegment in
            let middle: Int = (2 * slot + 1) * segments.count / (2 * count)
            return segments[middle]
        }
        let measured = await withTaskGroup(of: (bytes: Int64, seconds: Double)?.self) { group in
            for segment in picks {
                group.addTask {
                    guard let size = await segmentSize(segment, fetch: fetch, headers: headers, origin: origin) else { return nil }
                    return (size, segment.duration)
                }
            }
            return await group.reduce(into: [(bytes: Int64, seconds: Double)]()) { if let value = $1 { $0.append(value) } }
        }
        let bytes = measured.reduce(Int64(0)) { $0 + $1.bytes }
        let seconds = measured.reduce(0.0) { $0 + $1.seconds }
        guard bytes > 0, seconds > 0 else { return nil }
        return Double(bytes) / seconds
    }

    /// One segment's size: its byte range, or the total a one-byte request's Content-Range names —
    /// the segment itself is not downloaded. Headers follow the same per-host rule as the download.
    static func segmentSize(_ segment: HLSSegment, fetch: OfflineFetch, headers: [String: String], origin: URL) async -> Int64? {
        if let range = segment.byteRange { return range.length }
        var request = URLRequest(url: segment.uri)
        for (name, value) in OfflineRequestPolicy.headers(headers, for: segment.uri, origin: origin) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let response = try? await fetch(request, 1), (200...299).contains(response.status) else { return nil }
        if let range = response.headers["content-range"], let total = range.split(separator: "/").last, let value = Int64(total) {
            return value
        }
        if response.status == 200, let length = response.headers["content-length"].flatMap({ Int64($0) }) { return length }
        return nil
    }

    private func mediaPlaylist(_ url: URL, fetch: OfflineFetch, headers: [String: String], origin: URL) async throws -> HLSMediaPlaylist {
        var request = URLRequest(url: url)
        for (name, value) in OfflineRequestPolicy.headers(headers, for: url, origin: origin) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let response = try await fetch(request, OfflineHTTP.playlistLimit)
        guard (200...299).contains(response.status) else { throw OfflineFetchError.http(response.status) }
        guard !response.truncated,
              case .media(let media) = try HLSPlaylist.parse(String(decoding: response.data, as: UTF8.self),
                                                             base: response.url ?? url)
        else { throw OfflineFetchError.notMedia }
        return media
    }

    /// The package for a request: what to fetch, and what the record says about it.
    struct Prepared {
        var plan: OfflinePackagePlan
        var video: OfflineVideoInfo?
        var audio: OfflineAudioInfo?
        var subtitles: [OfflineSubtitleInfo]
        var estimate: OfflineSizeEstimate
        var duration: Double?
    }

    func build(_ request: OfflineDownloadRequest) async throws -> Prepared {
        let fetch = deps.fetcher(request.mediaURL, request.headers)
        switch try await probe(request.mediaURL, headers: request.headers, fetch: fetch) {
        case .progressive(let size, let ext):
            let unit = OfflineDownloadUnit(index: 0, remoteURL: request.mediaURL, byteRange: nil,
                                           relativePath: "media/video.\(ext)", role: .progressive)
            let plan = OfflinePackagePlan(units: [unit], playlists: [:], package: .progressive(relativePath: unit.relativePath),
                                          origin: request.mediaURL, headers: request.headers, sidecars: request.sidecars)
            return Prepared(plan: plan, video: nil, audio: nil, subtitles: [],
                            estimate: size.map { OfflineSizeEstimate(bytes: $0, basis: .exact) } ?? .unknown, duration: nil)
        case .playlist(let text, let base):
            switch try HLSPlaylist.parse(text, base: base) {
            case .media(let media):
                var plan = try OfflinePackageBuilder.build(
                    .init(master: nil, variant: nil, video: media, audio: nil, subtitles: []),
                    origin: request.mediaURL, headers: request.headers)
                plan.sidecars = request.sidecars
                let exact = media.segments.allSatisfy { $0.byteRange != nil }
                let estimate = exact
                    ? OfflineSizeEstimate(bytes: media.segments.reduce(0) { $0 + ($1.byteRange?.length ?? 0) }, basis: .exact)
                    : await sampledEstimate(video: media, audio: nil, fetch: fetch, headers: request.headers,
                                            origin: request.mediaURL) ?? .unknown
                return Prepared(plan: plan, video: nil, audio: nil, subtitles: [], estimate: estimate, duration: media.duration)
            case .master(let master):
                let choice = request.choice
                let variant = choice.variant.flatMap { key in master.variants.first(where: key.matches) }
                    ?? OfflineMediaSelector.chooseVideo(from: master, mode: choice.mode,
                                                        allowHighFrameRate: choice.allowHighFrameRate)?.variant
                guard let variant else { throw OfflinePackageError.empty }
                let video = try await mediaPlaylist(variant.uri, fetch: fetch, headers: request.headers, origin: request.mediaURL)
                let groupAudio = master.renditions(type: "AUDIO", group: variant.audioGroup)
                let wantedAudio = choice.audioID.flatMap { id in groupAudio.first { OfflineOptionsBuilder.audioID($0) == id } }
                    ?? OfflineMediaSelector.chooseAudio(groupAudio, preferredLanguage: nil, preferredName: nil, mode: choice.mode)
                var audio: OfflinePackageBuilder.Rendition?
                if let wantedAudio, let uri = wantedAudio.uri {
                    audio = .init(rendition: wantedAudio,
                                  playlist: try await mediaPlaylist(uri, fetch: fetch, headers: request.headers, origin: request.mediaURL))
                }
                var subtitles = [OfflinePackageBuilder.Rendition]()
                for rendition in OfflineMediaSelector.subtitleOptions(for: variant, in: master)
                where choice.subtitleIDs.contains(OfflineOptionsBuilder.subtitleID(rendition)) {
                    guard let uri = rendition.uri else { continue }
                    subtitles.append(.init(rendition: rendition,
                                           playlist: try await mediaPlaylist(uri, fetch: fetch, headers: request.headers,
                                                                             origin: request.mediaURL)))
                }
                var plan = try OfflinePackageBuilder.build(
                    .init(master: master, variant: variant, video: video, audio: audio, subtitles: subtitles),
                    origin: request.mediaURL, headers: request.headers)
                plan.sidecars = request.sidecars
                let subtitleInfo = subtitles.enumerated().map { index, item in
                    OfflineSubtitleInfo(id: OfflineOptionsBuilder.subtitleID(item.rendition), name: item.rendition.name,
                                        language: item.rendition.language, kind: .hlsRendition,
                                        relativePath: "playlists/sub-\(index + 1).m3u8")
                }
                return Prepared(plan: plan, video: variant.info,
                                audio: wantedAudio.map { OfflineOptionsBuilder.audioOption($0).info },
                                subtitles: subtitleInfo,
                                estimate: await sampledEstimate(video: video, audio: audio?.playlist, fetch: fetch,
                                                                headers: request.headers, origin: request.mediaURL)
                                    ?? OfflineMediaSelector.estimate(variant, duration: video.duration),
                                duration: video.duration)
            }
        }
    }

    private func prepare(_ id: String, generation: Int) async {
        guard let asset = store.asset(id) else { return }
        // IOS-POC-52 (F6): a download whose request is gone — a completed one whose files went
        // missing, or one interrupted between completing and cleaning up — starts over from the
        // episode, as 全部下載 does, in the mode it was downloaded in.
        var request = store.request(for: id) ?? OfflineDownloadRequest(
            mediaURL: URL(string: "about:blank")!, headers: [:],
            choice: OfflineDownloadChoice(mode: asset.mode, allowHighFrameRate: (asset.video?.frameRate ?? 0) > 31),
            sidecars: [], needsFreshSource: true,
            automatic: OfflineAutomaticChoice(preferredSubtitleLanguage: asset.subtitles.first?.language))
        let reResolved = request.needsFreshSource
        if request.needsFreshSource {
            guard let resolver, let target = await resolver(asset) else {
                // IOS-POC-52 (F26): an abandoned resolution must not fail a newer attempt or a pause.
                guard isCurrent(id, generation, .preparing) else { return }
                fail(id, OfflineFailure(.expiredSource, detail: "無法重新取得來源"))
                return
            }
            guard isCurrent(id, generation, .preparing) else { return }
            request.mediaURL = target.url
            request.headers = target.headers
            // IOS-POC-52 (F20): the chosen subtitle files at their fresh addresses.
            let fresh = OfflineOptionsBuilder.sidecars(target.subtitles)
            request.sidecars = request.sidecars.map { chosen in
                fresh.first { $0.name == chosen.name && $0.language == chosen.language }
                    .map { OfflineSidecarRequest(id: chosen.id, url: $0.url, name: chosen.name, language: chosen.language,
                                                 format: $0.format) } ?? chosen
            }
            if let automatic = request.automatic {
                // The sheet's own reading of the stream and its preselection, so 全部下載 makes
                // the package a 下載 with the sheet untouched would have made.
                let options: OfflineDownloadOptions
                do {
                    options = try await self.options(for: target,
                                                     preferredSubtitleLanguage: automatic.preferredSubtitleLanguage,
                                                     allowHighFrameRate: request.choice.allowHighFrameRate)
                } catch {
                    guard isCurrent(id, generation, .preparing) else { return }
                    fail(id, Self.failure(for: error))
                    return
                }
                guard isCurrent(id, generation, .preparing) else { return }
                if let refusal = options.refusal {
                    fail(id, refusal)
                    return
                }
                guard let option = options.option(for: request.choice.mode) ?? options.option(for: .smart)
                        ?? options.modes.values.first else {
                    fail(id, OfflinePackageError.empty.failure)
                    return
                }
                request.choice = OfflineDownloadChoice(mode: request.choice.mode,
                                                       allowHighFrameRate: request.choice.allowHighFrameRate,
                                                       variant: option.variant, audioID: option.defaultAudioID,
                                                       subtitleIDs: option.defaultSubtitleIDs)
                request.sidecars = OfflineOptionsBuilder.sidecars(target.subtitles)
                    .filter { request.choice.subtitleIDs.contains($0.id) }
                request.automatic = nil
            }
            request.needsFreshSource = false
            try? store.saveRequest(request, for: id)
        }

        let previous = loadPlan(id)
        let prepared: Prepared
        do {
            prepared = try await build(request)
        } catch {
            guard isCurrent(id, generation, .preparing) else { return }
            fail(id, Self.failure(for: error))
            return
        }
        guard isCurrent(id, generation, .preparing) else { return }

        // Files already here are kept only when the new plan names the same files for the same
        // timeline; otherwise the package starts over rather than mixing two copies. With no
        // readable earlier plan nothing says what the files are, so they go too (IOS-POC-52 F16).
        if previous.map({ !$0.sameTimeline(as: prepared.plan) }) ?? true {
            await discardResumeFiles(id)
            for folder in ["media", "audio", "subtitles", "keys", "playlists", "partial"] {
                try? FileManager.default.removeItem(at: layout.folder(for: id).appendingPathComponent(folder))
            }
            if previous != nil {
                OfflineLog.notice("[offline] \(OfflineLog.short(id)) timeline changed: partial files discarded")
            }
        } else if reResolved || previous?.origin != prepared.plan.origin || previous?.headers != prepared.plan.headers {
            // IOS-POC-52 (F17): resume data replays the request it came from — the old address and
            // its Cookie. A new address or new headers start the single file over.
            await discardResumeFiles(id)
        }
        // IOS-POC-52 (F2): no room is found out before anything more is written.
        guard hasRoom(for: prepared.estimate, id: id) else {
            fail(id, OfflineFailure(.insufficientStorage))
            return
        }
        do {
            try store.savePlan(prepared.plan, for: id)
        } catch {
            fail(id, OfflineFailure(OfflineStorage.isOutOfSpace(error) ? .insufficientStorage : .unknown))
            return
        }
        plans[id] = prepared.plan

        let sidecars = await downloadSidecars(prepared.plan, id: id)
        guard isCurrent(id, generation, .preparing) else {
            // IOS-POC-52 (F39): deleted while a subtitle was on its way — saving it made the
            // folder again, with no record to delete it by.
            if store.asset(id) == nil { store.removeFolder(id) }
            return
        }

        // Checked again with nothing awaited between it and `downloading`, so two downloads
        // preparing at once cannot both count the same free space.
        guard hasRoom(for: prepared.estimate, id: id) else {
            fail(id, OfflineFailure(.insufficientStorage))
            return
        }
        guard let updated = store.update(id, now: deps.now(), {
            $0.video = prepared.video
            $0.audio = prepared.audio
            $0.subtitles = prepared.subtitles + sidecars
            $0.package = prepared.plan.package
            if prepared.estimate.bytes != nil { $0.estimate = prepared.estimate }
            $0.durationSeconds = prepared.duration
            $0.progress = OfflineProgress(completedUnits: 0, totalUnits: prepared.plan.units.count)
            $0.state = .downloading
        }) else { return }
        OfflineLog.notice("[offline] \(OfflineLog.short(id)) downloading units=\(prepared.plan.units.count) video=\(prepared.video?.summary ?? "file") estimate=\(prepared.estimate.bytes ?? -1)")
        publish(force: true)
        await submitMissing(updated.id, plan: prepared.plan)
    }

    /// Whether the rest of this download fits beside what the running ones still need
    /// (IOS-POC-50).
    private func hasRoom(for estimate: OfflineSizeEstimate, id: String) -> Bool {
        let downloaded = OfflineStorage.allocatedSize(of: layout.folder(for: id))
        let remaining = estimate.bytes.map { max($0 - downloaded, 0) }
        return OfflineStorage.hasRoom(estimate: (remaining ?? 0) + reservedBytes(excluding: id), available: deps.capacity())
    }

    /// What the other running downloads still need by their estimates, so two of them cannot each
    /// find room for themselves in the same free space (IOS-POC-50).
    private func reservedBytes(excluding id: String) -> Int64 {
        store.all().filter { $0.id != id && $0.state == .downloading }.reduce(0) { total, asset in
            // IOS-POC-51: what has arrived so far projects the size better than the estimate.
            guard let bytes = asset.progress.projectedBytes ?? asset.estimate.bytes else { return total }
            return total + max(bytes - OfflineStorage.allocatedSize(of: layout.folder(for: asset.id)), 0)
        }
    }

    /// The source's own subtitle files, kept as UTF-8 SubRip beside the media. A file that fails is
    /// left out (and logged); the video still downloads.
    private func downloadSidecars(_ plan: OfflinePackagePlan, id: String) async -> [OfflineSubtitleInfo] {
        guard !plan.sidecars.isEmpty else { return [] }
        let folder = layout.folder(for: id)
        // IOS-POC-52 (F20): a subtitle an earlier attempt already saved is kept, not fetched again,
        // so an address that has expired since cannot take it out of the download.
        let saved = (store.asset(id)?.subtitles ?? []).filter {
            $0.kind == .sidecar && !$0.relativePath.isEmpty
                && FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.relativePath).path)
        }
        let cache = SubtitleSessionCache(root: folder.appendingPathComponent("subtitles", isDirectory: true),
                                         id: UUID(uuidString: "00000000-0000-0000-0000-000000000047") ?? UUID())
        let provider = SourceSubtitleProvider(headers: plan.headers, mediaURL: plan.origin)
        var kept = [OfflineSubtitleInfo]()
        for sidecar in plan.sidecars {
            if let earlier = saved.first(where: { $0.id == sidecar.id }) {
                kept.append(earlier)
                continue
            }
            let source = SourceSubtitle(url: sidecar.url.absoluteString, name: sidecar.name,
                                        language: sidecar.language ?? "", format: sidecar.format)
            let track = SourceSubtitles.track(for: source, url: sidecar.url)
            do {
                let file = try await deps.subtitles.download(
                    track, from: provider, into: cache, label: sidecar.name,
                    decodingLanguage: track.language.code == nil ? SubtitleLanguage(code: "zh") : nil)
                let path = String(file.fileURL.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
                kept.append(OfflineSubtitleInfo(id: sidecar.id, name: sidecar.name, language: sidecar.language ?? track.language.code,
                                                kind: .sidecar, relativePath: path))
            } catch {
                OfflineLog.notice("[offline] \(OfflineLog.short(id)) sidecar subtitle failed=\(SubtitleProviderError.classify(error).category)")
            }
        }
        return kept
    }

    /// What an error in preparing (or in reading a stream for the sheet) means for the viewer.
    public static func failure(for error: Error) -> OfflineFailure {
        if let error = error as? OfflinePackageError { return error.failure }
        if let error = error as? OfflineFetchError {
            switch error {
            case .http(let status): return OfflineFailure.forHTTP(status)
            case .notMedia: return OfflineFailure(.expiredSource, detail: "來源回傳的不是影片")
            }
        }
        if error is HLSPlaylist.ParseError { return OfflineFailure(.unsupported, detail: "無法讀取播放清單") }
        if OfflineStorage.isOutOfSpace(error) { return OfflineFailure(.insufficientStorage) }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return OfflineFailure(.network, detail: "NSURLError \(nsError.code)") }
        return OfflineFailure(.unknown, detail: nsError.domain)
    }

    // MARK: - Transfers

    private func loadPlan(_ id: String) -> OfflinePackagePlan? {
        if let plan = plans[id] { return plan }
        let plan = store.plan(for: id)
        plans[id] = plan
        return plan
    }

    private func finalURL(_ id: String, _ unit: OfflineDownloadUnit) -> URL {
        layout.folder(for: id).appendingPathComponent(unit.relativePath)
    }

    private func isCurrent(_ id: String, _ generation: Int, _ state: OfflineAssetState) -> Bool {
        guard let asset = store.asset(id) else { return false }
        return asset.generation == generation && asset.state == state
    }

    /// Sends every unit not yet on disk and not already in flight. The files on disk are the truth:
    /// a unit is done when its final file is there, which survives any crash.
    private func submitMissing(_ id: String, plan: OfflinePackagePlan) async {
        guard let asset = store.asset(id), asset.state == .downloading else { return }
        let generation = asset.generation
        let manager = FileManager.default
        var finished = Set<Int>()
        var unitSizes = [Int: Int64]()
        var bytes: Int64 = 0
        for unit in plan.units {
            let file = finalURL(id, unit)
            if let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value, size > 0 {
                finished.insert(unit.index)
                unitSizes[unit.index] = size
                bytes += size
            }
        }
        done[id] = finished
        sizes[id] = unitSizes
        store.updateInMemory(id) {
            $0.progress.completedUnits = finished.count
            $0.progress.totalUnits = plan.units.count
            $0.progress.receivedBytes = bytes
            $0.progress.projectedBytes = plan.projectedBytes(finished: unitSizes)
        }
        let active = await deps.transport.activeTags()
        guard isCurrent(id, generation, .downloading) else { return }
        let inFlight = Set(active.filter { $0.assetID == id && $0.generation == generation }.map(\.unit))
        let missing = plan.units.filter { !finished.contains($0.index) && !inFlight.contains($0.index) }
        if missing.isEmpty && inFlight.isEmpty {
            await finalize(id, generation: generation)
            return
        }
        // IOS-POC-52 (F10): credentialed units go through a window; the rest wait their turn.
        let credentialed = missing.filter { isCredentialed($0, plan: plan) }
        let flying = inFlight.filter { plan.units.indices.contains($0) && isCredentialed(plan.units[$0], plan: plan) }
        let room = max(Self.credentialedWindow - flying.count, 0)
        let held = Array(credentialed.dropFirst(room))
        let heldIndices = Set(held.map(\.index))
        waitingCredentialed[id] = held
        credentialedInFlight[id] = flying.union(credentialed.prefix(room).map(\.index))
        let requests = missing.filter { !heldIndices.contains($0.index) }.map { request(for: $0, asset: asset, plan: plan) }
        if !requests.isEmpty {
            OfflineLog.notice("[offline] \(OfflineLog.short(id)) submit=\(requests.count) held=\(held.count) done=\(finished.count)/\(plan.units.count) inflight=\(inFlight.count)")
            await deps.transport.submit(requests)
            await cancelIfStale(requests.map(\.tag), id: id, generation: generation)
        }
        publish(force: true)
    }

    /// IOS-POC-52 (F3): a pause, a delete or a failure that landed while a submit was running leaves
    /// what the submit created after it; those transfers stop now.
    private func cancelIfStale(_ tags: [OfflineTransferTag], id: String, generation: Int) async {
        guard !isCurrent(id, generation, .downloading) else { return }
        await deps.transport.cancel(tags: Set(tags))
    }

    private func isCredentialed(_ unit: OfflineDownloadUnit, plan: OfflinePackagePlan) -> Bool {
        OfflineRequestPolicy.isCredentialed(OfflineRequestPolicy.headers(plan.headers, for: unit.remoteURL, origin: plan.origin))
    }

    /// A credentialed unit is done (or gone): the next one waiting takes its place in the window.
    private func feedCredentialed(_ id: String, after unit: Int) async {
        guard credentialedInFlight[id]?.remove(unit) != nil, var waiting = waitingCredentialed[id], !waiting.isEmpty,
              let asset = store.asset(id), asset.state == .downloading, let plan = loadPlan(id) else { return }
        let next = waiting.removeFirst()
        waitingCredentialed[id] = waiting
        credentialedInFlight[id, default: []].insert(next.index)
        let generation = asset.generation
        await deps.transport.submit([request(for: next, asset: asset, plan: plan)])
        await cancelIfStale([OfflineTransferTag(assetID: id, generation: generation, unit: next.index)], id: id, generation: generation)
    }

    private func request(for unit: OfflineDownloadUnit, asset: OfflineAsset, plan: OfflinePackagePlan) -> OfflineTransferRequest {
        let headers = OfflineRequestPolicy.headers(plan.headers, for: unit.remoteURL, origin: plan.origin)
        let resume = unit.role == .progressive
            ? try? Data(contentsOf: layout.resumeDataFile(for: asset.id, unit: unit.index)) : nil
        return OfflineTransferRequest(
            tag: OfflineTransferTag(assetID: asset.id, generation: asset.generation, unit: unit.index),
            url: unit.remoteURL, headers: headers, byteRange: unit.byteRange, allowsCellular: asset.allowsCellular,
            credentialed: OfflineRequestPolicy.isCredentialed(headers), origin: plan.origin, resumeData: resume,
            reportsProgress: unit.role == .progressive)
    }

    /// The transport's report. Anything for an asset that is gone, not downloading, or of an older
    /// generation is dropped — and its file deleted — so it can change nothing.
    public func handle(_ tag: OfflineTransferTag, _ event: OfflineTransferEvent) async {
        guard let asset = store.asset(tag.assetID), asset.generation == tag.generation, asset.state == .downloading,
              let plan = loadPlan(tag.assetID), plan.units.indices.contains(tag.unit) else {
            if case .finished(let file, _) = event { try? FileManager.default.removeItem(at: file) }
            return
        }
        let unit = plan.units[tag.unit]
        switch event {
        case .progress(let written, let expected):
            guard unit.role == .progressive else { return }
            store.updateInMemory(asset.id) {
                $0.progress.receivedBytes = written
                $0.progress.expectedBytes = expected ?? $0.estimate.bytes
            }
            // IOS-POC-52 (F14): a single file is one unit, so the check after each unit would come
            // only once it is all here. Its space is checked as it arrives — and against the rest of
            // it once the server has said how big it is.
            if let free = deps.capacity() {
                let rest = expected.map { max($0 - written, 0) }
                if free < OfflineStorage.minimumFreeWhileDownloading
                    || rest.map({ !OfflineStorage.hasRoom(estimate: $0, available: free) }) == true {
                    fail(asset.id, OfflineFailure(.insufficientStorage))
                    return
                }
            }
            publish(force: false)
        case .finished(let file, let status):
            await accept(file, status: status, unit: unit, tag: tag)
        case .failed(let failure):
            await transferFailed(tag, unit: unit, failure: failure)
        }
    }

    private func accept(_ file: URL, status: Int, unit: OfflineDownloadUnit, tag: OfflineTransferTag) async {
        let manager = FileManager.default
        defer { try? manager.removeItem(at: file) }
        guard (200...299).contains(status) else {
            await transferFailed(tag, unit: unit, failure: OfflineTransferFailure(.http(status)))
            return
        }
        guard manager.fileExists(atPath: file.path) else { return }
        var body = file
        if let range = unit.byteRange, status == 200 {
            // The server ignored Range and sent the whole resource: cut the part this unit is.
            guard let sliced = Self.slice(file, range: range) else {
                await transferFailed(tag, unit: unit, failure: OfflineTransferFailure(.network("short body")))
                return
            }
            body = sliced
        }
        let size = (try? manager.attributesOfItem(atPath: body.path)[.size] as? NSNumber)?.int64Value ?? 0
        if unit.role == .key && size != OfflinePackageVerifier.keyBytes {
            // IOS-POC-52 (F7): an AES-128 key is 16 bytes. Anything else is how a key server
            // refuses an expired token or a missing Referer, and a package that cannot decrypt
            // must never be called complete.
            if body != file { try? manager.removeItem(at: body) }
            fail(tag.assetID, OfflineFailure(.expiredSource, detail: "金鑰無效"))
            return
        }
        let wrongSize = unit.byteRange.map { size != $0.length } ?? (size == 0)
        if wrongSize || (unit.role != .key && unit.role != .subtitleSegment && OfflineStorage.looksLikeHTML(body)) {
            if body != file { try? manager.removeItem(at: body) }
            // An HTML page where media should be is how a CDN refuses an expired address.
            fail(tag.assetID, wrongSize ? OfflineFailure(.integrity, detail: "片段大小不符")
                                        : OfflineFailure(.expiredSource, detail: "來源回傳網頁"))
            return
        }
        do {
            try OfflineStorage.moveIntoPlace(body, to: finalURL(tag.assetID, unit))
        } catch {
            if body != file { try? manager.removeItem(at: body) }
            fail(tag.assetID, OfflineFailure(OfflineStorage.isOutOfSpace(error) ? .insufficientStorage : .unknown,
                                             detail: "無法寫入"))
            return
        }
        if unit.role == .progressive {
            try? manager.removeItem(at: layout.resumeDataFile(for: tag.assetID, unit: unit.index))
        }
        attempts[tag] = nil
        var finished = done[tag.assetID] ?? []
        finished.insert(unit.index)
        done[tag.assetID] = finished
        var unitSizes = sizes[tag.assetID] ?? [:]
        unitSizes[unit.index] = size
        sizes[tag.assetID] = unitSizes
        let projected = loadPlan(tag.assetID)?.projectedBytes(finished: unitSizes)
        store.updateInMemory(tag.assetID) {
            $0.progress.completedUnits = finished.count
            if unit.role == .progressive { $0.progress.receivedBytes = size } else { $0.progress.receivedBytes += size }
            $0.progress.projectedBytes = projected
        }
        await feedCredentialed(tag.assetID, after: unit.index)
        unitsSinceFlush += 1
        if unitsSinceFlush >= 25 {
            unitsSinceFlush = 0
            store.flush(tag.assetID)
        }
        // The disk filling up stops the download cleanly, with everything so far kept.
        if let free = deps.capacity(), free < OfflineStorage.minimumFreeWhileDownloading {
            fail(tag.assetID, OfflineFailure(.insufficientStorage))
            return
        }
        guard let plan = loadPlan(tag.assetID) else { return }
        if finished.count >= plan.units.count {
            await finalize(tag.assetID, generation: tag.generation)
        } else {
            publish(force: false)
        }
    }

    static func slice(_ file: URL, range: HLSByteRange) -> URL? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(range.offset))
            guard let data = try handle.read(upToCount: Int(range.length)), data.count == Int(range.length) else { return nil }
            let target = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".slice")
            try data.write(to: target)
            return target
        } catch {
            return nil
        }
    }

    private func transferFailed(_ tag: OfflineTransferTag, unit: OfflineDownloadUnit, failure: OfflineTransferFailure) async {
        if unit.role == .progressive {
            if let data = failure.resumeData {
                saveResumeData(data, assetID: tag.assetID, unit: unit.index)
            } else {
                // IOS-POC-52 (F19): a transfer that ended without new resume data leaves the old one
                // stale — its partial file purged, or the server's validator changed. Sent again,
                // it would fail the same way for ever; the next attempt starts over.
                await discardResumeFiles(tag.assetID)
            }
        }
        switch failure.kind {
        case .noSpace:
            fail(tag.assetID, OfflineFailure(.insufficientStorage))
            return
        case .http(let status) where [401, 403, 404, 410].contains(status):
            fail(tag.assetID, OfflineFailure.forHTTP(status))
            return
        case .cancelled:
            // IOS-POC-52 (F4): only the system cancels a current transfer — a force quit. The
            // relaunch's submitMissing sends it again; retrying here too fetched every remaining
            // unit twice.
            return
        case .http, .network, .connectivity:
            break
        }
        let count = (attempts[tag] ?? 0) + 1
        attempts[tag] = count
        let budget: Int
        if case .connectivity = failure.kind { budget = Self.connectivityRetries } else { budget = Self.transferRetries }
        guard count <= budget else {
            attempts[tag] = nil
            switch failure.kind {
            case .http(let status): fail(tag.assetID, OfflineFailure.forHTTP(status))
            case .network(let detail), .connectivity(let detail): fail(tag.assetID, OfflineFailure(.network, detail: detail))
            default: fail(tag.assetID, OfflineFailure(.network))
            }
            return
        }
        try? await Task.sleep(for: deps.retryDelay)
        guard let asset = store.asset(tag.assetID), asset.generation == tag.generation, asset.state == .downloading,
              let plan = loadPlan(tag.assetID) else { return }
        // IOS-POC-52 (F4): not when the unit is already here or already on its way again.
        if done[tag.assetID]?.contains(unit.index) == true { return }
        if await deps.transport.activeTags().contains(tag) { return }
        OfflineLog.notice("[offline] \(OfflineLog.short(tag.assetID)) retry unit=\(unit.index) attempt=\(count)")
        await deps.transport.submit([request(for: unit, asset: asset, plan: plan)])
        await cancelIfStale([tag], id: tag.assetID, generation: tag.generation)
    }

    /// IOS-POC-52 (F18): saved resume data goes with the partial file the system keeps for it.
    private func discardResumeFiles(_ id: String) async {
        let partial = layout.folder(for: id).appendingPathComponent("partial")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: partial.path)) ?? []
        for name in names where name.hasSuffix(".resume") {
            let file = partial.appendingPathComponent(name)
            if let data = try? Data(contentsOf: file) { await deps.transport.discardResumeData(data) }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func saveResumeData(_ data: Data, assetID: String, unit: Int) {
        let file = layout.resumeDataFile(for: assetID, unit: unit)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? OfflineStorage.writeAtomically(data, to: file)
    }

    /// Writes the playlists, checks the package, and only then calls it complete.
    private func finalize(_ id: String, generation: Int) async {
        guard isCurrent(id, generation, .downloading), let plan = loadPlan(id) else { return }
        let folder = layout.folder(for: id)
        do {
            for (path, text) in plan.playlists {
                let file = folder.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try OfflineStorage.writeAtomically(Data(text.utf8), to: file)
            }
        } catch {
            fail(id, OfflineFailure(OfflineStorage.isOutOfSpace(error) ? .insufficientStorage : .unknown))
            return
        }
        let problems = OfflinePackageVerifier.problems(plan: plan, root: folder)
        guard problems.isEmpty else {
            // A unit of the wrong size goes, so a retry fetches it again.
            for unit in plan.units {
                if let range = unit.byteRange,
                   let size = (try? FileManager.default.attributesOfItem(atPath: finalURL(id, unit).path)[.size] as? NSNumber)?.int64Value,
                   size != range.length {
                    try? FileManager.default.removeItem(at: finalURL(id, unit))
                }
            }
            OfflineLog.notice("[offline] \(OfflineLog.short(id)) verification failed problems=\(problems.count)")
            fail(id, OfflineFailure(.integrity, detail: "缺少 \(problems.count) 個檔案"))
            return
        }
        // IOS-POC-52 (F5): completed is written first. A kill between this and the cleanup
        // below leaves a playable package with leftover addresses, never a finished download
        // with no plan and no request that no retry can recover.
        _ = store.update(id, now: deps.now()) {
            $0.state = .completed
            $0.failure = nil
            $0.actualBytes = store.size(of: id)
            $0.progress.completedUnits = plan.units.count
            $0.progress.totalUnits = plan.units.count
        }
        store.removeDownloadSecrets(for: id)
        plans[id] = nil
        done[id] = nil
        sizes[id] = nil
        removeStaging(for: id)
        let actual = store.size(of: id)
        _ = store.update(id, now: deps.now()) { $0.actualBytes = actual }
        OfflineLog.notice("[offline] \(OfflineLog.short(id)) completed bytes=\(actual) units=\(plan.units.count)")
        forgetWindow(id)
        publish(force: true)
        // IOS-POC-52 (F11): not awaited — the next download's preparing must not hold up the
        // events of the others, nor the end of a background wake.
        Task { await self.pump() }
    }

    private func forgetWindow(_ id: String) {
        waitingCredentialed[id] = nil
        credentialedInFlight[id] = nil
    }

    private func removeStaging(for id: String) {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: layout.stagingDirectory.path)) ?? [] where name.hasPrefix(id + "|") {
            try? manager.removeItem(at: layout.stagingDirectory.appendingPathComponent(name))
        }
    }

    // MARK: - Pause, resume, retry, fail

    /// Stops a download where it is. A progressive file keeps what it received as resume data.
    public func pause(_ id: String) async {
        guard let asset = store.asset(id), asset.state.isActive,
              let paused = store.update(id, now: deps.now(), { $0.state = .paused; $0.generation += 1 })
        else { return }
        OfflineLog.notice("[offline] \(OfflineLog.short(id)) paused")
        forgetWindow(id)
        publish(force: true)
        await cancelTransfers(id, previousGeneration: paused.generation - 1)
        await pump()
    }

    /// 繼續 for a paused download, 重新下載／繼續 for a failed one: back in the queue, keeping every
    /// file already here. When the addresses had stopped working, preparing resolves the episode
    /// again first.
    public func resume(_ id: String) async {
        guard let asset = store.asset(id), asset.state == .paused || asset.state == .failed else { return }
        if var request = store.request(for: id), asset.failure?.kind == .expiredSource {
            request.needsFreshSource = true
            try? store.saveRequest(request, for: id)
        }
        guard (store.update(id, now: deps.now(), {
            $0.state = .queued
            $0.failure = nil
            $0.generation += 1
        })) != nil else { return }
        OfflineLog.notice("[offline] \(OfflineLog.short(id)) resumed")
        publish(force: true)
        await pump()
    }

    /// A failed download keeps its partial files, so 重新下載／繼續 can use them and 刪除下載 can
    /// free them. It is never hidden or deleted by itself.
    private func fail(_ id: String, _ failure: OfflineFailure) {
        guard let asset = store.asset(id), asset.state != .completed, asset.state != .deleting,
              let failed = store.update(id, now: deps.now(), {
                  $0.state = .failed
                  $0.failure = failure
                  $0.generation += 1
              }) else { return }
        OfflineLog.notice("[offline] \(OfflineLog.short(id)) failed kind=\(failure.kind.rawValue) status=\(failure.httpStatus ?? 0) done=\(failed.progress.completedUnits)/\(failed.progress.totalUnits)")
        forgetWindow(id)
        publish(force: true)
        let previous = failed.generation - 1
        Task {
            await self.cancelTransfers(id, previousGeneration: previous)
            await self.pump()
        }
    }

    /// IOS-POC-49: 允許使用行動網路下載 for every download not finished yet, not only the ones
    /// queued after the change. A request's cellular rule is fixed when it is made — and resume data
    /// carries the request it came from — so a running download sends its unfinished pieces again
    /// under the new rule, and a single file's resume data is dropped: it starts over rather than
    /// keep the old rule.
    public func setAllowsCellular(_ allowed: Bool) async {
        for asset in store.all() where asset.state != .completed && asset.state != .deleting && asset.allowsCellular != allowed {
            let running = asset.state == .downloading
            guard (store.update(asset.id, now: deps.now(), {
                $0.allowsCellular = allowed
                if running { $0.generation += 1 }
            })) != nil else { continue }
            OfflineLog.notice("[offline] \(OfflineLog.short(asset.id)) cellular=\(allowed) state=\(asset.state.rawValue)")
            if running { _ = await deps.transport.cancel(assetID: asset.id, producingResumeData: false) }
            await discardResumeFiles(asset.id)
            if running, let current = store.asset(asset.id), current.state == .downloading, let plan = loadPlan(asset.id) {
                await submitMissing(current.id, plan: plan)
            }
        }
        publish(force: true)
    }

    private func cancelTransfers(_ id: String, previousGeneration: Int) async {
        // IOS-POC-52 (F18): only a single file is worth resuming; a segment's resume data would
        // only leave its partial file behind.
        let progressive = loadPlan(id)?.units.contains { $0.role == .progressive } ?? false
        let resume = await deps.transport.cancel(assetID: id, producingResumeData: progressive)
        guard store.asset(id) != nil else { return }
        for (tag, data) in resume where tag.generation == previousGeneration {
            if let plan = loadPlan(id), plan.units.indices.contains(tag.unit), plan.units[tag.unit].role == .progressive {
                saveResumeData(data, assetID: id, unit: tag.unit)
            }
        }
    }

    // MARK: - Delete (the one way)

    /// Deletes downloads in any state — queued, preparing, downloading, paused, failed, completed —
    /// or an unreadable folder. Cancels their transfers first, then removes each whole folder.
    @discardableResult
    public func delete(_ ids: [String]) async -> OfflineDeletionResult {
        await deleteNow(ids, reason: "viewer")
    }

    private func deleteNow(_ ids: [String], reason: String) async -> OfflineDeletionResult {
        var result = OfflineDeletionResult(deleted: 0, releasedBytes: 0)
        for id in Set(ids) {
            if store.asset(id) != nil {
                // Recorded first, so a crash mid-delete is finished at the next launch.
                _ = store.update(id, now: deps.now()) {
                    $0.state = .deleting
                    $0.generation += 1
                }
            } else if store.unreadable[id] == nil {
                continue
            }
            publish(force: true)
            _ = await deps.transport.cancel(assetID: id, producingResumeData: false)
            await discardResumeFiles(id)
            forgetWindow(id)
            plans[id] = nil
            done[id] = nil
            sizes[id] = nil
            removeStaging(for: id)
            let released = store.removeFolder(id)
            if store.asset(id) == nil && store.unreadable[id] == nil {
                result.deleted += 1
                result.releasedBytes += released
            }
            OfflineLog.notice("[offline] \(OfflineLog.short(id)) deleted reason=\(reason) released=\(released)")
        }
        measureUnreadable()
        publish(force: true)
        await pump()
        return result
    }

    // MARK: - Watched, and the auto-delete

    /// The episode really finished — the engine's end of file, or the formal auto-next
    /// (`OfflineCompletionPolicy`). Records it, and arms the auto-delete when it is on. Nothing is
    /// deleted here: the player may still hold the file.
    public func playbackEnded(_ id: String) {
        let arms = autoDeleteEnabled
        guard let asset = store.asset(id), asset.state == .completed,
              (store.update(id, now: deps.now(), {
                  $0.watched = true
                  if $0.autoDeleteAfterWatching && arms { $0.pendingAutoDelete = true }
              })) != nil else { return }
        OfflineLog.notice("[offline] \(OfflineLog.short(id)) watched autoDelete=\(asset.autoDeleteAfterWatching && arms ? "armed" : "off")")
        publish(force: true)
    }

    /// The player let go of the asset. Answers whether the armed auto-delete ran.
    @discardableResult
    public func playbackReleased(_ id: String) async -> Bool {
        guard autoDeleteEnabled, let asset = store.asset(id), asset.pendingAutoDelete, asset.autoDeleteAfterWatching
        else { return false }
        return await deleteNow([id], reason: "watched").deleted == 1
    }

    /// IOS-POC-52 (F13): the setting applies to every download, not only to the ones made after it
    /// changed. Turned off, the armed auto-deletes are disarmed; turned on, each download follows
    /// its own choice again.
    public func setAutoDeleteEnabled(_ enabled: Bool) {
        autoDeleteEnabled = enabled
        guard !enabled else { return }
        disarmAutoDeletes()
        publish(force: true)
    }

    private func disarmAutoDeletes() {
        for asset in store.all() where asset.pendingAutoDelete {
            _ = store.update(asset.id, now: deps.now()) { $0.pendingAutoDelete = false }
        }
    }

    public func setAutoDelete(_ enabled: Bool, for id: String) {
        _ = store.update(id, now: deps.now()) {
            $0.autoDeleteAfterWatching = enabled
            if !enabled { $0.pendingAutoDelete = false }
        }
        publish(force: true)
    }

    // MARK: - Leftovers and reset (IOS-POC-53)

    /// What an older build or an interrupted run left inside the offline folders: a folder with no
    /// record, half-written files, the addresses and partial data a finished download no longer
    /// needs, and staged bodies no current transfer will claim. Every download itself — finished,
    /// running, paused or failed — and every unreadable folder is kept.
    public func invalidFiles() -> [StorageCleanupItem] {
        let fileManager = FileManager.default
        var items = [StorageCleanupItem]()
        func add(_ url: URL, _ reason: StorageCleanupItem.Reason) {
            guard fileManager.fileExists(atPath: url.path) else { return }
            items.append(StorageCleanupItem(url: url, bytes: OfflineStorage.allocatedSize(of: url), reason: reason))
        }
        for name in ((try? fileManager.contentsOfDirectory(atPath: layout.root.path)) ?? []).sorted() where !name.hasPrefix(".") {
            let folder = layout.root.appendingPathComponent(name)
            guard store.asset(name) != nil || store.unreadable[name] != nil else {
                add(folder, .downloadLeftover)
                continue
            }
            for directory in [folder, folder.appendingPathComponent("playlists"), folder.appendingPathComponent("partial")] {
                for entry in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
                where entry.hasPrefix(".") && entry.contains(OfflineStorageLayout.temporaryMarker) {
                    add(directory.appendingPathComponent(entry), .interruptedWrite)
                }
            }
            if store.asset(name)?.state == .completed {
                add(layout.planFile(for: name), .downloadLeftover)
                add(layout.requestFile(for: name), .downloadLeftover)
                add(folder.appendingPathComponent("partial"), .downloadLeftover)
            }
        }
        for name in ((try? fileManager.contentsOfDirectory(atPath: layout.stagingDirectory.path)) ?? []).sorted() {
            if let tag = OfflineTransferTag(description: name.components(separatedBy: ".").first),
               let asset = store.asset(tag.assetID), asset.state == .downloading, asset.generation == tag.generation { continue }
            add(layout.stagingDirectory.appendingPathComponent(name), .downloadLeftover)
        }
        return items
    }

    /// Whether any download is not finished — its partial data must stay where the system keeps it.
    public func hasUnfinishedDownloads() -> Bool {
        store.all().contains { $0.state != .completed }
    }

    /// 初始化: every download and every unreadable folder, through the one delete path, so their
    /// transfers stop before the files go.
    @discardableResult
    public func deleteEverything() async -> OfflineDeletionResult {
        await deleteNow(store.all().map(\.id) + Array(store.unreadable.keys), reason: "reset")
    }

    // MARK: - Lookups

    public func asset(_ id: String) -> OfflineAsset? { store.asset(id) }
    public func asset(for identity: OfflineIdentity) -> OfflineAsset? { store.asset(for: identity) }

    /// A finished download of this episode, if there is one to play.
    public func completedAsset(for identity: OfflineIdentity) -> OfflineAsset? {
        store.asset(for: identity).flatMap { $0.state == .completed ? $0 : nil }
    }

    // MARK: - Publishing

    /// IOS-POC-52 (F30): what offline content occupies now — each finished package as measured,
    /// what every unfinished one has received (a single file's bytes sit in the system's own
    /// temporary file until it completes), and the unreadable folders — not a figure frozen at the
    /// last completion or delete.
    private func usage(of assets: [OfflineAsset]) -> Int64 {
        assets.reduce(unreadableUsage) { total, asset in
            total + (asset.state == .completed ? (asset.actualBytes ?? 0) : asset.progress.receivedBytes)
        }
    }

    private func measureUnreadable() {
        unreadableUsage = store.unreadable.keys.reduce(0) { $0 + store.size(of: $1) }
    }

    private func publish(force: Bool) {
        guard let observer else { return }
        let now = Date()
        if force || now.timeIntervalSince(lastPublish) >= 0.5 {
            lastPublish = now
            trailingPublish?.cancel()
            trailingPublish = nil
            observer(snapshot())
            return
        }
        guard trailingPublish == nil else { return }
        trailingPublish = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self.publishTrailing()
        }
    }

    private func publishTrailing() {
        trailingPublish = nil
        lastPublish = Date()
        observer?(snapshot())
    }
}

public enum OfflineFetchError: Error, Equatable {
    case http(Int)
    /// HTML (or nothing usable) where a playlist or media was expected.
    case notMedia
}

extension OfflineStorage {
    static func looksLikeHTMLText(_ data: Data) -> Bool {
        let text = String(decoding: data.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.hasPrefix("<!doctype html") || text.hasPrefix("<html") || text.hasPrefix("<head") || text.hasPrefix("<body")
    }
}
