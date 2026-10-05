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
/// bytes whatever the request asks; `/exact` sends exactly `OfflineHTTP.probeLimit` bytes.
private final class LoopbackHTTPServer: @unchecked Sendable {
    static let bigSize = 256 * 1024 * 1024
    private static let chunk = Data(repeating: 0x47, count: 64 * 1024)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-http-server")
    private let lock = NSLock()
    private var ended = [[String: String]]()
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
#endif
