# IOS-POC-55 — 電腦端分析 JAR，讓 App 自動重用相容的內建爬蟲

## Recovery anchor

- 目標（使用者 2026-10-06）：名稱不同、但協定實際相容的 `csp_*` 來源不必新增 adapter。電腦端分析設定實際引用的 JAR，用強證據比對＋既有 runtime 驗證確認後，產生限定範圍的對應，經既有相容包（`./spiders/manifest.json`）送到 App，App 自動選用既有 adapter。手機不反編譯、不執行 JAR。發布另行處理。
- 允收：改名但相容 → 對應；外觀相似但不相容、helper／JAR 更新、多候選歧義 → 待分析並列原因；對應只在「設定來源＋站 key＋類別＋JAR 實際 SHA-256＋adapter SHA-256」都相符時生效；不改 UI、播放器、收藏、記錄、下載；不判定來源失效。
- Task guard：`IOS-POC-55`（`standard`），基準 `d6823b53`。
- 狀態（2026-10-06 12:10）：工具、App 整合、相容包 `spider-pack/`（2026-10-06.1）完成並驗證；真實設定 **0 個新對應**（理由見第 7.3 節）。App 端隨 `0.1.69 (70)` 發布（第 7.7 節）；`spider-pack/` **沒有**發布到 GitLab。
- 唯一下一步：SideStore 真機驗收 `0.1.69 (70)`；`spider-pack/` 要不要放到設定旁的 `./spiders/`，由使用者另外決定（見第 7.6 節的影響）。

## 1. 研究（2026-10-06 11:20～11:30 CST）

| 來源 | 版本／取得 | 證據等級 | 支持的結論 | 對設計的影響 |
|---|---|---|---|---|
| FongMi/TV `app/src/main/java/com/fongmi/android/tv/bean/Site.java` | branch `fongmi` @ `c616c0aa3613e87529791587a9f71b78c278c991`，2026-10-06 以 `gh api` 讀原始碼 | 一手原始碼 | `Site.objectFrom(e, spider)`：站的 `jar` 為空就用設定的 `spider` | App 端「這站用哪個 JAR」照抄：`site.jar` 否則設定的 `spider` |
| 同 repo `api/loader/JarLoader.java` | 同上 | 一手原始碼 | 每個 JAR 字串一個 `DexClassLoader`（key＝`md5(jar)`），spider 實例 key＝`md5(jar)+siteKey`；`;md5;` 只用來判斷快取檔能不能直接用，不符就重新下載 | 同名類別在不同 JAR 是**不同類別**；`;md5;` 不等於實際版本（本設定 `xiaosa-0807.jar` 宣告 `4d263271…`，實際 `d8f71fc8…`），版本要看實際 bytes |
| Roy, Cordy, Koschke, *Comparison and evaluation of code clone detection techniques and tools*, Sci. Comput. Program. 74(7), 2009（經 [SourcererCC](https://arxiv.org/pdf/1512.06448)、[survey](https://arxiv.org/pdf/2006.15682) 的定義引用） | 2026-10-06 | 同行審查文獻（二手轉述定義） | Type-2 clone＝忽略識別字與字面值後語法相同 | 「單純改名」就是 Type-2 的識別字部分；**字面值（路徑、參數、金鑰、header、旗標名）這次刻意不忽略**，因為協定就寫在字面值裡 |
| Backes, Bugiel, Derr, *Reliable Third-Party Library Detection in Android*, CCS 2016（[LibScout](https://trust.cispa.saarland/publication/derr-16-ccs)） | 2026-10-06 摘要 | 同行審查文獻摘要 | 只用類別階層 profile 就能抵抗識別字改名 | 只看結構（階層／方法形狀）分不出兩支協定不同的 spider；**不能**當相容證據，只能用來找候選 |

不適用：平台規格（CatVod JAR 沒有規格文件，FongMi 原始碼就是事實上的規格）；benchmark（判定規則是「完全相等才算」，不是相似度門檻，不需要調參）。

## 2. 現況（本地程式）

- `scripts/audit_spider_jars.py`：讀設定、讀 DEX type／string 表、jadx 反編譯、依依賴分類（`protected-payload`、`http-crypto`…），只回答「能不能移植」，不比對類別之間是否相同。
- `scripts/spider_pack.py`：`build`／`verify`／`fingerprint`，`DEFAULT_ORIGINS` 只記到前 8 個 port 的來源 JAR。
- App：`SpiderRegistry.ported`＋`aliases`（`JPianAmns→JianPian`、`Jys→Jpys`，人工確認）只看類別名稱，不看 JAR；相容包的 `aliases` 是全域別名，只能指向同一包帶來的腳本。`Site` 不解碼 `jar`，設定的 `spider` 也沒讀。
- 結論：現有別名**不足以安全承載**自動對應（沒有設定來源、JAR 版本、adapter 版本的範圍），需要最小擴充。

## 3. 方案比較

| 方案 | 內容 | 問題 |
|---|---|---|
| 不做 | 每遇到改名的站就人工 alias 或新 adapter | 使用者要的就是把這件事自動化 |
| 用全域 `aliases` | 分析後把類別名加進相容包 `aliases` | 不分 JAR、不分設定、不看版本：同名類別在另一個 JAR 會被誤套；JAR 更新後仍套用 |
| 名稱／品牌／主機／關鍵字比對 | 站名或 `Amns` 去尾、同主機就套 | 使用者明確禁止；`Jys` 和 `Jpys` 主機相同、body 幾乎一樣，實際少送 `Origin`／`Referer`、旗標名不同 |
| **Type-2 正規化＋字面值保留＋呼叫目標內容化（採用）** | 識別字（類別、方法、欄位、區域變數、混淆過的 helper 名）一律換成占位符；字串、數字、外部 API 名保留；呼叫自家方法時換成被呼叫方法內容的 digest（深度 3）；整個類別＝成員 digest 的多重集合，必須**完全相等**才算相容 | 結構完全相同但編譯器不同導致 bytecode 形狀不同時，會判成不相容（保守方向，進「待分析」） |

## 4. 設計

### 4.1 電腦端（延伸 `scripts/audit_spider_jars.py`，不另造平台）

```
audit_spider_jars.py audit    …（原本的功能，參數不變）
audit_spider_jars.py baseline --jars DIR            → scripts/spider_baselines.json
audit_spider_jars.py compat   --config URL …        → build/compat/{report.json,report.md,mappings.json}
                              [--runtime]           → 對候選跑既有 live golden，通過才寫進 mappings.json
spider_pack.py build --mappings build/compat/mappings.json → manifest 多一個 `mappings`
```

- **特徵基準**：`spider_pack.py` 的 `DEFAULT_ORIGINS` 補齊 19 個 adapter 的來源 JAR 與 SHA-256；`baseline` 只接受 SHA-256 與記錄相同的 JAR，對該類別（含自家父類別）計算特徵，連同演算法版本寫進 `scripts/spider_baselines.json`。原版 JAR 之後改了，基準不會跟著漂移。
- **比對**：每個設定的 `csp_*` 站，以「實際 JAR SHA-256＋類別」為單位分析一次（同名類別在不同 JAR 各算各的）：
  1. 類別名已在 registry（含人工 alias）→ `existing`：App 照舊用名稱綁定，只報告跟基準相同或差在哪（不改行為）。
  2. 空殼／native／動態載入 → `pending`（原生／加密載入）。
  3. 特徵與唯一一個基準完全相等 → `candidate`；`--runtime` 用該站自己的 `ext` 跑既有 live golden（`appGetDrivesTheWholeCatVodFlowAgainstTheLiveSite`）通過 → `mapped`；不通過 → `pending`（無法驗證，不判定失效）。
  4. 與多個 adapter 相等 → `pending`（歧義）。
  5. 都不相等 → `pending`，列最接近的基準與差異（API 路徑、請求參數／header、簽章／加解密、回應、播放、helper 實作），並建議「只差常數→可評估補資料」或「缺協定／能力→要新 adapter 或 host 能力」。
- **類別改名不算差異**：字串字面值等於類別自己名字時（log tag、`init` 裡的名字）換成 `$SELF`。

### 4.2 相容包（最小擴充，schema 不變）

`manifest.mappings[]`，舊版 App 解碼時忽略未知欄位：

| 欄位 | App 讀 | 意義 |
|---|---|---|
| `config` | 是 | 設定檔 URL（比對時忽略 query／fragment） |
| `site` | 是 | 站 key |
| `class` | 是 | 設定的類別（不含 `csp_`） |
| `jar` | 是 | 解析後的 JAR 絕對 URL（不含 `;md5;`） |
| `jarSha256` | 是 | 分析時 JAR 實際 bytes 的 SHA-256 |
| `adapter`、`adapterSha256` | 是 | 要用的既有 adapter 與它的腳本 SHA-256 |
| `evidence` | 否 | 基準、指紋、runtime 驗證紀錄 |

### 4.3 App

- `Site.jar`：站自己的 `jar`，`WebHTVConfig` 解碼後空的補上設定的 `spider`（照 FongMi）。`Site.id` 不變。
- `SpiderRegistry`：名稱直接命中仍優先（既有行為不變）；否則找 `config`／`site`／`class`／`jar` 都相符、且目前 registry 裡 `adapter` 腳本 SHA-256 等於 `adapterSha256` 的對應。
- `CSPSourceResolver.session(for:)`：用到對應時先確認 JAR 實際 SHA-256（下載 bytes 算雜湊，不解壓、不執行；ETag 條件請求＋上次結果），不符就丟出具名錯誤「JAR 已更新，需要重新分析」，不列入失效判斷。spider 仍用站自己的 key 建 `SpiderStorage` 與新的 `CookieJar`，`ext` 照原樣。

## 5. 允收與驗證計畫

- Python 自測（`scripts/test_spider_compat.py`，離線）：改名但相容（類別與 helper 都改名）→ 相等；外觀相似但不相容（少一個 header、路徑不同）→ 不等且列出差異；helper 更新（md5→sha1）→ 不等；兩個 adapter 基準相同 → 歧義；同名類別在兩個 JAR → 各自判定。
- 真資料：兩份設定、17 個 JAR 跑一次 `compat`。
- Swift 單元測試（離線）：對應只在設定、站 key、類別、JAR URL、adapter SHA-256 全相符時生效；JAR SHA-256 不符時 session 丟出具名錯誤；名稱直接命中的既有行為不變；相容包解碼帶 `mappings` 與不帶時都正常。
- 回歸：`SpiderPackTests`、`SpiderGoldenTests`（離線部分）、`SourceClientTests` 等既有 spider 相關測試。

## 6. 回滾

一個 commit。`git revert` 後 App 回到只看類別名稱；已發布的相容包即使帶 `mappings`，舊版 App 也會忽略。

## 7. 實作紀錄（2026-10-06 11:00～11:45 CST，基準 `d6823b53`）

### 7.1 改動

| 檔案 | 內容 |
|---|---|
| `scripts/audit_spider_jars.py` | 改成子命令（`audit` 原樣保留，舊的無子命令呼叫仍可用）；新增 `baseline`、`compat`。DEX 表讀出「外部名稱」（JAR 自家程式以外的型別與成員名），jadx 輸出逐成員正規化，自家識別字換占位符、字面值與外部 API 保留、呼叫自家方法換成被呼叫內容的 digest（深度 3）、類別自己的名字當字串時換 `$SELF`；`compare` 依成員角色與字面值分類列原因；`decide` 判 existing／candidate／pending；`--runtime` 用該站自己的 `ext` 跑既有 live golden |
| `scripts/spider_baselines.json` | 19 個 adapter 原版類別的特徵基準（algorithm 1、深度 3），來源 JAR 必須是 `DEFAULT_ORIGINS` 釘住的 SHA-256 |
| `scripts/spider_pack.py` | `DEFAULT_ORIGINS` 補齊 44A～44F 的 11 個 adapter；`build --mappings`（adapter 版本不符就拒絕打包）；`verify` 可讀本機目錄，並檢查每個對應的 adapter 與雜湊 |
| `scripts/test_spider_compat.py` | 離線自測：改名、外觀相似、helper 更新、呼叫目標、歧義、同名不同 JAR、加密空殼、既有名稱 |
| `ios/…/SpiderPack.swift` | `SpiderPack.ClassMapping`、manifest 選用欄位 `mappings`；`assemble` 只保留 adapter 由本包以 `adapterSha256` 送達的對應；`JarFingerprints`（實際 bytes 的 SHA-256，ETag 條件請求，連不上時用上次結果）；`ClassMappingUnverified` |
| `ios/…/SpiderRegistry.swift` | `mapping(for:in:)`：名稱直接命中優先；設定（忽略 query）、站 key、類別、站實際使用的 JAR URL 都相符才回傳 |
| `ios/…/CSPSourceResolver.swift` | `canResolve`：已知 JAR 已變就不列；`session(for:)`：先驗 JAR 雜湊再用 adapter 建 runtime，仍用站自己的 key／`ext`／新 cookie jar |
| `ios/…/WebHTVConfig.swift` | `Site.jar`（站自己的 `jar`，空的補設定的 `spider`）；`Site.id` 不變 |
| `ios/Tests/…/SpiderPackTests.swift` | 範圍、adapter 版本、JAR 更新／304、`spider` 補值；一個用環境變數啟動的端到端測試（產出的相容包＋真實設定） |
| `spider-pack/` | 可發布的相容包 `2026-10-06.1`：19 支腳本、`mappings: []` |

### 7.2 可重複執行的入口

```bash
scripts/audit_spider_jars.py baseline --jars <放 river-fman／xiaosa-0807／xyqxbpq 的目錄>
scripts/audit_spider_jars.py compat --runtime \
  --config https://gitlab.com/st7833232/recha/-/raw/main/wang-movie.json \
  --config https://gitlab.com/st7833232/recha/-/raw/main/wang-sex.json      # → build/compat/{report.md,report.json,mappings.json}
scripts/spider_pack.py build --version <版本> --out spider-pack --mappings build/compat/mappings.json
scripts/spider_pack.py verify --url spider-pack
SPIDER_PACK_DIR=$PWD/spider-pack SPIDER_PACK_CONFIG=<設定 URL> \
  swift test --package-path ios --filter aGeneratedPackDrivesEveryMappedSite
python3 scripts/test_spider_compat.py
```

需要 `jadx`（Homebrew）與 Xcode 的 `swift`。一次完整 `compat`（兩份設定、17 個 JAR，jadx 快取後）約 30 秒。

### 7.3 真實設定的結果（2026-10-06 11:30，兩份設定、260 個 `csp_` 站、17 個 JAR）

| 判定 | 站數 | 類別@JAR |
|---|---:|---|
| 新的自動對應（mapped） | **0** | — |
| 既有名稱綁定，與基準相同 | 178 | 18 組：19 個 adapter 在它們的來源 JAR 裡全部與基準相同（`XBPQ`／`XYQHiker`@`xyqxbpq.jar` 等） |
| 既有名稱綁定，與基準不同（只報告，行為不變） | 29 | `App3Q`／`App99`／`AppGet`／`AppQi`@`xiaosa-0807.jar`、`AppQi`@`愛影.jar`、`Jys`@`river-fman.jar`（少送 `Origin`／`Referer`、旗標名不同）、`XBPQ`@`XBPQ.jar`／aliluya `spider.jar`／`xiaosa-0807.jar`、`XYQHiker`@`Aoki.jar`／`river-fman.jar` |
| 既有 alias，類別本身是加密空殼 | 1 | `JPianAmns`@`aowu.jar` |
| 待分析：原生／加密載入 | 34 | `aowu-0722.jar` 19 個 `*Amns`、`fan-0720.jar` 5 個 `*Guard`（全部是同一個 loader 的空殼，連 `QmdjAmns`、`HHkkAmns`、`JinPaiAmns` 也看不到邏輯，不能靠名字對到 `QimaoDJ`／`HaokanDJ`／`Jpys`） |
| 待分析：有相近基準但不同 | 6 | `AppSy`、`Hxq`、`PianKu8`@`xiaosa-0807.jar`，`Wwys`@`river-fman.jar`，`AppV6`@美團 JAR，`Jable`@`pg-0923.jar`：協定或 helper 不同，要新 adapter |
| 待分析：沒有相近基準 | 12 | `AppDrama`、`Douban`@`river-fman.jar`，`Uvod`@`custom_spider.jar`，`GM`、`MiMei`、`Zuise`、`Jable`@`xc0126.jar` |

結論：**今天兩份設定裡，沒有任何「名稱不同、協定其實相同」的未移植類別**。全部 17 個 JAR 的 1,164 個 spider 類別也用最終演算法掃過一次：沒有任何類別是 19 個基準的改名副本；跨名稱完全相同的只有三組加密空殼（`aowu-0722`、`aowu`、`fan-0720` 各自的 loader）和 `pg-0923` 兩個小 helper。所以這次沒有可發布的實際對應；工具與 App 機制是為之後設定新增改名類別準備的。另外發現：`xiaosa-0807.jar` 設定宣告的 md5（`4d263271…`）與實際檔案（`d8f71fc8…`）不符，這正是 App 端改用實際 SHA-256 的理由。

### 7.4 驗證

| 項目 | 方法 | 結果 |
|---|---|---|
| 改名但相容 | 真實 `river-fman.jar` 的 DEX 同長度改字串：`GuaziTY→GuaziTZ`、helper `merge/b/h→merge/b/y`，重算 checksum／signature（scratchpad `dexpatch.py`，不 commit），再走完整 `compat --runtime` | 特徵與 `GuaziTY` 基準完全相同 → live golden（瓜子 live m3u8）通過 → 2 筆對應（站自己的 `jar`、設定的 `spider` 各一） |
| 外觀相似但不相容 | 同上，再把 `client-version` 的 `3.0.1.1` 改 `3.0.1.9` | pending：「helper／欄位：字串常數不同（3.0.1.1 → 3.0.1.9）」 |
| helper 更新 | 同上，helper 的 `AES/CBC/PKCS5Padding` 改 `PKCS7Padding` | pending：「分類／詳情：本身相同，但呼叫的 helper 實作不同」 |
| 同名不同 JAR | 同一份測試設定裡三個 `csp_GuaziTZ` 指向三個 JAR | 各自判定，只有 `renamed.jar` 的對應 |
| 歧義、呼叫目標、加密空殼、既有名稱 | `scripts/test_spider_compat.py` | 通過；突變 2／2（拿掉改名占位、拿掉呼叫解析）都被抓到 |
| 端到端（App） | 測試相容包（19 支腳本＋2 筆對應）由 `SpiderPackStore` 安裝，`aGeneratedPackDrivesEveryMappedSite` 對測試設定跑 | 2 站列出、JAR 雜湊確認、經 `GuaziTY` 拿到 live m3u8 |
| 範圍與版本（App） | `SpiderPackTests` 新增 4 個離線測試 | 17／17 通過；突變（拿掉 JAR URL 比對）被抓到 |
| 交付的相容包 | `spider_pack.py verify --url spider-pack`；真實 `wang-movie.json`＋`spider-pack/` 跑端到端測試 | 19 支、0 對應、0 問題；安裝成功 |
| 回歸 | `WANG_MOVIE_JSON=… swift test`（全部） | 1019 個測試，2 個失敗都與本次無關：`decodesProvidedWangMovieConfig` 寫死 167（今天 169，44D 前就失敗）；`reportsLiveType4SitesFromProvidedConfig` 是 type-4 原生 CMS 站今天回 embed 頁（live 內容，不經 `csp_`）。App 列表仍是 74 站＝30 原生＋44 spider |
| Ponytail | `ponytail:ponytail-review` 最終 diff | 3 項（刪未用的 `ClassMapping` init、刪重複的 adapter 檢查、更正註解）已套用 |

**未驗證**：iOS 模擬器與真機都沒跑；App 端只在 `swift test`（macOS）驗證。真實設定沒有對應，所以「真機上自動用既有 adapter 開站」目前沒有實例可測。

### 7.5 已知限制

1. 判定是「完全相等」：同協定但編譯器／混淆器不同造成結構不同時，會判成不相容（保守方向，留在待分析）。
2. 呼叫解析深度 3、helper 呼叫靠「名稱＋參數個數」對應；更深的呼叫或同名同參數個數的重載只比對內容集合。
3. 已移植名稱照舊依名稱綁定（例如 `XBPQ`@`XBPQ.jar` 與基準不同仍用 `XBPQ.js`）；這次只報告不改，避免既有站退步。
4. JAR 主機連不上時，App 用上次確認過的雜湊；JAR 在連不上期間換版，要等下次連得上才會發現。
5. 同一份設定裡 key 重複的站，要每一個都通過 runtime 驗證才會產生對應。

### 7.6 發布時要知道的事（這次沒有發布）

- `spider-pack/` 放到設定旁的 `spiders/` 後，現有 App（含 0.1.68）會照既有機制採用：除了對應（目前 0 筆），**也會把 44D～44F 的 6 支新腳本送到 0.1.68**（`minHostApi 2`，0.1.68 的 `js.host` 是 1.2，可以跑）。要不要這樣做，由使用者決定。
- 舊版 App 忽略 `mappings`，行為不變；回滾＝撤掉或換掉 `spiders/manifest.json`。

### 7.7 隨 `0.1.69 (70)` 發布（2026-10-06）

- App 端的對應機制（`SpiderPack.mappings`、`JarFingerprints`、`Site.jar`）隨 `0.1.69 (70)` 發布，tag `ios-v0.1.69-b70` → `98384c2a`，run `37411484416`。紀錄在 `docs/IOS-POC-11-sidestore-release.md`「第七十次發布」。
- 公開 release notes 寫明：目前只支援程式特徵完全相同的改名副本，不代表任何協定相同的來源都能辨識；目前的分析沒有產生新對應。
- 沒有對應被發布（GitLab 相容包未發布），所以這版 App 實際上不會套用任何對應；行為與只看名稱時相同。

## 8. 狀態

- 2026-10-06 11:30：研究與設計完成，開始實作。
- 2026-10-06 11:45：實作、驗證、Ponytail 完成；真實設定 0 個新對應；發布另行處理。
- 2026-10-06 12:05：App 端隨 `0.1.69 (70)` 發布；相容包未發布。
