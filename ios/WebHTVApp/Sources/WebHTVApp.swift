import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebHTVCore

@main
struct WebHTVApp: App {
    var body: some Scene {
        WindowGroup { ConfigView() }
    }
}

private struct ConfigView: View {
    @State private var sites = [Site]()
    @State private var error: String?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Group {
                if sites.isEmpty {
                    ContentUnavailableView("尚未載入設定", systemImage: "doc.badge.plus", description: Text("匯入 wang-movie.json 以顯示 iOS 可用站點。"))
                } else {
                    List(sites) { site in
                        NavigationLink(site.name) { CMSView(site: site) }
                    }
                }
            }
            .navigationTitle("WebHTV")
            .toolbar { Button("匯入設定") { importing = true } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): load(url)
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        .alert("無法載入", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("確定", role: .cancel) {}
        } message: {
            Text(error ?? "未知錯誤")
        }
    }

    private func load(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do { sites = try ConfigLoader.decode(Data(contentsOf: url)).nativeCMSSites.filter { $0.type == 1 } }
        catch { self.error = error.localizedDescription }
    }
}

private struct CMSView: View {
    let site: Site
    @State private var items = [Vod]()
    @State private var query = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List(items) { vod in
            NavigationLink {
                VodView(site: site, summary: vod)
            } label: {
                HStack {
                    AsyncImage(url: URL(string: vod.picture)) { image in image.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                        .frame(width: 64, height: 90).clipShape(.rect(cornerRadius: 6))
                    VStack(alignment: .leading) {
                        Text(vod.name)
                        if !vod.remarks.isEmpty { Text(vod.remarks).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .overlay { if loading { ProgressView() } else if let error { ContentUnavailableView("載入失敗", systemImage: "exclamationmark.triangle", description: Text(error)) } }
        .navigationTitle(site.name)
        .searchable(text: $query, prompt: "搜尋影片")
        .onSubmit(of: .search) { Task { await load(search: query) } }
        .task { if items.isEmpty { await load() } }
    }

    private func load(search: String? = nil) async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let client = try CMSClient(site: site)
            items = if let search, !search.isEmpty { try await client.search(search).list } else { try await client.home().list }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct VodView: View {
    let site: Site
    let summary: Vod
    @State private var detail: Vod?
    @State private var pendingPlayback: Playback?
    @State private var error: String?

    var body: some View {
        List {
            if let detail {
                ForEach(detail.flags, id: \.name) { flag in
                    Section(flag.name) {
                        ForEach(Array(flag.episodes.enumerated()), id: \.offset) { _, episode in
                            Button(episode.name) {
                                if let url = episode.mediaURL { pendingPlayback = Playback(url: url) }
                            }
                            .disabled(episode.mediaURL == nil)
                        }
                    }
                }
            } else if let error {
                ContentUnavailableView("詳情載入失敗", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(summary.name)
        .task {
            do { detail = try await CMSClient(site: site).detail(id: summary.id) }
            catch { self.error = error.localizedDescription }
        }
        .sheet(item: $pendingPlayback) { PlayerPickerView(mediaURL: $0.url) }
    }
}

private struct Playback: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct PlayerPickerView: View {
    let mediaURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                NavigationLink("內建播放器") { PlayerView(url: mediaURL) }
                ForEach(ExternalPlayer.allCases, id: \.self) { player in
                    Button(player.displayName) { open(player) }
                }
            }
            .navigationTitle("選擇影片播放器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("取消") { dismiss() } }
            .alert("無法開啟播放器", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("確定", role: .cancel) {}
            } message: {
                Text(error ?? "未知錯誤")
            }
        }
    }

    private func open(_ player: ExternalPlayer) {
        guard let url = player.playbackURL(for: mediaURL) else {
            error = "無法建立 \(player.displayName) 播放連結。"
            return
        }
        UIApplication.shared.open(url) { opened in
            if !opened {
                Task { @MainActor in
                    error = "請先安裝或更新 \(player.displayName)，也可改用內建播放器。"
                }
            }
        }
    }
}

private struct PlayerView: View {
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear { player.play() }
            .onDisappear { player.pause() }
    }
}
