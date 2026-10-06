import Foundation
import JavaScriptCore

/// `host.req` — the one HTTP path every spider uses, with a per-session cookie store.
///
/// Synchronous on purpose. `Spider.java` is blocking Java, so a port reads line for line like the
/// decompiled original and stays auditable against it. Safe because `JavaScriptSpiderRuntime` gives
/// each session its own serial `DispatchQueue` rather than a Swift-concurrency cooperative thread.
enum HTTPHost {
    static func install(into context: JSContext, cookies: CookieJar, trail: NetworkTrail, session: URLSession) {
        let request: @convention(block) (String, [String: Any]?) -> [String: Any] = { url, options in
            perform(url: url, options: options ?? [:], cookies: cookies, trail: trail, session: session)
        }
        let host = JSValue(newObjectIn: context)
        host?.setObject(request, forKeyedSubscript: "request" as NSString)
        context.setObject(host, forKeyedSubscript: "__http" as NSString)
    }

    static func perform(url: String, options: [String: Any], cookies: CookieJar, trail: NetworkTrail,
                        session: URLSession) -> [String: Any] {
        guard let target = URL(string: url) else {
            return ["status": 0, "body": "", "headers": [:], "cookies": "", "url": url, "error": "invalid url"]
        }
        var request = URLRequest(url: target)
        request.httpMethod = (options["method"] as? String)?.uppercased() ?? "GET"
        if let timeout = options["timeout"] as? Double, timeout > 0 { request.timeoutInterval = timeout / 1000 }
        // Redirects follow by default, as OkHttp does; a spider sniffing a 302 opts out.
        let followRedirects = (options["redirect"] as? Bool) ?? true

        for (name, value) in (options["headers"] as? [String: Any]) ?? [:] {
            request.setValue(String(describing: value), forHTTPHeaderField: name)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("okhttp/3.14.9", forHTTPHeaderField: "User-Agent")
        }
        let jarCookies = cookies.header(for: target)
        if !jarCookies.isEmpty, request.value(forHTTPHeaderField: "Cookie") == nil {
            request.setValue(jarCookies, forHTTPHeaderField: "Cookie")
        }
        if let body = options["body"] as? String, !body.isEmpty {
            request.httpBody = Data(body.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }
        // IOS-POC-44G: bytes travel as base64 across the bridge and are never a String on this side,
        // which would replace every byte that is not valid UTF-8.
        if let encoded = options["bodyBase64"] as? String, !encoded.isEmpty,
           let bytes = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]) {
            request.httpBody = bytes
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            }
        }
        let binaryResponse = (options["responseType"] as? String)?.lowercased() == "base64"

        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any] = ["status": 0, "body": "", "headers": [String: String](), "cookies": "", "url": url]
        var failure: SiteFailure?
        let delegate = followRedirects ? nil : NoRedirect()
        let client = delegate.map { URLSession(configuration: session.configuration, delegate: $0, delegateQueue: nil) } ?? session
        let task = client.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { result["error"] = error.localizedDescription; failure = SiteFailure(error: error); return }
            let http = response as? HTTPURLResponse
            var headers = [String: String]()
            for (key, value) in http?.allHeaderFields ?? [:] {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
            if let setCookie = headers["set-cookie"] { cookies.store(setCookie, for: target) }
            result["status"] = http?.statusCode ?? 0
            result["headers"] = headers
            result["cookies"] = cookies.header(for: target)
            result["url"] = (http?.url ?? target).absoluteString
            let body = String(decoding: data ?? Data(), as: UTF8.self)
            result["body"] = binaryResponse ? "" : body
            if binaryResponse { result["bodyBase64"] = (data ?? Data()).base64EncodedString() }
            failure = SiteFailure(status: http?.statusCode ?? 0, headers: headers, body: binaryResponse ? "" : body)
        }
        task.resume()
        let timedOut = semaphore.wait(timeout: .now() + request.timeoutInterval + 5) == .timedOut
        if timedOut {
            task.cancel()
            result["error"] = "timeout"
        }
        trail.record(timedOut ? .timedOut : failure, host: target.host ?? url)
        return result
    }

    /// Lets a spider read a redirect instead of following it, which is how several sniff a media URL.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

/// IOS-POC-41A: the first failed request of the spider call in progress, so an empty answer can say
/// why. Confined to the runtime's serial queue: `JavaScriptSpiderRuntime` resets and reads it around
/// each call, and `perform` writes it from inside that call, on the same queue.
final class NetworkTrail: @unchecked Sendable {
    private(set) var first: SiteUnreachable?

    func reset() { first = nil }

    func record(_ failure: SiteFailure?, host: String) {
        guard first == nil, let failure else { return }
        first = SiteUnreachable(failure, host: host)
    }
}

/// Per-session cookie storage, keyed by host. Two sites running the same spider class never share
/// a login, which is the isolation Android gets from constructing one `Spider` per site.
public final class CookieJar: @unchecked Sendable {
    private var store = [String: [String: String]]()
    private let lock = NSLock()

    public init() {}

    func store(_ setCookie: String, for url: URL) {
        guard let host = url.host else { return }
        lock.withLock {
            var jar = store[host] ?? [:]
            // URLSession joins repeated Set-Cookie headers with ", "; split on the pair boundary.
            for chunk in setCookie.components(separatedBy: ",") {
                guard let pair = chunk.split(separator: ";").first else { continue }
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                jar[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
            store[host] = jar
        }
    }

    func header(for url: URL) -> String {
        guard let host = url.host else { return "" }
        return lock.withLock {
            (store[host] ?? [:]).map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
        }
    }
}
