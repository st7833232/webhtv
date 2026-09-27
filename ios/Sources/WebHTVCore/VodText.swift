import Foundation

/// IOS-POC-32 B: makes the free-text metadata sources send (`vod_content`, `vod_actor` and the
/// rest) presentable on the detail screen. Display only: nothing here feeds search, playback or
/// history, which keep the raw strings.
///
/// A deliberate superset of Android's `Util.clean` (`utils/Util.java:126-132`): Android runs
/// `Html.fromHtml` only when the text has a `<`, turns U+00A0 and U+3000 into spaces and trims each
/// line. This also decodes entities in text without tags, and collapses runs of blank lines.
public enum VodText {
    /// Plain text: CatVod link markup reduced to its label, HTML tags removed, entities decoded,
    /// each line trimmed, and at most one blank line in a row.
    public static func plain(_ raw: String) -> String {
        var text = raw
        // `[a=cr:{"id":"…","name":"…"}/]周杰伦[/a]` links a name to a category page in drpy
        // sources; only the label is text (`utils/Sniffer.java:24`, Android's `CLICKER`).
        if text.contains("[a=cr:") {
            text = text.replacingOccurrences(
                of: #"\[a=cr:.*?/\](.*?)\[/a\]"#, with: "$1", options: .regularExpression)
        }
        if text.contains("<") {
            text = text
                .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)</(p|div|li)\s*>"#, with: "\n", options: .regularExpression)
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
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            return UInt32(name.dropFirst(2), radix: 16).flatMap { Unicode.Scalar($0) }.map { Character($0) }
        }
        if name.hasPrefix("#") {
            return UInt32(name.dropFirst(), radix: 10).flatMap { Unicode.Scalar($0) }.map { Character($0) }
        }
        return named[name]
    }

    private static let named: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "hellip": "\u{2026}", "mdash": "\u{2014}", "ndash": "\u{2013}", "middot": "\u{00B7}",
    ]
}
