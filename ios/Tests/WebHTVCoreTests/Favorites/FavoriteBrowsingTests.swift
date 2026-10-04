import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-48 A8–A10: the detail screen's favourite state, the 片庫 tab and the favourites search.

// MARK: - A9: one tab, two pages, favourites first

@Test func theLibraryOpensOnFavoritesThenHistory() {
    #expect(LibrarySection.initial == .favorites)
    #expect(LibrarySection.allCases == [.favorites, .history])
    #expect(LibrarySection.allCases.map(\.title) == ["收藏", "記錄"])
}

// MARK: - A8: the detail screen's state is its own title's

/// The heart a detail screen shows is the favourite of exactly the configuration, site and vod it
/// was opened for: switching configuration or picking another site that happens to carry the same
/// title must not light it.
@Test func aDetailScreenSeesOnlyItsOwnTitlesFavorite() async throws {
    let a = try #require(URL(string: FavoriteFixture.configA)), b = try #require(URL(string: FavoriteFixture.configB))
    let site = try FavoriteFixture.site(key: "爱影", ext: #"{"url":"https://a.example"}"#)
    let sameKey = try FavoriteFixture.site(key: "爱影", ext: #"{"url":"https://b.example"}"#)
    let (store, _) = FavoriteFixture.store("detail-state")
    let favorited = FavoriteIdentity(source: .remote(a), site: site, vodID: "1")
    await store.add(favorited, snapshot: FavoriteFixture.snapshot(name: "同名作品"))

    #expect(await store.contains(FavoriteIdentity(source: .remote(a), site: site, vodID: "1")))
    #expect(!(await store.contains(FavoriteIdentity(source: .remote(b), site: site, vodID: "1"))))
    #expect(!(await store.contains(FavoriteIdentity(source: .remote(a), site: sameKey, vodID: "1"))))
    #expect(!(await store.contains(FavoriteIdentity(source: .importedFile, site: site, vodID: "1"))))
    #expect(!(await store.contains(FavoriteIdentity(source: .remote(a), site: site, vodID: "2"))))
}

/// A refreshed detail — a new poster, an episode added, a renamed title — is the same favourite:
/// nothing about an episode or its address is part of the identity.
@Test func aRefreshedDetailIsStillTheSameFavorite() async throws {
    let site = try FavoriteFixture.site(key: "s")
    let source = ConfigSource.remote(try #require(URL(string: FavoriteFixture.configA)))
    let identity = FavoriteIdentity(source: source, site: site, vodID: "42")
    let (store, _) = FavoriteFixture.store("same-after-refresh")
    let summary = Vod(id: "42", name: "片名", picture: "https://img.example/old.jpg", remarks: "更新至8集")
    await store.add(identity, snapshot: FavoriteSnapshot(summary: summary, detail: nil, siteName: site.name,
                                                         configSourceName: "A"), now: FavoriteFixture.t0)
    let detail = Vod(id: "42", name: "片名（新版）", picture: "https://img.example/new.jpg", remarks: "更新至9集",
                     playFrom: "線路①", playURL: "第1集$https://e/1#第2集$https://e/2")
    await store.refresh(identity, with: FavoriteSnapshot(summary: summary, detail: detail, siteName: site.name,
                                                         configSourceName: "A"),
                        now: FavoriteFixture.t0.addingTimeInterval(60))

    let all = await store.all()
    #expect(all.count == 1)
    #expect(all.first?.identity == identity)
    #expect(all.first?.createdAt == FavoriteFixture.t0)
    #expect(all.first?.picture == "https://img.example/new.jpg")
}

@Test func theSnapshotTakesTheDetailAndFillsFromTheListItem() {
    let summary = Vod(id: "1", name: "列表名", picture: "https://img.example/list.jpg", remarks: "HD",
                      year: "2024", actor: "列表演員")
    let detail = Vod(id: "1", name: "", picture: "", remarks: "全12集", year: "2025-03-01",
                     director: "<a href=\"x\">導演甲</a>", actor: "")
    let snapshot = FavoriteSnapshot(summary: summary, detail: detail, siteName: "站", configSourceName: "設定")
    #expect(snapshot.name == "列表名")
    #expect(snapshot.picture == "https://img.example/list.jpg")
    #expect(snapshot.remarks == "全12集")
    #expect(snapshot.year == "2025")
    #expect(snapshot.director == "導演甲")
    #expect(snapshot.actor == "列表演員")
    #expect(snapshot.siteName == "站")
    #expect(snapshot.configSourceName == "設定")
}

// MARK: - A10: the favourites page searches its own snapshots

private func favorite(_ vod: String, name: String, actor: String = "", director: String = "", typeName: String = "",
                      year: String = "", remarks: String = "", content: String = "") -> Favorite {
    Favorite(identity: FavoriteFixture.identity(vod: vod),
             snapshot: FavoriteSnapshot(name: name, remarks: remarks, year: year, typeName: typeName,
                                        director: director, actor: actor, content: content),
             createdAt: FavoriteFixture.t0)
}

private let library = [
    favorite("1", name: "权力的游戏", actor: "艾米莉亚·克拉克", director: "大卫·贝尼奥夫", typeName: "欧美剧", year: "2011"),
    favorite("2", name: "功夫", actor: "周星驰", director: "周星驰", typeName: "喜剧片", year: "2004"),
    favorite("3", name: "Breaking Bad", actor: "Bryan Cranston", typeName: "美剧", year: "2008",
             remarks: "全62集", content: "化學老師"),
]

@Test(arguments: [("权力", ["1"]), ("艾米莉亚", ["1"]), ("贝尼奥夫", ["1"]), ("喜剧", ["2"]), ("2008", ["3"]),
                  ("周星驰", ["2"]), ("剧", ["1", "2", "3"])])
func searchFindsNameCastDirectorGenreAndYear(query: String, expected: [String]) {
    #expect(FavoriteSearch.filter(library, query: query).map(\.identity.vodID) == expected)
}

/// Snapshots keep the source's script; the viewer types Taiwan Traditional. Either finds the other.
@Test func searchMatchesEitherScript() {
    #expect(FavoriteSearch.filter(library, query: "權力的遊戲").map(\.identity.vodID) == ["1"])
    #expect(FavoriteSearch.filter(library, query: "周星馳").map(\.identity.vodID) == ["2"])
    #expect(FavoriteSearch.filter(library, query: "breaking ＢＡＤ").map(\.identity.vodID) == ["3"])
}

/// The field list is the requirement's: remarks and synopsis are not searched, so a word that only
/// appears there finds nothing rather than a surprising match.
@Test func searchLooksOnlyAtTheListedFields() {
    #expect(FavoriteSearch.filter(library, query: "化學").isEmpty)
    #expect(FavoriteSearch.filter(library, query: "全62集").isEmpty)
}

@Test func anEmptySearchListsEveryFavoriteInOrder() {
    #expect(FavoriteSearch.filter(library, query: "  ").map(\.identity.vodID) == ["1", "2", "3"])
}
