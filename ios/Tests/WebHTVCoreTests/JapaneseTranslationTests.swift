import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-32 D. What these pin down: only Japanese goes to the translator, title and synopsis are
// judged apart (a Chinese title over a Japanese synopsis must not be sent, or the title comes back
// mangled), a Japanese name in brackets does not make a Chinese title Japanese, and the feature
// stays off until the user turns it on.

private let japaneseSynopsis = "東京の高校生探偵・工藤新一は、幼なじみの毛利蘭と遊園地に遊びに行った帰りに、怪しい取引を目撃する。"

@Test func aJapaneseTitleAndSynopsisAreBothSent() {
    let texts = JapaneseTranslation.texts(title: "名探偵コナン 30号殺人事件", synopsis: japaneseSynopsis)
    #expect(texts.title == "名探偵コナン 30号殺人事件")
    #expect(texts.synopsis == japaneseSynopsis)
}

@Test func aChineseTitleOverAJapaneseSynopsisSendsOnlyTheSynopsis() {
    let texts = JapaneseTranslation.texts(title: "名侦探柯南：30号杀人事件", synopsis: japaneseSynopsis)
    #expect(texts.title == nil)
    #expect(texts.synopsis == japaneseSynopsis)
}

@Test func aJapaneseNameInBracketsDoesNotMakeAChineseTitleJapanese() {
    // Without the brackets' content the kana would outnumber the Han four to three.
    #expect(TaiwanTraditional.isJapanese("海贼王（ワンピース）"))
    #expect(JapaneseTranslation.texts(title: "海贼王（ワンピース）", synopsis: "").title == nil)
    #expect(JapaneseTranslation.texts(title: "【独占】ソードアート・オンライン", synopsis: "").title
        == "【独占】ソードアート・オンライン")
}

@Test func chineseAndForeignNamesWithAMiddleDotAreNotSent() {
    let texts = JapaneseTranslation.texts(title: "湯姆・克魯斯的不可能任務", synopsis: "一部中文簡介。")
    #expect(texts.isEmpty)
}

@Test func translationIsOffUntilTheUserTurnsItOn() throws {
    let defaults = try #require(UserDefaults(suiteName: "japanese-translation-\(UUID())"))
    let preference = JapaneseTranslationPreference(defaults: defaults)
    #expect(preference.mode == .off)
    preference.setMode(.auto)
    #expect(JapaneseTranslationPreference(defaults: defaults).mode == .auto)
    defaults.set("something-else", forKey: JapaneseTranslationPreference.key)
    #expect(preference.mode == .off)
}
