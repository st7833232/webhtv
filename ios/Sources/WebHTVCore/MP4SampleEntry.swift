import Foundation

/// W-262: the sample entry of an MP4's first video track (`moov/trak/mdia/minf/stbl/stsd`), read from a
/// whole file a spider served, so a codec AVPlayer cannot decode starts on MPV instead of stalling first.
public enum MP4SampleEntry {
    /// VVC under its standard entries and ByteVC2's renamed one (docs/W-254-bvc2-decoder.md): AVFoundation
    /// has no VVC decoder; the app's MPV does (FFmpeg `vvc`, patch 0007 for `bvc2`).
    public static let needsMPV: Set<String> = ["bvc2", "vvc1", "vvi1"]

    /// The fourcc of the first video track's first sample entry, or nil when `data` has none to read.
    public static func videoFourCC(_ data: Data) -> String? {
        data.withUnsafeBytes { videoFourCC(in: $0) }
    }

    private static func videoFourCC(in bytes: UnsafeRawBufferPointer) -> String? {
        guard let moov = boxes(bytes, 0..<bytes.count).first(where: { $0.type == "moov" }) else { return nil }
        for trak in boxes(bytes, moov.payload) where trak.type == "trak" {
            guard let mdia = child("mdia", bytes, trak.payload),
                  let hdlr = child("hdlr", bytes, mdia.payload), hdlr.payload.count >= 12,
                  fourcc(bytes, hdlr.payload.lowerBound + 8) == "vide",
                  let minf = child("minf", bytes, mdia.payload),
                  let stbl = child("stbl", bytes, minf.payload),
                  let stsd = child("stsd", bytes, stbl.payload),
                  stsd.payload.count >= 16 else { continue }
            // version/flags (4), entry_count (4), then the first entry's size (4) and type (4).
            return fourcc(bytes, stsd.payload.lowerBound + 12)
        }
        return nil
    }

    private struct Box { let type: String; let payload: Range<Int> }

    private static func child(_ type: String, _ bytes: UnsafeRawBufferPointer, _ range: Range<Int>) -> Box? {
        boxes(bytes, range).first { $0.type == type }
    }

    /// The boxes directly inside `range`; stops at the first one whose size does not fit.
    private static func boxes(_ bytes: UnsafeRawBufferPointer, _ range: Range<Int>) -> [Box] {
        var found = [Box]()
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            var size = Int(be32(bytes, offset))
            var header = 8
            if size == 1 {
                guard offset + 16 <= range.upperBound else { break }
                let large = UInt64(be32(bytes, offset + 8)) << 32 | UInt64(be32(bytes, offset + 12))
                guard large <= UInt64(Int.max) else { break }
                size = Int(large)
                header = 16
            } else if size == 0 {
                size = range.upperBound - offset
            }
            guard size >= header, offset + size <= range.upperBound else { break }
            found.append(Box(type: fourcc(bytes, offset + 4), payload: (offset + header)..<(offset + size)))
            offset += size
        }
        return found
    }

    private static func be32(_ bytes: UnsafeRawBufferPointer, _ at: Int) -> UInt32 {
        bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func fourcc(_ bytes: UnsafeRawBufferPointer, _ at: Int) -> String {
        String(decoding: bytes[at..<at + 4], as: Unicode.ASCII.self)
    }
}
