import Foundation
import Testing
@testable import WebHTVCore

/// IOS-POC-47: the local HLS package. What matters is that the copy plays with the network off in
/// both engines: every address in it is local, each distinct file is fetched once, and only the
/// chosen renditions are in it.
struct OfflinePackageTests {
    private let base = URL(string: "https://cdn.example.com/a/b/index.m3u8?token=x")!

    private func media(_ text: String, base: URL? = nil) throws -> HLSMediaPlaylist {
        guard case .media(let media) = try HLSPlaylist.parse(text, base: base ?? self.base) else {
            throw HLSPlaylist.ParseError.notAPlaylist
        }
        return media
    }

    @Test func resolvesRelativeAndAbsoluteSegmentAddresses() throws {
        let playlist = try media("""
        #EXTM3U
        #EXT-X-TARGETDURATION:10
        #EXTINF:10,
        seg0.ts
        #EXTINF:10,
        ../c/seg1.ts
        #EXTINF:10,
        /root/seg2.ts
        #EXTINF:10,
        https://other.example.com/seg3.ts
        #EXT-X-ENDLIST
        """)
        #expect(playlist.segments.map(\.uri.absoluteString) == [
            "https://cdn.example.com/a/b/seg0.ts", "https://cdn.example.com/a/c/seg1.ts",
            "https://cdn.example.com/root/seg2.ts", "https://other.example.com/seg3.ts",
        ])
        #expect(playlist.duration == 40)
    }

    @Test func byteRangesContinueFromThePreviousRangeOfTheSameFile() throws {
        let playlist = try media("""
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-TARGETDURATION:6
        #EXT-X-MAP:URI="main.mp4",BYTERANGE="720@0"
        #EXTINF:6,
        #EXT-X-BYTERANGE:1000@720
        main.mp4
        #EXTINF:6,
        #EXT-X-BYTERANGE:2000
        main.mp4
        #EXT-X-ENDLIST
        """)
        #expect(playlist.segments[0].byteRange == HLSByteRange(length: 1000, offset: 720))
        #expect(playlist.segments[1].byteRange == HLSByteRange(length: 2000, offset: 1720))
        #expect(playlist.segments[0].map?.byteRange == HLSByteRange(length: 720, offset: 0))
    }

    // 30. The package names nothing on the network: no scheme, nothing absolute, keys and maps local.
    @Test func packagePlaylistsHoldNoRemoteAddress() throws {
        let video = try media("""
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:7
        #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/k?id=1",IV=0x00000000000000000000000000000001
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6,
        s0.m4s
        #EXT-X-DISCONTINUITY
        #EXTINF:6,
        https://ads.example.com/ad.m4s
        #EXT-X-ENDLIST
        """)
        let plan = try OfflinePackageBuilder.build(.init(master: nil, variant: nil, video: video, audio: nil, subtitles: []),
                                                   origin: base, headers: [:])
        let text = try #require(plan.playlists[OfflinePackageBuilder.videoPlaylist])
        #expect(!text.contains("://"))
        #expect(text.contains("#EXT-X-MEDIA-SEQUENCE:7"))
        #expect(text.contains("#EXT-X-DISCONTINUITY"))
        #expect(text.contains("IV=0x00000000000000000000000000000001"))
        #expect(text.contains("URI=\"../keys/k1.key\""))
        #expect(text.contains("#EXT-X-MAP:URI=\"../media/v-init1.mp4\""))
        #expect(plan.units.map(\.role) == [.key, .initSection, .segment, .segment])
        #expect(plan.units.filter { $0.role == .segment }.allSatisfy { $0.relativePath.hasSuffix(".m4s") })
    }

    // 31 (at the package level): one file missing and the package is not complete.
    @Test func verifierFindsAMissingSegmentAndAcceptsAWholePackage() throws {
        let video = try media(Fixture.media(3))
        let plan = try OfflinePackageBuilder.build(.init(master: nil, variant: nil, video: video, audio: nil, subtitles: []),
                                                   origin: base, headers: [:])
        let root = OfflineHarness.scratchLayout().root.appendingPathComponent("asset")
        for (path, text) in plan.playlists {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        for unit in plan.units.dropLast() {
            let file = root.appendingPathComponent(unit.relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Fixture.segment().write(to: file)
        }
        #expect(!OfflinePackageVerifier.problems(plan: plan, root: root).isEmpty)
        try Fixture.segment().write(to: root.appendingPathComponent(plan.units.last!.relativePath))
        #expect(OfflinePackageVerifier.problems(plan: plan, root: root).isEmpty)
        // A playlist that still pointed at the network would fail the same check.
        let remote = OfflinePackageVerifier.referenceProblems(in: "#EXTM3U\n#EXTINF:6,\nhttps://cdn/x.ts\n",
                                                              playlistPath: "playlists/x.m3u8", root: root)
        #expect(remote == ["remote reference in playlists/x.m3u8"])
        let escape = OfflinePackageVerifier.referenceProblems(in: "#EXTM3U\n#EXTINF:6,\n../../other/x.ts\n",
                                                              playlistPath: "playlists/x.m3u8", root: root)
        #expect(escape == ["reference outside the asset in playlists/x.m3u8"])
    }

    @Test func aSegmentUsedTwiceIsFetchedOnce() throws {
        let video = try media("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6,
        same.ts
        #EXTINF:6,
        same.ts
        #EXTINF:6,
        other.ts
        #EXT-X-ENDLIST
        """)
        let plan = try OfflinePackageBuilder.build(.init(master: nil, variant: nil, video: video, audio: nil, subtitles: []),
                                                   origin: base, headers: [:])
        #expect(plan.units.count == 2)
        let text = try #require(plan.playlists[OfflinePackageBuilder.videoPlaylist])
        #expect(text.components(separatedBy: "../media/v00001.ts").count - 1 == 2)
    }

    // FFmpeg refuses a segment whose extension does not match its format; a CDN's `.jpg` TS is renamed.
    @Test func filesAreNamedByWhatTheyContain() throws {
        let video = try media(Fixture.media(2, prefix: "img", ext: "jpg"))
        let plan = try OfflinePackageBuilder.build(.init(master: nil, variant: nil, video: video, audio: nil, subtitles: []),
                                                   origin: base, headers: [:])
        #expect(plan.units.allSatisfy { $0.relativePath.hasSuffix(".ts") })
    }

    // 35. FairPlay is refused before anything is fetched — and never decrypted for MPV.
    @Test func fairPlayIsRefusedAsDRM() throws {
        let video = try media("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key-id",KEYFORMAT="com.apple.streamingkeydelivery",KEYFORMATVERSIONS="1"
        #EXTINF:6,
        s0.ts
        #EXT-X-ENDLIST
        """)
        #expect(throws: OfflinePackageError.drmProtected) {
            try OfflinePackageBuilder.build(.init(master: nil, variant: nil, video: video, audio: nil, subtitles: []),
                                            origin: base, headers: [:])
        }
        #expect(OfflinePackageError.drmProtected.failure.kind == .drmProtected)
    }

    @Test func clearSampleAESAndLiveStreamsAreRefused() throws {
        let sample = try media("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="https://k/1"
        #EXTINF:6,
        s0.ts
        #EXT-X-ENDLIST
        """)
        #expect(throws: OfflinePackageError.unsupportedEncryption("SAMPLE-AES")) {
            try OfflinePackageBuilder.validate([sample])
        }
        let live = try media("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\ns0.ts\n")
        #expect(throws: OfflinePackageError.liveStream) { try OfflinePackageBuilder.validate([live]) }
    }

    // 7, 8, 9. Only the chosen video variant, the chosen audio rendition and the chosen subtitle.
    @Test func onlyTheChosenRenditionsAreInThePackage() throws {
        guard case .master(let master) = try HLSPlaylist.parse(Fixture.masterText([
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"國語\",LANGUAGE=\"zh\",DEFAULT=YES,URI=\"audio/zh.m3u8\"",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"English\",LANGUAGE=\"en\",URI=\"audio/en.m3u8\"",
            "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"繁體中文\",LANGUAGE=\"zh-Hant\",URI=\"subs/hant.m3u8\"",
            "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"English\",LANGUAGE=\"en\",URI=\"subs/en.m3u8\"",
            Fixture.variant(1920, 1080, bandwidth: 5_000_000, audio: "aud", subtitles: "subs", uri: "v1080/index.m3u8"),
            Fixture.variant(1280, 720, bandwidth: 2_000_000, audio: "aud", subtitles: "subs", uri: "v720/index.m3u8"),
        ]), base: base) else { Issue.record("not a master"); return }
        let variant = master.variants[0]
        let video = try media(Fixture.media(3, prefix: "v"), base: variant.uri)
        let zh = master.renditions[0]
        let hant = master.renditions[2]
        let plan = try OfflinePackageBuilder.build(.init(
            master: master, variant: variant, video: video,
            audio: .init(rendition: zh, playlist: try media(Fixture.media(3, prefix: "a", ext: "aac"), base: zh.uri!)),
            subtitles: [.init(rendition: hant, playlist: try media(Fixture.media(3, prefix: "s", ext: "vtt"), base: hant.uri!))]),
            origin: base, headers: [:])
        let hosts = Set(plan.units.map { $0.remoteURL.deletingLastPathComponent().lastPathComponent })
        #expect(hosts == ["v1080", "audio", "subs"])
        #expect(plan.units.filter { $0.role == .segment }.count == 6)
        #expect(plan.units.filter { $0.role == .subtitleSegment }.count == 3)
        #expect(!plan.units.contains { $0.remoteURL.absoluteString.contains("v720") || $0.remoteURL.lastPathComponent.hasPrefix("en") })
        let local = try #require(plan.playlists[OfflinePackageBuilder.masterPlaylist])
        #expect(local.components(separatedBy: "#EXT-X-STREAM-INF").count - 1 == 1)
        #expect(local.contains("NAME=\"國語\""))
        #expect(!local.contains("English"))
        #expect(local.contains("NAME=\"繁體中文\""))
        #expect(!local.contains("://"))
        #expect(plan.package == .hls(entryPath: OfflinePackageBuilder.masterPlaylist))
    }

    @Test func attributeListsKeepCommasInsideQuotes() {
        let attributes = HLSAttributes.parse("BANDWIDTH=1,CODECS=\"avc1.4d401f,mp4a.40.2\",RESOLUTION=640x360")
        #expect(attributes["CODECS"] == "avc1.4d401f,mp4a.40.2")
        #expect(attributes["RESOLUTION"] == "640x360")
    }

    // Credentials stay with the stream's origin; User-Agent and Referer go anywhere.
    @Test func credentialsAreSentOnlyToTheOrigin() {
        let origin = URL(string: "https://cdn.example.com/master.m3u8")!
        let headers = ["Cookie": "session=1", "Referer": "https://site.example.com/", "User-Agent": "UA"]
        let same = OfflineRequestPolicy.headers(headers, for: URL(string: "https://cdn.example.com/seg.ts")!, origin: origin)
        #expect(same["Cookie"] == "session=1")
        #expect(OfflineRequestPolicy.isCredentialed(same))
        let other = OfflineRequestPolicy.headers(headers, for: URL(string: "https://other.example.com/seg.ts")!, origin: origin)
        #expect(other["Cookie"] == nil)
        #expect(other["Referer"] != nil)
        #expect(!OfflineRequestPolicy.isCredentialed(other))
        var redirect = URLRequest(url: URL(string: "https://evil.example.net/seg.ts")!)
        redirect.setValue("session=1", forHTTPHeaderField: "Cookie")
        let stripped = OfflineHTTP.redirect(redirect, headers: headers, origin: origin)
        #expect(stripped.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(stripped.value(forHTTPHeaderField: "User-Agent") == "UA")
    }
}
