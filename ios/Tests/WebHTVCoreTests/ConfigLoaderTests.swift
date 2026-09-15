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

    #expect(config.sites.count == 167)
    #expect(config.nativeCMSSites.count == 30)
    #expect(config.nativeCMSSites.filter { $0.type == 4 }.count == 6)
    #expect(config.nativeCMSSites.contains { $0.name.contains("索尼") })
}

@Test func classifiesType4SitesAndToleratesNonDictionaryExt() throws {
    let data = Data(#"""
    {"sites":[
      {"key":"t4dict","name":"Dict","type":4,"api":"https://example.com/php/","ext":{"module_name":"CmsSuggest"}},
      {"key":"t4str","name":"Str","type":4,"api":"http://example.com/a.php","ext":"whatever"},
      {"key":"t4num","name":"Num","type":4,"api":"http://example.com/b.php","ext":0},
      {"key":"t4none","name":"None","type":4,"api":"http://192.0.2.1:5757/api/枫林影视"},
      {"key":"spider","name":"Spider","type":3,"api":"csp_Test"}
    ]}
    """#.utf8)
    let config = try ConfigLoader.decode(data)

    #expect(config.sites.count == 5)
    #expect(config.nativeCMSSites.map(\.key) == ["t4dict", "t4str", "t4num", "t4none"])
    #expect(config.sites.first { $0.key == "t4dict" }?.ext == ["module_name": "CmsSuggest"])
    #expect(config.sites.first { $0.key == "t4str" }?.ext == nil)
    #expect(config.sites.first { $0.key == "t4num" }?.ext == nil)
}
