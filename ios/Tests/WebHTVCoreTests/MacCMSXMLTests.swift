import Foundation
import Testing
@testable import WebHTVCore

/// The shape both configured type-0 endpoints actually return, trimmed to the elements the decoder
/// reads plus several it must parse past. Captured from `caiji.moduapi.cc` on 2026-09-16.
private let payload = Data(#"""
<?xml version="1.0" encoding="utf-8"?>
<rss version="5.1">
<list page="2" pagecount="239" pagesize="20" recordcount="4775">
<video>
<last>2026-09-16 15:28:31</last><id>82895</id><tid>34</tid>
<name><![CDATA[人气美食2026]]></name><type>大陆综艺</type>
<pic>https://www.mdzypic.com/upload/vod/a.jpg</pic>
<lang>国语</lang><area>中国大陆</area><year>2026</year><state></state>
<note><![CDATA[更新至20260915期]]></note>
<actor><![CDATA[]]></actor><director><![CDATA[]]></director>
<dl><dd flag="modum3u8"><![CDATA[第01集$https://play.modujx11.com/a/index.m3u8#第02集$https://play.modujx11.com/b/index.m3u8]]></dd></dl>
<des><![CDATA[描述]]></des>
</video>
<video>
<id>89511</id><name><![CDATA[熔城]]></name>
<pic>https://www.mdzypic.com/upload/vod/b.jpg</pic>
<note><![CDATA[更新至13集]]></note>
<dl>
<dd flag="modum3u8"><![CDATA[第01集$https://play.modujx17.com/c/index.m3u8]]></dd>
<dd flag="moduyun"><![CDATA[第01集$https://yun.example.com/d/index.m3u8]]></dd>
</dl>
</video>
</list>
<class><ty id="1">国产动漫</ty><ty id="26">国产剧</ty><ty id="34">大陆综艺</ty></class>
</rss>
"""#.utf8)

@Test func decodesTheMacCMSXMLShapeIntoTheSameResponseJSONSitesProduce() throws {
    let response = MacCMSXMLDecoder.decode(payload)

    // <class><ty id="…"> carries no parent, so these render as one category row.
    #expect(response.classes.map(\.id) == ["1", "26", "34"])
    #expect(response.classes.map(\.name) == ["国产动漫", "国产剧", "大陆综艺"])
    #expect(response.classes.allSatisfy { $0.parentID == 0 })
    #expect(response.categoryGroups.count == 3)
    #expect(response.categoryGroups.allSatisfy { $0.children.isEmpty })
    #expect(response.firstListableCategory?.id == "1")

    #expect(response.list.count == 2)
    let first = try #require(response.list.first)
    // id/name/pic/note map onto the same fields vod_id/vod_name/vod_pic/vod_remarks fill.
    #expect(first.id == "82895")
    #expect(first.name == "人气美食2026")
    #expect(first.picture == "https://www.mdzypic.com/upload/vod/a.jpg")
    #expect(first.remarks == "更新至20260915期")
}

@Test func turnsEachDdIntoAFlagWhoseEpisodesSplitLikeTypeOne() throws {
    let response = MacCMSXMLDecoder.decode(payload)

    let first = try #require(response.list.first)
    let flag = try #require(first.flags.first)
    #expect(first.flags.count == 1)
    #expect(flag.name == "modum3u8")
    #expect(flag.episodes.map(\.name) == ["第01集", "第02集"])
    #expect(flag.episodes.first?.url == "https://play.modujx11.com/a/index.m3u8")
    #expect(flag.episodes.first?.mediaURL != nil)

    // Two <dd> become two flags through the "$$$" encoding Vod.flags already expects.
    let second = response.list[1]
    #expect(second.playFrom == "modum3u8$$$moduyun")
    #expect(second.flags.map(\.name) == ["modum3u8", "moduyun"])
    #expect(second.flags.map { $0.episodes.count } == [1, 1])
    #expect(second.flags.last?.episodes.first?.url == "https://yun.example.com/d/index.m3u8")
}

@Test func readsPlainTextAsWellAsCDATAAndSurvivesAMalformedPayload() {
    // The same record without CDATA wrappers, which some providers send.
    let plain = Data(#"""
    <rss><list><video><id>7</id><name>純文字</name><pic>https://e.example/p.jpg</pic>
    <note>HD</note><dl><dd flag="m3u8">第01集$https://e.example/v.m3u8</dd></dl></video></list></rss>
    """#.utf8)
    let response = MacCMSXMLDecoder.decode(plain)
    #expect(response.list.first?.name == "純文字")
    #expect(response.list.first?.remarks == "HD")
    #expect(response.list.first?.flags.first?.episodes.first?.url == "https://e.example/v.m3u8")

    // Android's fromXml catches and returns empty; so does this, rather than throwing.
    let broken = MacCMSXMLDecoder.decode(Data("<rss><list><video><id>1".utf8))
    #expect(broken.list.isEmpty)
    #expect(broken.classes.isEmpty)
}

@Test func buildsTheTypeZeroQueriesAndroidSends() throws {
    let site = try JSONDecoder().decode(Site.self, from: Data(#"""
    {"key":"魔都","name":"魔都动漫","type":0,"api":"https://caiji.moduapi.cc/api.php/provide/vod/at/xml/"}
    """#.utf8))
    let client = try CMSClient(site: site)

    // SiteApi.ac(int) sends videolist for type 0, detail for everything else.
    #expect(client.detailAction == "videolist")
    let listing = client.listingQuery(categoryID: "26", page: 2)
    #expect(listing.map(\.name) == ["ac", "t", "pg"])
    #expect(listing.first?.value == "videolist")

    // The plain form is the only one carrying <class>, so a home still asks for it unqualified.
    #expect(client.listingQuery(categoryID: nil, page: 1).map(\.name) == ["ac"])
}
