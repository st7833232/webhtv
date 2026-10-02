import Foundation

/// IOS-POC-45 — what the online subtitle search field starts with, and the one-tap alternatives.
///
/// **A convenience, never a constraint.** These only prefill the editable field; the viewer can
/// delete all of it and type anything (`OnlineSubtitleSession.queryText`), and whatever is in the
/// field is what gets searched. Nothing here ever rewrites what the viewer typed.
///
/// A release code is looked for first, because a code is what subtitle sites index such files
/// under. Recognition runs as a small pipeline — fold widths and dashes, then try each
/// `SubtitleReleaseCode.Rule` in order — so a new code family is one more rule rather than a
/// special case in the middle. It is deliberately conservative: a code is letters and digits
/// joined by at most a hyphen or an underscore, never by a space, so "Blade Runner 2049" stays a
/// film title. Without a code the title itself is the query.
public struct SubtitleSearchKeywords: Sendable, Equatable {
    /// What the field is prefilled with.
    public let prefill: String
    /// Tappable alternatives, the prefill first. Never empty unless the title was.
    public let candidates: [String]
    /// The code recognized in the title, if any.
    public let code: SubtitleReleaseCode?

    /// - Parameters:
    ///   - title: what the player shows for this playback.
    ///   - alternatives: other names the playback has — the title without its episode, say.
    public static func make(title: String, alternatives: [String] = []) -> SubtitleSearchKeywords {
        let names = ([title] + alternatives).map(Self.cleaned).filter { !$0.isEmpty }
        let code = names.lazy.compactMap(SubtitleReleaseCode.recognize).first
        var candidates = [String]()
        func add(_ value: String) {
            guard !value.isEmpty,
                  !candidates.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame })
            else { return }
            candidates.append(value)
        }
        code?.searchForms.forEach(add)
        names.forEach(add)
        return SubtitleSearchKeywords(prefill: candidates.first ?? "", candidates: candidates, code: code)
    }

    /// Whitespace collapsed, ends trimmed. The title is otherwise left exactly as it was.
    static func cleaned(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// A release code such as `FC2-PPV-1234567` or `DLDSS-553`, in its canonical form.
public struct SubtitleReleaseCode: Sendable, Equatable {
    public enum Family: String, Sendable, Equatable {
        /// `FC2-PPV-<digits>` and its spellings.
        case fc2
        /// A letter label and a number: `DLDSS-553`, `SSIS-001`.
        case labelNumber
    }

    public let family: Family
    /// `FC2-PPV-1234567`, `DLDSS-553`.
    public let canonical: String
    /// What to offer as search text, canonical first.
    public let searchForms: [String]

    /// One code family: a pattern over the folded text, and how a match is written out.
    struct Rule: Sendable {
        let family: Family
        let pattern: String
        let forms: @Sendable (_ groups: [String]) -> [String]?
    }

    /// Tried in order; the first that matches wins. Add a family by adding a rule.
    static let rules: [Rule] = [
        // FC2PPV-1234567, FC2-PPV-1234567, FC2PPV1234567, FC2 PPV 1234567, FC2-1234567.
        Rule(family: .fc2, pattern: #"(?<![a-z0-9])fc2[\s_-]*(?:ppv[\s_-]*)?(\d{5,8})(?![0-9])"#) { groups in
            let number = groups[0]
            return ["FC2-PPV-\(number)", "FC2PPV-\(number)", "FC2PPV\(number)", number]
        },
        // DLDSS553, DLDSS-553, dldss-553, SSIS_001. Two to six letters, three to five digits, at
        // most one hyphen or underscore between them and nothing alphanumeric on either side.
        // A word joined to a year ("Dune-2021", "Avatar2009") is a title, unless written all in
        // capitals the way codes are.
        Rule(family: .labelNumber, pattern: #"(?<![a-z0-9])([a-z]{2,6})[-_]?(\d{3,5})(?![a-z0-9])"#) { groups in
            let label = groups[0].uppercased()
            guard !SubtitleReleaseCode.notALabel.contains(label) else { return nil }
            if let number = Int(groups[1]), (1900...2099).contains(number), groups[0] != label { return nil }
            return ["\(label)-\(groups[1])", "\(label)\(groups[1])"]
        },
    ]

    /// Words that precede numbers in ordinary titles and media names. Never a release label.
    static let notALabel: Set<String> = [
        "EP", "EPS", "VOL", "PART", "NO", "NUM", "HD", "FHD", "UHD", "SD", "BD", "DVD", "WEB", "AVC",
        "HEVC", "AAC", "AC", "DTS", "MP", "FPS", "BIT", "CH", "SEASON", "YEAR", "TOP", "TV", "CD",
        "DISC", "HDR", "DV", "ATMOS", "DDP", "DD", "OPUS", "FLAC", "PCM", "REMUX", "RIP", "WEBRIP",
        "BDRIP", "HDTV", "AVI", "MKV", "MOV", "WMV", "TS", "ISO", "PAGE", "ROOM", "ROUTE",
    ]

    /// The first code in `text`, or nil.
    public static func recognize(_ text: String) -> SubtitleReleaseCode? {
        let folded = fold(text)
        let range = NSRange(folded.startIndex..., in: folded)
        for rule in rules {
            guard let expression = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive])
            else { continue }
            for match in expression.matches(in: folded, range: range) {
                let groups = (1..<match.numberOfRanges).compactMap { index -> String? in
                    Range(match.range(at: index), in: folded).map { String(folded[$0]) }
                }
                guard groups.count == match.numberOfRanges - 1, let forms = rule.forms(groups),
                      let canonical = forms.first else { continue }
                return SubtitleReleaseCode(family: rule.family, canonical: canonical, searchForms: forms)
            }
        }
        return nil
    }

    /// Full-width letters and digits to ASCII and every dash to "-". Case is kept — the rules
    /// match without it, and the year rule reads it.
    static func fold(_ text: String) -> String {
        let dashes: Set<Character> = ["‐", "‑", "‒", "–", "—", "―", "－", "−"]
        return String(text.precomposedStringWithCompatibilityMapping.map { dashes.contains($0) ? "-" : $0 })
    }
}
