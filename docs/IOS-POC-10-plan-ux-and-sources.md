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

#### 結果（2026-09-21）：**已實作**

`WatchHistory.sourceID` 存 `ConfigSource.identity`（遠端是網址，匯入檔統一一個桶——
匯入檔沒有位址，硬要分也分不出來）。記錄頁改用 `records(for:)`。

**這個欄位是 `String?` 而不是 `String`，那個問號是重點。** `WatchHistory` 用合成的 `Codable`，
而合成的 decoder **不會**套用屬性預設值：加一個非 Optional 欄位會讓每一筆既有記錄擲出
`keyNotFound`，而 `WatchHistoryStore` 把讀不動的檔案當成「沒有記錄」。
**一個問號就是「新增欄位」與「刪掉使用者觀看記錄」的差別。** 已用一條測試釘住：
餵入真正的舊格式 JSON（完全沒有那個欄位），必須解得開。

`nil` 代表「這筆寫在分來源之前」，**在任何來源下都會顯示**——把它藏起來對使用者而言就是掉資料。
它下次被觀看時就會被蓋上目前來源，自然消化。

`sourceID` **刻意不進主鍵**：`Site.id` 已經識別了 provider，把設定檔也折進鍵裡，
會讓同一個來源透過兩份設定檔進入時把同一部片的進度拆成兩筆。

**刻意未改**：WebHome bridge 的 `app.history` 仍回傳全部記錄。那個介面是為了重現 Android 的
形狀，而 Android 沒有「多份設定檔」的概念；payload 逐欄建構，也沒有帶到新欄位。
記在這裡當作已知邊界。

## 流程

每一項各自一個 task guard session 與一個 atomic commit；功能性修改前後各跑一次 Ponytail；
每一項完成後跑 `swift test` 與模擬器 build。**10D／10E 會動到持久化資料，
向下相容要在測試裡有斷言，不能只靠肉眼。**


## 10G — 線路排在上方，只顯示所選線路的集數（使用者 2026-09-21 追加）

**現況**：`ForEach(detail.flags)` 把每一條線路連同它完整的集數格子**一路往下堆**。
使用者的截圖是 `VIP线路` 8 集、接著 `极速蓝光` 8 集……四條線路八十集就要捲過三百顆按鈕。

**做法**：線路改成頂端一排可橫捲的 chips，選中的高亮；下面只渲染那一條線路的集數。

**明確不動的**：`episodeBlocks` / `blockLabel` / `defaultChunk` 與 `episodeChunk`（以線路名為鍵）
一行都沒改——使用者交代「之前修改的 100 子群組不要更動」。每條線路仍各自記住自己的區段。

預設選哪一條：使用者手選的 → 上次看的那條（`watched.vodFlag`）→ 第一條。
**每次都對照實際存在的線路解析**，所以重新載入後少了某條線路時，畫面不會指向一條不存在的線路。

只有一條線路時**不顯示 chips 列**，維持原本的標題樣式——與下方「只有一個區段就不顯示區段列」
同一條規則。

驗證：`swift test` 168 條全過、模擬器 build 成功。**目視未驗**（同樣卡在來源狀態）。


## 10H — 拿掉 X，加上子母畫面（使用者 2026-09-22 追加）

使用者圈出播放畫面左上角那顆 X 並要求拿掉，同時要支援子母畫面（PiP）。

### 拿掉 X，連同它的整套機制

`chromeVisible`、控制列可見度的 delegate 方法、`opacity`／`allowsHitTesting` 全部刪除——
它們存在的唯一理由就是讓那顆按鈕淡入淡出。**刪掉的比加上的多。**

### 但那樣就沒有出口了，所以補了下滑手勢

`fullScreenCover` 沒有導覽列，AVKit 在內嵌模式也不提供 Done 鈕，所以按鈕一拿掉就真的關不掉。
補上下滑關閉——那是 iOS 各處關閉全螢幕影片的既有手勢。

**用 `simultaneousGesture` 而不是 `gesture`**：AVKit 自己的辨識器在下層的 UIKit view，
普通 SwiftUI 手勢會輸給它，那樣就會變成完全沒有出口。門檻設為「下移 > 80、水平 < 120」，
所以拖曳進度條與音量／亮度都不會被誤判成離開。

`ponytail:` 若之後覺得手勢不夠明顯，替代方案是改用 UIKit 自己 modal present
`AVPlayerViewController`，那樣 AVKit 會給它自己的 Done 鈕——但那要動整條呈現路徑，這一刀不做。

### PiP 要三件事同時成立，缺一不動

| 需要 | 做了什麼 |
|---|---|
| AVKit 開啟 PiP | `allowsPictureInPicturePlayback = true`（控制列出現 PiP 鈕）與 `canStartPictureInPictureAutomaticallyFromInline = true`（離開 App 時自動進 PiP 而不是凍住） |
| 音訊工作階段 | App 啟動時 `AVAudioSession` 設為 `.playback` / `.moviePlayback` 並啟用。失敗不致命（照樣能播，只是 PiP 不會武裝），所以是回報而不是中止 |
| 背景模式 | `Info.plist` 加 `UIBackgroundModes = [audio]`。**沒有這個 PiP 一離開 App 就會停** |

### 一個容易漏掉的正確性問題

`onDisappear` 原本無條件 `player.pause()`。進 PiP 之後畫面會消失，那行就會把使用者剛叫出來的
小視窗停掉——**PiP 唯一必須活過的就是這個時刻**。改成 PiP 啟用時直接跳過暫停與存檔。

驗證：`swift test` 168 條全過、模擬器 build 成功。**PiP 本身尚未實測**——它需要真機與一支能播的
影片，交給使用者這一輪。


## 10I — 模擬器實測，推翻了 10H 的一個假設

使用者要求直接在模擬器驗。用荐片的《欢迎来龙餐馆》走完整條真實播放路徑。

### 量到的三件事

| 問題 | 結果 |
|---|---|
| 自訂的 X 拿掉了嗎 | **是**。播放畫面上只剩 AVKit 自己那一排（X／AirPlay／靜音） |
| AVKit 的 X 會關嗎 | **會**。點下去回到播放器選單 |
| PiP 鈕呢 | **不在，而那是平台限制**。啟動日誌 `[pip] supported false`——模擬器沒有實作 PiP |

### 因此刪掉下滑手勢

10H 假設「拿掉自訂 X 就沒有出口」，所以補了下滑關閉。**那個假設是錯的**——AVKit 自己就有 X，
而且有效。一個可能與垂直拖曳誤判的第二出口，比沒有第二出口更糟，所以手勢刪除。

**這是驅動一次就推翻的假設，不是猜出來的。** 也是為什麼 10H 當時把它明確標成「未驗證」。

### 新增一行啟動日誌

`[pip] supported <bool>`。沒有它，每次有人看到控制列沒有 PiP 鈕都要重新猜一次是平台還是缺陷。

### 10G 順帶驗證通過

線路 chips 排在頂端、`VIP线路` 高亮，下面只顯示該線路的集數。
（那個標題是電影，所以「集」是 `TC国语`／`枪版` 這類版本名——第一眼容易誤讀成線路。）

### 仍未驗證

**PiP 本身**。它在模擬器上不存在，只能在真機測。裝置目前 `devicectl` 回報 `unavailable`。


## 10J — 播放器手勢（使用者 2026-09-22 追加）

水平拖曳＝快轉／倒轉；螢幕左右各半，右半上下＝音量，左半上下＝亮度。

### 一個取捨要先講：音量調的是播放器，不是系統

**系統音量沒有公開的寫入 API。** `AVAudioSession.outputVolume` 唯讀，業界做法是塞一個隱藏的
`MPVolumeView` 再去翻它內部的 `UISlider` ——那依賴**沒有文件保證的視圖階層**。

這個專案已經背了一個未公開 key（`AVURLAssetHTTPHeaderFieldsKey`，見
`docs/analysis/ios-app-store-readiness-research.md` 列為送審風險），**不值得再加一個**。
所以調的是 `AVPlayer.volume`，完全公開。差別：不會動到系統音量、不會跳出系統的音量 HUD，
只影響這支影片。

亮度用 `UIScreen.main.brightness`，那個本來就是公開可寫的。

### 判斷方式

軸向與左右**在拖曳開始的前幾點就決定，之後不再改變**。中途手指飄過中線不會從亮度變成音量——
會變的手勢用起來像在跟人吵架。左右是看**起點**落在哪一半，不是當下位置。

### 快轉不是即時套用的

拖曳過程只更新 HUD，`seek` 在手指離開時才發一次。每一幀都 seek 會讓網路串流整段抖動。
靈敏度：整個螢幕寬 = 120 秒。

### 亮度有下限 5%

往下滑到全黑，使用者就看不見那個能救回來的手勢了。Control Center 可以調到那麼暗是因為那是
刻意且可逆的操作；一個滑動手勢兩者都不是。

### 模擬器實測

| 檢查 | 結果 |
|---|---|
| 水平拖曳快轉 | **成立**。暫停狀態下 `0:02:38` → `0:03:46`，**+68 秒**，230pt 拖曳的預測值是 68.7 秒；畫面也換成完全不同的場景 |
| 垂直拖曳**不會**快轉 | **成立**。右半上滑後時間仍停在 `0:03:46` ——軸向判斷正確 |
| 音量／亮度的實際數值 | **未觀察到**。UI 上沒有常駐指示，HUD 0.6 秒就淡出，截圖抓不到；模擬器也不會反映亮度變化 |

**沒抓到 HUD 這件事本身不是缺陷，是我的驗證手段有限**——`touch_path` 送出的是完整手勢，
截圖只能在手指離開之後。真機由使用者肉眼確認。


## 10K — 讓錯誤說人話（使用者 2026-09-22 回報）

使用者在 麻豆 (js) 上看到：

> 載入失敗
> The operation couldn't be completed. (WebHTVCore.DrpyError error 0.)

### 原因

`DrpyError` 有 `CustomStringConvertible`，訊息寫得很好——**但畫面看的不是它**。
`description` 是 `print` 用的；`localizedDescription` 才是螢幕用的，而 Swift **不會**把前者橋到後者。
沒有 `LocalizedError` 就退回「模組名＋型別名＋case 序號」。

`error 0` 就是第一個 case，`noRemoteConfiguration`。

### 這是漏網，不是慣例

盤點 core 的七個錯誤型別：`ConfigLoaderError`、`WebHomeBridgeError`、`SpiderError`、
`PythonSpiderSource.Failure`、`SpiderPackError` **五個都已經實作 `LocalizedError`**；
只有 `DrpyError` 與 `CMSClientError` 沒有。兩個都補上，中文，因為那是給使用者看的。

**英文的 `description` 原封不動**——它進 log，而 log 用英文是這個 codebase 的慣例。
`SpiderError` 那個 `Spider script error:` 英文前綴仍然沒動：IOS-POC-7N 已經把它記成另一件事。

### 測試釘住的是什麼

不是「訊息內容等於某個字串」，而是**「不再是 Swift 的通用退路」**——
斷言 `localizedDescription` 不含 `couldn't be completed`。這個缺陷很容易重新引入而且在 code review
裡看不出來：一個有完美 `description` 的 enum，畫面上照樣顯示 `error 0`。

### 尚未查明

**`noRemoteConfiguration` 為什麼會在遠端設定下發生。** 列出 drpy 站的條件就是
`source.baseURL != nil`，所以它被列出來時來源是遠端的；到了內容呼叫卻說沒有。
**下次再發生時畫面會直接說出原因**，這正是修這個訊息的價值。


## 10L — 下拉重整「有跑，但被快取回答了」（使用者 2026-09-22 提問）

> 下拉重整真的有執行嗎？反應速度很快，但又沒什麼改變。

### 先確認它有執行

`.refreshable` 裡是 `await load(...)`，與分類 chip 走同一條路徑，**確實會執行也確實被等待**。
所以問題不在有沒有跑。

### 再量出它為什麼看起來沒動

**直接讀模擬器上 App 的 `Library/Caches/.../Cache.db`**，不是推論：

```
cached responses: 157
listing-ish (ac= / api / vod): 67
…/api/crumb/list?fcate_pid=3&category_id=&area=2&year=162&type=&sort=&page=1
```

**分類清單就在快取裡。** `URLSessionConfiguration.default` 自帶 `URLCache`，而 core 從來沒有設過
cache policy，所以重整被磁碟回答了——快、而且內容一模一樣。

### 修法：這條 session 不快取

`URLSession.webHTV` 加 `requestCachePolicy = .reloadIgnoringLocalCacheData` 與 `urlCache = nil`。

走這條 session 的**全部都是即時內容或程式碼**：CMS 清單、spider 自己的 HTTP、設定檔 JSON、
drpy 引擎、相容性套件。快取它們省下一點頻寬，換掉的是正確性——
**而且對 hash-pinned 的下載更糟**：一份過期的快取副本會對不上釘住的雜湊，直接把該站拒絕掉。
AVPlayer 不走這條 session，影片播放不受影響。

### 驗證

| 步驟 | 結果 |
|---|---|
| 修改前，瀏覽後看快取 | `crumb/list` 有 **10 筆** |
| 刪掉 `Cache.db`、裝新版、重跑並瀏覽 | **`Cache.db` 根本沒有被重建** |

加一條單元測試釘住 session 設定——這個缺陷從呼叫端完全看不出來，每個呼叫都寫
`URLSession.webHTV.data(from:)`，有沒有被快取回答長得一模一樣。

### 誠實的但書

這解決的是「重整被快取回答」。**它不保證畫面一定會變**——provider 的清單本來就可能好幾個小時
都一樣。差別在於：現在沒變是因為來源真的沒變，不是因為我們沒去問。


## 10M — 舊快取不該變成使用者的問題（使用者 2026-09-22 指出）

> 刪掉 Cache.db 我又沒辦法自己刪除

**完全正確，而我上一則的說明沒把這點講清楚。** 先澄清兩件事：

1. **不需要刪任何東西，修正就已經生效。** `urlCache = nil` 之後那條 session 根本沒有快取物件，
   舊的 `Cache.db` 不會被讀也不會被寫。我在模擬器上刪它，只是為了**證明**新版不再寫入。
2. **但那個檔案會一直躺在那裡。** 讀它的人沒有，能刪它的人也沒有——除非整個 App 重裝。
   在使用者的機器上那是幾 MB 的孤兒（`Cache.db` 約 0.8 MB 加上 2.1 MB 的 WAL）。

### 做法

啟動時 `URLCache.shared.removeAllCachedResponses()`。第一次啟動把孤兒清掉，之後就是 no-op，
因為已經沒有東西會寫進去。只動這個 App 自己的快取，沙箱保證了這一點。

**確認過沒有第二條路徑**：全專案沒有任何地方使用 `URLSession.shared`，
所有下載都走 `URLSession.webHTV`，所以 10L 的修正沒有漏網之處。

WKWebView 自己的快取（`Caches/WebKit/`）**沒有動**——那是 sniffer 正在使用的工作狀態。

### 驗證的限度，說清楚

模擬器上的快取在 10L 已經被我刪光，所以**這一輪沒有重建一個「有內容的快取」來親眼看它被清空**。
確認到的是：build 成功、啟動不 crash、App 正常運行、`swift test` 173 條全過。
`removeAllCachedResponses()` 是有文件的 API，風險在於呼叫本身而不在語意，而那一點已經驗過。


## 10N — 「設定檔裡的參照無法解析：」後面是空的（使用者 2026-09-22 回報）

步步｜4K 顯示這個訊息，而**冒號後面什麼都沒有**。

### 10K 的價值在這裡兌現

如果訊息還是 `DrpyError error 0`，這件事根本無從查起。換成具名訊息之後，
**「空的參照」本身就是線索**。

### 根因：這份設定檔有兩種 drpy 形狀，程式碼只認得一種

直接讀使用者設定檔裡全部 5 個 drpy 站：

| 站 | `api` | `ext` |
|---|---|---|
| 去看动漫／爱动漫／七色番动漫／爱动漫 | `./drpy_libs/drpy2.min.js`（引擎） | `./drpy_js/*.js`（規則） |
| **步步｜4K** | **`./json/4k.js`（規則本身）** | **完全沒有** |

`drpySession` 一律讀 `site.rawExtJSON`。對步步來說那是空字串，於是
`resourceURL(for: "")` 回 nil，丟出 `unresolvable("")`——訊息說「參照無法解析」，
**但真相是我們看錯欄位了**。

### 修法

`Site.drpyRuleReference`：`ext` 有就用 `ext`，沒有就用 `api`。
對一個 `.js` 站來說 `api` 本來就是腳本，引擎是隱含的——與 `csp_*` 類別名同理。

### 但這個站仍然不會動，而那是另一回事

`curl` 確認（2026-09-22）：

| 位址 | 結果 |
|---|---|
| `…/main/json/4k.js` | **HTTP 404** |
| `…/main/drpy_js/去看吧.js` | HTTP 200 |

**檔案不在使用者自己的 repo 裡**，這正是 IOS-POC-6A 當初記下的事，到今天仍然成立。
修好之後訊息會變成「抓取 4k.js 失敗，伺服器回應 HTTP 404。」——
**真話而且可行動**（把檔案放進去，或把這個站從設定檔移除），
而不是一則指向錯誤欄位的空訊息。

**沒有改成不列出它。** IOS-POC-6A 明確決定過「列表看形狀，打開時給具名錯誤」，
今天 404 的腳本明天可能就存在；靜靜地把它藏起來更糟。

### 驗證

3 條單元測試涵蓋兩種形狀與「只有空白的 ext」；全套 176 條通過；模擬器 build 成功。
**沒有親眼看到新的 404 訊息**——模擬器的來源選單不吃合成拖曳，捲不到那個站。
邏輯本身由測試釘住，404 由 `curl` 獨立確認。


## 10O — 第三種 drpy 形狀：`"ext": {}`（使用者 2026-09-22 指定 `wang-sex.json` 的麻豆(js)）

### 10N 只修對了一半

10N 把「`ext` 是空的就改用 `api`」寫成 `ext.isEmpty`。但 `wang-sex.json` 的麻豆是：

```json
{ "key": "js_madou", "api": "./drpy_js/麻豆.min.js", "ext": {} }
```

`ext` 是**空的 JSON 物件**，`rawExtJSON` 因此是 `"{}"`——**不是空字串**。
於是 10N 的檢查放行，把 `"{}"` 當成路徑丟進 `resourceURL`，然後以同樣不知所云的方式失敗。

掃過那份設定檔的全部 5 個 drpy 站：4 個是 `api`=引擎／`ext`=路徑字串，1 個是這種。

### 修法：不問「有沒有」，問「能不能解析」

`Site.isResourceReference`：只有相對路徑（`./`、`../`）或 http(s) 絕對位址才算參照，
其餘一律視為設定檔雜訊，改用 `api`。這面鏡子照的是 `ConfigSource.resourceURL(for:)`
自己接受的形狀——**能不能被那裡解析，就在這裡判斷，不要讓失敗晚一層才用錯的名字出現**。

### 驗證（模擬器，端到端）

| 站 | 修正前 | 修正後 |
|---|---|---|
| 步步｜4K（`api`=規則、無 `ext`） | 「設定檔裡的參照無法解析：」後面空白 | **「抓取 4k.js 失敗，伺服器回應 HTTP 404。」** 真話，而且可行動 |
| 麻豆(js)（`api`=規則、`ext`={}） | `DrpyError` | **不再報錯**，顯示「沒有內容」——引擎載入、規則腳本執行，home 回空清單 |

`./drpy_js/麻豆.min.js` 經 `curl` 確認為 HTTP 200，所以這個站是真的跑起來了；
home 回空是來源行為，與本修正無關。

### 我自己在驗證過程中犯的錯，記下來

先用 `xcrun simctl spawn <udid> defaults write` 去改設定來源，**完全沒有生效**：
那寫進的是模擬器的系統偏好網域，App 沙箱裡的
`<container>/Library/Preferences/com.webhtv.ios.poc.plist` 原封不動。
一度看起來像「App 忽略了設定」，其實是測試手法錯。
正確做法是直接改容器裡那份 plist 並停掉 `cfprefsd`。

### 順帶發現、只報不修

**快取不存在的冷啟動會忘記選過的站。** `restore()` 在找不到該來源的快取檔時提早返回，
`selectedSiteID` 仍是 nil；接著 `adopt` 只保留「記憶體裡的」值，never 回頭看存下來的 token，
於是落到 `loaded.first`。10D 讓每個來源各自快取之後，這個狀況變得比以前常見
（新增來源、或切到還沒抓過的來源）。**與 10C 同一個家族，但不是同一個缺陷**，沒有在這一刀處理。


## 10P — 麻豆(js) 不是 drpy，是另一種 JS spider（使用者：Android TV 上可以用）

### 為什麼 Android 可以而這裡不行

把麻豆丟進既有的 `DRPY_GOLDEN_SITE` 閘門測試（而不是繼續看截圖），拿到第一個線索：

```
[spider] undefined
[spider] p:undefined
home returned no categories → classes == []
```

抓下腳本本體對照，答案就清楚了。`drpy_js/麻豆.min.js` 的結尾是：

```js
…['category']=category, …=detail, …=play, …['search']=search; return …;   // 全部包在 __jsEvalReturn 裡
```

**那是 CatVod／TVBox 的「JS spider」契約，不是 drpy 規則。** 對照組：同一份設定檔裡的
`drpy_js/UAA[密].js`（真 drpy 規則）完全沒有 `__jsEvalReturn`。

兩者的入口不同：drpy 規則對引擎暴露一個 `rule` 物件；JS spider 定義 `__jsEvalReturn()`，
回傳 `{init, home, homeVod, category, detail, play, search}`。

`isDrpySpider` 只看「type 3 且 api 以 .js 結尾」，於是把 JS spider 餵給 drpy2，
drpy2 找不到 `rule`，每個方法都回空——畫面就是「沒有內容」。
**TVBox 有兩套 JavaScript runtime，這個 App 只實作了其中一套。**

### 這一刀只做診斷，不做實作

偵測 `__jsEvalReturn` 並丟出具名錯誤：
「麻豆.min.js 是 CatVod JS spider（__jsEvalReturn），不是 drpy 規則腳本；本 App 目前只實作 drpy。」

**沒有實作那套契約**——那是新能力，依 `AGENTS.md` §7 要先經使用者核可。
靜靜地顯示空清單是所有結果裡最糟的一個，先把它換成一句真話。

### 驗證

| 檢查 | 結果 |
|---|---|
| 麻豆(js) 走 golden | **具名失敗**：`麻豆.min.js is a CatVod JS spider (__jsEvalReturn), not a drpy rule` |
| UAA（同設定檔的真 drpy 站）走 golden | **完整通過**：home 3 類 → category 32 筆 → detail → search 32 筆 → player `parse=0` → 播放位址帶 headers |
| 全套 | 181 條通過 |

沒有誤傷真正的 drpy 站，這是加這個偵測時唯一要擔心的事。

### 如果要做，值多少

目前確認的 JS spider 只有麻豆**一站**（`wang-sex.json` 5 個 `.js` 站裡，4 個是 drpy）。
好消息是 runtime 大半已經在：`JavaScriptSpiderRuntime` 與 `host.js`（`req`／`pdfh`／`pdfa`／`local`）
正是這類腳本需要的 SDK，形狀上更接近既有的 `csp_*` 移植而不是另造一套。
**需要你決定要不要開這個階段。**


## 10S — 來源清單的順序要跟設定檔一樣（使用者 2026-09-22）

### 現況不是「排序錯了」，是被分組串接

`WebHTVConfig.drivableSites` 過去是：

```swift
supportedSites + spiderSites(resolvedBy: resolver)          // 原生 CMS 全部在前
spiderSites = (cspSpiderSites + drpySpiderSites + pythonSpiderSites).filter(...)
```

三個 accessor 各自 `sites.filter(...)` 再**串接**，所以清單被切成四段：
原生 CMS → `csp_*` → drpy → Python。設定檔自己的順序整個被丟掉。

**作者排的順序是資訊。** `wang-sex.json` 把 `🔞麻豆(js)` 放在第 7 筆（index 6），
App 卻把它推到 drpy 那一段去，使用者要捲很久才找得到。

### 修法：一次 filter，不串接

```swift
public func drivableSites(resolvedBy resolver: CSPSourceResolver) -> [Site] {
    sites.filter { isSupported($0) || ($0.isSpiderShape && resolver.canResolve($0)) }
}
```

新增 `Site.isSpiderShape`（`isCSPSpider || isDrpySpider || isPythonSpider`），
存在的理由只有一個：讓「這是不是 spider」能在**單一趟** `sites` 掃描裡回答。
`spiderSites(resolvedBy:)` 同樣改成單趟 filter，順序一併修正。

判定條件一個都沒改，所以**哪些站被列出完全不變**，只有順序變。

### 驗證

| 檢查 | 結果 |
|---|---|
| `listsSitesInTheOrderTheConfigurationWroteThem`（新增） | 通過；本機／遠端兩種 `ConfigSource` 都比對 `config.sites` 的原始順序 |
| 同一條測試跑在**舊行為**上 | **3 個 issue 失敗** — 這條測試抓得到這個缺陷 |
| `listsThePortedSpiderSitesAlongsideTheNativeCMSSites` | 通過，仍是 `62 = 30 native + 32 spider` |
| 全套 | 182 條，1 條失敗，見下 |

測試特地斷言 `firstSpider < lastNative`：這份設定檔真的是交錯的，
所以「分組後的清單」與「原始順序的清單」必然不同——不是一條永遠會過的測試。

### 這一輪唯一的失敗，與本修正無關

`reportsLiveType4SitesFromProvidedConfig` 在 `CMSClientTests.swift:212` 失敗：
`88看球` 這一站今天回的是 `https://embed.st/embed/admin/ppv-…/1`，一個**網頁**而不是媒體位址，
於是 `CMSClient.isDirectMedia` 斷言不成立。

**在 stash 掉本次改動、回到 `0cc565a3` 的乾淨狀態下重跑，同一條測試以同一個原因失敗**——
先確認過才敢這樣說。這是 provider 狀態（本文件與 `current-task-state.md` 早就記著
type-4 的直連媒體判定是路徑副檔名啟發法，標了 `ponytail:`），不是本次修改造成的迴歸，
依 AGENTS.md §2 只報不修。交接文件寫的「181 條全過」是 2026-09-21 的量測，今天不再成立。


## 10T — 實作 CatVod／TVBox JS spider 契約（10P 的後續，使用者核可）

10P 只把靜默換成具名失敗。這一刀把契約做出來。

### 評估（AGENTS.md §7）：先把腳本跑起來，不是讀截圖

用 Node 的 `vm` 把 `drpy_js/麻豆.min.js` 載進一個**空 context**，讓 `ReferenceError`
自己指認缺什麼，再接真的 HTTP 驅動整條鏈。量到的事實：

| 問題 | 答案 |
|---|---|
| 載入時需要的 global | **零個** |
| 呼叫時需要的 global | **只有 `req`** |
| 從 `req` 的回應讀走的欄位 | **只有 `.content`** |
| `__jsEvalReturn()` 回傳 | `{init, home, homeVod, category, detail, play, search}` |
| 七個方法 | **全部 `async`**，回傳 JSON 字串 |
| `init(extend)` | 收**物件**（它寫 `extend.stype='3'`） |
| `detail(id)` | 收**單一字串**，不是 `Spider.java` 的陣列 |
| `play()` | 不發請求，直接回 `{url:id, parse:0, jx:0, header:{User-Agent}}` |
| 實際端點 | `https://19q.cc/api.php/provide/vod` — 一個標準苹果CMS JSON API |

`req` 與 `.content` 的映射**早就存在**：`DrpyEngine.moduleRuntime` 為 drpy 站寫的
`res.content = res.body` 就是這個。`pdfh`／`pdfa`／`pd`／`local`／`print` 也已在那裡。

### 真正的阻礙不是 `__jsEvalReturn`，是 `async`

`drpy2.min.js` 全檔 **0 個 `async`**——這正是 `JavaScriptSpiderRuntime`
從來不必處理 Promise 也能動的原因，也是這個缺口一直沒被發現的原因。
麻豆七個方法全是 async，`invokeMethod` 拿回 Promise 本身，`JSON.stringify` 把它變成 `{}`。
**十三個方法全部回 `{}`，而且沒有任何錯誤**——畫面上就是「沒有內容」。

用 JavaScriptCore 實測（獨立的 `jsc.swift` 探針）：

```
naive result isString=false desc=[object Promise]       ← 修正前
after drain rounds=0 out={"got":{"ok":1,"u":"x"},"f":true}
```

掛上 `.then` 把結果存進 global 後，**不需要任何額外的 drain 次數**：
`CatVodHost` 的 HTTP 是同步的，spider 的 promise 沒有真正的暫停點，
JSC 在 native→JS 呼叫收攤時就把微任務排空了。

### 做法：接上去，不是另造一套

`IOS_SPIDER_RUNTIME_SPEC.md` 明文「There must never be two JS runtimes」。
上游 TVBox 那套是為 QuickJS 寫的，帶自己的 HTTP／WebView／`js2proxy`／`getProxy`，**拒絕原樣移植**。
這裡做的是把它的**入口契約**接到既有 runtime 上，與 `drpy-bridge.js` 完全同形。

| 檔案 | 改動 |
|---|---|
| `JavaScriptSpiderRuntime.settled(_:)` | 回傳是 thenable 就結算；rejected 變具名錯誤。**所有 JS spider 共用** |
| `Resources/Spiders/js-spider.js`（新，77 行） | 七方法 → 十三方法 ABI |
| `CSPSourceResolver.drpySession` | 一次下載服務兩種契約，看 bytes 決定走哪條 |
| `DrpyEngine.script(at:source:)` | 從 `rule(at:source:)` 拆出共用的下載＋同源檢查 |
| `SpiderRegistry.jsSpiderBridge` | 與 `drpyBridge` 同樣 bundled、同樣不可被 pack 取代 |

Swift 淨增 **118 行**（含註解），JS 77 行。**新增的 native 能力：零。**
JS spider **不下載 drpy 的 1.2 MB 引擎**——它不用。

### 兩處刻意的設計決定

**`init` 傳物件而非文字。** 這是兩套契約唯一真正的差異。`Spider.java` 給字串，drpy2 收字串，
但 JS spider 收的是解析後的 `ext` 而且會寫進去。字串 primitive 在 sloppy mode 下靜默無效、
在 strict 下丟 TypeError。所以 bridge 先 parse；不是 JSON 就包成 `{ext: <原文>}`。

**bridge 不寫 `isVideoFormat`／`manualVideoCheck`／`liveContent`／`destroy`。**
`JavaScriptSpiderRuntime` 對缺少的方法本來就回 base class 的預設值，
寫出來只是把下一層做的事再講一次。（第一版寫了，final-diff review 砍掉。）

### 驗證

| 檢查 | 結果 |
|---|---|
| **麻豆 走 `DRPY_GOLDEN_*` 閘門（真實來源）** | **通過**：home 20 類 → category 30 筆 → detail → search 30 筆 → player `parse=0` → `SourceClient` 取到真實媒體位元組，帶 1 個 header |
| **UAA（同設定檔的真 drpy 站）走同一條閘門** | **通過**：home 3 類 → category 32 → detail → search 32 → 播放位址。**沒有誤傷** |
| `JavaScriptSpiderRuntimeTests`（新，3 條離線） | 通過 |
| 同 3 條跑在**未結算 promise** 的舊行為上 | **全部失敗**，訊息是 `an error was expected but none was thrown and "{}" was returned`——正是使用者看到的症狀 |
| 全套 | **185 條，1 條失敗** |
| 模擬器 build（iPhone 17 Pro `E0A41D48…`） | BUILD SUCCEEDED |
| 真機 build（iPhone 18 Pro `00008160-00124C8200214036`） | BUILD SUCCEEDED |

唯一失敗仍是 `reportsLiveType4SitesFromProvidedConfig`（`88看球` 今天回一個網頁而非媒體位址）。
`AGENT_HANDOFF.md` 已寫明這條「**不要去「修」**」，且已確認在 `0cc565a3` 的乾淨狀態下以同一原因失敗。

### 還沒有人親眼看過的

**App 裡沒有目視確認。** 上面全部是測試與 build 證據——但閘門測試走的是
`SourceClient`，跟 App 自己用的是同一條路，而且斷到真實媒體位元組，不是只看 URL 存在。
**真機上實際點開麻豆播放，仍需使用者確認。**

### 代價

確認的 JS spider 只有麻豆**一站**（`wang-sex.json` 的 5 個 `.js` 站裡，4 個是 drpy）。
好處是成本也只有一支 bridge，而 promise 結算那一塊對任何 async spider 都有效。
關閉開關不變：`CSPSourceResolver.canResolve` 的 `isDrpySpider` 那一行。
`IOS_SPIDER_RUNTIME_SPEC.md` 的「遠端機制不可成為承重結構」照舊適用。


## 10V — 使用者在真機上確認：麻豆列得出來，也播得動（2026-09-22）

10S 與 10T 的目視驗證由使用者在 **iPhone 18 Pro**（`00008160-00124C8200214036`）完成。
安裝的是 `164dc271` 這版；`js-spider.js` 在 bundle 裡，與 commit 的原始碼逐字元比對過
（第一次裝的是 Ponytail trim 之前的 build，發現後重 build 重裝）。

### 確認到的

| 項目 | 由什麼證實 |
|---|---|
| **JS spider 契約在真機上可用** | 麻豆(js) 出現在來源清單、點得進去、有內容 |
| `home` / `category` / `detail` / `play` 在裝置上跑得通 | 使用者一路點到播放成功 |
| **真機上第一次有 JS spider 播出畫面** | 同上 |
| 順序修正（10S）已生效 | 使用者在清單裡找得到麻豆——修正前它被推到 drpy 那一段 |
| 遠端設定檔 + 同源腳本載入在裝置上成立 | 麻豆的腳本只能從設定檔自己的來源抓 |

### **不能**由這一次推論出來的事

**這不是 `AVURLAssetHTTPHeaderFieldsKey` 在真機上有效的證據。** 麻豆的 `play` 回的 header 只有
`User-Agent: Mozilla/5.0`，而那條串流**不帶 UA 也照樣回 200**——當場用 `curl` 兩邊各驗一次：

```
無 User-Agent      → HTTP 200  2217B  application/vnd.apple.mpegurl
User-Agent: Mozilla/5.0 → HTTP 200  2217B  application/vnd.apple.mpegurl
```

所以播得動只證明位址可播，沒有證明 header 有送到 `AVPlayer`。
**那個問題仍然懸著**，而且它真正的考題是 Bili（同時需要 `Referer` 與瀏覽器 `User-Agent`），
不是這一站。`current-task-state.md` 的「the header question is the sharp one」不要因此劃掉。

其他沒觀察到的：裝置上的 `search` 與 `homeVod`、麻豆是否恰好排在第 7 個。
沒看到就是沒看到。
