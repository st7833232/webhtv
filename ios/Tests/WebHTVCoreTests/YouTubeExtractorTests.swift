import Foundation
import Testing
@testable import WebHTVCore

/// W-212: YouTube addresses, the visionOS player request and how each answer ends.
@Suite struct YouTubeExtractorTests {
    @Test func videoIDsComeFromEveryYouTubeAddressFormAndNothingElse() {
        let id = "dQw4w9WgXcQ"
        for address in ["https://www.youtube.com/watch?v=\(id)&t=10", "https://youtube.com/embed/\(id)?autoplay=1",
                        "https://m.youtube.com/shorts/\(id)", "https://youtu.be/\(id)", "http://www.youtube.com/live/\(id)",
                        "https://www.youtube-nocookie.com/embed/\(id)"] {
            #expect(YouTubeURL.videoID(in: URL(string: address)!) == id, "\(address)")
        }
        for address in ["https://www.youtube.com/channel/UC1234567890", "https://www.youtube.com/watch?v=short",
                        "https://rr1---sn-x.googlevideo.com/videoplayback?id=\(id)", "https://notyoutube.com/watch?v=\(id)",
                        "https://example.com/embed/\(id)"] {
            #expect(YouTubeURL.videoID(in: URL(string: address)!) == nil, "\(address)")
        }
        #expect(YouTubeURL.proxiedVideoID(in: URL(string: "http://127.0.0.1:9978/proxy?do=py&type=mpd&vid=\(id)&quality=1080p")!) == id)
        #expect(YouTubeURL.proxiedVideoID(in: URL(string: "http://127.0.0.1:9978/proxy?do=py&type=m3u8&vid=\(id)")!) == nil)
        #expect(YouTubeURL.proxiedVideoID(in: URL(string: "http://127.0.0.1:9978/proxy?do=py&type=mpd&vid=x")!) == nil)
        #expect(YouTubeURL.isYouTubeStream(URL(string: "https://manifest.googlevideo.com/api/manifest/hls_variant/x")!))
        #expect(!YouTubeURL.isYouTubeStream(URL(string: "https://cdn.example.com/master.m3u8")!))
    }

    @Test func aPlayerReplyGivesItsHLSElseTheTallestSingleFile() throws {
        let hls = try reply(["playabilityStatus": ["status": "OK"],
                             "streamingData": ["hlsManifestUrl": "https://manifest.googlevideo.com/hls.m3u8",
                                               "formats": [["itag": 18, "height": 360, "url": "https://r.googlevideo.com/18"]]]])
        #expect(try YouTubeExtractor.stream(fromPlayerResponse: hls).absoluteString == "https://manifest.googlevideo.com/hls.m3u8")
        let files = try reply(["playabilityStatus": ["status": "OK"],
                               "streamingData": ["formats": [["itag": 18, "height": 360, "url": "https://r.googlevideo.com/18"],
                                                             ["itag": 22, "height": 720, "url": "https://r.googlevideo.com/22"]]]])
        #expect(try YouTubeExtractor.stream(fromPlayerResponse: files).absoluteString == "https://r.googlevideo.com/22")
        // ANDROID's SABR-only answer: adaptive formats without addresses are not playable here.
        let sabr = try reply(["playabilityStatus": ["status": "OK"],
                              "streamingData": ["adaptiveFormats": [["itag": 137]], "serverAbrStreamingUrl": "https://x"]])
        #expect(throws: YouTubeError.noStream) { try YouTubeExtractor.stream(fromPlayerResponse: sabr) }
    }

    @Test func verificationAgeContentWarningsAndMembershipStopWithTheirOwnReason() throws {
        let cases: [(String, String, YouTubeError)] = [
            ("LOGIN_REQUIRED", "Sign in to confirm you’re not a bot", .verificationRequired),
            ("LOGIN_REQUIRED", "Sign in to confirm your age", .ageRestricted),
            ("AGE_CHECK_REQUIRED", "", .ageRestricted),
            ("CONTENT_CHECK_REQUIRED", "", .contentCheckRequired),
            ("ERROR", "The following content may be inappropriate for some users.", .contentCheckRequired),
            ("UNPLAYABLE", "Join this channel to get access to members-only content", .membersOnly),
            ("ERROR", "Video unavailable", .unplayable("Video unavailable")),
        ]
        for (status, reason, expected) in cases {
            let data = try reply(["playabilityStatus": ["status": status, "reason": reason]])
            #expect(throws: expected, "\(status) \(reason)") { try YouTubeExtractor.stream(fromPlayerResponse: data) }
        }
    }

    @Test func theRequestIsTheVisionOSClientWithoutContentCheckFlagsAndOneVisitorLookup() async throws {
        let recorder = Recorder()
        let extractor = YouTubeExtractor(send: recorder.send)
        recorder.replies = [try reply(["responseContext": ["visitorData": "VISITOR"]]),
                            try reply(["playabilityStatus": ["status": "OK"], "streamingData": ["hlsManifestUrl": "https://m.googlevideo.com/a"]]),
                            try reply(["playabilityStatus": ["status": "OK"], "streamingData": ["hlsManifestUrl": "https://m.googlevideo.com/b"]])]
        #expect(try await extractor.stream(videoID: "dQw4w9WgXcQ").absoluteString == "https://m.googlevideo.com/a")
        #expect(try await extractor.stream(videoID: "jNQXAC9IVRw").absoluteString == "https://m.googlevideo.com/b")
        let paths = recorder.requests.map { $0.url!.path }
        #expect(paths == ["/youtubei/v1/visitor_id", "/youtubei/v1/player", "/youtubei/v1/player"])
        let player = try #require(recorder.requests.last)
        #expect(player.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("com.google.visionos.youtube/") == true)
        let body = try #require(try JSONSerialization.jsonObject(with: player.httpBody!) as? [String: Any])
        #expect(body["videoId"] as? String == "jNQXAC9IVRw")
        #expect(body["contentCheckOk"] == nil && body["racyCheckOk"] == nil)
        let client = ((body["context"] as? [String: Any])?["client"] as? [String: Any]) ?? [:]
        #expect(client["clientName"] as? String == "VISIONOS" && client["visitorData"] as? String == "VISITOR")
    }

    @Test func a429CoolsDownWithoutAnotherRequestUntilItEnds() async throws {
        let recorder = Recorder()
        let clock = Clock()
        let extractor = YouTubeExtractor(send: recorder.send, now: { clock.now })
        recorder.replies = [try reply(["responseContext": ["visitorData": "V"]])]
        recorder.status = [200, 429]
        await #expect(throws: YouTubeError.rateLimited) { _ = try await extractor.stream(videoID: "dQw4w9WgXcQ") }
        await #expect(throws: YouTubeError.rateLimited) { _ = try await extractor.stream(videoID: "dQw4w9WgXcQ") }
        #expect(recorder.requests.count == 2)
        clock.now = clock.now.addingTimeInterval(YouTubeExtractor.cooldown + 1)
        recorder.status = [200]
        recorder.replies = [try reply(["playabilityStatus": ["status": "OK"], "streamingData": ["hlsManifestUrl": "https://m.googlevideo.com/c"]])]
        #expect(try await extractor.stream(videoID: "dQw4w9WgXcQ").absoluteString == "https://m.googlevideo.com/c")
    }

    @Test func aYouTubeStreamIsNeverDownloaded() async {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        await harness.manager.start()
        let result = await harness.manager.enqueue(
            identity: Fixture.identity(), title: Fixture.title(),
            target: PlaybackTarget(url: URL(string: "https://manifest.googlevideo.com/api/manifest/hls_variant/x")!),
            choice: OfflineDownloadChoice(mode: .smart), estimate: OfflineSizeEstimate(bytes: 1, basis: .averageBandwidth),
            autoDeleteAfterWatching: true, allowsCellular: false)
        #expect(result == .refused(OfflineDownloadManager.youtubeRefusal))
        #expect(await harness.manager.snapshot().assets.isEmpty)
    }

    @Test func theSwitchIsOnUnlessTurnedOff() throws {
        let defaults = try #require(UserDefaults(suiteName: "YouTubeExtractorTests"))
        defaults.removePersistentDomain(forName: "YouTubeExtractorTests")
        #expect(YouTubeExtractor.isEnabled(defaults))
        defaults.set(false, forKey: YouTubeExtractor.enabledKey)
        #expect(!YouTubeExtractor.isEnabled(defaults))
    }
}

private func reply(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

private final class Recorder: @unchecked Sendable {
    var requests: [URLRequest] = []
    var replies: [Data] = []
    var status: [Int] = []
    var send: YouTubeExtractor.Send {
        { [self] request in
            requests.append(request)
            let code = status.isEmpty ? 200 : status.removeFirst()
            let data = code == 200 && !replies.isEmpty ? replies.removeFirst() : Data()
            return (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }
}
