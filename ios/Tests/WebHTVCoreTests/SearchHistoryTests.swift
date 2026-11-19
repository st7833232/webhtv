import Foundation
import Testing
@testable import WebHTVCore

// W-315 A4. What these pin down: newest first, no repeats, at most twelve, blank keywords ignored, one entry
// or all of them can go, and the list is what a fresh instance (a relaunch) reads back.

private func fresh() -> SearchHistory {
    let name = "W315-\(UUID().uuidString)"
    return SearchHistory(defaults: UserDefaults(suiteName: name)!, key: "history")
}

@Test func keepsTheNewestFirstWithoutRepeats() {
    let history = fresh()
    history.add("庆余年")
    history.add(" 哪吒 ")
    #expect(history.add("庆余年") == ["庆余年", "哪吒"])
    #expect(history.add("   ") == ["庆余年", "哪吒"])
}

@Test func keepsTwelveAtMost() {
    let history = fresh()
    for number in 1...13 { history.add("關鍵字\(number)") }
    #expect(history.entries.count == 12)
    #expect(history.entries.first == "關鍵字13")
    #expect(!history.entries.contains("關鍵字1"))
}

@Test func removesOneOrAllAndSurvivesARelaunch() {
    let defaults = UserDefaults(suiteName: "W315-\(UUID().uuidString)")!
    let history = SearchHistory(defaults: defaults, key: "history")
    history.add("怪奇物語")
    history.add("海街日记")
    history.add("鬼灭之刃")
    #expect(history.remove("海街日记") == ["鬼灭之刃", "怪奇物語"])
    #expect(SearchHistory(defaults: defaults, key: "history").entries == ["鬼灭之刃", "怪奇物語"])
    history.clear()
    #expect(SearchHistory(defaults: defaults, key: "history").entries.isEmpty)
}
