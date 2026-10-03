import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-45D. The bundled subtitle font is what keeps MPV's Chinese subtitles from being boxes;
// these pin the two properties that make it work.

/// The folder mpv is given holds exactly one font, and it is CFF OpenType ("OTTO"): FreeType reads
/// CFF, unlike the hvgl-only PingFang it replaces. A second file would be read into memory too.
@Test func theSubtitleFontFolderHoldsOneCFFFontAndNothingElse() throws {
    let directory = try #require(SubtitleFont.directory)
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }
    #expect(files == ["WebHTVSubtitleCJK-Regular.otf"])
    let data = try Data(contentsOf: directory.appendingPathComponent(files[0]))
    #expect(data.prefix(4) == Data("OTTO".utf8))
    #expect(data.count > 1 << 20)
    let tables = sfntTables(data)
    #expect(tables["CFF "] != nil && tables["hvgl"] == nil && tables["glyf"] == nil)
    // The family libass matches `sub-font` against: name ID 1, Windows platform, exactly.
    #expect(familyName(data, tables) == SubtitleFont.family)
}

/// The sfnt table directory: tag → (offset, length).
private func sfntTables(_ data: Data) -> [String: (Int, Int)] {
    func u16(_ at: Int) -> Int { Int(data[at]) << 8 | Int(data[at + 1]) }
    func u32(_ at: Int) -> Int { u16(at) << 16 | u16(at + 2) }
    var tables = [String: (Int, Int)]()
    for index in 0..<u16(4) {
        let record = 12 + index * 16
        let tag = String(decoding: data[record..<record + 4], as: UTF8.self)
        tables[tag] = (u32(record + 8), u32(record + 12))
    }
    return tables
}

/// Name ID 1 of platform 3 (Windows, UTF-16BE), as libass reads it.
private func familyName(_ data: Data, _ tables: [String: (Int, Int)]) -> String? {
    guard let (name, _) = tables["name"] else { return nil }
    func u16(_ at: Int) -> Int { Int(data[at]) << 8 | Int(data[at + 1]) }
    let count = u16(name + 2), strings = name + u16(name + 4)
    for index in 0..<count {
        let record = name + 6 + index * 12
        guard u16(record) == 3, u16(record + 6) == 1 else { continue }
        let start = strings + u16(record + 10), length = u16(record + 8)
        let units = stride(from: start, to: start + length, by: 2).map { UInt16(u16($0)) }
        return String(decoding: units, as: UTF16.self)
    }
    return nil
}
