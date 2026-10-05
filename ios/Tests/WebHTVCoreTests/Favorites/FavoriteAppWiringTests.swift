import Foundation
import Testing

// IOS-POC-48 — the app-target rules the compiler cannot see, pinned the way
// `ExternalPlayerRemovalTests` pins its own: by reading the app's source. The rules themselves are
// tested in WebHTVCore; these check that the screens use them and do not grow around them.

private func appSource() throws -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: ios.appendingPathComponent("WebHTVApp/Sources/WebHTVApp.swift"), encoding: .utf8)
}

/// One top-level declaration: from its header to its closing brace in the first column.
private func declaration(_ header: String, in source: String) throws -> String {
    let start = try #require(source.range(of: header), "\(header) is gone")
    let end = try #require(source[start.upperBound...].range(of: "\n}\n"))
    return String(source[start.lowerBound..<end.upperBound])
}

/// A9 and HIG's "avoid overflow tabs": five tabs, 片庫 where 記錄 was, no sixth for favourites.
@Test func theTabBarIsFiveTabsWithTheLibraryInTheMiddle() throws {
    let regex = try NSRegularExpression(pattern: #"\.tabItem \{ Label\("([^"]+)""#)
    let source = try appSource()
    let labels = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
        Range($0.range(at: 1), in: source).map { String(source[$0]) }
    }
    #expect(labels == ["首頁", "搜尋", "片庫", "下載", "設定"])
}

/// IOS-UI-A3 (user's device report): 記錄 first and the page the library opens on; the choice is
/// the Cinematic Minimal chips, not a segmented picker.
@Test func theLibraryShowsBothPagesAndOpensOnHistory() throws {
    let library = try declaration("private struct LibraryView: View {", in: try appSource())
    #expect(library.contains("@State private var section = LibrarySection.history"))
    #expect(library.contains("ForEach([LibrarySection.history, .favorites])"))
    #expect(library.contains("CinematicChoice("))
    #expect(library.contains("FavoritesView(sites: sites, source: source)"))
    #expect(library.contains("HistoryView(sites: sites, source: source)"))
}

/// A11: the watch history screen deletes watch history. IOS-POC-47 had it delete the title's
/// downloads too; the user's rule since IOS-POC-48 is that downloads are deleted on the downloads
/// screen only.
@Test func deletingWatchHistoryNeverDeletesDownloadsOrFavorites() throws {
    let history = try declaration("private struct HistoryView: View {", in: try appSource())
    for needle in ["OfflineDownloads.manager", "offlineLibrary", "FavoriteStore", "favoriteLibrary"] {
        #expect(!history.contains(needle), "HistoryView reaches into \(needle)")
    }
}

/// A11: the favourites screens read the watch history and the downloads, and never write them.
@Test func theFavoritesScreensOnlyReadHistoryAndDownloads() throws {
    let source = try appSource()
    for header in ["final class FavoriteLibrary {", "private struct FavoritesView: View {",
                   "private struct FavoriteCard: View {", "private struct FavoriteUnavailableView: View {"] {
        let body = try declaration(header, in: source)
        for needle in ["WatchHistoryStore.shared.save", "WatchHistoryStore.shared.remove", "WatchHistoryStore.shared.clear",
                       "OfflineDownloads.manager"] {
            #expect(!body.contains(needle), "\(header) calls \(needle)")
        }
    }
}

/// A8: the favourite is a secondary action in the bar; 立即播放 stays the full-width prominent button
/// (since IOS-UI-A2 an accent-filled button rather than `.borderedProminent`).
@Test func playNowStaysTheFullWidthPrimaryAction() throws {
    let detail = try declaration("private struct VodView: View {", in: try appSource())
    let play = try #require(detail.range(of: #"Text(resolving ? "準備播放…" : "立即播放")"#))
    let following = detail[play.upperBound...].prefix(500)
    #expect(following.contains(".frame(maxWidth: .infinity"))
    #expect(following.contains(".background(appAccent"))
    #expect(detail.contains("ToolbarItem(placement: .topBarTrailing) { detailFavorite }"))
    let favorite = try #require(detail.range(of: "private var detailFavorite: some View {"))
    #expect(detail[favorite.upperBound...].prefix(200).contains("FavoriteToggle("))
}

/// A8: no alert, no confirmation, and Reduce Motion turns the bounce off.
@Test func theFavoriteToggleAsksNothingAndRespectsReduceMotion() throws {
    let toggle = try declaration("private struct FavoriteToggle: View {", in: try appSource())
    for needle in [".alert", ".confirmationDialog", ".sheet"] {
        #expect(!toggle.contains(needle))
    }
    #expect(toggle.contains("accessibilityReduceMotion"))
    #expect(toggle.contains("if now && !reduceMotion"))
    #expect(toggle.contains(#""heart.fill" : "heart""#))
}
