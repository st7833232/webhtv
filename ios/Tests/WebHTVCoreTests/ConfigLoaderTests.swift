import Foundation
import Testing
@testable import WebHTVCore

@Test func decodesAndClassifiesSites() throws {
    let data = Data(#"{"sites":[{"key":"cms","name":"CMS","type":1,"api":"https://example.com/api"},{"key":"spider","name":"Spider","type":3,"api":"csp_Test"}]}"#.utf8)
    let config = try ConfigLoader.decode(data)

    #expect(config.sites.count == 2)
    #expect(config.nativeCMSSites.map(\.key) == ["cms"])
}

@Test func decodesProvidedWangMovieConfig() throws {
    guard let path = ProcessInfo.processInfo.environment["WANG_MOVIE_JSON"] else { return }
    let config = try ConfigLoader.decode(Data(contentsOf: URL(fileURLWithPath: path)))

    #expect(config.sites.count == 208)
    #expect(config.nativeCMSSites.count == 24)
    #expect(config.nativeCMSSites.contains { $0.name.contains("索尼") })
}
