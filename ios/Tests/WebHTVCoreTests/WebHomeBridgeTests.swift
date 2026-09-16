import Foundation
import Testing
@testable import WebHTVCore

private func bridge(defaults: UserDefaults) -> WebHomeBridge {
    WebHomeBridge(actions: .init(play: { _, _ in }, search: { _ in }), defaults: defaults)
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
    await #expect(throws: WebHomeBridgeError.unknownMethod("ui.getViewport")) {
        try await subject.handle(method: "ui.getViewport", payload: [:])
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
