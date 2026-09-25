import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-25. Android main's `HlsAdTimelineTest`, `MpvHlsAdblockTest` and the timeline half of
// `MpvHlsAdBoundaryStateTest`, case for case and with Android's own numbers, so the Swift mapping
// is held to exactly the contract the Java one is.

private func playlist(_ entries: String...) -> String {
    "#EXTM3U\n#EXT-X-TARGETDURATION:10\n" + entries.joined() + "#EXT-X-ENDLIST\n"
}

private func segment(_ uri: String, _ duration: String) -> String { "#EXTINF:\(duration),\n\(uri)\n" }

private func middleAd(_ duration: String) -> HLSAdTimeline {
    HLSAdTimeline.from(
        original: playlist(segment("main/0.ts", "4"), segment("ad/0.ts", duration), segment("main/1.ts", "6")),
        filtered: playlist(segment("main/0.ts", "4"), segment("main/1.ts", "6")))
}

private func range(_ start: Int64, _ end: Int64) -> HLSAdTimeline.Range { .init(startMs: start, endMs: end) }

@Test func removedSegmentsUseSourceTimeAndAdjacentAdsMerge() {
    let timeline = HLSAdTimeline.from(
        original: playlist(segment("main/0.ts", "4"), segment("ads/0.ts", "1.2"), segment("ads/1.ts", "2.3"),
                           segment("main/1.ts", "6")),
        filtered: playlist(segment("main/0.ts", "4"), segment("main/1.ts", "6")))
    #expect(timeline.ranges == [range(4000, 7500)])
    #expect(timeline.skipTargetMs(3999) == 3999)
    #expect(timeline.skipTargetMs(4000) == 7500)
    #expect(timeline.skipTargetMs(7499) == 7500)
    #expect(timeline.skipTargetMs(7500) == 7500)
    #expect(timeline.skipTargetMs(12000) == 12000)
}

@Test func leadingAndTrailingAdsKeepDistinctSourceRanges() {
    let timeline = HLSAdTimeline.from(
        original: playlist(segment("ad/start.ts", "2"), segment("main.ts", "9"), segment("ad/end.ts", "3")),
        filtered: playlist(segment("main.ts", "9")))
    #expect(timeline.ranges == [range(0, 2000), range(11000, 14000)])
    #expect(timeline.skipTargetMs(0) == 2000)
    #expect(timeline.skipTargetMs(13000) == 14000)
}

@Test func roundingDoesNotSkipProgrammeAtSubMillisecondBoundaries() {
    let timeline = HLSAdTimeline.from(
        original: playlist(segment("main/0", "1.000001"), segment("ad", "0.003998"), segment("main/1", "1")),
        filtered: playlist(segment("main/0", "1.000001"), segment("main/1", "1")))
    #expect(timeline.ranges == [range(1001, 1003)])
    #expect(timeline.skipTargetMs(1000) == 1000)
    #expect(timeline.skipTargetMs(1001) == 1003)
}

@Test func rejectsAmbiguousDuplicateOccurrences() {
    let timeline = HLSAdTimeline.from(
        original: playlist(segment("same.ts", "2"), segment("same.ts", "2"), segment("tail.ts", "5")),
        filtered: playlist(segment("same.ts", "2"), segment("tail.ts", "5")))
    #expect(timeline.ranges.isEmpty)
    #expect(timeline.reason == "ambiguous-segments")
}

@Test func repeatedRetainedSegmentsCanStillHaveAnUnambiguousMapping() {
    let timeline = HLSAdTimeline.from(
        original: playlist(segment("same.ts", "2"), segment("same.ts", "2"), segment("ads.ts", "1"),
                           segment("tail.ts", "5")),
        filtered: playlist(segment("same.ts", "2"), segment("same.ts", "2"), segment("tail.ts", "5")))
    #expect(timeline.ranges == [range(4000, 5000)])
}

@Test func byteRangeIdentitySeparatesSegmentsUsingTheSameUrl() {
    let first = "#EXTINF:2,\n#EXT-X-BYTERANGE:100@0\nvideo.mp4\n"
    let ad = "#EXTINF:2,\n#EXT-X-BYTERANGE:100@100\nvideo.mp4\n"
    let last = "#EXTINF:2,\n#EXT-X-BYTERANGE:100@200\nvideo.mp4\n"
    let timeline = HLSAdTimeline.from(original: playlist(first, ad, last), filtered: playlist(first, last))
    #expect(timeline.ranges == [range(2000, 4000)])
}

@Test func keyRotationAndDiscontinuityMetadataDoNotChangeSourcePositions() {
    let first = segment("body/0.ts", "4")
    let last = segment("body/1.ts", "6")
    let key = "#EXT-X-MEDIA-SEQUENCE:37\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n"
    let timeline = HLSAdTimeline.from(
        original: playlist(key, first, "#EXT-X-DISCONTINUITY\n", segment("ad/0.ts", "2"),
                           "#EXT-X-KEY:METHOD=NONE\n", last),
        filtered: playlist(key, first, "#EXT-X-KEY:METHOD=NONE\n", last))
    #expect(timeline.ranges == [range(4000, 6000)])
}

@Test func longFalsePositiveBeforeAndAfterAnAdRemainsSeekable() {
    let tail = segment("retained.ts", "900")
    let timeline = HLSAdTimeline.from(
        original: playlist(segment("programme-before.ts", "496.32"), "#EXT-X-DISCONTINUITY\n",
                           segment("ad.ts", "16.466666"), "#EXT-X-DISCONTINUITY\n",
                           segment("programme-after.ts", "800"), tail),
        filtered: playlist(tail))
    #expect(timeline.ranges == [range(496320, 512786)])
    #expect(timeline.skipTargetMs(0) == 0)
    #expect(timeline.skipTargetMs(490000) == 490000)
    #expect(timeline.skipTargetMs(500000) == 512786)
    #expect(timeline.skipTargetMs(700000) == 700000)
}

@Test func uninterruptedLongCandidateIsPreservedAndLimitIsInclusive() {
    let kept = segment("body.ts", "1000")
    #expect(HLSAdTimeline.from(original: playlist(segment("uncertain.ts", "120.000001"), kept),
                               filtered: playlist(kept)).ranges.isEmpty)
    #expect(HLSAdTimeline.from(original: playlist(segment("ad.ts", "120"), kept),
                               filtered: playlist(kept)).ranges == [range(0, 120000)])
}

@Test func acceptedAdjacentDiscontinuityBlocksStillMerge() {
    let kept = segment("body.ts", "1000")
    let timeline = HLSAdTimeline.from(
        original: playlist(segment("ad-1.ts", "10"), "#EXT-X-DISCONTINUITY\n", segment("ad-2.ts", "15"), kept),
        filtered: playlist(kept))
    #expect(timeline.ranges == [range(0, 25000)])
}

@Test func rejectsLiveMalformedNonFiniteAndOverflowingDurations() {
    let filtered = playlist(segment("body.ts", "5"))
    for duration in ["NaN", "Infinity", "-1", "0", "1e100", "1e1000000000", "1e-1000000000"] {
        #expect(HLSAdTimeline.from(original: playlist(segment("bad.ts", duration), segment("body.ts", "5")),
                                   filtered: filtered).ranges.isEmpty, "duration \(duration)")
    }
    let original = playlist(segment("ad.ts", "2"), segment("body.ts", "5"))
    #expect(HLSAdTimeline.from(original: original.replacingOccurrences(of: "#EXT-X-ENDLIST", with: ""),
                               filtered: filtered).ranges.isEmpty)
    #expect(HLSAdTimeline.from(original: original, filtered: "#EXTM3U\n#EXT-X-ENDLIST\n").ranges.isEmpty)
    #expect(HLSAdTimeline.from(original: original, filtered: nil).ranges.isEmpty)
    #expect(HLSAdTimeline.from(original: nil, filtered: filtered).ranges.isEmpty)
}

@Test func rejectsReorderingOrChangingRetainedMedia() {
    let a = segment("a.ts", "3")
    let b = segment("b.ts", "4")
    let original = playlist(a, segment("ad.ts", "1"), b)
    #expect(HLSAdTimeline.from(original: original, filtered: playlist(b, a)).ranges.isEmpty)
    #expect(HLSAdTimeline.from(original: original, filtered: playlist(segment("a.ts", "2"), b)).ranges.isEmpty)
    #expect(HLSAdTimeline.from(original: original, filtered: original).ranges.isEmpty)
}

@Test func stalePositionsCannotRepeatSeekAndManualOrMediaResetAllowsReplay() {
    let timeline = middleAd("2")
    var state = HLSAdTimeline.SkipState()
    #expect(state.nextTargetMs(timeline, 3999) == nil)
    #expect(state.nextTargetMs(timeline, 4000) == 6000)
    #expect(state.nextTargetMs(timeline, 4200) == nil)
    #expect(state.nextTargetMs(middleAd("2"), 4500) == nil)
    #expect(state.nextTargetMs(timeline, 6000) == nil)
    state.clear()
    #expect(state.nextTargetMs(timeline, 5000) == 6000)
    #expect(state.nextTargetMs(.none, 5000) == nil)
}

@Test func nextBoundaryFollowsSourceTimeInBothSeekDirections() {
    let timeline = middleAd("2")
    #expect(timeline.nextRange(0) == range(4000, 6000))
    #expect(timeline.nextRange(4000) == range(4000, 6000))
    #expect(timeline.nextRange(6000) == nil)
    #expect(timeline.nextRange(1000) == range(4000, 6000))
    #expect(HLSAdTimeline.none.nextRange(1000) == nil)
}

/// Android's frozen detector omissions for the reported `mixed.m3u8`: the mapping, not the
/// detector, must keep the long programme blocks the detector wrongly dropped.
@Test func unequalProgrammeBlocksDoNotBecomeUnseekable() {
    var source = "#EXTM3U\n#EXT-X-TARGETDURATION:8\n"
    var next = 0
    func appendBlock(_ count: Int, _ duration: String, _ first: String) {
        source += "#EXT-X-DISCONTINUITY\n"
        for index in 0..<count {
            source += segment("segment\(next).ts", index == 0 ? first : duration)
            next += 1
        }
    }
    func appendAd(_ durations: String...) {
        source += "#EXT-X-DISCONTINUITY\n"
        for duration in durations {
            source += segment("segment\(next).ts", duration)
            next += 1
        }
    }
    appendBlock(124, "4", "4.32")
    appendAd("6.633333", "3.333333", "4.8", "1.7")
    let retainedStart = source.utf16.count
    appendBlock(375, "4", "4.72")
    let retainedEnd = source.utf16.count
    appendAd("5.933333", "3.333333", "2.8", "5.3", "0.3")
    appendBlock(200, "4", "4.24")
    let finalBlockStart = source.utf16.count
    appendAd("6.633333", "3.333333", "4.8", "1.7")
    source += "#EXT-X-ENDLIST\n"
    let text = Array(source.utf16)
    let filtered = "#EXTM3U\n" + String(decoding: text[retainedStart..<retainedEnd], as: UTF16.self)
        + String(decoding: text[finalBlockStart...], as: UTF16.self)
    let timeline = HLSAdTimeline.from(original: source, filtered: filtered)
    #expect(timeline.ranges == [range(496320, 512786), range(2013507, 2031173)])
    for position: Int64 in [0, 9000, 490000, 600000, 2300000] {
        #expect(timeline.skipTargetMs(position) == position)
    }
    #expect(timeline.skipTargetMs(500000) == 512786)
    #expect(timeline.skipTargetMs(2020000) == 2031173)
}

// MARK: - Variants (`MpvHlsAdblockTest`)

private let low = HLSAdTimeline.Variant(bandwidth: 1_000_000, averageBandwidth: 900_000, width: 640, height: 360)
private let high = HLSAdTimeline.Variant(bandwidth: 4_000_000, averageBandwidth: 3_500_000, width: 1920, height: 1080)

@Test func directMediaPlaylistDoesNotNeedNativeVariantMetadata() {
    let direct = middleAd("2")
    #expect(HLSAdTimeline.resolve(direct: direct, variants: [:], selectedBitsPerSecond: 0,
                                  declaredVariantCount: 0) == direct)
}

@Test func selectedPeakOrAverageBitrateChoosesItsOwnPlan() {
    let lowPlan = middleAd("2")
    let highPlan = middleAd("4")
    let plans = [low: lowPlan, high: highPlan]
    #expect(HLSAdTimeline.resolve(direct: nil, variants: plans, selectedBitsPerSecond: 1_000_000,
                                  declaredVariantCount: 2) == lowPlan)
    #expect(HLSAdTimeline.resolve(direct: nil, variants: plans, selectedBitsPerSecond: 3_500_000,
                                  declaredVariantCount: 2) == highPlan)
    #expect(HLSAdTimeline.resolve(direct: nil, variants: plans, selectedBitsPerSecond: 2_000_000,
                                  declaredVariantCount: 2).ranges.isEmpty)
}

@Test func unknownSelectionRequiresEveryDeclaredVariantToAgree() {
    let plan = middleAd("2")
    #expect(HLSAdTimeline.resolve(direct: nil, variants: [low: plan], selectedBitsPerSecond: 0,
                                  declaredVariantCount: 2).ranges.isEmpty)
    #expect(HLSAdTimeline.resolve(direct: nil, variants: [low: plan, high: plan], selectedBitsPerSecond: 0,
                                  declaredVariantCount: 2) == plan)
    #expect(HLSAdTimeline.resolve(direct: nil, variants: [low: plan, high: .none], selectedBitsPerSecond: 0,
                                  declaredVariantCount: 2).ranges.isEmpty)
}

@Test func matchingBitratesWithConflictingPlansNeverGuess() {
    let alternate = HLSAdTimeline.Variant(bandwidth: 1_000_000, averageBandwidth: 900_000, width: 960, height: 540)
    #expect(HLSAdTimeline.resolve(direct: nil, variants: [low: middleAd("2"), alternate: middleAd("4")],
                                  selectedBitsPerSecond: 1_000_000, declaredVariantCount: 2).ranges.isEmpty)
}

@Test func imageOrIframePlaylistCannotSupplyTheVideoAdPlan() {
    let iframe = HLSAdTimeline.Variant(bandwidth: 1_000_000, averageBandwidth: 900_000, width: 640, height: 360,
                                       kind: .iFrame)
    #expect(HLSAdTimeline.resolve(direct: nil, variants: [iframe: middleAd("2")], selectedBitsPerSecond: 1_000_000,
                                  declaredVariantCount: 1).ranges.isEmpty)
}

@Test func theDeclaredCountIsOneRegularVariantPerPositiveBitrate() {
    // `buildVariantLadder`: an I-frame playlist, a zero bitrate and a second entry at the same
    // bitrate add nothing — so two same-bitrate entries with plans can never both be "every
    // declared variant", and the resolver refuses them.
    let sameBitrate = HLSAdTimeline.Variant(bandwidth: 1_000_000, averageBandwidth: 0, width: 960, height: 540)
    let zero = HLSAdTimeline.Variant(bandwidth: 0, averageBandwidth: 0, width: 0, height: 0)
    let averageOnly = HLSAdTimeline.Variant(bandwidth: 0, averageBandwidth: 700_000, width: 0, height: 0)
    let iframe = HLSAdTimeline.Variant(bandwidth: 200_000, averageBandwidth: 0, width: 0, height: 0, kind: .iFrame)
    #expect(HLSAdTimeline.declaredVariantCount([low, high, sameBitrate, zero, averageOnly, iframe]) == 3)
    let plan = middleAd("2")
    #expect(HLSAdTimeline.resolve(direct: nil, variants: [low: plan, sameBitrate: plan], selectedBitsPerSecond: 0,
                                  declaredVariantCount: HLSAdTimeline.declaredVariantCount([low, sameBitrate]))
        .ranges.isEmpty)
}

// MARK: - The duration parse (`new BigDecimal(value)` and `HALF_UP` to microseconds)

@Test func extinfDurationsBecomeMicrosecondsExactlyAsBigDecimalRoundsThem() {
    func micros(_ text: String) -> Int64? { JavaBigDecimal.microseconds(Array(text.utf16)) }
    #expect(micros("4.32") == 4_320_000)
    #expect(micros("16.466666") == 16_466_666)
    #expect(micros("0.0000005") == 1)          // .5 µs rounds half up
    #expect(micros("0.0000004") == 0)          // and below half down (then rejected as <= 0)
    #expect(micros("1.0000015") == 1_000_002)
    #expect(micros("+2") == 2_000_000)
    #expect(micros("2.") == 2_000_000)
    #expect(micros(".5") == 500_000)
    #expect(micros("1E1") == 10_000_000)
    #expect(micros("1e-3") == 1000)
    #expect(micros("1e13") == nil)             // scale −13 is outside −12…18
    #expect(micros("1e12") == 1_000_000_000_000_000_000)
    #expect(micros("9223372036854.775808") == nil)   // one past Long.MAX_VALUE microseconds
    #expect(micros("-0") == nil)
    #expect(micros("1.2.3") == nil)
    #expect(micros(".") == nil)
    #expect(micros("1e") == nil)
    #expect(micros(" 1") == nil)
    #expect(micros("١") == nil)                // Java would read other Unicode digits; iOS refuses
}
