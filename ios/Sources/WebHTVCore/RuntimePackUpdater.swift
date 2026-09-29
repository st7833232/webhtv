import Foundation

/// Where each scope's runtime pack is published.
public enum RuntimePackChannel {
    /// Beside the configuration, resolved by the same rule its `./json/` rule files use, so it is
    /// always on the configuration's own origin.
    public static let configurationReference = "./runtime/manifest.json"

    /// WebHTV's own pack, signed in CI (IOS-POC-13D). Only where to look: the location is not
    /// trusted, the signature is.
    public static let globalManifestURL =
        URL(string: "https://raw.githubusercontent.com/st7833232/webhtv/ios-poc/runtime/global/manifest.json")!

    /// `nil` for an imported configuration, which has no origin and so no configuration pack.
    public static func manifestURL(for scope: RuntimeScope, source: ConfigSource) -> URL? {
        switch scope {
        case .global: globalManifestURL
        case .configuration: source.resourceURL(for: configurationReference)
        }
    }

    /// Blobs are content-addressed beside the manifest; nothing a manifest says can point elsewhere.
    static func blobURL(_ sha256: String, beside manifest: URL) -> URL? {
        URL(string: "blobs/sha256/\(sha256)", relativeTo: manifest)?.absoluteURL
    }
}

/// IOS-POC-13B. Checks one scope for a newer runtime pack and installs it: manifest → (global)
/// signature → validation → admission → every blob, capped at its declared size → the store, which
/// verifies and smoke-tests everything again before the generation becomes active.
///
/// It never activates anything in memory — the caller decides that, because only the App knows
/// whether something is playing. Any failure leaves the scope exactly as it was.
public actor RuntimePackUpdater {
    public enum Outcome: Sendable, Equatable {
        /// This scope publishes no pack (HTTP 404, or an imported configuration).
        case noPack
        /// What this scope already accepted at this sequence.
        case upToDate
        /// Installed and active on disk; `nil` is a `rollbackToBundled` directive.
        case installed(RuntimeSpiderPack?)
        case rejected(RuntimePackRejection)
        /// The network, not the pack: try again later.
        case failed(String)
    }

    public enum FetchError: Error, Equatable {
        case notFound
        case tooLarge(Int)
        case status(Int)
    }

    /// Downloads at most `limit` bytes of `url`.
    public typealias Fetch = @Sendable (_ url: URL, _ limit: Int) async throws -> Data

    public static let shared = RuntimePackUpdater()

    private let store: RuntimePackStore
    private let fetch: Fetch

    public init(store: RuntimePackStore = .shared, fetch: Fetch? = nil) {
        self.store = store
        self.fetch = fetch ?? Self.download
    }

    public func check(_ scope: RuntimeScope, source: ConfigSource, host: RuntimeHost = .installed(),
                      trust: RuntimeTrustRoot = .bundled, now: Date = Date()) async -> Outcome {
        guard let url = RuntimePackChannel.manifestURL(for: scope, source: source) else { return .noPack }
        do {
            let manifest: Data
            do {
                manifest = try await fetch(url, RuntimePackLimits.manifestBytes)
            } catch FetchError.notFound {
                return .noPack
            } catch FetchError.tooLarge(let bytes) {
                return .rejected(.manifestTooLarge(bytes))
            }
            var signature: Data?
            if scope == .global {
                signature = try? await fetch(url.appendingPathExtension("sig"), RuntimePackLimits.signatureBytes)
            }
            let state = await store.state(for: scope)
            let candidate = try RuntimePackValidator.validate(
                manifest: manifest, signature: signature, fetchedFrom: url, scope: scope,
                configurationURL: source.baseURL, host: host, trust: trust,
                revokedKeyIds: Set(state?.revokedKeyIds ?? []), now: now)
            switch (state ?? RuntimeScopeState(scope: scope, packId: candidate.manifest.packId)).admission(of: candidate) {
            case .accept: break
            case .unchanged: return .upToDate
            case .reject(let rejection): return .rejected(rejection)
            }

            var files = [String: Data]()
            for file in candidate.manifest.files {
                guard let blob = RuntimePackChannel.blobURL(file.sha256, beside: url) else {
                    return .rejected(.invalidPath(file.path))
                }
                do {
                    files[file.path] = try await fetch(blob, file.bytes)
                } catch FetchError.notFound {
                    return .rejected(.fileMissing(file.path))
                } catch FetchError.tooLarge(let bytes) {
                    return .rejected(.fileTooLarge(path: file.path, bytes: bytes))
                }
            }
            return .installed(try await store.install(candidate, manifest: manifest, signature: signature, files: files))
        } catch let rejection as RuntimePackRejection {
            return .rejected(rejection)
        } catch FetchError.status(let code) {
            return .failed("HTTP \(code)")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Neither a cached copy nor a cookie: a hash-pinned download must never be served a stale
    /// body, and a pack's origin gets no state from the App (K15). Longer than the 10 s a content
    /// request gets, since a slow link should still finish a 2 MiB pack.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    /// The same streaming ceiling drpy's engine download uses: reading stops at `limit`, so an
    /// oversized or endless body is abandoned instead of buffered.
    private static let download: Fetch = { url, limit in
        do {
            return try await DrpyEngine.download(url, limit: limit, session: session)
        } catch DrpyError.transport(_, let code) {
            throw code == 404 ? FetchError.notFound : FetchError.status(code)
        } catch DrpyError.tooLarge(_, let bytes, _) {
            throw FetchError.tooLarge(bytes)
        }
    }
}
