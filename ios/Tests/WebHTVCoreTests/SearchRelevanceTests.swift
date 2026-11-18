import Testing
@testable import WebHTVCore

// W-312 A1. What these pin down: the title that is the keyword ranks first, then titles that start with it,
// then titles that contain it, then the rest; Traditional, full-width and spacing differences do not matter;
// a trailing tag does not demote the work itself.

@Test func ranksTheKeywordItselfFirstThenPrefixThenContains() {
    #expect(SearchRelevance.score(title: "慶餘年", keyword: "庆余年") == 3)
    #expect(SearchRelevance.score(title: "庆余年 (2019)", keyword: "慶餘年") == 3)
    #expect(SearchRelevance.score(title: "庆余年[电影解说]", keyword: "庆余年") == 3)
    #expect(SearchRelevance.score(title: "慶餘年 第二季", keyword: "庆余年") == 2)
    #expect(SearchRelevance.score(title: "一口氣看完《慶餘年》", keyword: "庆余年") == 1)
    #expect(SearchRelevance.score(title: "慶州紀行", keyword: "庆余年") == 0)
    #expect(SearchRelevance.score(title: "anything", keyword: "  ") == 0)
}

@Test func foldsWidthCaseSpacingAndPunctuation() {
    #expect(SearchRelevance.score(title: "Ｓｔｒａｎｇｅｒ Ｔｈｉｎｇｓ", keyword: "stranger things") == 3)
    #expect(SearchRelevance.score(title: "怪奇物語：1985故事集", keyword: "怪奇物语") == 2)
    #expect(SearchRelevance.score(title: "哪吒之魔童闹海", keyword: "哪吒") == 2)
}

@Test func dropsOnlyShortTrailingTags() {
    #expect(SearchRelevance.withoutTrailingTags("老友记 第十季 (1994) [国语]") == "老友记 第十季")
    #expect(SearchRelevance.withoutTrailingTags("片名(这是一段超过十二个字的很长很长的说明文字)") == "片名(这是一段超过十二个字的很长很长的说明文字)")
    #expect(SearchRelevance.withoutTrailingTags("(2019)") == "")
}
