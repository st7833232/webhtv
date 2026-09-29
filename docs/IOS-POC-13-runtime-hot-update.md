# IOS-POC-13 — Runtime Hot Update

- 狀態：**實作中**（2026-09-29）。使用者已回答第 7 節並核准連續實施（第 7.1 節）。
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
- 狀態：實作中，見第 11 節的實作紀錄。
- 基準：`5cd44076`。
- 下一步（唯一）：見第 11 節最後一個階段的「下一步」。

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
