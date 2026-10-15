import Foundation
import Testing
@testable import WebHTVCore

// W-124 (IOS-POC-59 U1, AC-8): m3u and txt live lists, parsed the way Android's LiveParser does,
// with the deliberate deviations X-4 to X-8 and B-2 to B-5 of the task document.

private let plain = LiveSource(name: "s", url: "http://x/list")

private func parse(_ text: String, _ source: LiveSource = plain) throws -> LivePlaylist {
    try LivePlaylistParser.parse(Data(text.utf8), source: source)
}

private func channels(_ playlist: LivePlaylist) -> [LiveChannel] { playlist.groups.flatMap(\.channels) }
private func lines(_ playlist: LivePlaylist) -> [LiveLine] { channels(playlist).flatMap(\.lines) }

// MARK: format and text

@Test func aJSONArrayListIsRefusedAndHashGenreBeatsEXTM3U() throws {
    #expect(throws: LivePlaylistError.unsupportedFormat) { try parse(#"  [{"name":"g","channel":[]}]"#) }
    // `#EXTM3U` on a `#genre#` line is a txt group name, not an m3u header.
    let txt = try parse("#EXTM3U x,#genre#\nA,http://x/a")
    #expect(txt.groups.map(\.name) == ["#EXTM3U x"])
    #expect(try parse("[ not json\nA,http://x/a").groups.map(\.name) == ["直播"])
    let m3u = try parse("#EXTM3U\n#EXTINF:-1,A\nhttp://x/a")
    #expect(m3u.groups.map(\.name) == ["直播"])
    #expect(channels(m3u).map(\.name) == ["A"])
}

@Test func aByteOrderMarkIsDropped() throws {
    let m3u = try parse("\u{FEFF}#EXTM3U x-tvg-url=\"http://e/x.xml\" catchup=\"append\"\n#EXTINF:-1,A\nhttp://x/a")
    #expect(m3u.tvgURL == "http://e/x.xml")
    #expect(m3u.catchup?.type == "append")
    #expect(try parse("\u{FEFF}G,#genre#\nA,http://x/a").groups.map(\.name) == ["G"])
}

@Test func everyLineEndingSplitsLines() throws {
    let playlist = try parse("G,#genre#\r\nA,http://x/a\rB,http://x/b\nC,http://x/c\r\n")
    #expect(channels(playlist).map(\.name) == ["A", "B", "C"])
    #expect(lines(playlist).map(\.url) == ["http://x/a", "http://x/b", "http://x/c"])
}

@Test func blankTabAndFullWidthCommaLinesMakeNothing() throws {
    #expect(try parse("\n\t\n   \nA，http://x/a\n").groups.isEmpty)
}

@Test func lineURLsAreTrimmedButTxtNamesAreNot() throws {
    let playlist = try parse("G,#genre#\n A ,  http://x/a \t")
    #expect(channels(playlist).map(\.name) == [" A "])
    #expect(lines(playlist).map(\.url) == ["http://x/a"])
    #expect(lines(playlist).map(\.support) == [.playable])
}

@Test func gb18030TextDecodesAndUndecodableBytesFail() throws {
    let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    let data = try #require("央视,#genre#\nCCTV1,http://x/1".data(using: gb18030))
    #expect(String(data: data, encoding: .utf8) == nil)
    #expect(try LivePlaylistParser.parse(data, source: plain).groups.map(\.name) == ["央视"])
    #expect(throws: LivePlaylistError.undecodableText) { try LivePlaylistParser.parse(Data([0xFF, 0xFF, 0xFF]), source: plain) }
}

@Test func emptyAndNoteOnlyListsHaveNoGroups() throws {
    #expect(try parse("").groups.isEmpty)
    #expect(try parse("更新时间,http://x/t\nLast Update 1,http://x/u").groups.isEmpty)
    #expect(try parse("#EXTM3U\n#EXTINF:-1,更新日期 1\nhttp://x/t").groups.isEmpty)
}

// MARK: m3u

@Test func m3uHeaderKeepsCatchupAndTheGuideOnlyWithoutASourceEPG() throws {
    let text = "#EXTM3U x-tvg-url=\"http://e/a.xml\" catchup=\"default\" catchup-source=\"?s={utc}\" catchup-replace=\"a/b\"\n#EXTINF:-1,A\nhttp://x/a"
    let playlist = try parse(text)
    #expect(playlist.tvgURL == "http://e/a.xml")
    #expect(playlist.catchup == LiveCatchupRaw(type: "default", source: "?s={utc}", replace: "a/b"))
    var withEPG = plain
    withEPG.epg = "http://e/{name}"
    #expect(try parse(text, withEPG).tvgURL == nil)
    #expect(try parse("#EXTM3U url-tvg=\"http://e/b.xml\"\n").tvgURL == "http://e/b.xml")
}

@Test func m3uNameIsAfterTheLastCommaAndAttributesAreKeptRaw() throws {
    let playlist = try parse("""
    #EXTM3U
    #EXTINF:-1 tvg-id="1" tvg-name="n1" tvg-logo="L1" http-user-agent="a, b" group-title="G" catchup="append" catchup-source="?x",Name
    http://x/1
    #EXTINF:-1 tvg-logo="L2" group-title="G",Name
    http://x/2
    """)
    let channel = try #require(channels(playlist).first)
    #expect(playlist.groups.map(\.name) == ["G"])
    #expect(channel.name == "Name")
    #expect(channel.lines.map(\.url) == ["http://x/1", "http://x/2"])
    #expect(channel.lines[0].headers["User-Agent"] == "a, b")
    // A later #EXTINF of the same channel overwrites what it carries, empty or not, as Android's
    // setters do.
    #expect(channel.logo == "L2")
    #expect(channel.tvgID == nil && channel.tvgName == nil && channel.catchup == nil)
    let other = try #require(channels(try parse("""
    #EXTM3U
    #EXTINF:-1 tvg-id="1" tvg-name="n1" tvg-logo="L1" catchup="append" catchup-source="?x",Other
    http://x/3
    """)).first)
    #expect(other.tvgID == "1" && other.tvgName == "n1" && other.logo == "L1")
    #expect(other.catchup == LiveCatchupRaw(type: "append", source: "?x", replace: ""))
}

@Test func m3uNoteChannelSkipsItsURLButKeepsTheSettingForTheNextOne() throws {
    let playlist = try parse("""
    #EXTM3U
    #EXTVLCOPT:http-user-agent=V
    #EXTINF:-1,更新时间 2026-10-15
    http://x/t
    #EXTINF:-1,A
    http://x/a
    #EXTINF:-1,B
    #EXTVLCOPT:http-user-agent=W
    not-a-url
    http://x/b
    """)
    #expect(channels(playlist).map(\.name) == ["A", "B"])
    #expect(lines(playlist).map(\.url) == ["http://x/a", "http://x/b"])
    #expect(lines(playlist).map { $0.headers["User-Agent"] } == ["V", "W"])
}

@Test func m3uSettingsClearAfterEachURL() throws {
    let playlist = try parse("""
    #EXTM3U
    #EXTVLCOPT:http-user-agent=V
    #EXTINF:-1,A
    http://x/a1
    http://x/a2
    #EXTINF:-1,B
    http://x/b
    """)
    #expect(lines(playlist).map { $0.headers["User-Agent"] } == ["V", nil, nil])
}

@Test func m3uUserAgentIsListSettingThenEXTINFThenSource() throws {
    var source = plain
    source.ua = "S"
    let playlist = try parse("""
    #EXTM3U
    #EXTINF:-1 http-user-agent="E",A
    #EXTVLCOPT:http-user-agent=V
    http://x/1
    http://x/2
    #EXTINF:-1,B
    http://x/3
    """, source)
    #expect(lines(playlist).map { $0.headers["User-Agent"] } == ["V", "E", "S"])
}

@Test func m3uVLCOptionsBecomeHeaders() throws {
    let playlist = try parse("""
    #EXTM3U
    #EXTVLCOPT:http-referrer="http://r/"
    #EXTVLCOPT:http-origin=http://o
    #EXTVLCOPT:http-cookie=a=b; c=d
    #EXTHTTP:{"X-T":"1"}
    #EXTINF:-1,A
    http://x/a
    """)
    #expect(lines(playlist).first?.headers == ["Referer": "http://r/", "Origin": "http://o", "Cookie": "a=b; c=d", "X-T": "1"])
}

@Test func kodiLicenceOrDashMarksTheLineDRMAndTheListStillParses() throws {
    let playlist = try parse("""
    #EXTM3U
    #KODIPROP:inputstream.adaptive.license_type=clearkey
    #KODIPROP:inputstream.adaptive.license_key=https://k/x
    #EXTINF:-1,A
    http://x/a.mpd
    #KODIPROP:inputstream.adaptive.manifest_type=mpd
    #EXTINF:-1,B
    http://x/b.mpd
    #EXTINF:-1,C
    http://x/c.m3u8
    """)
    #expect(lines(playlist).map(\.support) == [.unsupported(.drm), .unsupported(.drm), .playable])
}

@Test func kodiStreamHeadersReachTheLineAndTheirDRMSchemeMarksIt() throws {
    let playlist = try parse("""
    #EXTM3U
    #KODIPROP:inputstream.adaptive.stream_headers=X-K=1&Referer=http://r
    #EXTINF:-1,A
    http://x/a
    #KODIPROP:inputstream.adaptive.common_headers=drmScheme=clearkey&X-L=2
    #EXTINF:-1,B
    http://x/b
    """)
    #expect(lines(playlist).map(\.headers) == [["X-K": "1", "Referer": "http://r"], ["X-L": "2"]])
    #expect(lines(playlist).map(\.support) == [.playable, .unsupported(.drm)])
}

@Test func m3uMergesGroupsAndNamedChannelsButNeverUnnamedOnes() throws {
    let playlist = try parse("""
    #EXTM3U
    #EXTINF:-1 group-title="G",A
    http://x/1
    #EXTINF:-1 group-title="H",A
    http://x/2
    #EXTINF:-1 group-title="G",A
    http://x/3
    #EXTINF:-1 group-title="G",
    http://x/4
    #EXTINF:-1 group-title="G",
    http://x/5
    #EXTINF:-1 group-title="",C
    http://x/6
    """)
    #expect(playlist.groups.map(\.name) == ["G", "H", "直播"])
    #expect(playlist.groups[0].channels.map(\.name) == ["A", "", ""])
    #expect(playlist.groups[0].channels[0].lines.map(\.url) == ["http://x/1", "http://x/3"])
    #expect(playlist.groups[1].channels.count == 1)
}

/// N-4: a password group shares its visible name, but its channels must never fold into the
/// visible group of that name (Android merges by name alone).
@Test func m3uKeepsAPasswordGroupApartFromTheVisibleGroupOfItsName() throws {
    let playlist = try parse("""
    #EXTM3U
    #EXTINF:-1 group-title="X",A
    http://x/1
    #EXTINF:-1 group-title="X_9",B
    http://x/2
    """)
    #expect(playlist.groups.map(\.name) == ["X", "X"])
    #expect(playlist.groups.map(\.isHidden) == [false, true])
    #expect(playlist.groups[0].channels.map(\.name) == ["A"])
}

// MARK: txt

@Test func txtSettingsLastUntilTheNextGenre() throws {
    var source = plain
    source.ua = "S"
    let playlist = try parse("""
    G1,#genre#
    parse=1
    ua=X
    A,http://x/a
    B,http://x/b
    C,http://x/c
    G2,#genre#
    D,http://x/d
    """, source)
    #expect(lines(playlist).map { $0.headers["User-Agent"] } == ["X", "X", "X", "S"])
    #expect(lines(playlist).map(\.support) == [.unsupported(.parse), .unsupported(.parse), .unsupported(.parse), .playable])
}

@Test func aSettingBeforeAGenreIsClearedByIt() throws {
    #expect(lines(try parse("ua=X\nG,#genre#\nA,http://x/a")).first?.headers == [:])
}

@Test func aSettingLineWithACommaMakesNoChannel() throws {
    let playlist = try parse("""
    G,#genre#
    ua=Mozilla/5.0 (KHTML, like Gecko) http://x
    header={"a":"b","c":"http://d"}
    A,http://x/a
    """)
    #expect(channels(playlist).map(\.name) == ["A"])
    #expect(lines(playlist).first?.headers == ["a": "b", "c": "http://d", "User-Agent": "Mozilla/5.0 (KHTML, like Gecko) http://x"])
}

@Test func txtSplitsLinesOnHashAndLabelsOnDollar() throws {
    let channel = try #require(channels(try parse("G,#genre#\nA,http://x/1$高清#http://x/2$#rtmp://x/3")).first)
    #expect(channel.lines.map(\.url) == ["http://x/1", "http://x/2", "rtmp://x/3"])
    #expect(channel.lines.map(\.label) == ["高清", nil, nil])
    #expect(channel.lines.map(\.support) == [.playable, .playable, .attempt])
}

@Test func txtMergesNamesWithinAGroupButNeverGroups() throws {
    let playlist = try parse("G,#genre#\nA,http://x/1\nA,http://x/2\n,http://x/4\n,http://x/5\nG,#genre#\nA,http://x/3")
    #expect(playlist.groups.map(\.name) == ["G", "G"])
    #expect(playlist.groups[0].channels.map(\.name) == ["A", "", ""])
    #expect(playlist.groups[0].channels[0].lines.count == 2)
    #expect(playlist.groups[1].channels[0].lines.count == 1)
}

@Test func theDefaultGroupIsMadeOnlyForTheFirstRealLine() throws {
    #expect(try parse("A,not-a-url").groups.isEmpty)
    let playlist = try parse("A,not-a-url\nB,http://x/b\n,#genre#\nC,http://x/c")
    #expect(playlist.groups.map(\.name) == ["直播", "直播"])
    #expect(playlist.groups.map { $0.channels.map(\.name) } == [["B"], ["C"]])
}

@Test func emptyGroupsAreKept() throws {
    let playlist = try parse("A,#genre#\nB,#genre#\nX,http://x\n更新时间,#genre#")
    #expect(playlist.groups.map(\.channels.count) == [0, 1, 0])
}

@Test func aPipeHeaderBelongsToItsLineOnly() throws {
    let playlist = try parse("""
    G,#genre#
    header={"X-A":"s"}
    A,http://x/1|Referer=http://r&User-Agent=P
    A,http://x/2
    B,http://x/3|headers=X-B=1&X-C=2
    C,http://x/4|X-A=p
    D,http://x/5|drmScheme=clearkey&drmLicense=k
    """)
    let all = lines(playlist)
    #expect(all[0].headers == ["X-A": "s", "Referer": "http://r", "User-Agent": "P"])
    #expect(all[1].headers == ["X-A": "s"])
    #expect(all[2].headers == ["X-A": "s", "X-B": "1", "X-C": "2"])
    #expect(all[3].headers == ["X-A": "p"])
    #expect(all.map(\.support) == [.playable, .playable, .playable, .playable, .unsupported(.drm)])
}

// MARK: inheritance and groups

@Test func theSourceFillsOnlyWhatALineLeavesEmpty() throws {
    let source = LiveSource(name: "s", url: "http://x", ua: "S", origin: "SO", referer: "SR", header: ["H": "s"])
    let playlist = try parse("""
    G,#genre#
    A,http://x/1
    referer=http://lr
    B,http://x/2
    G2,#genre#
    header={"user-agent":"in-map"}
    C,http://x/3
    """, source)
    let all = lines(playlist)
    #expect(all[0].headers == ["H": "s", "User-Agent": "S", "Origin": "SO", "Referer": "SR"])
    #expect(all[1].headers == ["H": "s", "User-Agent": "S", "Origin": "SO", "Referer": "http://lr"])
    // A line with any header of its own takes none of the source's map; the source UA still
    // replaces the map's user agent, whatever its case.
    #expect(all[2].headers == ["User-Agent": "S", "Origin": "SO", "Referer": "SR"])
}

@Test func anUnderscoreSplitsTheGroupPassword() throws {
    let text = "A_123,#genre#\nX,http://x/1\nB_,#genre#\nY,http://x/2"
    let locked = try parse(text)
    #expect(locked.groups.map(\.name) == ["A", "B"])
    #expect(locked.groups.map(\.password) == ["123", nil])
    #expect(locked.groups.map(\.isHidden) == [true, false])
    // The parser keeps hidden groups; hiding them is the list screen's job (U2).
    #expect(locked.groups[0].channels.count == 1)
    var open = plain
    open.pass = true
    let passed = try parse(text, open)
    #expect(passed.groups.map(\.name) == ["A", "B"])
    #expect(passed.groups.allSatisfy { !$0.isHidden && $0.password == nil })
}

@Test func linesAreClassifiedBySchemeHostAndFlags() throws {
    let urls = ["http://x/a", "HTTPS://X/b", "https://www.youtube.com/watch?v=1", "https://youtu.be/1",
                "http://notyoutube.com/a", "rtsp://x/c", "rtmp://x/d", "video://x/e", "p3p://f", "mitv://g",
                "tvbus://h", "thunder://i", "proxy://j", "abc://k", ",http://x/l"]
    let playlist = try parse("G,#genre#\n" + urls.enumerated().map { "C\($0.offset),\($0.element)" }.joined(separator: "\n") + "\nZ,no-scheme")
    #expect(lines(playlist).map(\.support) == [
        .playable, .playable, .unsupported(.youtube), .unsupported(.youtube), .playable, .attempt, .attempt,
        .unsupported(.sniff), .unsupported(.p2p), .unsupported(.p2p), .unsupported(.p2p), .unsupported(.p2p),
        .unsupported(.proxy), .unsupported(.other), .unsupported(.other),
    ])
    #expect(channels(playlist).map(\.isUnsupported) == [false, false, true, true, false, false, false,
                                                       true, true, true, true, true, true, true, true])
}
