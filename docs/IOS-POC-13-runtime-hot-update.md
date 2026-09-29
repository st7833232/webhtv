# IOS-POC-13 — Runtime Hot Update

- 狀態：**程式完成（13A～13D，2026-09-29），尚未發布**。設定 scope 已在模擬器端對端驗證；global 通道要等使用者產生金鑰（第 11.4 節的步驟）並授權發布含公鑰的 IPA 才會生效。使用者已回答第 7 節並核准連續實施（第 7.1 節）。
- 授權：使用者 2026-09-29 說「開始 IOS-POC-13」。依 AGENTS.md §7，這是會新增網路下載、改變安全與啟用行為的 material requirement：實作前要先有本文件的研究、現況複核、方案比較、建議、驗收與回滾，並由使用者核准要做的階段。**不授權**：bump 版本、tag、SideStore release、GitHub Release、發布 IPA。
- 基準：`origin/ios-poc` `5cd44076456d4c0829eb321bbb55513909e8f5f2`（2026-09-29 14:43 fetch，與 HEAD 相同、worktree 乾淨）。
- 依賴的契約：`docs/IOS-POC-12-runtime-architecture-reconciliation.md` 第 1～21 節（Runtime ABI、manifest schema 1、信任、驗證、scope、狀態轉移）。本任務只實作它，不重新設計；要改那份契約時，先改 IOS-POC-12 文件並寫明原因。
- 本文件是 IOS-POC-13 唯一的任務文件；`docs/IOS-POC-12-13-runtime-update-roadmap.md` 是索引。

## 1. 要實現的能力

讓 WebHTV 在**不發新 IPA** 的情況下，更新 spider JavaScript（目前唯一可經 runtime pack 啟用的邏輯型別 `spider.js`），並且：

1. 失敗時一定保留原本可用的版本（上一個世代或內建腳本），不會半套用。
2. 每個設定來源的內容互不外洩，A → B → A 回到 A 自己的版本。
3. App 太舊時清楚顯示「需要較新的 App」，不會和「沒有更新」混在一起。
4. 播放中不會被迫切換腳本。
5. 原生程式、框架、entitlement、`Info.plist`、原生畫面仍然只能經 SideStore 更新。

## 2. 研究（2026-09-29 讀取）

IOS-POC-12 的 R1～R25（TUF、Uptane、Expo、CodePush、Shorebird、minisign、CryptoKit、Apple 的 App Review、W^X、原子寫入、檔案保護、SemVer、protobuf 演進、Sigstore）仍然適用，不重讀。這次只補 12 沒有回答的「何時檢查、何時啟用」：

| # | 來源 | revision | 級 | 支持的論點 | WebHTV 適用性 | 對決策的影響 |
|---|---|---|---|---|---|---|
| U1 | https://github.com/microsoft/react-native-code-push/blob/master/docs/api-js.md | `176121dffb7620026063a8ce6536c9b1c4424836`（已封存） | A | 檢查時機 `ON_APP_START`／`ON_APP_RESUME`／`MANUAL`；安裝時機 `IMMEDIATE`／`ON_NEXT_RESTART`／`ON_NEXT_RESUME`／`ON_NEXT_SUSPEND`＋`minimumBackgroundDuration`；更新綁定 binary 版本 | JS OTA 的標準做法：下載與啟用分開，啟用時機可選 | 採「啟動時檢查＋手動」，啟用與下載分開；不自動重啟 App |
| U2 | https://github.com/expo/expo/blob/main/docs/pages/versions/unversioned/sdk/updates.mdx | `e4a3081ac3f1d24993f12dd74db7a1a86b0371f5` | A | `checkAutomatically` 預設 `ON_LOAD`；`fallbackToCacheTimeout: 0` 表示啟動不等待遠端檢查；下載的更新預設在下次啟動套用，`reloadAsync()` 可立即套用 | 與 IOS-POC-12 R25「啟動不可依賴 updater I/O」一致 | 啟動先用已存的世代（O(1)），檢查在背景；spider 只要重設 session 就能換，不需要重啟整個 App |

本地與相關專案證據：

- Android（`origin/main` `5856232743d2b8ddd5b3730e676b197ff2c0a264`）`app/src/main/java/com/fongmi/android/tv/api/loader/JarLoader.java`：spider JAR 是設定擁有的內容，以 URL 的 md5 快取；換設定時 `clear()` 丟掉所有 loader 與 spider。這是「設定擁有的程式碼、以 session 重設換版」的成熟前例，也是 iOS 以 scope 隔離、以 `SpiderSessionStore.reset()` 啟用的依據。Android 可以執行 DEX，iOS 只能換直譯 JS。
- 本 repo 已有、要沿用而不重寫的做法：`DrpyEngine.download(_:limit:session:)` 的串流大小上限；`URLSession.webHTV` 不用 URLCache；`SpiderPackStore` 的 staging＋讀取時重驗；`SpiderSessionStore.reset()` 只丟參照、不 `destroy()`（IOS-POC-10Z），正在用的 session 不受影響。

不適用或不再搜尋的證據類別：完整 TUF client（12 已判定不採用）；背景下載（`BGTaskScheduler`，WebHTV 不需要在背景更新腳本，超出需求）；論文與部落格（再多來源不會改變「啟動檢查、閒置時啟用」這個決定）。

## 3. 現況複核（`5cd44076`）

| 位置 | 現況 | 對 13 的意義 |
|---|---|---|
| `WebHTVApp.swift` `ConfigView` 的 `.task` | 啟動：`restore` → `adoptCachedSpiderPack`（讀已存的 schema 1 pack）→ `refreshRemote` → `refreshSpiderPack` | 新流程掛在同一處：先載入已存世代、再背景檢查 |
| `WebHTVApp.swift` `refreshSpiderPack` | 下載成功就 `SpiderSessionStore.reset()`＋`rebuildSites()`；失敗只寫狀態字串 | 啟用的形狀已經存在；要加上「播放中不啟用」 |
| `SettingsView` 的 `LabeledContent("Spider 腳本", value: packStatus)` | 唯一的狀態顯示 | 13 的 UI 取代這一列 |
| `CSPSourceResolver.init(registry: .active(), …)` | App 的 11 個呼叫點都是 `CSPSourceResolver(source: source)`，走預設的 `.active()` | **只改一個地方**：預設改成 `.active(for: source)`，所有呼叫點自動套用 scope 與優先順序 |
| `SpiderRegistry.active()` | 內建＋process 全域的 `InstalledSpiderPack`（不分設定，G1） | 改成依 scope 的世代：設定 pack → global pack → 內建 |
| `SpiderRegistry.makeRuntime` | pack 腳本載入失敗時不回退內建（G2） | 加逐 class 回退內建（D9） |
| `SpiderSessionStore.reset()` | 只丟參照 | 啟用新世代時 await 它（G9 的時序） |
| `ConfigView.forget(_:)` | 刪快取與站台記憶 | 同時刪除該設定的 runtime pack 目錄 |
| `SpiderPackStore`（schema 1） | 全域目錄 `Application Support/SpiderPack`，從未在現場使用 | 第 7 節問題 2 |
| `RuntimePackManifest.swift`（IOS-POC-12） | 驗證、相容、世代檢查、狀態轉移都是純邏輯、沒有呼叫者 | 13 只補 I/O 與接線 |

## 4. 方案比較

| 方案 | 內容 | 優點 | 缺點 | 判斷 |
|---|---|---|---|---|
| N0 不做 | 維持 schema 1 相容包 | 沒有新風險 | G1 外洩、沒有真實性、沒有 LKG 與回滾、沒有 UI | 不採用 |
| N1 直接擴充 schema 1 | 在 `SpiderPackStore` 加 scope 與簽章 | 改動看起來少 | 會把兩套格式混在一個 store；IOS-POC-12 已定義 v1，擴充舊格式等於第二套契約 | 不採用 |
| N2 完整 updater（Expo／CodePush 形狀） | 每次回到前景都檢查、背景下載、立即重啟 | 最即時 | 重啟會中斷播放；背景下載超出需求；WebHTV 的內容只有 spider，session 重設就夠 | 不採用 |
| **N3 WebHTV 窄版（建議）** | 依 IOS-POC-12 契約：每個 scope 一個不可變世代目錄＋`state.json`；啟動時選世代（不連網）、背景檢查；驗證全部通過才啟用；沒在播放就立即以 session 重設啟用，播放中延到下次啟動；設定 scope 先做，global 通道等金鑰決定 | 沿用 12 的純邏輯與既有下載、session 做法；每個階段可獨立 revert | 要多一個 store 與一個 updater；global 需要維護者保管私鑰 | **採用** |

## 5. 分階段計畫（N3）

每個階段一個 task guard session、一個 commit，可獨立 revert。

| 階段 | 內容 | 修改檔案（預估） | 使用者可見變化 | 預估（本 agent 實際時間） |
|---|---|---|---|---|
| **13A** 世代儲存與啟動選擇 | `RuntimePackStore`（actor）：`Application Support/RuntimePacks/<scope.storageName>/` 下的 `state.json`（原子寫入、`completeUntilFirstUserAuthentication`、不排除備份）與 `generations/<id>/`（排除備份）；安裝＝staging → `verifyGeneration` → 同一 volume 內 rename → 更新狀態；啟動選擇：重驗 active（manifest digest、檔案 hash、相容、global 簽章與撤銷）→ LKG → 內建；只保留 active＋1 個 LKG；清掉殘留 staging；刪除 scope。`SpiderRegistry.active(for:)` 的優先順序與逐 class 回退內建。沒有網路 | `RuntimePackStore.swift`（新）、`SpiderRegistry.swift`、`CSPSourceResolver.swift`、測試 | 沒有（還沒有任何 pack） | 1.5～2 小時 |
| **13B** 設定 scope 的 updater | `RuntimePackUpdater`：以不用 URLCache、較長逾時的專用 session 抓設定旁的 `./runtime/manifest.json`（沿用 `DrpyEngine.download` 的串流上限）→ `RuntimePackValidator.validate` → admission → 下載 `blobs/sha256/<hex>`（讀到宣告的 bytes 就停）→ 每支 `spider.js` 在拋棄式 JSContext 編譯並確認有匯出（smoke）→ 安裝 → 啟用（沒在播放時 await `SpiderSessionStore.reset()`＋重建站台；播放中延到下次啟動）；`forget` 刪 scope；發布工具 `scripts/runtime_pack.py build/verify` | `RuntimePackUpdater.swift`（新）、`WebHTVApp.swift`（啟動與 forget 接線）、`scripts/runtime_pack.py`（新）、測試 | 只有設定作者發布 runtime pack 時才有：spider 不經 IPA 更新 | 2～3 小時 |
| **13C** 設定頁 UI | 「執行期更新」區塊：App 版本與 build、Runtime ABI、目前設定與 global 的 pack 版本／序號、上次檢查、更新說明、「檢查更新」按鈕；狀態文字分開「已是最新」「需要較新的 App」「更新失敗，仍使用 …」；取代現在的「Spider 腳本」一列 | `WebHTVApp.swift` | 設定頁多一個區塊 | 1～1.5 小時 |
| **13D** global 簽章通道（只有問題 1 選 global 才做） | 產生 Ed25519 金鑰（依問題 1 的保管方式）；公鑰加入 `RuntimeTrustRoot.bundled`；global manifest 位置（WebHTV repo 的固定 release，內容定址 blob）編進 App；`scripts/runtime_pack.py sign`；必要時簽章 workflow | `RuntimePackManifest.swift`、`scripts/runtime_pack.py`、可能新增 workflow | 內建 8 支 spider 可由 WebHTV 遠端更新；**公鑰要隨新 IPA 發布才生效** | 1.5 小時（不含使用者保管金鑰的步驟） |
| **13E** 舊相容包（依問題 2） | 移除 schema 1，或保留並改成逐設定存放 | `SpiderPack.swift`、`SpiderPackTests.swift`、`scripts/spider_pack.py`、`WebHTVApp.swift` | 見問題 2 | 0.5～1 小時 |

合計約 5～8 小時代理時間（13D 另加使用者處理金鑰的時間）。實作期間 `swift test` 與模擬器驗收由我在這台 Mac 上執行；發布前另外問。

## 6. 驗收標準

1. 沒有 pack 時，App 行為與 `0.1.31 (32)` 完全相同（既有 577 個測試全部通過）。
2. 設定發布有效的 runtime pack：啟動後背景下載、驗證、啟用，spider 改用 pack 的腳本（模擬器以本機 HTTPS 伺服器驗證）。
3. 任何一種 IOS-POC-12 第 13 節的拒絕情況：active、LKG、內建都不變，設定頁顯示原因。
4. 離線啟動、404、逾時、半途斷線、檔案被改：都回到上一個可用世代或內建。
5. A → B → A：B 看不到 A 的腳本，切回 A 恢復 A 的世代；遺忘 A 會刪掉 A 的目錄。
6. 播放中不啟用新世代；關閉播放器或下次啟動後才啟用。
7. 降版安裝（裝回舊 IPA）：不相容的世代不被選用、也不被刪除。
8. 載入失敗的 pack 腳本回退內建（逐 class），並把該世代標壞、不再自動重試。
9. 13D（若做）：沒有簽章、簽章錯、金鑰被撤銷、過期的 global manifest 都不採用。

## 7. 待使用者決定

| # | 問題 | 建議 | 影響 |
|---|---|---|---|
| 1 | 發布通道（IOS-POC-12 D13、D3） | 先只做設定 scope（13A～13C），global 通道之後再做 | global 需要維護者長期保管私鑰、定期重簽 `expires`（建議 30 天）；公鑰要隨新 IPA 才生效 |
| 2 | 舊 schema 1 相容包 | 移除（從未在現場使用；新格式完整取代它） | 保留原樣會留下 G1 外洩；保留並改逐設定存放要多維護一套格式 |
| 3 | 檢查與啟用時機 | 啟動時檢查＋手動按鈕；沒在播放就立即啟用，播放中延到下次啟動 | 回到前景也檢查會增加網路請求；只手動則要使用者記得按 |
| 4 | 實施方式 | 13A→13C（＋依問題 1、2 的 13D、13E）連續完成，每階段各自 commit 並 push，發布前再問 | 每階段都停下會多幾次往返 |

### 7.1 使用者的決定（2026-09-29）

1. 發布通道：**設定＋global**；active 私鑰放 GitHub Actions secret 由 CI 簽章，backup 私鑰由使用者離線保管。私鑰的產生與 secret 的設定由使用者親自執行（agent 不經手私鑰、不替使用者設定 secret）；agent 準備工具、workflow，並把使用者提供的**公鑰**嵌進 App。
2. 舊 schema 1 相容包：**移除**。
3. 檢查與啟用：**啟動時檢查＋手動按鈕；沒在播放就立即啟用，播放中延到下次啟動**。實作細節：設定 scope 在「成功從網路載入該設定」時檢查（啟動、切換來源、手動重新整理都算），global 在啟動與手動時檢查。
4. 實施方式：**連續完成**，每階段各自 commit 並 push；bump 版本、tag、發布前再問。

依決定調整的階段順序：13E（移除 schema 1）併入 13A，因為兩者改的是同一條 registry 路徑，分開做要把 registry 接線寫兩次。順序為 13A（儲存、啟動選擇、registry、移除 schema 1）→ 13B（updater、發布工具）→ 13C（UI）→ 13D（global 通道；公鑰等使用者產生後嵌入）。

## 8. 回滾

- 每個階段是一個 commit，`git revert` 即可。13A～13C 在沒有任何 pack 發布時不改變行為。
- 已發布的壞 pack：設定作者（或 global 維護者）發布 `directive: rollbackToBundled`（更大的 `sequence`），不需要新 IPA。
- 使用者端：遺忘並重新加入來源會刪除該設定的 pack 目錄；刪除 App 資料會回到內建。

## 9. 風險

1. 設定 scope 沒有真實性：誰控制設定的主機就控制 pack，與現在的 drpy、Python 腳本相同（IOS-POC-12 第 9 節）。
2. Python spider 可以改寫容器，理論上能竄改 `state.json`（IOS-POC-12 第 9 節第 6 點）；13 不處理。
3. 遠端 JS 仍然沒有 CPU watchdog 與 `host.req` 回應大小上限（D10）；pack 只能取代既有 spider，沒有擴大這個既有面。
4. 真機與 Release build 要等發布授權後才會驗證。

## 10. Recovery anchor

- 目標：依 IOS-POC-12 契約實作 runtime pack 的儲存、下載、驗證、啟用、回滾與 UI，不經 IPA 更新 spider JS。
- 狀態：程式完成並 push（13A `f4bddf64`、13B `bd91108a`、13C `3aa08675`、13D `24f072a8`），未發布、真機未驗證。
- 基準：`5cd44076`。
- 檔案與符號：`RuntimePackStore.swift`（`RuntimePackStore`、`ActiveRuntimePacks`）、`RuntimePackUpdater.swift`（`RuntimePackChannel`、`RuntimePackUpdater`）、`RuntimePackManifest.swift`（`revalidate`、`RuntimeTrustRoot.bundledKeys`、`RuntimePackRejection.errorDescription`）、`SpiderRegistry.active(for:)`、`CSPSourceResolver.init`、`WebHTVApp.swift`（`loadRuntimePacks`、`checkRuntimePack`、`checkRuntimePacksNow`、`runtimeSection`、`PlaybackSession.isOpen`）、`ios/Tools/WebHTVRuntimePack/main.swift`、`.github/workflows/ios-runtime-pack.yml`。
- 驗證：`swift test` 586／586；模擬器 Debug build；模擬器端對端（第 11.3 節）。沒有驗到：播放器開著時延後套用、真機、Release build、GitHub 上實際執行 workflow。
- 下一步（唯一）：公鑰已編進 App、secret 已設定；等使用者把 backup 私鑰移到離線，並決定是否發布含 IOS-POC-12／13 與公鑰的下一版 IPA（要另外授權）；發布後再執行「iOS Runtime Pack (global)」workflow。

## 11. 實作紀錄

### 11.1 13A：世代儲存、啟動選擇、registry 優先順序、移除 schema 1（2026-09-29）

| 檔案 | 變更 |
|---|---|
| `ios/Sources/WebHTVCore/RuntimePackStore.swift`（新） | `RuntimePackStore`（actor）：`state.json`＋不可變的 `generations/<id>/`；`install`（admission → manifest digest → `verifyGeneration` → 每支 `spider.js` 在拋棄式 JSContext 編譯並確認 `module.exports`（smoke）→ staging → 同 volume rename → 原子寫入狀態 → 只留 active＋1 個 LKG）；`load`（重驗 manifest digest、簽章與撤銷、scope、相容、每檔 hash；確定性失敗標壞並退回 LKG，「這個 build 不能跑」只跳過不刪）；`markBad`、`forget`、`removeStaging`。`ActiveRuntimePacks`（registry 同步讀取用的鎖盒）、`RuntimeSpiderPack` |
| `ios/Sources/WebHTVCore/RuntimePackManifest.swift` | `validate` 拆出 `revalidate`（啟動重驗用：不查 origin 與 `expires`）；`RuntimeHost.installed(bundle:)`；新拒絕原因 `scriptDoesNotLoad` |
| `ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift` | `active(for:)`：內建 → global pack → 該設定的 pack，後者優先；pack 別名只指向同一個 pack 帶來的腳本；`Entry.fallback`＝同 class 的內建腳本，pack 的腳本載入失敗時逐 class 回退（D9）；`Source.pack(scope, version:)` |
| `ios/Sources/WebHTVCore/Spider/CSPSourceResolver.swift` | 沒有指定 registry 時用 `.active(for: source)`；App 的 11 個呼叫點不用改 |
| `ios/Sources/WebHTVCore/Spider/SpiderPack.swift`、`ios/Tests/WebHTVCoreTests/SpiderPackTests.swift` | **刪除**（使用者決定移除 schema 1） |
| `ios/WebHTVApp/Sources/WebHTVApp.swift` | 啟動時 `loadRuntimePacks()`：清 staging、清舊 `Application Support/SpiderPack*` 與 `spiderPackURL`、載入 global 與目前設定的 pack；切換到另一個設定時載入它自己的 pack 並重建站台；遺忘來源時刪除它的 pack；移除舊的 `adoptCachedSpiderPack`／`refreshSpiderPack`；設定頁說明拿掉 `./spiders/manifest.json` 那句 |
| `scripts/spider_pack.py` | 只留 `fingerprint`（JAR 來源比對），build／verify 刪除 |
| 測試 | 新增 `RuntimePackStoreTests.swift`（12 個）；`SpiderGoldenTests` 的連網測試改走 runtime pack；`RuntimeABITests` 以 `theNativeScriptsAreTheBundledSDK` 取代 schema 1 對照測試 |
| 文件 | IOS-POC-12（加註 schema 1 已移除）、`IOS_SPIDER_RUNTIME_SPEC.md`、IOS-POC-5O（標為已移除）、roadmap |

使用者可見變化：沒有 runtime pack 時與 `0.1.31 (32)` 相同。schema 1 相容包不再被讀取（從未在現場使用）；設定頁說明少一句。

驗證：`swift test` 577 個全部通過（刪 12 個舊測試、加 12 個新測試）；模擬器 Debug build 成功，`project.pbxproj` 未被改動；`python3 scripts/spider_pack.py fingerprint` 可執行。真機未驗證。

回滾：`git revert` 本 commit（會把 schema 1 相容包加回來）。

下一步：13B（updater、發布工具）。

### 11.2 13B：updater、App 接線、發布工具（2026-09-29）

| 檔案 | 變更 |
|---|---|
| `ios/Sources/WebHTVCore/RuntimePackUpdater.swift`（新） | `RuntimePackChannel`：設定 scope 的 manifest 在設定旁的 `./runtime/manifest.json`，global 在 `https://raw.githubusercontent.com/st7833232/webhtv/ios-poc/runtime/global/manifest.json`（位置不被信任，簽章才被信任），blob 一律是 manifest 旁的 `blobs/sha256/<hex>`。`RuntimePackUpdater.check`：manifest（64 KiB 上限）→ global 另抓 `.sig` → `validate` → admission（相同就是 `upToDate`）→ 每個 blob 以宣告的 bytes 為上限下載 → `store.install`（再驗一次並做 smoke）。結果分成 `noPack`（404 或匯入的設定）、`upToDate`、`installed`、`rejected`、`failed`（網路）。專用 session：ephemeral、不用 URLCache、不帶 cookie、30 秒逾時；串流上限沿用 `DrpyEngine.download` |
| `ios/WebHTVApp/Sources/WebHTVApp.swift` | 啟動：載入已存 pack → `refreshRemote` → 檢查 global；每次成功從網路載入設定（啟動、切換、手動重新整理）就檢查該設定的 pack。`installed` 時：沒有開著的播放器就立即放進 `ActiveRuntimePacks`、重設 spider session、重建站台；播放器開著就不動記憶體（磁碟上已經是 active），下次啟動才用，狀態顯示「新版本下次啟動套用」。`PlaybackSession.isOpen`（`router.sessionActive`）。設定頁說明補上 `./runtime/manifest.json` |
| `ios/Package.swift`、`ios/Tools/WebHTVRuntimePack/main.swift`（新） | 維護者工具 `webhtv-runtime-pack`（`swift run --package-path ios webhtv-runtime-pack`）：`build`（從 spider 目錄產生 `manifest.json` 與 `blobs/sha256/`，自動排除 SDK 腳本，`--alias`、`--sequence` 或 `--after`（前一版＋1）、`--rollback`、`--min-app-build`、`--expires-days`，寫出前先以 App 的 `RuntimePackManifest.decode` 檢查）與 `verify`（以 App 的 `revalidate`＋`verifyGeneration` 驗證整個目錄）。不會連結進 App |
| `ios/Tests/WebHTVCoreTests/RuntimePackUpdaterTests.swift`（新） | 7 個：位置、安裝一次後 up to date、下一版與 LKG、沒有 pack、每種失敗都不動現有世代、網路失敗、只讀自己設定旁的 manifest、global 沒簽章或 key 不在 App 內就拒絕 |

使用者可見變化：設定作者在設定旁發布 runtime pack 時，spider 會在下次成功載入設定後更新；設定頁說明多一句。沒有發布 pack 時與以前相同。

驗證：`swift test` 584 個全部通過；模擬器 Debug build 成功；`webhtv-runtime-pack build`（內建 8 支 spider）後 `verify` 回報 `ok … generation gen-1-6421cc898986ac74`。端對端模擬器驗收排在 13C 之後一起做。真機未驗證。

回滾：`git revert` 本 commit（App 回到只讀已存 pack、不再下載）。

下一步：13C（設定頁 UI）。

### 11.3 13C：設定頁「Spider 腳本更新」與端對端驗收（2026-09-29）

| 檔案 | 變更 |
|---|---|
| `ios/WebHTVApp/Sources/WebHTVApp.swift` | 設定頁新增「Spider 腳本更新」區塊：App 版本（`CFBundleShortVersionString (CFBundleVersion)`）、WebHTV 更新包、此設定的更新包（版本、序號、腳本數＋上次檢查的結果）、上次檢查時間、使用中 pack 的更新說明、「檢查更新」按鈕（檢查 global 與目前設定，進行中停用）；說明文字列出 Runtime ABI。結果文字：已更新／已是最新／尚未發布／這個設定沒有提供／已下載新版本，下次啟動套用／有新版本，需要較新的 App／沒有採用：原因，繼續使用目前的版本／無法檢查（原因），繼續使用目前的版本。移除原本的「Spider 腳本」一列 |
| `ios/Sources/WebHTVCore/RuntimePackManifest.swift` | `RuntimePackRejection` 加上中文 `errorDescription`；「需要較新的 App」只在 `requiresNewerApp` 為真時出現 |
| `ios/Tests/WebHTVCoreTests/RuntimePackManifestTests.swift` | `needingANewerAppReadsDifferentlyFromEveryOtherRefusal` |

模擬器端對端驗收（iPhone 17 Pro 模擬器 iOS 26.3，Debug build，2026-09-29 15:15～15:19）：本機 HTTPS 伺服器（臨時自簽 CA 加入模擬器信任）提供一份兩個站的設定（一個 CMS、一個只有更新包才有的 `csp_RuntimeProbe`）與 `webhtv-runtime-pack build` 產生的 `./runtime/`。

| # | 情境 | 結果 |
|---|---|---|
| 1 | 啟動 | 伺服器依序收到 `wang-movie.json`、`runtime/manifest.json`、`blobs/sha256/313cbca9…`；容器內出現 `RuntimePacks/<scope 雜湊>/state.json` 與 `generations/gen-1-8ab9c5d6…/` |
| 2 | 站台清單 | 出現「E2E 更新包」（class 只存在於 pack）；點進去，分類「來自更新包」、影片「runtime pack OK」，由 pack 的腳本產生 |
| 3 | 設定頁 | App 版本 0.1.31 (32)；WebHTV 更新包「內建腳本；尚未發布」（global manifest 還不存在）；此設定的更新包「e2e-1（序號 1，1 支腳本）；已更新」；更新說明「E2E 測試更新包」 |
| 4 | 發布序號 2，blob 被改一個 byte，按「檢查更新」 | 「e2e-1（序號 1，1 支腳本）；沒有採用：更新包的檔案不完整或內容不符，繼續使用目前的版本」，仍是第一版 |
| 5 | blob 修好後再按一次 | 「e2e-2（序號 2，1 支腳本）；已更新」；`generations/` 保留 gen-1（LKG）與 gen-2；切換站台再切回，分類變成「來自更新包 v2」 |
| 6 | 停掉伺服器後重開 App | 從磁碟載入 gen-2，停在同一個站台，顯示「來自更新包 v2」 |

測試後已還原模擬器上 App 的 `Application Support` 與偏好設定；臨時 CA 的私鑰已刪除，CA 憑證留在這台模擬器的信任清單到 2 天後到期。Debug build 的 `PythonLiveCheck` 會以舊 `wang-movie.json` 對目前設定網址抓 `.py`，伺服器紀錄中的 `/py/*.py` 404 都來自它，與本任務無關。

已知行為：啟用新世代只重設 spider session；畫面上已載入的列表不會自動重抓，下一次載入（切換站台、分類、搜尋、進詳情）才用新腳本。

沒有驗到：播放器開著時的「下次啟動套用」（純 App 邏輯 `PlaybackSession.isOpen`，模擬器上沒有操作）；真機；Release build。

驗證：`swift test` 585 個全部通過；模擬器 Debug build 成功。

下一步：13D（global 簽章通道）。

### 11.4 13D：global 簽章通道（2026-09-29）

| 檔案 | 變更 |
|---|---|
| `ios/Sources/WebHTVCore/RuntimePackManifest.swift` | `RuntimeTrustRoot.bundledKeys`：編進 App 的公鑰清單（base64 的 32 bytes Ed25519 公鑰＋角色）。**目前是空的**，所以任何 global pack 都被拒絕，要等使用者產生金鑰後把公鑰加進來；`Key.publicKey` 改為 public（公鑰，無安全影響） |
| `ios/Tools/WebHTVRuntimePack/main.swift` | `keygen --out DIR`：在本機產生 active／backup 兩組金鑰，私鑰寫成 0600 檔案、不印出、不覆寫既有檔，只印出 keyId 與公鑰；`sign --dir DIR`（`--key FILE` 或環境變數 `WEBHTV_RUNTIME_SIGNING_KEY`）：對 `manifest.json` 原始位元組簽 Ed25519，寫出 `manifest.json.sig`；`verify` 預設使用 App 編進去的公鑰；`build --revoke KEYID`：金鑰外洩時的撤銷 manifest |
| `.github/workflows/ios-runtime-pack.yml`（新） | 只能手動觸發（`workflow_dispatch`）：checkout `ios-poc` → 建工具 → 以 `ios/Sources/WebHTVCore/Resources/Spiders` 產生 global pack 到 `runtime/global/`（序號＝上一版＋1，`expires` 預設 30 天，可選 `min_app_build`、`rollback`）→ 以 secret `WEBHTV_RUNTIME_ACTIVE_KEY` 簽章 → **以這個 ref 的 App 內建公鑰驗證**（公鑰還沒進 App 時這一步必定失敗，什麼都不會發布）→ commit 並 push 到 `ios-poc` |
| `ios/Tests/WebHTVCoreTests/RuntimePackManifestTests.swift` | `everyCompiledInKeyIsAUsableEd25519PublicKey` |

以拋棄式金鑰驗證（驗完即刪）：`keygen` 產生的兩個檔都是 `-rw-------`，第二次執行拒絕覆寫；未簽章的 global pack `verify` 回 `signatureRequired`；簽了但公鑰不在 App 內回 `unknownKey`；加上 `--public-key` 後 `ok`；`--rollback --revoke` 產生的 manifest 帶 `revokeKeyIds` 與 `rollbackToBundled`，可用 backup 金鑰簽章。`swift test` 586 個全部通過；模擬器 Debug build 成功；workflow YAML 以 Ruby 解析通過（沒有 actionlint，GitHub 上未實際執行）。

**要由使用者親自完成的步驟**（agent 不經手私鑰，也不替使用者設定 secret）：

1. 在自己的 Mac 上產生金鑰（放在 repo 以外的位置）：`swift run --package-path ios webhtv-runtime-pack keygen --out ~/webhtv-runtime-keys`
2. 把 active 私鑰放進 GitHub secret：`gh secret set WEBHTV_RUNTIME_ACTIVE_KEY --repo st7833232/webhtv < ~/webhtv-runtime-keys/active.key`
3. `backup.key` 移到離線的地方保管（它是唯一能撤銷 active 金鑰的鑰匙），並從這台 Mac 刪除。
4. 把 `keygen` 印出的兩行 `active …`、`backup …`（只有 keyId 與公鑰）交給 agent，由 agent 加進 `RuntimeTrustRoot.bundledKeys` 並 commit。
5. 公鑰只有在含它的 IPA 發布後才會生效（發布要使用者另外授權）；之後在 GitHub Actions 手動執行「iOS Runtime Pack (global)」發布第一個 global pack。之後每次改了內建 spider，就再執行一次；`expires` 30 天，過期的 manifest 不會被新裝置採用（已在用的不受影響）。

**金鑰狀態（2026-09-29）**：使用者已在自己的 Mac 上執行 `keygen`（私鑰在 `~/webhtv-runtime-keys/`，agent 沒有讀取）。公鑰已編進 `RuntimeTrustRoot.bundledKeys`：active `db8863f2dcd3f4de`（`HrzYhdAPWN7CvbmC36c1hsllrytZyuB9Dr4N06fsDbA=`）、backup `9ed9a5bd0cecd110`（`dAXPtrjfyCzR857Ve1G47AjNO8nzuq9sTbg7ElaMugQ=`）；`everyCompiledInKeyIsAUsableEd25519PublicKey` 釘住這兩個 keyId，確認由公鑰算出的 id 與 `keygen` 印出的一致。步驟 2 已完成：使用者 2026-09-29 以 `gh secret set` 設定 `WEBHTV_RUNTIME_ACTIVE_KEY`（`gh secret list` 顯示建立於 2026-09-29T07:36:03Z；agent 只看名稱，沒有讀取內容）。還沒做：步驟 3（backup 移到離線並從 Mac 刪除）、步驟 5（發布含公鑰的 IPA，之後才第一次執行 workflow——manifest 30 天後過期，太早發布會在 IPA 到達前就過期）。

金鑰外洩時：本機以 `build --scope global --pack-id webhtv.spiders --sequence <任意> --version … --revoke <外洩的 keyId> [--rollback] --out runtime/global` 產生，再 `sign --key backup.key`，commit 到 `ios-poc`；App 之後拒絕外洩的 key，序號下限只重設這一次。之後要換 active 金鑰，需要新的 IPA。

下一步：更新 `docs/current-task-state.md` 與 roadmap，收尾 IOS-POC-13。
