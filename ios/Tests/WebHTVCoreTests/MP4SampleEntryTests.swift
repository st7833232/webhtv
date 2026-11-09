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
