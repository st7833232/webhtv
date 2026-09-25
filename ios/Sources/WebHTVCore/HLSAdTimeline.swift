import Foundation

/// IOS-POC-25 — where the detector's omissions sit on the **original** playlist's timeline.
///
/// A port of Android main's `androidx.media3.mpvplayer.HlsAdTimeline`, which exists for the same
/// reason here: the player keeps playing the untouched playlist (its timestamps, implicit AES IVs,
/// byte ranges and rendition alignment stay intact) and skips the detected ranges by seeking.
/// `HLSAdsParser.process` says *which* segments are ads by leaving them out; this maps each
/// omission back to source time and refuses — with no ranges at all — whenever that mapping is not
/// certain.
///
/// Milliseconds on the source timeline, half-open `[startMs, endMs)`.
public struct HLSAdTimeline: Sendable, Equatable {
    public struct Range: Sendable, Hashable {
        public let startMs: Int64
        public let endMs: Int64

        public init(startMs: Int64, endMs: Int64) {
            self.startMs = startMs
            self.endMs = endMs
        }
    }

    /// Nothing to skip: the detector left the playlist as it was.
    public static let none = HLSAdTimeline(ranges: [], durationUs: 0, reason: "no-ads")

    static let maxSegments = 100_000
    /// The detector is heuristic. A multi-minute candidate can be programme content, so it is
    /// preserved instead of making that whole interval unseekable (Android: 120 s, inclusive).
    static let maxAutoSkipBlockUs: Int64 = 120_000_000

    public let ranges: [Range]
    /// The original playlist's total duration, zero when no mapping was made.
    public let durationUs: Int64
    /// Why the timeline is what it is — Android's reason strings, for the log.
    public let reason: String

    init(ranges: [Range], durationUs: Int64, reason: String) {
        self.ranges = ranges
        self.durationUs = durationUs
        self.reason = reason
    }

    /// `HlsAdTimeline.from(original, filtered)`.
    public static func from(original: String?, filtered: String?) -> HLSAdTimeline {
        guard let original else { return .none }
        if let filtered, original.utf16.elementsEqual(filtered.utf16) { return .none }
        guard let source = Playlist.parse(original), let kept = Playlist.parse(filtered),
              !kept.segments.isEmpty, kept.segments.count < source.segments.count
        else { return empty("invalid-or-unchanged-playlist") }
        let count = kept.segments.count
        var first = [Int](repeating: 0, count: count)
        var cursor = 0
        for index in 0..<count {
            let segment = kept.segments[index]
            while cursor < source.segments.count, segment != source.segments[cursor] { cursor += 1 }
            if cursor == source.segments.count { return empty("not-a-subsequence") }
            first[index] = cursor
            cursor += 1
        }
        // Repeated URIs/durations/ranges must not silently identify the wrong occurrence: the
        // earliest and the latest possible matching have to be the same one.
        cursor = source.segments.count - 1
        for index in stride(from: count - 1, through: 0, by: -1) {
            let segment = kept.segments[index]
            while cursor >= 0, segment != source.segments[cursor] { cursor -= 1 }
            if cursor != first[index] { return empty("ambiguous-segments") }
            cursor -= 1
        }
        var ranges = [Range]()
        var positionUs: Int64 = 0
        var adStartUs: Int64 = -1
        var keptIndex = 0
        var preservedBlocks = 0
        for index in source.segments.indices {
            let retained = keptIndex < count && first[keptIndex] == index
            // Separate source blocks are validated before they merge, so a false-positive
            // programme block cannot swallow the short ad next to it.
            if adStartUs >= 0, retained || source.discontinuities.contains(index) {
                if !addRange(&ranges, startUs: adStartUs, endUs: positionUs) { preservedBlocks += 1 }
                adStartUs = -1
            }
            if retained {
                keptIndex += 1
            } else if adStartUs < 0 {
                adStartUs = positionUs
            }
            positionUs += source.segments[index].durationUs
        }
        if adStartUs >= 0, !addRange(&ranges, startUs: adStartUs, endUs: positionUs) { preservedBlocks += 1 }
        return HLSAdTimeline(ranges: ranges, durationUs: positionUs,
                             reason: preservedBlocks == 0
                                 ? "exo-hls-detector" : "exo-hls-detector-long-blocks-preserved")
    }

    /// Rounds **inward**: never skip programme content at a sub-millisecond boundary.
    private static func addRange(_ ranges: inout [Range], startUs: Int64, endUs: Int64) -> Bool {
        if endUs - startUs > maxAutoSkipBlockUs { return false }
        var startMs = startUs / 1000 + (startUs % 1000 == 0 ? 0 : 1)
        let endMs = endUs / 1000
        if endMs > startMs {
            if let last = ranges.last, last.endMs == startMs {
                startMs = ranges.removeLast().startMs
            }
            ranges.append(Range(startMs: startMs, endMs: endMs))
        }
        return true
    }

    private static func empty(_ reason: String) -> HLSAdTimeline {
        HLSAdTimeline(ranges: [], durationUs: 0, reason: reason)
    }

    /// The same cut points over the same total duration — the agreement a variant must show.
    public func sameCuts(_ other: HLSAdTimeline?) -> Bool {
        guard let other else { return false }
        return durationUs == other.durationUs && ranges == other.ranges
    }

    /// Where a position inside a range goes: the range's end. Anything else stays where it is.
    public func skipTargetMs(_ positionMs: Int64) -> Int64 {
        range(at: positionMs)?.endMs ?? positionMs
    }

    /// The first range that has not ended by `positionMs`.
    public func nextRange(_ positionMs: Int64) -> Range? {
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].endMs <= positionMs { low = mid + 1 } else { high = mid }
        }
        return low == ranges.count ? nil : ranges[low]
    }

    /// The range containing `positionMs`, if any.
    public func range(at positionMs: Int64) -> Range? {
        var low = 0
        var high = ranges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = ranges[mid]
            if positionMs < range.startMs {
                high = mid - 1
            } else if positionMs >= range.endMs {
                low = mid + 1
            } else {
                return range
            }
        }
        return nil
    }

    /// Keeps stale position readings from repeatedly seeking to the same cut end.
    public struct SkipState: Sendable {
        private var requested = Set<Range>()

        public init() {}

        /// The end of the range `positionMs` is in, the first time that range is reached; nil
        /// otherwise.
        public mutating func nextTargetMs(_ timeline: HLSAdTimeline, _ positionMs: Int64) -> Int64? {
            guard let range = timeline.range(at: positionMs), requested.insert(range).inserted
            else { return nil }
            return range.endMs
        }

        /// A range already dealt with some other way (a seek the viewer made into it).
        public mutating func markRequested(_ range: Range) { requested.insert(range) }

        public mutating func clear() { requested.removeAll() }
    }

    // MARK: - Variants (Android `MpvHlsProxy.resolveAdTimeline`)

    /// `HlsPlaylistRewriter.Variant`: a master playlist entry, identified by what it declares.
    public struct Variant: Sendable, Hashable {
        public enum Kind: Sendable, Hashable { case stream, iFrame, image }

        public let bandwidth: Int64
        public let averageBandwidth: Int64
        public let width: Int
        public let height: Int
        public let kind: Kind

        public init(bandwidth: Int64, averageBandwidth: Int64, width: Int, height: Int,
                    kind: Kind = .stream) {
            self.bandwidth = bandwidth
            self.averageBandwidth = averageBandwidth
            self.width = width
            self.height = height
            self.kind = kind
        }

        /// `HlsVariant.selectionBitsPerSecond`: the peak bandwidth, or the average without one.
        var selectionBitsPerSecond: Int64 { bandwidth > 0 ? bandwidth : averageBandwidth }
    }

    /// How many regular video variants a master declares — `buildVariantLadder`'s count: stream
    /// variants with a positive selection bitrate, one per bitrate.
    public static func declaredVariantCount(_ variants: [Variant]) -> Int {
        Set(variants.filter { $0.kind == .stream && $0.selectionBitsPerSecond > 0 }
            .map(\.selectionBitsPerSecond)).count
    }

    /// `resolveAdTimeline`. A direct media playlist's own timeline wins. Otherwise only stream
    /// variants count, a known selection narrows them to the variants at that bitrate, and every
    /// variant considered must cut the same ranges. **Probing a rendition does not mean it is
    /// selected**: with the selection unknown, every declared regular video variant must have a
    /// timeline, and all of them must agree.
    public static func resolve(direct: HLSAdTimeline?, variants: [Variant: HLSAdTimeline],
                               selectedBitsPerSecond: Int64, declaredVariantCount: Int) -> HLSAdTimeline {
        if let direct { return direct }
        var candidate: HLSAdTimeline?
        var matched = 0
        // A fixed order, so the reason a caller logs does not depend on hashing.
        let ordered = variants.sorted { lhs, rhs in
            (lhs.key.bandwidth, lhs.key.averageBandwidth, lhs.key.width, lhs.key.height)
                < (rhs.key.bandwidth, rhs.key.averageBandwidth, rhs.key.width, rhs.key.height)
        }
        for (variant, timeline) in ordered {
            guard variant.kind == .stream else { continue }
            if selectedBitsPerSecond > 0, selectedBitsPerSecond != variant.bandwidth,
               selectedBitsPerSecond != variant.averageBandwidth { continue }
            if let candidate, !candidate.sameCuts(timeline) { return .none }
            candidate = timeline
            matched += 1
        }
        if selectedBitsPerSecond <= 0, declaredVariantCount <= 0 || matched != declaredVariantCount {
            return .none
        }
        return candidate ?? .none
    }

    // MARK: - The playlist, as the mapping reads it

    private struct Segment: Equatable {
        let uri: [UInt16]
        let durationUs: Int64
        let byteRange: [UInt16]
    }

    private struct Playlist {
        let segments: [Segment]
        let discontinuities: Set<Int>

        private static let extM3U = JavaText.units("#EXTM3U")
        private static let streamInf = JavaText.units("#EXT-X-STREAM-INF:")
        private static let part = JavaText.units("#EXT-X-PART:")
        private static let skip = JavaText.units("#EXT-X-SKIP:")
        private static let iFramesOnly = JavaText.units("#EXT-X-I-FRAMES-ONLY")
        private static let endList = JavaText.units("#EXT-X-ENDLIST")
        private static let discontinuity = JavaText.units("#EXT-X-DISCONTINUITY")
        private static let extInf = JavaText.units("#EXTINF:")
        private static let byteRangeTag = JavaText.units("#EXT-X-BYTERANGE:")

        /// A finished media playlist, or nil for anything else: a master, LL-HLS parts or skips,
        /// an I-frame playlist, a live playlist, a malformed or overflowing duration, a URI with no
        /// `#EXTINF`, or media after `#EXT-X-ENDLIST`.
        static func parse(_ text: String?) -> Playlist? {
            guard let text else { return nil }
            var content = JavaText.units(JavaText.strip(text))
            if content.first == 0xFEFF { content.removeFirst() }
            guard JavaText.starts(content, with: extM3U) else { return nil }
            var segments = [Segment]()
            var discontinuities = Set<Int>()
            var durationUs: Int64 = -1
            var totalUs: Int64 = 0
            var byteRange = [UInt16]()
            var ended = false
            for raw in JavaText.lines(content) {
                let line = JavaText.trim(raw)
                if JavaText.starts(line, with: streamInf) || JavaText.starts(line, with: part)
                    || JavaText.starts(line, with: skip) || line == iFramesOnly { return nil }
                if line == endList {
                    ended = true
                } else if line == discontinuity {
                    discontinuities.insert(segments.count)
                } else if JavaText.starts(line, with: extInf) {
                    if ended || durationUs >= 0 { return nil }
                    let end = JavaText.index(of: JavaText.comma, in: line) ?? line.count
                    let value = JavaText.trim(Array(line[extInf.count..<end]))
                    if value.count > 48 { return nil }
                    guard let parsed = JavaBigDecimal.microseconds(value), parsed > 0 else { return nil }
                    durationUs = parsed
                } else if JavaText.starts(line, with: byteRangeTag) {
                    byteRange = JavaText.trim(Array(line[byteRangeTag.count...]))
                } else if !line.isEmpty, line[0] != JavaText.hash {
                    if ended || durationUs <= 0 || segments.count >= HLSAdTimeline.maxSegments { return nil }
                    let (sum, overflow) = totalUs.addingReportingOverflow(durationUs)
                    if overflow { return nil }
                    totalUs = sum
                    segments.append(Segment(uri: line, durationUs: durationUs, byteRange: byteRange))
                    durationUs = -1
                    byteRange = []
                }
            }
            return ended && durationUs < 0 && !segments.isEmpty
                ? Playlist(segments: segments, discontinuities: discontinuities) : nil
        }
    }
}

extension JavaText {
    /// `String.strip()`: `Character.isWhitespace` code points off both ends. Unlike `trim()` this
    /// is Unicode whitespace, minus the no-break spaces Java excludes.
    static func strip(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }),
              let last = scalars.lastIndex(where: { !isWhitespace($0) }) else { return "" }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[first...last])
        return String(view)
    }

    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x1F: return true
        case 0x00A0, 0x2007, 0x202F: return false
        default: break
        }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }
}

/// `new BigDecimal(value)` → `movePointRight(6).setScale(0, HALF_UP).longValueExact()`, with the
/// `scale()` bounds `HlsAdTimeline` checks, done in integers so nothing rounds twice.
enum JavaBigDecimal {
    /// Microseconds, or nil where Android's parse returns null: not a decimal literal, a scale
    /// outside −12…18, or a value that does not fit a `long`. A negative value is nil too: every
    /// one of them is `<= 0`, which `HlsAdTimeline` rejects anyway. ASCII digits only — Java would
    /// also take other Unicode digits; refusing them only means no ranges.
    static func microseconds(_ value: [UInt16]) -> Int64? {
        var index = 0
        if index < value.count, value[index] == 0x2B || value[index] == 0x2D {
            if value[index] == 0x2D { return nil }
            index += 1
        }
        var digits = [UInt8]()
        var fraction = 0
        var seenPoint = false
        while index < value.count {
            let unit = value[index]
            if unit >= 0x30, unit <= 0x39 {
                digits.append(UInt8(unit - 0x30))
                if seenPoint { fraction += 1 }
            } else if unit == 0x2E, !seenPoint {
                seenPoint = true
            } else {
                break
            }
            index += 1
        }
        guard !digits.isEmpty else { return nil }
        var exponent = 0
        if index < value.count, value[index] == 0x65 || value[index] == 0x45 {
            index += 1
            var negative = false
            if index < value.count, value[index] == 0x2B || value[index] == 0x2D {
                negative = value[index] == 0x2D
                index += 1
            }
            let start = index
            var magnitude = 0
            while index < value.count, value[index] >= 0x30, value[index] <= 0x39 {
                magnitude = magnitude * 10 + Int(value[index] - 0x30)
                // Beyond `int`: `BigDecimal` refuses the exponent.
                if magnitude > Int(Int32.max) { return nil }
                index += 1
            }
            guard index > start else { return nil }
            exponent = negative ? -magnitude : magnitude
        }
        guard index == value.count else { return nil }
        let scale = fraction - exponent
        guard scale >= -12, scale <= 18 else { return nil }
        // value = digits × 10^-scale, so microseconds = digits × 10^(6 - scale).
        let shift = 6 - scale
        var kept = digits
        var roundUp = false
        if shift >= 0 {
            kept.append(contentsOf: repeatElement(0, count: shift))
        } else {
            let dropped = -shift
            let firstDropped = kept.count - dropped
            roundUp = firstDropped >= 0 && kept[firstDropped] >= 5
            kept = firstDropped > 0 ? Array(kept[..<firstDropped]) : []
        }
        var result: Int64 = 0
        for digit in kept {
            let (times, overflowTimes) = result.multipliedReportingOverflow(by: 10)
            let (plus, overflowPlus) = times.addingReportingOverflow(Int64(digit))
            if overflowTimes || overflowPlus { return nil }
            result = plus
        }
        if roundUp {
            let (plus, overflow) = result.addingReportingOverflow(1)
            if overflow { return nil }
            result = plus
        }
        return result
    }
}
