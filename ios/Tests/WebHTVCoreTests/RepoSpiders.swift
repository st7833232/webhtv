import Foundation

extension Bundle {
    /// IOS-POC-61 S5: the spiders left the App for the repository's `ios/Spiders`, which only the pack tools and the
    /// tests read. A plain directory is a bundle, so `ios/` is one whose `Spiders` subdirectory is that folder.
    static let repoSpiders = Bundle(url: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent())!
}
