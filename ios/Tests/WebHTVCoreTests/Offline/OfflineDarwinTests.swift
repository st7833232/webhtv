#if canImport(Network)
import Foundation
import Network
import Testing
@testable import WebHTVCore

/// IOS-POC-52-7: the Darwin-only network paths of F22 and F36, against a real URLSession on
/// loopback. Linux compiles neither, so these only run on macOS.
struct OfflineDarwinTests {
    /// F22: `OfflineDownloads.manager` fetches sidecar subtitles with exactly this fetcher.
    @Test func offlineSubtitleRedirectsKeepTheSourceCredentialsOnItsOrigin() async throws {
        let server = try await LoopbackHTTPServer.start()
        let fetch = SubtitleHTTP.fetcher(session: OfflineHTTP.subtitleSession)

        // 127.0.0.1 → localhost is another host to `SourceSubtitleProvider.sameOrigin`.
        let cross = try await server.headersAfterRedirect(to: "localhost", with: fetch)
        #expect(cross["cookie"] == nil, "\(cross)")
        #expect(cross["authorization"] == nil, "\(cross)")
        #expect(cross["user-agent"] == "WebHTV-Test")
        #expect(cross["referer"] == "https://site.example/")

        let same = try await server.headersAfterRedirect(to: "127.0.0.1", with: fetch)
        #expect(same["cookie"] == "a=1", "\(same)")
        #expect(same["authorization"] == "Bearer t", "\(same)")

        // Without the policy URLSession carries the Cookie across, so the test is not vacuous. (macOS
        // 27's URLSession drops Authorization on a cross-host redirect by itself; older systems are
        // not assumed to, and the policy removes both.)
        let plain = URLSession(configuration: .ephemeral)
        defer { plain.invalidateAndCancel() }
        let unguarded = try await server.headersAfterRedirect(to: "localhost", with: SubtitleHTTP.fetcher(session: plain))
        #expect(unguarded["cookie"] == "a=1", "\(unguarded)")
    }

    /// F36: a server that ignores Range and sends a huge body. The fetcher keeps `limit` bytes,
    /// says it truncated, and stops the transfer instead of reading the rest.
    @Test func theFetcherStopsReadingAtTheLimit() async throws {
        let server = try await LoopbackHTTPServer.start()
        let big = server.url("/big")
        let fetch = OfflineHTTP.fetcher(origin: big, originalHeaders: [:])

        let probe = try await fetch(URLRequest(url: big), OfflineHTTP.probeLimit)
        #expect(probe.data.count == OfflineHTTP.probeLimit)
        #expect(probe.truncated)
        let sent = try await server.bigBytesSentBeforeClose()
        #expect(sent < LoopbackHTTPServer.bigSize / 4, "server sent \(sent) of \(LoopbackHTTPServer.bigSize) bytes")

        let exact = try await fetch(URLRequest(url: server.url("/exact")), OfflineHTTP.probeLimit)
        #expect(exact.data.count == OfflineHTTP.probeLimit)
        #expect(!exact.truncated)
    }

    /// F35 (IOS-POC-52-12): AVFoundation reads a remote MP4's movie header, with the source's headers
    /// and by byte range, and a saved fMP4 init section from disk. Something that is not video is nil.
    @Test func theVideoProbeReadsAnMP4AndAnInitSection() async throws {
        let server = try await LoopbackHTTPServer.start()
        let wide = try #require(await OfflineVideoProbe.info(server.url("/wide.mp4"), headers: ["Referer": "https://site.example/"]))
        #expect(wide.width == 2560)
        #expect(wide.height == 1440)
        #expect(wide.codec == .h264)
        #expect(wide.dynamicRange == .sdr)
        #expect(server.wideRequests.allSatisfy { $0["referer"] == "https://site.example/" })
        #expect(server.wideRequests.contains { $0["range"] != nil }, "read by byte range")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("init-\(UUID().uuidString).mp4")
        try ProbeFixture.initSection.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let section = try #require(await OfflineVideoProbe.info(file, headers: [:]))
        #expect(section.width == 1280)
        #expect(section.height == 720)
        #expect(section.codec == .hevc)

        #expect(await OfflineVideoProbe.info(server.url("/end"), headers: [:]) == nil)
    }

    /// F11 (IOS-POC-52-9): iOS hears the wake's events are handled before the next download's
    /// preparing is waited for, and the app's background task goes only after that.
    @Test func aWakeTellsTheSystemBeforeItSettles() async {
        var order = [String]()
        await URLSessionOfflineTransport.endWake(tellSystem: { order.append("system") },
                                                 settle: { order.append("settle") },
                                                 settled: { order.append("settled") })
        #expect(order == ["system", "settle", "settled"])
    }
}

/// HTTP/1.1 on 127.0.0.1 for the tests above. `/redirect/<host>` answers 302 to
/// `http://<host>:<port>/end`; `/end` records the headers it was sent; `/big` streams `bigSize`
/// bytes whatever the request asks; `/exact` sends exactly `OfflineHTTP.probeLimit` bytes;
/// `/wide.mp4` serves `ProbeFixture.wide` with byte ranges.
private final class LoopbackHTTPServer: @unchecked Sendable {
    static let bigSize = 256 * 1024 * 1024
    private static let chunk = Data(repeating: 0x47, count: 64 * 1024)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-http-server")
    private let lock = NSLock()
    private var ended = [[String: String]]()
    private var wide = [[String: String]]()
    /// The headers each `/wide.mp4` request carried.
    var wideRequests: [[String: String]] { lock.withLock { wide } }
    private var bigSent = 0
    private var bigClosed = false
    private var started = false

    private init() throws { listener = try NWListener(using: .tcp, on: .any) }

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    static func start() async throws -> LoopbackHTTPServer {
        let server = try LoopbackHTTPServer()
        server.listener.newConnectionHandler = { server.serve($0) }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            server.listener.stateUpdateHandler = { state in
                let result: Result<Void, Error>
                switch state {
                case .ready: result = .success(())
                case .failed(let error): result = .failure(error)
                default: return
                }
                // `.failed` can follow `.ready`; the continuation is resumed once.
                guard server.lock.withLock({ () -> Bool in defer { server.started = true }; return !server.started }) else { return }
                ready.resume(with: result)
            }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    /// Fetches `/redirect/<host>` with a source's headers and answers what `/end` was sent.
    func headersAfterRedirect(to host: String, with fetch: SubtitleFetch) async throws -> [String: String] {
        var request = URLRequest(url: url("/redirect/\(host)"))
        request.setValue("a=1", forHTTPHeaderField: "Cookie")
        request.setValue("Bearer t", forHTTPHeaderField: "Authorization")
        request.setValue("WebHTV-Test", forHTTPHeaderField: "User-Agent")
        request.setValue("https://site.example/", forHTTPHeaderField: "Referer")
        let before = lock.withLock { ended.count }
        let response = try await fetch(request, 1024)
        #expect(response.status == 200)
        return try #require(lock.withLock { ended.count > before ? ended.last : nil })
    }

    /// What `/big` had handed to the network when its connection closed — at most three seconds on.
    func bigBytesSentBeforeClose() async throws -> Int {
        for _ in 0..<60 {
            if let sent = lock.withLock({ bigClosed ? bigSent : nil }) { return sent }
            try await Task.sleep(for: .milliseconds(50))
        }
        return lock.withLock { bigSent }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil { connection.cancel() } else { self.read(connection, buffer) }
                return
            }
            self.respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first.flatMap { $0.split(separator: " ").dropFirst().first }.map(String.init) ?? "/"
        var headers = [String: String]()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let close = "Connection: close\r\n\r\n"
        switch path {
        case _ where path.hasPrefix("/redirect/"):
            let host = path.dropFirst("/redirect/".count)
            send(connection, "HTTP/1.1 302 Found\r\nLocation: http://\(host):\(port)/end\r\nContent-Length: 0\r\n" + close)
        case "/end":
            lock.withLock { ended.append(headers) }
            send(connection, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n" + close, body: Data("ok".utf8))
        case "/wide.mp4":
            lock.withLock { wide.append(headers) }
            let body = ProbeFixture.wide
            if let asked = headers["range"], let range = OfflineMediaServer.byteRange(asked, size: Int64(body.count)) {
                let part = body[Int(range.lowerBound)...Int(range.upperBound)]
                send(connection, "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\n"
                     + "Content-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(body.count)\r\nContent-Length: \(part.count)\r\n" + close,
                     body: Data(part))
            } else {
                send(connection, "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\nContent-Length: \(body.count)\r\n" + close,
                     body: body)
            }
        case "/exact":
            send(connection, "HTTP/1.1 200 OK\r\nContent-Length: \(OfflineHTTP.probeLimit)\r\n" + close,
                 body: Data(repeating: 0x47, count: OfflineHTTP.probeLimit))
        case "/big":
            connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nContent-Length: \(Self.bigSize)\r\n\(close)".utf8),
                            completion: .contentProcessed { _ in })
            stream(connection, sent: 0)
        default:
            send(connection, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n" + close)
        }
    }

    private func send(_ connection: NWConnection, _ head: String, body: Data = Data()) {
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func stream(_ connection: NWConnection, sent: Int) {
        guard sent < Self.bigSize else { closeBig(connection, sent: sent); return }
        connection.send(content: Self.chunk, completion: .contentProcessed { error in
            if error != nil { self.closeBig(connection, sent: sent) } else { self.stream(connection, sent: sent + Self.chunk.count) }
        })
    }

    private func closeBig(_ connection: NWConnection, sent: Int) {
        lock.withLock { bigSent = sent; bigClosed = true }
        connection.cancel()
    }
}

/// IOS-POC-52-12: made with ffmpeg 9.0.2 — one black 2560×1440 H.264 frame, `-movflags +faststart`
/// (2,247 bytes), and the init section of a 1280×720 HEVC (`hvc1`) fMP4 HLS (3,223 bytes).
private enum ProbeFixture {
    static let wide = Data(base64Encoded: """
AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMXbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAACgAAQAAAQAA
AAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAA
AkJ0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAACgAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAA
AAAAAAAAAAAAAABAAAAACgAAAAWgAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAAoAAAAAAABAAAAAAG6bWRpYQAAACBtZGhk
AAAAAAAAAAAAAAAAAAAyAAAAAgBVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABZW1p
bmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAASVzdGJsAAAAwXN0c2QA
AAAAAAAAAQAAALFhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAACgAFoABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMiBsaWJ4
MjY0AAAAAAAAAAAAAAAAGP//AAAAN2F2Y0MBZAAy/+EAGmdkADKs2UAoALWwEQAAAwABAAADADIPGDGWAQAGaOvjyyLA/fj4AAAA
ABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAABEwAAAAAAAAAABhzdHRzAAAAAAAAAAEAAAABAAACAAAAABxzdHNjAAAAAAAAAAEA
AAABAAAAAQAAAAEAAAAUc3RzegAAAAAAAAWAAAAAAQAAABRzdGNvAAAAAAAAAAEAAANHAAAAYXVkdGEAAABZbWV0YQAAAAAAAAAh
aGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxzdAAAACSpdG9vAAAAHGRhdGEAAAABAAAAAExhdmY2My4xLjEwMgAA
AAhmcmVlAAAFiG1kYXQAAAKvBgX//6vcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2
NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1s
IC0gb3B0aW9uczogY2FiYWM9MSByZWY9MyBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgzOjB4MTEzIG1lPWhleCBzdWJtZT03IHBz
eT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTEgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0xIDh4OGRjdD0x
IGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MTUgbG9va2FoZWFk
X3RocmVhZHM9MiBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNv
bnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0zIGJfcHlyYW1pZD0yIGJfYWRhcHQ9MSBiX2JpYXM9MCBkaXJlY3Q9MSB3ZWlnaHRi
PTEgb3Blbl9nb3A9MCB3ZWlnaHRwPTIga2V5aW50PTI1MCBrZXlpbnRfbWluPTI1IHNjZW5lY3V0PTQwIGludHJhX3JlZnJlc2g9
MCByY19sb29rYWhlYWQ9NDAgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0
ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAACyWWIhAAr//72c3wKa22wlS4Fdvdmo+XQkuX7EGD60AAAAwAAAwAAAwAA
AwAAAwAVdmYQdGv0ySuoAAADAAADAAADAD3AAAADAAPgAAADAABugAAAAwATMAAAAwAD6AAAAwAAyQAAAwAAOIAAAAMAD+AAAAMA
BMgAAAMAAhoAAAMAAQEAAAMAAGKAAAADADsAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMA
AAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMA
AAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMA
AAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMA
AAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMA
AAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMA
AAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMA
AAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAAAMAABNR

""", options: .ignoreUnknownCharacters)!
    static let initSection = Data(base64Encoded: """
AAAAHGZ0eXBpc281AAACAGlzbzVpc282bXA0MQAADHttb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAAAAABAAABAAAAAAAA
AAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAALfnRy
YWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAA
AAAAAAAAAEAAAAAFAAAAAtAAAAAAADBlZHRzAAAAKGVsc3QAAAAAAAAAAgAAAFD/////AAEAAAAAAAAAAAQAAAEAAAAACuptZGlh
AAAAIG1kaGQAAAAAAAAAAAAAAAAAADIAAAAAAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxl
cgAAAAqVbWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAKVXN0YmwA
AAoJc3RzZAAAAAAAAAABAAAJ+Wh2YzEAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAFAALQAEgAAABIAAAAAAAAAAEUTGF2YzYzLjEu
MTAyIGxpYngyNjUAAAAAAAAAAAAAAAAY//8AAAmJaHZjQwEBYAAAAJAAAAAAAF3wAPz9+PgAAA8EoAABABhAAQwB//8BYAAAAwCQ
AAADAAADAF2VmAmhAAEAK0IBAQFgAAADAJAAAAMAAAMAXaACgIAtFllZpJMrwFoCAAADAAIAAAMAMhCiAAEAB0QBwXK0YkAnAAEJ
DE4BBf///////////wcsot4JtRdH27tVpP5/wvxOeDI2NSAoYnVpbGQgMjE3KSAtIDQuMysxLWU5Yjg4MTI6W01hYyBPUyBYXVtj
bGFuZyAyMS4wLjBdWzY0IGJpdF0gOGJpdCsxMGJpdCsxMmJpdCAtIEguMjY1L0hFVkMgY29kZWMgLSBDb3B5cmlnaHQgMjAxMy0y
MDE4IChjKSBNdWx0aWNvcmV3YXJlLCBJbmMgLSBodHRwOi8veDI2NS5vcmcgLSBvcHRpb25zOiBjcHVpZD05OCBmcmFtZS10aHJl
YWRzPTMgd3BwIG5vLXBtb2RlIG5vLXBtZSBuby1wc25yIG5vLXNzaW0gbG9nLWxldmVsPTAgYml0ZGVwdGg9OCBpbnB1dC1jc3A9
MSBmcHM9MjUvMSBpbnB1dC1yZXM9MTI4MHg3MjAgaW50ZXJsYWNlPTAgdG90YWwtZnJhbWVzPTAgbGV2ZWwtaWRjPTAgaGlnaC10
aWVyPTEgdWhkLWJkPTAgcmVmPTMgbm8tYWxsb3ctbm9uLWNvbmZvcm1hbmNlIG5vLXJlcGVhdC1oZWFkZXJzIGFubmV4YiBuby1h
dWQgbm8tZW9iIG5vLWVvcyBuby1ocmQgaW5mbyBoYXNoPTAgdGVtcG9yYWwtbGF5ZXJzPTAgb3Blbi1nb3AgbWluLWtleWludD0y
NSBrZXlpbnQ9MjUwIGdvcC1sb29rYWhlYWQ9MCBiZnJhbWVzPTQgYi1hZGFwdD0yIGItcHlyYW1pZCBiZnJhbWUtYmlhcz0wIHJj
LWxvb2thaGVhZD0yMCBsb29rYWhlYWQtc2xpY2VzPTQgc2NlbmVjdXQ9NDAgbm8taGlzdC1zY2VuZWN1dCByYWRsPTAgbm8tc3Bs
aWNlIG5vLWludHJhLXJlZnJlc2ggY3R1PTY0IG1pbi1jdS1zaXplPTggbm8tcmVjdCBuby1hbXAgbWF4LXR1LXNpemU9MzIgdHUt
aW50ZXItZGVwdGg9MSB0dS1pbnRyYS1kZXB0aD0xIGxpbWl0LXR1PTAgcmRvcS1sZXZlbD0wIGR5bmFtaWMtcmQ9MC4wMCBuby1z
c2ltLXJkIHNpZ25oaWRlIG5vLXRza2lwIG5yLWludHJhPTAgbnItaW50ZXI9MCBuby1jb25zdHJhaW5lZC1pbnRyYSBzdHJvbmct
aW50cmEtc21vb3RoaW5nIG1heC1tZXJnZT0zIGxpbWl0LXJlZnM9MSBuby1saW1pdC1tb2RlcyBtZT0xIHN1Ym1lPTIgbWVyYW5n
ZT01NyB0ZW1wb3JhbC1tdnAgbm8tZnJhbWUtZHVwIG5vLWhtZSB3ZWlnaHRwIG5vLXdlaWdodGIgbm8tYW5hbHl6ZS1zcmMtcGlj
cyBkZWJsb2NrPTA6MCBzYW8gbm8tc2FvLW5vbi1kZWJsb2NrIHJkPTMgc2VsZWN0aXZlLXNhbz00IGVhcmx5LXNraXAgcnNraXAg
bm8tZmFzdC1pbnRyYSBuby10c2tpcC1mYXN0IG5vLWN1LWxvc3NsZXNzIGItaW50cmEgbm8tc3BsaXRyZC1za2lwIHJkcGVuYWx0
eT0wIHBzeS1yZD0yLjAwIHBzeS1yZG9xPTAuMDAgbm8tcmQtcmVmaW5lIG5vLWxvc3NsZXNzIGNicXBvZmZzPTAgY3JxcG9mZnM9
MCByYz1jcmYgY3JmPTI4LjAgcWNvbXA9MC42MCBxcHN0ZXA9NCBzdGF0cy13cml0ZT0wIHN0YXRzLXJlYWQ9MCBpcHJhdGlvPTEu
NDAgcGJyYXRpbz0xLjMwIGFxLW1vZGU9MiBhcS1zdHJlbmd0aD0xLjAwIGN1dHJlZSB6b25lLWNvdW50PTAgbm8tc3RyaWN0LWNi
ciBxZy1zaXplPTMyIG5vLXJjLWdyYWluIHFwbWF4PTY5IHFwbWluPTAgbm8tY29uc3QtdmJ2IHNhcj0xIG92ZXJzY2FuPTAgdmlk
ZW9mb3JtYXQ9NSByYW5nZT0wIGNvbG9ycHJpbT0yIHRyYW5zZmVyPTIgY29sb3JtYXRyaXg9MiBjaHJvbWFsb2M9MCBkaXNwbGF5
LXdpbmRvdz0wIGNsbD0wLDAgbWluLWx1bWE9MCBtYXgtbHVtYT0yNTUgbG9nMi1tYXgtcG9jLWxzYj04IHZ1aS10aW1pbmctaW5m
byB2dWktaHJkLWluZm8gc2xpY2VzPTEgbm8tb3B0LXFwLXBwcyBuby1vcHQtcmVmLWxpc3QtbGVuZ3RoLXBwcyBuby1tdWx0aS1w
YXNzLW9wdC1ycHMgc2NlbmVjdXQtYmlhcz0wLjA1IG5vLW9wdC1jdS1kZWx0YS1xcCBuby1hcS1tb3Rpb24gbm8taGRyMTAgbm8t
aGRyMTAtb3B0IG5vLWRoZHIxMC1vcHQgbm8taWRyLXJlY292ZXJ5LXNlaSBhbmFseXNpcy1yZXVzZS1sZXZlbD0wIGFuYWx5c2lz
LXNhdmUtcmV1c2UtbGV2ZWw9MCBhbmFseXNpcy1sb2FkLXJldXNlLWxldmVsPTAgc2NhbGUtZmFjdG9yPTAgcmVmaW5lLWludHJh
PTAgcmVmaW5lLWludGVyPTAgcmVmaW5lLW12PTEgcmVmaW5lLWN0dS1kaXN0b3J0aW9uPTAgbm8tbGltaXQtc2FvIGN0dS1pbmZv
PTAgbm8tbG93cGFzcy1kY3QgcmVmaW5lLWFuYWx5c2lzLXR5cGU9MCBjb3B5LXBpYz0xIG1heC1hdXNpemUtZmFjdG9yPTEuMCBu
by1keW5hbWljLXJlZmluZSBuby1zaW5nbGUtc2VpIG5vLWhldmMtYXEgbm8tc3Z0IG5vLWZpZWxkIHFwLWFkYXB0YXRpb24tcmFu
Z2U9MS4wMCBzY2VuZWN1dC1hd2FyZS1xcD0wY29uZm9ybWFuY2Utd2luZG93LW9mZnNldHMgcmlnaHQ9MCBib3R0b209MCBkZWNv
ZGVyLW1heC1yYXRlPTAgbm8tdmJ2LWxpdmUtbXVsdGktcGFzcyBuby1tY3N0ZiBuby1zYnJjIG5vLWZyYW1lLXJjgAAAAApmaWVs
AQAAAAAQcGFzcAAAAAEAAAABAAAAEHN0dHMAAAAAAAAAAAAAABBzdHNjAAAAAAAAAAAAAAAUc3RzegAAAAAAAAAAAAAAAAAAABBz
dGNvAAAAAAAAAAAAAAAobXZleAAAACB0cmV4AAAAAAAAAAEAAAABAAAAAAAAAAAAAAAAAAAAYXVkdGEAAABZbWV0YQAAAAAAAAAh
aGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxzdAAAACSpdG9vAAAAHGRhdGEAAAABAAAAAExhdmY2My4xLjEwMg==

""", options: .ignoreUnknownCharacters)!
}
#endif
