# W-252 紅果短劇常連線逾時：分層根因與修正

## Recovery anchor
- 目標：重現使用者「原生逾時 → 自動切 MPV → MPV error -13，第 3 集之後特別容易，2 倍速」，分層找出逾時在哪一層；我們的上限或處理方式有問題就做最小通用修正，腳本／站方問題寫證據不改。
- 狀態（2026-11-09 11:35）：根因已分層確認；代理「同檔請求合併」修正＋R1 已 commit，重新送審。後續「已知失敗集數直接提示、不再卡轉圈」由 W-253 處理。
- 證據：`.herdr-synapse/webhtv-dev/artifacts/w252/`（`*-key.txt` 為篩選後的 log，`*-applog.txt` 為完整 log；驅動 `w252.sh`）。
- 下一步（唯一）：等 Reviewer 審查；REVISE 就開新 guard session 修正後重跑 `swift test --filter SpiderProxyServerTests`。

## 分層結論
1. **正常集數不會逾時。** Simulator（熱點，Debug，設定 `https://127.0.0.1:18445/w233-test.json` 的「红果 • 短剧」，腳本與 GitLab 同一份）：
   - 1x 連播 3 集（`x1-key.txt`）：代理 17 次呼叫，0 次 504、0 次 5xx；冷下載起播 3.4～9.2 秒（熱點被系統當低數據模式，預熱 `skipped: lowData`）。
   - 2x＋預熱（`WEBHTV_PREFETCH_IGNORE_LOW_DATA=1`，`x2-key.txt`）連播 4 集：代理 24 次，0 次 504／5xx；`content-warm ok` 3.3～4.4 秒，換集起播 0.33～0.57 秒。2x 有生效（每集實際約 90 秒，1x 約 173 秒）。
2. **出問題的是部分集數本身（站方／腳本，不改）。** 這些集數的影像編碼是 `bvc2`（字節跳動自家編碼，`stsd` 裡的 sample entry；ffprobe `codec_tag_string=bvc2`、`codec_name=unknown`），AVPlayer、MPV（FFmpeg）、Android ExoPlayer 都不能解。腳本 `红果短剧.py` 的 `_mp4_has_video` 只認 avc1/hvc1 等，把它當成「纯音频资源」，然後依序試 1080→720→540→480→360，但影片資料只有一個畫質，`_select_quality` 每次都回同一個 720 檔，等於同一個檔重複下載 5 次，10～16 秒（網路慢時超過 37 秒）後才回 `500 hg localProxy failed: no video track q=360`。
   - Mac CPython 對「裝窮提親」量 12 集（`hg_time.py`）：8 集是這種情況（12.4～16.0 秒後回 500），4 集正常（3.4～4.8 秒，200）。另一部「十八歲太奶奶…第五部」6 集都正常（3.7～5.2 秒）。
3. **App 放大問題的地方（我們的部分）：**
   - 原生播放器 10 秒還沒起播就放棄改用 MPV（`not started on 原生 after 10s — trying MPV`），這時腳本還在跑。MPV 的請求進到同一個站的**序列 Python 佇列**，排在原生那次後面，再跑一次冷下載；代理的 `callTimeout` 20 秒是從送出就開始算，所以變成 504（`→ none`），MPV 顯示「Failed to open 127.0.0.1」→「無法播放…(mpv error -13)」。`hg1-key.txt`：開播後約 33 秒才報錯。
   - 預熱其實已經知道下一集會失敗（`content-warm 5 failed: HTTP 500`，換集前 78 秒），換集時還是照樣去試：原生 10 秒 → MPV → `retrying an unplayable prefetch` 即時重解析 → 再一輪，一集用掉 4 次腳本呼叫（每次 10～15 秒），最後停在 `AVPlayerWaitingWithNoItemToPlayReason` 一直轉圈（`b2-key.txt`）。佇列一直被占著，也是「第 3 集以後更容易」的原因。
   - 代理 20 秒上限**不是**根因：正常集數冷下載 3～9 秒；bvc2 集數不管等多久都會失敗。

## 修正（本單）
- `ios/Sources/WebHTVCore/Spider/SpiderProxyServer.swift`：`call` 改走新的 `shared`。同一個檔（參數去掉 `range`）已經有腳本呼叫在跑時，後到的請求等同一個結果，不重新排隊。只有在結果和 range 無關時才共用：range 相同、5xx、或整集 `200 video/mp4`（`rangedMP4` 會依各自的 range 切）；206、403 等就各自再問。登記一直保留到腳本真的回應（逾時的請求放棄了，呼叫仍占著佇列），並在交出結果**之前**移除，所以之後的重試（W-246 的暫時性 500）一定會重新問腳本。`timed` 改成等一個 `Task`。
- 測試 `SpiderProxyServerTests`：`aRequestJoinsTheSameFileAlreadyBeingAnswered`（500 與整集 MP4 兩種：兩個不同 range 的同時請求只呼叫腳本 1 次、都拿到結果；結束後再請求會重新呼叫）、`aRangeAnswerIsNotSharedWithAnotherRangeOrFile`（真 206 不共用）。
- 驗證：`swift test --filter SpiderProxyServerTests` 34/34；反證：還原來源檔後新測試 4 項失敗。Ponytail review：1 項（結束後才清登記會讓重試拿到舊 500）已修正後重測通過。
- Simulator（修正後，`fix-hg1-key.txt`、`fix-b2-key.txt`）：正常集數照常（第 4 集 964 ms 起播）；換到 bvc2 第 5 集時 MPV 加入原生那次呼叫，沒有另外排隊，一集的腳本呼叫從 4 次降到 3 次。但那次腳本本身跑了 37 秒以上，兩邊仍在 20 秒時 504，最後仍是「mpv error -13」。**這類集數仍然會失敗**，只是佇列少堆一次。

## REVISE R1（Reviewer #6594 C1）
- 問題：`shared` 先建立 Task 才登記；腳本呼叫立刻回應或丟錯時，Task 內的移除會先於登記執行，登記永遠留著，之後同一檔每個請求都加入已結束的 task（nil→一直 504、5xx→一直舊 500）。
- 修正：建立 Task 與登記放進同一個 `lock.withLock`；Task 內的移除拿同一把 lock，必定排在登記之後。
- 測試：新增 `anAnswerAtOnceIsNeverReusedByTheNextRequest`（立即回 500／立即丟錯，同一檔連續 300 次請求，每次都要呼叫腳本）。`swift test --filter SpiderProxyServerTests` 35/35；反證：換回 5adec51b 的來源檔，300 次只呼叫腳本 150 次而失敗。
- 只改加鎖順序，沒有重跑 Simulator（行為由單元測試覆蓋）。

## 建議（範圍外，已轉 W-253）
- 預熱已拿到下一集 5xx 時，換集直接顯示原因（或跳到下一集），不再試原生 10 秒＋MPV＋即時重解析。
- 即時重解析後原生 `-1008` 停在轉圈、沒有顯示錯誤，要修成顯示錯誤。
- 原生 10 秒放棄門檻比腳本冷回應（3～16 秒）短，整集 MP4 代理來源可考慮等腳本先回應再判斷。
- 腳本對 bvc2 重複下載 5 次屬腳本問題（不改腳本，記錄給使用者／腳本來源）。

## 沒驗到
- 真機（使用者版本推測 0.1.93 之後，未確認）。Android 上這些 bvc2 集數同樣無法解碼是依編碼推論，沒有實際在 Android 播放。
