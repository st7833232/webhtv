import Foundation

/// IOS-POC-12. Everything a runtime pack is allowed to depend on in this build, as compile-time
/// constants, so a pack can be judged against the App that is actually installed rather than
/// against a guess.
///
/// **Native Core vs Dynamic Runtime.** The App binary owns every executable, framework, primitive,
/// entitlement and screen; those change only with a new IPA through SideStore. A runtime pack owns
/// interpreted scripts and data that run *on* those primitives. This type is the line between the
/// two: a pack names the surfaces and capabilities it needs, and a build that lacks any of them
/// refuses the pack before a single file is fetched (`RuntimePackValidator`).
///
/// **Why constants, not `Info.plist` or a resource.** A version kept in a mutable resource drifts
/// silently, and the drift looks exactly like "no update" (docs/IOS-POC-12, R24). A constant is part
/// of the code that implements the surface, and `RuntimeABITests` fingerprints every file and
/// primitive each surface is made of: changing one without bumping its version here fails the tests.
public enum RuntimeABI {
    /// `major` changes when something is removed or changes meaning; `minor` when something is
    /// added. A requirement is met by the same major with a minor at least as large (SemVer).
    public struct Version: Hashable, Sendable, Comparable, CustomStringConvertible {
        public let major: Int
        public let minor: Int

        public init(_ major: Int, _ minor: Int) {
            self.major = major
            self.minor = minor
        }

        public static func < (lhs: Version, rhs: Version) -> Bool {
            (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
        }

        public var description: String { "\(major).\(minor)" }
    }

    /// The contracts downloaded content can touch. Playback, watch history, persistence and the
    /// native player options are deliberately absent: a pack cannot reach them, so they version
    /// with the IPA and are frozen only by their own tests.
    public enum Surface: String, CaseIterable, Sendable {
        /// The `SpiderRuntime` methods the App calls and the CatVod JSON it decodes from them.
        case catvodResult = "catvod.result"
        /// `host.js`, the native `__http`/`__crypto`/`__store`/`__util` primitives under it, the
        /// drpy and CatVod JS bridges, and `DrpyEngine.moduleRuntime`.
        case jsHost = "js.host"
        /// The bundled CPython, `base.spider.Spider`, `webhtv_runtime` and the vendored wheels.
        case pythonHost = "python.host"
        /// Recorded for completeness, never requirable: a WebHome page is bundled, not delivered.
        case webhomeBridge = "webhome.bridge"

        public var version: Version {
            switch self {
            // 1.0 is the state frozen at 0.1.31 (32); older IPAs carry no runtime ABI at all.
            case .catvodResult: Version(1, 0)
            // Minor 1 continues the retired schema-1 compatibility pack's host API 1 (IOS-POC-13
            // removed that format), so the number a script was written against never went back.
            case .jsHost: Version(1, 1)
            case .pythonHost: Version(1, 0)
            case .webhomeBridge: Version(1, 0)
            }
        }

        /// Whether a manifest may list it in `requires.abi`.
        public var isRequirable: Bool { self != .webhomeBridge }
    }

    /// Named native primitives a pack may require by name, one per thing a script can actually
    /// call or rely on being called. A pack needing something outside this set — RSA, `proxy`, a
    /// WebView primitive — is refused as needing a newer App instead of failing mid-call.
    ///
    /// Not hand-picked: `RuntimeABITests` derives each group from the real thing — the keys of
    /// `host.js`'s exported `host`, the `runtime.` calls `SpiderSession` makes, and the wheels in
    /// `third_party/python-ios-lock.json` — and fails when this list and reality disagree.
    public static let capabilities: Set<String> = Set(
        catvodMethods.map { "catvod.result.\($0)" }
        + jsHostExports.map { "js.host.\($0)" }
        + pythonPackages.map { "python.host.\($0)" }
    )

    /// The eight of `SpiderRuntime`'s thirteen methods with a production caller. `liveContent`,
    /// `isVideoFormat`, `manualVideoCheck`, `proxy` and `action` exist in the protocol but nothing
    /// calls them, so a spider that relies on them is not supported.
    static let catvodMethods = [
        "initialize", "homeContent", "homeVideoContent", "categoryContent",
        "detailContent", "searchContent", "playerContent", "destroy",
    ]

    static let jsHostExports = [
        "req", "get", "post", "encodeForm", "enc", "dec", "base64",
        "aesDecrypt", "aesEncrypt", "desDecrypt", "aesEncryptIV", "aesDecryptIV",
        "md5", "sha1", "sha256", "hmac", "local", "now", "timestamp", "random", "match",
        "parse", "select", "text", "pdfh", "pdfa", "pd", "urljoin",
        "cut", "cut1", "stripTags", "parseJSON", "result",
    ]

    static let pythonPackages = ["requests", "urllib3", "certifi", "idna", "charset-normalizer"]

    /// The bundled scripts that *are* the SDK rather than spiders on it. Native Core: a pack can
    /// never replace them, because replacing one would change what every version number above
    /// means. `SpiderRegistry.bundledOnly` loads them as the prelude and the two bridges, and a
    /// runtime pack may not name a class after any of them.
    public static let nativeScripts: Set<String> = ["host.js", "drpy-bridge.js", "js-spider.js"]
}
