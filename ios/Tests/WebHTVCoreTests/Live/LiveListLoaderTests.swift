import Foundation
import Testing
@testable import WebHTVCore

// W-125 (IOS-POC-59 U2): fetching a live list. The source's headers go with it, its address is used as written,
// the whole fetch has one deadline (Manager #2158 B2-2: 30 s in total), and a list is fetched once until refreshed.

/// Answers by path; a path it does not know never answers at all.
final class LiveListSite: URLProtocol, @unchecked Sendable {
    struct Seen { let url: URL; let headers: [String: String] }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) private static var seen: [Seen] = []

    static func serve(_ served: [String: (Int, Data)]) {
        lock.withLock { replies = served.mapValues { (status: $0.0, body: $0.1) }; seen = [] }
    }
    static var requests: [Seen] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var trickling = true
    override func stopLoading() { trickling = false }

    override func startLoading() {
        let url = request.url!
        // A server that keeps sending a byte every 0.1 s and never finishes: no idle timeout ever fires.
        if url.path == "/trickle.txt" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            func drip() {
                guard trickling else { return }
                client?.urlProtocol(self, didLoad: Data("#".utf8))
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1, execute: drip)
            }
            drip()
            return
        }
        let reply = Self.lock.withLock { () -> (status: Int, body: Data)? in
            Self.seen.append(Seen(url: url, headers: request.allHTTPHeaderFields ?? [:]))
            return Self.replies[url.path]
        }
        guard let reply else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func loader(limit: TimeInterval = 30) -> LiveListLoader {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LiveListSite.self]
    return LiveListLoader(configuration: configuration, limit: limit)
}

private let txt = Data("G,#genre#\nA,http://x/a.m3u8".utf8)

@Suite(.serialized) struct LiveListLoaderTests {
    @Test func aListIsFetchedWithTheSourceHeadersAtItsAddressAsWritten() async throws {
        LiveListSite.serve(["/a;b.txt": (200, txt)])
        let source = LiveSource(name: "s", url: "http://x.test/a;b.txt?k=1", ua: "U", referer: "R", header: ["X": "1"])
        let playlist = try await loader().playlist(for: source, base: nil)
        #expect(playlist.groups.map(\.name) == ["G"])
        let seen = try #require(LiveListSite.requests.first)
        #expect(seen.url.absoluteString == "http://x.test/a;b.txt?k=1")
        #expect(seen.headers == ["X": "1", "User-Agent": "U", "Referer": "R"])
    }

    @Test func aRelativeAddressResolvesAgainstTheConfigurationWithoutCuttingAtSemicolon() async throws {
        LiveListSite.serve(["/cfg/live/a;1.txt": (200, txt)])
        let source = LiveSource(name: "s", url: "./live/a;1.txt")
        _ = try await loader().playlist(for: source, base: URL(string: "http://x.test/cfg/config.json"))
        #expect(LiveListSite.requests.map(\.url.absoluteString) == ["http://x.test/cfg/live/a;1.txt"])
        // An imported configuration has no base, so a relative live cannot be fetched.
        await #expect(throws: LiveListError.badAddress) { try await loader().playlist(for: source, base: nil) }
    }

    @Test func aFailedFetchSaysOnlyWhatWentWrong() async throws {
        LiveListSite.serve(["/a.txt": (404, Data())])
        let source = LiveSource(name: "s", url: "http://x.test/a.txt?sid=secret")
        do {
            _ = try await loader().playlist(for: source, base: nil)
            Issue.record("no error")
        } catch {
            #expect(error as? LiveListError == .httpStatus(404))
            #expect(error.localizedDescription == "HTTP 404")
        }
        #expect(LiveListError.timedOut.localizedDescription == "逾時")
        #expect(LiveListError.unreachable.localizedDescription == "無法連線")
    }

    // Without a deadline the trickle never ends; the time limit turns that hang into a failure.
    @Test(.timeLimit(.minutes(1))) func theWholeFetchHasOneDeadline() async throws {
        LiveListSite.serve([:])
        let started = ContinuousClock.now
        await #expect(throws: LiveListError.timedOut) {
            try await loader(limit: 0.3).playlist(for: LiveSource(name: "s", url: "http://x.test/never.txt"), base: nil)
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        // A list that trickles in forever still ends at the deadline (the idle timeout alone would never fire).
        let trickle = ContinuousClock.now
        await #expect(throws: LiveListError.timedOut) {
            try await loader(limit: 0.5).playlist(for: LiveSource(name: "s", url: "http://x.test/trickle.txt"), base: nil)
        }
        #expect(ContinuousClock.now - trickle < .seconds(5))
    }

    @Test func aListIsFetchedOnceUntilRefreshed() async throws {
        LiveListSite.serve(["/a.txt": (200, txt)])
        let loader = loader()
        let source = LiveSource(name: "s", url: "http://x.test/a.txt")
        _ = try await loader.playlist(for: source, base: nil)
        _ = try await loader.playlist(for: source, base: nil)
        #expect(LiveListSite.requests.count == 1)
        _ = try await loader.playlist(for: source, base: nil, refresh: true)
        #expect(LiveListSite.requests.count == 2)
        // The same address with other headers is another list.
        var other = source
        other.ua = "U2"
        _ = try await loader.playlist(for: other, base: nil)
        #expect(LiveListSite.requests.count == 3)
    }

    @Test func anOversizedOrUnparsableListIsAnError() async throws {
        LiveListSite.serve(["/big.txt": (200, Data(count: LiveListLoader.maximumBytes + 1)), "/a.json": (200, Data(#"[{"name":"g"}]"#.utf8))])
        await #expect(throws: LiveListError.tooLarge) {
            try await loader().playlist(for: LiveSource(name: "s", url: "http://x.test/big.txt"), base: nil)
        }
        await #expect(throws: LivePlaylistError.unsupportedFormat) {
            try await loader().playlist(for: LiveSource(name: "s", url: "http://x.test/a.json"), base: nil)
        }
    }
}
