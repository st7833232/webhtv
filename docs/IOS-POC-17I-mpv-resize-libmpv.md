# IOS-POC-17I — MPV 旋轉根治：自建含 resize 修正的 Libmpv

- 狀態：**17I-1 實作中**（2026-09-25）。使用者核准方案 E 與 17I-1，授權 notice 選「repo 先補，App 畫面另開任務」。workflow、patch、lock、notice 已寫好；等 CI 建置、比對與發布（第十二節）。17I-2、17I-3 尚未開始，各需另外核准。
- 使用者需求（2026-09-25，`0.1.18 (19)` 真機）：「MPV 螢幕直立橫向切換，畫面會短暫的跑版，然後恢復正常」。使用者在選擇題中選了「根本解法：自建 libmpv」，而不是「重建期間短暫蓋黑」的緩解做法。
- 同一次回報的另一個問題（解除子母畫面時放大、進度往回），使用者決定「先不改，等有模擬器你再修改」，記錄在 `docs/IOS-POC-17H-mpv-picture-in-picture.md` 的「真機回報：解除子母畫面時放大、進度往回」一節，不在本任務範圍。
- 研究基準：分支 `ios-poc`，HEAD `d960fcdffde7b8d129b79e7e3041d45a1f4d8237`；存取日期 2026-09-25。
- 本任務屬 AGENTS §7／§8：它更換 MPV 的 native 二進位來源與打包方式。核准前不修改程式、lock、workflow 或二進位。

## 一、診斷（2026-09-25，9 個 agent 的 workflow：三條平行診斷、整合、四個反駁者、補查遺漏）

### 根因（信心：高；兩個反駁者都未能推翻）

1. MPVKit 1.0.0 的 `moltenvk` context（`Sources/BuildScripts/patch/libmpv/0001-player-add-moltenvk-context.patch`）只在 VO 設定時讀一次 `CAMetalLayer.drawableSize`（`moltenvk_reconfig`），`moltenvk_control` 一律回 `VO_NOTIMPL`，從不送出 `VO_EVENT_RESIZE`。
2. 旋轉時 `MPVVideoView.layoutSubviews` 立刻把 Metal view 設成新 bounds。下一幀 MoltenVK 因 `drawableSize` 不等於 bounds × scale 回傳 `VK_SUBOPTIMAL_KHR`；mpv 沒有設定 `allow_suboptimal`，libplacebo 就依新尺寸重建 swapchain，MoltenVK 也把新尺寸寫回 `drawableSize`。
3. mpv 卻仍保留舊方向的 `dwidth/dheight` 與目標矩形，把舊矩形畫進新尺寸的畫布：直轉橫只剩一小條、其餘全黑；橫轉直是放大並被裁切。這正是 17G 文件「修正前重現：影片只剩左上角一小條、其餘全黑」的現象。
4. 17G 的 App 端做法要等 300 ms，再以切換 `vo` 強制重建輸出（新 VO、新 Vulkan 裝置、新 VideoToolbox 解碼器、重新編譯 shader，外加一次從前一個關鍵影格開始的 exact seek）。這段期間錯誤的畫面一直露出，之後才恢復＝「短暫跑版，然後恢復正常」。
5. 暫停時不會畫新影格，舊 drawable 會被 `kCAGravityResize` 拉伸。17G 文件原本的解釋（Core Animation 拉伸）只涵蓋這個暫停情況與第一幀。

### 診斷用到的原始碼

| 來源 | 版本 | 位置 | 結論 |
|---|---|---|---|
| mpvkit/MPVKit | `288527dffbc6d3e63cce147fc7b520c64a791603`（1.0.0） | `patch/libmpv/0001-player-add-moltenvk-context.patch` 的 `moltenvk_reconfig`、`moltenvk_control` | 只在 reconfig 讀尺寸，control 回 `VO_NOTIMPL` |
| mpv-player/mpv | `41f6a645068483470267271e1d09966ca3b9f413`（v0.41.0） | `video/out/vulkan/context.c:418-428、439-448`；`video/out/vo_gpu_next.c:1503-1514、1858-1868`；`player/command.c:7952-7960、8019-8022`；`options/options.c:245-250`；`player/video.c:1193-1196` | 無 `allow_suboptimal`；`dwidth/dheight` 只在 resize 更新；`VO_EVENT_RESIZE` 會觸發 `resize(vo)`；`UPDATE_VO` 會重建並 exact seek；iOS 沒有 `VOCTRL_EXTERNAL_RESIZE` 的觸發選項；reconfig 失敗＝VO 初始化失敗 |
| KhronosGroup/MoltenVK | `db66022459ffb663aa2b50f6b018bc2e124f5edf`（v1.4.2） | `MVKSwapchain.mm:103、122-138、292-296、445-447、498、509、653`；`MVKDevice.mm:1970` | 尺寸不符時回 SUBOPTIMAL；重建 swapchain 時寫回 `drawableSize`；某些情況會寫成 1×1 |
| haasn/libplacebo | `cee9b076f2c63104ccfd497fa79c39a867293ec4`（v7.360.1） | `src/vulkan/swapchain.c:605-612、843-847、1022-1038` | SUBOPTIMAL 時重建 swapchain；尺寸 0 代表不變 |
| WebHTV | `d960fcdffde7b8d129b79e7e3041d45a1f4d8237` | `ios/WebHTVApp/Sources/MPVEngine.swift:225-244`（300 ms settle）、`406-426`（`rebuildVideoOutput`）、`255-264`（`MPVMetalLayer` 擋 1×1） | 17G 的替代寫法 |

## 二、研究：修正從哪裡來（三條唯讀研究線，2026-09-25）

| 證據 | 等級 | 版本 | 發現 | 對決策的影響 |
|---|---|---|---|---|
| mpvkit/MPVKit 1.0.0 之後 | A（原始碼） | tag 仍只有 `1.0.0`；main `2103893078c5e339073b11737b86f7f22b9c4491`、`f82e06d4f5ef4fc4aa9faba3782a462dbbef870c`（FFmpeg 升 n9.0.1，未發版）；moltenvk patch 最後修改 `60a74b338249e783fbdc9fc1de27efc165c757fc`（2025-11-10） | 沒有新 release，上游沒有收進任何 resize 修正，control 仍回 `VO_NOTIMPL` | **升級路線不存在** |
| edde746/MPVKit `e6b129fdd31347b25d5d862f73f52c23f9e55624`（2025-11-28，“fix: resize”；parent `6401bcb8afd2959582eff06f99d055a66442f3ce`） | A | 0001 patch sha256 `b5e6148850eae529f09d70aa8fe82ee5faba00dfa8409f6de56d799be5a75897` | 在 `VOCTRL_CHECK_EVENTS` 讀 `drawableSize`，有變就 `ra_vk_ctx_resize` 並送 `VO_EVENT_RESIZE`；App API 不需改。parent 的 0001 與 1.0.0 逐位元相同，可直接替換；在 mpv v0.41.0 上依序套 edde 的 0001 與上游 0002、0003 均成功 | 修正邏輯可用，但有三個缺點要改（見第四節） |
| edde746/MPVKit 授權與二進位 | A | LGPL→GPL-3.0-only 於 `b9e88e80657ec20ced3993c490d9e08b858d9bff`；nonfree 於 `cddc830affc978e9a0cdf0ed7de057aa4c31c884`（2026-07-05）才移除；tag `7cb0ac1f21fb9168a4e3b2afde7c664d0277ff5d`、`67994daf188eb338f4677395084f77635da58d30`、`2e887368b44ce1dc9e1649e7757ec62c2564e792` | e6b129f 提交時 repo 為 LGPL-3.0，0001 檔頭是 mpv 的 LGPL-2.1+，可移植進我們的 LGPL build；它發的二進位一律 GPL（舊版還帶 nonfree，不可散布），且夾帶 30 多個改變播放行為的 patch；前兩個 tag 的 manifest 網址 404 | **否決直接使用 fork 二進位**（違反 IOS-POC-9A 的 LGPL 決定） |
| starsdaisuki/mpvkit-starplay `fcd71702f6306f652ce3f06f0a9539daa61fe4f1` | B（成熟度低） | 以 1.0.0 為基底 | LGPL、只重編 Libmpv、忽略 ≤1 的尺寸；但 FFmpeg 改用 OpenSSL、拿掉 version3，個人 4 個 commit 的快照 | 證明「只重編 Libmpv」可行；二進位最多拿來做真機 A/B，不當正式依賴 |
| edde746/mpv-build `45f87bb19c62d2f19ae176af03a737953cabe311`、edde746/plezy `e9fa92d056db38fd20b88e5664fd4654c50bc8a5` | B | 2026-09-25 | 同一份 resize 程式碼，GPL；Plezy 的 iOS 用 `vo_avfoundation` | e6b129f 在 iOS 的 moltenvk 路徑很可能沒有上架產品驗證（推論） |
| LemonBuild `655a7fb0bdbd1baba23336e265618b5bc59fc09b`、MazeDev7/MPVKit `29803ccbfa631997d496f34c2c1ed191cc8fd2c3` | C | — | 前者只送 `VO_EVENT_RESIZE`、不重建 swapchain（錯誤示範）；後者是 e6b129f 的副本 | 不採用 |
| mpv master `2a4eb8067ca68ec19adf23daf8ccbb1a05afd6ed` | A | 2026-09-23 | 沒有 iOS／MoltenVK context，只有 macOS 的 `context_mac.m`（在 control 處理 resize，e6b129f 照此寫法） | 上游短期不會提供修法 |
| MPVKit 1.0.0 的建置 | A | release 實際由 `9d057f9c19fa704e242b199d26bc6c5cf23dd5d6` 建置（與 288527df 只差 Package.swift） | 只有 FFmpeg n8.1.2 與 mpv v0.41.0 從原始碼編譯，其他都是下載預編 zip；`FFmpeg-all.zip`（sha256 `edf065ee784591b791afa9d6bbee9106a721966f67b00dd1946d5e1017e08daf`）內的靜態庫與 xcframework 位元組相同 | **可以只換 `Libmpv.xcframework`**，其他二進位維持上游原檔 |
| GitHub runner-images `ebade26c60adcb867918b31c8f8caa37343a3d39`（macos-26 20260907.0351.1） | A | 2026-09-25 | Xcode 26.0.1～26.6、ninja、pkgconf、wget 已預裝；上游當初用 Xcode 15.4／meson 1.4.2 | 可在 macos-26 建置；編譯器版本不同，不影響 C ABI，需以 features 字串與靜態庫成員比對把關 |

- 無法取得：MPVKit issue #3 本輪讀不到（GitHub MCP 只允許本 repo，proxy 對未加入的 repo 回 403），狀態沿用 IOS-POC-17 的紀錄（2024-04 開、2026-09 仍 open），不影響結論。
- 論文與部落格：不適用。這是特定 context 實作的缺陷，決策依據是原始碼。
- 程序註記：兩個研究 agent 各有一次在補登唯讀 `add_repo` 之前，讀了前一輪已 clone 的 repo；內容來源不受影響。

## 三、方案比較

| 方案 | 評估 |
|---|---|
| A 維持現狀（17G） | 每次旋轉都有 300 ms＋重建時間的錯誤畫面與一次 exact seek |
| B 緩解：重建期間蓋黑（診斷 workflow 的建議） | 只改 App；錯誤畫面變成短暫黑畫面，但停頓與 seek 仍在。使用者未選 |
| C 升級 MPVKit | 不存在可升級的版本 |
| D 直接使用 fork 的二進位 | edde746 是 GPL（部分含 nonfree），違反 IOS-POC-9A；starplay 更換 TLS 元件且維護不足 |
| **E 沿用 1.0.0 配方只重建 Libmpv，套改良版 e6b129f（建議）** | 其他二進位全部維持上游原檔；只有 `context_moltenvk` 的行為改變；旋轉不再重建 VO、不再 seek |
| F 改走 OpenGL／render API 路徑 | renderer 大改，iOS 的 OpenGL ES 已棄用；不採用 |

## 四、建議設計（方案 E）

### 1. 改良版 0001 patch（以 e6b129f 為基礎，修正三個缺點）

- 保留 e6b129f 的做法：在 `VOCTRL_CHECK_EVENTS` 讀 `drawableSize`，尺寸改變才呼叫 `ra_vk_ctx_resize` 並設定 `VO_EVENT_RESIZE`，同時更新 `vo->dwidth/dheight`。
- 缺點 (a)：e6b129f 在尺寸 ≤0 時讓 `reconfig` 回傳失敗，會變成 `MPV_ERROR_VO_INIT_FAILED`。改為維持 1.0.0 的行為：尺寸無效時仍回傳成功，沿用目前尺寸。
- 缺點 (b)：MoltenVK 1.4.2 會把 `drawableSize` 寫成 1×1。改為忽略 ≤1 的尺寸（starplay 的做法），App 端的 `MPVMetalLayer` 1×1 防護也保留。
- 缺點 (c)：暫停時 VO 執行緒最長可睡約 1000 秒，只有 redraw 或 control 會叫醒它，所以暫停中旋轉要有一個輕量喚醒。實作時二選一，以原始碼確認後決定：
  - App 端在暫停中更新尺寸後觸發一次不會 seek 的重繪（例如一次不可見的 OSD 更新）；
  - 或在 patch 內觀察 layer 尺寸並呼叫 `vo_wakeup`。

  兩者都不能重建 VO 或 seek，都要真機驗證。
- 從 CAMetalLayer 讀 `drawableSize` 是在 VO 執行緒進行（e6b129f 與 starplay 皆如此），App 在主執行緒寫入；列為風險，以真機驗證。

### 2. 建置（新 workflow，與 App 發版分開）

- 新增 `.github/workflows/ios-libmpv-build.yml`：`workflow_dispatch`、`macos-26`，固定 Xcode 版本，以 `pip install meson==1.4.2` 並檢查版本（腳本找不到 meson 時會自動 `brew install` 最新版）。
- 取 MPVKit `9d057f9c19fa704e242b199d26bc6c5cf23dd5d6` 的建置腳本。只替換 0001 patch，並做一個小改動讓 FFmpeg 改用 1.0.0 的預編 `FFmpeg-all.zip`（pin sha256），不重編。建置 `platform=ios`，不加 `enable-gpl`；可能的話只建裝置 slice。
- 同一個 job 內驗收：
  - enabled-features 與 configuration 字串要和上游 `Libmpv` 逐字相同（只容許 build date 與 `-dirty` 差異）；
  - 靜態庫成員清單相同；
  - 符號差異只在 `context_moltenvk`。
- 產物上傳到 `st7833232/webhtv` 的 GitHub release，tag 不可符合 `ios-v*-b*`（避免觸發 App 發版），例如 `mpvkit-1.0.0-webhtv.1`。一起上傳 build log 與 manifest。
- 預估 CI 時間：只建裝置 slice 約 10～15 分鐘，含模擬器約 15～25 分鐘。

### 3. 來源與授權紀錄

- `third_party/mpv-ios/`：改良版 0001 patch、腳本改動、README、`MANIFEST.sha256`、`licenses/`（格式比照 `third_party/exo-dv5-native/`）。
- `third_party/mpv-ios-lock.json`：記錄以下各項，產物雜湊即 SPM checksum。IOS-POC-9B 取消 lock 的前提（完全使用 SPM 上游二進位）已不再成立，所以恢復 lock。
  - MPVKit 與 mpv 的完整 commit；
  - 上游 0002（`d3bbabb5dc307131a1c21e12265d935d061bd79e5042b5d111793c6a4a6498f9`）、0003（`693e8ace8057ac46c42195949777159c5aa37f9b7ce81f488758481973da9312`）與新 0001 的 sha256；
  - 上游 0001 原檔 sha256 `6f3625c0179f9b5665ab8b8b0d3c01a01e6ea0e67ad3e0e32b24a924c6804c07`；
  - 各依賴 zip 的 sha256；
  - runner image、Xcode 與 meson 版本；
  - 產物 SHA-256。
- 授權：維持 LGPL 的 `MPVKit` product（`-Dgpl=false`，FFmpeg 無 `--enable-gpl`／nonfree）。修改過的 LGPL 程式碼（patch）與建置方式公開在 repo 內。不複製 edde746 改為 GPL 之後的任何腳本，也不使用任何 `-GPL` 檔。
- 既有缺口（本任務發現，不是本任務造成）：IOS-POC-9A 的 L4 要求 notice 隨 App 出貨，App 內也要有看得到的歸屬畫面；目前 repo 與 App 都沒有。見「待你決定」Q2。

### 4. App 端（另一個 commit）

- 新增本地 Swift package `ios/Vendor/MPVKit/`：`Package.swift` 逐字複製 1.0.0，只把 `Libmpv` target 的 url 與 checksum 換成我們的 release 產物；product 名稱 `MPVKit` 與 module 名稱 `Libmpv` 不變（`import Libmpv` 三處不需修改）。
- `project.pbxproj`：MPVKit 從 `XCRemoteSwiftPackageReference` 改為 `XCLocalSwiftPackageReference`；`Package.resolved` 移除 mpvkit 的 pin。App 發版 workflow 不需修改。
- `MPVEngine.swift`：
  - 移除 17G 的 `vo` 交替重建（`rebuildVideoOutput`、`voSpelledWithFallback`、`onResize` 與 300 ms settle）；
  - `layoutSubviews` 在尺寸改變時直接更新 `drawableSize`；
  - 加上暫停中的輕量喚醒（若選 App 端做法）；
  - 保留 `MPVMetalLayer` 的 1×1 防護，以及 PiP 的 software output 切換。PiP 進出各一次的重建與 seek 不受本修正影響。

## 五、分階段

| 階段 | 內容 | 核准 |
|---|---|---|
| 17I-1 | 新 workflow、改良版 patch、腳本改動、lock／manifest／licenses；執行一次產生 `Libmpv.xcframework` 並上傳 release | 需要（會在 repo 發布一個二進位 release） |
| 17I-2 | App 改用本地 package 與新 Libmpv，移除 17G 重建，加暫停喚醒；commit、push | 需要 |
| 17I-3 | 發布新版 App 到 SideStore，真機驗收 | 需要（依「每次發布前先問我」） |

## 六、驗收標準

1. CI 從 MPVKit 1.0.0 配方建出 `Libmpv.xcframework`，只有 0001 patch 不同；features／configuration 字串與上游逐字相同，靜態庫成員相同，符號差異只在 `context_moltenvk`。2026-09-25 使用者核准一個具名例外：`_wcslen`，限定只能由 `filters_f_hwtransfer.c.o` 引用（第十二節 CI 紀錄）。
2. lock 與 manifest 完整記錄來源、patch、依賴 zip、工具鏈與產物 SHA-256，產物 SHA-256 等於 SPM checksum。
3. App 以本地 package 在既有發版 workflow 編譯成功；仍是 LGPL 的 `MPVKit` product。
4. 真機，播放中直轉橫、橫轉直：不再出現一小條或裁切放大的畫面，沒有明顯停頓，也沒有進度跳動。
5. 真機，暫停中直轉橫、橫轉直：旋轉後畫面正確，仍維持暫停。
6. 子母畫面進出、回到前景、背景播放、字幕與 OSD、HDR／Dolby Vision、音軌字幕切換都和修改前相同。

## 七、驗證方式與限制

- 本環境沒有 Swift 與 Xcode：patch 的編譯與二進位驗收在 17I-1 的 CI job 內完成；App 的編譯在既有發版 workflow 內完成。
- 暫停中喚醒、執行緒讀取 `drawableSize`、各機型的實際效果只能由使用者真機驗證。
- 子母畫面的放大問題不在本任務，依使用者決定等有模擬器再處理。

## 八、回滾

- 最快：把 `ios/Vendor/MPVKit/Package.swift` 的 `Libmpv` target 改回上游網址與 checksum `c381ceb4c1504efac12da95293e56585bbeb691634aa64e3a729f517169933ba`（只改一個項目），並恢復 17G 的重建程式。
- 完整：revert 17I-2 的 commit，恢復遠端 MPVKit 1.0.0 與 17G。17I-1 的 workflow 與 release 不影響 App，可以保留或刪除。

## 九、風險

- 編譯器由 Xcode 15.4 變成 26.x：不影響 C ABI，以第六節第 1 條把關。
- 依賴默默變動：腳本會依檔案是否存在自動啟用功能，meson 可能被自動升級；pin 每個 zip 的 SHA-256 並檢查 meson 版本。
- e6b129f 在 iOS moltenvk 路徑缺少上架產品驗證；以真機驗收把關，失敗即回滾。
- 維護：之後若升級 MPVKit，要重新套用並驗證我們的 patch。

## 十、使用者決定（2026-09-25）

- **Q1**：核准方案 E，開始 17I-1（「核准，開始 17I-1」）。
- **Q2**：授權 notice 選「repo 先補，App 畫面另開任務」。17I-1 補齊 `third_party/mpv-ios/licenses/`；App 內的「授權」畫面（IOS-POC-9A L4 的後半）另開任務，不併入 17I-2。

## 十一、預估（本 agent 的執行時間）

| 階段 | 時間 |
|---|---|
| 17I-1 開發（workflow、patch、腳本改動、lock／manifest） | 45～60 分 |
| 17I-1 CI 建置與驗收 | 10～25 分（預留 1～2 次重跑） |
| 17I-2 開發（本地 package、pbxproj、MPVEngine） | 30～45 分 |
| 17I-3 發布 | 約 10 分 |
| **合計** | **約 2～2.5 小時**，不含等你核准與真機測試 |

## 十二、17I-1 實作紀錄（2026-09-25）

### 新增的檔案

| 路徑 | 內容 |
|---|---|
| `third_party/mpv-ios/patches/libmpv/0001-player-add-moltenvk-context.patch` | 取代 MPVKit 同名 patch；只有 `context_moltenvk.m` 不同。sha256 `6a4a83ee98198de00c16d6eb4601b8a3cd03ab87b201fa20980be0f8d719b82f` |
| `third_party/mpv-ios/patches/buildscripts/0001-restore-prebuilt-ffmpeg.patch` | recipe 的 `main.swift` 改用 1.0.0 的 `FFmpeg-all.zip`，不重編 FFmpeg。sha256 `376301f5f42ed082855c3877108e55029f1d25b33f4d7620f721eac592bff942` |
| `third_party/mpv-ios-lock.json` | recipe、mpv、上游與 WebHTV patch、21 個依賴 zip（URL、bytes、sha256）、對照用的上游 `Libmpv.xcframework.zip`、工具鏈、產物 tag；產物雜湊在 CI 發布後補上 |
| `.github/workflows/ios-libmpv-build.yml` | 唯一的建置路徑，唯一讀 lock 的程式 |
| `third_party/mpv-ios/README.md`、`MANIFEST.sha256`、`licenses/` | 來源說明、本目錄檔案雜湊、各元件授權全文 |

### patch 的實際寫法（相對 e6b129f 的修改）

1. **尺寸無效時不讓 VO 失敗**（缺點 a）：`moltenvk_reconfig` 一律回傳 true。
2. **忽略 ≤1 的尺寸**（缺點 b）：`layer_size()` 把 0×0 與 1×1 都讀成 0×0。`ra_vk_ctx_resize()` 收到 0×0 的意思是「沿用目前尺寸」，並回報 swapchain 實際尺寸（libplacebo `src/vulkan/swapchain.c:1022-1040`）。
3. **`vo->dwidth/dheight` 交給 `ra_vk_ctx_resize()` 寫回**：`vo_reconfig` 會先把它們設成影片尺寸，所以 reconfig 每次都呼叫 `ra_vk_ctx_resize()`，尺寸沒變時不會重建 swapchain。e6b129f 是在尺寸沒變時自己寫入 layer 尺寸；改成回報 swapchain 的實際尺寸。
4. **比對的是 layer 尺寸**：只在 layer 尺寸改變時送 `VO_EVENT_RESIZE`，避免 layer 與 swapchain 尺寸長期不同時每一幀都 resize。
5. **暫停中喚醒**（缺點 c）：採用 patch 內做法，實作為 `ra_ctx_fns.wait_events`，把 VO 執行緒每次睡眠限制在 100 ms 以內。以原始碼確認的依據：
   - VO 迴圈每次迭代先送 `VOCTRL_CHECK_EVENTS`，閒置時睡到 `now + 1000 s`，只有 wakeup 會叫醒它（mpv `video/out/vo.c:1141-1215`）。
   - `wait_events` 是 mpv 給 context 的正式掛點（`video/out/gpu/context.h:54-57`），vo_gpu_next 會轉呼叫（`video/out/vo_gpu_next.c:1880-1888`）。
   - `VO_EVENT_RESIZE` 經 `resize(vo)` 設定 `want_redraw`（`vo_gpu_next.c:1481-1490、1864-1865`）。VO 迴圈據此叫醒核心，核心再呼叫 `vo_redraw()`（`player/playloop.c:687-690`），所以暫停中也會重畫，不會 seek。
   - 提早醒來等同一般的 spurious wakeup。唯一會提早叫醒核心的是 `wakeup_on_done` 路徑，核心會用 `vo_still_displaying()` 重新判斷並重新登記（`player/video.c:1174-1176`、`video/out/vo.c:815-824`），欠載判斷也以狀態為準（`player/video.c:1082`）。
   - 沒選 KVO 加 `vo_wakeup`：`CAMetalLayer.drawableSize` 沒有文件保證 KVO 相容。沒選 App 端觸發：需要一個保證叫醒 VO、又不 seek、不重建的 mpv 指令，iOS 沒有對應的 resize 觸發選項（第一節）。
   - 代價：暫停或閒置時 VO 執行緒每秒最多醒來 10 次。每次只處理 dispatch 佇列、讀一次 `drawableSize`，`render_frame` 走快速路徑。播放中每幀間隔都小於 100 ms，不受影響。

### 建置設計的決定

- **工作目錄**：recipe 放在 `/Users/runner/work/MPVKit/MPVKit`，與上游 1.0.0 建置時相同。上游 `Libmpv` 的 `Configuration:` 字串包含 `--cross-file=/Users/runner/work/MPVKit/MPVKit/dist/libmpv/ios/scratch/arm64/crossFile.meson`，放在同一路徑才能逐字比對。
- **runner**：`macos-26`＋`Xcode_26.6`，依設計。上游用的 `macos-14`／Xcode 15.4 仍可用，但 runner-images 公告 2026-11-02 起完全停止支援，之後無法重建，所以不選。
- **meson**：recipe 用自己的 PATH（`BaseBuild.defaultPath`）找 meson，找不到就 `brew install meson` 最新版。workflow 把 venv 內的 meson 1.4.2 連到 `/opt/homebrew/bin`，並用 recipe 的 PATH 檢查版本。
- **依賴**：21 個 zip 的 sha256 於 2026-09-25 下載計算。`FFmpeg-all.zip` 與上游 `Libmpv.xcframework.zip` 和先前紀錄的值相同。workflow 先放好並解壓，recipe 就不會下載；建置後檢查 `dist/` 下沒有未鎖定的 zip，mpv 原始碼 HEAD 必須是 `41f6a645`，而且含我們的 patch。所有 zip 最上層都只有 `include`、`lib`、`pkgconfig-example`。
- **與上游比對**（device slice）：`Configuration:` 與 `List of enabled features:` 字串、靜態庫成員、已定義的外部符號、binary 以外的 framework 檔案都必須相同；未定義符號只能因 `context_moltenvk` 成員而不同；模擬器 slice 比對架構。任一項不同就不發布。
- **觸發條件**：`workflow_dispatch`，另加只在 `third_party/mpv-ios/patches/**` 或 workflow 本身變更時觸發的 push。原因是本 repo 的預設分支 `main` 沒有 iOS workflow，只存在於 `ios-poc` 的 workflow 要先被某個事件觸發、在 repo 登記後，才能手動觸發。`ios-sidestore-release.yml` 也另有 push（tag）條件。這一點依 GitHub 的已知行為推論；本環境的 proxy 擋下 docs.github.com，無法讀文件確認。這不是測試 CI（使用者決定不新增 push 觸發的測試 CI），只在需要重建時執行。
- **發布**：tag 取自 lock 的 `artifact.release_tag`（`mpvkit-1.0.0-webhtv.1`），不符合 `ios-v*-b*`，不會觸發 App 發版；已存在就失敗，不覆蓋已發布的產物。以 prerelease、`--latest=false` 發布，因為 `cnb-release-sync.yml` 沒指定 tag 時會同步 latest release，要避免 libmpv 被當成 App 版本同步出去。附上 build manifest、比對報告與 build log。

### 已完成的驗證（本環境）

1. 新 0001 與上游 0002、0003 依序 `git apply` 到乾淨的 mpv v0.41.0（`41f6a645`）成功，產生的 `context_moltenvk.m` 與預期內容逐字相同。從上游 patch 抽出的原檔 blob hash 與 patch 的 index 行一致（`445b907f`）。
2. 上游三個 patch 的 sha256 與 lock 記錄相同。buildscripts patch 以 `git apply --check` 套用到 MPVKit `9d057f9c` 成功。
3. workflow：YAML 可解析，各 `run` 區塊 `bash -n` 通過，內嵌 Python 可編譯，lock 內兩個 WebHTV patch 的雜湊與檔案相同。
4. 未驗證：C 編譯（本環境沒有 Apple SDK 與 Xcode），以及 CI 內的建置與比對。

### 授權 notice（Q2：repo 先補）

- `third_party/mpv-ios/licenses/` 收錄 57 個上游授權檔，涵蓋 LGPL `MPVKit` product 在 iOS 連結的元件與其內嵌程式碼（對照表在 `third_party/mpv-ios/README.md`）。由背景 agent 依 recipe 與各 `mpvkit/*-build` repo 在 lock 所列 tag 的建置腳本查出來源版本，逐檔以 `cmp` 確認與上游相同；我另以獨立 clone 抽查 4 檔（mpv 的 `LICENSE.LGPL` 與 `Copyright`、libplacebo、MoltenVK），結果相同。
- 從二進位確認（agent 以 `llvm-nm` 檢查 ios-arm64 slice）：FFmpeg configure 沒有 `--enable-gpl`／`--enable-nonfree`；mpv 為 `-Dgpl=false`；lcms2 的 GPL-3.0 plugin 與 libsmbclient 都沒有連結；glslang 的 Bison 產生檔是 GPL-3.0 附 Bison exception。
- **缺口**：
  1. libbluray 1.4.0、內嵌的 libudfread 1.2.0、uchardet 0.0.8 的授權檔沒有收錄。它們的主機（code.videolan.org、gitlab.freedesktop.org）被本環境的對外連線政策擋下。
  2. `Libdovi` 內靜態連結的 Rust 標準庫與 crate 授權沒有收集。
  3. nettle、GMP 取自 GitHub 鏡像；uavs3d 實際建置的 commit 在上游找不到。
  4. agent 的判讀：本 build 的 FFmpeg 是 LGPL v3 以上，gmp／nettle 也可選 LGPLv3。LGPLv3 對 iOS 這類使用者產品的安裝資訊義務，屬法律判斷，列為待確認，沒有結論。
- App 內的授權畫面（IOS-POC-9A L4 的後半）依使用者決定另開任務。

### CI 紀錄

| run | commit | 結果 |
|---|---|---|
| [`36084275635`](https://github.com/st7833232/webhtv/actions/runs/36084275635) | `1fdce318` | 建置成功（`Build Libmpv` 108 秒，含 BuildScripts 編譯與三個 slice）；mpv 原始碼 HEAD 與 patch 檢查通過，21 個依賴 zip 都是鎖定版本。`Configuration:` 與 `List of enabled features:` 字串都和上游逐字相同。**比對步驟失敗、沒有發布**：上游與新產物的 `ios-arm64` binary 都是只含 arm64 的 fat file，`ar` 無法讀取，兩邊成員清單都是空的，判定為不同，步驟就在取出 `context_moltenvk` 成員時中止。是比對腳本的錯，不是產物的差異 |

修正（`IOS-POC-17I-1-compare-fix`）：先以 `lipo -thin arm64` 取出 thin archive，再比成員、符號與字串。另外新增一項檢查：新產物的 `context_moltenvk` 成員必須引用 `_vo_wait_default`，只有 WebHTV 的 `wait_events` 會呼叫它，以此直接證明新 patch 編進了 binary。

| run | commit | 結果 |
|---|---|---|
| [`36084616106`](https://github.com/st7833232/webhtv/actions/runs/36084616106) | `5f6f2edf` | 比對到位：`Configuration:`、features、靜態庫成員、已定義外部符號、binary 以外的 framework 檔案、模擬器架構都與上游相同，新 `context_moltenvk` 引用 `_mp_time_ns`、`_vo_wait_default`（新 patch 確實編入）。**唯一差異**：`context_moltenvk` 以外多了一個未定義符號 `_wcslen`，所以沒有發布。上游 213 個目標檔都不引用任何 `wcs*` 函式；mpv 在 iOS 會編譯的原始碼沒有直接呼叫 `wcslen`（直接呼叫都在 Windows 專用程式碼） |

下一步（`IOS-POC-17I-1-symbol-diag`）：比對報告列出引用這類符號的成員與函式，只作診斷，不改變判定。依結果判斷是新版編譯器把迴圈換成 `wcslen`，還是 SDK 讓某個 config 檢查結果不同，再決定如何處理。

| run | commit | 結果 |
|---|---|---|
| [`36085068570`](https://github.com/st7833232/webhtv/actions/runs/36085068570) | `051d953f` | 比對結果與上一輪相同；診斷指出 `_wcslen` 只由 `filters_f_hwtransfer.c.o` 引用（awk 沒抓到呼叫所在的函式，顯示 unknown） |

`_wcslen` 的來源與判斷：

- 原始碼：mpv `filters/f_hwtransfer.c:333-335` 用迴圈數 `ctx->supported_formats` 的元素個數，直到遇到 0；型別是 `const int *`（`video/hwdec.h:26`）。
- Apple 平台的 `wchar_t` 是 32 位元 `int`，這段迴圈和 `wcslen()` 完全等價。新版編譯器（Xcode 26.6）把它換成一次 `wcslen` 呼叫，上游的 Xcode 15.4 保留迴圈。這是依呼叫位置與迴圈形式所做的推論，沒有查證是哪一版 LLVM 加入這項最佳化。
- 其他都相同：mpv 在 iOS 會編譯的原始碼沒有直接呼叫 `wcslen`，features／configuration 字串相同，代表不是設定或功能差異。`wcslen` 是 iOS 系統內建函式，連結與執行行為不變。
- 使用者決定（2026-09-25，選擇題）：「接受 `_wcslen`」。另外兩個選項是改用 `macos-14`＋Xcode 15.4 重建（該 runner 2026-11-02 起停止支援），以及先停在這裡。
- 實作（`IOS-POC-17I-1-wcslen`）：比對加上具名例外。只有當新產物中引用 `_wcslen` 的成員恰好只有 `filters_f_hwtransfer.c.o` 時才允許，其他任何差異仍會擋下。lock 的 `reference.note` 與 `third_party/mpv-ios/README.md` 同步記錄。

## Recovery anchor

- 目前（2026-09-25）：17I-1 的 workflow、patch、lock、README、notice 已 commit 並 push，由 push 觸發 `iOS libmpv Build`。App 沒有任何修改，仍使用上游 MPVKit 1.0.0 與 17G 的重建。研究產物在本工作階段 scratchpad 的 `research2/`、`research3/`、`p17i/`，不進 repo。
- 下一步（唯一）：看 `iOS libmpv Build` 的結果。通過就把產物 bytes 與 sha256 填進 lock 的 `artifact`，把 CI 結果記到第十二節，再請使用者核准 17I-2；失敗就依 build log 修正後重跑。
