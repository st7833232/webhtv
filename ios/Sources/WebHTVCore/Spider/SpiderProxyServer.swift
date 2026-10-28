#if canImport(Network)
import Foundation
import Network
import os

/// W-202: Android's `127.0.0.1:9978/proxy?do=py`, served on iOS for the spider that asked for it.
///
/// A Python spider such as YouTube｜PY answers `playerContent` with that address and serves the stream
/// itself from `localProxy` — a DASH manifest whose BaseURLs point back at the same address. FongMi
/// runs the server on every interface with no check; this one listens on loopback only, on a port the
/// system picks, behind a per-launch token, and serves nothing but `localProxy` (design: docs/W-201).
/// The 9978 prefix is rewritten wherever it reaches the player: the play address and every text answer.
///
/// FFmpeg reads a DASH representation with a single BaseURL as one whole-file request, and a script
/// buffers what it fetches, so a large request is asked of the spider in `segment`-sized ranges and
/// streamed out as one response with the true length — which is also what lets the player seek.
public final class SpiderProxyServer: @unchecked Sendable {
    public static let shared = SpiderProxyServer()
    static let log = Logger(subsystem: "com.webhtv.ios.poc", category: "spider-proxy")
    /// The address FongMi serves `localProxy` on, which scripts write and `getProxyUrl` returns.
    public static let androidPrefix = "http://127.0.0.1:9978/proxy"
    /// W-202: googlevideo refuses a first audio request of 2 MB; 512 KB keeps each read short.
    static let segment: Int64 = 512 * 1024
    var callTimeout: Duration = .seconds(20)

    private let queue = DispatchQueue(label: "com.webhtv.ios.poc.spider-proxy")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: NWEndpoint.Port?
    private var waiting = [CheckedContinuation<URL?, Never>]()
    /// FongMi's "most recent Python spider": the one whose play address was rewritten last.
    private var session: (any SpiderProxying)?
    /// Sizes read from the `sidx` of files a spider serves with no total, by request without its Range.
    private var totals = [String: Int64]()
    /// Manifests already given their segment lists: FFmpeg reads a manifest twice when it opens it.
    private var listed = [String: String]()
    private var dash = Set<String>()
    public let token = UUID().uuidString.lowercased()

    init() {}

    // MARK: - Play addresses

    /// `address` with Android's proxy prefix replaced by this server's, or nil when it has none.
    /// Starts the server on first use and makes `session` the one `/proxy` calls.
    public func serve(_ address: String, for session: SpiderSession, dash isDASH: Bool) async -> String? {
        guard address.hasPrefix(Self.androidPrefix) else { return nil }
        lock.withLock { self.session = session }
        guard let base = await start() else { return nil }
        let rewritten = Self.rewrite(address, base: base)
        if isDASH { lock.withLock { _ = dash.insert(rewritten) } }
        return rewritten
    }

    /// True for an address `serve` handed out as DASH: AVPlayer cannot open one, so it goes to MPV.
    public static func prefersMPV(_ url: URL) -> Bool {
        shared.lock.withLock { shared.dash.contains(url.absoluteString) }
    }

    /// True for any address of this server: already a stream, never probed or sniffed.
    public static func serves(_ url: URL) -> Bool {
        url.host == "127.0.0.1" && url.path.hasPrefix("/\(shared.token)/proxy")
    }

    static func rewrite(_ text: String, base: URL) -> String {
        text.replacingOccurrences(of: androidPrefix, with: base.absoluteString + "proxy")
    }

    /// A DASH manifest cut to one video and one audio Representation (W-210). FFmpeg's dashdec opens and
    /// probes every Representation before playing, each read from its first byte through the spider one
    /// call at a time: bili's six qualities and three audio tracks took more than MPV's 20 s to start.
    /// The one kept has the highest bandwidth among the H.264 ones when there are any (every iPhone decodes
    /// them in hardware), else among all. Adaptation sets left empty go too; anything else is untouched.
    static func oneRepresentationPerType(_ mpd: String) -> String {
        let sets = mpd.matches(of: /(?s)<AdaptationSet\b.*?<\/AdaptationSet>/).map { String($0.output) }
        func kind(_ set: String) -> String? {
            let open = set.prefixMatch(of: /<AdaptationSet\b[^>]*>/).map { String($0.output) } ?? ""
            return ["video", "audio"].first { open.contains("\"\($0)/") || open.contains("contentType=\"\($0)\"") }
        }
        func reps(_ set: String) -> [String] {
            set.matches(of: /(?s)<Representation\b[^>]*?(?:\/>|>.*?<\/Representation>)/).map { String($0.output) }
        }
        func rank(_ rep: String) -> (Int, Int) {
            let codecs = rep.firstMatch(of: /\bcodecs="([^"]*)"/).map { String($0.1) } ?? ""
            return (codecs.hasPrefix("avc1") ? 1 : 0, rep.firstMatch(of: /\bbandwidth="(\d+)"/).flatMap { Int($0.1) } ?? 0)
        }
        var out = mpd
        for type in ["video", "audio"] {
            let ofType = sets.filter { kind($0) == type }
            let all = ofType.flatMap(reps)
            guard all.count > 1, let keep = all.max(by: { rank($0) < rank($1) }) else { continue }
            for set in ofType {
                var trimmed = set
                for rep in reps(set) where rep != keep {
                    trimmed = trimmed.replacingOccurrences(of: rep, with: "")
                }
                out = out.replacingOccurrences(of: set, with: reps(set).contains(keep) ? trimmed : "")
            }
        }
        return out
    }

    // MARK: - Listener (OfflineMediaServer's lifecycle: loopback, any port, reopened when suspended)

    func start() async -> URL? {
        if let ready = lock.withLock({ () -> (listener: NWListener, port: NWEndpoint.Port)? in
            guard let listener, listener.state == .ready, let port else { return nil }
            return (listener, port)
        }) {
            if await OfflineMediaServer.answers(port: ready.port) { return base(ready.port) }
            let dropped = lock.withLock { () -> Bool in
                guard let current = listener, current === ready.listener else { return false }
                listener = nil
                port = nil
                return true
            }
            if dropped { ready.listener.cancel() }
        }
        return await withCheckedContinuation { continuation in
            let (ready, needsListener) = lock.withLock { () -> (URL?, Bool) in
                if let listener, listener.state == .ready, let port { return (base(port), false) }
                waiting.append(continuation)
                return (nil, listener == nil)
            }
            if let ready { continuation.resume(returning: ready) } else if needsListener { makeListener() }
        }
    }

    private func base(_ port: NWEndpoint.Port) -> URL? {
        URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/")
    }

    private func makeListener() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return finish(nil) }
        lock.withLock { self.listener = listener }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                let port = self.lock.withLock { () -> NWEndpoint.Port? in
                    guard self.listener === listener else { return nil }
                    self.port = listener.port
                    return listener.port
                }
                if let port { self.finish(self.base(port)) }
            case .failed, .cancelled:
                let current = self.lock.withLock { () -> Bool in
                    guard self.listener === listener else { return false }
                    self.listener = nil
                    self.port = nil
                    return true
                }
                if current { listener.cancel(); self.finish(nil) }
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    private func finish(_ url: URL?) {
        let continuations = lock.withLock { defer { waiting = [] }; return waiting }
        continuations.forEach { $0.resume(returning: url) }
    }

    // MARK: - Requests

    struct Request: Equatable {
        let method: String
        /// FongMi's map: the query, then every request header by its lower-cased name.
        let params: [String: String]
        /// The query as sent: which file is asked for, whatever headers come with it.
        var query = ""
    }

    static func parse(_ head: String, token: String) -> Request? {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, ["GET", "HEAD"].contains(String(parts[0])),
              let components = URLComponents(string: String(parts[1])), components.path == "/\(token)/proxy"
        else { return nil }
        var params = [String: String]()
        for item in components.queryItems ?? [] { params[item.name] = item.value ?? "" }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            params[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Request(method: String(parts[0]), params: params, query: components.percentEncodedQuery ?? "")
    }

    /// The bytes a request asks for: `bytes=a-b` or `bytes=a-`, or all of it without a Range.
    /// Nil for anything else (a suffix or multi-range), which is passed to the spider unchanged.
    static func window(_ range: String?) -> (start: Int64, end: Int64?)? {
        guard let range else { return (0, nil) }
        guard range.lowercased().hasPrefix("bytes="), !range.contains(",") else { return nil }
        let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard bounds.count == 2, let start = Int64(bounds[0]) else { return nil }
        if bounds[1].isEmpty { return (start, nil) }
        guard let end = Int64(bounds[1]), end >= start else { return nil }
        return (start, end)
    }

    /// `Content-Range: bytes a-b/total`, from a spider's 206.
    static func contentRange(_ headers: [String: String]) -> (start: Int64, end: Int64, total: Int64)? {
        guard let value = headers.first(where: { $0.key.lowercased() == "content-range" })?.value,
              let match = value.firstMatch(of: /bytes\s+(\d+)-(\d+)\/(\d+)/),
              let start = Int64(match.1), let end = Int64(match.2), let total = Int64(match.3)
        else { return nil }
        return (start, end, total)
    }

    static func isText(_ mime: String) -> Bool {
        let mime = mime.lowercased()
        return mime.hasPrefix("text/") || mime.contains("xml") || mime.contains("mpegurl") || mime.contains("json")
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                Task { await self.respond(to: head, on: Writer(connection)) }
            } else if error != nil || complete || buffer.count > 16 * 1024 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    func respond(to head: String, on writer: some ProxyWriting) async {
        guard let request = Self.parse(head, token: token) else { return await writer.status(404) }
        let target = lock.withLock { session }
        // shortcut: only `do=py` (or none) for the most recent Python spider, FongMi's default
        // dispatch; `do=js` and jar proxies have no caller on iOS. Add them when a site needs one.
        guard let target, ["py", ""].contains(request.params["do"] ?? "") else { return await writer.status(404) }
        await handle(request, target: target, writer: writer)
    }

    func handle(_ request: Request, target: any SpiderProxying, writer: some ProxyWriting) async {
        var params = request.params
        let original = params["range"]
        let file = request.query.isEmpty
            ? params.filter { $0.key != "range" }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            : request.query
        if request.method == "HEAD" {
            params["range"] = "bytes=0-0"
            guard let answer = await call(target, params) else { return await writer.status(504) }
            if answer.status == 206, let range = Self.contentRange(answer.headers),
               let window = Self.window(original) {
                await writer.write(head: Self.streamHead(answer, window: window, total: range.total,
                                                                 ranged: original != nil), body: nil)
                return
            }
            await writer.write(head: forwarded(answer, target: target).head, body: nil)
            return
        }
        guard let window = Self.window(original),
              window.end.map({ $0 - window.start + 1 > Self.segment }) ?? true else {
            guard var answer = await call(target, params) else { return await writer.status(504) }
            // A bare 206 for part of a file whose size is known gets the Content-Range FFmpeg checks.
            if answer.status == 206, !answer.headers.keys.contains(where: { $0.lowercased() == "content-range" }),
               let window = Self.window(original), let total = lock.withLock({ totals[file] }), window.start < total {
                let end = min(window.start + Int64(answer.body.count), total) - 1
                answer.headers["Content-Range"] = "bytes \(window.start)-\(end)/\(total)"
            }
            let reply = await forwarded(answer, target: target)
            await writer.write(head: reply.head, body: reply.body)
            return
        }
        params["range"] = "bytes=\(window.start)-\(window.start + Self.segment - 1)"
        guard let first = await call(target, params) else { return await writer.status(504) }
        // A 206 with no Content-Range still honoured the range when it is a whole segment long (py/哔哩.py
        // answers bare `[206, mime, body]`); unless its index says otherwise, the total is then unknown.
        let range = Self.contentRange(first.headers)
        guard first.status == 206, range.map({ $0.start == window.start }) ?? (Int64(first.body.count) == Self.segment) else {
            // The spider ignores Range: what it answered is the whole thing.
            let reply = await forwarded(first, target: target)
            await writer.write(head: reply.head, body: reply.body)
            return
        }
        // A fragmented MP4 says its size in its index, which comes in its first bytes (W-210): kept per file,
        // so a later seek is answered with the Content-Range FFmpeg needs to land there.
        if range == nil, window.start == 0, let size = Self.sidxTotal(first.body) {
            remember(size, of: file)
        }
        let total = range?.total ?? lock.withLock { totals[file] }.flatMap { window.start < $0 ? $0 : nil }
        let end: Int64? = total.map { min(window.end ?? $0 - 1, $0 - 1) } ?? window.end
        let head = total.map { Self.streamHead(first, window: window, total: $0, ranged: original != nil) }
            ?? Self.openHead(first, ranged: original != nil)
        var next = window.start
        var part = first
        while true {
            let wanted = end.map { Int($0 - next + 1) } ?? part.body.count
            // With no Content-Range a short answer is the last one: asking past the end of the file can
            // bring back an error page, which would be appended as video.
            let last = (end.map { next + Int64(part.body.count) > $0 } ?? false)
                || (range == nil && part.body.count < Self.segment)
            guard await writer.write(head: next == window.start ? head : nil, body: part.body.prefix(wanted), more: !last),
                  !last else { break }
            next += Int64(part.body.count)
            params["range"] = "bytes=\(next)-\(end.map { min(next + Self.segment - 1, $0) } ?? next + Self.segment - 1)"
            // Only a 206 starting where the stream stands continues it. Anything else ends the stream short:
            // with a length sent the player asks again from there; without one it sees the end of the file.
            guard let answer = await call(target, params), answer.status == 206, !answer.body.isEmpty,
                  Self.contentRange(answer.headers).map({ $0.start == next }) ?? (range == nil)
            else { break }
            part = answer
        }
        await writer.close()
    }

    /// The size of a fragmented MP4 from its `sidx` box: where the box ends, plus its first offset, plus
    /// every referenced size, reaches the last byte. Nil when the bytes hold no `sidx` among the top boxes.
    static func sidxTotal(_ data: Data) -> Int64? {
        sidx(data).map { $0.firstByte + $0.references.reduce(0) { $0 + $1.size } }
    }

    /// The top-level `sidx` box in `data`: its timescale, where the first referenced byte is (relative
    /// to `data`), and each reference's size and duration. Nil without one, or for a nested index.
    static func sidx(_ data: Data) -> (timescale: Int64, firstByte: Int64, references: [(size: Int64, duration: Int64)])? {
        let bytes = [UInt8](data)
        func int(_ at: Int, _ count: Int) -> Int64? {
            guard at >= 0, at + count <= bytes.count else { return nil }
            return bytes[at..<at + count].reduce(0) { $0 << 8 | Int64($1) }
        }
        var at = 0
        while let size = int(at, 4), size >= 8, let type = int(at + 4, 4) {
            guard type == 0x7369_6478 else { at += Int(size); continue } // "sidx"
            // version, flags, reference_ID and timescale, then two times 32 or 64 bits wide by version
            guard let version = int(at + 8, 1) else { return nil }
            let wide = version == 0 ? 4 : 8, times = at + 20
            guard let timescale = int(at + 16, 4), let offset = int(times + wide, wide),
                  let count = int(times + 2 * wide + 2, 2) else { return nil }
            var references = [(size: Int64, duration: Int64)]()
            for index in 0..<Int(count) {
                let entry = times + 2 * wide + 4 + 12 * index
                guard let reference = int(entry, 4), reference >> 31 == 0, let duration = int(entry + 4, 4) else { return nil }
                references.append((reference & 0x7fff_ffff, duration))
            }
            return (timescale, Int64(at) + size + offset, references)
        }
        return nil
    }

    /// The head of a stream whose total the spider never said: no Content-Length, so the body ends when
    /// the connection closes; Accept-Ranges still lets the player seek with a new request.
    static func openHead(_ answer: SpiderProxyResponse, ranged: Bool) -> Data {
        OfflineMediaServer.head(status: ranged ? "206 Partial Content" : "200 OK",
                                headers: ["Content-Type": answer.mime.isEmpty ? "application/octet-stream" : answer.mime,
                                          "Accept-Ranges": "bytes"])
    }

    /// The head of a stream assembled from segments: 206 for the window asked for, 200 for all of it.
    static func streamHead(_ answer: SpiderProxyResponse, window: (start: Int64, end: Int64?), total: Int64,
                           ranged: Bool) -> Data {
        let end = min(window.end ?? total - 1, total - 1)
        var headers = ["Content-Type": answer.mime.isEmpty ? "application/octet-stream" : answer.mime,
                       "Accept-Ranges": "bytes", "Content-Length": String(max(end - window.start + 1, 0))]
        if ranged { headers["Content-Range"] = "bytes \(window.start)-\(end)/\(total)" }
        return OfflineMediaServer.head(status: ranged ? "206 Partial Content" : "200 OK", headers: headers)
    }

    private func remember(_ size: Int64, of file: String) {
        lock.withLock {
            if totals.count > 64 { totals.removeAll() }
            totals[file] = size
        }
    }

    /// Each of this server's files a manifest gives as a `SegmentBase` (one MP4 and its index), given
    /// instead as a `SegmentList` of the index's references, with their times in the set's
    /// `SegmentTimeline` (W-210). FFmpeg's dashdec reads a `SegmentBase` file as one fragment it cannot
    /// seek in, so a resume at 19 minutes read 75 MB from the start; with a list it opens the fragment
    /// that holds the time asked for. The index costs one small spider call per file, and the file's
    /// size is kept for the Content-Range of the parts asked later. Files it cannot index, or whose spider
    /// answers with a Content-Range of its own, stay as they are.
    func segmentLists(_ mpd: String, base: URL, target: any SpiderProxying) async -> String {
        if let done = lock.withLock({ listed[mpd] }) { return done }
        var out = mpd
        for set in mpd.matches(of: /(?s)<AdaptationSet\b.*?<\/AdaptationSet>/).map({ String($0.output) }) {
            var converted = set, timeline = ""
            for representation in set.matches(of: /(?s)<Representation\b[^>]*?>.*?<\/Representation>/).map({ String($0.output) }) {
                guard let address = representation.firstMatch(of: /<BaseURL>([^<]*)<\/BaseURL>/)
                        .map({ String($0.1).replacingOccurrences(of: "&amp;", with: "&") }),
                      address.hasPrefix(base.absoluteString + "proxy?"), let query = URLComponents(string: address),
                      let segmentBase = representation.firstMatch(of: /(?s)<SegmentBase\b[^>]*?(?:\/>|>.*?<\/SegmentBase>)/),
                      let index = segmentBase.output.firstMatch(of: /indexRange="(\d+)-(\d+)"/),
                      let indexStart = Int64(index.1),
                      let initialization = segmentBase.output.firstMatch(of: /<Initialization\b[^>]*\brange="(\d+-\d+)"/)
                else { continue }
                var params = [String: String]()
                for item in query.queryItems ?? [] { params[item.name] = item.value ?? "" }
                params["range"] = "bytes=\(index.1)-\(index.2)"
                // Only a file served bare (no Content-Range, py/哔哩.py) needs it. One whose spider says its range
                // (YouTube｜PY) already seeks; listed, each part became its own request, and googlevideo's 403s
                // ended playback within seconds instead of after the ~75 s buffered (W-202 limit).
                guard let answer = await call(target, params), answer.status == 200 || answer.status == 206,
                      !answer.headers.keys.contains(where: { $0.lowercased() == "content-range" }),
                      let sidx = Self.sidx(answer.body), !sidx.references.isEmpty else { continue }
                var offset = indexStart + sidx.firstByte
                let segments = sidx.references.map { reference in
                    defer { offset += reference.size }
                    return "<SegmentURL mediaRange=\"\(offset)-\(offset + reference.size - 1)\"/>"
                }
                remember(offset, of: query.percentEncodedQuery ?? "")
                converted = converted.replacingOccurrences(of: representation, with: representation.replacingOccurrences(
                    of: String(segmentBase.output),
                    with: "<SegmentList timescale=\"\(sidx.timescale)\"><Initialization range=\"\(initialization.1)\"/>"
                        + segments.joined() + "</SegmentList>"))
                // dashdec reads a SegmentTimeline only from the set's SegmentList: one per set, so per
                // kept Representation (oneRepresentationPerType leaves one).
                timeline = "<SegmentList timescale=\"\(sidx.timescale)\"><SegmentTimeline>"
                    + sidx.references.map { "<S d=\"\($0.duration)\"/>" }.joined() + "</SegmentTimeline></SegmentList>"
            }
            guard !timeline.isEmpty, let open = converted.prefixMatch(of: /<AdaptationSet\b[^>]*>/) else { continue }
            converted.insert(contentsOf: timeline, at: open.range.upperBound)
            out = out.replacingOccurrences(of: set, with: converted)
        }
        if out != mpd {
            lock.withLock {
                if listed.count > 8 { listed.removeAll() }
                listed[mpd] = out
            }
        }
        return out
    }

    /// The spider's own answer, with its length recomputed and Android's prefix rewritten in text.
    private func forwarded(_ answer: SpiderProxyResponse, target: any SpiderProxying) async -> (head: Data, body: Data) {
        var body = answer.body
        if Self.isText(answer.mime), let base = lock.withLock({ port.flatMap(base) }) {
            var text = Self.rewrite(String(decoding: body, as: UTF8.self), base: base)
            if answer.mime.lowercased().contains("dash+xml") {
                text = await segmentLists(Self.oneRepresentationPerType(text), base: base, target: target)
            }
            body = Data(text.utf8)
        }
        var headers = answer.headers.filter {
            !["content-length", "transfer-encoding", "connection", "content-type"].contains($0.key.lowercased())
        }
        headers["Content-Type"] = answer.mime.isEmpty ? "application/octet-stream" : answer.mime
        headers["Content-Length"] = String(body.count)
        let reason = HTTPURLResponse.localizedString(forStatusCode: answer.status).capitalized
        return (OfflineMediaServer.head(status: "\(answer.status) \(reason)", headers: headers), body)
    }

    /// One `localProxy` call, or nil when it fails or outlasts `callTimeout` (the Python call itself
    /// cannot be interrupted; it finishes on the site's queue and its answer is dropped). A 403 is
    /// relayed, not retried: googlevideo's per-address quota does not reset by waiting (W-202).
    private func call(_ target: any SpiderProxying, _ params: [String: String]) async -> SpiderProxyResponse? {
        let answer = await timed(target, params)
        // The request's shape only — never the address, which carries the token. `file` tells the files of
        // one manifest apart without printing their (signed) addresses.
        let file = params["url"].map { String(UInt32(truncatingIfNeeded: $0.hashValue), radix: 36) } ?? ""
        Self.log.notice("[proxy] type=\(params["type"] ?? "", privacy: .public) file=\(file, privacy: .public) track=\(params["track"] ?? "", privacy: .public) itag=\(params["itag"] ?? "", privacy: .public) range=\(params["range"] ?? "", privacy: .public) → \(answer.map { "\($0.status) \($0.body.count)B" } ?? "none", privacy: .public)")
        return answer
    }

    private func timed(_ target: any SpiderProxying, _ params: [String: String]) async -> SpiderProxyResponse? {
        await withTaskGroup(of: SpiderProxyResponse?.self) { group in
            group.addTask { try? await target.proxy(params: params) }
            group.addTask { [callTimeout] in try? await Task.sleep(for: callTimeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// What the server calls; `SpiderSession` in the app, a stub in tests.
public protocol SpiderProxying: Sendable {
    func proxy(params: [String: String]) async throws -> SpiderProxyResponse?
}

extension SpiderSession: SpiderProxying {}

/// The connection, as the request handler sees it. `write` answers false once the player has gone.
protocol ProxyWriting: Sendable {
    @discardableResult func write(head: Data?, body: Data?, more: Bool) async -> Bool
    func close() async
}

extension ProxyWriting {
    @discardableResult func write(head: Data, body: Data?) async -> Bool { await write(head: head, body: body, more: false) }
    func status(_ code: Int) async {
        let reason = HTTPURLResponse.localizedString(forStatusCode: code).capitalized
        await write(head: OfflineMediaServer.head(status: "\(code) \(reason)", headers: ["Content-Length": "0"]), body: nil)
    }
}

private struct Writer: ProxyWriting {
    let connection: NWConnection
    init(_ connection: NWConnection) { self.connection = connection }

    func write(head: Data?, body: Data?, more: Bool) async -> Bool {
        var data = head ?? Data()
        if let body { data.append(body) }
        let sent = await withCheckedContinuation { continuation in
            connection.send(content: data, isComplete: !more,
                            completion: .contentProcessed { continuation.resume(returning: $0 == nil) })
        }
        if !sent || !more { connection.cancel() }
        return sent
    }

    func close() async { connection.cancel() }
}
#endif
