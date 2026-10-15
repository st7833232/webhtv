import Testing
@testable import WebHTVCore

// W-124 (IOS-POC-59 U1): the order a channel's lines are tried in. X-3: one full round that wraps,
// starting with the chosen line itself, skipping what iOS cannot play.

private func switcher(_ supports: [LineSupport], start: Int) -> LiveLineSwitcher {
    LiveLineSwitcher(lines: supports.map { LiveLine(url: "http://x", label: nil, headers: [:], support: $0) }, start: start)
}

private func drain(_ switcher: inout LiveLineSwitcher) -> [Int] {
    var tried: [Int] = []
    while let index = switcher.next() { tried.append(index) }
    return tried
}

@Test func aRoundStartsAtTheChosenLineAndWrapsOnce() {
    var lines = switcher([.playable, .playable, .playable, .playable], start: 1)
    #expect(drain(&lines) == [1, 2, 3, 0])
    #expect(lines.next() == nil)
}

@Test func unsupportedLinesAreSkippedAndAttemptLinesAreTried() {
    var fromZero = switcher([.unsupported(.p2p), .attempt, .playable, .unsupported(.youtube)], start: 0)
    #expect(drain(&fromZero) == [1, 2])
    var fromUnsupported = switcher([.unsupported(.p2p), .attempt, .playable, .unsupported(.youtube)], start: 3)
    #expect(drain(&fromUnsupported) == [1, 2])
}

@Test func oneLineAndNoUsableLine() {
    var one = switcher([.playable], start: 0)
    #expect(drain(&one) == [0])
    var none = switcher([.unsupported(.drm), .unsupported(.parse)], start: 0)
    #expect(none.next() == nil)
    var empty = LiveLineSwitcher(lines: [], start: 0)
    #expect(empty.next() == nil)
}

@Test func selectingALineStartsANewRoundFromIt() {
    var lines = switcher([.playable, .playable, .playable, .playable], start: 1)
    #expect(lines.next() == 1)
    lines.select(3)
    #expect(drain(&lines) == [3, 0, 1, 2])
    // "Retry" after a spent round is selecting the start again.
    lines.select(1)
    #expect(drain(&lines) == [1, 2, 3, 0])
}

// W-124 review N-2: a start outside the lines wraps instead of crashing.
@Test func aStartOutsideTheLinesWraps() {
    var negative = switcher([.playable, .playable, .playable, .playable], start: -1)
    #expect(drain(&negative) == [3, 0, 1, 2])
    var past = switcher([.playable, .playable], start: 5)
    #expect(drain(&past) == [1, 0])
}
