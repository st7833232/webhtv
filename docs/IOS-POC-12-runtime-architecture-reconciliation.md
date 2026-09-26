# IOS-POC-12 — Runtime Architecture Reconciliation（規劃）

- 狀態：**規劃完成，未實作**（2026-09-25）。本文件只定義契約、資產分類、版本政策、manifest 草案與分階段計畫；沒有修改任何程式、測試、workflow、lock 或 artifact。
- Lane：規劃（只讀盤點）。Ponytail：unavailable / skipped。
- 任務文件：本文件 `docs/IOS-POC-12-runtime-architecture-reconciliation.md` 是 IOS-POC-12 唯一的任務文件（AGENTS.md §7）。`docs/IOS-POC-12-13-runtime-update-roadmap.md` 維持 IOS-POC-12／13 的索引並連到本文件；IOS-POC-12 的細節兩者不一致時，以本文件為準。
- 盤點基準：`origin/ios-poc` `a6652cc3b50f0349fcaefea8943691319222e095`（IOS-POC-26-1），2026-09-25 以 `git fetch origin ios-poc` 讀取。位置以「檔案＋符號」為主，行號只是這個 commit 上的輔助。**凍結（12A）時必須重新確認 HEAD**，並依第四節之零重新比對盤點，不要沿用本文件引用的 SHA。
- 驗證限制：本環境沒有 Swift toolchain，本文件提到的測試都沒有執行。
- 用語：英文術語（fallback、fail closed、generation、scope 等）的中文說明集中在第一節之二。

## 一、狀態與授權

### 之一、授權範圍

1. 使用者 2026-09-25 要求規劃 IOS-POC-12。這是**規劃授權，不是實施授權**。`docs/current-task-state.md`「使用者規定」第 3 條（沒有指示前不開始 IOS-POC-12／13）仍然有效，第八節每個階段都要使用者另外明確說「開始實施 12X」。規定第 1 條也仍然有效：bump 版本、tag、發布 SideStore release 前都要先問。
2. 路線圖的前置條件是核心真機驗收（`docs/IOS-POC-8L-core-real-device-acceptance.md`）：
   - ⑱（MPV 真機 first frame（第一個畫面）的事件序列與四格解碼）沒有正式回報；`0.1.10 (11)` 上「MPV 有畫面」只是非正式觀察。
   - ⑲（原生 ↔ MPV 切換與 fallback）的**位置項目已有真機失敗回報**（`docs/IOS-POC-26-engine-switch-position.md` 第一節記為真機失敗），由 IOS-POC-26 修正中；速度、暫停、集數、線路、Bili headers、MPV 沒有畫面時 10 秒內回原生等其餘項目沒有回報。
3. 同一個 `ios-poc` 分支上並行的任務：
   - IOS-POC-26（切換位置與 MPV seek 正確性）：26-1 已 commit 為 `a6652cc3`（`PlaybackLoadRequest.exactStart`、`resumed(at:rate:autoplay:exact:)`、`PlayerRouter.handOff`／`reload`／`setRate` 的精確度規則、`PlaybackSession.loadNative` 的零容差起播），**未編譯、未執行測試、未發布**；26-2（MPV 在廣告 `EXT-X-DISCONTINUITY` 上的時間軸、MPV 核心復原）研究中。該文件預定的下一版是 `0.1.22 (23)`。
   - IOS-POC-25（HLS 串流中段跳廣告）：另一個 session 開發中。截至 `a6652cc3`，repo 內沒有它的任務文件或 commit。它可能改到 `ads`、`rules`、`MediaSniffer` 或 `PlaybackTarget`（K16～K18、K21），也可能新增廣告偵測規則或 host 清單，這類內容是 Dynamic Layer 的高變動候選。
4. 能不能在 ⑱⑲ 之前開始：
   - **整個 IOS-POC-12 不能在 ⑱⑲ 與 IOS-POC-25／26 結束前完成。** 交接（hand-off）的位置與精確度、autoplay、fallback，以及有廣告的 HLS 上「位置」指哪一條時間軸，都還在變（K28、K29）；現在凍結會把未驗證的行為寫成契約。
   - ⑱⑲ 與 IOS-POC-25／26 影響的是 Native 內部的播放契約（第四節之一第三組）與 sniffer 的內部行為，不影響 runtime pack 會依賴的面（Spider ABI、JS／Python host、CatVod 輸出 schema，第六節）。即使 MPV 最後觸發 IOS-POC-17 的停止條件，換掉的也是引擎邊界，不是 pack 面。
   - 因此 12A～12D 可以先做：12A 只改文件，使用者說「開始實施 12A」即視為同意；12B～12D 要使用者同意調整路線圖順序（D1），12B 另外要重新開啟 IOS-POC-20 Q6（D2）。
   - 必須等待：12E（播放契約凍結）要等 IOS-POC-25 與 IOS-POC-26 都結束、26-2 決定有廣告 HLS 上「位置」採哪一條時間軸、⑲ 在含 IOS-POC-26 的版本上重新回報；MPV 相關列另等 ⑱。
   - 草案的 12F（相容包強化）會改變行為且需要發版，已移出 IOS-POC-12（第八節之六、D4）。
5. 沒有其他答案時能做的事：使用者說「開始實施 12A」，即視為同意 12A 先於 ⑱⑲（12A 只改文件，不依賴真機結果）。12B～12D 另需 D1、D2 的答案；12E 等前置條件。
6. 撰寫時最新已發布版本是 `0.1.21 (22)`。之後的版本以 Git 與 `docs/IOS-POC-11-sidestore-release.md` 為準。

### 之二、用語

| 英文 | 本文件的意思 |
|---|---|
| runtime pack | 執行期內容包：不經 IPA 就能更新的直譯腳本、規則或資料 |
| Native Core | 原生核心：只能隨 IPA 更新的程式、框架、資源與信任根 |
| Dynamic Layer | 動態層：可由 runtime pack 或使用者設定更新的內容 |
| ABI | 應用程式介面契約：pack 能呼叫或依賴的函式、全域名稱與資料形狀 |
| manifest | 內容包清單 |
| fail closed | 預設拒絕：遇到不認得或不相容的內容時拒絕，而不是猜測 |
| no-op | 不動作 |
| golden 測試 | 以固定基準輸出比對的測試 |
| fingerprint | 指紋：把一組會影響相容性的內容算成一個雜湊 |
| generation | 世代：一次完整啟用的內容包目錄，建立後不可修改 |
| scope | 範圍：global（WebHTV 維護者發布、所有設定共用）或 config（屬於某一份使用者設定） |
| LKG（last known good） | 最近一次確認可用的世代 |
| rollback | 回滾：回到較舊的版本 |
| freeze attack | 凍結攻擊：一直提供舊的 metadata，讓用戶端看不到新版本 |
| fast-forward attack | 快轉攻擊：把序號推到極大，讓之後的合法發布都被當成回滾 |
| digest | 摘要值；本文件一律指 SHA-256 |
| staging | 暫存區 |
| hand-off | 交接：把同一個播放請求交給另一個核心 |
| fallback | 備援切換 |
| entry | 清單中的一個項目 |
| sidecar | 與主檔並存的附屬檔 |
| overlay | 覆蓋：pack 的腳本蓋過同名的內建腳本 |
| content-addressed | 內容定址：以檔案內容的雜湊命名 |
| 單位 | KiB＝1,024 bytes，MiB＝1,048,576 bytes；精確值寫 bytes |

## 二、問題、原因、解法、風險

| 項目 | 內容 |
|---|---|
| 問題 | IOS-POC-13 要判斷下載的內容能不能在已安裝的 App 上執行，但現在只有一個相容性數字 `SpiderPackStore.hostApiVersion = 1`（`ios/Sources/WebHTVCore/Spider/SpiderPack.swift` `SpiderPackStore`，`:122`）。它在 repo 內漂移過一次：`7c76d5c2`（2026-09-18）改了 `host.js` 的 `:gt`／`:lt` 選擇器，版本仍是 `67e02aad`（2026-09-17）設定的 1。這次漂移**沒有到達使用者**：`7c76d5c2` 是 IOS-POC-11 發版基準 `54b9e89d` 與第一次發布 `7d18cf4a`（`0.1 (1)`）的祖先，之後 `host.js` 沒有再改，`0.1 (1)`～`0.1.21 (22)` 的 `host.js` 都是 sha256 `6bd11d38…`（以 `git merge-base --is-ancestor` 與 `git log` 確認）。但它證明手動維護的號碼會漂移，下一次可能發生在發版之後。Python shim、CatVod 輸出 schema、WebHome bridge 都沒有版本號 |
| 原因 | 契約散在程式裡，只由行為測試間接保護。`ConfigSource.identity`、`SavedSource.cacheFileName`、`Site.id`、`history.json` 世代都沒有 golden 測試；App target 沒有測試；發版 workflow（`.github/workflows/ios-sidestore-release.yml`）只以 `xcodebuild -scheme WebHTVApp` 編譯 App，測試 target 不會被編譯；使用者在 IOS-POC-20 Q6 決定不跑單元測試 |
| 為什麼先凍結再做 updater | manifest 要以穩定的契約為比較對象。若在 `SourceClient`、播放、Spider ABI、持久資料還在變時做 updater，manifest 會追著實作細節改，普通的重構會變成相容性破壞；漂移的 ABI 號碼會讓預設拒絕（fail closed）失效，該拒絕的 pack 會被接受 |
| 解法 | 以文件、golden 測試與編譯期 ABI 常數凍結 pack 會依賴的面；Native 內部語意只凍結文件與測試，不進 ABI；manifest、信任根、大小上限、回滾與用戶端安全狀態只定義、不實作（第七節）；production 只新增常數，相容性判斷函式留到 IOS-POC-13 |
| 風險 | 第一，播放契約在 IOS-POC-25／26 與 ⑲ 之前凍結會固定未驗證的行為，對策是 12E 設閘。第二，沒有執行測試的管道時「可測試」只成立一半，對策是 D2 的選項，並寫明無法證明的部分。第三，過度設計（為沒有 renderer 的 UI 或沒有變更證據的資料建立動態層），對策是第五節的窄化方案。第四，盤點在凍結前被並行任務改變，對策是第四節之零的重新比對規則 |

## 三、最佳實務研究（2026-09-25 讀取）

評級與 IOS-POC-23、24 相同：A＝原始碼、規格或官方文件；B＝維護者或 Apple 工程師討論；C＝成熟專案程式碼；D＝論壇或 issue 回報。論文不在這個評級內；R2 只讀了摘要與導論，保守列為 D。

| # | 來源 | revision | 讀取日 | 級 | 支持的論點 | WebHTV 適用性 | 對決策的影響 |
|---|---|---|---|---|---|---|---|
| R1 | https://github.com/theupdateframework/specification/blob/master/tuf-spec.md | `7dd5faca4251995063b851c060a12ac915b17ae3`（spec 1.0.36） | 2026-09-25 | A | 用戶端必須內建 root key；timestamp 版本較低是回滾、相等是不動作；過期是凍結攻擊；target 只下載到宣告長度並驗 hash；root 只讀到 W bytes；consistent snapshot 以 hash 命名；檢查 `spec_version`；快轉攻擊的復原是換 key 後刪除信任中的 timestamp／snapshot metadata（`tuf-spec.md` 5.3.11） | 單一發布者、靜態主機、沒有成熟的 Swift client；完整協定過重，用戶端規則可直接沿用 | 採「TUF-lite」：內建公鑰、簽章的遞增 `sequence`、`expires`、每檔 `bytes`＋`sha256`、manifest 大小上限、內容定址路徑、`schema` major；backup key 簽的 manifest 重設序號下限（第七節之十） |
| R2 | https://github.com/theupdateframework/theupdateframework.io/blob/main/static/papers/survivable-key-compromise-ccs2010.pdf 、`prevention-rollback-attacks-atc2017.pdf` | repo `1afcb7daff9cdae450c2e50875953026b5cd8220`（CCS 2010、USENIX ATC 2017） | 2026-09-25 | D | 更新系統對金鑰妥協與撤銷的防護不足；repository 被入侵後可回滾到有漏洞的舊版本；版本資訊必須在用戶端保護 | CI 簽章金鑰外洩是最實際的妥協；回滾到舊 spider 組合是最實際的攻擊。只讀了摘要與導論 | 內建 active 與離線 backup 兩把公鑰；每個 scope 已接受的最大 `sequence` 存在用戶端 |
| R3 | https://github.com/uptane/uptane-standard/blob/master/uptane-standard.md | `a02f9cace9e842dbc33f2151b47620a50ccc9151` | 2026-09-25 | A | 部分驗證使用「目前時間或最近安全證明的時間」，本機時鐘不可信 | 多 ECU 架構不適用；iPhone 使用者可以改時間，這一點適用 | `expires` 只擋採用該 manifest，不刪除、不停用 active 或 LKG；防回滾主要靠 `sequence` |
| R4 | https://github.com/expo/expo/blob/main/docs/pages/eas-update/runtime-versions.mdx | `40726fb4479c8b1bcb44b938c774fbc1f2036724` | 2026-09-25 | A | runtimeVersion 保證原生碼與更新相容；以 appVersion 為策略時，原生變更忘記升版就會不符；fingerprint 策略自動升版 | 與路線圖的 Native Core／Dynamic Layer 相同；WebHTV 已發 22 版，多數沒有改 host ABI | ABI 是編譯期常數，與 `CFBundleShortVersionString`／build 分開；加 fingerprint 測試 |
| R5 | https://github.com/expo/expo/blob/main/docs/pages/technical-specs/expo-updates-1.mdx | `40726fb4479c8b1bcb44b938c774fbc1f2036724` | 2026-09-25 | A | 未知欄位要允許並忽略；每個 asset 的 SHA-256 必驗；同一 URL 的 asset 不得變更；簽 manifest 即傳遞簽署 asset；使用前、下載 asset 前先驗簽；根憑證內建於 App；`rollBackToEmbedded` 指令 | 成熟的 iOS 直譯碼 OTA 協定，manifest → asset hash → 簽章鏈與需求一致 | 先驗簽、再解析、再抓檔；內容定址；定義 `rollbackToBundled`；容忍未知選填欄位 |
| R6 | https://github.com/expo/expo/blob/main/docs/pages/eas-update/code-signing.mdx | `40726fb4479c8b1bcb44b938c774fbc1f2036724` | 2026-09-25 | A | 憑證內建；憑證過期的 binary 不再套用更新；換金鑰需要新的 runtime | 信任根屬於原生契約 | 內建公鑰集合凍結為 Native Core；一開始就內建 active＋backup；原始 Ed25519 沒有到期，新鮮度靠 `expires` |
| R7 | https://github.com/expo/expo/blob/main/docs/pages/eas-update/error-recovery.mdx | `40726fb4479c8b1bcb44b938c774fbc1f2036724` | 2026-09-25 | A | 只對內容出現前的錯誤自動回滾，因為之後可能已改了持久狀態；失敗的更新標記後不再啟動；回退順序是最近成功的更新，再來是內建；「not a full safety net」 | 觀看紀錄、設定、引擎選擇、站台記憶都由 Swift 擁有；v1 pack 只有 JS，JSContext 內唯一可寫的是 `host.local`。config 擁有的 Python spider 例外，它可寫整個 App 容器（G7） | 凍結「runtime pack 不能寫 Native 持久資料」，回滾到 LKG 或內建因此對 JS pack 安全；健康判斷用確定性檢查 |
| R8 | https://github.com/expo/expo/tree/main/packages/expo-updates/ios/EXUpdates/SelectionPolicy | `40726fb4479c8b1bcb44b938c774fbc1f2036724` | 2026-09-25 | C | launcher 以 runtimeVersion 過濾；loader 只接受比啟動中更新的；清理器（reaper）保留啟動中加一個較舊的，只在同一 `scopeKey` 內刪除 | `scopeKey` 對應 global／per-config 隔離（A→B→A） | 每個 scope 保留 active＋1 個 LKG；scope key＝（信任域、config identity） |
| R9 | https://github.com/microsoft/react-native-code-push （README、`docs/api-js.md`、`docs/api-ios.md`） | `50a7ed5bc0f195f22ffefe8dad4109f1dd0b869e`（2025-05-20，已封存） | 2026-09-25 | A（已封存） | 2025-03-31 隨 App Center 退役；更新綁定 binary 版本，商店更新後回到內建 bundle；`notifyAppReady` 不呼叫就回滾；README 引用舊條號「3.3.2」 | 長期運作的 JS OTA 產品，版本綁定與 readiness marker（就緒標記）都是已知痛點 | 用 ABI 範圍而不是精確 App 版本；自架靜態 manifest；不用 readiness marker |
| R10 | https://github.com/microsoft/react-native-code-push/issues/2594 | 2023-10-06 開、同日關閉 | 2026-09-25 | D | 安裝成功後殺掉 App 再開，被誤判為「沒載入完成」而回滾 | iOS 使用者常在播放中殺 App 或進背景。只有一則回報，經 issue 搜尋讀取 | 只在確定性失敗時標記壞世代，不因 App 被殺或進背景 |
| R11 | https://github.com/shorebirdtech/docs/tree/main/src/content/docs/code-push （`system-architecture.mdx`、`guides/patch-signing.mdx`、`rollback.mdx`） | `7fb0b642988c43ecdb5cff23fa41d0a12dee403f` | 2026-09-25 | A | patch 綁一個 release；patch hash「不是安全功能」；可選簽章把公鑰內建；啟動失敗的 patch 標記 bad 不再啟動；iOS 以直譯器執行 | 印證 `SpiderPack.swift` 的註解「同源 digest 是完整性，不是真實性」，也印證 iOS 不能下載原生碼 | 本機壞世代清單，不自動重試；真實性要靠內建公鑰的簽章 |
| R12 | https://github.com/jedisct1/minisign （README、`src/minisign.c`、`src/minisign.h`） | `4ade1121ba8b65e0e7568a5b411aa4733284e8a8` | 2026-09-25 | C | Ed25519，預設簽章 `ED` 為 BLAKE2b-512 預雜湊；舊的 `Ed` 格式預設拒絕；trusted comment 另有全域簽章 | CryptoKit 沒有 BLAKE2b | 裝置端不採用 minisign 檔案格式；對 manifest 原始位元組做 Ed25519 分離簽章，sidecar 帶 `keyId`、`alg` |
| R13 | https://developer.apple.com/documentation/cryptokit/curve25519/signing/publickey/isvalidsignature(_:for:) | Apple 文件 JSON；iOS 13.0+ | 2026-09-25 | A | `Curve25519.Signing` 以 Ed25519 建立與驗證簽章 | WebHTVCore 已有 `import CryptoKit`（`SpiderPack.swift`、`Spider/DrpyEngine.swift`、`AdBlockList.swift`；`CryptoHost.swift` 用的是 `CommonCrypto`），不需新相依 | 簽章演算法定為 Ed25519，公鑰編進 Swift。RFC 8032 本文無法讀取 |
| R14 | https://developer.apple.com/app-store/review/guidelines/ | Last Updated: June 8, 2026 | 2026-09-25 | A | 2.5.2 不得下載、安裝或執行會新增或改變功能的程式碼；4.7 允許 HTML5／JS mini app；4.7.2 不得對下載的軟體擴充或暴露原生 API | SideStore 不受 App Review 約束，但這定義了路線圖選定的保守邊界 | pack 只能改直譯腳本、規則與資料；不能新增或暴露原生 primitive（原生基本功能），host API 只隨 IPA 成長 |
| R15 | https://developer.apple.com/support/terms/apple-developer-program-license-agreement/ | 目前網頁版（未取得修訂日） | 2026-09-25 | A | §3.3.1(B)：不得下載或安裝可執行碼；直譯碼可下載，條件是不改變主要用途、不繞過簽章或沙盒等 OS 安全機制；(c) 只限 App Store。§3.3.2 現為 Regulatory Compliance | 條件 (b) 與發布通路無關；免費 Apple ID 簽章適用的條款不同 | 文件引用 DPLA §3.3.1(B) 與 Guidelines 2.5.2、4.7.2，不再用舊的「3.3.1／3.3.2」 |
| R16 | https://developer.apple.com/documentation/browserenginekit/protecting-code-compiled-just-in-time | Apple 文件 JSON（目前版） | 2026-09-25 | A | 系統以硬體強制記憶體頁只能可寫或可執行（W^X）；切換需要瀏覽器引擎專用的 JIT entitlement | 一般 sideload App 沒有這些 entitlement。Apple Platform Security guide 被擋，以此文件代替；debugger JIT 手法未研究，不得依賴 | 取消「可能可執行」分類：需要可執行記憶體頁的一律 Native Core；JavaScriptCore 上的 JS、已出貨 CPython 上的 `.py` 是 Dynamic Layer |
| R17 | https://developer.apple.com/documentation/foundation/filemanager/replaceitemat(_:withitemat:backupitemname:options:) | Apple 文件 JSON；iOS 8.0+ | 2026-09-25 | A | 以「不會遺失資料」的方式取代；只能在同一 volume；失敗時原檔可能留在暫存位置 | `SpiderPackStore.write` 的註解宣稱當機時不會混合新舊，比 Apple 文件寫的更強 | IOS-POC-13 用不可變的世代目錄＋一個小指標檔；既有 swap 只記錄，12 不改 |
| R18 | https://developer.apple.com/documentation/foundation/nsdata/writingoptions/atomic | Apple 文件 JSON（目前版） | 2026-09-25 | A | 先寫輔助檔，完成後取代原檔 | 單檔指標切換的原語；斷電持久性未說明 | 指標與安全狀態以 `Data.write(options: .atomic)` 寫在世代所在的 volume |
| R19 | https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files （另 `fileprotectiontype/completeuntilfirstuserauthentication`、`urlresourcevalues/isexcludedfrombackup`） | Apple 文件 JSON（目前版） | 2026-09-25 | A | 預設 `completeUntilFirstUserAuthentication` 在第一次解鎖後可讀；`complete` 只在解鎖時可讀；背景 App 要選背景可用的等級；`isExcludedFromBackup` 用於不需備份的支援檔 | 鎖定中有 PiP、背景音訊與自動下一集，spider 可能在鎖定時載入 | 世代、指標與安全狀態用 `completeUntilFirstUserAuthentication`；世代排除備份，安全狀態不排除（第七節之十） |
| R20 | https://github.com/semver/semver/blob/master/semver.md | `f99d5485190a47c0863949e7da810a5553e0ed4d`（SemVer 2.0.0） | 2026-09-25 | A | 公開 API「SHOULD be precise and comprehensive」（`semver.md:60`）；已發布內容不得修改；MAJOR 不相容、MINOR 相容新增並在棄用時升；0.y.z 不穩定 | ABI 是動態內容比較的對象；PATCH 對 ABI 閘沒有意義 | 每個面用（major、minor）；相容＝major 相同且 minor 不小於要求；從 1.x 起；已發布的 `sequence` 不可變 |
| R21 | https://github.com/protocolbuffers/protocolbuffers.github.io/blob/main/content/programming-guides/proto3.md （#updating、#unknowns） | `c00537c22ece49df397a05586e77af033991ab85` | 2026-09-25 | A | 新增欄位對舊 parser 安全，會當成未知欄位；列舉新增值會破壞 exhaustive switch | 標準的 schema 演進規則，原則適用 JSON | 新增選填欄位是 MINOR；語意改變要新 major；列舉型欄位以 String 解碼，未知值拒絕該 entry，不讓解碼失敗 |
| R22 | https://github.com/swiftlang/swift-evolution/blob/main/proposals/0166-swift-archival-serialization.md | `cf74276b94dbf0bb4bd9c7fbd8617f2e1b9bd9c2` | 2026-09-25 | A | keyed container 依 key 解碼，有 `decodeIfPresent`、`allKeys` | 現行 `SpiderPackManifest` 用合成的 `Decodable`，會忽略多餘 key（實務行為，不是 SE-0166 的規範語句） | 保留容忍未知選填欄位；另加 `critical`（必須理解）清單，讓語意必要的新增能預設拒絕 |
| R23 | https://github.com/sigstore/docs （`content/en/about/overview.md`、`about/security.md`、`language_clients/`） | `842c30981f1bf5061fe0d370512db4de8cdf3b33` | 2026-09-25 | A | keyless 簽章用短效 Fulcio 憑證與 Rekor 透明度 log，信任根以 TUF 發布；列出的 client 沒有 Swift | 裝置端要驗 X.509 鏈、Rekor 證明與 TUF 根，沒有 Swift client | 不用於 App 內驗證；最多用於 CI 出處紀錄，不在 12 契約內 |
| R24 | https://github.com/expo/expo/issues/48148 | 2026-07-26 開（未關閉） | 2026-09-25 | D | runtime version 存在可翻譯的 Android 字串資源，被 Play 自動翻譯改寫，裝置約七週拿到乾淨的「沒有更新」，沒有任何錯誤 | 機制是 Android 的，但「ABI 放在可變資源會靜默漂移」「相容性不符看起來像沒有更新」適用 iOS | ABI 是 Swift 編譯期常數，不放 Info.plist 或資源；「需要較新的 App」與「沒有更新」是不同的可見狀態 |
| R25 | https://github.com/expo/expo/issues/47920 | 2026-07-17 開（issue 記載 main 已由 expo/expo#45058 修正；該 PR 未讀） | 2026-09-25 | D | updater 在啟動關鍵路徑上，log queue 與無上限的 log 造成死結，畫面凍結但不當機，錯誤回復永遠不觸發 | WebHTV 啟動不可依賴 updater I/O 成功；卡住和當機一樣要處理 | 凍結啟動契約：選世代是 O(1)，讀指標、驗小 manifest，不連網、不重播 log；任何失敗選 LKG 或內建 |

證據類別的涵蓋情形：

1. 上游原始碼與測試：本任務沒有要合併的外部上游 commit。對等的上游是本 repo 的 Android FongMi 原始碼，bridge 與觀看紀錄的相容性以它為準：`app/src/main/java/com/fongmi/android/tv/web/HomeWebBridge.java`、`app/src/main/java/com/fongmi/android/tv/bean/History.java`、`app/src/main/java/com/fongmi/android/tv/db/dao/HistoryDao.java`、`app/src/main/java/com/fongmi/android/tv/server/process/Media.java`、`catvod/src/main/java/com/github/catvod/utils/Trans.java`。
2. 官方規格與平台文件：R1、R3～R7、R9、R11、R13～R23。
3. 上游 PR、issue、revert 與維護者討論：R10、R24、R25（都是 issue 回報，列 D）。
4. 成熟相關專案程式碼：R8、R12。
5. 論文、技術文章、實地回報：R2。

判定不適用或無法取得的證據類別：

1. 完整 TUF／Uptane client 程式庫（python-tuf、go-tuf、rust-tuf、aktualizr）：沒有成熟的 Swift client，單一發布者的靜態主機也讓完整協定不成比例，只採用規格規則；Uptane 的 Director／Image repository 與多 ECU 部分不適用單一 iOS App。
2. 簽章與雜湊驗證的效能基準：一次 Ed25519 驗證加上數 MiB 的 SHA-256，相對網路下載可忽略，沒有設計選擇取決於它。
3. 被出口 proxy 擋住的官方網站，以 GitHub repo 或 developer.apple.com JSON 的原始來源代替：docs.expo.dev、theupdateframework.io、semver.org、docs.sigstore.dev、docs.shorebird.dev、minisign 文件站、man.openbsd.org（signify）、learn.microsoft.com、support.apple.com（Apple Platform Security guide；W^X 改以 BrowserEngineKit 文件佐證）、rfc-editor.org 與 ietf.org（RFC 8032、RFC 7515 `crit` 無法讀取；「必須理解」的設計改以 TUF `spec_version` 與 protobuf 演進規則為依據）。
4. expo/expo 與 microsoft/react-native-code-push 的 issue 直接讀取被 session 範圍拒絕，改以 issue 搜尋讀取本文，只引用這些 issue。
5. GitHub issue 以外的部落格與論壇：規格、成熟程式碼與 issue 回報已足以決定每個設計問題，不再追加。SideStore 專用的 JIT 或 debugger 手法刻意不研究，產品不得依賴。

停止條件：再多的來源不會改變上述決策。仍未決的是 D3（私鑰存放）、D13（是否要 global 發布通道）與 D14（用戶端安全狀態存在檔案還是 Keychain），都是使用者或 IOS-POC-13 的決定，不是研究問題。

## 四、現況盤點（基準 `a6652cc3`）

### 之零、基準、寫法與重新比對規則

1. 基準：`origin/ios-poc` `a6652cc3`。與規劃草案使用的 `0b0d0b5f` 相比，只有 `PlaybackEngine.swift`、`WebHTVApp.swift`、`PlaybackEngineTests.swift` 與三份文件改變，這三個程式檔的引用都已重新定位。
2. 位置寫法：
   - `ios/Sources/WebHTVCore/` 下的檔案只寫檔名（含 `Spider/`、`Spider/Host/` 子目錄的檔案），檔名在 repo 內唯一。
   - `ios/WebHTVApp/Sources/` 下的 App 檔也只寫檔名（`WebHTVApp.swift`、`MPVEngine.swift` 等）。
   - Python 寫 `base/spider.py`、`base/__init__.py`、`webhtv_runtime.py`（在 `ios/WebHTVApp/Python/`）；內建 JS 寫 `host.js` 等（在 `ios/Sources/WebHTVCore/Resources/Spiders/`）；測試寫測試檔名與測試函式名（在 `ios/Tests/WebHTVCoreTests/`）。
   - 兩個 `Package.swift` 與 workflow、scripts、lock 一律寫完整路徑。
   - 行號只作輔助，以符號為準。
3. 凍結前重新比對（12A 的第一步，不得省略）：
   - `git fetch origin ios-poc`，記下凍結 HEAD 的完整 SHA。
   - 比對範圍只含 iOS 相關路徑：`ios`、`third_party/python-ios-lock.json`、`third_party/mpv-ios-lock.json`、`third_party/mpv-ios`、`.github/workflows/ios-*.yml`、`scripts/spider_pack.py`、`scripts/update_sidestore_source.py`、`scripts/fetch_python_ios.sh`、`source.json`、`webhome-devkit/templates/homepages/app-capabilities-showcase.html`（A31），以及凍結 HEAD 上新出現、名稱含 `ios` 的 `scripts` 或 `.github/workflows` 檔案。`third_party`、`scripts`、`.github` 其餘的 Android 專用檔案不在盤點範圍。
   - `git diff --stat a6652cc3..<凍結 HEAD> -- <上述路徑>`：每個變更檔都要對到至少一個 K、A、M 或 G 列，逐列更新位置與內容。
   - `git ls-files -- <上述路徑>` 與第四節之二的「位置」欄比對：新增的檔案要新增一列並分類，刪除的檔案標成已移除。
   - 以符號重新定位每一列（`grep -n <符號>`），不從舊行號推算。
   - IOS-POC-25、26 碰到的列（預期至少有 K16～K18、K21、K27～K30、K39、A18、A20、A33，以及 IOS-POC-25 新增的廣告規則或 host 清單）標成「暫定」。12A 只宣告其餘列 v1 生效，暫定列在 12E 一併凍結。
   - 比對結果寫進本文件第十一節與 12A 的 commit message。

### 之一、要凍結的契約

分三組。只有第一組進 runtime ABI（第六節）；第二、三組只凍結文件語意與 golden 測試，pack 不能依賴，也不能改變。「缺口」欄是凍結前要補或要記錄的事，不代表 12 會修改行為。

**第一組：runtime pack 與 config 擁有的腳本會依賴**

| # | 契約（凍結名稱） | 位置 | 主要使用者 | 既有測試 | 缺口 |
|---|---|---|---|---|---|
| K1 | Spider ABI（屬 `catvod.result` 1.0） | `SpiderRuntime.swift` `SpiderRuntime`（13 個方法）、其 extension 的預設實作、`SpiderError`；`SpiderSession.swift` `SpiderSession` | `SpiderSession`（唯一的 production 呼叫端）、`JavaScriptSpiderRuntime`、`PythonSpiderRuntime`、`PythonSpiderSupport` | `SpiderHostTests` `bridgesValuesAndErrorsBetweenSwiftAndJavaScript`；`DrpyEngineTests` `theBridgeAnswersTheSpiderABIByDelegatingToTheLoadedEngine` | 13 個方法中 8 個有 production（非 DEBUG）呼叫：`initialize`、`homeContent`、`homeVideoContent`、`categoryContent`、`detailContent`、`searchContent`、`playerContent`、`destroy`，全部經 `SpiderSession`。`liveContent`、`isVideoFormat`、`manualVideoCheck`、`action` 只有 DEBUG 的 `PythonBoot.selfCheck` 呼叫，`proxy` 沒有任何呼叫端；這 5 個都沒有 host 支援。沒有測試釘住可達集合 |
| K2 | CatVod 輸出 schema 1（屬 `catvod.result`） | `CMSClient.swift` `CMSResponse`、`CMSFilter`（含 `Option`）、`CMSCategory`、`Vod`、`Flag`、`Episode`、`PlayResponse`；`SourceClient.swift` `SpiderPlayResponse`；`PlayURL.swift` `PlayURL`、`PlayURL.Value` | `SourceClient` 的 `home`、`category`、`search`、`detail`、`playbackURL`；UI；`PlaybackTarget` | `SourceClientTests`、`PlayURLTests`（14 個）、`CMSClientTests`（19 個） | 解碼寬鬆（`decodeIfPresent`），需要新解碼器的 pack 會靜默退化。8 個內建 spider 共經過 12 個不同的 commit，其中 3 個同時改了解碼器或 UI（`d786c627`、`0ab06a3c`、`f34ae805`）。各型別的 `CodingKeys` 是 internal、不是 `CaseIterable`，無法在執行期列舉（fingerprint 做法見第六節之十） |
| K3 | ext → `init(extend)` 字串（屬 `catvod.result`） | `WebHTVConfig.swift` `Site.rawExtJSON`、`JSONValue.extendText`；`CSPSourceResolver.swift` `resolvedExtend(for:)`、`resolvingNestedPaths(in:)` | 每個 JS、Python、drpy spider 的 `init` | `SpiderHostTests` `resolvesARuleFileExtAgainstTheConfigurationDirectory` 等；`CMSClientTests` | 物件 ext 以不排序的 `JSONSerialization` 重新序列化，位元組順序不固定；golden 必須比較解析後的 JSON |
| K4 | JS host（`js.host` 1.1） | `host.js` 匯出物件 `host`（`:464-473`）；`CatVodHost.swift` `CatVodHost.install`；`HTTPHost.swift` `HTTPHost`、`CookieJar`；`CryptoHost.swift` `CryptoHost`；`StorageHost.swift` `StorageHost`、`SpiderStorage`；`DrpyEngine.swift` `DrpyEngine.rewritten(_:named:)`、`DrpyEngine.moduleRuntime`；`JavaScriptSpiderRuntime.swift` `JavaScriptSpiderRuntime`；`drpy-bridge.js`、`js-spider.js` | 8 個內建 spider、相容包、drpy2 與 9 個 lib、CatVod JS spider | `SpiderHostTests`（17 個：選擇器、加密、cookie、隔離）；`DrpyEngineTests`（27 個：模組、promise、bridge）；`SpiderPackTests` 兩個 `minHostApi` 測試 | `SpiderPackStore.hostApiVersion` 未隨 `7c76d5c2` 升版（沒有出貨，見第二節）；沒有 digest 綁定測試；`JavaScriptSpiderRuntime` 的 `timeout` 存了但不強制（沒有 CPU watchdog）；`HTTPHost.perform` 的回應 body 沒有上限 |
| K5 | Python host（`python.host` 1.0） | `PythonSpiderRuntime.swift` `PythonSpiderRuntime`（`call`、`bridge`、`unwrap`）；`webhtv_runtime.py` `load`、`invoke`、`unload`、`diagnostics`；`base/spider.py` `Spider`；`base/__init__.py`；`PythonBoot.swift` `PythonBoot.boot`（`sys.path` 順序）；`third_party/python-ios-lock.json` | 42 個 Python 站台（14 個能執行、6 個到媒體，IOS-POC-7P） | `PythonRoutingTests`（8 個，只有路由與傳輸）；`PythonBoot.selfCheck`（DEBUG） | 沒有版本號；`base/spider.py` 模組層級的 `_site_key`、`_cache_dir` 由 `load` 覆寫，先載入站台的 `getCache`／`setCache` 會寫到最後載入站台的檔案（既有缺陷，只回報，G10） |
| K6 | 路由判定（routing 1，原生規則） | `WebHTVConfig.swift` `Site.isNativeCMS`、`isCSPSpider`、`isDrpySpider`、`isPythonSpider`、`drpyRuleReference`、`isSpiderShape`；`DrpyEngine.swift` `isJavaScriptSpider(_:)`；`CSPSourceResolver.swift` `canResolve(_:)`、`session(for:)` | `WebHTVConfig.drivableSites`、`SourceClient.make` | `SpiderHostTests` `routesCSPSitesThroughTheRegistryRatherThanRejectingTypeThree`；`PythonRoutingTests` 三個；`DrpyEngineTests` 六個 | pack 可以新增 `csp_` class，不能新增路由種類；待辦的 Python 相依工作會碰 `canResolve` |
| K7 | Registry 優先順序與 alias（原生規則） | `SpiderRegistry.swift` `SpiderRegistry.active`、`bundled(bundle:overlaying:)`、`bundledOnly`、`ported`、`aliases`、`makeRuntime(for:siteKey:…)` | `CSPSourceResolver`、`drivableSites` | `SpiderPackTests` 三個；`SpiderGoldenTests` `registryClaimsOnlyWhatIsActuallyPorted` | pack script 載入失敗時不回退內建 script（沒有 per-class fallback，G2） |
| K8 | 相容包 manifest schema 1（舊格式） | `SpiderPack.swift` `SpiderPack`、`SpiderPackManifest`、`SpiderPackStore`、`InstalledSpiderPack` | `WebHTVApp.swift` `ConfigView.adoptCachedSpiderPack`、`refreshSpiderPack`；`SpiderRegistry.active`；`scripts/spider_pack.py` | `SpiderPackTests`（12 個）；`SpiderGoldenTests` 一個需要連網 | 見之四 G1～G6、G24 |
| K9 | config 相對解析（原生規則） | `ConfigSource.swift` `ConfigSource.baseURL`、`resourceURL(for:)`；`WebHTVConfig.swift` `Site.isResourceReference` | `CSPSourceResolver`、`DrpyEngine`、`PythonSpiderSource`、`SpiderPackStore.url(for:defaults:)`、`WebHomeBridge.handle` | `ConfigSourceTests`（7 個） | `;md5;` 後綴被切掉且不驗證，不是完整性；新 manifest 只能沿用這條規則或相對 manifest 自己解析，不得有第三種 |
| K10 | config 擁有的腳本傳輸閘（原生規則） | `DrpyEngine.swift` `checked(_:origin:)`、`download(_:limit:session:)`、`maximumFileBytes`、`maximumBundleBytes`、`maximumRuleBytes`、`script(at:source:…)`、`rule(at:source:…)`、`downloadSession`；`PythonSpiderSource.swift` `maximumScriptBytes`、`script(for:source:…)` | drpy 站台、`麻豆(js)`、Python 站台 | `PythonRoutingTests` 五個；`DrpyEngineTests` 七個 | 同源只比 host 與 port，在 gitlab.com 這類多租戶主機上不代表同一擁有者；drpy／JS 的 `downloadSession` 使用共用 URLCache（G13） |

**第二組：設定內容依賴的原生解讀規則**

| # | 契約（凍結名稱） | 位置 | 主要使用者 | 既有測試 | 缺口 |
|---|---|---|---|---|---|
| K11 | config schema v1（只讀 `sites`、`ads`、`rules`；每站只讀 key、name、type、api、ext、searchable） | `WebHTVConfig.swift` `WebHTVConfig`、`Site`（含 `CodingKeys`） | `WebHTVApp.swift` `ConfigView.rebuildSites`、`adopt(_:config:from:)`、`restore`；`AggregateSearch.sites(from:)` | `ConfigLoaderTests`（3 個）；`SourceClientTests`；`AggregateSearchTests` | 一個站缺欄位就拒絕整份設定（Android Gson 較寬容），凍結為預設拒絕規則；沒有測試列出被忽略的 key |
| K12 | configIdentity v1（`absoluteString` 原樣，或 `imported`） | `ConfigSource.swift` `ConfigSource.identity`；`SavedSource.swift` `SavedSource.id` | `WatchHistory.sourceID`、`selectedSiteBySource`、`PlaybackTargetIdentity`、快取檔名、`DrpyEngineStore` | 沒有直接釘住的測試；`WatchHistoryTests`、`NextPlaybackTargetTests` 間接涵蓋 | 缺 golden 與「不正規化」測試；IOS-POC-13 的 config scope key 必須以它為準 |
| K13 | Site identity v2（key＋NUL＋排序後的 ext JSON） | `WebHTVConfig.swift` `Site.id`、`JSONValue.identityText`；`SiteSelection.swift` `SiteSelection.canonicalStructuredExtend` | spider session、站台記憶、觀看紀錄、`PlaybackTargetIdentity`、搜尋去重 | `SiteSelectionTests`（9 個）；`WatchHistoryTests` | 不含 api、type、config identity；缺代表性 golden；任何改變都要帶遷移（如 `8df71c12`） |
| K14 | 設定 LKG 閘 | `ConfigLoader.swift` `ConfigLoader.decode`、`validate`、`fetch(from:)`、`ConfigLoaderError` | `WebHTVApp.swift` `ConfigView.load(remote:showHome:reportFailure:)`、`rebuildSites`、`restore` | `ConfigSourceTests` | 沒有大小上限、digest、真實性；接受 http；錯誤文字沒提 type-0。pack 不得經過或放寬這個閘 |
| K15 | 共用傳輸政策（10 秒、無 URLCache） | `ConfigLoader.swift` `URLSession.webHTV` | 設定、CMS、spider HTTP、media probe、相容包 | `CMSClientTests` | IOS-POC-13 的 manifest 與檔案下載要同樣繞過 HTTP 快取，另用較長逾時的 session |
| K16 | `ads` → sniffer content blocker | `AdBlockList.swift` `AdBlockList.make(ads:)`、`filter(for:)`；`MediaSniffer.swift` `MediaSniffer.contentRules`；`WebHTVApp.swift` `ConfigView.adoptAdBlocking(from:)` | `MediaSniffer.Collector`、`WKContentRuleListStore` | `AdBlockListTests`（9 個） | 識別碼推導改變會孤立已編譯的清單；清單從不清理。IOS-POC-25 可能改到，列暫定 |
| K17 | `rules` 優先順序與 `script` | `SnifferRules.swift` `SnifferRule`、`SnifferRules.make(rules:)`、`rule(for:)`、`verdict(for:)`、`script(for:)`；`MediaSniffer.swift` `MediaSniffer.sniff`、`Collector` | `MediaSniffer.Collector`、`SourceClient.target(from:headers:parse:)` | `SnifferRulesTests`（31 個） | 若出現 global 規則，順序必須是 config → global → 內建。IOS-POC-25 可能改到，列暫定 |
| K18 | 內建 sniffer 與 `MediaProbe` | `MediaSniffer.swift` `MediaProbe.classify`、`MediaSniffer.defaultKeywords`、`defaultExclusions`、`isCandidate`、`embeddedMedia`、`Collector.hook`（注入每個 frame 的 JS） | `SourceClient.target(from:headers:parse:)`、`resolveMedia` | `MediaSnifferTests`（11 個）；`SnifferRulesTests` | 無。IOS-POC-25 可能改到，列暫定 |
| K19 | MacCMS／type-4 請求協定 | `CMSClient.swift` `CMSClient`（`home`、`category`、`listingQuery`、`playbackURL`、`search`、`detail`、`detailAction`）；`MacCMSXML.swift` `MacCMSXMLDecoder` | `SourceClient` 的 `.cms` 分支、`WebHomeBridge` | `CMSClientTests`；`MacCMSXMLTests`（4 個） | 無 |
| K20 | 聚合搜尋參與規則與關鍵字繁轉簡 | `AggregateSearch.swift` `AggregateSearch`（`sites(from:)`、`run`、`defaultLimit`、`defaultDeadline`）；`TraditionalSimplified.swift` `TraditionalSimplified.toSimplified` | `WebHTVApp.swift` `AggregateSearchView.search(in:)` | `AggregateSearchTests`（8 個） | 無；上限與期限是原生常數 |
| K21 | `PlaybackTarget` 與請求 headers 的套用方式 | `SourceClient.swift` `SourceClient.playbackURL(for:flag:)`、`target(from:headers:parse:)`、`resolveMedia`、`PlaybackTarget`；`WebHTVApp.swift` `PlaybackSession.asset(for:headers:)`（`:2961`）；`PlaybackEngine.swift` `MPVRequestHeaders` | `PlaybackSession.open`、畫質切換、AVPlayer、MPV、`MediaProbe`、`NextPlaybackTarget` | `SourceClientTests`；`PlaybackEngineTests` `everyHeaderReachesMPVAsOneField`；`NextPlaybackTargetTests` | WebView sniff 只帶 `Referer`；AVPlayer 用未公開的 `AVURLAssetHTTPHeaderFieldsKey`，真機未確認（8L ⑨）；CR／LF 過濾只在 MPV。媒體 URL 的 scheme 規則見 K28。IOS-POC-25 可能改到，列暫定 |

**第三組：Native 內部語意（不進 runtime ABI）**

| # | 契約（凍結名稱） | 位置 | 主要使用者 | 既有測試 | 缺口 |
|---|---|---|---|---|---|
| K22 | 持久資料配置 v1（名稱總表見 A10） | `SavedSource.swift` `SavedSource`、`SavedSourceList`、`cacheFileName`；`WebHTVApp.swift` 檔案層級的 `selectedSiteKey`、`siteBySourceKey`、`configSourceURLKey`、`configUpdatedAtKey`，`ConfigView.persistSaved`、`savedSourcesURL`、`configURL(for:)`、`migrateLegacyCache(to:)`；`WatchHistory.swift` `WatchHistoryStore`；`PlaybackEngine.swift` `PlaybackEnginePreference.key` | `ConfigView`、`SettingsView`、`PythonLiveCheck`（DEBUG） | `SavedSourceTests`（7 個） | App target 沒有測試；沒有 `cacheFileName` golden；URL 約 187 bytes 以上時檔名超過 255 bytes，無法採用（G14） |
| K23 | 站台選擇 token 與逐來源記憶 | `SiteSelection.swift` `SiteSelection.token(for:)`、`resolve`、`choose(remembered:current:in:)`；`WebHTVApp.swift` `ConfigView.adopt(_:config:from:)`、`siteMemory` | `choose()`、`pickedSite` | `SiteSelectionTests`（9 個） | 啟用新世代時只能經 `choose()`，不得寫記憶 |
| K24 | `SpiderSession` 生命週期與 `SpiderSessionStore` | `SpiderSession.swift` `SpiderSession`；`SourceClient.swift` `SpiderSessionStore.session(for:resolver:)`、`reset` | `SourceClient`、`WebHTVApp.swift` `ConfigView.refreshSpiderPack`、`adopt` | `SourceClientTests`；需要連網的 golden | key 只有 `Site.id`；adopt 時的 reset 沒有 await（G9） |
| K25 | spider 持久狀態配置 | `StorageHost.swift` `SpiderStorage`（前綴 `spider_<siteKey>_`）；`PythonSpiderRuntime.swift` `defaultCacheDirectory`；`base/spider.py` `Spider._cache_file`；`SpiderPack.swift` `SpiderPackStore.defaultDirectory` | 使用 `host.local` 的 JS spider、Python `getCache`／`setCache`、`SpiderPackStore` | `SpiderHostTests` `keepsTwoSitesOnTheSameSpiderClassFullyIsolated`；`SpiderGoldenTests` `jianPianRemembersWhatWorked` | 不分設定（G8）；改名會孤立已存的 token |
| K26 | 引擎種類、偏好 key 與 `PlaybackEngineSelection` | `PlaybackEngine.swift` `PlaybackEngineKind`、`PlaybackEngineCapabilities`、`PlaybackEnginePreference`、`PlaybackEngineSelection` | `PlaybackSession`、設定頁、控制列 | `PlaybackEngineTests`（40 個中的選擇類） | pack 不得讀寫 `webhtv.playback.defaultEngine`；設定也沒有選引擎的欄位 |
| K27 | `PlaybackFailure` 分類與每次嘗試一次 fallback | `PlaybackEngine.swift` `PlaybackFailure`（`classify`、`allowsEngineFallback`、`avCapabilityCodes`、`mpvCapabilityCodes`）、`PlayerRouter.startupTimeout`（`:409`；IOS-POC-27A 改為 `startupTimeout(for:)`，原生 5 秒、MPV 20 秒）、`startupTimedOut`、`engineFailed` | `AVPlayerEngine.report`、`MPVEngine`、`PlaybackSession.watchStartup`、失敗畫面 | `PlaybackEngineTests` 的分類與 fallback 測試（如 `aStartThatNeverComesTriesTheOtherEngineOnce`） | `docs/IOS-POC-17-dual-internal-player.md` 第十節「契約」小節的表仍是 17B 規則（G19）；`PlaybackActivityTests` 的 `aNativeStartIsGivenUpOnSoonerThanAnMPVStart` 斷言 5／20 秒；沒有測試直接斷言開播逾時以 `engineCapability` 計入 fallback |
| K28 | `PlaybackEngine` 協定、`PlaybackLoadRequest` 與引擎邊界的 URL | `PlaybackEngine.swift` `PlaybackLoadRequest`（含 26-1 的 `exactStart`，`:277`；`resumed(at:rate:autoplay:exact:)`，`:292`）、`PlaybackEngine`、`PlaybackEngineState`；`MPVEngine.swift` `MPVEngine.load`、`MPVPlayerCore.load(url:headerFields:startSeconds:rate:autoplay:)`；`WebHTVApp.swift` `PlaybackEngines`、`AVPlayerEngine` | `PlayerRouter`、`PlaybackSession`、測試的 `FakeEngine` | `PlaybackEngineTests` `switchingAVPlayerToMPVKeepsTheTargetPositionRateAndIdentity`、`onlyAPositionAnEngineReportedIsLandedOnExactly`（26-1）等 | 哪些 URL scheme 可以進引擎沒有明文：CMS 的集數網址（`Episode.mediaURL`）與 WebHome 的 `playUrl`（`WebHomeBridge.playableURL`）只收 http／https，但 type-4 `?play=` 回應、spider `playerContent` 結果與畫質項目都經 `SourceClient.target(from:headers:parse:)`，沒有 scheme 檢查；`file://…/x.mp4` 能通過 `CMSClient.isDirectMedia`。這是契約缺口，決策見 D7。`exactStart` 未編譯、未執行測試 |
| K29 | `PlayerRouter` 交接（位置與精確度、速度、暫停、autoplay） | `PlaybackEngine.swift` `PlayerRouter`（`open`、`select(_:playing:)`、`setRate`、`reload(at:autoplay:)`、`run`、`engineFailed`、`handOff(autoplay:)`）；`MPVEngine.swift` `MPVEngine.currentTime`、`MPVPlayerCore.drain` 的 `time-pos`；`WebHTVApp.swift` `PlaybackSession.loadNative`（`:2897`，26-1 的零容差 seek）、`AVPlayerEngine.load` | 控制列切換、2.5／3× 交給 MPV、開播逾時（原生 5 秒、MPV 20 秒）、背景重新載入、續播 | `PlaybackEngineTests` 的切換、高倍速、fallback、reload 測試（26-1 在這些既有測試加了 `exactStart` 檢查）與新增的 `onlyAPositionAnEngineReportedIsLandedOnExactly` | `FakeEngine.load` 把 `currentTime` 設成剛好 `startSeconds`，抓不到引擎端誤差；緩衝中手動切換會以暫停抵達（G20，IOS-POC-27A 已修正）；有廣告 HLS 上 AVPlayer 用播放清單時間、mpv 用封包 PTS（IOS-POC-26 RC3），「位置」的意思未定；**等 IOS-POC-25、26 結束再凍結**（12E）；IOS-POC-27A：`startupTimeout(for:)` 依核心（原生 5 秒、MPV 20 秒），`select(_:playing:)` 由 App 傳入播放意圖 |
| K30 | `PlaybackSession` 速度、續播與畫質切換 | `WebHTVApp.swift` `PlaybackSession`（`open(url:headers:title:…)`、`open(_:preferredQuality:title:…)`、`selectQuality`、`setRate`、`seek(toSeconds:)`、`persist`、`start(at:)`、`load(_:autoplay:)`） | `VodView`、`Playback.start`、WebHome 播放 | `WatchHistoryTests`（只有 core） | session 接線在 App target，沒有測試；2026-09-22 起到 `a6652cc3` 共 18 次 commit 改到 `PlaybackSession` 所在區段（`git log -L` 量測）。IOS-POC-26 可能改到，列暫定 |
| K31 | `PlaybackTargetIdentity` 與下一集預解析 | `NextPlaybackTarget.swift` `PlaybackTargetIdentity`、`NextPlaybackTarget`、`PlaybackTargetPrefetch`（`maximumAge`）、`PlaybackPrefetchMiss` | `VodView`、`PlaybackSession.selectQuality`、`PlaybackPrefetchGate` | `NextPlaybackTargetTests`（16 個） | 沒有世代；啟用後舊世代解析的目標最多仍有效 300 秒 |
| K32 | 內嵌音軌模型、生命週期（暫停後重新載入、PiP、音訊工作階段）、控制列與速度 | `PlaybackMediaSelection.swift`；`PausedBackgroundReload.swift` `PausedBackgroundReload`；`PictureInPictureForegroundRestoreState.swift`；`WebHTVApp.swift` `PlaybackSession.noteEnteredBackground`、`noteBecameActive`、`reloadPaused(at:)`、`restoreTracksAfterReload`、`activateAudioSession`；`MPVEngine.swift` `MPVPlayerCore.init(layer:)` 的音訊工作階段選項；`PlayerChrome.swift` | `PlaybackSession`、`MPVEngine`、控制列 | `PausedBackgroundReloadTests`（12 個）；`PictureInPictureForegroundRestoreStateTests`（3 個）；`PlayerChromeTests`（9 個）；`PlaybackEngineTests` 的音軌測試 | 音訊工作階段沒有測試，`0.1.21 (22)` 真機未驗證；綁定 Libmpv patch 0004 |
| K33 | `history.json` schema v1 | `WatchHistory.swift` `WatchHistory`（`Codable` 欄位）、`WatchHistoryStore` | `PlaybackSession.persist`、`VodView`、`HistoryView`、`WebHomeBridge` 的 `app.history` | `WatchHistoryTests`（42 個） | 沒有 schema 版本；解不開就當成空的，下次儲存會覆寫；降版 IPA 會丟掉新欄位；缺三個世代的 fixture |
| K34 | 觀看紀錄主鍵與設定綁定 | `WatchHistory.swift` `WatchHistory.separator`、`key`、`key(siteID:vodId:)`、`sourceID`、`siteID`、`reidentified(to:)`、`androidKey`；`WatchHistoryStore.records(for:now:)`、`migrateSiteIdentities(in:now:)` | `WatchHistoryStore`、`VodView`、`HistoryView`、速度延續 | `WatchHistoryTests` | 缺 golden；Dynamic Layer 的任何對照都必須在 identity 算完之後才套用 |
| K35 | 續播公式與片頭片尾 | `WatchHistory.swift` `resumePosition`、`isNearEnding`、`startPosition(resuming:)`、`hasReachedEnding`、`openingEndingLimit`、`canSetOpening`、`canSetEnding`；`WebHTVApp.swift` `PlaybackSession.open`、`setOpening`、`setEnding`、`markOpening`、`markEnding`、`startSampling` | `PlaybackSession`、控制列、`app.history` | `WatchHistoryTests` | 無；pack 不得設定 |
| K36 | WebHome bridge ABI（注入 SDK、訊息形狀、方法表、Android 形狀 payload、`cache.*`、inline resolver、`player.control`／`player.status`） | `WebHomeBridge.swift` `WebHomeBridge`（`sdkScript`、`messageHandlerName`、`handle(method:payload:)`、`historyText`、`statusText`、`inlineVod`、`cacheKey`、`playableURL`、`netRequest`、`decodeMessage`）；`WebHTVApp.swift` `PlaybackSession.control(_:)`、`status()`、`androidState(_:)`，`deviceInfo()`，`WebHomeWebView` 與其 `Coordinator` | 內建的 showcase 頁 | `WebHomeBridgeTests`（16 個）；`WatchHistoryTests` | 沒有 `sdkScript` 雜湊測試；沒有 frame／origin 閘（G18）；`app.history` 跨設定（G17）；`prev`／`next` 與 Android 不同；狀態對照在 App target，無法測 |
| K37 | 發布身分（版本／build、bundle id、`source.json`、tag 命名空間） | `ios/WebHTVApp/WebHTVApp.xcodeproj/project.pbxproj` 的 `MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`、`PRODUCT_BUNDLE_IDENTIFIER`；`.github/workflows/ios-sidestore-release.yml`（`Resolve release metadata`、`Create or update GitHub Release`）；`scripts/update_sidestore_source.py`；`source.json` | SideStore、release workflow、`device.info` | 只有 CI 檢查 | build 嚴格遞增沒有檢查；`source.json` 沒有 IPA digest；app release 會被覆寫（`--clobber`）；pack 要另用不重疊、不可變的 tag 命名空間 |
| K38 | bundle 資源配置、Info.plist、原生 binary 與 CPython pin、WebHome 頁載入 | `project.pbxproj` 的資源與 framework 段；`ios/WebHTVApp/Info.plist`；`ios/Vendor/MPVKit/Package.swift`；`ios/Package.swift`（`resources: [.copy("Resources/Spiders")]`）；`third_party/mpv-ios-lock.json`；`WebHTVApp.swift` `WebHomeView`（`:4505` 載入 showcase）、`WebHomeWebView.makeUIView` | `PythonBoot`、`SpiderRegistry.bundledOnly`（經 `Bundle.module` 的 `Spiders` 子目錄）、`appWallpaper()`、`MPVEngine`、`WebHomeView` | `ExternalPlayerRemovalTests`（1 個）；其餘只有 CI | ATS 全關（`NSAllowsArbitraryLoads`），動態內容的傳輸規則只能在 Swift 強制；pack 內容不得放上 `sys.path`，不得遮蔽內建名稱 |
| K39 | IOS-POC-15D 緩衝與預解析契約 | `PlaybackNetworkPolicy.swift` `PlaybackItemKind`、`PlaybackNetworkSample`、`PlaybackNetworkState`、`PlaybackBufferPolicy`、`PlaybackLimit`、`PlaybackNetworkMonitor`、`PlaybackPrefetchGate`；`WebHTVApp.swift` `PlaybackSession.observeNetwork`、`apply(_:to:)`、`prefetchNextIfDue` | `PlaybackSession`（AVPlayer 的 `preferredForwardBufferDuration`、峰值位元率、解析度上限） | `PlaybackNetworkPolicyTests`（26 個；IOS-POC-27B 新增 6 個，共 32 個） | 常數另列 A20、A21；App 端接線沒有測試；pack 不得調整。IOS-POC-26-2 可能改到，列暫定。IOS-POC-27B：`policy(for:…rate:)` 依倍速放大、上限 `maximumForwardBufferSeconds` 120 秒；`setRate` 立即重新套用；每 30 秒一行 `holding` 記錄 |

### 之二、資產分類

擁有者只有兩個：Native Core 與 Dynamic Layer。每個資產只會落在下列四個固定標籤之一，沒有「可能可執行」或「待決定」的分類：

| 標籤 | 擁有者 | 意思 |
|---|---|---|
| Native Core | Native Core | 原生程式、ABI、信任根、建置設定或 UI 文字，只能隨 IPA 更新 |
| Native Core（內建內容） | Native Core | 不可執行或只在 Debug 使用的內建資料與資源；評估過，不動態化。它和 Native Core 一樣只隨 IPA 更新，標籤只說明「有想過動態化，結論是不做」 |
| Dynamic Layer（global pack 候選） | Dynamic Layer | WebHTV 內建、在已出貨的 JavaScriptCore 上執行、已可由相容包覆蓋的直譯碼；IOS-POC-13 可由 WebHTV 簽章的 global pack 取代，內建版本保留為 fallback |
| Dynamic Layer（config 擁有） | Dynamic Layer | 使用者設定擁有、已有自己更新路徑的內容；不是 WebHTV pack 的成員，WebHTV 的簽章不涵蓋它。只有 A66（相容包）的格式會併入 v1 manifest 模型（M6） |

判定規則（依序套用，第一條符合就停）：

1. 需要可執行記憶體頁（W^X，R16），或是 Swift／原生框架／簽章、entitlement 與建置設定 → Native Core。
2. 定義 pack 所依賴的 ABI（`host.js`、兩個 bridge、`moduleRuntime`、`base/spider.py`、`base/__init__.py`、`webhtv_runtime.py`）→ Native Core。
3. 安全性依賴程式碼簽章（pin 表、certifi、sniffer hook、有 bridge 權限的 WebHome 頁）→ Native Core。
4. 使用者設定擁有、已有自己更新路徑的內容 → Dynamic Layer（config 擁有）。
5. WebHTV 內建、在已出貨 JavaScriptCore 上執行、已有相容包覆蓋路徑的直譯碼 → Dynamic Layer（global pack 候選）。
6. 其餘內建資料或資源 → Native Core（內建內容）。

「變更證據」取自本 repo 的 `git log`；config 擁有的內容在使用者的設定 repo，本 repo 無法量測。「發版基準」指 IOS-POC-11 的 `54b9e89d`；第一次發布是 `7d18cf4a`（`0.1 (1)`，2026-09-22）。

| # | 資產 | 位置 | 變更證據 | 目前信任模型 | 分類 | 理由 |
|---|---|---|---|---|---|---|
| A1 | 站台路由判定（type 0／1／4＋http／https api 是 CMS；type 3＋`csp_`、`.js`、`.py` 是 spider） | `WebHTVConfig.swift` `WebHTVConfig.nativeCMSSites`、`supportedSites`、`drivableSites`、`isSupported`；`Site.isNativeCMS`、`isCSPSpider`、`isDrpySpider`、`isPythonSpider`、`isSpiderShape` | 檔案 15 次（2026-09-15～2026-09-24）；`4a9fd68f`、`9b0369f4`、`7c76d5c2`、`b43c89fb` 每次都新增一個原生 runtime | 隨 IPA 簽章；決定哪個直譯器執行遠端內容 | Native Core | 新站台種類需要新的原生 runtime；pack 只能在既有形狀內新增 spider |
| A2 | drpy rule 參照選擇（ext 或 api） | `WebHTVConfig.swift` `Site.drpyRuleReference`、`Site.isResourceReference` | 同日兩次修正 `590a086f`、`c96d3779`（2026-09-22） | 簽章；結果再經 `ConfigSource.resourceURL` 與同源檢查 | Native Core | 決定要抓並執行哪個遠端檔案，改成資料會讓資料操控程式載入 |
| A3 | MacCMS／type-4 請求分支與 XML 元素名稱 | `CMSClient.swift` `CMSClient`（`listingQuery`、`detailAction`、`playbackURL`）；`MacCMSXML.swift` `MacCMSXMLDecoder` | `CMSClient.swift` 15 次（功能成長）；`MacCMSXML.swift` 1 次 `4a9fd68f` | 簽章；回應是不可信資料 | Native Core | 通用協定 client，沒有任何 host 或 key |
| A4 | 直接媒體副檔名清單 | `CMSClient.swift` `CMSClient.isDirectMedia(_:)` | 清單內容 1 次 `84213fd4`，之後未變（`14e1255a` 只新增呼叫端） | 簽章 | Native Core | 在播放解析路徑上，影響起播延遲；沒有變更需求 |
| A5 | 畫質標籤排名表 | `PlayURL.swift` `PlaybackQuality.rank(_:)`、`defaultIndex(in:position:)` | 1 次 `0ab06a3c` | 簽章；套在站台的自由文字上 | Native Core | 播放路徑的選擇規則；之後若多次新增字詞再評估 |
| A6 | 篩選列名稱對照 | `CMSClient.swift` `CMSFilter.rowNames`、`displayName` | 1 次 `efbd04a4` | 簽章；封閉清單；`FilterNameTests`（4 個） | Native Core | 純顯示但未曾變更，外移要新建本地化層，沒有收益 |
| A7 | 繁轉簡對照表（2,528 組，Android `Trans.java` `cf2d9c7f875bbdcc752a2b34ee0fe9ea422f0914`） | `TraditionalSimplified.swift` `TraditionalSimplified.traditional`、`simplified` | 1 次 `ee597124` | 簽章；決定每個來源收到的關鍵字 | Native Core | 由 pack 提供會靜默改變所有設定的搜尋語意 |
| A8 | 聚合搜尋常數（同時 6 個、30 秒）與 logger subsystem | `AggregateSearch.swift` `AggregateSearch.defaultLimit`、`defaultDeadline`、`log` | 1 次 `ee597124` | 簽章 | Native Core | 受原生執行緒模型限制 |
| A9 | 傳輸常數（10 秒、無 URLCache） | `ConfigLoader.swift` `URLSession.webHTV` | 2 次 `71446d18`、`1496fec2` | 簽章；讓雜湊固定的下載不會拿到舊副本 | Native Core | 安全與正確性相關 |
| A10 | 持久儲存名稱總表（見下方清單） | `WebHTVApp.swift` 檔案層級常數、`ConfigView.savedSourcesURL`、`configURL(for:)`；`SavedSource.swift` `cacheFileName`；`WatchHistory.swift` `WatchHistoryStore`；`PlaybackEngine.swift` `PlaybackEnginePreference.key`；`SpiderPack.swift` `SpiderPackStore.defaultDirectory`、`url(for:defaults:)`、`write`；`StorageHost.swift` `SpiderStorage`；`PythonSpiderRuntime.swift` `defaultCacheDirectory`；`WebHomeBridge.swift` `cacheKey`；`AdBlockList.swift` `make(ads:)` | `1b1d99f5`、`0a2b418c`、`4d703da3` 等 | App 容器；設定快取讀取時重新 `validate` | Native Core | 持久資料 ABI，改名需要 Swift 遷移 |
| A11 | config 相對錨點慣例（`./`、`../`、`;md5;` 剝除、`./spiders/manifest.json`、`spiderPackURL`） | `ConfigSource.swift` `ConfigSource.baseURL`、`resourceURL(for:)`；`SpiderPack.swift` `SpiderPackStore.defaultReference`、`url(for:defaults:)` | `ConfigSource.swift` 2 次；`SpiderPack.swift` 1 次 `67e02aad` | 簽章；同源與 SHA-256 在下游 | Native Core | 所有 config 擁有的動態資產都以它為信任錨點 |
| A12 | 使用者可見錯誤字串（設定與 CMS） | `ConfigLoader.swift` `ConfigLoaderError.errorDescription`；`CMSClient.swift` `CMSClientError.errorDescription`；`WebHTVApp.swift` `ConfigView.load(_:)`、`load(remote:showHome:reportFailure:)`、`useRemote`、`restore` 的錯誤文字 | `9191585f`；`ConfigLoader` 的文字自 `1b1d99f5` 未變且已過時 | 簽章；`ErrorMessageTests`（5 個） | Native Core | 綁定原生錯誤 case，沒有本地化層 |
| A13 | `DrpyEngine.moduleRuntime` 與 ES module 改寫 | `DrpyEngine.swift` `DrpyEngine.moduleRuntime`（internal `static let`，`:235`）、`rewritten(_:named:)` | `moduleRuntime` 與 `rewritten` 本身各 1 次 `7c76d5c2`（`DrpyEngine.swift` 整檔 4 次，2026-09-18～2026-09-22），發版基準後 0 次 | 編進 binary | Native Core | 定義遠端 rule 依賴的全域，屬 `js.host` |
| A14 | `SpiderRegistry.ported`（9 個 class 名稱對應 8 個 script；`JPianAmns` 由 `JianPian.js` 驅動） | `SpiderRegistry.swift` `SpiderRegistry.ported`、`bundledOnly` | `ported` 表 4 次，最後 2026-09-17 | 編進 binary；pack overlay 可新增或取代 | Native Core | 內建 fallback 的索引；動態路徑已由 overlay 提供 |
| A15 | alias `JPianAmns → JianPian` | `SpiderRegistry.swift` `SpiderRegistry.aliases` | 1 次 `d34c9dbe` | 編進 binary；pack alias 只能指向 pack 提供的 script | Native Core | 內建基準 alias；新 alias 已走 pack |
| A16 | drpy 相依 pin 表（10 檔 bytes＋SHA-256，共 1,223,545 bytes，約 1.17 MiB） | `DrpyEngine.swift` `DrpyEngine.directory`、`dependencies` | 1 次 `7c76d5c2`，之後未改 | SHA-256 編進 IPA（使用者 A+ 決定，IOS-POC-6A） | Native Core | 安全性依賴程式碼簽章；只有在 IOS-POC-13 實作 IPA 內建的簽章信任根之後才重新評估 |
| A17 | Spider 政策常數（schema 1、`hostApiVersion` 1、預設參照、drpy 與 Python 大小上限） | `SpiderPack.swift` `SpiderPack.schema`、`SpiderPackStore.hostApiVersion`、`defaultReference`；`DrpyEngine.swift` `maximumFileBytes`（512 KiB）、`maximumBundleBytes`（2 MiB）、`maximumRuleBytes`（256 KiB）；`PythonSpiderSource.swift` `maximumScriptBytes`（256 KiB） | 各 1 次 | 編進 binary | Native Core | 遠端內容被檢查的閘門；pack 不得自帶上限或 ABI 號碼 |
| A18 | MPV 選項與觀察屬性 | `MPVEngine.swift` `MPVPlayerCore.init(layer:)` | 3 次（`7d679d68`、`8824c8ee`、`45357898`），每次都伴隨原生變更 | 簽章；skip-session 選項只存在 patched Libmpv | Native Core | 遠端 mpv 設定會改變 renderer、decoder 與音訊工作階段；Libluajit 只在 macOS 連結，iOS 的 mpv 沒有腳本層。IOS-POC-26-2 可能改到，列暫定 |
| A19 | `PlaybackFailure` 錯誤碼 allowlist、離線集合、訊息 | `PlaybackEngine.swift` `PlaybackFailure.avCapabilityCodes`、`mpvCapabilityCodes`、`mpvDomain`、`mpvNoFirstFrame`、`message`、`networkDetail` | `7d679d68` 後未變；語意在 `b37751d2` 改一次 | 簽章；單元測試 | Native Core | 由 IPA 內的 AVFoundation 與 libmpv 版本定義，也是 fallback 迴圈的防護 |
| A20 | 播放時間常數 | `PlaybackEngine.swift` `PlayerRouter.startupTimeout(for:)`（原生 5 秒、MPV 20 秒）；`MPVEngine.swift` `MPVEngine.firstFrameTimeout`（10 秒）；`PausedBackgroundReload.swift` `heartbeat`（1 秒）、`suspensionGap`（3 秒）；`NextPlaybackTarget.swift` `PlaybackTargetPrefetch.maximumAge`（300 秒）；`PlaybackNetworkPolicy.swift` `PlaybackPrefetchGate.stablePlaybackSeconds`（20 秒）、`leadSeconds`（90 秒）；`PlayerChrome.swift` `PlayerChrome.autoHideSeconds`（5 秒）；`WebHTVApp.swift` `PlayerView.seekSpan`（120）、`levelSpan`（400） | 各引入一次；`startupTimeout` 在 IOS-POC-27A 第 2 次（改為依核心，原生 20→5 秒） | 簽章；多數有 core 測試 | Native Core | 生命週期、fallback 與短效網址曝光期限，不是內容。IOS-POC-26 可能改到，列暫定 |
| A21 | `PlaybackNetworkThresholds` 與緩衝策略表 | `PlaybackNetworkPolicy.swift` `PlaybackNetworkThresholds`、`PlaybackBufferPolicy.policy(for:…)` | 2 次 `d7247b91`、`6416c4d4`；IOS-POC-27B 第 3 次（新增 `rate` 參數與 `maximumForwardBufferSeconds`） | 簽章；`PlaybackNetworkPolicyTests` 的 `noStateEverCapsPeakBitRate` 等 | Native Core | 調整會改變播放效能；沒有跨 IPA 調整的證據 |
| A22 | 速度清單與 AVPlayer 2× 上限 | `WebHTVApp.swift` `PlayerControlBar.speeds`（`:3381`）；`PlaybackEngine.swift` `PlaybackRateSupport.nativeLimit` | 各 1 次 | 簽章 | Native Core | 綁定 `.timeDomain` 與 MPV 交接規則 |
| A23 | 音軌標籤表（語言、codec、聲道） | `PlaybackMediaSelection.swift` `PlaybackMediaOption.channelDescription`、`displayName`、`normalizedCodec`、`localizedLanguageName`、`canonicalLanguageCode` | 1 次 `637d3597` | 簽章；單元測試 | Native Core | 詞彙來自內建引擎，隨 IPA 變 |
| A24 | 播放器 UI 字串 | `PlaybackEngine.swift` `PlaybackEngineKind.displayName`、`shortName`、`PlaybackFailure.message`；`PlayerChrome.swift` `PlayerPanel.title`；`WebHTVApp.swift` `PlayerControlBar.panelRows` 的「（尚未開放）」；`MPVEngine.swift` `MPVPlayerCore.refreshMediaSelection` 的「音軌」「字幕」「關閉」 | 引入後未改 | 簽章 | Native Core | 播放器沒有讀取資料標籤的 renderer |
| A25 | `AVURLAssetHTTPHeaderFieldsKey` | `WebHTVApp.swift` `PlaybackSession.asset(for:headers:)`（`:2963`） | 1 次 `0414c032` | 簽章；未公開 API，真機未確認（8L ⑨） | Native Core | AVFoundation 的 API 細節 |
| A26 | 引擎開放閘 | `WebHTVApp.swift` `PlaybackEngines.offered`（`:2975`） | 2 次 `7d679d68`、`a1bc5bb6` | 每個 build 決定 | Native Core | 遠端開關會是新能力，沒有需求證據；若日後需要，只能把集合縮小到 AVPlayer |
| A27 | Android 相容狀態對照（state 3／6／2／1、毫秒） | `WebHTVApp.swift` `PlaybackSession.androidState(_:)`（`:2751`）、`milliseconds(_:)` | 自 `588cb85a`（2026-09-16） | 簽章；對應 Android `Media.java` | Native Core | 屬 WebHome bridge ABI |
| A28 | `WebHomeBridge.sdkScript` | `WebHomeBridge.swift` `WebHomeBridge.sdkScript` | 建立（`3fc7be86`）後未變 | Swift 字串、簽章 | Native Core | 每個方法都要 Swift case，替換無法新增能力，只會破壞 |
| A29 | MediaSniffer JS hook | `MediaSniffer.swift` `MediaSniffer.Collector.hook`（`:354`） | 1 次 `14e1255a` | 簽章；注入第三方頁面的每個 frame | Native Core | 熱更新會把可遠端改變的腳本放進每個被嗅探的頁面 |
| A30 | WebHome inline resolver 膠合 JS | `WebHTVApp.swift` `WebHomeWebView.Coordinator.resolveInlineEpisode(_:)` | 1 次 `588cb85a` | 簽章 | Native Core | 綁定 `callAsyncJavaScript` 與 Android 定義的名稱 |
| A31 | `app-capabilities-showcase.html`（52,327 bytes） | `webhome-devkit/templates/homepages/app-capabilities-showcase.html`；`project.pbxproj` 資源段；`WebHTVApp.swift` `WebHomeView`（`:4505`）、`WebHomeWebView.makeUIView` | 全 repo 1 次 `979e8250`（2026-06-16） | 從封存的 bundle 載入，取得完整 bridge；沒有 frame、origin、navigation 檢查；Release 版可從「開發者」進入 | Native Core | 可執行內容且有 bridge 權限，安全性完全依賴內建；要動態化必須先以 IPA 加上原生的 origin／frame 閘 |
| A32 | `cjkFallbackScript` | `WebHTVApp.swift` `cjkFallbackScript`（`:4601`，`#if DEBUG`） | 1 次 `f047d3de` | 只在 Debug；Release 不含 | Native Core（內建內容） | 不在出貨 IPA |
| A33 | `MediaSniffer.defaultKeywords`／`defaultExclusions` | `MediaSniffer.swift` `MediaSniffer.defaultKeywords`、`defaultExclusions` | 內容自 `14e1255a` 未變 | 簽章 | Native Core（內建內容） | config `rules` 已能以較高優先順序逐 host 覆寫；外移只多一個選擇串流網址的遠端面。IOS-POC-25 可能改到，列暫定 |
| A34 | `MediaProbe` 常數（Range 0-1023、64 bytes、HTML 標記） | `MediaSniffer.swift` `MediaProbe.classify` | 3 次，都是原生原因 | 簽章 | Native Core | 探測演算法與網路成本 |
| A35 | `AdBlockList` 編譯常數 | `AdBlockList.swift` `AdBlockList.resourceTypes`、`make(ads:)` 的識別碼、`filter(for:)` | 1 次 `7b7ad584` | 簽章 | Native Core | 改識別碼推導會孤立 `WKContentRuleListStore` 裡的清單 |
| A36 | WatchHistory 政策常數（`@@@`、60 天、500 筆、10 秒、1% 夾在 5～30 秒、3／6／10 分、5 秒取樣） | `WatchHistory.swift` `WatchHistory.separator`、`isNearEnding`、`resumePosition`、`openingEndingLimit`、`WatchHistoryStore.retention`、`limit`；`WebHTVApp.swift` `PlaybackSession.startSampling` | `261b5c03`、`d47f549d` 後未變 | 簽章；對應 Android 公式 | Native Core | 會刪除使用者資料的政策 |
| A37 | WebHome Android 相容 payload 常數 | `WebHomeBridge.swift` `WebHomeBridgeError`、`viewportText`、`historyText`、`inlineSiteKey`（`webhome_inline`）、`statusText`；`WebHTVApp.swift` `deviceInfo()`（`:4612`） | 2026-09-16～2026-09-18 引入，之後只改 opening／ending | 簽章 | Native Core | 凍結的 bridge ABI |
| A38 | `AppGet.js`（10,103 bytes） | `ios/Sources/WebHTVCore/Resources/Spiders/AppGet.js` | 4 次（`9b0369f4`、`66716c30`、`d786c627`、`f34ae805`）；發版基準後 0 次；`d786c627`、`f34ae805` 同時改輸出 schema 或 UI | 內建簽章；可被 HTTPS＋每檔 SHA-256 的相容包取代 | Dynamic Layer（global pack 候選） | 純 JS，已可打包；entry 要宣告 `catvod.result`；內建保留為 fallback |
| A39 | `AppQi.js`（11,275 bytes） | 同目錄 | 2 次（`67142485`、`f34ae805`） | 同 A38 | Dynamic Layer（global pack 候選） | 只有站台協定邏輯 |
| A40 | `App99.js`（9,646 bytes） | 同目錄 | 1 次 `67142485`，同一 commit 新增 `CryptoHost` 的 `symmetricIV` | 同 A38 | Dynamic Layer（global pack 候選） | 腳本可熱更新；需要新 primitive 時仍是 IPA＋ABI minor |
| A41 | `App3Q.js`（6,717 bytes，內含 `bbys.app`、finger、pkg、device id） | 同目錄 `:18-29`、`:44` | 1 次 `67142485` | 同 A38 | Dynamic Layer（global pack 候選） | 內嵌的 provider 資料正是 pack 要取代的高變動資料 |
| A42 | `Bili.js`（9,698 bytes，`api.bilibili.com` 端點） | 同目錄 `:94-178` | 2 次（`67142485`、`0ab06a3c`）；`0ab06a3c` 同時改 `PlayURL.swift` | 同 A38 | Dynamic Layer（global pack 候選） | 輸出 schema 凍結後可由 pack 更新 |
| A43 | `JianPian.js`（11,649 bytes，兼 `csp_JPianAmns`） | 同目錄 `:19-25` | 3 次（`d34c9dbe`、`54b9e89d`、`80a5ac52`）；兩次修正都只改 JS 與測試；`80a5ac52` 在第一次發布之後，隨 `0.1.1 (2)` 以 IPA 發布 | 同 A38 | Dynamic Layer（global pack 候選） | 最強證據：發版後唯一的 spider 變更只有 JS，卻要發一版 IPA |
| A44 | `XBPQ.js`（12,137 bytes，規則引擎） | 同目錄 | 3 次（`226e826c`、`f0e42264`、`a392f564`） | 同 A38；規則以 inline ext 傳入 | Dynamic Layer（global pack 候選） | 引擎是 JS，規則是 config 資料 |
| A45 | `XYQHiker.js`（11,878 bytes，規則引擎） | 同目錄 | 3 次（`226e826c`、`f0e42264`、`66716c30`）；`66716c30` 同時改 `host.js` | 同 A38；自己以 `host.get` 抓規則檔 | Dynamic Layer（global pack 候選） | 同 A44；同時改 host 的變更必須升 ABI |
| A46 | `host.js`（21,157 bytes） | 同目錄；`SpiderRegistry.bundledOnly` 把它載入成 `prelude` | 6 次（2026-09-16～2026-09-18），發版基準後 0 次 | 內建；明確不可打包：`scripts/spider_pack.py` 的 `NOT_PACKABLE` 與註解；overlay 只取代 `entries`，不取代 `prelude` | Native Core | `minHostApi` 描述的 SDK；執行期替換會改變所有 pack 版本閘的意義 |
| A47 | `drpy-bridge.js`（2,956 bytes） | 同目錄；`SpiderRegistry.drpyBridge` | 1 次 `7c76d5c2` | 內建；`SpiderRegistry.swift` 的註解（`:34-36`）寫明不可打包，overlay 不能取代，但 `NOT_PACKABLE` 漏列 | Native Core | 遠端 drpy rule 與 Spider ABI 之間的轉接 |
| A48 | `js-spider.js`（3,813 bytes） | 同目錄；`SpiderRegistry.jsSpiderBridge` | 1 次 `a076ab51` | 同 A47（註解 `:38-39`） | Native Core | CatVod JS spider 的 ABI 轉接 |
| A49 | `base/spider.py` | `ios/WebHTVApp/Python/base/spider.py` `Spider` | 3 次（2026-09-21） | 內建；`sys.path` 第一位 | Native Core | Python 版的 `host.js` |
| A50 | `webhtv_runtime.py` | `ios/WebHTVApp/Python/webhtv_runtime.py` `load`、`invoke`、`unload`、`diagnostics` | 1 次 `3f9a7588` | 內建 | Native Core | 必須與 `PythonSpiderRuntime.swift` 的 envelope 同步變更 |
| A51 | vendored wheels（requests 2.34.2、urllib3 2.8.0、certifi 2026.7.22、idna 3.20、charset-normalizer 3.5.1） | `third_party/python-ios-lock.json` `python_packages`；`scripts/fetch_python_ios.sh` | lock 共 2 次（`52a0df4f`、`85fb4e6a`，都在 2026-09-21） | build 時 bytes＋SHA-256，封存並簽章 | Native Core | certifi 是所有 Python spider 的 TLS 信任根，所有 spider 共用同一個 import 命名空間 |
| A52 | CPython XCFramework、stdlib、lib-dynload（3.13.15、b15） | `third_party/python-ios-lock.json`；`project.pbxproj` 的 framework 段 | 同 A51 | build 時 bytes＋SHA-256，嵌入並簽章 | Native Core | 原生可執行碼，iOS 禁止執行期替換 |
| A53 | WebHTV Libmpv（`mpvkit-1.0.0-webhtv.2`，patch 0001、0004） | `ios/Vendor/MPVKit/Package.swift` 的 `Libmpv` binary target；`third_party/mpv-ios-lock.json`；`third_party/mpv-ios/`（`patches/`、`MANIFEST.sha256`、授權檔）；`.github/workflows/ios-libmpv-build.yml` | lock 5 次、workflow 5 次，都在 2026-09-25 | 釘選建置、與上游比對、不可變 prerelease、SwiftPM checksum | Native Core | patch 過的原生碼，Swift 行為依賴它 |
| A54 | 其他 MPVKit xcframework（FFmpeg LGPL、openssl 等） | `ios/Vendor/MPVKit/Package.swift` 其餘 binary target；`ios/Vendor/MPVKit/Sources/` 的空殼 target（`dummy.c`）與 `LICENSE` | 2 次 commit 都只改 Libmpv | SwiftPM checksum、靜態連結 | Native Core | 原生框架 |
| A55 | `Info.plist` 與產生的 key（ATS、背景音訊、顯示名稱、bundle id、版本、MinimumOSVersion） | `ios/WebHTVApp/Info.plist`；`project.pbxproj` 的 `MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`、`PRODUCT_BUNDLE_IDENTIFIER`、`IPHONEOS_DEPLOYMENT_TARGET` | `Info.plist` 2 次；版本 key 每次發版都變 | iOS 只從安裝的 bundle 讀 | Native Core | 路線圖明列；平台只能從簽章 bundle 讀取 |
| A56 | 程式碼簽章與 entitlements（沒有 `.entitlements`，SideStore 安裝時簽） | `.github/workflows/ios-sidestore-release.yml` `Build unsigned device app`（`CODE_SIGNING_ALLOWED=NO`） | 自 `7db9aadb` 未變 | 簽章代表使用者的 Apple ID，不代表 WebHTV | Native Core | 無法用來驗證 pack；pack 的信任根必須是編進 binary 的 WebHTV 公鑰 |
| A57 | App icon（1,032,989 bytes） | `ios/WebHTVApp/Assets.xcassets/AppIcon.appiconset` | 1 次 `6d0194e0` | 編入 `Assets.car`；SideStore 清單圖示另從 branch 抓 | Native Core | 主畫面圖示只能來自簽章 bundle |
| A58 | `wallpaper_1.png`（65,612 bytes） | `ios/WebHTVApp/Resources/wallpaper_1.png`；`WebHTVApp.swift` `appWallpaper()`、`bundledImage(_:)` | 1 次 `1a432078` | 封存；缺檔就 `fatalError` | Native Core（內建內容） | 只變過一次；沒有覆寫資源的 primitive，新增會多一條遠端解圖路徑與當機風險 |
| A59 | `ic_logo.png`（50,269 bytes） | `ios/WebHTVApp/Resources/ic_logo.png`；`project.pbxproj` 資源段 | 1 次 `1a432078`；沒有任何 Swift 引用 | 封存；沒有讀取者 | Native Core（內建內容） | 未使用的資源，不是動態內容；移除屬無關清理，不在 12 範圍 |
| A60 | SideStore `source.json` | `source.json` | 23 次（建立一次，之後每次發版一次） | HTTPS、可變 branch；CI 以 schema 驗證；只有 size，沒有 digest | Native Core | Native Core 的發布通道；pack 不得搭載 |
| A61 | 使用者設定 JSON（遠端或匯入） | `ConfigLoader.swift` `ConfigLoader.fetch(from:)`；`WebHTVApp.swift` `ConfigView.load(remote:…)`、`refreshRemote`、`adopt(_:config:from:)` | 使用者擁有；每次啟動重抓（2、5、15 秒重試）與手動 | http／https 都接受（`NSAllowsArbitraryLoads`）；2xx、可解碼、至少一個 CMS 站；沒有大小上限、digest、簽章；逐來源 LKG | Dynamic Layer（config 擁有） | 使用者資料，有自己的更新路徑，也是 config scope 的信任錨點；路線圖把它留在 pack 之外 |
| A62 | 設定的 `ads` | `WebHTVConfig.swift` `WebHTVConfig.ads`；`WebHTVApp.swift` `ConfigView.adoptAdBlocking(from:)` | 使用者擁有；實測 1 筆與 62 筆 | 同 A61；輸出只有宣告式阻擋規則 | Dynamic Layer（config 擁有） | 已是 config 擁有的動態資料；不得放進 global pack |
| A63 | 設定的 `rules`（hosts、regex、exclude） | `WebHTVConfig.swift` `WebHTVConfig.rules`；`SnifferRules.swift` `SnifferRule` | 使用者擁有；實測 19 筆 | 同 A61；無法編譯的 pattern 視為不符 | Dynamic Layer（config 擁有） | global 規則若出現，要有自己的識別與信任根，排在 config 之後 |
| A64 | 設定的 `rules[].script` | `SnifferRules.swift` `SnifferRules.script(for:)`；`MediaSniffer.swift` `MediaSniffer.Collector` | 使用者擁有；實測 2 筆 | 在一次性的 sniffer WKWebView 內 `evaluateJavaScript`；該 WebView 唯一的原生通道只能回報 URL | Dynamic Layer（config 擁有） | 不是 WebHTV pack 內容；13 不得加 global 腳本來源 |
| A65 | ext 指向的規則與 cookie 檔（XBPQ／XYQHiker 的 `./json/*.json`、Bili） | `CSPSourceResolver.swift` `resolvedExtend(for:)`；`XYQHiker.js:139-141`；`Bili.js:110-113` | config 資料 | 原生只解析 URL；spider 以 `host.req` 自抓，允許 http、任何 host、沒有大小上限 | Dynamic Layer（config 擁有） | 已可不經 IPA 更新；12 不改其傳輸 |
| A66 | 相容包（`manifest.json`＋`scripts/*.js`） | `SpiderPack.swift` `SpiderPackStore`；`WebHTVApp.swift` `ConfigView.adoptCachedSpiderPack`、`refreshSpiderPack` | 程式 1 次；沒有為使用者的設定發布過任何 pack | HTTPS、schema 1、`minHostApi`、每檔 SHA-256（完整性）、整包拒絕、staging＋`replaceItemAt`、讀取時重算 hash；**沒有同源要求**（G24） | Dynamic Layer（config 擁有） | 新 manifest 的原型；13 保留信任邊界、補上缺口（G1～G6、G24） |
| A67 | drpy 引擎函式庫（`drpy_libs/*.js`，共 1,223,545 bytes） | `DrpyEngine.swift` `DrpyEngine.prelude(source:host:…)`、`load(_:source:…)`；`DrpyEngineStore` | pin 自 2026-09-18 未變 | IPA 內 pin、同源 HTTPS、串流上限、只在記憶體 | Native Core | 位元組放在 config 主機，但接受與否完全由 IPA 內的 pin 決定 |
| A68 | drpy rule 與 CatVod JS spider 腳本（例如 麻豆.min.js） | `DrpyEngine.swift` `DrpyEngine.script(at:source:…)`、`rule(at:source:…)`；`WebHTVConfig.swift` `Site.drpyRuleReference` | config 擁有；IOS-POC-6A 記錄為 KiB 級且常變 | 同源 HTTPS、256 KiB、UTF-8、不 pin；`downloadSession` 用共用 URLCache | Dynamic Layer（config 擁有） | 已是 config 擁有的動態內容；不移進 global pack，不改傳輸閘 |
| A69 | Python `.py` 腳本 | `PythonSpiderSource.swift` `PythonSpiderSource.script(for:source:…)`；`webhtv_runtime.py` `load` | config 擁有；42 站、35 支腳本，其中 31 支同源（IOS-POC-7A） | 同源 HTTPS、256 KiB、不 pin；在完整 CPython 上執行，可存取容器檔案系統與 socket | Dynamic Layer（config 擁有） | 能力比 JSContext 大，沒有真實性之前不得進 global pack；受 `python.host` 閘 |
| A71 | `MPVProbeView.swift`（MPV 算繪探針） | `ios/WebHTVApp/Sources/MPVProbeView.swift` `MPVProbeView`；入口在 `WebHTVApp.swift` `SettingsView` 的 `#if DEBUG` 區塊 | 4 次（2026-09-21～2026-09-23），最後 `cf076e79` | 編進 Release 但只有 Debug 能進入；內含 Apple 範例串流網址（`devstreaming-cdn.apple.com`）；8L ⑱ 的四格探針 | Native Core | Swift 程式；範例網址是測試資料，不是使用者來源 |
| A72 | `MPVBoot.swift`（libmpv 自我測試） | `ios/WebHTVApp/Sources/MPVBoot.swift` `MPVBoot.start`；唯一呼叫在 `WebHTVApp.init()` 的 `#if DEBUG` 區塊 | 1 次 `401b3076` | 檔案本身沒有 `#if DEBUG`；以 `webhtv-no-such-property` 當反向對照 | Native Core | Swift 程式 |
| A73 | `PythonLiveCheck.swift` | `ios/WebHTVApp/Sources/PythonLiveCheck.swift` `PythonLiveCheck`（整檔 `#if DEBUG`） | 2 次（2026-09-21），最後 `26c6040c` | 只在 Debug；直接讀 `configSourceURL` 與 `wang-movie.json` | Native Core | Swift 程式；持久名稱改名時必須一起改（A10） |
| A74 | `base/__init__.py` | `ios/WebHTVApp/Python/base/__init__.py` | 1 次 `3f9a7588` | 內建 | Native Core | `from base.spider import Spider` 的套件形狀，屬 `python.host`，列入 fingerprint |
| A75 | `ios/Package.swift` | `resources: [.copy("Resources/Spiders")]`、`platforms: [.iOS(.v17), .macOS(.v14)]`、`swift-tools-version: 6.2` | 2 次，最後 `9b0369f4`（2026-09-16） | 建置設定 | Native Core | 內建 fallback 靠 `Bundle.module` 的 `Spiders` 子目錄（`SpiderRegistry.bundledOnly`）；12B 的 runner 必須滿足 swift-tools 6.2 與 macOS 14 |
| A76 | UI 文字中的 `wang-movie.json` | `WebHTVApp.swift` `ConfigView` 的空狀態說明「匯入 wang-movie.json，或直接貼上它的 HTTPS 網址。」與網址 placeholder；`SettingsView` 同一 placeholder | 以 `git log -S` 查，最後由 `1b1d99f5`（2026-09-16）與 `ed3f2709`（2026-09-18）改動 | 簽章 | Native Core | 產品是不內建使用者來源的外殼，這只是檔名提示，不是來源；改文字是使用者可見變更，12 只記錄。匯入檔的快取也叫 `wang-movie.json`（A10） |
| A77 | 共用 scheme | `ios/WebHTVApp/WebHTVApp.xcodeproj/xcshareddata/xcschemes/WebHTVApp.xcscheme` | 1 次 `1722eff4` | 建置設定；release workflow 以 `-scheme WebHTVApp` 使用 | Native Core | 建置設定 |

草案中的 A70（解析後的媒體 URL 與請求 headers）不是可更新的資產，已移出本表，改為 K28 的契約缺口與 D7。

A10 的持久名稱總表（改名都需要 Swift 遷移；第七節之八第 6 條的「pack 不可寫」清單以它為準，spider 自己的狀態除外）：

1. UserDefaults：`configSourceURL`、`configUpdatedAt`、`selectedSiteKey`、`selectedSiteBySource`、`webhtv.playback.defaultEngine`、`spiderPackURL`（只讀，沒有 UI）、`spider_<siteKey>_<key>`（JS `host.local`）、`cache_[<rule>_]<key>`（WebHome `cache.*`）。
2. Application Support：`saved-sources.json`、`wang-movie.json`（匯入的設定，也是舊版的單一快取）、`<base64url>.json`（`SavedSource.cacheFileName`，逐來源快取）、`WatchHistory/history.json`、`SpiderPack/`（`manifest.json`、`scripts/<class>.js`）、`SpiderPack-staging-<UUID>/`。
3. Caches：`python-spider/<siteKey>.json`。
4. WebKit：`WKContentRuleListStore` 識別碼 `webhtv-ads-<32 個十六進位字元>`。

統計：共 76 項。Native Core 60 項（其中 Native Core（內建內容）4 項：A32、A33、A58、A59）；Dynamic Layer 16 項，其中 global pack 候選 8 項（A38～A45）、config 擁有 8 項（A61～A66、A68、A69）。config 擁有的 8 項中，只有 A66 的格式會併入 v1 manifest 模型，其餘維持各自的路徑（之三）。

路線圖列出的「圖片、文字與其他非原生資源」與「schema 驅動的 UI 屬性」**目前沒有任何資產符合**：沒有任何 renderer 讀取資料驅動的標籤、順序或樣式，唯一可能的圖片（A58）不值得動態化。12 不新建這一層。

### 之三、既有更新機制、信任邊界與處置

「處置」欄回答路線圖「能否共用一個 manifest／啟用模型」：「併入 v1」表示 IOS-POC-13 改用第七節的 manifest 與世代啟用；「維持分開」表示保留現有路徑與信任根；「13 決定」表示要在 IOS-POC-13 以證據決定，並寫出目前的建議。

| # | 機制 | 時機 | 檢查 | 信任根 | 範圍 | 主要缺口 | 處置 |
|---|---|---|---|---|---|---|---|
| M1 | SideStore IPA 更新 | 使用者在 SideStore 更新 | CI：IPA 只有一個 `Info.plist`、bundle id／版本／build 相符（`scripts/update_sidestore_source.py`）；以 SideStore schema 驗證（schema 從 main 抓）；下載後以 `cmp` 回驗 | GitHub Release＋可變 branch 的 `source.json`；裝置端由使用者的 Apple ID 重簽 | 整個 App | `source.json` 沒有 IPA digest；重跑會覆寫同一 tag 的 IPA（`--clobber`）；build 單調性沒檢查 | 維持分開（Native Core 的通道） |
| M2 | SideStore 清單圖示 | 任何改到該檔的 push | 無 | raw branch 檔案（`source.json` 的 icon 網址） | 清單顯示 | 不經 IPA 發布 | 維持分開（不屬 runtime） |
| M3 | 遠端設定 | 啟動（2、5、15 秒重試）與手動 | scheme 與 host、2xx、JSON、至少一個 CMS 站；原子寫入逐來源快取 | 使用者選的 URL | 每個來源 | 沒有大小上限與真實性；允許 http，http 設定會靜默失去 drpy、Python 與相容包 | 維持分開；它是 config scope 的信任錨點與 scope key 的來源 |
| M4 | 匯入設定 | 使用者匯入 | 同 M3 | 使用者 | `imported` | 沒有 baseURL，drpy／Python 隱藏，沒有 pack URL | 維持分開；沒有 config scope |
| M5 | 舊快取遷移 | 一次，slot 為空時 | 無 | 本機 | 作用中的遠端來源 | 見 G15 | 維持分開（一次性遷移） |
| M6 | 相容包 | 只在啟動（adopt → refresh） | HTTPS、2xx、schema 1、整包與逐 script `minHostApi`、每檔 SHA-256、整包拒絕、staging＋`replaceItemAt`、讀取時重算 hash | 設定旁的 `./spiders/manifest.json` 或 `spiderPackURL`（沒有 UI） | 解析依設定，儲存與 `InstalledSpiderPack` 全域 | G1～G6、G24 | **併入 v1**（config scope）；12 期間 schema 1 不變，何時停用舊格式是 D5 |
| M7 | drpy 引擎 | 建 session | 同源 HTTPS、512 KiB／2 MiB 串流上限、IPA 內 SHA-256 pin | IPA pin | 記憶體，逐 baseURL | 使用者更新 `drpy_libs` 會讓所有 drpy 站失效，直到新 IPA | 維持分開；pin 是信任根，IOS-POC-13 有簽章信任根之後才重新評估（A16） |
| M8 | drpy rule 與 CatVod JS 腳本 | 每次建 session | 同源 HTTPS（host＋port）、256 KiB、UTF-8 | config origin | config | 共用 URLCache，可能拿到舊腳本；多租戶主機 | 13 決定（D16）；建議維持每個 session 即時抓取，不改成世代啟用，因為內容屬使用者設定且變動頻繁 |
| M9 | Python 腳本 | 每次建 session | 同 M8，走 `URLSession.webHTV` | config origin | config | 多租戶主機 | 13 決定（D16）；v1 manifest 不接受 `.py`，建議維持即時抓取 |
| M10 | ext 規則與 cookie 檔 | spider `init` | 無（`HTTPHost.perform`） | spider 自行決定 | config | 沒有 HTTPS、origin、大小閘 | 維持分開（spider 自己抓的資料，不是 WebHTV 交付的內容） |
| M11 | `rules[].script` 執行 | 每次嗅探的 `didFinish` | 非空 | config | 單次 sniffer WebView | 沒有其他驗證 | 維持分開（設定 JSON 內的資料） |
| M12 | `WKContentRuleListStore` 編譯快取 | 每次 adopt | 識別碼＝內容 SHA-256 前 32 字元 | 衍生自 `ads` | WebKit 全域 store | 從不清理 | 維持分開（衍生快取） |
| M13 | WebHome `net.request` 與 inline resolver | 頁面呼叫 | 沒有 scheme、origin、大小限制 | 內建頁面 | WebHome WebView | 只有內建頁能到達；不是程式交付 | 維持分開 |
| M14 | 下一集預解析 | 最後 90 秒 | `PlaybackTargetIdentity`＋300 秒 | 解析結果，不是程式 | 單次播放 | 沒有世代 | 維持分開；世代啟用時要讓它失效（第七節之八） |
| M15 | build 時抓取 | CI 或本機建置 | CPython lock bytes＋SHA-256；SwiftPM checksum；Libmpv workflow 雜湊、上游比對、拒絕重發 | git commit 中的 lock | IPA | runtime 用戶端無法使用這個信任根 | 維持分開（build 時） |

觀看紀錄沒有任何遠端或更新路徑。以上機制都不交付 Swift 或原生碼。結論：15 個機制中只有 M6 併入 v1 manifest；M8、M9 在 13 決定；其餘維持分開，各自的信任邊界不變。

### 之四、基準缺口

只記錄；12 不修。標「相容包強化」的是移出 IOS-POC-12 的工作（第八節之六）。

| # | 缺口 | 位置 | 處理 |
|---|---|---|---|
| G1 | 相容包跨設定外洩：儲存是一個全域目錄與 process 全域的 `InstalledSpiderPack`，URL 卻依作用中的設定；只在啟動 refresh；切換設定不 refresh 也不丟棄；B 沒有 pack 時保留 A 的 | `SpiderPack.swift` `SpiderPackStore.defaultDirectory`、`refresh(from:)`、`InstalledSpiderPack`；`WebHTVApp.swift` `ConfigView.adoptCachedSpiderPack`、`load(remote:…)`、`adopt(_:config:from:)` | 記錄為基準；13 以 scope 解決，不得繼承 |
| G2 | 沒有 per-class fallback：hash 正確但載入失敗的 pack script 會遮蔽內建 script | `SpiderRegistry.swift` `makeRuntime(for:siteKey:…)` | D9 |
| G3 | 相容包下載沒有大小上限 | `SpiderPack.swift` `SpiderPackStore.refresh(from:)`、`fetch` | 相容包強化或 13 |
| G4 | `className` 未驗證就當成檔名，`../../x` 會寫到 pack 目錄外，staging 清理也不會刪 | `SpiderPack.swift` `SpiderPackStore.write(manifest:sources:)`、`scriptURL(for:)` | 相容包強化或 13 |
| G5 | 沒有防回滾：`version` 是字串且從不比較；只有一個槽位，沒有 LKG 歷史 | `SpiderPack.swift` `SpiderPackManifest.version` | 13 |
| G6 | 讀取路徑不重套 refresh 的閘：`installedPack()` 只重算 hash 與逐 script `minHostApi`，不檢查 schema 與整包 `minHostApi`；缺檔時該 script 被略過，並在 `assemble` 以 `Rejection`（「manifest 列出但沒有內容」）記錄。SideStore 可在保留容器下裝回舊 IPA | `SpiderPack.swift` `SpiderPackStore.installedPack()`、`assemble(manifest:sources:)` | 相容包強化或 13 |
| G7 | 磁碟自洽不是信任邊界：Python spider 在完整 CPython 上執行（`webhtv_runtime.load` 的 `exec`），可寫整個 App 容器，能寫出自洽的 manifest 與 script 並在下次啟動被全域採用。對 IOS-POC-13 的 global 世代，開機重驗簽章只保證真實性，不保證新鮮度：它仍可把指標改回舊的、簽章有效的世代，並刪除用戶端安全狀態 | `webhtv_runtime.py` `load`；`SpiderPack.swift` `installedPack()` | 已知限制，見 第七節之十第 6 條與 D14 |
| G8 | spider 狀態不分設定：`spider_<siteKey>_` 與 `Caches/python-spider/<siteKey>.json` | `StorageHost.swift` `SpiderStorage`；`base/spider.py` `Spider._cache_file` | D11 |
| G9 | session key 只有 `Site.id`，adopt 的 reset 沒有 await；兩份設定有相同 key 與 ext 時可能沿用舊設定建的 session（未觀察到） | `SourceClient.swift` `SpiderSessionStore.session(for:resolver:)`；`WebHTVApp.swift` `ConfigView.adopt(_:config:from:)` | 13 啟用時 await reset，或 key 加世代 |
| G10 | Python cache 的模組全域缺陷 | `base/spider.py` `_site_key`、`_cache_dir`；`webhtv_runtime.py` `load` | 只回報，不修 |
| G11 | JS 沒有 CPU／時間上限，`host.req` 回應 body 沒有上限 | `JavaScriptSpiderRuntime.swift` `JavaScriptSpiderRuntime`（`timeout`）；`HTTPHost.swift` `HTTPHost.perform` | D10 |
| G12 | publisher 漂移：`NOT_PACKABLE` 只列 `host.js`；`SCHEMA`／`HOST_API` 在 Python 與 Swift 各寫一份 | `scripts/spider_pack.py` `SCHEMA`、`HOST_API`、`NOT_PACKABLE` | 12D 加一致性測試；清單修正屬相容包強化 |
| G13 | drpy rule 腳本走共用 URLCache | `DrpyEngine.swift` `DrpyEngine.downloadSession` | 只記錄（改掉會改變行為）；13 的下載不得沿用 |
| G14 | 快取檔名長度上限（URL 約 187 bytes 以上） | `SavedSource.swift` `cacheFileName`；`WebHTVApp.swift` `ConfigView.configURL(for:)` | 12C 以測試記錄現況；13 的 scope 目錄改用 SHA-256 命名 |
| G15 | 作用中的來源可以被刪除；下次啟動可能把 `wang-movie.json` 複製進它的 slot，離線時以遠端身分顯示別的設定 | `WebHTVApp.swift` `ConfigView.forget(_:)`、`restore`、`migrateLegacyCache(to:)`、`SettingsView` 的來源清單 | 只回報 |
| G16 | `use(_:)` 註解說供應商掛掉時顯示自己的快取，實際是保持前一個來源並顯示錯誤 | `WebHTVApp.swift` `ConfigView.use(_:)` | 凍結以實際行為為準 |
| G17 | `app.history` 回傳所有設定的紀錄（Android 依 cid 過濾、上限 60）；記錄分頁的「清除」刪除所有設定的紀錄 | `WebHomeBridge.swift` `handle(method:payload:)` 的 `app.history`；`WebHTVApp.swift` `HistoryView` 的清除動作（`WatchHistoryStore.clear()`） | D8 |
| G18 | WebHome bridge 沒有 frame／origin 閘：`userContentController(_:didReceive:)` 不檢查 `frameInfo` | `WebHTVApp.swift` `WebHomeWebView.makeUIView`、`Coordinator.userContentController(_:didReceive:)` | 凍結「WebHome 頁只能內建」 |
| G19 | IOS-POC-17 第十節「契約」小節的表過時（仍寫只有 capability 失敗才切換、MPV 沒有音軌選擇） | `docs/IOS-POC-17-dual-internal-player.md` 第十節 | 12A 加註，以程式與本文件為準 |
| G20 | 緩衝中手動換核心會以暫停抵達；開播前按暫停，20 秒後仍會切換並自動播放（**IOS-POC-27A 已修正**：換核心與換畫質依播放意圖 `rate != 0`；開播檢查只計算想播的時間，原生逾時改為 5 秒、MPV 維持 20 秒，見 `docs/IOS-POC-27-avplayer-2x-buffer-stall-controls.md`） | `PlaybackEngine.swift` `PlayerRouter.select(_:playing:)`、`startupTimedOut()` | IOS-POC-26 已記錄為既有的 A1；12E 依 26 的結論凍結 |
| G21 | SideStore schema 從 main 抓；`source.json` 沒有 IPA digest；build 單調性沒檢查 | `.github/workflows/ios-sidestore-release.yml` `Package and validate IPA`；`scripts/update_sidestore_source.py` | D12 |
| G22 | `fetch_python_ios.sh` 信任 `.payload-sha256` stamp，不重算解開後的內容 | `scripts/fetch_python_ios.sh` | 只回報（只影響本機建置） |
| G23 | 只有 spider 站台的設定會被拒 | `ConfigLoader.swift` `ConfigLoader.validate` | 另案產品決定，不屬 12 |
| G24 | 相容包的絕對 HTTPS script 路徑可以指向任何 host，`spiderPackURL` 也可以覆寫成任何 URL，schema 1 沒有同源要求；`DrpyEngine.checked` 在 config 沒寫 port 時也會拒絕 `https://host:443/…`（次要） | `SpiderPack.swift` `SpiderPackStore.refresh(from:)`、`url(for:defaults:)`；`DrpyEngine.swift` `checked(_:origin:)` | v1 manifest 以內容定址、禁止絕對 URL、要求同源（強化，第七節之五）；舊格式在 13 決定 |

### 之五、路線圖項目對照

| 路線圖項目 | 本文件的 ID |
|---|---|
| 契約：`ConfigSource` 與設定身分、逐來源快取隔離 | K9、K11、K12、K14、K22；G14、G15 |
| 契約：`SourceClient` 與 `PlaybackTarget`（含 headers） | K2、K15、K18、K19、K21 |
| 契約：`PlaybackSession` 狀態與控制語意 | K30、K32、K35、K39 |
| 契約：播放引擎邊界（`PlaybackEngine`、`PlayerRouter`、`PlaybackEngineSelection`、`PlaybackFailure`） | K26～K29；G20；12E |
| 契約：`SpiderRuntime`、`CSPSourceResolver`、CatVod JS／Python／drpy 路由與 host primitive | K1、K3～K7、K10；第六節 |
| 契約：`WatchHistory` 持久化、來源綁定、片頭片尾、續播 | K33～K35 |
| 契約：WebHome bridge ABI 與 Android 形狀 payload | K36；A27、A28、A30、A31、A37；G17、G18 |
| 契約：相容包優先順序、驗證與失敗回退 | K7、K8；A66；G1～G6、G24 |
| 盤點：Swift 內的來源 key、alias、host 清單、對照表與站台專屬分支 | A1～A15、A76 |
| 盤點：獨立於原生行為變更的內建 JS／Python／規則檔與圖片資源 | A31～A33、A38～A50、A57～A59、A74 |
| 盤點：已有安全遠端路徑的動態內容，與安全性依賴內建的內容 | A61～A69（已有遠端路徑）；A16、A28～A31、A46～A52（依賴內建） |
| 盤點：重複或重疊的更新機制 | M1～M15（處置欄） |

## 五、方案比較

| 方案 | 內容 | 正確性與相容性 | 安全 | 效能與包大小 | 維護、驗證、回滾 | 判斷 |
|---|---|---|---|---|---|---|
| S0 不改，直接做 IOS-POC-13 | 以現有 `hostApiVersion` 與相容包為基礎做 updater | 13 要猜相容性；`hostApiVersion` 的漂移會重演 | global 內容只有完整性，沒有真實性 | 無 | 13 的回滾沒有凍結的比較對象 | 不採用 |
| S1 路線圖原形 | 八個領域全部併成一個版本化 runtime ABI（含 `PlaybackSession` 與播放引擎）；每一類 Dynamic Layer（含圖片、文字、schema UI）都設計 logicalType；把相容包、drpy、Python、設定併入同一個 manifest | 播放區 2026-09-22 起有 18 次 commit、IOS-POC-25／26 進行中、⑱⑲ 未完成，會凍結未驗證的行為；schema UI 沒有 renderer，只能新建 | WebHTV 的簽章無法涵蓋使用者的內容，合併會改變 config 內容的信任邊界 | 無 | ABI 面太大，任何播放修正都要升 ABI，但 pack 其實碰不到播放 | 採用它的盤點範圍，不採用形狀 |
| S2 WebHTV 窄化版 | runtime ABI 只含 pack 碰得到的三個面（第六節）；Native 內部只凍結文件與 golden 測試；global 與 config 兩個信任域；manifest 只定義；v1 logicalType 只有 `spider.js`；播放凍結設閘；12 不改 production 行為，production 只新增常數 | ABI 最小；不凍結未驗證的播放；舊 pack 以 `js.host` minor＝`hostApiVersion` 對應，繼續有效 | global 以 Ed25519 取得真實性；config 在 v1 加上同源要求（強化）；安全狀態的完整性限制寫明（第七節之十） | 12A～12E 沒有執行期成本，production 只多一個只有常數、沒有呼叫者的檔案 | 每個階段可獨立 revert；測試的執行證據取決於 D2 | **採用** |
| S3 完整 TUF 或 Sigstore | 四角色 TUF client，或 keyless 簽章 | 相容 | 最強，含金鑰妥協復原 | 要新相依 | 沒有成熟的 Swift client，單一發布者不成比例 | 不採用；TUF 的用戶端規則已併入 S2 |

判斷：對路線圖是**補充並修正**。

1. 補充：runtime ABI 的明確範圍與升版規則、兩個信任域、fingerprint 測試、用戶端安全狀態的定義、測試執行管道的前提。
2. 修正：「圖片、文字、schema UI」目前沒有候選，不建立；設定擁有的內容不併入 WebHTV 簽章的 manifest，只共用 manifest 格式與啟用模型；`hostApiVersion` 從手動維護改為由測試綁定內容；播放契約的凍結改為設閘，不在 12 的開頭；相容包強化移出 12。
3. 不採用：Expo、CodePush、Shorebird 產品形狀中的精確 App 版本綁定、託管服務、readiness marker 與計時的當機判斷。

## 六、Runtime ABI 與版本政策

### 之一、涵蓋範圍

只涵蓋 runtime pack 能依賴的面：

| 面 | 包含 | 凍結時版本 | 與既有常數的關係 |
|---|---|---|---|
| `catvod.result` | `SpiderRuntime` 13 個簽名，其中 8 個有 production 呼叫（K1）；`class`、`list`、`filters` 輸出；`playerContent` 的 `{parse, url, header}`；`PlayURL` 的三種形狀；ext → `init` 字串規則（K1～K3） | 1.0 | 新增 |
| `js.host` | `host.js`（sha256 `6bd11d380d6194f26051f8e958685b2a0e74f54d01b3b0c09651a128dd827789`）與它的匯出物件；`__http`、`__crypto`、`__store`、`__util`、`console` 的名稱、參數、回傳形狀與預設值（User-Agent `okhttp/3.14.9`、`host.req` 逾時 15000 ms、跟隨轉址）；`drpy-bridge.js`、`js-spider.js`；`DrpyEngine.moduleRuntime` 的全域與四種 ESM 改寫；`JavaScriptSpiderRuntime` 的回傳轉換與最多 8 次 promise settle（K4） | 1.1 | major 為 1 時，minor 等於 `SpiderPackStore.hostApiVersion`（現為 1），舊 pack 的 `minHostApi` 直接對應 `minMinor`（之五） |
| `python.host` | CPython 3.13.15（Python-Apple-support b15）；`base.spider.Spider` 方法集與 `base/__init__.py` 的套件形狀；`webhtv_runtime` 的 `load`、`invoke`、`unload`、`diagnostics` 與 envelope；`sys.path` 順序；五個 wheel 版本（K5） | 1.0 | 新增；v1 manifest 不接受 `.py`，這個面先用於 config 腳本的診斷與日後的 logicalType |

另外記錄但 **pack 不能要求** 的：`webhome.bridge` 1.0（`sdkScript` 文字、訊息形狀、方法表、payload，K36），因為 WebHome 頁只能內建。v1 manifest 在 `requires.abi` 列出上表以外的任何面，一律拒絕。

### 之二、不涵蓋

播放、觀看紀錄、持久資料、config identity、Info.plist、mpv 選項、Libmpv、CPython 二進位。它們隨 IPA 版本走，只以第四節之一第二、三組的語意與 golden 測試凍結。另定義一個只供診斷的 `nativeCore` 描述：App 版本與 build、各 ABI 面版本、Libmpv `mpvkit-1.0.0-webhtv.2`、mpv `v0.41.0`、CPython `3.13.15`／`b15`。相容性判斷**永遠不以它為依據**。

### 之三、存放位置

WebHTVCore 的 Swift 編譯期常數（草案名 `RuntimeABI`，12D），不放 `Info.plist`、本地化字串或 bundle 資源（R24）。**production 只放常數**，沒有判斷函式。

### 之四、相容規則（規格，IOS-POC-13 實作）

對 `requires.abi` 列出的每一個面 s，必須同時成立：s 是這個 build 認得的面；`host[s].major == requires[s].major`；`host[s].minor >= requires[s].minMinor`。沒有列出的面不檢查（R20）。12D 只在測試 target 放一份參考實作，用來測試這條規則與之八的預設拒絕表；production 的判斷函式在 IOS-POC-13 落地，並必須通過同一組測試。

### 之五、`js.host` 與 `SpiderPackStore.hostApiVersion` 的對應

1. `js.host.major == 1` 時：`js.host.minor == SpiderPackStore.hostApiVersion`；schema 1 相容包的 `minHostApi` n 等同 `js.host` {major 1, minMinor n}。
2. schema 1 相容包只在 `js.host.major == 1` 時接受。
3. `js.host` 升到 2.0 時：`hostApiVersion` 停在最後一個 1.x 的 minor，不歸零、不重用；schema 1 路徑整包拒絕所有相容包，原因顯示「相容包格式太舊」。這是那時的行為變更，要在那一次升 major 的任務中另外核准。
4. 12D 的測試只在 major 為 1 時斷言第 1 條；major 不是 1 時改為斷言 schema 1 路徑存在拒絕分支（由 IOS-POC-13 實作）。

### 之六、升版規則

| 變更 | 升版 |
|---|---|
| 新增 host primitive、`host.js` 函式、注入的全域、`base.spider` 方法、原生會讀的新輸出欄位、新 logicalType、新 manifest 功能 | 該面 MINOR |
| 讓 `proxy`、`action`、`liveContent`、`isVideoFormat`、`manualVideoCheck` 變成有 production 呼叫與 host 支援 | `catvod.result` MINOR |
| 標記棄用 | MINOR |
| 移除或改名；改變語意或預設值（User-Agent、逾時、promise settle 次數、Bool 文字、吞掉錯誤的方法、cookie 範圍）；改變輸出欄位的意義；CPython 換 minor 版本（3.13 → 3.14）；wheel 有不相容變更 | 該面 MAJOR |
| fingerprint 改變（包括 JS／Python 檔只改註解） | 目前版本已隨 IPA 發布時一律要升版；MINOR 或 MAJOR 由變更者依上表判斷並寫進本文件。保守做法，避免人工判斷「語意沒變」。目前版本尚未隨任何 IPA 發布時，改寫該版本那一列即可（之十） |
| 只改 Swift 實作，fingerprint 不變 | 不升 |

### 之七、App build 閘

`minAppBuild`、`maxAppBuild` 是選填整數，與 `Bundle.main` 的 `CFBundleVersion` 比較；不比較 marketing 版本，不讀 pbxproj。只用於兩種情況：pack 依賴一個沒有改 ABI 的原生修正；排除已知有問題的 build。前提：IOS-POC-13 依賴它之前，`scripts/update_sidestore_source.py` 必須檢查 build 嚴格遞增（D12），現在沒有。

### 之八、預設拒絕

| 條件 | 結果 |
|---|---|
| 列出未知的 ABI 面，或 major 不同，或 minor 不足 | 整包拒絕；原因顯示「需要較新的 App」；active、LKG、內建都不變 |
| `critical` 含這個 build 不認得的功能名 | 整包拒絕 |
| 必要 entry 的 `logicalType` 未知 | 整包拒絕；`optional: true` 的 entry 則跳過並記錄 |
| build 不在 `minAppBuild`～`maxAppBuild` | 整包拒絕；原因顯示需要的 build |
| 未知的選填欄位 | 忽略（R5、R21、R22） |
| `expires` 已過 | 不採用這份 manifest；不影響 active 與 LKG（R3） |

「需要較新的 App」與「沒有更新」是兩個不同的可見狀態（R24）。

### 之九、降版安裝

SideStore 可以在保留容器的情況下裝回舊 IPA。開機時對已存的世代重套 ABI、build 與 `critical` 閘；不相容的世代不選用（回到 LKG 或內建），但不刪除，重新升級後可恢復。

### 之十、可測試的方式（fingerprint 機制）

每個面有一張「版本 → fingerprint」表，寫在 12D 的測試裡。測試算出目前的 fingerprint，必須等於 `RuntimeABI` 目前版本那一列；對不上就失敗。要讓測試通過，只能升版並新增一列（正常路徑），或在目前版本尚未隨任何 IPA 發布時改寫它那一列的雜湊（在 diff 上看得到，並在本文件記錄原因）。已隨 IPA 發布的版本列只能新增，不能修改，因此不能以「ABI 未變」為理由改寫。fingerprint 由四種機制組成，每一種都能偵測新增：

1. 整檔雜湊：`host.js`、`drpy-bridge.js`、`js-spider.js`、`base/spider.py`、`base/__init__.py`、`webhtv_runtime.py` 各算 SHA-256。App target 的 Python 檔以 `#filePath` 相對路徑讀取，沿用 `ExternalPlayerRemovalTests` 讀 App 檔案的做法。`third_party/python-ios-lock.json` 解析成 JSON，只取 CPython 版本、build 與各 wheel 的（名稱、版本），排序後雜湊。任何一個 byte 或版本改變都會失敗。
2. 執行期列舉：在測試裡建立一個 `JSContext`，呼叫 `CatVodHost.install(into:storage:cookies:session:)`（internal，`@testable import WebHTVCore` 可見），再執行 `host.js`。列出三種名稱，排序後與期望清單比較：與空 `JSContext` 相比新增的全域；`__http`、`__crypto`、`__store`、`__util`、`console` 各自的屬性名稱；`host.js` 匯出物件 `host` 的 `Object.keys`。新增、刪除或改名一個 primitive 都會失敗。`DrpyEngine.moduleRuntime` 是 internal `static let`（`DrpyEngineTests` 已直接使用），整段字串算 SHA-256。
3. 宣告切片雜湊：測試以 `#filePath` 讀 Swift 原始碼，依宣告開頭的文字（例如 `public struct CMSResponse`、`public struct CMSFilter`、`public struct CMSCategory`、`public struct Vod`、`struct PlayResponse`、`struct SpiderPlayResponse`、`public struct PlayURL`、`public protocol SpiderRuntime`、`public extension SpiderRuntime`、`public actor SpiderSession`）以大括號配對取出整個宣告本體（宣告名稱比對到完整識別字為止，例如 `public actor SpiderSession` 不得配到 `SpiderSessionStore`），刪除註解與空白行後算 SHA-256。在 `CodingKeys` 加一個 case、在合成 `Decodable` 的型別加一個欄位、在 `SpiderRuntime` 加一個方法、在 `SpiderSession` 加一個 runtime 呼叫，雜湊都會改變；找不到宣告開頭（改名或搬移）也失敗。切片器只需處理平衡的大括號、行註解、區塊註解與一般字串，這些宣告內沒有多行字串。它對同一宣告內的純實作修改也敏感，這正是之六「fingerprint 改變一律升版」要處理的保守代價。
4. 呼叫點掃描：沿用 `ExternalPlayerRemovalTests` 的做法，掃描 `ios/Sources/WebHTVCore` 與 `ios/WebHTVApp/Sources` 的 `.swift`，找出 `.liveContent(`、`.isVideoFormat(`、`.manualVideoCheck(`、`.proxy(`、`.action(`。在 `a6652cc3` 上只有前四個出現，而且只在 `PythonBoot.swift` 的 DEBUG 自我測試，`.proxy(` 沒有出現；新增的出現位置會讓測試失敗。限制：這是文字比對，以其他寫法間接呼叫會漏掉；第 3 條的 `SpiderSession` 切片負責主要路徑。

另外斷言：`js.host` major 為 1 時 minor 等於 `SpiderPackStore.hostApiVersion`（之五）；讀 `scripts/spider_pack.py`，斷言 `SCHEMA`、`HOST_API` 與 `SpiderPack.schema`、`SpiderPackStore.hostApiVersion` 相同；`WebHomeBridge.sdkScript` 的 SHA-256 記在 `webhome.bridge` 1.0 那一列。

## 七、Manifest 契約草案（只定義，不實作）

### 之一、檔案

`manifest.json` 是契約本體；global scope 另有 `manifest.json.sig`（sidecar）。檔案本體放在 manifest 同目錄的 `blobs/sha256/<hex>`，以內容定址，發布後不可變（R1、R5）。`files[].path` 是安裝到世代內的邏輯路徑，下載位置由 `sha256` 推導，**不允許絕對 URL**（補上 G24）。

### 之二、檢查順序（IOS-POC-13 實作）

1. 以不使用 URLCache 的專用 session 下載 `manifest.json`，超過 64 KiB 立即中止（K15、R1）。
2. global：下載 `manifest.json.sig`（1 KiB 以內），以 `keyId` 找內建公鑰，對 manifest **原始位元組**驗 Ed25519；未知或已撤銷的 `keyId` 拒絕。config：沒有簽章，改檢查 HTTPS，並要求 manifest 與 config 同源（沿用 `DrpyEngine.checked` 的比較方式，這是對 schema 1 的強化，見之五）。
3. 解析；`format` 與 `schema` major 必須認得。
4. `scope` 必須與用戶端自己推導的 scope 相同；manifest 不能自稱別的 scope。
5. `sequence` 必須大於這個 scope 與 `packId` 已接受的最大值；相等不動作；較小視為回滾並拒絕（例外：之十第 7 條的 backup key 重設）。
6. `expires` 未過。
7. `requires` 與 `critical`（第六節）。
8. 檔案清單：路徑規則、不重複、數量、每檔 `bytes` 與總和都在上限內。
9. 以上都通過才下載 blob；讀到宣告的 `bytes` 就停，比對 SHA-256。
10. 型別驗證（`spider.js` 在拋棄式 JSContext 編譯並確認 `module.exports` 非空）；全部通過才建立世代、更新安全狀態與指標。

### 之三、欄位

| 欄位 | 型別 | 必填 | 語意 | 驗證 |
|---|---|---|---|---|
| `format` | String | 是 | 固定 `"webhtv.runtime-pack"` | 不符就拒絕 |
| `schema` | Int | 是 | manifest 格式的 major，v1＝`1` | 不認得就拒絕；新增選填欄位不升 |
| `packId` | String | 是 | pack 識別，`[a-z0-9.-]`，1～64 字元 | 不得與 bundle id 或 SideStore source id 相同 |
| `scope` | Object | 是 | `{"kind": "global"}` 或 `{"kind": "config"}` | 必須等於用戶端推導的 scope |
| `sequence` | UInt64 | 是 | 單調遞增的發布序號，在這個（scope、`packId`）內唯一 | 見之二第 5 條；已發布的序號內容不可變 |
| `version` | String | 是 | 顯示用版本 | 從不比較 |
| `requires.abi` | Object | 是 | `{"<面>": {"major": Int, "minMinor": Int}}` | 第六節之四 |
| `requires.minAppBuild`、`requires.maxAppBuild` | Int | 否 | 見第六節之七 | 整數比較 |
| `critical` | [String] | 是（可為空） | 必須理解的功能名；v1 已知集合為空 | 有未知名稱就拒絕 |
| `expires` | String（RFC 3339，UTC） | 是 | 這份 manifest 可被採用的期限 | 見第六節之八 |
| `files[].path` | String | 是 | 世代內的相對路徑，只允許 `[A-Za-z0-9._/-]`，不得有 `..`、開頭 `/`、重複，128 bytes 以內 | 不符就整包拒絕 |
| `files[].logicalType` | String | 是 | v1 只有 `"spider.js"` | 以 String 解碼；未知值依 `optional` 處理 |
| `files[].class` | String | `spider.js` 必填 | 對應的 `csp_` class 名稱，必須是合法檔名 | 補上 G4 |
| `files[].aliases` | [String] | 否 | 只能指向同一 pack 提供的 script（沿用 K7） | |
| `files[].bytes` | Int | 是 | 檔案大小 | 不超過每檔上限；下載讀到此數就停 |
| `files[].sha256` | String | 是 | 64 個小寫十六進位字元 | 不符就整包拒絕 |
| `files[].optional` | Bool | 否，預設 `false` | 無法使用時是否可跳過 | |
| `directive` | String | 否 | v1 只有 `"rollbackToBundled"`：`files` 必須為空，把這個 scope 退回內建 | 本身也受 `sequence` 約束 |
| `revokeKeyIds` | [String] | 否 | 只接受由 backup key 簽的 manifest；用戶端持久保存，之後拒絕這些 `keyId` | 只限 global |
| `notes` | String | 否 | 更新說明，視為不可信的純文字 | 4 KiB 以內 |

### 之四、範例

數值為示意；global scope：

```json
{
  "format": "webhtv.runtime-pack",
  "schema": 1,
  "packId": "webhtv.spiders",
  "scope": { "kind": "global" },
  "sequence": 3,
  "version": "2026.09.25-1",
  "requires": {
    "abi": {
      "catvod.result": { "major": 1, "minMinor": 0 },
      "js.host": { "major": 1, "minMinor": 1 }
    },
    "minAppBuild": 22
  },
  "critical": [],
  "expires": "2026-12-31T00:00:00Z",
  "files": [
    {
      "path": "spiders/JianPian.js",
      "logicalType": "spider.js",
      "class": "JianPian",
      "aliases": ["JPianAmns"],
      "bytes": 12000,
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
    }
  ],
  "notes": "修正 JianPian 的站台位址"
}
```

`manifest.json.sig`：

```json
{ "keyId": "0123456789abcdef", "alg": "ed25519", "sig": "<base64 簽章>" }
```

### 之五、真實性信任根

| 選項 | 內容 | 真實性 | 成本與風險 | 判斷 |
|---|---|---|---|---|
| T0 同源＋完整性 | HTTPS＋與 config 同源＋manifest 內 SHA-256 | 沒有，只有完整性 | 最低 | config scope 採用；比 schema 1 嚴格（schema 1 允許 `spiderPackURL` 覆寫與指向任何 host 的絕對 URL，G24），是新決策；對 global 不足 |
| T1 只接受 WebHTV 的 GitHub Release URL | 固定發布主機 | 信任的是帳號與傳輸，不是作者簽章；app release 會被 `--clobber` 覆寫 | 低 | 不採用 |
| T2 Ed25519 分離簽章，公鑰編進 Swift | CryptoKit `Curve25519.Signing.PublicKey.isValidSignature`；active 與 backup 兩把 | 有 | 要管理私鑰；換掉內建集合需要 IPA | **採用（global，前提是 D13 決定要 global 通道）** |
| T3 minisign 預設格式 | BLAKE2b 預雜湊 | 有 | CryptoKit 沒有 BLAKE2b | 不採用；CI 以標準工具產生原始 Ed25519 簽章 |
| T4 RSA／X.509 | 憑證鏈（Expo、Shorebird 的做法） | 有 | 較大；憑證到期會讓舊 IPA 拒絕所有更新 | 不採用 |
| T5 Sigstore keyless | Fulcio＋Rekor＋TUF root | 有 | 沒有 Swift client | 最多用於 CI 出處紀錄 |
| T6 完整 TUF 四角色 | root、targets、snapshot、timestamp | 有，含金鑰妥協復原 | 沒有成熟 Swift client；單一發布者不成比例 | 採用其用戶端規則，不採用協定 |

產品前提（D13）：T2 讓 WebHTV 維護者可以遠端推 JS 給所有使用者，也要長期保管私鑰、定期重簽 `expires`。使用者可以選「只要 config scope」：那樣就沒有 global 通道、不需要私鑰，A38～A45 維持隨 IPA 更新；本文件仍保留 global 的定義，日後要開再決定。

金鑰規則（D13 選 global 時適用）：

- global 採 T2。兩把公鑰：`active`（CI 簽發用）與 `backup`（離線保存，只用於撤銷、重設與接手）。
- `keyId`＝公鑰原始 32 bytes 的 SHA-256 前 16 個十六進位字元。
- 撤銷：backup key 簽的 manifest 可帶 `revokeKeyIds`；之後即使沒有新 IPA，也不再接受 active key。active 被撤銷後，直到新 IPA 帶來新的內建集合前，只有 backup key 能簽。新增或更換內建集合需要 IPA。
- 私鑰放 GitHub Actions secret 或由使用者離線簽，是 D3。
- 限制：公鑰本身的真實性等同 IPA 通道（GitHub Release＋可變 branch 的 `source.json`，沒有 IPA digest，G21）。
- SideStore 重簽不影響編進 binary 的公鑰。任何信任判斷都不得依賴 bundle id、team id 或簽章身分；免費帳號可能改寫 bundle id，repo 沒有驗證。
- config scope 採 T0：WebHTV 的簽章不得宣稱涵蓋使用者的內容。v1 的 config manifest 位置只以 K9 的規則相對 config 解析，不讀 `spiderPackURL`；schema 1 路徑在 12 期間不變（D5）。

### 之六、Digest

SHA-256，小寫十六進位（CryptoKit，`SpiderPack.swift` 已使用）。global 的 digest 由簽章傳遞取得真實性；config 的 digest 只有完整性。`;md5;` 後綴永遠不算 digest（K9）。

### 之七、大小上限

編進 Native Core，manifest 只能宣告不超過這些值：

| 項目 | 上限 | 依據 |
|---|---|---|
| `manifest.json` | 64 KiB | R1 的 W；目前的相容包只會列 8 個 script |
| `manifest.json.sig` | 1 KiB | 固定格式 |
| 單一檔案 | 512 KiB | 與 `DrpyEngine.maximumFileBytes` 相同；最大的內建 spider `XBPQ.js` 12,137 bytes，`host.js` 21,157 bytes |
| 每個世代總和 | 2 MiB | 與 `DrpyEngine.maximumBundleBytes` 相同 |
| 檔案數 | 64 | 目前候選 8 個 |
| `notes` | 4 KiB | 純文字顯示 |
| `path` | 128 bytes | 避開檔名長度問題 |
| `state.json` | 64 KiB | 用戶端自己寫的安全狀態（之十） |

### 之八、Scope 與隔離

1. scope key：`global`，或 `config:<configIdentity v1>`（K12 的原樣字串）。匯入的設定沒有 baseURL，沒有 config scope，與現在相同。
2. 儲存位置：`Application Support/RuntimePacks/<SHA-256(scope key)>/`，與 `Application Support/SpiderPack` 並存、不取代；目錄名用雜湊，scope key 本身寫在 `state.json` 裡，避開 G14 的檔名上限。遷移舊相容包是 13 的明確步驟。
3. 優先順序（D6 建議）：config scope 的 pack → global pack → 內建 script。
4. A→B→A：每個 config scope 有自己的 active 指標，切換設定時選該 scope 的世代；global 對所有設定相同。這修正 G1。
5. 遺忘來源（`ConfigView.forget(_:)`）時刪除該 scope 的整個目錄，包括 `state.json`（之十第 4 條）。
6. runtime pack 不可寫的 Native 持久資料：A10 總表的全部名稱，也就是 `configSourceURL`、`configUpdatedAt`、`selectedSiteKey`、`selectedSiteBySource`、`webhtv.playback.defaultEngine`、`spiderPackURL`、`cache_*`、`saved-sources.json`、`wang-movie.json`、`<base64url>.json`、`WatchHistory/history.json`、`SpiderPack/`、`SpiderPack-staging-*`、`webhtv-ads-*`，以及 `RuntimePacks/` 本身。spider 自己的狀態（`spider_<siteKey>_*`、`Caches/python-spider/`）除外（第 7 條）。
7. spider 可見的狀態（`spider_<siteKey>_`、`Caches/python-spider`）維持現在的 key，跨世代保留；是否改為逐 scope 是 D11。
8. 啟用新世代時必須失效的快取與工作（全表）：
   - `SpiderSessionStore.reset()`，並 **await** 完成後才發布新世代（修正 G9 的時序）。
   - process 全域的 `InstalledSpiderPack.shared` 與每次呼叫 `SpiderRegistry.active` 算出的 registry：改為以世代為輸入。
   - `DrpyEngineStore.shared`（以 baseURL 為 key 的記憶體 prelude）：只有啟用的內容會影響 drpy 時才清。
   - 進行中的 `AggregateSearch`：舊世代建立的呼叫可以跑完，但結果以開始時的世代標記；新搜尋用新世代。
   - WebHome inline session（`WebHomeBridge.inlineSiteKey`＝`webhome_inline`）與它的 spider session。
   - `PlaybackSession` 的下一集預解析（`PlaybackTargetPrefetch`）：清掉，或讓 `PlaybackTargetIdentity` 加入世代 id。
   - 播放中不啟用；站台清單改變時只經 `SiteSelection.choose()`，不寫站台記憶。
9. 限制：Python spider 可寫整個容器（G7），config scope 的隔離只防意外外洩，不防惡意的 Python spider；對 global 的影響見之十第 6 條。

### 之九、Activation generation id

1. 格式 `gen-<sequence>-<manifest SHA-256 前 8 字元>`；目錄內容不可變，永不就地修改。世代目錄保留原始的 `manifest.json` 與 global 的 `manifest.json.sig`，開機重驗、LKG 重驗與撤銷判斷（之十第 7、8 條）都讀它們，`state.json` 不另存 `keyId`。
2. 指標與安全狀態合在每個 scope 的 `state.json`（之十），以 `Data.write(options: .atomic)` 寫在世代所在的 volume（R17、R18）。
3. 開機選擇是 O(1)：讀 `state.json`，以與下載時相同的規則重驗 active 世代；不連網、不重播 log；任何失敗依序改用 LKG（同樣重驗）、內建（R25）。

### 之十、用戶端安全狀態

1. 內容：每個 scope 一份 `state.json`：
   - `scopeKey`、`packId`；
   - `maxSequence`：這個（scope、`packId`）已接受的最大 `sequence`；
   - `active`、`lkg`：各為 `{generation, sequence, manifestSha256}` 或 null；
   - `bad`：壞世代清單，每筆 `{sequence, manifestSha256, reason}`；
   - global 另有 `revokedKeyIds`。
2. 存放：`Application Support/RuntimePacks/<SHA-256(scope key)>/state.json`，檔案保護 `completeUntilFirstUserAuthentication`（R19）。世代目錄排除備份；`state.json` **不排除備份**，讓換機或還原後仍保留序號下限。
3. 生命週期：第一次接受某 scope 的 manifest 時建立；每次接受、啟用、標壞都整檔原子重寫。`maxSequence` 只增不減，只有兩個例外：第 4 條與第 7 條（第 7 條每次撤銷只生效一次）。`revokedKeyIds` 只增不減。`bad` 只保留 `sequence` 大於等於 LKG 的項目。
4. 遺忘來源：刪除該 config scope 的整個目錄，`maxSequence` 隨之歸零。之後重新加入同一來源，會接受任何 `sequence`，所以可能被回滾到較舊的內容；config scope 本來就沒有真實性（T0），這是可接受的代價。反過來，config origin 若曾被入侵並推出極大的 `sequence`（快轉攻擊），使用者以「遺忘來源再加回」即可復原；本文件把這件事寫進 13 的失敗說明文字。
5. 備份與還原：世代不在備份內，還原後回到內建再重抓；`state.json` 在備份內，保留備份當時的下限。還原到較舊的備份等於下限回到較舊的值，這段期間只能靠 `expires` 限制可重放的舊 manifest。因此 global 的 `expires` 長度屬於 D13：越短，可重放的期間越短，但維護者要更常重簽。建議 30 天。
6. 完整性限制：Python spider 在同一個 process 內、以完整 CPython 執行（G7），可以刪改 `state.json`，再把指標改回較舊、簽章仍有效的世代（已發布的 blob 不可變且公開），重新啟用舊組合或已撤銷的 key。簽章不涵蓋本機狀態，所以**global 的防回滾與撤銷只在沒有惡意程式碼於 App 內執行時成立**。可選的補強是把 `maxSequence` 與 `revokedKeyIds` 另存一份在 Keychain（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`），開機時兩者取較嚴格的值。限制：Keychain 對同一個 process 可讀寫；CPython 的 lib-dynload 沒有刪減、授權清單列有 libFFI，`ctypes` 很可能可用（未在裝置上確認），惡意 Python 仍能呼叫 Security framework；Keychain 只擋住「以一般檔案 I/O 刪改」這條最簡單的路。`ThisDeviceOnly` 的項目不隨備份移到新裝置。是否採用是 D14，在 13 決定。
7. 快轉攻擊的復原（沿用 TUF 1.0.36 5.3.11 的做法：換 key 後丟掉信任中的版本資訊）：active key 外洩後，攻擊者可發布接近 UInt64 上限的 `sequence`，之後的合法發布都會被拒。復原方式：維護者以 backup key 簽一份 manifest，帶 `revokeKeyIds`（撤銷外洩的 active key）；用戶端接受 backup key 簽的 manifest 時，**只有在它的 `revokeKeyIds` 至少新增一個尚未在 `revokedKeyIds` 裡的 keyId 時**，才把該 scope 的 `maxSequence` 設為這份 manifest 自己的 `sequence`（即使比現值小），並清掉以被撤銷 key 接受的 `active`、`lkg`，回到內建或這份 manifest 的內容。其他情況（包括之後每一份 backup key 簽的發布）一律照「`sequence` 必須嚴格大於 `maxSequence`」處理。因為 `revokedKeyIds` 只增不減，每次撤銷只能重設一次下限；若無條件重設，任何人都能在 `expires` 之前重播一份較舊、仍有效的 backup 簽章 manifest 來拉低下限，形成永久的回滾缺口（審查 2026-09-25 發現）。這條規則屬於安全語意，列入 D17 由使用者確認。backup key 本身等同信任根，離線保存。
8. LKG 重驗：回退到 LKG 時，以與下載時相同的規則重驗：global 驗簽章並確認簽章的 `keyId` 沒有被撤銷；兩種 scope 都重算每檔 hash、重套 `schema`、ABI、build 與 `critical` 閘，並確認不在 `bad` 清單。任何一項失敗就改用內建。

### 之十一、LKG 與保留

1. 每個 scope 保留 active 加 1 個 LKG；staging 另外清理（R8）。
2. 壞世代清單以（scope key、`packId`、`sequence`、`manifestSha256`）為 key，不自動重試（R11）。
3. 只有確定性失敗才標壞：簽章、hash、schema、ABI、JS 編譯或載入 smoke。App 被殺或進背景不算，也不用計時的當機推論（R10）。
4. `rollbackToBundled` 讓已發布的壞 global pack 不需新 IPA 就能撤回；之後較大的 `sequence` 可以再啟用。
5. 檔案保護用 `completeUntilFirstUserAuthentication`，不用 `.complete`（鎖定中有 PiP、背景音訊與自動下一集）；世代排除備份，從備份還原時回到內建再重抓（R19）。
6. 過期不刪除、不停用 active 與 LKG。

### 之十二、舊格式 schema 1 的對應

1. 12 期間 schema 1 相容包維持原樣可採用（D5 建議），行為不變。
2. 概念對應：scope＝config（解析方式不變）；`requires.abi` 等同 `js.host` {1, `minHostApi`} 與 `catvod.result` {1, 0}；只在 `js.host.major == 1` 時成立（第六節之五）。
3. v1 只有整包層級的 `requires`；舊格式逐 script `minHostApi` 的跳過規則只保留在 schema 1 路徑。
4. schema 1 沒有 `sequence`，沒有防回滾，也沒有同源要求，這是舊格式的已知限制（G5、G24）。

## 八、分階段實施

### 之零、共同規則

1. 每個階段一個 task guard session、一個 commit，可獨立 revert；開始前都要使用者明確說「開始實施 12X」。
2. 12A～12E 都不改 production 行為、不需要發版。會改行為的相容包強化已移出（之六）。
3. 本環境沒有 Swift toolchain：測試都是未經編譯撰寫，編譯與執行證據取決於 D2 選定的管道；預估已含一次編譯錯誤的修正。
4. 預估是本環境代理的實際執行時間，不含使用者回覆與前置等待；CI 單次等待時間未量測，另計。
5. 12E 的 task guard scope 含 `PlaybackEngineTests.swift`，與 IOS-POC-26-2 可能改的檔案相同，必須排在 IOS-POC-26 最後一個 commit 之後，不得與它的未提交或未發布工作重疊。

### 之一、12A：文件凍結

| 項目 | 內容 |
|---|---|
| 前置 | 使用者說「開始實施 12A」（視為同意 12A 先於 ⑱⑲，D1 只對 12B～12D 另問） |
| 內容 | 依第四節之零在凍結 HEAD 重新比對並更新第四節；非暫定列標成「v1 生效」，暫定列保留到 12E；`docs/current-task-state.md` 更新 IOS-POC-12 狀態；`docs/IOS-POC-12-13-runtime-update-roadmap.md` 的 IOS-POC-12 節更新狀態並連到本文件；在 `docs/IOS-POC-17-dual-internal-player.md` 第十節「契約」小節的表前加一行註記「已被 17F、IOS-POC-26 與程式取代，以 IOS-POC-12 任務文件為準」，不改其他內容 |
| 修改檔案 | 本文件、路線圖、`docs/current-task-state.md`、`docs/IOS-POC-17-dual-internal-player.md` |
| 回歸時會失敗的測試 | 不適用（文件） |
| 驗收 | 凍結 HEAD 的完整 SHA 已記錄；每個變更檔與新增檔都對到 K、A、M 或 G 列；每一列都有檔案＋符號；分類只有四個固定標籤；沒有「待決定」列 |
| 回滾 | `git revert` |
| 預估 | 20～30 分鐘 |

### 之二、12B：macOS 單元測試 workflow（重新開啟 IOS-POC-20 Q6）

| 項目 | 內容 |
|---|---|
| 前置 | D1 與 D2 選「12B」 |
| 與既有決定的關係 | 使用者在 IOS-POC-20 Q6 選 C（不跑單元測試），沒有選 A（在發版 workflow 加 `swift test`），並決定「不新增 push 觸發的測試 CI」（`docs/IOS-POC-20-aggregate-search.md`「驗證方式（更新）」與「實作紀錄」；IOS-POC-26 與 `a6652cc3` 的 commit message 也引用）。12B 只能手動觸發，不違反「不新增 push 觸發」，但**推翻 Q6＝C**，必須由使用者明確改變決定 |
| 內容 | 新增只能手動觸發（`workflow_dispatch`）的 workflow，在與發版 workflow 相同的 `macos-26` runner 上執行 `swift test --package-path ios`（滿足 `ios/Package.swift` 的 swift-tools 6.2 與 macOS 14）；不設 `WANG_MOVIE_JSON`、`WANG_MOVIE_URL`、`CSP_GOLDEN_SITE`、`DRPY_GOLDEN_SITE`／`DRPY_GOLDEN_BASE`，這些測試因此提前返回；不加 push、pull_request 或 schedule 觸發；不發布、不上傳任何 artifact |
| 修改檔案 | `.github/workflows/ios-core-tests.yml`（新檔） |
| 基準 | 第一次執行時實際的測試數與結果。參考：`a6652cc3` 上有 382 個 `@Test` 宣告；最後一次有紀錄的完整執行是 IOS-POC-22 的 354／354（`docs/current-task-state.md`）；之後 P10（`637d3597`）、IOS-POC-20（`ee597124`）、IOS-POC-23（`440d671e`）、IOS-POC-26-1（`a6652cc3`）改過的測試從未編譯或執行 |
| 失敗規則 | 測試 target 編譯失敗：12B 停止，不在 12B 內修，記錄錯誤與檔案，請使用者決定是否另開「只修測試編譯」的單元（D15）；在它完成前 12C、12D 不開始，因為它們的測試無法編譯。WebHTVCore 本身編譯失敗：代表 production 有問題，停止並回報（下一次發版也會失敗）。既有測試執行失敗：分類為環境（例如需要網路）、過時的預期或回歸，回報、不修、不以 `--skip` 隱藏；基準記為「N 通過、M 失敗（列名與分類）」，失敗不在 12C／12D 會碰的檔案時，12C、12D 可以繼續 |
| 驗收 | 一次執行完成，基準與失敗分類寫入本文件 |
| 回滾 | 刪除該檔 |
| 預估 | 20～30 分鐘，另加 1～2 次 CI |

使用者維持 Q6＝C 或改選其他選項時：

| D2 的選擇 | 12B 做什麼 | 仍無法證明的事 |
|---|---|---|
| B：使用者在自己的 Mac 執行 `swift test --package-path ios` 並回報 | 不新增檔案；基準與失敗規則同上，由使用者的回報填入 | 只證明那一台 Mac、那一次的結果；之後每次變更都要再請使用者執行 |
| A：在發版 workflow 的 build 前加 `swift test`，只在核准發布時執行 | 改 `.github/workflows/ios-sidestore-release.yml`，失敗就不發布 | 沒有發布就沒有測試證據；既有測試失敗會擋住發布，要先處理 D15 |
| C（維持）：不跑 | 12B 不做；12C、12D 的測試只能未經編譯撰寫 | 測試能否編譯（發版 workflow 只編譯 App，不編譯測試 target，測試檔的錯誤不會被發現）；golden 值與 fingerprint 期望值是否正確；新增測試是否破壞既有測試；`RuntimeABI.swift` 只在下次核准發布時隨 App 編譯。第九節「Runtime ABI／版本政策可測試」只能寫成「已文件化，並有可執行的 `swift test` 指令，沒有執行證據」 |

### 之三、12C：設定、身分、觀看紀錄 golden 測試（只加測試）

| 項目 | 內容 |
|---|---|
| 前置 | D1；D2 選定管道；D15 若被觸發則先完成 |
| 內容 | `ConfigSource.identity` 不正規化（host 大小寫、結尾斜線、query、fragment）與 `imported`；`SavedSource.cacheFileName` golden，並記錄約 187 bytes URL 的檔名上限（記錄現況，不修）；`Site.id` 與 history key 的 golden（flat、object、string ext、重複 key）；ext → extend 以解析後的 JSON 比較；`history.json` 三個世代的 fixture（10E 前沒有 `sourceID`、5S-2 前沒有 `opening`／`ending`、目前），以字串常數內嵌；config schema v1 被忽略的 key 清單 |
| 修改檔案 | `ios/Tests/WebHTVCoreTests/ContractFreezeConfigTests.swift`（新檔）；不改 `ios/Package.swift`（fixture 內嵌，不加資源） |
| 回歸時會失敗的測試 | 有人正規化 identity、改 base64url、改 `Site.id` 推導、把 history 的選填欄位改成必填或改名時，對應測試失敗 |
| 驗收 | D2 的管道全部通過，測試數＝基準＋新增 |
| 回滾 | 刪除測試檔 |
| 預估 | 45～60 分鐘，另加 1～2 次 CI |

### 之四、12D：Runtime ABI 常數與 fingerprint

| 項目 | 內容 |
|---|---|
| 前置 | 同 12C |
| 內容 | production 新增 `RuntimeABI`，**只有常數**：`catvod.result` 1.0、`js.host` 1.1、`python.host` 1.0 與記錄用的 `webhome.bridge` 1.0；沒有判斷函式、沒有呼叫者。測試新增：第六節之十的四種 fingerprint 機制與「版本 → fingerprint」表；`js.host` major 為 1 時 minor 等於 `SpiderPackStore.hostApiVersion`；讀 `scripts/spider_pack.py` 斷言 `SCHEMA`、`HOST_API` 與 Swift 相同；`WebHomeBridge.sdkScript` 的 SHA-256；相容規則（第六節之四）的測試用參考實作與它的規則表測試 |
| 修改檔案 | `ios/Sources/WebHTVCore/RuntimeABI.swift`（新檔）；`ios/Tests/WebHTVCoreTests/RuntimeABITests.swift`（新檔）。`DrpyEngine.moduleRuntime`、`CatVodHost.install` 都是 internal，測試以 `@testable import WebHTVCore` 直接使用，不改任何存取層級 |
| 回歸時會失敗的測試 | `host.js`、兩個 bridge、`moduleRuntime`、host primitive、`base/spider.py`、`base/__init__.py`、`webhtv_runtime.py`、lock 內的 CPython 與 wheel 版本、輸出型別的宣告本體、`SpiderRuntime`／`SpiderSession` 本體或 `sdkScript` 改變而版本沒變；新增 `SpiderRuntime` 的 production 呼叫點 |
| 驗收 | D2 的管道通過；production diff 固定只有新增的 `RuntimeABI.swift` |
| 回滾 | 刪除兩個新檔 |
| 預估 | 75～105 分鐘，另加 1～2 次 CI |

### 之五、12E：播放契約凍結（設閘）

| 項目 | 內容 |
|---|---|
| 前置 | IOS-POC-25 結束（commit、發布與真機結果寫入它的任務文件）；IOS-POC-26 結束（26-1 編譯、發布並真機驗收；26-2 決定有廣告 HLS 上「位置」的時間軸與 MPV 核心復原）；⑲ 在含 IOS-POC-26 的版本上重新回報；MPV 相關列另等 ⑱ |
| 內容 | 依 IOS-POC-26 的最終語意寫入交接規則：目標引擎從切換當下的位置開始；只有引擎回報過的位置（`PlayerRouter.handOff` 的已回報位置、`reload(at:autoplay:)` 的非起點位置）標 `exactStart`，開片、續播、片頭略過、換畫質維持原本的起播；有廣告 HLS 上的位置採 26-2 決定的時間軸；容許誤差以 ⑲ 的實測值寫入；autoplay 依使用者的播放意圖，不依當下是否有畫面；target 與 history 不變；每次嘗試最多一次自動切換。加測試直接斷言 20 秒開播逾時以 `engineCapability` 計入 fallback；以 26-1 的 `onlyAPositionAnEngineReportedIsLandedOnExactly` 等既有測試為基準，不重寫。記錄 `player.control`／`player.status` 對照（把 `androidState` 搬進 WebHTVCore 是重構，要另外核准）。同時凍結第四節標成暫定的列 |
| 修改檔案 | `ios/Tests/WebHTVCoreTests/PlaybackEngineTests.swift`；本文件 |
| 回歸時會失敗的測試 | `PlaybackEngineTests` 的交接、`exactStart` 與逾時測試 |
| 驗收 | D2 的管道通過；⑲ 的實測誤差寫入 8L 與本文件 |
| 回滾 | revert 該 commit |
| 預估 | 30～45 分鐘，另加 1 次 CI（不含前置等待） |

### 之六、12F（已移出 IOS-POC-12）：相容包強化

| 項目 | 內容 |
|---|---|
| 內容 | `className` 必須是合法檔名（拒絕 `/`、`..`）；每檔 512 KiB、總和 2 MiB 的串流上限；`installedPack()` 重套 schema 與整包 `minHostApi`，缺檔時拒絕整包；`scripts/spider_pack.py` 的 `NOT_PACKABLE` 補上 `drpy-bridge.js`、`js-spider.js`。只對異常或惡意的 pack 改變行為 |
| 為什麼移出 | 會改 production 行為（例如降版 IPA 後，已安裝的相容包可能被拒），也需要發版；IOS-POC-12 的驗收是「不刻意改變使用者可見行為」 |
| 歸屬 | D4：另開任務（編號由使用者指定），或併入 IOS-POC-13 |
| 修改檔案（預估） | `SpiderPack.swift`、`SpiderPackTests.swift`、`scripts/spider_pack.py` |
| 發布前要問的事（使用者規定第 1 條） | 版本號與 build（`MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`；IOS-POC-26 已預定 `0.1.22 (23)`，屆時以 Git 為準）；是否與 IOS-POC-25／26 同批發布；tag `ios-v<版本>-b<build>`；release notes 中的行為變更說明；SideStore `source.json` 的更新；測試證據：發版 workflow 不編譯測試 target，新增的 `SpiderPackTests` 要靠 D2 的其他選項才有執行證據 |
| 預估 | 45～75 分鐘，另加 1～2 次 CI；發布另計 |

### 之七、12G：收尾

| 項目 | 內容 |
|---|---|
| 內容 | 第九節逐條填結果；移交 IOS-POC-13 的輸入清單（第七節、D3、D5～D17 的決定） |
| 修改檔案 | 本文件、路線圖、`docs/current-task-state.md` |
| 預估 | 10～15 分鐘 |

合計：12A～12D 加 12G 約 3～4 小時代理時間，D2 選 12B 時另加 3～6 次 CI 等待（12B、12C、12D 各 1～2 次）；12E 等前置條件。

## 九、驗收標準

| 路線圖的驗收項目 | 可檢查的條件 |
|---|---|
| 沒有刻意改變使用者可見行為 | 12A～12E 的 diff 只含文件、測試、12B 的 workflow（D2 選 12B 時）與只有常數的 `RuntimeABI.swift`；production 沒有行為變更，不需要發版。相容包強化已移出 |
| 書面盤點把每個候選資產分類 | 第四節之二的 76 項，每項都是四個固定標籤之一，並有位置、變更證據與信任模型；12A 在凍結 HEAD 重新比對後，沒有未分類的檔案 |
| 沒有「可能可執行」的模糊分類 | 判定規則第 1 條（W^X）先套用；只有兩個擁有者；沒有「待決定」列 |
| Runtime ABI／版本政策有文件且可測試 | 第六節；12D 的 fingerprint 與相容規則測試在 D2 選定的管道通過；只改內容不升版時測試失敗。D2 維持 C 時只能寫「已文件化，有測試，沒有執行證據」 |
| manifest／真實性／大小／回滾語意已定義 | 第七節：欄位表、範例、信任根、digest、上限、scope、世代 id、用戶端安全狀態、LKG 與保留、舊格式對應 |
| 既有相容包與設定的安全保證維持或加強 | `SpiderPack.swift`、`DrpyEngine.swift`、`PythonSpiderSource.swift`、`ConfigLoader.swift` 在 12A～12E 沒有任何變更；v1 對 config scope 加上同源要求（強化）；G1～G24 已記錄 |
| 本階段不新增 updater、downloader 或啟用 UI | diff 中沒有新的網路呼叫、檔案寫入或 UI；production 沒有相容性判斷函式 |

另外：

1. 測試數＝12B（或 D2 的替代管道）記下的基準＋12C、12D、12E 新增數。
2. 12E 完成前，本文件的狀態只能寫「部分凍結（pack 面與設定面）」，不得寫 IOS-POC-12 完成。
3. 第四節之零的重新比對已在凍結 HEAD 完成並記錄。

## 十、風險與未決問題

需要使用者決定：

| # | 問題 | 建議 | 需要使用者決定的事 |
|---|---|---|---|
| D1 | 12B～12D 能否在 8L ⑱⑲ 完成前開始（12A 以「開始實施 12A」同意） | 可以；它們不依賴播放的真機結果 | 同意調整路線圖順序，或維持「核心真機驗收之後才開始」 |
| D2 | 重新開啟 IOS-POC-20 Q6：單元測試怎麼執行 | 12B（只能手動觸發的 macOS workflow） | 選 12B、B（使用者的 Mac）、A（發版 workflow 內）或維持 C；各選項無法證明的事見第八節之二 |
| D3 | global 簽章私鑰放哪裡 | active 放 GitHub Actions secret，backup 離線由使用者保存 | IOS-POC-13 開始前決定；D13 選「只要 config」時不需要 |
| D4 | 相容包強化（原 12F）的歸屬 | 併入 IOS-POC-13 的第一個階段（13 本來就要改 `SpiderPack.swift`） | 併入 13，或另開任務並隨下一次發版 |
| D5 | schema 1 相容包是否繼續可採用 | 12 期間不變；13 遷到 config scope 後再決定是否停用 | 同意 |
| D6 | config pack 與 global pack 誰優先 | config → global → 內建（與 `rules` 的順序一致；使用者的設定作者優先） | 同意或改成 global 優先 |
| D7 | 引擎邊界的 URL scheme 白名單（K28 的缺口） | IOS-POC-13 開放 spider 熱更新前，在 `PlayerRouter.open` 或 `SourceClient.target(from:headers:parse:)` 加 http／https 白名單；先確認沒有現有來源依賴其他 scheme（尚未檢查） | 是否接受非 http 目標的行為改變 |
| D8 | `app.history` 跨設定、「清除」刪除所有設定的紀錄、`prev`／`next` 與 Android 不同 | 12 凍結現況，另開任務決定是否改成 Android 行為 | 是否另開任務 |
| D9 | pack script 載入失敗時回退內建（per-class fallback） | 13 加上，符合「遠端失敗不移除內建路徑」 | 同意列入 13 |
| D10 | 啟用遠端程式前是否需要 JS watchdog 與 `host.req` body 上限 | 13 啟用 global pack 前需要 | 同意列入 13 |
| D11 | spider 狀態是否改為逐 scope | 先不改（改名會孤立 token），13 設計遷移後再決定 | 同意延後 |
| D12 | `scripts/update_sidestore_source.py` 檢查 build 嚴格遞增、`source.json` 加 IPA digest、SideStore schema 釘版本 | 在 13 依賴 `minAppBuild` 前另案處理 | 是否另開任務 |
| D13 | 要不要有 global 發布通道 | 要，但只放 A38～A45；`expires` 30 天 | 選「global＋config」或「只要 config scope」；前者要長期保管私鑰並定期重簽 |
| D14 | 用戶端安全狀態只存檔案，還是另存一份在 Keychain | 13 決定；建議先只存檔案並把第七節之十第 6 條列為已知限制，Keychain 只在有證據顯示值得時再加 | 同意在 13 決定 |
| D15 | 12B（或 D2 的替代管道）發現既有測試無法編譯時怎麼辦 | 另開「只修測試編譯」的單元，scope 只含無法編譯的測試檔，完成後才開始 12C、12D | 是否授權那個單元 |
| D16 | M8（drpy rule、CatVod JS）、M9（Python）要不要改成世代啟用 | 維持每個 session 即時抓取；v1 manifest 不收它們 | 同意在 13 以證據決定 |
| D17 | backup key 簽的 manifest 何時可以重設序號下限（第七節之十第 7 條） | 只在新增撤銷 keyId 時重設一次，其餘一律要求序號嚴格遞增 | 同意這條安全規則，或要求更嚴格的做法（例如重設時另外要求 `expires` 更晚） |

不需要決定、但要知道的風險：

1. 本環境無法驗證任何事；在 D2 的管道執行之前，本文件提到的測試都沒有執行證據。
2. 播放區仍在變：2026-09-22 起 18 次 commit 改到 `PlaybackSession` 所在區段；Libmpv lock 在 2026-09-25 改了 5 次；`0.1.21 (22)` 的音訊工作階段變更真機未驗證；IOS-POC-25、26 進行中。
3. 相容包機制從未在現場使用：沒有為使用者的設定發布過 pack，`80a5ac52` 以 IPA 發布；13 不能假設發布管線已可用。
4. 公鑰的真實性等同 IPA 通道；SideStore 免費帳號可能改寫 bundle id（未驗證）。
5. config scope 的隔離不防惡意 Python spider（G7）；global 的防回滾與撤銷也只在沒有惡意程式碼於 App 內執行時成立（第七節之十第 6 條）。
6. 測試 target 自 354／354 之後沒有編譯過；目前有 382 個 `@Test` 宣告，第一次編譯可能失敗（D15）。

## 十一、Recovery anchor

- 目標：凍結 runtime pack 會依賴的 Native Core 契約、完成資產分類、定義 runtime ABI 與 manifest（真實性、大小、scope、世代、用戶端安全狀態、LKG），不改變使用者可見行為，不做 updater、downloader 或啟用 UI；完成後才能開始 IOS-POC-13。
- 狀態（2026-09-25）：**規劃完成、未實作**，沒有程式變更。
- 基準：`origin/ios-poc` `a6652cc3`；凍結前依第四節之零重新確認 HEAD 並重新比對，不沿用本文件的 SHA。
- 前置未完成：⑱ 未回報；⑲ 的位置項目已回報失敗，IOS-POC-26 修正中（26-1 已 commit、未編譯、未發布；26-2 研究中）；IOS-POC-25 由另一個 session 進行中。
- 可做的範圍：使用者說「開始實施 12A」後只能做 12A（只改文件）；12B～12D 需要 D1、D2 的答案；12E 等前置條件；相容包強化不屬於 IOS-POC-12。
- 相關檔案：本文件；`docs/IOS-POC-12-13-runtime-update-roadmap.md`（索引）；`docs/current-task-state.md`；`docs/IOS-POC-8L-core-real-device-acceptance.md`；`docs/IOS-POC-26-engine-switch-position.md`；`docs/IOS-POC-20-aggregate-search.md`（Q6）。第八節列出的新檔都還不存在。
- 驗收：第九節的七項與「另外」三條。
- 未解風險：第十節的六項。
- 下一步（唯一）：等使用者回覆「開始實施 12A」的指示，以及 D1、D2、D13 的答案。

## 附錄、審查處理

兩份審查的每一項都已套用；下列是查證後與審查文字不同，或需要補充說明的項目：

1. 「`startupTimeout` 在 `:408`」：`a6652cc3` 上 `public static let startupTimeout: Double = 20` 在 `PlaybackEngine.swift:409`，本文件用 `:409`。
2. 「`PlaybackEngine.swift`（+33）」：33 是 `a6652cc3` 的新增加刪除行數，淨位移是 15 行；本文件已依符號重新定位，不依位移推算。
3. 「第一次發版基準」：`54b9e89d` 是 IOS-POC-11 的發版基準，`7d18cf4a` 是第一次發布 `0.1 (1)` 的 commit，兩者都對；`7c76d5c2` 是兩者的祖先，本文件同時寫出。
4. 「`MPVBoot.swift` 是 DEBUG-only」：檔案本身沒有 `#if DEBUG`，唯一的呼叫在 `WebHTVApp.init()` 的 `#if DEBUG` 區塊內，A72 照實記錄。
5. 「使用者這次的要求是『開發完成發佈』」：使用者 2026-09-25 同一則訊息裡的「開發完成發佈」指的是切換位置修正（IOS-POC-26），對 IOS-POC-12 只要求規劃。本文件不把它當成 IOS-POC-12 的實施或發布授權。發布相關的待問事項列在第八節之六，IOS-POC-26 的發布狀態列在第一節。
6. 草案中「內建 spider 的 18 次 commit」：實測 8 個內建 spider 共經過 12 個不同的 commit（逐檔合計 19 次），K2 已更正。
7. 草案寫的「`PlaybackSession` 區 14 次 commit」：以 `git log -L` 對 `a6652cc3` 上的 `PlaybackSession` 區段量測是 18 次，K30、第五節與第十節已更正。
8. 評級：改為與 IOS-POC-23、24 相同的定義，不再註記差異；因此 R8、R12 由 B 改為 C，R9 改為 A（官方專案文件，已封存），R10、R24、R25 由 C 改為 D。
