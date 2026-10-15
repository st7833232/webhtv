import Foundation

/// IOS-POC-61 S2 (W-120). Checks for a newer official spider pack and installs it, **only when called** — no
/// launch hook, timer or retry loop: manifest (capped) → unsigned validation → admission → every blob, capped at
/// its declared size → the store, which verifies and compiles everything again before `state.json` switches.
///
/// It never activates anything in memory; the caller decides that, because only the App knows whether something
/// is playing. Any failure leaves the installed generations and `state.json` exactly as they were.
public actor RuntimePackUpdater {
    /// Where the official pack is published (`ios-poc:spider-pack/official/`). Compiled in, never configurable:
    /// with no signature this fixed HTTPS address is part of the trust.
    public static let manifestURL =
        URL(string: "https://raw.githubusercontent.com/st7833232/webhtv/ios-poc/spider-pack/official/manifest.json")!

    public enum Outcome: Sendable, Equatable {
        /// What is installed is already this sequence.
        case upToDate
        /// Installed and active on disk. `needsNewerApp` names the classes this build is too old for: they keep
        /// the copy that ran before, or stay bundled.
        case installed(version: String, needsNewerApp: [String])
        /// The pack itself was refused; `rejection.requiresNewerApp` tells "update the App" from "broken".
        case rejected(RuntimePackRejection)
        /// The server was never reached (offline, refused, no such host, timed out before any answer).
        case unreachable(String)
        /// The network, not the pack, after the server answered: an HTTP error or a transfer that stopped.
        case failed(String)
    }

    public enum FetchError: Error, Equatable {
        case tooLarge(Int)
        case status(Int)
        case insecureRedirect
    }

    /// Downloads at most `limit` bytes of `url`.
    public typealias Fetch = @Sendable (_ url: URL, _ limit: Int) async throws -> Data

    public static let shared = RuntimePackUpdater()

    private let store: RuntimePackStore
    private let fetch: Fetch
    private let manifestURL: URL
    /// One check at a time: a second caller waits for the first one's outcome instead of starting another.
    private var running: Task<Outcome, Never>?

    public init(store: RuntimePackStore = .shared, manifestURL: URL = RuntimePackUpdater.manifestURL,
                fetch: Fetch? = nil) {
        self.store = store
        self.manifestURL = manifestURL
        self.fetch = fetch ?? Self.download
    }

    public func check(host: RuntimeHost = .installed(), now: Date = Date()) async -> Outcome {
        if let running { return await running.value }
        let task = Task { await run(host: host, now: now) }
        running = task
        defer { running = nil }
        return await task.value
    }

    private func run(host: RuntimeHost, now: Date) async -> Outcome {
        // Refused before anything is asked of the network, not after a plain-HTTP body arrived.
        guard manifestURL.scheme?.lowercased() == "https" else { return .rejected(.insecureOrigin(manifestURL.absoluteString)) }
        do {
            let manifest: Data
            do {
                manifest = try await fetch(manifestURL, RuntimePackLimits.manifestBytes)
            } catch FetchError.tooLarge(let bytes) {
                return .rejected(.manifestTooLarge(bytes))
            } catch let error as URLError where Self.neverReached.contains(error.code) {
                return .unreachable(error.localizedDescription)
            }
            let candidate = try RuntimePackValidator.validateOfficial(manifest: manifest, fetchedFrom: manifestURL,
                                                                      host: host, now: now)
            let state = await store.state() ?? RuntimeScopeState(scope: .global, packId: candidate.manifest.packId)
            switch state.admission(of: candidate) {
            case .accept: break
            // Already installed: nothing is downloaded. Only a restore that left its files out fetches them again.
            case .unchanged where await store.has(candidate.generation): return .upToDate
            case .unchanged: break
            case .reject(let rejection): return .rejected(rejection)
            }
            var files = [String: Data]()
            for file in candidate.manifest.files {
                // Content-addressed beside the manifest: nothing a manifest says can point elsewhere.
                guard let blob = URL(string: "blobs/sha256/\(file.sha256)", relativeTo: manifestURL)?.absoluteURL else {
                    return .rejected(.invalidPath(file.path))
                }
                do {
                    files[file.path] = try await fetch(blob, file.bytes)
                } catch FetchError.tooLarge(let bytes) {
                    return .rejected(.fileTooLarge(path: file.path, bytes: bytes))
                }
            }
            let pack = try await store.install(candidate, manifest: manifest, files: files, host: host)
            // `nil` is either "already this one" or a rollbackToBundled directive, which did change something.
            if pack == nil, candidate.manifest.directive == nil { return .upToDate }
            let hostApi = host.abi[.jsHost]?.minor ?? 0
            let tooNew = candidate.manifest.files.filter { ($0.minHostApi ?? 0) > hostApi }.compactMap(\.className)
            return .installed(version: candidate.manifest.version, needsNewerApp: tooNew.sorted())
        } catch let rejection as RuntimePackRejection {
            return .rejected(rejection)
        } catch FetchError.status(let code) {
            return .failed("HTTP \(code)")
        } catch FetchError.insecureRedirect {
            return .failed("insecure redirect")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Before the manifest's first byte, these mean the server was not reached at all.
    private static let neverReached: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut,
        .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
    ]

    /// Neither a cached copy nor a cookie: a hash-pinned download must never be served a stale body, and the
    /// pack's host gets no state from the App. Longer than a content request, so a slow link finishes 2 MiB.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    /// Streams with a hard ceiling (as `DrpyEngine.download`), and refuses a redirect that left HTTPS — the App
    /// allows arbitrary loads, and the manifest's own bytes are not hash-pinned by anything else.
    private static let download: Fetch = { url, limit in
        let (stream, response) = try await session.bytes(from: url)
        guard response.url?.scheme?.lowercased() == "https" else { throw FetchError.insecureRedirect }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FetchError.status(http.statusCode)
        }
        if response.expectedContentLength > Int64(limit) { throw FetchError.tooLarge(Int(response.expectedContentLength)) }
        var data = Data()
        data.reserveCapacity(min(limit, 1 << 20))
        for try await byte in stream {
            data.append(byte)
            if data.count > limit { throw FetchError.tooLarge(data.count) }
        }
        return data
    }
}
