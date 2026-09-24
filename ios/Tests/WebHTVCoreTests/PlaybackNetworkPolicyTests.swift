import Foundation
import Testing
@testable import WebHTVCore

// MARK: - Sample builders

/// A reading of a stream that is playing comfortably. Every test below starts from this and
/// changes only the one thing it is about.
private func healthy(bufferAhead: Double = 45, rate: Double = 1,
                     variantCount: Int = 0, stalls: Int = 0) -> PlaybackNetworkSample {
    PlaybackNetworkSample(
        kind: .onDemand, bufferAhead: bufferAhead, likelyToKeepUp: true, bufferEmpty: false,
        playing: true, waitingToPlay: false, rate: rate,
        observedBitrate: 8_000_000, indicatedBitrate: 3_000_000,
        stalls: stalls, variantCount: variantCount
    )
}

private func riskish(variantCount: Int = 0, stalls: Int = 0) -> PlaybackNetworkSample {
    healthy(bufferAhead: 6, variantCount: variantCount, stalls: stalls)
}

/// A rebuffer: the player is waiting on data it does not have. Since IOS-POC-15D that — not merely a
/// thin cushion — is what `poor` means.
private func poorish(variantCount: Int = 0, stalls: Int = 0) -> PlaybackNetworkSample {
    var sample = healthy(bufferAhead: 1.5, variantCount: variantCount, stalls: stalls)
    sample.playing = false
    sample.waitingToPlay = true
    return sample
}

// MARK: - 15A: the policy table

@Test func ordinaryOnDemandPlaybackAsksForSixtySecondsOfForwardBuffer() {
    let policy = PlaybackBufferPolicy.policy(for: .normal, kind: .onDemand, variantCount: 0)

    #expect(policy.forwardBufferSeconds == 60)
    #expect(policy.maximumResolutionHeight == nil)
}

@Test func aStrugglingOnDemandStreamIsAllowedNinetyThenOneHundredAndTwentySeconds() {
    #expect(PlaybackBufferPolicy.policy(for: .risk, kind: .onDemand, variantCount: 0)
        .forwardBufferSeconds == 90)
    #expect(PlaybackBufferPolicy.policy(for: .poor, kind: .onDemand, variantCount: 0)
        .forwardBufferSeconds == 120)
    // Good is not *more* than normal: sixty seconds is the target, not a floor to grow from.
    #expect(PlaybackBufferPolicy.policy(for: .good, kind: .onDemand, variantCount: 0)
        .forwardBufferSeconds == 60)
}

@Test func liveOrUnknownDurationPlaybackNeverInheritsTheLargeVODBuffer() {
    for state in PlaybackNetworkState.allCases {
        let policy = PlaybackBufferPolicy.policy(for: state, kind: .liveOrUnknown, variantCount: 8)

        #expect(policy.forwardBufferSeconds == 0, "\(state) must leave live buffering to the system")
        #expect(policy.maximumResolutionHeight == nil, "\(state) must not cap a live ladder")
    }
}

@Test func noStateEverCapsPeakBitRate() {
    // A peak-bitrate ceiling is a limit on what may be downloaded, not a way to download faster.
    // If anyone ever returns a non-zero value from the policy, this fails.
    for state in PlaybackNetworkState.allCases {
        for kind in [PlaybackItemKind.onDemand, .liveOrUnknown] {
            for variants in [0, 1, 6] {
                let policy = PlaybackBufferPolicy.policy(for: state, kind: kind,
                                                         variantCount: variants)
                #expect(policy.peakBitRate == 0, "\(state)/\(kind)/\(variants) capped peak bitrate")
            }
        }
    }
}

// MARK: - 15A: only a real variant ladder may be capped

@Test func aNonAdaptiveStreamIsNeverQualityCapped() {
    // A direct MP4 reports no variants; a single-variant HLS reports one. Capping either cannot
    // make the player choose something smaller — it can only refuse the one stream there is.
    for variants in [0, 1] {
        for state in PlaybackNetworkState.allCases {
            let policy = PlaybackBufferPolicy.policy(for: state, kind: .onDemand,
                                                     variantCount: variants)
            #expect(policy.maximumResolutionHeight == nil,
                    "\(variants) variant(s) must never be capped, state \(state)")
        }
    }
}

@Test func aRealVariantLadderIsCappedConservativelyAndOnlyWhenStruggling() {
    #expect(PlaybackBufferPolicy.policy(for: .poor, kind: .onDemand, variantCount: 5)
        .maximumResolutionHeight == 720)
    #expect(PlaybackBufferPolicy.policy(for: .risk, kind: .onDemand, variantCount: 5)
        .maximumResolutionHeight == 1080)
    #expect(PlaybackBufferPolicy.policy(for: .normal, kind: .onDemand, variantCount: 5)
        .maximumResolutionHeight == nil)
    #expect(PlaybackBufferPolicy.policy(for: .good, kind: .onDemand, variantCount: 5)
        .maximumResolutionHeight == nil)
}

// MARK: - The single-sample reading

@Test func oneReadingIsClassifiedByCushionThroughputAndKeepUpTogether() {
    #expect(PlaybackNetworkMonitor.level(of: healthy()) == .good)
    #expect(PlaybackNetworkMonitor.level(of: healthy(bufferAhead: 20)) == .normal)
    #expect(PlaybackNetworkMonitor.level(of: riskish()) == .risk)
    #expect(PlaybackNetworkMonitor.level(of: poorish()) == .poor)

    // A comfortable buffer is not good on its own: the player saying it cannot keep up outranks it.
    var doubtful = healthy()
    doubtful.likelyToKeepUp = false
    #expect(PlaybackNetworkMonitor.level(of: doubtful) == .risk)

    // Nor is a comfortable buffer good while throughput is below the variant it is feeding.
    var starved = healthy()
    starved.observedBitrate = 2_000_000
    #expect(PlaybackNetworkMonitor.level(of: starved) == .risk)

    // Throughput that merely keeps up is not healthy either — the buffer can never grow on it.
    var breakingEven = healthy()
    breakingEven.observedBitrate = 3_100_000
    #expect(PlaybackNetworkMonitor.level(of: breakingEven) == .normal)

    // Waiting to play after playback has begun is a rebuffer by another name.
    var waiting = healthy()
    waiting.playing = false
    waiting.waitingToPlay = true
    #expect(PlaybackNetworkMonitor.level(of: waiting) == .poor)
}

@Test func theCushionIsCountedInPlaybackSecondsSoAFastRateCountsAgainstIt() {
    // Twenty-four seconds of media is a comfortable cushion at 1× and eight seconds at 3× — which
    // is the viewer's 2.5×/3× report expressed in the model rather than special-cased beside it.
    #expect(PlaybackNetworkMonitor.level(of: healthy(bufferAhead: 24, rate: 1)) == .normal)
    #expect(PlaybackNetworkMonitor.level(of: healthy(bufferAhead: 24, rate: 3)) == .risk)
    #expect(PlaybackNetworkMonitor.level(of: healthy(bufferAhead: 24, rate: 2.5)) == .risk)

    // Slower than real time never flatters the cushion.
    #expect(healthy(bufferAhead: 24, rate: 0.5).bufferAheadPlaybackSeconds == 24)
}

// MARK: - 15A: hysteresis

@Test func noSingleReadingCanMoveTheState() {
    var monitor = PlaybackNetworkMonitor()
    monitor.ingest(healthy())
    #expect(monitor.state == .normal)

    monitor.ingest(riskish())
    #expect(monitor.state == .normal, "one bad reading is not evidence")

    // A good reading in between clears the run, so an alternating source cannot walk the state down.
    monitor.ingest(healthy())
    monitor.ingest(riskish())
    #expect(monitor.state == .normal)

    monitor.ingest(riskish())
    #expect(monitor.state == .risk, "two consecutive bad readings are")
}

@Test func startUpIsNotMistakenForAStrugglingNetwork() {
    var monitor = PlaybackNetworkMonitor()
    var loading = poorish()
    loading.playing = false
    loading.waitingToPlay = false

    for _ in 0..<8 { monitor.ingest(loading) }

    #expect(monitor.state == .normal, "nothing has played yet, so nothing has gone wrong yet")
}

@Test func anActualStallDropsTheStateAtOnceAndRaisesTheBufferTarget() {
    var monitor = PlaybackNetworkMonitor()
    monitor.ingest(healthy())
    #expect(monitor.state == .normal)

    // A stall is an event, not a reading, so it does not wait for a run of two.
    let policy = monitor.ingest(healthy(stalls: 1))

    #expect(monitor.state == .poor)
    #expect(policy.forwardBufferSeconds == 120)
}

@Test func anEmptyBufferCountsAsARebufferOnlyWhenThePlayerAlsoCannotKeepUp() {
    var monitor = PlaybackNetworkMonitor()
    monitor.ingest(healthy())

    var drained = healthy()
    drained.bufferEmpty = true
    drained.likelyToKeepUp = false
    monitor.ingest(drained)

    #expect(monitor.state == .poor)
}

@Test func recoveryClimbsOneRungAtATimeSoQualityIsNeverRestoredInstantly() {
    var monitor = PlaybackNetworkMonitor()
    monitor.ingest(healthy())
    monitor.ingest(healthy(stalls: 1))
    #expect(monitor.state == .poor)

    // Five clean readings in a row are not yet enough for even one rung.
    for _ in 0..<(PlaybackNetworkThresholds.recoverSamples - 1) {
        monitor.ingest(healthy(variantCount: 5, stalls: 1))
    }
    #expect(monitor.state == .poor)
    #expect(PlaybackBufferPolicy.policy(for: monitor.state, kind: .onDemand, variantCount: 5)
        .maximumResolutionHeight == 720)

    // The sixth buys exactly one rung — 720p becomes 1080p, not unrestricted.
    let afterOneRung = monitor.ingest(healthy(variantCount: 5, stalls: 1))
    #expect(monitor.state == .risk)
    #expect(afterOneRung.maximumResolutionHeight == 1080,
            "a perfect reading must not hand the whole ladder back at once")

    for _ in 0..<PlaybackNetworkThresholds.recoverSamples {
        monitor.ingest(healthy(variantCount: 5, stalls: 1))
    }
    #expect(monitor.state == .normal)
    #expect(PlaybackBufferPolicy.policy(for: monitor.state, kind: .onDemand, variantCount: 5)
        .maximumResolutionHeight == nil)

    for _ in 0..<PlaybackNetworkThresholds.recoverSamples {
        monitor.ingest(healthy(variantCount: 5, stalls: 1))
    }
    #expect(monitor.state == .good)
}

@Test func recoveryIsStructurallySlowerThanDegradation() {
    // Degradation crosses every rung it has evidence for; recovery walks back one at a time. That
    // asymmetry — not a timer — is what makes 1080 → 720 → 1080 → 720 inexpressible.
    var degrading = PlaybackNetworkMonitor()
    degrading.ingest(healthy())
    for _ in 0..<PlaybackNetworkThresholds.recoverSamples { degrading.ingest(healthy()) }
    #expect(degrading.state == .good)

    degrading.ingest(poorish())
    degrading.ingest(poorish())
    #expect(degrading.state == .poor, "good to poor in two readings")

    var recovering = PlaybackNetworkMonitor()
    recovering.ingest(healthy())
    recovering.ingest(healthy(stalls: 1))
    #expect(recovering.state == .poor)
    for _ in 0..<(PlaybackNetworkThresholds.recoverSamples * 3 - 1) {
        recovering.ingest(healthy(stalls: 1))
    }
    #expect(recovering.state != .good, "poor to good takes three full runs, not two readings")
}

@Test func aSteadyStreamStaysWhereItIs() {
    var monitor = PlaybackNetworkMonitor()
    for _ in 0..<40 { monitor.ingest(healthy(bufferAhead: 20)) }

    #expect(monitor.state == .normal, "no flapping on an unchanging source")
}

// MARK: - 15B: naming what is limiting playback

@Test func diagnosticsTellTheFourCasesApart() {
    // 1. The wait was in turning an episode into an address, not in media at all.
    #expect(PlaybackNetworkMonitor.limit(of: healthy(), resolutionSeconds: 6) == .sourceResolution)

    // 2. Throughput is well ahead of the variant, but too little is held in front of the playhead.
    var shortBuffer = healthy(bufferAhead: 4)
    shortBuffer.observedBitrate = 9_000_000
    shortBuffer.indicatedBitrate = 2_000_000
    #expect(PlaybackNetworkMonitor.limit(of: shortBuffer) == .forwardBuffer)

    // 3. One stream, and the provider cannot deliver it fast enough. Nothing to step down to.
    var slowCDN = healthy(bufferAhead: 4, variantCount: 1)
    slowCDN.observedBitrate = 1_000_000
    slowCDN.indicatedBitrate = 4_000_000
    #expect(PlaybackNetworkMonitor.limit(of: slowCDN) == .cdnThroughput)

    // 4. Same shortfall, but smaller variants exist — so the selection is what is too big.
    var tooHigh = slowCDN
    tooHigh.variantCount = 5
    #expect(PlaybackNetworkMonitor.limit(of: tooHigh) == .selectedBitrate)

    // Nothing is wrong.
    #expect(PlaybackNetworkMonitor.limit(of: healthy()) == .healthy)
    #expect(PlaybackNetworkMonitor.limit(of: healthy(), resolutionSeconds: 0.2) == .healthy)
}

@Test func aPausedPlayerIsNotDiagnosedAsAProblem() {
    var paused = poorish()
    paused.playing = false
    paused.waitingToPlay = false

    #expect(PlaybackNetworkMonitor.limit(of: paused) == .healthy)
}

// MARK: - 15C: when the next episode may be resolved

@Test func theNextEpisodeIsNotResolvedBeforePlaybackIsStable() {
    // Ten seconds in, and near the end of a very short episode: the lead window is satisfied and the
    // stability rule is not.
    #expect(!PlaybackPrefetchGate.shouldPrefetch(position: 10, duration: 60, endingSeconds: 0,
                                                 state: .good, alreadyHolding: false))
    #expect(PlaybackPrefetchGate.shouldPrefetch(position: 21, duration: 60, endingSeconds: 0,
                                                state: .good, alreadyHolding: false))
}

@Test func theNextEpisodeIsNotResolvedUntilTheHandoffIsClose() {
    // Twenty seconds into a forty-minute episode is stable, but resolving there would leave the
    // address to go stale for thirty-nine minutes.
    #expect(!PlaybackPrefetchGate.shouldPrefetch(position: 30, duration: 2400, endingSeconds: 0,
                                                 state: .good, alreadyHolding: false))
    #expect(PlaybackPrefetchGate.shouldPrefetch(position: 2320, duration: 2400, endingSeconds: 0,
                                                state: .good, alreadyHolding: false))
}

@Test func theViewersEndingIsWhereTheHandoffActuallyIs() {
    // A title with a ninety-second ending set hands over at 2310, so the window opens at 2220 —
    // ninety seconds earlier than it would for the runtime alone (IOS-POC-5S-2).
    #expect(PlaybackPrefetchGate.shouldPrefetch(position: 2225, duration: 2400, endingSeconds: 90,
                                                state: .good, alreadyHolding: false))
    #expect(!PlaybackPrefetchGate.shouldPrefetch(position: 2225, duration: 2400, endingSeconds: 0,
                                                 state: .good, alreadyHolding: false))
}

@Test func liveAndUnknownDurationPlaybackNeverPrefetches() {
    for duration in [0.0, -1, .infinity, .nan] {
        #expect(!PlaybackPrefetchGate.shouldPrefetch(position: 600, duration: duration,
                                                     endingSeconds: 0, state: .good,
                                                     alreadyHolding: false),
                "duration \(duration) has no handoff to be early for")
    }
}

@Test func aStrugglingStreamIsNotMadeToCompeteWithAPrefetch() {
    #expect(!PlaybackPrefetchGate.shouldPrefetch(position: 2350, duration: 2400, endingSeconds: 0,
                                                 state: .risk, alreadyHolding: false))
    #expect(!PlaybackPrefetchGate.shouldPrefetch(position: 2350, duration: 2400, endingSeconds: 0,
                                                 state: .poor, alreadyHolding: false))
    #expect(PlaybackPrefetchGate.shouldPrefetch(position: 2350, duration: 2400, endingSeconds: 0,
                                                state: .normal, alreadyHolding: false))
}

@Test func onlyOneEpisodeIsEverResolvedAhead() {
    #expect(!PlaybackPrefetchGate.shouldPrefetch(position: 2350, duration: 2400, endingSeconds: 0,
                                                 state: .good, alreadyHolding: true))
}

// MARK: - IOS-POC-15D

@Test func aThinCushionThatIsStillPlayingIsRiskAndOnlyARebufferIsPoor() {
    // One and a half seconds ahead and still playing: tight, which earns 90 s — not 120.
    let thin = healthy(bufferAhead: 1.5)
    #expect(PlaybackNetworkMonitor.level(of: thin) == .risk)

    var monitor = PlaybackNetworkMonitor()
    monitor.ingest(healthy())
    for _ in 0..<10 { monitor.ingest(thin) }
    #expect(monitor.state == .risk)
    let tight = monitor.ingest(thin)
    #expect(tight.forwardBufferSeconds == 90)

    // An actual stall is what earns the 120 s.
    let rebuffered = monitor.ingest(healthy(bufferAhead: 1.5, stalls: 1))
    #expect(rebuffered.forwardBufferSeconds == 120)
    #expect(monitor.state == .poor)
}

@Test func aQualityTheViewerChoseIsNeverCapped() {
    for state in PlaybackNetworkState.allCases {
        let policy = PlaybackBufferPolicy.policy(for: state, kind: .onDemand, variantCount: 4,
                                                 viewerChoseQuality: true)
        #expect(policy.maximumResolutionHeight == nil, "\(state)")
        #expect(policy.peakBitRate == 0)
    }
    // The buffer still grows for it: only the ceiling is withheld.
    var monitor = PlaybackNetworkMonitor()
    monitor.ingest(healthy(variantCount: 4))
    var stalled = healthy(variantCount: 4, stalls: 1)
    stalled.viewerChoseQuality = true
    let policy = monitor.ingest(stalled)
    #expect(policy.forwardBufferSeconds == 120)
    #expect(policy.maximumResolutionHeight == nil)
}

@Test func framesDroppedWithAHealthyBufferNameTheDecoder() {
    var decoding = healthy(rate: 3)
    decoding.droppedFrames = 40
    #expect(PlaybackNetworkMonitor.limit(of: decoding) == .decoding)

    // A handful is noise, not a verdict.
    var noise = healthy()
    noise.droppedFrames = PlaybackNetworkThresholds.decodingDroppedFrames - 1
    #expect(PlaybackNetworkMonitor.limit(of: noise) == .healthy)

    // A short buffer is the network's problem first, whatever the decoder is doing.
    var short = healthy(bufferAhead: 4)
    short.droppedFrames = 40
    short.observedBitrate = 2_000_000
    #expect(PlaybackNetworkMonitor.limit(of: short) == .cdnThroughput)

    // Paused, nothing is being decoded late.
    var paused = decoding
    paused.playing = false
    #expect(PlaybackNetworkMonitor.limit(of: paused) == .healthy)
}
