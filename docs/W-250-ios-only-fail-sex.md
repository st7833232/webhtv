# W-250 wang-sex：只有 iOS 失敗的 3 站，以及只有 Android 能用的 4 站

工單 W-250（Manager #6485）。設定底稿：GitLab recha `2a74b1f`（130 站）。不改設定檔。
分支 `task/W-250`，自 `origin/ios-poc` 253de768（Manager #6504：送審前不用 rebase）。

## Recovery anchor

- 目標：前 3 站（香肠派对.py、KISSAV(标签)、KISSAV(主题)）找到 iOS 失敗的根因，修到能播或寫下證據；後 4 站（Jable、番號、女優、薇薇珊）只評估 iOS 要補什麼，不實作。
- 狀態：KISSAV 首頁已修（`XBPQ.js`）。單元測試紅→綠；Simulator 上首頁「已載入 5 部」，可以進詳情。**但播不出來**：抓到的 m3u8 本身回 200，金鑰與片段一律 403（見下）。香肠派对今天在 iOS 正常。4 站評估完成。
- 暫停：Manager #6612 改排 W-254 優先，KISSAV 修正先 commit 送審。未完成的是 KISSAV 播放根因與香肠派对的 Simulator 實播。

## 每站結論

位置是 `2a74b1f` 的 `sites` 從 0 算。

| 位置 | 站 | 類型 | 結論 | iOS 要做什麼 |
|---:|---|---|---|---|
| 32 | 香肠派对.py | Python | **今天在 iOS 能用**。App 內 Python survey 只放這一站：load→init→home（4 分類、20 部）→category（16）→detail→search（5）→player→sniff→probe(media) 全部通過；首頁畫面顯示「已載入 20 部」。同一支腳本在 Mac 用 iOS 的 `base/spider.py` 跑，4 個分類各 16 部。W-226 兩次「載入失敗」（11-05、11-06）和今天第一次啟動時分類空了一次，都沒有重現出程式錯誤。判斷是站台或網路偶發，不是 iOS 程式問題。 | 不用改程式。 |
| 123 | KISSAV(标签) | csp_XBPQ | **已修**。網站改版：`www.kissavtv.com` 301 轉到 `kissavs.com`，分類連結從 `/index/tagMvs/tags/…` 改成 `/av/tag/…`，設定的 `分类ID` 規則一個都對不到，所以 0 個分類。站台沒設 `首页`，原版 `xyqxbpq.jar` 預設就是首頁 40 部（IOS-POC-39 §4.4），Android 因此還有首頁 5 部、分類退回预设的电影／连续剧／综艺／动漫。iOS 卻刻意改成「沒設 `首页` 就列第一個分類」（IOS-POC-39 S3，紅果短剧靠這個），沒有分類時首頁就空了。 | `XBPQ.js`：沒設 `首页` 又沒有分類時，照原版列首頁（有分類的站不變；沒有首頁網址仍回空）。 |
| 124 | KISSAV(主题) | csp_XBPQ | 同上，已修。 | 同上。 |
| 21 | Jable | csp_Jable（`xc0126.jar` Java 類別） | iOS 沒有 `csp_Jable` 的移植。同一份設定另有 `Jable.py`（位置 34），key 也是 `Jable`、也沒有 ext。iOS 依 key＋ext 選站，所以永遠選到前面這個跑不了的 Java 站。`Jable.py` 用 iOS 的 Python base 在 Mac 上整條通過：6 分類、24 部、詳情 1 集、播放 m3u8。 | 最便宜：設定把 `Jable.py` 的 key 改成唯一（只改設定、0 程式碼；要交 Manager／使用者，不在本單範圍）。程式替代方案：iOS 選站時，同 key 跳過本平台跑不了的站，約 1 小時＋測試。移植 `csp_Jable` 不建議，已有能用的 Python 版。 |
| 51 | 番號 | type 4（`./json/00title05152.json`） | 不是「iOS 不支援 type 4」：iOS 的 `CMSClient` 本來就支援 type 4。缺兩件事：①api 是相對路徑，iOS 沒有用設定網址補成完整網址，請求直接以 -1002（不支援的網址）失敗；補成完整網址後，iOS 讀得到 1 個分類、75 項。②項目沒有 `vod_id`。FongMi 點下去是空 id，`VideoActivity.checkId` 走 `setEmpty`，也就是用片名搜尋所有站；iOS 沒有這個流程，會去開一個空 id 的詳情。 | ①type 4 的相對 api 用 `ConfigSource.resourceURL` 補成完整網址（約 0.5 小時＋測試）；②沒有 `vod_id` 的項目點下去開全站搜尋（App 已有 `AggregateSearchView(initialQuery:)`，約 1～1.5 小時＋Simulator 驗證）。合計約 2～3 小時。三站共用。 |
| 72 | 女優 | type 4（`00title05151.json`） | 同上；補成完整網址後 139 項。 | 同上。 |
| 107 | 薇薇珊 | type 4（`00title05153.json`） | 同上；補成完整網址後 57 項。 | 同上。 |

## 修改（KISSAV）

- `ios/Spiders/XBPQ.js` 與 `spider-pack/scripts/XBPQ.js`（兩份相同）`homeVideoContent`：沒設 `首页` 時，有分類照舊列第一個分類；沒有分類時改用原版預設 `40`，列 `主页url` 的片；連首頁網址都沒有就回空清單（和改之前一樣）。
- 測試 `XBPQRuleTests.listsTheHomePageWhenUnsetAndNoCategoryWasFound`：分類規則對不到時，首頁列出首頁的片。修正前失敗、修正後通過；`swift test --filter XBPQ` 31 項通過。
- 真實網站（熱點 172.20.10.6，暫時測試、未提交）：兩個 KISSAV 站都是首頁 5 部、詳情 1 線 1 集（`;;z` 直接播放），`playerContent` 從影片頁解出 m3u8（parse=0）。這個 m3u8 是 AES-128 HLS，不帶 Referer 也回 200。

## KISSAV 播放：根因與修正（11-10，task/W-250-kissav）

- 根因：影片頁的播放器程式用 Dean Edwards 的 p,a,c,k,e,d 打包。解開後，播放器開的是站內代理 `https://<站>/media/m3u8/?url=<原 m3u8>`。代理回的清單裡，金鑰與片段換成另一組有簽章的網址（`hc163/...?auth_key=`），curl 不帶 Referer 也回 200。iOS 原本是用 `playerContent` 最後一條正則，抓到頁面 SEO 區塊（`ld+json` 的 `contentUrl`）裡的原始 m3u8，那組金鑰與片段一律 403。證據在 `artifacts/w250/kissav/`：`video.html`、`player-unpacked.js`、`proxied.m3u8`。
- 修正（通用，不是只給 KISSAV）：`XBPQ.js` 新增 `unpacked(raw)`，用純字串運算解開打包，不執行頁面程式。`playerContent` 在「頁內唯一串流」那條正則之前，先取解開後播放器的 `'url':'…'`，用播放頁網址補成完整網址，路徑含 m3u8 或 .mp4 就直接播（parse 0）。這裡不用 `isVideo`，因為它預設的過濾詞 `url=http` 會擋掉代理網址；是網站自己的播放器開這個網址，才放寬。`ios/Spiders/XBPQ.js` 與 `spider-pack/scripts/XBPQ.js` 同步修改，內容相同。
- 為什麼不是改設定檔：不能改使用者的設定檔；而且同樣的打包手法在其他苹果CMS 類網站也很常見，修在通用引擎可以一起受惠（符合 11-10「新增站台先走通用格式、優先擴充規則引擎」）。
- 驗證：
  - 單元測試 `playsThePackedPlayersOwnAddressBeforeTheSEOStream`：打包的播放器加上 `ld+json` 陷阱，結果取到代理網址；沒有打包時仍取頁內唯一串流。換回原版 `XBPQ.js` 時這個測試是紅的，修正後是綠的。XBPQ 相關測試 32 個全過。
  - 真實網站（熱點，暫時測試、沒有提交）：引擎在真實影片頁回 `{"parse":0,"url":"https://kissavs.com/media/m3u8/?url=…"}`；ffmpeg 讀這個網址 5 秒，AES 解密與解碼都正常（h264 1280x720＋aac）。
  - Simulator App 實播（Reviewer C-1，11-10 15:57）：iPhone 18 Pro、iOS 27，App 是 W-278 的 Debug 建置。本機 https 相容包放在 `artifacts/w250/kissav/srv/`：設定 `w250-kissav.json` 只有 wang-sex 的兩個 KISSAV 站，站點物件原樣照抄；`spiders/manifest.json` 只覆蓋修正版 `XBPQ.js`；用 18448 埠提供，不碰共用的 18445；測試 CA 已用 `simctl keychain add-root-cert` 加入 Simulator。
    - 重開 App 後，伺服器 log 有取 `manifest.json` 與 `XBPQ.js`，首頁「KISSAV(標籤) · 已載入 5 部」。
    - 第一部「立即播放」，進度從 00:10 走到 00:30（總長 1:17:10），有起播且持續播放。
    - 證據只存畫面的文字樹（`artifacts/w250/kissav/sim/*.txt`）與伺服器 log，不存成人內容截圖。
  - Android 對照：Reviewer 說 Android 本來就能播，不必對照，所以沒做。
- Ponytail（Reviewer C-2）：1 項必修，已修。打包區塊的基數 `a` 和字數 `c` 是從頁面讀來的；不合理的值（`a` 不在 2～62 之間，或 `c` 很大）原本會讓 `word()` 無限遞迴，或讓迴圈空轉很久。現在 `a` 超出範圍就跳過這個區塊，`c` 上限是實際字數。測試加了兩個不合理的打包區塊，都會跳過，最後仍播頁內那條串流。XBPQ 測試 32 個全過。
- 實播版本（Manager #7546）：上面 Simulator 實播載入的相容包 `XBPQ.js` 和 78f67fd7 逐字相同，也就是 Ponytail 修正**之前**的版本。那項修正只會跳過數字不合理的打包區塊，KISSAV 的頁面不會走到，所以不重播。

## 香肠派对：Simulator 實播（11-10，task/W-250-scpd）

> 已移到 docs/W-283-scpd-ios-play.md（W-283）：根因是爬蟲方法 1 的正則與 re.sub，修在 recha；本節保留當時紀錄。

- 用同一個本機 https 相容包（`w250-kissav.json` 加上 `scpd` 站，`py/香肠派对.py` 原樣照抄）。首頁載入 20 部；第一部（`/vodplay/402997-1-1.html`）按「立即播放」，出現「這一集沒有可播放的網址」。修正後再播一次，有一次出現 `requests` 的 `Connection reset by peer`（偶發），再播仍是「沒有可播放的網址」。證據 `artifacts/w250/kissav/sim/w250-09…14*.txt`、`scpd-play.html`。
- 找到兩個原因：
  1. **iOS 跟 Android 讀播放結果的方式不一樣（已修）**：這支爬蟲的前四種取法都只回 `{"parse":0,"playUrl":…}`、沒有 `url`。FongMi 播的是 `Result.getRealUrl()` = `playUrl + url`（`PlaybackActivity.startPlayer`、`PlaySpec.from`），iOS 只讀 `url`。修法：`PlayURL.prefixed(by:)`，`parse` 與 `jx` 都是 0 時，爬蟲結果與 type 4 結果都改播 `playUrl + url`；type 4 的 `PlayResponse` 沒有 `url` 也照樣解碼。測試 `aSpiderResultPlaysPlayUrlPlusUrlWhenNothingParses`。
  2. **這一部真正卡住的地方（還沒修）**：播放頁的 `var player_aaaa={…}` 後面沒有分號，直接接 `</script>`。爬蟲的正則 `var player_aaaa\s*=\s*({.*?});` 對不到，其他方法也都沒中，最後回 `{"parse":1,"url":播放頁}`，要求嗅探。iOS 交給 `MediaSniffer.sniffWithSubtitles` 去嗅探這一頁，結果沒抓到串流（頁面播放器依 `playerconfig.js` 與 `from:"aosika"` 再載入播放器），所以 `target()` 回 nil。Android 是用 WebView 嗅探。頁面裡其實就有 `player_aaaa.url`（一個 m3u8）。
- 下一步建議（另開單或由 Manager 決定）：查 iOS 嗅探器在這一頁為什麼沒抓到（iframe／hls.js 的請求），或在 `parse:1` 的苹果CMS 頁面先讀 `player_aaaa.url` 再嗅探。不改使用者的爬蟲檔。
- 驗證：SourceClient／PlayURL／GlobalParse／SpiderGolden 共 54 個測試全過；全量 1543 個裡只有已知不穩的嗅探 WebView 測試失敗，單獨重跑通過。App Debug 建置通過。

## KISSAV 播放（Simulator 11-09 11:29，當時未解，保留紀錄）

- 首頁 5 部 → 詳情（直播列表 1 集）→ 立即播放：`resolve … live 1304ms`。原生播放器 10 秒內沒起播（`neverReady`、buffer 0），自動改用 MPV 也一樣失敗（`Failed to open xv.dzuxta.cn .m3u8`）。
- curl：m3u8 回 200。它的 AES 金鑰和 `.ts` 片段，不論帶不帶 `Referer: https://kissavs.com/`、補不補上 m3u8 的 `auth_key` query，都回 403。這個 m3u8 是頁面 SEO 區塊（`ld+json` 的 `contentUrl`）裡的網址，iOS 的 `playerContent` 是用最後一條正則抓到它；網站自己的播放器實際用哪個網址還沒找到。
- 實驗（只在本機測試包，沒改 repo）：拿掉那條正則、改成把影片頁交給嗅探。45 秒內沒有 resolve 紀錄，畫面停在詳情頁，結果不確定。
- Android 這輪播不起來是因為 Mac 負載 40～99、模擬器一直跳系統 ANR，所以沒有兩平台的對照。下一步：等 Mac 不忙時在 Android 播同一部片，確認 Android 能不能播、用的是哪個網址，再決定 iOS 要不要改嗅探順序。
- 附帶發現（不在本單範圍）：相容包是在首頁載入之後才套用，而 `rebuildSites` 不會重建爬蟲 session，所以 App 開起來的第一個畫面還是正式包的腳本，要下拉重新整理才換成相容包。

## 驗證狀態

- 已驗證：上面的單元測試與真實網站引擎測試；Android 5560 上 KISSAV 首頁 5 部（11-09）。
- 已驗證：Simulator 上 KISSAV(主题) 首頁「已載入 5 部」（本機相容包放修正版 XBPQ.js，下拉重新整理後）。
- 未驗證：KISSAV 播放（上一節）；香肠派对的 Simulator 實播（今天只有 survey 跑到 media）。Android 播放：模擬器 ANR。
- 證據：`.herdr-synapse/webhtv-dev/artifacts/w250/work/logs/`（App survey `xcpd-console2.log`、XBPQ 測試 `swift-test-xbpq.log`、香肠派对第一次啟動畫面 `xcpd.png`）。不存片名或影片截圖。

## 回復

還原 `XBPQ.js` 兩份與該測試即可；沒有資料格式或設定變更。
