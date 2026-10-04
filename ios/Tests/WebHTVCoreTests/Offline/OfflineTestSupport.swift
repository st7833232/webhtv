import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WebHTVCore

/// IOS-POC-47 test doubles: a transport that only records, a network made of fixtures, and a
/// scratch storage root per test.

actor FakeTransport: OfflineTransport {
    private var sink: (@Sendable (OfflineTransferTag, OfflineTransferEvent) async -> Void)?
    private(set) var submitted = [OfflineTransferRequest]()
    private(set) var cancelled = [String]()
    private var active = Set<OfflineTransferTag>()
    let staging: URL
    /// What a cancel with resume data hands back, per asset.
    var resumeData = [String: Data]()

    init(staging: URL) { self.staging = staging }

    func attach(_ sink: @escaping @Sendable (OfflineTransferTag, OfflineTransferEvent) async -> Void) async {
        self.sink = sink
    }

    func submit(_ requests: [OfflineTransferRequest]) async {
        submitted += requests
        for request in requests { active.insert(request.tag) }
    }

    func cancel(assetID: String, producingResumeData: Bool) async -> [OfflineTransferTag: Data] {
        cancelled.append(assetID)
        let tags = active.filter { $0.assetID == assetID }
        active.subtract(tags)
        guard producingResumeData, let data = resumeData[assetID] else { return [:] }
        return Dictionary(uniqueKeysWithValues: tags.map { ($0, data) })
    }

    func activeTags() async -> Set<OfflineTransferTag> { active }

    func setActive(_ tags: Set<OfflineTransferTag>) { active = tags }
    func setResumeData(_ data: Data, for assetID: String) { resumeData[assetID] = data }
    func clearSubmitted() { submitted = [] }

    /// A transfer finishing: its body lands in staging and the manager is told.
    func finish(_ tag: OfflineTransferTag, body: Data, status: Int = 200) async {
        active.remove(tag)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let file = staging.appendingPathComponent("\(tag.description).\(UUID().uuidString).part")
        try? body.write(to: file)
        await sink?(tag, .finished(file: file, status: status))
    }

    func fail(_ tag: OfflineTransferTag, _ failure: OfflineTransferFailure) async {
        active.remove(tag)
        await sink?(tag, .failed(failure))
    }

    /// Finishes every submitted transfer not finished yet with `body(unit)`.
    func finishAll(where include: (OfflineTransferRequest) -> Bool = { _ in true },
                   body: (OfflineTransferRequest) -> Data) async {
        for request in submitted where active.contains(request.tag) && include(request) {
            await finish(request.tag, body: body(request))
        }
    }
}

struct FakeNetwork: Sendable {
    struct Response: Sendable {
        var data: Data
        var status = 200
        var headers = [String: String]()

        static func text(_ text: String) -> Response { Response(data: Data(text.utf8)) }
    }

    var responses: [String: Response]

    init(_ responses: [String: Response] = [:]) { self.responses = responses }

    func fetch(_ request: URLRequest, limit: Int) throws -> OfflineHTTPResponse {
        guard let url = request.url, let response = responses[url.absoluteString] else {
            throw URLError(.cannotFindHost)
        }
        return OfflineHTTPResponse(data: response.data.prefix(limit), status: response.status, url: url,
                                   headers: response.headers, truncated: response.data.count > limit)
    }
}

/// Records which requests the network saw, with their headers.
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = [URLRequest]()
    func append(_ request: URLRequest) { lock.lock(); requests.append(request); lock.unlock() }
    var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

final class Capacity: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64?
    init(_ value: Int64?) { self.value = value }
    func set(_ value: Int64?) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Int64? { lock.lock(); defer { lock.unlock() }; return value }
}

struct OfflineHarness {
    let layout: OfflineStorageLayout
    let transport: FakeTransport
    let manager: OfflineDownloadManager
    let capacity: Capacity
    let log: RequestLog

    init(network: FakeNetwork = FakeNetwork(), capacity: Int64? = 50_000_000_000, layout: OfflineStorageLayout? = nil,
         transport: FakeTransport? = nil, subtitleFiles: [String: String] = [:]) {
        let layout = layout ?? Self.scratchLayout()
        self.layout = layout
        let transport = transport ?? FakeTransport(staging: layout.stagingDirectory)
        self.transport = transport
        let capacity = Capacity(capacity)
        self.capacity = capacity
        let log = RequestLog()
        self.log = log
        let subtitles = SubtitleDownloadService(fetch: { request, _ in
            log.append(request)
            guard let url = request.url, let text = subtitleFiles[url.absoluteString] else {
                return SubtitleHTTPResponse(status: 404, mimeType: "text/plain", data: Data(), url: request.url)
            }
            return SubtitleHTTPResponse(status: 200, mimeType: "text/plain", data: Data(text.utf8), url: request.url)
        }, retryDelay: .zero)
        manager = OfflineDownloadManager(.init(
            layout: layout, transport: transport, capacity: { capacity.get() },
            fetcher: { _, _ in { request, limit in log.append(request); return try network.fetch(request, limit: limit) } },
            subtitles: subtitles, retryDelay: .zero))
    }

    static func scratchLayout() -> OfflineStorageLayout {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("offline-tests-\(UUID().uuidString)", isDirectory: true)
        return OfflineStorageLayout(root: base.appendingPathComponent("OfflineMedia", isDirectory: true),
                                    temporaryRoot: base.appendingPathComponent("tmp/WebHTVOfflineDownloads", isDirectory: true))
    }

    /// The same storage and transport after a relaunch: a fresh manager reading the same disk.
    func relaunched(network: FakeNetwork = FakeNetwork()) -> OfflineHarness {
        OfflineHarness(network: network, capacity: capacity.get(), layout: layout, transport: transport)
    }

    func waitFor(_ id: String, _ state: OfflineAssetState, timeout: Duration = .seconds(5)) async -> OfflineAsset? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let asset = await manager.asset(id), asset.state == state { return asset }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await manager.asset(id)
    }

    func waitForSubmissions(_ count: Int, assetID: String? = nil, timeout: Duration = .seconds(5)) async -> [OfflineTransferRequest] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let submitted = await transport.submitted.filter { assetID == nil || $0.tag.assetID == assetID }
            if submitted.count >= count { return submitted }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await transport.submitted.filter { assetID == nil || $0.tag.assetID == assetID }
    }

    func folderExists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: layout.folder(for: id).path)
    }
}

enum Fixture {
    static let master = URL(string: "https://cdn.example.com/show/ep1/master.m3u8?sig=abc")!

    static func identity(_ episode: String = "ep1") -> OfflineIdentity {
        OfflineIdentity(historyKey: "site\u{0}{}@@@vod1", flag: "線路①", episodeURL: "https://source.example.com/\(episode)")
    }

    static func title(_ episode: String = "第01集", index: Int = 0) -> OfflineTitleInfo {
        OfflineTitleInfo(siteKey: "site", siteName: "站", sourceID: "config", vodId: "vod1", vodName: "片",
                         vodPic: "", episodeName: episode, episodeIndex: index)
    }

    static func variant(_ width: Int?, _ height: Int?, codecs: String = "avc1.640028,mp4a.40.2", bandwidth: Int,
                        average: Int? = nil, fps: Double? = nil, range: String? = nil, audio: String? = nil,
                        subtitles: String? = nil, uri: String) -> String {
        var attributes = ["BANDWIDTH=\(bandwidth)"]
        if let average { attributes.append("AVERAGE-BANDWIDTH=\(average)") }
        if let width, let height { attributes.append("RESOLUTION=\(width)x\(height)") }
        attributes.append("CODECS=\"\(codecs)\"")
        if let fps { attributes.append("FRAME-RATE=\(fps)") }
        if let range { attributes.append("VIDEO-RANGE=\(range)") }
        if let audio { attributes.append("AUDIO=\"\(audio)\"") }
        if let subtitles { attributes.append("SUBTITLES=\"\(subtitles)\"") }
        return "#EXT-X-STREAM-INF:" + attributes.joined(separator: ",") + "\n" + uri
    }

    static func masterText(_ lines: [String]) -> String {
        (["#EXTM3U", "#EXT-X-VERSION:6"] + lines).joined(separator: "\n") + "\n"
    }

    /// A finished media playlist of `count` segments, `prefix` naming the files.
    static func media(_ count: Int, prefix: String = "seg", ext: String = "ts", duration: Double = 6,
                      extra: [String] = []) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:6", "#EXT-X-MEDIA-SEQUENCE:0"] + extra
        for index in 0..<count { lines += ["#EXTINF:\(duration),", "\(prefix)\(index).\(ext)"] }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    static func target(_ url: URL = master, headers: [String: String] = [:],
                       subtitles: [SourceSubtitle] = []) -> PlaybackTarget {
        PlaybackTarget(url: url, headers: headers, subtitles: subtitles)
    }

    /// A segment body that is not HTML.
    static func segment(_ size: Int = 188 * 4) -> Data { Data([0x47] + Array(repeating: 0x11, count: size - 1)) }

    /// A simple HLS stream: master with 1080p and 720p, each four segments.
    static func simpleNetwork(base: String = "https://cdn.example.com/show/ep1/") -> FakeNetwork {
        FakeNetwork([
            master.absoluteString: .text(masterText([
                variant(1920, 1080, codecs: "hvc1.1.6.L120.90,mp4a.40.2", bandwidth: 4_000_000, average: 2_500_000, uri: "1080/index.m3u8"),
                variant(1280, 720, codecs: "hvc1.1.6.L93.90,mp4a.40.2", bandwidth: 2_000_000, average: 1_200_000, uri: "720/index.m3u8"),
            ])),
            base + "1080/index.m3u8": .text(media(4)),
            base + "720/index.m3u8": .text(media(4)),
        ])
    }
}

extension OfflineHarness {
    /// Queues the simple fixture and drives it to `downloading`; answers the asset and its requests.
    func startSimpleDownload(identity: OfflineIdentity = Fixture.identity(), autoDelete: Bool = true,
                             target: PlaybackTarget = Fixture.target()) async -> (OfflineAsset, [OfflineTransferRequest]) {
        await manager.start()
        let result = await manager.enqueue(identity: identity, title: Fixture.title(), target: target,
                                           choice: OfflineDownloadChoice(mode: .smart),
                                           estimate: OfflineSizeEstimate(bytes: 1_000_000, basis: .averageBandwidth),
                                           autoDeleteAfterWatching: autoDelete, allowsCellular: false)
        guard case .created(let asset) = result else { fatalError("not created: \(result)") }
        _ = await waitFor(asset.id, .downloading)
        return (asset, await waitForSubmissions(4, assetID: asset.id))
    }

    /// Finishes every outstanding transfer with segment bytes and waits for `completed`.
    func completeAll(_ id: String) async -> OfflineAsset? {
        await transport.finishAll(where: { $0.tag.assetID == id }) { _ in Fixture.segment() }
        return await waitFor(id, .completed)
    }
}
