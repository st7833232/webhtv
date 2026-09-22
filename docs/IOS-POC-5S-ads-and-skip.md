# IOS-POC-5S — 廣告、片頭、片尾

- 狀態：**5S-1（ads）已完成**。5S-2（片頭片尾）與 5S-3（config `rules`）**尚未開始**，使用者明確指示本輪不做。
- 基線 HEAD `fc106079`
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

我們的 `WatchHistoryRecord` 已經是毫秒、已有 `position`／`duration`／`isNearEnding`／`resumePosition`，
**只缺這兩個欄位**。這是 5S-2 的工作，本輪不做。

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

## 驗證

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

## 尚未驗證

**沒有人在 App 裡看著它擋掉真實廣告。** 上面全部是測試證據——但那個 WebKit 測試走的是真實
`WKContentRuleList`、真實 `WKWebView`、真實 socket，不是 mock。真機上的行為仍未有人目視確認。

## 回滾

單一 commit，`git revert` 即可。關閉開關：`ads` 解析為空（或把 `adoptAdBlocking` 改成永遠設 nil），
規則就完全不存在。

## 本輪刻意不做

m3u8 mid-stream 廣告剝除（無契約）、burned-in 浮水印、影像辨識／OCR、DOM selector 刪除、
啟發式廣告辨識、片頭片尾（5S-2）、config `rules` 接進 sniffer（5S-3）。
