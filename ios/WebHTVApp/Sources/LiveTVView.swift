import SwiftUI
import WebHTVCore

/// IOS-POC-59 U2 (W-125): the configuration's live lists — a source menu, groups on the left, channels on the right
/// (D§6.4.2). Password groups never show (D§6.2.6); empty groups do, as on Android (Manager #2158 B2-3); a channel
/// with no line iOS can try is greyed out. A tap opens the player on `LiveTVController` (U3).
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
        // `item`, not `isPresented`: a cover built in the same update that set the controller would read it as nil
        // and show an empty, unclosable black screen (W-126 Simulator run).
        .fullScreenCover(item: $controller, onDismiss: {
            running?.stop()
            running = nil
            PlaybackSession.shared.onPlaylistFinished = nil
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
                Button { play(index, in: group) } label: {
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

    private func play(_ index: Int, in group: LiveGroup) {
        guard let source else { return }
        let live = LiveTVController(source: source, channels: group.channels, start: index)
        running = live
        controller = live
        live.play()
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
    let channels: [LiveChannel]
    private(set) var channelIndex: Int
    private(set) var lineIndex = 0
    private(set) var phase = Phase.opening
    /// Lines tried in this round, for 「已試 N 條線路」.
    private(set) var tried = 0
    @ObservationIgnored private var switcher: LiveLineSwitcher
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var budget: Task<Void, Never>?
    @ObservationIgnored private let session = PlaybackSession.shared

    init(source: LiveSource, channels: [LiveChannel], start: Int) {
        self.source = source
        self.channels = channels
        channelIndex = start
        switcher = LiveLineSwitcher(lines: channels[start].lines, start: 0)
    }

    var channel: LiveChannel { channels[channelIndex] }

    func play() { restart(at: 0) }

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
                .frame(minHeight: 32)
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
