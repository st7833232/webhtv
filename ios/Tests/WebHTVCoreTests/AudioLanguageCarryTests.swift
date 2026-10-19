import Testing
@testable import WebHTVCore

// W-154. An engine switch (the viewer's, or a fallback) keeps the audio language the viewer had:
// track ids belong to one engine adapter, so the language is what crosses over.

private func audio(_ tracks: [(id: String, language: String?)], selected: String) -> PlaybackMediaTrack {
    PlaybackMediaTrack(options: tracks.map { PlaybackMediaOption(id: $0.id, language: $0.language, fallbackName: $0.id) },
                       selectedID: selected)
}

@Suite struct AudioLanguageCarryTests {
    @Test func japaneseOnAVPlayerIsJapaneseOnMPV() {
        // As the W-149 synthetic sample listed them: both engines report `en` and `ja`.
        let mpv = audio([("mpv-audio-1", "en"), ("mpv-audio-2", "ja")], selected: "mpv-audio-1")
        #expect(mpv.reselection(carryingLanguage: "ja") == "mpv-audio-2")
    }

    @Test func japaneseOnMPVIsJapaneseOnAVPlayer() {
        let native = audio([("native-audio-0", "en"), ("native-audio-1", "ja")], selected: "native-audio-0")
        #expect(native.reselection(carryingLanguage: "ja") == "native-audio-1")
    }

    @Test func noTrackInThatLanguageKeepsTheDefault() {
        let mpv = audio([("mpv-audio-1", "en"), ("mpv-audio-2", nil)], selected: "mpv-audio-1")
        #expect(mpv.reselection(carryingLanguage: "ja") == nil)
    }

    @Test func noPreviousSelectionKeepsTheDefault() {
        let mpv = audio([("mpv-audio-1", "en"), ("mpv-audio-2", "ja")], selected: "mpv-audio-1")
        #expect(mpv.reselection(carryingLanguage: nil) == nil)
        #expect(mpv.reselection(carryingLanguage: "und") == nil)
    }

    @Test func theDefaultAlreadyInThatLanguageIsLeftAlone() {
        let native = audio([("native-audio-0", "ja"), ("native-audio-1", "en")], selected: "native-audio-0")
        #expect(native.reselection(carryingLanguage: "ja") == nil)
    }

    @Test func caseRegionAndThreeLetterCodesMatch() {
        let mpv = audio([("mpv-audio-1", "eng"), ("mpv-audio-2", "jpn")], selected: "mpv-audio-1")
        #expect(mpv.reselection(carryingLanguage: "ja-JP") == "mpv-audio-2")
        let native = audio([("native-audio-0", "en"), ("native-audio-1", "JA_jp")], selected: "native-audio-0")
        #expect(native.reselection(carryingLanguage: "jpn") == "native-audio-1")
    }

    @Test func theSameRegionWinsOverTheSameLanguage() {
        let mpv = audio([("mpv-audio-1", "zh-CN"), ("mpv-audio-2", "zh-HK")], selected: "mpv-audio-1")
        #expect(mpv.reselection(carryingLanguage: "zh-HK") == "mpv-audio-2")
        #expect(mpv.reselection(carryingLanguage: "zh-TW") == nil)   // zh-CN is already playing
    }
}
