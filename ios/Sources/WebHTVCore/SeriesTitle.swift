import Foundation

/// W-312 §4 / W-313 方案 C — a title split into its series name and season, shared by search grouping
/// (W-312) and new-season hints (W-313). Pure: no network, no state.
///
/// The rules (docs/W-312-ios-search-improvements.md §4.2, 83c3730e), in order:
/// 1. Fold: NFKC (full width to half width), Traditional to Simplified with the table searches are sent
///    with, lower case. Only `baseKey` is folded; `baseDisplay` keeps the source's script.
/// 2. Trailing bracketed tags — `(2017)`, `[国语]`, `（…）`, `【…】`, 12 characters at most — are set aside.
/// 3. A trailing 劇場版／電影版／特別篇／番外（篇）／總集篇／SP／OVA is `special`.
/// 4. A trailing season marker: strong is 第N季／部／輯 (Arabic or Chinese numerals), Season N, SN／S0N;
///    weak is a bare 2–20 right after a Chinese character (「慶餘年2」). Nothing else is a season.
/// 5. What is left, without spaces and punctuation, is `baseKey`.
public struct SeriesTitle: Hashable, Sendable {
    public enum Strength: Sendable { case none, weak, strong }
    /// 劇場版／電影版; 特別篇／SP／OVA／總集篇; 番外.
    public enum Special: Sendable { case movie, special, extra }

    public let original: String
    /// For comparing: folded, without punctuation. Never shown.
    public let baseKey: String
    /// The title without its season and special markers, as the source wrote it: the keyword a new
    /// season is searched for with.
    public let baseDisplay: String
    /// Nil when the title has no marker; grouping reads that as season 1.
    public let season: Int?
    public let strength: Strength
    public let special: Special?
    /// Trailing bracketed tags, outermost last: (2019), [國語], 4K…
    public let tags: [String]

    public init(_ title: String) {
        original = title
        var text = title.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespaces)
        var tags = [String]()
        while let match = Self.first(Self.tag, in: text) {
            tags.insert(Self.group(1, of: match, in: text), at: 0)
            text = Self.before(match, in: text)
        }
        var special: Special?
        if let match = Self.first(Self.special, in: text) {
            special = Self.kind(of: Self.group(1, of: match, in: text))
            text = Self.before(match, in: text)
        }
        var season: Int?
        var strength = Strength.none
        for pattern in Self.strong {
            guard let match = Self.first(pattern, in: text),
                  let number = Self.number(Self.group(1, of: match, in: text)), number > 0, number < 100 else { continue }
            season = number
            strength = .strong
            text = Self.before(match, in: text)
            break
        }
        if strength == .none, let match = Self.first(Self.weak, in: text),
           let number = Int(Self.group(1, of: match, in: text)), (2...20).contains(number),
           Self.before(match, in: text).count >= 2 {
            season = number
            strength = .weak
            text = Self.before(match, in: text)
        }
        // A special ends its series' name, so 「鬼滅之刃 劇場版」 joins 鬼滅之刃.
        if special == nil, let match = Self.first(Self.special, in: text) {
            special = Self.kind(of: Self.group(1, of: match, in: text))
            text = Self.before(match, in: text)
        }
        self.tags = tags
        self.special = special
        self.season = season
        self.strength = strength
        baseDisplay = text.trimmingCharacters(in: Self.separators)
        baseKey = Self.key(baseDisplay)
    }

    /// The comparing form of any text: rule 1 and rule 5.
    static func key(_ text: String) -> String {
        let folded = TraditionalSimplified.toSimplified(text.precomposedStringWithCompatibilityMapping).lowercased()
        return folded.unicodeScalars.filter { !punctuation.contains($0) }.map(String.init).joined()
    }

    // MARK: - Patterns (on the NFKC text, case-insensitive; both scripts spelled out)

    private static let lead = #"[\s:·\-—]*"#
    private static let numeral = "([0-9]{1,3}|[零〇一二两兩三四五六七八九十]{1,3})"
    private static let tag = regex(#"\s*[\(\[（【]([^\)\]）】]{1,12})[\)\]）】]\s*$"#)
    private static let special = regex(lead + #"(剧场版|劇場版|电影版|電影版|特别篇|特別篇|番外篇?|总集篇|總集篇|\bsp\b|\bova\b)$"#)
    private static let strong = [
        regex(lead + "第" + numeral + "[季部辑輯]$"),
        regex(lead + #"season\s*0*([0-9]{1,2})$"#),
        // Not after a letter: 「PS5」 is a console, not season 5 of 「P」.
        regex(lead + #"(?<![a-z])s0*([0-9]{1,2})$"#),
    ]
    private static let weak = regex(#"(?<=[\x{4E00}-\x{9FFF}])\s*0*([0-9]{1,2})$"#)
    private static let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":·-—"))
    private static let punctuation = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "　:：·・-—_~～!！?？,，.。、'\"“”‘’《》「」『』<>"))

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func first(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func group(_ index: Int, of match: NSTextCheckingResult, in text: String) -> String {
        Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
    }

    private static func before(_ match: NSTextCheckingResult, in text: String) -> String {
        guard let range = Range(match.range, in: text) else { return text }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    private static func kind(of word: String) -> Special {
        switch word.lowercased() {
        case "剧场版", "劇場版", "电影版", "電影版": .movie
        case "番外", "番外篇": .extra
        default: .special
        }
    }

    /// 「十二」 is 12, 「二十一」 21, 「兩」 2.
    static func number(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "兩": 2, "三": 3, "四": 4,
                                        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if text == "十" { return 10 }
        if let ten = text.firstIndex(of: "十") {
            let head = text[..<ten], tail = text[text.index(after: ten)...]
            let tens = head.isEmpty ? 1 : head.count == 1 ? digits[head.first!] : nil
            let ones = tail.isEmpty ? 0 : tail.count == 1 ? digits[tail.first!] : nil
            guard let tens, let ones else { return nil }
            return tens * 10 + ones
        }
        return text.count == 1 ? digits[text.first!] : nil
    }
}

/// W-312 §4.3 / §4.5 — series made of titles, and whether one title is a later season of another.
public enum SeriesGrouping {
    /// Conservative: titles with the same `baseKey` become one series only when at least one carries a
    /// season marker and they span at least two seasons or specials; otherwise each stays alone, so a
    /// remake and its original (「射鵰英雄傳(1983)」「(2017)」) are never merged. A series sits where its
    /// first member did; inside it, seasons ascend (no marker is season 1) and specials come last.
    public static func groups<T>(_ items: [T], title: (T) -> String) -> [[T]] {
        groups(items, series: { SeriesTitle(title($0)) })
    }

    /// The same, for items whose titles are already parsed: a list regrouped as results keep arriving
    /// parses each title once, not on every regroup (W-312 A2).
    public static func groups<T>(_ items: [T], series: (T) -> SeriesTitle) -> [[T]] {
        let parsed = items.map { ($0, series($0)) }
        var buckets = [String: [(T, SeriesTitle)]]()
        var order = [String]()
        for item in parsed {
            if buckets[item.1.baseKey] == nil { order.append(item.1.baseKey) }
            buckets[item.1.baseKey, default: []].append(item)
        }
        var placed = Set<String>()
        var result = [[T]]()
        for item in parsed {
            let key = item.1.baseKey
            let members = buckets[key] ?? []
            if isSeries(members.map(\.1)), !key.isEmpty {
                guard placed.insert(key).inserted else { continue }
                let sorted = members.enumerated().sorted { a, b in
                    let left = rank(a.element.1), right = rank(b.element.1)
                    return left != right ? left < right : a.offset < b.offset
                }
                result.append(sorted.map(\.element.0))
            } else {
                result.append([item.0])
            }
        }
        return result
    }

    /// W-326: one site's own list, grouped page by page (`pageStarts`: where each 載入更多 page began). A later page
    /// is grouped on its own and follows what is already shown, so nothing on screen moves under the finger; the
    /// price is that a season turning up only on a later page stays on that page.
    public static func paged<T>(_ items: [T], pageStarts: [Int], series: (T) -> SeriesTitle) -> [T] {
        let bounds = [0] + pageStarts.filter { $0 > 0 && $0 < items.count } + [items.count]
        return zip(bounds, bounds.dropFirst()).flatMap { groups(Array(items[$0..<$1]), series: series).joined() }
    }

    private static func isSeries(_ titles: [SeriesTitle]) -> Bool {
        guard titles.contains(where: { $0.strength != .none }) else { return false }
        var kinds = Set<String>()
        for title in titles {
            kinds.insert(title.special.map { "special:\($0)" } ?? "season:\(title.season ?? 1)")
        }
        return kinds.count > 1
    }

    private static func rank(_ title: SeriesTitle) -> (Int, Int) {
        (title.special == nil ? 0 : 1, title.season ?? 1)
    }

    /// W-313 (定案, W-312 83c3730e §4.1/§4.5): the same series, a candidate with a strong season marker and
    /// no special, and a higher season than the one watched (no marker is season 1). A weak 「XX2」 may be
    /// an episode number or another title with the same name, so it never counts.
    public static func isNewerSeason(_ candidate: SeriesTitle, than watched: SeriesTitle) -> Bool {
        guard !candidate.baseKey.isEmpty, candidate.baseKey == watched.baseKey,
              candidate.strength == .strong, candidate.special == nil, let season = candidate.season
        else { return false }
        return season > (watched.season ?? 1)
    }
}
