import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-45F. "有些影片選不出CC字幕": a caption track listed as an unlabelled twin, or as
// `EIA_608`, reads as no CC at all; and an empty list said nothing. These pin the labels and what
// the panel says, and that an ordinary subtitle's label did not change.

@Test func aCaptionTrackSaysCCWhicheverEngineListedIt() {
    let avPlayer = PlaybackMediaOption(id: "native-subtitle-1", title: "English", language: "en",
                                       fallbackName: "字幕 2", subtitleRole: .closedCaptions)
    #expect(avPlayer.displayName == "English · CC")
    let mpv = PlaybackMediaOption(id: "mpv-subtitle-3", codec: "eia_608", fallbackName: "字幕 1")
    #expect(mpv.subtitleRole == .closedCaptions)
    #expect(mpv.displayName == "字幕 1 · CC")
    #expect(!mpv.displayName.contains("EIA"))
}

@Test func sdhForcedAndUndecodableTracksSayWhatTheyAre() {
    #expect(PlaybackMediaOption(id: "a", title: "English", fallbackName: "x", subtitleRole: .sdh).displayName == "English · SDH")
    #expect(PlaybackMediaOption(id: "b", title: "日本語", fallbackName: "x", subtitleRole: .forced).displayName == "日本語 · 強制")
    let teletext = PlaybackMediaOption(id: "c", title: "Deutsch", codec: "dvb_teletext", fallbackName: "x")
    #expect(teletext.isUnsupportedSubtitle && teletext.displayName.hasSuffix("不支援"))
}

/// Regression: an ordinary subtitle reads exactly as it did before IOS-POC-45F.
@Test func anOrdinarySubtitlesLabelIsUnchanged() {
    #expect(PlaybackMediaOption(id: "d", title: "中文", codec: "subrip", fallbackName: "x").displayName == "中文 · SUBRIP")
    #expect(PlaybackMediaOption(id: "e", language: "ja", codec: "ass", fallbackName: "字幕 1").subtitleRole == .normal)
}

/// The panel never says "no subtitles": on AVPlayer it offers MPV, which reads captions AVPlayer
/// does not list; on MPV it says none are listed yet. A downloaded file is not an embedded track.
@Test func anEmptyListOffersMPVOnAVPlayerAndSaysNotYetOnMPV() {
    let off = PlaybackMediaOption(id: PlaybackMediaOption.subtitleOffID, title: "關閉", isOff: true, fallbackName: "關閉")
    let online = PlaybackMediaOption(id: "online-subtitle-1", title: "繁中", fallbackName: "繁中")
    let embedded = PlaybackMediaOption(id: "native-subtitle-0", title: "English", fallbackName: "字幕 1")
    #expect(SubtitleEmptyState.state(engine: .native, subtitles: nil) == .tryMPV)
    #expect(SubtitleEmptyState.state(engine: .native, subtitles: .init(options: [off, online], selectedID: online.id)) == .tryMPV)
    #expect(SubtitleEmptyState.state(engine: .mpv, subtitles: nil) == .provisional)
    #expect(SubtitleEmptyState.state(engine: .mpv, subtitles: .init(options: [off, embedded], selectedID: nil)) == .none)
}

/// The log line counts kinds and codecs and carries no title, language name or address.
@Test func theSubtitleLogLineCarriesCountsOnly() {
    let options = [
        PlaybackMediaOption(id: "native-subtitle-0", title: "Secret Title https://x.example/a?token=1", language: "en",
                            codec: "c608", fallbackName: "x"),
        PlaybackMediaOption(id: "native-subtitle-1", title: "中文", codec: "wvtt", fallbackName: "y", subtitleRole: .sdh),
        PlaybackMediaOption(id: "online-subtitle-1", title: "下載的", fallbackName: "z"),
    ]
    let line = SubtitleTrackSummary.line(engine: "AVPlayer", status: "ok", options: options)
    #expect(line == "[subtitle] engine=AVPlayer list=ok options=2 cc=1 sdh=1 forced=0 unsupported=0 codecs=c608,wvtt")
    #expect(!line.contains("://") && !line.contains("Secret") && !line.contains("中文"))
}
