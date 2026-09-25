# IOS-POC-5S — 廣告、片頭、片尾

- 狀態：**5S-1（ads）、5S-2（片頭片尾）、5S-3（config `rules`）全部已完成程式實作**。
  **IOS-POC-5S 整體 code complete**——但**不是 real-device acceptance complete**：
  5S 的三個部分沒有任何一項在真機上被人看著運作過。
- 5S-1 基線 HEAD `fc106079`；5S-2 基線 HEAD `eba5346c`（2026-09-22）；
  **5S-3 基線 HEAD `60a9241e`（2026-09-23）**
- Lane：`standard`

## 量測（動手前，不猜 schema）

使用者的兩份設定檔實測結果。

### `ads`：扁平的字串陣列

| 檔案 | 筆數 |
|---|---:|
| `wang-movie.json` | 1 |
| `wang-sex.json` | 62 |
| **合計** | **63** |

**63 筆不等於 63 條規則**：**62 筆是 domain 形狀，1 筆是完整 URL**
（`https://lf1-cdn-tos.bytegoofy.com/obj/…`）。

Android 唯一的消費點是 `CustomWebView.shouldInterceptRequest` → `isAd(host)` →
`Util.containOrMatch(host, ad)`，也就是 `host.contains(ad) || host.matches(ad)`，**只比對 host**，
命中就回空回應。`RuleConfig` 把 VodConfig 與 LiveConfig 的合併。

**完整 URL 那一筆永遠不可能是 host 的子字串，所以它在 Android 上本來就是死的**——
本移植也讓它保持 inert。**把它 normalize 成 host 會是新增 Android 沒有的行為。**

另外實測：63 筆裡**沒有任何 ≤6 字元的短字串，也沒有任何 regex 元字元**，全是完整網域
（cnzz、hm.baidu、google-analytics、googletagmanager 之類）。

### `rules`：`{name, hosts, regex?, script?, exclude?}`

19 筆，鍵出現次數 `name` 19、`hosts` 19、`regex` 17、`script` 2、`exclude` 2。

唯一消費點是 `Sniffer.getRule(uri)`：以 **host** 比對（URI 的 host **或它 `url=` 查詢參數的 host**），
**第一個命中者勝出**，然後 `exclude` → 判定不是影片、`regex` → 判定是影片，
都沒命中才落到內建 `SNIFFER` pattern。`script` 餵給 WebView 注入的 JS。

### m3u8 廣告規則：**在這個 Android app 裡沒有消費者**

`wang-sex.json` 有 9 條明顯為了剝除 m3u8 廣告而寫的規則
（`#EXT-X-DISCONTINUITY…`、`15.1666`、`16.63`）。搜過整個 repo：

> `Rule.getRegex()` / `getExclude()` / `getScript()` 的消費者**只有 `Sniffer`**。

那些 regex 會被拿去比對**網址**，永遠不命中。**它們在這個 app 裡是死的。**
所以「不實作 HLS mid-stream 廣告」不只是保守，**是根本沒有契約可以移植**；
要做就得自己發明規則語意，那正是本專案禁止的猜測。

### 片頭片尾：**不在設定檔裡**

與 `ads`／`rules` 完全無關。住在 `History`：`opening` / `ending`，**`long` 毫秒**，
初始 `C.TIME_UNSET`，**由使用者在播放器上用 ±1000ms 按鈕自己設**。消費點精確地只有兩處：

| 位置 | 語意 |
|---|---|
| `VideoActivity:5603` | `position = max(opening, position)` — 起播位置 |
| `VideoActivity:5550` | `ending > 0 && duration > 0 && ending + position >= duration` → `checkEnded` |

我們的 `WatchHistory`（注意：型別名稱是 `WatchHistory`，不是 `WatchHistoryRecord`）已經是毫秒、
已有 `position`／`duration`／`isNearEnding`／`resumePosition`，**只缺這兩個欄位**。
這是 5S-2 的工作，下面一整節就是它。

5S-2 實作時又補量了三處上面沒寫到、但決定了 UI 語意的東西：

| 位置 | 語意 |
|---|---|
| `VideoActivity`（mobile）`onOpening`／`onEnding` | 點一下＝`opening = position`／`ending = duration - position` |
| `VideoActivity`（leanback）`onOpeningAdd/Sub` | 方向鍵上下＝`max(0, max(0, opening) ± 1000)`，**這就是使用者說的 ±1000ms** |
| `VideoActivity` 兩版 `onOpeningReset` | 長按＝設 0 |
| `PlayerManager.canSetOpening/canSetEnding` | `position > 0 && duration > 0`，且距離該端點不超過 `Constant.getOpEdLimit(duration)` |
| `Constant.getOpEdLimit` | `< 15 分` → 3 分；`< 30 分` → 6 分；否則 10 分 |

也就是說 Android 的四個操作是**設為目前位置 / +1 秒 / −1 秒 / 清除**，`±1000ms` 只是其中兩個。

## 5S-1：`ads` → 嗅探 WebView 的宣告式封鎖

### 為什麼不是原樣移植

`WKWebView` **沒有 `shouldInterceptRequest`**。原樣移植不是「比較差」，是**不存在**。
iOS 的對應物是 `WKContentRuleList`——Safari 內容封鎖器的同一套引擎，**宣告式**，
比對發生在這段程式碼底下，不刪 DOM、不做啟發式。

### 與 Android 的三個差異，都是窄化，都刻意

1. **字面網域經過 escaping，不當成 pattern。** Android 把原字串丟給 `String.matches`，
   所以 `s13.cnzz.com` 的點是萬用字元。63 筆實測全是字面網域、無元字元、無短字串，
   所以 escaping **不會失去任何已設定的行為**，只移除短字串式的過度攔截。
2. **host 有錨定。** Android 的 `contains` 會命中 `s13.cnzz.com.example.net`；本規則只命中該網域與其子網域。
3. **top-level document 永不被擋。** `resource-type` 列出 WebKit 提供的全部類型**除了 `document`**。
   **這是本專案刻意採用的安全窄化，不是 Android 原樣行為**——Android 不分請求類型一律照 host 擋。
   嗅探頁面正是這個 WebView 存在的唯一目的，能取消它的規則會把封鎖清單變成來源故障。

### 兩件對著 WebKit 量出來、不是猜的

- **`([:/]|$)` 會被拒絕**（`Invalid or unsupported regular expression`）：content blocker 的 regex
  子集只接受出現在整個 pattern 最後的 `$`。改用 `[:/]` 就夠——WebKit 會先把
  `https://host` 正規化成 `https://host/` 才比對。
- **只 escape `.`**：`isHostShaped` 已把輸入限制在英數與 `.`、`-`、`_`，其中只有 `.` 是元字元；
  escape `-` 或 `/` 會產生該子集不接受的跳脫序列。

第一版還踩到一個**決定性錯誤**：`JSONSerialization` 對 dictionary 的鍵**沒有固定順序**，
於是同一份 `ads` 每次序列化結果不同，內容雜湊出來的 identifier 就不再是 identity。
`a.identifier == aAgain.identifier` 直接失敗抓到。修法是 `.sortedKeys`。

### 規則屬於 active configuration

identifier 由**規則內容**的 SHA-256 導出，所以：切換設定檔 A→B→A 時，B 不會繼承 A 的 compiled list
（`adBlockList` 一改就清掉快取），切回 A 時直接重用 A 自己那份。
**`ads` 為空 → `AdBlockList.make` 回 `nil` → 完全不編譯、不掛載**，與沒有 blocker 的 build 無法區分。

App 在**三個** adopt 路徑都設定：啟動時的 restore、抓取後的 adopt、pack 造成的 rebuild。

### 只掛在嗅探 WebView

規則加在 `Collector` 自己的 `WKWebViewConfiguration` 上，該 configuration 每次 sniff 建立、用完丟棄。
**沒有**掛到 WebHome bridge 的 WebView、設定頁、或任何 process 層級的預設 configuration。

## 5S-1 驗證

| 檢查 | 結果 |
|---|---|
| 63 entries 分類 | **62 host rules + 1 inert URL entry**，inert 那筆被保留可回報，不是默默丟掉 |
| 規則可編譯 | 對真實 `WKContentRuleListStore` 編譯成功（不是檢查 JSON 字串） |
| **真實頁面載入：被擋 host 的 top document** | **仍然載入**，而 `/ads.js`、`/tracker.gif` **沒有抵達 socket** |
| **真實頁面載入：不相關的規則** | `/page.html`、`/app.js`、`/ads.js`、`/tracker.gif` **全部照常抵達**——沒有過度比對 |
| A→B→A 切換 | 每一步 compiled list 都被清掉並重建成當前那份；切回 A 命中 A 自己的 identifier |
| 空 ads | 不建立 blocker（`make` 回 nil，`compiledRulesForTesting` 回 nil） |
| identity 決定性 | 同樣輸入同樣 identifier；不同輸入不同；順序不同也算不同 |
| 既有 sniffer 行為 | `isCandidate`、wrapper 解包、headers、redirect／sniff 流程測試全部維持 |
| 全套 | **197 條，全過** |
| 模擬器 build | BUILD SUCCEEDED |

那條長期因 provider 狀態而浮動的 `reportsLiveType4SitesFromProvidedConfig` 本輪也通過了。

## 5S-1 尚未驗證

**沒有人在 App 裡看著它擋掉真實廣告。** 上面全部是測試證據——但那個 WebKit 測試走的是真實
`WKContentRuleList`、真實 `WKWebView`、真實 socket，不是 mock。真機上的行為仍未有人目視確認。

## 5S-1 回滾

單一 commit，`git revert` 即可。關閉開關：`ads` 解析為空（或把 `adoptAdBlocking` 改成永遠設 nil），
規則就完全不存在。

## 5S-2：`History.opening` / `History.ending` → `WatchHistory` + `PlaybackSession`

### 資料模型與 migration

`WatchHistory` 多兩個欄位，型別 `Double?`，毫秒：

```swift
public var opening: Double?
public var ending: Double?
```

**為什麼是 Optional，而且這件事不是風格問題。** `WatchHistory` 用合成的 `Codable`，它**不會**回退到
屬性的預設值——非 Optional 欄位碰到舊 JSON 會丟 `keyNotFound`，而 `WatchHistoryStore.loaded()` 把
「解不開」讀成「沒有任何記錄」。所以一個 `?` 就是「新增欄位」與「刪掉使用者全部觀看紀錄」的差別。
IOS-POC-10E 的 `sourceID` 當初正是為了同一個理由做成 Optional，這裡照抄那個決定。

**sentinel 對齊 Android，但不搬 Android 的常數。** Android 初始值是 `C.TIME_UNSET`（`Long.MIN_VALUE + 1`，
一個很大的負數），但它的 reset 鍵寫的是 `0`，而四個消費點全部測 `> 0`——**在 Android 上「不是正數」
本來就等於未設定**。iOS 因此把 `nil`、`0`、負數、非有限值全部收斂成同一個狀態，由
`openingOffset` / `endingOffset` 這兩個 computed property 在**唯一一處**決定。刻意不複製
`C.TIME_UNSET` 本身：那會在 Swift API 裡放一個沒有任何消費端讀得回來的 sentinel。

### 語意，全部是 Android 的，放在 `WatchHistory` 裡當純函式

| 函式 | Android 出處 |
|---|---|
| `startPosition(resuming:)` | `VideoActivity.setPosition()` 的 `max(getOpening(), getPosition())` |
| `hasReachedEnding(position:duration:)` | `onTimeChanged()` 的 `ending > 0 && duration > 0 && ending + position >= duration` |
| `canSetOpening` / `canSetEnding` | `PlayerManager` 同名方法 |
| `openingEndingLimit(duration:)` | `Constant.getOpEdLimit`（internal，只服務上面兩個 predicate） |
| `setOpening(_:duration:)` / `setEnding(_:duration:)` | `onOpeningAdd/Sub/Reset` 的 `max(0, …)`，**加上 Android 沒有的上限** |

**放在 `WebHTVCore` 而不是 App target 是刻意的**：這樣整條語意都能被 `swift test` 直接測，
App target 只剩接線。

`startPosition` 的 `resuming` 參數對應 IOS-POC-14：一筆記錄涵蓋整部片（`WatchHistory.key` 是
站＋片，不是集），所以自動播下一集時**不能**把上一集的 position 續進去，但片頭仍然屬於這部片、
仍然要套用。

### 起播

`PlaybackSession.open` 原本只在 `resuming == true` 時去讀 store。現在**不論是不是續播都讀**，
原因是一個實際會咬人的 bug：

> `VodView.record(for:flag:)` 每次都**從頭組一筆全新的樣板**，裡面沒有 opening/ending。
> 樣板直接被指派給 `PlaybackSession.record`，而 `persist()` 就是把 `record` 寫回 store 的人。
> 若不在這裡把 store 裡的值併回來，**使用者設好的片頭片尾會在下一次取樣時被空樣板覆蓋掉**。

`open` 因此變成：讀 store → 把 `opening`／`ending`／`position`／`duration` 併進樣板 → 算
`startPosition(resuming:)` → 才 `start`。這一處同時涵蓋「重開一部片」與「自動播下一集」兩條路徑，
也就是為什麼下一集會繼承同一部片的設定、而**不可能**繼承上一部片或上一個來源的設定——
key 不同就是不同記錄，store 本來就以 key 為準。

### 片尾

走既有的五秒取樣器，**不另外造一條 ended pipeline**：取樣器本來就每五秒讀一次 position 與
duration，命中就呼叫既有的 `finished()`，於是片尾拿到的是真正播完會拿到的同一套
auto-advance／history 寫入／關閉播放器。

只在 **rising edge** 觸發。交棒是非同步的（解析下一集要一次 `playerContent`，有時還要 sniff），
沒有 edge 的話五秒後的下一次取樣會再要一集。重播或換集會讓 position 掉回門檻以下，flag 自己就清掉了，
所以 `control("loop")` 仍然正常。

`ponytail:` 寫明了天花板：**Android 的 clock 是 1 秒，這裡是 5 秒**，所以片尾最多會多播五秒才跳。
升級路徑是 1 秒的 `addPeriodicTimeObserver`，或等 duration 已知後設
`AVPlayerItem.forwardPlaybackEndTime`——兩者都是為了五秒而新增機制，現在不值得。

### 邊界

| 情況 | 行為 |
|---|---|
| `opening` 大於 duration | clamp 到 `duration - endingOffset`。**Android 只 floor 不 cap**，一直按上鍵會把 opening 推過片長，`setPosition` 就 seek 到片尾之後——那是缺陷不是契約 |
| `ending` 大到吃掉 opening | clamp 到 `duration - openingOffset`，有效播放區不會變負 |
| duration 未知（0、負數、直播） | `hasReachedEnding` 直接回 false，不會提前跳；`setOpening/setEnding` 只 floor 不 cap，上限等 duration 出現的下一次寫入再補 |
| 負數／`NaN`／`Infinity` | `openingOffset`／`endingOffset` 讀成 0；寫入時 `clamped` 也擋掉 |
| 從 0 再按 −1 秒 | 0，與 Android 的 `max(0, max(0, opening) - 1000)` 相同 |

### UI

> **2026-09-23 更新：這一節描述的位置已被使用者否決，改由 IOS-POC-16 取代。**
> 使用者要求控制不要浮在影片上。查證結果是 iOS **既不能插入 AVKit 的 transport bar，也無法得知
> 它何時顯示**（`willTransitionToVisibilityOfTransportBar` 同樣是 tvOS 專用），所以「跟著控制列
> 淡入淡出」這條路不存在。決定自建整條控制列：`docs/IOS-POC-16-custom-player-controls.md`。
> **下面的描述仍然是目前 `0.1.5 (6)` 的實際行為**，在 16 落地前不變。
> （2026-09-25 更正：IOS-POC-16 已落地，`2deac879`（2026-09-23），隨 `0.1.6 (7)` 發布。片頭／片尾
> 控制現在在自建控制列 `PlayerControlBar` 裡（`ios/WebHTVApp/Sources/WebHTVApp.swift:3699`），下面的
> overlay 只描述 `0.1.5 (6)` 及更早版本的行為。）

**AVKit 在 iOS 上的控制列不能擴充**——`transportBarCustomMenuItems` 是 tvOS 的。所以 OP/ED 只能做成
overlay，放在**右側邊緣、垂直置中**：那是 `AVPlayerViewController` 全螢幕版面裡上方列
（Done／PiP／AirPlay）與下方 transport bar 都不佔的一塊。

觸控螢幕沒有方向鍵，所以 Android 的「點 / 上 / 下 / 長按」收成**一個 `Menu`、四個項目**：
`設為目前位置`、`+1 秒`、`−1 秒`、`清除`。操作本身一個沒改、一個沒加。

兩件實作上的事：

1. **「設為目前位置」的位置由 `PlaybackSession` 自己讀**，不是 view 算好傳進去。第一版把
   `session.status()` 放在 `@ViewBuilder` 裡，那是 **render 時**求值——使用者點下去拿到的會是
   上一次 layout 的舊 position。Ponytail final-diff review 抓到的就是這一條。
2. **結果用既有的 HUD 回報**（拖曳手勢本來就有這個 readout，抽成 `flashHUD`）。這不是裝飾：
   clamp 會存進比要求更小的數，`canSetOpening/canSetEnding` 還會整個拒絕——沒有回報的話，
   一個 Android 會默默忽略的項目在 iOS 上看起來就是壞掉的按鈕。

沒有記錄身分的播放（`player.playUrl`、頁面自己的 inline playlist）**完全不顯示這組控制**。

### `app.history`

`opening` / `ending` 從固定的 `0` 改成 `record.openingOffset` / `record.endingOffset`。
**這是把 Android 本來就宣告的欄位填上，不是暴露 iOS 自己發明的欄位**——`History.java` 兩個欄位都有
`@SerializedName`。未設定仍然送 `0`，理由 R5 已經寫過：Android 的 `C.TIME_UNSET` 是很大的負數，
對頁面任何 `> 0` 的判斷來說跟 0 讀起來一樣。`quality` 依舊**不在** payload 裡。

### 驗證

| 檢查 | 結果 |
|---|---|
| 舊 history JSON（單筆與整個陣列）沒有這兩欄仍正常 decode | **通過**，且 `position`／`duration` 原封不動 |
| 新欄位 round-trip 過 store | 通過 |
| opening 比 resume 大 → 從 opening 起播 | 通過 |
| resume 比 opening 大 → 保留 resume | 通過 |
| opening 未設定 → resume 行為一字未改（含 D4 十秒門檻） | 通過 |
| 看完的片重播 → `isNearEnding` 殺掉 resume，只剩 opening | 通過 |
| 下一集吃 opening、不吃上一集 position | 通過 |
| ending 命中 threshold（前後各一毫秒） | 通過 |
| ending 未設定／為 0／為負 → 永不觸發 | 通過 |
| duration 未知（0、−1） → 永不觸發 | 通過 |
| `getOpEdLimit` 三段與 `canSet*` 的可標記窗 | 通過 |
| opening 推過片長 → clamp | 通過 |
| ending 吃掉 opening → clamp，有效播放區不為負 | 通過 |
| 從 0 減 1 秒 → 0 | 通過 |
| duration 未知時只 floor 不 cap | 通過 |
| `NaN` / `Infinity` 被拒 | 通過 |
| 跨 title / 跨 site / 跨 config 不串線 | 通過 |
| 同一部片換集換線路，設定跟著走且不被覆蓋 | 通過 |
| `app.history` 設定值與未設定值 | 通過 |
| 既有 WatchHistory、PlaybackSession、`app.history`、multi-quality、播放器測試 | **全部維持** |
| 全套 | **225 條，全過**（5S-2 之前是 203） |
| 模擬器 build | BUILD SUCCEEDED（`id=7B4E9557-…`） |

### 尚未驗證

- **真機一次都沒跑。** 下面每一項都只有單元測試或模擬器建置的證據：
  - overlay 在真機 `AVPlayerViewController` 全螢幕版面裡**實際不擋到** Done／PiP／AirPlay／
    transport bar——這是量過版面規則後選的位置，**不是看著真機量的**；
  - `Menu` 疊在 `simultaneousGesture` 的音量拖曳區上，點按不會被手勢吃掉；
  - 片尾命中後 auto-advance 在真實串流上接得上；
  - 五秒取樣造成的延遲在真機上主觀可不可以接受。
- **片尾與 PiP 同時發生**沒有測過。
- **沒有真實 WebHome 頁面讀過**帶值的 `app.history.opening/ending`。

### 回滾

單一 commit，`git revert` 即可。資料面向下相容是雙向的：revert 之後舊版仍然能 decode 帶了這兩欄的
JSON 嗎——**不能**，舊版的合成 `Codable` 會忽略不認得的鍵，所以**可以**，多的鍵被丟掉而已，
其餘欄位照常。使用者只會失去片頭片尾設定，不會失去觀看紀錄。

### Ponytail

**實作前（設計軸）。** ① 需要存在——使用者要求，且 Android 有量過的契約。② 已有的東西先用——
`WatchHistory`／`WatchHistoryStore`／`PlaybackSession.record`／`persist`／`finished`／取樣器／
`status()` 的毫秒 position/duration／`PlayerPickerView` 那套「讀出既存記錄、把記住的欄位填回樣板」
（quality 用的就是它）／`sourceID` 的 Optional migration 手法，全部沿用，**沒有第二套 playback state**。
③ 標準庫——`Codable`、`max`/`min`、`KeyPath`。④ 原生平台——評估過
`AVPlayerItem.forwardPlaybackEndTime` 與 1 秒 `addPeriodicTimeObserver` 當片尾觸發器，兩者都是為了
「5 秒 → 精確」而新增機制，取樣器本來就在算那兩個數字，所以用取樣器並把天花板寫進 `ponytail:`；
`transportBarCustomMenuItems` 查證為 tvOS-only，所以 overlay 是 iOS 上唯一的插入點。⑤ 沒有新相依。
⑦ 最小：兩個欄位、六個純函式、一處併回點、一個 rising-edge 判斷、一組 overlay。

刻意不做：自動偵測片頭片尾、AI／OCR、來源提供的章節時間、遠端規則、m3u8 heuristics、
每集各自的設定（Android 也是整部片一筆）、獨立的設定頁、把設定同步到任何地方。

**final diff 軸。** 抓到並修掉一條真缺陷：`skipControls` 在 `@ViewBuilder` 裡呼叫 `session.status()`，
那是 render 時求值，「設為目前位置」會標到上一次 layout 的舊 position——改成
`PlaybackSession.markOpening/markEnding` 自己讀。另外 `openingEndingLimit` 從 `public` 收成
`internal`（App target 不呼叫它，只有同型別的兩個 predicate 與測試用）。一條測試
`oneRecordCoversEveryEpisodeOfItsTitle` 原本是恆真式（`key(A,1) == key(A,1)`），改寫成真的走 store 的
換集換線路案例。新增的每個 public 成員都有呼叫端。一個 `ponytail:` 註記寫明五秒取樣的天花板與升級路徑。

## 5S-3：config `rules` → MediaSniffer

### 先把 Android 的原始碼讀完，不用摘要

`app/src/main/java/com/fongmi/android/tv/utils/Sniffer.java` 有三段，**每一段都有一個容易被摘要寫錯的地方**。

```java
private static Rule getRule(Uri uri) {
    if (uri.getHost() == null) return Rule.empty();
    String hosts = TextUtils.join(",", Arrays.asList(UrlUtil.host(uri),
                                                     UrlUtil.host(uri.getQueryParameter("url"))));
    for (Rule rule : RuleConfig.get().getRules())
        for (String host : rule.getHosts())
            if (Util.containOrMatch(hosts, host)) return rule;
    return Rule.empty();
}
```

**① haystack 是一個「逗號串起來的字串」，不是兩個候選。** 所以 direct host 與 `url=` 裡的 host
**彼此沒有優先順序**——規則只要它的 host 出現在那一對裡的任何位置就命中。
優先順序在**規則層**：設定檔順序，first match wins。
（本移植的 `theDirectHostAndTheWrappedHostShareOneHaystackWithNoPrecedenceBetweenThem`
把同一組 host 前後對調各測一次，證明贏的是設定檔順序而不是 direct host。）

**② `containOrMatch` 只對 host 字串比對。**

```java
public static boolean containOrMatch(String text, String regex) {
    try { return text.contains(regex) || text.matches(regex); }
    catch (Exception e) { return false; }
}
```

`contains` 是子字串、`matches` 是 Java 的**整串**比對，而且整個包在 try/catch 裡回 false。
所以**壞掉的 host pattern 在 Android 本來就是不命中，不是崩潰**——這一條是 parity，不是窄化。
它**不是**拿整個 URL 去比，也**不是** fuzzy matching：
`https://other.example/redirect/douyin.com/a` 不會命中 `douyin.com`，有測試釘住。

```java
public static boolean isVideoFormat(String url) {
    Rule rule = getRule(UrlUtil.uri(url));
    for (String exclude : rule.getExclude()) if (url.contains(exclude)) return false;
    for (String exclude : rule.getExclude()) if (Pattern.compile(exclude).matcher(url).find()) return false;
    for (String regex : rule.getRegex()) if (url.contains(regex)) return true;
    for (String regex : rule.getRegex()) if (Pattern.compile(regex).matcher(url).find()) return true;
    …內建 SNIFFER…
}
```

**③ 每個清單跑「兩趟」：先把所有項目當字面子字串，再把所有項目當 regex。**
所以第二個項目的字面命中會贏過第一個項目的 pattern 命中。
寫成「每個項目各試 contains 再試 regex」會改變哪一個項目決定結果。

**④ `exclude` 全面優先於 `regex`，兩者都優先於內建 pattern。**

### 實際量到的 schema

`wang-movie.json` 有 **10 筆**（`name` 10、`hosts` 10、`regex` 8、`script` 2、`exclude` 2），
加上 `wang-sex.json` 的 9 筆共 **19 筆**，與既有紀錄相符。實際內容：

| name | hosts | 內容 |
|---|---|---|
| `cl` | `magnet` | regex `最 新` / `直 播` / `更 新` |
| `火山嗅探` | `huoshan.com` | regex `item_id=` |
| `抖音嗅探` | `douyin.com` | regex `is_play_url=` |
| `農民嗅探` | `toutiaovod.com` | regex `video/tos/cn` |
| `七新嗅探` | `api.52wyb.com` | regex `m3u8?pt=m3u8` |
| `夜市` | `yeslivetv.com` | **script** `…('vjs-big-play-button')[0].click()` |
| `毛驢` | `www.maolvys.com` | **script** `…('swal-button swal-button--confirm')[0].click()` |
| `czzy` | `10086.cn` | regex `/storageWeb/servlet/downloadServlet` |
| `bdys` | `bytetos.com` 等 4 個 | regex `/tos-cn`，exclude `.m3u8` |
| `bdys10` | `bdys10.com` | regex `/obj/`，exclude `.m3u8` |

兩個 `script` 都是「幫使用者按下播放鈕」的 DOM click，沒有別的。

### 接到哪裡

| Android | iOS |
|---|---|
| `shouldInterceptRequest` → `isVideoFormat(url)` | `Collector.userContentController(didReceive:)`，在既有 `MediaSniffer.isCandidate` **之前** |
| `onPageFinished` → `evaluate(getScript(url))` | `Collector.webView(_:didFinish:)` → `evaluateJavaScript` |

**兩者選規則用的是不同的 URI，這一點不能互換**：accept/reject 用**候選 URL 自己的** host，
`script` 用**剛載入完成的頁面**的 host。Android 就是這樣分的。

**`script` 用 `evaluateJavaScript`，刻意不用 `WKUserScript`。** user script 會掛在
content controller 上活到 web view 結束，每次 navigation 重跑並且**疊加**；
Android 是每個 finished page 評估一次。加上 `Collector` 的 web view 本來就是每次 sniff 新建、
用完丟棄，所以跨 sniff 也不可能累積。多段 script 依序執行，因為 Android 把每一段接在前一段的
completion handler 裡——那兩段都是 `.click()`，後一段可能依賴前一段揭開的元素。

**規則只進嗅探 WebView，這是結構上的事實不是承諾**：整個 iOS 樹只有**兩處**建立 `WKWebView`
（`MediaSniffer.Collector` 與 WebHome bridge），而 `ruleset` 只在 `Collector` 內被讀到。

### 全部邏輯在 WebHTVCore，WebKit 層只有接線

`SnifferRules.swift` 是純值：host 取出、規則選擇、`exclude`/`regex` 兩趟優先序、`script` 查詢
全部可以被 `swift test` 直接驅動。`WKNavigationDelegate` 裡沒有任何規則邏輯。

### 設定檔隔離

`MediaSniffer.snifferRules` 由既有的 `adoptAdBlocking(from:)` 一併設定——
**刻意共用同一個接點**：`rules` 大可有自己的 adopt 函式，但那樣日後新增第四條 adopt 路徑時
要記得呼叫兩次，而漏掉的後果是無聲的（舊規則照樣嗅探，只是用錯設定檔的規則）。
它是一個沒有快取的純值，所以**沒有東西「可以」被留下**；A→B→A 是重新建構而不是還原。
`rules` 為空 → `make` 回 nil → 完全不做規則查詢，與本階段之前的行為逐位元組相同。

### malformed regex：Android 會炸，這裡不會（**刻意的 iOS 窄化**）

`isVideoFormat` 的 `Pattern.compile` **不在** try/catch 裡，所以 Android 遇到壞掉的
`regex`／`exclude` 會丟 `PatternSyntaxException`。**沒有 Android fallback 可以移植。**
這裡採最保守的讀法：**該 pattern 不匹配**，把判斷交還給既有的內建測試，
並在**採用設定檔時記一行**（不是每個候選 URL 記一次）。
注意與 host 的差別：host 那條是 parity（Android 自己就回 false），regex 這條才是窄化。

### 那 9 條像 m3u8 的 regex

**維持 inert，一行程式都沒有為它們寫。** `Rule.getRegex/getExclude/getScript` 在整個 Android
repository 裡的消費者**只有 `Sniffer`**，而 `Sniffer` 看的是 URL 字串。
`#EXT-X-DISCONTINUITY` / `15.1666` / `16.63` 拿去比對 URL 就是不命中，如此而已。
**沒有實作** m3u8 mid-stream 去廣告、playlist rewrite、segment skipping、OCR、影像辨識、
DOM heuristics、stream proxy、segment cache 或任何新的廣告演算法。
有一條測試 `theRulesNeverTouchAPlaylist` 明確釘住這件事。

### 一個誠實的風險，照 Android 保留

規則命中 `regex` 就**直接接受**，繞過內建的關鍵字測試——Android 就是這樣。
後果是：對**設定檔點名的那些 host**，一個不像媒體的 URL（例如 `bdys10.com/obj/cover.jpg`
對上 regex `/obj/`）也會被當成串流，而且 sniffer 取的是**第一個**命中。
這與 Android 完全相同，而且範圍被 `hosts` 限制在那 10 條規則點名的網域內。
**沒有加上 iOS 自己的額外窄化**，因為設定檔作者是對著 Android 的這個行為調 `exclude` 的；
擅自收窄反而可能讓他們刻意要的 URL 被擋掉。

### 驗證

| 檢查 | 結果 |
|---|---|
| 真實 10 筆 rules 可 decode；只有 `name/hosts` 的 rule 正常；壞掉的成員不毀整份清單 | 通過 |
| direct host 命中；`url=` 裡的 host 命中 | 通過 |
| direct 與 wrapped 同時存在 → **設定檔順序決定**（前後對調各一次） | 通過 |
| first matching rule wins | 通過 |
| host 比對只看 host，不看 path/query | 通過 |
| 沒有 host 的 URL 不選任何規則 | 通過 |
| `containOrMatch` 的 contains／整串 matches／壞 pattern 回 false | 通過 |
| `exclude` 優先於 `regex`（兩者都命中時） | 通過 |
| exclude 命中拒絕、regex 命中接受 | 通過 |
| 規則命中但這個 URL 沒說到 → undecided | 通過 |
| 沒有任何規則命中 → 完全維持現有行為 | 通過 |
| 字面趟／pattern 趟兩趟都會決定（`m3u8?pt=m3u8` 兩種讀法各一條） | 通過 |
| malformed regex／exclude 不 crash，且不影響同一條規則裡正常的 pattern | 通過 |
| **m3u8-looking regex 不觸發任何 playlist 行為** | 通過 |
| `script` 取自**頁面**的規則；沒命中就沒有 script；空字串跳過 | 通過 |
| **`script` 真的在嗅探 WebView 上執行**（真 socket + 真 `WKWebView`，頁面本身不發任何請求） | 通過 |
| 頁面 host 沒有規則 → 完全不注入，請求沒有抵達 socket | 通過 |
| `snifferRules = nil` → 與本階段之前一致 | 通過 |
| 設定檔 A→B→A 不串線，且回到 A 是 deterministic | 通過 |
| 空 rules 等價於沒有規則 | 通過 |
| 既有 `isCandidate`、wrapper `url=` 解包行為維持 | 通過 |
| **全套** | **297 條，296 通過**（5S-3 之前是 266；新增 **31** 條） |
| 模擬器 build | **BUILD SUCCEEDED** |

唯一失敗是既有的 `reportsLiveType4SitesFromProvidedConfig`（88看球 解析成 `qq-kbs.html`），
handoff 明文記載是 provider 天氣、不要修。本輪**沒有新增任何失敗**。

**一個既有警告，沒有順手修**：`WebHTVConfig.swift` 的 `ads` 那行
（`as? [String]` 的條件轉型無作用）。那行本輪未修改，只是位置下移；依 AGENTS.md §2 回報不修。

### 5S-3 尚未驗證

- **真機一次都沒跑。** 沒有人看著 `script` 在真實站台上按下播放鈕，
  也沒有人看著 `regex`／`exclude` 改變某個來源的嗅探結果。
- **那 10 條規則點名的 host，一個都沒有在真機上實測過**——
  其中 `yeslivetv.com` 與 `www.maolvys.com`（唯二有 `script` 的）最值得看。
- 上面「誠實的風險」那一節的情境**沒有在真實資料上發生過，也沒有被排除過**。
- **2026-09-23 IOS-POC-8L 盤點（桌面檢查，未 live）**：`wang-movie.json` 的全部 site 欄位與
  它引用的 40 個 config-relative 資源裡，**沒有任何來源會碰到 `yeslivetv.com` 或
  `www.maolvys.com`**，所以兩條 `script` rule 在這份設定檔上沒有可測的來源。唯一沾得上的是
  `农民嗅探`（`toutiaovod.com`，regex `video/tos/cn`）對 `🥇｜农民｜高清`（XYQHiker），
  但內建關鍵字本來就含 `video/tos`，規則命中與否**不會改變可見結果**。
  `ads` 在這份設定檔只有 `mozai.4gtv.tv`，同樣沒有來源會請求它。
  嗅探 WebView 不可見、`print` 診斷在 SideStore 安裝上看不到，所以 5S-1／5S-3 的正向行為在真機上
  只能驗非回歸。完整矩陣：`docs/IOS-POC-8L-core-real-device-acceptance.md`。

### 5S-3 回滾

單一 commit，`git revert` 即可。不 revert 的關閉開關：設定檔沒有 `rules`，
或讓 `SnifferRules.make` 永遠回 nil——規則查詢就完全不存在。
沒有資料格式改變，沒有 migration。

### Ponytail

**實作前（設計軸）。** ① 需要存在——5S 的最後一塊，且是 roadmap 進入 12/13 的前置。
② **已有的東西先用**——`AdBlockList` 的形狀（設定檔衍生的值型別 ＋ 單一 adopt 接點 ＋
`MediaSniffer` 上的屬性）整組照抄；`isCandidate` 是既有的單一判準，新規則接在它**前面**而不是
另開一條平行路徑；`WebHTVConfig` 既有的寬容 decode 照用；`Collector` 既有的 per-sniff
configuration 照用。③ 標準庫——`NSRegularExpression` 正好能表達 Java 的 `find()` 與 `matches()`
之別，`URLComponents` 取 `url=`。⑤ 沒有新增相依。⑦ 最小：一個新 core 檔、一個新 decode 欄位、
`MediaSniffer` 三處小改、adopt 接點一行。

**實作前就先解掉的三條 finding**（不是事後補救）：
`script` 不可以用 `WKUserScript`（會累積）；規則邏輯不可以塞進 `WKNavigationDelegate`；
accept/reject 與 `script` 選規則用的是**兩個不同的 URI**。

**final diff 軸。** 讀回整個 diff 後確認：`.video` 路徑仍然走既有的 wrapper 解包
（Android 在這裡會交出外層網址，iOS 自 IOS-POC-6C 起解一層——**既有的 iOS 改良，不是本輪新增的分歧**，
在此明白記錄）；`hasPrefix("http")` 從 `isCandidate` 內提到前面，對既有路徑結果不變、
對規則路徑多一道底線；`didFinish` 的 Task 每一圈都重新檢查 `continuation` 是否還在，
所以 sniff 結束後不會再對已經拆掉的 web view 求值。
`SnifferRules.make` 丟掉沒有 `hosts` 的規則——Android 會留著但內層迴圈跑不到，行為等價。
`make` 裡原本寫成雙重否定的 filter 在提交前就改掉了。

## 本輪刻意不做

**5S-1 那一輪：** m3u8 mid-stream 廣告剝除（無契約）、burned-in 浮水印、影像辨識／OCR、
DOM selector 刪除、啟發式廣告辨識、片頭片尾（5S-2）、config `rules` 接進 sniffer（5S-3）。

**5S-2 那一輪：** config `rules` 接進 sniffer（5S-3）、任何重構或內更（IOS-POC-12／13）、MPV、
Python 相依、更多 CSP、CarPlay、發布新的 IPA。使用者明確指示這些都不要開始。

**5S-3 這一輪：** IOS-POC-12／13、MPV、更多 CSP、Python 相依、CarPlay、persistent media cache、
HLS segment cache、playlist rewrite、runtime hot update、任何新的 IPA release，
以及**重新調整 IOS-POC-15 的 buffer/network policy**。使用者明確指示這些都不要開始。
**IOS-POC-15 維持 `device verification pending`**——使用者已決定真機效能驗收延後自行進行，
本輪不得把它寫成 closed，也不以它為前提。
