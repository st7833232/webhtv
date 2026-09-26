import Foundation

public enum WebHomeBridgeError: Error, Equatable, LocalizedError {
    case unknownMethod(String)
    case invalidPayload
    case unknownSite(String)

    /// Android rejects with `e.getMessage()`; these are the equivalent strings.
    public var errorDescription: String? {
        switch self {
        case .unknownMethod(let method): "Unknown method: \(method)"
        case .invalidPayload: "invalid payload"
        case .unknownSite(let key): "Unknown site: \(key)"
        }
    }
}

/// Native half of the WebHome string-RPC contract. The JS half is `WebHomeBridge.sdkScript`, ported
/// from `HomeWebController.getSdk()`; existing pages only ever touch `window.fm` / `window.fongmi`,
/// so the script text is the real compatibility surface and is kept as close to Android as possible.
public struct WebHomeBridge: Sendable {
    /// What the page can be told about its window. Android reports Android system insets too; those
    /// have no iOS equivalent and are reported as zero rather than omitted, so a page reading them
    /// finds a number instead of `undefined`.
    public struct Viewport: Sendable {
        public var width: Double
        public var height: Double
        public var safeTop: Double
        public var safeRight: Double
        public var safeBottom: Double
        public var safeLeft: Double

        public init(width: Double, height: Double, safeTop: Double, safeRight: Double, safeBottom: Double, safeLeft: Double) {
            self.width = width
            self.height = height
            self.safeTop = safeTop
            self.safeRight = safeRight
            self.safeBottom = safeBottom
            self.safeLeft = safeLeft
        }
    }

    /// What the page is told about playback. Mirrors `server/process/Media.java`'s `/media` object
    /// field for field; Android reads the same values off its own player on demand.
    public struct PlaybackStatus: Sendable {
        /// Android's codes: 3 playing, 6 buffering, 2 ready, 1 otherwise.
        public var state: Int
        public var speed: Double
        public var duration: Double
        public var position: Double
        public var url: String
        public var title: String
        public var artist: String
        public var artwork: String
        /// Nothing has been played yet, which Android reports as a bare `{}`.
        public var idle: Bool

        public init(
            state: Int, speed: Double, duration: Double, position: Double,
            url: String, title: String, artist: String = "", artwork: String = "", idle: Bool = false
        ) {
            self.state = state
            self.speed = speed
            self.duration = duration
            self.position = position
            self.url = url
            self.title = title
            self.artist = artist
            self.artwork = artwork
            self.idle = idle
        }

        public static let idleStatus = PlaybackStatus(
            state: 1, speed: 0, duration: 0, position: 0, url: "", title: "", idle: true
        )
    }

    /// One episode of an inline vod. `url` is nil when the page asked for lazy resolution, in which
    /// case `resolvePayload` is the episode JSON to hand back to the page's own resolver.
    /// No media format is carried: AVPlayer infers it, so storing Android's `format` would be dead weight.
    public struct PlaybackItem: Sendable, Equatable {
        public var name: String
        public var url: URL?
        public var resolvePayload: String?

        public init(name: String, url: URL?, resolvePayload: String? = nil) {
            self.name = name
            self.url = url
            self.resolvePayload = resolvePayload
        }
    }

    /// A vod the page supplied in full, rather than one the app fetches from a site.
    public struct InlineVod: Sendable {
        public var id: String
        public var title: String
        public var picture: String
        public var items: [PlaybackItem]
        public var startIndex: Int

        public init(id: String, title: String, picture: String, items: [PlaybackItem], startIndex: Int) {
            self.id = id
            self.title = title
            self.picture = picture
            self.items = items
            self.startIndex = startIndex
        }
    }

    /// Side effects the host owns. Kept as closures so the bridge itself stays testable without UI.
    /// They touch view state, so they are main-actor bound and awaited from the dispatch below.
    public struct Actions: Sendable {
        public var play: @MainActor @Sendable (URL, String) -> Void
        /// Opens the app's own vod screen for a configured site, as Android's `VideoActivity.start` does.
        public var playVod: @MainActor @Sendable (Site, Vod) -> Void
        public var playInline: @MainActor @Sendable (InlineVod) -> Void
        public var control: @MainActor @Sendable (String) -> Void
        public var status: @MainActor @Sendable () -> PlaybackStatus
        public var search: @MainActor @Sendable (String) -> Void
        public var toast: @MainActor @Sendable (String) -> Void
        public var setToolbar: @MainActor @Sendable (Bool) -> Void
        public var back: @MainActor @Sendable () -> Void
        public var reload: @MainActor @Sendable () -> Void
        public var viewport: @MainActor @Sendable () -> Viewport

        public init(
            play: @escaping @MainActor @Sendable (URL, String) -> Void,
            playVod: @escaping @MainActor @Sendable (Site, Vod) -> Void,
            playInline: @escaping @MainActor @Sendable (InlineVod) -> Void,
            control: @escaping @MainActor @Sendable (String) -> Void,
            status: @escaping @MainActor @Sendable () -> PlaybackStatus,
            search: @escaping @MainActor @Sendable (String) -> Void,
            toast: @escaping @MainActor @Sendable (String) -> Void,
            setToolbar: @escaping @MainActor @Sendable (Bool) -> Void,
            back: @escaping @MainActor @Sendable () -> Void,
            reload: @escaping @MainActor @Sendable () -> Void,
            viewport: @escaping @MainActor @Sendable () -> Viewport
        ) {
            self.play = play
            self.playVod = playVod
            self.playInline = playInline
            self.control = control
            self.status = status
            self.search = search
            self.toast = toast
            self.setToolbar = setToolbar
            self.back = back
            self.reload = reload
            self.viewport = viewport
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
    private let site: Site?
    /// `player.playVod` names a site by key, so the bridge needs the configured list to resolve it.
    private let sites: [Site]
    private let source: ConfigSource
    /// Device facts are handed in because `UIDevice` is UIKit and this module also builds for macOS.
    private let device: [String: String]
    private nonisolated(unsafe) let defaults: UserDefaults
    /// What `app.history` answers from. Injected so a test can drive its own file rather than the
    /// one the app is using.
    private let history: WatchHistoryStore

    public init(
        actions: Actions,
        site: Site? = nil,
        sites: [Site] = [],
        source: ConfigSource = .importedFile,
        device: [String: String] = [:],
        defaults: UserDefaults = .standard,
        history: WatchHistoryStore = .shared
    ) {
        self.actions = actions
        self.site = site
        self.sites = sites
        self.source = source
        self.device = device
        self.defaults = defaults
        self.history = history
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
        case "player.playVod":
            let key = Self.string(payload, "siteKey")
            // Android hands the key to VideoActivity and fails inside it. Rejecting here tells the
            // page what went wrong, which matters because a page may not know which config is loaded.
            guard let site = sites.first(where: { $0.key == key }) else { throw WebHomeBridgeError.unknownSite(key) }
            let vodId = Self.string(payload, "vodId")
            guard !vodId.isEmpty else { throw WebHomeBridgeError.invalidPayload }
            await actions.playVod(site, Vod(
                id: vodId,
                name: Self.title(payload, fallback: vodId),
                picture: Self.picture(payload)
            ))
            return "{}"
        case "player.playVodInline":
            let vod = Self.inlineVod(payload)
            guard !vod.items.isEmpty else { throw WebHomeBridgeError.invalidPayload }
            await actions.playInline(vod)
            // The only playback method with a non-empty result; the page uses it to address the vod later.
            return Self.text(from: ["siteKey": Self.inlineSiteKey, "vodId": vod.id]) ?? "{}"
        case "player.control":
            // Android returns {} even when no playback service exists, so an unknown action is not an error.
            await actions.control(Self.string(payload, "action"))
            return "{}"
        case "player.status":
            // Android fetches this from its own local server, so the page parses a net.request
            // envelope rather than the media object. The envelope is reproduced; the HTTP hop is not.
            return Self.statusText(await actions.status())
        case "app.search":
            let keyword = Self.string(payload, "keyword")
            guard !keyword.isEmpty else { throw WebHomeBridgeError.invalidPayload }
            await actions.search(keyword)
            return "{}"
        case "app.history":
            // IOS-POC-30: this configuration's list, as the history screen shows it — Android's
            // `HomeWebBridge.history()` is `History.get()`, the current configuration's only.
            return Self.historyText(await history.records(for: source.identity))
        case "cache.get":
            return Self.jsonText(defaults.string(forKey: Self.cacheKey(payload)) ?? "")
        case "cache.set":
            defaults.set(Self.string(payload, "value"), forKey: Self.cacheKey(payload))
            return "{}"
        case "cache.del":
            defaults.removeObject(forKey: Self.cacheKey(payload))
            return "{}"
        case "ui.getViewport":
            return Self.viewportText(await actions.viewport())
        case "ui.setToolbar":
            // Android treats a missing `visible` as true.
            await actions.setToolbar((payload["visible"] as? Bool) ?? true)
            return "{}"
        case "navigation.back":
            await actions.back()
            return "{}"
        case "navigation.reload":
            await actions.reload()
            return "{}"
        case "site.info":
            // Android also reports homePage, chromeMode, webHomeChrome and header; the iOS Site
            // model carries none of them, so they are absent rather than invented.
            return Self.text(from: ["key": site?.key ?? "", "name": site?.name ?? "", "type": site?.type ?? 0]) ?? "{}"
        case "config.info":
            // `id` and `desc` have no iOS equivalent; drive check is an Android-only feature.
            return Self.text(from: [
                "id": "", "desc": "",
                "url": source.baseURL?.absoluteString ?? "",
                "driveCheck": false,
            ]) ?? "{}"
        case "ext.info":
            // There is no extension registry on iOS yet, so the counts are honestly zero.
            return Self.text(from: [
                "siteKey": site?.key ?? "", "siteName": site?.name ?? "", "homePage": "",
                "enabled": false, "matched": 0, "ready": 0,
            ]) ?? "{}"
        case "ext.log":
            print("[webhome-ext] \(Self.string(payload, "message")) \(payload["data"].map { String(describing: $0) } ?? "")")
            return "{}"
        case "ext.toast":
            let message = Self.string(payload, "message")
            if !message.isEmpty { await actions.toast(message) }
            return "{}"
        case "device.info":
            // Android proxies this to its local server's /device. No such server exists here, so the
            // payload is built natively and its fields are iOS facts, not an Android-identical shape.
            return Self.text(from: device) ?? "{}"
        default:
            throw WebHomeBridgeError.unknownMethod(method)
        }
    }

    /// `WebHomeViewport.json`. The Android-only inset fields are kept at zero so the payload shape
    /// matches and a page never reads `undefined` from one of them.
    static func viewportText(_ viewport: Viewport) -> String {
        text(from: [
            "width": viewport.width, "height": viewport.height,
            "safeTop": viewport.safeTop, "safeRight": viewport.safeRight,
            "safeBottom": viewport.safeBottom, "safeLeft": viewport.safeLeft,
            "safeBottomMax": viewport.safeBottom,
            "gestureLeft": 0, "gestureRight": 0, "gestureBottom": 0,
            "statusBarHeight": viewport.safeTop, "navigationBarHeight": 0, "keyboardBottom": 0,
            "chromeMode": "", "systemBarsHidden": false,
        ]) ?? "{}"
    }

    /// `HomeWebBridge.history()`, which is `gson.toJson(History.get())` — a plain array of
    /// `History` objects, already filtered to the last 60 days.
    ///
    /// Every field Android declares is present, because a page written against Android indexes them
    /// directly. The ones iOS has nothing to put in follow this bridge's existing rule and carry
    /// zero, empty or false rather than being omitted:
    ///
    /// - `wallPic`, `revSort`, `revPlay` — no equivalent concept here;
    /// - `opening` / `ending` carry what the viewer set on the player since IOS-POC-5S-2. These are
    ///   Android's own fields being filled in rather than new ones being invented; unset stays `0`,
    ///   because Android's `C.TIME_UNSET` is a large negative that reads the same to any `> 0` test
    ///   a page makes, and its own reset button writes `0`;
    /// - `speed` and `scale` carry Android's own defaults, 1 and -1;
    /// - `cid` is 0 because an iOS configuration has no id, exactly as `config.info` reports.
    ///
    /// `WatchHistory.quality` is deliberately **not** here: it has no Android counterpart, and this
    /// payload is a reproduction rather than an extension.
    static func historyText(_ records: [WatchHistory]) -> String {
        let items: [[String: Any]] = records.map { record in
            [
                "key": record.androidKey,
                "vodPic": record.vodPic,
                "wallPic": "",
                "vodName": record.vodName,
                "vodFlag": record.vodFlag,
                "vodRemarks": record.vodRemarks,
                "episodeUrl": record.episodeUrl,
                "revSort": false,
                "revPlay": false,
                "createTime": record.createTime,
                "opening": record.openingOffset,
                "ending": record.endingOffset,
                "position": record.position,
                "duration": record.duration,
                "speed": 1,
                "scale": -1,
                "cid": 0,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// `WebHomeInlineVodStore.KEY`: the pseudo-site an inline vod is addressed under.
    static let inlineSiteKey = "webhome_inline"

    /// The `player.status` reply. `ok`/`status` describe a call that never left the device, and `url`
    /// is empty where Android reports its local server address. `body` is `/media` field for field.
    static func statusText(_ status: PlaybackStatus) -> String {
        let body: Any = status.idle ? [String: Any]() : [
            "state": status.state,
            "speed": status.speed,
            "duration": status.duration,
            "position": status.position,
            "url": status.url,
            "title": status.title,
            "artist": status.artist,
            "artwork": status.artwork,
        ]
        return text(from: [
            "ok": true, "status": 200, "url": "",
            "headers": [String: String](), "cookies": [String](),
            "body": body,
        ]) ?? errorText("encode failed")
    }

    /// `HomeWebBridge.playVodInline` plus its `title`/`pic` fallbacks.
    static func inlineVod(_ payload: [String: Any]) -> InlineVod {
        let episodes = (payload["episodes"] as? [[String: Any]]) ?? []
        let items = episodes.enumerated().map { index, episode -> PlaybackItem in
            let name = string(episode, "name").isEmpty ? String(format: "%02d", index + 1) : string(episode, "name")
            let url = playableURL(episode)
            return PlaybackItem(
                name: name,
                url: url,
                // The page resolves this one itself, so keep its own JSON to hand straight back.
                resolvePayload: url == nil ? text(from: episode) : nil
            )
        }
        let mark = string(payload, "mark")
        let id = string(payload, "vod_id").isEmpty
            ? "inline_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            : string(payload, "vod_id")
        return InlineVod(
            id: id,
            title: title(payload, fallback: id),
            picture: picture(payload),
            items: items,
            startIndex: items.firstIndex { $0.name == mark } ?? 0
        )
    }

    /// Android: `title`, then `vod_name`.
    static func title(_ payload: [String: Any], fallback: String) -> String {
        for key in ["title", "vod_name"] where !string(payload, key).isEmpty { return string(payload, key) }
        return fallback
    }

    /// Android: `pic`, then `vod_pic`.
    static func picture(_ payload: [String: Any]) -> String {
        for key in ["pic", "vod_pic"] where !string(payload, key).isEmpty { return string(payload, key) }
        return ""
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
