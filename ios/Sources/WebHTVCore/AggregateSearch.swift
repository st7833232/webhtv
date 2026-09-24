import Foundation
import os

/// Searches every site of the configuration in use at once and reports each site as it answers.
///
/// IOS-POC-20. The sites run on three threading models, and the limits here follow from those rather
/// than from Android's twenty threads (`docs/IOS-POC-20-aggregate-search.md`, 設計研究):
///
/// - a CMS site is an async `URLSession` request, so cancelling its task really stops it;
/// - a JavaScript spider — every ported `csp_*` class is one — runs on its own serial queue, and its
///   HTTP host blocks that thread on a semaphore for up to 65 s a request, which nothing interrupts;
/// - a Python spider has the same shape since this task moved it onto a queue of its own.
///
/// So at most `limit` calls of one search run at once, a call keeps its slot until the work under it
/// has really ended (a spider past its deadline still holds a thread), and a site still busy with an
/// earlier search is reported as busy instead of being queued behind itself. The deadline decides
/// only what the screen says: it can stop a CMS request, never a spider.
public struct AggregateSearch: Sendable {
    public static let defaultLimit = 6
    public static let defaultDeadline: Duration = .seconds(30)

    /// One page of one site's results, for a keyword that is already simplified.
    public typealias Search = @Sendable (_ site: Site, _ keyword: String, _ page: Int) async throws -> [Vod]

    public struct Report: Sendable {
        /// The site's position in the list handed to `run`.
        public let index: Int
        public let site: Site
        public let outcome: Outcome
    }

    public enum Outcome: Sendable {
        case found([Vod])
        case failed(String)
        /// No answer within the deadline. A spider's call is still running.
        case timedOut
        /// Still busy with a call from an earlier search, so this search did not ask it again.
        case busy
    }

    private let limit: Int
    private let deadline: Duration
    private let search: Search

    public init(limit: Int = AggregateSearch.defaultLimit, deadline: Duration = AggregateSearch.defaultDeadline,
                search: @escaping Search) {
        self.limit = max(limit, 1)
        self.deadline = deadline
        self.search = search
    }

    /// The sites a search goes to, in configuration order: the searchable ones, each `Site.id` once.
    /// A spider session is keyed on `Site.id` (`SpiderSessionStore`), so a second site with the same
    /// id would only ask the first one's session again.
    public static func sites(from sites: [Site]) -> [Site] {
        var seen = Set<String>()
        return sites.filter { $0.isSearchable && seen.insert($0.id).inserted }
    }

    /// One search. The stream yields one report per site and then finishes. Ending the iteration, or
    /// cancelling the task that iterates, stops the search: no further site is asked, a pending CMS
    /// request is cancelled, and a spider already running finishes on its own.
    public func run(_ sites: [Site], keyword: String) -> AsyncStream<Report> {
        let (stream, continuation) = AsyncStream.makeStream(of: Report.self)
        let simplified = TraditionalSimplified.toSimplified(keyword)
        let task = Task {
            await drive(sites, keyword: simplified, into: continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// A further page of one site, for that site's 載入更多. It is one call the user asked for, so it
    /// is neither limited nor skipped; a spider still busy runs it after the call before it.
    public func page(_ page: Int, of site: Site, keyword: String) async throws -> [Vod] {
        try await search(site, TraditionalSimplified.toSimplified(keyword), page)
    }

    // MARK: - Scheduling

    private static let log = Logger(subsystem: "com.webhtv.ios.poc", category: "search")

    /// Sites with a call still running, across every search in the app: the spiders they run on are
    /// shared app-wide (`SpiderSessionStore`), so this is too.
    private static let calls = InFlightCalls()

    private func drive(_ sites: [Site], keyword: String,
                       into continuation: AsyncStream<Report>.Continuation) async {
        let began = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            var pending = sites.enumerated().makeIterator()
            var running = 0
            while !Task.isCancelled {
                while running < limit, let next = pending.next() {
                    guard await Self.calls.begin(next.element.id) else {
                        Self.log.notice("[search] \(next.element.name, privacy: .public) is still busy with an earlier search")
                        continuation.yield(Report(index: next.offset, site: next.element, outcome: .busy))
                        continue
                    }
                    running += 1
                    let count = running
                    Self.log.notice("[search] ask \(next.element.name, privacy: .public), \(count) running")
                    group.addTask {
                        await call(next.element, at: next.offset, keyword: keyword, into: continuation)
                    }
                }
                guard running > 0 else { break }
                _ = await group.next()
                running -= 1
            }
        }
        Self.log.notice("[search] \(sites.count) sites done in \(Self.milliseconds(since: began))ms")
    }

    private func call(_ site: Site, at index: Int, keyword: String,
                      into continuation: AsyncStream<Report>.Continuation) async {
        guard !Task.isCancelled else {
            await Self.calls.end(site.id)
            return
        }
        let began = ContinuousClock.now
        let work = Task { [search] () -> Outcome in
            let outcome: Outcome
            do {
                outcome = .found(try await search(site, keyword, 1))
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            await Self.calls.end(site.id)
            return outcome
        }
        switch await Self.race(work, deadline: deadline) {
        case .finished(let outcome):
            Self.log.notice("[search] \(site.name, privacy: .public) answered in \(Self.milliseconds(since: began))ms")
            continuation.yield(Report(index: index, site: site, outcome: outcome))
        case .timedOut:
            Self.log.notice("[search] \(site.name, privacy: .public) timed out")
            continuation.yield(Report(index: index, site: site, outcome: .timedOut))
            // Stops a CMS request. A spider runs on, and its slot stays taken until it returns, so no
            // more than `limit` threads are ever blocked under one search.
            work.cancel()
            _ = await Self.race(work, deadline: nil)
        case .cancelled:
            work.cancel()
        }
    }

    private enum Race: Sendable {
        case finished(Outcome)
        case timedOut
        case cancelled
    }

    /// Waits for `work`, for `deadline` when there is one, or for this task to be cancelled, whichever
    /// comes first. It never waits for `work` to stop, because a spider does not stop on request —
    /// which is also why this is not a task group: a group always waits for all of its child tasks.
    private static func race(_ work: Task<Outcome, Never>, deadline: Duration?) async -> Race {
        let first = FirstRace()
        let timer = deadline.map { deadline in
            Task {
                do { try await Task.sleep(for: deadline) } catch { return }
                first.settle(.timedOut)
            }
        }
        Task { first.settle(.finished(await work.value)) }
        let winner: Race = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Race, Never>) in
                first.install(continuation)
            }
        } onCancel: {
            first.settle(.cancelled)
        }
        timer?.cancel()
        return winner
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let elapsed = (ContinuousClock.now - start).components
        return elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
    }

    /// Resumes one continuation exactly once, with whichever result comes first (a continuation must
    /// be resumed exactly once — WWDC22 110350). A result can come before the continuation does: a
    /// cancellation handler runs first when the task is already cancelled, so it is kept until then.
    /// The continuation is resumed outside the lock, as `withTaskCancellationHandler` asks.
    private final class FirstRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Race, Never>?
        private var result: Race?

        func install(_ continuation: CheckedContinuation<Race, Never>) {
            let early: Race? = lock.withLock {
                if result == nil { self.continuation = continuation }
                return result
            }
            if let early { continuation.resume(returning: early) }
        }

        func settle(_ race: Race) {
            let waiting: CheckedContinuation<Race, Never>? = lock.withLock {
                guard result == nil else { return nil }
                result = race
                let waiting = continuation
                continuation = nil
                return waiting
            }
            waiting?.resume(returning: race)
        }
    }

    private actor InFlightCalls {
        private var sites = Set<String>()

        func begin(_ id: String) -> Bool { sites.insert(id).inserted }
        func end(_ id: String) { sites.remove(id) }
    }
}
