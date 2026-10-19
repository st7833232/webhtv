# W-155：MPV 內嵌 CC 字幕軌與實際解析度 log

> Recovery anchor（2026-10-19 CST）：webhtv-dev-claude-dev-2，guard `W-155`，`--no-tag`。來源：W-149 F-3（MPV 看不到 CEA-608，`cc=0`；原生 `cc=1`）、F-5（MPV 實際解析度沒有 log）。

## 結論

- **F-3：不需要改 mpv 選項。** 工單原本要開 `sub-create-cc-track=yes`。Simulator 第一輪證明它有副作用：**每部影片都多一條空的 CC 軌，而且被選成預設字幕**（沒有字幕的 640x360 測試片也出現「字幕 1 · CC」並被選取；mpv 文件：這個選項只是「對每條視訊流預先建立 CC 軌」，否則在字幕資料出現時才建立）。拿掉選項後第二輪證明：mpv 在 CC 資料出現約 2.7 秒後自己加上 CC 軌（log `cc=0` → `cc=1 codecs=eia_608`），不會自動選取、沒有字幕的片不會出現 CC 軌，選取後畫面正確顯示字幕。所以 W-149 看到的 MPV `cc=0`，最可能是在 CC 資料到達之前就讀了字幕清單（或該串流的 CC 只宣告在 master playlist、片段裡沒有 SEI，原生是從宣告讀到的）——**沒有回頭用那條真實直播重驗**。程式裡只留一行註解說明為什麼不開這個選項，避免之後有人再加。
- **F-5：已做。** `MPV_EVENT_VIDEO_RECONFIG` 時，若尺寸大於 0 且和上次記的不同，記一行 `[playback] mpv video <dwidth>x<dheight> decoded=<video-params/w>x<video-params/h> hls-bitrate=<current-tracks/video/hls-bitrate> video-bitrate=<video-bitrate>`；只有數字，沒有網址；值拿不到時寫 `?`／`n/a`；`FILE_LOADED` 時重置，所以每個檔案開始各記一次，之後只在尺寸改變時再記。

## 改動

| 檔案 | 內容 |
|---|---|
| `ios/WebHTVApp/Sources/MPVEngine.swift` | `loggedVideoSize`（只在 mpv 事件 queue 上讀寫）；`FILE_LOADED` 重置；`VIDEO_RECONFIG` 記一行解析度 log；選項區加註解說明不開 `sub-create-cc-track` 的原因 |

## 驗證

| 項目 | 結果 | 證據（`.herdr-synapse/webhtv-dev/artifacts/`） |
|---|---|---|
| 測試片 | 本機合成：testsrc2 1280x720 H.264（`-bf 0`），自寫腳本把 ATSC A/53「GA94」SEI 的 CEA-608 paint-on 字幕「WEBHTV CC TEST」插進每一幀（`scratchpad/w155_cc/inject_cc.py`），再 `-c copy` 切成 HLS；host 上 `ffmpeg … movie=cc.m3u8[out0+subcc]` 讀出同一段字幕。另有 640x360 無字幕片。不走外網 | `w155-gui-evidence/RESULT.md` |
| Simulator 第一輪（開選項） | CC 軌可選、字幕顯示、解析度 log 正確；**沒有字幕的片也有預設選取的空 CC 軌（FAIL）** | `w155-gui-evidence/RESULT.md` |
| Simulator 第二輪（拿掉選項，最終程式） | CC 片：載入時 `cc=0`，約 2.7 秒後 `cc=1 codecs=eia_608`，不自動選取（`sid=auto`，畫面無字），選取後顯示完整「WEBHTV CC TEST」；無字幕片 25 秒後仍沒有 CC 軌；log 有 `mpv video 1280x720 decoded=1280x720 …` 與 `640x360 decoded=640x360 …`，沒有網址；安裝的是這次 build | `w155-gui-evidence/run2/RESULT.md` |
| 全量 `swift test` | 1331 tests／50 suites，1 個失敗是 5 秒計時測試 `theProbeReadsOnlyTheHeadOfABodyThatNeverEnds`（5.7 秒，當時 load 187），單獨重跑通過；本單只動 App 目標，Core 測試不受影響 | `w155-full.log`、`w155-rerun.log` |
| Ponytail review | Ship（審的是開選項的版本；拿掉選項後只剩註解與 log，沒有新邏輯） | — |

## 未驗證／風險

- 兩個 bitrate 在本機單一變體 HLS 都是 `n/a`（沒有 master playlist、mpv 在 reconfig 當下還沒有估計值）；真實多變體直播是否有值未驗。
- 第一輪「重選 CC 後只剩 WE」沒重現成功（第二輪片子播完），可能是 paint-on 字幕重畫途中切換所致，未查。
- W-149 那條真實直播在 MPV 上是否會自己出現 CC 軌未重驗（省流量）。
- 實機。

## 回滾

一個 commit；`git revert` 只移除解析度 log 與註解。
