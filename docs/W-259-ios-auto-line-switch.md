# W-259 iOS 點播播放失敗自動換線：設計研究

- 工單：herdr W-259（Manager 派）；只寫文件，不改程式。分支 `task/W-259` 自 ios-poc `ad6a66a0`（含 W-253 `f4d67bee`）。
- 起因：W-249 發現飛魚、七色番第 1 條線失效時，Android（FongMi）會自動換到下一條線，iOS 只能手動換。
- 範圍：點播（VOD）的線路（flag）自動切換。直播已有自動換線（IOS-POC-59、`LiveLineSwitcher`），不在本案。

## 1. FongMi（Android）怎麼做

以下引用 repo 內的 FongMi fork。L＝`app/src/leanback/java/com/fongmi/android/tv/ui/activity/VideoActivity.java`，M＝`app/src/mobile/.../VideoActivity.java`，PM＝`app/src/main/java/com/fongmi/android/tv/player/PlayerManager.java`，PA＝`app/src/main/java/com/fongmi/android/tv/ui/activity/PlaybackActivity.java`。leanback 與 mobile 的邏輯幾乎相同。

**觸發條件**：唯一入口是 `onError(String)`（L:5456、M:5743）。它停止播放、`showError`，再呼叫 `startFlow()`（L:5639）。會走到這裡的有：
- 取播放網址失敗：DRM 不支援、站回訊息、空網址（PA:330-337）；`SiteViewModel.execute` 30 秒逾時或例外（`main/.../model/SiteViewModel.java:196-209`）。
- 起播逾時：`PM.onPlaybackTimeout`（PM:417-426），預設 `Site.getTimeout()`＝`Constant.TIMEOUT_PLAY` 15 秒。
- 解析失敗：`PM.onParseError`（PM:6083-6092）。
- 播放器錯誤：`PM.onPlayerError`（PM:7536-7587）先做完各種**原地重試**（MPV 格式／HLS variant／Vulkan→OpenGL、Exo 的 retryFormat、解碼 tunneling 關閉、本機代理重連最多 2 次），剩下的 FATAL 才 `onError`。`RELOAD` 也會落到 `onError`（PA:277-278）。
- 沒有自動換播放器（Exo/IJK/MPV）再換線的流程，也沒有依 HTTP 狀態碼分流（`PlaybackErrorClassifier` 未細讀，不確定）。

**順序與範圍**（`startFlow`）：
- 有解析時先輪換解析（`checkParse`，L:5646）。
- 換線 `checkFlag` → `nextFlag`（L:5660、5764）：從目前線路往後一條，**不繞回開頭**；已是最後一條就 `checkSearch(false)` 搜尋其他站。
- 同一集：`seamless(flag)` 用 `flag.find(history.episode, true)`（`Flag.java:168-187`）：先同一個 Episode，再按集名／數字評分，最後退回同位置。
- 播放位置：判定同一集時保留進度（L:3736-3743、5596-5605）。

**換站**：`checkSearch` → 搜尋 `isSearchable && isChangeable` 的站，片名完全相同才算，排除已失敗的站，依站點健康度挑最佳（L:5680-5780）；新站用新的紀錄 key，按片名合併舊紀錄（`History.java:421-436`）。

**上限**：沒有重試計數；上限＝剩下的線路數＋搜到的同名站數。都用完就停在錯誤畫面（L:3444）。

**設定**：總開關 `PlayerSetting.isAutoChange()`（pref `player_auto_change`，預設開，`main/.../setting/PlayerSetting.java:246-252`），介面字串「自動換源」；每站 `Site.isChangeable()`（預設可換）——目前站不可換時完全不自動換。手動「換源」按鈕不受總開關限制。

**提示**：`Notify.show`：「正在切換線路至「%s」」「正在切換站源至「%s」」（`values-zh-rTW/strings.xml:82-83`）。

## 2. iOS 現況與接點

- **詳情頁開播**：`VodView.play(_:flag:)`（`ios/WebHTVApp/Sources/WebHTVApp.swift` 約 3258）解析網址（`SourceClient.playbackURL`）後 `PlaybackSession.open`。解析失敗只設 `playbackError`（詳情頁跳錯誤），不會試別條線。
- **換集**：`VodView.start(_:flag:usingPrefetch:)`（約 3401）；預解析位址失敗時即時重解析一次（IOS-POC-15D，`retryWithoutPrefetch`）。
- **播放器失敗**：`PlayerRouter`（`ios/Sources/WebHTVCore/PlaybackEngine.swift`）每次嘗試可換一次引擎（原生↔MPV，`PlaybackEngineSelection.fallback`）；用完後 `onUnrecoverable` → `PlaybackSession`（約 5790）`notePlayHealth(false)`、`onFailure`（播放器畫面泡泡）、`lineObserver?(.failed)`。**`lineObserver` 只有直播設定**；點播的失敗不會回到 `VodView`。
- **W-253**：起播逾時且備援已用完、原因 neverReady／HTTP → `router.giveUp`；預熱連兩次 5xx 的下一集 → 交棒當下 `giveUp(.source(...))`。兩者都走同一個 `onUnrecoverable`。
- **直播的換線**：`LiveLineSwitcher`（`ios/Sources/WebHTVCore/Live/LiveLineSwitcher.swift`）一輪：從選定線路開始、**繞回**、略過 iOS 不能播的線；`LiveTVView` 靠 `lineObserver(.started/.failed)` 推進。這是點播可以照用的形狀。
- **同一集對應**：`Flag.episode(after:)` 用網址比對（同一條線內）；換線後網址不同，要用集名／順序。`Flag.playNow` 已有「依集名（不分大小寫）找、找不到退第一集」的邏輯，可抽出共用。
- **播放位置**：`PlaybackSession.retryResumeSeconds`（W-243 C3）已有「從失敗位置重開」的機制；`forgetRetryPosition()` 在手動選集時清掉。
- iOS `Site` 沒有解析 `changeable`。

## 3. 方案比較

| | A 不做 | B 照搬 FongMi | C iOS 調整版（建議） |
| --- | --- | --- | --- |
| 觸發 | — | 任何錯誤（引擎內原地重試後） | 只在 iOS 既有恢復都用完後：引擎備援已用、預解析重試已用、W-253 giveUp，或解析失敗／沒有網址 |
| 順序 | — | 往後一條，不繞回；用完搜其他站 | 一輪：從目前線路往後、繞回、每條最多一次（同 `LiveLineSwitcher`）；跳過找不到同一集的線 |
| 換站 | — | 有（同名搜尋） | 第一階段不做（另立案） |
| 同一集 | — | `Flag.find` 評分 | 集名不分大小寫相同 → 同位置 index → 跳過此線 |
| 位置 | — | 保留 | 已起播：從失敗位置（`retryResumeSeconds`）；未起播：原本起點 |
| 開關 | — | 設定「自動換源」預設開＋每站 changeable | 第一階段一律開、不加設定；第二階段視需要加設定與 `changeable` |
| 優點 | 零風險 | 與 Android 一致 | 不改 W-253／15D／17F 的既有恢復順序，只在「最後失敗」之後多一層；邏輯可做成純函式測試 |
| 缺點 | 使用者要手動換 | 引擎備援、預解析重試、W-253 的判斷會被提早打斷；不繞回漏試前面的線；換站要搜尋全部站，iOS 目前無此流程 | 比 Android 少換站；整輪最壞耗時＝線數 ×（解析＋最多約 30 秒起播） |

## 4. 與既有機制的互動（方案 C）

- **W-253 確定性失敗**：預熱連兩次 5xx 的下一集，交棒時直接換到下一條線的同一集，**不必先開引擎**；顯示「這一集第 1 條線來源連續兩次回應 HTTP 500，已切換到「線路 2」」。所有線都失敗才顯示 W-253 的原因。
- **W-253 起播放棄（約 30 秒）**：放棄後才換線；不改 W-253 的判斷。
- **預解析／預熱／預抓（W-243、W-245）**：都是對「目前線路的下一集」做；換線即 `prefetch.invalidate()`＋`nextContent.dropAll()`（`play` 已這樣做），新線路從頭照常預載。
- **IOS-POC-15D 預解析重試**：先用完（即時重解析一次），仍失敗才換線。
- **302 退路**（解析器內的轉址處理）：屬於 `SourceClient` 解析的一部分，先跑完；換線只看最終結果。
- **續播紀錄**：換線成功後紀錄的 `vodFlag` 改成新線路（下次「立即播放」從這條開始，與 Android 相同）；整輪失敗不改紀錄。
- **站點健康度**：每條失敗線仍記一次 `notePlayHealth(false)`（現行為），成功的那條記成功。
- **離線下載的集數**：不換線（本機檔案失敗與線路無關）。
- **使用者手動選線／選集**：重設這一輪。

## 5. 建議

採 **C**。理由：iOS 已有 Android 沒有的恢復層（引擎互換、預解析重試、W-253 判斷），換線放在它們全部失敗之後，才不會把現有修好的行為打斷；一輪繞回比 Android 的「只往後」多試前面的線，與 iOS 直播一致。換站另立案，因為 iOS 沒有「同名跨站搜尋」流程，牽涉搜尋與健康度排序，規模不同。

**最小實作（另立實作工單後）**
1. WebHTVCore：`VodLineSwitcher`（或把 `LiveLineSwitcher` 泛化成接受「這條線可不可以試」）＋`Flag.sameEpisode(as:in:)`（集名 → index）；單元測試：繞回、略過沒有該集的線、每條最多一次、手動選擇重設。
2. `PlaybackSession`：點播也設一個失敗觀察者（沿用 `lineObserver` 的 `.started/.failed`，或新增 `vodLineObserver`），在 `onUnrecoverable` 的「沒有重試」分支與 W-253 known-failure 分支通知 `VodView`。
3. `VodView`：收到 `.failed` → switcher 給下一條 → `onNotice`「正在切換線路至「X」」→ 以保留位置 `play`；`.started` → 結束這一輪；解析失敗（`playbackError` 分支）同樣換線。
4. 文件與 Simulator 驗收。

**驗收**
- 單元測試全過。
- Simulator（沿用 W-253 的測試 py 爬蟲，加一部兩條線的劇：線 1 第 1 集每次 500、線 2 正常）：開播後自動換到線 2 第 1 集並起播，畫面出現「正在切換線路至「線路 2」」；所有線都壞的劇最後顯示原因且不轉圈；已起播 30 秒後才失敗的集數換線後從約 30 秒處續播。
- 既有行為不退步：引擎互換、預解析重試、W-253 的 f1／t1 情境照舊。

**回退**：單一 commit，`git revert` 即可；不改設定格式、不改紀錄格式（只是 `vodFlag` 寫入新值，與手動換線相同）。

**估時（本 agent 實作）**：Core＋測試 1 小時、App 接線 1.5 小時、Simulator 驗收 1 小時、文件與審查 0.5 小時，約 4 小時。第二階段（設定開關、`changeable`、跨站換源）另估。

## 6. 研究證據與未查證

- 上游實作：repo 內 FongMi fork（`app/src/**`），本次只讀程式碼、未實機執行（2026-11-09）。
- 官方規格／平台文件、論文、部落格：不適用——這是產品流程的選擇，不是協定或平台 API 問題；AVFoundation／mpv 的錯誤分類已在 IOS-POC-17、W-253 處理。
- 未查證：FongMi `PlaybackErrorClassifier` 細節；FongMi 在清單用完後是否可能反覆搜尋（讀碼看不出）；Android 實機換線的實際體驗（熱點恢復後可在 W-255 的 FongMi 實測時順便看）。

## 審查

Reviewer webhtv-dev-codex-reviewer-2 核准 6569d6f9（看板 #6773、#6774），抽查 FongMi 行號正確。實作工單必須納入：
1. 同一集對應：先比集名，再比集名裡的集數數字；兩條線集數相同時才用同位置 index，否則跳過這條線（多了預告或缺集時 index 會對錯集）。
2. 一輪總時間要有上限，或每次換線的提示讓使用者可以停止，避免連續換好幾分鐘。
3. W-253 已知失敗直接換線時，新線路要重新預熱／解析，不能沿用舊線的 `knownFailing`。

## 狀態

已核准；由 Manager 交使用者決定是否實作（約 4 小時）。
