# W-254 ByteVC2（bvc2）播放設計研究

狀態：研究中（只研究與離線實驗，未改 App 程式、鎖檔、二進位）。§1–§3、§5 由 webhtv-dev-claude-dev-2 撰寫；§4（iOS MPV／FFmpeg 建置與整合）由 webhtv-dev-claude-dev 在 W-256 撰寫。使用者 11-09 決定 iOS 先做，Android 暫不做（Manager #6649）。

## Recovery anchor

- 目標：查清 bvc2 是什麼、能不能用現有或可接受授權的解碼器播放，給出 iOS 先行的方案、驗收與回退；Reviewer 核准後由 Manager 交使用者決定是否實作。
- 完成：§1 版本與原始碼、§2 Mac 實解（兩個獨立解碼器逐幀相同）、§3 授權、§5 iOS 評估、§6 建議初稿。
- 未完成：§4（claude-dev，W-256）；§6 的體積與 iPhone 實測數字要等 §4 建置。
- 阻礙：librempeg 原始碼建置（執行其 `configure`）被本機權限分類器拒絕，記為 BLOCKED；改以 Homebrew FFmpeg 9.0.2＋Fraunhofer vvdec 3.2.1 實證，結論不依賴 librempeg 執行檔（見 §2.4）。
- 下一步：claude-dev 在本文件 §4 補上 iOS 建置、體積與真機數字後，一起送 webhtv-dev-codex-reviewer-2 審。

## 結論摘要

1. **bvc2 就是標準 H.266／VVC 位元流，只是 MP4 的 sample entry 換了名字。** 紅果樣本 5056 幀用 FFmpeg 原生 VVC 解碼器與 Fraunhofer vvdec（獨立的標準解碼器）各解一次，**5056／5056 幀逐位元相同**，解碼 0 錯誤。不同處只有容器：sample entry 是 `bvc2`（標準是 `vvc1`／`vvi1`），設定盒是私有的 `bv2C`（標準是 `vvcC`），參數集（SPS／PPS）每個 IDR 前都放在位元流裡。
2. **librempeg 的 `ff_bvc2_decoder` 不是新解碼器**，是把 FFmpeg 的 VVC 解碼器換一個 codec ID 再登記一次，並固定用 4 位元組 NAL 長度、不讀 `bv2C`（`c0984cae71bf1365676497178cde0ac1cab34ff2`、`54e926c86b60a8b44a6a6798b73b9030a18e27be`）。
3. **不需要 librempeg。** 只把 MP4 裡 `bvc2`→`vvc1`、`bv2C`→最小 `vvcC`（4 位元組長度、0 個參數集陣列）＋`free` 補位（大小不變），未修改的 FFmpeg 9.0.2 就能直接播整集、拖曳正常，結果仍與 vvdec 逐位元相同。
4. **授權：librempeg 不能用在 iOS。** librempeg 把 VVC 相關檔案改成 GPLv3+，命令列工具要 `--enable-agpl`；WebHTV iOS 依 IOS-POC-9A 只出 LGPL 的 MPVKit 產品。上游 FFmpeg n8.1.2 的同一批檔案是 LGPL 2.1+，可以用。
5. **iOS：AVPlayer／VideoToolbox 沒有 VVC（iOS 27 SDK 也沒有 VVC codec type），只能走 MPV 軟解。** 現行 iOS FFmpeg n8.1.2 的 libavcodec 用 `--disable-decoders` 白名單，**沒有開 `vvc` 解碼器**，所以要重建 libavcodec（現在 workflow 只重建 libavformat）。效能估計夠：M4 單執行緒 720×1280 約 330 fps，換算 iPhone（含 iOS 16 支援的 A11／A12）720p 單執行緒仍有數倍餘裕；1080p 與耗電要真機量。

## §1 librempeg 版本與 bvc2 解碼器原始碼

### 1.1 使用者說的「8.1」對應哪個版本

| 項目 | 查到的事實（2026-11-09 存取） |
| --- | --- |
| 倉庫 | https://github.com/librempeg/librempeg ，HEAD `e375cbb14fc3ba0ce86703465b441b891270d599`（2026-11-08） |
| tag | 最新 `v0.6.1`（`e33f58af5a1a630c440eae51a69c35f014d0fa04`），另有 `n7.0`、`n6.2-dev`；**沒有 8.1 tag** |
| HEAD 的版本字串 | `RELEASE` = `8.0.git`（`77d80657c4`，2025-08-19「RELEASE: update to 8.0」）；`libavcodec` 63.28.100；`Changelog` 頂端是 `version 9.0` 段落（跟上游 FFmpeg 合併來的） |
| hongguo-drama 固定的版本 | `cb1f8f3eef84999e61b27e2d44664858179bc240`（2026-11-03，`build/ffmpeg/LIBREMPEG-NOTICE.txt`），Manager 提的 cb1f8f3e 就是這個 |
| 本機 iOS FFmpeg | MPVKit 1.0.0 recipe 重建的 **FFmpeg n8.1.2**（`1c2c67c0b9f7f66ab32c19dcf7f227bcd290aa4c`），見 `.github/workflows/ios-ffmpeg-build.yml` |

判斷（推論）：librempeg 沒有任何叫 8.1 的版本；「8.1」最可能是把 iOS 現用的 FFmpeg 8.1（n8.1.2）跟 librempeg 混在一起。對結論沒有影響：bvc2 解碼器 2025-11-27 加入、2026-02-24 修回，之後所有提交（含 cb1f8f3e 與 HEAD）都有；而且 §2 證明根本不需要 librempeg。

### 1.2 bvc2 解碼器的兩個提交

| 提交（完整 ID） | 日期／作者 | 內容 |
| --- | --- | --- |
| `c0984cae71bf1365676497178cde0ac1cab34ff2` avcodec: add BVC2 decoder | 2025-11-27，Paul B Mahol | 13 檔 +99/−4。新增 `AV_CODEC_ID_BVC2`（描述 `byteVC2`，profile 表直接用 `ff_vvc_profiles`）；`isom_tags.c` 把 MP4 標籤 `bvc2` 對到它；`ff_bvc2_decoder` 的 init／decode／flush／close **全部是 `vvc_decode_*`**，`vvc_decode_init` 改成用 `avctx->codec_id` 建 CBS；Makefile 讓 bvc2 編譯同一批 `vvc/*.o`；新增 `cbs_bvc2`，NAL 分割固定 `H2645_FLAG_IS_NALFF`＋`nal_length_size = 4`，不解析 extradata；NAL 標頭、SEI 都照 H.266 處理 |
| `54e926c86b60a8b44a6a6798b73b9030a18e27be` avcodec: add back BVC2 support | 2026-02-24，Paul B Mahol | 上游 FFmpeg 把 `cbs_h2645.c` 拆成各編碼一檔（`76b3b870cd085eebfc5dc4dc96139d19ac349195`）後，把同樣的 `cbs_bvc2_split_fragment` 移到 `cbs_h266.c` 補回 |

證據等級：A（原始碼本身）。結論：bvc2 解碼器＝VVC 解碼器＋「MP4 標籤 bvc2」＋「固定 4 位元組長度、參數集在流內」。librempeg 沒有任何 bvc2 專屬的解碼工具。

### 1.3 參考專案的做法（只看播放架構）

| 專案 | 做法 | 對我們的意義 |
| --- | --- | --- |
| jackotom/hongguo-drama `ccdbc8fec407eb0d2f4f5132a43ee276d36a33eb`（桌面 Electron，GPL-3.0） | 另帶一個 librempeg 執行檔（cb1f8f3e，`--enable-agpl`），**整集下載完**後轉成 H.264（Mac 用 VideoToolbox，其他 x264），單一佇列、解碼與編碼各 2 執行緒；有 H.264／HEVC 可選時優先不轉（`src/native/bytevc2.js`、`docs/issue-119-bytevc2-6.3.md`）。137 秒 1080p 樣本在 Mac arm64 轉換 33.8→15.7 秒 | 證明桌面端「先轉碼再播」可行但要等整集；行動裝置轉碼耗電又慢，我們能直接解就不必轉。它自己的 Android 版明寫「不支持 ByteVC2」（`android/README.md`） |
| zhangbaio/hongguo README | 表格寫 720p 以下是 bytevc2，「需支持 ByteVC2 的播放器（ffmpeg 内置不解 bvc2）」 | 「ffmpeg 不解」只對了一半：FFmpeg 不認 `bvc2` 標籤，但位元流 FFmpeg 的 VVC 解碼器能解（§2） |
| guoapp、hongguoTV、Veyra、qist/tvbox | 未取得原始碼／不在本輪範圍；只看播放架構的要求下，hongguo-drama 已足以回答「轉碼 vs 直解」 | 不影響決定；如 Reviewer 要求再補 |

不採用任何取源、簽章或存取控制繞過；紅果腳本與解密都沒碰（樣本是 claude-dev 用現行腳本取得並解密的成品）。

## §2 Mac 實證：bvc2 是不是標準 VVC

證據都在 `.herdr-synapse/webhtv-dev/artifacts/w254/exp/`（樣本與取樣腳本在上一層，由 claude-dev 提供，#6647）。

### 2.1 樣本

- `hg-zhuangqiong-ep1-bvc2-decrypted.mp4`：「裝窮提親，娶到全家嫌棄的她」第 1 集，6.66 MB，168.55 秒，720×1280、30 fps、5056 幀；音訊 HE-AACv2。同一部第 2、3、5、6、7、11 集也是 bvc2。
- Homebrew `ffprobe` 9.0.2：`codec_name=unknown`、`codec_tag_string=bvc2` → 未修改的 FFmpeg 不認識這個標籤，所以 AVPlayer、MPV、ExoPlayer 都播不了（W-252 的現象）。

### 2.2 容器與位元流（`bvc2_probe.py` → `probe.txt`）

- sample entry `bvc2`（665 bytes），子盒：`bv2C` 445 bytes、`fiel`、`pasp`、`free`、`btrt`。
- `bv2C` 是私有格式：開頭 `01 07 42 …`，後面有和 vvcC／hvcC 類似的參數集陣列（例如 `8f 0001 0111` 後接 273 bytes 的 SPS，內容與流內 SPS 相同），但標頭排法不是 `vvcC`，所以單純把 `bv2C` 改名成 `vvcC` 會被 FFmpeg 拒絕（實測 `Invalid data found`）。
- 5056 個 sample 全部可用 4 位元組長度切開，0 個格式錯誤；每個 NAL 的 forbidden_zero_bit=0、layer 0，類型都是合法 VVC 類型：SPS 40、PPS 280、PREFIX_SEI 40、IDR_W_RADL 40、TRAIL 5016。每個 IDR 前都有 SPS／PPS（參數集在流內）。
- SEI 是 user_data_unregistered，內含編碼器字串 `BVC2-v1.3.4.8`（字節跳動自家 VVC 編碼器的版本）。
- 解碼器報告：profile **Main 10**、level_idc 105、輸出 yuv420p（8 bit）。

### 2.3 兩個獨立解碼器逐幀比對

把位元流轉成 Annex B（`ep1.266`，只把 4 位元組長度換成起始碼，不動任何 NAL）：

| 解碼器 | 結果 |
| --- | --- |
| FFmpeg 9.0.2 原生 `vvc`（`-xerror`） | 5056 幀，0 錯誤（`decode-err.txt` 空） |
| Fraunhofer **vvdec 3.2.1**（Homebrew bottle，H.266 的獨立實作） | 5056 幀 |
| 逐幀 MD5（`ep1-std-vvc.framemd5` vs `ep1-vvdec.framemd5`） | **5056／5056 完全相同** |

畫面抽查（`frame-1..4.png`，第 0／1500／3000／5055 幀）：人物、字幕清楚，沒有花屏或色偏。

結論（已驗證）：bvc2 的位元流是標準 H.266／VVC；兩個互不相干的標準解碼器結果逐位元一致。

### 2.4 不改 FFmpeg、只改容器就能播（`bvc2_retag.py`）

在原檔上就地改寫（總大小不變，不動 stco 偏移）：sample entry `bvc2`→`vvc1`；`bv2C`（453 bytes）→ 14 bytes 的最小 `vvcC`（version/flags 0，`0xFE`＝lengthSizeMinusOne 3、無 PTL，0 個陣列）＋439 bytes `free`。

- 未修改的 FFmpeg 9.0.2 直接開 MP4：`codec_name=vvc`，解出 5056 幀，與 vvdec **逐位元相同**（`retag.framemd5`）。
- 拖曳：`-ss 120` 直接取到第 120 秒畫面（`seek-120s.png`），正常。
- 這也說明 FFmpeg 的 VVC 解碼器只需要知道「4 位元組長度、參數集在流內」，和 librempeg `cbs_bvc2` 做的事一樣。FFmpeg n8.1.2 `libavformat/mov.c` 的 `mov_read_glbl` 對 `vvcC` 會跳過 4 bytes 再整段當 extradata，所以最小 vvcC 對應的 extradata 就是 `FE 00`。

librempeg 本身沒有實跑（建置被拒，見 Recovery anchor）。這不影響結論：§1.2 證明 librempeg 的 bvc2 路徑就是同一個 VVC 解碼器，§2.3 用兩個獨立解碼器證明位元流標準且結果一致。

### 2.5 解碼速度（Apple M4 10 核，arm64，`speed-mac-m4.txt`）

| 情境 | 時間（168.55 秒內容） | 約當 |
| --- | --- | --- |
| Annex B，1 執行緒 | 14.58 s | 347 fps，11.6 倍即時 |
| Annex B，10 執行緒 | 4.43 s | 1141 fps |
| 改標籤後的 MP4，1／2／4 執行緒 | 15.30／14.73／18.20 s | 330／343／278 fps |

720p 這種小畫面多執行緒幫助有限（Mac 上結果也不穩定）；真機要量 `threads=auto` 與 1080p。

## §3 授權

| 元件 | 授權（存取 2026-11-09） | 對 iOS IPA |
| --- | --- | --- |
| librempeg 整體 | `LICENSE.md`：大部分檔案 **GPLv3+**，「In combination the GPL v3+ applies」；`--enable-agpl` 時變 AGPLv3+ | **不可用**：IOS-POC-9A 規定 iOS 只出 LGPL 的 MPVKit 產品（`docs/IOS-POC-17I-mpv-resize-libmpv.md` 已以同理否決 GPL fork 二進位）。GPL 與 App Store 條款的相容性長期有爭議 |
| librempeg 的 VVC 相關檔案 | `libavcodec/vvc/dec.c`、`vvc/ctu.c`、`h2645_parse.c`、`libavformat/isom_tags.c`：**GPLv3+**；`cbs_h266.c`、`aarch64/vvc/inter.S`：LGPL 2.1+ | bvc2 兩個提交改到的 dec.c、isom_tags.c 在 librempeg 是 GPLv3，**不能把那兩個提交直接搬進我們的 LGPL build** |
| librempeg 命令列工具 | 需 `--enable-agpl`（hongguo-drama 的 NOTICE） | 與 App 無關（我們不出命令列工具） |
| 上游 FFmpeg n8.1.2 同一批檔案 | `vvc/dec.c`、`vvc/ctu.c`、`cbs_h266.c`、`h2645_parse.c`、`isom_tags.c`：**LGPL 2.1+** | **可用**，和現行 iOS FFmpeg 授權相同 |
| Fraunhofer vvdec | BSD-3-Clause-Clear（含專利不授權條款） | 只拿來做驗證，不出貨 |
| hongguo-drama | GPL-3.0 | 只參考架構，不複製程式碼 |

專利（提醒，不是法律意見）：H.266 有專利池（Access Advance、Via LA）。iOS 現有 FFmpeg 已帶 HEVC 等軟體解碼器，加 VVC 軟體解碼器屬同一類風險；是否接受由使用者決定。

建議做法：用上游 LGPL 的 FFmpeg VVC 解碼器，`bvc2` 的對應由我們自己寫（§2.4 證明只要「標籤對到 VVC＋4 位元組長度」），不搬 librempeg 的 GPLv3 程式碼。

## §4 iOS 建置與整合（W-256，claude-dev 撰寫）

（待補：libavcodec 加 `--enable-decoder=vvc` 的重建方式與 provenance、libavformat 對 `bvc2` 的處理方式、IPA 體積增加、iPhone 真機 fps／耗電、播放器選擇與各功能不退化的驗證。）

## §5 iOS 可行性評估

### 5.1 平台限制

- **AVPlayer 不行**：iOS 27 SDK 的 `CoreMedia/CMFormatDescription.h` 與 VideoToolbox 標頭沒有任何 VVC／H.266 codec type（有 `hvc1`、`vp09`、`av01`）。原生播放器不可能播 bvc2，也沒有硬體解碼。
- **MPV 可以，但要換 FFmpeg 設定**：iOS MPV 用 WebHTV 自建的 FFmpeg n8.1.2（`.github/workflows/ios-ffmpeg-build.yml`，只重建 libavformat，其他函式庫用 MPVKit 1.0.0 的二進位）。實際 libavcodec 的設定字串是 `--disable-decoders` 加白名單（有 h264、hevc、av1、vp9…），**沒有 `vvc`**。要播 bvc2 必須重建 libavcodec 打開 `vvc` 解碼器（`vvc_decoder_select` 的 cabac、cbs_h266、golomb、videodsp、vvc_sei 會一起進來），再加上 `bvc2` 標籤處理（§5.2）。
- MPV 的 `hwdec=auto-safe`（`ios/WebHTVApp/Sources/MPVEngine.swift:517`）遇到 VideoToolbox 不支援的編碼會自動用軟體解，不需要改 MPV 設定。

### 5.2 `bvc2` 標籤由誰處理（給 §4 選）

| 方案 | 做法 | 優點 | 缺點 |
| --- | --- | --- | --- |
| A 不處理 | 維持現況（W-253 只讓它快一點顯示無法播放） | 零風險 | bvc2 集數永遠不能播 |
| B 搬 librempeg | 引入 `c0984cae…`、`54e926c8…` 或整個 librempeg | 和 hongguo-drama 同源 | **GPLv3，違反 IOS-POC-9A**；整個換 fork 還會帶進大量無關變更。否決 |
| C FFmpeg 層對應（建議） | 自寫小 patch：libavformat 把 MP4 標籤 `bvc2` 對到 `AV_CODEC_ID_VVC`，忽略 `bv2C`、給最小 extradata（`FE 00`，表示 4 位元組長度）；libavcodec 打開 `vvc` | LGPL；所有來源（代理、直連、下載、HLS fMP4）一體適用；workflow 本來就在重建並 patch libavformat | 要重建並出新 libavcodec（體積、provenance 檢查都要更新）；要寫 FATE 式的小測試 |
| D 代理改寫 | `SpiderProxyServer` 已持有整集 `200 video/mp4`（`rangedMP4`），回應前就地改寫 moov 的那 453 bytes（§2.4 的做法） | 不動 libavformat | 只涵蓋整集經代理的來源；仍要重建 libavcodec；把容器知識放進 App 層 |

### 5.3 自動判斷與播放器選擇（不影響既有功能）

- 判斷依據：MP4 `moov/trak/mdia/minf/stbl/stsd` 第一個 sample entry 的 fourcc。`bvc2`（以及 `vvc1`／`vvi1`）→ 直接用 MPV，不先試原生 10 秒（現在 `WebHTVApp.swift:7073` 那段 10 秒換手）。整集經代理的來源，代理第一次拿到檔案時就看得到 moov，成本是一次掃描。
- 其他編碼完全照舊；判斷只影響「第一個選哪個播放器」，播放中進度、拖曳、暫停、倍速、自動下一集、預緩衝、畫質選擇、離線下載都由 MPV 既有路徑處理（MPV 本來就是原生失敗後的備援，這些功能已在 MPV 上運作）。§4 驗收要逐項在 bvc2 集數上重測。

### 5.4 效能與耗電（推估，未在 iPhone 量）

- M4 單執行緒 720×1280 約 330 fps（§2.5）。以 Geekbench 6 單核比例粗估：A15～A18 約為 M4 的 60～90%，iOS 16 最低支援的 A11／A12 約 35～45%。→ 720p 單執行緒約 115～300 fps，30 fps 播放、2 倍速（60 fps）都有餘裕。
- 1080p 像素是 720p 的 2.25 倍：A11／A12 單執行緒約 50～65 fps，2 倍速會吃緊，要靠多執行緒；新機沒問題。
- 軟解比硬解耗電、發熱；連播短劇要量 10 分鐘以上的電量與溫度。紅果目前看到的 bvc2 都是 720p（同一部的 1080p 檔就是同一個 720 檔，W-252）。

### 5.5 體積

未量（librempeg 建置被拒，Homebrew dylib 已 strip 無法分符號）。§4 重建 libavcodec 時直接比較前後 IPA／framework 大小。

## §6 方案比較與建議（初稿，§4 補數字後定稿）

| 方案 | 能播 bvc2 | 授權 | 改動 | 建議 |
| --- | --- | --- | --- | --- |
| 不改 | 否 | — | 0 | 不建議（使用者明確要能播） |
| 原封搬 librempeg | 是 | GPLv3／AGPL，違反 IOS-POC-9A | 換整個 FFmpeg 來源 | 否決 |
| hongguo-drama 式先轉碼 | 是，但要等整集轉完 | 要帶編碼器；行動裝置慢且耗電 | 大 | 不建議（能直接解就不轉） |
| **上游 FFmpeg VVC＋自寫 `bvc2` 對應（5.2 C）＋MP4 編碼判斷直接走 MPV（5.3）** | 是，邊下邊播 | LGPL 2.1+ | 重建 libavcodec（開 vvc）＋libavformat 小 patch＋App 播放器選擇 | **建議** |

驗收（實作時）：
1. 單元／FATE 式測試：`bvc2` 樣本經我們的 libavformat 開檔得到 `vvc`，解碼幀 MD5 與本研究的 `ep1-vvdec.framemd5` 相同。
2. iPhone 真機（SideStore IPA，不直接安裝）：紅果 bvc2 集數起播、拖曳、暫停、2 倍速、自動下一集、預緩衝、離線下載後播放全部正常；同一部的 H.264 集數照舊走原生。
3. 真機量 720p（有 1080p 樣本時也量）fps、掉幀、10 分鐘電量與溫度。
4. 一般 H.264／HEVC 片源的起播時間、播放器選擇不變。

回退：iOS FFmpeg 是 GitHub release 資產，鎖在 `third_party/mpv-ios-lock.json`；回退＝把鎖檔指回現行 release（libavformat、libavcodec 各自的 checksum），App 層的編碼判斷可單獨 revert（判斷不到就回到現在的原生→MPV 流程）。

預估（Claude 執行時間，不含 GitHub Actions 排隊）：libavformat patch＋測試約 1.5 小時；workflow 改成同時重建 libavcodec 並更新 provenance 約 2 小時＋建置 1～2 輪各約 40 分鐘；App 判斷＋測試約 1.5 小時；真機驗收依使用者時間。詳細由 §4 定。

## 證據表

| 來源 | 版本／提交 | 存取 | 等級 | 支持的主張 | 對決定的影響 |
| --- | --- | --- | --- | --- | --- |
| librempeg 原始碼 | `c0984cae71bf1365676497178cde0ac1cab34ff2`、`54e926c86b60a8b44a6a6798b73b9030a18e27be`、`cb1f8f3eef84999e61b27e2d44664858179bc240`、HEAD `e375cbb14fc3ba0ce86703465b441b891270d599` | 2026-11-09 | A | bvc2 解碼器＝VVC 解碼器＋標籤＋固定 4 位元組長度；GPLv3 檔頭 | 不需搬 librempeg；不能搬 |
| FFmpeg n8.1.2 原始碼 | `1c2c67c0b9f7f66ab32c19dcf7f227bcd290aa4c` | 2026-11-09 | A | VVC 相關檔 LGPL 2.1+；`mov_read_glbl` 的 vvcC 處理 | 方案 C 授權可行 |
| 本機實驗 | FFmpeg 9.0.2、vvdec 3.2.1、樣本 ep1 | 2026-11-09 | A（可重現） | 標準 VVC、逐幀相同、改標籤即可播、M4 fps | 核心結論 |
| iOS 27 SDK 標頭 | Xcode 27.0.0 | 2026-11-09 | A | 無 VVC codec type | AVPlayer 不可行 |
| iOS libavcodec 設定字串 | MPVKit 1.0.0 Libavcodec（DerivedData Release-iphoneos） | 2026-11-09 | A | 沒有 `vvc` 解碼器 | 必須重建 libavcodec |
| jackotom/hongguo-drama | `ccdbc8fec407eb0d2f4f5132a43ee276d36a33eb` | 2026-11-09 | B | 桌面轉碼架構、Android 不支援、轉碼耗時 | 不採轉碼 |
| zhangbaio/hongguo README | GitHub code search 摘要 | 2026-11-09 | C | 低畫質為 bytevc2 | 只作旁證 |
| 規格與專利 | ITU-T H.266／ISO/IEC 14496-15（VVC in ISOBMFF）未全文重讀 | — | — | 以兩個標準解碼器一致作為實證替代 | 不影響結論；如 Reviewer 要求再補 |

## 歷程

- 2026-11-09 11:36 開工（attempt 2），依 Manager #6633 分工、#6649 改 iOS 先行。
- 11:40 librempeg 原始碼與版本查證；11:41 `configure` 被權限分類器拒絕（BLOCKED，不繞過）。
- 11:41～11:55 樣本解析、兩解碼器逐幀比對、改標籤直接播、速度量測。
- 12:00 起撰寫本文件 §1–§3、§5、§6 初稿。
