import CryptoKit
import Foundation

/// W-311: FongMi's multi-depot configuration — an address whose JSON is `{"urls":[{"name":…,"url":…},…]}`, a list of
/// other configuration addresses (Android `VodConfig.checkJson`/`parseDepot`, docs/W-311-ios-multi-repo-config.md §2).
///
/// Read after unwrapping (`**` base64, `2423` AES), as FongMi does, and before any site validation; when `urls` is there
/// `sites` is ignored, also as FongMi does. Each entry becomes a saved source of its own, so its cache, remembered site,
/// local sites, favourites and history stay apart exactly as for any other saved source.
public enum DepotConfig {
    public struct Entries: Equatable, Sendable {
        public var sources: [SavedSource]
        /// Relative entries left out because there was no address to resolve them against (an imported file).
        public var skippedRelative: Int
    }

    /// The entries of a depot, or nil when `data` is not one. Relative `./`, `../` entries resolve against `url`, the
    /// depot's own address; with no address (a file imported from Files) they are counted and left out. Blank, non-http(s)
    /// and repeated entries are dropped, order kept. Throws `ConfigLoaderError.emptyDepot` when nothing usable is left.
    public static func entries(_ data: Data, from url: URL?) throws -> Entries? {
        guard let object = try? JSONSerialization.jsonObject(with: ConfigLoader.unwrapped(data), options: [.json5Allowed])
                as? [String: Any],
              let items = object["urls"] as? [Any] else { return nil }
        var sources = [SavedSource](), seen = Set<String>(), skipped = 0
        for case let item as [String: Any] in items {
            let text = (item["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let relative = text.hasPrefix("./") || text.hasPrefix("../")
            if relative && url == nil { skipped += 1; continue }
            guard !text.isEmpty, let resolved = relative ? URL(string: text, relativeTo: url)?.absoluteURL : URL(string: text),
                  let scheme = resolved.scheme?.lowercased(), scheme == "http" || scheme == "https", resolved.host?.isEmpty == false,
                  seen.insert(resolved.absoluteString).inserted else { continue }
            sources.append(SavedSource(name: (item["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                       url: resolved))
        }
        guard !sources.isEmpty || skipped > 0 else { throw ConfigLoaderError.emptyDepot }
        return Entries(sources: sources, skippedRelative: skipped)
    }

    /// The group key of a depot imported from a file: its content, so two files with one name stay two groups
    /// and importing the same file again lands in the group it made before.
    public static func importedID(_ data: Data) -> String {
        "imported:" + SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
