import Foundation
import Testing

/// IOS-POC-17A. Third-party players were removed from the product at the user's decision
/// (2026-09-23): a URL scheme carries no headers, position, line, quality or history, so it can
/// never be a real playback path. The type, the picker rows and the handoff are deleted, which the
/// compiler already enforces; this pins the part it cannot see — a scheme string or a
/// `LSApplicationQueriesSchemes` entry quietly coming back in the app sources or the plist.
@Test func noThirdPartyPlayerHandoffRemainsInTheApp() throws {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let files = try [ios.appendingPathComponent("WebHTVApp/Sources"),
                     ios.appendingPathComponent("Sources/WebHTVCore")]
        .flatMap { directory in
            try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }
        } + [ios.appendingPathComponent("WebHTVApp/Info.plist")]
    #expect(files.count > 3)

    let forbidden = ["infuse://", "\"infuse\"", "filebox", "senplayer", "open-vidhub",
                     "ExternalPlayer", "LSApplicationQueriesSchemes"]
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        for needle in forbidden {
            #expect(!text.contains(needle), "\(needle) is back in \(file.lastPathComponent)")
        }
    }
}
