import Foundation
import Testing
@testable import WebHTVCore

/// Golden test for the first ported `csp_*` spider.
///
/// The reference is the live API the Android original talks to, reached with the same host, key and
/// IV from the same `ext`. The port is held to the *semantics* the app consumes — CatVod JSON
/// shape, class list, list fields, detail fields, the `$$$`/`#` play encoding and a playable URL —
/// not to byte-identical JSON or key order, which the original never guaranteed either.
///
/// Gated on `CSP_GOLDEN_SITE` so the suite stays offline by default; these providers have proven
/// volatile all through this project, and a dead host must not read as a regression.
///
///     CSP_GOLDEN_SITE='{"key":"不戳","name":"不戳","type":3,"api":"csp_AppGet",
///       "ext":{"url":"https://appcmszbc.zbc4k.app","dataKey":"pYrEkiWRYhBLTUTC","dataIv":"pYrEkiWRYhBLTUTC"}}' \
///       swift test --package-path ios --filter Golden
private func goldenSite() throws -> Site? {
    guard let raw = ProcessInfo.processInfo.environment["CSP_GOLDEN_SITE"] else { return nil }
    return try JSONDecoder().decode(Site.self, from: Data(raw.utf8))
}

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

/// The addresses in a `playerContent` result's `url`, whichever of CatVod's three shapes it used.
/// `PlayURL` is the production decoder; this only has to be able to read the same JSON back.
private func playURL(_ value: Any?) -> [String] {
    if let text = value as? String { return [text] }
    if let pairs = value as? [Any] {
        return stride(from: 1, to: pairs.count, by: 2).compactMap { pairs[$0] as? String }
    }
    if let object = value as? [String: Any], let values = object["values"] as? [[String: Any]] {
        return values.compactMap { $0["v"] as? String }
    }
    return []
}

@Test func appGetDrivesTheWholeCatVodFlowAgainstTheLiveSite() async throws {
    guard let site = try goldenSite() else { return }
    let session = try CSPSourceResolver().session(for: site)

    // --- home: the class list the UI renders -------------------------------
    let home = try await object(session.home())
    let classes = try #require(home["class"] as? [[String: Any]])
    #expect(!classes.isEmpty, "home must return categories")
    for entry in classes {
        #expect((entry["type_id"] as? String)?.isEmpty == false)
        #expect((entry["type_name"] as? String)?.isEmpty == false)
        // The original hides these; the port must hide them too or the class list differs.
        #expect(!["伦理", "福利", "小影院"].contains(entry["type_name"] as? String ?? ""))
    }
    print("[golden] home classes: \(classes.compactMap { $0["type_name"] as? String })")

    // --- category: paged list ---------------------------------------------
    let tid = try #require(classes.first(where: { ($0["type_id"] as? String) != "0" })?["type_id"] as? String)
    let category = try await object(session.category(tid: tid, page: "1"))
    let list = try #require(category["list"] as? [[String: Any]])
    #expect(!list.isEmpty, "category \(tid) returned nothing")
    #expect(category["page"] as? Int == 1)
    for item in list {
        #expect((item["vod_id"] as? String)?.isEmpty == false)
        #expect(item["vod_name"] is String)
        #expect(item["vod_pic"] is String)
        #expect(item["vod_remarks"] is String)
    }
    print("[golden] category \(tid): \(list.count) items, first=\(list[0]["vod_name"] ?? "")")

    // --- detail: flags and the $$$ / # play encoding -----------------------
    // Some listings lead with a promo tile that has no playable detail, so take the first id
    // that actually resolves rather than assuming index 0.
    var detail: [String: Any]?
    for candidate in list.prefix(4) {
        guard let id = candidate["vod_id"] as? String else { continue }
        let decoded = try await object(session.detail(ids: [id]))
        if let first = (decoded["list"] as? [[String: Any]])?.first,
           (first["vod_play_url"] as? String)?.isEmpty == false {
            detail = first
            break
        }
    }
    let vod = try #require(detail, "no listed title produced a playable detail")
    let froms = (vod["vod_play_from"] as? String ?? "").components(separatedBy: "$$$")
    let urls = (vod["vod_play_url"] as? String ?? "").components(separatedBy: "$$$")
    #expect((vod["vod_name"] as? String)?.isEmpty == false)
    #expect(!froms.isEmpty)
    // The two lists are zipped positionally by the app's Vod.flags; a mismatch breaks every episode.
    #expect(froms.count == urls.count)
    let episodes = try #require(urls.first).components(separatedBy: "#")
    #expect(!episodes.isEmpty)
    // Each episode is `name$target`, which is what Episode.parse expects.
    #expect(episodes.allSatisfy { $0.contains("$") })
    print("[golden] detail \(vod["vod_name"] ?? ""): flags=\(froms), episodes=\(episodes.count)")

    // --- search ------------------------------------------------------------
    let search = try await object(session.search(key: "我"))
    let results = try #require(search["list"] as? [[String: Any]])
    print("[golden] search 我: \(results.count) results")
    for item in results.prefix(5) {
        #expect((item["vod_id"] as? String)?.isEmpty == false)
    }

    // --- player: a real playable URL ---------------------------------------
    let episode = try #require(episodes.first)
    let target = String(episode.drop(while: { $0 != "$" }).dropFirst())
    let play = try await object(session.player(flag: froms.first ?? "", id: target))
    // `url` is three shapes, not one (`PlayURL`), so reading it as a String would fail this test on
    // any source that answers with a quality list rather than a single address.
    let url = try #require(playURL(play["url"]).first)
    #expect(play["parse"] != nil)
    print("[golden] player: parse=\(play["parse"] ?? "") url=\(url.prefix(90))")
    if play["parse"] as? Int == 0 {
        // parse:0 promises a directly playable stream, so it must look like one.
        #expect(url.hasPrefix("http"))
        #expect(url.contains(".m3u8") || url.contains(".mp4") || url.contains(".mkv") || url.contains(".flv"))
        // Headers travel with the URL, which is what the player needs for a referer-checked CDN.
        #expect(play["header"] != nil)
    }

    await session.destroy()
}

/// The same live flow, driven by a script that arrived as a **compatibility pack** rather than from
/// the app bundle. This is the claim the whole IOS-POC-5O architecture rests on: a pack is not a
/// second-class path, it is the path, and a script delivered that way drives a real site end to end.
///
/// The bytes are the bundled script, published through the pack machinery with its真 SHA-256, so the
/// test exercises manifest parsing, hash verification, atomic install and registry override, and
/// then asks the result to go and fetch from the live provider.
@Test func aSpiderDeliveredAsACompatibilityPackDrivesTheLiveSite() async throws {
    guard let site = try goldenSite() else { return }
    let className = SpiderRegistry.className(from: site.api)
    let bundled = try #require(SpiderRegistry.bundled().entry(for: site.api)?.script,
                               "this test publishes the bundled script through the pack path")

    let manifestURL = URL(string: "https://example.invalid/spiders/manifest.json")!
    let scriptURL = "https://example.invalid/spiders/\(className).js"
    let digest = SpiderPackStore.sha256(Data(bundled.utf8))
    let manifest = """
    {"schema": \(SpiderPack.schema), "version": "golden", "scripts": [
      {"class": "\(className)", "path": "./\(className).js", "sha256": "\(digest)",
       "originJar": "river-fman.jar", "notes": "published by the golden test"}]}
    """
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("golden-pack-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("SpiderPack", isDirectory: true)
    let store = SpiderPackStore(directory: directory) { url in
        let body = url.absoluteString == manifestURL.absoluteString ? manifest : bundled
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    }

    let pack = try await store.refresh(from: manifestURL)
    let registry = SpiderRegistry.bundled(overlaying: pack)
    #expect(registry.entry(for: site.api)?.source == .pack(version: "golden"))

    let session = try CSPSourceResolver(registry: registry).session(for: site)
    let home = try await object(session.home())
    let classes = try #require(home["class"] as? [[String: Any]])
    #expect(!classes.isEmpty)
    let tid = try #require(classes.first(where: { ($0["type_id"] as? String) != "0" })?["type_id"] as? String)
    let list = try #require(try await object(session.category(tid: tid, page: "1"))["list"] as? [[String: Any]])
    #expect(!list.isEmpty)

    var play: [String: Any]?
    for candidate in list.prefix(4) {
        guard let id = candidate["vod_id"] as? String,
              let vod = (try await object(session.detail(ids: [id]))["list"] as? [[String: Any]])?.first,
              let urls = vod["vod_play_url"] as? String, !urls.isEmpty,
              let first = urls.components(separatedBy: "$$$").first?.components(separatedBy: "#").first
        else { continue }
        let target = String(first.drop(while: { $0 != "$" }).dropFirst())
        let flag = (vod["vod_play_from"] as? String)?.components(separatedBy: "$$$").first ?? ""
        play = try await object(session.player(flag: flag, id: target))
        break
    }
    let resolved = try #require(play, "no listed title produced a playable episode")
    print("[golden-pack] \(className) home=\(classes.count) list=\(list.count) " +
          "play=\(String(describing: resolved["url"]).prefix(90))")
    #expect((resolved["url"] as? String)?.isEmpty == false)
    let search = try await object(session.search(key: "我"))
    #expect(search["list"] is [[String: Any]])

    await session.destroy()
    await store.reset()
}

/// The registry must only ever claim classes it can genuinely drive; everything else stays absent so
/// the app reports "not ported" rather than failing at the first call.
@Test func registryClaimsOnlyWhatIsActuallyPorted() {
    let registry = SpiderRegistry.bundled()
    #expect(registry.portedClasses ==
            ["App3Q", "App99", "AppGet", "AppQi", "Bili", "JPianAmns", "JianPian", "XBPQ", "XYQHiker"])
    #expect(!registry.prelude.isEmpty)
    let entry = registry.entry(for: "csp_AppGet")
    #expect(entry?.portability == .httpCrypto)
    #expect(entry?.origin.contains("river-fman.jar") == true)
    #expect(registry.canDrive("csp_XBPQ"))
    // IOS-POC-5L: every script the registry names must have actually loaded from the bundle.
    #expect(registry.entry(for: "csp_Bili")?.portability == .httpJSON)
    #expect(registry.entry(for: "csp_App99")?.origin.contains("xiaosa-0807.jar") == true)
    // IOS-POC-5M: the alias must load JianPian's script, not an empty entry for a name with no file.
    #expect(registry.entry(for: "csp_JPianAmns")?.script == registry.entry(for: "csp_JianPian")?.script)
    #expect(registry.entry(for: "csp_JPianAmns")?.script.contains("crumb/list") == true)
    #expect(registry.canDrive("csp_NotAThing") == false)
}

/// IOS-POC-5Q Q2, and the gate for its success condition S3: a bilibili episode must offer more
/// than one quality, each as its own line carrying its own `qn`, best first — and the best one must
/// actually serve bytes.
///
/// Its own test rather than the generic golden above, because that one asserts the shape every
/// spider shares and would pass while pointed at `csp_Bili` without checking a single quality.
///
///     CSP_GOLDEN_SITE='{"key":"bili","name":"bili","type":3,"api":"csp_Bili"}' \
///       swift test --package-path ios --filter biliOffersMultipleQualityLines
///
/// `ext` may be omitted: the flow below searches rather than browsing the site's home document, so
/// it needs neither `ext.json` nor a remote configuration base to resolve one.
@Test func biliOffersMultipleQualityLines() async throws {
    guard let site = try goldenSite(), SpiderRegistry.className(from: site.api) == "Bili" else { return }
    let session = try CSPSourceResolver().session(for: site)

    let search = try await object(session.search(key: "音樂"))
    let results = try #require(search["list"] as? [[String: Any]])
    var lines = [(name: String, episodes: [String])]()
    for hit in results.prefix(5) {
        guard let id = hit["vod_id"] as? String else { continue }
        let detail = try await object(session.detail(ids: [id]))
        guard let vod = (detail["list"] as? [[String: Any]])?.first else { continue }
        let froms = (vod["vod_play_from"] as? String ?? "").components(separatedBy: "$$$")
        let urls = (vod["vod_play_url"] as? String ?? "").components(separatedBy: "$$$")
        guard froms.count == urls.count, froms.count > 1 else { continue }
        lines = zip(froms, urls).map { ($0, $1.components(separatedBy: "#")) }
        print("[golden] bili \(vod["vod_name"] ?? ""): lines=\(froms)")
        break
    }
    // Every quality above 360P needs a session bilibili may refuse today. A run that finds only
    // single-quality videos measures the account, not this port, so it must not read as a failure.
    guard !lines.isEmpty else {
        print("[golden] bili: no searched title offered more than one quality — nothing to assert")
        return
    }

    // Each line is one quality, so its episodes carry that line's own `qn` in their target.
    let qns = try lines.map { line -> Int in
        let episode = try #require(line.episodes.first)
        let target = String(episode.drop(while: { $0 != "$" }).dropFirst())
        let qn = try #require(target.components(separatedBy: "+").last.flatMap { Int($0) })
        #expect(line.name.hasPrefix("B站 "))
        return qn
    }
    #expect(Set(qns).count == qns.count, "two lines shared a qn, so one of them is unreachable")
    #expect(qns == qns.sorted(by: >), "lines must be ordered best first: \(qns)")
    #expect(try #require(qns.first) == qns.max())

    // The first line is the one the player will open by default, so it is the one that must play.
    let best = try #require(lines.first)
    let episode = try #require(best.episodes.first)
    let target = String(episode.drop(while: { $0 != "$" }).dropFirst())
    let play = try await object(session.player(flag: best.name, id: target))
    let url = try #require(playURL(play["url"]).first)
    let headers = play["header"] as? [String: String] ?? [:]
    print("[golden] bili player qn=\(qns.first ?? 0): \(url.prefix(90)) +hdr\(headers.count)")
    #expect(play["parse"] as? Int == 0)
    let resolved = try #require(URL(string: url))
    #expect(await MediaProbe.classify(resolved, headers: headers) == .media)

    await session.destroy()
}
