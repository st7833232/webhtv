import Foundation
import Testing
@testable import WebHTVCore

/// The defect these cover is IOS-POC-10C: `Site.id` embeds a NUL, `UserDefaults` truncates there,
/// and the app reopened on the wrong source every launch.
@Suite struct SiteSelectionTests {
    private func site(key: String, ext: String) throws -> Site {
        let json = #"{"key":"\#(key)","name":"\#(key)","type":3,"api":"csp_AppGet","ext":"\#(ext)"}"#
        return try JSONDecoder().decode(Site.self, from: Data(json.utf8))
    }

    @Test func aTokenSurvivesTheNulThatUserDefaultsTruncates() throws {
        let one = try site(key: "php_无水印资源", ext: "https://a.example/api")
        #expect(one.id.contains("\u{0}"), "the identity this guards still has to contain a NUL")
        let token = SiteSelection.token(for: one.id)
        #expect(!token.contains("\u{0}"))
        #expect(SiteSelection.resolve(token, in: [one]) == one.id)
    }

    @Test func twoSitesSharingAKeyStayDistinct() throws {
        let a = try site(key: "爱影", ext: "https://a.example/api")
        let b = try site(key: "爱影", ext: "https://b.example/api")
        #expect(a.id != b.id)
        #expect(SiteSelection.resolve(SiteSelection.token(for: b.id), in: [a, b]) == b.id)
    }

    @Test func objectExtOrderingIsStable() throws {
        let aJSON = #"{"key":"linghu","name":"x","type":3,"api":"csp_AppGet","ext":{"url":"https://a","dataKey":"k"}}"#
        let bJSON = #"{"key":"linghu","name":"x","type":3,"api":"csp_AppGet","ext":{"dataKey":"k","url":"https://a"}}"#
        let a = try JSONDecoder().decode(Site.self, from: Data(aJSON.utf8))
        let b = try JSONDecoder().decode(Site.self, from: Data(bJSON.utf8))
        #expect(a.id == b.id)
    }

    @Test func preCanonicalObjectTokenResolves() throws {
        let json = #"{"key":"linghu","name":"x","type":3,"api":"csp_AppGet","ext":{"dataKey":"k","url":"https://a"}}"#
        let site = try JSONDecoder().decode(Site.self, from: Data(json.utf8))
        let oldID = "linghu\u{0}{\"url\":\"https://a\",\"dataKey\":\"k\"}"
        #expect(SiteSelection.resolve(SiteSelection.token(for: oldID), in: [site]) == site.id)
    }

    @Test func aLegacyTruncatedValueStillFindsItsSite() throws {
        let other = try site(key: "无水", ext: "https://other.example/api")
        let wanted = try site(key: "php_无水印资源", ext: "https://a.example/api")
        // Exactly what was found on disk before the fix: the key alone, the ext gone.
        #expect(SiteSelection.resolve("php_无水印资源", in: [other, wanted]) == wanted.id)
    }

    @Test func aChangedExtStillFindsAKeyUsedOnce() throws {
        let before = try site(key: "薦片", ext: "https://old.example/jianpian.json")
        let after = try site(key: "薦片", ext: "https://new.example/jianpian.json")
        let other = try site(key: "爱影", ext: "https://a.example/api")
        #expect(SiteSelection.resolve(SiteSelection.token(for: before.id), in: [other, after]) == after.id)
    }

    @Test func aChangedExtDoesNotGuessBetweenARepeatedKey() throws {
        let before = try site(key: "爱影", ext: "https://old.example/api")
        let a = try site(key: "爱影", ext: "https://a.example/api")
        let b = try site(key: "爱影", ext: "https://b.example/api")
        #expect(SiteSelection.resolve(SiteSelection.token(for: before.id), in: [a, b]) == nil)
    }

    /// IOS-POC-19: the remembered site first, then the one showing, then the first.
    @Test func choosingPrefersTheRememberedSiteThenTheCurrentThenTheFirst() throws {
        let first = try site(key: "a", ext: "https://a.example/api")
        let showing = try site(key: "b", ext: "https://b.example/api")
        let remembered = try site(key: "c", ext: "https://c.example/api")
        let sites = [first, showing, remembered]
        let token = SiteSelection.token(for: remembered.id)
        #expect(SiteSelection.choose(remembered: token, current: showing.id, in: sites) == remembered.id)
        #expect(SiteSelection.choose(remembered: nil, current: showing.id, in: sites) == showing.id)
        #expect(SiteSelection.choose(remembered: token, current: nil, in: [first, showing]) == first.id)
        #expect(SiteSelection.choose(remembered: nil, current: "gone\u{0}", in: sites) == first.id)
        #expect(SiteSelection.choose(remembered: token, current: nil, in: []) == nil)
    }

    @Test func nothingStoredAndNothingMatchingBothAnswerNil() throws {
        let one = try site(key: "a", ext: "https://a.example/api")
        #expect(SiteSelection.resolve(nil, in: [one]) == nil)
        #expect(SiteSelection.resolve("", in: [one]) == nil)
        #expect(SiteSelection.resolve(SiteSelection.token(for: "gone\u{0}{}"), in: [one]) == nil)
    }
}
