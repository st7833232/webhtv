import SwiftUI
import WebHTVCore

/// IOS-POC-59 U2 (W-125): the configuration's live lists — a source menu, groups on the left, channels on the right
/// (D§6.4.2). Password groups never show (D§6.2.6); empty groups do, as on Android (Manager #2158 B2-3); a channel
/// with no line iOS can try is greyed out. A tap plays the channel's first usable line; switching lines and channels
/// is U3's.
struct LiveTVView: View {
    let lives: [LiveSource]
    /// The configuration's own address, for a `./` list.
    let base: URL?

    private enum Load {
        case loading
        case failed(String)
        /// Only the groups that may show.
        case loaded([LiveGroup])
    }

    /// Starts on the first source (B2-4: remembering the last one is U4's).
    @State private var sourceIndex = 0
    @State private var reload = 0
    @State private var refresh = false
    @State private var load = Load.loading
    @State private var groupIndex = 0
    @State private var playing = false
    @ScaledMetric(relativeTo: .body) private var groupWidth: CGFloat = 112

    /// The chosen source, kept in range: a configuration refresh can hand this screen a shorter `lives`.
    private var source: LiveSource? { lives.isEmpty ? nil : lives[min(sourceIndex, lives.count - 1)] }

    private struct Request: Equatable {
        let source: Int
        let reload: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            if let source {
                sourceMenu(source)
                Divider()
                content.frame(maxHeight: .infinity)
            } else {
                ContentUnavailableView("此設定沒有直播源", systemImage: "tv")
            }
        }
        .navigationTitle("直播")
        .navigationBarTitleDisplayMode(.inline)
        // A new source or a retry cancels the request before it, so a late answer for another source never lands.
        .task(id: Request(source: sourceIndex, reload: reload)) {
            load = .loading
            groupIndex = 0
            let fresh = refresh
            refresh = false
            guard let source else { return }
            do {
                let playlist = try await LiveListLoader.shared.playlist(for: source, base: base, refresh: fresh)
                guard !Task.isCancelled else { return }
                load = .loaded(playlist.groups.filter { !$0.isHidden })
            } catch {
                guard !Task.isCancelled else { return }
                load = .failed(error.localizedDescription)
            }
        }
        .fullScreenCover(isPresented: $playing, onDismiss: {
            PlaybackSession.shared.onPlaylistFinished = nil
        }) { LivePlayerScreen() }
    }

    private func sourceMenu(_ source: LiveSource) -> some View {
        HStack(spacing: 12) {
            Menu {
                Picker("直播源", selection: $sourceIndex) {
                    ForEach(lives.indices, id: \.self) { index in Text(zhTW: lives[index].name).tag(index) }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(zhTW: source.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("切換直播源，目前為 \(zhTW(source.name))")
            Spacer(minLength: 0)
            if case .failed(let reason) = load {
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var content: some View {
        switch load {
        case .loading:
            ProgressView("載入清單中（最多 30 秒）")
        case .failed(let reason):
            ContentUnavailableView {
                Label("無法載入此直播源", systemImage: "antenna.radiowaves.left.and.right.slash")
            } description: {
                Text(reason)
            } actions: {
                Button("重試") { refresh = true; reload += 1 }
            }
        case .loaded(let groups) where groups.isEmpty:
            ContentUnavailableView("此直播源沒有可顯示的頻道", systemImage: "tv")
        case .loaded(let groups):
            HStack(spacing: 0) {
                groupColumn(groups).frame(width: min(groupWidth, 140))
                Divider()
                channelColumn(groups[min(groupIndex, groups.count - 1)])
            }
            // A list's addresses can carry short-lived tokens (tv123's sid); a pull fetches it again.
            .refreshable { refresh = true; reload += 1 }
        }
    }

    private func groupColumn(_ groups: [LiveGroup]) -> some View {
        List(groups.indices, id: \.self) { index in
            Button { groupIndex = index } label: {
                Text(zhTW: groups[index].name).font(.subheadline).lineLimit(2)
                    .foregroundStyle(index == groupIndex ? Color.accentColor : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(index == groupIndex ? .isSelected : [])
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private func channelColumn(_ group: LiveGroup) -> some View {
        if group.channels.isEmpty {
            ContentUnavailableView("此群組沒有頻道", systemImage: "tv")
        } else {
            List(group.channels.indices, id: \.self) { index in
                let channel = group.channels[index]
                Button { play(channel) } label: {
                    HStack {
                        Text(zhTW: channel.name).lineLimit(1)
                        Spacer(minLength: 8)
                        if channel.isUnsupported { Text("iOS 不支援").font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(channel.isUnsupported)
                .opacity(channel.isUnsupported ? 0.45 : 1)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .id(groupIndex)
        }
    }

    /// The first line iOS can try, at 1×, with no watch history (D§6.3.6: live stays out of 記錄).
    private func play(_ channel: LiveChannel) {
        var lines = LiveLineSwitcher(lines: channel.lines, start: 0)
        guard let index = lines.next(), let url = URL(string: channel.lines[index].url) else { return }
        let session = PlaybackSession.shared
        // No episode controls are left over from a title played before.
        session.advance = nil
        session.episodeStepper = nil
        session.episodeSteps = EpisodeSteps()
        session.onPlaylistFinished = { playing = false }
        session.open(url: url, headers: channel.lines[index].headers, title: channel.name, history: nil, rate: 1)
        playing = true
    }
}
