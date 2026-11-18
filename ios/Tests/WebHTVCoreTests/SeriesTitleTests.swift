import Testing
@testable import WebHTVCore

// W-312 §4 / W-313 方案 C — the shared series parser. The title table is the one W-312's prototype
// (artifacts/w312/series_proto.py) checks; W-312 and W-313 keep one table, here.

private let titles: [(String, String, Int?, SeriesTitle.Strength)] = [
    ("怪奇物语 第四季", "怪奇物语", 4, .strong),
    ("怪奇物語第五季", "怪奇物语", 5, .strong),
    ("怪奇物语：第一季", "怪奇物语", 1, .strong),
    ("Stranger Things Season 2", "strangerthings", 2, .strong),
    ("黑镜 S03", "黑镜", 3, .strong),
    ("庆余年2", "庆余年", 2, .weak),
    ("庆余年第二季", "庆余年", 2, .strong),
    ("慶餘年 第兩部", "庆余年", 2, .strong),
    ("庆余年", "庆余年", nil, .none),
    ("唐人街探案3", "唐人街探案", 3, .weak),
    ("1917", "1917", nil, .none),
    ("2046", "2046", nil, .none),
    ("长安十二时辰", "长安十二时辰", nil, .none),
    ("西部世界 第十一季", "西部世界", 11, .strong),
    ("某劇 第二十一輯", "某剧", 21, .strong),
    ("老友记第十季(1994)", "老友记", 10, .strong),
    ("鬼灭之刃 剧场版", "鬼灭之刃", nil, .none),
    ("进击的巨人 第三季 Part.2", "进击的巨人第三季part2", nil, .none),
    ("ＸＸＸ：ＸＸＸＸ 第一季", "xxxxxxx", 1, .strong),
    ("XXX：XXXX 第二季", "xxxxxxx", 2, .strong),
    ("狂飙", "狂飙", nil, .none),
    ("007：无暇赴死", "007无暇赴死", nil, .none),
    ("PS5", "ps5", nil, .none),
    ("某劇1", "某剧1", nil, .none),
]

@Test func titlesSplitIntoSeriesAndSeason() {
    for (title, key, season, strength) in titles {
        let parsed = SeriesTitle(title)
        #expect(parsed.baseKey == key, "\(title)")
        #expect(parsed.season == season, "\(title)")
        #expect(parsed.strength == strength, "\(title)")
    }
}

@Test func specialsTagsAndTheSearchableNameAreKept() {
    let special = SeriesTitle("慶餘年 第一季 特別篇")
    #expect(special.special == .special)
    #expect(special.season == 1)
    #expect(special.baseDisplay == "慶餘年")
    #expect(SeriesTitle("鬼滅之刃 劇場版").special == .movie)
    #expect(SeriesTitle("某劇 番外").special == .extra)
    let tagged = SeriesTitle("射鵰英雄傳(2017)[國語]")
    #expect(tagged.tags == ["2017", "國語"])
    #expect(tagged.baseDisplay == "射鵰英雄傳")
    #expect(SeriesTitle("怪奇物語：第五季").baseDisplay == "怪奇物語")
}

@Test func seriesAreGroupedConservativelyAndInSeasonOrder() {
    let groups = SeriesGrouping.groups(["怪奇物语 第四季", "怪奇物語第五季", "怪奇物语", "庆余年2", "庆余年",
                                        "射雕英雄传(2017)", "射雕英雄传(1983)", "鬼灭之刃 剧场版", "鬼灭之刃 第二季"],
                                       title: { $0 })
    #expect(groups == [["怪奇物语", "怪奇物语 第四季", "怪奇物語第五季"], ["庆余年", "庆余年2"],
                       ["射雕英雄传(2017)"], ["射雕英雄传(1983)"], ["鬼灭之刃 第二季", "鬼灭之刃 剧场版"]])
}

/// W-312 §4.5, the rule W-313 notifies by: strong markers only.
@Test func onlyAStrongLaterSeasonOfTheSameSeriesIsNew() {
    let watched = SeriesTitle("慶餘年")
    #expect(SeriesGrouping.isNewerSeason(SeriesTitle("庆余年第二季"), than: watched))
    #expect(!SeriesGrouping.isNewerSeason(SeriesTitle("庆余年2"), than: watched))
    #expect(!SeriesGrouping.isNewerSeason(SeriesTitle("庆余年第一季"), than: watched))
    #expect(!SeriesGrouping.isNewerSeason(SeriesTitle("庆余年第二季 特别篇"), than: watched))
    #expect(!SeriesGrouping.isNewerSeason(SeriesTitle("庆余年之帝王业 第二季"), than: watched))
    #expect(SeriesGrouping.isNewerSeason(SeriesTitle("Stranger Things Season 3"), than: SeriesTitle("Stranger Things S02")))
    #expect(!SeriesGrouping.isNewerSeason(SeriesTitle("第二季"), than: SeriesTitle("第一季")))
}
