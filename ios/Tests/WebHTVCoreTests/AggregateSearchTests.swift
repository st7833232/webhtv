import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-20. What these pin down: a search across sites asks exactly the sites Android would, sends
// the keyword in the simplified form the sources index, never has more calls in flight than its limit,
// reports a slow site without holding the others back, and does not ask a site that is still busy
// with an earlier search — because a spider cannot be stopped, asking again would only queue a second
// call behind the first.

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

@Test func sendsTheKeywordInSimplifiedForm() async throws {
    let heard = Heard()
    let search = AggregateSearch { _, keyword, _ in
        await heard.record(keyword)
        return []
    }
    let one = try site(unique("t2s"))
    _ = await collect(search.run([one], keyword: "慶餘年"))
    #expect(await heard.keywords == ["庆余年"])
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
}

private actor Heard {
    private(set) var keywords = [String]()
    func record(_ keyword: String) { keywords.append(keyword) }
}

private actor Meter {
    private(set) var peak = 0
    private var active = 0
    func enter() {
        active += 1
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
