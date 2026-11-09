import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import WebHTVCore

/// W-268: downloads from the app's loopback spider proxy, whose address dies with each launch.
struct OfflineLocalProxyTests {
    static let site = "site\u{0}{}" // Fixture.identity's site
    static let old = URL(string: "http://127.0.0.1:50000/\(UUID().uuidString.lowercased())/proxy?do=py&url=ep%201")!

    static func base() -> URL { URL(string: "http://127.0.0.1:\(Int.random(in: 50001...60000))/\(UUID().uuidString.lowercased())/")! }

    static func network(_ base: URL) -> FakeNetwork {
        FakeNetwork([OfflineLocalProxy.rewrite(old, base: base, siteID: site).absoluteString:
            .init(data: Fixture.segment(1024), status: 206,
                  headers: ["content-range": "bytes 0-1023/5000", "content-type": "video/mp4"])])
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on: Bool
        init(_ on: Bool) { self.on = on }
        var value: Bool { lock.withLock { on } }
        func set(_ value: Bool) { lock.withLock { on = value } }
    }

    func enqueue(_ harness: OfflineHarness) async throws -> OfflineAsset {
        let result = await harness.manager.enqueue(identity: Fixture.identity(), title: Fixture.title(), target: Fixture.target(Self.old),
                                                   choice: OfflineDownloadChoice(mode: .smart),
                                                   estimate: OfflineSizeEstimate(bytes: 5000, basis: .exact),
                                                   autoDeleteAfterWatching: false, allowsCellular: false)
        guard case .created(let asset) = result else { throw HarnessFailure() }
        return asset
    }

    @Test func anAddressIsMovedToThisLaunchsProxyForItsSite() throws {
        let base = Self.base()
        let moved = OfflineLocalProxy.rewrite(Self.old, base: base, siteID: Self.site)
        #expect(moved.absoluteString == base.absoluteString + "proxy?do=py&url=ep%201&webhtv-download-site=site%00%7B%7D")
        // Android's own address, and one already moved, go the same way; the site is named once.
        let android = try #require(URL(string: "http://127.0.0.1:9978/proxy?do=py&url=ep%201"))
        #expect(OfflineLocalProxy.rewrite(android, base: base, siteID: Self.site) == moved)
        #expect(OfflineLocalProxy.rewrite(moved, base: base, siteID: Self.site) == moved)
        let cdn = try #require(URL(string: "https://cdn.example.com/a/proxy"))
        #expect(!OfflineLocalProxy.matches(cdn) && OfflineLocalProxy.rewrite(cdn, base: base, siteID: Self.site) == cdn)
        #expect(!OfflineLocalProxy.matches(try #require(URL(string: "http://127.0.0.1:8080/proxy"))))
        #expect(!OfflineLocalProxy.matches(try #require(URL(string: "http://127.0.0.1:8080/not-a-token/proxy"))))
        // The proxy sends nothing until the spider answers: the request outwaits the proxy's own limit.
        let request = OfflineTransferRequest(tag: OfflineTransferTag(assetID: "a", generation: 0, unit: 0), url: moved,
                                             headers: [:], byteRange: nil, allowsCellular: false, credentialed: true,
                                             origin: moved, resumeData: nil, reportsProgress: true)
        #expect(request.urlRequest.timeoutInterval > OfflineLocalProxy.callTimeout.timeInterval)
    }

    /// The W-264 hang: the unit's background transfer pointed at the previous launch's proxy, the session
    /// still listed it, so `reconnect` counted it in flight and sent nothing — 0% for good. It is
    /// cancelled at launch and sent again to this launch's proxy, once the configuration can make the
    /// site's spider; in the app, never in the background session.
    @Test func aRelaunchCancelsTheDeadProxysTransferAndSendsItAgain() async throws {
        let base1 = Self.base()
        let harness = OfflineHarness(network: Self.network(base1))
        await harness.manager.setLocalProxy { _ in base1 }
        await harness.manager.start()
        let asset = try await enqueue(harness)
        _ = try #require(await harness.waitFor(asset.id, .downloading))
        let first = try #require(await harness.waitForSubmissions(1, assetID: asset.id).first)
        #expect(first.url == OfflineLocalProxy.rewrite(Self.old, base: base1, siteID: Self.site))
        #expect(first.credentialed && first.resumeData == nil)

        let base2 = Self.base()
        let ready = Flag(false)
        let relaunched = harness.relaunched()
        await relaunched.manager.setResolver({ _ in nil }, ready: { ready.value })
        await relaunched.manager.setLocalProxy { _ in base2 }
        await harness.transport.clearSubmitted()
        await relaunched.manager.start()
        #expect(await harness.transport.cancelledTags.contains(first.tag))
        #expect(await harness.transport.activeTags().isEmpty)
        // No spider can be made before the configuration is loaded: it waits, it does not fail.
        #expect(await harness.transport.submitted.isEmpty)
        #expect(await relaunched.manager.asset(asset.id)?.state == .downloading)

        ready.set(true)
        await relaunched.manager.resolverBecameReady()
        let again = try #require(await relaunched.waitForSubmissions(1, assetID: asset.id).first)
        #expect(again.tag == first.tag)
        #expect(again.url == OfflineLocalProxy.rewrite(Self.old, base: base2, siteID: Self.site))
        #expect(again.credentialed)
        await harness.transport.finish(again.tag, body: Fixture.segment(5000))
        _ = try #require(await relaunched.waitFor(asset.id, .completed))
    }

    /// The control: a CDN transfer the background session still holds is left to run, not sent twice.
    @Test func aCDNTransferStillListedAtRelaunchIsLeftRunning() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = try await harness.startSimpleDownload()
        #expect(requests.allSatisfy { !$0.credentialed && !OfflineLocalProxy.matches($0.url) })
        let relaunched = harness.relaunched(network: Fixture.simpleNetwork())
        await harness.transport.clearSubmitted()
        await relaunched.manager.start()
        #expect(await harness.transport.cancelledTags.isEmpty)
        #expect(await harness.transport.submitted.isEmpty)
        #expect(await relaunched.manager.asset(asset.id)?.state == .downloading)
    }

    /// A second resend while the first is still sending sends nothing twice (the launch's reconnect and
    /// the configuration becoming ready can overlap).
    @Test func overlappingResendsSendEachUnitOnce() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, _) = try await harness.startSimpleDownload()
        await harness.transport.setActive([]) // the session lost them
        await harness.transport.clearSubmitted()
        let gate = Gate()
        await harness.transport.holdSubmits(gate)
        let first = Task { await harness.manager.resubmitRunning() }
        try await Task.sleep(for: .milliseconds(100)) // the first is held inside its submit
        let second = Task { await harness.manager.resubmitRunning() }
        try await Task.sleep(for: .milliseconds(100))
        await gate.open()
        await first.value
        await second.value
        let sent = await harness.transport.submitted.filter { $0.tag.assetID == asset.id }
        #expect(sent.count == 4)
        #expect(Set(sent.map(\.tag)).count == 4)
    }

    /// W-270: the download sheet, and 全部下載's own reading, ask the proxy as the download does (its site named,
    /// so the download limit); playback's requests keep the 20 s limit.
    @Test func theSheetAndDownloadAllReadTheProxyAsADownload() async throws {
        let base = Self.base()
        let played = try #require(URL(string: base.absoluteString + "proxy?do=py&url=ep%201"))
        let asDownload = OfflineLocalProxy.downloadTarget(Fixture.target(played), siteID: Self.site)
        #expect(asDownload.url == OfflineLocalProxy.rewrite(Self.old, base: base, siteID: Self.site))
        #expect(OfflineLocalProxy.downloadTarget(Fixture.target(), siteID: Self.site) == Fixture.target())

        let harness = OfflineHarness(network: Self.network(base))
        _ = try await harness.manager.options(for: asDownload)
        #expect(!harness.log.all.isEmpty && harness.log.all.allSatisfy { $0.url == asDownload.url })

        await harness.manager.setLocalProxy { _ in base }
        await harness.manager.setResolver { _ in Fixture.target(played) }
        await harness.manager.start()
        let result = await harness.manager.enqueueAutomatic(
            identity: Fixture.identity(), title: Fixture.title(), mode: .smart, allowHighFrameRate: false,
            preferredSubtitleLanguage: nil, autoDeleteAfterWatching: false, allowsCellular: false)
        guard case .created(let asset) = result else { throw HarnessFailure() }
        _ = try #require(await harness.waitFor(asset.id, .downloading))
        #expect(harness.log.all.allSatisfy { $0.url == asDownload.url })
        #expect(SpiderProxyServer().callTimeout == .seconds(20))
    }

    @Test func theSheetSaysALoopbackProxyDownloadNeedsTheAppOpen() {
        #expect(OfflineLocalProxy.backgroundNote(for: Self.old).contains("要開著 App"))
        #expect(OfflineLocalProxy.backgroundNote(for: Fixture.master).contains("iOS 會在允許時繼續下載"))
    }

    /// W-270: after a session reset the proxy answers a transfer for a site it let go with 503; the download
    /// retries it, asking for the site's spider again, instead of failing as a 404 would.
    @Test func aTransferTheProxyLetGoOfIsRetriedWithItsSpiderMadeAgain() async throws {
        let base = Self.base()
        let asked = Count()
        let harness = OfflineHarness(network: Self.network(base))
        await harness.manager.setLocalProxy { _ in asked.add(); return base }
        await harness.manager.start()
        let asset = try await enqueue(harness)
        let first = try #require(await harness.waitForSubmissions(1, assetID: asset.id).first)
        let before = asked.value
        await harness.transport.fail(first.tag, OfflineTransferFailure(.http(503)))
        let sent = await harness.waitForSubmissions(2, assetID: asset.id)
        #expect(sent.count == 2 && sent[1].url == first.url && sent[1].tag == first.tag)
        #expect(asked.value > before)
        #expect(await harness.manager.asset(asset.id)?.state == .downloading)
    }

    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.withLock { n } }
        func add() { lock.withLock { n += 1 } }
    }

    @Test func aSiteWhoseSpiderCannotBeMadeNeedsAttention() async throws {
        let harness = OfflineHarness(network: Self.network(Self.base()))
        await harness.manager.setLocalProxy { _ in nil }
        await harness.manager.start()
        let asset = try await enqueue(harness)
        let failed = try #require(await harness.waitFor(asset.id, .failed))
        #expect(failed.failure == OfflineDownloadManager.noLocalProxy)
        #expect(await harness.transport.submitted.isEmpty)
    }
}

private extension Duration {
    var timeInterval: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
