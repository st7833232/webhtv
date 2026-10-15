import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-60 (W-40): a list item whose `vod_tag` is "folder" opens as a category of its own, the way
// FongMi's Android Vod.isFolder() does (design artifacts/qist-folder-design-2026-10-09.md, inputs W-30).

private func decode(_ json: String) throws -> CMSResponse { try JSONDecoder().decode(CMSResponse.self, from: Data(json.utf8)) }

/// An adapter that builds its own result (keeping `vod_tag`) and reports what it was asked for in the first item's remarks.
private let folderSpider = """
module.exports = {
  init: function () { return ''; },
  categoryContent: function (tid, pg, filter, extend) {
    return { page: 1, pagecount: 1, list: [
      { vod_id: '/play/420851', vod_name: '狗镇', vod_tag: 'folder', vod_remarks: JSON.stringify({ tid: tid, pg: pg, extend: extend }) },
      { vod_id: '/play/1', vod_name: 'file', vod_tag: 'file' }
    ] };
  },
  homeContent: function () { return host.result.page([{ vod_id: '/article/1', vod_name: 'x', vod_tag: 'folder' }]); }
};
"""

private func spiderClient() throws -> SourceClient {
    let site = try JSONDecoder().decode(Site.self, from: Data(#"{"key":"f","name":"f","type":3,"api":"csp_F"}"#.utf8))
    let runtime = try JavaScriptSpiderRuntime(name: "f", script: folderSpider, prelude: SpiderRegistry.bundled().prelude,
                                              storage: SpiderStorage(siteKey: "f", defaults: .standard))
    return .spider(SpiderSession(site: site, runtime: runtime), site)
}

struct FolderVodTests {
    // T1 (W-30 synthetic-folder-mixed.json): only an exact "folder" string is a folder; any other tag reads as
    // empty and never fails the record or the page.
    @Test func onlyAnExactFolderTagIsAFolderAndNoTagShapeFailsTheRecord() throws {
        let list = try decode(#"""
            {"list":[{"vod_id":"/article/1","vod_name":"x","vod_tag":"folder"},{"vod_id":"2","vod_name":"y","vod_tag":123},
            {"vod_id":"3","vod_name":"z"},{"vod_id":"4","vod_name":"w","vod_tag":"Folder"},{"vod_id":"5","vod_name":"v","vod_tag":null},
            {"vod_id":"6","vod_name":"u","vod_tag":["folder"]},{"vod_id":"7","vod_name":"t","vod_tag":{"type":"folder"}}]}
            """#).list
        #expect(list.map(\.id) == ["/article/1", "2", "3", "4", "5", "6", "7"])
        #expect(list.map(\.tag) == ["folder", "", "", "Folder", "", "", ""])
        #expect(list.map(\.isFolder) == [true, false, false, false, false, false, false])
        #expect(list[1].name == "y" && list[6].name == "t")
    }

    // T2: an item without a tag, and one built in code, are what they were.
    @Test func anUntaggedOrBuiltItemIsNotAFolder() throws {
        let vod = try #require(try decode(#"{"list":[{"vod_id":"9","vod_name":"n","vod_pic":"p","vod_remarks":"r"}]}"#).list.first)
        #expect(vod.tag == "" && !vod.isFolder && vod.name == "n" && vod.picture == "p" && vod.remarks == "r")
        #expect(!Vod(id: "1", name: "a", picture: "").isFolder)
    }

    // T4: the folder's id reaches the spider as tid exactly, with the parent's extend, and its items keep their tag.
    @Test func aFolderListsAsACategoryWithTheParentExtend() async throws {
        let response = try await spiderClient().category(id: "/article/233", page: 1, extend: ["cateId": "kanlist/剧情"])
        #expect(response.list.map(\.isFolder) == [true, false])
        let asked = try #require(try JSONSerialization.jsonObject(with: Data(response.list[0].remarks.utf8)) as? [String: Any])
        #expect(asked["tid"] as? String == "/article/233" && asked["pg"] as? String == "1")
        #expect(asked["extend"] as? [String: String] == ["cateId": "kanlist/剧情"])
    }

    // T5: host.result's builders keep the four card fields only, so an adapter that wants folders builds its own result.
    @Test func hostResultDropsTheTag() async throws {
        let home = try await spiderClient().home()
        #expect(home.list.map(\.id) == ["/article/1"] && home.list.allSatisfy { !$0.isFolder })
    }
}
