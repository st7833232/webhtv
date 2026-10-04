import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-48 A3: an imported configuration file has an identity of its own, given to its content
// when it is first imported and kept from then on.

private func scratchDefaults() -> UserDefaults {
    UserDefaults(suiteName: "imported-identity-tests-\(UUID().uuidString)")!
}

private let legacyFile = Data(#"{"sites":[{"key":"a","name":"A","type":1,"api":"https://a.example"}]}"#.utf8)
private let fileB = Data(#"{"sites":[{"key":"b","name":"B","type":1,"api":"https://b.example"}]}"#.utf8)
private let fileC = Data(#"{"sites":[{"key":"c","name":"C","type":1,"api":"https://c.example"}]}"#.utf8)

/// The file imported before IOS-POC-48 keeps `"imported"`, so the watch history, site memory and
/// health records already bound to it stay bound (and `ContractFreezeTests` K12 still holds).
@Test func theFileImportedBeforeKeepsItsIdentity() {
    let identities = ImportedConfigIdentities(defaults: scratchDefaults())
    #expect(identities.identity(of: legacyFile) == ConfigSource.legacyImportedIdentity)
    #expect(ConfigSource.importedFile.identity == "imported")
    #expect(ConfigSource.importedFile == .imported(id: "imported"))
}

@Test func aDifferentFileIsADifferentConfiguration() throws {
    let identities = ImportedConfigIdentities(defaults: scratchDefaults())
    let b = identities.register(fileB, replacing: legacyFile)
    let c = identities.register(fileC, replacing: fileB)
    #expect(b.hasPrefix("imported:") && c.hasPrefix("imported:"))
    #expect(b != c)
    #expect(identities.identity(of: fileB) == b)
    #expect(identities.identity(of: fileC) == c)
    #expect(identities.identity(of: legacyFile) == "imported")
    // Never an address: saved sources are http(s) only, so no remote identity can equal it.
    let scheme = try #require(URL(string: b)?.scheme)
    #expect(scheme != "http" && scheme != "https")
}

/// The settings page cannot switch back to an imported file, so going back means importing the same
/// file again. The same bytes are the same configuration, provably, and get their identity back —
/// including the file imported before IOS-POC-48.
@Test func theSameBytesImportedAgainKeepTheirIdentity() {
    let identities = ImportedConfigIdentities(defaults: scratchDefaults())
    let b = identities.register(fileB, replacing: legacyFile)
    _ = identities.register(fileC, replacing: fileB)
    #expect(identities.register(fileB, replacing: fileC) == b)
    #expect(identities.register(legacyFile, replacing: fileB) == "imported")
}

@Test func theIdentitySurvivesARelaunch() {
    let defaults = scratchDefaults()
    let b = ImportedConfigIdentities(defaults: defaults).register(fileB, replacing: nil)
    #expect(ImportedConfigIdentities(defaults: defaults).identity(of: fileB) == b)
}

/// The importer records the new bytes, then writes the file. A crash between the two leaves the old
/// file on disk, and the old file still reads as the old configuration — there is no separate
/// "current identity" to be left pointing at the wrong file.
@Test func aCrashBeforeTheFileIsWrittenLeavesTheOldIdentity() {
    let identities = ImportedConfigIdentities(defaults: scratchDefaults())
    let b = identities.register(fileB, replacing: nil)
    _ = identities.register(fileC, replacing: fileB)   // …and the app stops before writing C.
    #expect(identities.identity(of: fileB) == b)
}

@Test func everyImportedFileAnchorsNothing() {
    let source = ConfigSource.imported(id: "imported:1234")
    #expect(source.identity == "imported:1234")
    #expect(source.baseURL == nil)
    #expect(source.resourceURL(for: "./jar/fm.jar") == nil)
}
