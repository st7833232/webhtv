import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-25. The detector is a port, so the test of it is Android itself: every expected value in
// `androidGoldens` was produced on 2026-09-25 by running Android main's own `HlsAdsParser.java`
// (the Media3 fork's sources jar) and `HlsAdTimeline.java` on JDK 21, with only `TextUtils`, `Log`,
// `C` and `Util.split` stubbed, over the playlists `Corpus` builds below. `input` pins that the
// playlist is byte for byte the one Android saw; `filtered` is the SHA-256 of the playlist Android
// rebuilt (nil where it returned its input); the ranges, duration and reason are
// `HlsAdTimeline.from(input, filtered)`'s. A port that drifts from Android's behaviour fails here.

struct AndroidGolden: Sendable, CustomTestStringConvertible {
    let name: String
    let input: String
    let filtered: String?
    let ranges: [[Int64]]
    let durationUs: Int64
    let reason: String
    var testDescription: String { name }

    init(_ name: String, input: String, filtered: String?, ranges: [[Int64]], durationUs: Int64,
         reason: String) {
        self.name = name
        self.input = input
        self.filtered = filtered
        self.ranges = ranges
        self.durationUs = durationUs
        self.reason = reason
    }
}

let androidGoldens: [AndroidGolden] = [
    AndroidGolden("a-no-ads",
                  input: "ac667c36a7c1b75395dba27066a6293a25228a0c84285319dac88b1111c2865f",
                  filtered: nil,
                  ranges: [], durationUs: 0, reason: "no-ads"),
    AndroidGolden("b-host-ad-middle",
                  input: "d90644e6bae47280a5948af7bed82dafb55e1484930eee34f585499436278638",
                  filtered: "069a0e04ac86cd6d2e3b2b851b1eea77b74da1c98a63673ffaf474c4712bb7d6",
                  ranges: [[120000, 135000]], durationUs: 255000000, reason: "exo-hls-detector"),
    AndroidGolden("c-dir-ad-head",
                  input: "53582018160eaa0f0fffba1acfd1786a9c7c90ee59ab2a37056d65dce0db8a22",
                  filtered: "bb5d98ec24bebfcf024a7688f848317f236e703f9e67980d55d6a014da3c5881",
                  ranges: [[0, 12000]], durationUs: 192000000, reason: "exo-hls-detector"),
    AndroidGolden("d-dir-ad-tail",
                  input: "e34302e227ad4f0610b76445249120f9a592319fbf6c24f955b2bbccfcd3f1a1",
                  filtered: "1da914f08947a7f2d6be06cf605716a5247455228c4193b0eafb5c090e305c40",
                  ranges: [[180000, 190000]], durationUs: 190000000, reason: "exo-hls-detector"),
    AndroidGolden("e-prefix",
                  input: "9623920c4f876320a7b5f48986144cd9006548e86ee9c2236e335226feb204bd",
                  filtered: "5738695b090c874bb24f6b98208f6b85e0610c9c2919663fbbb6353cc5d1cad7",
                  ranges: [[120000, 135000]], durationUs: 255000000, reason: "exo-hls-detector"),
    AndroidGolden("f-disc-mode",
                  input: "33e4b8b62b59a21dfd8544292f06a977fa0751f7eee10f8e31de42256b6c3b49",
                  filtered: "2f945d814dba22e1d404af077f15c0ce739fbc47a258cf78b5756d4366e45250",
                  ranges: [[60000, 70000], [130000, 140000]], durationUs: 260000000, reason: "exo-hls-detector"),
    AndroidGolden("g-disc-too-many",
                  input: "be96efab6d015c134d06fc692c39a26bf0841e99c8c53462cf2b314e45c40281",
                  filtered: nil,
                  ranges: [], durationUs: 0, reason: "no-ads"),
    AndroidGolden("h-disc-fallback",
                  input: "5264098995fee57dc3cee478d95816f99ee78c90ca241fb1b1f5778f42d3e057",
                  filtered: "bc024b048760dc6684a583bccfb9fd3f1a76e57b9608c7fd0c509725cd0bfdc9",
                  ranges: [[0, 48000]], durationUs: 192000000, reason: "exo-hls-detector"),
    AndroidGolden("i-mixed-real-structure",
                  input: "c026d06682375387e4e991e988e37b9d35f3ef801a9da90385a4fc1c35774440",
                  filtered: "52323220ceeed42c4f31dd2f07e7db2c8dcb01bdca8e023c50e95a53350f5fd0",
                  ranges: [[496320, 512786], [2013507, 2031173]], durationUs: 2847879998, reason: "exo-hls-detector-long-blocks-preserved"),
    AndroidGolden("j-repeated-uri",
                  input: "a6a68877b528bb436570643f877af10e8bb54a5699008b1baecc2f6a1d5cf76c",
                  filtered: "22c2d7a771f1dcaaebd3d27db3385d2474e059405fca238f1101a2ce58acda74",
                  ranges: [[4000, 6000]], durationUs: 13000000, reason: "exo-hls-detector"),
    AndroidGolden("k-byterange",
                  input: "5e878e435dd77e443cde4a50b1a8949a172b1f7a8f39d83fb01926d568552177",
                  filtered: "a2979d3791d22a24b6f89311d1601a01385f6c920162cc9b63accd5301e70c89",
                  ranges: [[16000, 19000]], durationUs: 51000000, reason: "exo-hls-detector"),
    AndroidGolden("l-aes-seq37",
                  input: "dea6f0650cea2c8457e57cd5aa6f49903335a1e1c322ea9041db0c9c4aecd0f4",
                  filtered: "a1ed84757713f273a44509ce1f43c79ddcdd5d8cd7f6e8dd3955f79bc2b50f28",
                  ranges: [[90000, 100000]], durationUs: 190000000, reason: "exo-hls-detector"),
    AndroidGolden("m-live-no-endlist",
                  input: "ed3447258107bd48918a1b81e066595f5f069807600b794f4e996a63b2978080",
                  filtered: nil,
                  ranges: [], durationUs: 0, reason: "no-ads"),
    AndroidGolden("n-llhls-parts",
                  input: "ad0fbc7fe50bdd1d82a75c2c37ddf15c42e4c82dd8f1795fc1d324b81fa7ca37",
                  filtered: "e400dbf36d0aeb31e79be43f6051825d765427607cdb7eb4096e1bd6ee19a36d",
                  ranges: [], durationUs: 0, reason: "invalid-or-unchanged-playlist"),
    AndroidGolden("o-crlf",
                  input: "7862157f0ce4c36569cb5dba256be6b268ab068946b550a159dda07a0020b2db",
                  filtered: "069a0e04ac86cd6d2e3b2b851b1eea77b74da1c98a63673ffaf474c4712bb7d6",
                  ranges: [[120000, 135000]], durationUs: 255000000, reason: "exo-hls-detector"),
    AndroidGolden("p-long-ad-121s",
                  input: "915d59de78849c48ca65afcaee5b6897e31306b35be415736e59fd70334dc03e",
                  filtered: "069a0e04ac86cd6d2e3b2b851b1eea77b74da1c98a63673ffaf474c4712bb7d6",
                  ranges: [], durationUs: 361000000, reason: "exo-hls-detector-long-blocks-preserved"),
    AndroidGolden("q-ad-exactly-120s",
                  input: "98992e0d20308f78333a1830c880a0acbd9575fc3b6940bea2bd83b04cd6ea5e",
                  filtered: "069a0e04ac86cd6d2e3b2b851b1eea77b74da1c98a63673ffaf474c4712bb7d6",
                  ranges: [[120000, 240000]], durationUs: 360000000, reason: "exo-hls-detector"),
    AndroidGolden("r-malformed-extinf",
                  input: "ce3e6522480a0d02f9f85ab363f4687efe66d768ec639249935ba055c3cc8684",
                  filtered: "57d5d606ae1937f64f1c7492122e54276ef1d2cb5f37d0a917ac28ca672d1cb3",
                  ranges: [], durationUs: 0, reason: "invalid-or-unchanged-playlist"),
    AndroidGolden("s-master",
                  input: "f75a1a230895882750efba13949a4d6292996ad9421ee71666ffeee9b29851ec",
                  filtered: nil,
                  ranges: [], durationUs: 0, reason: "no-ads"),
    AndroidGolden("t-bom",
                  input: "e8d7526a752651b2fbe27c260f92fc1beaf5cbd95c3ac0483cd3a10af2f35bca",
                  filtered: "6d5905270ff71c7c3a62b6f0d3f138fa21539d1900724b278d99092566b2ca5d",
                  ranges: [], durationUs: 0, reason: "invalid-or-unchanged-playlist"),
    AndroidGolden("u-disc-head-ad",
                  input: "8b2cb406b8900d356846d31b812d9bede7fc8c99a4ac2381f5f2614039097b67",
                  filtered: "08456e7414334b3f125eb049402aa28188a7383186ef3b4fe29f5e7788ed56b9",
                  ranges: [[0, 10000]], durationUs: 190000000, reason: "exo-hls-detector"),
    AndroidGolden("v-adjacent-ads-merge",
                  input: "1b7fb0c45b0f166bbbcd1667dae3f04173e1b0daabbc9abdb971cd9802fdc2e2",
                  filtered: "1bb96cc5843ce4ee262ecf8e0d5c5ff0cc264c9f52c9011ec72ac016ea5dc8bc",
                  ranges: [[0, 25000]], durationUs: 225000000, reason: "exo-hls-detector"),
    AndroidGolden("w-unicode-dirs",
                  input: "ec8c73abac70d6877b3c81459180ceeeaceea6926d89bf95b645fcfa5cdc11b8",
                  filtered: "0d9ac8320d5a257cf7658b9eafa1d815955dffdab2e8efd58032bbb68e02b846",
                  ranges: [[120000, 130000]], durationUs: 250000000, reason: "exo-hls-detector"),
    AndroidGolden("x-astral-prefix",
                  input: "933cb666a15439dee9519700ad02a58981069f7a8fb37d36be47873d67443ef8",
                  filtered: "3fd5f55ab7c2180a69e34aba440032355af8aac412bd29b752fe4667315a9b2c",
                  ranges: [[120000, 135000]], durationUs: 255000000, reason: "exo-hls-detector"),
    AndroidGolden("y-trailing-spaces-tabs",
                  input: "1862471ecd6a11811d453f042cd9b596cae73ddefdff7ed0665f2b0a2ee74143",
                  filtered: "c5aa17803d08f4a11cb65764ad74a787ce63141f21cbd41b7f20784569c24389",
                  ranges: [[120000, 130000]], durationUs: 250000000, reason: "exo-hls-detector"),
    AndroidGolden("z-two-mid-ads-long-video",
                  input: "2501c5c0d48770ee94e41aeec50be9367a5b1435d75791af936051f15723bdd5",
                  filtered: "63936df9f7246fa9e8ebbda5b6a3688dab7132d1a66fd304143d0beac765219f",
                  ranges: [[900000, 915000], [1815000, 1830000]], durationUs: 2730000000, reason: "exo-hls-detector"),
]

/// The playlists, built exactly as the script that fed Android built them.
enum Corpus {
    static let head = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXT-X-MEDIA-SEQUENCE:0\n"
    static let end = "#EXT-X-ENDLIST\n"
    static let disc = "#EXT-X-DISCONTINUITY\n"

    static func seg(_ uri: String, _ duration: String = "6") -> String { "#EXTINF:\(duration),\n\(uri)\n" }
    static func pl(_ parts: String..., head: String = Corpus.head, end: String = Corpus.end) -> String {
        head + parts.joined() + end
    }
    static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
    static func many(_ range: Range<Int>, _ duration: String = "6", _ uri: (Int) -> String) -> String {
        range.map { seg(uri($0), duration) }.joined()
    }
    static func prog(_ range: Range<Int>, _ duration: String = "6") -> String {
        many(range, duration) { "https://cdn.example.com/v/20240101/abc/index\(pad($0, 4)).ts" }
    }
    static func v(_ range: Range<Int>, _ duration: String = "6") -> String {
        many(range, duration) { "v/\(pad($0, 5)).ts" }
    }
    static func ads(_ count: Int, _ name: String = "ad") -> String {
        many(0..<count, "5") { "https://ad.example.net/x/\(name)\($0).ts" }
    }
    static func byteRange(_ offset: Int) -> String { "#EXTINF:4,\n#EXT-X-BYTERANGE:1000@\(offset)\nvideo.mp4\n" }
    static let key = "#EXT-X-KEY:METHOD=AES-128,URI=\"https://cdn.example.com/key.bin\"\n"

    static func mixed() -> String {
        var text = "#EXTM3U\n#EXT-X-TARGETDURATION:8\n"
        var next = 0
        func block(_ count: Int, _ duration: String, _ first: String) {
            text += disc
            for index in 0..<count {
                text += seg("segment\(next).ts", index == 0 ? first : duration)
                next += 1
            }
        }
        func ad(_ durations: String...) {
            text += disc
            for duration in durations {
                text += seg("segment\(next).ts", duration)
                next += 1
            }
        }
        block(124, "4", "4.32"); ad("6.633333", "3.333333", "4.8", "1.7")
        block(375, "4", "4.72"); ad("5.933333", "3.333333", "2.8", "5.3", "0.3")
        block(200, "4", "4.24"); ad("6.633333", "3.333333", "4.8", "1.7")
        return text + end
    }

    static func input(_ name: String) -> String {
        switch name {
        case "a-no-ads": return pl(prog(0..<30))
        case "b-host-ad-middle": return pl(prog(0..<20), disc, ads(3), disc, prog(20..<40))
        case "c-dir-ad-head": return pl(many(0..<3, "4") { "ad/\($0).ts" }, disc, many(0..<30) { "seg/\($0).ts" })
        case "d-dir-ad-tail": return pl(many(0..<30) { "seg/\($0).ts" }, disc, many(0..<2, "5") { "ad/\($0).ts" })
        case "e-prefix":
            return pl(many(0..<20) { "kstream\(pad($0, 6)).ts" }, disc, many(0..<3, "5") { "promo\(pad($0, 6)).ts" },
                      disc, many(20..<40) { "kstream\(pad($0, 6)).ts" })
        case "f-disc-mode":
            return pl(v(0..<10), disc, v(10..<12, "5"), disc, v(12..<22), disc, v(22..<24, "5"), disc,
                      v(24..<34), disc, v(34..<44))
        case "g-disc-too-many":
            return pl(v(0..<10), disc, v(10..<11, "5"), disc, v(11..<21), disc, v(21..<22, "5"), disc,
                      v(22..<32), disc, v(32..<33, "5"), disc, v(33..<43), disc, v(43..<44, "5"), disc,
                      v(44..<54), disc, v(54..<64))
        case "h-disc-fallback": return pl(v(0..<4), disc, v(4..<8), disc, v(8..<20), disc, v(20..<32))
        case "i-mixed-real-structure": return mixed()
        case "j-repeated-uri":
            return pl(seg("same.ts", "2"), seg("same.ts", "2"), disc, seg("https://ad.example.net/a.ts", "2"), disc,
                      seg("same.ts", "2"), seg("tail.ts", "5"))
        case "k-byterange":
            return pl(byteRange(0), byteRange(1000), byteRange(2000), byteRange(3000), disc,
                      "#EXTINF:3,\n#EXT-X-BYTERANGE:500@0\nad.mp4\n", disc,
                      byteRange(4000), byteRange(5000), byteRange(6000), byteRange(7000), disc,
                      byteRange(8000), byteRange(9000), byteRange(10000), byteRange(11000))
        case "l-aes-seq37":
            return pl(key, prog(0..<15), disc, "#EXT-X-KEY:METHOD=NONE\n", ads(2), disc, key, prog(15..<30),
                      head: "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXT-X-MEDIA-SEQUENCE:37\n")
        case "m-live-no-endlist": return pl(prog(0..<10), disc, ads(2), disc, prog(10..<20), end: "")
        case "n-llhls-parts":
            return pl("#EXT-X-PART:DURATION=2,URI=\"p0.0.ts\"\n", prog(0..<10), disc, ads(2), disc, prog(10..<20))
        case "o-crlf":
            return input("b-host-ad-middle").replacingOccurrences(of: "\n", with: "\r\n")
        case "p-long-ad-121s": return pl(prog(0..<20), disc, seg("https://ad.example.net/x/long.ts", "121"), disc, prog(20..<40))
        case "q-ad-exactly-120s": return pl(prog(0..<20), disc, seg("https://ad.example.net/x/long.ts", "120"), disc, prog(20..<40))
        case "r-malformed-extinf":
            return pl(prog(0..<5), seg("https://cdn.example.com/v/20240101/abc/bad.ts", "abc"), prog(5..<20), disc,
                      seg("https://ad.example.net/x/ad.ts", "5"), disc, prog(20..<30))
        case "s-master":
            return "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\nlow/index.m3u8\n"
                + "#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720\nmid/index.m3u8\n"
        case "t-bom": return "\u{FEFF}" + input("b-host-ad-middle")
        case "u-disc-head-ad": return pl(v(0..<2, "5"), disc, v(2..<12), disc, v(12..<22), disc, v(22..<32))
        case "v-adjacent-ads-merge":
            return pl(seg("ad/1.ts", "10"), disc, seg("ad/2.ts", "15"), disc, many(0..<20, "10") { "body/\($0).ts" })
        case "w-unicode-dirs":
            return pl(many(0..<20) { "视频/第01集/\($0).ts" }, disc, many(0..<2, "5") { "广告/\($0).ts" }, disc,
                      many(20..<40) { "视频/第01集/\($0).ts" })
        case "x-astral-prefix":
            return pl(many(0..<20) { "\u{1F3AC}movie\(pad($0, 4)).ts" }, disc, many(0..<3, "5") { "promo\(pad($0, 4)).ts" },
                      disc, many(20..<40) { "\u{1F3AC}movie\(pad($0, 4)).ts" })
        case "y-trailing-spaces-tabs":
            return pl(many(0..<20) { " https://cdn.example.com/v/a/\($0).ts\t" }, disc,
                      many(0..<2, "5") { "https://ad.example.net/x/\($0).ts " }, disc,
                      many(20..<40) { "https://cdn.example.com/v/a/\($0).ts" })
        case "z-two-mid-ads-long-video":
            return pl(prog(0..<150), disc, ads(3, "a"), disc, prog(150..<300), disc, ads(3, "b"), disc, prog(300..<450))
        default: fatalError("no corpus entry \(name)")
        }
    }
}

private func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func units(_ text: String) -> [UInt16] { Array(text.utf16) }

@Test(arguments: androidGoldens)
func theDetectorAndTheMappingDecideExactlyWhatAndroidDecides(_ golden: AndroidGolden) {
    let input = Corpus.input(golden.name)
    #expect(sha256(input) == golden.input, "the corpus drifted from the playlist Android was given")
    let filtered = HLSAdsParser.process(input)
    if let expected = golden.filtered {
        #expect(sha256(filtered) == expected)
    } else {
        #expect(units(filtered) == units(input))
    }
    let timeline = HLSAdTimeline.from(original: input, filtered: filtered)
    #expect(timeline.ranges == golden.ranges.map { HLSAdTimeline.Range(startMs: $0[0], endMs: $0[1]) })
    #expect(timeline.durationUs == golden.durationUs)
    #expect(timeline.reason == golden.reason)
}

// MARK: - What each strategy is for

@Test func aPlaylistWithNoAdsComesBackAsTheSameString() {
    let text = Corpus.input("a-no-ads")
    #expect(units(HLSAdsParser.process(text)) == units(text))
    #expect(HLSAdTimeline.from(original: text, filtered: HLSAdsParser.process(text)) == HLSAdTimeline.none)
}

@Test func aLivePlaylistIsNeverAnalysedEvenWithAnObviousAd() {
    // No #EXT-X-ENDLIST: a playlist that can still grow is not a VOD the ranges could hold for.
    let live = Corpus.input("m-live-no-endlist")
    #expect(units(HLSAdsParser.process(live)) == units(live))
}

@Test func removingAnAdKeepsTheLinesBeforeItsExtinfAndDropsEverythingUpToItsUri() {
    // The key and the discontinuity before the ad's #EXTINF stay (they belong to what follows);
    // the ad's own tags between #EXTINF and its URI go with it. Neither discontinuity is orphaned
    // (each has a non-boundary line on both sides), so both stay — Android's output, checked on
    // the JDK, not assumed.
    let text = Corpus.pl(Corpus.prog(0..<4), Corpus.disc, "#EXT-X-KEY:METHOD=NONE\n",
                         "#EXTINF:5,\n#EXT-X-BYTERANGE:10@0\nhttps://ad.example.net/x/only.ts\n",
                         Corpus.disc, Corpus.prog(4..<8))
    let filtered = HLSAdsParser.process(text)
    #expect(filtered.contains("#EXT-X-KEY:METHOD=NONE"))
    #expect(!filtered.contains("ad.example.net"))
    #expect(!filtered.contains("#EXT-X-BYTERANGE"))
    #expect(filtered.components(separatedBy: "#EXT-X-DISCONTINUITY").count - 1 == 2)
    #expect(HLSAdTimeline.from(original: text, filtered: filtered).ranges == [.init(startMs: 24000, endMs: 29000)])
}

@Test func theLastDiscontinuityBlockIsNeverTakenForAnAd() {
    // The only small block is the last one; Android leaves it out of the analysis entirely.
    let text = Corpus.pl(Corpus.v(0..<10), Corpus.disc, Corpus.v(10..<20), Corpus.disc, Corpus.v(20..<22, "5"))
    #expect(units(HLSAdsParser.process(text)) == units(text))
}

@Test func tooManySmallBlocksForTheRuntimeMeansTheStructureIsNotAds() {
    // Four candidates in a six-minute video exceeds the three a short runtime allows.
    let text = Corpus.input("g-disc-too-many")
    #expect(units(HLSAdsParser.process(text)) == units(text))
}

@Test func linesAreTrimmedTheJavaWayNotTheUnicodeWay() {
    // U+3000 is Unicode whitespace but above U+0020, so Java's trim() keeps it — and so must the
    // port, or two URIs Android tells apart would be merged here.
    #expect(JavaText.trim(units("\t a \u{3000}")) == units("a \u{3000}"))
    #expect(JavaText.trim(units(" \r\n ")).isEmpty)
    #expect(JavaText.lines(units("a\r\nb\r\r\nc\n")) == [units("a"), units("b\r"), units("c"), []])
}

@Test func extinfDurationsParseLikeJavasParseDouble() {
    // Each expectation is what `Double.parseDouble` printed for the same text on JDK 21.
    #expect(JavaText.parseDouble(units(" 6.5 ")) == 6.5)
    #expect(JavaText.parseDouble(units("+5")) == 5)
    #expect(JavaText.parseDouble(units(".5")) == 0.5)
    #expect(JavaText.parseDouble(units("5.")) == 5)
    #expect(JavaText.parseDouble(units("0x1p3")) == 8)
    #expect(JavaText.parseDouble(units("1e400")) == .infinity)
    #expect(JavaText.parseDouble(units("10f")) == 10)
    #expect(JavaText.parseDouble(units("1e1")) == 10)
    #expect(JavaText.parseDouble(units("NaN"))?.isNaN == true)
    #expect(JavaText.parseDouble(units("-Infinity")) == -.infinity)
    #expect(JavaText.parseDouble(units("abc")) == nil)
    #expect(JavaText.parseDouble(units("nan")) == nil)
    #expect(JavaText.parseDouble(units("")) == nil)
}
