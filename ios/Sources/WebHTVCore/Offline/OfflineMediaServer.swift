#if canImport(Network)
import Foundation
import Network

/// IOS-POC-47 — serves downloaded HLS packages to both engines on `127.0.0.1`.
///
/// Why a server at all: AVPlayer will not play HLS from `file://`, and a resource-loader delegate
/// may only redirect a segment request to an HTTP address (Apple media engineers on the developer
/// forums, threads 69357 and 113063). A loopback HTTP server is the one local route AVPlayer takes,
/// and MPV is handed the identical address, so both engines read one copy.
///
/// **What it will serve:** GET and HEAD of a regular file inside `root/<asset-id>/`, named by
/// `/<token>/<asset-id>/<relative path>`. The token is random per launch, so nothing else on the
/// device can guess an address; the listener binds to the loopback interface only; a path with
/// `..`, an absolute path, a symlink out of the asset, or a file that is gone is refused. It
/// reads files and nothing else — no listing, no writes, no other methods.
public final class OfflineMediaServer: @unchecked Sendable {
    private let root: URL
    private let queue = DispatchQueue(label: "com.webhtv.ios.poc.offline-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: NWEndpoint.Port?
    private var waiting = [CheckedContinuation<URL?, Never>]()
    public let token = UUID().uuidString.lowercased()

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// `http://127.0.0.1:<port>/<token>/`, starting the listener when it is not running — also
    /// after iOS tore it down while the app was suspended. The previous port is tried first, so an
    /// address handed out before stays valid.
    public func start() async -> URL? {
        await withCheckedContinuation { continuation in
            let (ready, needsListener, preferred) = lock.withLock { () -> (URL?, Bool, NWEndpoint.Port?) in
                if let listener, listener.state == .ready, let port { return (base(port), false, port) }
                waiting.append(continuation)
                return (nil, listener == nil, port)
            }
            if let ready {
                continuation.resume(returning: ready)
            } else if needsListener {
                makeListener(preferred: preferred)
            }
        }
    }

    private func base(_ port: NWEndpoint.Port) -> URL? {
        URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/")
    }

    private func makeListener(preferred: NWEndpoint.Port?) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: preferred ?? .any)
        guard let listener = try? NWListener(using: parameters) else {
            if preferred != nil { makeListener(preferred: nil) } else { finish(nil) }
            return
        }
        lock.withLock { self.listener = listener }
        let identity = ObjectIdentifier(listener)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let port = self.lock.withLock { () -> NWEndpoint.Port? in
                    guard let current = self.listener, ObjectIdentifier(current) == identity else { return nil }
                    self.port = current.port
                    return current.port
                }
                guard let port else { return }
                OfflineLog.notice("[offline] server ready")
                self.finish(self.base(port))
            case .failed, .cancelled:
                let (stale, hadWaiters) = self.lock.withLock { () -> (NWListener?, Bool) in
                    guard let current = self.listener, ObjectIdentifier(current) == identity else { return (nil, false) }
                    self.listener = nil
                    return (current, !self.waiting.isEmpty)
                }
                guard let stale else { return }
                stale.cancel()
                // The preferred port is taken: any port, rather than no server.
                if hadWaiters { self.makeListener(preferred: nil) }
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    private func finish(_ url: URL?) {
        let continuations = lock.withLock {
            defer { waiting = [] }
            return waiting
        }
        continuations.forEach { $0.resume(returning: url) }
    }

    // MARK: Requests

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
                self.respond(to: head, on: connection)
            } else if error != nil || complete || buffer.count > 16 * 1024 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// The parsed request: method, the file it names, and an optional `Range`.
    struct Request: Equatable {
        let method: String
        let assetID: String
        let relativePath: String
        let range: String?
    }

    static func parse(_ head: String, token: String) -> Request? {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, ["GET", "HEAD"].contains(String(parts[0])) else { return nil }
        let rawPath = String(parts[1].split(separator: "?").first ?? "")
        let components = rawPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            .map { String($0).removingPercentEncoding ?? String($0) }
        guard components.count >= 3, components[0] == token, UUID(uuidString: components[1]) != nil,
              !components.dropFirst(2).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("/") || $0.contains("\\") })
        else { return nil }
        let range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces) }
        return Request(method: String(parts[0]), assetID: components[1],
                       relativePath: components.dropFirst(2).joined(separator: "/"), range: range)
    }

    /// `bytes=a-b`, `bytes=a-` or `bytes=-n`, within `size`. Nil for a range that cannot be served.
    static func byteRange(_ header: String, size: Int64) -> ClosedRange<Int64>? {
        guard header.lowercased().hasPrefix("bytes="), size > 0 else { return nil }
        let spec = header.dropFirst("bytes=".count).split(separator: ",").first ?? ""
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty {
            guard let suffix = Int64(bounds[1]), suffix > 0 else { return nil }
            return max(size - suffix, 0)...(size - 1)
        }
        guard let start = Int64(bounds[0]), start < size else { return nil }
        let end = bounds[1].isEmpty ? size - 1 : min(Int64(bounds[1]) ?? (size - 1), size - 1)
        guard end >= start else { return nil }
        return start...end
    }

    static func contentType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "m4s": return "video/iso.segment"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "aac": return "audio/aac"
        case "ac3": return "audio/ac3"
        case "ec3": return "audio/eac3"
        case "mp3": return "audio/mpeg"
        case "vtt": return "text/vtt"
        case "srt": return "application/x-subrip"
        default: return "application/octet-stream"
        }
    }

    /// The file a request names, if it is a regular file inside its asset's folder.
    func file(for request: Request) -> URL? {
        let folder = root.appendingPathComponent(request.assetID, isDirectory: true).resolvingSymlinksInPath()
        let file = root.appendingPathComponent(request.assetID).appendingPathComponent(request.relativePath)
            .resolvingSymlinksInPath()
        guard file.path.hasPrefix(folder.path + "/"),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true
        else { return nil }
        return file
    }

    private func respond(to head: String, on connection: NWConnection) {
        guard let request = Self.parse(head, token: token) else {
            send(status: "400 Bad Request", headers: [:], on: connection)
            return
        }
        guard let file = file(for: request),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        else {
            send(status: "404 Not Found", headers: [:], on: connection)
            return
        }
        var headers = ["Content-Type": Self.contentType(request.relativePath), "Accept-Ranges": "bytes"]
        var range: ClosedRange<Int64> = 0...max(size - 1, 0)
        var status = "200 OK"
        if let header = request.range {
            guard let parsed = Self.byteRange(header, size: size) else {
                send(status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(size)"], on: connection)
                return
            }
            range = parsed
            status = "206 Partial Content"
            headers["Content-Range"] = "bytes \(parsed.lowerBound)-\(parsed.upperBound)/\(size)"
        }
        let length = size == 0 ? 0 : range.upperBound - range.lowerBound + 1
        headers["Content-Length"] = String(length)
        let headerData = Self.head(status: status, headers: headers)
        guard request.method == "GET", length > 0, let handle = try? FileHandle(forReadingFrom: file) else {
            connection.send(content: headerData, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let reader = Reader(handle)
        connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self, reader.seek(to: range.lowerBound) else { reader.close(); connection.cancel(); return }
            self.stream(reader, remaining: length, on: connection)
        })
    }

    /// One open file, read on the server's queue only, one piece at a time.
    private final class Reader: @unchecked Sendable {
        private let handle: FileHandle
        init(_ handle: FileHandle) { self.handle = handle }
        func seek(to offset: Int64) -> Bool { (try? handle.seek(toOffset: UInt64(offset))) != nil }
        func read(_ count: Int) -> Data? { try? handle.read(upToCount: count) }
        func close() { try? handle.close() }
    }

    /// The body in 512 KB pieces, each sent once the previous one has gone.
    private func stream(_ reader: Reader, remaining: Int64, on connection: NWConnection) {
        let chunk = Int(min(remaining, 512 * 1024))
        guard chunk > 0, let data = reader.read(chunk), !data.isEmpty else {
            reader.close()
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let left = remaining - Int64(data.count)
        connection.send(content: data, isComplete: left <= 0, completion: .contentProcessed { [weak self] error in
            guard error == nil, left > 0, let self else {
                reader.close()
                connection.cancel()
                return
            }
            self.stream(reader, remaining: left, on: connection)
        })
    }

    private func send(status: String, headers: [String: String], on connection: NWConnection) {
        var headers = headers
        headers["Content-Length"] = "0"
        connection.send(content: Self.head(status: status, headers: headers), isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    static func head(status: String, headers: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
        return Data((text + "\r\n").utf8)
    }
}
#endif
