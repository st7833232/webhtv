# W-222 iOS XBPQ：跳轉頁不是影片時，嗅探跳轉到的頁面

## Recovery anchor
- 目標：光速影視「电影天堂云」線在 iOS 播得出來（Android FongMi 已能播）。
- 範圍：`ios/Spiders/XBPQ.js`、`spider-pack/scripts/XBPQ.js`（兩份位元組相同）、`ios/Tests/WebHTVCoreTests/XBPQRuleTests.swift`、本文件。不改站點設定、不上傳 GitLab、不發包。
- 分支：`ios-poc`，起點 `11a39252`；開工時工作區乾淨。
- 狀態：完成。程式、測試、Ponytail、Simulator 實播都通過。
- 下一步：送 Reviewer 審查。

## 根因（證據）
- 站點規則（GitLab 現行設定）：`跳转播放链接` = `var now="&&"`，`二次跳转播放链接` = `const vid = '&&'`。
- 播放頁 `https://www.yingshiso.link/video/?216411-1-0.html` 的 `var now` 是分享頁 `https://play.phimgood.com/share/<id>`；分享頁裡寫的是 `const vid = "…"`（雙引號），所以二次跳轉切不到東西，跳轉結果停在分享頁，不是影片。
- Android（FongMi 5.8.4，`artifacts/android-compat/emu-play-1029/guangsu.logcat.txt`）：jar 版 XBPQ 回 `{"parse":1,"url":"https://play.phimgood.com/share/…"}`，WebView 嗅探分享頁拿到 m3u8，有畫面。
- iOS：`ios/Spiders/XBPQ.js` `playerContent` 在跳轉與各種後備規則都拿不到影片時，回的是**原始播放頁** `target`（`return host.result.play(target, true, headers)`），不是跳轉到的分享頁。嗅探原始播放頁拿不到影片 →「這一集沒有可播放的網址」。

## 做法
- `playerContent` 記住 `jumpedUrl` 的結果；最後要交給嗅探時，有跳轉結果就嗅探它，沒有才嗅探原始播放頁。和 Android jar 一致（jar 回的是跳轉結果加 `parse:1`）。
- 不選的做法：
  - 不改：iOS 這站一直播不出。
  - 改站點規則（`const vid = "&&"`）：任務限制不改站點設定，而且 Android 現在能播，iOS 應該和 Android 吃同一份設定。
  - 在 iOS 直接解析分享頁的 `const url`：只對這個播放器有效，比照 Android 交給嗅探更通用。
- 影響範圍：只影響「有 `跳转播放链接`、跳轉結果不是影片、其他後備規則也沒抓到影片」的情況；原本交給嗅探的是原始頁，現在改成跳轉到的頁。跳轉結果是影片、或沒有寫跳轉規則的站，行為不變。

## 驗證
- 新測試 `sniffsThePageTheJumpReachedWhenItIsNotAStream`：改前失敗（回原始播放頁）、改後通過。
- `swift test --filter XBPQ`：30 個測試全過。`swift test`：1423 個測試全過。
- 兩份 XBPQ.js `cmp` 相同。
- Simulator：App 已從本機 HTTPS 載入只含修正版 XBPQ.js 的相容包（`artifacts/w222-guangsu-dytt/server.log`），但公司網路的 Fortinet 防火牆攔截 `www.yingshiso.link`（回 Fortinet 簽的憑證），App 顯示 TLS 失敗（`g1-sim-company-network-tls-blocked.png`）。這是公司網站過濾，不繞過。當時實播未驗。
- Simulator 實播（2026-10-29 16:19，Mac 回到手機熱點後）：webhtv-w202，App 從本機 HTTPS 載入測試設定與修正版 XBPQ.js（`server-hotspot.log`：`w222-test.json`、`spiders/manifest.json`、`spiders/scripts/XBPQ.js` 各 200）。光速影視「街頭王國：奏響你的聲音。」選「電影天堂雲」線（`h2-detail-dytt-selected.png`），App 記錄 `resolve HD中字 live 7057ms`、`started … on 原生 in 4414ms`，畫面有片（`h3/h4-play-*.png`，`app-playback.log`）。W-219 時同一部片同一條線在 iOS 是「這一集沒有可播放的網址」。測完 App 設定改回 GitLab、Simulator 關機。
- 測試方法（給續作）：自建一次性 CA 只信任在 webhtv-w202（`simctl keychain add-root-cert`），`https_srv.py` 提供 `w222-test.json`（只有光速一站）＋`spiders/manifest.json`＋`spiders/scripts/XBPQ.js`；App 設定用 `simctl spawn <udid> defaults write com.webhtv.ios.poc configSourceURL/selectedSiteKey/selectedSiteBySource` 改（直接改 plist 無效）。

## Ponytail
- `ponytail:ponytail-review`（2026-10-29，未 commit diff）：Looks good. Ship. 無發現。已查：只影響「跳轉結果不是影片、後備規則也沒抓到」的情況；沒寫跳轉規則的站不變；嗅探規則依頁面主機比對，與 Android 嗅探跳轉頁一致。

## 回復
- revert 本單 commit。
