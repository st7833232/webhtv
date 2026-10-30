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

@Test func decodesCommentedConfigAndKeepsURLStrings() throws {
    let standard = #"{"sites":[{"key":"cms","name":"CMS","type":1,"api":"http://example.com/api.php/provide/vod"}]}"#
    let commented = """
    // 网盘资源区
    {"sites":[
      //{"key":"off","name":"Off","type":1,"api":"http://example.com/off"},
      {"key":"cms","name":"CMS","type":1,"api":"http://example.com/api.php/provide/vod"} /* tail */
    ]}
    """
    for text in [standard, commented] {
        let config = try ConfigLoader.decode(Data(text.utf8))
        #expect(config.sites.map(\.key) == ["cms"])
        #expect(config.sites[0].api == "http://example.com/api.php/provide/vod")
    }
    #expect(throws: (any Error).self) { try ConfigLoader.decode(Data("not json".utf8)) }
    #expect(throws: (any Error).self) { try ConfigLoader.decode(Data(#"{"sites":["#.utf8)) }
}

@Test func decodesProvidedQistXYQConfig() throws {
    guard let path = ProcessInfo.processInfo.environment["QIST_XYQ_JSON"] else { return }
    let config = try ConfigLoader.decode(Data(contentsOf: URL(fileURLWithPath: path)))

    #expect(config.sites.count == 49)
    #expect(config.sites.first { $0.key == "csp_JianPian" }?.rawExtJSON.contains("http://39.108.238.168:20000") == true)
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

// W-228: FongMi's wrapped configuration formats (`Decoder.verify`), built here from a synthetic config.
private let wrappedSource = #"{"sites":[{"key":"cms","name":"CMS","type":1,"api":"https://example.com/api.php/provide/vod"}]}"#

/// `Decoder.cbc` read backwards: hex of `$#<key>#$`, the AES-CBC ciphertext, then the 13-character IV.
private func cbcWrapped(_ plain: String, key: String = "w228key", iv: String = "1234567890123") -> String {
    func hex(_ text: String) -> String { Data(text.utf8).map { String(format: "%02x", $0) }.joined() }
    let pad = { (value: String) in value + String(repeating: "0", count: 16 - value.count) }
    let cipher = CryptoHost.run(algorithm: "aes", encrypt: true, input: plain, key: pad(key), iv: pad(iv),
                                mode: "CBC", inputEncoding: "hex")
    return hex("$#\(key)#$") + cipher + hex(iv)
}

@Test func decodesFongMiBase64AndCBCWrappedConfigs() throws {
    let base64 = "// header\nAbCd1234**" + Data(wrappedSource.utf8).base64EncodedString()
    let cbc = cbcWrapped(wrappedSource)
    let cbcWithWhitespace = String(cbc.prefix(40)) + "\n  " + String(cbc.dropFirst(40))
    let both = "Zz9Yy8Xx**" + Data(cbc.utf8).base64EncodedString()
    for text in [base64, cbc, cbcWithWhitespace, both] {
        let config = try ConfigLoader.decode(Data(text.utf8))
        #expect(config.sites.map(\.key) == ["cms"], "\(text.prefix(12))")
        #expect(config.sites[0].api == "https://example.com/api.php/provide/vod")
    }
    #expect(cbc.hasPrefix("2423"))
}

@Test func leavesJSONAloneAndRejectsBrokenWrappers() throws {
    // A real JSON object is never unwrapped, even when a value happens to contain the markers.
    let json = #"{"sites":[{"key":"k","name":"AbCd1234**x","type":1,"api":"https://example.com/2423"}]}"#
    #expect(ConfigLoader.unwrapped(Data(json.utf8)) == Data(json.utf8))
    #expect(try ConfigLoader.decode(Data(json.utf8)).sites[0].name == "AbCd1234**x")

    let cbc = cbcWrapped(wrappedSource)
    for broken in ["2423zz", "2423" + String(repeating: "00", count: 20), String(cbc.dropLast(26)),
                   // The same ciphertext behind a different `$#key#$` (18 hex digits instead of 22): wrong key.
                   String(cbcWrapped("x", key: "other").prefix(18)) + String(cbc.dropFirst(22)),
                   "AbCd1234**%%%not base64%%%", "ab**" + Data(wrappedSource.utf8).base64EncodedString()] {
        #expect(throws: (any Error).self, "\(broken.prefix(16))") { try ConfigLoader.decode(Data(broken.utf8)) }
    }
    #expect(ConfigLoader.cbc("2423zz") == nil)
}
