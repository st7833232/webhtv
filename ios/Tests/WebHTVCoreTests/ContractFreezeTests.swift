import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-12. Goldens for the identities a runtime scope and every persisted record are keyed on.
// Each was only covered indirectly before; any change here orphans a cache, a watch-history record
// or a runtime generation, so it has to arrive with a migration and fail this file first.

private let address = "https://example.invalid/repo/raw/main/wang-movie.json"

private func site(_ json: String) throws -> Site {
    try JSONDecoder().decode(Site.self, from: Data(json.utf8))
}

/// K12: the configuration identity is the address exactly as given — never normalised, because
/// watch history, site memory and the runtime scope all compare it byte for byte.
@Test func theConfigurationIdentityIsTheAddressAsWritten() throws {
    #expect(ConfigSource.remote(try #require(URL(string: address))).identity == address)
    #expect(ConfigSource.importedFile.identity == "imported")
    for variant in ["https://EXAMPLE.invalid/repo/raw/main/wang-movie.json", address + "/", address + "?x=1", address + "#top"] {
        #expect(ConfigSource.remote(try #require(URL(string: variant))).identity == variant)
    }
    #expect(SavedSource(name: "", url: try #require(URL(string: address))).id == address)
}

/// K22: each source's cached configuration file name, base64url of the address without padding.
@Test func theCacheFileNameIsTheBase64URLOfTheAddress() throws {
    let source = SavedSource(name: "任何名字", url: try #require(URL(string: address)))
    #expect(source.cacheFileName == "aHR0cHM6Ly9leGFtcGxlLmludmFsaWQvcmVwby9yYXcvbWFpbi93YW5nLW1vdmllLmpzb24.json")
}

/// K13: a site is its key plus its `ext` with object keys sorted, so two sites sharing a key stay
/// two sites and a reordered `ext` stays the same one.
@Test func theSiteIdentityIsTheKeyAndTheSortedExtend() throws {
    let object = try site(#"{"key":"爱影","name":"a","type":3,"api":"csp_AppQi","ext":{"url":"https://b.invalid","site":"x"}}"#)
    #expect(object.id == "爱影\u{0}{\"site\":\"x\",\"url\":\"https:\\/\\/b.invalid\"}")
    let reordered = try site(#"{"key":"爱影","name":"b","type":3,"api":"csp_AppQi","ext":{"site":"x","url":"https://b.invalid"}}"#)
    #expect(reordered.id == object.id)
    #expect(try site(#"{"key":"k","name":"n","type":3,"api":"csp_XBPQ","ext":"./json/a.json"}"#).id == "k\u{0}./json/a.json")
    #expect(try site(#"{"key":"k","name":"n","type":1,"api":"https://a.invalid/api.php","ext":7}"#).id == "k\u{0}7")
    #expect(try site(#"{"key":"k","name":"n","type":1,"api":"https://a.invalid/api.php"}"#).id == "k\u{0}")
}

/// K34: a watch-history record is keyed on the site identity and the vod id; Android sees only
/// `siteKey@@@vodId`.
@Test func theWatchHistoryKeyIsTheSiteIdentityAndTheVodID() {
    #expect(WatchHistory.key(siteID: "k\u{0}7", vodId: "123") == "k\u{0}7@@@123")
    #expect(WatchHistory.separator == "@@@")
}
