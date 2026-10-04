import Foundation
import Testing
@testable import WebHTVCore

/// IOS-POC-47: Smart Download Selection. Each test names the rule it protects: offline copies never
/// exceed 1080p, and within that the smallest copy that still looks like what it claims to be.
struct OfflineSelectionTests {
    private func master(_ variants: [String], extra: [String] = []) throws -> HLSMasterPlaylist {
        guard case .master(let master) = try HLSPlaylist.parse(Fixture.masterText(extra + variants), base: Fixture.master)
        else { throw HLSPlaylist.ParseError.notAPlaylist }
        return master
    }

    private func chosen(_ master: HLSMasterPlaylist, _ mode: OfflineQualityMode, highFPS: Bool = false) -> HLSVariant? {
        OfflineMediaSelector.chooseVideo(from: master, mode: mode, allowHighFrameRate: highFPS)?.variant
    }

    // 1. A 4K source must never be downloaded, in any mode — it is the size cap the user set.
    @Test func neverChoosesAbove1080pInAnyMode() throws {
        let playlist = try master([
            Fixture.variant(3840, 2160, bandwidth: 20_000_000, uri: "2160.m3u8"),
            Fixture.variant(2560, 1440, bandwidth: 12_000_000, uri: "1440.m3u8"),
            Fixture.variant(1920, 1080, bandwidth: 6_000_000, uri: "1080.m3u8"),
            Fixture.variant(1280, 720, bandwidth: 3_000_000, uri: "720.m3u8"),
        ])
        for mode in OfflineQualityMode.allCases {
            let height = chosen(playlist, mode)?.height ?? 0
            #expect(height <= 1080, "\(mode) chose \(height)p")
        }
        #expect(chosen(playlist, .high)?.height == 1080)
        #expect(chosen(playlist, .smart)?.height == 1080)
    }

    // 2. At the same resolution HEVC is about half the size of H.264 for the same picture.
    @Test func prefersHEVCOverH264AtTheSameResolution() throws {
        let playlist = try master([
            Fixture.variant(1920, 1080, codecs: "avc1.640028,mp4a.40.2", bandwidth: 5_000_000, average: 4_000_000, uri: "avc.m3u8"),
            Fixture.variant(1920, 1080, codecs: "hvc1.2.4.L123.B0,mp4a.40.2", bandwidth: 5_500_000, average: 4_500_000, uri: "hevc.m3u8"),
        ])
        #expect(chosen(playlist, .smart)?.codec == .hevc)
        #expect(chosen(playlist, .high)?.codec == .hevc)
    }

    // 3. "1080p" does not mean the most expensive 1080p: smart takes the cheapest reasonable one.
    @Test func smartTakesTheLowestReasonableAverageBitrate() throws {
        let playlist = try master([
            Fixture.variant(1920, 1080, codecs: "hvc1.1.6.L120.90", bandwidth: 9_000_000, average: 7_000_000, uri: "high.m3u8"),
            Fixture.variant(1920, 1080, codecs: "hvc1.1.6.L120.90", bandwidth: 4_000_000, average: 2_500_000, uri: "mid.m3u8"),
            // Below the floor for a 1080p HEVC picture: a starved copy, not a bargain.
            Fixture.variant(1920, 1080, codecs: "hvc1.1.6.L120.90", bandwidth: 600_000, average: 500_000, uri: "starved.m3u8"),
        ])
        #expect(chosen(playlist, .smart)?.uri.lastPathComponent == "mid.m3u8")
        #expect(chosen(playlist, .high)?.uri.lastPathComponent == "high.m3u8")
        #expect(chosen(playlist, .saver) == nil || chosen(playlist, .saver)!.height! <= 720)
    }

    // 4. 最省空間 stops at 720p even when 1080p exists.
    @Test func saverModeStopsAt720p() throws {
        let playlist = try master([
            Fixture.variant(1920, 1080, codecs: "hvc1.1.6.L120.90", bandwidth: 5_000_000, uri: "1080.m3u8"),
            Fixture.variant(1280, 720, codecs: "avc1.64001f", bandwidth: 2_500_000, uri: "720-avc.m3u8"),
            Fixture.variant(1280, 720, codecs: "hvc1.1.6.L93.90", bandwidth: 1_500_000, uri: "720-hevc.m3u8"),
            Fixture.variant(854, 480, codecs: "avc1.64001e", bandwidth: 900_000, uri: "480.m3u8"),
        ])
        let pick = try #require(chosen(playlist, .saver))
        #expect(pick.height == 720)
        #expect(pick.codec == .hevc)
    }

    // 5. Without a 1080p copy the best one under it is taken — not the 4K one above it.
    @Test func withoutA1080pCopyTakesTheHighestBelow() throws {
        let playlist = try master([
            Fixture.variant(3840, 2160, bandwidth: 20_000_000, uri: "2160.m3u8"),
            Fixture.variant(1280, 720, bandwidth: 3_000_000, uri: "720.m3u8"),
            Fixture.variant(854, 480, bandwidth: 1_000_000, uri: "480.m3u8"),
        ])
        #expect(chosen(playlist, .smart)?.height == 720)
        #expect(chosen(playlist, .high)?.height == 720)
    }

    // 6. HDR costs space and needs an HDR screen to look right: SDR first.
    @Test func smartPrefersSDROverHDR() throws {
        let playlist = try master([
            Fixture.variant(1920, 1080, codecs: "dvh1.05.06", bandwidth: 6_000_000, range: "PQ", uri: "dv.m3u8"),
            Fixture.variant(1920, 1080, codecs: "hvc1.2.4.L123.B0", bandwidth: 6_000_000, range: "PQ", uri: "hdr10.m3u8"),
            Fixture.variant(1920, 1080, codecs: "hvc1.1.6.L120.90", bandwidth: 4_000_000, range: "SDR", uri: "sdr.m3u8"),
        ])
        let choice = try #require(OfflineMediaSelector.chooseVideo(from: playlist, mode: .smart))
        #expect(choice.variant.dynamicRange == .sdr)
        #expect(!choice.hdrOnly)
    }

    @Test func hdrIsChosenOnlyWhenNothingElseFitsAndSaysSo() throws {
        let playlist = try master([
            Fixture.variant(1920, 1080, codecs: "hvc1.2.4.L123.B0", bandwidth: 6_000_000, range: "PQ", uri: "hdr10.m3u8"),
        ])
        let choice = try #require(OfflineMediaSelector.chooseVideo(from: playlist, mode: .smart))
        #expect(choice.hdrOnly)
    }

    // Rule 5: 60 fps doubles the size for the same resolution; only on request.
    @Test func standardFrameRateUnlessHighFrameRateIsAskedFor() throws {
        let playlist = try master([
            Fixture.variant(1920, 1080, codecs: "hvc1.1.6.L120.90", bandwidth: 8_000_000, fps: 59.94, uri: "60.m3u8"),
            Fixture.variant(1920, 1080, codecs: "hvc1.1.6.L120.90", bandwidth: 4_000_000, fps: 23.976, uri: "24.m3u8"),
        ])
        #expect(chosen(playlist, .smart)?.uri.lastPathComponent == "24.m3u8")
        #expect(chosen(playlist, .smart, highFPS: true)?.uri.lastPathComponent == "60.m3u8")
    }

    @Test func portrait1080pCountsAs1080pAndPortrait1440pDoesNot() throws {
        let playlist = try master([
            Fixture.variant(1440, 2560, bandwidth: 9_000_000, uri: "p1440.m3u8"),
            Fixture.variant(1080, 1920, bandwidth: 5_000_000, uri: "p1080.m3u8"),
        ])
        #expect(chosen(playlist, .smart)?.uri.lastPathComponent == "p1080.m3u8")
    }

    @Test func undeclaredResolutionsAvoidTheLikely4KBitrate() throws {
        let playlist = try master([
            Fixture.variant(nil, nil, bandwidth: 25_000_000, uri: "big.m3u8"),
            Fixture.variant(nil, nil, bandwidth: 5_000_000, uri: "mid.m3u8"),
            Fixture.variant(nil, nil, bandwidth: 1_000_000, uri: "low.m3u8"),
        ])
        let smart = try #require(OfflineMediaSelector.chooseVideo(from: playlist, mode: .smart))
        #expect(smart.variant.uri.lastPathComponent == "mid.m3u8")
        #expect(smart.resolutionUnknown)
        #expect(chosen(playlist, .saver)?.uri.lastPathComponent == "low.m3u8")
    }

    @Test func audioOnlyVariantsAreNeverTheVideo() throws {
        let playlist = try master([
            "#EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS=\"mp4a.40.2\"\naudio.m3u8",
            Fixture.variant(1280, 720, bandwidth: 2_000_000, uri: "720.m3u8"),
        ])
        #expect(chosen(playlist, .saver)?.uri.lastPathComponent == "720.m3u8")
    }

    // Audio: one rendition, the one playing; 最省空間 picks the source's own stereo copy.
    @Test func audioChoiceFollowsThePlayingTrackAndSaverPrefersStereo() throws {
        let playlist = try master([Fixture.variant(1920, 1080, bandwidth: 5_000_000, audio: "aud", uri: "v.m3u8")], extra: [
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"國語 5.1\",LANGUAGE=\"zh\",CHANNELS=\"6\",DEFAULT=YES,URI=\"zh51.m3u8\"",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"國語\",LANGUAGE=\"zh\",CHANNELS=\"2\",URI=\"zh2.m3u8\"",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"English\",LANGUAGE=\"en\",CHANNELS=\"2\",URI=\"en.m3u8\"",
        ])
        let options = playlist.renditions(type: "AUDIO", group: "aud")
        #expect(OfflineMediaSelector.chooseAudio(options, preferredLanguage: "en", preferredName: nil, mode: .smart)?.name == "English")
        #expect(OfflineMediaSelector.chooseAudio(options, preferredLanguage: nil, preferredName: nil, mode: .smart)?.name == "國語 5.1")
        #expect(OfflineMediaSelector.chooseAudio(options, preferredLanguage: "zh", preferredName: nil, mode: .saver)?.name == "國語")
        // A multichannel track the viewer is playing is kept as it is in the default mode — never downmixed.
        #expect(OfflineMediaSelector.chooseAudio(options, preferredLanguage: nil, preferredName: "國語 5.1", mode: .smart)?.name == "國語 5.1")
    }

    @Test func defaultSubtitlePrefersTraditionalChinese() throws {
        let playlist = try master([Fixture.variant(1920, 1080, bandwidth: 5_000_000, subtitles: "subs", uri: "v.m3u8")], extra: [
            "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"简体\",LANGUAGE=\"zh-Hans\",URI=\"hans.m3u8\"",
            "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"繁體\",LANGUAGE=\"zh-Hant\",URI=\"hant.m3u8\"",
        ])
        let options = OfflineMediaSelector.subtitleOptions(for: playlist.variants[0], in: playlist)
        #expect(OfflineMediaSelector.defaultSubtitle(options, preferredLanguage: "zh-TW")?.name == "繁體")
    }

    // Size: AVERAGE-BANDWIDTH is an estimate; BANDWIDTH alone is only an upper bound, and says so.
    @Test func estimateUsesAverageBandwidthAndMarksPeakAsApproximate() throws {
        let playlist = try master([
            Fixture.variant(1920, 1080, bandwidth: 8_000_000, average: 4_000_000, uri: "a.m3u8"),
            Fixture.variant(1280, 720, bandwidth: 3_000_000, uri: "b.m3u8"),
        ])
        let average = OfflineMediaSelector.estimate(playlist.variants[0], duration: 600)
        #expect(average.bytes == 300_000_000)
        #expect(average.basis == .averageBandwidth)
        let peak = OfflineMediaSelector.estimate(playlist.variants[1], duration: 600)
        #expect(peak.basis == .peakBandwidth)
        #expect(peak.isApproximate)
    }
}
