import Foundation

// IOS-POC-25 — HLS mid-stream ad skip, for both engines.
//
// Android main detects the ads in an HLS VOD playlist with Media3's `HlsAdsParser`; ExoPlayer plays
// the filtered playlist, while MPV keeps the original one and seeks past the detected source-time
// ranges (`HlsAdTimeline`, `MpvHlsProxy.resolveAdTimeline`, `MpvPlayer.maybeSkipHlsAd`). iOS has no
// playlist proxy, so the app reads the playlist itself once the engine has opened it, runs the
// same detector and the same mapping, and both engines seek past the ranges — AVPlayer and MPV
// share this one plan and these decisions. Everything here is pure or plain Foundation; the app
// only feeds it the engine's position and performs the seeks it asks for.

/// What one item's playlist says can be skipped.
public struct HLSAdPlan: Sendable, Equatable {
    /// The ranges, already agreed across every declared variant.
    public let timeline: HLSAdTimeline
    /// Whether any media playlist behind the item carries `#EXT-X-DISCONTINUITY`.
    ///
    /// **Why MPV needs to know.** Stock FFmpeg n8.1.2 ignores the tag: `hls.c` passes each
    /// segment's own timestamps through, so across an inserted ad MPV's `time-pos` stops being
    /// source time, and IOS-POC-25 kept MPV off such playlists. Since `0.1.23 (24)` the app links
    /// WebHTV's Libavformat (`ffmpeg-n8.1.2-webhtv.1`, IOS-POC-26-2b), whose patch 0006 anchors a
    /// VOD's timestamps to the playlist timeline (Android's FFmpeg, FongMi `177f090e`, only corrects
    /// large jumps), so MPV acts on these playlists too (IOS-POC-25-2), waiting
    /// `HLSAdSkipper.mpvDiscontinuityEntryDelay` for the offsets that mapping leaves. The app
    /// target links with `-u _ff_hls_timestamp_map_segment`, so a build against the stock
    /// Libavformat fails unless this change is reverted with it. AVPlayer keeps the playlist
    /// timeline itself.
    public let hasDiscontinuity: Bool

    public init(timeline: HLSAdTimeline, hasDiscontinuity: Bool) {
        self.timeline = timeline
        self.hasDiscontinuity = hasDiscontinuity
    }

    /// The ranges an engine may act on, or nil when there is nothing to skip. Both engines act on
    /// the same ranges (IOS-POC-25-2, see `hasDiscontinuity`).
    public func timeline(for _: PlaybackEngineKind) -> HLSAdTimeline? {
        guard !timeline.ranges.isEmpty else { return nil }
        return timeline
    }

    static func unavailable(_ reason: String) -> HLSAdPlan {
        HLSAdPlan(timeline: HLSAdTimeline(ranges: [], durationUs: 0, reason: reason), hasDiscontinuity: false)
    }
}

/// A playlist as fetched: its text and the address it finally came from (relative variant URIs
/// resolve against that, as Android resolves them against the response's URL).
public struct HLSFetchedPlaylist: Sendable {
    public let text: String
    public let url: URL

    public init(text: String, url: URL) {
        self.text = text
        self.url = url
    }
}

public enum HLSAdPlanner {
    public typealias Fetch = @Sendable (URL) async throws -> HLSFetchedPlaylist

    /// A playlist is text; anything this large is not one worth reading.
    public static let maximumPlaylistBytes = 8 << 20
    /// A bound on the requests one item may cost. A master declaring more is left alone.
    public static let maximumVariants = 8

    /// `MpvPlayer.isLikelyHls`'s address test: an `http(s)` address containing `m3u8`. DASH, MP4,
    /// FLV and anything else are never fetched at all.
    public static func isCandidate(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.absoluteString.lowercased().contains("m3u8")
    }

    /// The whole plan for one item. Never throws: every failure is a plan with no ranges.
    public static func plan(for url: URL, fetch: Fetch) async -> HLSAdPlan {
        guard isCandidate(url) else { return .unavailable("not-hls") }
        guard let top = try? await fetch(url) else { return .unavailable("fetch-failed") }
        guard isMaster(top.text) else {
            guard let media = await stableTimeline(first: top, url: url, fetch: fetch) else {
                return .unavailable("fetch-failed")
            }
            return validated(HLSAdPlan(timeline: media.timeline, hasDiscontinuity: media.discontinuity))
        }
        let entries = streamVariants(top.text)
        guard !entries.isEmpty else { return .unavailable("master-without-variants") }
        guard entries.count <= maximumVariants else { return .unavailable("too-many-variants") }
        var timelines = [HLSAdTimeline.Variant: HLSAdTimeline]()
        var discontinuity = false
        for entry in entries {
            // Every entry must be read: two entries can share a bitrate, and the resolver counts
            // bitrates, so one left out would not be missed.
            guard let variantURL = URL(string: entry.uri, relativeTo: top.url)?.absoluteURL,
                  let first = try? await fetch(variantURL),
                  let media = await stableTimeline(first: first, url: variantURL, fetch: fetch)
            else { return .unavailable("variant-unreadable") }
            discontinuity = discontinuity || media.discontinuity
            // Two entries declaring the same variant must cut the same ranges (Android's `merge`).
            timelines[entry.variant] = timelines[entry.variant].map { $0.sameCuts(media.timeline) ? $0 : HLSAdTimeline.none }
                ?? media.timeline
        }
        let declared = HLSAdTimeline.declaredVariantCount(entries.map { $0.variant })
        let resolved = HLSAdTimeline.resolve(direct: nil, variants: timelines,
                                             selectedBitsPerSecond: 0, declaredVariantCount: declared)
        return validated(HLSAdPlan(timeline: resolved, hasDiscontinuity: discontinuity))
    }

    /// A media playlist's plan, with no network.
    public static func plan(mediaPlaylist text: String) -> HLSAdPlan {
        validated(HLSAdPlan(timeline: timeline(forMediaPlaylist: text), hasDiscontinuity: hasDiscontinuity(text)))
    }

    /// iOS reads the playlist separately from the engine, and some CDNs insert different ads on
    /// every request. A playlist with ranges is therefore read a second time, and both readings
    /// must cut the same ranges — Android's rule for a variant read twice (`merge` → `NONE`),
    /// applied to every playlist the plan rests on. Nil when the second reading fails.
    private static func stableTimeline(first: HLSFetchedPlaylist, url: URL,
                                       fetch: Fetch) async -> (timeline: HLSAdTimeline, discontinuity: Bool)? {
        let read = Self.timeline(forMediaPlaylist: first.text)
        let discontinuity = hasDiscontinuity(first.text)
        guard !read.ranges.isEmpty else { return (read, discontinuity) }
        guard let again = try? await fetch(url) else { return nil }
        guard read.sameCuts(Self.timeline(forMediaPlaylist: again.text)) else {
            return (HLSAdTimeline(ranges: [], durationUs: 0, reason: "unstable-playlist"), discontinuity)
        }
        return (read, discontinuity || hasDiscontinuity(again.text))
    }

    /// Of the programme, the most a plan may skip.
    public static let maximumSkippedShare = 0.25

    /// **iOS only, not Android's.** A plan that would skip more than `maximumSkippedShare` of the
    /// runtime, or more separate ranges than the detector itself allows ad breaks for that runtime
    /// (3/4/5/6 up to 30/60/90/more minutes — `HlsAdsParser`'s own tier), is not an ad plan but an
    /// unknown structure: host-sharded or renumbered programme segments that the path/prefix
    /// strategy mistook for ads. Nothing is skipped. This can only remove skips, never add one.
    static func validated(_ plan: HLSAdPlan) -> HLSAdPlan {
        let timeline = plan.timeline
        guard !timeline.ranges.isEmpty, timeline.durationUs > 0 else { return plan }
        let skippedUs = timeline.ranges.reduce(0.0) { $0 + Double($1.endMs - $1.startMs) * 1000 }
        if skippedUs > Double(timeline.durationUs) * maximumSkippedShare { return .unavailable("implausible-share") }
        let minutes = Double(timeline.durationUs) / 60_000_000
        if timeline.ranges.count > HLSAdsParser.minorityCountThreshold(totalMinutes: minutes) {
            return .unavailable("too-many-ranges")
        }
        return plan
    }

    /// Android's `applyAdblock` for a video playlist: only a finished playlist is analysed, and
    /// the timeline is the mapping of the detector's own output.
    static func timeline(forMediaPlaylist text: String) -> HLSAdTimeline {
        guard text.uppercased().contains("#EXT-X-ENDLIST") else { return .none }
        return HLSAdTimeline.from(original: text, filtered: HLSAdsParser.process(text))
    }

    private static let discontinuityTag = JavaText.units("#EXT-X-DISCONTINUITY")
    private static let streamInfTag = JavaText.units("#EXT-X-STREAM-INF")
    private static let hashUnit = JavaText.hash

    static func hasDiscontinuity(_ text: String) -> Bool {
        JavaText.lines(JavaText.units(text)).contains { JavaText.trim($0) == discontinuityTag }
    }

    static func isMaster(_ text: String) -> Bool {
        JavaText.lines(JavaText.units(text)).contains { JavaText.starts(JavaText.trim($0), with: streamInfTag) }
    }

    /// `HlsPlaylistRewriter.rewrite`'s variant list: each `#EXT-X-STREAM-INF` with the URI line
    /// after it. I-frame and image playlists are tags with a `URI=` attribute and never become a
    /// variant here, and neither do `#EXT-X-MEDIA` renditions.
    static func streamVariants(_ master: String) -> [(uri: String, variant: HLSAdTimeline.Variant)] {
        var entries = [(uri: String, variant: HLSAdTimeline.Variant)]()
        var pending: HLSAdTimeline.Variant?
        for raw in JavaText.lines(JavaText.units(master)) {
            let line = JavaText.trim(raw)
            if JavaText.starts(line, with: streamInfTag) {
                pending = variant(String(decoding: line, as: UTF16.self))
            } else if !line.isEmpty, line[0] != hashUnit {
                if let variant = pending { entries.append((String(decoding: line, as: UTF16.self), variant)) }
                pending = nil
            }
        }
        return entries
    }

    /// `HlsPlaylistRewriter.parseVariant`.
    static func variant(_ line: String) -> HLSAdTimeline.Variant {
        var width = 0
        var height = 0
        if let resolution = attribute(line, "RESOLUTION"), !resolution.isEmpty {
            let parts = resolution.lowercased().split(separator: "x", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, let w = Int32(trimmed(String(parts[0]))), let h = Int32(trimmed(String(parts[1]))) {
                width = Int(w)
                height = Int(h)
            }
        }
        return HLSAdTimeline.Variant(bandwidth: longAttribute(line, "BANDWIDTH"),
                                     averageBandwidth: longAttribute(line, "AVERAGE-BANDWIDTH"),
                                     width: width, height: height, kind: .stream)
    }

    private static func longAttribute(_ line: String, _ name: String) -> Int64 {
        guard let value = attribute(line, name), let parsed = Int64(value) else { return 0 }
        return max(0, parsed)
    }

    /// `HlsPlaylistRewriter.attributeValue`: after the first `:`, split on every `,` (a quoted
    /// comma splits too, exactly as there), first matching key wins, surrounding quotes dropped.
    static func attribute(_ line: String, _ name: String) -> String? {
        guard let colon = line.firstIndex(of: ":"), line.index(after: colon) < line.endIndex else { return nil }
        for part in line[line.index(after: colon)...].split(separator: ",", omittingEmptySubsequences: false) {
            guard let equals = part.firstIndex(of: "="), equals > part.startIndex else { continue }
            guard trimmed(String(part[..<equals])).caseInsensitiveCompare(name) == .orderedSame else { continue }
            var value = trimmed(String(part[part.index(after: equals)...]))
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }

    private static func trimmed(_ text: String) -> String {
        String(decoding: JavaText.trim(JavaText.units(text)), as: UTF16.self)
    }

    // MARK: Reading a playlist

    public enum FetchError: Error, Equatable {
        case status(Int)
        case tooLarge
        case notAPlaylist
    }

    /// Reads with the source's own headers, the ones the engine sends too. Stops early on a body
    /// that does not start like a playlist, and on one past `maximumPlaylistBytes`.
    public static func fetcher(headers: [String: String], session: URLSession = .webHTV) -> Fetch {
        { url in try await fetchPlaylist(url, headers: headers, session: session) }
    }

    static func fetchPlaylist(_ url: URL, headers: [String: String],
                              session: URLSession) async throws -> HLSFetchedPlaylist {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else { throw FetchError.status(code) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumPlaylistBytes { throw FetchError.tooLarge }
            if data.count == 64, !looksLikePlaylist(data) { throw FetchError.notAPlaylist }
        }
        guard looksLikePlaylist(data) else { throw FetchError.notAPlaylist }
        // OkHttp's `body().string()` consumes a UTF-8 byte order mark; Android's detector never
        // sees one, so this one must not either (it would read as a segment line).
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        return HLSFetchedPlaylist(text: String(decoding: data, as: UTF8.self),
                                  url: response.url ?? url)
    }

    /// `#EXTM3U` after an optional byte order mark and whitespace.
    static func looksLikePlaylist(_ data: Data) -> Bool {
        var head = data.prefix(64)
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { head = head.dropFirst(3) }
        let text = String(decoding: head, as: UTF8.self)
        return JavaText.strip(text).hasPrefix("#EXTM3U")
    }
}

/// One item's ad plan and every skip decision over it, for whichever engine is playing.
///
/// The rules, each Android's unless marked:
/// - A range is skipped once, when playback is running at a position inside it
///   (`maybeSkipHlsAd`, `SkipState`); stale readings cannot seek to the same end again.
/// - A seek the viewer makes into a range lands at its end; any other seek is left alone, and any
///   seek forgets which ranges were skipped (`seekToPosition`).
/// - A new item forgets everything; a new engine under the same item, or the same engine loading
///   it again, forgets which ranges were skipped (`START_FILE`).
/// - iOS: the viewer's ending owns the end of the item. Nothing at or after it is skipped, and a
///   range reaching past it stops there — the existing five-second sampler hands over, so a skip
///   can never race the ending into a second auto-next.
/// - iOS: acting needs evidence that the engine plays **this** playlist, the one read separately:
///   the engine's duration must match the plan's within `durationTolerance`.
/// - iOS: acting needs the playhead seen advancing at the playing rate between two readings, the
///   engine-agnostic stand-in for MPV's `PLAYBACK_RESTART`: a load's placeholder zero, a stale
///   reading after a seek or the jump itself never count as "inside a range".
/// - iOS: after a viewer's seek, automatic skips wait until the playhead is near where it was
///   sent (or `manualSettle` passes), so a reading from before the seek cannot pull it elsewhere.
/// - iOS: a seek made outside the session (PiP, the system's controls) is seen as a jump between
///   readings (`jumpBack`, or further forward than the rate allows) and forgets the same way.
/// - iOS: after an automatic skip the playhead must be seen playing on from the target. Short of
///   it or past it means this engine does not play the plan's timeline, and it stops skipping for
///   the rest of the item.
/// - iOS, MPV: lands `mpvLandingMargin` before a range's end, inside the ad's last segment.
///   FFmpeg n8.1.2 drops the first keyframe of a segment whose timestamp sits just under its
///   playlist start and resumes a whole segment later (WebHTV's Libavformat still does on a
///   playlist without `#EXT-X-DISCONTINUITY`); a target inside the preceding segment cannot lose
///   programme that way. The price is at most that margin of the ad.
/// - iOS, MPV on a playlist with `#EXT-X-DISCONTINUITY` (IOS-POC-25-2): an automatic skip waits
///   until the position reads `mpvDiscontinuityEntryDelay` into a range. After a cut crossed
///   without a seek that reached FFmpeg, WebHTV's Libavformat can leave `time-pos` later than the
///   playlist time of the frame on screen (IOS-POC-26 H1: 0.044-0.093 s per cut, 0.232 s after two
///   breaks on its fixtures, no fixed bound), and mpv serves seeks inside its demuxer cache
///   without FFmpeg, so a skip may not clear that.
///   Skipping at the range's start would cut that much programme; waiting costs at most that much
///   more ad. A viewer's seek is not delayed.
public struct HLSAdSkipper: Sendable {
    /// Plan and engine durations must agree this closely, in seconds.
    public static let durationTolerance = 1.0
    /// How close to a viewer's seek target the playhead must be seen before skips resume.
    public static let manualSettleDistance = 1.0
    /// The longest a viewer's seek holds automatic skips back if its target is never reported.
    public static let manualSettle: Duration = .seconds(3)
    /// Where an automatic skip must be seen landing: this far short of its target at most…
    public static let landingEarly = 0.25
    /// …and at most this far past it (a whole segment late means programme was lost).
    public static let landingLate = 1.5
    /// How long a skip has to be seen landing.
    public static let landingWait: Duration = .seconds(3)
    /// MPV's landing point before a range's end (see the type's notes).
    public static let mpvLandingMargin = 0.1
    /// How far into a range MPV must read before skipping it on a playlist with discontinuities
    /// (see the type's notes). Covers the H1 offsets IOS-POC-26 measured (0.232 s after two breaks);
    /// H1 has no fixed bound, and an offset beyond this still cuts the difference.
    public static let mpvDiscontinuityEntryDelay = 0.25
    /// A playhead seen this far behind its last reading was moved by a seek.
    public static let jumpBack = 0.5

    public private(set) var generation = 0
    public private(set) var plan: HLSAdPlan?
    /// Why skipping stopped for an engine on this item, the first time it did.
    public private(set) var suspensionReason: String?
    private var candidate = false
    private var requested = false
    private var suspended = Set<PlaybackEngineKind>()
    private var skips = HLSAdTimeline.SkipState()
    private var last: (position: Double, at: ContinuousClock.Instant)?
    private var pendingSeek: (seconds: Double, at: ContinuousClock.Instant)?
    private var landing: (target: Double, engine: PlaybackEngineKind, at: ContinuousClock.Instant)?

    public init() {}

    /// A new item: nothing about the previous one survives. Answers the item's generation, which
    /// a plan must carry back to be adopted.
    public mutating func begin(url: URL) -> Int {
        generation &+= 1
        candidate = HLSAdPlanner.isCandidate(url)
        requested = false
        plan = nil
        suspensionReason = nil
        suspended = []
        skips.clear()
        last = nil
        pendingSeek = nil
        landing = nil
        return generation
    }

    /// Nothing is left to do for this item: it is not HLS, or its plan has nothing to skip.
    public var isSettled: Bool {
        !candidate || plan?.timeline.ranges.isEmpty == true
    }

    /// The generation to plan for, once per item: an HLS address, enabled, and an engine that has
    /// opened the media (a duration is known). The item's own address is then already spent by the
    /// engine, never by this; variant playlists the native engine has not loaded yet may still be
    /// read here first.
    public mutating func planRequest(enabled: Bool, duration: Double) -> Int? {
        guard candidate, enabled, !requested, duration.isFinite, duration > 0 else { return nil }
        requested = true
        return generation
    }

    /// Adopts a plan made for `generation`; a plan for an earlier item is dropped.
    @discardableResult
    public mutating func adopt(_ plan: HLSAdPlan, for generation: Int) -> Bool {
        guard generation == self.generation, candidate, self.plan == nil else { return false }
        self.plan = plan
        return true
    }

    /// The same item on a new engine, or loaded again on the same one.
    public mutating func engineReloaded() {
        skips.clear()
        last = nil
        pendingSeek = nil
        landing = nil
    }

    /// The ranges that may act now, or nil.
    public func activeTimeline(engine: PlaybackEngineKind, duration: Double, enabled: Bool) -> HLSAdTimeline? {
        guard enabled, !suspended.contains(engine), let timeline = plan?.timeline(for: engine),
              duration.isFinite, duration > 0,
              abs(duration - Double(timeline.durationUs) / 1_000_000) <= Self.durationTolerance
        else { return nil }
        return timeline
    }

    /// Where playback should jump now, or nil. Call on every reading of the engine.
    public mutating func automaticTarget(position: Double, duration: Double, rate: Float, playing: Bool,
                                         engine: PlaybackEngineKind, enabled: Bool,
                                         endingThreshold: Double?, now: ContinuousClock.Instant) -> Double? {
        let advancing = observe(position: position, rate: rate, now: now)
        checkLanding(position: position, advancing: advancing, engine: engine, now: now)
        if let pending = pendingSeek {
            guard abs(position - pending.seconds) <= Self.manualSettleDistance
                    || now - pending.at > Self.manualSettle else { return nil }
            pendingSeek = nil
        }
        guard landing == nil, playing, advancing,
              let timeline = activeTimeline(engine: engine, duration: duration, enabled: enabled)
        else { return nil }
        if let endingThreshold, position >= endingThreshold { return nil }
        let positionMs = Self.milliseconds(position)
        // The delay is checked first: a range `nextTargetMs` has seen counts as skipped.
        guard let range = timeline.range(at: positionMs),
              positionMs >= range.startMs + entryDelayMs(engine),
              skips.nextTargetMs(timeline, positionMs) != nil else { return nil }
        let target = landingPoint(range, engine: engine, endingThreshold: endingThreshold)
        guard target > position else { return nil }
        landing = (target, engine, now)
        return target
    }

    /// Where a seek the viewer asked for lands: the end of the range it falls in, else unchanged.
    public mutating func manualTarget(_ seconds: Double, duration: Double, engine: PlaybackEngineKind,
                                      enabled: Bool, endingThreshold: Double?,
                                      now: ContinuousClock.Instant) -> Double {
        skips.clear()
        last = nil
        landing = nil
        var target = seconds
        if let timeline = activeTimeline(engine: engine, duration: duration, enabled: enabled),
           endingThreshold.map({ seconds < $0 }) ?? true,
           let range = timeline.range(at: Self.milliseconds(seconds)) {
            skips.markRequested(range)
            target = max(landingPoint(range, engine: engine, endingThreshold: endingThreshold), seconds)
        }
        pendingSeek = (target, now)
        return target
    }

    /// Seconds of playback until the next range can be skipped at `rate` (its start, plus MPV's
    /// entry delay where that applies), zero once it can, nil when there is none — so the caller
    /// can wake at the boundary instead of a tick after it.
    public func secondsUntilNextRange(position: Double, rate: Float, engine: PlaybackEngineKind,
                                      duration: Double, enabled: Bool) -> Double? {
        guard rate > 0,
              let timeline = activeTimeline(engine: engine, duration: duration, enabled: enabled),
              let next = timeline.nextRange(Self.milliseconds(position)) else { return nil }
        let start = Double(next.startMs + entryDelayMs(engine)) / 1000
        return start > position ? (start - position) / Double(rate) : 0
    }

    /// How far into a range `engine` must read before an automatic skip, in milliseconds.
    private func entryDelayMs(_ engine: PlaybackEngineKind) -> Int64 {
        guard engine == .mpv, plan?.hasDiscontinuity == true else { return 0 }
        return Int64((Self.mpvDiscontinuityEntryDelay * 1000).rounded())
    }

    private func landingPoint(_ range: HLSAdTimeline.Range, engine: PlaybackEngineKind,
                              endingThreshold: Double?) -> Double {
        let start = Double(range.startMs) / 1000
        var target = Double(range.endMs) / 1000
        if engine == .mpv { target = max(start, target - Self.mpvLandingMargin) }
        if let endingThreshold { target = min(target, endingThreshold) }
        return target
    }

    /// An automatic skip is done when the playhead is seen playing on from near its target: mpv
    /// reports the target itself until the first frame after the seek decodes. Seen well past it,
    /// or never seen near it, the engine's timeline is not the plan's: that engine stops skipping.
    private mutating func checkLanding(position: Double, advancing: Bool, engine: PlaybackEngineKind,
                                       now: ContinuousClock.Instant) {
        guard let landing else { return }
        guard landing.engine == engine else { self.landing = nil; return }
        if position > landing.target + Self.landingLate {
            suspend(engine, "landed-past-target")
        } else if position >= landing.target - Self.landingEarly {
            if advancing { self.landing = nil }
        } else if now - landing.at > Self.landingWait {
            suspend(engine, "landed-short-of-target")
        }
    }

    private mutating func suspend(_ engine: PlaybackEngineKind, _ reason: String) {
        suspended.insert(engine)
        landing = nil
        if suspensionReason == nil { suspensionReason = reason }
    }

    /// Whether the playhead moved forward about as far as `rate` says it should have since the
    /// last reading. Always records this reading. A jump neither this nor the viewer's seek made
    /// (PiP's skip buttons, the system's controls) forgets which ranges were skipped, as Android's
    /// seek does, so an ad jumped back into is skipped again.
    private mutating func observe(position: Double, rate: Float, now: ContinuousClock.Instant) -> Bool {
        defer { self.last = (position, now) }
        guard position.isFinite, let last, now > last.at else { return false }
        let elapsed = Self.seconds(now - last.at)
        let advanced = position - last.position
        let reach = elapsed * Double(max(rate, 0)) * 2 + 0.25
        if (advanced < -Self.jumpBack || advanced > reach), landing == nil, pendingSeek == nil { skips.clear() }
        return advanced > 0 && advanced <= reach
    }

    /// Down, so a range is entered only once the playhead is really inside it.
    static func milliseconds(_ seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64((seconds * 1000).rounded(.down))
    }

    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// Android's global 智慧去廣 switch (`Setting.isAdblock()`, on by default), for IOS-POC-25's skip.
/// It does not touch IOS-POC-5S-1's sniffer ad list, which the configuration owns.
public struct HLSAdSkipPreference: Sendable {
    public static let key = "webhtv.playback.hlsAdSkip"
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var enabled: Bool { defaults.object(forKey: Self.key) as? Bool ?? true }

    public func setEnabled(_ enabled: Bool) { defaults.set(enabled, forKey: Self.key) }
}
