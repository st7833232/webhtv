import Foundation

/// IOS-POC-45 — the real network under `SubtitleFetch`.
public enum SubtitleHTTP {
    /// Reads at most `limit` bytes of a body, as `HLSAdPlanner.fetcher` and `DrpyEngine.download`
    /// do: a larger body is abandoned rather than buffered. Any status is answered, body included,
    /// because a 403's body is what tells a challenge page from a plain refusal.
    public static func fetcher(session: URLSession = .webHTV) -> SubtitleFetch {
        { request, limit in
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            if response.expectedContentLength > Int64(limit) { throw SubtitleBodyTooLarge() }
            var data = Data()
            data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), limit, 1 << 20))
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { throw SubtitleBodyTooLarge() }
            }
            return SubtitleHTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                        mimeType: response.mimeType, data: data, url: response.url)
        }
    }
}
