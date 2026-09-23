import Foundation
import Testing
@testable import WebHTVCore

// MARK: - S1: all three shapes of CatVod's `url`

private func playURL(_ json: String) throws -> PlayURL {
    try JSONDecoder().decode(PlayURL.self, from: Data(json.utf8))
}

@Test func aSingleStringURLIsOneUnnamedValue() throws {
    let url = try playURL(#""https://cdn.invalid/a.m3u8""#)
    #expect(url.values == [PlayURL.Value(v: "https://cdn.invalid/a.m3u8")])
    #expect(url.values.first?.n == nil)
    #expect(url.position == 0)
    #expect(url.isEmpty == false)
}

/// `UrlAdapter.convert` walks the array in twos, so it is `name, url, name, url`.
@Test func anArrayURLIsAlternatingNameAndAddress() throws {
    let url = try playURL(#"["1080P","https://a/1.m3u8","720P","https://a/2.m3u8"]"#)
    #expect(url.values == [PlayURL.Value(n: "1080P", v: "https://a/1.m3u8"),
                           PlayURL.Value(n: "720P", v: "https://a/2.m3u8")])
}

/// The Java loop condition is `i + 1 < size`, which silently drops a trailing odd element.
@Test func anOddTrailingArrayElementIsDroppedAsOnAndroid() throws {
    let url = try playURL(#"["1080P","https://a/1.m3u8","720P"]"#)
    #expect(url.values == [PlayURL.Value(n: "1080P", v: "https://a/1.m3u8")])
}

@Test func anObjectURLCarriesValuesAndPosition() throws {
    let url = try playURL(#"{"values":[{"n":"高清","v":"https://a/1.m3u8"},{"n":"標清","v":"https://a/2.m3u8"}],"position":1}"#)
    #expect(url.values.map(\.n) == ["高清", "標清"])
    #expect(url.position == 1)
}

/// `Url.set` clamps with `min(position, size - 1)`; an out-of-range index must not become an empty
/// URL or a crash.
@Test func anOutOfRangePositionIsClamped() throws {
    #expect(try playURL(#"{"values":[{"v":"https://a/1.m3u8"}],"position":7}"#).position == 0)
    #expect(try playURL(#"{"values":[{"v":"a"},{"v":"b"}],"position":-3}"#).position == 0)
}

// MARK: - S1: malformed input costs the malformed part, never the whole result

@Test func aMalformedURLFieldYieldsAnEmptyMenuRatherThanThrowing() throws {
    // `Url.objectFrom` catches its own failure and returns an empty Url.
    #expect(try playURL(#"{"values":"nope"}"#).values.isEmpty)
    #expect(try playURL(#"{}"#).values.isEmpty)
    #expect(try playURL(#"[]"#).values.isEmpty)
    // A member that is not a string still keeps the pairing aligned.
    #expect(try playURL(#"["1080P","https://a/1.m3u8",{"x":1},"https://a/2.m3u8"]"#).values
        == [PlayURL.Value(n: "1080P", v: "https://a/1.m3u8"),
            PlayURL.Value(n: "", v: "https://a/2.m3u8")])
    // Gson leaves a missing field null, so one incomplete member must not discard the menu.
    #expect(try playURL(#"{"values":[{"n":"高清"},{"n":"標清","v":"https://a/2.m3u8"}]}"#).values
        == [PlayURL.Value(n: "高清", v: ""), PlayURL.Value(n: "標清", v: "https://a/2.m3u8")])
}

@Test func anIntegerArrayMemberIsStringifiedRatherThanSkipped() throws {
    #expect(try playURL(#"[1,"https://a/1.m3u8"]"#).values == [PlayURL.Value(n: "1", v: "https://a/1.m3u8")])
}

// MARK: - S1: the spider and CMS decoders both read all three shapes

@Test func aSpiderPlayResponseReadsAllThreeURLShapes() throws {
    func decode(_ json: String) throws -> SpiderPlayResponse {
        try JSONDecoder().decode(SpiderPlayResponse.self, from: Data(json.utf8))
    }
    #expect(try decode(#"{"parse":0,"url":"https://a/1.m3u8"}"#).url.values.count == 1)
    // This is the case that used to throw DecodingError.typeMismatch and surface as a raw
    // decoder message in the app.
    #expect(try decode(#"{"parse":0,"url":["1080P","https://a/1.m3u8","720P","https://a/2.m3u8"]}"#)
        .url.values.count == 2)
    #expect(try decode(#"{"parse":0,"url":{"values":[{"n":"高清","v":"https://a/1.m3u8"}],"position":0}}"#)
        .url.values.count == 1)
    // Headers and the string/int `parse` tolerance both survive the change.
    let spider = try decode(#"{"parse":"1","url":["a","https://a/1.m3u8"],"header":{"Referer":"https://b"}}"#)
    #expect(spider.parse == 1)
    #expect(spider.header?["Referer"] == "https://b")
    #expect(try decode(#"{"parse":0}"#).url.values.isEmpty)
}

// MARK: - S2: which entry the menu starts on (D8) and how labels rank (D18)

private func menu(_ names: [String]) -> [PlaybackQuality] {
    names.enumerated().map { PlaybackQuality(name: $1, url: URL(string: "https://a/\($0).m3u8")!) }
}

@Test func theMenuDefaultsToTheHighestRankingLabel() {
    #expect(PlaybackQuality.defaultIndex(in: menu(["360P", "720P", "1080P"])) == 2)
    #expect(PlaybackQuality.defaultIndex(in: menu(["藍光", "超清", "高清", "標清"])) == 0)
    #expect(PlaybackQuality.defaultIndex(in: menu(["1080P 高碼率", "4K 超清", "720P60"])) == 1)
    // Simplified and traditional wordings rank the same.
    #expect(PlaybackQuality.defaultIndex(in: menu(["流畅 360P", "蓝光 1080P"])) == 1)
}

/// D18: a label nothing matches is not evidence to reorder on, so the source's own preference wins.
@Test func anUnrankableMenuKeepsTheSourcesOwnPosition() {
    #expect(PlaybackQuality.defaultIndex(in: menu(["線路A", "線路B", "線路C"]), position: 2) == 2)
    #expect(PlaybackQuality.defaultIndex(in: menu(["線路A", "線路B"])) == 0)
    // An unnamed single-URL source is the same case.
    #expect(PlaybackQuality.defaultIndex(in: menu([""])) == 0)
    #expect(PlaybackQuality.defaultIndex(in: []) == 0)
}

/// D8: a name the user picked by hand outranks the default, or 「預設」 would keep undoing them.
/// The preference is injected, which is what keeps this independent of the watch history (R1).
@Test func arememberedChoiceOutranksTheHighestQuality() {
    let qualities = menu(["360P", "720P", "1080P"])
    #expect(PlaybackQuality.defaultIndex(in: qualities, preferred: "720P") == 1)
    // A remembered name the source no longer offers falls back to the default rather than failing.
    #expect(PlaybackQuality.defaultIndex(in: qualities, preferred: "4K") == 2)
    #expect(PlaybackQuality.defaultIndex(in: qualities, position: 0, preferred: nil) == 2)
}

@Test func theLabelRankerTakesTheHighestWordItFinds() {
    #expect(PlaybackQuality.rank("藍光 4K") == PlaybackQuality.rank("4K"))
    #expect(PlaybackQuality.rank("1080P") ?? 0 > PlaybackQuality.rank("720P") ?? 0)
    #expect(PlaybackQuality.rank("720P") ?? 0 > PlaybackQuality.rank("標清 480P") ?? 0)
    #expect(PlaybackQuality.rank("線路①") == nil)
    #expect(PlaybackQuality.rank("") == nil)
}

// MARK: - S1: a single-URL source keeps exactly the shape it had

@Test func aSingleURLSourceStillPresentsAOneEntryMenu() throws {
    let target = PlaybackTarget(url: URL(string: "https://a/1.m3u8")!)
    #expect(target.qualities.count == 1)
    #expect(target.qualities.first?.url == target.url)
    #expect(target.qualities.first?.name == "")
    #expect(target.defaultIndex == 0)
    #expect(target.headers.isEmpty)
}

// IOS-POC-17E. The control bar's quality menu: where it starts, which address each entry opens,
// and that a single-URL source offers no menu at all.
@Test func theQualityChoiceStartsRememberedAndOpensTheResolvedDefault() throws {
    let resolved = try #require(URL(string: "https://cdn.example.com/sniffed/1080.m3u8"))
    let raw1080 = try #require(URL(string: "https://page.example.com/1080"))
    let raw720 = try #require(URL(string: "https://cdn.example.com/720.m3u8"))
    let target = PlaybackTarget(url: resolved,
                                qualities: [PlaybackQuality(name: "1080P", url: raw1080),
                                            PlaybackQuality(name: "720P", url: raw720)],
                                position: 0, defaultIndex: 0)

    var choice = PlaybackQualityChoice(target: target, preferred: "")
    #expect(choice.offersChoice)
    #expect(choice.name == "1080P")
    #expect(choice.url == resolved, "the default entry plays from its probed/sniffed address")
    let switched = choice.select(1)
    #expect(switched)
    #expect(choice.url == raw720, "any other entry opens as the source gave it")
    let again = choice.select(1)
    let outOfRange = choice.select(9)
    #expect(!again, "choosing what is already on screen changes nothing")
    #expect(!outOfRange)

    let remembered = PlaybackQualityChoice(target: target, preferred: "720P")
    #expect(remembered.name == "720P" && remembered.url == raw720)

    let single = PlaybackQualityChoice(target: PlaybackTarget(url: resolved), preferred: "")
    #expect(!single.offersChoice)
    #expect(single.url == resolved)
}
