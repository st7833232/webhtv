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
///
/// IOS-POC-33: a call asks each keyword form (`DualScriptSearch`) in turn within its one slot, and
/// the site is still reported once, with the forms' titles merged.
public struct AggregateSearch: Sendable {
    public static let defaultLimit = 6
    public static let defaultDeadline: Duration = .seconds(30)

    /// One page of one site's results, for one keyword form (`DualScriptSearch.forms(of:)`).
    public typealias Search = @Sendable (_ site: Site, _ keyword: String, _ page: Int) async throws -> [Vod]

    public struct Report: Sendable {
        /// The site's position in the list handed to `run`.
        public let index: Int
        public let site: Site
        public let outcome: Outcome
        /// IOS-POC-33: where this site's 載入更多 starts. Finished unless something was found.
        public let cursor: DualScriptSearch.Cursor
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
        let forms = DualScriptSearch.forms(of: keyword)
        let task = Task {
            await drive(sites, forms: forms, into: continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// A further page of one site, for that site's 載入更多: the next page of every keyword form still
    /// adding titles, merged onto what is shown (IOS-POC-33). It is one request the user made, so it
    /// is neither limited nor skipped; a spider still busy runs it after the call before it.
    public func more(after shown: [Vod], cursor: DualScriptSearch.Cursor, of site: Site) async
        -> (vods: [Vod], cursor: DualScriptSearch.Cursor) {
        await DualScriptSearch.nextPage(after: shown, cursor: cursor) { [search] keyword, page in
            try await search(site, keyword, page)
        }
    }

    // MARK: - Scheduling

    private static let log = Logger(subsystem: "com.webhtv.ios.poc", category: "search")

    /// Sites with a call still running, across every search in the app: the spiders they run on are
    /// shared app-wide (`SpiderSessionStore`), so this is too.
    private static let calls = InFlightCalls()

    private func drive(_ sites: [Site], forms: [String],
                       into continuation: AsyncStream<Report>.Continuation) async {
        let began = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            var pending = sites.enumerated().makeIterator()
            var running = 0
            while !Task.isCancelled {
                while running < limit, let next = pending.next() {
                    guard await Self.calls.begin(next.element.id) else {
                        Self.log.notice("[search] \(next.element.name, privacy: .public) is still busy with an earlier search")
                        continuation.yield(Report(index: next.offset, site: next.element, outcome: .busy,
                                                  cursor: DualScriptSearch.Cursor(pending: [])))
                        continue
                    }
                    running += 1
                    let count = running
                    Self.log.notice("[search] ask \(next.element.name, privacy: .public), \(count) running")
                    group.addTask {
                        await call(next.element, at: next.offset, forms: forms, into: continuation)
                    }
                }
                guard running > 0 else { break }
                _ = await group.next()
                running -= 1
            }
        }
        Self.log.notice("[search] \(sites.count) sites done in \(Self.milliseconds(since: began))ms")
    }

    private func call(_ site: Site, at index: Int, forms: [String],
                      into continuation: AsyncStream<Report>.Continuation) async {
        guard !Task.isCancelled else {
            await Self.calls.end(site.id)
            return
        }
        let began = ContinuousClock.now
        // What the forms have found so far, for a deadline that passes between two of them.
        let partial = Partial()
        let work = Task { [search] () -> Answer in
            let answer: Answer
            do {
                let found = try await DualScriptSearch.firstPage(
                    forms: forms, titles: { $0 },
                    progress: { form, vods, cursor in
                        // Only a later form can still be waiting, so one form keeps the old timeout.
                        guard forms.count > 1 else { return }
                        partial.set(vods, cursor)
                        Self.log.notice("[search] \(site.name, privacy: .public) form \(form + 1)/\(forms.count): \(vods.count) titles in \(Self.milliseconds(since: began))ms")
                    },
                    search: { keyword in try await search(site, keyword, 1) })
                answer = Answer(outcome: .found(found.vods), cursor: found.cursor)
            } catch {
                answer = Answer(outcome: .failed(error.localizedDescription), cursor: DualScriptSearch.Cursor(pending: []))
            }
            await Self.calls.end(site.id)
            return answer
        }
        switch await Self.race(work, deadline: deadline) {
        case .finished(let answer):
            Self.log.notice("[search] \(site.name, privacy: .public) answered in \(Self.milliseconds(since: began))ms")
            continuation.yield(Report(index: index, site: site, outcome: answer.outcome, cursor: answer.cursor))
        case .timedOut:
            // IOS-POC-33: a form that answered in time is shown; only a site with nothing to show has
            // timed out.
            if let found = partial.value {
                Self.log.notice("[search] \(site.name, privacy: .public) timed out after \(found.vods.count) titles")
                continuation.yield(Report(index: index, site: site, outcome: .found(found.vods), cursor: found.cursor))
            } else {
                Self.log.notice("[search] \(site.name, privacy: .public) timed out")
                continuation.yield(Report(index: index, site: site, outcome: .timedOut,
                                          cursor: DualScriptSearch.Cursor(pending: [])))
            }
            // Stops a CMS request. A spider runs on, and its slot stays taken until it returns, so no
            // more than `limit` threads are ever blocked under one search.
            work.cancel()
            _ = await Self.race(work, deadline: nil)
        case .cancelled:
            work.cancel()
        }
    }

    /// What one call ends with: the site's outcome and where its 載入更多 starts.
    private struct Answer: Sendable {
        let outcome: Outcome
        let cursor: DualScriptSearch.Cursor
    }

    private enum Race: Sendable {
        case finished(Answer)
        case timedOut
        case cancelled
    }

    /// Waits for `work`, for `deadline` when there is one, or for this task to be cancelled, whichever
    /// comes first. It never waits for `work` to stop, because a spider does not stop on request —
    /// which is also why this is not a task group: a group always waits for all of its child tasks.
    private static func race(_ work: Task<Answer, Never>, deadline: Duration?) async -> Race {
        let first = FirstRace()
        let timer = deadline.map { deadline in
            Task {
                do { try await Task.sleep(for: deadline) } catch { return }
                first.settle(.timedOut)
                // IOS-POC-33: at once, so no later keyword form starts after the deadline. Settled
                // first, so the timeout still wins over the cancelled work's own answer.
                work.cancel()
            }
        }
        Task { first.settle(.finished(await work.value)) }
        let winner: Race = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Race, Never>) in
                first.install(continuation)
            }
        } onCancel: {
            first.settle(.cancelled)
            work.cancel()
        }
        timer?.cancel()
        return winner
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int64 {
        Int64((ContinuousClock.now - start) / .milliseconds(1))
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

    /// IOS-POC-33: what one call's keyword forms have found so far, and where 載入更多 would start.
    private final class Partial: @unchecked Sendable {
        private let lock = NSLock()
        private var found: (vods: [Vod], cursor: DualScriptSearch.Cursor)?

        var value: (vods: [Vod], cursor: DualScriptSearch.Cursor)? { lock.withLock { found } }

        func set(_ vods: [Vod], _ cursor: DualScriptSearch.Cursor) {
            lock.withLock { found = (vods: vods, cursor: cursor) }
        }
    }

    private actor InFlightCalls {
        private var sites = Set<String>()

        func begin(_ id: String) -> Bool { sites.insert(id).inserted }
        func end(_ id: String) { sites.remove(id) }
    }
}
