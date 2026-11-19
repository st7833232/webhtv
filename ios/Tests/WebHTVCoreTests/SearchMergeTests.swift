import Testing
@testable import WebHTVCore

// W-315 A3. What these pin down: the same whole title (season included) with the same year is one card,
// however the sites spell it; another season, another year, or a year on one side only is another card;
// folders and titles that fold to nothing never merge; a card sits where its first result was.

private func vod(_ name: String, year: String = "", tag: String = "") -> Vod {
    Vod(id: name, name: name, picture: "", year: year, tag: tag)
}

@Test func mergesTheSameTitleAndYearAcrossSpellings() {
    let key = SearchMerge.key(for: vod("慶餘年 第二季", year: "2024"))
    #expect(key != nil)
    #expect(SearchMerge.key(for: vod("庆余年第二季", year: "2024")) == key)
    #expect(SearchMerge.key(for: vod("慶餘年：第二季", year: "2024-05-16")) == key)
    #expect(SearchMerge.key(for: vod("ＳＴＲＡＮＧＥＲ ＴＨＩＮＧＳ")) == SearchMerge.key(for: vod("Stranger Things")))
}

@Test func keepsOtherSeasonsYearsAndUnknownYearsApart() {
    let second = SearchMerge.key(for: vod("慶餘年 第二季", year: "2024"))
    #expect(SearchMerge.key(for: vod("慶餘年 第一季", year: "2024")) != second)
    #expect(SearchMerge.key(for: vod("慶餘年2", year: "2024")) != second)
    #expect(SearchMerge.key(for: vod("射鵰英雄傳", year: "1983")) != SearchMerge.key(for: vod("射鵰英雄傳", year: "2017")))
    #expect(SearchMerge.key(for: vod("射鵰英雄傳")) != SearchMerge.key(for: vod("射鵰英雄傳", year: "2017")))
    #expect(SearchMerge.key(for: vod("射鵰英雄傳", year: "未知")) == SearchMerge.key(for: vod("射鵰英雄傳")))
    // A trailer or a commentary keeps its tag in the key, so it never hides behind the work itself.
    #expect(SearchMerge.key(for: vod("慶餘年 第二季[預告片]")) != SearchMerge.key(for: vod("慶餘年 第二季")))
    #expect(SearchMerge.key(for: vod("慶餘年[電影解說]")) != SearchMerge.key(for: vod("慶餘年")))
}

@Test func neverMergesFoldersOrEmptyTitles() {
    #expect(SearchMerge.key(for: vod("慶餘年", tag: "folder")) == nil)
    #expect(SearchMerge.key(for: vod("《》 · ！")) == nil)
}

@Test func readsOnlyAFourDigitYear() {
    #expect(SearchMerge.year("2019") == "2019")
    #expect(SearchMerge.year("2019年") == "2019")
    #expect(SearchMerge.year("更新至2019-11-26") == "2019")
    #expect(SearchMerge.year("12019") == "")
    #expect(SearchMerge.year("1080P") == "")
    #expect(SearchMerge.year("") == "")
}

@Test func placesEachCardWhereItsFirstResultWas() {
    let items = ["a", "b", "x", "a", "c", "b", "x"]
    let groups = SearchMerge.merged(items) { $0 == "x" ? nil : $0 }
    #expect(groups == [["a", "a"], ["b", "b"], ["x"], ["c"], ["x"]])
}

// W-318: a card is shown by a result with the work's own facts, not a clip site's play length.
@Test func leadsWithAResultWhoseRemarksAreNotAPlayLength() {
    #expect(SearchMerge.lead(["13057:27", "1:17:00", "全46集", "已完结"]) { $0 } == 2)
    #expect(SearchMerge.lead(["13057:27", "45:10"]) { $0 } == 0)
    #expect(SearchMerge.lead(["", "13057:27"]) { $0 } == 0)
    #expect(SearchMerge.lead(["13057:27", "", "全46集"]) { $0 } == 2)
    #expect(SearchMerge.lead([String]()) { $0 } == 0)
}

@Test func tellsAPlayLengthFromOtherRemarks() {
    for length in ["13057:27", "1:17:00", "05:30", " 45:10 "] { #expect(SearchMerge.isDuration(length), "\(length)") }
    for other in ["全46集", "更新至12集", "HD", "", "2019", "12:", "1:7", "第3:00集", "更新至 20:00", "1:60"] {
        #expect(!SearchMerge.isDuration(other), "\(other)")
    }
}
