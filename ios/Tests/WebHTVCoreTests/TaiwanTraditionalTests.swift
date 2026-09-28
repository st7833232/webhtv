import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-32 C. What these pin down: Simplified text from a source reads as Taiwan Traditional the way
// OpenCC's own `s2tw` writes it (every converted value below is that tool's output at 528ae262, with
// 臺 written 台); text that is already Traditional, Japanese, or not Chinese comes back as it went in,
// because OpenCC would change it; nothing is converted twice; a cast list keeps the surnames `s2tw`
// reads as words; and search, which must keep sending and reporting a source's own text, never goes
// through the conversion.

private let bundled = Result { try TaiwanTraditional.bundled() }

private func converter() throws -> TaiwanTraditional { try bundled.get() }

@Test func writesSimplifiedTheWayOpenCCsTaiwanConversionDoes() throws {
    let zh = try converter()
    let expected: [(String, String)] = [
        ("头发", "頭髮"),  // the phrase decides: not 頭發
        ("皇后驾到", "皇后駕到"),  // not 皇後
        ("这里", "這裡"),
        ("台风来了", "颱風來了"),
        ("干净", "乾淨"),
        ("一只猫", "一隻貓"),
        ("面条", "麵條"),
        ("庆余年", "慶餘年"),
        ("斗罗大陆", "斗羅大陸"),
        ("钟汉良", "鍾漢良"),
        ("姜文导演", "姜文導演"),
        ("HD国语", "HD國語"),
        ("1080P 蓝光", "1080P 藍光"),
        ("软件", "軟件"),  // characters only, not Taiwan vocabulary (軟體): the user's choice
    ]
    for (input, output) in expected {
        #expect(zh.convert(input) == output, "\(input)")
    }
}

@Test func writesTheCommonTaiThroughout() throws {
    // `s2tw` writes the formal 臺 (臺劇, 港臺劇, 平臺); the user chose 台 everywhere.
    let zh = try converter()
    let expected: [(String, String)] = [
        ("台剧", "台劇"), ("港台剧", "港台劇"), ("台综", "台綜"), ("台湾", "台灣"), ("平台", "平台"),
        ("大陆综艺", "大陸綜藝"),
    ]
    for (input, output) in expected {
        #expect(zh.convert(input) == output, "\(input)")
    }
}

@Test func leavesTraditionalAndNonChineseTextAsItCame() throws {
    // OpenCC expects Simplified input: given these it writes 幹擾, 裡長, 臺北, 週末. Many sources
    // already send Traditional.
    let zh = try converter()
    let unchanged = [
        "干擾", "里長", "台北", "周末", "若干", "于小彤", "鬥羅大陸", "周杰倫", "湯姆・克魯斯",
        "1080P", "第01集", "第1-8集", "Episode 1", "https://example.com/a.m3u8", "",
    ]
    for text in unchanged {
        #expect(zh.convert(text) == text, "\(text)")
        #expect(zh.convert(text, mode: .names) == text, "\(text)")
    }
}

@Test func convertsNothingTwice() throws {
    // A converted string never holds a Simplified-only character, so a second pass is a no-op.
    // OpenCC alone turns its own 朴樹 into 樸樹 on the second pass.
    let zh = try converter()
    for text in ["头发", "朴树", "钟汉良", "台剧", "于和伟", "改编自漫画《ワンピース》"] {
        let once = zh.convert(text)
        #expect(zh.convert(once) == once, "\(text)")
    }
    #expect(zh.convert(zh.convert("朴树")) == "朴樹")
}

@Test func keepsTheSurnamesThatTaiwanConversionReadsAsWords() throws {
    let zh = try converter()
    // As ordinary text `s2tw` reads 于 as 於, 范 as 範 and 余 as 餘, which is why cast lists have a mode.
    #expect(zh.convert("于和伟") == "於和偉")
    let cast: [(String, String)] = [
        ("于和伟,张嘉益", "于和偉,張嘉益"),
        ("范伟 / 余华", "范偉 / 余華"),
        ("钟汉良、朴树", "鍾漢良、朴樹"),
        ("沈腾，姜文", "沈騰，姜文"),
        ("张译 王景春", "張譯 王景春"),
        ("于和伟,于小彤", "于和偉,于小彤"),  // a Traditional name in the list stays as it is
    ]
    for (input, output) in cast {
        #expect(zh.convert(input, mode: .names) == output, "\(input)")
    }
}

@Test func leavesJapaneseAloneButConvertsChineseThatQuotesIt() throws {
    let zh = try converter()
    // 学 and 国 are Simplified-only in Chinese, and Japanese writes them the same way.
    for text in ["東京の大学に通う主人公は、ある日突然", "君の名は", "新人デビュー 国民的アイドル"] {
        #expect(TaiwanTraditional.isJapanese(text), "\(text)")
        #expect(zh.convert(text) == text, "\(text)")
    }
    // A Chinese synopsis quoting a Japanese title: only the Chinese changes.
    #expect(zh.convert("改编自漫画《ワンピース》，讲述了路飞的冒险") == "改編自漫畫《ワンピース》，講述了路飛的冒險")
    #expect(zh.convert("进击の巨人") == "進擊の巨人")
    // The middle dot of a foreign name is not kana.
    #expect(!TaiwanTraditional.isJapanese("汤姆・克鲁斯"))
    #expect(zh.convert("汤姆・克鲁斯") == "湯姆・克魯斯")
    // Accepted limitation: a short Chinese title that is mostly kana reads as Japanese and is shown as sent.
    #expect(TaiwanTraditional.isJapanese("海贼王（ワンピース）"))
    #expect(zh.convert("海贼王（ワンピース）") == "海贼王（ワンピース）")
}

@Test func searchStillReportsExactlyWhatTheSourceSent() async throws {
    // A source matches the text it indexes, so the names search reports stay the source's own.
    // Compared as bytes: `String` equality treats canonically equivalent text as equal.
    let site = try searchSite("zhtw-" + UUID().uuidString)
    let search = AggregateSearch { _, _, _ in
        [Vod(id: "1", name: "头发", picture: ""), Vod(id: "2", name: "庆余年", picture: "")]
    }
    var names = [String]()
    for await report in search.run([site], keyword: "頭髮") {
        if case .found(let vods) = report.outcome { names += vods.map(\.name) }
    }
    #expect(names.map { Array($0.utf8) } == ["头发", "庆余年"].map { Array($0.utf8) })
}

@Test func nothingElseInCoreConverts() throws {
    // Search, history, identity values and the WebHome bridge live in this module. None of them may
    // store a converted string or send one to a source; only the app, where it draws text, converts.
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/WebHTVCore")
    let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
    var scanned = 0
    var callers = [String]()
    for case let url as URL in files where url.pathExtension == "swift" {
        scanned += 1
        guard url.lastPathComponent != "TaiwanTraditional.swift" else { continue }
        if try String(contentsOf: url, encoding: .utf8).contains("TaiwanTraditional") {
            callers.append(url.lastPathComponent)
        }
    }
    #expect(scanned > 20)  // the path is right, so an empty list means something
    #expect(callers.isEmpty)
}

@Test func recordsWhatTextCopiedFromTheScreenCannotSearchFor() {
    // Known risk 1 (IOS-POC-32 document, section 6): these 664 Traditional-only characters can appear
    // on screen, and search's Traditional → Simplified table (Android's) leaves them as they are, so a
    // title copied from the screen into search can find nothing where the source indexes the Simplified
    // form. Since IOS-POC-33 the copied text is also sent as it is, which a site indexing Traditional
    // finds, but the Simplified form still carries these characters. Widening the table is a separate
    // change, and this list is regenerated with it (the document says how).
    let unmapped = "㑯㑳㑶㓨㗲㘚㜄㜏㜢㠏㠣㥮㩜㩳㩵㺏䁪䁻䃮䊷䋙䋚䋹䋻䍦䎱䓣䙡䜀䝼䡵䥇䥑䥕䥱䦛䦟䧢䮄䯀䰾䱷䱽䲁䲘䴉乾佈佔併侷係俔俥俬倈倖倲偑傌傢僕僞僤僱儁儎儘儸兇冑剋剎剷劏劚勣卹叄吶唸啓喎喫嗰嘆嘓噁噚噹嚐嚥嚧嚮囌埨塸塿墠壎壗壠奼姦娙媰嫺嬀嬃孃孋孻寀屓峯崑崙崬嵽嵾巖巘幓幷幹廕廞弒弔彄彆彔彙彲彿徵悞悽慄慺慼慾懞懤戱扞拚挩捨捱捲掆採揯搧搵摺撝擓擣擽敓斆昇晛暐曆曏曥朥朮柺桱桿梜梲棡椲榘榦榲槓槤槮槶槼樑樢樧樫樳樿橯檯櫍櫱欓殨殭殰氾汎汙沖洩浿涗湋溼滙滷漍潕潙潚澐澫澾濄濆濚濛濧瀂瀇瀰灒灕灙灡煱熅熰燀燖燬燶燻爲牀牴獱璊璕璗璯璸瓅瓛痠痾瘲瘻癒癥癧皁盃盪睍睏瞜瞶矇硃碽磠磾礐祕禡稏稜穀穇穫窵竈筴箇範篔篠篢篸籅籔籛籤糉糰糹紃紞紬紲絃絅絪絺綄綎綐綑綖綝綡綧綪綵緻縯縳縴繫繮繶繸繻繿纁纆纔纕罃罈羣羶翫脣脩膞膢臟舖菴菸萴葯蒍蒐蒕蓆蔄蔔蔘蔯蔿蕓薀薴薵薹藭蘟虆虉蝀蝨螮蟳蠁衆衊衕衚裊裏裡製複襀襉襬覈訏託訢註詀詝詪詷誌誾諓諟諲諴謏譁譓譞譟譭讅讌谿貍貙賰贊蹟躎軏軝輄輋輓輗輮輶迴週鄩鄳酇醟醣醲釐釒釦釴釾釿鈇鈮鉊鉋鉝鉢鉥鉧鉮鉷銈銶鋐鋗鋩鋮鋹錀錏錛錞錤錶鍀鍃鍊鍩鍭鍼鎇鎌鎓鎝鎩鎵鎶鏏鏝鏺鏻鐄鐇鐍鐏鐥鐨鐩鐯鐽鑌鑑鑕鑪鑱钂閑閤闆闇闉闑闢隑隤隮隯隻霑霢靝鞝鞦韆頍頔頠頫頵顗颱颳飈飠飢餈餗餚餬餵餸饘馼駃駉駓駪駼騄騊騑騞騠騧騱騵驎骯髮鬆鬍鬚鬥鬨鬱鬹魟鮀鮆鮈鮎鮟鮠鮡鮣鮸鯻鰆鰊鰌鰤鰧鰲鰶鰺鱀鱇鱚鱲鳾鴷鵁鵏鵟鵰鵾鶄鶖鶠鶪鶱鷀鷉鷟鷭鷽鸂鸊鸑麪麬麳麴麵鼕齘齣齮齯齼龎龑鿁鿓𠁞𠗣𡃕𡅏𡑍𡑭𡓾𡔖𡞵𡠹𡢃𡮉𡮣𡳳𡾱𢣚𢶫𢹿𣈶𣙎𣞻𣠩𣠲𣯶𣾷𤁣𤅶𤓩𤪺𤫩𤳸𥊝𥌃𥕥𥖅𥗽𥢢𥸠𥼽𦘧𦣎𦪙𧜗𧜵𧝞𧟀𧩙𧵳𧶧𨊰𨊸𨋢𨤻𨦫𨧀𨧜𨨏𨭆𨭎𨯅𩞯𩠴𩣑𩶘𰻞"
    #expect(unmapped.unicodeScalars.count == 664)
    #expect(TraditionalSimplified.toSimplified(unmapped) == unmapped)
}

// MARK: - Helpers

/// Busy sites are remembered app-wide and tests run in parallel, so the key is unique.
private func searchSite(_ key: String) throws -> Site {
    let json = #"{"key":"\#(key)","name":"\#(key)","type":1,"api":"https://example.com/api.php/provide/vod"}"#
    return try JSONDecoder().decode(Site.self, from: Data(json.utf8))
}
