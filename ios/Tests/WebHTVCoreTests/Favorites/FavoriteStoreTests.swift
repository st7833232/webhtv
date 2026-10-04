import Foundation
import Testing
@testable import WebHTVCore

/// IOS-POC-48 fixtures, shared by the favourites tests.
enum FavoriteFixture {
    static let configA = "https://config.example/a.json"
    static let configB = "https://config.example/b.json"
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func directory(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("favorites-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    static func store(_ name: String) -> (FavoriteStore, URL) {
        let directory = directory(name)
        return (FavoriteStore(directory: directory), directory)
    }

    /// A type-1 site; `ext` is raw JSON, so `{…}` gives the structured identity.
    static func site(key: String, ext: String = #""https://api.example/x""#) throws -> Site {
        let json = #"{"key":"\#(key)","name":"\#(key)站","type":1,"api":"https://api.example/\#(key)","ext":\#(ext)}"#
        return try JSONDecoder().decode(Site.self, from: Data(json.utf8))
    }

    static func identity(config: String = configA, siteID: String = "s\u{0}{}", vod: String = "1") -> FavoriteIdentity {
        FavoriteIdentity(configSourceID: config, siteID: siteID, vodID: vod)
    }

    static func snapshot(name: String = "片", picture: String = "https://img.example/p.jpg",
                         remarks: String = "更新至8集", year: String = "2025", typeName: String = "国产剧",
                         director: String = "導演甲", actor: String = "演員甲", content: String = "簡介",
                         siteName: String = "站") -> FavoriteSnapshot {
        FavoriteSnapshot(name: name, picture: picture, remarks: remarks, year: year, area: "大陆",
                         typeName: typeName, director: director, actor: actor, content: content,
                         siteName: siteName, configSourceName: "設定A")
    }

    static func file(in directory: URL) -> URL { directory.appendingPathComponent("favorites.json") }

    static func write(_ text: String, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file(in: directory))
    }

    /// One favourite as the store writes it, for hand-built files.
    static func json(_ favorite: Favorite) throws -> String {
        String(decoding: try JSONEncoder().encode(favorite), as: UTF8.self)
    }
}

// MARK: - A5: one favourite per title, kept across launches, newest first

@Test func favoritingTheSameTitleTwiceKeepsOneFavorite() async throws {
    let (store, _) = FavoriteFixture.store("twice")
    let identity = FavoriteFixture.identity()
    await store.add(identity, snapshot: FavoriteFixture.snapshot(remarks: "更新至8集"), now: FavoriteFixture.t0)
    // A second tap, or a second detail screen of the same title, must not make a second favourite —
    // nor restart its place in the list.
    await store.add(identity, snapshot: FavoriteFixture.snapshot(remarks: "更新至9集"),
                    now: FavoriteFixture.t0.addingTimeInterval(60))

    let all = await store.all()
    #expect(all.count == 1)
    #expect(all.first?.createdAt == FavoriteFixture.t0)
    #expect(all.first?.remarks == "更新至9集")
}

@Test func favoritesSurviveARelaunch() async throws {
    let (store, directory) = FavoriteFixture.store("relaunch")
    let saved = try #require(await store.add(FavoriteFixture.identity(), snapshot: FavoriteFixture.snapshot(),
                                             now: FavoriteFixture.t0))
    // A new store over the same directory is what the next launch is.
    let relaunched = FavoriteStore(directory: directory)
    #expect(await relaunched.all() == [saved])
}

@Test func theMostRecentFavoriteComesFirst() async throws {
    let (store, _) = FavoriteFixture.store("order")
    for (vod, offset) in [("a", 0.0), ("b", 10), ("c", 5)] {
        await store.add(FavoriteFixture.identity(vod: vod), snapshot: FavoriteFixture.snapshot(),
                        now: FavoriteFixture.t0.addingTimeInterval(offset))
    }
    #expect(await store.all().map(\.identity.vodID) == ["b", "c", "a"])
}

@Test func removingAFavoriteRemovesOnlyThatFavorite() async throws {
    let (store, _) = FavoriteFixture.store("remove")
    await store.add(FavoriteFixture.identity(vod: "1"), snapshot: FavoriteFixture.snapshot(), now: FavoriteFixture.t0)
    await store.add(FavoriteFixture.identity(vod: "2"), snapshot: FavoriteFixture.snapshot(), now: FavoriteFixture.t0)
    let removed = await store.remove(FavoriteFixture.identity(vod: "1"))
    #expect(removed?.identity.vodID == "1")
    #expect(await store.all().map(\.identity.vodID) == ["2"])
    #expect(await store.remove(FavoriteFixture.identity(vod: "1")) == nil)
}

/// A8: the heart in the detail screen's bar. Two quick taps must leave the title as it was, not
/// favourited twice by two adds that both saw "not a favourite".
@Test func twoQuickTogglesEndWhereTheyStarted() async throws {
    let (store, _) = FavoriteFixture.store("toggle")
    let identity = FavoriteFixture.identity()
    async let first = store.toggle(identity, snapshot: FavoriteFixture.snapshot())
    async let second = store.toggle(identity, snapshot: FavoriteFixture.snapshot())
    let states = await [first, second]
    #expect(Set(states) == [true, false])
    #expect(await store.all().isEmpty)
    #expect(await store.toggle(identity, snapshot: FavoriteFixture.snapshot()))
    #expect(await store.contains(identity))
}

@Test func anIncompleteIdentityIsNeverStored() async throws {
    let (store, _) = FavoriteFixture.store("incomplete")
    // A list item without a vod id names no title the detail screen could open again.
    #expect(await store.add(FavoriteFixture.identity(vod: ""), snapshot: FavoriteFixture.snapshot()) == nil)
    #expect(await store.all().isEmpty)
}

// MARK: - A2: identity is the configuration, the whole site and the vod id

@Test func theSameTitleFromAnotherSourceIsAnotherFavorite() async throws {
    let (store, _) = FavoriteFixture.store("sources")
    let a = FavoriteFixture.identity(config: FavoriteFixture.configA, siteID: "s\u{0}{}", vod: "1")
    let otherConfig = FavoriteFixture.identity(config: FavoriteFixture.configB, siteID: "s\u{0}{}", vod: "1")
    let otherSite = FavoriteFixture.identity(config: FavoriteFixture.configA, siteID: "t\u{0}{}", vod: "1")
    for identity in [a, otherConfig, otherSite] {
        await store.add(identity, snapshot: FavoriteFixture.snapshot(name: "同名作品"), now: FavoriteFixture.t0)
    }
    #expect(await store.all().count == 3)
    // Unfavouriting one of them leaves the others: they are different works to the viewer.
    await store.remove(otherConfig)
    #expect(await store.contains(a))
    #expect(await store.contains(otherSite))
    #expect(!(await store.contains(otherConfig)))
}

/// K2 of IOS-POC-5R again: the configuration repeats keys, so a favourite keyed on the key alone
/// would make two providers' titles one favourite.
@Test func sitesSharingAKeyNeverShareAFavorite() async throws {
    let first = try FavoriteFixture.site(key: "爱影", ext: #"{"url":"https://a.example"}"#)
    let second = try FavoriteFixture.site(key: "爱影", ext: #"{"url":"https://b.example"}"#)
    let source = ConfigSource.remote(try #require(URL(string: FavoriteFixture.configA)))
    let one = FavoriteIdentity(source: source, site: first, vodID: "1")
    let other = FavoriteIdentity(source: source, site: second, vodID: "1")
    #expect(one != other)

    let (store, _) = FavoriteFixture.store("dupes")
    await store.add(one, snapshot: FavoriteFixture.snapshot())
    #expect(await store.contains(one))
    #expect(!(await store.contains(other)))
}

// MARK: - A4: only title metadata

/// The forbidden list of the task (position, episode, duration, line, quality, download state or
/// path, headers, cookies, tokens, resolved or signed addresses, site health) is enforced by the
/// shape itself: a new field here has to change this test, which is where that decision belongs.
@Test func aFavoriteHoldsOnlyTitleMetadata() throws {
    let favorite = Favorite(identity: FavoriteFixture.identity(), snapshot: FavoriteFixture.snapshot(),
                            createdAt: FavoriteFixture.t0)
    let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(favorite)) as? [String: Any])
    #expect(Set(object.keys) == ["identity", "name", "picture", "remarks", "year", "area", "typeName", "director",
                                 "actor", "content", "siteName", "configSourceName", "createdAt",
                                 "snapshotUpdatedAt"])
    let identity = try #require(object["identity"] as? [String: Any])
    #expect(Set(identity.keys) == ["configSourceID", "siteID", "vodID"])
}

// MARK: - A6: refresh merges what the source sent and never moves the favourited time

@Test func aRefreshNeverMovesTheFavoritedTime() async throws {
    let (store, _) = FavoriteFixture.store("refresh")
    let identity = FavoriteFixture.identity()
    await store.add(identity, snapshot: FavoriteFixture.snapshot(actor: "演員甲"), now: FavoriteFixture.t0)
    let t1 = FavoriteFixture.t0.addingTimeInterval(3_600)
    let refreshed = try #require(await store.refresh(identity, with: FavoriteFixture.snapshot(actor: "演員乙"), now: t1))
    #expect(refreshed.createdAt == FavoriteFixture.t0)
    #expect(refreshed.snapshotUpdatedAt == t1)
    #expect(refreshed.actor == "演員乙")
    // The same snapshot again changes nothing, so it is not a new snapshot either.
    let again = try #require(await store.refresh(identity, with: FavoriteFixture.snapshot(actor: "演員乙"),
                                                 now: t1.addingTimeInterval(60)))
    #expect(again.snapshotUpdatedAt == t1)
}

@Test func aSourceThatLeavesFieldsOutDoesNotEmptyTheSnapshot() async throws {
    let (store, _) = FavoriteFixture.store("nonempty")
    let identity = FavoriteFixture.identity()
    let original = try #require(await store.add(identity, snapshot: FavoriteFixture.snapshot(), now: FavoriteFixture.t0))
    // A detail that came back without cast, year, poster and synopsis, but with new remarks.
    let sparse = FavoriteSnapshot(name: "", picture: "", remarks: "全12集", year: "", typeName: " ",
                                  director: "", actor: "", content: "")
    let merged = try #require(await store.refresh(identity, with: sparse, now: FavoriteFixture.t0.addingTimeInterval(1)))
    #expect(merged.remarks == "全12集")
    #expect(merged.name == original.name)
    #expect(merged.picture == original.picture)
    #expect(merged.year == original.year)
    #expect(merged.typeName == original.typeName)
    #expect(merged.actor == original.actor)
    #expect(merged.content == original.content)
    #expect(merged.createdAt == original.createdAt)
}

@Test func openingADetailNeverFavoritesIt() async throws {
    let (store, _) = FavoriteFixture.store("notfavorite")
    #expect(await store.refresh(FavoriteFixture.identity(), with: FavoriteFixture.snapshot()) == nil)
    #expect(await store.all().isEmpty)
}

// MARK: - A5: damaged, corrupt, unreadable and newer files

@Test func oneDamagedRecordCostsNoOtherFavorite() async throws {
    let directory = FavoriteFixture.directory("damaged")
    let good = Favorite(identity: FavoriteFixture.identity(vod: "1"), snapshot: FavoriteFixture.snapshot(),
                        createdAt: FavoriteFixture.t0)
    let alsoGood = Favorite(identity: FavoriteFixture.identity(vod: "2"), snapshot: FavoriteFixture.snapshot(),
                            createdAt: FavoriteFixture.t0)
    // A record without an identity, one with half an identity, and a bare number.
    let damaged = #"{"name":"缺少識別"}"#
    let halfIdentity = #"{"identity":{"configSourceID":"x","siteID":"","vodID":"9"},"createdAt":1}"#
    let goodJSON = try FavoriteFixture.json(good), alsoGoodJSON = try FavoriteFixture.json(alsoGood)
    try FavoriteFixture.write(#"{"schemaVersion":1,"favorites":[\#(goodJSON),\#(damaged),\#(halfIdentity),42,\#(alsoGoodJSON)]}"#,
                              to: directory)

    let store = FavoriteStore(directory: directory)
    #expect(Set(await store.all().map(\.identity.vodID)) == ["1", "2"])
    let report = await store.lastLoad
    #expect(report.loaded == 2)
    #expect(report.unreadable == 3)

    // Saving keeps the records this build cannot read, exactly where a later build can.
    await store.add(FavoriteFixture.identity(vod: "3"), snapshot: FavoriteFixture.snapshot())
    let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: FavoriteFixture.file(in: directory)))
                               as? [String: Any])
    let entries = try #require(written["favorites"] as? [Any])
    #expect(entries.count == 6)
    #expect(entries.contains { ($0 as? [String: Any])?["name"] as? String == "缺少識別" })
    #expect(entries.contains { ($0 as? Int) == 42 })
}

@Test func aCorruptFileIsSetAsideNotOverwritten() async throws {
    let directory = FavoriteFixture.directory("corrupt")
    try FavoriteFixture.write("{ not json", to: directory)

    let store = FavoriteStore(directory: directory)
    #expect(await store.all().isEmpty)
    let aside = try #require(await store.lastLoad.setAside)
    #expect(try String(contentsOf: directory.appendingPathComponent(aside), encoding: .utf8) == "{ not json")
    // The store carries on with a new file; the damaged one is still there to be recovered.
    #expect(await store.add(FavoriteFixture.identity(), snapshot: FavoriteFixture.snapshot()) != nil)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(aside).path))
}

/// The case `WatchHistoryStore` does not cover: a file that is there but cannot be read now (data
/// protection before the first unlock, an I/O error). Reading it as empty and saving would replace
/// every favourite with one.
@Test func aFileThatCannotBeReadIsNeverOverwritten() async throws {
    let directory = FavoriteFixture.directory("unreadable")
    let file = FavoriteFixture.file(in: directory)
    // A directory where the file should be: it exists, and reading it fails.
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)

    let store = FavoriteStore(directory: directory)
    #expect(await store.all().isEmpty)
    #expect(await store.lastLoad.failed)
    #expect(await store.add(FavoriteFixture.identity(), snapshot: FavoriteFixture.snapshot()) == nil)
    var isDirectory: ObjCBool = false
    let untouched = FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) && isDirectory.boolValue
    #expect(untouched)

    // Readable again later: the next call loads it rather than remembering the failure.
    try FileManager.default.removeItem(at: file)
    let good = Favorite(identity: FavoriteFixture.identity(), snapshot: FavoriteFixture.snapshot(), createdAt: FavoriteFixture.t0)
    let goodJSON = try FavoriteFixture.json(good)
    try FavoriteFixture.write(#"{"schemaVersion":1,"favorites":[\#(goodJSON)]}"#, to: directory)
    #expect(await store.all() == [good])
}

@Test func aNewerSchemaIsCopiedAsideBeforeThisBuildRewritesIt() async throws {
    let directory = FavoriteFixture.directory("newer")
    let good = Favorite(identity: FavoriteFixture.identity(), snapshot: FavoriteFixture.snapshot(), createdAt: FavoriteFixture.t0)
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as? [String: Any])
    object["rating"] = 5
    let record = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    let newer = #"{"schemaVersion":9,"favorites":[\#(record)]}"#
    try FavoriteFixture.write(newer, to: directory)

    let store = FavoriteStore(directory: directory)
    // Readable fields are read: the favourite is still a favourite in this build.
    #expect(await store.all().map(\.identity) == [good.identity])
    let backup = try #require(await store.lastLoad.backedUp)
    await store.add(FavoriteFixture.identity(vod: "2"), snapshot: FavoriteFixture.snapshot())
    // What this build cannot write back — the newer field — survives in the copy.
    #expect(try String(contentsOf: directory.appendingPathComponent(backup), encoding: .utf8) == newer)
    let rewritten = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: FavoriteFixture.file(in: directory)))
                                 as? [String: Any])
    #expect(rewritten["schemaVersion"] as? Int == FavoriteStore.currentSchemaVersion)
}

@Test func aRepeatedRecordKeepsTheFirstFavoritedOne() async throws {
    let directory = FavoriteFixture.directory("repeated")
    let later = Favorite(identity: FavoriteFixture.identity(), snapshot: FavoriteFixture.snapshot(name: "後"),
                         createdAt: FavoriteFixture.t0.addingTimeInterval(5))
    let first = Favorite(identity: FavoriteFixture.identity(), snapshot: FavoriteFixture.snapshot(name: "先"),
                         createdAt: FavoriteFixture.t0)
    let laterJSON = try FavoriteFixture.json(later), firstJSON = try FavoriteFixture.json(first)
    try FavoriteFixture.write(#"{"schemaVersion":1,"favorites":[\#(laterJSON),\#(firstJSON)]}"#, to: directory)
    let store = FavoriteStore(directory: directory)
    #expect(await store.all() == [first])
    #expect(await store.lastLoad.duplicates == 1)
}

// MARK: - A13: restore is exactly the removed record

@Test func restoreBringsBackTheSameRecord() async throws {
    let (store, _) = FavoriteFixture.store("restore")
    let identity = FavoriteFixture.identity()
    await store.add(identity, snapshot: FavoriteFixture.snapshot(), now: FavoriteFixture.t0)
    await store.add(FavoriteFixture.identity(vod: "newer"), snapshot: FavoriteFixture.snapshot(),
                    now: FavoriteFixture.t0.addingTimeInterval(10))
    let removed = try #require(await store.remove(identity))
    #expect(await store.restore(removed))
    #expect(await store.favorite(identity) == removed)
    // Its own favourited time, so it returns to its own place in the list rather than the top.
    #expect(await store.all().map(\.identity.vodID) == ["newer", "1"])
}

@Test func restoreNeverReplacesAFavoriteMadeSince() async throws {
    let (store, _) = FavoriteFixture.store("restore-later")
    let identity = FavoriteFixture.identity()
    await store.add(identity, snapshot: FavoriteFixture.snapshot(), now: FavoriteFixture.t0)
    let removed = try #require(await store.remove(identity))
    let t1 = FavoriteFixture.t0.addingTimeInterval(30)
    await store.add(identity, snapshot: FavoriteFixture.snapshot(), now: t1)
    #expect(!(await store.restore(removed)))
    #expect(await store.favorite(identity)?.createdAt == t1)
}

// MARK: - A7: site identity migration is conservative

@Test func aReorderedStructuredExtIsStillTheSameSite() async throws {
    let site = try FavoriteFixture.site(key: "linghu", ext: #"{"dataKey":"k","url":"https://a"}"#)
    let oldID = "linghu\u{0}{\"url\":\"https://a\",\"dataKey\":\"k\"}"
    #expect(oldID != site.id)
    let (store, _) = FavoriteFixture.store("reordered")
    await store.add(FavoriteFixture.identity(siteID: oldID), snapshot: FavoriteFixture.snapshot(), now: FavoriteFixture.t0)

    #expect(await store.migrateSiteIdentities(in: [site], configSourceID: FavoriteFixture.configA) == 1)
    let migrated = try #require(await store.all().first)
    #expect(migrated.identity.siteID == site.id)
    #expect(migrated.createdAt == FavoriteFixture.t0)
}

/// `SiteSelection.resolve` would take a key used once as the same site (IOS-POC-19). A favourite
/// must not: the `ext` is where the site points, so a changed one may be another provider.
@Test func aSiteWhoseExtReallyChangedIsNotGuessed() async throws {
    let site = try FavoriteFixture.site(key: "爱影", ext: #"{"url":"https://new.example"}"#)
    let oldID = "爱影\u{0}{\"url\":\"https:\\/\\/old.example\"}"
    let (store, _) = FavoriteFixture.store("changed")
    await store.add(FavoriteFixture.identity(siteID: oldID), snapshot: FavoriteFixture.snapshot())

    #expect(await store.migrateSiteIdentities(in: [site], configSourceID: FavoriteFixture.configA) == 0)
    let kept = try #require(await store.all().first)
    #expect(kept.identity.siteID == oldID)
    #expect(FavoriteAvailability(kept.identity, configSourceID: FavoriteFixture.configA, sites: [site])
        == .unavailable(.siteMissing))
}

@Test func aKeyWithSeveralCandidatesIsNotGuessed() async throws {
    let one = try FavoriteFixture.site(key: "爱影", ext: #"{"url":"https://a.example"}"#)
    let two = try FavoriteFixture.site(key: "爱影", ext: #"{"url":"https://b.example"}"#)
    let oldID = "爱影\u{0}{\"url\":\"https:\\/\\/c.example\"}"
    let (store, _) = FavoriteFixture.store("candidates")
    await store.add(FavoriteFixture.identity(siteID: oldID), snapshot: FavoriteFixture.snapshot())
    #expect(await store.migrateSiteIdentities(in: [one, two], configSourceID: FavoriteFixture.configA) == 0)
    #expect(await store.all().first?.identity.siteID == oldID)
}

@Test func aSiteThatIsGoneKeepsItsFavorite() async throws {
    let (store, _) = FavoriteFixture.store("gone")
    let identity = FavoriteFixture.identity(siteID: "gone\u{0}{}")
    await store.add(identity, snapshot: FavoriteFixture.snapshot())
    #expect(await store.migrateSiteIdentities(in: [], configSourceID: FavoriteFixture.configA) == 0)
    #expect(await store.contains(identity))
    #expect(FavoriteAvailability(identity, configSourceID: FavoriteFixture.configA, sites: []) == .unavailable(.siteMissing))
}

@Test func migrationOnlyTouchesTheLoadedConfiguration() async throws {
    let site = try FavoriteFixture.site(key: "linghu", ext: #"{"dataKey":"k","url":"https://a"}"#)
    let oldID = "linghu\u{0}{\"url\":\"https://a\",\"dataKey\":\"k\"}"
    let (store, _) = FavoriteFixture.store("other-config")
    await store.add(FavoriteFixture.identity(config: FavoriteFixture.configB, siteID: oldID), snapshot: FavoriteFixture.snapshot())
    // Configuration A's sites say nothing about configuration B's favourites.
    #expect(await store.migrateSiteIdentities(in: [site], configSourceID: FavoriteFixture.configA) == 0)
    #expect(await store.all().first?.identity.siteID == oldID)
}

@Test func migratingOntoAnExistingFavoriteKeepsTheEarlierOne() async throws {
    let site = try FavoriteFixture.site(key: "linghu", ext: #"{"dataKey":"k","url":"https://a"}"#)
    let oldID = "linghu\u{0}{\"url\":\"https://a\",\"dataKey\":\"k\"}"
    let (store, _) = FavoriteFixture.store("merge")
    await store.add(FavoriteFixture.identity(siteID: oldID), snapshot: FavoriteFixture.snapshot(), now: FavoriteFixture.t0)
    await store.add(FavoriteFixture.identity(siteID: site.id), snapshot: FavoriteFixture.snapshot(),
                    now: FavoriteFixture.t0.addingTimeInterval(60))
    await store.migrateSiteIdentities(in: [site], configSourceID: FavoriteFixture.configA)
    let all = await store.all()
    #expect(all.count == 1)
    #expect(all.first?.createdAt == FavoriteFixture.t0)
}

// MARK: - A14: availability

@Test func aFavoriteOpensOnlyOnItsOwnConfigurationAndSite() throws {
    let site = try FavoriteFixture.site(key: "s", ext: #"{"url":"https://a"}"#)
    let identity = FavoriteFixture.identity(siteID: site.id)
    #expect(FavoriteAvailability(identity, configSourceID: FavoriteFixture.configA, sites: [site]) == .available(siteID: site.id))
    // Another configuration loaded: never remapped to whatever site that one has under the same id.
    #expect(FavoriteAvailability(identity, configSourceID: FavoriteFixture.configB, sites: [site])
        == .unavailable(.otherConfiguration))
}
