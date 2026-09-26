import Foundation

/// IOS-POC-15 — what AVPlayer's own numbers say about the network, and what to do about it.
///
/// **Plain values in, policy out, no AVFoundation.** Everything here is arithmetic over readings the
/// app target takes from `AVPlayerItem`, so `swift test` drives the whole model on macOS without a
/// player, a stream or a device. That is the same split `PictureInPictureForegroundRestoreState`
/// already uses: the lifecycle decision is testable, the UIKit/AVKit wiring is not.
///
/// **It never guesses at the network from the radio.** Wi-Fi versus 5G says nothing about whether
/// this CDN is feeding this variant fast enough; the buffer, the stalls and the access log do.

// MARK: - What is loaded

/// Whether the current item is ordinary on-demand video or something whose runtime is unknown.
///
/// Decided from the item's own duration at runtime, never from the URL: a `.m3u8` is as likely to be
/// a film as a live channel, and a source that reports no duration is indistinguishable from a live
/// one — which is exactly why both share this case. A large forward-buffer target is meaningless for
/// a stream with no end, so neither gets one.
public enum PlaybackItemKind: Sendable, Equatable {
    case onDemand
    case liveOrUnknown
}

// MARK: - One observation

/// A single reading of the player, taken on the sampler that already runs every five seconds.
///
/// Every field is something AVFoundation reports directly. Nothing here is inferred, and nothing
/// here is a proxy for anything else — the point of taking all of them is that no one of them is
/// enough: `observedBitrate / indicatedBitrate` alone cannot tell a full buffer from an empty one,
/// and a full buffer alone cannot tell a healthy CDN from one that is about to run out.
public struct PlaybackNetworkSample: Sendable, Equatable {
    public var kind: PlaybackItemKind
    /// Seconds of media already on the device ahead of the playhead, from `loadedTimeRanges`.
    public var bufferAhead: Double
    /// `AVPlayerItem.isPlaybackLikelyToKeepUp`.
    public var likelyToKeepUp: Bool
    /// `AVPlayerItem.isPlaybackBufferEmpty`.
    public var bufferEmpty: Bool
    /// `timeControlStatus == .playing`.
    public var playing: Bool
    /// `timeControlStatus == .waitingToPlayAtSpecifiedRate`. After playback has begun this is a
    /// rebuffer by another name.
    public var waitingToPlay: Bool
    /// The speed playback is running at.
    ///
    /// **This is why the viewer's 3× report belongs to this stage.** Thirty seconds of buffered
    /// media is thirty seconds of cushion at 1× and ten at 3×, so the thresholds below compare
    /// against `bufferAheadPlaybackSeconds` rather than against the raw figure.
    ///
    /// IOS-POC-15 stopped there: a fast rate pushed the state down by itself, which raised the
    /// target, "using the mechanism that is already here instead of adding a second one". That
    /// raises it only once the cushion is already thin, which for a viewer who always watches at 2×
    /// is too late — 60 seconds of media held only 30 of their viewing. **Since IOS-POC-27B the
    /// target follows the speed too** (`PlaybackBufferPolicy.policy(…rate:)`), capped at the most
    /// the model already asked for.
    public var rate: Double
    /// `AVPlayerItemAccessLogEvent.observedBitrate`, bits per second. Zero or negative when the log
    /// has not reported yet, which is treated as "no evidence" rather than as "slow".
    public var observedBitrate: Double
    /// `AVPlayerItemAccessLogEvent.indicatedBitrate` — the variant the player has actually selected.
    public var indicatedBitrate: Double
    /// Stalls counted on this item since it loaded.
    public var stalls: Int
    /// How many variants the asset genuinely offers (`AVURLAsset.variants`).
    ///
    /// **A resolution ceiling may only ever be applied when this is greater than one.** A direct
    /// MP4 reports none and a single-variant HLS reports one; capping either cannot make the player
    /// choose something smaller, it can only refuse the one stream there is.
    public var variantCount: Int
    /// Whether the viewer is playing a quality of their own choosing (IOS-POC-15D).
    ///
    /// True while the source offers the control bar's quality menu: whatever entry plays is one the
    /// viewer picked or kept, and its label is on screen. **The policy never caps such a stream** —
    /// a silent ceiling would contradict the label, and stepping down is the viewer's own choice to
    /// make from the same menu.
    public var viewerChoseQuality: Bool
    /// Video frames the player dropped since the previous sample (`AVPlayerItemAccessLog`). Frames
    /// dropped while the buffer is healthy mean the decoder, not the network, is what cannot keep up.
    public var droppedFrames: Int

    public init(kind: PlaybackItemKind, bufferAhead: Double, likelyToKeepUp: Bool,
                bufferEmpty: Bool, playing: Bool, waitingToPlay: Bool, rate: Double,
                observedBitrate: Double = 0, indicatedBitrate: Double = 0,
                stalls: Int = 0, variantCount: Int = 0, viewerChoseQuality: Bool = false,
                droppedFrames: Int = 0) {
        self.kind = kind
        self.bufferAhead = bufferAhead
        self.likelyToKeepUp = likelyToKeepUp
        self.bufferEmpty = bufferEmpty
        self.playing = playing
        self.waitingToPlay = waitingToPlay
        self.rate = rate
        self.observedBitrate = observedBitrate
        self.indicatedBitrate = indicatedBitrate
        self.stalls = stalls
        self.variantCount = variantCount
        self.viewerChoseQuality = viewerChoseQuality
        self.droppedFrames = droppedFrames
    }

    /// The cushion measured in seconds of *playback* rather than seconds of media.
    public var bufferAheadPlaybackSeconds: Double {
        max(bufferAhead, 0) / PlaybackBufferPolicy.speedFactor(rate)
    }

    /// Whether the access log has said anything usable about throughput yet.
    public var hasThroughputEvidence: Bool {
        observedBitrate.isFinite && observedBitrate > 0
            && indicatedBitrate.isFinite && indicatedBitrate > 0
    }
}

// MARK: - The state

/// How well playback is actually being fed. Ordered, so "better than" and "worse than" are the
/// comparisons the hysteresis is written in.
public enum PlaybackNetworkState: Int, Sendable, Comparable, CaseIterable {
    case poor = 0
    case risk = 1
    case normal = 2
    case good = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - Every threshold, in one place

/// The whole of the tuning surface. Nothing in this file compares against a number that is not
/// declared here, so the policy can be re-tuned from device measurements by editing one type.
public enum PlaybackNetworkThresholds {
    /// Cushion, in playback seconds, below which it is no longer comfortable.
    ///
    /// There is deliberately no "poor" cushion (IOS-POC-15D): a thin buffer that is still playing
    /// is `risk` and earns the 90 s target; only an actual rebuffer — a stall, an empty buffer, a
    /// player waiting to play — earns `poor` and its 120 s.
    public static let riskBufferSeconds: Double = 10
    /// Cushion that has to be held, along with healthy throughput, to count as good.
    public static let goodBufferSeconds: Double = 30

    /// Observed throughput must beat the selected variant's bitrate by this much to be called
    /// healthy. Equal throughput means the buffer can never grow.
    public static let healthyThroughputRatio: Double = 1.3
    /// At or below this the CDN cannot sustain the variant that is playing.
    public static let starvedThroughputRatio: Double = 1.0

    /// Consecutive degraded samples required to step down without a hard signal. A stall or an
    /// empty buffer bypasses this — those are not opinions.
    public static let degradeSamples = 2
    /// Consecutive samples at a better level required to step **one** rung back up. At the
    /// five-second sampler this is thirty seconds per rung, so `poor` to `good` takes ninety.
    public static let recoverSamples = 6

    /// `AVPlayerItem.preferredForwardBufferDuration`, in media seconds, per state.
    public static let normalForwardBufferSeconds: Double = 60
    public static let riskForwardBufferSeconds: Double = 90
    public static let poorForwardBufferSeconds: Double = 120
    /// IOS-POC-27B: the most any speed may ask for — the `poor` target, which the model already
    /// asked for at 1×. So no speed holds more media, or more memory, than a stalled 1× stream
    /// already could, and the wait to refill after a stall is no longer than it was. Whether
    /// AVPlayer honours more than about 100 s is unmeasured; the 30-second buffer line says.
    public static let maximumForwardBufferSeconds: Double = 120

    /// Resolution ceilings, in pixel height. `nil` is unrestricted.
    public static let riskMaximumHeight = 1080
    public static let poorMaximumHeight = 720

    /// A resolution that took at least this long is the thing that delayed playback, whatever the
    /// buffer was doing afterwards.
    public static let slowResolutionSeconds: Double = 2

    /// Dropped frames in one five-second sample, with the buffer healthy, that name the decoder as
    /// the limit — about a third of a second of a 30 fps picture.
    public static let decodingDroppedFrames = 10
}

// MARK: - The policy

/// The three knobs this stage is allowed to turn on an `AVPlayerItem`, and nothing else.
///
/// **There is no URL and no quality here on purpose.** IOS-POC-5Q's lines and qualities are separate
/// WebHTV addresses that the viewer chooses; this model must never swap one for another. All it can
/// do is tell AVPlayer how much to hold and, within the one HLS asset it was given, how large a
/// variant it may pick.
public struct PlaybackBufferPolicy: Sendable, Equatable {
    /// `AVPlayerItem.preferredForwardBufferDuration`. Zero means "leave it to the system", which is
    /// what live and unknown-duration playback gets.
    public let forwardBufferSeconds: Double
    /// Pixel height for `preferredMaximumResolution`; `nil` leaves it unrestricted.
    public let maximumResolutionHeight: Int?
    /// `AVPlayerItem.preferredPeakBitRate`, and it is **always zero**.
    ///
    /// The field exists so that stays checkable rather than merely intended: a peak-bitrate cap is a
    /// ceiling on what the player may download, not a way to make it download faster, and every test
    /// in `PlaybackNetworkPolicyTests` that walks the states asserts this is zero. If anyone ever
    /// returns something else from here, those tests fail.
    public let peakBitRate: Double

    /// What live, unknown-duration and not-yet-classified playback gets: the system's own judgement.
    public static let systemManaged = PlaybackBufferPolicy(
        forwardBufferSeconds: 0, maximumResolutionHeight: nil
    )

    public init(forwardBufferSeconds: Double, maximumResolutionHeight: Int?) {
        self.forwardBufferSeconds = forwardBufferSeconds
        self.maximumResolutionHeight = maximumResolutionHeight
        self.peakBitRate = 0
    }

    /// The speed a cushion or a target is scaled by. Anything slower than 1×, and anything that is
    /// not a real speed — NaN, infinite, zero, negative — counts as 1×: a slow speed needs no less
    /// than the model already asks for, and a bad reading must never become a bad target.
    public static func speedFactor(_ rate: Double) -> Double {
        rate.isFinite && rate > 1 ? rate : 1
    }

    /// The policy for one state and one item. Pure, so every cell of the table has a test.
    ///
    /// `rate` (IOS-POC-27B): the target is media seconds (`preferredForwardBufferDuration`), so at
    /// 2× the 1× table holds half the viewing. It is scaled by the speed — as Media3's
    /// `DefaultLoadControl` scales its buffer — and capped at
    /// `PlaybackNetworkThresholds.maximumForwardBufferSeconds`, as Media3 caps it at its maximum.
    public static func policy(for state: PlaybackNetworkState,
                              kind: PlaybackItemKind,
                              variantCount: Int,
                              viewerChoseQuality: Bool = false,
                              rate: Double = 1) -> PlaybackBufferPolicy {
        // A stream with no known end must not inherit a minute of VOD buffering, and capping its
        // resolution would be guessing at a ladder we have not been shown.
        guard kind == .onDemand else { return .systemManaged }

        let base: Double
        switch state {
        case .good, .normal: base = PlaybackNetworkThresholds.normalForwardBufferSeconds
        case .risk: base = PlaybackNetworkThresholds.riskForwardBufferSeconds
        case .poor: base = PlaybackNetworkThresholds.poorForwardBufferSeconds
        }
        let forward = min(base * speedFactor(rate), PlaybackNetworkThresholds.maximumForwardBufferSeconds)

        // Only a genuinely multi-variant asset has anything to step down to. Anything else keeps the
        // one stream it has — and so does a quality the viewer chose.
        let height: Int?
        if variantCount > 1, !viewerChoseQuality {
            switch state {
            case .poor: height = PlaybackNetworkThresholds.poorMaximumHeight
            case .risk: height = PlaybackNetworkThresholds.riskMaximumHeight
            case .normal, .good: height = nil
            }
        } else {
            height = nil
        }

        return PlaybackBufferPolicy(forwardBufferSeconds: forward, maximumResolutionHeight: height)
    }
}

// MARK: - What is actually limiting playback

/// Which of the things IOS-POC-15 set out to tell apart is holding playback back — slow resolution,
/// too little forward buffer, CDN throughput, too large a variant, and (IOS-POC-15D) the decoder.
public enum PlaybackLimit: Sendable, Equatable {
    case healthy
    /// Time went into turning an episode into an address — `playerContent`, a probe, a sniff — and
    /// not into media at all.
    case sourceResolution
    /// Throughput is ahead of the variant, but too little is being held in front of the playhead.
    case forwardBuffer
    /// The provider cannot deliver as fast as the one stream available needs.
    case cdnThroughput
    /// The player picked a variant this connection cannot sustain, and smaller ones exist.
    case selectedBitrate
    /// The buffer is fine and frames are still being dropped: the decoder cannot keep up — at a
    /// high rate, or with a stream heavier than the device decodes smoothly (IOS-POC-15D).
    case decoding
}

// MARK: - The monitor

/// Turns a stream of samples into a state, with hysteresis, and answers the policy to apply.
///
/// **No single sample may move the state** except an actual stall or an empty buffer, which are
/// events rather than readings. Everything else needs `degradeSamples` in a row to step down, and
/// `recoverSamples` in a row to step up — by **one rung at a time**, so recovery is structurally
/// slower than degradation and a `1080 → 720 → 1080 → 720` oscillation cannot be expressed.
public struct PlaybackNetworkMonitor: Sendable {
    public private(set) var state: PlaybackNetworkState = .normal
    /// Whether anything has played yet. Before it has, a small buffer is a start-up, not a problem,
    /// so no sample is allowed to move the state.
    private var hasPlayed = false
    private var degradedRun = 0
    private var recoveryRun = 0
    private var lastStalls = 0

    public init() {}

    /// What one reading says on its own, before any hysteresis.
    public static func level(of sample: PlaybackNetworkSample) -> PlaybackNetworkState {
        let cushion = sample.bufferAheadPlaybackSeconds
        let moving = sample.playing || sample.waitingToPlay

        // `poor` is a rebuffer, not a thin cushion (IOS-POC-15D).
        if sample.bufferEmpty && moving { return .poor }
        if sample.waitingToPlay { return .poor }

        if !sample.likelyToKeepUp { return .risk }
        if moving && cushion < PlaybackNetworkThresholds.riskBufferSeconds { return .risk }
        if sample.hasThroughputEvidence,
           sample.observedBitrate
            < sample.indicatedBitrate * PlaybackNetworkThresholds.starvedThroughputRatio {
            return .risk
        }

        let throughputHealthy = !sample.hasThroughputEvidence
            || sample.observedBitrate
                >= sample.indicatedBitrate * PlaybackNetworkThresholds.healthyThroughputRatio
        if cushion >= PlaybackNetworkThresholds.goodBufferSeconds && throughputHealthy {
            return .good
        }
        return .normal
    }

    /// Feeds one reading and answers the policy that should be applied now.
    @discardableResult
    public mutating func ingest(_ sample: PlaybackNetworkSample) -> PlaybackBufferPolicy {
        if sample.playing { hasPlayed = true }

        // A stall or an empty buffer is a fact, not a reading, so it does not wait for a run.
        let stalled = sample.stalls > lastStalls
        lastStalls = sample.stalls
        let rebuffered = hasPlayed && (stalled || (sample.bufferEmpty && !sample.likelyToKeepUp))

        if rebuffered {
            state = .poor
            degradedRun = 0
            recoveryRun = 0
        } else if hasPlayed {
            let level = Self.level(of: sample)
            if level < state {
                recoveryRun = 0
                degradedRun += 1
                if degradedRun >= PlaybackNetworkThresholds.degradeSamples {
                    // Degradation may cross several rungs at once: the evidence says where we are.
                    state = level
                    degradedRun = 0
                }
            } else if level > state {
                degradedRun = 0
                recoveryRun += 1
                if recoveryRun >= PlaybackNetworkThresholds.recoverSamples {
                    // Recovery climbs one rung, however good the sample was. Giving the resolution
                    // back is the expensive direction to be wrong in.
                    state = PlaybackNetworkState(rawValue: state.rawValue + 1) ?? state
                    recoveryRun = 0
                }
            } else {
                degradedRun = 0
                recoveryRun = 0
            }
        }

        return PlaybackBufferPolicy.policy(for: state, kind: sample.kind,
                                           variantCount: sample.variantCount,
                                           viewerChoseQuality: sample.viewerChoseQuality,
                                           rate: sample.rate)
    }

    /// Names what is limiting playback, so a log line says which case this is.
    ///
    /// `resolutionSeconds` is how long the last episode-to-address resolution took, when one is
    /// known; it outranks everything because a viewer waiting on `playerContent` is not waiting on
    /// the network at all.
    public static func limit(of sample: PlaybackNetworkSample,
                             resolutionSeconds: Double? = nil) -> PlaybackLimit {
        if let resolutionSeconds,
           resolutionSeconds >= PlaybackNetworkThresholds.slowResolutionSeconds {
            return .sourceResolution
        }
        guard sample.playing || sample.waitingToPlay else { return .healthy }

        let short = sample.bufferAheadPlaybackSeconds < PlaybackNetworkThresholds.riskBufferSeconds
            || !sample.likelyToKeepUp
        guard short else {
            return sample.playing && sample.droppedFrames >= PlaybackNetworkThresholds.decodingDroppedFrames
                ? .decoding : .healthy
        }

        // Something is short. Only the access log can say whether the network is to blame.
        guard sample.hasThroughputEvidence else { return .forwardBuffer }
        if sample.observedBitrate
            >= sample.indicatedBitrate * PlaybackNetworkThresholds.healthyThroughputRatio {
            return .forwardBuffer
        }
        // The connection cannot sustain the variant. Whether that is the provider's fault or the
        // player's choice depends on whether a smaller variant exists at all.
        return sample.variantCount > 1 ? .selectedBitrate : .cdnThroughput
    }
}

// MARK: - When the next episode may be resolved

/// The gate on IOS-POC-15C. Pure, so "not before playback is stable" and "not for a live stream"
/// are assertions rather than intentions.
public enum PlaybackPrefetchGate {
    /// How much of the current episode has to have played before anything is resolved in the
    /// background. Resolving while the current stream is still finding its feet competes with it.
    public static let stablePlaybackSeconds: Double = 20
    /// How close to the handoff the prefetch is allowed to start.
    ///
    /// **This is the whole answer to short-lived addresses.** Resolving at the twenty-second mark of
    /// a forty-minute episode would leave the address to go stale for thirty-nine minutes; resolving
    /// inside the last ninety seconds means it is used almost immediately. No source in this
    /// configuration publishes its TTL, so the defence is to not create the exposure.
    public static let leadSeconds: Double = 90

    /// Whether the next episode may be resolved now.
    ///
    /// - `endingSeconds` is the viewer's own ending offset (IOS-POC-5S-2), because that — not the
    ///   runtime — is where this episode actually hands over.
    /// - A duration that is not finite and positive is live or unknown, and never prefetches: there
    ///   is no handoff to be early for.
    public static func shouldPrefetch(position: Double,
                                      duration: Double,
                                      endingSeconds: Double,
                                      state: PlaybackNetworkState,
                                      alreadyHolding: Bool) -> Bool {
        guard !alreadyHolding else { return false }
        guard duration.isFinite, duration > 0, position.isFinite else { return false }
        guard position >= stablePlaybackSeconds else { return false }
        // Do not spend a source request on the next episode while this one is struggling.
        guard state >= .normal else { return false }
        let handoff = duration - max(endingSeconds, 0)
        return handoff - position <= leadSeconds
    }
}
