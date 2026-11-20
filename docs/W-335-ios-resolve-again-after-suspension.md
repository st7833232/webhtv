# W-335 暫停後被系統凍結，回前景時重新解析網址再載入

- 分支 `claude/kind-dirac-ojjljm`，接在 W-334（`0fe9960d`）之後。
- Lane：quick-fix。使用者 2026-11-20 回報，並指示「不只紅果會這樣」，要 App 端的通用修正。

## 1. 問題

影片播放時按下暫停，退到背景一段時間後回到前景，就無法播放，只能重啟 App 才能繼續。不只紅果會這樣。

## 2. 原因

- IOS-POC-23 已處理「暫停時被凍結，回前景以同一網址重新載入」（`reloadPaused`）；IOS-POC-52 F12 另外處理了「已下載的 HLS 先重開本機伺服器並改用新連接埠」。
- 線上播放仍以**同一個網址**重新載入。凍結後這個網址常常已經失效：
  1. App 爬蟲代理（`SpiderProxyServer`，127.0.0.1）的監聽 socket 被 iOS 關掉。代理會在下一次 `serve()` 時重開，連接埠可能不同，但重新載入不會經過 `serve()`。
  2. 腳本自己的本機服務，例如紅果 PY 的 `_start_stream_server`，同樣被關掉。
  3. 有時效的簽章連結已過期。
- 重啟 App 會重新解析網址，所以就好了。

## 3. 做法

- `PlaybackSession` 新增 `resolveAgain: (() async -> PlaybackTarget?)?`，由詳情頁 `VodView` 開啟線上集數時提供，內容就是同一套即時解析：`SourceClient.make(...).playbackURL(for:flag:)`。開新項目、開 `InlineVod`、關閉播放器時清掉。
- `reloadPaused` 不是已下載的 HLS 時，改呼叫 `reloadResolvedAgain(at:)`：
  - 有 `resolveAgain`、而且不是離線檔：先重新解析網址，再用 `PlaybackQualityChoice(target:preferred:)` 選回原本的畫質，以 `router.reload(at:autoplay:false,url:)` 在原位置暫停載入。重新解析會經過 `serve()`，所以代理會在需要時重開。
  - 解析失敗或沒有 `resolveAgain`（直播、網頁內嵌播放、離線單檔）：照舊以舊網址重新載入。
  - 解析期間使用者換了集數：不做任何事。
- 沒有改的部分：判斷是否被凍結的方式（心跳間隔）、eligibility 規則、離線 HLS 的路徑、自動播放規則（重新載入後仍是暫停）。

## 4. 紅果的限制（需要 recha 另外修）

紅果 PY 的 `_start_stream_server` 只在第一次啟動時開伺服器，之後永遠回傳快取的連接埠，不會檢查它是否還活著。所以 App 重新解析網址時，紅果仍會回傳已被關掉的連接埠，必須在 recha 另外修。這不在本任務範圍內，也不在本 repo。

## 5. 驗證

- 本機沒有 Swift／Xcode，**尚未編譯**，只做了 diff 靜態審查。已確認 `PlaybackQualityChoice.name`、`.url`、`init(target:preferred:)` 都是 public，閉包寫法和既有的 `retry` 相同。
- 這段是 App 生命週期流程，沒有單元測試可涵蓋。
- 實機待確認（非紅果的站台）：
  1. 播放時暫停，切到背景超過約 1 分鐘，或鎖定螢幕讓 App 被凍結後再回來，按播放能繼續；log 會出現 `resolved again after the suspension`。
  2. 回來後仍是暫停狀態、位置正確、畫質維持原本的選擇。
- Ponytail：unavailable / skipped（此環境沒有提供）。

## 6. 風險

- 重新解析需要時間，紅果冷啟動要 3–18 秒。這段時間按播放，舊網址不會動，等解析完成後重新載入，畫面會停在暫停狀態，需要再按一次播放。
- 重新載入沿用舊的 request headers，只換網址；如果新網址需要不同的 headers，可能無法播放（少見）。

## 7. 回復

`git revert <W-335 commit>`。

## Recovery anchor

- 狀態：程式碼與文件已完成，尚未編譯。
- 下一步：和 W-334 一起推送並發佈為 0.1.111；紅果需要另外修 recha PY 的 `_start_stream_server`（等使用者決定）。
