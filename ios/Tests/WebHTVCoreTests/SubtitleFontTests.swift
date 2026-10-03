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
    // The family mpv asks for is the one inside the file (name table, stored as UTF-16BE).
    let family = Data(SubtitleFont.family.unicodeScalars.flatMap { [UInt8(0), UInt8($0.value & 0xFF)] })
    #expect(data.range(of: family) != nil)
}
