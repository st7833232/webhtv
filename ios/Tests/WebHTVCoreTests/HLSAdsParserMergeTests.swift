import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// W-235 — the one place the iOS detector deliberately differs from Android's `HlsAdsParser`.
// Some CDNs split one ad break across two discontinuities. A video over 90 minutes with four such
// breaks shows eight small blocks, more than the six Android allows, so Android (and the port before
// W-235) skips nothing at all. iOS now counts a run of exactly two adjacent small blocks lasting
// 60 s or less as one break. Every other case must still decide exactly what Android decides: the
// 26 `androidGoldens` in HLSAdsParserTests.swift stay unchanged and keep running.

private enum Split {
    /// Segment names carry no path or numbering, so only the discontinuity analysis can decide.
    static func name(_ index: Int) -> String {
        SHA256.hash(data: Data("w235-\(index)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined() + ".ts"
    }

    /// Blocks as (segment count, seconds); each block's seconds are spread evenly over its segments.
    static func playlist(_ blocks: [(Int, Double)]) -> String {
        var body = ""
        var index = 0
        for (number, (count, seconds)) in blocks.enumerated() {
            if number > 0 { body += Corpus.disc }
            for _ in 0..<count {
                body += Corpus.seg(name(index), String(format: "%.3f", seconds / Double(count)))
                index += 1
            }
        }
        return Corpus.pl(body)
    }

    /// "count/seconds" pairs separated by white space — the real block layout, anonymised.
    static func blocks(_ layout: String) -> [(Int, Double)] {
        layout.split(whereSeparator: \.isWhitespace).map { pair in
            let parts = pair.split(separator: "/")
            return (Int(parts[0])!, Double(parts[1])!)
        }
    }

    static func film(_ count: Int) -> [(Int, Double)] { Array(repeating: (50, 300), count: count) }

    static func skippedSeconds(_ timeline: HLSAdTimeline) -> Double {
        Double(timeline.ranges.reduce(Int64(0)) { $0 + $1.endMs - $1.startMs }) / 1000
    }

    /// W-233's root-cause video (FF line, 122.7 min): four ad breaks, each split in two.
    static let rootCause = """
        5/20.019 5/21.056 5/20.554 5/20.221 5/20.721 5/17.985 5/20.955 5/20.454 10/38.106 5/20.688
        10/40.809 5/19.354 5/19.821 5/20.188 5/20.454 4/15.283 3/14.567 2/5.067 5/21.922 5/19.120
        5/18.919 5/20.088 5/22.322 5/18.553 5/19.254 5/19.821 5/19.987 5/19.621 5/20.321 5/22.523
        5/19.220 5/18.320 5/20.887 5/18.653 5/21.221 5/18.953 5/21.222 5/21.455 5/20.120 5/17.017
        5/21.521 5/19.953 5/19.687 5/19.087 5/19.787 5/20.688 5/19.652 5/21.889 5/18.420 10/42.108
        5/17.284 5/19.953 5/20.989 5/20.154 15/59.827 5/20.387 20/81.252 5/20.153 10/38.171 5/21.088
        5/18.819 5/19.486 5/20.220 5/22.321 10/39.107 5/18.519 5/19.854 15/61.030 5/21.755 5/17.752
        5/20.488 5/21.655 5/16.817 5/21.555 1/6.960 3/10.400 5/19.587 5/20.887 5/19.253 5/19.354
        5/21.255 5/20.221 5/19.786 5/21.255 5/19.554 5/19.087 5/19.987 5/21.455 5/19.854 5/17.852
        5/19.320 5/22.022 5/19.753 5/20.187 5/18.719 5/22.222 5/19.854 5/19.587 5/20.055 5/18.887
        5/20.588 5/19.421 5/21.488 5/20.020 5/18.018 5/19.921 5/19.520 5/20.187 5/21.189 5/20.021
        5/18.219 5/22.289 5/18.052 5/20.755 5/21.421 5/19.787 5/20.021 5/19.253 10/39.039 5/19.353
        5/22.324 5/17.885 5/20.553 5/21.823 5/18.653 25/99.738 5/19.821 5/19.287 10/40.040 5/21.055
        5/22.022 50/197.136 5/21.055 10/39.507 5/21.622 10/40.042 5/19.686 5/18.452 15/61.863
        5/20.021 10/39.541 5/19.520 5/20.087 5/19.020 5/21.756 10/39.976 5/20.654 5/19.354 15/59.527
        3/14.567 2/5.067 5/18.953 5/19.621 5/20.321 5/19.819 5/19.219 5/22.656 5/17.517 5/20.888
        5/19.954 5/19.754 5/21.756 5/20.287 5/20.154 5/17.452 5/21.689 5/19.253 5/21.855 5/19.486
        5/19.787 5/19.853 5/20.687 5/18.319 5/18.686 5/20.288 5/21.355 5/20.021 5/19.754 5/19.554
        5/20.153 10/39.038 5/21.354 20/80.116 5/19.487 5/19.187 5/20.021 5/20.922 10/40.041 5/21.589
        5/19.620 10/39.508 5/18.753 30/120.559 5/21.156 5/19.921 5/19.421 5/19.153 5/21.122
        15/58.662 5/20.021 5/19.954 5/20.754 5/20.020 5/18.786 5/20.454 5/20.588 20/80.214 5/19.952
        10/38.840 5/20.588 5/19.954 5/21.222 5/19.521 5/19.287 5/19.620 5/21.388 5/20.021 5/20.021
        10/40.941 5/19.855 5/17.251 5/21.087 5/20.288 5/21.522 5/20.087 5/18.720 5/20.854 15/59.095
        5/21.188 5/18.954 5/19.820 5/20.122 5/20.021 5/19.287 5/21.022 5/19.754 2/10.960 2/6.400
        30/119.959 5/19.486 5/20.321 5/20.354 5/19.153 20/79.617 5/19.553 5/21.722 5/19.987 5/18.052
        5/21.422 5/18.753 5/20.920 5/20.555 10/39.239 5/19.487 5/20.021 5/20.021 25/100.235 5/21.189
        5/18.219 20/82.048 5/20.922 5/18.720 5/19.587 5/21.956 5/19.687 5/18.453 5/19.120 5/19.787
        5/20.154 5/19.987 5/21.255 5/19.754 15/61.196 5/19.820 10/38.306 5/19.954 5/20.787 5/21.722
        5/19.421 5/20.021 10/38.907 5/20.021 5/20.854 10/38.974 5/19.888 5/20.154 5/19.220 5/19.787
        5/20.788 5/19.487 5/19.588 5/21.923 5/18.520 5/21.689 5/20.187 5/17.452 3/11.879
"""

    /// The 蓝光 line's 141.2-minute sample: the same split, four breaks of 69.7 s in all.
    static let longest = """
        5/21.542 5/20.042 5/18.416 5/21.667 5/22.084 5/20.835 5/20.835 5/20.835 5/17.543 5/18.416
        10/38.291 5/19.501 9/37.083 3/14.200 2/4.866 5/20.293 5/19.624 5/20.500 5/22.125 5/17.417
        5/20.042 5/18.917 5/22.042 5/19.832 5/20.125 5/21.125 5/17.875 5/19.000 5/21.292 5/21.251
        15/60.419 5/18.458 5/20.999 5/19.334 5/20.250 5/18.125 5/21.542 5/18.668 5/19.709 5/22.334
        5/17.625 15/64.167 5/18.459 10/38.875 5/19.543 5/20.460 5/19.042 5/20.541 5/21.875 5/17.626
        5/22.709 5/17.250 5/21.543 20/78.211 5/20.708 5/19.500 5/21.501 5/19.208 15/59.626 5/20.667
        5/19.500 5/19.917 5/20.499 5/22.084 5/19.001 1/6.667 3/9.099 5/18.542 5/19.750 5/21.041
        5/22.000 5/18.251 5/20.625 5/18.542 5/18.918 5/20.501 5/19.375 5/20.542 5/21.791 5/18.709
        5/18.916 5/20.624 5/22.709 5/19.667 15/57.252 5/20.166 5/19.917 5/20.792 5/22.042 5/18.249
        5/21.584 5/18.500 5/19.501 5/19.000 5/23.042 5/17.209 5/20.250 5/21.751 5/19.499 5/21.792
        5/18.084 5/19.709 5/20.292 5/18.750 10/42.207 5/18.417 5/22.416 5/18.084 5/19.000 20/82.001
        5/17.959 5/23.417 5/16.125 5/20.375 5/21.083 5/21.041 5/20.501 5/18.375 5/19.458 5/19.750
        5/21.791 10/38.750 5/19.292 5/19.708 5/20.833 20/82.046 5/17.251 5/20.376 5/19.500 5/22.001
        5/19.875 15/61.376 5/18.125 5/18.667 5/23.208 5/20.126 5/19.375 5/17.875 5/20.167 5/20.835
        5/20.835 5/20.835 5/20.835 5/20.835 20/78.421 5/18.416 5/21.709 5/17.375 5/19.000 5/22.000
        5/19.500 10/40.000 5/19.000 10/39.875 5/21.417 5/20.208 5/19.209 5/20.917 3/14.200 2/4.866
        5/18.375 5/20.500 5/19.208 5/20.041 5/22.458 5/19.667 5/21.250 5/16.542 5/19.833 5/20.085
        5/20.625 5/19.291 5/21.125 5/19.375 5/20.625 5/20.708 5/20.501 5/18.583 10/41.334 5/20.084
        5/19.626 5/19.500 5/19.376 5/20.041 5/20.750 5/19.959 5/19.333 5/19.458 5/20.958 5/19.667
        5/21.833 5/19.792 10/38.291 5/21.584 10/40.877 5/18.541 10/38.417 5/21.375 40/158.835
        5/20.583 5/20.835 10/41.378 5/20.168 5/20.835 5/18.000 50/200.963 5/19.584 5/18.334
        15/60.002 5/21.875 5/20.626 10/36.417 5/20.916 5/21.125 5/18.667 5/22.000 10/38.876 5/19.292
        5/20.333 5/19.000 5/20.500 5/20.000 1/6.667 3/9.099 5/20.167 5/21.459 5/20.251 5/18.500
        5/19.209 5/19.917 5/20.500 15/59.626 5/20.250 35/139.754 5/21.499 5/18.542 5/21.875
        10/39.500 5/19.750 10/39.707 5/20.708 5/18.250 5/20.126 5/21.876 5/20.084 5/19.459 5/18.207
        5/20.333 5/19.958 5/20.542 10/41.374 5/18.167 5/20.125 5/20.126 5/19.875 5/19.959 5/23.500
        5/17.668 5/20.499 10/38.793 5/20.041 15/63.292 5/15.792 5/20.125 15/61.375 5/18.999 5/20.459
        5/19.750 5/19.333 5/22.001 5/19.542 5/18.542 5/20.625 5/21.668 10/37.584 5/20.249 5/21.125
        5/19.708 20/79.165 5/20.000 5/20.000 5/20.000 5/23.835 5/17.584 5/18.667 5/19.876 5/19.792
        5/22.251 5/18.542 5/19.875 15/63.375 5/16.875 5/19.834 5/20.500 5/19.000 5/22.501 5/17.292
        5/21.709 5/19.208 5/19.084 5/22.001 5/21.209 10/39.084 5/18.083 5/20.334 5/21.833 5/17.667
        5/22.168 5/17.917 15/61.083 5/18.960 5/21.626 5/20.835 5/19.459 5/19.792 5/18.458 5/20.835
        5/19.876 5/21.293 5/18.668 5/19.668 10/39.170 5/22.043 10/39.167 5/20.334 5/18.667 5/21.208
        5/22.542 15/57.959 5/19.042 5/20.835 5/19.917 5/19.000 10/40.460 5/20.585 5/19.917 5/22.083
        5/16.501 5/21.834 5/20.626 5/18.916 5/19.499 5/19.499 5/19.499 2/7.416
"""
}

private func timeline(_ blocks: [(Int, Double)]) -> HLSAdTimeline {
    let text = Split.playlist(blocks)
    return HLSAdTimeline.from(original: text, filtered: HLSAdsParser.process(text))
}

@Test func fourBreaksEachSplitInTwoAreSkippedInALongVideo() {
    var blocks: [(Int, Double)] = []
    for _ in 0..<4 { blocks += Split.film(5); blocks += [(3, 9.9), (2, 8)] }
    let result = timeline(blocks + Split.film(2))
    #expect(result.reason == "exo-hls-detector")
    #expect(result.ranges.count == 4)
    #expect(abs(Split.skippedSeconds(result) - 4 * 17.9) < 0.01)
}

@Test(arguments: [60.0, 5.0])
func aLongRunOfShortBlocksIsStillCountedBlockByBlock(_ blockSeconds: Double) {
    // Ten adjacent short blocks. Merged, the run would be one "break" and up to ten minutes of
    // programme would be skipped.
    let short: (Int, Double) = (blockSeconds >= 10 ? 10 : 1, blockSeconds)
    let blocks: [(Int, Double)] = Split.film(10) + Array(repeating: short, count: 10) + Split.film(10)
    #expect(timeline(blocks).ranges.isEmpty)
}

@Test func sevenScatteredShortBlocksStayOverTheLimitAsOnAndroid() {
    var blocks: [(Int, Double)] = []
    for _ in 0..<7 { blocks += Split.film(3); blocks.append((3, 9.9)) }
    #expect(timeline(blocks + Split.film(2)).ranges.isEmpty)
}

@Test func aTwoBlockRunLongerThanSixtySecondsIsNotMerged() {
    var blocks: [(Int, Double)] = []
    for _ in 0..<4 { blocks += Split.film(5); blocks += [(6, 36), (6, 36)] }
    #expect(timeline(blocks + Split.film(2)).ranges.isEmpty)
}

@Test func aThreeBlockRunIsNotMerged() {
    var blocks: [(Int, Double)] = []
    for _ in 0..<3 { blocks += Split.film(6); blocks += [(3, 9.9), (3, 9.9), (3, 9.9)] }
    #expect(timeline(blocks + Split.film(2)).ranges.isEmpty)
}

@Test(arguments: [0, 1])
func realSplitLayoutsSkipExactlyTheirFourBreaks(_ sample: Int) {
    // Android: eight small blocks > six, so nothing is skipped. iOS: four breaks, and nothing else.
    let layout = sample == 0 ? Split.rootCause : Split.longest
    let adSeconds = sample == 0 ? 74.0 : 69.7
    let result = timeline(Split.blocks(layout))
    #expect(result.reason == "exo-hls-detector")
    #expect(result.ranges.count == 4)
    #expect(abs(Split.skippedSeconds(result) - adSeconds) < 0.1)
}
