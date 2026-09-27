import Foundation

/// IOS-POC-32 B: makes the free-text metadata sources send (`vod_content`, `vod_actor` and the
/// rest) presentable on the detail screen. Display only: nothing here feeds search, playback or
/// history, which keep the raw strings.
///
/// Modelled on Android's `Util.clean` (`utils/Util.java:126-132`), which returns text without a `<`
/// unchanged and otherwise runs `Html.fromHtml`, turns U+00A0 and U+3000 into spaces and trims each
/// line. Differences: entities are decoded even without tags, but only the numeric forms and the
/// named set below (Android: the full HTML set); U+00A0/U+3000 and line trimming apply to every
/// text (Android: only when a tag is present); `</p>` gives one line break, not a blank line; runs
/// of blank lines collapse to one.
public enum VodText {
    /// Plain text: CatVod link markup reduced to its label, HTML tags removed, entities decoded,
    /// each line trimmed, and at most one blank line in a row.
    public static func plain(_ raw: String) -> String {
        var text = raw
        // `[a=cr:{"id":"…","name":"…"}/]周杰伦[/a]` links a name to a category page in drpy
        // sources; only the label is text. Android's `CLICKER` shape, label trimmed as Android
        // does (`utils/Sniffer.java:24`, `:62`).
        if text.contains("[a=cr:") {
            text = text.replacingOccurrences(
                of: #"\[a=cr:\{.*?\}/\]\s*(.*?)\s*\[/a\]"#, with: "$1", options: .regularExpression)
        }
        if text.contains("<") {
            // A break tag already ends the line, so a source line break right after it (PHP's
            // nl2br writes `<br />` then a newline) is part of the same break, not a blank line.
            text = text
                .replacingOccurrences(
                    of: #"(?i)<br\s*/?\s*>[ \t]*(?:\r\n|\r|\n)?"#, with: "\n", options: .regularExpression)
                .replacingOccurrences(
                    of: #"(?i)</(p|div|li)\s*>[ \t]*(?:\r\n|\r|\n)?"#, with: "\n", options: .regularExpression)
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        }
        // After the tags, so an escaped `&lt;b&gt;` stays visible text rather than becoming a tag.
        text = decodeEntities(text)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines = [String]()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(trimmed)
        }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// A four-digit year from 1900 to 2099 at the start of the value, or nil. MacCMS stores `0`
    /// for an unknown year, and some sources send a full date.
    public static func year(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix(4)
        guard digits.count == 4, digits.allSatisfy(\.isASCII), let value = Int(digits),
              (1900...2099).contains(value) else { return nil }
        if let next = trimmed.dropFirst(4).first, next.isASCII, next.isNumber { return nil }
        return String(digits)
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = text[...]
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let tail = rest[amp...]
            let body = tail.dropFirst()
            // The longest entity handled is `&#x10FFFF;` (ten characters with the `&`).
            if let semicolon = body.prefix(10).firstIndex(of: ";"),
               let decoded = entity(String(body[..<semicolon])) {
                result.append(decoded)
                rest = body[body.index(after: semicolon)...]
            } else {
                result.append("&")
                rest = body
            }
        }
        result += rest
        return result
    }

    private static func entity(_ name: String) -> Character? {
        let digits: Substring
        let radix: Int
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            digits = name.dropFirst(2)
            radix = 16
        } else if name.hasPrefix("#") {
            digits = name.dropFirst()
            radix = 10
        } else {
            return named[name]
        }
        // Digits only (the integer parser would accept a sign), and never NUL.
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let value = UInt32(digits, radix: radix), value != 0,
              let scalar = Unicode.Scalar(value) else { return nil }
        return Character(scalar)
    }

    private static let named: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "AMP": "&", "LT": "<", "GT": ">", "QUOT": "\"",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "hellip": "\u{2026}", "mdash": "\u{2014}", "ndash": "\u{2013}", "middot": "\u{00B7}",
        "emsp": "\u{2003}", "ensp": "\u{2002}", "thinsp": "\u{2009}", "bull": "\u{2022}",
        "laquo": "\u{00AB}", "raquo": "\u{00BB}", "times": "\u{00D7}", "copy": "\u{00A9}",
        "reg": "\u{00AE}", "trade": "\u{2122}", "yen": "\u{00A5}",
    ]
}
