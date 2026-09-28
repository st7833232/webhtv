import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-20. What these pin down: a search across sites asks exactly the sites Android would, sends
// the keyword in the simplified form the sources index, never has more calls in flight than its limit,
// reports a slow site without holding the others back, and does not ask a site that is still busy
// with an earlier search — because a spider cannot be stopped, asking again would only queue a second
// call behind the first.
//
// IOS-POC-33: a keyword typed in Traditional is also sent as typed, after the Simplified form, within
// the same slot; the site is still reported once, with both answers merged, and a form that answered
// before the deadline is shown rather than lost to it.

@Test func searchableFollowsAndroidsRule() throws {
    #expect(try site("absent").isSearchable)
    #expect(try site("one", searchable: "1").isSearchable)
    #expect(try !site("opted-out", searchable: "0").isSearchable)
    // 2 is what Android's per-site switch writes when a user turns a site off.
    #expect(try !site("switched-off", searchable: "2").isSearchable)
    #expect(try !site("quoted", searchable: #""0""#).isSearchable)
}

@Test func asksEachSearchableSiteOnceInConfigurationOrder() throws {
    let sites = [
        try site("a"), try site("b", searchable: "0"), try site("c", searchable: "2"),
        try site("a"), try site("d", searchable: "1"),
    ]
    #expect(AggregateSearch.sites(from: sites).map(\.key) == ["a", "d"])
}

@Test func convertsTraditionalCharactersAndLeavesTheRestAlone() {
    #expect(TraditionalSimplified.toSimplified("慶餘年") == "庆余年")
    // Android's own table turns these into 犟 and 缐, which no site indexes.
    #expect(TraditionalSimplified.toSimplified("強") == "强")
    #expect(TraditionalSimplified.toSimplified("線上") == "线上")
    #expect(TraditionalSimplified.toSimplified("戏谑 謔") == "戏谑 谑")
    #expect(TraditionalSimplified.toSimplified("软件 Film 4K") == "软件 Film 4K")
    #expect(TraditionalSimplified.toSimplified("") == "")
}

@Test func sendsTheSimplifiedFormThenTheKeywordAsTyped() async throws {
    let heard = Heard()
    let search = AggregateSearch { _, keyword, _ in
        await heard.record(keyword)
        return []
    }
    // IOS-POC-33: the form the sources index first, as before, then what was typed; still one report.
    let reports = await collect(search.run([try site(unique("t2s"))], keyword: "慶餘年"))
    #expect(await heard.keywords == ["庆余年", "慶餘年"])
    #expect(reports.count == 1)
    // Nothing to convert: one call, as before.
    _ = await collect(search.run([try site(unique("s"))], keyword: "庆余年"))
    #expect(await heard.keywords == ["庆余年", "慶餘年", "庆余年"])
}

@Test func mergesBothFormsIntoOneReportPerSite() async throws {
    let search = AggregateSearch { _, keyword, _ in
        keyword == "庆余年"
            ? [Vod(id: "1", name: "庆余年", picture: ""), Vod(id: "2", name: "庆余年2", picture: "")]
            : [Vod(id: "2", name: "慶餘年2", picture: ""), Vod(id: "3", name: "慶餘年3", picture: "")]
    }
    let reports = await collect(search.run([try site(unique("merge"))], keyword: "慶餘年"))
    #expect(reports.count == 1)
    let vods = try #require(reports.first?.outcome.vods)
    // The first answer exactly as sent, then only the title the typed form added.
    #expect(vods.map(\.id) == ["1", "2", "3"])
    #expect(vods.map(\.name) == ["庆余年", "庆余年2", "慶餘年3"])
    #expect(reports.first?.cursor.pending == [.init(keyword: "庆余年", page: 2), .init(keyword: "慶餘年", page: 2)])
}

@Test func showsWhatOneFormFoundWhenTheDeadlinePasses() async throws {
    let gate = Gate()
    // The typed form does not answer in time, the way a slow spider's second call does. Before
    // IOS-POC-33 this site answered in time, so it must not turn into a timeout now.
    let search = AggregateSearch(deadline: .milliseconds(100)) { _, keyword, _ in
        if keyword == "慶餘年" { await gate.wait() }
        return [Vod(id: "1", name: "庆余年", picture: "")]
    }
    var reports = search.run([try site(unique("partial"))], keyword: "慶餘年").makeAsyncIterator()
    let report = await reports.next()
    #expect(report?.outcome.name == "found")
    #expect(report?.outcome.vods?.map(\.id) == ["1"])
    // The typed form's page 1 was never shown, so 載入更多 starts it there.
    #expect(report?.cursor.pending == [.init(keyword: "庆余年", page: 2), .init(keyword: "慶餘年", page: 1)])
    await gate.open()
    let end = await reports.next()
    #expect(end == nil)
}

@Test func failsASiteOnlyWhenEveryFormFails() async throws {
    struct Refused: Error {}
    let half = AggregateSearch { _, keyword, _ in
        if keyword == "庆余年" { throw Refused() }
        return [Vod(id: "1", name: "慶餘年", picture: "")]
    }
    let found = await collect(half.run([try site(unique("half"))], keyword: "慶餘年"))
    #expect(found.map(\.outcome.name) == ["found"])
    let none = AggregateSearch { _, _, _ in throw Refused() }
    let failed = await collect(none.run([try site(unique("none"))], keyword: "慶餘年"))
    #expect(failed.map(\.outcome.name) == ["failed"])
}

@Test func twoFormsStillTakeOneSlotPerSite() async throws {
    let meter = Meter()
    let sites = try (0..<8).map { try site(unique("forms-\($0)")) }
    let search = AggregateSearch(limit: 3) { _, _, _ in
        await meter.enter()
        try? await Task.sleep(for: .milliseconds(10))
        await meter.leave()
        return []
    }
    let reports = await collect(search.run(sites, keyword: "慶餘年"))
    #expect(reports.count == 8)
    #expect(reports.allSatisfy { $0.outcome.name == "found" })
    // Every site asked both forms, and never more than three calls ran at once.
    #expect(await meter.total == 16)
    let peak = await meter.peak
    #expect(peak >= 1 && peak <= 3)
}

@Test func asksNoLaterFormOnceTheCallIsCancelled() async throws {
    // A timeout or 停止 cancels the call's work. The form already running cannot be stopped (a spider
    // ignores it), but the typed form must not start after it: it would hold the site busy for nothing.
    let heard = Heard()
    let gate = Gate()
    let work = Task {
        try await DualScriptSearch.firstPage(
            forms: ["庆余年", "慶餘年"], titles: { $0 },
            search: { (keyword: String) async -> [Vod] in
                await heard.record(keyword)
                if keyword == "庆余年" { await gate.wait() }
                return [Vod(id: "1", name: "庆余年", picture: "")]
            })
    }
    work.cancel()
    await gate.open()
    let answer = try await work.value
    #expect(answer.vods.map(\.id) == ["1"])
    #expect(await heard.keywords == ["庆余年"])
    #expect(answer.cursor.pending == [.init(keyword: "庆余年", page: 2), .init(keyword: "慶餘年", page: 1)])
}

@Test func neverHasMoreCallsInFlightThanTheLimit() async throws {
    let meter = Meter()
    let sites = try (0..<10).map { try site(unique("limit-\($0)")) }
    let search = AggregateSearch(limit: 3) { _, _, _ in
        await meter.enter()
        try? await Task.sleep(for: .milliseconds(20))
        await meter.leave()
        return []
    }
    let reports = await collect(search.run(sites, keyword: "x"))
    #expect(reports.count == 10)
    #expect(reports.allSatisfy { $0.outcome.name == "found" })
    let peak = await meter.peak
    #expect(peak >= 1 && peak <= 3)
}

@Test func reportsASlowSiteWithoutWaitingForIt() async throws {
    let gate = Gate()
    let slow = try site(unique("slow"))
    let fast = try site(unique("fast"))
    // The slow site ignores cancellation, the way a spider blocked in its HTTP host does.
    let search = AggregateSearch(deadline: .milliseconds(50)) { site, _, _ in
        if site.id == slow.id { await gate.wait() }
        return [Vod(id: "1", name: "片名", picture: "")]
    }
    var reports = search.run([slow, fast], keyword: "x").makeAsyncIterator()
    var outcomes = [String: String]()
    for _ in 0..<2 {
        guard let report = await reports.next() else { break }
        outcomes[report.site.key] = report.outcome.name
    }
    #expect(outcomes[fast.key] == "found")
    #expect(outcomes[slow.key] == "timedOut")
    // The search only ends once the slow call has really returned.
    await gate.open()
    let end = await reports.next()
    #expect(end == nil)
}

@Test func skipsASiteStillBusyWithAnEarlierSearch() async throws {
    let gate = Gate()
    let busy = try site(unique("busy"))
    let search = AggregateSearch(deadline: .milliseconds(50)) { _, _, _ in
        await gate.wait()
        return []
    }
    var first = search.run([busy], keyword: "x").makeAsyncIterator()
    let timedOut = await first.next()
    #expect(timedOut?.outcome.name == "timedOut")

    let second = await collect(search.run([busy], keyword: "y"))
    #expect(second.map(\.outcome.name) == ["busy"])

    await gate.open()
    while await first.next() != nil {}
    let third = await collect(search.run([busy], keyword: "z"))
    #expect(third.map(\.outcome.name) == ["found"])
}

@Test func reportsAFailingSiteAsFailed() async throws {
    struct Refused: Error {}
    let search = AggregateSearch { _, _, _ in throw Refused() }
    let failing = try site(unique("fails"))
    let reports = await collect(search.run([failing], keyword: "x"))
    #expect(reports.map(\.outcome.name) == ["failed"])
}

// MARK: - Helpers

private func site(_ key: String, searchable: String? = nil) throws -> Site {
    var json = #"{"key":"\#(key)","name":"\#(key)","type":1,"api":"https://example.com/api.php/provide/vod""#
    if let searchable { json += #","searchable":\#(searchable)"# }
    json += "}"
    return try JSONDecoder().decode(Site.self, from: Data(json.utf8))
}

/// Busy sites are remembered app-wide, and tests run in parallel, so every test uses its own keys.
private func unique(_ key: String) -> String { key + "-" + UUID().uuidString }

private func collect(_ stream: AsyncStream<AggregateSearch.Report>) async -> [AggregateSearch.Report] {
    var reports = [AggregateSearch.Report]()
    for await report in stream { reports.append(report) }
    return reports
}

private extension AggregateSearch.Outcome {
    var name: String {
        switch self {
        case .found: "found"
        case .failed: "failed"
        case .timedOut: "timedOut"
        case .busy: "busy"
        }
    }

    var vods: [Vod]? {
        if case .found(let vods) = self { return vods }
        return nil
    }
}

private actor Heard {
    private(set) var keywords = [String]()
    func record(_ keyword: String) { keywords.append(keyword) }
}

private actor Meter {
    private(set) var peak = 0
    private(set) var total = 0
    private var active = 0
    func enter() {
        active += 1
        total += 1
        peak = max(peak, active)
    }
    func leave() { active -= 1 }
}

/// A wait that ignores task cancellation until the test opens it.
private actor Gate {
    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
