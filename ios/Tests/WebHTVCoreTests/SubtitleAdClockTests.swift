import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-45E. 智慧去廣 leaves the ads in the engine's clock and a downloaded file is timed to the
// programme alone, so a correction lined up after one ad break was off again after the next. These
// pin the mapping that makes one correction hold for the whole video.

/// IOS-POC-25's recorded sample: two breaks, 19.633 s and 17.359 s.
private let sample = SubtitleAdClock(ads: [.init(start: 356.648, end: 376.281), .init(start: 1697.852, end: 1715.211)])

@Test func adSecondsCountOnlyTheAdTimeAlreadyPassed() {
    #expect(sample.adSeconds(before: 100) == 0)
    #expect(abs(sample.adSeconds(before: 366.648) - 10) < 1e-9)
    #expect(abs(sample.adSeconds(before: 376.281) - 19.633) < 1e-9)
    #expect(abs(sample.adSeconds(before: 2000) - (19.633 + 17.359)) < 1e-9)
    #expect(abs(sample.totalSeconds - 36.992) < 1e-9 && sample.count == 2)
}

/// Programme time stops for the length of an ad and resumes where it stopped.
@Test func contentTimeFreezesInsideAnAdAndResumesAfterIt() throws {
    #expect(sample.contentTime(at: 356.648) == nil && sample.contentTime(at: 360) == nil)
    #expect(abs(try #require(sample.contentTime(at: 356.6)) - 356.6) < 1e-9)
    // The ad ends where the programme stopped.
    #expect(abs(try #require(sample.contentTime(at: 376.281)) - 356.648) < 1e-9)
    #expect(abs(try #require(sample.contentTime(at: 1000)) - (1000 - 19.633)) < 1e-9)
}

/// The report: lined up at 10:00, seeked to 30:00. With the mapping the same correction shows the
/// same line on both sides of the second break; without it the line came 17.4 s early.
@Test func oneCorrectionKeepsTheSameLineOnBothSidesOfAnAdBreak() {
    let cues = SubtitleCues([SubtitleCue(start: 580, end: 583, text: "第一句"),
                             SubtitleCue(start: 1700, end: 1703, text: "第二句")])
    let delay = 0.5
    // Engine time of each line: programme time plus the ads before it, plus the correction.
    #expect(cues.text(at: 580 + 19.633 + delay + 1, delay: delay, clock: sample) == "第一句")
    #expect(cues.text(at: 1700 + 36.992 + delay + 1, delay: delay, clock: sample) == "第二句")
    #expect(cues.text(at: 1700 + 19.633 + delay + 1, delay: delay, clock: sample) == nil)
    // What the unmapped lookup did: lined up after the first break (the correction then had to
    // carry that break, 19.633 s), the second line came 17.359 s before its moment.
    let unmapped = 19.633 + delay
    #expect(cues.text(at: 1700 + unmapped + 1, delay: unmapped) == "第二句")
    #expect(cues.text(at: 1700 + 36.992 + delay + 1, delay: unmapped) == nil)
}

/// No plan, no change: every lookup is exactly what it was before.
@Test func noAdPlanLeavesTheLookupExactlyAsBefore() {
    let cues = SubtitleCues([SubtitleCue(start: 1, end: 2, text: "a"), SubtitleCue(start: 2.5, end: 9, text: "b")])
    for position in stride(from: -1.0, through: 12, by: 0.05) {
        for delay in [-1.5, 0, 0.3, 2] {
            #expect(cues.text(at: position, delay: delay, clock: .none) == cues.text(at: position, delay: delay))
        }
    }
}

/// A line running into an ad is hidden for the ad and shows its remainder afterwards.
@Test func aCueStraddlingAnAdHidesDuringItAndFinishesAfter() {
    let clock = SubtitleAdClock(ads: [.init(start: 10, end: 30)])
    let cues = SubtitleCues([SubtitleCue(start: 9, end: 11, text: "跨廣告")])
    #expect(cues.text(at: 9.5, delay: 0, clock: clock) == "跨廣告")
    #expect(cues.text(at: 20, delay: 0, clock: clock) == nil)
    #expect(cues.text(at: 30.5, delay: 0, clock: clock) == "跨廣告")
    #expect(cues.text(at: 31.5, delay: 0, clock: clock) == nil)
}

/// mpv only shifts: its delay is the viewer's plus every ad begun, the whole ad from its first
/// moment, so where the programme resumes the value is already right.
@Test func mpvGetsTheViewersCorrectionPlusEveryAdBegun() {
    #expect(sample.engineDelay(user: 0.5, at: 100) == 0.5)
    #expect(abs(sample.engineDelay(user: 0.5, at: 356.7) - (0.5 + 19.633)) < 1e-9)
    #expect(abs(sample.engineDelay(user: 0.5, at: 2000) - (0.5 + 36.992)) < 1e-9)
    #expect(sample.isInsideAd(356.7) && !sample.isInsideAd(376.281))
    #expect(SubtitleAdClock.none.engineDelay(user: -2, at: 999) == -2)
}

/// Ranges a millisecond apart are one ad split across blocks, as the skipper jumps them.
@Test func adjacentRangesCountAsOneAd() {
    let timeline = HLSAdTimeline(ranges: [.init(startMs: 10_000, endMs: 20_000), .init(startMs: 20_001, endMs: 25_000),
                                          .init(startMs: 60_000, endMs: 70_000)],
                                 durationUs: 100_000_000, reason: "test")
    let clock = SubtitleAdClock(timeline)
    #expect(clock.ads == [.init(start: 10, end: 25), .init(start: 60, end: 70)])
}

/// 對齊下一句: pressed when the line is heard, it starts now. 對齊上一句 does the same for the line
/// already shown.
@Test func aligningALineMakesItStartNow() throws {
    let cues = SubtitleCues([SubtitleCue(start: 100, end: 102, text: "一"), SubtitleCue(start: 110, end: 112, text: "二")])
    // Programme time 104, no correction: the next line is 110, the previous 100.
    let next = try #require(SubtitleDelay.aligned(cues, contentTime: 104, delay: 0, next: true))
    #expect(next == -6)
    #expect(cues.text(at: 104, delay: next) == "二")
    let previous = try #require(SubtitleDelay.aligned(cues, contentTime: 104, delay: 0, next: false))
    #expect(previous == 4)
    #expect(cues.text(at: 104, delay: previous) == "一")
    #expect(SubtitleDelay.aligned(cues, contentTime: 200, delay: 0, next: true) == nil)
}
