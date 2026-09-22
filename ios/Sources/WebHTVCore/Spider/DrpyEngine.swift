import CryptoKit
import Foundation

/// Loads the drpy JavaScript engine and the libraries it imports, and refuses to hand back anything
/// it has not verified.
///
/// **This is a loader, not a second runtime.** What it produces is a prelude string; the thing that
/// runs it is the same `JavaScriptSpiderRuntime`, the same `JSContext`, the same `CatVodHost` every
/// ported `csp_*` spider uses. A drpy site adds no native capability: no bridge, no file system, no
/// entitlement, no shell. It sees exactly what a spider sees.
///
/// **Why the engine is pinned and a site's rule script is not.** IOS-POC-5O already drew this line
/// for `csp_*`: a compatibility pack may replace a *spider script* at runtime, but `host.js` — the
/// SDK those scripts run against — is deliberately not packable, because changing the SDK is an app
/// release. drpy2 and its nine libraries are that same kind of thing: they are the engine a site's
/// rules run *against*, roughly a megabyte of third-party bundles that change rarely. So they are
/// pinned to this build by SHA-256 and a mismatch refuses the site outright. A site's own rule
/// script is the spider-equivalent — kilobytes, changing often — and stays hot-updatable under the
/// same same-origin, HTTPS and size rules the rest of the configuration already lives by.
///
/// Pinning therefore costs no hot-update ability that IOS-POC-5O promised; it only puts the engine
/// on the side of the line `host.js` is already on.
///
/// Every failure is closed: a non-HTTPS URL, a cross-origin URL, an oversized body, a hash that does
/// not match, a transport error or a syntax error after rewriting all mean *this site does not run*.
/// None of them degrades into evaluating unverified code.
public enum DrpyEngine {
    /// One pinned file: what it is, how big it was, and what it must hash to.
    ///
    /// The byte count is recorded as provenance rather than as a second gate — a wrong length cannot
    /// survive the hash. The limits below are what actually bound resource use, because they stop a
    /// hostile or broken server *before* a body is buffered.
    public struct Dependency: Sendable, Equatable {
        /// The file's name inside the configuration's `drpy_libs/` directory.
        public let file: String
        public let bytes: Int
        public let sha256: String

        public init(file: String, bytes: Int, sha256: String) {
            self.file = file
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    /// Where the engine and its libraries live, relative to the configuration.
    ///
    /// drpy2 imports two of them through `assets://js/lib/…`, which is how the Android app reaches
    /// its own bundled copies. This configuration carries the same files here, so the `assets://`
    /// scheme is mapped to this directory and **no third-party code is vendored into this
    /// repository**.
    public static let directory = "./drpy_libs/"

    /// Caps that bound resource use before a body is buffered. The real engine is 1,194 KB across
    /// ten files, the largest of them cheerio at 349 KB.
    public static let maximumFileBytes = 512 * 1024
    public static let maximumBundleBytes = 2 * 1024 * 1024
    /// A site's rule script is not hash-pinned, so for it this cap is the only bound. The largest
    /// real one is 12 KB.
    public static let maximumRuleBytes = 256 * 1024

    /// The engine's dependency graph in evaluation order: every library first, the engine last.
    ///
    /// Measured 2026-09-18 against `https://gitlab.com/st7833232/recha/-/raw/main/drpy_libs/`.
    /// None of these files imports another, which is why a flat list is a valid order. If the
    /// configuration's copies ever change, every drpy site stops working with a hash mismatch
    /// naming the file — which is the intended behaviour, not a regression to fix by relaxing it.
    public static let dependencies: [Dependency] = [
        .init(file: "cheerio.min.js", bytes: 356_593,
              sha256: "f03171a4d979593c59dff2267b4beee8aaedd1a0af04f34f9984bdf5f7bdeade"),
        .init(file: "crypto-js.js", bytes: 204_310,
              sha256: "731c9606953ddedd5bafe52e32eeced73f2a3750fbdac3c812b4a04881e48c07"),
        .init(file: "jsencrypt.js", bytes: 217_423,
              sha256: "dfba3a7905507484399622e0938cd5462a44c913450927ea8c3eb760d57660dd"),
        .init(file: "node-rsa.js", bytes: 167_481,
              sha256: "b2e1d9c402ce06c19d08e1659624bfbbda91994d06339300970c395977e6d37c"),
        .init(file: "pako.min.js", bytes: 46_859,
              sha256: "7b7a3b8db4d7b65846b807f1309688a8955961dbde5538694862a6c5cbc932cf"),
        .init(file: "模板.js", bytes: 20_033,
              sha256: "0f6874dc6d19aa9fb71125780bc3ffd349ef7be80032f95a76985a1f1ac8cbf2"),
        .init(file: "gbk.js", bytes: 56_246,
              sha256: "cf46ccf34d32ce873f021fc5e94c43a73afcb7a551004be8d6a02e94986d0696"),
        .init(file: "json5.js", bytes: 60_431,
              sha256: "1b3d54f76b9106641e540b6561dc950ffe281590f8546b88f26fc7a91c225e10"),
        .init(file: "jinja.js", bytes: 22_706,
              sha256: "6cf1781f0c32206236049d392383dbc558b530244926d93762dfa3362967bff2"),
        .init(file: "drpy2.min.js", bytes: 71_463,
              sha256: "cbfd7b23f86b07f8fa55ba85aae66af430b2a1c5501160f8867e1852661adba2"),
    ]

    // MARK: - Origin

    /// A drpy site may only load from the configuration's own origin, over HTTPS.
    ///
    /// This is what stops a rule script or an import from reaching an arbitrary host: the engine is
    /// as trusted as the configuration and no more. `NSAllowsArbitraryLoads` ships for playback
    /// hosts and does not relax this — the check is ours, not the transport's.
    static func checked(_ url: URL, origin: URL) throws -> URL {
        guard url.scheme?.lowercased() == "https" else { throw DrpyError.insecureURL(url.absoluteString) }
        guard let host = url.host?.lowercased(), let base = origin.host?.lowercased(),
              host == base, url.port == origin.port,
              origin.scheme?.lowercased() == "https" else {
            throw DrpyError.crossOrigin(url.absoluteString)
        }
        return url
    }

    /// Resolves one of the engine's files against the configuration, then origin-checks it.
    public static func url(for file: String, source: ConfigSource) throws -> URL {
        guard let origin = source.baseURL else { throw DrpyError.noRemoteConfiguration }
        guard let url = source.resourceURL(for: directory + file) else {
            throw DrpyError.unresolvable(file)
        }
        return try checked(url, origin: origin)
    }

    // MARK: - Fetch and verify

    /// Downloads with a hard ceiling, so an oversized or endless body is abandoned rather than
    /// buffered. `URLSession.data(from:)` would have the whole thing in memory before anyone could
    /// object, which is the failure this cap exists to prevent.
    static func download(_ url: URL, limit: Int, session: URLSession) async throws -> Data {
        let (stream, response) = try await session.bytes(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DrpyError.transport(url.lastPathComponent, http.statusCode)
        }
        if response.expectedContentLength > Int64(limit) {
            throw DrpyError.tooLarge(url.lastPathComponent, Int(response.expectedContentLength), limit)
        }
        var data = Data()
        data.reserveCapacity(min(limit, 1 << 20))
        for try await byte in stream {
            data.append(byte)
            if data.count > limit { throw DrpyError.tooLarge(url.lastPathComponent, data.count, limit) }
        }
        return data
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Fetches one pinned dependency and refuses it unless the bytes hash to what this build
    /// approved. There is no warn-and-continue path.
    static func load(_ dependency: Dependency, source: ConfigSource,
                     session: URLSession) async throws -> String {
        let url = try url(for: dependency.file, source: source)
        let data = try await download(url, limit: maximumFileBytes, session: session)
        let actual = digest(data)
        guard actual == dependency.sha256 else {
            throw DrpyError.hashMismatch(dependency.file, expected: dependency.sha256, actual: actual)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw DrpyError.notText(dependency.file)
        }
        return text
    }

    // MARK: - ES modules

    /// Four of the ten files are ES modules, in four narrow shapes. This rewrites those shapes into
    /// plain script and leaves everything else alone.
    ///
    /// ponytail: a rewrite for the shapes these files actually use, **not** an ES module loader.
    /// JavaScriptCore has `JSScript` and a module-loader delegate, but the dependency graph here is
    /// ten static files that import nothing from each other, so a loader would be machinery for a
    /// problem nobody has. **The residual check is the engine's own parser**: anything this fails to
    /// rewrite is still module syntax, `evaluateScript` raises a SyntaxError, and the site fails
    /// closed — which is a better detector than a scanner that cannot tell code from the word
    /// "import" inside one of cheerio's string literals.
    ///
    /// Each module is wrapped in a function so its top-level names stay its own. Sharing one global
    /// scope would have cheerio's minified `var e,t` collide with the engine's. The wrapper is
    /// deliberately not strict: the UMD bundles among these detect their host through a sloppy-mode
    /// `this`, and sloppy code breaks under strict far more often than the reverse.
    static func rewritten(_ source: String, named module: String) -> String {
        var text = source
        var exported = [String]()

        // Every pattern is anchored to a statement boundary — start of file, `;`, `}` or a newline —
        // and re-emits whatever it matched. Without that anchor the side-effect form matched
        // `expected import"` **inside one of cheerio's string literals** and replaced a few hundred
        // characters of real code with a semicolon, which surfaced as a `break` outside a loop.
        // Module syntax only ever appears at a statement boundary, so this costs nothing real.
        //
        // The import forms deliberately do **not** consume their trailing `;`. drpy2 puts all nine
        // imports on one line, so eating the separator would leave the next one without the anchor
        // it needs and the scan does not revisit text it has already replaced.

        // `import {a, b} from "path";` → destructure the module object.
        text = text.replacing(#/(^|[;\n}])\s*import\s*\{([^}]*)\}\s*from\s*["']([^"']+)["']/#) { match in
            "\(match.1)var {\(match.2)} = __drpyModule(\"\(match.3)\")"
        }
        // `import X from "path";` → the module's default export.
        text = text.replacing(#/(^|[;\n}])\s*import\s+([\p{L}_$][\p{L}\p{N}_$]*)\s+from\s*["']([^"']+)["']/#) { match in
            "\(match.1)var \(match.2) = __drpyDefault(\"\(match.3)\")"
        }
        // `import "path";` — side effect only, and the file is already in the prelude above.
        text = text.replacing(#/(^|[;\n}])\s*import\s*["'][^"']+["']/#) { match in
            "\(match.1)void 0"
        }

        // `export {a as b, c as default};` → one object literal under this module's name.
        text = text.replacing(#/(^|[;\n}])\s*export\s*\{([^}]*)\}\s*;?/#) { match in
            let pairs = match.2.split(separator: ",").compactMap { entry -> String? in
                let parts = entry.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard let local = parts.first else { return nil }
                let name = parts.count >= 3 && parts[1] == "as" ? parts[2] : local
                return "\"\(name)\": \(local)"
            }
            return "\(match.1)__drpyExport(\"\(module)\", {\(pairs.joined(separator: ", "))});"
        }
        // `export function f(…)` — keep the declaration, register the name afterwards.
        for match in text.matches(of: #/(?:^|[;\n}])\s*export\s+function\s+([\p{L}_$][\p{L}\p{N}_$]*)/#) {
            exported.append(String(match.1))
        }
        text = text.replacing(#/(^|[;\n}])\s*export\s+function\s+/#) { match in
            "\(match.1)function "
        }
        // `export default <expression>` — a plain assignment, so the expression's own terminator
        // still terminates it. Wrapping it in a call would need a closing paren this cannot place
        // without knowing where the expression ends.
        text = text.replacing(#/(^|[;\n}])\s*export\s+default\s*/#) { match in
            "\(match.1)globalThis.__drpyModules[\"\(module)\"] = "
        }

        if !exported.isEmpty {
            let pairs = exported.map { "\"\($0)\": \($0)" }.joined(separator: ", ")
            text += "\n__drpyExport(\"\(module)\", {\(pairs)});"
        }
        return "(function(){\n\(text)\n})();"
    }

    /// The two helpers the rewritten modules call, plus the registry they share.
    static let moduleRuntime = """
    globalThis.__drpyModules = globalThis.__drpyModules || {};

    // drpy's host contract puts its selector helpers in the global scope, where the Android host
    // injects them natively. Ours has had them all along under `host.` — `CatVodHost` is where
    // `pdfh`/`pdfa`/`pd` live and where every ported spider already gets them. These are aliases to
    // exactly those functions: no second implementation, no new capability, nothing a `csp_*`
    // spider could not already reach. Assigned only when absent, so a module that brings its own
    // keeps it.
    (function () {
      // `CatVodHost` is always installed before this prelude in production. Guarded so the module
      // rewriter can still be exercised in a bare context without dragging the whole host in.
      if (typeof host === 'undefined') { return; }
      var aliases = {
        pdfh: host.pdfh, pdfa: host.pdfa, pd: host.pd,
        joinUrl: host.urljoin, urljoin: host.urljoin,
        local: host.local
      };
      for (var name in aliases) {
        if (aliases[name] !== undefined && globalThis[name] === undefined) {
          globalThis[name] = aliases[name];
        }
      }
      if (globalThis.print === undefined) { globalThis.print = function () {}; }
      if (globalThis.log === undefined) { globalThis.log = globalThis.print; }

      // drpy's HTTP primitive. `CatVodHost.req` already makes the request — same session, same
      // cookie jar, same timeouts — and answers `{body, json, headers, code}`; drpy reads
      // `res.content`. This maps that one field name. It is not a second HTTP stack and it grants
      // nothing a `csp_*` spider cannot already do.
      if (globalThis.req === undefined) {
        globalThis.req = function (url, options) {
          var res = host.req(url, options || {}) || {};
          res.content = res.body === undefined ? '' : res.body;
          return res;
        };
      }
    })();
    function __drpyKey(path) {
      return String(path).split('/').pop().replace(/\\.js$/, '');
    }
    function __drpyExport(name, value) {
      var existing = globalThis.__drpyModules[name];
      if (existing && typeof existing === 'object' && typeof value === 'object' && value !== null) {
        globalThis.__drpyModules[name] = Object.assign(existing, value);
      } else {
        globalThis.__drpyModules[name] = value;
      }
      return globalThis.__drpyModules[name];
    }
    function __drpyModule(path) {
      var key = __drpyKey(path);
      var found = globalThis.__drpyModules[key];
      // Fail closed rather than hand back undefined and fail somewhere unrecognisable later.
      if (found === undefined) throw new Error('drpy: module not loaded: ' + path);
      return found;
    }
    function __drpyDefault(path) {
      var found = __drpyModule(path);
      return (found && found.default !== undefined) ? found.default : found;
    }
    """

    // MARK: - Assembly

    /// Fetches, verifies and assembles the engine into a prelude for `JavaScriptSpiderRuntime`.
    ///
    /// The bundle ceiling is checked as files arrive, so a graph that grows past it stops early.
    /// The engine's own session. `URLSession.webHTV` caps request inactivity at 10 seconds, which is
    /// right for a content API and marginal for a 349 KB library over a busy Git host — measured
    /// 2026-09-18, cheerio timed out at 10 s against GitLab more than once. A longer ceiling changes
    /// nothing about what is accepted: the size caps and the hash check are what bound this.
    public static let downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration)
    }()

    public static func prelude(source: ConfigSource, host: String,
                               session: URLSession = downloadSession) async throws -> String {
        var parts = [host, moduleRuntime]
        var total = 0
        for dependency in dependencies {
            let text = try await load(dependency, source: source, session: session)
            total += text.utf8.count
            guard total <= maximumBundleBytes else {
                throw DrpyError.tooLarge("bundle", total, maximumBundleBytes)
            }
            let module = dependency.file.replacingOccurrences(of: ".js", with: "")
            parts.append(rewritten(text, named: module))
        }
        return parts.joined(separator: "\n;\n")
    }

    /// A site's own rule script: same origin, same HTTPS rule, its own size cap, **not** hash-pinned.
    /// It is the spider-equivalent here — see the note at the top of this file.
    public static func rule(at reference: String, source: ConfigSource,
                            session: URLSession = downloadSession) async throws -> String {
        guard let origin = source.baseURL else { throw DrpyError.noRemoteConfiguration }
        guard let resolved = source.resourceURL(for: reference) else {
            throw DrpyError.unresolvable(reference)
        }
        let url = try checked(resolved, origin: origin)
        let data = try await download(url, limit: maximumRuleBytes, session: session)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DrpyError.notText(url.lastPathComponent)
        }
        guard !isJavaScriptSpider(text) else {
            throw DrpyError.notADrpyRule(url.lastPathComponent)
        }
        return text
    }

    /// Does this script speak the **CatVod JS spider** contract rather than drpy's?
    ///
    /// IOS-POC-10P. `wang-sex.json`'s 麻豆(js) is `type 3` with a `.js` api, which is all
    /// `isDrpySpider` looks at — so it went to drpy2, which found no `rule` object and answered
    /// every method with nothing. The screen said 「沒有內容」, while the same source plays on
    /// Android TV, because TVBox routes a script like this to its **other** JavaScript runtime.
    ///
    /// The entry point tells them apart. A drpy rule exposes a `rule` object for the engine to
    /// read; a JS spider defines `__jsEvalReturn()` returning
    /// `{init, home, homeVod, category, detail, play, search}` — which is exactly how 麻豆.min.js
    /// ends. Matching that one name is deliberately narrow: it is the function the host has to
    /// call, so a script carrying it is not a drpy rule whatever else is in it.
    ///
    /// **This names the situation; it does not implement the contract.** Quietly showing an empty
    /// list was the worst of the outcomes available.
    static func isJavaScriptSpider(_ script: String) -> Bool {
        script.contains("__jsEvalReturn")
    }
}

/// IOS-POC-10K: `LocalizedError`, not merely `CustomStringConvertible`.
///
/// `description` is what a `print` shows; `localizedDescription` is what the **screen** shows, and
/// Swift does not bridge one to the other. Without this conformance every one of these failures
/// reached the viewer as `The operation couldn't be completed. (WebHTVCore.DrpyError error 0.)` —
/// a type name and a case index, which says nothing to the person holding the phone and not much
/// more to whoever is debugging it.
///
/// The English `description` above is kept as it was: it goes to logs, where English is the rest
/// of this codebase's language. The Chinese below is for the screen.
public enum DrpyError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case noRemoteConfiguration
    case unresolvable(String)
    case insecureURL(String)
    case crossOrigin(String)
    case transport(String, Int)
    case tooLarge(String, Int, Int)
    case hashMismatch(String, expected: String, actual: String)
    case notText(String)
    /// The script is a CatVod/TVBox **JS spider**, not a drpy rule — a different runtime
    /// contract that this app does not implement. See `DrpyEngine.isJavaScriptSpider`.
    case notADrpyRule(String)

    public var description: String {
        switch self {
        case .noRemoteConfiguration:
            "drpy needs a remote configuration: an imported file has no origin to load an engine from"
        case .unresolvable(let reference):
            "drpy could not resolve \(reference) against the configuration"
        case .insecureURL(let url):
            "drpy refuses a non-HTTPS resource: \(url)"
        case .crossOrigin(let url):
            "drpy refuses a resource outside the configuration's own origin: \(url)"
        case .transport(let file, let status):
            "drpy could not fetch \(file): HTTP \(status)"
        case .tooLarge(let file, let bytes, let limit):
            "drpy refuses \(file): \(bytes) bytes exceeds the \(limit) byte limit"
        case .hashMismatch(let file, let expected, let actual):
            "drpy refuses \(file): expected SHA-256 \(expected), got \(actual)"
        case .notText(let file):
            "drpy refuses \(file): not valid UTF-8"
        case .notADrpyRule(let file):
            "\(file) is a CatVod JS spider (__jsEvalReturn), not a drpy rule"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noRemoteConfiguration:
            "這個來源需要遠端設定檔：匯入的本機檔案沒有來源位址，drpy 的引擎無從載入。"
        case .unresolvable(let reference):
            "設定檔裡的參照無法解析：\(reference)"
        case .insecureURL(let url):
            "drpy 只接受 HTTPS，這個位址不是：\(url)"
        case .crossOrigin(let url):
            "drpy 只從設定檔自己的來源載入，這個位址不在同一個來源：\(url)"
        case .transport(let file, let status):
            "抓取 \(file) 失敗，伺服器回應 HTTP \(status)。"
        case .tooLarge(let file, let bytes, let limit):
            "\(file) 太大：\(bytes) 位元組，上限是 \(limit)。"
        case .hashMismatch(let file, _, _):
            "\(file) 的 SHA-256 與內建的不符，已拒絕載入。"
        case .notText(let file):
            "\(file) 不是文字檔，無法當成腳本執行。"
        case .notADrpyRule(let file):
            "\(file) 是 CatVod JS spider（__jsEvalReturn），不是 drpy 規則腳本；本 App 目前只實作 drpy。"
        }
    }
}

/// Keeps the verified engine for the process, so four drpy sites do not fetch 1.2 MB four times and
/// no site re-fetches it per call.
///
/// The cache is **memory only and holds text this process already verified**, so there is no path
/// by which unverified bytes re-enter. A disk cache would need to re-verify every dependency on the
/// way back in; that is the reason there isn't one.
public actor DrpyEngineStore {
    public static let shared = DrpyEngineStore()

    private var preludes = [String: String]()

    public init() {}

    public func prelude(source: ConfigSource, host: String,
                        session: URLSession = DrpyEngine.downloadSession) async throws -> String {
        let key = source.baseURL?.absoluteString ?? ""
        if let cached = preludes[key] { return cached }
        let assembled = try await DrpyEngine.prelude(source: source, host: host, session: session)
        preludes[key] = assembled
        return assembled
    }

    public func reset() {
        preludes.removeAll()
    }
}
