import Foundation
import Testing
@testable import WebHTVCore

// W-127 (IOS-POC-59 U4, D§6.5): the last channel and the favourites, per configuration and live source, in
// `Application Support/LiveTV/live-state.json`; a broken file is set aside, never written over.

private func scratch() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("live-state-\(UUID().uuidString)")
}

private func channel(_ name: String, labels: [String?] = [nil], support: LineSupport = .playable) -> LiveChannel {
    LiveChannel(name: name, lines: labels.map { LiveLine(url: "http://x/" + name, label: $0, headers: [:], support: support) })
}

private func group(_ name: String, _ channels: [LiveChannel], password: String? = nil) -> LiveGroup {
    LiveGroup(name: name, password: password, channels: channels)
}

@Test func theLastChannelAndFavouritesAreReadBackFromDisk() async {
    let directory = scratch()
    let last = LiveLastChannel(group: "央視", channel: "CCTV1", lineLabel: "高清", lineIndex: 1)
    let store = LiveStateStore(directory: directory)
    await store.setLast(last, config: "a", live: "源1")
    #expect(await store.toggleFavorite("CCTV1", config: "a", live: "源1") == ["CCTV1"])
    #expect(await store.toggleFavorite("CCTV2", config: "a", live: "源1") == ["CCTV1", "CCTV2"])

    let reopened = LiveStateStore(directory: directory)
    #expect(await reopened.last(config: "a", live: "源1") == last)
    #expect(await reopened.lastLive(config: "a") == "源1")
    #expect(await reopened.favorites(config: "a", live: "源1") == ["CCTV1", "CCTV2"])
    #expect(await reopened.toggleFavorite("CCTV1", config: "a", live: "源1") == ["CCTV2"])
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("live-state.json").path))
}

@Test func configurationsAndLiveSourcesDoNotShareState() async {
    let store = LiveStateStore(directory: scratch())
    await store.setLast(LiveLastChannel(group: "g", channel: "x", lineLabel: nil, lineIndex: 0), config: "a", live: "源1")
    _ = await store.toggleFavorite("CCTV1", config: "a", live: "源1")
    await store.setLastLive("源2", config: "b")
    // X-9: the same channel name in another live source, or another configuration, is not a favourite.
    #expect(await store.favorites(config: "a", live: "源2") == [])
    #expect(await store.favorites(config: "b", live: "源1") == [])
    #expect(await store.last(config: "b", live: "源1") == nil)
    #expect(await store.lastLive(config: "a") == "源1")
    #expect(await store.lastLive(config: "b") == "源2")
}

@Test func aFileThatIsNotThisFormatIsSetAsideAndStartedAfresh() async throws {
    let directory = scratch()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("garbage".utf8).write(to: directory.appendingPathComponent("live-state.json"))
    let store = LiveStateStore(directory: directory)
    #expect(await store.lastLive(config: "a") == nil)
    let moved = try #require(await store.setAside)
    #expect(moved.hasPrefix("live-state.corrupt-") && moved.hasSuffix(".json"))
    #expect(try String(contentsOf: directory.appendingPathComponent(moved), encoding: .utf8) == "garbage")
    #expect(await store.toggleFavorite("CCTV1", config: "a", live: "源1") == ["CCTV1"])
}

@Test func aNewerSchemaIsBackedUpAndReadAsEmpty() async throws {
    let directory = scratch()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let newer = #"{"schemaVersion":9,"configs":{"a":{"lastLive":"源1","last":{},"favorites":{"源1":["CCTV1"]}}}}"#
    try Data(newer.utf8).write(to: directory.appendingPathComponent("live-state.json"))
    let store = LiveStateStore(directory: directory)
    #expect(await store.favorites(config: "a", live: "源1") == [])
    #expect(await store.backedUp == "live-state.schema9.backup.json")
    #expect(try String(contentsOf: directory.appendingPathComponent("live-state.schema9.backup.json"), encoding: .utf8) == newer)
}

@Test func theLastChannelIsFoundInItsGroupThenAnyOtherThenNowhere() {
    let groups = [group("新聞", [channel("CCTV13")]), group("央視", [channel("CCTV1"), channel("CCTV2", labels: ["甲", "高清", nil])]),
                  group("其他", [channel("CCTV2")])]
    // Its own group first, its line by label.
    #expect(LiveLastChannel(group: "央視", channel: "CCTV2", lineLabel: "高清", lineIndex: 0).locate(in: groups)
            == LivePosition(group: 1, channel: 1, line: 1))
    #expect(LiveLastChannel(group: "其他", channel: "CCTV2", lineLabel: nil, lineIndex: 0).locate(in: groups)
            == LivePosition(group: 2, channel: 0, line: 0))
    // The label gone: the index; out of range: line 0.
    #expect(LiveLastChannel(group: "央視", channel: "CCTV2", lineLabel: "乙", lineIndex: 2).locate(in: groups)
            == LivePosition(group: 1, channel: 1, line: 2))
    #expect(LiveLastChannel(group: "央視", channel: "CCTV2", lineLabel: nil, lineIndex: 7).locate(in: groups)
            == LivePosition(group: 1, channel: 1, line: 0))
    // The group renamed: the first other group with the channel.
    #expect(LiveLastChannel(group: "舊名", channel: "CCTV2", lineLabel: nil, lineIndex: 0).locate(in: groups)
            == LivePosition(group: 1, channel: 1, line: 0))
    // Gone from the list, or no line iOS can try any more: nothing to continue.
    #expect(LiveLastChannel(group: "央視", channel: "CCTV9", lineLabel: nil, lineIndex: 0).locate(in: groups) == nil)
    let unusable = [group("央視", [channel("CCTV1", support: .unsupported(.drm))])]
    #expect(LiveLastChannel(group: "央視", channel: "CCTV1", lineLabel: nil, lineIndex: 0).locate(in: unusable) == nil)
}

@Test func theFavouritesGroupLeadsWithEachFavouriteOnceFromTheVisibleGroups() {
    let visible = [group("央視", [channel("CCTV1"), channel("CCTV2")]), group("其他", [channel("CCTV1"), channel("鳳凰")])]
    let shown = visible.withFavorites(["鳳凰", "CCTV1", "不在清單"])
    #expect(shown.map(\.name) == [LiveGroup.favoritesName, "央視", "其他"])
    // X-11: the first occurrence only, in the order favourited; one missing from the list stays stored but unshown.
    #expect(shown[0].channels.map(\.name) == ["鳳凰", "CCTV1"])
    #expect(visible.withFavorites([]) == visible)
    #expect(visible.withFavorites(["不在清單"]) == visible)
}
