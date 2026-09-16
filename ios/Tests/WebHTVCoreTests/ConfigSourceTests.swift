import Foundation
import Testing
@testable import WebHTVCore

/// The real archive layout, measured 2026-09-16: the configuration sits beside jar/, py/, json/,
/// drpy_libs/ and drpy_js/, and the published URL carries a query the base must discard.
private let remote = ConfigSource.remote(
    URL(string: "https://example.com/group/project/-/raw/main/wang-movie.json?ref_type=heads")!
)
private let base = "https://example.com/group/project/-/raw/main/"

@Test func resolvesConfigRelativeResourcesAgainstTheConfigDirectory() {
    #expect(remote.resourceURL(for: "./json/4k.json")?.absoluteString == base + "json/4k.json")
    #expect(remote.resourceURL(for: "./drpy_libs/drpy2.min.js")?.absoluteString == base + "drpy_libs/drpy2.min.js")
    #expect(remote.resourceURL(for: "./drpy_js/x.js")?.absoluteString == base + "drpy_js/x.js")
    #expect(remote.resourceURL(for: "../shared/a.json")?.absoluteString
        == "https://example.com/group/project/-/raw/shared/a.json")
}

@Test func dropsTheChecksumSuffixThatIsNotPartOfThePath() {
    // 96 of the archive's jar references carry ";md5;<hash>". This resolves locations only; the
    // hash is deliberately not verified here.
    #expect(remote.resourceURL(for: "./jar/fm.jar;md5;b0adab2fad1de8871b9533527f407cdf")?.absoluteString
        == base + "jar/fm.jar")
    #expect(remote.resourceURL(for: "./jar/愛影.jar")?.absoluteString == base + "jar/%E6%84%9B%E5%BD%B1.jar")
    #expect(remote.resourceURL(for: "./py/油管-6.py")?.absoluteString == base + "py/%E6%B2%B9%E7%AE%A1-6.py")
}

@Test func leavesAbsoluteReferencesAloneAndRefusesNonResources() {
    #expect(remote.resourceURL(for: "https://cdn.example.com/a.jar")?.absoluteString == "https://cdn.example.com/a.jar")
    // Spider class names are not paths; URL(string:relativeTo:) would otherwise invent a URL.
    #expect(remote.resourceURL(for: "csp_XYZHiker") == nil)
    #expect(remote.resourceURL(for: "jar/fm.jar") == nil)
    #expect(remote.resourceURL(for: "") == nil)
    #expect(remote.resourceURL(for: ";md5;abc") == nil)
}

@Test func anImportedFileAnchorsNothing() {
    // No base URL exists for a file picked out of Files, so relative references cannot resolve.
    #expect(ConfigSource.importedFile.baseURL == nil)
    #expect(ConfigSource.importedFile.resourceURL(for: "./jar/fm.jar") == nil)
    // An absolute reference still stands on its own.
    #expect(ConfigSource.importedFile.resourceURL(for: "https://cdn.example.com/a.jar")?.host == "cdn.example.com")
}

@Test func validationRefusesPayloadsThatMustNotReplaceAGoodCache() throws {
    let usable = Data(#"{"sites":[{"key":"k","name":"n","type":1,"api":"https://example.com/api"}]}"#.utf8)
    #expect(try ConfigLoader.validate(usable).supportedSites.count == 1)

    // Decodes cleanly but drives nothing: type-3 and type-0 are classified, not usable.
    let useless = Data(#"{"sites":[{"key":"s","name":"s","type":3,"api":"csp_Test"},{"key":"x","name":"x","type":0,"api":"https://example.com/xml"}]}"#.utf8)
    #expect(throws: ConfigLoaderError.noSupportedSites) { try ConfigLoader.validate(useless) }
    #expect(throws: (any Error).self) { try ConfigLoader.validate(Data("not json".utf8)) }
}

@Test func countsTheSupportedSitesOfTheSuppliedConfig() throws {
    guard let path = ProcessInfo.processInfo.environment["WANG_MOVIE_JSON"] else { return }
    let config = try ConfigLoader.validate(Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(config.supportedSites.count == 28)
    #expect(config.supportedSites.filter { $0.type == 4 }.count == 6)
}

/// Live check against a real Raw URL. Gated on an environment variable so the suite stays offline
/// by default; the URL is supplied by the operator, not hard-coded, because Core knows no provider.
@Test func fetchesAndAnchorsARealRemoteConfig() async throws {
    guard let value = ProcessInfo.processInfo.environment["WANG_MOVIE_URL"],
          let url = URL(string: value) else { return }
    let (data, config) = try await ConfigLoader.fetch(from: url)
    let source = ConfigSource.remote(url)

    #expect(config.supportedSites.count == 28)
    print("remote config: \(data.count) bytes, \(config.sites.count) sites, \(config.supportedSites.count) supported")

    // The spider entry is the archive's own relative reference; resolve it and prove the resource
    // is really there, which is what makes the config directory the right base URL.
    let spider = try #require(source.resourceURL(for: "./jar/fm.jar;md5;b0adab2fad1de8871b9533527f407cdf"))
    print("resolved: \(spider.absoluteString)")
    var head = URLRequest(url: spider)
    head.httpMethod = "HEAD"
    let (_, response) = try await URLSession.webHTV.data(for: head)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    print("resource HEAD: \(status)")
    #expect(status == 200)
}
