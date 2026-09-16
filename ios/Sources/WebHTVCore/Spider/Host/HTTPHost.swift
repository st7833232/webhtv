import Foundation
import JavaScriptCore

/// `host.req` — the one HTTP path every spider uses, with a per-session cookie store.
///
/// Synchronous on purpose. `Spider.java` is blocking Java, so a port reads line for line like the
/// decompiled original and stays auditable against it. Safe because `JavaScriptSpiderRuntime` gives
/// each session its own serial `DispatchQueue` rather than a Swift-concurrency cooperative thread.
enum HTTPHost {
    static func install(into context: JSContext, cookies: CookieJar, session: URLSession) {
        let request: @convention(block) (String, [String: Any]?) -> [String: Any] = { url, options in
            perform(url: url, options: options ?? [:], cookies: cookies, session: session)
        }
        let host = JSValue(newObjectIn: context)
        host?.setObject(request, forKeyedSubscript: "request" as NSString)
        context.setObject(host, forKeyedSubscript: "__http" as NSString)
    }

    static func perform(url: String, options: [String: Any], cookies: CookieJar, session: URLSession) -> [String: Any] {
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

        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any] = ["status": 0, "body": "", "headers": [String: String](), "cookies": "", "url": url]
        let delegate = followRedirects ? nil : NoRedirect()
        let client = delegate.map { URLSession(configuration: session.configuration, delegate: $0, delegateQueue: nil) } ?? session
        let task = client.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { result["error"] = error.localizedDescription; return }
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
            result["body"] = String(decoding: data ?? Data(), as: UTF8.self)
        }
        task.resume()
        if semaphore.wait(timeout: .now() + request.timeoutInterval + 5) == .timedOut {
            task.cancel()
            result["error"] = "timeout"
        }
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

    public func all(for host: String) -> [String: String] { lock.withLock { store[host] ?? [:] } }
    public func clear() { lock.withLock { store.removeAll() } }
}
