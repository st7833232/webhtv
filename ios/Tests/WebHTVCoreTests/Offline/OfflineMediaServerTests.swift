#if canImport(Network)
import Foundation
import Testing
@testable import WebHTVCore

/// IOS-POC-47: the loopback server both engines read a downloaded HLS package from. It must serve
/// exactly the asset's own files — with byte ranges, as AVPlayer asks — and nothing else.
struct OfflineMediaServerTests {
    private let token = "t0k3n"
    private let id = UUID().uuidString

    @Test func parsesOnlyRequestsForAnAssetFileUnderTheToken() {
        let ok = OfflineMediaServer.parse("GET /\(token)/\(id)/playlists/index.m3u8 HTTP/1.1\r\nRange: bytes=0-99", token: token)
        #expect(ok == .init(method: "GET", assetID: id, relativePath: "playlists/index.m3u8", range: "bytes=0-99"))
        for path in ["/wrong/\(id)/a.ts", "/\(token)/not-a-uuid/a.ts", "/\(token)/\(id)/../other/a.ts",
                     "/\(token)/\(id)/%2e%2e/a.ts", "/\(token)/\(id)/"] {
            #expect(OfflineMediaServer.parse("GET \(path) HTTP/1.1", token: token) == nil, "\(path)")
        }
        #expect(OfflineMediaServer.parse("POST /\(token)/\(id)/a.ts HTTP/1.1", token: token) == nil)
    }

    @Test func byteRangesFollowRFC7233() {
        #expect(OfflineMediaServer.byteRange("bytes=0-99", size: 1000) == 0...99)
        #expect(OfflineMediaServer.byteRange("bytes=900-", size: 1000) == 900...999)
        #expect(OfflineMediaServer.byteRange("bytes=-100", size: 1000) == 900...999)
        #expect(OfflineMediaServer.byteRange("bytes=990-2000", size: 1000) == 990...999)
        #expect(OfflineMediaServer.byteRange("bytes=1000-", size: 1000) == nil)
    }

    // The real thing on 127.0.0.1: a whole file, a range, and a refusal outside the asset.
    @Test func servesTheAssetsFilesOverLoopback() async throws {
        let layout = OfflineHarness.scratchLayout()
        let folder = layout.folder(for: id)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("media"), withIntermediateDirectories: true)
        let body = Data((0..<4096).map { UInt8($0 % 251) })
        try body.write(to: folder.appendingPathComponent("media/v00001.ts"))
        try Data("secret".utf8).write(to: layout.root.appendingPathComponent("outside.txt"))
        let server = OfflineMediaServer(root: layout.root)
        let base = try #require(await server.start())
        #expect(base.host == "127.0.0.1")

        let whole = try await URLSession.shared.data(from: base.appendingPathComponent("\(id)/media/v00001.ts"))
        #expect(whole.0 == body)
        #expect((whole.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "video/mp2t")

        var ranged = URLRequest(url: base.appendingPathComponent("\(id)/media/v00001.ts"))
        ranged.setValue("bytes=100-199", forHTTPHeaderField: "Range")
        let part = try await URLSession.shared.data(for: ranged)
        #expect((part.1 as? HTTPURLResponse)?.statusCode == 206)
        #expect(part.0 == body[100...199])

        let escape = try await URLSession.shared.data(from: URL(string: base.absoluteString + "\(id)/..%2Foutside.txt")!)
        #expect((escape.1 as? HTTPURLResponse)?.statusCode != 200)
        // Started again, it answers at the same address.
        #expect(await server.start() == base)
    }
}
#endif
