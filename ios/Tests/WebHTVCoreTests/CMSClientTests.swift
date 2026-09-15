import Foundation
import Testing
@testable import WebHTVCore

@Test func buildsExternalPlayerURLsWithoutChangingMediaURL() throws {
    let mediaURL = try #require(URL(string: "https://example.com/video.m3u8?token=a+b&quality=1080p"))
    let expected = [
        (ExternalPlayer.infuse, "infuse", "x-callback-url", "/play"),
        (ExternalPlayer.fileball, "filebox", "play", ""),
        (ExternalPlayer.senPlayer, "senplayer", "x-callback-url", "/play"),
        (ExternalPlayer.vidHub, "open-vidhub", "x-callback-url", "/play"),
    ]

    for (player, scheme, host, path) in expected {
        let url = try #require(player.playbackURL(for: mediaURL))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == scheme)
        #expect(components.host == host)
        #expect(components.path == path)
        #expect(components.queryItems == [URLQueryItem(name: "url", value: mediaURL.absoluteString)])
    }
}

@Test func decodesPlaybackGroupsAndBracketedEpisodeNames() throws {
    let data = Data(#"{"class":[{"type_id":1,"type_name":"電影"}],"list":[{"vod_id":7,"vod_name":"測試","vod_play_from":"line1$$$line2","vod_play_url":"第1集$https://example.com/1.m3u8#花絮(上#下)$https://example.com/2.mp4$$$備用$custom://2"}]}"#.utf8)
    let response = try JSONDecoder().decode(CMSResponse.self, from: data)

    #expect(response.classes.first?.id == "1")
    #expect(response.list.first?.id == "7")
    #expect(response.list.first?.flags.first?.episodes.map(\.name) == ["第1集", "花絮(上#下)"])
    #expect(response.list.first?.flags.first?.episodes.first?.mediaURL?.scheme == "https")
    #expect(response.list.first?.flags.last?.episodes.first?.mediaURL == nil)
}

@Test func completesLiveCMSFlowFromProvidedConfig() async throws {
    guard let path = ProcessInfo.processInfo.environment["WANG_MOVIE_JSON"] else { return }
    let config = try ConfigLoader.decode(Data(contentsOf: URL(fileURLWithPath: path)))
    let site = try #require(config.sites.first { $0.api.contains("cj.rycjapi.com/api.php/provide/vod/at/json") })
    let client = try CMSClient(site: site)
    let home = try await client.home()
    let first = try #require(home.list.first)
    let search = try await client.search(first.name)
    let detail = try #require(try await client.detail(id: first.id))

    #expect(!home.classes.isEmpty)
    #expect(search.list.contains { $0.id == first.id })
    #expect(detail.flags.flatMap(\.episodes).contains { $0.mediaURL != nil })
}
