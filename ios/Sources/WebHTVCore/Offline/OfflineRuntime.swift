import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// IOS-POC-47 — the downloads screens' view of the manager: the latest snapshot, on the main actor.
@MainActor
@Observable
public final class OfflineLibrary {
    public private(set) var snapshot = OfflineSnapshot()

    public init() {}

    /// Starts receiving the manager's snapshots.
    public func connect(_ manager: OfflineDownloadManager) async {
        await manager.setObserver { [weak self] snapshot in
            Task { @MainActor in self?.apply(snapshot) }
        }
    }

    func apply(_ snapshot: OfflineSnapshot) {
        // Snapshots cross to the main actor one task each; an older one arriving late is dropped.
        guard snapshot.sequence >= self.snapshot.sequence else { return }
        self.snapshot = snapshot
    }

    public func asset(for identity: OfflineIdentity) -> OfflineAsset? {
        snapshot.assets.first { $0.identity == identity && $0.state != .deleting }
    }

    /// One title's downloads, in episode order.
    public func assets(forHistoryKey key: String) -> [OfflineAsset] {
        snapshot.assets.filter { $0.identity.historyKey == key && $0.state != .deleting }
            .sorted { ($0.identity.flag, $0.title.episodeIndex) < ($1.identity.flag, $1.title.episodeIndex) }
    }
}

#if canImport(Darwin)
/// The real transport: a background `URLSession`, so iOS keeps downloading after the app leaves the
/// screen or the phone locks, and hands the finished transfers back after a relaunch.
///
/// A transfer whose headers may only go to the stream's origin (`credentialed`) runs on a default
/// session instead: a background session follows redirects without asking (Apple), which could
/// carry a Cookie to another host. Such a transfer stops with the app and is sent again on return
/// (`OfflineDownloadManager.reconnect`).
///
/// Events reach the manager through one stream, in the order the session reported them.
public final class URLSessionOfflineTransport: NSObject, OfflineTransport, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let backgroundIdentifier = "com.webhtv.ios.poc.offline"

    private let staging: URL
    private let lock = NSLock()
    private var background: URLSession!
    private var foreground: URLSession!
    /// One report, or the mark that the background session has delivered everything it held.
    private enum Item: Sendable {
        case event(OfflineTransferTag, OfflineTransferEvent)
        case drained(Completion)
    }
    private let events: AsyncStream<Item>
    private let continuation: AsyncStream<Item>.Continuation
    /// IOS-POC-52 (F29): how many times each asset's transfers were cancelled. A `submit` that
    /// started before a cancel creates nothing more for that asset.
    private var cancellations = [String: Int]()
    private var consumer: Task<Void, Never>?
    private var redirects = [Int: (headers: [String: String], origin: URL)]()
    private var finishedTasks = Set<String>()
    private var lastProgress = [String: Date]()
    private var backgroundCompletion: Completion?

    /// iOS's handler is not `Sendable`; it is called once, on the main queue, as iOS asks.
    private final class Completion: @unchecked Sendable {
        let call: () -> Void
        init(_ call: @escaping () -> Void) { self.call = call }
    }

    public init(staging: URL) {
        self.staging = staging
        (events, continuation) = AsyncStream.makeStream(of: Item.self)
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let backgroundConfiguration = URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
        backgroundConfiguration.sessionSendsLaunchEvents = true
        backgroundConfiguration.isDiscretionary = false
        backgroundConfiguration.httpMaximumConnectionsPerHost = 4
        backgroundConfiguration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        backgroundConfiguration.urlCache = nil
        background = URLSession(configuration: backgroundConfiguration, delegate: self, delegateQueue: queue)
        let foregroundConfiguration = URLSessionConfiguration.default
        foregroundConfiguration.httpMaximumConnectionsPerHost = 4
        foregroundConfiguration.urlCache = nil
        foregroundConfiguration.timeoutIntervalForRequest = 30
        // IOS-POC-49: a Wi-Fi-only download on a cellular-only route waits, as the background
        // session's do, instead of failing with "not connected".
        foregroundConfiguration.waitsForConnectivity = true
        foreground = URLSession(configuration: foregroundConfiguration, delegate: self, delegateQueue: queue)
    }

    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`'s handler, called
    /// once the session has delivered everything it held.
    public func setBackgroundCompletion(_ handler: @escaping () -> Void) {
        let completion = Completion(handler)
        lock.withLock { backgroundCompletion = completion }
    }

    public func attach(_ sink: @escaping @Sendable (OfflineTransferTag, OfflineTransferEvent) async -> Void,
                       settle: @escaping @Sendable () async -> Void) async {
        let events = events
        lock.withLock {
            guard consumer == nil else { return }
            consumer = Task {
                for await item in events {
                    switch item {
                    case .event(let tag, let event):
                        await sink(tag, event)
                    case .drained(let completion):
                        // IOS-POC-52 (F11): every event before this one has been handled, and what
                        // they started has had its chance to finish, before iOS hears we are done.
                        await settle()
                        DispatchQueue.main.async { completion.call() }
                    }
                }
            }
        }
    }

    public func submit(_ requests: [OfflineTransferRequest]) async {
        let started = lock.withLock { cancellations }
        for request in requests {
            let session = request.credentialed ? foreground! : background!
            // Created under the lock, so a cancel either comes first and stops it, or comes after
            // and finds it among the session's tasks.
            let task: URLSessionDownloadTask? = lock.withLock {
                guard cancellations[request.tag.assetID] == started[request.tag.assetID] else { return nil }
                let task = request.resumeData.map { session.downloadTask(withResumeData: $0) }
                    ?? session.downloadTask(with: request.urlRequest)
                task.taskDescription = request.tag.description
                if request.credentialed { redirects[task.taskIdentifier] = (request.headers, request.origin) }
                return task
            }
            task?.resume()
        }
    }

    private func allTasks() async -> [URLSessionTask] {
        let first = await background.allTasks
        let second = await foreground.allTasks
        return first + second
    }

    public func cancel(assetID: String, producingResumeData: Bool) async -> [OfflineTransferTag: Data] {
        lock.withLock { cancellations[assetID, default: 0] += 1 }
        var collected = [OfflineTransferTag: Data]()
        for task in await allTasks() {
            guard let tag = OfflineTransferTag(description: task.taskDescription), tag.assetID == assetID else { continue }
            if producingResumeData, let download = task as? URLSessionDownloadTask {
                if let data = await download.cancelByProducingResumeData() { collected[tag] = data }
            } else {
                task.cancel()
            }
        }
        return collected
    }

    public func cancel(tags: Set<OfflineTransferTag>) async {
        for task in await allTasks() {
            if let tag = OfflineTransferTag(description: task.taskDescription), tags.contains(tag) { task.cancel() }
        }
    }

    public func discardResumeData(_ data: Data) async {
        // A task made from the resume data and cancelled without asking for new resume data:
        // the session removes the partial file it pointed at.
        background.downloadTask(withResumeData: data).cancel()
    }

    public func activeTags() async -> Set<OfflineTransferTag> {
        Set(await allTasks().filter { $0.state == .running || $0.state == .suspended }
            .compactMap { OfflineTransferTag(description: $0.taskDescription) })
    }

    private func key(_ session: URLSession, _ task: URLSessionTask) -> String {
        "\(session === background ? "b" : "f")\(task.taskIdentifier)"
    }

    // MARK: Delegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let tag = OfflineTransferTag(description: downloadTask.taskDescription) else { return }
        let taskKey = key(session, downloadTask)
        lock.withLock { _ = finishedTasks.insert(taskKey) }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200...299).contains(status) else {
            continuation.yield(.event(tag, .failed(OfflineTransferFailure(.http(status)))))
            return
        }
        // The file is gone once this method returns: it is moved now, synchronously (Apple). Its
        // name keeps the tag and the status, so a body the app never got to handle is taken up at
        // the next launch (IOS-POC-52 F11, `OfflineStagedBody`).
        let target = staging.appendingPathComponent(OfflineStagedBody.name(tag: tag, status: status))
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: target)
            continuation.yield(.event(tag, .finished(file: target, status: status)))
        } catch {
            continuation.yield(.event(tag, .failed(OfflineTransferFailure(OfflineStorage.isOutOfSpace(error) ? .noSpace : .network("move")))))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskKey = key(session, task)
        let isForeground = session === foreground
        let finished = lock.withLock {
            if isForeground { redirects[task.taskIdentifier] = nil }
            lastProgress[taskKey] = nil
            return finishedTasks.remove(taskKey) != nil
        }
        guard !finished, let tag = OfflineTransferTag(description: task.taskDescription) else { return }
        guard let error else {
            continuation.yield(.event(tag, .failed(OfflineTransferFailure(.network("no body")))))
            return
        }
        let nsError = error as NSError
        let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let kind: OfflineTransferFailure.Kind
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            kind = .cancelled
        } else if OfflineStorage.isOutOfSpace(error) {
            kind = .noSpace
        } else if nsError.domain == NSURLErrorDomain, Self.connectivityCodes.contains(nsError.code) {
            kind = .connectivity("NSURLError \(nsError.code)")
        } else {
            kind = .network("NSURLError \(nsError.code)")
        }
        continuation.yield(.event(tag, .failed(OfflineTransferFailure(kind, resumeData: resume))))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // Only a large file is worth reporting, at most twice a second.
        guard totalBytesExpectedToWrite <= 0 || totalBytesExpectedToWrite > 8_000_000,
              let tag = OfflineTransferTag(description: downloadTask.taskDescription) else { return }
        let taskKey = key(session, downloadTask)
        let now = Date()
        let due = lock.withLock {
            let due = now.timeIntervalSince(lastProgress[taskKey] ?? .distantPast) >= 0.5
            if due { lastProgress[taskKey] = now }
            return due
        }
        guard due else { return }
        continuation.yield(.event(tag, .progress(written: totalBytesWritten,
                                                 expected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)))
    }

    /// Only the default session asks (a background one follows redirects by itself): headers meant
    /// for the origin do not follow a redirect to another host.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let info = lock.withLock { redirects[task.taskIdentifier] }
        guard let info else { completionHandler(request); return }
        completionHandler(OfflineHTTP.redirect(request, headers: info.headers, origin: info.origin))
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock {
            defer { backgroundCompletion = nil }
            return backgroundCompletion
        }
        guard let completion else { return }
        // IOS-POC-52 (F11): through the stream, behind the events it delivered — calling it here
        // let iOS suspend the app before the manager had handled them.
        continuation.yield(.drained(completion))
    }

    /// Timeout, lost connection, no connection, cellular not allowed, roaming off.
    static let connectivityCodes: Set<Int> = [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                                              NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed,
                                              NSURLErrorInternationalRoamingOff]
}

/// Resolves a download's episode again — fresh addresses for a retry whose old ones expired —
/// through the very path a play uses (`SourceClient.playbackURL`).
public enum OfflineEpisodeResolver {
    public static func target(for asset: OfflineAsset, sites: [Site], source: ConfigSource) async -> PlaybackTarget? {
        let suffix = WatchHistory.separator + asset.title.vodId
        guard asset.identity.historyKey.hasSuffix(suffix) else { return nil }
        let siteID = String(asset.identity.historyKey.dropLast(suffix.count))
        guard let site = sites.first(where: { $0.id == siteID }),
              let client = try? await SourceClient.make(site: site, resolver: CSPSourceResolver(source: source))
        else { return nil }
        let episode = Episode(name: asset.title.episodeName, url: asset.identity.episodeURL)
        return try? await client.playbackURL(for: episode, flag: asset.identity.flag)
    }
}

/// The app's one set of offline objects.
public enum OfflineDownloads {
    public static let layout = OfflineStorageLayout.standard()
    public static let transport = URLSessionOfflineTransport(staging: layout.stagingDirectory)
    public static let manager = OfflineDownloadManager(.init(
        layout: layout, transport: transport,
        capacity: { OfflineStorage.availableCapacity(at: layout.root.deletingLastPathComponent()) },
        fetcher: { origin, headers in OfflineHTTP.fetcher(origin: origin, originalHeaders: headers) },
        subtitles: SubtitleDownloadService()))
    #if canImport(Network)
    public static let server = OfflineMediaServer(root: layout.root)
    #endif

    /// The address a completed asset is played from: the server is started for an HLS package.
    public static func playbackSource(for asset: OfflineAsset) async -> OfflinePlaybackSource? {
        var base: URL?
        #if canImport(Network)
        if asset.package?.isHLS == true { base = await server.start() }
        #endif
        return OfflinePlaybackResolver.source(for: asset, layout: layout, serverBase: base)
    }
}
#endif
