import Foundation
import Testing
@testable import WebHTVCore

/// IOS-POC-10B: filter rows showed their API token as the label while the chips under them were
/// Chinese.
@Suite struct FilterNameTests {
    private func filter(key: String, name: String) throws -> CMSFilter {
        let json = #"{"key":"\#(key)","name":"\#(name)","value":[{"n":"全部","v":""}]}"#
        return try JSONDecoder().decode(CMSFilter.self, from: Data(json.utf8))
    }

    @Test func theApiTokensBecomeChinese() throws {
        #expect(try filter(key: "class", name: "class").displayName == "類型")
        #expect(try filter(key: "area", name: "area").displayName == "地區")
        #expect(try filter(key: "by", name: "sort").displayName == "排序")
        #expect(try filter(key: "year", name: "YEAR").displayName == "年代")
    }

    @Test func aProviderThatAlreadyLabelsItsRowsIsLeftAlone() throws {
        // The whole point of a closed table: unknown wording is the provider's, not a mistake.
        #expect(try filter(key: "class", name: "題材").displayName == "題材")
        #expect(try filter(key: "custom", name: "獨家分類").displayName == "獨家分類")
    }

    @Test func simplifiedRowNamesBecomeTraditional() throws {
        #expect(try filter(key: "class", name: "类型").displayName == "類型")
        #expect(try filter(key: "area", name: "地区").displayName == "地區")
    }

    @Test func anEmptyNameFallsBackToTheKeyRatherThanABlankLabel() throws {
        #expect(try filter(key: "area", name: "").displayName == "地區")
        #expect(try filter(key: "mystery", name: "").displayName == "mystery")
    }
}
