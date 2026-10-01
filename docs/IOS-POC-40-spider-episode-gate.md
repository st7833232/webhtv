# IOS-POC-40 — spider 站的集數與「立即播放」變灰、不能按

## Recovery anchor

- 使用者回報（2026-10-01，附截圖）：「金牌可以看得到資源但是無法播放」。截圖為「🥇｜金牌系列-zjuys」的《名偵探柯南：30 號殺人事件》，詳情與年份、演員、簡介都正常，集數按鈕與「立即播放」都是灰色。
- 狀態：**已實作並 commit；未編譯、未執行單元測試、真機未驗證。**
- 唯一下一步：下一版 IPA 在 iPhone 上照第四節驗證。

## 一、原因（已確認）

1. `又是一個金牌.py`（GitLab `st7833232/recha` `main`，2026-10-01 取得，SHA-256 `32bc2ee53149d914c360e520686203d1e522a4c8656700b19476049fd3d6737f`）`detailContent` 第 125-127 行把每一集寫成 `名稱$影片id@@集數id`，`playerContent` 再以這兩個 id 呼叫 `/api/mw-movie/anonymous/v2/video/episode/url` 取得網址。
2. 詳情頁的集數格以 `episode.mediaURL == nil` 停用按鈕（`ios/WebHTVApp/Sources/WebHTVApp.swift` `VodView`），`Flag.playNow` 也只認 `mediaURL != nil`（`ios/Sources/WebHTVCore/CMSClient.swift`）。`mediaURL` 只接受 http(s)，`123@@456` 不是網址，所以每一集與「立即播放」都停用。
3. 播放路徑本身沒問題：`SourceClient.playbackURL` 的 spider 分支刻意不檢查 `mediaURL`（IOS-POC-5D 第 2 點「`episode.mediaURL` must not gate playback」）。是畫面的判斷與這條既定規則矛盾。
4. IOS-POC-37 的 `PythonLiveCheck` 直接呼叫腳本，不經過畫面，所以模擬器上金牌系列都到 media，沒有看出這個問題。
5. 影響範圍：所有集數值不是 http(s) 的 spider 站（Python、`csp_*`、drpy）。哪些站符合，未逐站查證。

## 二、修改

1. `Episode.isPlayable(spider:)`：spider 站只要集數值非空即可；CMS 站維持 `mediaURL != nil`。
2. `Flag.playNow` 加 `spider:` 參數（預設 `false`，CMS 行為不變），以 `isPlayable` 判斷可播。
3. `VodView` 的集數格停用條件與「立即播放」的兩處呼叫都傳 `site.isSpiderShape`。列出的 spider 站都經 `WebHTVConfig` 以 `isSpiderShape && resolver.canResolve` 篩選，與 `SourceClient.make` 走 spider 分支的條件一致。
4. 測試：`PlayNowTests.aSpiderEpisodeNeedsOnlyATargetForPlayerContent`。spider 站的 `123@@456` 可播；同樣的值在 CMS 站不可播；空值在 spider 站不可播。

## 三、風險與回滾

- 風險：spider 站中 `playerContent` 解析不出網址的集數，從「按不下去」變成「按了顯示『這一集沒有可播放的網址。』」，與 Android 行為一致。
- 驗證缺口：本環境是 Linux，沒有 Swift toolchain，WebHTVCore 依賴 JavaScriptCore、WebKit、CryptoKit，無法在此編譯或執行測試；發布 workflow 只做 Release build，不跑單元測試。
- 回滾：`git revert` 本 commit。

## 四、真機驗證

1. 金牌系列-zjuys（或其他金牌站）任一部片：集數按鈕與「立即播放」可以按，並能播放。
2. 任一 CMS 站：集數與「立即播放」行為不變。

## 五、同一次回報的可可影視（不在本 commit）

- `kkys.py`（2026-10-01 取得，SHA-256 `5b507240927e80f59438322519e47e2036236628aac44a0da6fb351adbc1b9d1`）`detailContent` 第 922-929 行只回傳 `vod_id`、`vod_name`、`vod_pic`、`vod_content` 與播放清單，沒有 `vod_year`、`vod_area`、`vod_director`、`vod_actor`，所以詳情頁不顯示這些列。App 不需修改。
- 要補欄位需要詳情頁 HTML；本環境 egress proxy 對 `www.kkys20.com` 回 `CONNECT tunnel failed, response 403`，無法取得。
