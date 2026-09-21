import Foundation
import Libmpv

/// Creates a libmpv context once and reports what came up.
///
/// This lives in the app target for the same hard reason `PythonBoot` does: MPVKit ships iOS-only
/// xcframeworks, and `WebHTVCore` has to keep building and testing on macOS, where the 151 existing
/// tests run. Nothing that links libmpv may sit below this line.
///
/// IOS-POC-9B starts with the boot alone, because it answers the one question no macOS test can:
/// does libmpv link and initialise inside *this* app. Rendering, `PlayerRouter` and the
/// `PlaybackSession` integration are separate units and are deliberately not here — a router
/// between one real engine and a stub is an interface with one implementation.
enum MPVBoot {
    /// What libmpv reported, or why it did not start. Computed once during launch, before anything
    /// concurrent exists — the same `nonisolated(unsafe)` this codebase already uses for launch-time
    /// shared state in `CSPSourceResolver` and `PythonBoot`.
    nonisolated(unsafe) private(set) static var status: Status?

    enum Status: Equatable {
        case running(version: String, apiVersion: String)
        case failed(String)
    }

    @discardableResult
    static func start() -> Status {
        if let status { return status }
        let result = boot()
        status = result
        return result
    }

    private static func boot() -> Status {
        let api = mpv_client_api_version()
        let apiVersion = "\(api >> 16).\(api & 0xFFFF)"

        guard let ctx = mpv_create() else {
            return .failed("mpv_create returned nil")
        }
        defer { mpv_terminate_destroy(ctx) }

        let rc = mpv_initialize(ctx)
        guard rc >= 0 else {
            return .failed("mpv_initialize: \(errorText(rc))")
        }

        guard let raw = mpv_get_property_string(ctx, "mpv-version") else {
            return .failed("mpv-version was not readable")
        }
        let version = String(cString: raw)
        mpv_free(raw)

        // Negative control. Without it a stubbed-out or short-circuited client library would look
        // exactly like a working one — the lesson IOS-POC-7F recorded when a `PyRun_SimpleString`
        // that executed nothing was indistinguishable from success. A property that does not exist
        // must be reported as an error, not answered.
        if mpv_get_property_string(ctx, "webhtv-no-such-property") != nil {
            return .failed("negative control failed: an unknown property was answered")
        }

        return .running(version: version, apiVersion: apiVersion)
    }

    private static func errorText(_ code: Int32) -> String {
        guard let text = mpv_error_string(code) else { return "error \(code)" }
        return "\(String(cString: text)) (\(code))"
    }
}
