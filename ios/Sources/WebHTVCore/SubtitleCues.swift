import Foundation

/// IOS-POC-45 — a subtitle file's timed lines, for the one engine that cannot draw them itself.
///
/// mpv reads the downloaded file with its own parser and libass (`sub-add`). AVPlayer has no way to
/// side-load a subtitle into a streamed item — an HLS asset's renditions come from its playlist —
/// so under AVPlayer the player screen draws the active cue over the video, and these are the
/// cues it draws. The same parse is also the download's proof that a file really is a subtitle.
public struct SubtitleCue: Sendable, Equatable {
    /// Seconds.
    public let start: Double
    public let end: Double
    /// Display text: formatting tags removed, lines kept.
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Cues in start order, with the lookup the overlay runs a few times a second.
public struct SubtitleCues: Sendable, Equatable {
    public let cues: [SubtitleCue]
    /// The longest cue, which bounds how far back a lookup has to look for one still showing.
    private let longest: Double

    public init(_ cues: [SubtitleCue]) {
        self.cues = cues.enumerated()
            .sorted { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }
            .map(\.element)
        longest = cues.map { $0.end - $0.start }.max() ?? 0
    }

    public var isEmpty: Bool { cues.isEmpty }

    /// Every cue showing at `seconds`, joined line by line; nil when none is. Overlapping cues
    /// show together, as SubRip players draw them.
    public func text(at seconds: Double) -> String? {
        guard seconds.isFinite, !cues.isEmpty else { return nil }
        // The last cue starting at or before `seconds`.
        var low = 0, high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= seconds { low = middle + 1 } else { high = middle }
        }
        var showing = [String]()
        var index = low - 1
        while index >= 0, cues[index].start >= seconds - longest {
            let cue = cues[index]
            if cue.start <= seconds, seconds < cue.end, !cue.text.isEmpty { showing.append(cue.text) }
            index -= 1
        }
        return showing.isEmpty ? nil : showing.reversed().joined(separator: "\n")
    }

    /// What shows at `seconds` with the viewer's timing correction: a positive delay shows every
    /// cue that much later, as mpv's `sub-delay` does.
    public func text(at seconds: Double, delay: Double) -> String? {
        text(at: seconds - delay)
    }

    /// IOS-POC-45E: the same on a stream that still carries its ads: the lookup runs on the
    /// programme's time, and nothing shows inside an ad. With `.none` it is `text(at:delay:)`.
    public func text(at seconds: Double, delay: Double, clock: SubtitleAdClock) -> String? {
        guard !clock.isEmpty else { return text(at: seconds, delay: delay) }
        guard let content = clock.contentTime(at: seconds) else { return nil }
        return text(at: content - delay)
    }
}

/// IOS-POC-45B — 時間軸校正: how far the viewer moves the subtitles, in seconds. Positive shows
/// them later, negative earlier.
public enum SubtitleDelay {
    /// Either way. A different cut of the same video is rarely minutes off; past ten it is the
    /// wrong file.
    public static let limit = 600.0

    /// Within the limit and on a tenth of a second, so ten taps of +0.1 read 1.0, not 0.99999.
    public static func clamped(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return (min(max(seconds, -limit), limit) * 10).rounded() / 10
    }

    /// 「+0.5 秒」, 「-1.2 秒」, 「0.0 秒」.
    public static func label(_ seconds: Double) -> String {
        let value = clamped(seconds)
        let sign = value > 0 ? "+" : value < 0 ? "-" : ""
        return sign + String(format: "%.1f", abs(value)) + " 秒"
    }

    /// IOS-POC-45E 對齊上一句／下一句: the correction that makes a line start now, `contentTime`
    /// being the programme time on screen. The previous line is the last one already started on
    /// the file's own clock (`contentTime - delay`), the next the first still to come.
    public static func aligned(_ cues: SubtitleCues, contentTime: Double, delay: Double, next: Bool) -> Double? {
        let fileTime = contentTime - delay
        let cue = next ? cues.cues.first { $0.start > fileTime } : cues.cues.last { $0.start <= fileTime }
        return cue.map { clamped(contentTime - $0.start) }
    }

    /// Whether the correction reaches the subtitle on screen. mpv moves every subtitle it draws;
    /// AVPlayer cannot move its own legible renditions, only the overlay's downloaded file.
    public static func applies(to engine: PlaybackEngineKind, selectedSubtitleID: String?) -> Bool {
        guard let id = selectedSubtitleID, id != PlaybackMediaOption.subtitleOffID else { return false }
        return engine == .mpv || PlaybackExternalSubtitle.isExternalID(id)
    }
}

/// SubRip (`.srt`), read the way players read it rather than the way the format is specified:
/// the counter line is optional, milliseconds may follow a comma or a dot and have one to three
/// digits, hours may be missing, blank lines may repeat, and a malformed block is skipped instead
/// of ending the file.
public enum SubRip {
    public static func parse(_ text: String) -> SubtitleCues {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var cues = [SubtitleCue]()
        var index = 0
        while index < lines.count {
            guard let span = timing(lines[index]) else {
                index += 1
                continue
            }
            index += 1
            var body = [String]()
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
                // A block that lost its blank line: the next timing line starts the next cue (the
                // counter line above it, if any, is then the last line here and is dropped).
                if timing(line) != nil {
                    if let last = body.last, Int(last.trimmingCharacters(in: .whitespaces)) != nil {
                        body.removeLast()
                    }
                    break
                }
                body.append(String(line))
                index += 1
            }
            if span.end > span.start {
                cues.append(SubtitleCue(start: span.start, end: span.end, text: displayText(body)))
            }
        }
        return SubtitleCues(cues)
    }

    /// `00:01:02,500 --> 00:01:04,000`, with anything after the end time (positions) ignored.
    static func timing(_ line: Substring) -> (start: Double, end: Double)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let left = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        // WebVTT allows a tab before the cue settings as well as a space.
        let right = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            .split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        guard let start = seconds(left), let end = seconds(right) else { return nil }
        return (start, end)
    }

    /// `HH:MM:SS,mmm`, `H:MM:SS.m` or `MM:SS,mmm`.
    static func seconds(_ raw: String) -> Double? {
        let parts = raw.split(whereSeparator: { $0 == "," || $0 == "." })
        guard (1...2).contains(parts.count) else { return nil }
        let clock = parts[0].split(separator: ":")
        let numbers = clock.compactMap { Int($0) }
        guard (2...3).contains(clock.count), numbers.count == clock.count else { return nil }
        let hours = clock.count == 3 ? numbers[0] : 0
        let minutes = numbers[numbers.count - 2]
        let secs = numbers[numbers.count - 1]
        guard minutes < 60, secs < 60, hours >= 0, minutes >= 0, secs >= 0 else { return nil }
        var fraction = 0.0
        if parts.count == 2 {
            let digits = parts[1]
            guard (1...3).contains(digits.count), let value = Int(digits) else { return nil }
            fraction = Double(value) / pow(10, Double(digits.count))
        }
        return Double(hours * 3600 + minutes * 60 + secs) + fraction
    }

    /// `<i>`, `<b>`, `<font …>` and ASS override blocks (`{\an8}`) removed; `\N` is a line break.
    static func displayText(_ lines: [String]) -> String {
        lines.map { line in
            var text = line.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            text = text.replacingOccurrences(of: #"<[^>]{1,80}>"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\{\\[^}]{0,120}\}"#, with: "", options: .regularExpression)
            return text.trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }
}

// MARK: - IOS-POC-45H: WebVTT and ASS, read into the same cues

/// What a subtitle file's text is, read from the text itself: a source's `format` (a MIME string)
/// and a file name are often missing or wrong, and mpv also decides by content.
public enum SubtitleTextFormat: Sendable, Equatable {
    case subRip, webVTT, ssa

    public static func of(_ text: String) -> SubtitleTextFormat {
        if text.prefix(64).drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" }).hasPrefix("WEBVTT") { return .webVTT }
        // A line that is the `[Events]` heading, wherever it is: an Aegisub file puts its embedded
        // fonts before it, often far past the first few kilobytes.
        for line in text.split(whereSeparator: \.isNewline) where line.count <= 16 {
            if line.trimmingCharacters(in: .whitespaces).lowercased() == "[events]" { return .ssa }
        }
        return .subRip
    }
}

public extension SubRip {
    /// Cues as a SubRip file, for a WebVTT or ASS file kept as SubRip: both engines then read one
    /// format, and mpv draws it in the bundled font (IOS-POC-45D) rather than an ASS style's.
    static func serialize(_ cues: SubtitleCues) -> String {
        func stamp(_ seconds: Double) -> String {
            let total = Int((max(seconds, 0) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", total / 3_600_000, total / 60_000 % 60, total / 1000 % 60, total % 1000)
        }
        return cues.cues.filter { !$0.text.isEmpty }.enumerated().map { index, cue in
            "\(index + 1)\n\(stamp(cue.start)) --> \(stamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }
}

/// WebVTT: SubRip's timing lines with `.` milliseconds and optional hours, cue settings after the
/// end time, `NOTE`/`STYLE` blocks without timings — all of which the SubRip reading already
/// passes over — plus character references in the text.
public enum WebVTT {
    public static func parse(_ text: String) -> SubtitleCues {
        SubtitleCues(SubRip.parse(text).cues.map { cue in
            var text = cue.text
            for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&lrm;", ""), ("&rlm;", ""),
                                        ("&amp;", "&")] {
                text = text.replacingOccurrences(of: entity, with: character)
            }
            return SubtitleCue(start: cue.start, end: cue.end, text: text)
        })
    }
}

/// ASS/SSA `[Events]`: each `Dialogue:` line's Start, End and Text, by the section's `Format:`
/// (v4+ and v4 order by default). Styles, positions and effects are not kept; a vector drawing
/// (`{\p1}`) is not text and is left out; the same line on several layers (an outline under a
/// fill) shows once.
public enum SSA {
    public static func parse(_ text: String) -> SubtitleCues {
        var inEvents = false
        var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var cues = [SubtitleCue]()
        var seen = Set<String>()
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
            if key == "format" {
                fields = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard key == "dialogue", let startIndex = fields.firstIndex(of: "start"),
                  let endIndex = fields.firstIndex(of: "end"), let textIndex = fields.firstIndex(of: "text"),
                  textIndex == fields.count - 1 else { continue }
            let parts = value.split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false)
            guard parts.count == fields.count,
                  let start = SubRip.seconds(parts[startIndex].trimmingCharacters(in: .whitespaces)),
                  let end = SubRip.seconds(parts[endIndex].trimmingCharacters(in: .whitespaces)), end > start else { continue }
            // Past this a line is a drawing or an attack, not something to read out.
            guard parts[textIndex].utf8.count <= 16_384, let body = withoutOverrides(parts[textIndex]) else { continue }
            let shown = SubRip.displayText([body.replacingOccurrences(of: "\\h", with: " ")])
            guard !shown.isEmpty, seen.insert("\(start)|\(end)|\(shown)").inserted else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: shown))
        }
        return SubtitleCues(cues)
    }

    /// The text with every `{…}` override block taken out, however long; nil for a drawing (a block
    /// with `\p1`…`\p9`). One pass, no regular expression: a line of a million `{` with no `}`
    /// must not cost a million scans of the rest of the line.
    static func withoutOverrides(_ text: Substring) -> String? {
        var shown = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "{" else {
                shown.append(text[index])
                index = text.index(after: index)
                continue
            }
            guard let close = text[index...].firstIndex(of: "}") else {
                // No `}` after this one, so none after any later `{` either: the rest is text.
                shown += text[index...]
                break
            }
            let block = text[text.index(after: index)..<close]
            var position = block.startIndex
            while let slash = block[position...].firstIndex(of: "\\") {
                let next = block.index(after: slash)
                if next < block.endIndex, block[next] == "p" {
                    let digit = block.index(after: next)
                    if digit < block.endIndex, ("1"..."9").contains(block[digit]) { return nil }
                }
                position = next
            }
            index = text.index(after: close)
        }
        return shown
    }
}
