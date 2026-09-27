import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-32 B. `Vod` also decodes every list and search page (type 0/1 sites list in the detail
// form), so the new display-only fields must never cost a record, and search must see the same
// titles it saw before they existed.

@Test func oddlyTypedMetadataNeverDropsASearchResult() throws {
    // Shapes real sources send: a numeric year, a null area, an actor array, HTML in the synopsis.
    // `CMSResponse` decodes `list` as one array, so a single throwing field would empty the page.
    let data = Data(#"""
    {"list":[
      {"vod_id":1,"vod_name":"头发","vod_pic":"https://img.example.com/1.jpg","vod_remarks":"HD",
       "vod_year":2026,"vod_area":null,"vod_actor":["甲","乙"],"type_name":"剧情",
       "vod_content":"<p>第一段</p>"},
      {"vod_id":"2","vod_name":"庆余年","vod_director":{"name":"丙"},"vod_class":"古装,剧情"}
    ]}
    """#.utf8)
    let list = try JSONDecoder().decode(CMSResponse.self, from: data).list

    #expect(list.map(\.id) == ["1", "2"])
    #expect(list.map(\.name) == ["头发", "庆余年"])  // raw: search and history keep source text
    #expect(list[0].year == "2026")
    #expect(list[0].area.isEmpty)
    #expect(list[0].actor.isEmpty)  // an array is not display text
    #expect(list[0].typeName == "剧情")
    #expect(list[0].content == "<p>第一段</p>")  // stored raw; VodText cleans it for display
    #expect(list[1].director.isEmpty)
    #expect(list[1].typeName == "古装,剧情")  // vod_class stands in when type_name is missing
}

@Test func metadataFallbacksKeepPrecedenceAndNamesStayRaw() throws {
    // type_name and vod_content are the fields sources mean; vod_class and vod_blurb only stand in
    // when those are empty. The name is an identity value (history key text, search results), so
    // decoding must never clean it, even when it carries markup the view would tidy.
    let data = Data(#"""
    {"list":[
      {"vod_id":3,"vod_name":"湯姆&amp;傑利","type_name":"动画","vod_class":"喜剧","vod_content":"正文","vod_blurb":"摘要"},
      {"vod_id":4,"vod_name":"<b>乙</b>","type_name":"","vod_class":"喜剧","vod_content":"","vod_blurb":"摘要"},
      {"vod_id":5,"vod_name":"丙","vod_blurb":"摘要"}
    ]}
    """#.utf8)
    let list = try JSONDecoder().decode(CMSResponse.self, from: data).list

    #expect(list.map(\.name) == ["湯姆&amp;傑利", "<b>乙</b>", "丙"])
    #expect(list.map(\.typeName) == ["动画", "喜剧", ""])
    #expect(list.map(\.content) == ["正文", "摘要", "摘要"])
}

@Test func theXMLDecoderCarriesTheSameMetadata() throws {
    let data = Data(#"""
    <rss><list page="1"><video><id>7</id><name><![CDATA[熔城]]></name><type>国产剧</type>
    <year>2025</year><area>中国大陆</area><actor><![CDATA[甲,乙]]></actor>
    <director><![CDATA[丙]]></director><des><![CDATA[<p>简介</p>]]></des>
    <dl><dd flag="m3u8"><![CDATA[第01集$https://cdn.example.com/a.m3u8]]></dd></dl></video></list></rss>
    """#.utf8)
    let vod = try #require(MacCMSXMLDecoder.decode(data).list.first)

    #expect(vod.id == "7")
    #expect(vod.flags.count == 1)  // the playback fields are unaffected
    #expect(vod.year == "2025")
    #expect(vod.area == "中国大陆")
    #expect(vod.typeName == "国产剧")
    #expect(vod.actor == "甲,乙")
    #expect(vod.director == "丙")
    #expect(vod.content == "<p>简介</p>")
}

@Test func synopsisHTMLBecomesPlainLines() {
    // Paragraphs and breaks are the line structure; every other tag is noise.
    #expect(VodText.plain("<p>第一段</p><p>第二段<br/>第三行</p>") == "第一段\n第二段\n第三行")
    #expect(VodText.plain("<div><span style=\"color:red\">紅</span></div>") == "紅")
    // PHP's nl2br writes `<br />` and then the newline it replaced: still one break, or the
    // four-line synopsis would spend half its lines on blank ones.
    #expect(VodText.plain("甲<br />\r\n乙<br />\r\n丙") == "甲\n乙\n丙")
    #expect(VodText.plain("<p>一</p>\r\n<p>二</p>") == "一\n二")
    // A blank line the markup asks for survives.
    #expect(VodText.plain("甲<br><br>乙") == "甲\n\n乙")
    // Entities decode once, after the tags, so escaped markup stays visible text.
    #expect(VodText.plain("A&amp;B &lt;b&gt; &#20013;&#x6587;") == "A&B <b> 中文")
    // Android decodes only when a tag is present; a bare entity would otherwise show as `&amp;`.
    #expect(VodText.plain("湯姆&amp;傑利") == "湯姆&傑利")
    // `&emsp;` indents Chinese paragraphs; it decodes, and like any leading space is trimmed.
    #expect(VodText.plain("<p>&emsp;&emsp;正文&copy;</p>") == "正文©")
    // A stray ampersand is not an entity, NUL is never produced, and a signed number is not one.
    #expect(VodText.plain("A & B &unknown; C") == "A & B &unknown; C")
    #expect(VodText.plain("甲&#0;乙&#+65;") == "甲&#0;乙&#+65;")
}

@Test func synopsisWhitespaceIsTidied() {
    // U+3000 indents are common in Chinese synopses. Unlike Android, which leaves text without a
    // tag as it is, they are always turned into spaces and trimmed.
    #expect(VodText.plain("\u{3000}\u{3000}正文\u{00A0}") == "正文")
    // Runs of blank lines collapse to one, and none lead or trail.
    #expect(VodText.plain("\r\n甲\r\n\r\n\r\n乙\n\n") == "甲\n\n乙")
    #expect(VodText.plain("").isEmpty)
}

@Test func linkMarkupShowsOnlyItsLabel() {
    // drpy sources wrap names in CatVod links; the JSON inside is not text.
    let actor = #"[a=cr:{"id":"1","name":"甲"}/]甲[/a],[a=cr:{"id":"2","name":"乙"}/]乙[/a]"#
    #expect(VodText.plain(actor) == "甲,乙")
    // Android trims each label, so padded labels still read as a plain list.
    #expect(VodText.plain(#"[a=cr:{"id":"1"}/] 甲 [/a],[a=cr:{"id":"2"}/] 乙 [/a]"#) == "甲,乙")
}

@Test func onlyAPlausibleYearIsShown() {
    #expect(VodText.year("2026") == "2026")
    #expect(VodText.year(" 2026-09-01") == "2026")  // a full date still names its year
    #expect(VodText.year("0") == nil)  // MacCMS stores 0 for an unknown year
    #expect(VodText.year("未知") == nil)
    #expect(VodText.year("1899") == nil)
    #expect(VodText.year("20261") == nil)  // five digits is not a year
}
