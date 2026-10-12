import Foundation
import Testing
@testable import WebHTVCore

// QIST-POSTER (W-39, design W-32 §5): poster addresses carrying TVBox image headers.

private let chrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
// What Ikanbot.java and Djuu.java write: org.json's toString, which escapes "/".
private let escapedChrome = chrome.replacingOccurrences(of: "/", with: "\\/")

@Test func readsIkanbotsDoubanPosterAndDjuusLogoAsTheUpstreamWritesThem() throws {
    let douban = try #require(ImageRequest.parse(
        #"https://img3.doubanio.com/view/photo/m_ratio_poster/public/p2933860063.jpg@Headers={"User-Agent":"\#(escapedChrome)","Referer":"https:\/\/www.douban.com"}"#))
    #expect(douban.url.absoluteString == "https://img3.doubanio.com/view/photo/m_ratio_poster/public/p2933860063.jpg")
    #expect(douban.headers == ["User-Agent": chrome, "Referer": "https://www.douban.com"])

    let logo = try #require(ImageRequest.parse(
        #"https://m.djuu.com/static/mobile/images/play/logo.png@Headers={"User-Agent":"\#(escapedChrome)","Referer":"https:\/\/m.djuu.com\/"}"#))
    #expect(logo.url.absoluteString == "https://m.djuu.com/static/mobile/images/play/logo.png")
    #expect(logo.headers == ["User-Agent": chrome, "Referer": "https://m.djuu.com/"])
}

@Test func sendsOnlyRefererAndUserAgentAndNeverACookie() throws {
    let json = try #require(ImageRequest.parse(
        #"https://i.example/p.jpg@Headers={"Cookie":"sid=1","Authorization":"Bearer t","Host":"evil.example","referer":"https://r.example/","X-Other":"1"}"#))
    #expect(json.headers == ["Referer": "https://r.example/"])

    // POSTER-03: a value ends at the next known marker, so the cookie never rides inside the Referer.
    let chained = try #require(ImageRequest.parse("https://i.example/p.jpg@Referer=https://r.example/@Cookie=sid=1"))
    #expect(chained.url.absoluteString == "https://i.example/p.jpg")
    #expect(chained.headers == ["Referer": "https://r.example/"])
    #expect(!chained.headers.values.contains { $0.contains("Cookie") || $0.contains("sid") })

    let cookieOnly = try #require(ImageRequest.parse("https://i.example/p.jpg@Cookie=sid=1"))
    #expect(cookieOnly.url.absoluteString == "https://i.example/p.jpg" && cookieOnly.headers.isEmpty)
}

@Test func dropsAnyValueCarryingCROrLFCountedAsScalars() throws {
    // POSTER-01: "\r\n" is one Character in Swift, so only a unicode-scalar check catches the pair.
    for value in ["a\r\nb", "\r\n", "a\rb", "a\nb"] {
        let json = try JSONSerialization.data(withJSONObject: ["Referer": value, "User-Agent": "ok"])
        let parsed = try #require(ImageRequest.parse("https://i.example/p.jpg@Headers=" + String(decoding: json, as: UTF8.self)))
        #expect(parsed.headers == ["User-Agent": "ok"], "\(value.unicodeScalars.map(\.value))")
        #expect(try #require(ImageRequest.parse("https://i.example/p.jpg@Referer=" + value)).headers.isEmpty)
    }
}

@Test func keepsAnAtSignInAValueOrTheAddressAndRefusesWhatIsNotAWebImage() throws {
    #expect(try #require(ImageRequest.parse("https://i.example/p.jpg@User-Agent=a@b")).headers == ["User-Agent": "a@b"])
    let retina = try #require(ImageRequest.parse("https://a.com/x@2x.png@Referer=https://r"))
    #expect(retina.url.absoluteString == "https://a.com/x@2x.png" && retina.headers == ["Referer": "https://r"])

    let broken = try #require(ImageRequest.parse(#"https://i.example/p.jpg@Headers={"Referer":"#))
    #expect(broken.url.absoluteString == "https://i.example/p.jpg" && broken.headers.isEmpty)

    #expect(ImageRequest.parse("ftp://i.example/p.jpg@Referer=https://r") == nil)
    #expect(ImageRequest.parse("data:image/png;base64,AAAA@Referer=https://r") == nil)
    #expect(ImageRequest.parse("https://i.example/p.jpg") == nil)
    #expect(ImageRequest.parse("https://a.com/x@2x.png") == nil)

    // W48-02: BeiLeHu's posters carry an image-processing "@…" that is part of the address, not a marker.
    let beilehu = "https://res1.ubestkid.com/blk/t/001_xtzgg.png@c_1,x_120,y_0,w_720,h_540%7Cs_0,w_300,f_png"
    #expect(ImageRequest.parse(beilehu) == nil)
    let withReferer = try #require(ImageRequest.parse(beilehu + "@Referer=https://www.ubestkid.com/"))
    #expect(withReferer.url.absoluteString == beilehu && withReferer.headers == ["Referer": "https://www.ubestkid.com/"])
}
