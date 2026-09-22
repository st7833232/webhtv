import Foundation
import Testing
@testable import WebHTVCore

/// IOS-POC-10K. A failure the viewer can read.
///
/// The bug these pin is easy to reintroduce and invisible in code review: an `Error` enum with a
/// perfectly good `description` still shows `(Module.Type error 0.)` on screen, because
/// `localizedDescription` only consults `LocalizedError`.
@Suite struct ErrorMessageTests {
    /// The exact shape the user was shown on device, so a regression is recognisable.
    private func isSwiftFallback(_ text: String) -> Bool {
        text.contains("couldn’t be completed") || text.contains("couldn't be completed")
    }

    @Test func drpyFailuresSayWhatWentWrong() {
        let cases: [DrpyError] = [
            .noRemoteConfiguration,
            .unresolvable("./drpy_libs/drpy2.min.js"),
            .insecureURL("http://x.example/a.js"),
            .crossOrigin("https://other.example/a.js"),
            .transport("drpy2.min.js", 404),
            .tooLarge("a.js", 900, 100),
            .hashMismatch("a.js", expected: "aa", actual: "bb"),
            .notText("a.js"),
        ]
        for failure in cases {
            let shown = (failure as Error).localizedDescription
            #expect(!isSwiftFallback(shown), "still the generic fallback: \(shown)")
            #expect(!shown.isEmpty)
        }
    }

    @Test func theCaseTheUserHitNamesItsCause() {
        let shown = (DrpyError.noRemoteConfiguration as Error).localizedDescription
        #expect(shown.contains("遠端設定檔"))
    }

    @Test func cmsFailuresSayWhatWentWrong() {
        for failure in [CMSClientError.unsupportedSiteType(9), .invalidURL, .invalidHTTPStatus(500)] {
            let shown = (failure as Error).localizedDescription
            #expect(!isSwiftFallback(shown), "still the generic fallback: \(shown)")
        }
        #expect((CMSClientError.invalidHTTPStatus(503) as Error).localizedDescription.contains("503"))
    }

    /// The log-facing text is deliberately unchanged, and English like the rest of the codebase.
    @Test func theLogStillGetsItsEnglish() {
        #expect(DrpyError.noRemoteConfiguration.description.contains("drpy needs a remote configuration"))
    }
}
