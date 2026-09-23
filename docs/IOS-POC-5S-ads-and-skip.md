# IOS-POC-5S — 廣告、片頭、片尾

- 狀態：**5S-1（ads）與 5S-2（片頭片尾）已完成**。5S-3（config `rules`）**尚未開始**，
  使用者明確指示 5S-2 這一輪不要碰它。
- 5S-1 基線 HEAD `fc106079`；**5S-2 基線 HEAD `eba5346c`（2026-09-22）**
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

## 本輪刻意不做

**5S-1 那一輪：** m3u8 mid-stream 廣告剝除（無契約）、burned-in 浮水印、影像辨識／OCR、
DOM selector 刪除、啟發式廣告辨識、片頭片尾（5S-2）、config `rules` 接進 sniffer（5S-3）。

**5S-2 這一輪：** config `rules` 接進 sniffer（5S-3）、任何重構或內更（IOS-POC-12／13）、MPV、
Python 相依、更多 CSP、CarPlay、發布新的 IPA。使用者明確指示這些都不要開始。
