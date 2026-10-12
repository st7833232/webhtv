import Foundation

/// A poster address in the TVBox image convention — `<url>@Headers={json}`, `@Referer=…`, `@User-Agent=…`,
/// with `@Cookie=…` recognised and dropped — read into the URL and the only headers an image request may
/// carry to any host: Referer and User-Agent (QIST-POSTER, W-32 design; Android's `ImgUtil.getUrl`).
public enum ImageRequest {
    static let markers = ["@Headers=", "@Cookie=", "@Referer=", "@User-Agent="]

    /// nil for an address with no marker (it loads as a plain URL, as before) or whose URL is not http(s).
    public static func parse(_ picture: String) -> (url: URL, headers: [String: String])? {
        var hits: [(marker: String, range: Range<String.Index>)] = []
        for marker in markers {
            var from = picture.startIndex
            while let range = picture.range(of: marker, range: from..<picture.endIndex) {
                hits.append((marker, range))
                from = range.upperBound
            }
        }
        hits.sort { $0.range.lowerBound < $1.range.lowerBound }
        // The URL ends at the first marker, not the first "@", which an address may contain itself.
        guard let first = hits.first, let url = URL(string: String(picture[..<first.range.lowerBound])),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }

        var headers: [String: String] = [:]
        func add(_ name: String, _ value: String) {
            let key = name.lowercased()
            // Scalars, not `Character`s: Swift reads "\r\n" as one grapheme that equals neither.
            guard SourceSubtitleProvider.anyHost.contains(key),
                  !value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) else { return }
            headers[key == "referer" ? "Referer" : "User-Agent"] = value
        }
        for (index, hit) in hits.enumerated() {
            // A value runs to the next known marker, so `@Referer=r@Cookie=x` never sends the cookie as Referer.
            let end = index + 1 < hits.count ? hits[index + 1].range.lowerBound : picture.endIndex
            let value = String(picture[hit.range.upperBound..<end])
            switch hit.marker {
            case "@Headers=":
                let object = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any]
                object?.forEach { if let text = $0.value as? String { add($0.key, text) } }
            case "@Referer=": add("Referer", value)
            case "@User-Agent=": add("User-Agent", value)
            default: break // @Cookie= is never sent.
            }
        }
        return (url, headers)
    }
}
