import Foundation
import Testing
@testable import WebHTVCore

// W-124 (IOS-POC-59 U1, AC-5 to AC-7, AC-24): the W-92 lists, which never enter the repository.
// Runs only when WEBHTV_LIVE_FIXTURES names their `raw/lists` folder (the configuration sits at
// `../config-wang-movie.json`). Prints numbers only: no group, channel, address or header value.

private struct Stats {
    var groups = 0, channels = 0, lines = 0, emptyGroups = 0
    var hiddenGroups = 0, hiddenChannels = 0, hiddenLines = 0
    var playable = 0, attempt = 0, deadChannels = 0
    var reasons: [String: Int] = [:]

    init(_ playlist: LivePlaylist) {
        groups = playlist.groups.count
        for group in playlist.groups {
            if group.channels.isEmpty { emptyGroups += 1 }
            let lineCount = group.channels.reduce(0) { $0 + $1.lines.count }
            if group.isHidden { hiddenGroups += 1; hiddenChannels += group.channels.count; hiddenLines += lineCount }
            channels += group.channels.count
            lines += lineCount
            for channel in group.channels {
                if channel.isUnsupported { deadChannels += 1 }
                for line in channel.lines {
                    switch line.support {
                    case .playable: playable += 1
                    case .attempt: attempt += 1
                    case .unsupported(let reason): reasons["\(reason)", default: 0] += 1
                    }
                }
            }
        }
    }
}

/// Channels and lines that carry a user agent from the list itself: parse with the source's own
/// user agent and header removed, so any user agent left came from the list.
private func listUserAgents(_ data: Data, _ source: LiveSource) throws -> (channels: [(group: Int, lines: Int)], lines: Int) {
    var bare = source
    bare.ua = nil
    bare.header = [:]
    let playlist = try LivePlaylistParser.parse(data, source: bare)
    var channels: [(group: Int, lines: Int)] = []
    for (index, group) in playlist.groups.enumerated() {
        for channel in group.channels {
            let count = channel.lines.filter { $0.headers["User-Agent"] != nil }.count
            if count > 0 { channels.append((index, count)) }
        }
    }
    return (channels, channels.reduce(0) { $0 + $1.lines })
}

@Test func realListsParseToTheAndroidCounts() throws {
    guard let folder = ProcessInfo.processInfo.environment["WEBHTV_LIVE_FIXTURES"] else { return }
    let lists = URL(fileURLWithPath: folder, isDirectory: true)
    let config = try ConfigLoader.decode(Data(contentsOf: lists.appendingPathComponent("../config-wang-movie.json")))
    #expect(config.lives.count == 20)

    #if DEBUG
    let build = "debug"
    #else
    let build = "release"
    #endif
    print("live lists (\(build)): # fmt G/C/L empty hidden(G/C/L) listUA(C/L) http attempt drm parse youtube p2p sniff proxy other dead ms(median of 5)")
    var results: [Int: (stats: Stats, listUA: (channels: [(group: Int, lines: Int)], lines: Int), ms: Double)] = [:]
    for number in [3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 15, 17, 20] {
        let data = try Data(contentsOf: lists.appendingPathComponent(String(format: "L%02d.body", number)))
        let source = config.lives[number - 1]
        var times: [Double] = []
        var playlist = LivePlaylist(groups: [])
        for _ in 0..<5 {
            let start = ContinuousClock.now
            playlist = try LivePlaylistParser.parse(data, source: source)
            let elapsed = ContinuousClock.now - start
            times.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        let stats = Stats(playlist)
        let listUA = try listUserAgents(data, source)
        let ms = times.sorted()[2]
        results[number] = (stats, listUA, ms)
        let format = String(decoding: data.prefix(4096), as: UTF8.self).contains("#EXTM3U") ? "m3u" : "txt"
        let r = stats.reasons
        print(String(format: "#%d %@ %d/%d/%d %d %d(%d/%d) %d/%d %d %d %d %d %d %d %d %d %d %d %.1f",
                     number, format, stats.groups, stats.channels, stats.lines, stats.emptyGroups,
                     stats.hiddenGroups, stats.hiddenChannels, stats.hiddenLines, listUA.channels.count, listUA.lines,
                     stats.playable, stats.attempt, r["drm", default: 0], r["parse", default: 0], r["youtube", default: 0],
                     r["p2p", default: 0], r["sniff", default: 0], r["proxy", default: 0], r["other", default: 0],
                     stats.deadChannels, ms))
    }

    func gcl(_ number: Int) -> [Int] { results[number].map { [$0.stats.groups, $0.stats.channels, $0.stats.lines] } ?? [] }
    // AC-5 (W-92 G§3).
    #expect(gcl(8) == [11, 114, 114])
    #expect(gcl(9) == [15, 564, 2343])
    #expect(gcl(4) == [11, 1635, 1712])
    #expect(gcl(15) == [4, 49, 49])
    #expect(gcl(7) == [33, 1233, 1288])
    #expect(gcl(10) == [38, 7255, 9041])
    // AC-7: hidden groups as groups/channels/lines.
    #expect(results[7].map { [$0.stats.hiddenGroups, $0.stats.hiddenChannels, $0.stats.hiddenLines] } == [1, 38, 46])
    #expect(results[10].map { [$0.stats.hiddenGroups, $0.stats.hiddenChannels, $0.stats.hiddenLines] } == [4, 3299, 3331])
    // AC-6: #17's in-list `ua=` reaches exactly 1034 channels and 1070 lines, all in its 26th to
    // 30th groups, and every one of those lines needs a parse service.
    let seventeen = try #require(results[17])
    #expect(gcl(17) == [40, 4367, 6726])
    #expect(seventeen.stats.emptyGroups == 4)
    #expect(seventeen.listUA.channels.count == 1034)
    #expect(seventeen.listUA.lines == 1070)
    #expect(seventeen.listUA.channels.allSatisfy { (25...29).contains($0.group) })
    #expect(seventeen.stats.reasons["parse"] == 1070)
    #expect(results[8].map { $0.stats.playable } == 114)
    // tv123: three channels with their own user agent; 81 DRM lines.
    #expect(results[3].map { [$0.listUA.channels.count, $0.stats.reasons["drm", default: 0]] } == [3, 81])
}

@Test func seventeenUsesTheSourceAgentOutsideItsSettingGroupsAndShowsItsUnderscoreGroups() throws {
    guard let folder = ProcessInfo.processInfo.environment["WEBHTV_LIVE_FIXTURES"] else { return }
    let lists = URL(fileURLWithPath: folder, isDirectory: true)
    let config = try ConfigLoader.decode(Data(contentsOf: lists.appendingPathComponent("../config-wang-movie.json")))
    let source = config.lives[16]
    let data = try Data(contentsOf: lists.appendingPathComponent("L17.body"))
    let sourceUA = try #require(source.ua)
    #expect(source.pass)

    let playlist = try LivePlaylistParser.parse(data, source: source)
    let outside = playlist.groups.enumerated().filter { !(25...29).contains($0.offset) }.flatMap { $0.element.channels.flatMap(\.lines) }
    #expect(!outside.isEmpty)
    #expect(outside.allSatisfy { $0.headers["User-Agent"] == sourceUA })
    #expect(playlist.groups.allSatisfy { !$0.isHidden && $0.password == nil && !$0.name.contains("_") })

    // With `pass` off, the same list hides exactly its 15 underscore groups.
    var locked = source
    locked.pass = false
    #expect(try LivePlaylistParser.parse(data, source: locked).groups.filter(\.isHidden).count == 15)
}
