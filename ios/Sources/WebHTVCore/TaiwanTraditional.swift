import Foundation
import os

/// IOS-POC-32 C: Simplified Chinese from a source, shown as Taiwan Traditional. **Display only**: the
/// app calls this where a string is drawn and nowhere else, so search, identity values, watch
/// history and the WebHome bridge keep the source's own text. Nothing else in this module calls it
/// (`TaiwanTraditionalTests` checks).
///
/// The conversion is OpenCC's `s2tw` (`data/config/s2tw.json` at `528ae262`), reimplemented over the
/// same six dictionaries, bundled unmodified in `Resources/OpenCC` (its README says where each came
/// from):
/// 1. compatibility ideographs are normalised (`CJK_Compatibility_Ideographs`);
/// 2. at each position the longest `STPhrases` ∪ `STPhrases_GeneratedFromRegionalPhrases` key is
///    one segment; the characters no phrase starts at form segments of their own and are converted
///    one at a time (`STCharacters`). This is OpenCC's `mmseg` segmentation and first conversion
///    step, which always pick the same spans;
/// 3. inside each segment, the longest `TWVariantsPhrases` key, else `TWVariants`.
/// Every dictionary gives its first candidate, and the first entry for a key wins, as in OpenCC's
/// own matcher (`src/PrefixMatch.cpp`, `LeafMatcher::AddDict`). A Python copy of these steps gave
/// OpenCC's output on all 67 of its `s2tw` test cases and on 134,127 generated lines (IOS-POC-32
/// document, section 6). Not reproduced: OpenCC copies an ideographic description sequence
/// (`⿰氵马`) through whole; here its parts are converted like any other character.
///
/// What WebHTV adds around it:
/// - Only text holding a character that only Simplified writing uses is converted. OpenCC expects
///   Simplified input and changes Traditional text (干擾 → 幹擾, 里長 → 裡長), and many sources
///   already send Traditional. Converted text never holds such a character, so a string is never
///   converted twice (OpenCC alone turns 朴樹 into 樸樹 on a second pass).
/// - Japanese text is left alone (`isJapanese`): its kanji are not Simplified Chinese.
/// - 臺 is written 台 (the user's choice): `s2tw` writes 臺北, 臺劇, 平臺.
/// - `.names`, for director and cast, keeps the surnames 于 朴 范 姜 余 沈 and writes 钟 as 鍾;
///   `s2tw` reads them as ordinary words (于和伟 → 於和偉, 范伟 → 範偉, 余华 → 餘華).
public struct TaiwanTraditional: Sendable {
    public enum Mode: Sendable {
        /// Titles, remarks, categories, lines, episodes, synopses: anything but a list of names.
        case text
        /// A director or cast field: names split on `，` `,` `/` `、` and white space.
        case names
    }

    public enum LoadError: Error {
        case missingDictionary(String)
    }

    private let compatibility: OpenCCTable
    private let phrases: OpenCCTable
    private let characters: OpenCCTable
    private let variantPhrases: OpenCCTable
    private let variants: OpenCCTable
    /// The characters of `STCharacters` that no dictionary writes and that are not Taiwan-variant
    /// keys: text holding one is Simplified. 3,797 characters at `528ae262`.
    private let simplifiedOnly: Set<Unicode.Scalar>

    private static let log = Logger(subsystem: "com.webhtv.ios.poc", category: "zhtw")
    private static let nameSeparators: Set<Unicode.Scalar> = ["，", ",", "/", "、"]
    private static let keptSurnames: Set<Unicode.Scalar> = ["于", "朴", "范", "姜", "余", "沈"]
    private static let formalTai: Unicode.Scalar = "臺"
    private static let commonTai: Unicode.Scalar = "台"

    /// The converter over the dictionaries bundled with this module. It parses about 1 MB, so call it
    /// off the main thread; the app loads it once at launch.
    public static func bundled() throws -> TaiwanTraditional {
        let began = ContinuousClock.now
        func dictionary(_ name: String) throws -> String {
            guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "OpenCC")
            else { throw LoadError.missingDictionary(name) }
            return try String(contentsOf: url, encoding: .utf8)
        }
        let converter = try TaiwanTraditional(
            compatibility: dictionary("CJK_Compatibility_Ideographs"),
            phrases: [dictionary("STPhrases"), dictionary("STPhrases_GeneratedFromRegionalPhrases")],
            characters: dictionary("STCharacters"),
            variantPhrases: dictionary("TWVariantsPhrases"),
            variants: dictionary("TWVariants"))
        let elapsed = ContinuousClock.now - began
        let milliseconds = Int(elapsed / .milliseconds(1))
        Self.log.notice("[zhtw] dictionaries loaded in \(milliseconds)ms")
        return converter
    }

    private init(compatibility: String, phrases: [String], characters: String, variantPhrases: String,
                 variants: String) {
        var phraseTable = OpenCCTable()
        for text in phrases { phraseTable.add(text) }
        let characterTable = OpenCCTable(characters)
        let variantPhraseTable = OpenCCTable(variantPhrases)
        let variantTable = OpenCCTable(variants)
        var written = variantPhraseTable.keyScalars.union(variantTable.keyScalars)
        for table in [phraseTable, characterTable, variantPhraseTable, variantTable] {
            written.formUnion(table.written)
        }
        self.compatibility = OpenCCTable(compatibility)
        self.phrases = phraseTable
        self.characters = characterTable
        self.variantPhrases = variantPhraseTable
        self.variants = variantTable
        simplifiedOnly = characterTable.keyScalars.subtracting(written)
    }

    /// `text` as it should read on screen: converted when it is Simplified Chinese, otherwise
    /// returned as it came.
    public func convert(_ text: String, mode: Mode = .text) -> String {
        guard needsConversion(text) else { return text }
        switch mode {
        case .text:
            return taiwan(text)
        case .names:
            var result = ""
            var name = ""
            for scalar in text.unicodeScalars {
                if Self.nameSeparators.contains(scalar) || scalar.properties.isWhitespace {
                    result += convertName(name)
                    result.unicodeScalars.append(scalar)
                    name = ""
                } else {
                    name.unicodeScalars.append(scalar)
                }
            }
            return result + convertName(name)
        }
    }

    /// Mostly kana, by the ratio of kana to Han characters rather than by any kana at all: a Chinese
    /// synopsis may quote a Japanese title. The katakana middle dot and the prolonged sound mark
    /// (・ ー ･ ゠) are not counted, because Chinese writes foreign names with them (湯姆・克魯斯).
    /// Shared with IOS-POC-32 D, which translates what this calls Japanese.
    public static func isJapanese(_ text: String) -> Bool {
        var kana = 0
        var han = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3041...0x3096, 0x309D...0x309F, 0x30A1...0x30FA, 0x30FD...0x30FF, 0x31F0...0x31FF,
                 0xFF66...0xFF6F, 0xFF71...0xFF9D:
                kana += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F:
                han += 1
            default:
                break
            }
        }
        return kana >= 2 && kana * 4 >= kana + han
    }

    private func needsConversion(_ text: String) -> Bool {
        text.unicodeScalars.contains { simplifiedOnly.contains($0) } && !Self.isJapanese(text)
    }

    /// One name of a director or cast field.
    private func convertName(_ name: String) -> String {
        guard needsConversion(name), let first = name.unicodeScalars.first else { return name }
        let rest = Self.string(name.unicodeScalars.dropFirst())
        if Self.keptSurnames.contains(first) { return Self.string(CollectionOfOne(first)) + convert(rest) }
        if first == "钟" { return "鍾" + convert(rest) }
        return taiwan(name)
    }

    /// `s2tw`, then 臺 → 台.
    private func taiwan(_ text: String) -> String {
        let source = Array(text.unicodeScalars)
        let scalars = Self.rewrite(source, 0 ..< source.count, compatibility)
        var output = [Unicode.Scalar]()
        output.reserveCapacity(scalars.count)
        var runStart = 0
        var index = 0
        while index < scalars.count {
            guard let match = phrases.match(scalars, at: index, before: scalars.count) else {
                index += 1
                continue
            }
            if runStart < index {
                output += variantsStep(Self.rewrite(scalars, runStart ..< index, characters))
            }
            output += variantsStep(Array(match.value.unicodeScalars))
            index += match.length
            runStart = index
        }
        if runStart < scalars.count {
            output += variantsStep(Self.rewrite(scalars, runStart ..< scalars.count, characters))
        }
        return Self.string(output.map { $0 == Self.formalTai ? Self.commonTai : $0 })
    }

    /// OpenCC's second step, inside one segment of the first.
    private func variantsStep(_ segment: [Unicode.Scalar]) -> [Unicode.Scalar] {
        Self.rewrite(segment, 0 ..< segment.count, variantPhrases, variants)
    }

    /// One OpenCC conversion over `scalars[range]`: at each position the first table with a match
    /// writes its value, and a character no table matches is copied. No match reaches past `range`.
    private static func rewrite(_ scalars: [Unicode.Scalar], _ range: Range<Int>, _ first: OpenCCTable,
                                _ second: OpenCCTable? = nil) -> [Unicode.Scalar] {
        var output = [Unicode.Scalar]()
        output.reserveCapacity(range.count)
        var index = range.lowerBound
        while index < range.upperBound {
            if let match = first.match(scalars, at: index, before: range.upperBound)
                ?? second?.match(scalars, at: index, before: range.upperBound) {
                output.append(contentsOf: match.value.unicodeScalars)
                index += match.length
            } else {
                output.append(scalars[index])
                index += 1
            }
        }
        return output
    }

    private static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var text = ""
        text.unicodeScalars.append(contentsOf: scalars)
        return text
    }
}

/// One OpenCC dictionary in its text format (`key<TAB>candidate candidate…`, `#` comments).
private struct OpenCCTable: Sendable {
    /// Each key's first candidate, from the first entry for that key.
    private var values: [String: String] = [:]
    /// The longest key, in Unicode scalars, starting with each scalar: how far a match can reach.
    private var reach: [Unicode.Scalar: Int] = [:]
    /// Every scalar of every key.
    private(set) var keyScalars = Set<Unicode.Scalar>()
    /// Every scalar of every candidate, not only the first: all this dictionary can write.
    private(set) var written = Set<Unicode.Scalar>()

    init(_ texts: String...) {
        for text in texts { add(text) }
    }

    mutating func add(_ text: String) {
        for line in text.unicodeScalars.split(separator: "\n") {
            guard line.first != "#", let tab = line.firstIndex(of: "\t") else { continue }
            let key = line[..<tab]
            let candidates = line[line.index(after: tab)...]
            let value = candidates.prefix { $0 != " " }
            guard let head = key.first, !value.isEmpty else { continue }
            keyScalars.formUnion(key)
            written.formUnion(candidates)
            var keyText = ""
            keyText.unicodeScalars.append(contentsOf: key)
            guard values[keyText] == nil else { continue }
            var valueText = ""
            valueText.unicodeScalars.append(contentsOf: value)
            values[keyText] = valueText
            reach[head] = max(reach[head] ?? 0, key.count)
        }
    }

    /// The longest key at `scalars[index]` that ends before `end`, with its value.
    func match(_ scalars: [Unicode.Scalar], at index: Int, before end: Int) -> (length: Int, value: String)? {
        guard let longest = reach[scalars[index]] else { return nil }
        var length = min(longest, end - index)
        while length > 0 {
            var key = ""
            key.unicodeScalars.append(contentsOf: scalars[index ..< index + length])
            if let value = values[key] { return (length, value) }
            length -= 1
        }
        return nil
    }
}
