import Foundation

/// W-312 A1: how close a result's title is to the keyword, so 全部 lists the titles that are the keyword
/// before the hundreds a fuzzy site or a channel of clips sends back (docs/W-312-ios-search-improvements.md §2.5).
///
/// Both sides are folded the same way before they are compared: compatibility forms (full-width → half-width),
/// the search table's Traditional → Simplified, lower case, and only letters and digits kept. A title's
/// trailing bracketed tags — (2019), [国语], [电影解说] — do not stop it from being the keyword itself.
public enum SearchRelevance {
    /// 3: the title is the keyword; 2: it starts with it; 1: it contains it; 0: neither (or no keyword).
    public static func score(title: String, keyword: String) -> Int {
        let keyword = folded(keyword), whole = folded(title)
        guard !keyword.isEmpty else { return 0 }
        if whole == keyword || folded(withoutTrailingTags(title)) == keyword { return 3 }
        if whole.hasPrefix(keyword) { return 2 }
        return whole.contains(keyword) ? 1 : 0
    }

    static func folded(_ text: String) -> String {
        let simplified = TraditionalSimplified.toSimplified(text.precomposedStringWithCompatibilityMapping).lowercased()
        return String(String.UnicodeScalarView(simplified.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    private static let closers: [Character: Character] = [")": "(", "]": "[", "）": "（", "】": "【"]

    /// Drops trailing `(…)`, `[…]`, `（…）`, `【…】` groups of up to 12 characters, one after another.
    static func withoutTrailingTags(_ title: String) -> String {
        var text = Substring(title.trimmingCharacters(in: .whitespaces))
        while let last = text.last, let opener = closers[last],
              let start = text.dropLast().lastIndex(of: opener),
              text.distance(from: start, to: text.endIndex) <= 14 {
            text = text[..<start]
            while text.last?.isWhitespace == true { text = text.dropLast() }
        }
        return String(text)
    }
}
