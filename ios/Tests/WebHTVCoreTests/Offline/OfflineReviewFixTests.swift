import Foundation
import Testing
@testable import WebHTVCore

/// IOS-POC-52: the review of IOS-POC-47 found these; each test reproduces one finding (F1–F40 in
/// docs/IOS-POC-52-offline-review-fixes.md) and fails if the fix goes.
struct OfflineReviewFixTests {
    static let base = URL(string: "https://cdn.example.com/show/ep1/")!

    // MARK: F15 — a malformed number in a playlist

    // `Int(Double("inf"))` traps: a broken source must fail its download, not crash the app on
    // every launch.
    @Test func brokenNumbersFailThePlaylistInsteadOfTrapping() throws {
        for bad in ["#EXT-X-TARGETDURATION:inf", "#EXT-X-TARGETDURATION:nan", "#EXT-X-TARGETDURATION:1e20",
                    "#EXT-X-TARGETDURATION:6\n#EXTINF:inf,", "#EXT-X-TARGETDURATION:6\n#EXTINF:1e300,",
                    "#EXT-X-TARGETDURATION:6\n#EXT-X-BYTERANGE:1e30@0\n#EXTINF:6,"] {
            let text = (["#EXTM3U", bad, "#EXTINF:6,", "s0.ts", "#EXT-X-ENDLIST"]).joined(separator: "\n")
            #expect(throws: HLSPlaylist.ParseError.badNumber) { try HLSPlaylist.parse(text, base: Self.base) }
        }
    }

    // Optional attributes that are not usable numbers are left out, and nothing computed from them traps.
    @Test func unusableVariantNumbersAreIgnored() throws {
        let text = Fixture.masterText([
            "#EXT-X-STREAM-INF:BANDWIDTH=1e30,AVERAGE-BANDWIDTH=99999999999999999999999,RESOLUTION=99999999999x99999999999,FRAME-RATE=nan",
            "v.m3u8",
        ])
        guard case .master(let master) = try HLSPlaylist.parse(text, base: Self.base) else { Issue.record("not a master"); return }
        let variant = try #require(master.variants.first)
        #expect(variant.bandwidth == 0 && variant.averageBandwidth == nil)
        #expect(variant.width == nil && variant.height == nil && variant.frameRate == nil)
        #expect(OfflineMediaSelector.chooseVideo(from: master, mode: .smart) != nil)
        #expect(OfflineMediaSelector.estimate(variant, duration: 1e300) == .unknown)
    }

    // The crash loop: the chosen variant's playlist is broken; the download fails as unsupported
    // and is still failed, not preparing again, after a relaunch.
    @Test func aBrokenVariantPlaylistFailsTheDownloadAndStaysFailed() async throws {
        var network = Fixture.simpleNetwork()
        network.responses[Self.base.absoluteString + "1080/index.m3u8"] = .text(
            "#EXTM3U\n#EXT-X-TARGETDURATION:inf\n#EXTINF:6,\nseg0.ts\n#EXT-X-ENDLIST\n")
        let harness = OfflineHarness(network: network)
        await harness.manager.start()
        guard case .created(let asset) = await harness.manager.enqueue(
            identity: Fixture.identity(), title: Fixture.title(), target: Fixture.target(),
            choice: OfflineDownloadChoice(mode: .smart), estimate: .unknown, autoDeleteAfterWatching: false,
            allowsCellular: false) else { Issue.record("not created"); return }

        let failed = try #require(await harness.waitFor(asset.id, .failed))
        #expect(failed.state == .failed && failed.failure?.kind == .unsupported)
        let relaunched = harness.relaunched(network: network)
        await relaunched.manager.start()
        #expect(await relaunched.manager.asset(asset.id)?.state == .failed)
    }

    // MARK: F2 — a full disk refuses the record

    // The record cannot be written (as on a full disk): the download still fails, its transfers
    // are cancelled, and the record reaches the disk once it can.
    @Test func aRecordTheDiskRefusesStillChangesStateAndIsWrittenLater() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = try await harness.startSimpleDownload()
        try #require(requests.count == 4)
        let metadata = harness.layout.metadataFile(for: asset.id)
        try FileManager.default.removeItem(at: metadata)
        // A directory where the record goes: every write of it fails.
        let blocker = metadata.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)

        await harness.transport.fail(requests[0].tag, OfflineTransferFailure(.http(403)))

        #expect(await harness.waitFor(asset.id, .failed)?.state == .failed)
        let deadline = ContinuousClock.now + .seconds(5)
        while await !harness.transport.cancelled.contains(asset.id), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await harness.transport.cancelled.contains(asset.id))

        // The disk has room again: the next pump writes the record that could not be written.
        try FileManager.default.removeItem(at: metadata)
        await harness.manager.pump()
        let written = try JSONDecoder.offline.decode(OfflineAsset.self, from: Data(contentsOf: metadata))
        #expect(written.state == .failed)
    }

    // MARK: F8 — a clear init section declared before the key

    private func media(_ text: String) throws -> HLSMediaPlaylist {
        guard case .media(let media) = try HLSPlaylist.parse(text, base: Self.base) else { throw HLSPlaylist.ParseError.notAPlaylist }
        return media
    }

    private func localPlaylist(_ text: String) throws -> String {
        let plan = try OfflinePackageBuilder.build(.init(master: nil, variant: nil, video: try media(text), audio: nil, subtitles: []),
                                                   origin: Self.base, headers: [:])
        return try #require(plan.playlists[OfflinePackageBuilder.videoPlaylist])
    }

    private func tags(_ playlist: String) -> [String] {
        playlist.split(separator: "\n").map(String.init).filter { $0.hasPrefix("#EXT-X-KEY") || $0.hasPrefix("#EXT-X-MAP") }
            .map { $0.hasPrefix("#EXT-X-MAP") ? "MAP" : ($0.contains("METHOD=NONE") ? "NONE" : "KEY") }
    }

    // A key applies only to init sections declared after it (RFC 8216 §4.3.2.4): the local copy
    // must keep the clear init section outside the key, or both engines decrypt it into garbage.
    @Test func aMapDeclaredBeforeTheKeyStaysClear() throws {
        let local = try localPlaylist("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MAP:URI="init.mp4"
        #EXT-X-KEY:METHOD=AES-128,URI="k.key",IV=0x01
        #EXTINF:6,
        s0.m4s
        #EXTINF:6,
        s1.m4s
        #EXT-X-ENDLIST
        """)
        #expect(tags(local) == ["MAP", "KEY"])
    }

    @Test func aMapDeclaredAfterTheKeyStaysEncrypted() throws {
        let local = try localPlaylist("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-KEY:METHOD=AES-128,URI="k.key",IV=0x01
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6,
        s0.m4s
        #EXT-X-ENDLIST
        """)
        #expect(tags(local) == ["KEY", "MAP"])
    }

    // A MAP and a KEY changing at the same segment: the new init section under the old (no) key.
    @Test func aMapAndAKeyChangingTogetherKeepTheirOrder() throws {
        let local = try localPlaylist("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MAP:URI="init1.mp4"
        #EXTINF:6,
        s0.m4s
        #EXT-X-MAP:URI="init2.mp4"
        #EXT-X-KEY:METHOD=AES-128,URI="k.key",IV=0x01
        #EXTINF:6,
        s1.m4s
        #EXT-X-ENDLIST
        """)
        #expect(tags(local) == ["MAP", "MAP", "KEY"])
    }

    // MARK: F27 — a byte-order mark

    @Test func everyPlaylistMayStartWithAByteOrderMark() async throws {
        let text = "\u{FEFF}#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\ns0.ts\n#EXT-X-ENDLIST\n"
        #expect(throws: Never.self) { try HLSPlaylist.parse(text, base: Self.base) }
        var network = Fixture.simpleNetwork()
        network.responses[Self.base.absoluteString + "1080/index.m3u8"] = .text("\u{FEFF}" + Fixture.media(4))
        let harness = OfflineHarness(network: network)
        let (asset, _) = try await harness.startSimpleDownload()
        #expect(await harness.manager.asset(asset.id)?.state == .downloading)
    }

    // MARK: F28 — AV1 or VP9 that one engine cannot play

    @Test func av1AndVP9AreChosenOnlyWhenNothingElseFits() throws {
        func master(_ lines: [String]) throws -> HLSMasterPlaylist {
            guard case .master(let master) = try HLSPlaylist.parse(Fixture.masterText(lines), base: Self.base) else {
                throw HLSPlaylist.ParseError.notAPlaylist
            }
            return master
        }
        let mixed = try master([
            Fixture.variant(1920, 1080, codecs: "av01.0.08M.08,mp4a.40.2", bandwidth: 3_000_000, uri: "av1.m3u8"),
            Fixture.variant(1920, 1080, codecs: "vp09.00.40.08,mp4a.40.2", bandwidth: 3_000_000, uri: "vp9.m3u8"),
            Fixture.variant(1280, 720, codecs: "avc1.64001f,mp4a.40.2", bandwidth: 2_500_000, uri: "h264.m3u8"),
        ])
        for mode in OfflineQualityMode.allCases {
            #expect(OfflineMediaSelector.chooseVideo(from: mixed, mode: mode)?.variant.uri.lastPathComponent == "h264.m3u8")
        }
        let onlyAV1 = try master([Fixture.variant(1920, 1080, codecs: "av01.0.08M.08", bandwidth: 3_000_000, uri: "av1.m3u8")])
        #expect(OfflineMediaSelector.chooseVideo(from: onlyAV1, mode: .smart)?.variant.uri.lastPathComponent == "av1.m3u8")
    }

    // MARK: F7 — a key server's error page as the key

    static func encryptedNetwork() -> FakeNetwork {
        var network = Fixture.simpleNetwork()
        network.responses[base.absoluteString + "1080/index.m3u8"] = .text(
            Fixture.media(4, extra: ["#EXT-X-KEY:METHOD=AES-128,URI=\"k.key\""]))
        return network
    }

    @Test func aKeyThatIsNotSixteenBytesFailsTheDownload() async throws {
        let harness = OfflineHarness(network: Self.encryptedNetwork())
        await harness.manager.start()
        guard case .created(let asset) = await harness.manager.enqueue(
            identity: Fixture.identity(), title: Fixture.title(), target: Fixture.target(),
            choice: OfflineDownloadChoice(mode: .smart), estimate: .unknown, autoDeleteAfterWatching: false,
            allowsCellular: false) else { Issue.record("not created"); return }
        let requests = await harness.waitForSubmissions(5, assetID: asset.id)
        let key = try #require(requests.first { $0.url.lastPathComponent == "k.key" })

        await harness.transport.finish(key.tag, body: Data("<html><body>token expired</body></html>".utf8))

        let failed = try #require(await harness.waitFor(asset.id, .failed))
        #expect(failed.state == .failed && failed.failure?.kind == .expiredSource)
        #expect(!FileManager.default.fileExists(atPath: harness.layout.folder(for: asset.id).appendingPathComponent("keys/k1.key").path))
    }

    @Test func theVerifierRefusesAKeyOfTheWrongSize() throws {
        let root = OfflineHarness.scratchLayout().root.appendingPathComponent("pkg")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("keys"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 39).write(to: root.appendingPathComponent("keys/k1.key"))
        let plan = OfflinePackagePlan(units: [OfflineDownloadUnit(index: 0, remoteURL: URL(string: "https://k.example/k")!, byteRange: nil,
                                                                  relativePath: "keys/k1.key", role: .key)],
                                      playlists: [:], package: .hls(entryPath: "playlists/index.m3u8"), origin: Self.base, headers: [:])
        #expect(OfflinePackageVerifier.problems(plan: plan, root: root).contains { $0.hasPrefix("key #0") })
        try Data(repeating: 1, count: 16).write(to: root.appendingPathComponent("keys/k1.key"))
        #expect(OfflinePackageVerifier.problems(plan: plan, root: root).isEmpty)
    }

    // MARK: Retry and re-resolve (F6, F9, F16, F17, F20, F26)

    private func waitUntil(_ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    // F6: a completed download whose files went missing has no request left; 重新下載 resolves the
    // episode again instead of failing as interrupted for ever.
    @Test func aCompletedDownloadWithMissingFilesCanBeDownloadedAgain() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let resolved = Resolutions()
        await harness.manager.setResolver { asset in resolved.append(asset.identity.episodeURL); return Fixture.target() }
        let (asset, _) = try await harness.startSimpleDownload()
        #expect(await harness.completeAll(asset.id)?.state == .completed)
        try FileManager.default.removeItem(at: harness.layout.folder(for: asset.id).appendingPathComponent("playlists"))

        let relaunched = harness.relaunched(network: Fixture.simpleNetwork())
        await relaunched.manager.setResolver { asset in resolved.append(asset.identity.episodeURL); return Fixture.target() }
        await relaunched.manager.start()
        #expect(await relaunched.manager.asset(asset.id)?.failure?.kind == .integrity)
        await relaunched.transport.clearSubmitted()
        await relaunched.manager.resume(asset.id)

        #expect(await relaunched.waitFor(asset.id, .downloading)?.state == .downloading)
        #expect(resolved.all.count == 1)
        #expect(await relaunched.waitForSubmissions(4, assetID: asset.id).count == 4)
    }

    // F9: the source re-encoded the episode — same number of segments, other durations. Files from
    // the first encode must not be mixed into the second.
    @Test func aReResolveWithOtherDurationsStartsTheFilesOver() async throws {
        let fresh = URL(string: Self.base.absoluteString + "master.m3u8?sig=fresh")!
        var network = Fixture.simpleNetwork()
        network.responses[fresh.absoluteString] = network.responses[Fixture.master.absoluteString]
        let harness = OfflineHarness(network: network)
        await harness.manager.setResolver { _ in Fixture.target(fresh) }
        let (asset, requests) = try await harness.startSimpleDownload()
        try #require(requests.count == 4)
        await harness.transport.finish(requests[0].tag, body: Fixture.segment())
        await harness.transport.finish(requests[1].tag, body: Fixture.segment())
        await harness.transport.fail(requests[2].tag, OfflineTransferFailure(.http(403)))
        #expect(await harness.waitFor(asset.id, .failed)?.state == .failed)

        var reEncoded = network
        reEncoded.responses[Self.base.absoluteString + "1080/index.m3u8"] = .text(Fixture.media(4, duration: 5))
        let relaunched = harness.relaunched(network: reEncoded)
        await relaunched.manager.setResolver { _ in Fixture.target(fresh) }
        await relaunched.manager.start()
        await relaunched.transport.clearSubmitted()
        await relaunched.manager.resume(asset.id)

        #expect(await relaunched.waitForSubmissions(4, assetID: asset.id).count == 4)
    }

    // F16: the earlier plan cannot be read — nothing says what the files on disk are, so they go.
    @Test func anUnreadablePlanDiscardsTheFilesItDescribed() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = try await harness.startSimpleDownload()
        try #require(requests.count == 4)
        await harness.transport.finish(requests[0].tag, body: Fixture.segment())
        try Data("{not json".utf8).write(to: harness.layout.planFile(for: asset.id))

        let relaunched = harness.relaunched(network: Fixture.simpleNetwork())
        await relaunched.manager.start()
        #expect(await relaunched.manager.asset(asset.id)?.state == .failed)
        await relaunched.transport.clearSubmitted()
        await relaunched.manager.resume(asset.id)

        #expect(await relaunched.waitForSubmissions(4, assetID: asset.id).count == 4)
    }

    // F17: resume data replays the old address and its Cookie; after a re-resolve it must go.
    @Test func aReResolvedSingleFileDoesNotResumeTheOldRequest() async throws {
        let file = URL(string: "https://cdn.example.com/movie.mp4?sig=old")!
        let fresh = URL(string: "https://cdn.example.com/movie.mp4?sig=new")!
        let answer = FakeNetwork.Response(data: Data(repeating: 0, count: 1024), status: 206,
                                          headers: ["content-range": "bytes 0-1023/50000000"])
        let harness = OfflineHarness(network: FakeNetwork([file.absoluteString: answer, fresh.absoluteString: answer]))
        await harness.manager.setResolver { _ in Fixture.target(fresh) }
        await harness.manager.start()
        guard case .created(let asset) = await harness.manager.enqueue(
            identity: Fixture.identity("movie"), title: Fixture.title(), target: Fixture.target(file, headers: ["Cookie": "sid=1"]),
            choice: OfflineDownloadChoice(mode: .smart), estimate: .unknown, autoDeleteAfterWatching: false,
            allowsCellular: false) else { Issue.record("not created"); return }
        let first = await harness.waitForSubmissions(1)
        try #require(first.count == 1)
        // The connection dropped earlier with resume data; the next answer was a 403.
        await harness.transport.fail(first[0].tag, OfflineTransferFailure(.http(403), resumeData: Data("old request".utf8)))
        #expect(await harness.waitFor(asset.id, .failed)?.state == .failed)
        #expect(await waitUntil { FileManager.default.fileExists(atPath: harness.layout.resumeDataFile(for: asset.id, unit: 0).path) })

        await harness.transport.clearSubmitted()
        await harness.manager.resume(asset.id)
        let retried = await harness.waitForSubmissions(1)
        #expect(retried.first?.url == fresh)
        #expect(retried.first?.resumeData == nil)
    }

    // F20: the chosen subtitle was saved by the first attempt; a retry whose subtitle address no
    // longer answers keeps it.
    @Test func aSavedSubtitleSurvivesARetryThatCannotFetchItAgain() async throws {
        let subtitleURL = "https://subs.example.com/zh.srt"
        let fresh = URL(string: Self.base.absoluteString + "master.m3u8?sig=fresh")!
        var network = Fixture.simpleNetwork()
        network.responses[fresh.absoluteString] = network.responses[Fixture.master.absoluteString]
        let harness = OfflineHarness(network: network, subtitleFiles: [subtitleURL: "1\n00:00:01,000 --> 00:00:02,000\n你好\n"])
        // The re-resolved subtitle lives at an address the subtitle server no longer answers.
        await harness.manager.setResolver { _ in
            Fixture.target(fresh, subtitles: [SourceSubtitle(url: "https://subs.example.com/zh.srt?expired", name: "繁中", language: "zh-TW")])
        }
        await harness.manager.start()
        guard case .created(let asset) = await harness.manager.enqueue(
            identity: Fixture.identity(), title: Fixture.title(),
            target: Fixture.target(subtitles: [SourceSubtitle(url: subtitleURL, name: "繁中", language: "zh-TW")]),
            choice: OfflineDownloadChoice(mode: .smart, subtitleIDs: ["sidecar|0"]), estimate: .unknown,
            autoDeleteAfterWatching: false, allowsCellular: false) else { Issue.record("not created"); return }
        let requests = await harness.waitForSubmissions(4, assetID: asset.id)
        #expect(await harness.manager.asset(asset.id)?.subtitles.map(\.name) == ["繁中"])
        try #require(requests.count == 4)
        await harness.transport.fail(requests[0].tag, OfflineTransferFailure(.http(403)))
        #expect(await harness.waitFor(asset.id, .failed)?.state == .failed)

        await harness.manager.resume(asset.id)
        #expect(await harness.waitFor(asset.id, .downloading)?.state == .downloading)
        #expect(await harness.manager.asset(asset.id)?.subtitles.map(\.name) == ["繁中"])
    }

    // F26: the viewer paused while the episode was being resolved; the late answer that it
    // cannot be resolved changes nothing.
    @Test func aLateResolverFailureDoesNotOverrideAPause() async throws {
        let gate = Gate()
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        await harness.manager.setResolver { _ in await gate.wait(); return nil }
        let (asset, requests) = try await harness.startSimpleDownload()
        try #require(requests.count == 4)
        await harness.transport.fail(requests[0].tag, OfflineTransferFailure(.http(403)))
        #expect(await harness.waitFor(asset.id, .failed)?.state == .failed)
        Task { await harness.manager.resume(asset.id) }
        #expect(await harness.waitFor(asset.id, .preparing)?.state == .preparing)

        await harness.manager.pause(asset.id)
        await gate.open()

        try? await Task.sleep(for: .milliseconds(50))
        #expect(await harness.manager.asset(asset.id)?.state == .paused)
    }

    // MARK: Batch 3 — transfers and background

    // F3: a pause while the submit was still creating transfers; what it created afterwards stops.
    @Test func aPauseDuringASubmitStopsWhatTheSubmitCreatedAfterIt() async throws {
        let gate = Gate()
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        await harness.transport.holdSubmits(gate)
        await harness.manager.start()
        guard case .created(let asset) = await harness.manager.enqueue(
            identity: Fixture.identity(), title: Fixture.title(), target: Fixture.target(),
            choice: OfflineDownloadChoice(mode: .smart), estimate: .unknown, autoDeleteAfterWatching: false,
            allowsCellular: false) else { Issue.record("not created"); return }
        #expect(await harness.waitFor(asset.id, .downloading)?.state == .downloading)

        await harness.manager.pause(asset.id)
        await gate.open()

        #expect(await waitUntil { await harness.transport.submitted.count == 4 })
        let created = Set(await harness.transport.submitted.map(\.tag))
        #expect(await waitUntil { await harness.transport.cancelledTags.isSuperset(of: created) })
        #expect(await harness.transport.activeTags().isEmpty)
    }

    // F3: at launch, transfers for a deleted asset or an older generation are cancelled; the
    // current ones are left alone.
    @Test func launchCancelsStaleTransfersOnly() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = try await harness.startSimpleDownload()
        try #require(requests.count == 4)
        let current = Set(requests.map(\.tag))
        let old = OfflineTransferTag(assetID: asset.id, generation: requests[0].tag.generation - 1, unit: 0)
        let orphan = OfflineTransferTag(assetID: UUID().uuidString, generation: 0, unit: 0)
        await harness.transport.setActive(current.union([old, orphan]))

        let relaunched = harness.relaunched(network: Fixture.simpleNetwork())
        await relaunched.manager.start()

        #expect(await relaunched.transport.cancelledTags == [old, orphan])
        #expect(await relaunched.transport.activeTags() == current)
    }

    // F4: the system cancelled a current transfer (a force quit); the relaunch sends it again, so
    // the cancellation must not send it a second time.
    @Test func aCancelledCurrentTransferIsNotRetried() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = try await harness.startSimpleDownload()
        try #require(requests.count == 4)
        await harness.transport.clearSubmitted()

        await harness.transport.fail(requests[0].tag, OfflineTransferFailure(.cancelled))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await harness.transport.submitted.isEmpty)
        #expect(await harness.manager.asset(asset.id)?.state == .downloading)
    }

    // F4: a late failure for a unit already sent again is not retried on top of it.
    @Test func aFailureForAUnitAlreadyInFlightIsNotRetried() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (_, requests) = try await harness.startSimpleDownload()
        try #require(requests.count == 4)
        await harness.transport.clearSubmitted()

        // The tag is still in flight (sent again by a relaunch) when the old failure arrives.
        await harness.manager.handle(requests[0].tag, .failed(OfflineTransferFailure(.network("late"))))

        #expect(await harness.transport.submitted.isEmpty)
    }

    // F10: credentialed units go through a window of six; each one done lets the next one in.
    @Test func credentialedUnitsAreSentThroughAWindow() async throws {
        var network = Fixture.simpleNetwork()
        network.responses[Self.base.absoluteString + "1080/index.m3u8"] = .text(Fixture.media(10))
        let harness = OfflineHarness(network: network)
        await harness.manager.start()
        guard case .created(let asset) = await harness.manager.enqueue(
            identity: Fixture.identity(), title: Fixture.title(), target: Fixture.target(headers: ["Cookie": "sid=1"]),
            choice: OfflineDownloadChoice(mode: .smart), estimate: .unknown, autoDeleteAfterWatching: false,
            allowsCellular: false) else { Issue.record("not created"); return }
        let first = await harness.waitForSubmissions(OfflineDownloadManager.credentialedWindow, assetID: asset.id)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await harness.transport.submitted.count == OfflineDownloadManager.credentialedWindow)
        #expect(first.allSatisfy { $0.credentialed })

        await harness.transport.finish(first[0].tag, body: Fixture.segment())
        #expect(await harness.waitForSubmissions(OfflineDownloadManager.credentialedWindow + 1).count
                == OfflineDownloadManager.credentialedWindow + 1)
    }

    // F10: a connection problem is retried more often than a failed request.
    @Test func connectivityFailuresHaveTheirOwnBudget() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = try await harness.startSimpleDownload()
        try #require(requests.count == 4)
        for _ in 0...OfflineDownloadManager.transferRetries {
            await harness.transport.fail(requests[0].tag, OfflineTransferFailure(.connectivity("NSURLError -1005")))
            #expect(await waitUntil { await harness.transport.activeTags().contains(requests[0].tag) })
        }
        #expect(await harness.manager.asset(asset.id)?.state == .downloading)

        for _ in 0...OfflineDownloadManager.transferRetries {
            await harness.transport.fail(requests[1].tag, OfflineTransferFailure(.network("NSURLError -1011")))
        }
        #expect(await harness.waitFor(asset.id, .failed)?.state == .failed)
    }

    // F11: a body the session delivered but the app never handled is taken up at the next launch,
    // not downloaded again.
    @Test func aStagedBodyIsTakenUpAtLaunch() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = try await harness.startSimpleDownload()
        try #require(requests.count == 4)
        try FileManager.default.createDirectory(at: harness.layout.stagingDirectory, withIntermediateDirectories: true)
        try Fixture.segment().write(to: harness.layout.stagingDirectory
            .appendingPathComponent(OfflineStagedBody.name(tag: requests[0].tag, status: 200)))
        // The app ended: the session holds nothing any more.
        await harness.transport.setActive([])
        await harness.transport.clearSubmitted()

        let relaunched = harness.relaunched(network: Fixture.simpleNetwork())
        await relaunched.manager.start()

        let resent = await relaunched.waitForSubmissions(3, assetID: asset.id)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(Set(await relaunched.transport.submitted.map(\.tag.unit)) == Set(resent.map(\.tag.unit)))
        #expect(!resent.contains { $0.tag.unit == requests[0].tag.unit })
        #expect(await relaunched.manager.asset(asset.id)?.progress.completedUnits == 1)
    }

    // F11: the transport is given a settle step, which returns once nothing is preparing.
    @Test func theTransportWaitsForPreparingToSettle() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        await harness.manager.start()
        let settle = try #require(await harness.transport.settle)
        await settle()
    }

    // F14: a single file checks the space as it arrives, against the rest of it once its size is known.
    @Test func aSingleFileStopsWhenTheRestNoLongerFits() async throws {
        let file = URL(string: "https://cdn.example.com/movie.mp4")!
        let harness = OfflineHarness(network: FakeNetwork([file.absoluteString: .init(data: Data(repeating: 0, count: 1024), status: 206)]),
                                     capacity: 1_000_000_000)
        await harness.manager.start()
        guard case .created(let asset) = await harness.manager.enqueue(
            identity: Fixture.identity("movie"), title: Fixture.title(), target: Fixture.target(file),
            choice: OfflineDownloadChoice(mode: .smart), estimate: .unknown, autoDeleteAfterWatching: false,
            allowsCellular: false) else { Issue.record("not created"); return }
        let first = await harness.waitForSubmissions(1)
        try #require(first.count == 1)
        #expect(await harness.manager.asset(asset.id)?.estimate == .unknown)

        // The server now says it is 2 GB: the 1 GB free cannot hold the rest.
        await harness.manager.handle(first[0].tag, .progress(written: 10_000_000, expected: 2_000_000_000))

        let failed = try #require(await harness.waitFor(asset.id, .failed))
        #expect(failed.failure?.kind == .insufficientStorage)
    }

    // F18: deleting gives up the saved resume data, so the system removes its partial file; an HLS
    // pause asks for no resume data at all.
    @Test func deletingGivesUpResumeDataAndSegmentsMakeNone() async throws {
        let file = URL(string: "https://cdn.example.com/movie.mp4")!
        let harness = OfflineHarness(network: FakeNetwork([file.absoluteString: .init(data: Data(repeating: 0, count: 1024), status: 206,
                                                                                      headers: ["content-range": "bytes 0-1023/50000000"])]))
        await harness.manager.start()
        guard case .created(let movie) = await harness.manager.enqueue(
            identity: Fixture.identity("movie"), title: Fixture.title(), target: Fixture.target(file),
            choice: OfflineDownloadChoice(mode: .smart), estimate: .unknown, autoDeleteAfterWatching: false,
            allowsCellular: false) else { Issue.record("not created"); return }
        _ = await harness.waitForSubmissions(1)
        await harness.transport.setResumeData(Data("partial".utf8), for: movie.id)
        await harness.manager.pause(movie.id)
        #expect(await harness.transport.resumeDataRequested.last == true)

        await harness.manager.delete([movie.id])
        #expect(await harness.transport.discarded == [Data("partial".utf8)])

        let hls = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, _) = try await hls.startSimpleDownload()
        await hls.manager.pause(asset.id)
        #expect(await hls.transport.resumeDataRequested.last == false)
    }

    // F19: resume data that a resumed transfer could not use, and that brought no new resume data,
    // is dropped: the next attempt starts over instead of failing the same way for ever.
    @Test func resumeDataThatFailedIsNotSentAgain() async throws {
        let file = URL(string: "https://cdn.example.com/movie.mp4")!
        let harness = OfflineHarness(network: FakeNetwork([file.absoluteString: .init(data: Data(repeating: 0, count: 1024), status: 206,
                                                                                      headers: ["content-range": "bytes 0-1023/50000000"])]))
        await harness.manager.start()
        guard case .created = await harness.manager.enqueue(
            identity: Fixture.identity("movie"), title: Fixture.title(), target: Fixture.target(file),
            choice: OfflineDownloadChoice(mode: .smart), estimate: .unknown, autoDeleteAfterWatching: false,
            allowsCellular: false) else { Issue.record("not created"); return }
        let first = await harness.waitForSubmissions(1)
        try #require(first.count == 1)
        await harness.transport.clearSubmitted()
        await harness.transport.fail(first[0].tag, OfflineTransferFailure(.network("lost"), resumeData: Data("resume".utf8)))
        let resumed = await harness.waitForSubmissions(1)
        #expect(resumed.first?.resumeData == Data("resume".utf8))

        // The resumed transfer fails and brings no new resume data.
        await harness.transport.clearSubmitted()
        await harness.transport.fail(first[0].tag, OfflineTransferFailure(.network("cannot resume")))
        let restarted = await harness.waitForSubmissions(1)
        #expect(restarted.first?.resumeData == nil)
    }

    // F30: the 下載 tab's total counts what downloads have received so far, also after a pause.
    @Test func usageCountsWhatUnfinishedDownloadsHold() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = try await harness.startSimpleDownload()
        try #require(requests.count == 4)
        await harness.transport.finish(requests[0].tag, body: Fixture.segment(1880))
        #expect(await harness.manager.snapshot().usageBytes == 1880)
        await harness.manager.pause(asset.id)
        #expect(await harness.manager.snapshot().usageBytes == 1880)
    }

    // F34: leftovers of an interrupted write one folder down go at launch too.
    @Test func launchRemovesInterruptedWritesInSubfolders() throws {
        let folder = OfflineHarness.scratchLayout().root.appendingPathComponent("asset")
        for sub in ["playlists", "partial"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent(sub).appendingPathComponent(".index.m3u8.tmp-1234"))
        }
        try Data("keep".utf8).write(to: folder.appendingPathComponent("playlists/index.m3u8"))
        #expect(OfflineStorage.removeStaleTemporaries(in: folder) == 2)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("playlists/index.m3u8").path))
    }

    // F39: deleted while its subtitle was on its way: saving the subtitle must not leave a folder
    // with no record behind.
    @Test func deletingWhilePreparingLeavesNoFolder() async throws {
        let gate = Gate()
        let subtitleURL = "https://subs.example.com/zh.srt"
        let harness = OfflineHarness(network: Fixture.simpleNetwork(),
                                     subtitleFiles: [subtitleURL: "1\n00:00:01,000 --> 00:00:02,000\n你好\n"], subtitleGate: gate)
        await harness.manager.start()
        guard case .created(let asset) = await harness.manager.enqueue(
            identity: Fixture.identity(), title: Fixture.title(),
            target: Fixture.target(subtitles: [SourceSubtitle(url: subtitleURL, name: "繁中", language: "zh-TW")]),
            choice: OfflineDownloadChoice(mode: .smart, subtitleIDs: ["sidecar|0"]), estimate: .unknown,
            autoDeleteAfterWatching: false, allowsCellular: false) else { Issue.record("not created"); return }
        #expect(await harness.waitFor(asset.id, .preparing)?.state == .preparing)
        try? await Task.sleep(for: .milliseconds(20))

        await harness.manager.delete([asset.id])
        await gate.open()

        #expect(await waitUntil { !harness.folderExists(asset.id) })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!harness.folderExists(asset.id))
        #expect(await harness.transport.submitted.isEmpty)
    }

    // MARK: Batch 4 — what counts as watched, and the auto-delete switch

    // F1: the scrubber's right edge, +10 s near the end, the lock screen: the end of file that
    // follows is a skip. Seeking back and playing to the end is a watch again.
    @Test func aSeekToTheEndIsNotAWatch() {
        var policy = OfflineCompletionPolicy()
        _ = policy.opened("a")
        policy.viewerSeeked(to: 2_400, duration: 2_400)
        #expect(policy.ended(.endOfFile, position: 2_400, duration: 2_400).isEmpty)

        policy.viewerSeeked(to: 600, duration: 2_400)
        #expect(policy.ended(.endOfFile, position: 2_400, duration: 2_400) == [.markWatched("a")])

        // A new episode starts clean.
        _ = policy.opened("b")
        #expect(!policy.seekedToEnd)
    }

    // F1: the viewer's ending reached for the next episode stays a real end, as the requirement allows.
    @Test func theFormalAutoNextCountsEvenAfterASeekIntoTheCredits() {
        var policy = OfflineCompletionPolicy()
        _ = policy.opened("a")
        policy.viewerSeeked(to: 2_399, duration: 2_400)
        #expect(policy.ended(.formalAutoNext, position: 2_300, duration: 2_400) == [.markWatched("a")])
    }

    // F12: an end of file well before the duration is the engine giving up on segments it could
    // not read, not the end of the episode.
    @Test func anEndOfFileShortOfTheDurationIsNotAWatch() {
        var policy = OfflineCompletionPolicy()
        _ = policy.opened("a")
        #expect(policy.ended(.endOfFile, position: 1_200, duration: 2_400).isEmpty)
        #expect(policy.ended(.endOfFile, position: 2_398, duration: 2_400) == [.markWatched("a")])
    }

    // F23: only the engine's end and the viewer's ending are ends; a stop, an error, anything else
    // the session reports is not.
    @Test func onlyTheEngineEndAndTheViewersEndingAreEnds() {
        #expect(OfflineCompletionPolicy.endReason(finishedBy: "end") == .endOfFile)
        #expect(OfflineCompletionPolicy.endReason(finishedBy: "ending") == .formalAutoNext)
        for other in ["stop", "error", "fallback", "replay", ""] {
            #expect(OfflineCompletionPolicy.endReason(finishedBy: other) == nil)
        }
    }

    // F13: turned off in 設定, nothing is auto-deleted — not an episode set to be when it was
    // downloaded, not one already armed, not one a crash left armed.
    @Test func theSettingTurnedOffStopsEveryAutoDelete() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, _) = try await harness.startSimpleDownload(autoDelete: true)
        #expect(await harness.completeAll(asset.id)?.state == .completed)
        await harness.manager.playbackEnded(asset.id)
        #expect(await harness.manager.asset(asset.id)?.pendingAutoDelete == true)

        await harness.manager.setAutoDeleteEnabled(false)
        #expect(await harness.manager.asset(asset.id)?.pendingAutoDelete == false)
        #expect(await harness.manager.playbackReleased(asset.id) == false)
        await harness.manager.playbackEnded(asset.id)
        #expect(await harness.manager.asset(asset.id)?.pendingAutoDelete == false)
        #expect(await harness.manager.asset(asset.id)?.watched == true)
        #expect(harness.folderExists(asset.id))
    }

    @Test func aCrashArmedAutoDeleteWaitsForTheSettingAtLaunch() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, _) = try await harness.startSimpleDownload(autoDelete: true)
        #expect(await harness.completeAll(asset.id)?.state == .completed)
        await harness.manager.playbackEnded(asset.id)

        let relaunched = harness.relaunched(network: Fixture.simpleNetwork())
        await relaunched.manager.setAutoDeleteEnabled(false)
        await relaunched.manager.start()

        #expect(relaunched.folderExists(asset.id))
        #expect(await relaunched.manager.asset(asset.id)?.pendingAutoDelete == false)
    }

    // MARK: Batch 5 — security and the sheet

    // F22: a sidecar subtitle sent with the source's Cookie and Authorization (same origin as the
    // stream) is redirected elsewhere. URLSession copies the fields onto the redirect; they must
    // reach only the stream's own origin, as every other offline request's do.
    @Test func offlineSubtitleRedirectsKeepTheSourceCredentialsOnItsOrigin() throws {
        var original = URLRequest(url: URL(string: "https://cdn.a.com/sub/1.srt")!)
        let sent = ["Cookie": "auth=1", "Authorization": "Bearer t", "User-Agent": "UA", "Referer": "https://site.example/",
                    "Accept": "text/plain"]
        for (name, value) in sent { original.setValue(value, forHTTPHeaderField: name) }
        let session = OfflineHTTP.subtitleSession
        let policy = try #require(session.delegate as? OfflineHTTP.SubtitleRedirectPolicy)
        let task = session.dataTask(with: original)
        defer { task.cancel() }
        func redirect(to address: String) throws -> URLRequest {
            var carried = original
            carried.url = URL(string: address)
            let response = try #require(HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: nil,
                                                        headerFields: ["Location": address]))
            var answer: URLRequest?
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: carried) { answer = $0 }
            return try #require(answer)
        }

        let elsewhere = try redirect(to: "https://storage.other.net/x.srt")
        #expect(elsewhere.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(elsewhere.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(elsewhere.value(forHTTPHeaderField: "User-Agent") == "UA")
        #expect(elsewhere.value(forHTTPHeaderField: "Referer") == "https://site.example/")
        #expect(elsewhere.value(forHTTPHeaderField: "Accept") == "text/plain")

        let sameOrigin = try redirect(to: "https://cdn.a.com/sub/2.srt")
        #expect(sameOrigin.value(forHTTPHeaderField: "Cookie") == "auth=1")
        #expect(sameOrigin.value(forHTTPHeaderField: "Authorization") == "Bearer t")

        let downgraded = try redirect(to: "http://cdn.a.com/sub/1.srt")
        #expect(downgraded.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(downgraded.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // F21: 全部下載 in 最省空間 on a stream whose versions are all above 720p still downloads (the
    // sheet's fallback), but the record says the mode that supplied the version, not 最省空間.
    @Test func downloadAllInSaverModeWithoutA720pVersionRecordsTheModeItUsed() async throws {
        let base = "https://cdn.example.com/show/ep1/"
        let harness = OfflineHarness(network: FakeNetwork([
            Fixture.master.absoluteString: .text(Fixture.masterText([
                Fixture.variant(1920, 1080, bandwidth: 4_000_000, average: 2_500_000, uri: "1080/index.m3u8"),
            ])),
            base + "1080/index.m3u8": .text(Fixture.media(4)),
        ]))
        let options = try await harness.manager.options(for: Fixture.target())
        #expect(options.option(for: .saver) == nil)
        #expect(options.option(for: .smart) != nil)
        await harness.manager.setResolver { _ in Fixture.target() }
        await harness.manager.start()

        let result = await harness.manager.enqueueAutomatic(
            identity: Fixture.identity(), title: Fixture.title(), mode: .saver, allowHighFrameRate: false,
            preferredSubtitleLanguage: nil, autoDeleteAfterWatching: true, allowsCellular: false)
        guard case .created(let queued) = result else {
            Issue.record("not queued: \(result)")
            return
        }
        let downloading = try #require(await harness.waitFor(queued.id, .downloading))

        #expect(downloading.state == .downloading)
        #expect(downloading.video?.height == 1080)
        #expect(downloading.mode == .smart)
        #expect(OfflineAssetStore(layout: harness.layout).request(for: queued.id)?.choice.mode == .smart)
    }

    // F32: a launch prepares queued downloads before the app has loaded its configuration (iOS
    // may relaunch it in the background for a finished transfer, with no screen to load it). A
    // retry that must resolve its episode waits queued instead of failing as unresolvable; one
    // that already has its addresses is not held back.
    @Test func aDownloadThatMustResolveWaitsQueuedUntilTheConfigurationIsLoaded() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let loaded = Gate()
        let resolved = Resolutions()
        await harness.manager.setResolver({ asset in
            resolved.append(asset.identity.episodeURL)
            return Fixture.target()
        }, ready: { await loaded.isOpen })
        await harness.manager.start()

        let automatic = await harness.manager.enqueueAutomatic(
            identity: Fixture.identity("ep2"), title: Fixture.title("ep2"), mode: .smart, allowHighFrameRate: false,
            preferredSubtitleLanguage: nil, autoDeleteAfterWatching: true, allowsCellular: false)
        guard case .created(let waiting) = automatic else {
            Issue.record("not queued: \(automatic)")
            return
        }
        let (plain, _) = try await harness.startSimpleDownload(identity: Fixture.identity("ep1"))
        #expect(await harness.waitFor(plain.id, .downloading)?.state == .downloading)

        #expect(await harness.manager.asset(waiting.id)?.state == .queued)
        #expect(resolved.all.isEmpty)

        await loaded.open()
        await harness.manager.resolverBecameReady()
        #expect(await harness.waitFor(waiting.id, .downloading)?.state == .downloading)
        #expect(resolved.all == [Fixture.identity("ep2").episodeURL])
    }

    // F35: a single file or a media playlist with no master is one version of unknown size; a
    // master offers versions to pick from by resolution.
    @Test func aLoneUndeclaredVersionIsToldApartFromAPickedOne() async throws {
        let progressive = OfflineOptionsBuilder.progressive(size: 1_000, sidecars: [], preferredSubtitleLanguage: nil)
        #expect(progressive.singleUndeclaredVersion)

        let media = URL(string: "https://cdn.example.com/show/ep1/index.m3u8")!
        let bare = OfflineHarness(network: FakeNetwork([media.absoluteString: .text(Fixture.media(4))]))
        #expect(try await bare.manager.options(for: Fixture.target(media)).singleUndeclaredVersion)

        let master = OfflineHarness(network: Fixture.simpleNetwork())
        #expect(try await master.manager.options(for: Fixture.target()).singleUndeclaredVersion == false)

        // Undeclared too, but more than one: 最省空間 and 智慧 1080p pick different ones by bitrate.
        let base = "https://cdn.example.com/show/ep1/"
        let undeclared = OfflineHarness(network: FakeNetwork([
            Fixture.master.absoluteString: .text(Fixture.masterText([
                Fixture.variant(nil, nil, bandwidth: 800_000, uri: "low/index.m3u8"),
                Fixture.variant(nil, nil, bandwidth: 3_000_000, uri: "high/index.m3u8"),
            ])),
            base + "low/index.m3u8": .text(Fixture.media(4)),
            base + "high/index.m3u8": .text(Fixture.media(4)),
        ]))
        let picked = try await undeclared.manager.options(for: Fixture.target())
        #expect(picked.option(for: .saver)?.resolutionUnknown == true)
        #expect(picked.singleUndeclaredVersion == false)
        #expect(OfflineOptionsBuilder.refused(OfflineFailure(.drmProtected), compatibility: .avPlayerOnly)
            .singleUndeclaredVersion == false)
    }

    // MARK: Batch 6 — tests that can fail (F25, F38)

    // F25: a crash in the middle of a delete leaves a `.deleting` record. The library hides those,
    // so if launch did not finish the delete the folder would take space for ever, out of sight.
    @Test func launchFinishesADeleteACrashInterrupted() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, _) = try await harness.startSimpleDownload()
        #expect(await harness.completeAll(asset.id)?.state == .completed)
        let crashed = OfflineAssetStore(layout: harness.layout)
        _ = crashed.load()
        try #require(crashed.update(asset.id) { $0.state = .deleting } != nil)

        let relaunched = harness.relaunched(network: Fixture.simpleNetwork())
        #expect(relaunched.folderExists(asset.id))
        await relaunched.manager.start()

        #expect(!relaunched.folderExists(asset.id))
        #expect(await relaunched.manager.asset(asset.id) == nil)
    }

    // F25: every unit reported finished, but one file is gone by the time the last lands. The
    // verifier is what keeps that from being marked completed.
    @Test func aPackageMissingAFileWhenTheLastUnitLandsFailsVerification() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = try await harness.startSimpleDownload()
        await harness.transport.finish(requests[0].tag, body: Fixture.segment())
        #expect(await waitUntil { await harness.manager.asset(asset.id)?.progress.completedUnits == 1 })
        let folder = harness.layout.folder(for: asset.id)
        let landed = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "ts" }
        try #require(landed.count == 1)
        try FileManager.default.removeItem(at: landed[0])

        for request in requests.dropFirst() { await harness.transport.finish(request.tag, body: Fixture.segment()) }
        let failed = try #require(await harness.waitFor(asset.id, .failed))
        #expect(failed.failure?.kind == .integrity)
    }

    // F25: queued with no estimate, the enqueue check only asks for the reserve. Preparing measures
    // the package; one that does not fit must fail before a single transfer starts.
    @Test func aDownloadQueuedWithoutAnEstimateIsRefusedWhenItsPackageDoesNotFit() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork(), capacity: OfflineStorage.reserveBytes + 1_000_000)
        await harness.manager.start()
        let result = await harness.manager.enqueue(identity: Fixture.identity(), title: Fixture.title(), target: Fixture.target(),
                                                   choice: OfflineDownloadChoice(mode: .smart), estimate: .unknown,
                                                   autoDeleteAfterWatching: true, allowsCellular: false)
        guard case .created(let asset) = result else {
            Issue.record("not queued: \(result)")
            return
        }
        let failed = try #require(await harness.waitFor(asset.id, .failed))
        #expect(failed.failure?.kind == .insufficientStorage)
        #expect(await harness.transport.submitted.isEmpty)
    }

    // F38: mobile data is the viewer's to allow. Off unless set, and what a download was queued
    // with reaches every transfer and the request iOS is handed.
    @Test func cellularIsOffUntilAllowedAndReachesEveryTransfer() async throws {
        let suite = "offline-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = OfflineDownloadPreferences(defaults: defaults)
        #expect(preferences.allowsCellular == false)
        preferences.allowsCellular = true
        #expect(OfflineDownloadPreferences(defaults: defaults).allowsCellular)

        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (_, requests) = try await harness.startSimpleDownload()
        #expect(requests.allSatisfy { !$0.allowsCellular && !$0.urlRequest.allowsCellularAccess })

        let allowed = OfflineHarness(network: Fixture.simpleNetwork())
        await allowed.manager.start()
        let result = await allowed.manager.enqueue(identity: Fixture.identity(), title: Fixture.title(), target: Fixture.target(),
                                                   choice: OfflineDownloadChoice(mode: .smart),
                                                   estimate: OfflineSizeEstimate(bytes: 1_000_000, basis: .averageBandwidth),
                                                   autoDeleteAfterWatching: true, allowsCellular: true)
        guard case .created(let asset) = result else {
            Issue.record("not queued: \(result)")
            return
        }
        let sent = await allowed.waitForSubmissions(4, assetID: asset.id)
        #expect(sent.count == 4 && sent.allSatisfy { $0.allowsCellular && $0.urlRequest.allowsCellularAccess })
    }

    // F38: 刪除記錄 deletes a title's downloads through this list, so it must hold every one that
    // takes space — queued, downloading, paused, failed, not only completed — and no other title's.
    @MainActor @Test func aTitlesDownloadsIncludeEveryStateButDeleting() {
        let key = Fixture.identity().historyKey
        var assets = OfflineAssetState.allCases.enumerated().map { index, state in
            var asset = OfflineAsset(identity: OfflineIdentity(historyKey: key, flag: "線路①", episodeURL: "https://source.example.com/\(index)"),
                                     title: Fixture.title("第\(index)集", index: OfflineAssetState.allCases.count - index),
                                     mode: .smart, autoDeleteAfterWatching: true, allowsCellular: false)
            asset.state = state
            return asset
        }
        assets.append(OfflineAsset(identity: OfflineIdentity(historyKey: "other", flag: "線路①", episodeURL: "https://source.example.com/x"),
                                   title: Fixture.title(), mode: .smart, autoDeleteAfterWatching: true, allowsCellular: false))
        let library = OfflineLibrary()
        library.apply(OfflineSnapshot(assets: assets, sequence: 1))

        let listed = library.assets(forHistoryKey: key)
        #expect(Set(listed.map(\.state)) == Set(OfflineAssetState.allCases.filter { $0 != .deleting }))
        #expect(listed.map(\.title.episodeIndex) == listed.map(\.title.episodeIndex).sorted())
    }

    // F35 (IOS-POC-52-12): a lone version's probed video is shown on every mode and recorded, and its
    // size never refuses it — the user's rule: there is no other version, so this one is downloaded.
    @Test func aLoneFileShowsAndRecordsItsProbedVideo() async throws {
        let file = URL(string: "https://cdn.example.com/movie.mp4")!
        let wide = OfflineVideoInfo(width: 2560, height: 1440, codec: .h264, dynamicRange: .sdr)
        let asked = Asked()
        let harness = OfflineHarness(
            network: FakeNetwork([file.absoluteString: .init(data: Data(repeating: 0, count: 1024), status: 206)]),
            videoProbe: { url, headers in asked.add(url, headers); return wide })
        await harness.manager.start()
        let target = Fixture.target(file, headers: ["Referer": "https://site.example/"])
        let options = try await harness.manager.options(for: target)
        #expect(options.refusal == nil, "above 1080p, and still offered")
        #expect(options.singleUndeclaredVersion)
        #expect(OfflineQualityMode.allCases.allSatisfy { options.option(for: $0)?.video == wide })
        #expect(asked.first?.0 == file)
        #expect(asked.first?.1["Referer"] == "https://site.example/")

        guard case .created(let asset) = await harness.manager.enqueue(
            identity: Fixture.identity("movie"), title: Fixture.title(), target: target,
            choice: OfflineDownloadChoice(mode: .smart), estimate: .unknown, autoDeleteAfterWatching: false,
            allowsCellular: false) else { Issue.record("not created"); return }
        _ = await harness.waitForSubmissions(1)
        #expect(await harness.manager.asset(asset.id)?.video == wide, "the record says what was downloaded")
    }

    @Test func aMediaPlaylistIsProbedThroughItsInitSectionOnly() async throws {
        let playlist = URL(string: "https://cdn.example.com/show/v.m3u8")!
        let hevc = OfflineVideoInfo(width: 1280, height: 720, codec: .hevc, dynamicRange: .sdr)
        let section = Data("init-section".utf8)
        let harness = OfflineHarness(network: FakeNetwork([
            playlist.absoluteString: .text(Fixture.media(2, ext: "m4s", extra: [#"#EXT-X-MAP:URI="init.mp4""#])),
            "https://cdn.example.com/show/init.mp4": .init(data: section)
        ]), videoProbe: { url, _ in url.isFileURL && (try? Data(contentsOf: url)) == section ? hevc : nil })
        await harness.manager.start()
        let options = try await harness.manager.options(for: Fixture.target(playlist))
        #expect(OfflineQualityMode.allCases.allSatisfy { options.option(for: $0)?.video == hevc })
        guard case .created(let asset) = await harness.manager.enqueue(
            identity: Fixture.identity("hls"), title: Fixture.title(), target: Fixture.target(playlist),
            choice: OfflineDownloadChoice(mode: .smart), estimate: .unknown, autoDeleteAfterWatching: false,
            allowsCellular: false) else { Issue.record("not created"); return }
        _ = await harness.waitForSubmissions(1)
        #expect(await harness.manager.asset(asset.id)?.video == hevc)

        // MPEG-TS has no init section: nothing is probed, and nothing changes.
        let ts = OfflineHarness(network: FakeNetwork([playlist.absoluteString: .text(Fixture.media(2))]),
                                videoProbe: { _, _ in Issue.record("a TS playlist was probed"); return hevc })
        await ts.manager.start()
        let unknown = try await ts.manager.options(for: Fixture.target(playlist))
        #expect(unknown.singleUndeclaredVersion)
        #expect(unknown.option(for: .smart)?.video != hevc)
    }

    // F12 (IOS-POC-52-11): only the loopback server's port can change; anything else is not moved.
    @Test func aSourceIsRebasedOnlyWhenItsServerMovedPort() {
        func source(_ address: String) -> OfflinePlaybackSource {
            OfflinePlaybackSource(assetID: "a", url: URL(string: address)!, compatibility: .bothEngines, sidecars: [],
                                  folder: URL(fileURLWithPath: "/tmp/a"), label: "離線 1080p")
        }
        let served = source("http://127.0.0.1:50000/tok/a/playlists/index.m3u8")
        let moved = served.rebased(to: URL(string: "http://127.0.0.1:50001/tok/")!)
        #expect(moved?.url.absoluteString == "http://127.0.0.1:50001/tok/a/playlists/index.m3u8")
        #expect(moved?.assetID == "a")
        #expect(moved?.label == served.label)
        #expect(served.rebased(to: URL(string: "http://127.0.0.1:50000/tok/")!) == nil, "the address still holds")
        #expect(served.rebased(to: URL(string: "http://127.0.0.1:50001/other/")!) == nil, "another server's token")
        #expect(source("file:///tmp/a/media/video.mp4").rebased(to: URL(string: "http://127.0.0.1:50001/tok/")!) == nil)
    }

    // F11 (IOS-POC-52-9): the wake's background task ends exactly once, whichever path comes first.
    @Test func aWakeTaskEndsOnceWhicheverWayItFinishes() {
        // Settling done, then iOS's expiry, then settling again.
        let settled = Ends()
        var expire: (@Sendable () -> Void)?
        let first = OfflineWakeTask.begin { onExpiry in expire = onExpiry; return settled.end }
        first.finish()
        expire?()
        first.finish()
        #expect(settled.count == 1)

        // iOS's expiry first; settling afterwards changes nothing.
        let expired = Ends()
        let second = OfflineWakeTask.begin { onExpiry in expire = onExpiry; return expired.end }
        expire?()
        #expect(expired.count == 1)
        second.finish()
        #expect(expired.count == 1)

        // Expired before `begin` had kept the end: it still runs, once.
        let early = Ends()
        let third = OfflineWakeTask.begin { onExpiry in onExpiry(); return early.end }
        #expect(early.count == 1, "ended as soon as begin had it, not left for a later finish")
        third.finish()
        #expect(early.count == 1)

        // No task (`.invalid`): nothing to end, and nothing breaks.
        OfflineWakeTask.begin { _ in nil }.finish()
    }
}

/// What the video probe was asked.
private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = [(URL, [String: String])]()
    func add(_ url: URL, _ headers: [String: String]) { lock.withLock { calls.append((url, headers)) } }
    var first: (URL, [String: String])? { lock.withLock { calls.first } }
}

/// Counts the ends of one wake task.
private final class Ends: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    var end: @Sendable () -> Void { { self.lock.withLock { self.calls += 1 } } }
}
