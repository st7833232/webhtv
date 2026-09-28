import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-33. What these pin down: a keyword typed in Traditional is also searched as typed, after the
// Simplified form the sources index, so a site with Traditional titles finds them; a keyword with
// nothing to convert is sent once, exactly as before; the first answer stays exactly as the source
// sent it and a later form only adds titles it lacks; one form answering is enough; and 載入更多
// pages a form from where it really is (page 2 after an answer, page 1 after a cut-off, never after a
// failure) and only while it adds titles, which with one form is the rule it always had.

@Test func searchesTheTypedFormOnlyWhenItDiffers() {
    #expect(DualScriptSearch.forms(of: "慶餘年") == ["庆余年", "慶餘年"])
    #expect(DualScriptSearch.forms(of: "庆余年") == ["庆余年"])
    #expect(DualScriptSearch.forms(of: "Friends") == ["Friends"])
    #expect(DualScriptSearch.forms(of: "1080") == ["1080"])
    // 髮 is not in the search table, so the Simplified form is mixed, and the typed one still goes.
    #expect(DualScriptSearch.forms(of: "頭髮") == ["头髮", "頭髮"])
}

@Test func keepsTheFirstAnswerAsSentAndAddsOnlyNewTitles() async throws {
    let answer = try await DualScriptSearch.firstPage(
        forms: ["庆余年", "慶餘年"], titles: { $0 },
        search: { keyword in
            keyword == "庆余年" ? [title("2"), title("1"), title("2")] : [title("1"), title("3")]
        })
    // The source's own repeat stays where it was; 1 is not added a second time.
    #expect(answer.vods.map(\.id) == ["2", "1", "2", "3"])
    #expect(answer.cursor.pending == [.init(keyword: "庆余年", page: 2), .init(keyword: "慶餘年", page: 2)])
}

@Test func oneFormAnsweringIsEnough() async throws {
    struct Refused: Error {}
    let answer = try await DualScriptSearch.firstPage(
        forms: ["a", "b"], titles: { $0 },
        search: { keyword in
            if keyword == "a" { throw Refused() }
            return [title("9")]
        })
    #expect(answer.vods.map(\.id) == ["9"])
    // The form that failed is not paged.
    #expect(answer.cursor.pending == [.init(keyword: "b", page: 2)])
    await #expect(throws: Refused.self) {
        _ = try await DualScriptSearch.firstPage(
            forms: ["a", "b"], titles: { $0 }, search: { _ in throw Refused() })
    }
}

@Test func aLaterFormThatAddsNothingIsNotPaged() async throws {
    // A site that folds the two scripts itself answers both the same: paging the typed form would
    // only fetch the same pages twice.
    let answer = try await DualScriptSearch.firstPage(
        forms: ["a", "b"], titles: { $0 }, search: { _ in [title("1")] })
    #expect(answer.vods.map(\.id) == ["1"])
    #expect(answer.cursor.pending == [.init(keyword: "a", page: 2)])
}

@Test func pagesEachFormOnlyWhileItAddsTitles() async {
    // "a" has a page 2 and then ends; "b" repeats a title already shown, as a source that ignores pg does.
    let pages: [String: [Int: [Vod]]] = ["a": [2: [title("3")], 3: []], "b": [2: [title("2")]]]
    let start = DualScriptSearch.Cursor(pending: [.init(keyword: "a", page: 2), .init(keyword: "b", page: 2)])
    let first = await DualScriptSearch.nextPage(after: [title("1"), title("2")], cursor: start) { keyword, page in
        pages[keyword]?[page] ?? []
    }
    #expect(first.vods.map(\.id) == ["1", "2", "3"])
    #expect(first.cursor.pending == [.init(keyword: "a", page: 3)])
    let second = await DualScriptSearch.nextPage(after: first.vods, cursor: first.cursor) { keyword, page in
        pages[keyword]?[page] ?? []
    }
    #expect(second.vods.map(\.id) == ["1", "2", "3"])
    #expect(second.cursor.isFinished)
}

@Test func pagesACutOffFormFromItsFirstPage() async {
    // The deadline passed while "b" was still on page 1, so its page 1 has never been shown.
    let start = DualScriptSearch.Cursor(pending: [.init(keyword: "a", page: 2), .init(keyword: "b", page: 1)])
    let next = await DualScriptSearch.nextPage(after: [title("1")], cursor: start) { keyword, page in
        if keyword == "a", page == 2 { return [title("2")] }
        if keyword == "b", page == 1 { return [title("3")] }
        return []
    }
    #expect(next.vods.map(\.id) == ["1", "2", "3"])
    #expect(next.cursor.pending == [.init(keyword: "a", page: 3), .init(keyword: "b", page: 2)])
}

@Test func aFailingFormStopsWithoutStoppingTheOther() async {
    struct Refused: Error {}
    let start = DualScriptSearch.Cursor(pending: [.init(keyword: "庆余年", page: 2), .init(keyword: "慶餘年", page: 2)])
    let next = await DualScriptSearch.nextPage(after: [title("1")], cursor: start) { keyword, _ in
        if keyword == "庆余年" { throw Refused() }
        return [title("2")]
    }
    #expect(next.vods.map(\.id) == ["1", "2"])
    #expect(next.cursor.pending == [.init(keyword: "慶餘年", page: 3)])
}

@Test func oneFormPagesAsLoadMoreAlwaysHas() async throws {
    let answer = try await DualScriptSearch.firstPage(
        forms: DualScriptSearch.forms(of: "Friends"), titles: { $0 }, search: { _ in [title("1")] })
    #expect(answer.cursor.pending == [.init(keyword: "Friends", page: 2)])
    let repeated = await DualScriptSearch.nextPage(after: answer.vods, cursor: answer.cursor) { _, _ in [title("1")] }
    #expect(repeated.vods.map(\.id) == ["1"])
    #expect(repeated.cursor.isFinished)
}

// MARK: - Helpers

private func title(_ id: String) -> Vod { Vod(id: id, name: "片名\(id)", picture: "") }
