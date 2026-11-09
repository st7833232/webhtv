import Foundation
import Testing
@testable import WebHTVCore

// W-263 (W-259 plan C): which line a failed VOD episode is tried on next, and which episode on it.

private func line(_ name: String, _ episodes: [String]) -> Flag {
    Flag(name: name, episodes: episodes.enumerated().map { Episode(name: $1, url: "https://\(name)/\($0)") })
}

private func drain(_ switcher: inout VodLineSwitcher, now: Date = Date()) -> [VodLineSwitcher.Step] {
    var steps: [VodLineSwitcher.Step] = []
    while let step = switcher.next(now: now) { steps.append(step) }
    return steps
}

@Test func aRoundStartsAfterTheFailedLineWrapsAndTriesEachLineOnce() {
    let flags = (0..<4).map { line("L\($0)", ["第1集", "第2集"]) }
    var switcher = VodLineSwitcher(flags: flags, failed: 2, episode: flags[2].episodes[1], spider: true)
    #expect(drain(&switcher).map(\.flag) == [3, 0, 1])
    #expect(drain(&switcher).isEmpty)
}

@Test func oneLineHasNothingToSwitchTo() {
    let flags = [line("L0", ["第1集"])]
    var switcher = VodLineSwitcher(flags: flags, failed: 0, episode: flags[0].episodes[0], spider: true)
    #expect(switcher.next() == nil)
}

@Test func theSameEpisodeIsFoundByNameFirst() {
    let source = line("A", ["預告", "第1集", "第2集"])
    let target = line("B", ["第2集", "第1集"])
    #expect(target.sameEpisode(as: source.episodes[2], in: source) == 0)
    // Case and surrounding spaces do not matter.
    #expect(line("C", ["ep1", " EP2 "]).sameEpisode(as: Episode(name: "EP2", url: "x"), in: source) == 1)
}

@Test func thenByTheEpisodeNumberInTheName() {
    let source = line("A", ["第01集", "第02集", "第03集"])
    let target = line("B", ["花絮", "1", "2", "3"])
    #expect(target.sameEpisode(as: source.episodes[1], in: source) == 2)
}

@Test func aNumberSharedOnTheSourceLineDoesNotMatch() {
    // Review C2: S01E05 reads 1, as does every episode of the season, so it must not become 第1集.
    let source = line("A", (1...10).map { String(format: "S01E%02d", $0) })
    let target = line("B", (1...10).map { "第\($0)集" })
    #expect(target.sameEpisode(as: source.episodes[4], in: source) == 4)
    // A different count leaves nothing trustworthy: skip the line.
    #expect(line("C", (1...12).map { "第\($0)集" }).sameEpisode(as: source.episodes[4], in: source) == nil)
}

@Test func thePositionOnlyWhenBothLinesHoldTheSameNumberOfEpisodes() {
    let source = line("A", ["正片", "加長版"])
    #expect(line("B", ["HD", "4K"]).sameEpisode(as: source.episodes[1], in: source) == 1)
    // One more entry (a trailer) or one fewer: the position could be another episode, so skip.
    #expect(line("C", ["預告", "HD", "4K"]).sameEpisode(as: source.episodes[1], in: source) == nil)
    #expect(line("D", ["HD"]).sameEpisode(as: source.episodes[1], in: source) == nil)
}

@Test func anAmbiguousNumberFallsBackToTheEqualCountRuleOnly() {
    let source = line("A", ["第1集", "第2集"])
    // Two entries numbered 2 and a different count: no trustworthy match.
    #expect(line("B", ["第2集上", "第2集下", "第3集"]).sameEpisode(as: source.episodes[1], in: source) == nil)
    // Same count: the position decides.
    #expect(line("C", ["第2集上", "第2集下"]).sameEpisode(as: source.episodes[1], in: source) == 1)
}

@Test func aLineWithoutTheEpisodeIsSkipped() {
    let flags = [line("A", ["第1集", "第2集", "第3集"]), line("B", ["第1集"]), line("C", ["第3集"])]
    var switcher = VodLineSwitcher(flags: flags, failed: 0, episode: flags[0].episodes[2], spider: true)
    #expect(drain(&switcher) == [.init(flag: 2, episode: 0)])
}

@Test func anUnplayableEpisodeIsSkipped() {
    // A CMS line's entry must be an http(s) address to be offered (IOS-POC-40).
    let flags = [line("A", ["第1集"]), Flag(name: "B", episodes: [Episode(name: "第1集", url: "magnet:x")]),
                 line("C", ["第1集"])]
    var switcher = VodLineSwitcher(flags: flags, failed: 0, episode: flags[0].episodes[0], spider: false)
    #expect(drain(&switcher).map(\.flag) == [2])
}

@Test func theRoundStopsAtItsTimeLimit() {
    let start = Date(timeIntervalSince1970: 1000)
    let flags = (0..<3).map { line("L\($0)", ["第1集"]) }
    var switcher = VodLineSwitcher(flags: flags, failed: 0, episode: flags[0].episodes[0], spider: true,
                                   now: start, limit: 120)
    #expect(switcher.next(now: start.addingTimeInterval(60))?.flag == 1)
    #expect(switcher.next(now: start.addingTimeInterval(121)) == nil)
}

@Test func episodeNumberReadsTheFirstRunOfDigits() {
    #expect(Flag.episodeNumber("第01集") == 1)
    #expect(Flag.episodeNumber("EP12 HD") == 12)
    #expect(Flag.episodeNumber("正片") == nil)
}
