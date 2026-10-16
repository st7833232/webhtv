# IOS-POC-61：爬蟲工具與主程式分離（spider decouple）

> Recovery anchor（2026-10-15，W-122 S4）：S1–S3 已審過並推上 origin（最新 `aaa14023`）。S4 在分支 `task/W-122` 實作，Core 驗證完成（見「S4 驗證」），Simulator 證據在 `artifacts/w122-gui-evidence/`。下一步：Reviewer code review，之後 S5 要等 N 版發布與真機確認。

- 編號：工單 W-119 寫的 `IOS-POC-60` 已被 W-40 的 `docs/IOS-POC-60-folder-navigation.md` 用掉，`IOS-POC-59` 預留給直播 L1，所以本任務用 **IOS-POC-61**（Manager #2062）。
- 來源：計畫 `.herdr-synapse/webhtv-dev/artifacts/spider-decouple-plan-2026-10-15.md`（W-118，Reviewer 撰寫），審查預備 `review-prep-W-119-2026-10-15.md`。下面「計畫」各節照搬，只改了：簽章相關段落改成「不做」、33 支（W-105 加了 Sports88）、檔尾第二個「## 10」改成「## 11」。計畫內的 `檔:行` 以 `a0e6991b` 為準；S1 實際改動的位置以本節為準。

## 使用者決定（2026-10-15）與 Manager 拍板

- 使用者：「不簽章，照計畫開工。」問題 1＝1（分兩版）、2＝1（只限手動下載）、3＝2（**不簽章**：固定 HTTPS＋SHA-256＋序號防降級）、4＝1（`ios-poc` 分支、手動 workflow 發布）、5＝1（設定檔相容包保留且優先）、6＝1（逐支判斷）、7＝1（S1→S4 連續做、各自 commit 送審；發 N 版前再問；S5 等 N 版真機確認）。簽章相關（`RuntimeTrustRoot`、Ed25519、sign 子命令）全部不做。
- Manager #2062：
  1. 文件用 IOS-POC-61。
  2. `RuntimePackManifest.File` 新增可選 `minHostApi`，沒寫就以整包的 `requires.abi` 為準；IOS-POC-12 契約在同一個 commit 補一列（§8.1）。
  3. validator 不簽章的改動放在 **S2（W-120）**：global 不要求簽章、信任根可以是空的、`expires` 改成可選、序號下限不可重設、帶 `revokeKeyIds` 一律拒絕。**S1 的 store 完全不呼叫 `authenticate`**。
  4. 發布路徑 `spider-pack/official/`；現有 `spider-pack/manifest.json` 相容包不動。
  5. W-120 的 verify 驗 build 產出的 `spider-pack/official/`。

## S1（W-119）：官方包儲存與 registry 三層順序

### 改動（基準 `b1a2a43e`）

| 檔案 | 內容 |
|---|---|
| `RuntimePackStore.swift`（新） | `OfficialSpiderPack`（世代、版本、scripts、aliases）；`ActiveOfficialPack.shared`：registry 同步讀取用的鎖盒，和相容包的 `InstalledSpiderPack` 分開；`actor RuntimePackStore(root:)`，只做 global scope。目錄：`Application Support/RuntimePacks/<sha256("global")>/{state.json, generations/<id>/, staging-<uuid>/}`。`install`：admission（序號下限、同序號換內容、已標壞）→ manifest SHA-256 → `verifyGeneration` → 每支 JS 編譯 smoke → 寫進 staging（路徑標準化後必須還在 staging 內）→ 同 volume rename 成 `generations/<id>`（已存在就跳過：同 id 同內容）→ `state.json` 以 `.atomic` 寫入，這是唯一的切換點（iOS 加 `completeFileProtectionUntilFirstUserAuthentication`）→ 只留 active＋1 個 LKG。同一包再裝一次是 no-op。`load(host:)`：active → LKG → `nil`（內建）；不連網；確定性失敗（manifest digest、decode、scope、檔案 hash／大小）標壞且永不重試；App 不相容（`requiresNewerApp`、`appBuildTooNew`、`abiMajorMismatch`）只略過，不標壞也不刪。`removeStaging()` 只刪 `staging-*`。**沒有任何簽章檢查** |
| `RuntimePackManifest.swift` | `File.minHostApi: Int?`（可選，≥1，否則 `.malformed("minHostApi")`）；`RuntimePackRejection.scriptDoesNotLoad(String)` |
| `SpiderRegistry.swift` | `Source` 加 `.official(version:)`；新 `bundled(bundle:official:overlaying:)`：內建 → 官方包 → 相容包，逐 class 覆蓋；`active()` 讀兩個鎖盒；原本的 `bundled(bundle:overlaying:)` 轉呼叫新的（官方為 `nil`），行為不變。mappings 只取相容包的 |
| `StorageMaintenance.swift` | `supportKeep` 加 `RuntimePacks`，儲存空間清理不會把官方包列成殘留 |
| `docs/IOS-POC-12-…md` | §8.1 加 `files[].minHostApi` 一列與原因 |

不改 `WebHTVApp.swift`（U3）：還沒有任何呼叫端會 install 或 load，所以使用者可見行為不變。啟動時 load 世代、清 staging 的接線留到 S3／S4。

### 別名規則（A1）

**每一層的別名只指向同一層帶來的 script**：內建的 Swift `aliases` 在載入時展開；官方包的 alias 只在官方包自己帶了目標時才生效；相容包同理（和原本 `case .pack` 的規則相同，改用 `entry.source == source` 判斷）。所以：

- 相容包更新 `JianPian` 但沒宣告 `Jianpian` 別名，而官方包兩者都帶時，`JianPian` 跑相容包、`Jianpian` 跑官方包（測試 `eachLayerOnlyRepointsItsOwnAliases`）。這是三層才會出現的組合，以「各層只認自己的別名」為準。
- **已知缺口（A4）**：官方包（`spider_pack.py` 建出的）沒有 `Jys`／`Short*`／`SportsGuazi` 這些別名，所以官方包更新 `HemaDJ` 時，`ShortHema` 仍然跑內建的 `HemaDJ`。S1 沒有官方包上線，所以不影響使用者；計畫 §6.1 已註明 N+1 版要把別名補進包裡，S2 的 build 工具要處理。

### 簡化（shortcut）

- 某支 `minHostApi` 高於本機 `js.host` minor 時，**那一支連同它的別名直接退回內建**，其他支照用官方包（`RuntimePackStore.assemble` 有 `shortcut:` 註記）。計畫 §5.3 的「先退 LKG 世代的同一支，再退內建」還沒做；S5 移除內建前一定要補，否則那一支會直接消失。
- 某支 JS 編譯不過：install 時整個世代拒絕（smoke），不是逐支退回。執行時的逐支載入失敗不在 S1 範圍。

### S1 驗證

| 項目 | 結果 | 證據（`.herdr-synapse/webhtv-dev/artifacts/w119-logs/`） |
|---|---|---|
| 先紅 | 16 個新測試在 store、`OfficialSpiderPack`、`official:` 參數、`scriptDoesNotLoad` 都不存在時編譯失敗 | `red.log` |
| 後綠 | `RuntimePackStoreTests` 11＋`SpiderRegistryLayerTests` 5＋`StorageMaintenanceTests`＋既有 `SpiderPackTests`，39/39 | `green.log` |
| 涵蓋 | G1 目錄、G2 只有 state.json 能切換、G4 active→LKG→內建、G5 標壞不重試（admission 回 `knownBad`）、R5 不相容只略過不標壞不刪、G6 只留 active＋LKG、G7 降版／序號重用拒絕與同包 no-op、驗不過或編譯不過不寫 state、G8 state 壞掉退內建不刪世代、S1 只刪 staging、R3 逐支 minHostApi、U1 沒有包時和內建逐項相同、R1／R2 三層順序、A2 官方別名、A3 各層別名、R6 mappings、M1 StorageMaintenance | — |
| Mutant | M1 層序對調、M2 minHostApi 不足時整包不用、M3 拿掉別名同層判斷、M5 清 staging 刪全部、M6 prune 不留 LKG、M7 不相容也標壞、M9 拿掉 `RuntimePacks` keep、M10 load 不做 `verifyGeneration`：8/8 變紅（M3 第一次存活，因為舊的 stale alias 案例剛好指向 Kanqiu 本來就跑的 Sports88；改成指向 `AppGet` 後變紅）。全部還原，sha256 一致 | `mutants.txt`、`mut-*.log` |
| 全測試 | `swift test` 1203 tests／43 suites 全部通過（W-40 後 1187＋16） | `full.log` |
| App build | Simulator Debug `** BUILD SUCCEEDED **`（`Source` 加了 case，App 仍能編譯） | `app-build.log` |
| Ponytail | 自審 Ship，沒有 finding（標壞後 LKG 接手、序號下限不可重設、缺檔視為確定性失敗、不相容只略過，都已確認） | — |

沒驗到：檔案保護等級（macOS 測試沒有這個選項，只能讀碼）；平行測試污染（新測試都用注入的 root 與 `bundled(official:overlaying:)`，沒有寫 `.shared`）。

### S1 審查修正（Reviewer F-1，`artifacts/w119-review-2026-10-15.md`）

- 問題：`generations/` 排除備份，`state.json` 會備份。iCloud／電腦備份還原後世代目錄不在，原本的 `load` 把「讀不到檔」當成確定性失敗，active 和 LKG 都被標壞；之後同一版 admission 回 `knownBad`，要等更大的 sequence 才裝得回來。N+1 版沒有內建時，爬蟲會全部消失。Reviewer 的探針 `artifacts/w119-review/probe-restore.log` 證實（bad=[2,1]、重裝丟 knownBad）。
- 修正：`load` 遇到世代目錄或 `manifest.json` 不存在時略過，不標壞；`install` 遇到 `.unchanged`（已接受的同一版）但世代目錄不在時照樣寫回，並把它設為 active。目錄在、檔案 hash 錯，仍然標壞（`anEditedGenerationFallsBackOneStepAndIsNeverRetried` 不變）。
- 測試：`aRestoreWithoutGenerationsMarksNothingBadAndTheSamePackReinstalls`（刪掉 `generations/` → load 回內建、`bad` 是空的、重裝同一包成功、load 回到該版）。先紅：`red-restore.log`（bad 不是空的、重裝丟 `knownBad`），後綠 17/17：`green-restore.log`。
- Mutant：M11 拿掉略過（缺檔又被標壞）、M12 `.unchanged` 一律不寫回，都變紅。全量 `swift test` 1204／43 通過（`full-restore.log`）。
- 非阻擋 N-1（smoke 用 `Int.max` 把本機跑不了的那支也拿去編譯）、N-2（`scriptDoesNotLoad` 不標壞）照 Reviewer 意見留到 S2。

### S1 回滾

一個 commit；`git revert` 會移除 store、`File.minHostApi`、`.official` 來源與 `RuntimePacks` keep。沒有任何呼叫端會建立 `RuntimePacks/`，所以不會留下磁碟狀態。


## S2（W-120）：手動 updater、建包／驗證工具、發布 workflow

接在 W-119 的 `d910cab4` 之後（Manager #2132：前一張送審就接著做）。審查預備 `artifacts/review-prep-W-120-2026-10-15.md`。

### 決定

- **不簽章的驗證**（§0-1、Manager #2062 第 3 點）：新增 `RuntimePackValidator.validateOfficial(manifest:fetchedFrom:host:now:)`，不呼叫 `authenticate`；原本有簽章的 `validate` 和它的測試都不動，日後要加回簽章不必再改契約。`expires` 選填，有寫才檢查；帶 `revokeKeyIds` 一律拒絕；`signer == nil`，所以序號下限不能被重設。IOS-POC-12 §9 第 7 點寫明。
- **「現有包」的定義**（§0-2）：選 (b)。新工具 `scripts/runtime_pack.py verify` 驗的是它自己 build 出的官方格式；舊相容包仍由 `spider_pack.py verify` 驗，結果不變（33 支、0 problem）。
- **發布路徑**（§0-3）：`ios-poc:spider-pack/official/`（`manifest.json`＋`blobs/sha256/<hex>`）；App 編進的網址 `RuntimePackUpdater.manifestURL` 就是這個；`spider-pack/manifest.json` 相容包不動。
- **整包需求**（§0-4、§0-5）：`requires.abi` 的 `js.host` 寫 base（`1.2`，`BASE_HOST_API`），`catvod.result` 寫 `1.0`（爬蟲回傳的 `subs`、`jx`、`vod_tag` 都是加欄位，舊 App 只是忽略）；需要更多的那幾支自己寫 `minHostApi`（`AppDrama`、`Uvod` 3，`Gulu` 4）。
- **App 太舊（逐支保留，P1–P3）**：新世代只放新 manifest 驗得過的檔（P2 的 (a)），`load` 讀到 active 有本機跑不了的 class 時，取 LKG 世代的同一支；LKG 也沒有能跑的就退內建。W-119 的 `shortcut:` 已移除。**P3**：連續兩版都是本機跑不了的版本時，第二版把有舊版的 LKG prune 掉後，那一支退回內建（N 版有內建；S5 移除內建前要再處理）。測試 `aClassThisAppIsTooOldForKeepsTheCopyThatRanBefore` 釘住這兩段。
- **Review N-1／N-2（承 W-119）**：smoke 只編譯本機會跑的 script（用 install 的 `host`）；編譯不過時把那一版記成 bad，下次 check 直接 `knownBad`，不再下載。
- **工具**：Python 寫，和 `spider_pack.py` 並存（K5），讀它的 `DEFAULT_ORIGINS` 與 `NOT_PACKABLE`、讀 `SpiderRegistry.aliases`（`audit_spider_jars.registry_names`），沒有第二份表。**W-119 的 A4 缺口已補**：官方包現在帶 `Jys`、`Short*`、`SportsGuazi` 別名。沒有 `sign`／`keygen`。`build` 是確定性的，既有 blob 不刪。
- **Workflow** `.github/workflows/ios-spider-pack.yml`：只有 `workflow_dispatch`；與 IPA 發布同一個 `concurrency` group；先拒絕不大於已發布的 sequence，再 build＋verify，verify 失敗就不推；`git pull --rebase` 後推 `ios-poc`；不刪舊 blob；commit message 不寫站名。**本單沒有執行，也沒有把官方包 commit 進 repo**：發布要使用者另外授權。

### 改動

| 檔案 | 內容 |
|---|---|
| `RuntimePackUpdater.swift`（新） | `check(host:now:)`，只在被呼叫時執行，沒有排程或重試。非 HTTPS 網址在發出任何請求前就拒絕；manifest 讀取上限 64 KiB、blob 上限是宣告的 `bytes`；串流下載，重新導向離開 HTTPS 就失敗。`.unchanged` 而且世代在磁碟上就回 `.upToDate`，不下載 blob；`Outcome` 分成 `upToDate`／`installed(version, needsNewerApp)`／`rejected`（`requiresNewerApp` 可分辨「要更新 App」）／`failed`（網路） |
| `RuntimePackManifest.swift` | `validateOfficial`、`RuntimeHost.installed()` |
| `RuntimePackStore.swift` | `load` 逐 class 取 LKG；`install(…, host:)`；編譯失敗記成 bad；`has(_:)` |
| `scripts/runtime_pack.py`（新） | `build`／`verify` |
| `.github/workflows/ios-spider-pack.yml`（新） | 見上 |

沒有改 `WebHTVApp.swift`、`ios/Package.swift`、`spider_pack.py`、`spider-pack/`；沒有任何呼叫端會跑 updater（C1）。

### S2 驗證（證據 `.herdr-synapse/webhtv-dev/artifacts/w120-logs/`）

| 項目 | 結果 |
|---|---|
| 先紅 | 把 `RuntimePackUpdater.swift` 暫時移開時，新測試編譯失敗（`cannot find type 'RuntimePackUpdater'`）：`red.log` |
| 後綠 | updater 8＋store＋registry layer＋manifest 測試 55/55：`green.log` |
| updater 涵蓋 | 已是最新只抓 manifest；下一版＋LKG 且 registry 看得到；壞 hash、降級、序號重用、超大 manifest、blob 多 1 byte、HTTP 503、第 2 個 blob 斷線、整包需要較新 App（`requiresNewerApp`）都不動 `state.json`／目錄；逐支保留（含重開 App、P3）；編譯不過不重抓；revokeKeyIds、過期、明文 HTTP（且沒有發出請求） |
| 端到端 | `RUNTIME_PACK_DIR` 指向工具 build 的包：updater → store → registry，`SpiderRegistry.ported` 每個名稱都是官方來源、內容與內建相同：`e2e.log` |
| 工具 | `build` 兩次 `diff -r` 相同；33 支；verify 0 problem；改 1 byte、改名、刪檔各被抓到並 exit 1；`spider_pack.py verify` 舊相容包仍 0 problem：`tool-build.txt`、`tool-verify.txt` |
| Mutant | U1 manifest 不設上限、U2 略過 admission、U3 blob 不設上限、U4 不取 LKG、U5 太新就整包不用、U6 編譯失敗不記 bad、U7 `.unchanged` 照樣下載、U8 拿掉 HTTPS 檢查、U9 允許 revokeKeyIds：9/9 變紅，全部還原：`mutants.txt` |
| 全測試 | `swift test` 1212／44 通過（rollback directive 修正之後重跑）：`full.log` |
| App build | Simulator Debug `** BUILD SUCCEEDED **`：`app-build.log` |
| Ponytail | 自審抓到一處：manifest 帶 `rollbackToBundled` 時 `install` 回 `nil`，updater 會誤報「已是最新」；改成只有沒有 directive 的 `nil` 才是已是最新。其餘 Ship |

沒驗到：真的 GitHub raw 網址（快取時間、重新導向）；workflow 沒有跑過；`expectedContentLength` 和重新導向檢查只讀碼、沒有用假伺服器測（正式下載路徑不經過注入的 fetch）。

### S2 回滾

一個 commit；`git revert` 移除 updater、工具、workflow 與 `validateOfficial`，store 回到 W-119 的行為。workflow 沒跑過，沒有發布物要收回。


## S3（W-121）：設定頁「爬蟲工具」、首頁提示、播放中延後套用

接在 W-120 的 `47c1d023` 之後。審查預備 `artifacts/review-prep-W-121-2026-10-15.md`（下稱 prep）。

### 決定

- **只在使用者按下時連網**（C1–C3）：`RuntimePackUpdater.check` 只在 `ConfigView.checkSpiderTool()` 呼叫，入口只有三個按鈕（設定頁「檢查更新」、首頁橫幅「下載」、全是爬蟲站畫面「下載爬蟲工具」）。啟動只做不連網的 `removeStaging()`＋`load(host:)`＋`ActiveOfficialPack.shared.set`（S1／S2 都還沒接，這是第一次接上）。`.task` 裡既有的相容包 `refreshSpiderPack()` 不動。沒有排程、重試或 `Task.sleep`。
- **prep §0-1（Manager #2112 ①）選 (a)**：`ConfigLoader.validate` 多認一種「只等爬蟲工具的站」（`sitesNeedingSpiderTool` 非空），四條路徑（匯入、遠端、啟動、`rebuildSites`）共用同一個 `validate`，所以一致。全是**未移植** csp 類別的設定仍丟 `.noSupportedSites`，無用的 payload 仍不能取代快取（C24）。`validate` 多一個 `resolvedBy:` 參數（預設 `CSPSourceResolver()`，行為和原本相同），只為了讓測試能注入「什麼都沒有」的 registry。
- **缺爬蟲數 N（prep §0-2，Manager #2112 ②）**：`WebHTVConfig.sitesNeedingSpiderTool(resolvedBy:)`＝`csp_*` 站、類別在 `SpiderRegistry.ported`（含別名）、而且目前 `canResolve` 為 false。未移植類別、drpy、Python 不算，所以 N 版正常狀態 N＝0，0825 這類含大量未移植類別的設定不會出現永久橫幅。N+1 版沒有內建時 `ported` 從哪來，留給 S5。
- **空站台不交給 `HomeView`（prep §0-3，Manager #2112 ③）**：`ConfigView` 新增 `needSpiderTool`，和 `sites` 由同一個 `show(_:from:)` 一起算（三條路徑共用）。`sites` 空且 N＝0 → 原本的「尚未載入設定」畫面（C23，程式沒動）；`sites` 空且 N＞0 → 分頁列照常，首頁分頁換成 `SpiderToolNeededView`（「設定已載入」＋「下載爬蟲工具」），`HomeView` 只在 `sites` 非空時建立，所以 `selectedSite` 的 `sites[0]` 不會遇到空陣列。`SettingsView`（`sites.first`）、`AggregateSearchView`（0 站已有空狀態）、`LibraryView` 對空陣列不會越界。
- **結果文字**（C8）：純函式 `SpiderToolText.result(of:scripts:playing:)`，一個 `Outcome` 對一句（計畫 §2.4，「簽章錯誤」拿掉）。`.sequenceReused`、`.knownBad` 等其他拒絕都歸「更新包驗證失敗，沒有採用，繼續使用目前的版本」；`.rollback` 是「伺服器版本比目前的舊，已忽略」；`requiresNewerApp` 是「這個版本需要較新的 App，請到 SideStore 更新」，和「已是最新版本」不同。為了分出「無法連線」和「下載沒有完成」，updater 的 `Outcome` 加 `unreachable`：**抓 manifest 時**遇到離線、連線被拒、找不到主機、DNS、逾時、TLS 失敗；manifest 之後（blob）的逾時或斷線、HTTP 錯誤仍是 `failed`。「未安裝時：無法連線，請稍後再試」N 版不會出現（一定有內建），`shortcut:` 註記留給 S5。
- **狀態列**（C10）：`內建基準（33 支）`／`官方包 <version>（序號 S，N 支）`；設定檔相容包另一列「設定檔相容包」，沿用原本的說明文字（失敗時的退回字改成「沒有（更新失敗：…）」，因為這一列講的是相容包，不是內建）。內建基準的版本號要等 S4 種子才有。
- **進行中與互斥**（C4–C7）：一個 `spiderToolBusy`（`ConfigView` 的 state）給三個入口共用，下載與重設互斥；updater 本身也把同時兩次 `check` 合成一次（第二個等第一個的結果，只抓一次 manifest）；重設是 store actor 的方法，不會插進 install 中間。下載用的 `Task` 不綁設定頁，離開再回來結果仍在。
- **重設（prep C11）選 (a)**：`RuntimePackStore.reset()` 刪掉整個官方包 scope（世代、LKG、bad、序號下限），registry 退回內建，再按「檢查更新」同一版會真的裝上。序號下限回到 0 是使用者自己按的，可以接受。S4 加種子後「內建基準」就是種子世代，屆時 S4 決定重設後是否立刻重新種子。只動 `RuntimePacks/`，相容包 `SpiderPack/`、設定、記錄、收藏、離線下載都不動（C13）。重設和安裝走同一個套用（C14）。
- **播放中＝`favoriteLibrary.playerOpen`**（C19）：三種播放入口（詳情、離線、inline）都經過 `PlaybackSession.open` 設為 true，`closePlayer` 設回 false。install 照常做完；registry 發布、`SpiderSessionStore.reset()`、`rebuildSites()` 三件事（`applyOfficialPack`）在 `playerOpen` 為 true 時延後，顯示「已下載，關閉播放器後套用」，`onChange(of: playerOpen)` 變 false 時套用（C15、C17）。registry 只在套用時由 `ActiveOfficialPack.shared.set` 換掉，播放中任何新建的 `CSPSourceResolver` 讀到的仍是舊版（C16）；沒有呼叫任何 session 的 `destroy()`（C18）。**限制**：關閉播放器後仍在 PiP 播放時算「不在播放」，會照常套用；PiP 中自動下一集可能用新腳本解析舊集數 id。Simulator 不支援 PiP，只讀程式碼；真機回報前不處理。
- **初始化文字**（C27）：頁尾與第一層確認補上「下載的爬蟲工具也會刪除，回到內建版本」（N 版的真實結果）。
- **W-120 審查 N-3**：`install` 的 `.unchanged` 改用 `has`（看 `manifest.json`）；目錄在、manifest 不在時把舊目錄換掉再寫入。
- **只在 DEBUG 編譯的 GUI 縫**（prep §5.1）：`WEBHTV_RUNTIME_PACK_URL`（App 的 updater 改指本機 HTTPS 伺服器）與 `WEBHTV_HIDE_BUNDLED_SPIDERS=1`（`SpiderRegistry.active()` 拿掉內建層，模擬 N+1 做情境⑦）。兩者都包在 `#if DEBUG`，只讀環境變數，不讀 `UserDefaults`；Release build 的 binary 裡找不到這兩個名稱（見驗證）。
- 沒做：觀看紀錄／收藏打開缺爬蟲站時的「需要爬蟲工具」訊息（計畫 §2.5 最後一句，N 版不會發生，S5 做）；手動「退回上一版」按鈕（計畫已決定不做）。

### 改動

| 檔案 | 內容 |
|---|---|
| `WebHTVApp.swift` | `ConfigView`：官方包狀態、`checkSpiderTool`／`resetSpiderTool`／`loadOfficialPack`／`applyOfficialPack`、`show(_:from:)`、啟動載入、`playerOpen` 觀察、首頁橫幅 `SpiderToolBanner`、全是爬蟲站畫面 `SpiderToolNeededView`、log category `spider-tool`；`SettingsView`：「爬蟲工具」區塊（狀態、設定檔相容包、上次檢查＋結果、檢查更新、重設＋確認），拿掉「Spider 腳本」列與 `./spiders/manifest.json` 那句；初始化文字 |
| `SpiderToolText.swift`（新） | 狀態列與結果文字 |
| `RuntimePackUpdater.swift` | `Outcome.unreachable`；同時兩次 `check` 合成一次 |
| `RuntimePackStore.swift` | `reset()`；N-3 |
| `ConfigLoader.swift`、`WebHTVConfig.swift` | `validate(_:resolvedBy:)` 放寬；`sitesNeedingSpiderTool` |
| `SpiderRegistry.swift` | DEBUG 縫 `WEBHTV_HIDE_BUNDLED_SPIDERS` |
| 測試 | `SpiderToolTests`（新，4）、`RuntimePackUpdaterTests`（+3）、`RuntimePackStoreTests`（+1） |

### S3 驗證（證據 `.herdr-synapse/webhtv-dev/artifacts/w121-logs/`、`w121-gui-evidence/`）

| 項目 | 結果 |
|---|---|
| 先紅 | 新測試在 `SpiderToolText`、`sitesNeedingSpiderTool`、`validate(_:resolvedBy:)`、`.unreachable`、`reset()` 都不存在時編譯失敗：`red.log` |
| 後綠 | `SpiderToolTests`＋`RuntimePackUpdaterTests`＋`RuntimePackStoreTests`＋`ConfigSourceTests` 41/41：`green.log` |
| Mutant | M2 整包需要較新 App 對到「已是最新」、M3 rollback 對到「已更新」、M4 N 改回 `isCSPSpider && !canResolve`、M7 重設只刪世代不刪 state、M8 拿掉同時 check 的合併、M11 拿掉 unreachable 分類、M12 validate 不認只等爬蟲工具的站、M13 N-3 改回看目錄：8/8 變紅，全部還原後 sha256 相同：`mutants.txt`、`mut-*.log`。UI 層的 M1（`.task` 呼叫 updater）、M5（不延後）、M6（關閉後不套用）、M9（空陣列進 HomeView）以 GUI 證據與讀碼代替 |
| 全測試 | `swift test` 1219／45 通過（1212＋7；N-3 測試在其後加入，由 41/41 那輪涵蓋）：`full.log` |
| App build | Simulator Debug `** BUILD SUCCEEDED **`：`app-build.log` |
| Release 縫 | Simulator Release build（`ONLY_ACTIVE_ARCH=YES`；不加會在 Python framework 複製兩種架構那一步失敗，和程式無關）成功；binary 含本版新字串「沒有（更新失敗」，`WEBHTV_RUNTIME_PACK_URL`、`WEBHTV_HIDE_BUNDLED_SPIDERS` 都是 0 筆，Debug dylib 各 1 筆：`release-strings.txt`、`release-build.log` |
| Simulator | iPhone 18 Pro / iOS 27.0（`BC4948DD`），本機 HTTPS 假伺服器（臨時 CA）＋`runtime_pack.py build` 的序號 1–3 包：C23「尚未載入設定」不變、⑦a 全是爬蟲站專屬畫面（分頁列在，下載後站台出現）、⑦b 混合設定橫幅（下載後消失；重設後同一序號真的重裝，C11）、C20 0825 沒有橫幅、① 下載成功（manifest 1＋33 blob）、② 已是最新（只抓 manifest）、③ 壞 blob 驗證失敗、④ 停機「無法連線」且 csp 站仍可用、⑥ 中途斷線「下載沒有完成」（③④⑥ `state.json` 不變、沒有殘留 staging）、⑤ 播放中延後套用（`installed`＝`deferred` → `player closed` → `applied`，延後期間播放持續 01:56→02:03，關閉後不必重開 App；第一輪荐片片源 DNS 解析不到，改用嗶哩重做）、⑧ 重設（data 差異只在 `RuntimePacks/`）、C1 只有按鈕會連網（4 次啟動 0 請求）、C4、C7 都 PASS。C25 第一輪橫幅在最大字級截字，修正（文字可換行、背景改圓角矩形）後複驗 PASS（§5）；最大字級時橫幅約 465pt 高，可用但佔半個畫面，要改成按鈕放文字下方再說。「已下載，關閉播放器後套用」這句出現時播放器蓋住設定頁，只有 log 證據。開 DEBUG 縫時狀態列仍寫「內建基準」，是縫的限制。App／data 還原 BYTE-IDENTICAL；臨時 CA 留在這台 Simulator 的信任清單（私鑰已刪、2 天後過期；移除只能整台 `keychain reset`）。沒驗到：PiP、真機、Release 實際操作、不可路由位址的逾時、有設定檔相容包時的那一列。`artifacts/w121-gui-evidence/RESULT.md`（sha256 `1807d573…`） |
| Ponytail | 審查抓到 2 點並已修：我插入的兩個 struct 把 A13 的文件註解從 `FavoriteUndoBanner` 搶走（移回）；相容包失敗的退回字「內建腳本（更新失敗…）」在新的「設定檔相容包」列下意思不對，而沒有相容包的遠端設定每次都會 404（改「沒有（更新失敗…）」）。其餘 Ship |

### S3 回滾

一個 commit；`git revert` 移除設定頁區塊、橫幅、專屬畫面、延後套用與啟動載入，updater／store／validate 回到 W-120。磁碟上已下載的 `RuntimePacks/` 留著也無害：沒有呼叫端會再讀它，registry 回到「內建＋相容包」。


## S4（W-122）：內建基準種子

接在 W-121 的 `aaa14023` 之後（分支 `task/W-122`，Manager #2186 的新流程）。審查預備 `artifacts/review-prep-W-122-2026-10-15.md`（下稱 prep）。

### 決定

- **何時種子（prep §0-1，Manager #2112 ①）選 (a)**：每次啟動都把內建基準當成一個 candidate，走和下載同一條 `RuntimePackStore.install`（admission → 驗證 → staging → rename → `state.json`）。所以由序號下限決定：空 scope（floor 0）、或新 IPA 的基準序號高於已下載的版本時才寫入；同一個基準再來一次是 `.unchanged`、什麼都不寫；較低的基準丟 `.rollback`、什麼都不動。這樣 IPA 帶來的爬蟲修正不會被較舊的下載版蓋住。「空」不看 `generations/`：rename 後、寫 state 前被殺留下的孤兒目錄，下次照樣種子（同 id 目錄直接沿用）。
- **序號空間（§0-2，Manager #2112 ②）**：基準和官方包同一個序列、同一個下限，下限不可重設（只有使用者按「重設」會清掉）。規則：**每次改內建爬蟲，就用 `runtime_pack.py build` 重建基準，序號加 1，並在 `SpiderBaselineTests.shipped` 加一列**；已發布的序號內容不能變。守門：(1) `theBaselineIsTheBundledScripts`：基準 manifest 的每個檔和 bundle 裡的同名檔 hash、大小相同，檔案集合＝`Resources/Spiders` 扣掉 SDK 3 支，忘了重建就紅；(2) `eachShippedSequenceKeepsItsContent`：序號 → 內容 identity 的凍結表，重建了卻沒升序號就紅；(3) `theBaselineIsAboveAnyPublishedOfficialPack`：repo 裡有已發布的官方包、而且它的**腳本**（每支的路徑、hash、`minHostApi`、別名，不看序號與版本名稱）和基準不同時，基準序號要比它大；腳本相同就通過（官方包本來就是同一份 `Resources/Spiders` 建的，序號比基準大是 workflow 規定的）；(4) workflow 新增一步：要發布的官方包序號必須大於 App 的基準序號，否則已種子的裝置會拒收。
- **`packId`（§0-3，Manager #2112 ③）**：基準 manifest 由同一支工具產生，`packId`＝`webhtv.spiders`，scope global（測試斷言）。
- **內建基準的 manifest（§0-5）選 (a)**：`runtime_pack.py build --sequence 1 --version 2026-10-15.1` 產出的 `manifest.json` 放在 `Resources/SpiderBaseline/`（`Package.swift` 加一行 `.copy`），檔案內容直接讀 bundle 的 `Spiders/`，不另存一份。序號 1，所以第一個發布的官方包至少是 2。`minHostApi`（AppDrama／Uvod 3、Gulu 4）與別名（含 W-120 補上的 `Jys`／`Short*`／`SportsGuazi`）和官方包同一份來源。
- **怎麼分辨種子與下載（§0-4）**：用內容 identity，不用序號。`SpiderBaseline.identity`（只解析 manifest，畫面繪製時不讀 33 支檔）等於 active 的 `contentIdentity` 時，狀態列顯示「內建基準 2026-10-15.1（序號 1，33 支）」，否則「官方包 …」。
- **啟動位置（§0-6）**：`ConfigView.task` 裡 `removeStaging()` 之後、`loadOfficialPack()` 與 `restore()` 之前 `await seedBaseline()`，所以站台清單會等它。每次啟動先只讀、只驗基準 manifest，用 `state()?.admission` 判斷：已種子過（`.unchanged` 而且世代在）直接結束、`.reject` 照丟，只有要寫入時才讀 33 支腳本並經 install 的編譯 smoke。實測（暫存 Simulator，log 毫秒）：重複啟動 43、32 ms（修正前每次讀 33 支，54–343 ms）；全新安裝的第一次 1026 ms（冷啟動、含 33 支編譯），換新基準的那一次也是這個量級，期間畫面是「尚未載入設定」。要完全不擋，可改成先 `restore()`、種子後有寫入才重建站台（要動 `WebHTVApp.swift`，本單沒做，列為後續可選）。
- **失敗（B10）**：任何錯誤只寫 log（「baseline not seeded: …」），registry 照用內建。唯一會標壞的是 install 的 smoke 編譯失敗（W-122 審查 N-1）：那表示內建腳本本身編譯不過，內建層同樣壞掉；下一版 IPA 換了序號就是新的世代 id，所以沒有實際影響。完全不連網（B12）：沒有 updater、沒有 `URLSession`。
- **重設（W-121 留下的問題）**：「重設」清掉 scope 後**立刻重新種子**再套用，狀態回到「內建基準 2026-10-15.1（序號 1）」，和重新啟動一致；之後「檢查更新」較高序號的官方包照樣會裝上（下限回到基準序號）。初始化清掉 Application Support，下次啟動重新種子（B14）。
- **Ikanbot／Djuu（Manager #2249，使用者 15:15）**：第一版官方包不收這兩支，`runtime_pack.py` 會排除（W-41 做）。種子由同一支工具產生，所以也不含；registry 逐 class 疊層，缺的 class 由內建層提供，行為不變。`SpiderBaselineTests.notInBaseline` 要和工具的排除集合一致（目前兩支都還沒進內建，集合是空的），基準 manifest 不必因此重建。
- **S5 退場（B15）**：`SpiderBaseline(bundle:)` 在 bundle 沒有 `SpiderBaseline/manifest.json` 時回 `nil`、種子什麼都不做（`shortcut:` 註記）。S5 待辦：移除基準 manifest 與種子程式；N→N+1 升級者保留 N 版種子出的世代（或之後下載的版本），離線可用；0.1.76 跳版到 N+1 沒有種子，走 S3 的提示。

### 改動

| 檔案 | 內容 |
|---|---|
| `RuntimePackStore.swift` | `SpiderBaseline`（manifest＋candidate＋bundle 檔、`identity`）；`seedBaseline(bundle:host:)`＝把基準交給 `install` |
| `Resources/SpiderBaseline/manifest.json`（新）、`Package.swift` | 基準 manifest，序號 1 |
| `SpiderToolText.swift` | 狀態列用內容 identity 分辨「內建基準」與「官方包」 |
| `WebHTVApp.swift` | 啟動與重設後 `seedBaseline()`，log 種子結果與耗時 |
| `.github/workflows/ios-spider-pack.yml` | 發布序號必須大於 App 的基準序號 |
| 測試 | `SpiderBaselineTests`（新，9）、`SpiderToolTests`（狀態列 +1 斷言） |

### S4 驗證（證據 `.herdr-synapse/webhtv-dev/artifacts/w122-logs/`、`w122-gui-evidence/`）

| 項目 | 結果 |
|---|---|
| 先紅 | 新測試在 `SpiderBaseline`、`seedBaseline`、`status(of:baseline:)` 不存在時編譯失敗：`red.log` |
| 後綠 | `SpiderBaselineTests`＋`SpiderToolTests`＋`RuntimePackStoreTests`＋`RuntimePackUpdaterTests` 42/42（另一輪含 `JianpianAliasTests`、`Sports88SpiderTests` 57/57）：`green.log` |
| 涵蓋 | B1 空 scope 種子、B1(3)／B9 孤兒世代不擋、B2 第二次啟動不寫入（bytes 與 mtime）、B3 已有較新下載時丟 `.rollback` 且 state 不變、B4／B7 內容與 bundle 逐檔相同＋`packId`＋scope、B6 種子後每個 ported 名稱（含別名）腳本與 `bundled()` 相同、B8 序號＋1 取代種子且種子成為 LKG／同序號不同內容 `.sequenceReused`／種子後下限不回退、Manager ① 新基準取代較舊的下載、狀態列 identity 與種子內容一致 |
| Mutant | M1 每次啟動先清掉再種子、M4 基準 `packId` 改掉、M5 序號改 2 但凍結表沒加、M7 改一支內建爬蟲 1 byte 不重建基準、M11 狀態列不分辨基準、M12 `Package.swift` 拿掉 `SpiderBaseline`：6/6 變紅，全部還原後 sha256 相同：`mutants.txt`、`mut-*.log`。prep 的 M2（看目錄判斷空）、M6（先寫 state 再 rename）、M8（失敗標壞）、M9（連網）在這個設計下沒有對應的程式（種子就是 install），不適用 |
| 全測試 | `swift test` 1229／46 通過（1219＋10）：`full.log` |
| App build | Simulator Debug `** BUILD SUCCEEDED **`，`.app` 內有 `WebHTVCore_WebHTVCore.bundle/SpiderBaseline/manifest.json`：`app-build.log` |
| workflow | YAML 解析通過；新步驟沒有執行過（發布要另外授權） |
| Simulator | 暫存 Simulator（同型號，測完刪除，臨時 CA 只加在它上面）＋日常機 `BC4948DD`：① 全新安裝首次啟動種子 275 ms，`state.json` latest＝active＝`gen-1-49b0a7f7…`、`packId` `webhtv.spiders`，種子 33 支與 `.app` 內同名檔 sha256 全同、SDK 3 支不在內，首次啟動時段沒有網路連線，狀態「內建基準 2026-10-15.1（序號 1，33 支）」，荐片分類可載入；② 重複啟動兩次都「baseline unchanged」，`state.json` sha256 與 mtime 不變、沒有 staging；④ 初始化（兩層確認含爬蟲工具那句）後沒有 `RuntimePacks/`，重開重新種子；⑤ 序號 2 官方包取代種子（LKG＝種子），重設後立刻重新種子回「內建基準…序號 1」，再檢查序號 2 真的重裝；③ 升級（S3 build `aaa14023` → 本 build，data 保留）：升級後種子 538 ms，選站 48 個站名集合相同，荐片（別名站）15 部、嗶哩 20 部前後一致（看球前後都是網站 TLS 失敗）。全部 PASS。「unchanged」那條路每次啟動仍讀 33 支檔，實測 54–343 ms，在 store actor 上、不擋畫面。BC4948DD 的 App／data 還原 BYTE-IDENTICAL。沒驗到：真機、檔案保護等級、0.1.76 IPA 原檔升級（以 S3 Simulator build 代替）、真正斷網（只有網路 log 佐證）、種子中途被殺與種子失敗（單元測試涵蓋）。`artifacts/w122-gui-evidence/RESULT.md`（sha256 `b5cf9a67…`） |
| Ponytail | 自審抓到 1 點並已修：`SpiderBaseline.identity` 原本建整個基準（讀 33 支檔＋驗證）只為了取 identity，而它第一次被讀是在畫面繪製時；改成只解析 manifest，另加測試確認兩者一致。其餘 Ship |

### S4 審查修正（`artifacts/w122-review-2026-10-15.md`）

- **F-1**：第 (3) 條守門原本比整份 manifest 的 `contentIdentity`，但它含序號與版本名稱，第一次發布官方包（序號必須大於基準）之後，ios-poc 上每個人的 `swift test` 都會紅。改成比腳本內容，抽成 `baselineKeepsUpWith`，新測試 `thePublishedRuleComparesScriptsNotTheWholeManifest`：已發布序號＝基準＋1、腳本相同 → 通過；改一支 → 不通過。
- **F-2**：`seedBaseline` 先看 admission 再讀腳本（見上「啟動位置」）；`SpiderBaseline.files()` 改成要用時才讀，缺檔直接丟 `fileMissing`。新測試 `aRepeatLaunchReadsNoScript`：種子後換一個只有基準 manifest、沒有任何腳本的 bundle 再種子 → 回 nil、`state.json` 不變（macOS 2 ms）；同一個 bundle 遇到空 scope 才需要腳本 → 丟錯。
- Mutant：MF1 判斷前先讀腳本、MF2 拿掉「已種子就結束」、MF3 守門改回比整份 identity：3/3 變紅，還原後 sha256 相同（`w122-logs/mutants-fix.txt`）。後綠 44/44（`green-fix.log`），全量 `swift test` 1276／46（rebase 後含 W-124 的測試，`full-fix.log`），App Simulator build 成功（`app-build-fix.log`），重複啟動耗時 `repeat-launch-log.txt`。

### 站台清單不等官方包（W-131，接在 S4 之後）

- 問題：S3 把「載入官方包」、S4 把「種子」都放在 `restore()` 之前 await，站台清單要等它們。實測（暫存 Simulator、不帶設定檔、log「site list ready … ms after launch」，`artifacts/w131-logs/launch-before.txt`）：全新安裝 962 ms（種子 346 ms），重複啟動 252、289 ms（種子 40 ms，其餘是載入時重驗 33 支的 hash）。
- 修正：`ConfigView.task` 先 `restore()`（用內建腳本列站台），再 `removeStaging()`、`seedBaseline()`、`loadOfficialPack()`。載入的版本和這個 build 的內建內容相同（`SpiderBaseline.identity`，種子就是這種）時什麼都不用動；不同（下載的版本）才清 session 快取並 `rebuildSites()`。開機這段時間不會有播放器開著，所以不必走延後套用。上面「啟動位置」那段的「站台清單會等它」已不成立。
- 實測（同上條件，`launch-after.txt`）：站台清單 1、0、0 ms 出現；種子 1494 ms、重複啟動 27、26 ms 都在之後的背景完成。帶 0825 設定檔（`launch-after-with-config.txt`）：有快取的重複啟動 56、39 ms 列出站台。
- 取捨：載入的是和內建不同的下載版時，站台清單先用內建腳本列出，約幾百毫秒後重建一次；這段時間點進去的爬蟲站用的是內建腳本，重建時 session 快取清掉，下一次請求就用新腳本（和相容包更新的做法相同）。這條路沒有 GUI 證據（要先下載一個和內建不同的官方包），只讀程式碼。

### 啟動時的下載版也照播放中延後（W-134，接在 W-131 之後）

- 問題（W-131 審查 N-1）：W-131 的啟動流程載入後直接換掉 `ActiveOfficialPack`，下載版那條路沒有看 `playerOpen`，繞過了 S3 的播放中延後；靠的是清單出現後約 230 ms 內使用者還來不及開播放器。
- 修正：載入的結果先放在區域變數。內容和這個 build 的內建相同（種子）→ 直接設定，不重建、不清 session；不同（下載版）→ 呼叫 `applyOfficialPack()`，和安裝一樣在播放器開著時延後、關閉後套用（它會再載入一次，只發生在這條路）。
- DEBUG 縫 `WEBHTV_DELAY_PACK_LOAD_MS`：只在 DEBUG 編譯，讓載入延後，GUI 才做得出「載入前已經在播放」的情境（Release 不含，和 S3 的兩個縫同一種做法）。
- 驗證：App Simulator build 成功、`swift test` 1276／46（`artifacts/w134-logs/`）。GUI（N-2 一併補）：暫存 Simulator（測完刪除，臨時 CA 只加在那台）、本機 HTTPS 伺服器提供一個「`JianPian.js` 多一行註解」的序號 2 下載版，全部 PASS（`artifacts/w134-gui-evidence/RESULT.md`，sha256 `c44211e5…`）：A 檢查更新裝上序號 2；B（N-2）正常重開：`site list ready 35 ms` → 種子 `.rollback` → `applied … seq 2`，站台在、荐片分類可載入；C 播放中延後：`WEBHTV_DELAY_PACK_LOAD_MS=20000` 下先開始播放（嗶哩），`deferred: player open`、播放期間沒有 `applied`、時間碼 00:22→00:29，關閉播放器 → `player closed` → `applied … seq 2`（第一輪荐片片源 DNS 解析不到，改嗶哩重做）；D 重設回內建基準後正常重開：只有 `site list ready 73 ms` 與 `baseline unchanged`，沒有 `applied`。沒驗到：真機、MPV、PiP、Release；正常啟動的約 230 ms 空檔沒有真的撞到過（用 DEBUG 延遲做出來）。Ponytail：沒有 finding。

### 沒有相容包的設定不顯示失敗列（W-138，0.1.77 使用者回報）

- 問題（W-121 審查 N-4）：每次啟動 `refreshSpiderPack()` 都會抓設定旁的 `./spiders/manifest.json`，絕大多數設定沒有相容包，伺服器回 404 是正常的，設定頁卻顯示「設定檔相容包：沒有（更新失敗：相容性套件回應 HTTP 404。）」，使用者以為更新失敗。
- 修正：狀態文字改由 `SpiderToolText.compatibilityRow(failure:installed:)` 決定：沒有裝過相容包而且是 HTTP 404 → 空字串（列不顯示）；已有相容包（仍在使用）或其他錯誤 → 照舊顯示「<目前的包或『沒有』>（更新失敗：原因）」。相容包的下載與驗證、官方包流程都沒動。
- 驗證：`theCompatibilityRowHidesOnlyAConfigurationWithoutAPack`（404 無包 → 空；404 有舊包 → 舊包＋失敗；503、manifest 壞 → 顯示）先紅後綠；mutant（拿掉 404 判斷）變紅；`swift test` 1277／46；App Simulator build 成功（`artifacts/w138-logs/`）。截圖：暫存 Simulator、0825 設定（它的 `spiders/manifest.json` 回 404，Mac 上 curl 確認），啟動約 2 分鐘後設定頁「爬蟲工具」區塊只有狀態「內建基準 2026-10-15.1（序號 1，33 支）」、檢查更新、重設與頁尾說明，沒有「設定檔相容包」列，畫面裡「404」0 筆，PASS（`artifacts/w138-gui-evidence/RESULT.md`，sha256 `6ce17677…`）。沒驗到：App 自己那次相容包請求沒有 log 佐證（由網址 404 與等待時間推論）；「已裝相容包又 404」與非 404 錯誤只有單元測試；真機、Release。Ponytail：沒有 finding（一個條件、一個呼叫端）。

### S4 回滾

一個 commit；`git revert` 移除基準 manifest、種子與狀態列的分辨。已種子的裝置留下的世代內容就是內建檔，registry 讀它和讀內建結果相同；S3 的「重設」可清掉。

## S5（W-139）：把內建爬蟲搬出 App 本體

接在 0.1.78 截點 `683ceb1b` 之後（分支 `task/W-139`）。依據：計畫 §8 S5 列、驗收列、風險 8，使用者 2026-10-15 18:00 決定（Ikanbot／Djuu 收進第二版官方包）、Manager #2561／#2562；設計預審 `artifacts/w139-design-prereview.md`（W-141）四個必改由 Manager #2590 全部採用。依 M-4 分兩個 commit：**C1 工具**（本段）先讓官方包序號 3 能從 `ios-poc` 建出 35 支；**C2 App**（下一段）拿掉內建，隨 App 0.1.79。

### C1：建包工具改讀 `ios/Spiders`，官方包收進 Ikanbot／Djuu

- 35 支爬蟲**複製**到 `ios/Spiders/`（內容逐檔相同，`cmp`）。C1 不動 App：`Resources/Spiders` 照舊帶 38 個檔，App 行為和 0.1.78 完全相同；C2 才刪掉 App 那份。用複製而不是搬，是因為搬了 App 在 C1 就失去內建，C1 就不再是「只動工具」。
- `runtime_pack.py`：移除 `NOT_IN_FIRST_OFFICIAL_PACK`（W-41 的 `shortcut:` 兌現），官方包收 35 支；`--scripts` 預設 `ios/Spiders`。`spider_pack.py`：`--scripts` 預設 `ios/Spiders`；`IPA_ONLY` 行為照舊（相容包仍不收資料夾爬蟲），只改註解（S-6：不改名，避免動到引用它的地方）。`audit_spider_jars.py` 的 adapter 目錄改 `ios/Spiders`。
- `test_pack_exclusions.py`：相容包不得有、**官方包必須有** Ikanbot／Djuu；加 M-3 的一致性檢查：工具建出的官方包「類別＋別名」必須等於 `SpiderRegistry.ported`（`registry_names`），兩邊漂移就紅。
- 驗證（`artifacts/w139-logs/c1-tools.txt`、`c1-mutant.txt`）：`test_pack_exclusions.py` PASS（相容 33 支不含兩支、官方 35 支含兩支、名稱集合＝`ported`）；`runtime_pack.py build --sequence 3` 35 支、9 個別名齊全、`verify` 0 problem；`spider_pack.py build` 從新路徑建出的相容包 `scripts/` 與已發布的 `spider-pack/scripts` 逐檔相同。Mutant：`ported` 多一個包裡沒有的名稱 → 一致性檢查 FAIL、還原後 sha256 相同。沒有 Swift 改動，C1 不跑 `swift test`。
- Ponytail（C1 diff）：Ship。1 點留 C2：`IkanbotSpiderTests.neitherPackToolPacksIkanbot` 在 `swift test` 裡跑這支腳本，名稱與註解還寫「兩個工具都不收」，C2 改名（C1 不動 Swift，免得為一個名稱重建）；C1 到 C2 之間兩份爬蟲並存，C2 刪掉 App 那份。
- 推送與發布：C1、C2 都審過後一起推，再發序號 3、再發 0.1.79（理由：C1 單獨在 `ios-poc` 時一旦發出序號 3，舊的 `SpiderBaselineTests` 第 3 條守門會因腳本和基準不同而紅，要 C2 刪掉基準才恢復）。C2 推上到序號 3 發布之間不能觸發 IPA 發布。
- 回滾：`git revert` C1 只會讓工具回到舊路徑與排除集合；`ios/Spiders` 的複本消失。App 不受影響。

---

# 計畫（W-118，照搬並依決定修正）


## 1. 一頁摘要

**建議：方案 D「分兩版走到完全分離」。**

1. **第一版（N）**：App 內仍帶一份爬蟲當「基準包」，同時加上「設定 › 爬蟲工具」可以下載或更新 WebHTV 官方爬蟲包。第一次啟動時，App 會把內建的基準包複製一份到可更新的儲存區（不用連網）。這一版什麼都不會消失，只是多了更新管道。
2. **第二版（N+1）**：在 N 版真機確認沒問題後，移除 App 內建的 33 支爬蟲，只留下爬蟲共用的執行環境（`host.js` 等 3 個檔）。從此新安裝的 App 不帶爬蟲，打開後首頁直接提示「下載爬蟲工具」。升級的舊使用者早在 N 版就有複製好的一份，所以來源不會突然不見。

**為什麼不一版就直接做到「不內建」**：已安裝的使用者一升級，內建爬蟲就跟著 IPA 一起被換掉。如果新版本來就沒帶，又剛好離線、或沒去設定頁按下載，原本看得到的爬蟲來源會整批消失，違反「不能讓已裝使用者突然看不到來源」這條要求。分兩版的成本只是多發一次版，換來的是升級時不會有空窗。

**先講清楚的事實**

- **不是為了省空間**：可抽離的 32 支爬蟲（W-105 後為 33 支）壓縮後約 122 KB，只佔目前 IPA（35,422,351 bytes）的 0.34%。分離的價值在於「爬蟲更新不必再發 IPA」，以及「App 本身不帶內容來源」（與上游 FongMi TV 的立場一致）。
- **這等於重新打開 2026-09-29 撤銷的「熱更新」核心**：由 WebHTV 發布、所有人的 App 都會下載執行的爬蟲包。當時的撤銷紀錄只寫「不要熱更新，把 manifest.json 相關的還原」，沒有寫原因（第 4 節）。本計畫把範圍限縮成**只有使用者在設定頁按下按鈕、或首頁缺爬蟲時點一下，才會下載**，不做背景自動更新。這一點要請使用者明確確認（問題 2）。
- 當時寫好又撤掉的程式（`9410fb68`）不能整包還原：之後 IOS-POC-55（2026-10-06）的 JAR 對應功能依賴舊的相容包程式 `SpiderPack.swift`，而 13A 會把這個檔刪掉。本計畫只取用其中的設計與片段。

**需要使用者決定的事**（細節在第 9 節，回覆編號即可）：

| # | 問題 | 建議 |
|---|---|---|
| 1 | 最終形態與節奏 | 分兩版：N 版有基準包＋可更新，N+1 版移除內建 |
| 2 | 是否以本需求取代 2026-09-29 的撤銷決定，以及下載時機 | 取代，但只限手動：設定頁按鈕，加上首頁缺爬蟲時的一鍵提示；不做背景自動檢查 |
| 3 | 爬蟲包要不要簽章 | ~~要，用 Ed25519~~ → **使用者 2026-10-15 決定不簽章**：固定 HTTPS 網址＋SHA-256＋序號防降級 |
| 4 | 發布位置 | `ios-poc` 分支的固定路徑（和 `source.json` 同一種做法） |
| 5 | 舊的「設定檔相容包」`./spiders/manifest.json` | 保留，而且優先於官方包 |
| 6 | App 太舊、新版爬蟲需要更新 App 時 | 逐支判斷：需要新 App 的那幾支保留目前已裝的版本，其餘照常更新 |
| 7 | 實施方式 | S1→S4 連續做、每階段各自 commit；發 N 版前再問；S5 等 N 版真機確認後再開始 |

---

## 2. 使用者流程

### 2.1 名詞

- **爬蟲工具**：對使用者顯示的名稱，指 WebHTV 官方爬蟲包（以下簡稱「官方包」）。
- **基準包**：N 版 App 內建的那一份。N+1 版起不再有。
- **設定檔相容包**：設定檔旁的 `./spiders/manifest.json`。今天就存在，但沒有任何設定檔真的提供它（`docs/current-task-state.md:420`：GitLab 沒有 `spiders/manifest.json`）。

### 2.2 首次安裝（N+1 版，沒有任何爬蟲）

| 狀況 | 畫面 |
|---|---|
| 還沒載入設定檔 | 維持現狀：「尚未載入設定」，提供「使用網址」「匯入設定」（`WebHTVApp.swift:150-175`） |
| 設定檔載入了，有一般 CMS 站，也有需要爬蟲的站 | 首頁照常顯示 CMS 站，上方多一條橫幅：「這個設定有 N 個來源需要爬蟲工具」＋「下載」按鈕。設定頁「爬蟲工具」顯示「未安裝」 |
| 設定檔載入了，但**所有站都需要爬蟲** | **一定要改**。今天 `sites.isEmpty` 會退回「尚未載入設定」，而且整個分頁列（包括設定頁）都不存在（`WebHTVApp.swift:152`、`:162-165` 的註解），使用者會卡住、找不到設定頁。改成專屬畫面：「設定已載入。有 N 個來源需要爬蟲工具」＋「下載爬蟲工具」按鈕，下載完成後自動重建站台清單 |
| 下載完成 | 橫幅消失，爬蟲來源出現在站台清單；不必重開 App（沿用 `rebuildSites()`，`WebHTVApp.swift:453-460`） |

「需要爬蟲的來源數 N」＝設定裡 `csp_*` 站，扣掉目前能驅動或能對應的。這只是用 `CSPSourceResolver.canResolve` 反過來算（`CSPSourceResolver.swift:38-50`），不用新的判斷邏輯。drpy、Python 站本來就每次從設定檔來源抓，不在這個範圍。

### 2.3 設定頁「爬蟲工具」區塊

取代今天那一列「Spider 腳本」（`WebHTVApp.swift:2027`），以及頁尾的「可由 ./spiders/manifest.json 熱更新」那句說明（`:2036`）。

| 列 | 內容 |
|---|---|
| 狀態 | `未安裝`／`內建基準 2026-10-15.1（33 支）`／`官方包 2026-10-20.1（序號 12，33 支）`；有設定檔相容包時多一行「此設定另有相容包 …，優先使用」 |
| 上次檢查 | 時間＋結果文字（見 2.4） |
| 按鈕「下載」／「檢查更新」 | 進行中會停用；按下後依序檢查官方包，以及設定檔相容包（如果有的話） |
| 按鈕「重設」 | N 版：刪掉已下載的版本，回到內建基準。N+1 版：刪掉爬蟲工具，回到「未安裝」。兩者都要先確認 |

刻意不做：手動「退回上一版」按鈕。上一版只在新版載入失敗時自動使用（第 5 節），出問題時用「重設」再重新下載就夠了。

### 2.4 結果與錯誤提示（一律保留目前版本）

| 情況 | 顯示 |
|---|---|
| 成功 | 「已更新到 2026-10-20.1（33 支）」 |
| 已是最新 | 「已是最新版本」 |
| 離線或連不到伺服器 | 「無法連線，繼續使用目前的版本」（未安裝時：「無法連線，請稍後再試」） |
| 下載到一半中斷、逾時、HTTP 錯誤 | 「下載沒有完成，繼續使用目前的版本」 |
| 檔案驗證不符、格式不認得（不簽章，所以沒有簽章錯誤這一類） | 「更新包驗證失敗，沒有採用，繼續使用目前的版本」 |
| 伺服器上的版本比已裝的舊 | 「伺服器版本比目前的舊，已忽略」（防降級） |
| 部分爬蟲需要較新的 App | 「已更新；其中 N 支需要較新的 App，暫時沿用目前版本：A、B」 |
| 整包都需要較新的 App | 「這個版本需要較新的 App，請到 SideStore 更新」。這句要和「已是最新」分開，不能混在一起（IOS-POC-12 R24 的教訓） |
| 正在播放 | 新版本照樣下載驗證，但等關閉播放器後才換上；顯示「已下載，關閉播放器後套用」（沿用 IOS-POC-13 第 7.1 節第 3 點） |

### 2.5 舊使用者升級（不可以讓來源消失）

| 路徑 | 結果 |
|---|---|
| 0.1.76 以前 → N | 內建基準包還在，行為不變。第一次啟動時把基準包複製到可更新的儲存區（不連網） |
| N → N+1 | 已有複製的一份（或後來下載的更新版），升級後照樣可用，離線也可以 |
| 0.1.76 以前**跳過 N**、直接裝 N+1 | 沒有可用的一份。只要設定裡有需要爬蟲的站，啟動後首頁顯示 2.2 的橫幅或專屬畫面，一鍵下載。這是唯一會短暫看不到來源的路徑，而且畫面上會說清楚原因。SideStore 允許跳版，所以這一條要做、也要測 |
| 任何版本按「儲存空間 › 初始化」 | `clearAll` 會清空 Application Support（`StorageMaintenance.swift:146-150`）。N 版會回到內建基準，N+1 版會回到「未安裝」。初始化的確認文字要補上「爬蟲工具需要重新下載」 |

觀看紀錄與收藏引用的爬蟲站，在爬蟲工具裝好之前打不開。此時的錯誤訊息要寫「需要爬蟲工具」，不能寫成「來源失效」。

---

## 3. 套件來源與信任

### 3.1 誰發布、放哪裡（建議）

- **發布者**：WebHTV 維護者，透過手動觸發的 GitHub Actions workflow（`workflow_dispatch`，和 IPA 發布同一種方式），從 repo 內的爬蟲原始檔建包。
- **位置**：`https://raw.githubusercontent.com/st7833232/webhtv/ios-poc/spider-pack/manifest.json`，網址編進 App。檔案採**內容定址**命名（`blobs/sha256/<hex>`，IOS-POC-12 第 8 節已經定義）。好處是 CDN 快取就算短暫讓新 manifest 配到舊檔案，也只會驗證失敗、下次再試，不會混用新舊檔。
- **為什麼不用 GitHub Release 的「latest」網址**：GitHub 對 latest 的定義是「最近一個非 prerelease、非 draft 的 release，依 `created_at` 排序」（N8）。IPA 和爬蟲包放在同一個 repo，會互相搶 latest。SideStore 讀的是 `source.json`，不受影響，但爬蟲包不能依賴 latest。
- **App 內的使用者覆寫**：今天 `UserDefaults` 的 `spiderPackURL` 可以覆寫相容包網址（`SpiderPack.swift:177-182`），但沒有任何 UI 會寫它。官方包**不**讀這個值，網址固定。

### 3.2 驗證鏈

1. HTTPS（`SpiderPack.swift:205` 今天就有這條檢查）。
2. manifest 大小上限 64 KiB、單檔 512 KiB、總量 2 MiB、最多 64 個檔、路徑白名單、拒絕原生副檔名：沿用 `RuntimePackLimits` 與 `RuntimePackManifest.checkFields`（`RuntimePackManifest.swift:58-69`、`:245-325`）。
3. **簽章：不做**（使用者 2026-10-15 決定問題 3＝2）。信任靠固定的 HTTPS 網址、每個檔的 SHA-256，以及 `state.json` 的序號下限防降級。`RuntimeTrustRoot`／Ed25519／sign 子命令都不做；validator 的不簽章改動在 S2（W-120，Manager #2062）。
4. 每個檔案逐一比對宣告的 bytes 與 SHA-256，任何缺檔、多檔或不符就整包拒絕（`verifyGeneration`，`:598-609`）。
5. 防降級：每個 scope 記錄已接受的最大 `sequence`，比它小的拒絕、相同但內容不同的也拒絕（`RuntimeScopeState.admission`，`:694-709`）。
6. 每支腳本先在拋棄式 JSContext 編譯，確認有匯出（IOS-POC-13A 的 smoke），通過才安裝。

**誠實說明不簽章能防什麼**：HTTPS＋每個檔的 SHA-256 能防傳輸途中被竄改、CDN 給錯檔或給到一半；序號下限能防有人拿舊版本來降級。**不能防**的是 GitHub 帳號或 `ios-poc` 推送權限被盜：拿到的人可以直接發一個惡意的包。這和 `source.json`／IPA 本身的信任等級相同（同一個 repo、同一組權限），使用者已接受這個取捨。

### 3.3 和其他發布物的關係

| 項目 | 關係 |
|---|---|
| IPA／`source.json` | 互相獨立：各自的版號、各自的 workflow。爬蟲包用自己的 `sequence`（整數，只比較它）和顯示用的 `version`（例如 `2026-10-20.1`，延續 `spider-pack/manifest.json` 現在的寫法）。release notes 照舊不寫站名（使用者記憶規則） |
| App 相容性 | 包裡宣告它需要的 `js.host` 版本（`RuntimeABI.swift:68`，目前 1.5，等於 `SpiderPackStore.hostApiVersion` 5，`SpiderPack.swift:147`），必要時再加 `minAppBuild` |
| 設定檔相容包 | 屬於設定作者的信任範圍：信任設定檔自己的 HTTPS origin，不需要也不接受 WebHTV 簽章（IOS-POC-12 第 5 節） |

### 3.4 優先順序

**設定檔相容包 → 官方包 → 內建基準（N 版）→ 沒有（N+1 版）。** 這和 IOS-POC-12 的 D6 一致，也和設定檔的 `rules` 一樣是「設定優先」。今天的程式只有「相容包 → 內建」兩層（`SpiderRegistry.swift:17-22`、`:141-159`）。

已知缺口 G1：今天的相容包存在全域目錄（`SpiderPack.swift:168-175`），沒有依設定檔分開，切換設定檔不會丟掉 A 的包（IOS-POC-12 第 11 節第 5 點）。官方包是全域的，沒有這個問題。相容包的 G1 不在本計畫範圍，除非問題 5 選擇改動它。

---

## 4. 歷史決策：2026-09-29 撤銷了什麼、和現在差在哪

### 4.1 撤銷的內容

- 撤銷的是 IOS-POC-13 的 13A～13D（`docs/IOS-POC-13-runtime-hot-update.md:3`，revert commit `20fd462e`）：
  - 每個 scope 一個世代目錄＋`state.json`
  - updater：啟動時與每次成功載入設定檔時自動檢查
  - 設定頁「Spider 腳本更新」區塊
  - 發布工具 `webhtv-runtime-pack`
  - Ed25519 的 global 簽章通道（含公鑰）
  - 手動觸發的簽章 workflow `ios-runtime-pack.yml`
- 13A 曾刪除舊的 schema 1 相容包，撤銷後它照 0.1.31 原樣回來。這些程式都沒有發布過。
- 保留的是 IOS-POC-12 的契約：`RuntimeABI.swift`、`RuntimePackManifest.swift`（純邏輯、目前沒有呼叫者）。

### 4.2 撤銷的原因

- 文件只記了使用者的話：「不要熱更新，把 manifest.json 相關的還原」（`IOS-POC-13-runtime-hot-update.md:221`），revert commit 也只寫「at the user's decision」。**沒有記錄具體原因**，本計畫不替使用者猜。
- 從當時的設計看，可能的顧慮有三種：
  - 啟動時自動在背景下載並換掉腳本（13B）
  - 金鑰保管的負擔（13D 要使用者親自產生、保管兩把私鑰）
  - 整套機制的複雜度（1,572 行新增）
- 這三點本計畫各自對應如下：

| 可能的顧慮 | 本計畫的處理 |
|---|---|
| 背景自動更新 | 不做。只有使用者按設定頁按鈕、或首頁缺爬蟲時點一下，才會下載（問題 2） |
| 金鑰負擔 | 讓使用者選（問題 3）。不簽也能運作，只是信任退回到「固定 HTTPS 網址」 |
| 複雜度 | 只做 global（官方包）一個 scope。設定檔相容包維持現狀，不另做逐設定世代 |

### 4.3 這次需求和當時的差別

| | 2026-09-29 撤銷的 IOS-POC-13 | 本需求 |
|---|---|---|
| 目的 | 不發 IPA 也能更新爬蟲 | 同左，**再加上**新安裝的 App 不帶爬蟲 |
| 觸發 | 啟動、切換設定檔時自動檢查 | 使用者手動 |
| scope | 設定檔＋global | 只有 global（官方包），設定檔相容包維持舊路徑 |
| 沒有包時 | 使用內建 | N 版用內建基準；N+1 版顯示「需要下載」 |

這次需求本身就是「由 WebHTV 發布、App 下載執行的爬蟲」，和當時撤銷的核心相同。所以**必須由使用者明確確認本需求取代那次決定**（問題 2），不能只靠推論。

### 4.4 可以重用的契約與程式

| 來源 | 重用方式 |
|---|---|
| `RuntimePackManifest.swift`（HEAD，IOS-POC-12） | 直接用：manifest 格式、大小／路徑／型別檢查、相容性（簽章驗證不用：使用者決定不簽章）、`verifyGeneration`、`RuntimeScopeState`（防降級、LKG、標壞） |
| `RuntimeABI.swift` | 直接用：`js.host` 版本與 `nativeScripts` |
| `SpiderPack.swift`（HEAD） | 保留給設定檔相容包與 IOS-POC-55 的 mappings，不刪 |
| `9410fb68` 的 `RuntimePackStore.swift`（278 行）、`RuntimePackUpdater.swift`（139 行）、`Tools/WebHTVRuntimePack/main.swift`（232 行）、`ios-runtime-pack.yml`（105 行）及其測試 | 取片段改寫：只留 global scope、改成手動觸發；registry 接線要重寫，因為 13A 的接線假設 `SpiderPack.swift` 已經刪除 |
| 13C 的 UI 文字（`IOS-POC-13-runtime-hot-update.md:169`） | 結果文字大多可直接沿用 |
| 13D 的金鑰 | 公鑰 `db8863f2dcd3f4de`／`9ed9a5bd0cecd110` 記錄在 `IOS-POC-13-runtime-hot-update.md:213`。私鑰是否還在 `~/webhtv-runtime-keys/`、secret `WEBHTV_RUNTIME_ACTIVE_KEY` 是否還在，要使用者自己確認（agent 不經手私鑰） |

---

## 5. 版本相容、原子安裝與回滾

### 5.1 App 太舊（建議：問題 6 的選項 1）

- 整包層級：manifest 宣告的 `js.host` major 不同，或 `minAppBuild` 大於本機 → 整包不採用，保留目前版本，顯示「需要較新的 App」。
- 逐支層級：某支腳本宣告的 `minHostApi` 大於本機 → **那一支沿用目前已裝的版本**，其餘照常更新。目前沒裝過那一支，就先不提供。今天 `assemble` 的做法是直接丟掉那一支（`SpiderPack.swift:252-257`），在官方包裡會讓原本能用的站消失，所以要改成沿用舊版。
- 每次啟動都要對已裝的世代重新檢查相容性，因為 SideStore 可以把舊 IPA 裝回同一個容器（IOS-POC-12 第 12 節第 2 點）。不相容的世代不使用，但也不刪除。
- 現況：已移植的 33 支裡，只有 `AppDrama`、`Uvod` 需要 3，`Gulu` 需要 4（`spider_pack.py:70-85`），其他都是 2。目前的 App 是 5，全部都能跑。

### 5.2 原子安裝

1. 下載到 `Application Support/RuntimePacks/<scope>/staging-<uuid>/`，每個檔只讀到宣告的 bytes 為止（沿用 `DrpyEngine.download` 的串流上限）。
2. 逐檔驗 SHA-256，加上 smoke 測試。
3. 在同一個 volume 內 rename 成不可變的 `generations/<id>/`。
4. 用原子寫入 `state.json`（`Data.write(.atomic)`，R18）作為唯一的「切換點」。

不再用今天 `replaceItemAt` 整個目錄替換的做法（`SpiderPack.swift:289-307`），因為 Apple 文件寫明失敗時原檔可能留在暫存位置（R17）。檔案保護等級用 `completeUntilFirstUserAuthentication`，因為鎖定螢幕時的 PiP、背景音訊也會載入爬蟲（R19）。

### 5.3 保留上一版與壞包退回

- 只保留 active 和 1 個 LKG（上一個可用版本）（`RuntimeScopeState.activating`，`RuntimePackManifest.swift:712-729`）。
- **確定性失敗**才把世代標壞並退回 LKG：hash 不符、格式錯誤、ABI 不符、JS 編譯失敗、載入 smoke 失敗。標壞的版本永遠不自動重試（`markingBad`，`:733-744`）。App 被殺、進背景都**不算**失敗（R10）。
- 單一 class 在執行時載入失敗：先退回 LKG 世代的同一支，N 版再退回內建基準（IOS-POC-12 D9）。
- 啟動時選世代不連網，是 O(1) 的動作：讀 `state.json` → 重驗 active → 不行就用 LKG → 再不行就用基準或「未安裝」（R25）。

### 5.4 回滾層級

| 層級 | 做法 |
|---|---|
| 發布端 | 發布更大 `sequence` 的修正版，或 `directive: rollbackToBundled`（`RuntimePackManifest.swift:165-168`）。N+1 版沒有內建，所以 rollback 的意思變成「清空官方包」，實際上應該發一個修正版，不要發 rollback |
| 使用者端 | 設定頁「重設」，或「初始化」 |
| 程式 | 每個階段一個 commit，`git revert` 即可；S1～S4 在沒有發布官方包時不改變任何行為 |

---

## 6. 範圍：什麼一定留在 App、什麼可以抽離

### 6.1 一定留在 App（Native Core）

- `host.js`（26,087 B）、`drpy-bridge.js`（2,956 B）、`js-spider.js`（3,813 B）：它們是爬蟲依賴的 SDK，也是 prelude。`RuntimeABI.nativeScripts`（`RuntimeABI.swift:133`）、`spider_pack.py` 的 `NOT_PACKABLE`（`:29`）都已經把它們排除，`RuntimePackManifest.checkType` 也拒絕這些 class 名稱（`:318-323`）。
- 爬蟲包的公鑰、官方包網址、`RuntimeABI` 常數、大小上限。
- `SpiderRegistry.aliases`（`SpiderRegistry.swift:125`）和 `ported`（`:47-116`）目前寫在 Swift 裡。N+1 版要改成以包的內容為準：別名搬進 manifest 的 `aliases`。目前只有 `JianPian` 的別名在包裡（`spider_pack.py:51`），`Jys`、`Short*`、`SportsGuazi` 都要補進去。

### 6.2 可以抽離

`Resources/Spiders` 裡其餘 33 支全部可以抽離。**更正指派時的假設**：`FirstAid.js` 只用基本 host API（http-html），不需要 native。它已經在 `spider-pack/manifest.json` 裡（`DEFAULT_ORIGINS`，`spider_pack.py:78-79`），也已經能打包。`Gulu`（`minHostApi` 4）同樣能打包，只是比 4 舊的 App 會略過它。目前沒有任何一支爬蟲需要 JS 以外的原生能力，需要新原生能力的一律等新 IPA 與 `js.host` minor 升版。

### 6.3 IPA 大小

依 HEAD 實測，壓縮用 `zip -9`（IPA 也是 zip，實際比例會接近）：

| 內容 | 檔數 | 原始大小 | 壓縮後約 | 佔 IPA 35,422,351 B |
|---|---|---|---|---|
| `Resources/Spiders` 全部 | 35 | 334,831 B | 134,451 B | 0.38% |
| 留在 App 的 SDK | 3 | 32,856 B | 12,466 B | 0.04% |
| **可抽離** | **32** | **301,975 B** | **約 122 KB** | **約 0.34%** |

結論：N+1 版的 IPA 大約小 0.12 MB，**大小不是做這件事的理由**。

---

## 7. 方案比較

| 方案 | 內容 | 使用者體驗 | 安全 | 維護／測試 | 回滾 | 離線 | 與 2026-09-29 撤銷的關係 |
|---|---|---|---|---|---|---|---|
| **A 不改** | 爬蟲跟 IPA 一起發；設定檔相容包照舊 | 最簡單；但修一支爬蟲就要發一版 IPA，使用者要到 SideStore 更新 | 不新增攻擊面 | 不增加 | IPA 回滾 | 完全可用 | 一致 |
| **B 一版完全抽離** | 下一版直接移除 33 支，只能下載 | 新安裝要多一步；**舊使用者升級時，離線或沒去下載的人會看到來源消失**；要做首次啟動自動下載才能補救 | 新增 WebHTV 發布通道 | 要搬測試資源、改 registry、做空狀態 | 只能靠發修正版；壞包又沒有 LKG 時就沒有爬蟲 | 新安裝離線不可用 | 重開核心，而且偏向自動下載 |
| **C 內建基準＋可更新** | 保留內建一份，設定頁可下載更新覆蓋 | 不會有空窗；能更新 | 同 B | 中等 | 「重設」回到內建 | 完全可用 | 重開核心（手動版） |
| **D 分兩版走到 B（建議）** | N 版＝C 加上「把基準包複製到可更新儲存區」；N+1 版移除內建 | N 版無感；N+1 版新安裝會引導下載；升級者已有複製的一份 | 同 B，但在 N 版就先在真機驗證過通道 | 同 B，分兩次做 | N 版有內建可退；N+1 版有 LKG＋重新下載 | N 版完全可用；N+1 版新安裝需要先連網一次 | 重開核心（手動版），問題 2 要確認 |
| E 只靠設定檔相容包（FongMi 模式） | 不做官方包；爬蟲由設定檔作者放在設定檔旁 | 使用者完全沒有操作；但目前沒有任何設定檔提供（GitLab recha 沒有） | 信任設定檔來源，和 drpy／Python 相同 | 最少 | 設定作者撤包 | 依設定檔 | 不重開官方通道 |

**E 為什麼不建議**：E 最接近上游（N4～N7），但它把「誰來發布爬蟲」交給設定檔作者。WebHTV 的 33 支是維護者自己寫的移植，設定檔作者不會、也不該替 WebHTV 發布。要做 E，等於要使用者自己把 `spider-pack/` 放到 GitLab recha（`docs/current-task-state.md:421`：要不要發布到 GitLab 由使用者決定），而且每個設定檔都要放一份。E 可以和 D 並存，就是第 3.4 節的「設定檔相容包優先」。

**建議 D**：它是唯一同時滿足以下四點的方案：

- 新安裝不帶爬蟲（最終狀態）
- 已裝使用者不會失去來源
- 爬蟲更新不必發 IPA
- 每一步都能獨立回滾

---

## 8. 分階段實作

每個階段一個 task guard session、一個 commit，可以獨立 `git revert`。預估是本 agent 的實際時間，不含使用者授權發布與真機回報的等待。

| 階段 | 內容 | 主要檔案 | 使用者可見變化 | 預估 |
|---|---|---|---|---|
| **S1** 官方包儲存與 registry 順序 | 只有 global scope 的 `RuntimePackStore`（取 `9410fb68` 片段改寫）：世代目錄、`state.json`、啟動時選世代、標壞、LKG、清殘留 staging；registry 順序改成「設定檔相容包 → 官方包 → 內建」；逐 class 退回；`StorageMaintenance.supportKeep` 加上 `RuntimePacks` | `RuntimePackStore.swift`（新）、`SpiderRegistry.swift`、`StorageMaintenance.swift`、測試 | 沒有 | 2～3 h |
| **S2** 手動 updater＋發布工具 | `RuntimePackUpdater.check()`（只在被呼叫時跑）：抓 manifest（上限）→ admission → 下載 blob → install；`webhtv-runtime-pack build/verify`（不做 sign）；手動 workflow 發布到 `ios-poc:spider-pack/`；validator 改成 global 不要求簽章（Manager #2062） | `RuntimePackUpdater.swift`（新）、`ios/Tools/…`、`ios/Package.swift`、`.github/workflows/ios-spider-pack.yml`（新）、測試 | 沒有（還沒有 UI 會呼叫它） | 2～3 h |
| **S3** 設定頁＋首頁提示 | 「爬蟲工具」區塊（2.3）、結果文字（2.4）、首頁橫幅與「全是爬蟲站」專屬畫面（2.2）、播放中延後套用 | `WebHTVApp.swift` | 有：設定頁新區塊；缺爬蟲時出現提示 | 1.5～2 h |
| **S4** 遷移種子 | 啟動時如果官方包 scope 是空的，就把內建基準複製成一個世代（`sequence`＝建包時寫進 App 的基準序號），不連網 | `RuntimePackStore.swift`、`WebHTVApp.swift`、測試 | 沒有（基準和內建內容相同） | 0.5～1 h |
| ── 發布 N 版（要使用者另外授權）＋ 真機驗收 ── | | | | |
| **S5** 移除內建爬蟲 | 33 支搬到 `spider-pack/src/`（或同等位置），從 `WebHTVCore` 的 resources 移除；測試改從 repo 目錄載入；`ported`／`aliases` 改由包決定；`StorageMaintenance` 初始化文字；`spider_pack.py` 的預設來源路徑 | `Resources/Spiders/*`、`SpiderRegistry.swift`、`ios/Package.swift`、約 23 個測試檔、`scripts/spider_pack.py`、`WebHTVApp.swift` | 有：新安裝要先下載 | 2～3 h |
| ── 發布 N+1 版（要使用者另外授權） ── | | | | |

S1～S4 合計約 6～9 小時，S5 另外 2～3 小時。

### 驗收條件

| 階段 | 單元測試 | Simulator GUI（Claude 自己安裝並操作，證明是本 build） | 證據 |
|---|---|---|---|
| S1 | 既有 `swift test` 全部通過（沒有包時行為和 HEAD 相同）；新測試：世代選擇、LKG、標壞、降版安裝不選用也不刪除、三層優先順序、逐 class 退回 | 不需要 | 測試輸出 |
| S2 | 假 fetch：已是最新、下一版＋LKG、每種拒絕（hash、大小、降級、序號重用、需要較新的 App）都不動現有世代；網路失敗；`webhtv-runtime-pack verify` 對 `spider-pack/` 回報 ok | 不需要 | 測試輸出、工具輸出 |
| S3 | 結果文字對照表測試（「需要較新的 App」與「已是最新」不同） | 用本機 HTTPS 伺服器（臨時 CA，沿用 13C 做法）：①未安裝→下載→站台出現 ②檢查更新：已是最新 ③blob 改一個 byte：驗證失敗、仍是舊版 ④停掉伺服器：離線訊息、仍可用 ⑤下載中途切斷：沿用舊版 ⑥播放中：延後套用 ⑦全是爬蟲站的設定：專屬畫面可以下載 ⑧重設 | 螢幕截圖＋伺服器存取紀錄＋容器內 `RuntimePacks/` 列表 |
| S4 | 空 scope 會長出種子；已有世代時不覆蓋；種子序號低於已裝版本時不採用 | 從 0.1.76 的容器升級到本 build：站台不變、設定頁顯示「內建基準」 | 截圖、容器列表 |
| N 版 | — | 真機（使用者回報）：下載、更新、重設、離線啟動 | 使用者回報 |
| S5 | 測試全部改從 repo 目錄載入後通過；registry 在沒有包時 `canDrive` 全部為 false；`RuntimeABITests` 的 SDK 清單不變 | ①新安裝＋只有 CMS 的設定：正常 ②新安裝＋混合設定：橫幅→下載 ③N 版容器升級到 N+1：站台不變、離線可用 ④跳版（0.1.76 容器直接升 N+1）：提示下載 ⑤初始化後：回到未安裝 | 截圖、IPA 內 `Spiders/` 只剩 3 個檔 |

Ponytail review：每個階段完成前對最終 diff 執行並記錄（AGENTS.md §4）。

---

## 9. 風險與待使用者決定的問題

### 9.1 風險

1. **首次使用需要網路**（N+1 版）：新安裝、離線時，爬蟲來源無法使用。這是需求本身的代價，只能靠清楚的畫面提示緩解。
2. **跳版升級**的短暫空窗（2.5）：用首頁提示緩解，無法完全消除。
3. **官方通道被冒用**：不簽章（使用者決定），GitHub 帳號或推送權限被盜就能發惡意包；與 IPA 同一個信任等級，見 3.2 的說明。
4. **遠端 JS 沒有 CPU watchdog 與 `host.req` 回應大小上限**（IOS-POC-12 D10）：官方包只是取代既有腳本，沒有擴大這個既有的面，但 IOS-POC-12 第 20 節第 3 點建議在開放遠端 JS 之前先補上。本計畫把它列為 S2 的可選項，不擋 S1～S4。
5. **Python 爬蟲能改寫整個 App 容器**（IOS-POC-12 第 9 節第 6 點），理論上可以竄改 `state.json`。這是既有限制，本計畫不處理。
6. **raw.githubusercontent.com 的快取時間沒有查證**：內容定址檔名讓結果最壞只是「這次驗證失敗、稍後再試」。
7. **Apple 政策**：App Store Review Guidelines 2.5.2 禁止下載會新增或改變功能的程式碼，4.7 只允許 HTML5／JS mini app 並要求開發者負責，4.7.2 禁止把原生 API 暴露給下載的軟體（N1）。WebHTV 透過 SideStore 側載，不受 App Review 約束，但這代表本設計永遠不適合上架 App Store。這一點在今天的設定檔驅動 drpy／CatVod JS／Python 腳本上就已經成立。
8. **測試搬家**（S5）：約 23 個測試檔依賴 `Bundle.module` 的爬蟲，搬家時要確保每支爬蟲的 golden 測試仍然有跑。

### 9.2 待使用者決定（回覆編號即可）

**問題 1：最終形態與節奏**

1. （建議）分兩版：N 版有內建基準＋可更新＋遷移種子；N 版真機確認後，N+1 版移除內建
2. 一版直接移除內建；首次啟動在偵測到缺爬蟲時自動下載（離線的新安裝不能用，跳版升級的人也一樣）
3. 只做到 C：永遠保留內建基準，不移除

**問題 2：以本需求取代 2026-09-29「不要熱更新」的決定，以及下載時機**

1. （建議）取代，但只限手動：設定頁「下載／檢查更新」，加上首頁缺爬蟲時的一鍵提示；不做任何背景或啟動時自動檢查
2. 取代，而且每次啟動自動檢查（但只在使用者同意後安裝）
3. 不取代：維持撤銷決定，本計畫停止（等同方案 A）

**問題 3：官方包要不要簽章**（已決定：選 2，不簽章；下面是當時的選項原文）

1. （建議）要，Ed25519，沿用 13D 做法：active 私鑰放 GitHub secret 由 CI 簽，backup 私鑰離線保存。請先確認 `~/webhtv-runtime-keys/` 與 secret `WEBHTV_RUNTIME_ACTIVE_KEY` 是否還在，不在就重新 `keygen`（由使用者親自執行）
2. 不簽：只靠固定 HTTPS 網址＋SHA-256＋序號防降級（信任等同 GitHub 帳號與 `source.json`）
3. 要，但只在使用者自己的電腦本機簽：最安全，每次發布都要使用者操作

**問題 4：官方包的發布位置**

1. （建議）`ios-poc` 分支的 `spider-pack/`（內容定址），經 `raw.githubusercontent.com` 提供，用手動 workflow 發布，和 `source.json` 同一種做法
2. GitHub Release asset（每版一個 `spiders-s<n>` tag）＋分支上的指標檔
3. GitLab recha（和設定檔放在一起）

**問題 5：舊的設定檔相容包 `./spiders/manifest.json`**

1. （建議）保留不動，並且優先於官方包（設定作者可以覆蓋；IOS-POC-55 的 JAR 對應靠它運作）
2. 移除（從未在現場使用），IOS-POC-55 的 mappings 改放進官方包

**問題 6：新版爬蟲需要較新的 App 時**

1. （建議）逐支判斷：需要新 App 的那幾支保留目前已裝的版本，其餘照常更新，並顯示「N 支需要較新的 App」
2. 整包不採用，等使用者更新 App

**問題 7：實施方式**

1. （建議）核准後 S1→S4 連續做，每階段各自 commit 並交 Reviewer；發布 N 版前再問；S5 等 N 版真機確認後再開始
2. 每個階段都停下來等核准

---

## 10. 附錄

### 10.1 研究證據表

級別：A＝原始碼、規格、官方文件；B＝維護者討論；C＝成熟專案程式碼或 README；D＝論壇或 issue 回報。

**本次新讀（2026-10-15）**

| # | 來源 | revision | 存取日 | 級 | 支持的主張 | 對 WebHTV 的適用性與 caveat | 對決策的影響 |
|---|---|---|---|---|---|---|---|
| N1 | https://developer.apple.com/app-store/review/guidelines/ | 頁面的 Last Updated 不在讀到的前 100,000 字內（R14 記錄為 2026-06-08） | 2026-10-15 | A | 2.5.2：不得下載、安裝、執行會新增或改變功能的程式碼；4.7：可提供不內嵌在 binary 的 HTML5／JS mini app，開發者負責；4.7.2：不得對其擴充或暴露原生 API。Guidelines 裡**沒有 3.3.2**（指派時提到的「3.3.2」是舊 DPLA 條號，現在是 DPLA §3.3.1(B)，見 R15） | SideStore 側載不受審查；用來界定保守邊界 | 官方包只能放直譯 JS，不能新增原生 primitive；明講永遠不適合上架 |
| N2 | https://developer.apple.com/tutorials/data/documentation/javascriptcore.json （JavaScriptCore 文件 JSON） | 目前版 | 2026-10-15 | A | 「evaluate JavaScript programs from within … apps」「insert custom objects into the JavaScript environment」 | 下載的腳本能做的事，等於 App 注入的物件（`host.js` 底下的 `__http`／`__crypto`／`__store`／`__util`）；沒有 JIT（R16） | 安全面由 `js.host` 決定，不由包決定；D10 watchdog 列為風險 4 |
| N3 | https://developer.apple.com/tutorials/data/documentation/javascriptcore/jsexport.json | 目前版 | 2026-10-15 | A | `JSExport` 決定哪些原生方法暴露給 JS | 同 N2 | 同 N2 |
| N4 | https://github.com/FongMi/TV （README） | `fongmi` 分支，6,738 commits；hash 頁面沒有顯示 | 2026-10-15 | C | 「App 本身不內建或提供任何內容來源」；支援外部配置與 CatVod Spider 介面擴充 | 上游 Android 的產品立場就是 B，但爬蟲由**設定檔**提供，不是由 App 維護者提供 | 支持「最終不內建」；也說明 E 方案（設定檔提供）是上游做法 |
| N5 | https://fongmi.github.io/TV/config/ | 頁面沒有日期或版本 | 2026-10-15 | A | `spider`：全域 Spider JAR 路徑或 URL；site 的 `jar` 覆蓋全域；`api` 可以用相對路徑 `.js`／`.py`；**沒有描述快取或更新機制** | 快取行為要看原始碼（N7） | — |
| N6 | https://fongmi.github.io/TV/spider/ | 頁面沒有日期 | 2026-10-15 | A | JS 爬蟲以 QuickJS 執行，相對路徑以配置檔位置為準；JAR 類別在 `com.github.catvod.spider`；App 不內建來源 | 同 N4 | 同 N4 |
| N7 | 本 repo 的 Android 原始碼（HEAD `a0e6991b`）：`app/src/main/java/com/fongmi/android/tv/api/loader/JarLoader.java:151-170`（`;md5;` 相符就用快取，否則每次下載）、`:45-53`（`clear()` 換設定檔時丟掉所有 loader 與 spider）；`catvod/…/utils/Util.java:61-63`（快取檔 md5 比對）；`catvod/…/utils/Path.java:121-123`（快取在 `cache/jar/<md5(url)>.jar`）；`api/config/VodConfig.java:84-95`、`:195-197`（載入設定時 `parseJar(spider)`）；`api/loader/JsLoader.java:35-49`、`BaseLoader.java:58-63`；`app/src/main/assets` 沒有任何爬蟲 JAR | `origin/main` `5856232743d2b8ddd5b3730e676b197ff2c0a264` 同源 | 2026-10-15 | A | Android 不內建爬蟲；爬蟲屬於設定檔；以 URL 的 md5 快取，宣告的 md5 只是快取提示（不是真實性）；換設定檔時整批重設 | Android 能執行 DEX，iOS 只能換直譯 JS；md5 不能當信任來源（IOS-POC-55 也記錄過 `;md5;` 與實際 JAR 不符） | 支持「以 session 重設套用新版」；WebHTV 的信任要比上游強（簽章或固定網址＋SHA-256） |
| N8 | https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases 、https://docs.github.com/en/rest/releases/releases#get-the-latest-release | 目前版 | 2026-10-15 | A | `/releases/latest/download/<asset>` 可以連到最新 release 的 asset；latest＝最近一個非 prerelease、非 draft、依 `created_at` 排序的 release | IPA 與爬蟲包在同一個 repo 會互搶 latest | 不用 latest 網址；問題 4 建議分支上的固定路徑 |
| N9 | https://github.com/CatVodTVOfficial/CatVodTVJarLoader 、https://github.com/CatVodTVOfficial/CatVodTVSpider | — | 2026-10-15 | — | **無法取得**（HTTP 404） | 用 N7 的本機原始碼代替 | 不影響決策 |

**沿用、本次未重讀**（原始紀錄在 `docs/IOS-POC-12-runtime-architecture-reconciliation.md` 第三節，2026-09-25 讀取；`docs/IOS-POC-13-runtime-hot-update.md` 第 2 節，2026-09-29 讀取）：

| # | 來源 | 用在本計畫的哪裡 |
|---|---|---|
| R1 | TUF spec 1.0.36 | 內建公鑰、遞增序號防回滾、只下載到宣告長度、內容定址（3.2、5.2） |
| R5～R7 | Expo updates 規格、code signing、error recovery | 先驗簽再解析；`rollbackToBundled`；只有確定性失敗才回退；回退順序 LKG → 內建（5.3） |
| R9、R10 | CodePush | App 被殺不算失敗（5.3） |
| R11 | Shorebird | hash 不是安全功能（3.2） |
| R13 | CryptoKit `Curve25519.Signing` | Ed25519，不需新相依（3.2） |
| R14、R15 | App Review Guidelines、DPLA §3.3.1(B) | 政策邊界（N1、風險 7） |
| R16 | BrowserEngineKit W^X | iOS 只能換直譯碼（N2） |
| R17～R19 | `replaceItemAt`、`.atomic`、檔案保護 | 原子安裝與保護等級（5.2） |
| R24、R25 | Expo issue 48148、47920 | 「需要較新的 App」要和「已是最新」分開；啟動不可依賴 updater I/O（2.4、5.3） |
| U1、U2 | CodePush／Expo 的檢查與套用時機 | 下載與套用分開，播放中延後（2.4） |

**證據類別涵蓋情形**

- 上游原始碼：N7。
- 官方規格與平台文件：N1～N3、N5、N6、N8，以及 R1、R5～R7、R13～R19。
- 上游 PR、issue、維護者討論：R10、R24、R25（沿用）。
- 成熟相關專案：N4，以及 R8、R12（沿用）。
- 論文與部落格：R2（沿用）；沒有新增。

**停止條件**：再多的來源不會改變第 7 節的建議。剩下的都是使用者的決定（第 9.2 節），不是研究問題。

### 10.2 現況檔:行對照（HEAD `a0e6991b`）

| 主題 | 位置 | 現況 |
|---|---|---|
| 內建爬蟲 | `ios/Sources/WebHTVCore/Resources/Spiders/` | 35 個檔、334,831 B（`git ls-tree -l HEAD`）；`Package.swift:10` 以 `.copy("Resources/Spiders")` 打包 |
| 相容包信任說明 | `ios/Sources/WebHTVCore/Spider/SpiderPack.swift:19-25` | 同一來源的 SHA-256 只證明完整性、不證明真實性；簽章列為升級路徑 |
| `hostApiVersion` | `SpiderPack.swift:147` | 等於 `RuntimeABI.Surface.jsHost.version.minor` |
| 預設位置／覆寫 | `SpiderPack.swift:152`、`:177-182` | `./spiders/manifest.json`，可被 `UserDefaults` 的 `spiderPackURL` 覆寫（沒有 UI 會寫它） |
| 儲存位置 | `SpiderPack.swift:168-175` | `Application Support/SpiderPack`（全域，G1） |
| `installedPack` | `SpiderPack.swift:186-200` | 讀取時重新驗證 |
| `refresh` | `SpiderPack.swift:203-241` | HTTPS、schema、整包與逐支 host 閘、下載、`assemble`、寫入 |
| `assemble` | `SpiderPack.swift:247-287` | hash 不符整包拒絕；host 太新的那一支丟掉；mappings 綁 adapter 的 hash |
| 原子寫入 | `SpiderPack.swift:289-307` | staging 目錄＋`replaceItemAt` |
| `reset` | `SpiderPack.swift:309-314` | 刪目錄，回到內建 |
| registry 來源順序 | `ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift:17-22`、`:141-159` | 相容包 → 內建；包的別名只指向包自己帶的腳本 |
| `ported`／`aliases` | `SpiderRegistry.swift:47-116`、`:125` | Swift 內的白名單與別名表 |
| `bundledOnly` | `SpiderRegistry.swift:161-175` | 從 `Bundle.module` 的 `Spiders/` 載入，加上 prelude（`host`）與兩個 bridge |
| `canResolve` | `ios/Sources/WebHTVCore/Spider/CSPSourceResolver.swift:38-50` | 不能驅動的 csp 站不列出 |
| 站台過濾 | `ios/Sources/WebHTVCore/WebHTVConfig.swift:68-70` | `drivableSites` |
| `js.host` | `ios/Sources/WebHTVCore/RuntimeABI.swift:68` | 1.5 |
| SDK 腳本 | `RuntimeABI.swift:133` | `host.js`、`drpy-bridge.js`、`js-spider.js` |
| runtime pack 契約 | `ios/Sources/WebHTVCore/RuntimePackManifest.swift:19-54`（scope）、`:58-69`（上限）、`:123-326`（manifest）、`:446-478`（信任根，`bundled` 為空：`:472`）、`:513-640`（validator）、`:662-753`（狀態） | 純邏輯，沒有任何呼叫者 |
| 建包工具 | `scripts/spider_pack.py:20-29`（`SCHEMA`、`HOST_API` 5、`BASE_HOST_API` 2、`NOT_PACKABLE`）、`:35-109`（`DEFAULT_ORIGINS`）、`:124-165`（build）、`:182-209`（verify）、`:212-245`（fingerprint） | |
| 已建好但未發布的包 | `spider-pack/manifest.json` | schema 1、`2026-10-15.1`、`minHostApi` 2、33 支、mappings 0 |
| App 啟動接線 | `ios/WebHTVApp/Sources/WebHTVApp.swift:265-277` | `adoptCachedSpiderPack()` → `refreshRemote` → `refreshSpiderPack()`：**今天每次啟動都會抓設定檔旁的 `spiders/manifest.json`** |
| 相容包函式 | `WebHTVApp.swift:422-449` | 成功時 `SpiderSessionStore.reset()`＋`rebuildSites()`；失敗只寫狀態字串 |
| 重建站台 | `WebHTVApp.swift:453-460` | |
| 空狀態 | `WebHTVApp.swift:150-175` | `sites.isEmpty` 時沒有分頁列 |
| 設定頁 | `WebHTVApp.swift:2023-2038` | 「Spider 腳本」一列＋頁尾說明 |
| 儲存空間 | `ios/Sources/WebHTVCore/StorageMaintenance.swift:64-65`（`supportKeep` 含 `SpiderPack`）、`:102`（staging 殘留）、`:146-150`（初始化清空全部） | |
| 發布流程 | `docs/IOS-POC-11-sidestore-release.md:6`（0.1.76 (77)，IPA 35,422,351 B）、`:53`（`source.json` URL）；`.github/workflows/ios-sidestore-release.yml:147-151`（Release asset）、`:167-192`（把 `source.json` 推回 `ios-poc`） | |
| 歷史 | `docs/IOS-POC-13-runtime-hot-update.md:3`、`:95-102`、`:117-122`、`:213`、`:219-227`；revert `20fd462e`；撤銷前的程式 `9410fb68`；`docs/IOS-POC-12-runtime-architecture-reconciliation.md` 第 2.6、5、9、11、12、20 節（`:96`、`:138`、`:290`、`:315`、`:326`、`:466`） | |

## 11. 使用者決定（2026-10-15）

使用者回覆「不簽章，照計畫開工。」對應：問題 1＝1（分兩版）、問題 2＝1（取代 2026-09-29 撤銷決定，但只限手動下載）、問題 3＝2（不簽章：固定 HTTPS＋SHA-256＋序號防降級）、問題 4＝1（ios-poc 分支 spider-pack/，手動 workflow 發布）、問題 5＝1（設定檔相容包保留且優先）、問題 6＝1（逐支判斷）、問題 7＝1（S1→S4 連續做、各自 commit 送審；發 N 版前再問；S5 等 N 版真機確認）。簽章相關（RuntimeTrustRoot、Ed25519、sign 子命令）全部不做。
