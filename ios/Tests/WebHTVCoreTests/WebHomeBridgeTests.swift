import Foundation
import Testing
@testable import WebHTVCore

private let noopActions = WebHomeBridge.Actions(
    play: { _, _ in }, playVod: { _, _ in }, playInline: { _ in },
    control: { _ in }, status: { .idleStatus },
    search: { _ in }, toast: { _ in }, setToolbar: { _ in },
    back: {}, reload: {},
    viewport: { .init(width: 402, height: 720, safeTop: 59, safeRight: 0, safeBottom: 34, safeLeft: 0) }
)

/// `Site` only decodes, so the fixture is the JSON a real config carries rather than a memberwise
/// init added to production code for a test's benefit.
private let testSite = try! JSONDecoder().decode(Site.self, from: Data(#"""
{"key":"vod_360","name":"360","type":1,"api":"https://example.com/api.php/provide/vod"}
"""#.utf8))

private func bridge(defaults: UserDefaults, history: WatchHistoryStore = WatchHistoryStore(
    directory: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("webhome-history-\(UUID().uuidString)", isDirectory: true)
)) -> WebHomeBridge {
    WebHomeBridge(actions: noopActions, defaults: defaults, history: history)
}

private func decode(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func scratchDefaults(_ name: String) throws -> UserDefaults {
    let defaults = try #require(UserDefaults(suiteName: "webhome.test.\(name)"))
    defaults.removePersistentDomain(forName: "webhome.test.\(name)")
    return defaults
}

@Test func buildsTheSameCacheKeyAsTheAndroidBridge() {
    // HomeWebBridge.cacheKey: "cache_" + optional rule + key.
    #expect(WebHomeBridge.cacheKey(["key": "token"]) == "cache_token")
    #expect(WebHomeBridge.cacheKey(["key": "token", "rule": "ymvid"]) == "cache_ymvid_token")
    #expect(WebHomeBridge.cacheKey([:]) == "cache_")
}

@Test func storesAndClearsCacheEntriesThroughTheContract() async throws {
    let defaults = try scratchDefaults("cache")
    let subject = bridge(defaults: defaults)

    #expect(try await subject.handle(method: "cache.get", payload: ["key": "k"]) == #""""#)
    #expect(try await subject.handle(method: "cache.set", payload: ["key": "k", "value": "v"]) == "{}")
    // cache.get returns a JSON string literal, not a bare value.
    #expect(try await subject.handle(method: "cache.get", payload: ["key": "k"]) == #""v""#)
    #expect(try await subject.handle(method: "cache.del", payload: ["key": "k"]) == "{}")
    #expect(try await subject.handle(method: "cache.get", payload: ["key": "k"]) == #""""#)
}

/// IOS-POC-5R: `app.history` answers the real store. It returned a hard-coded `[]` until now, which
/// is a behaviour change rather than a relaxed assertion — the field shape is asserted in
/// `WatchHistoryTests`.
@Test func appHistoryReportsWhatWasActuallyWatched() async throws {
    let defaults = try scratchDefaults("history")
    let store = WatchHistoryStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("webhome-history-\(UUID().uuidString)", isDirectory: true))
    await store.save(WatchHistory(key: "site\u{0}{}@@@9", siteKey: "site", vodId: "9",
                                  vodName: "蓮花樓", vodFlag: "線路①", vodRemarks: "01",
                                  episodeUrl: "https://a/9.m3u8", position: 42_000, duration: 2_400_000))
    let subject = bridge(defaults: defaults, history: store)

    let text = try await subject.handle(method: "app.history", payload: [:])
    let items = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    #expect(items.count == 1)
    #expect(items.first?["key"] as? String == "site@@@9")
    #expect(items.first?["vodName"] as? String == "蓮花樓")
    #expect(items.first?["position"] as? Double == 42_000)
}

@Test func reportsAnEmptyHistoryAndRejectsUnsupportedMethods() async throws {
    let defaults = try scratchDefaults("misc")
    let subject = bridge(defaults: defaults)

    // Still `[]` — but now because nothing has been watched, not because the method is a stub.
    #expect(try await subject.handle(method: "app.history", payload: [:]) == "[]")
    // ui.getViewport became supported in IOS-POC-2D; pan.check is still outside every slice.
    await #expect(throws: WebHomeBridgeError.unknownMethod("pan.check")) {
        try await subject.handle(method: "pan.check", payload: [:])
    }
    await #expect(throws: WebHomeBridgeError.invalidPayload) {
        try await subject.handle(method: "player.playUrl", payload: ["url": "notaurl"])
    }
    await #expect(throws: WebHomeBridgeError.invalidPayload) {
        try await subject.handle(method: "app.search", payload: [:])
    }
}

@Test func encodesTheNetRequestShapeWebHomePagesParse() throws {
    let url = try #require(URL(string: "https://example.com/api"))
    let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
    let body = Data(#"{"a":1}"#.utf8)

    func decode(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    let plain = try decode(WebHomeBridge.successText(data: body, response: response, requested: url, responseType: ""))
    #expect(plain["ok"] as? Bool == true)
    #expect(plain["status"] as? Int == 200)
    #expect(plain["url"] as? String == "https://example.com/api")
    #expect(plain["body"] as? String == #"{"a":1}"#)
    #expect((plain["headers"] as? [String: String])?["Content-Type"] == "application/json")

    // responseType only changes `body`.
    let asJSON = try decode(WebHomeBridge.successText(data: body, response: response, requested: url, responseType: "json"))
    #expect((asJSON["body"] as? [String: Any])?["a"] as? Int == 1)
    let asBase64 = try decode(WebHomeBridge.successText(data: body, response: response, requested: url, responseType: "base64"))
    #expect(asBase64["body"] as? String == body.base64EncodedString())

    let failure = try decode(WebHomeBridge.errorText("boom"))
    #expect(failure["ok"] as? Bool == false)
    #expect(failure["status"] as? Int == 500)
    #expect(failure["error"] as? String == "boom")
}

@Test func decodesTheInvokeTripleAndRejectsMalformedMessages() {
    let call = WebHomeBridge.decodeMessage(["id": "fm_1", "method": "net.request", "payload": #"{"url":"https://example.com"}"#])
    #expect(call?.id == "fm_1")
    #expect(call?.method == "net.request")
    #expect(WebHomeBridge.string(call?.payload ?? [:], "url") == "https://example.com")

    // A payload that is not an object degrades to empty rather than failing the call.
    #expect(WebHomeBridge.decodeMessage(["id": "fm_2", "method": "app.history", "payload": "[]"])?.payload.isEmpty == true)
    #expect(WebHomeBridge.decodeMessage(["method": "net.request"]) == nil)
    #expect(WebHomeBridge.decodeMessage("not a message") == nil)
}

@Test func repliesWithTheScriptsTheInjectedSdkListensFor() {
    #expect(WebHomeBridge.resolveScript(id: "fm_1", json: "{}")
        == #"window.fongmiNative&&window.fongmiNative.resolve("fm_1",{})"#)
    #expect(WebHomeBridge.resolveScript(id: "fm_1", json: "")
        == #"window.fongmiNative&&window.fongmiNative.resolve("fm_1",null)"#)
    #expect(WebHomeBridge.rejectScript(id: "fm_1", message: "Unknown method: ui.getViewport")
        == #"window.fongmiNative&&window.fongmiNative.reject("fm_1","Unknown method: ui.getViewport")"#)
}

@Test func injectsTheSameSdkSurfaceExistingPagesExpect() {
    let sdk = WebHomeBridge.sdkScript
    for symbol in ["window.fongmiNative", "window.fongmi=", "window.fm=", "fmsdk"] {
        #expect(sdk.contains(symbol), "missing \(symbol)")
    }
    // invoke must cross via postMessage, not the Android synchronous interface.
    #expect(sdk.contains("window.webkit.messageHandlers.fongmiBridge.postMessage"))
    #expect(!sdk.contains("fongmiBridge.invoke"))
    // iOS never chunks, so the synchronous result accessors must not appear.
    #expect(!sdk.contains("resultChunk"))
    #expect(!sdk.contains("resultLength"))
}


@Test func reportsTheViewportWithEveryFieldAndroidSends() async throws {
    let defaults = try scratchDefaults("viewport")
    let payload = try await decode(try bridge(defaults: defaults).handle(method: "ui.getViewport", payload: [:]))

    #expect(payload["width"] as? Double == 402)
    #expect(payload["height"] as? Double == 720)
    #expect(payload["safeTop"] as? Double == 59)
    #expect(payload["safeBottom"] as? Double == 34)
    // Android system-inset concepts with no iOS equivalent are zero, not missing, so a page reading
    // one of them never gets `undefined`.
    for key in ["gestureLeft", "gestureRight", "gestureBottom", "navigationBarHeight", "keyboardBottom"] {
        #expect(payload[key] as? Double == 0, "\(key) should be present and zero")
    }
    #expect(payload["systemBarsHidden"] as? Bool == false)
    #expect(payload["chromeMode"] as? String == "")
}

@Test func reportsSiteConfigAndExtensionState() async throws {
    let defaults = try scratchDefaults("info")
    let site = try JSONDecoder().decode(
        Site.self,
        from: Data(#"{"key":"vod_360","name":"360","type":1,"api":"https://example.com/api","ext":null}"#.utf8)
    )
    let url = try #require(URL(string: "https://example.com/a/wang-movie.json?ref_type=heads"))
    let subject = WebHomeBridge(actions: noopActions, site: site, source: .remote(url), device: ["model": "iPhone"], defaults: defaults)

    let info = try await decode(try subject.handle(method: "site.info", payload: [:]))
    #expect(info["key"] as? String == "vod_360")
    #expect(info["type"] as? Int == 1)

    let config = try await decode(try subject.handle(method: "config.info", payload: [:]))
    #expect(config["url"] as? String == url.absoluteString)
    #expect(config["driveCheck"] as? Bool == false)

    let ext = try await decode(try subject.handle(method: "ext.info", payload: [:]))
    #expect(ext["siteKey"] as? String == "vod_360")
    #expect(ext["enabled"] as? Bool == false)
    #expect(ext["matched"] as? Int == 0)

    #expect(try await decode(try subject.handle(method: "device.info", payload: [:]))["model"] as? String == "iPhone")
}

@MainActor @Test func routesTheSideEffectingUiMethodsToTheHost() async throws {
    let defaults = try scratchDefaults("ui")
    // @MainActor, not an actor: every Actions closure is already `@MainActor @Sendable` and
    // `handle` awaits it, so recording synchronously makes the write finish before `handle`
    // returns. Bridging to an actor through `Task { }` instead made the read race the write —
    // these tests passed only while the suite was fast enough to hide it.
    @MainActor final class Calls {
        var toasts = [String]()
        var toolbar = [Bool]()
        var backs = 0
        var reloads = 0
        func toast(_ m: String) { toasts.append(m) }
        func toolbar(_ v: Bool) { toolbar.append(v) }
        func back() { backs += 1 }
        func reload() { reloads += 1 }
    }
    let calls = Calls()
    let actions = WebHomeBridge.Actions(
        play: { _, _ in }, playVod: { _, _ in }, playInline: { _ in },
        control: { _ in }, status: { .idleStatus },
        search: { _ in },
        toast: { m in calls.toast(m) },
        setToolbar: { v in calls.toolbar(v) },
        back: { calls.back() },
        reload: { calls.reload() },
        viewport: { .init(width: 0, height: 0, safeTop: 0, safeRight: 0, safeBottom: 0, safeLeft: 0) }
    )
    let subject = WebHomeBridge(actions: actions, defaults: defaults)

    #expect(try await subject.handle(method: "ext.toast", payload: ["message": "hi"]) == "{}")
    // Android treats a missing `visible` as true.
    #expect(try await subject.handle(method: "ui.setToolbar", payload: [:]) == "{}")
    #expect(try await subject.handle(method: "ui.setToolbar", payload: ["visible": false]) == "{}")
    #expect(try await subject.handle(method: "navigation.back", payload: [:]) == "{}")
    #expect(try await subject.handle(method: "navigation.reload", payload: [:]) == "{}")
    #expect(try await subject.handle(method: "ext.log", payload: ["message": "x"]) == "{}")

    try await Task.sleep(for: .milliseconds(120))
    #expect(calls.toasts == ["hi"])
    #expect(calls.toolbar == [true, false])
    #expect(calls.backs == 1)
    #expect(calls.reloads == 1)
}

@Test func stillRejectsTheMethodsThisSliceLeftOut() async throws {
    let defaults = try scratchDefaults("unsupported")
    let subject = bridge(defaults: defaults)
    // player.control and player.status became supported in IOS-POC-2E; preloadArtwork did not,
    // because AsyncImage has no preload hook and a no-op would claim success it never had.
    for method in ["pan.check", "player.preloadArtwork", "net.resourceUrl", "ui.setChrome", "app.openLive"] {
        await #expect(throws: WebHomeBridgeError.unknownMethod(method)) {
            try await subject.handle(method: method, payload: [:])
        }
    }
}

@MainActor @Test func opensAConfiguredSiteForPlayVodAndRejectsAnyOtherKey() async throws {
    let defaults = try scratchDefaults("playvod")
    @MainActor final class Opened {
        var calls = [(String, String, String, String)]()
        func add(_ site: Site, _ vod: Vod) { calls.append((site.key, vod.id, vod.name, vod.picture)) }
    }
    let opened = Opened()
    var actions = noopActions
    actions.playVod = { site, vod in opened.add(site, vod) }
    let subject = WebHomeBridge(actions: actions, sites: [testSite], defaults: defaults)

    #expect(try await subject.handle(
        method: "player.playVod",
        payload: ["siteKey": "vod_360", "vodId": "12345", "title": "蓮花樓", "pic": "https://example.com/p.jpg"]
    ) == "{}")

    try await Task.sleep(for: .milliseconds(120))
    let call = try #require(opened.calls.first)
    #expect(call == ("vod_360", "12345", "蓮花樓", "https://example.com/p.jpg"))

    // The showcase page ships an empty siteKey field, so this is the first path a page reaches.
    await #expect(throws: WebHomeBridgeError.unknownSite("")) {
        try await subject.handle(method: "player.playVod", payload: ["vodId": "1"])
    }
    await #expect(throws: WebHomeBridgeError.unknownSite("nope")) {
        try await subject.handle(method: "player.playVod", payload: ["siteKey": "nope", "vodId": "1"])
    }
    await #expect(throws: WebHomeBridgeError.invalidPayload) {
        try await subject.handle(method: "player.playVod", payload: ["siteKey": "vod_360"])
    }
}

@MainActor @Test func buildsAnInlinePlaylistAndAnswersWithTheStoreKey() async throws {
    let defaults = try scratchDefaults("inline")
    @MainActor final class Opened {
        var vods = [WebHomeBridge.InlineVod]()
        func add(_ vod: WebHomeBridge.InlineVod) { vods.append(vod) }
    }
    let opened = Opened()
    var actions = noopActions
    actions.playInline = { vod in opened.add(vod) }
    let subject = WebHomeBridge(actions: actions, defaults: defaults)

    // The shape the devkit showcase page's own vod-inline button sends.
    let reply = try await decode(try await subject.handle(method: "player.playVodInline", payload: [
        "vod_id": "webhome-sdk-showcase",
        "vod_name": "WebHome SDK Showcase",
        "vod_pic": "https://example.com/poster.jpg",
        "mark": "HLS",
        "episodes": [
            ["name": "MP4", "url": "https://example.com/a.mp4"],
            ["name": "HLS", "url": "https://example.com/b.m3u8"],
            ["name": "Resolver HLS", "pageUrl": "https://example.com/#resolver", "resolve": true],
        ],
    ]))

    #expect(reply["siteKey"] as? String == "webhome_inline")
    #expect(reply["vodId"] as? String == "webhome-sdk-showcase")

    try await Task.sleep(for: .milliseconds(120))
    let vod = try #require(opened.vods.first)
    // title falls back to vod_name and pic to vod_pic, as HomeWebBridge.playVodInline does.
    #expect(vod.title == "WebHome SDK Showcase")
    #expect(vod.picture == "https://example.com/poster.jpg")
    #expect(vod.items.count == 3)
    #expect(vod.items[0].url?.absoluteString == "https://example.com/a.mp4")
    // mark names the episode to start on.
    #expect(vod.startIndex == 1)
    // An episode with no URL keeps its own JSON, which is what the page's resolver is handed back.
    #expect(vod.items[2].url == nil)
    #expect(try #require(vod.items[2].resolvePayload).contains("#resolver"))

    await #expect(throws: WebHomeBridgeError.invalidPayload) {
        try await subject.handle(method: "player.playVodInline", payload: ["vod_name": "no episodes"])
    }
}

@MainActor @Test func forwardsEveryControlActionAndNeverFails() async throws {
    let defaults = try scratchDefaults("control")
    @MainActor final class Calls {
        var actions = [String]()
        func add(_ action: String) { actions.append(action) }
    }
    let calls = Calls()
    var actions = noopActions
    actions.control = { action in calls.add(action) }
    let subject = WebHomeBridge(actions: actions, defaults: defaults)

    for action in ["play", "pause", "stop", "prev", "next", "loop", "replay", "nonsense"] {
        #expect(try await subject.handle(method: "player.control", payload: ["action": action]) == "{}")
    }

    try await Task.sleep(for: .milliseconds(150))
    // Android returns {} even with no service, so an unknown action is forwarded, not rejected.
    #expect(calls.actions == ["play", "pause", "stop", "prev", "next", "loop", "replay", "nonsense"])
}

@Test func reportsPlaybackStatusInTheEnvelopePagesParse() async throws {
    let defaults = try scratchDefaults("status")
    var actions = noopActions
    actions.status = {
        .init(
            state: 3, speed: 1, duration: 125_000, position: 4_200,
            url: "https://example.com/b.m3u8", title: "WebHome SDK Showcase HLS",
            artwork: "https://example.com/poster.jpg"
        )
    }
    let subject = WebHomeBridge(actions: actions, defaults: defaults)

    // Android answers this through its local server, so the page parses a net.request envelope.
    let envelope = try await decode(try await subject.handle(method: "player.status", payload: [:]))
    #expect(envelope["ok"] as? Bool == true)
    #expect(envelope["status"] as? Int == 200)
    #expect(envelope["headers"] as? [String: String] == [:])
    #expect(envelope["cookies"] as? [String] == [])

    let body = try #require(envelope["body"] as? [String: Any])
    #expect(body["state"] as? Int == 3)
    #expect(body["speed"] as? Double == 1)
    #expect(body["duration"] as? Double == 125_000)
    #expect(body["position"] as? Double == 4_200)
    #expect(body["url"] as? String == "https://example.com/b.m3u8")
    #expect(body["title"] as? String == "WebHome SDK Showcase HLS")
    #expect(body["artwork"] as? String == "https://example.com/poster.jpg")
    // Present but empty: iOS has no metadata source for it.
    #expect(body["artist"] as? String == "")

    // Nothing played yet is a bare {}, which is what Android returns with no playback service.
    let idle = try await decode(try await bridge(defaults: defaults).handle(method: "player.status", payload: [:]))
    #expect((idle["body"] as? [String: Any])?.isEmpty == true)
}
