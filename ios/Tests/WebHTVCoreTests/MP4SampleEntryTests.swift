import Foundation
import Testing
@testable import WebHTVCore

/// W-262: synthetic MP4s, box by box.
enum MP4Fixture {
    static func box(_ type: String, _ payload: Data) -> Data {
        var size = UInt32(8 + payload.count).bigEndian
        return Data(bytes: &size, count: 4) + Data(type.utf8) + payload
    }
    static func track(handler: String, entry: String) -> Data {
        let hdlr = box("hdlr", Data(count: 8) + Data(handler.utf8) + Data(count: 12))
        let stsd = box("stsd", Data([0, 0, 0, 0, 0, 0, 0, 1]) + box(entry, Data(count: 78)))
        return box("trak", box("mdia", box("mdhd", Data(count: 24)) + hdlr
                                        + box("minf", box("stbl", stsd + box("stsz", Data(count: 12))))))
    }
    /// `ftyp`, a `moov` with the given tracks, and an `mdat`; `moovLast` puts the index after the media.
    static func file(_ tracks: [Data], moovLast: Bool = false) -> Data {
        let ftyp = box("ftyp", Data("isom".utf8) + Data(count: 4))
        let moov = box("moov", box("mvhd", Data(count: 100)) + tracks.reduce(Data(), +))
        let mdat = box("mdat", Data(repeating: 7, count: 64))
        return moovLast ? ftyp + mdat + moov : ftyp + moov + mdat
    }
}

struct MP4SampleEntryTests {
    @Test func theFirstVideoTracksEntryIsRead() {
        let audio = MP4Fixture.track(handler: "soun", entry: "mp4a")
        #expect(MP4SampleEntry.videoFourCC(MP4Fixture.file([audio, MP4Fixture.track(handler: "vide", entry: "bvc2")])) == "bvc2")
        #expect(MP4SampleEntry.videoFourCC(MP4Fixture.file([MP4Fixture.track(handler: "vide", entry: "avc1"), audio])) == "avc1")
        #expect(MP4SampleEntry.videoFourCC(MP4Fixture.file([MP4Fixture.track(handler: "vide", entry: "hvc1")], moovLast: true)) == "hvc1")
    }

    @Test func onlyVVCAndByteVC2NeedMPV() {
        #expect(MP4SampleEntry.needsMPV == ["bvc2", "vvc1", "vvi1"])
        #expect(!MP4SampleEntry.needsMPV.contains("avc1") && !MP4SampleEntry.needsMPV.contains("hvc1"))
    }

    @Test func aFileWithoutAReadableVideoEntryAnswersNil() {
        #expect(MP4SampleEntry.videoFourCC(Data()) == nil)
        #expect(MP4SampleEntry.videoFourCC(Data("#EXTM3U\n".utf8)) == nil)
        #expect(MP4SampleEntry.videoFourCC(MP4Fixture.file([MP4Fixture.track(handler: "soun", entry: "mp4a")])) == nil)
        let whole = MP4Fixture.file([MP4Fixture.track(handler: "vide", entry: "bvc2")])
        // Cut inside the moov: the box no longer fits, nothing is read past the end.
        #expect(MP4SampleEntry.videoFourCC(whole.prefix(60)) == nil)
        var huge = whole
        huge.replaceSubrange(whole.startIndex + 24..<whole.startIndex + 28, with: [0xff, 0xff, 0xff, 0xff])
        #expect(MP4SampleEntry.videoFourCC(huge) == nil)
    }
}

#if canImport(Network)
/// W-269: a script's own loopback service, read from its first bytes.
struct LoopbackMP4ProbeTests {
    @Test func onlyALoopbackFileTheProxyDoesNotServeIsProbed() throws {
        #expect(LoopbackMP4Probe.applies(to: try #require(URL(string: "http://127.0.0.1:18447/media/ep1.mp4"))))
        #expect(LoopbackMP4Probe.applies(to: try #require(URL(string: "http://[::1]:9000/v?id=1"))))
        #expect(!LoopbackMP4Probe.applies(to: try #require(URL(string: "https://cdn.example.com/ep1.mp4"))))
        #expect(!LoopbackMP4Probe.applies(to: try #require(URL(string: "http://127.0.0.1:9000/index.m3u8"))))
        let proxied = try #require(URL(string: "http://127.0.0.1:9/\(SpiderProxyServer.shared.token)/proxy?do=py&vid=1"))
        #expect(!LoopbackMP4Probe.applies(to: proxied))
    }

    @Test func aVVCFrontOpensOnMPVAndAnythingElseKeepsTheUsualWay() throws {
        let vvc = try #require(URL(string: "http://127.0.0.1:18447/\(UUID().uuidString).mp4"))
        let avc = try #require(URL(string: "http://127.0.0.1:18447/\(UUID().uuidString).mp4"))
        let tail = try #require(URL(string: "http://127.0.0.1:18447/\(UUID().uuidString).mp4"))
        let bvc2 = MP4Fixture.file([MP4Fixture.track(handler: "soun", entry: "mp4a"), MP4Fixture.track(handler: "vide", entry: "bvc2")])
        #expect(LoopbackMP4Probe.record(vvc, prefix: bvc2) == true)
        #expect(LoopbackMP4Probe.isVVC(vvc) && PlayerRouter.needsMPV(vvc))
        #expect(LoopbackMP4Probe.record(avc, prefix: MP4Fixture.file([MP4Fixture.track(handler: "vide", entry: "avc1")])) == false)
        #expect(!PlayerRouter.needsMPV(avc))
        // A moov at the end, or one cut by the byte limit, says nothing: the usual way.
        let moovLast = MP4Fixture.file([MP4Fixture.track(handler: "vide", entry: "bvc2")], moovLast: true)
        #expect(LoopbackMP4Probe.record(tail, prefix: moovLast.prefix(64)) == nil)
        #expect(LoopbackMP4Probe.record(tail, prefix: bvc2.prefix(100)) == nil)
        #expect(!PlayerRouter.needsMPV(tail))
    }

    /// W-292: only a script's own 5xx is a refusal; a 504 may only be slow, and a 4xx or no answer says nothing.
    @Test func onlyAScriptsOwnFiveHundredIsARefusal() async throws {
        let url = try #require(URL(string: "http://127.0.0.1:10010/hg.mp4?vid=\(UUID().uuidString)"))
        func answer(_ status: Int, _ data: Data = Data("media session failed".utf8)) async -> LoopbackMP4Probe.Finding? {
            await LoopbackMP4Probe.probe(url, headers: [:]) { request, _ in
                #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-524287")
                return OfflineHTTPResponse(data: data, status: status, url: url, headers: [:])
            }
        }
        #expect(await answer(502) == .refused(502))
        #expect(await answer(500) == .refused(500))
        #expect(await answer(504) == nil)
        #expect(await answer(404) == nil)
        #expect(await LoopbackMP4Probe.probe(url, headers: [:]) { _, _ in throw URLError(.timedOut) } == nil)
        let bvc2 = MP4Fixture.file([MP4Fixture.track(handler: "vide", entry: "bvc2")])
        #expect(await answer(206, bvc2) == .vvc(true))
        #expect(PlayerRouter.needsMPV(url))
    }
}
#endif
