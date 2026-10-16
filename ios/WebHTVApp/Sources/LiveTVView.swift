import SwiftUI
import WebHTVCore

/// IOS-POC-59 U2 (W-125): the configuration's live lists — a source menu, groups on the left, channels on the right
/// (D§6.4.2). Password groups never show (D§6.2.6); empty groups do, as on Android (Manager #2158 B2-3); a channel
/// with no line iOS can try is greyed out. A tap opens the player on `LiveTVController` (U3). U4 (D§6.4.2, §6.5): the
/// last live source opens first, its last channel is marked and offered as 「繼續看」 — never played by itself
/// (X-15) — and favourites lead the group column as 「收藏」.
struct LiveTVView: View {
    let lives: [LiveSource]
    /// The configuration's own address, for a `./` list.
    let base: URL?
    /// `ConfigSource.identity`: the last channel and the favourites are this configuration's (X-9).
    let config: String

    private enum Load {
        case loading
        case failed(String)
        /// Only the groups that may show.
        case loaded([LiveGroup])
    }

    /// The first source until the last one is read (`restored`), once, before any list loads.
    @State private var sourceIndex = 0
    @State private var restored = false
    @State private var reload = 0
    @State private var refresh = false
    @State private var load = Load.loading
    /// By name, so 「收藏」 appearing or going does not move the viewer to another group.
    @State private var groupName: String?
    @State private var favorites: [String] = []
    @State private var last: LiveLastChannel?
    private let store = LiveStateStore.shared
    /// The cover's item: set, the player shows this controller's channel.
    @State private var controller: LiveTVController?
    /// The same controller, kept past the cover's dismissal so its timers are stopped whatever closed it.
    @State private var running: LiveTVController?
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
            if !restored {
                restored = true
                if let name = await store.lastLive(config: config), let index = lives.firstIndex(where: { $0.name == name }),
                   index != sourceIndex {
                    sourceIndex = index  // this task is cancelled and runs again for it
                    return
                }
            }
            load = .loading
            groupName = nil
            let fresh = refresh
            refresh = false
            guard let source else { return }
            favorites = await store.favorites(config: config, live: source.name)
            last = await store.last(config: config, live: source.name)
            do {
                let playlist = try await LiveListLoader.shared.playlist(for: source, base: base, refresh: fresh)
                guard !Task.isCancelled else { return }
                let visible = playlist.groups.filter { !$0.isHidden }
                let shown = visible.withFavorites(favorites)
                groupName = last?.locate(in: shown).map { shown[$0.group].name }
                load = .loaded(visible)
            } catch {
                guard !Task.isCancelled else { return }
                load = .failed(error.localizedDescription)
            }
        }
        .onChange(of: sourceIndex) { _, index in
            guard lives.indices.contains(index) else { return }
            Task { await store.setLastLive(lives[index].name, config: config) }
        }
        // `item`, not `isPresented`: a cover built in the same update that set the controller would read it as nil
        // and show an empty, unclosable black screen (W-126 Simulator run).
        .fullScreenCover(item: $controller, onDismiss: {
            running?.stop()
            running = nil
            PlaybackSession.shared.onPlaylistFinished = nil
            // The player may have recorded a started line or changed a favourite.
            guard let source else { return }
            Task {
                favorites = await store.favorites(config: config, live: source.name)
                last = await store.last(config: config, live: source.name)
            }
        }) { live in
            LivePlayerScreen(controller: live)
        }
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
        case .loaded(let visible):
            let groups = visible.withFavorites(favorites)
            let current = groups.firstIndex { $0.name == groupName } ?? 0
            let resume = last?.locate(in: groups)
            VStack(spacing: 0) {
                if let last, let resume {
                    Button {
                        play(resume.channel, in: groups[resume.group], line: resume.line)
                    } label: {
                        Label("繼續看：\(zhTW(last.channel))", systemImage: "play.fill").lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                HStack(spacing: 0) {
                    groupColumn(groups, current: current).frame(width: min(groupWidth, 140))
                    Divider()
                    channelColumn(groups[current], scrollTo: resume?.group == current ? resume?.channel : nil)
                }
            }
            // A list's addresses can carry short-lived tokens (tv123's sid); a pull fetches it again.
            .refreshable { refresh = true; reload += 1 }
        }
    }

    private func groupColumn(_ groups: [LiveGroup], current: Int) -> some View {
        ScrollViewReader { proxy in
            List(groups.indices, id: \.self) { index in
                Button { groupName = groups[index].name } label: {
                    Text(zhTW: groups[index].name).font(.subheadline).lineLimit(2)
                        .foregroundStyle(index == current ? Color.accentColor : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(index == current ? .isSelected : [])
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear { proxy.scrollTo(current) }
        }
    }

    @ViewBuilder private func channelColumn(_ group: LiveGroup, scrollTo target: Int?) -> some View {
        if group.channels.isEmpty {
            ContentUnavailableView("此群組沒有頻道", systemImage: "tv")
        } else {
            ScrollViewReader { proxy in
                List(group.channels.indices, id: \.self) { index in
                    channelRow(group.channels[index]) { play(index, in: group) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onAppear { if let target { proxy.scrollTo(target, anchor: .center) } }
            }
            .id(group.name)
        }
    }

    private func channelRow(_ channel: LiveChannel, play: @escaping () -> Void) -> some View {
        let favorite = favorites.contains(channel.name)
        let action = favorite ? "取消收藏" : "加入收藏"
        return Button(action: play) {
            HStack(spacing: 8) {
                Text(zhTW: channel.name).lineLimit(1)
                if channel.name == last?.channel {
                    Text("上次觀看").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 8)
                if channel.isUnsupported { Text("iOS 不支援").font(.caption).foregroundStyle(.secondary) }
                if favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow).accessibilityLabel("已收藏") }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(channel.isUnsupported)
        .opacity(channel.isUnsupported ? 0.45 : 1)
        // D§6.4.2: a long press favourites; VoiceOver gets the same as an action.
        .contextMenu {
            if !channel.isUnsupported {
                Button(action, systemImage: favorite ? "star.slash" : "star") { toggleFavorite(channel.name) }
            }
        }
        .accessibilityAction(named: action) { toggleFavorite(channel.name) }
    }

    private func toggleFavorite(_ name: String) {
        guard let live = source?.name else { return }
        Task {
            let now = await store.toggleFavorite(name, config: config, live: live)
            if source?.name == live { favorites = now }
        }
    }

    private func play(_ index: Int, in group: LiveGroup, line: Int = 0) {
        guard let source else { return }
        let live = LiveTVController(source: source, config: config, group: group.name, channels: group.channels,
                                    start: index, favorites: favorites)
        running = live
        controller = live
        live.play(line: line)
    }
}

/// IOS-POC-59 U3 (D§6.3): a channel's lines, tried in turn. Each line has `LiveSource.lineBudget` seconds to start —
/// counted only while the viewer means it to play and the app is not in the background (Manager #2158 B3-2) — and a
/// failure or a spent budget moves to the next line. A round tries every usable line once, wrapping (X-3), then
/// stops: no automatic channel change. Every line opens on the global default engine (`freshEngine`) at 1×, with no
/// watch history. `attempt` drops what an earlier line reports after a newer one opened.
@MainActor @Observable final class LiveTVController: Identifiable {
    enum Phase: Equatable { case opening, playing, exhausted, ended }

    let source: LiveSource
    let config: String
    /// The group shown when it was opened (「收藏」 too), for the last channel (U4).
    let group: String
    let channels: [LiveChannel]
    private(set) var channelIndex: Int
    private(set) var favorites: [String]
    private(set) var lineIndex = 0
    private(set) var phase = Phase.opening
    /// Lines tried in this round, for 「已試 N 條線路」.
    private(set) var tried = 0
    @ObservationIgnored private var switcher: LiveLineSwitcher
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var budget: Task<Void, Never>?
    @ObservationIgnored private let session = PlaybackSession.shared

    init(source: LiveSource, config: String, group: String, channels: [LiveChannel], start: Int, favorites: [String]) {
        self.source = source
        self.config = config
        self.group = group
        self.channels = channels
        channelIndex = start
        self.favorites = favorites
        switcher = LiveLineSwitcher(lines: channels[start].lines, start: 0)
    }

    var channel: LiveChannel { channels[channelIndex] }
    var isFavorite: Bool { favorites.contains(channel.name) }

    /// From the first line, or 「繼續看」's.
    func play(line: Int = 0) { restart(at: line) }

    func toggleFavorite() {
        let name = channel.name
        Task { favorites = await LiveStateStore.shared.toggleFavorite(name, config: config, live: source.name) }
    }

    /// 上一台／下一台: within the group, wrapping, past greyed-out channels.
    func zap(_ step: Int) {
        guard let next = channels.zap(from: channelIndex, by: step) else { return }
        channelIndex = next
        restart(at: 0)
    }

    /// A line picked by hand starts a new round from it.
    func select(line: Int) { restart(at: line) }

    /// 重試 after every line failed, or 重新播放 after an ending: a new round from the first line.
    func retry() { restart(at: 0) }

    func stop() {
        attempt += 1
        budget?.cancel()
        session.lineObserver = nil
        // Unloaded, not left paused: a line still starting would fail later and reopen on MPV behind a closed
        // player (W-126 Simulator run 2).
        session.control("stop")
    }

    private func restart(at line: Int) {
        switcher = LiveLineSwitcher(lines: channel.lines, start: line)
        tried = 0
        open(after: nil)
    }

    /// The next line of the round; `reason` names why the one before is left (logged, by number only).
    private func open(after reason: String?) {
        budget?.cancel()
        let from = lineIndex
        var next = switcher.next()
        while let candidate = next, URL(string: channel.lines[candidate].url) == nil { next = switcher.next() }
        guard let next, let url = URL(string: channel.lines[next].url) else {
            // The last line stays loaded and heard: one out of budget that starts after all clears the card.
            phase = .exhausted
            PlaybackSession.log.notice("[live] line \(from + 1) reason=\(reason ?? "none", privacy: .public) — all \(self.tried) lines tried")
            return
        }
        if let reason {
            PlaybackSession.log.notice("[live] line \(from + 1)→\(next + 1) reason=\(reason, privacy: .public)")
        }
        attempt += 1
        lineIndex = next
        tried += 1
        phase = .opening
        let id = attempt
        session.lineObserver = { [weak self] event in self?.handle(event, id: id) }
        // An ending (an MP4 "channel") is not a failure: it offers 重新播放, it does not switch.
        session.onPlaylistFinished = { [weak self] in self?.ended(id: id) }
        session.advance = nil
        session.episodeStepper = nil
        session.episodeSteps = EpisodeSteps()
        session.open(url: url, headers: channel.lines[next].headers, title: channel.name, history: nil, rate: 1,
                     freshEngine: true)
        let seconds = Double(source.lineBudget)
        budget = Task { [weak self] in await self?.count(seconds, id: id) }
    }

    private func count(_ seconds: Double, id: Int) async {
        var elapsed = Duration.zero
        var last = ContinuousClock.now
        while elapsed < .seconds(seconds) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, id == attempt else { return }
            // The clock, not the ticks: a busy main actor sleeps longer than asked (W-126 run 2 took 16.03 s).
            let now = ContinuousClock.now
            if session.activity.showsPause, UIApplication.shared.applicationState != .background { elapsed += now - last }
            last = now
        }
        guard id == attempt, phase == .opening else { return }
        open(after: "budget")
    }

    private func handle(_ event: LiveLineEvent, id: Int) {
        guard id == attempt else { return }
        switch event {
        case .started:
            phase = .playing
            budget?.cancel()
            // D§6.5: only a line that started is remembered, by its label and index — never its address.
            let last = LiveLastChannel(group: group, channel: channel.name, lineLabel: channel.lines[lineIndex].label,
                                       lineIndex: lineIndex)
            Task { await LiveStateStore.shared.setLast(last, config: config, live: source.name) }
        case .failed:
            // After a round is spent, the last line failing too changes nothing.
            if phase != .exhausted { open(after: "failed") }
        }
    }

    private func ended(id: Int) {
        guard id == attempt else { return }
        budget?.cancel()
        phase = .ended
    }
}

/// IOS-POC-59 U3 (D§6.4.3): the live layer over the player — channel, line and its menu, 上一台／下一台 with the bar;
/// the "all lines tried" or ended card whatever the bar does.
struct LivePlayerOverlay: View {
    let controller: LiveTVController
    let controlsVisible: Bool

    var body: some View {
        VStack(spacing: 16) {
            if controlsVisible {
                HStack(spacing: 14) {
                    zapButton(-1, symbol: "chevron.up", label: "上一台")
                    VStack(spacing: 2) {
                        Text(zhTW: controller.channel.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        lineMenu
                    }
                    zapButton(1, symbol: "chevron.down", label: "下一台")
                    Button { controller.toggleFavorite() } label: {
                        Image(systemName: controller.isFavorite ? "star.fill" : "star").font(.body.weight(.semibold))
                            .foregroundStyle(controller.isFavorite ? .yellow : .white)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel(controller.isFavorite ? "取消收藏" : "加入收藏")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
            }
            if controller.phase == .exhausted || controller.phase == .ended { card }
        }
        .foregroundStyle(.white)
        .padding(.top, 64)
        .padding(.horizontal, 16)
    }

    private var lineMenu: some View {
        let lines = controller.channel.lines
        return Menu {
            ForEach(lines.indices, id: \.self) { index in
                Button(name(of: index)) { controller.select(line: index) }
                    .disabled(!lines[index].support.isTried)
            }
        } label: {
            Text("線路 \(controller.lineIndex + 1)／\(lines.count)：\(name(of: controller.lineIndex))")
                .font(.caption).lineLimit(1)
                .frame(minHeight: 44)
        }
        .accessibilityLabel("選擇線路，目前為線路 \(controller.lineIndex + 1)")
    }

    private func name(of index: Int) -> String {
        let label = controller.channel.lines[index].label ?? ""
        return label.isEmpty ? "線路 \(index + 1)" : zhTW(label)
    }

    private func zapButton(_ step: Int, symbol: String, label: String) -> some View {
        Button { controller.zap(step) } label: {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    private var card: some View {
        let ended = controller.phase == .ended
        return VStack(spacing: 12) {
            Text(ended ? "播放結束" : "此頻道目前無法播放（已試 \(controller.tried) 條線路）")
                .font(.subheadline).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button(ended ? "重新播放" : "重試") { controller.retry() }.buttonStyle(.borderedProminent)
                if !ended { Button("換台") { controller.zap(1) }.buttonStyle(.bordered) }
            }
        }
        .padding(16)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
        .padding(.top, 120)
    }
}
