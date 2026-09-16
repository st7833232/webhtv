import Foundation
import Testing
@testable import WebHTVCore

private let noopActions = WebHomeBridge.Actions(
    play: { _, _ in }, search: { _ in }, toast: { _ in }, setToolbar: { _ in },
    back: {}, reload: {},
    viewport: { .init(width: 402, height: 720, safeTop: 59, safeRight: 0, safeBottom: 34, safeLeft: 0) }
)

private func bridge(defaults: UserDefaults) -> WebHomeBridge {
    WebHomeBridge(actions: noopActions, defaults: defaults)
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

@Test func reportsAnEmptyHistoryAndRejectsUnsupportedMethods() async throws {
    let defaults = try scratchDefaults("misc")
    let subject = bridge(defaults: defaults)

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

@Test func routesTheSideEffectingUiMethodsToTheHost() async throws {
    let defaults = try scratchDefaults("ui")
    actor Calls {
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
        play: { _, _ in }, search: { _ in },
        toast: { m in Task { await calls.toast(m) } },
        setToolbar: { v in Task { await calls.toolbar(v) } },
        back: { Task { await calls.back() } },
        reload: { Task { await calls.reload() } },
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
    #expect(await calls.toasts == ["hi"])
    #expect(await calls.toolbar == [true, false])
    #expect(await calls.backs == 1)
    #expect(await calls.reloads == 1)
}

@Test func stillRejectsTheMethodsThisSliceLeftOut() async throws {
    let defaults = try scratchDefaults("unsupported")
    let subject = bridge(defaults: defaults)
    for method in ["pan.check", "player.control", "player.status", "net.resourceUrl", "ui.setChrome", "app.openLive"] {
        await #expect(throws: WebHomeBridgeError.unknownMethod(method)) {
            try await subject.handle(method: method, payload: [:])
        }
    }
}
