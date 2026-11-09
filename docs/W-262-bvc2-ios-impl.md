# W-262 iOS 支援 ByteVC2（bvc2／VVC）影片播放

## Recovery anchor

- 目標：照 docs/W-254-bvc2-decoder.md §6 的三段方案，讓 iOS 能播 bvc2 集數：①FFmpeg 認 bvc2、Libavcodec 開 vvc；②代理讀 MP4 `stsd`，判定 bvc2 直接起 MPV；③驗收。使用者 11-09 選「建置走 GitHub Actions」（Manager #6843）。
- 狀態：完成（reviewer-2 #7062 要求補 Ponytail 與幀 MD5 紀錄，已補）。prerelease `ffmpeg-n8.1.2-webhtv.2`（run 42586264973）已發布並寫進 Package.swift 與鎖檔；Simulator 用 release 檔重播 bvc2 第 1 集（見「驗證」）。
- 分支：task/W-262（自 ios-poc 85688786）。提交：4370b6ca（FFmpeg patch＋workflow＋鎖檔）、d1ced8c0（預審 P1/P2＋下載重試）、f85bd677（ALF 符號）、2f2727a0（pipefail 修正）、a54a11a1（release zip 改帶 token 下載）；App 端、Package.swift 與鎖檔在最後一個提交。
- 下一步：reviewer-2 審最後一個提交；核准後由 Manager 推。

## 改了什麼

### 第一段：FFmpeg（全部在 GitHub Actions 建置）

- `third_party/mpv-ios/patches/ffmpeg/0007-avformat-mov-read-ByteVC2-bvc2-as-VVC.patch`（WebHTV 自寫，LGPL，無 librempeg 程式碼）：
  - `isom_tags.c`：`{ AV_CODEC_ID_VVC, MKTAG('b','v','c','2') }`，排在 `vvc1`／`vvi1` 之後，mov muxer 寫檔仍選標準標籤（reviewer #6728）。
  - `mov.c` `mov_finalize_stsd_codec`：`bvc2` 且沒有 extradata 時，給 2 bytes 最小 vvcC `fe 00`（lengthSizeMinusOne 3、無 PTL、0 個陣列），讓 VVC 解碼器以 4 位元組長度讀樣本、參數集從樣本內取得（`vvi1` 語意）。
  - 本機驗證：0001～0007 依序可套在 n8.1.2 `38b88335f99e76ed89ff3c93f877fdefce736c13`。
- `third_party/mpv-ios/patches/buildscripts/0003-enable-vvc-decoder.patch`：MPVKit `main.swift`（build_commit `9d057f9c19fa704e242b199d26bc6c5cf23dd5d6`）解碼器白名單加 `--enable-decoder=vvc`，接在 0002 之後。
- `.github/workflows/ios-ffmpeg-build.yml`：
  - 套用 0003；檢查 bvc2 patch 與 vvc 參數確實在。
  - 比對擴充：Libavutil 仍須與上游完全重現；Libavformat 與 Libavcodec 的設定字串去掉 ` --enable-decoder=vvc` 後須與上游相同；`config.h` 只允許 `FFMPEG_CONFIGURATION` 與 `CONFIG_VVC_SEI`（0→1）兩行不同。
  - Libavcodec：成員與對外符號不得刪除；新增符號只能是 vvc／h266／executor／`ff_alf_*`（VVC ALF NEON，`libavcodec/aarch64/vvc/alf.S`）；新需要的 `av_`／`ff_` 符號必須在上游 Libavutil 有定義（App 仍用 MPVKit 1.0.0 的 Libavutil）；記錄大小。
  - 發布 Libavformat＋Libavcodec；`workflow_dispatch` 加 `publish` 輸入，可從測試分支發 prerelease；ios-poc push 遇到已存在的 tag 只驗證、不報錯（reviewer 預審 P1）。
  - 相依 zip 下載改 `--retry 5 --retry-delay 15 --retry-all-errors`（兩輪遇到 GitHub 504）。
- `third_party/mpv-ios-lock.json`：0007／0003 雜湊與來源、`reference_avcodec`（MPVKit 1.0.0 Libavcodec，sha256 `136e4329…`）、release tag 升到 `ffmpeg-n8.1.2-webhtv.2`。

### 第二段：App 判斷 bvc2 直接起 MPV

- `ios/Sources/WebHTVCore/MP4SampleEntry.swift`（新）：讀第一個影片軌（`hdlr` = `vide`）的 `stsd` 第一個 sample entry fourcc；`needsMPV` = `bvc2`、`vvc1`、`vvi1`（AVFoundation 沒有 VVC）。只走 box 標頭、不複製內容、尺寸不合即停。
- `ios/Sources/WebHTVCore/Spider/SpiderProxyServer.swift`：腳本回整集 `200 video/mp4` 時（每個檔只解析一次）記下 VVC 的檔；`prefersMPV(url)` 除了 DASH 也對這些檔回 true。既有的 `PlayerRouter.open` → `needsMPV` 就會直接選 MPV（與 DASH 相同，不消耗備援次數）。下一集預熱（W-245）經過代理，所以換集時就知道。
- `ios/WebHTVApp/Sources/WebHTVApp.swift`（起播監看迴圈）：冷啟動時原生已在開，代理一判定是 VVC，就在起播前 `router.select(.mpv, playing: true)`，不等原生 10 秒逾時。
- 與 DASH 相同，選到 MPV 後同一個播放 session 後續集數也留在 MPV（MPV 可播任何格式）；新開的 session 依全域預設，H.264 集數走原生。

## 驗證

- 單元測試：`MP4SampleEntryTests`（影片軌在音訊軌後、moov 在檔尾、avc1／hvc1、空檔、M3U8、截斷、超大 box）、`aWholeByteVC2EpisodeIsMarkedForMPV`（bvc2 標記、avc1 與真 206 不標、同檔改回 H.264 會取消）、`aByteVC2EpisodeTheSharedProxyServedOpensOnMPV`（共用代理標記後 `PlayerRouter.needsMPV` 為 true）；`SpiderProxyServerTests`、`PlaybackEngineTests` 相關套件 89 項全過。
- Simulator（webhtv-w185，iOS 27.0，Debug）：測試來源 `artifacts/w262/kit/`（本機 Python 測試爬蟲，與紅果一樣經 App 代理回整集 MP4；第 1、2 集是 W-254 的 bvc2 樣本，第 3 集是 H.264），預設播放器原生。FFmpeg 用第二輪 CI（run 42571074868）的產物暫時替換本機建置快取（與發布版同一份原始碼；正式版待第四輪）。紀錄 `artifacts/w262/sim-ci42571074868.log`：
  - 冷啟動第 1 集：原生開啟 → 代理取得整集 → `is VVC — moved to MPV before it started` → MPV 0.8 秒起播，`mpv video 720x1280 decoded=720x1280`、`hwdec-current=no`（軟體 VVC），畫面正常。
  - 2 倍速：控制列「2 倍」，12 秒內進度 02:03→02:26。
  - 拖曳：103.1 秒 → 156.7 秒 `seek landed`。
  - 自動下一集：第 1 集 `finished (end)` → 第 2 集（已預熱 `content-warm 第2集 ok`）直接在 MPV 0.54 秒起播、解出 720x1280 → 第 3 集（H.264）照常接續。
  - 非 bvc2 走原路徑：重新打開第 3 集 → `on 原生 … reason=open`，0.79 秒起播。
  - 已判定過的 bvc2：重新打開第 1 集 → 一開就 `on MPV … reason=open`，不經原生。
  - 修正前對照（舊 FFmpeg、新 App）：同樣換到 MPV，但 `Failed to initialize a decoder for codec ''`（只有聲音）。
- 正式 prerelease 檔（`ffmpeg-n8.1.2-webhtv.2`，rebase 到 ios-poc 93cfa38b 之後建置；`strings WebHTVApp.debug.dylib` 有 `--enable-decoder=vvc`）。Simulator webhtv-w185，預設播放器原生。紀錄 `artifacts/w262/sim-release-native-applog.txt`（另有預設 MPV 時的 `sim-release-applog.txt`）、畫面 `ra-play.png`、`rb-play.png`：
  - 經 App 代理（KIT｜bvc2）：第 1 集 `on 原生 … reason=open` → `is VVC — moved to MPV before it started`（0.8 秒內）→ MPV 1.6 秒起播、`decoded=720x1280`；看完自動接第 2 集直接在 MPV 0.4 秒起播。
  - 腳本自有 127.0.0.1 服務、不經代理（KIT｜自有服務，新增在 `kit.json`，模擬新版紅果 PY）：第 1 集 `on 原生` → 原生約 0.2 秒就回 `Operation Stopped` → 失敗換手 MPV，0.74 秒起播、`decoded=720x1280`。也就是 #6969／#6972 說的「原生逾時 → MPV」實測是原生立刻失敗再換手，不必等 10 秒；但這要看原生對該檔的反應，真站沒有 bvc2 可驗。測試伺服器（Python `http.server`）不支援 Range，所以這條路徑 MPV 不能拖曳（`Cannot seek in this stream`）；真站服務若支援 Range 就不受影響，未驗。
- 紅果真站：新版紅果 PY 這部「裝窮提親」的超清／高清／標準在 iOS 都是 H.264，原生 3 秒起播（另由 W-267 量測新版 PY），所以真站沒有 bvc2 可驗。

## 體積

- Libavcodec ios-arm64 靜態庫：10,290,144 → 11,125,784 bytes（+835,640，+8.1%；run 42571074868 的 compare.txt）。新增成員全是 VVC 解碼器（`alf.o cabac.o ctu.o data.o dec.o dsp_init.o dsp.o executor.o filter.o inter_sme2.o inter.o ×2 intra_utils.o intra.o itx_1d.o mvs.o ps.o refs.o sad.o sei.o thread.o`）。
- App 主程式（Release iphoneos，未簽章）：47,952,256 → 48,687,576 bytes（+735,320，+1.5%）；整個 .app 壓縮後 33,740,888 → 34,099,735 bytes（+358,847）。兩次建置都停在連結之後的「Install Python」腳本（未簽章建置），.app 都不含 Python 執行環境，可互相比較（`artifacts/w262/size.txt`）。
- 新 Libavcodec zip 14.1 MB vs 上游 55.7 MB：只建 iOS 平台，App 只用 iOS，不影響。

## CI 與 provenance

| run | 提交 | 結果 |
| --- | --- | --- |
| 42570405987 | 4370b6ca | 下載相依 zip 時 GitHub 504（兩次） |
| 42571074868 | d1ced8c0 | 24 項比對 same，只有 `ff_alf_*_neon` 被判為「vvc 以外」 → f85bd677 |
| 42575749368 | f85bd677 | `grep -v` 無輸出在 pipefail 下中止（腳本錯誤）→ 2f2727a0 |
| 42577645816 | 2f2727a0 | 下載相依 zip 時 GitHub 504（匿名下載被擋）→ a54a11a1 |
| 42586264973 | a54a11a1 | 成功；24 項比對 same、0 different；發布 [ffmpeg-n8.1.2-webhtv.2](https://github.com/st7833232/webhtv/releases/tag/ffmpeg-n8.1.2-webhtv.2)：Libavformat 3,133,564 B sha256 `12e55a65d51ad8d0fe65905a3e505e77def00110efa264c6ecedad79aa309db1`；Libavcodec 14,075,788 B sha256 `5a84e31e068e300ea50f35e023da00a27b8ce203904a861914c22bf5ec4b0079` |

- prerelease 從測試分支 `test/W-262-ffmpeg` 發布；release target 指向該分支提交，請保留該分支（reviewer 預審 P1）。

## Ponytail 審查

已跑 `ponytail:ponytail-review`，範圍 `93cfa38b..e7a22afc`（workflow、patch、`MP4SampleEntry`、代理 VVC 標記、起播監看、Package.swift／鎖檔）。一項發現，已修：

- 代理記錄的整集 MP4 滿 16 部時，只要再收到**同一部**的另一段請求就會整批清空，連帶清掉這部的 VVC 標記；之後同一部不會再讀 `stsd`（大小沒變），重開時就回到「原生 → 逾時／失敗 → MPV」。修正：只有新的一部才清空（`SpiderProxyServer.adapted`，一行）。測試 `theSixteenthEpisodeKeepsItsVVCMarkAcrossItsOwnRanges`：修正前失敗、修正後通過；`SpiderProxyServer`＋`MP4SampleEntry`＋`OfflineLocalProxy` 48/48。
- 其他沒有發現：`MP4SampleEntry` 每一步都檢查邊界；每部只在第一次（或大小改變時）讀；起播監看只在原生、尚未起播、代理判定 VVC 時才換。

## 回退

- FFmpeg：`ios/Vendor/MPVKit/Package.swift` 與鎖檔的 Libavformat／Libavcodec url＋checksum 指回 `ffmpeg-n8.1.2-webhtv.1` 與 MPVKit 1.0.0（各自原值見 git 歷史）。
- App：還原 `SpiderProxyServer.prefersMPV` 與起播監看的那段即回到「原生 10 秒逾時 → MPV」。兩段互不依賴；只回退 FFmpeg 時，bvc2 仍會被送去 MPV，但 MPV 解不出畫面（與現在相同）。

## 沒驗到

- W-254 §6 驗收第 1 項「新 libavformat 開 bvc2 得到 vvc，逐幀 MD5 與 `ep1-vvdec.framemd5` 相同」：沒做。發布的 Libavformat／Libavcodec 只有 iOS 與 iOS Simulator 的 slice，Mac 上不能直接跑 ffmpeg 算 framemd5；本機自建 FFmpeg 的 configure 被權限分類器拒絕（W-256 已記）。替代證據：①patch 0007 做的對應（`bvc2` → VVC、extradata `FE 00`，即最小 `vvcC` 經 `mov_read_glbl` 跳過 4 bytes 後的內容）與 W-254 §2.4 的改標籤實證相同，那次未改的 FFmpeg 解出 5056 幀、與 vvdec 逐位元相同（`artifacts/w254/exp/retag.framemd5`）；改成 `vvi1` 也一樣（`artifacts/w256/vvi1.framemd5`）；②CI compare 24 項 same，Libavcodec 只多 VVC 解碼器成員；③Simulator 用正式檔解出 720x1280、畫面正常（`artifacts/w262/ra-play.png`、`rb-play.png`），拖曳、2 倍速、下一集正常（第二輪 CI 產物）。
- 真機（SideStore IPA）；iPhone 上 VVC 軟解的 fps、耗電（W-254 §4.5 推估）。
- 離線下載後的 bvc2 檔：不經代理，仍走原生 10 秒逾時 → MPV（MPV 能解）。
- 腳本自己開 127.0.0.1 服務、不經 App 代理的來源（新版紅果 PY，W-267；#6969／#6972）：App 讀不到 `stsd`，第一個 bvc2 集數仍走原生 10 秒逾時 → MPV（MPV 能解；Simulator 上原生約 0.2 秒就失敗換手，見「驗證」，但不保證每個檔都這麼快失敗，最壞是原生 10 秒逾時）。改善另開 W-269（127.0.0.1 MP4 先探測前段）。
