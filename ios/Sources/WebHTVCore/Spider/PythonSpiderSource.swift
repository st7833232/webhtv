import Foundation

/// Where a Python spider's script comes from, and who is allowed to run one.
///
/// The transport rules are the configuration's, not any one engine's: same origin as the
/// configuration, HTTPS only, a hard size ceiling, and every failure closed. They are the rules
/// IOS-POC-6B set for drpy, and they are reused here rather than restated — including the
/// implementations, so the two cannot drift apart.
///
/// IOS-POC-7H.
public enum PythonSpiderSource {
    /// 256 KB. Measured 2026-09-21 across all 31 same-origin `.py` scripts in the user's
    /// configuration: 569 KB in total, and the largest single script — `油管-6.py` — is 93.7 KB.
    public static let maximumScriptBytes = 256 * 1024

    public enum Failure: Error, Equatable, LocalizedError {
        case noRemoteConfiguration
        case rejected(reference: String, reason: String)
        case notText(String)
        case noRuntime

        public var errorDescription: String? {
            switch self {
            case .noRemoteConfiguration:
                "A Python source needs a remote configuration: an imported file has no origin to check against."
            case .rejected(let reference, let reason):
                "Refused to load \(reference): \(reason)"
            case .notText(let name):
                "\(name) did not decode as UTF-8 text"
            case .noRuntime:
                "This build has no Python interpreter"
            }
        }
    }

    /// Fetches one script, or refuses and says why.
    ///
    /// An imported configuration file has no origin, so it can never satisfy the same-origin rule
    /// and a Python site is refused outright rather than fetched from wherever the path points.
    public static func script(for site: Site, source: ConfigSource,
                              session: URLSession = .webHTV) async throws -> String {
        guard let origin = source.baseURL else { throw Failure.noRemoteConfiguration }
        guard let resolved = source.resourceURL(for: site.api) else {
            throw Failure.rejected(reference: site.api, reason: "the path does not resolve against the configuration")
        }
        let url: URL
        do {
            // Same host, same port, HTTPS on both sides. The three cross-origin scripts in the
            // user's configuration — two of them plain HTTP — are refused here, by design, and
            // coverage is not a reason to relax it.
            url = try DrpyEngine.checked(resolved, origin: origin)
        } catch {
            throw Failure.rejected(reference: site.api, reason: String(describing: error))
        }
        let data: Data
        do {
            data = try await DrpyEngine.download(url, limit: maximumScriptBytes, session: session)
        } catch {
            throw Failure.rejected(reference: site.api, reason: String(describing: error))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw Failure.notText(url.lastPathComponent)
        }
        return text
    }
}

/// The seam that lets a Python site route without this package linking an interpreter.
///
/// `WebHTVCore` builds and tests on macOS, where the CPython XCFramework has no slice, so core
/// cannot construct a `PythonSpiderRuntime` — the app installs one at launch. Until it does,
/// `isAvailable` is false and a Python site is **not offered at all**, rather than offered and
/// failing when it is opened.
public enum PythonSpiderSupport {
    public typealias Factory = @Sendable (_ script: String, _ siteKey: String) throws -> SpiderRuntime

    nonisolated(unsafe) public static var makeRuntime: Factory?

    public static var isAvailable: Bool { makeRuntime != nil }

    public static func runtime(script: String, siteKey: String) throws -> SpiderRuntime {
        guard let makeRuntime else { throw PythonSpiderSource.Failure.noRuntime }
        return try makeRuntime(script, siteKey)
    }
}
