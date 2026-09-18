# IOS-POC-5R — 播放記錄、續播與 `app.history`

- 狀態：**R1–R6 已實作並驗證**。**R7（片頭／片尾跳過）依使用者 2026-09-18 指示 deferred**，與整個 IOS-POC-5S 一起。
- 分支 `ios-poc`，基線 HEAD `0ab06a3c`（IOS-POC-5Q 之後）
- 計畫：`docs/IOS-POC-5Q-5R-plan-playback-quality-and-history.md`
- 日期：2026-09-18

## 這個階段解決什麼

App 從來不記任何東西。看到哪裡、上次看哪一集、用哪條線路與畫質，關掉就沒了；WebHome 的
`app.history` 是一個寫明原因的 stub，固定回傳 `[]`，所以任何依賴它的頁面在 iOS 上都只看得到空白。

## 做了什麼

### R1 — `WatchHistory` 與 store（`ios/Sources/WebHTVCore/WatchHistory.swift`）

欄位名稱照 `app/src/main/java/com/fongmi/android/tv/bean/History.java`，因為 `app.history` 會把它
直接交給 WebHome 頁面，而照 Android 寫的頁面是直接索引那些欄位的。兩個欄位刻意不一樣：

| 欄位 | 說明 |
|---|---|
| `key` | **用 `Site.id`（key + ext），不是 `siteKey`** |
| `quality` | **Android 沒有的欄位**；Android 把每個畫質都表達成線路，`vodFlag` 就夠了。IOS-POC-5Q 之後一條線路可以帶多個畫質，D3 要求兩個都記。它**不進 `app.history` 的 payload** |

`key` 這件事是 K2／D6：`wang-movie.json` 有 4 組重複 site key（IOS-POC-5L 的 `爱影`），只用 `siteKey`
會把兩個不同 provider 的記錄合成一筆。`Site.id` 才是真正識別一個來源的東西——`SpiderSessionStore`
也是為了同一個理由用它當快取鍵。對外的 `androidKey`（`siteKey@@@vodId`）另外算，因為 Android 的
`getSiteKey()`／`getVodId()` 就是對那個字串做 split。**內部 key 永遠不 split**：`Site.id` 內嵌整個
`ext`，裡面可以是任何東西，所以 `siteKey` 與 `vodId` 各自存成獨立欄位。

Android 的公式照抄，不自己定：

- `canSave` = `position > 0`（`History.canSave()`）
- `isNearEnding` = 剩餘時間 ≤ `min(30s, max(5s, duration/100))`（`History.isNearEnding()`，D12）
- `resumePosition` = `position > 10s` 且不在 near-end 區間內才回傳（D4）

Store 是 `WatchHistoryStore`，一個 actor，單一 JSON 檔放在 Application Support：

- **為什麼是檔案不是資料庫**：幾百筆資料不值得 SwiftData 與一套要遷移的 schema，而且 config 與
  compatibility pack 已經建立了這個模式。`Data.write(options: .atomic)` 就是全部的原子性——標準庫
  本來就是寫暫存檔再 rename，寫到一半崩潰留下的是舊清單。
- **為什麼是 actor**：每次寫都重寫整個檔案，而播放取樣器從 main actor 寫、bridge 從 web view 回答的
  地方讀。用 actor 串起來才讓「整份重寫」是安全的。
- 壞檔 = 沒有記錄，不是啟動失敗；下一次 save 整份覆蓋。
- prune：60 天（`Constant.HISTORY_TIME`）+ 上限 500 筆（D2；Android 沒有筆數上限，因為 Room 不會
  讓 App 去 parse 一個越長越大的檔案，這裡會）。

### R2 — 播放身分與位置取樣

前置照計畫寫的做了：`Playback` 與 `PlaybackSession.open` 本來只帶 `url/headers/title/artwork`，
完全沒有站與片的身分。現在 `VodView.play` 組出記錄樣板（key、siteKey、siteName、vodId、vodName、
vodPic、vodFlag=線路名、vodRemarks=單集名、episodeUrl），`PlayerPickerView` 補上實際選定的畫質，
再交給 `PlaybackSession.open(..., history:)`。

寫入時機：每 5 秒一次（**只在真的在播的時候**——檔案是整份重寫，暫停中的播放器不該每 5 秒重寫一次）、
關閉播放畫面時、進背景時、播完時、以及 `control("stop")`。

`ponytail:` 註記寫明了天花板：幾百筆資料的整檔寫入在 5 秒間隔下沒問題；真的長到有影響再做合併寫入
或只在暫停／進背景時 flush。

**不記錄的兩條路徑**，各有原因：`player.playUrl` 只給一個裸 URL，沒有站與片可以當鍵；inline vod 是
頁面自己的播放清單，掛在 `webhome_inline` 這個假站底下。外部播放器也永遠不會被記錄（K6：URL scheme
沒有回傳管道）。

### R3 — 續播

`open` 先把記錄讀出來解出 `resumePosition`，**然後才** `start`。讀的是 actor 的記憶體快取，而先播
再 seek 等於對一條已經開始的串流做 seek。`load` 在 `replaceCurrentItem` 之後、`play()` 之前發出
seek——這時候發出的 seek 會在 item ready 之後被執行，所以不需要一個 readiness observer。

### R4 — 記錄分頁與詳情頁標記

新的「記錄」分頁（首頁 / 記錄 / 設定），列出 60 天內看過的片，每列顯示海報、片名、
`站名 · 線路 · 集數`、以及「看到 0:44 / 46:36」或「已看完」。

點一列是回到**該片的詳情頁**，不是直接續播進播放器：詳情頁才是標著上次那一集的地方，而且想換一集
本來也得回到那裡。站在設定檔裡找不到了的記錄會變灰顯示而不是消失——因為某個站改名就刪掉使用者的
記錄，比留一列死資料更糟。

詳情頁的單集格上，上次看的那一集會加粗並上色。

### R5 — `app.history`

`HomeWebBridge.history()` 在 Android 是 `gson.toJson(History.get())`，就是一個 `History` 陣列。
iOS 現在回傳同樣的 17 個欄位。填不了的照這個 bridge 既有的規則給 0／空字串／false 而不是省略：

| 欄位 | 值 | 理由 |
|---|---|---|
| `wallPic`、`revSort`、`revPlay` | `""` / `false` | iOS 沒有對應概念 |
| `opening`、`ending` | `0` | R7 deferred。Android 的未設定值是 `C.TIME_UNSET`（一個很大的負數），對頁面任何 `> 0` 的判斷來說 0 讀起來一樣 |
| `speed`、`scale` | `1`、`-1` | Android 自己的預設值 |
| `cid` | `0` | iOS 的設定檔沒有 id，跟 `config.info` 一致 |

`key` 用 `androidKey`（`siteKey@@@vodId`），因為頁面會對它做 split。`quality` **不在** payload 裡:
它沒有 Android 對應物，而這個 payload 是複製而不是擴充。

### R6 — 記住線路與畫質

畫質：`PlayerPickerView` 用 IOS-POC-5Q 那個純函式重算預設索引，把記錄裡的 `quality` 當
`preferred:` 注入——這正是當初把偏好做成參數而不是讓 core 去查表的原因。優先順序是 D8：
記住的選擇 > 標籤排名最高 > 來源自己的 `position`。

線路：記錄裡的 `vodFlag` + `episodeUrl` 在詳情頁標出上次那一集（R4），也就是上次那條線路。

## 與計畫的偏離

| 項目 | 計畫 | 實作 | 原因 |
|---|---|---|---|
| R7 片頭／片尾 | 在 5R 範圍內 | **未實作** | 使用者 2026-09-18 指示與 IOS-POC-5S 一起 deferred |
| 記錄的刪除 | 計畫只寫「列出看過的片」 | 多了滑動刪除與「清除」 | **這是超出 R4 字面的東西**，明白標示在這裡。理由：store 有 500 筆上限與 60 天保留，若沒有任何移除手段，使用者對自己的記錄唯一的控制方式是等 60 天。共 9 行。不要就說一聲，砍掉即可 |
| `siteName` 存進記錄 | 計畫沒提 | 存 | Android 的 `getSiteName()` 是回設定檔查的；store 沒有站清單，而且「站已經不在設定檔裡」那一列正需要它才顯示得出東西 |

## 驗證

### 單元測試

```bash
WANG_MOVIE_JSON=<config> swift test --package-path ios
```

**124 測試、124 全過**（5R 之前是 110／109）。

值得記一筆：`reportsLiveType4SitesFromProvidedConfig` **這一輪通過了**。它是既有的即時網路案例
（88看球），在 2026-09-18 稍早的兩輪都失敗。這正好佐證它量的是 provider 狀態而不是 regression，
下次再失敗仍然不要去修。

5R 新增 14 條（`WatchHistoryTests.swift`）：round-trip、upsert 不重複、**重複 site key 各自保有記錄**、
無 position 不存、60 天 prune、500 筆上限（新的優先）、壞檔不致命且下次 save 復原、remove／clear
落到磁碟、40 個並行 save 全部落地、resume 門檻（10 秒／near-end）、near-end 公式三段區間
（20 分鐘→12s、3 小時→夾到 30s、2 分鐘→夾到 5s）、記住的畫質決定選單起點、以及
`app.history` 的 17 個欄位。

改寫了 `WebHomeBridgeTests` 那條「回傳 `[]`」的斷言——**這是行為改變，不是放寬斷言**：原本那條
留著（沒看過任何東西時仍然是 `[]`），另外新增一條 `appHistoryReportsWhatWasActuallyWatched`
證明它現在回的是真資料。

### 建置

```bash
xcodebuild -project ios/WebHTVApp/WebHTVApp.xcodeproj -scheme WebHTVApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```

→ BUILD SUCCEEDED。

### 模擬器實測（iPhone 17 Pro，`7B4E9557-…`，2026-09-18）

端到端走完，每一步都有截圖或磁碟證據：

1. `愛瓜 PHP` → `莲花楼` → 普快线路 01 → 播放器選擇 sheet。**沒有畫質區塊**——單一網址來源的正確
   行為，也是 Q3 的反向驗證。
2. 播 16 秒後，App 容器裡真的出現了記錄：
   ```json
   {"key":"爱瓜TV @@@2@194093","siteKey":"爱瓜TV","siteName":"🏆｜愛瓜｜PHP",
    "vodName":"莲花楼","vodFlag":"普快线路","vodRemarks":"01","position":28261,"duration":2796399}
   ```
   注意 `key` 裡的 ` ` —— 那是 `Site.id` 的 key/ext 分隔符，證明記錄鍵確實是 `Site.id` 而不是
   `siteKey`。
3. 關閉播放畫面 → `position` 前進到 44292，`onDisappear` 的寫入生效。
4. 詳情頁：**01 變成加粗上色**，其他集沒有。
5. 記錄分頁：一列「莲花楼 / 愛瓜｜PHP · 普快线路 · 01 / 看到 0:44 / 46:36」，海報正常。
6. 從記錄列點回去 → 01 → 內建播放器 → **7 秒後 `position` 是 53487**。從頭播會是 ~7000，
   所以確實是從 44292 續上去的。**R3 續播在真實串流上驗證通過。**

順帶一提：詳情頁的單集鍵這次 synthetic tap **有反應**。既有踩坑 ② 記的是「沒反應」，在這一輪的
type-1 來源上沒有重現；先前 5Q 那次在 bili 格線上打不開，比較可能是座標換算失準而不是同一個問題。
**不把這當成 ② 已解決**，只記錄這次的觀察。

### 沒驗到的

- **實機一次都沒跑。** 專案沒有任何 `CODE_SIGN` / `DEVELOPMENT_TEAM`。
- **`app.history` 沒有從真的 WebHome 頁面驅動過**，只有 bridge 單元測試。
- **R6 的畫質記憶沒有在真實多畫質來源上實測**：62 站沒有任何一個回傳 `url` 陣列，B 站走的是線路。
  單元測試涵蓋了「記住的畫質決定選單起點」。
- **進背景寫入沒有實測**，只有程式路徑（`didEnterBackgroundNotification`）。
- **500 筆上限與 60 天 prune 只有單元測試**，沒有在裝置上累積到那個量。

## Ponytail

**實作前（設計軸）。** ① 需要存在——使用者要求，且 `app.history` 回 `[]` 是實際缺口。
② 已有的東西先用——`SpiderPackStore` 的 Application Support + actor + 原子替換模式照抄形狀；
IOS-POC-5Q 的 `PlaybackQuality.defaultIndex` 已經把偏好做成參數，R6 直接注入，沒有新函式。
③ 標準庫——`Codable` + `Data.write(options: .atomic)`，原子寫入不自己刻。④ 不用 SwiftData／CoreData
（D5）。⑤ 沒有新增相依。⑦ 最小可行：一個新檔（model + store）、bridge 一個 case + 一個 payload
builder、App target 串身分與取樣。

刻意不做：跨裝置同步（Android 走它自己的本機 HTTP server，iOS 無等價物）、外部播放器回寫（不可能）、
`opening`/`ending`（使用者 defer）、獨立的 progress 寫入路徑（一個 `save` 就夠）。

**final diff 軸。** 檢查過新增的每個 public 成員都有呼叫端（`siteName`／`remove`／`clear`／
`canSave`／`androidKey`／`resumePosition`／`isNearEnding` 全部有）。`persist(onlyWhilePlaying:)`
一個 Bool 參數兩個呼叫端，沒有拆成兩個函式。記錄的刪除是唯一超出計畫字面的東西，已在上面標示。
一個 `ponytail:` 註記寫明整檔寫入的天花板與升級路徑。

## 下一步

使用者指定的順序：**durable documentation reconciliation**，然後才是 drpy JavaScript loader。
5S（`ads`、`rules.script`、片頭片尾、m3u8 去廣告）保留在計畫文件中並標示 deferred，不刪除。
