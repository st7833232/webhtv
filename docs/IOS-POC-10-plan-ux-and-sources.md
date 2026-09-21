# IOS-POC-10 — 計畫：五項 UI／資料修正

- 狀態：**計畫已確認，尚未實作**
- 日期 2026-09-21，基線 HEAD `d606cdf3`
- 來源：使用者 2026-09-21 直接提出五項
- 兩個有歧義的項目已由使用者當面決定，記錄在下方

MPV（IOS-POC-9x）本輪暫停，真機結果記在 `docs/IOS-POC-9B-mpv-playback-core.md` 末段。

## 五項，依相依順序排列

| # | 項目 | 規模 | 相依 |
|---|---|---|---|
| 10A | 播放器的 X 改成跟著控制列一起淡入淡出 | 小 | — |
| 10B | 篩選列的列名顯示繁體中文 | 小 | — |
| 10C | 重開 App 回到上次的站台 | 小（先查為何失效） | — |
| 10D | 設定檔來源可存多筆，有名稱，可切換 | **大** | — |
| 10E | 觀看記錄與設定檔來源綁定 | 中 | **10D** |

### 10A — 播放器關閉鈕

**現況**：`PlayerView` 用 `.overlay(alignment: .topLeading)` 掛一顆常駐的 `xmark`，
IOS-POC-8B 把它下移到 AVKit 那排之下。它永遠在畫面上。

**做法**：SwiftUI 的 `VideoPlayer` 沒有暴露 AVKit 控制列的顯示狀態，也**不可用私有 API 去讀**。
用 `.simultaneousGesture(TapGesture())` 觀察點擊而**不攔截**——AVKit 自己的控制列照常收到那一下——
再用一個計時器在數秒後淡出。**不加透明遮罩**，那會吃掉 AVKit 的觸控。

`ponytail:` 自行計時而不是跟 AVKit 同步，時間點可能與系統控制列差一點。
沒有公開 API 能同步，等有了再換。

#### 第一版做錯了，使用者回報「隱藏 X 做反了」

第一版用「點擊切換＋4 秒計時器」去**模仿** AVKit，因為 SwiftUI 的 `VideoPlayer` 不公開控制列狀態。
實際使用時兩者相位相反：叫出 AVKit 的控制列，X 反而不見。

**錯的不是時間長度，是「用猜的」這個做法。**

#### 第二版（採用）：跟著 AVKit 自己的訊號

`AVPlayerViewControllerDelegate` 有
`playerViewController(_:willTransitionToVisibilityOfPlaybackControls:with:)`——**公開 API**，
明確告訴我們控制列何時進出。改用 `AVPlayerViewController` 的 `UIViewControllerRepresentable`
（`VideoPlayer` 包的是同一個 controller，但不給 delegate），接上這個 delegate。

**計時器、切換邏輯、`simultaneousGesture` 全部刪掉**——按鈕不可能再相位相反，因為它不再自己記相位。
淡入淡出掛在 AVKit 給的 `UIViewControllerTransitionCoordinator` 上，曲線與時長與控制列完全一致，
不是近似。隱藏時仍 `allowsHitTesting(false)`。

**驗證狀態要說清楚**：`swift test` 與模擬器 build 都過，但**還沒有真的看著它淡出**——
那需要一支正在播放的影片，而當下試的來源回 TLS 憑證錯誤。與 10B 併成一次模擬器目視驗證。

### 10B — 篩選列列名

**現況**：`filterRow` 顯示 `CMSFilter.name`，那是來源自己給的。
`AppGet.js`／`AppQi.js` **已經**映射成中文（類型／地區／語言／年代／排序），
所以使用者看到的英文來自**其他來源**——CMS 型來源的 `name` 直接來自 provider。

**做法**：在顯示層加一張小對照表，只在 `name` 是已知英文鍵時才替換，否則原樣顯示 provider 的字。
一處修改涵蓋所有來源，勝過逐一改 spider（且改 spider 蓋不到 CMS 來源）。

#### 結果（2026-09-21）：**已實作，尚未目視驗證**

`CMSFilter.displayName` 在 core，對照表是**封閉**的：只認得 CatVod／MacCMS 那套詞彙
（`class`／`area`／`lang`／`year`／`sort`…）與對應的簡體寫法，其餘一律原樣輸出 provider 自己的字。
**不猜**——猜錯會把一個標好的欄位改壞。`name` 為空時退回 `key` 的對照，總比空白標籤好。
4 條單元測試涵蓋：英文鍵轉中文、provider 自有字不動、簡轉繁、空名稱退回。

### 10A／10B 的目視驗證：本輪做不到，原因記下來

兩項都只有 `swift test`（159 條）與模擬器 build 通過，**沒有真的看著畫面**。
連續試了三個來源，全部是 provider 端失敗，沒有一個能把內容或影片放出來：

| 來源 | 失敗 |
|---|---|
| 天涯｜高清◎順播 | TLS 憑證無效（`tyyszyapi.com`） |
| 菠菜｜高清 | 同上（錯誤畫面未更新，仍顯示前一個來源的訊息——**這本身是個小缺陷，已記下未修**） |
| 銅牌｜高清 | GitLab 抓 `./py/皮皮虾.py` 逾時（稍早 survey 連抓 42 支，本文件早就警告過會這樣） |

依本專案一貫紀律：**provider 狀態不是本專案的缺陷**，但也不能拿它當「已驗證」。
這兩項的目視確認交給使用者手機上的那一輪。

### 10C — 重開回到上次站台

**現況**：程式碼**看起來已經做了**——`selectedSiteKey` 在 `onChange` 寫入，`restore()` 讀回。
**所以這是一個缺陷，不是缺功能**，要先找出為何失效，不能直接重寫。
候選：啟動時的遠端重新整理跑完 `adopt(...)` 之後是否覆蓋了選擇；
`Site.ID` 的型別與 `UserDefaults` 的存取是否對得上；`HomeView` 是否自己另有狀態。
**先重現再修。**

#### 結果（2026-09-21）：**已修，根因是 `UserDefaults` 在 NUL 處截斷**

先重現，沒有猜。直接讀模擬器的 `com.webhtv.ios.poc.plist`，`selectedSiteKey` 存的是
`php_无水印资源`——**長度 9，沒有 `ext`**。而 `Site.id` 是 `key + "\u{0}" + rawExtJSON`，
**CFPreferences 把字串在 NUL 處砍斷了**。寫入看起來正常、讀取看起來正常，只有磁碟上的位元組說了實話。
回讀對不上任何站台，於是每次都落到 `sites.first`。

修法：新增 `SiteSelection`（在 core，因為 app target 沒有測試宿主），存的是 base64，
round trip 精確。**同時接受舊的截斷值**——以 `key` 比對——讓升級後第一次啟動就能救回使用者真正的
選擇，而不是默默把他丟回清單頂端。

驗證：4 條新單元測試；模擬器實測選「天涯｜高清◎順播」→ plist 存成 `dm9kX+Wkqea2rwA=`
（解碼為 `vod_天涯<NUL>`，NUL 完整保留）→ 冷啟動後來源列仍是「天涯｜高清◎順播」。

### 10D — 多筆設定檔來源（使用者已決定：可存多筆、能切換）

**現況**：只存一個 `configSourceURL` 字串，換回舊的要重打網址。

**做法**：新增一個可編碼的清單（名稱＋網址＋加入時間），存成一個 JSON 檔，
與 `WatchHistoryStore` 同樣的原子寫入做法。設定頁列出名稱，可新增／改名／刪除／切換。
**不改既有的設定檔載入與快取邏輯**——切換只是換一個來源再走現成的載入路徑。

未決細節（實作時採用最保守的一種）：切換來源時既有快取如何處置。
預設：**每個來源各自一份快取檔**，這樣切回去不必重抓，也不會互相覆蓋。

#### 結果（2026-09-21）：**已實作**

- `SavedSource` / `SavedSourceList` 在 core，**以網址為識別**，7 條單元測試。
- 清單存 `saved-sources.json`，原子寫入，與 `WatchHistoryStore` 同做法。
- **每個來源各自快取**（`configURL(for:)`）。這不是講究，是正確性：共用一份的話切到 B 會蓋掉 A，
  下次 A 連不上就會把 B 的站台掛在 A 的名字下。
- **兩段升級處理**，缺一個都會讓舊安裝看起來像掉了設定：
  1. `migrateLegacyCache` 把舊的單一 `wang-movie.json` 複製到該來源的新檔名；
  2. `restore()` 把既有的 `configSourceURL` 自動收編成一筆已存來源，用 host 當預設名稱。
- 設定頁新增「已存來源」：顯示**名稱**、打勾標示使用中、左滑「改名」／「刪除」，刪除時一併清掉快取檔。

模擬器實測：升級後「已存來源」出現 `gitlab.com` 並打勾（收編成立）；左滑出現改名／刪除；
改名對話框開啟且帶入原名。**未逐一實測的**：新增第二個來源後的切換與快取隔離
（需要第二個可用的設定檔網址，手邊沒有）。

### 10E — 觀看記錄綁定來源（使用者已決定：只顯示目前來源）

**現況**：`WatchHistory` 以 `Site.id`（`key + ext`）為主鍵，**沒有設定檔來源的概念**。
同一份設定檔內的站台不會互撞，但兩份設定檔的記錄會混在一起。

**做法**：記錄多帶一個來源識別，記錄頁只列目前來源的。
**相容性是硬要求**：既有記錄沒有那個欄位，不能因此消失或崩潰——
缺欄位的舊記錄歸給目前來源，並在文件中寫明這個決定。

## 流程

每一項各自一個 task guard session 與一個 atomic commit；功能性修改前後各跑一次 Ponytail；
每一項完成後跑 `swift test` 與模擬器 build。**10D／10E 會動到持久化資料，
向下相容要在測試裡有斷言，不能只靠肉眼。**
