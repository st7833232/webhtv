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
    let url = try #require(play["url"] as? String)
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

/// The registry must only ever claim classes it can genuinely drive; everything else stays absent so
/// the app reports "not ported" rather than failing at the first call.
@Test func registryClaimsOnlyWhatIsActuallyPorted() {
    let registry = SpiderRegistry.bundled()
    #expect(registry.portedClasses == ["AppGet", "XBPQ", "XYQHiker"])
    #expect(!registry.prelude.isEmpty)
    let entry = registry.entry(for: "csp_AppGet")
    #expect(entry?.portability == .httpCrypto)
    #expect(entry?.origin.contains("river-fman.jar") == true)
    #expect(registry.canDrive("csp_XBPQ"))
    #expect(registry.canDrive("csp_NotAThing") == false)
}

/// Sweeps **every** configured spider site through the exact path the app uses (`SourceClient`),
/// reporting where each one stops instead of asserting. Exists because IOS-POC-5D was first reported
/// as "15 sites work" on the strength of four hand-checked sites; this is the cheap way to know.
///
///     SPIDER_SWEEP_CONFIG=/path/wang-movie.json SPIDER_SWEEP_BASE=https://…/wang-movie.json \
///       swift test --package-path ios --filter sweepsEveryPortedSpiderSite
@Test func sweepsEveryPortedSpiderSiteThroughTheAppPath() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["SPIDER_SWEEP_CONFIG"] else { return }
    let config = try JSONDecoder().decode(WebHTVConfig.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    // A rule-engine site resolves a relative `ext` against the config's own directory, so the sweep
    // must run with the same remote source the app had — otherwise those sites fail for the wrong reason.
    let source: ConfigSource = env["SPIDER_SWEEP_BASE"].flatMap { URL(string: $0) }.map { .remote($0) } ?? .importedFile
    let resolver = CSPSourceResolver(source: source)

    for site in config.spiderSites(resolvedBy: resolver) {
        var line = "[sweep] \(site.api.replacingOccurrences(of: "csp_", with: "")) \(site.key): "
        do {
            let client = try await SourceClient.make(site: site, resolver: resolver)
            let home = try await client.home()
            line += "classes=\(home.classes.count) home=\(home.list.count)"
            if let first = home.list.first { line += " first=\(first.name)" }
            if home.list.isEmpty {
                print(line + "  -> EMPTY HOME"); continue
            }
            let detail = try await client.detail(id: first(home).id)
            let flags = detail?.flags ?? []
            line += " | flags=\(flags.count) eps=\(flags.first?.episodes.count ?? 0)"
            guard let episode = flags.first?.episodes.first, let flag = flags.first?.name else {
                print(line + "  -> NO EPISODE"); continue
            }
            let url = try await client.playbackURL(for: episode, flag: flag)
            line += " | play=\(url?.absoluteString.prefix(70) ?? "nil")"
            print(line)
        } catch {
            print(line + "  -> ERROR \(error)")
        }
    }
}

private func first(_ response: CMSResponse) -> Vod { response.list[0] }
