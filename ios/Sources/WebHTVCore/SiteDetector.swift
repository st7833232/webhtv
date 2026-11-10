import Foundation

/// W-277 (design W-275 §4.1–4.3, plan B): which MacCMS collection API a typed address offers, proven by
/// fetching its home and one title's detail through `CMSClient`, the same client the site will use.
///
/// One candidate at a time and never a search (E8: searching is the expensive call on a MacCMS server).
/// GET only, no credentials; a verification page, a closed API or a paid one is reported, never worked around.
public struct SiteDetector: Sendable {
    public enum Format: String, Sendable {
        case given, v10JSON, v10XML, v8JSON, v8XML

        public var label: String {
            switch self {
            case .given: "輸入的介面網址"
            case .v10JSON: "苹果CMS v10 JSON"
            case .v10XML: "苹果CMS v10 XML"
            case .v8JSON: "苹果CMS v8 JSON"
            case .v8XML: "苹果CMS v8 XML"
            }
        }
    }

    public struct Candidate: Equatable, Sendable {
        public let url: URL
        /// 0 for XML, 1 for JSON: the TVBox type the site is added as.
        public let type: Int
        public let format: Format

        public var label: String { format == .given ? "\(format.label)（\(type == 0 ? "XML" : "JSON")）" : format.label }
    }

    public enum Failure: Error, Equatable, Sendable {
        case closed, unauthorized, challenge, empty, timeout, network, notCMS, noTitles, noEpisodes
        case http(Int)

        public var message: String {
            switch self {
            case .closed: "站方關閉了採集介面"
            case .unauthorized: "收費介面，這個網域未授權"
            case .challenge: "需要人機驗證，不支援"
            case .empty: "回應是空白"
            case .timeout: "逾時"
            case .network: "連不上"
            case .notCMS: "不是苹果CMS 介面"
            case .noTitles: "介面有回應，但沒有任何影片"
            case .noEpisodes: "影片詳情沒有線路或集數"
            case .http(let status): "HTTP \(status)"
            }
        }
    }

    public struct Attempt: Equatable, Sendable {
        public let candidate: Candidate
        /// Nil: this candidate passed.
        public let failure: Failure?
    }

    /// What the preview shows (§4.5) and what is added.
    public struct Found: Sendable {
        public let candidate: Candidate
        public let categoryCount: Int
        /// The listing entry, for 試播第一集 (`VodView` opens it like any title).
        public let firstTitle: Vod
        public let lineCount: Int
        public let episodeCount: Int
        /// The first episode is a media file; otherwise it needs sniffing or a parse and may not play.
        public let isDirect: Bool

        public var isInsecure: Bool { candidate.url.scheme == "http" }
    }

    public enum Outcome: Sendable {
        case found(Found)
        case failed([Attempt])
        case invalidInput
    }

    let session: URLSession
    let budget: Duration

    /// §4.3: 10 s per request (`URLSession.webHTV`), 45 s for the whole round.
    public init(session: URLSession = .webHTV, budget: Duration = .seconds(45)) {
        self.session = session
        self.budget = budget
    }

    /// §4.1–4.2, in order. No scheme typed: every https candidate, then every http one. Nil when the input is
    /// not an http(s) address.
    // shortcut: a site under a sub-path (`/m/`) is only tried at its origin; add `{origin}{path}` candidates if a real site needs it.
    public static func candidates(for input: String) -> [Candidate]? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedScheme = text.range(of: "://").map { text[..<$0.lowerBound].lowercased() }
        let schemes: [String]
        switch typedScheme {
        case nil: schemes = ["https", "http"]
        case "http"?, "https"?: schemes = [typedScheme!]
        default: return nil
        }
        let rest = typedScheme == nil ? text : String(text[text.range(of: "://")!.upperBound...])
        var result: [Candidate] = []
        for scheme in schemes {
            guard var components = URLComponents(string: scheme + "://" + rest), let host = components.host, !host.isEmpty
            else { return nil }
            components.fragment = nil
            let origin = scheme + "://" + host + (components.port.map { ":\($0)" } ?? "")
            let path = components.percentEncodedPath.lowercased()
            var round: [Candidate] = []
            if ["provide/vod", "api.php", "inc/api"].contains(where: path.contains), let url = components.url {
                let xml = url.absoluteString.lowercased().contains("xml") || path.hasSuffix("/inc/api.php")
                round.append(Candidate(url: url, type: xml ? 0 : 1, format: .given))
            }
            let standard: [(String, Int, Format)] = [
                ("/api.php/provide/vod/", 1, .v10JSON), ("/api.php/provide/vod/at/xml/", 0, .v10XML),
                ("/inc/apijson_vod.php", 1, .v8JSON), ("/inc/api.php", 0, .v8XML),
            ]
            for (suffix, type, format) in standard {
                guard let url = URL(string: origin + suffix), !round.contains(where: { $0.url == url }) else { continue }
                round.append(Candidate(url: url, type: type, format: format))
            }
            result += round
        }
        return result
    }

    /// §4.3 shape check on the candidate's own reply. Nil: it looks like the API it was asked as. Checked
    /// before the shape, because both answer 200 `text/html` (E2): `closed` and the paid API's refusal.
    public static func judge(_ data: Data, status: Int, xml: Bool) -> Failure? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = (200...299).contains(status)
        if text.isEmpty { return ok ? .empty : .http(status) }
        if text == "closed" { return .closed }
        if text.contains("域名未授权") { return .unauthorized }
        let lower = text.lowercased()
        if ok, xml ? lower.contains("<rss") && (lower.contains("<list") || lower.contains("<class")) : jsonShape(data) {
            return nil
        }
        // E7: a page that is not the API but asks a person to prove themselves.
        let markers = ["cf-chl", "cf-browser-verification", "challenge-platform", "just a moment", "captcha", "验证", "驗證", "人机"]
        if markers.contains(where: lower.contains) { return .challenge }
        return ok ? .notCMS : .http(status)
    }

    /// `code` 1 or absent, and a non-empty `class` or a `list` array.
    static func jsonShape(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let code = object["code"], "\(code)" != "1" { return false }
        return !((object["class"] as? [Any]) ?? []).isEmpty || object["list"] is [Any]
    }

    /// The first candidate that passes; `progress` hears every attempt as it ends. Stops at the budget, and
    /// when the task is cancelled (the viewer's 取消).
    public func detect(_ input: String, progress: @Sendable (Attempt) -> Void = { _ in }) async -> Outcome {
        guard let candidates = Self.candidates(for: input) else { return .invalidInput }
        let deadline = ContinuousClock.now + budget
        var attempts: [Attempt] = []
        var unreachable: Set<String> = []
        for candidate in candidates {
            guard !Task.isCancelled else { break }
            // An origin that timed out or could not be reached will not answer its other paths either.
            let origin = (candidate.url.scheme ?? "") + "://" + (candidate.url.host ?? "")
            guard !unreachable.contains(origin) else { continue }
            guard ContinuousClock.now < deadline else {
                attempts.append(Attempt(candidate: candidate, failure: .timeout))
                progress(attempts.last!)
                break
            }
            do {
                let found = try await verify(candidate)
                progress(Attempt(candidate: candidate, failure: nil))
                return .found(found)
            } catch {
                let failure = error as? Failure ?? .network
                if failure == .timeout || failure == .network { unreachable.insert(origin) }
                attempts.append(Attempt(candidate: candidate, failure: failure))
                progress(attempts.last!)
            }
        }
        return .failed(attempts)
    }

    /// §4.3: the shape, then home and one title's detail through `CMSClient`, which must give a line with an episode.
    func verify(_ candidate: Candidate) async throws -> Found {
        do {
            let (data, response) = try await session.data(from: candidate.url)
            if let failure = Self.judge(data, status: (response as? HTTPURLResponse)?.statusCode ?? 200, xml: candidate.type == 0) {
                throw failure
            }
            guard let site = LocalSite(name: "", type: candidate.type, api: candidate.url.absoluteString, detectedFrom: "")?.site
            else { throw Failure.notCMS }
            let client = try CMSClient(site: site, session: session)
            let home = try await client.home()
            func playable(_ list: [Vod]) -> Vod? { list.first { !$0.id.isEmpty && !$0.isFolder } }
            var first = playable(home.list)
            if first == nil, let category = home.firstListableCategory {
                first = playable(try await client.category(id: category.id).list)
            }
            guard let first else { throw Failure.noTitles }
            let flags = (try await client.detail(id: first.id))?.flags.filter { !$0.episodes.isEmpty } ?? []
            guard let line = flags.first, let episode = line.episodes.first else { throw Failure.noEpisodes }
            return Found(candidate: candidate, categoryCount: home.classes.count, firstTitle: first, lineCount: flags.count,
                         episodeCount: line.episodes.count, isDirect: episode.mediaURL.map(CMSClient.isDirectMedia) ?? false)
        } catch let failure as Failure {
            throw failure
        } catch CMSClientError.invalidHTTPStatus(let status) {
            throw Failure.http(status)
        } catch let error as URLError {
            throw error.code == .timedOut ? Failure.timeout : Failure.network
        } catch is DecodingError {
            throw Failure.notCMS
        }
    }
}
