import Testing
@testable import WebHTVCore

// W-126 (IOS-POC-59 U3): which channel a swipe or the 上一台／下一台 buttons go to — within the group, wrapping,
// past channels with no line iOS can try (Android's default: no crossing groups).

private func channel(_ name: String, _ support: LineSupport) -> LiveChannel {
    LiveChannel(name: name, lines: [LiveLine(url: "http://x/" + name, label: nil, headers: [:], support: support)])
}

@Test func zappingWrapsWithinTheGroupAndSkipsUnusableChannels() {
    let channels = [channel("a", .playable), channel("b", .unsupported(.drm)), channel("c", .attempt), channel("d", .playable)]
    #expect(channels.zap(from: 0, by: 1) == 2)
    #expect(channels.zap(from: 2, by: 1) == 3)
    #expect(channels.zap(from: 3, by: 1) == 0)
    #expect(channels.zap(from: 0, by: -1) == 3)
    #expect(channels.zap(from: 2, by: -1) == 0)
}

@Test func zappingHasNowhereToGoAlone() {
    #expect([channel("a", .playable)].zap(from: 0, by: 1) == nil)
    #expect([channel("a", .playable), channel("b", .unsupported(.p2p))].zap(from: 0, by: -1) == nil)
    #expect([LiveChannel]().zap(from: 0, by: 1) == nil)
    // A channel without lines at all (an m3u #EXTINF with no address) is skipped too.
    #expect([channel("a", .playable), LiveChannel(name: "e", lines: []), channel("c", .playable)].zap(from: 0, by: 1) == 2)
}
