import Foundation
import Testing
@testable import WebHTVCore

// W-277: local sites (design W-275 §4.4, user choice 1b — they follow the configuration source).

@Test func oneAPIWrittenSeveralWaysIsOneSite() {
    let same = ["https://Example.com:443/api.php/provide/vod/at/xml/", "http://example.com/api.php/provide/vod?ac=list",
                "https://example.com/api.php/provide/vod/", "http://example.com:80//api.php//provide/vod/at/json#top"]
    #expect(Set(same.map(LocalSites.normalizedAPI)) == ["//example.com/api.php/provide/vod"])
    // Different hosts, paths, path case and kept ports stay apart.
    #expect(LocalSites.normalizedAPI("https://www.example.com/api.php/provide/vod/") == "//www.example.com/api.php/provide/vod")
    #expect(LocalSites.normalizedAPI("https://example.com/inc/api.php") == "//example.com/inc/api.php")
    #expect(LocalSites.normalizedAPI("https://example.com/API.php/provide/vod") == "//example.com/API.php/provide/vod")
    #expect(LocalSites.normalizedAPI("https://example.com:8443/api.php") == "//example.com:8443/api.php")
    #expect(LocalSites.normalizedAPI("http://example.com:443/api.php") == "//example.com:443/api.php")
    // Protocol parameters go, the rest is sorted and kept.
    #expect(LocalSites.normalizedAPI("https://example.com/api.php?b=2&at=xml&a=1&pg=3&wd=x&key")
        == "//example.com/api.php?a=1&b=2&key")
    #expect(LocalSites.normalizedAPI("ftp://example.com/api.php") == nil)
    #expect(LocalSites.normalizedAPI("csp_XBPQ") == nil)
}

@Test func aLocalKeyIsStableAndNeverAConfigurationsKey() throws {
    let key = try #require(LocalSites.key(forAPI: "https://example.com/api.php/provide/vod/"))
    #expect(key.hasPrefix("local_") && key.count == 16)
    #expect(LocalSites.key(forAPI: "http://EXAMPLE.com/api.php/provide/vod/at/xml") == key)
    #expect(LocalSites.key(forAPI: "https://other.com/api.php/provide/vod/") != key)

    let site = try #require(LocalSite(name: "測試", type: 0, api: "http://example.com/api.php/provide/vod/at/xml/", detectedFrom: "x")?.site)
    #expect(site.key == key && site.type == 0 && site.isNativeCMS && site.isSearchable && LocalSites.isLocal(site))
}

private func remoteSites(_ json: String) throws -> [Site] {
    try JSONDecoder().decode([Site].self, from: Data(json.utf8))
}

@Test func aRemoteSiteWithTheSameAPIHidesTheLocalOne() throws {
    let remote = try remoteSites(#"[{"key":"a","name":"A","type":1,"api":"https://a.com/api.php/provide/vod/"},{"key":"x","name":"X","type":3,"api":"csp_XBPQ"}]"#)
    let shadowed = try #require(LocalSite(name: "A 本機", type: 0, api: "http://a.com/api.php/provide/vod/at/xml", detectedFrom: ""))
    let own = try #require(LocalSite(name: "B", type: 1, api: "https://b.com/api.php/provide/vod/", detectedFrom: ""))
    let merged = LocalSites.merged(remote, with: [shadowed, own])
    #expect(merged.map(\.key) == ["a", "x", own.key])
    #expect(LocalSites.isShadowed(shadowed, by: LocalSites.remoteAPIs(remote)))
}

@Test func localSitesFollowTheirSourceAndGoWithIt() throws {
    let site = try #require(LocalSite(name: "甲", type: 1, api: "https://a.com/api.php/provide/vod/", detectedFrom: ""))
    let again = try #require(LocalSite(name: "甲改名", type: 1, api: "http://a.com/api.php/provide/vod", detectedFrom: ""))
    var store = LocalSiteStore()
    store.upsert(site, for: "A")
    store.upsert(again, for: "A")
    #expect(store.sites(for: "A").map(\.name) == ["甲改名"])
    #expect(store.sites(for: "B").isEmpty)
    store.rename(key: site.key, to: "乙", for: "A")
    #expect(store.sites(for: "A").first?.name == "乙")

    let file = FileManager.default.temporaryDirectory.appendingPathComponent("local-sites-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(LocalSiteStore.load(from: file) == LocalSiteStore())
    try store.save(to: file)
    #expect(LocalSiteStore.load(from: file) == store)

    store.upsert(site, for: "B")
    store.forget(source: "A")
    #expect(store.sites(for: "A").isEmpty && store.sites(for: "B").count == 1)
    store.remove(key: site.key, for: "B")
    #expect(store.bySource.isEmpty)
}
