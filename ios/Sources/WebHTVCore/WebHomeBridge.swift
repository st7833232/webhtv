import Foundation

public enum WebHomeBridgeError: Error, Equatable, LocalizedError {
    case unknownMethod(String)
    case invalidPayload

    /// Android rejects with `e.getMessage()`; these are the equivalent strings.
    public var errorDescription: String? {
        switch self {
        case .unknownMethod(let method): "Unknown method: \(method)"
        case .invalidPayload: "invalid payload"
        }
    }
}

/// Native half of the WebHome string-RPC contract. The JS half is `WebHomeBridge.sdkScript`, ported
/// from `HomeWebController.getSdk()`; existing pages only ever touch `window.fm` / `window.fongmi`,
/// so the script text is the real compatibility surface and is kept as close to Android as possible.
public struct WebHomeBridge: Sendable {
    /// Side effects the host owns. Kept as closures so the bridge itself stays testable without UI.
    /// They touch view state, so they are main-actor bound and awaited from the dispatch below.
    public struct Actions: Sendable {
        public var play: @MainActor @Sendable (URL, String) -> Void
        public var search: @MainActor @Sendable (String) -> Void

        public init(play: @escaping @MainActor @Sendable (URL, String) -> Void, search: @escaping @MainActor @Sendable (String) -> Void) {
            self.play = play
            self.search = search
        }
    }

    public static let messageHandlerName = "fongmiBridge"

    /// Ported from `HomeWebController.getSdk()`. The wrapper surface is kept whole even for methods
    /// this stage does not implement, so a page sees the same API shape it sees on Android and an
    /// unsupported call rejects rather than finding `undefined`. Three things differ, by design:
    /// `invoke` posts a message instead of calling a synchronous Java interface, `hydrate` is a
    /// pass-through because iOS never chunks a result, and `net.resourceUrl` returns the raw URL
    /// because there is no local proxy server on this path.
    public static let sdkScript = #"""
    (function(){
      if(window.fm&&window.fongmi){window.dispatchEvent(new CustomEvent('fmsdk'));return;}
      if(document&&document.documentElement)document.documentElement.classList.add('fm-native');
      window.fongmiClient={mode:'mobile',isLeanback:false};
      const callbacks={};
      let seq=0;
      function invoke(method,payload){
        return new Promise((resolve,reject)=>{
          const id='fm_'+Date.now()+'_'+(++seq);
          callbacks[id]={resolve,reject};
          window.webkit.messageHandlers.fongmiBridge.postMessage({id:id,method:method,payload:JSON.stringify(payload||{})});
        });
      }
      function hydrate(data){return data;}
      window.fongmiNative={
        resolve:(id,data)=>{ if(callbacks[id]){ callbacks[id].resolve(hydrate(data)); delete callbacks[id]; } },
        reject:(id,error)=>{ if(callbacks[id]){ callbacks[id].reject(new Error(error||'')); delete callbacks[id]; } }
      };
      if(!window.__fmUrlHook&&window.history){
        window.__fmUrlHook=true;
        const emit=()=>window.dispatchEvent(new CustomEvent('fmurlchange',{detail:{url:location.href}}));
        const rawPush=history.pushState;
        const rawReplace=history.replaceState;
        history.pushState=function(){const r=rawPush.apply(this,arguments);emit();return r;};
        history.replaceState=function(){const r=rawReplace.apply(this,arguments);emit();return r;};
        window.addEventListener('popstate',emit);
      }
      const player={
        playUrl:(url,title,options)=>invoke('player.playUrl',Object.assign({},options||{},{url,title})),
        playVod:(siteKey,vodId,title,pic,options)=>invoke('player.playVod',Object.assign({},options||{},{siteKey,vodId,title,pic})),
        playVodInline:(payload)=>invoke('player.playVodInline',payload||{}),
        preloadArtwork:(pic,wallPic)=>invoke('player.preloadArtwork',{pic,wallPic}),
        control:(action)=>invoke('player.control',{action}),
        status:()=>invoke('player.status',{})
      };
      const net={
        request:(url,options)=>invoke('net.request',Object.assign({},options||{},{url})),
        resourceUrl:(url)=>url
      };
      const cache={
        get:(key,rule)=>invoke('cache.get',{key,rule}),
        set:(key,value,rule)=>invoke('cache.set',{key,value,rule}),
        del:(key,rule)=>invoke('cache.del',{key,rule})
      };
      const pan={
        check:(items)=>invoke('pan.check',{items}),
        play:(payload)=>invoke('pan.play',payload||{})
      };
      const ext={
        info:()=>invoke('ext.info',{}),
        log:(message,data)=>invoke('ext.log',{message,data}),
        toast:(message)=>invoke('ext.toast',{message})
      };
      const ui={
        setToolbar:(visible)=>invoke('ui.setToolbar',{visible:visible!==false}),
        setChrome:(options)=>invoke('ui.setChrome',options||{}),
        restoreChrome:()=>invoke('ui.restoreChrome',{}),
        getViewport:()=>invoke('ui.getViewport',{})
      };
      window.fongmi={invoke,player,net,cache,
        app:{
          search:(keyword,options)=>invoke('app.search',Object.assign({},options||{},{keyword})),
          openVod:()=>invoke('app.openVod',{}),
          openLive:()=>invoke('app.openLive',{}),
          openKeep:()=>invoke('app.openKeep',{}),
          openSetting:()=>invoke('app.openSetting',{}),
          history:()=>invoke('app.history',{})
        },
        pan,
        ext,
        device:{info:()=>invoke('device.info',{})},
        site:{info:()=>invoke('site.info',{})},
        config:{info:()=>invoke('config.info',{})},
        ui,
        navigation:{
          back:()=>invoke('navigation.back',{}),
          reload:()=>invoke('navigation.reload',{})
        }
      };
      window.fm={
        req:net.request,
        res:net.resourceUrl,
        play:player.playUrl,
        vod:player.playVod,
        vodInline:player.playVodInline,
        preloadArtwork:player.preloadArtwork,
        ctrl:player.control,
        stat:player.status,
        search:window.fongmi.app.search,
        openVod:window.fongmi.app.openVod,
        openLive:window.fongmi.app.openLive,
        openKeep:window.fongmi.app.openKeep,
        openSetting:window.fongmi.app.openSetting,
        history:window.fongmi.app.history,
        pan,
        check:window.fongmi.pan.check,
        cache,
        ext,
        ui,
        device:window.fongmi.device.info,
        site:window.fongmi.site.info,
        config:window.fongmi.config.info,
        back:window.fongmi.navigation.back,
        reload:window.fongmi.navigation.reload
      };
      window.dispatchEvent(new CustomEvent('fmsdk'));
    })();
    """#

    private let actions: Actions
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(actions: Actions, defaults: UserDefaults = .standard) {
        self.actions = actions
        self.defaults = defaults
    }

    /// Mirrors `HomeWebBridge.handle`: returns the JSON text handed to `fongmiNative.resolve`, or
    /// throws so the caller can reject. Methods outside this stage's subset take the same
    /// `Unknown method` path Android's `default` branch uses.
    public func handle(method: String, payload: [String: Any]) async throws -> String {
        switch method {
        case "net.request":
            return await Self.netRequest(payload)
        case "player.playUrl":
            guard let url = Self.playableURL(payload) else { throw WebHomeBridgeError.invalidPayload }
            let title = Self.string(payload, "title")
            await actions.play(url, title.isEmpty ? url.absoluteString : title)
            return "{}"
        case "app.search":
            let keyword = Self.string(payload, "keyword")
            guard !keyword.isEmpty else { throw WebHomeBridgeError.invalidPayload }
            await actions.search(keyword)
            return "{}"
        case "app.history":
            // ponytail: the iOS app has no watch-history store yet, so report an empty list rather
            // than pretending. Android returns History.get(), which is also empty on a fresh install.
            return "[]"
        case "cache.get":
            return Self.jsonText(defaults.string(forKey: Self.cacheKey(payload)) ?? "")
        case "cache.set":
            defaults.set(Self.string(payload, "value"), forKey: Self.cacheKey(payload))
            return "{}"
        case "cache.del":
            defaults.removeObject(forKey: Self.cacheKey(payload))
            return "{}"
        default:
            throw WebHomeBridgeError.unknownMethod(method)
        }
    }

    /// `HomeWebBridge.cacheKey`: "cache_" + optional rule + key.
    static func cacheKey(_ payload: [String: Any]) -> String {
        let rule = string(payload, "rule")
        return "cache_" + (rule.isEmpty ? "" : rule + "_") + string(payload, "key")
    }

    static func playableURL(_ payload: [String: Any]) -> URL? {
        guard let url = URL(string: string(payload, "url")), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// `WebCall.request`: the success and failure shapes here are what existing pages parse.
    static func netRequest(_ payload: [String: Any]) async -> String {
        let method = string(payload, "method").isEmpty ? "GET" : string(payload, "method").uppercased()
        guard let url = URL(string: string(payload, "url")) else { return errorText("invalid url") }
        let timeout = (payload["timeout"] as? Int).map { max($0, 1) } ?? 30
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(timeout))
        request.httpMethod = method
        for (name, value) in headerPairs(payload["headers"]) { request.setValue(value, forHTTPHeaderField: name) }
        if method != "GET", method != "HEAD" {
            request.httpBody = Data(string(payload, "body").utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
        }
        do {
            let (data, response) = try await URLSession.webHTV.data(for: request)
            return successText(data: data, response: response, requested: url, responseType: string(payload, "responseType"))
        } catch {
            return errorText(error.localizedDescription)
        }
    }

    static func successText(data: Data, response: URLResponse, requested: URL, responseType: String) -> String {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        // URLSession merges repeated headers into one comma-joined value, so unlike Android this
        // never produces an array. Cookies are reported the same way, as a single-entry list.
        var headers = [String: String]()
        for (name, value) in http?.allHeaderFields ?? [:] {
            headers[String(describing: name)] = String(describing: value)
        }
        var object: [String: Any] = [
            "ok": (200...299).contains(status),
            "status": status,
            "url": (http?.url ?? requested).absoluteString,
            "headers": headers,
            "cookies": headers["Set-Cookie"].map { [$0] } ?? [],
        ]
        switch responseType {
        case "base64":
            object["body"] = data.base64EncodedString()
        case "json":
            object["body"] = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
                ?? String(decoding: data, as: UTF8.self)
        default:
            object["body"] = String(decoding: data, as: UTF8.self)
        }
        return text(from: object) ?? errorText("encode failed")
    }

    static func errorText(_ message: String) -> String {
        text(from: ["ok": false, "status": 500, "body": "", "error": message, "headers": [String: String]()])
            ?? #"{"ok":false,"status":500,"body":"","error":"","headers":{}}"#
    }

    // MARK: - Replies

    /// `HomeWebBridge.resolve` / `reject`. iOS never chunks, so `__fmResultId` is never emitted and
    /// the SDK's hydrate() passes results straight through.
    public static func resolveScript(id: String, json: String) -> String {
        "window.fongmiNative&&window.fongmiNative.resolve(\(jsonText(id)),\(json.isEmpty ? "null" : json))"
    }

    public static func rejectScript(id: String, message: String) -> String {
        "window.fongmiNative&&window.fongmiNative.reject(\(jsonText(id)),\(jsonText(message)))"
    }

    /// Decodes one `postMessage` body into the `invoke(requestId, method, payload)` triple.
    public static func decodeMessage(_ body: Any) -> (id: String, method: String, payload: [String: Any])? {
        guard let message = body as? [String: Any] else { return nil }
        let id = string(message, "id")
        let method = string(message, "method")
        guard !id.isEmpty, !method.isEmpty else { return nil }
        let raw = string(message, "payload")
        let payload = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
        return (id, method, payload)
    }

    // MARK: - Helpers

    static func string(_ payload: [String: Any], _ key: String) -> String {
        if let value = payload[key] as? String { return value }
        if let value = payload[key] as? NSNumber { return value.stringValue }
        return ""
    }

    static func headerPairs(_ value: Any?) -> [(String, String)] {
        guard let object = value as? [String: Any] else { return [] }
        return object.map { ($0.key, String(describing: $0.value)) }
    }

    static func text(from object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Quotes a value as a JSON string literal, matching Android's `quote`.
    static func jsonText(_ value: String) -> String {
        text(from: value) ?? "\"\""
    }
}
