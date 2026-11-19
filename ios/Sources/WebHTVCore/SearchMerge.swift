import Foundation

/// W-315 A3 (docs/W-312-ios-search-improvements.md §5): one card for the same title found on many sites.
///
/// Two results are the same title when their whole titles — season marker included — fold to the same text
/// (`SearchRelevance.folded`: full width, Traditional → Simplified, case, punctuation) and their years agree.
/// A year counts only when the site gave one, so a title without a year joins only others without one; a
/// remake with another year stays its own card. A folder is a category, never merged.
public enum SearchMerge {
    /// Nil when the result must stay on its own: a folder, or a title with nothing left after folding.
    public static func key(for vod: Vod) -> String? {
        guard vod.tag != "folder" else { return nil }
        let title = SearchRelevance.folded(vod.name)
        guard !title.isEmpty else { return nil }
        return title + "\u{0}" + year(vod.year)
    }

    /// Results with the same key, together where the first of them was; results without a key stay alone.
    public static func merged<T>(_ items: [T], key: (T) -> String?) -> [[T]] {
        var result = [[T]]()
        var position = [String: Int]()
        for item in items {
            guard let key = key(item) else { result.append([item]); continue }
            if let at = position[key] {
                result[at].append(item)
            } else {
                position[key] = result.count
                result.append([item])
            }
        }
        return result
    }

    /// The first four-digit year in a site's year field (「2019」「2019-11-26」「2019年」), or "".
    static func year(_ text: String) -> String {
        text.firstMatch(of: /(?:^|[^0-9])((?:19|20)[0-9]{2})(?:[^0-9]|$)/).map { String($0.output.1) } ?? ""
    }
}
