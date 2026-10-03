import Foundation

/// IOS-POC-45D — the font MPV draws subtitles with.
///
/// libass reads fonts through FreeType, and FreeType 2.14.3 cannot read iOS 18+'s PingFang
/// (`PingFangUI.ttc` keeps its outlines only in Apple's `hvgl` table): Chinese came out as boxes,
/// and every missing character set off a fresh font search on every frame. This is a subset of
/// Noto Sans CJK TC with CFF outlines, renamed, under the SIL Open Font License
/// (`Resources/SubtitleFont/README.md` records the source, recipe and hashes).
public enum SubtitleFont {
    /// The family name inside the bundled file, for mpv's `sub-font`.
    public static let family = "WebHTV Subtitle CJK"

    /// The folder for mpv's `sub-fonts-dir`. It holds the font and nothing else: libass reads
    /// every file in that folder into memory. Nil if the resource is missing from the build.
    public static var directory: URL? {
        guard let root = Bundle.module.url(forResource: "SubtitleFont", withExtension: nil) else { return nil }
        let fonts = root.appendingPathComponent("fonts", isDirectory: true)
        return FileManager.default.fileExists(atPath: fonts.path) ? fonts : nil
    }
}
