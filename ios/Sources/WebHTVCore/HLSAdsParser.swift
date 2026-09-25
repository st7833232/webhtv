import Foundation

/// IOS-POC-25 — Android's HLS VOD ad detector, `HlsAdsParser.process`, ported rule for rule.
///
/// The source is the Media3 fork Android main ships
/// (`third_party/maven/androidx/media3/media3-exoplayer-hls/1.11.0-alpha01-fongmi/…-sources.jar`,
/// `androidx/media3/exoplayer/hls/playlist/HlsAdsParser.java`). This file invents nothing: the two
/// strategies, their order, every threshold and every tie-break are that class's. ExoPlayer plays
/// the playlist this returns; WebHTV never does — it only compares it with the original to learn
/// *which* segments the detector dropped (`HLSAdTimeline`), and both engines keep playing the
/// original playlist.
///
/// **Java string semantics, not Swift's.** The detector groups segment lines by prefixes measured
/// in UTF-16 code units and compares them with `String.equals`; Swift compares grapheme clusters
/// under canonical equivalence. Every line is therefore held as its UTF-16 code units, so a
/// grouping, a prefix length or an equality can never come out differently from Android's.
public enum HLSAdsParser {
    static let tagDuration = JavaText.units("#EXTINF")
    static let tagEndList = JavaText.units("#EXT-X-ENDLIST")
    static let tagDiscontinuity = JavaText.units("#EXT-X-DISCONTINUITY")
    static let defaultGroupIdentifier = JavaText.units("NO_PATH")

    static let reasonableGroupLimit = 10
    static let minPrefixLengthToTest = 5
    static let sequenceNumberReservedLength = 4

    static let adBreakThresholdShort = 3
    static let adBreakThresholdMedium = 4
    static let adBreakThresholdLong = 5
    static let adBreakThresholdExtra = 6

    static let minMajorityGroupRatio = 0.85
    static let adBlockSizeRatio = 0.75
    static let durationTierShort = 30.0
    static let durationTierMedium = 60.0
    static let durationTierLong = 90.0

    /// `HlsAdsParser.process`: the playlist unchanged when it is not a finished (VOD) playlist or
    /// nothing looks like an ad; otherwise the playlist rebuilt without the ad segments.
    public static func process(_ m3u8: String) -> String {
        let text = Array(m3u8.utf16)
        guard !text.isEmpty, JavaText.contains(text, tagEndList) else { return m3u8 }
        let lines = JavaText.lines(text)
        let ads = findAds(lines)
        if ads.isEmpty { return m3u8 }
        return rebuild(lines, ads)
    }

    // MARK: - Finding the ads

    private static func findAds(_ lines: [[UInt16]]) -> Set<Int> {
        let segments = lines.map(JavaText.trim).filter(isSegmentLine)
        let byFilename = findAdsByFilename(segments)
        if !byFilename.isEmpty { return byFilename }
        return findAdsByDiscontinuity(lines)
    }

    private static func findAdsByDiscontinuity(_ lines: [[UInt16]]) -> Set<Int> {
        let blocks = discontinuityBlocks(lines)
        guard blocks.count >= 2 else { return [] }
        // The last block is never analysed, so it can never be taken for an ad.
        let analysis = Array(blocks.dropLast())
        let mode = modeSize(analysis)
        guard mode > 0 else { return [] }
        var minorityBlocks = 0
        var ads = Set<Int>()
        let threshold = Double(mode) * adBlockSizeRatio
        var maxBlockSize = 0
        for block in analysis {
            maxBlockSize = max(maxBlockSize, block.count)
            if Double(block.count) < threshold {
                minorityBlocks += 1
                ads.formUnion(block)
            }
        }
        if minorityBlocks == 0 && mode * 2 < maxBlockSize {
            for block in analysis where block.count <= mode {
                minorityBlocks += 1
                ads.formUnion(block)
            }
        }
        let limit = minorityCountThreshold(totalMinutes: totalDurationInMinutes(lines))
        if minorityBlocks > 0 && minorityBlocks <= limit { return ads }
        return []
    }

    /// The most frequent block size; a tie goes to the larger size.
    private static func modeSize(_ blocks: [[Int]]) -> Int {
        var frequencies = [Int: Int]()
        for block in blocks { frequencies[block.count, default: 0] += 1 }
        var modeSize = -1
        var maxFrequency = -1
        for (size, frequency) in frequencies {
            if frequency > maxFrequency || (frequency == maxFrequency && size > modeSize) {
                maxFrequency = frequency
                modeSize = size
            }
        }
        return modeSize
    }

    /// Only for the heuristic's threshold, as on Android: a malformed `#EXTINF` is skipped, and the
    /// lines are **not** trimmed first (`line.startsWith(TAG_DURATION)` on the raw line).
    private static func totalDurationInMinutes(_ lines: [[UInt16]]) -> Double {
        var seconds = 0.0
        for line in lines where JavaText.starts(line, with: tagDuration) {
            if let duration = extInfDurationSeconds(line) { seconds += duration }
        }
        return seconds / 60
    }

    private static func extInfDurationSeconds(_ line: [UInt16]) -> Double? {
        let start = tagDuration.count + 1
        guard line.count > start, line[tagDuration.count] == JavaText.colon else { return nil }
        let end = JavaText.index(of: JavaText.comma, in: line, from: start) ?? line.count
        return JavaText.parseDouble(Array(line[start..<end]))
    }

    static func minorityCountThreshold(totalMinutes: Double) -> Int {
        if totalMinutes <= durationTierShort { return adBreakThresholdShort }
        if totalMinutes <= durationTierMedium { return adBreakThresholdMedium }
        if totalMinutes <= durationTierLong { return adBreakThresholdLong }
        return adBreakThresholdExtra
    }

    private static func discontinuityBlocks(_ lines: [[UInt16]]) -> [[Int]] {
        var blocks = [[Int]]()
        var current = [Int]()
        var segmentIndex = 0
        for raw in lines {
            let line = JavaText.trim(raw)
            if line == tagDiscontinuity {
                if !current.isEmpty { blocks.append(current) }
                current = []
            } else if isSegmentLine(line) {
                current.append(segmentIndex)
                segmentIndex += 1
            }
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    private static func findAdsByFilename(_ segments: [[UInt16]]) -> Set<Int> {
        guard segments.count >= 2 else { return [] }
        let structural = groupIndexes(segments, by: structuralIdentifier)
        if structural.count > 1 && structural.count <= reasonableGroupLimit {
            return findMinorityGroup(structural)
        }
        return findAdsByPrefixAnalysis(segments)
    }

    /// Scheme and host for an absolute URL, the directory for a relative one.
    private static func structuralIdentifier(_ segment: [UInt16]) -> [UInt16] {
        if let schemeEnd = JavaText.index(of: JavaText.units("://"), in: segment) {
            if let hostEnd = JavaText.index(of: JavaText.slash, in: segment, from: schemeEnd + 3) {
                return Array(segment[..<hostEnd])
            }
            return segment
        }
        if let lastSlash = segment.lastIndex(of: JavaText.slash) { return Array(segment[..<lastSlash]) }
        return defaultGroupIdentifier
    }

    /// Every group smaller than the largest, when the largest holds more than half the segments.
    private static func findMinorityGroup(_ groups: [[UInt16]: [Int]]) -> Set<Int> {
        let total = groups.values.reduce(0) { $0 + $1.count }
        let maxSize = groups.values.map(\.count).max() ?? 0
        guard maxSize * 2 > total else { return [] }
        var ads = Set<Int>()
        for group in groups.values where group.count < maxSize { ads.formUnion(group) }
        return ads
    }

    private static func findAdsByPrefixAnalysis(_ segments: [[UInt16]]) -> Set<Int> {
        guard let length = optimalPrefixLength(segments) else { return [] }
        let groups = groupIndexes(segments) { prefix($0, length) }
        guard groups.count > 1, groups.count <= reasonableGroupLimit else { return [] }
        return findMinorityGroup(groups)
    }

    private static func optimalPrefixLength(_ segments: [[UInt16]]) -> Int? {
        guard segments.count >= 2 else { return nil }
        let shortest = segments.map(\.count).min() ?? 0
        var best: Int?
        var highestScore = 0.0
        let maxLength = shortest - sequenceNumberReservedLength
        var length = minPrefixLengthToTest
        while length < maxLength {
            let groups = groupIndexes(segments) { prefix($0, length) }
            if groups.count > 1 && groups.count <= reasonableGroupLimit {
                let maxGroup = groups.values.map(\.count).max() ?? 0
                let score = Double(maxGroup) / Double(segments.count)
                if score >= minMajorityGroupRatio && score > highestScore {
                    highestScore = score
                    best = length
                }
            }
            length += 1
        }
        return best
    }

    private static func prefix(_ segment: [UInt16], _ length: Int) -> [UInt16] {
        segment.count > length ? Array(segment[..<length]) : segment
    }

    private static func groupIndexes(_ segments: [[UInt16]],
                                     by key: ([UInt16]) -> [UInt16]) -> [[UInt16]: [Int]] {
        var groups = [[UInt16]: [Int]]()
        for (index, segment) in segments.enumerated() { groups[key(segment), default: []].append(index) }
        return groups
    }

    static func isSegmentLine(_ trimmed: [UInt16]) -> Bool {
        !trimmed.isEmpty && trimmed[0] != JavaText.hash
    }

    // MARK: - Rebuilding

    private static func rebuild(_ lines: [[UInt16]], _ ads: Set<Int>) -> String {
        let cleaned = removeOrphanedDiscontinuityTags(removeAdSegments(lines, ads))
        var out = [UInt16]()
        for line in cleaned {
            out.append(contentsOf: line)
            out.append(JavaText.newline)
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// Drops an ad's `#EXTINF` and every line after it up to and including its URI; lines before
    /// its `#EXTINF` (a key, a discontinuity) stay. Blank lines go, and every line is trimmed.
    private static func removeAdSegments(_ lines: [[UInt16]], _ ads: Set<Int>) -> [[UInt16]] {
        var result = [[UInt16]]()
        var skipping = false
        var segmentIndex = 0
        for source in lines {
            let line = JavaText.trim(source)
            if line.isEmpty { continue }
            if JavaText.starts(line, with: tagDuration), ads.contains(segmentIndex) {
                skipping = true
                continue
            }
            if isSegmentLine(line) {
                segmentIndex += 1
                if skipping || ads.contains(segmentIndex - 1) {
                    skipping = false
                    continue
                }
            } else if skipping {
                continue
            }
            result.append(line)
        }
        return result
    }

    private static func removeOrphanedDiscontinuityTags(_ lines: [[UInt16]]) -> [[UInt16]] {
        var result = [[UInt16]]()
        for (index, line) in lines.enumerated() {
            if line == tagDiscontinuity {
                let previousIsBoundary = index == 0 || lines[index - 1] == tagDiscontinuity
                let next = index + 1 < lines.count ? lines[index + 1] : nil
                let nextIsBoundary = next == nil || next == tagDiscontinuity || next == tagEndList
                if previousIsBoundary || nextIsBoundary { continue }
            }
            result.append(line)
        }
        return result
    }
}

/// The handful of `java.lang.String` / `Double` behaviours the ported Android code relies on, on
/// UTF-16 code units. Internal: only the IOS-POC-25 port uses them.
enum JavaText {
    static let newline: UInt16 = 0x0A
    static let carriageReturn: UInt16 = 0x0D
    static let hash: UInt16 = 0x23
    static let comma: UInt16 = 0x2C
    static let slash: UInt16 = 0x2F
    static let colon: UInt16 = 0x3A

    static func units(_ text: String) -> [UInt16] { Array(text.utf16) }

    /// `value.split("\\r?\\n", -1)`: split at every LF, one CR before it belongs to the separator,
    /// trailing empty pieces kept.
    static func lines(_ text: [UInt16]) -> [[UInt16]] {
        text.split(separator: newline, omittingEmptySubsequences: false).map { piece in
            piece.last == carriageReturn ? Array(piece.dropLast()) : Array(piece)
        }
    }

    /// `String.trim()`: every code unit up to U+0020 off both ends — not Unicode whitespace.
    static func trim(_ line: [UInt16]) -> [UInt16] {
        guard let first = line.firstIndex(where: { $0 > 0x20 }),
              let last = line.lastIndex(where: { $0 > 0x20 }) else { return [] }
        return Array(line[first...last])
    }

    static func starts(_ line: [UInt16], with prefix: [UInt16]) -> Bool {
        line.count >= prefix.count && line[..<prefix.count].elementsEqual(prefix)
    }

    static func contains(_ text: [UInt16], _ needle: [UInt16]) -> Bool {
        index(of: needle, in: text) != nil
    }

    static func index(of unit: UInt16, in text: [UInt16], from start: Int = 0) -> Int? {
        guard start < text.count else { return nil }
        return text[start...].firstIndex(of: unit)
    }

    static func index(of needle: [UInt16], in text: [UInt16], from start: Int = 0) -> Int? {
        guard !needle.isEmpty else { return start <= text.count ? start : nil }
        var index = start
        while index + needle.count <= text.count {
            if text[index] == needle[0], text[index..<index + needle.count].elementsEqual(needle) {
                return index
            }
            index += 1
        }
        return nil
    }

    /// `Double.parseDouble` for what a playlist can hold: surrounding code units up to U+0020 are
    /// ignored, `NaN` and `Infinity` (exact case, optionally signed) are accepted, as is a trailing
    /// `f`/`F`/`d`/`D` type suffix. Anything else malformed is `nil`, where Java throws.
    static func parseDouble(_ raw: [UInt16]) -> Double? {
        var body = String(decoding: trim(raw), as: UTF16.self)
        var sign = ""
        if let first = body.first, first == "+" || first == "-" {
            sign = first == "-" ? "-" : ""
            body.removeFirst()
        }
        if body == "NaN" { return .nan }
        if body == "Infinity" { return sign == "-" ? -.infinity : .infinity }
        if let last = body.last, "fFdD".contains(last) { body.removeLast() }
        // Java's hexadecimal form needs its binary exponent; Swift reads the same notation.
        if body.hasPrefix("0x") || body.hasPrefix("0X") {
            let hex = body.dropFirst(2)
            guard let p = hex.firstIndex(where: { $0 == "p" || $0 == "P" }),
                  hex[..<p].contains(where: \.isHexDigit),
                  hex[..<p].allSatisfy({ $0.isHexDigit || $0 == "." }),
                  hex[..<p].filter({ $0 == "." }).count <= 1 else { return nil }
            var exponent = hex[hex.index(after: p)...]
            if let sign = exponent.first, sign == "+" || sign == "-" { exponent = exponent.dropFirst() }
            guard !exponent.isEmpty, exponent.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
            return Double(sign + body)
        }
        // Otherwise a decimal literal: digits, at most one point, an optional signed exponent.
        let scalars = Array(body.unicodeScalars)
        var index = 0
        var mantissaDigits = 0
        while index < scalars.count, ("0"..."9").contains(scalars[index]) { index += 1; mantissaDigits += 1 }
        if index < scalars.count, scalars[index] == "." {
            index += 1
            while index < scalars.count, ("0"..."9").contains(scalars[index]) { index += 1; mantissaDigits += 1 }
        }
        guard mantissaDigits > 0 else { return nil }
        if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
            index += 1
            if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" { index += 1 }
            let exponentStart = index
            while index < scalars.count, ("0"..."9").contains(scalars[index]) { index += 1 }
            guard index > exponentStart else { return nil }
        }
        guard index == scalars.count else { return nil }
        return Double(sign + body)
    }
}
