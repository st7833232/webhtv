# IOS-POC-17I — MPV 旋轉根治：自建含 resize 修正的 Libmpv

- 狀態：**設計研究完成，待使用者核准**（2026-09-25）；尚無程式、workflow 或二進位修改。
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

1. CI 從 MPVKit 1.0.0 配方建出 `Libmpv.xcframework`，只有 0001 patch 不同；features／configuration 字串與上游逐字相同，靜態庫成員相同，符號差異只在 `context_moltenvk`。
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

## 十、待你決定

- **Q1**：核准方案 E，並開始 17I-1（新增建置 workflow 與 patch，執行一次並在本 repo 發布 `Libmpv` 二進位 release）？
- **Q2**：授權 notice。IOS-POC-9A 要求 notice 隨 App 出貨、App 內要有歸屬畫面，目前兩者都沒有。
  - 建議：17I-1 先把 repo 內的 notice 與 patch 補齊，App 內的「授權」畫面另開一個小任務；
  - 或者 App 內畫面也併入 17I-2。

## 十一、預估（本 agent 的執行時間）

| 階段 | 時間 |
|---|---|
| 17I-1 開發（workflow、patch、腳本改動、lock／manifest） | 45～60 分 |
| 17I-1 CI 建置與驗收 | 10～25 分（預留 1～2 次重跑） |
| 17I-2 開發（本地 package、pbxproj、MPVEngine） | 30～45 分 |
| 17I-3 發布 | 約 10 分 |
| **合計** | **約 2～2.5 小時**，不含等你核准與真機測試 |

## Recovery anchor

- 目前（2026-09-25）：診斷與設計研究完成，寫入本文件；**未核准、沒有任何程式、workflow 或二進位修改**。研究產物（clone、下載檔）在本工作階段 scratchpad 的 `research2/`、`research3/`，不進 repo。
- 下一步（唯一）：使用者回覆 Q1、Q2 並核准後，開始 17I-1。
