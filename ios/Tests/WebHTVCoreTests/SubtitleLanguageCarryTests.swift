import Testing
@testable import WebHTVCore

// W-159. An engine switch keeps the embedded subtitle the viewer had — its language and kind, or 「關閉」 — as W-154
// does for audio: ids belong to one engine adapter. Online subtitles are the router's and cross on their own.

private let off = PlaybackMediaOption(id: "off", title: "關閉", isOff: true, fallbackName: "關閉")

private func option(_ id: String, _ language: String?, codec: String? = nil, role: PlaybackSubtitleRole = .normal) -> PlaybackMediaOption {
    PlaybackMediaOption(id: id, language: language, codec: codec, fallbackName: id, subtitleRole: role)
}

private func subtitles(_ options: [PlaybackMediaOption], selected: String?) -> PlaybackMediaTrack {
    PlaybackMediaTrack(options: [off] + options, selectedID: selected)
}

@Suite struct SubtitleLanguageCarryTests {
    @Test func chineseOnAVPlayerIsChineseOnMPVAndBack() throws {
        let native = subtitles([option("native-sub-0", "en"), option("native-sub-1", "zh")], selected: "native-sub-1")
        let carry = try #require(PlaybackSubtitleCarry(native))
        let mpv = subtitles([option("mpv-sub-1", "eng"), option("mpv-sub-2", "chi")], selected: "off")
        #expect(mpv.reselection(carrying: carry) == .select("mpv-sub-2"))

        let back = try #require(PlaybackSubtitleCarry(subtitles([option("mpv-sub-1", "eng"), option("mpv-sub-2", "chi")],
                                                               selected: "mpv-sub-2")))
        #expect(subtitles([option("native-sub-0", "en"), option("native-sub-1", "zh")], selected: "off")
                    .reselection(carrying: back) == .select("native-sub-1"))
    }

    // 「關閉」 is a choice too: the engine taking over may switch a default track on by itself.
    @Test func offStaysOff() throws {
        let carry = try #require(PlaybackSubtitleCarry(subtitles([option("native-sub-0", "zh")], selected: "off")))
        #expect(carry == .off)
        #expect(subtitles([option("mpv-sub-1", "zh")], selected: "mpv-sub-1").reselection(carrying: carry) == .select("off"))
        #expect(subtitles([option("mpv-sub-1", "zh")], selected: "off").reselection(carrying: carry) == .matched)
        // MPV's first list may have nothing selected yet; it picks a default afterwards (W-159 Simulator run 1).
        #expect(subtitles([option("mpv-sub-1", "zh")], selected: nil).reselection(carrying: carry) == .matched)
        #expect(PlaybackMediaTrack(options: [option("x", "zh")], selectedID: "x").reselection(carrying: .off) == .unavailable)
        // A forced track (foreign dialogue) stays on: 「關閉」 is about subtitles, not about those lines.
        #expect(subtitles([option("forced", "zh", role: .forced)], selected: "forced").reselection(carrying: carry) == .matched)
    }

    // MPV adds a caption track only once captions arrive (W-155), so a carried CC waits for it; anything else that
    // the new engine does not list is given up at once, keeping its default.
    @Test func closedCaptionsWaitForTheTrackOtherLanguagesDoNot() throws {
        let native = subtitles([option("native-cc", nil, role: .closedCaptions)], selected: "native-cc")
        let carry = try #require(PlaybackSubtitleCarry(native))
        #expect(subtitles([option("mpv-sub-1", "en")], selected: "off").reselection(carrying: carry) == .wait)
        #expect(subtitles([option("mpv-sub-1", "en"), option("mpv-sub-2", nil, codec: "eia_608")], selected: "off")
                    .reselection(carrying: carry) == .select("mpv-sub-2"))

        let japanese = try #require(PlaybackSubtitleCarry(subtitles([option("native-sub-0", "ja")], selected: "native-sub-0")))
        #expect(subtitles([option("mpv-sub-1", "en")], selected: "mpv-sub-1").reselection(carrying: japanese) == .unavailable)
        // A track the build cannot decode is no match: MPV would drop it and the carry would keep putting it back.
        #expect(subtitles([option("ttx", "ja", codec: "dvb_teletext")], selected: "off").reselection(carrying: japanese) == .unavailable)
    }

    @Test func theSameKindAndTagWinWithinALanguage() throws {
        let mpv = subtitles([option("sdh", "zh-TW", role: .sdh), option("hans", "zh-CN"), option("hant", "zh-TW")], selected: "off")
        let normal = try #require(PlaybackSubtitleCarry(subtitles([option("n", "zh-TW")], selected: "n")))
        #expect(mpv.reselection(carrying: normal) == .select("hant"))
        let sdh = try #require(PlaybackSubtitleCarry(subtitles([option("n", "zh-TW", role: .sdh)], selected: "n")))
        #expect(mpv.reselection(carrying: sdh) == .select("sdh"))
        // The language without that kind still beats the engine's default.
        #expect(subtitles([option("hans", "zh-CN")], selected: "off").reselection(carrying: sdh) == .select("hans"))
        // Already showing it: nothing to do.
        #expect(subtitles([option("hant", "zh-TW")], selected: "hant").reselection(carrying: normal) == .matched)
        #expect(normal.description == "zh-TW/normal" && PlaybackSubtitleCarry.off.description == "off")
    }

    @Test func nothingToCarryFromAnOnlineSubtitleOrAnUnlabelledTrack() {
        let online = PlaybackMediaTrack(options: [off, PlaybackExternalSubtitle.option(id: PlaybackExternalSubtitle.idPrefix + "1")],
                                        selectedID: PlaybackExternalSubtitle.idPrefix + "1")
        #expect(PlaybackSubtitleCarry(online) == nil)
        #expect(PlaybackSubtitleCarry(subtitles([option("x", nil)], selected: "x")) == nil)
        #expect(PlaybackSubtitleCarry(subtitles([option("x", "und")], selected: "x")) == nil)
        #expect(PlaybackSubtitleCarry(nil) == nil)
        #expect(PlaybackSubtitleCarry(PlaybackMediaTrack(options: [off], selectedID: nil)) == nil)
    }
}

private extension PlaybackExternalSubtitle {
    static func option(id: String) -> PlaybackMediaOption { PlaybackMediaOption(id: id, title: "線上", fallbackName: "線上") }
}
