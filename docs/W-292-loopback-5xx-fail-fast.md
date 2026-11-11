# W-292 腳本本機服務回 5xx 時快速顯示失敗

- 工單：herdr W-292（Manager #7874，接 W-289 建議②）；分支 `task/W-292`，自 ios-poc `084c2de4`（0.1.101）。
- 來源：W-289 根因報告 `.herdr-synapse/webhtv-dev/artifacts/w289/W-289-hongguo-play-fail.md`——紅果站方 API 回空內容，腳本本機服務每集 `502 media session failed`，App 原生 10 秒 → MPV → 逐線路換，約 90 秒後才顯示 `mpv error -13`。
- 範圍：通用（不寫死站名），不改腳本、不碰簽章、不改重試策略。

## 問題

W-269 的本機迴路探測（`LoopbackMP4Probe`）在原生開啟時同時讀前段，但：

1. 逾時 3 秒，腳本冷建會話要 3～18 秒（紅果失敗要 ~14 秒才回 502），所以探測在 502 回來前就放棄了（W-289 紀錄 `vvc=unknown in 3005ms`）。
2. 就算讀到，5xx 也只被當成「沒結果」。
3. 失敗之後還會換另一個播放器、即時重解析、換其他線路。紅果的五條線路都是同一個腳本去問同一個站方 API，每條約 18 秒，結果都一樣。

## 做法

| 位置 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/MP4SampleEntry.swift` `LoopbackMP4Probe` | `probe` 回 `Finding?`：`.vvc(Bool)` 照舊；腳本本機服務回 **5xx（504 除外）** → `.refused(status)`。504（可能只是慢）、4xx、逾時、沒有回應、讀不到 moov → nil，照舊。逾時 3 → 30 秒（探測跟開啟同時進行，等久不會拖慢起播）。`fetch` 可注入（預設照舊用 `OfflineHTTP.fetcher`），供測試用。 |
| `ios/WebHTVApp/Sources/WebHTVApp.swift` 探測結果處理 | 仍是同一個位址、而且還沒起播（`startupMilliseconds == nil`）時收到 `.refused`：取消起播監看、清掉預解析重試、清掉這次的點播換線監聽（`vodLineObserver`），`router.giveUp(.source("無法播放：來源腳本回報失敗（HTTP n）"))`，走 W-253 既有的失敗顯示路徑。VVC 換 MPV 的邏輯不變。 |

- 直播的換線（`lineObserver`）不動：直播頻道照舊換下一條線。
- 換線監聽只清掉這一次；下一次播放（手動選集、下一集）`observeLine` 會重新設定，`play` 非換線時也會重置 `lineRound`。
- 只認「腳本本機服務自己回的 5xx」：新版紅果腳本在回 502 之前已自己重試 3 次並換過裝置；W-246 的「冷快取第一次 500」走的是 App 代理路徑（`SpiderProxyServer.serves` 的位址不會被探測），不受影響。

## 單元測試

`LoopbackMP4ProbeTests.onlyAScriptsOwnFiveHundredIsARefusal`（`ios/Tests/WebHTVCoreTests/MP4SampleEntryTests.swift`）：用假的 fetch 呼叫真的 `probe`——502、500 → `.refused`；504、404、逾時 → nil；206 bvc2 前段 → `.vvc(true)` 且 `PlayerRouter.needsMPV`；也檢查送出的 `Range`。

- `swift test --filter 'LoopbackMP4Probe|MP4SampleEntry|SpiderProxyServer|PlaybackEngine|PlayerRouter'`：99/99 通過。
- 修正前失敗：拿掉 `.refused` 那一行後，新測試在 502、500 兩項失敗（`Expectation failed: await answer(502) == .refused(502)`），還原後通過。

## Simulator（webhtv-w202，iOS 27，Debug，預設播放器原生，熱點 172.20.10.6）

證據 `.herdr-synapse/webhtv-dev/artifacts/w292/`（`*-applog.txt`、`hg1-end.png`）。

**紅果現況**（正式設定 GitLab `wang-movie.json`「紅果 • 短劇」，小鎮是非多之同床異夢第 1 集；`hg1-applog.txt`、`hg1-end.png`）：

| | 修正前（W-289，084c2de4） | 修正後 |
|---|---|---|
| 經過 | 原生 10 秒 → MPV → 換 5 條線路，每條 18～22 秒 | 10:13:26.560 原生開啟 → 10 秒 MPV（照舊）→ 10:13:39.581 探測 `refused HTTP 502`（11.8 秒）→ 10:13:39.610 `shown failed` |
| 顯示失敗 | 約 90 秒，`無法播放：…(mpv error -13.)` | **13.0 秒**，`無法播放：來源腳本回報失敗（HTTP 502）` |
| 之後 | — | 沒有換線路、沒有 MPV 錯誤、沒有重解析 |

13 秒的下限是腳本自己回 502 要花的時間（它會先重試、換裝置），App 這邊沒有再多等。

**一般 H.264 冒煙**（W-262 kit「KIT｜自有服務」第 3 集：支援 Range 的本機服務、H.264，走的正是這次改到的路徑；每次重開 App）。兩個版本都探測 `vvc=no`（38～767 ms），都在原生起播，沒有換播放器：

| | 從 0 秒 | 從觀看紀錄續播 | 不重開 App |
|---|---|---|---|
| 基準 084c2de4 | 680 ms | 1163／1826／1718 ms（中位 1718） | — |
| W-292 | 1272 ms | 1298／1239／1316 ms（中位 1298） | 325 ms |

兩邊互有高低，落在 Simulator 每次的波動範圍內；成功路徑的程式差別只有把結果包成 `Finding`，探測不在起播的路徑上。

## Ponytail

`ponytail:ponytail-review`（最終 diff）：Looks good. Ship。檢查了 `probe` 唯一呼叫端、同位址與未起播守衛、直播換線不受影響、504／4xx／逾時照舊、30 秒逾時不在起播路徑上。附註（不改）：快速連續切集時，舊探測最多讀 30 秒才結束（結果會被位址守衛丟掉）。

## 限制／沒驗到

- 只有用原生開啟時才會探測（W-269 原設計）；預設播放器設成 MPV 的使用者仍會等 MPV 失敗再換線。
- 本機服務給的是 504，或根本不回應／逾時：照舊流程。
- 真機沒測。
- 修正只縮短等待、讓錯誤看得懂；紅果本身仍然播不出來（站方問題，見 W-289）。

## 回退

`git revert` 本單提交。沒有資料格式或設定改動。

## 狀態

已送審（Reviewer：webhtv-dev-codex-reviewer-2）。
