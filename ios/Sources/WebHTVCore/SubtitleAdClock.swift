import Foundation

/// IOS-POC-45E — a downloaded subtitle's clock on a stream that still carries its ads.
///
/// 智慧去廣 does not take the ads out of the playlist: both engines play the original one and seek
/// past each detected range (`HLSAdTimeline`), so the ad seconds stay in the engine's clock. A
/// file downloaded for the video is timed to the programme alone. One constant correction can
/// therefore only hold between two ad breaks: lined up after the first, a line is early by the
/// second break's length once the viewer seeks past it. This maps the engine's position onto the
/// programme's own time instead, so one correction holds for the whole video.
///
/// Seconds on the engine's (the playlist's) timeline, half-open `[start, end)`.
public struct SubtitleAdClock: Sendable, Equatable {
    public struct Ad: Sendable, Equatable {
        public let start: Double
        public let end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }

        var length: Double { end - start }
    }

    /// Sorted, never overlapping or touching.
    public let ads: [Ad]

    /// No ads to take out: every lookup is exactly what it was before IOS-POC-45E.
    public static let none = SubtitleAdClock(ads: [])

    public init(ads: [Ad]) {
        var merged = [Ad]()
        for ad in ads.filter({ $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, ad.start <= last.end {
                merged[merged.count - 1] = Ad(start: last.start, end: max(last.end, ad.end))
            } else {
                merged.append(ad)
            }
        }
        self.ads = merged
    }

    /// The plan's ranges. Ranges `HLSAdSkipper.adjacentRangeGapMs` apart are one ad split across
    /// blocks (the skipper jumps them in one seek), so they count as one here too.
    public init(_ timeline: HLSAdTimeline) {
        var ads = [Ad]()
        var last: HLSAdTimeline.Range?
        for range in timeline.ranges.sorted(by: { $0.startMs < $1.startMs }) {
            if let previous = last, range.startMs - previous.endMs <= HLSAdSkipper.adjacentRangeGapMs {
                last = HLSAdTimeline.Range(startMs: previous.startMs, endMs: max(previous.endMs, range.endMs))
            } else {
                if let previous = last { ads.append(Ad(start: Double(previous.startMs) / 1000, end: Double(previous.endMs) / 1000)) }
                last = range
            }
        }
        if let previous = last { ads.append(Ad(start: Double(previous.startMs) / 1000, end: Double(previous.endMs) / 1000)) }
        self.init(ads: ads)
    }

    public var isEmpty: Bool { ads.isEmpty }
    public var count: Int { ads.count }
    public var totalSeconds: Double { ads.reduce(0) { $0 + $1.length } }

    /// Ad time already played, or skipped, at `position`: all of each ad before it, the part of
    /// the one it is in.
    public func adSeconds(before position: Double) -> Double {
        ads.reduce(0) { $0 + min(max(position - $1.start, 0), $1.length) }
    }

    /// The ads wholly behind `position`, the one it is in left out.
    public func adSeconds(endedBy position: Double) -> Double {
        ads.reduce(0) { $1.end <= position ? $0 + $1.length : $0 }
    }

    public func isInsideAd(_ position: Double) -> Bool {
        ads.contains { $0.start <= position && position < $0.end }
    }

    /// The programme's own time at `position`; nil inside an ad, which has none.
    public func contentTime(at position: Double) -> Double? {
        guard position.isFinite, !isInsideAd(position) else { return nil }
        return position - adSeconds(before: position)
    }

    /// What an engine that only shifts subtitles (mpv's `sub-delay`) must be given at `position`
    /// for the viewer's correction to hold: that correction plus every ad that has begun. Inside an
    /// ad the whole ad counts, so the value is already right where the programme resumes; the
    /// subtitle is hidden meanwhile (`isInsideAd`).
    public func engineDelay(user: Double, at position: Double) -> Double {
        user + ads.reduce(0) { $1.start <= position ? $0 + $1.length : $0 }
    }
}
