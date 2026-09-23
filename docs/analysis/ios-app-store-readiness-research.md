# iOS 發行可行性研究

> **Superseded by dual internal-player decision, 2026-09-23** — for every mention of third-party players here (Infuse / Fileball / SenPlayer / VidHub, URL-scheme handoff, "external player"): they were removed from the product; WebHTV plays only with its own AVPlayer and MPV engines. See `docs/IOS-POC-17-dual-internal-player.md`. The rest of this record stands as written.

日期：2026-09-21
範圍：目前 `ios-poc` 的 App Store 送審風險，以及不經 App Store、自行簽署 IPA 的替代路線。

## 結論

目前完整相容版不適合原封不動送 App Store。最可能的阻擋項依序是：遠端下載並執行
JavaScript／Python、使用未公開的 AVFoundation 選項、第三方影音來源的授權責任。

自行簽署則可行，但不應每日產生一份 IPA：

- 免費 Apple Account 的描述檔只有 7 天，必須定期重新建置並安裝；把同一份即將到期的描述檔每天重簽，
  不會延長有效期。
- 付費 Apple Developer Program 可用 Ad Hoc 描述檔將固定裝置納入，只有程式更新或描述檔接近到期時才需重建。
- GitHub Actions 可以安全地自動簽署，但憑證、私鑰密碼與描述檔必須放在 Actions Secrets，不能提交到 Git。
- 從 GitHub 下載 IPA 不等於能直接在 iPhone 點擊安裝；仍需 SideStore／AltStore、Apple Configurator、
  Sideloadly，或合規的 Ad Hoc／MDM 安裝流程。

## Confirmed Facts

### 1. 現有架構會執行遠端程式碼

- `PythonSpiderSource.script` 從遠端設定檔的同源 HTTPS 位址下載 `.py`，再由
  `PythonSpiderRuntime` 交給內嵌 CPython 執行。
- `DrpyEngine` 下載引擎與規則後交給 `JavaScriptCore` 執行。
- `SpiderPackStore` 下載相容性套件，驗證 SHA-256 後替換執行中的 Spider 腳本。
- SHA-256、HTTPS 與同源限制能降低完整性風險，但不會改變它們是「下載後執行的程式碼」。

Apple App Review Guidelines 2.5.2 要求 App 自包含，禁止下載、安裝或執行會引入或改變功能的程式碼。
4.7 雖允許特定 HTML5／JavaScript mini apps、plug-ins 等遠端軟體，但還要求完整索引、內容管理、
年齡限制，且未經 Apple 事前許可不得向遠端軟體暴露原生平台 API。現有 `CatVodHost`／WebHome bridge
正會提供網路、儲存與播放器能力，不能假設自動符合 4.7。

### 2. 播放器使用未公開選項

`ios/WebHTVApp/Sources/WebHTVApp.swift` 以字串 `AVURLAssetHTTPHeaderFieldsKey` 將 HTTP 標頭交給
`AVURLAsset`，程式內註解也明確記錄該 key 不在 Apple 公開標頭中。Guideline 2.5.1 要求只能使用公開 API。
這是獨立於播放器是否正常運作的送審風險。

### 3. 內容權利需要逐一成立

Guidelines 5.2.1 至 5.2.3 要求開發者擁有或取得內容、第三方服務及影音串流的授權，Apple 可要求
提供證明。使用者自行匯入設定比在 App 內內建來源風險低，但不會讓開發者完全免責；App 目前明確以
`wang-movie.json` 作為入口，且包含針對特定第三方服務的 Spider 實作。

目前兩支內建 Spider 會隱藏「倫理、福利、小影院」分類，但這不是涵蓋所有匯入來源的系統性內容政策。
Guideline 1.1.4 禁止色情內容；若把外部來源視為使用者產生或遠端軟體內容，1.2／4.7 另要求過濾、
檢舉、封鎖與年齡控管。

### 4. 傳輸安全需要重做發行設定

`ios/WebHTVApp/Info.plist` 目前全域設定 `NSAllowsArbitraryLoads = true`。Apple 表示此設定會降低安全性、
送審時必須提出理由，並建議優先改用 ATS 相容 HTTPS 或最窄例外。這不一定單獨造成拒絕，但會增加審查，
且現有理由是「個人 POC」，不足以作為公開發行的長期設計。

### 5. 隱私與送件資料尚未完成

- 專案沒有 `PrivacyInfo.xcprivacy`。
- App 與 Core 多處使用 `UserDefaults`。Apple 將它列為 required reason API；App 自用情境對應的核准理由
  為 `CA92.1`。缺少適用理由的上傳檔案不會被 App Store Connect 接受。
- 所有 App 都必須在 App Store Connect 與 App 內提供容易找到的隱私權政策；目前 App 內沒有此入口。
- WKWebView 與第三方來源可能產生 cookie、IP、識別碼或追蹤行為，需在實際網路與第三方資料流稽核後，
  才能正確填寫 App Privacy。Apple 明確表示功能型 webview 的追蹤按原生功能處理。

### 6. 其他送件項目

- 目前 Bundle ID 是 `com.webhtv.ios.poc`，仍是 POC 識別。
- 內嵌 CPython payload 包含 OpenSSL；App Store Connect 要求所有包含或使用加密的 App 完成出口合規判定。
- 根目錄為 GPLv3。公開散布前必須確認所有著作權人的授權範圍、完整對應原始碼與第三方授權告知。
  App Store 條款與 GPLv3 是否能同時履行屬法律判斷；目前證據不足以宣稱已解決，應由權利人或法律顧問確認。
- 初次啟動只有匯入檔案或貼網址。若送審版沒有可合法測試的內容，可能同時碰到 2.1 完整性與 4.2 最低功能問題。

## Inferences

### App Store 最小可行版本

最短路線不是重寫整個 App，而是增加一個嚴格的 App Store 發行輪廓：

1. 不下載或執行 Python、drpy、Spider compatibility pack；移除未使用的 CPython payload。
2. 只接受 HTTPS 的資料型來源，例如原生實作的 type-0／1／4 API；不把 `wang-movie.json` 或第三方來源內建進 App。
3. 移除 `NSAllowsArbitraryLoads`，也不提供 HTTP 開關。
4. 移除 `AVURLAssetHTTPHeaderFieldsKey`；送審版只支援不需特殊標頭的串流，除非另有公開 API 的可驗證實作。
5. 提供一個開發者有權利的公版／自有示範來源，讓審查員能完成首頁、搜尋、詳情與播放流程。
6. 補齊隱私 manifest、App 內隱私權政策入口、App Privacy、授權告知、出口合規與 Review Notes。

這個版本仍可保留目前的 SwiftUI UI、AVPlayer、播放記錄、檔案匯入與外部播放器選擇。完整相容版則維持
個人安裝／側載用途；兩者不應使用完全相同的功能集合送審。

### 自行簽署方案

| 帳號／方式 | 可行性 | 更新節奏 | 主要限制 |
| --- | --- | --- | --- |
| 免費 Personal Team | 可行，但適合開發測試 | 最長每 7 天重新佈署 | 最多 3 台裝置、每台 3 個 App、描述檔與 App ID 7 天到期；GitHub 上放同一份簽章無法續期 |
| 付費 Developer Program + Ad Hoc | 最適合少數固定裝置 | 程式更新時或描述檔到期前 | 每個裝置 UDID 必須登錄；每類裝置每會員年度最多 100 台 |
| TestFlight | 適合測試群組 | 每個 build 90 天 | 外部測試需 TestFlight 審查；不是永久公開下載 |
| Enterprise | 不適用個人散布 | 依企業管理 | 僅限合格組織內部員工，不可當一般側載通道 |

若採付費 Ad Hoc，建議 GitHub Actions 只在 `ios-poc` 有新 commit 或手動按鈕觸發時建置，產物放 GitHub
Release／Artifact。每日排程只會浪費 macOS runner 時數，並不增加簽章壽命。

## Unknowns

1. 使用者目前是免費 Apple Account 或付費 Apple Developer Program。
2. 實際要安裝的 iPhone 數量、UDID 與偏好的安裝工具。
3. `wang-movie.json` 各來源的內容與 API 授權是否能提出書面證明。
4. GPLv3 專案所有貢獻者是否能授予 App Store 所需的額外許可或改採相容授權。
5. 遠端網站、WKWebView 與來源服務實際收集哪些資料。

## Decision Implications

- 若目標是自己長期使用：優先做「付費 Developer Program + Ad Hoc + GitHub Actions 按更新簽署」，不必處理 App Store 審核。
- 若目標是免費帳號：由 SideStore／AltStore 在裝置端定期刷新，比把 Apple Account 密碼交給雲端排程更合理。
- 若目標仍是 App Store：下一個開發階段應先建立 App Store 發行輪廓，而不是繼續增加遠端 Spider 覆蓋率。

## Sources

### Grade A：官方規範與文件

- Apple, App Review Guidelines（2.1、2.5.1、2.5.2、4.2、4.7、5.1.1、5.2），存取日 2026-09-21：
  <https://developer.apple.com/app-store/review/guidelines/>
- Apple, `NSAllowsArbitraryLoads`：
  <https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloads>
- Apple, Preventing Insecure Network Connections：
  <https://developer.apple.com/documentation/security/preventing-insecure-network-connections>
- Apple, Required reason APIs：
  <https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api>
- Apple, App Privacy：
  <https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy>
- Apple, Developer account overview（Personal Team 7 天限制）：
  <https://developer.apple.com/help/account/basics/about-your-developer-account>
- Apple, Create an Ad Hoc provisioning profile：
  <https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile>
- Apple, Device registration updates：
  <https://developer.apple.com/help/account/reference/device-registration-updates>
- Apple, Export compliance：
  <https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance>
- GitHub, Signing Xcode applications on macOS runners：
  <https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications>

### Local primary evidence

- `ios/Sources/WebHTVCore/Spider/PythonSpiderSource.swift`
- `ios/WebHTVApp/Sources/PythonSpiderRuntime.swift`
- `ios/Sources/WebHTVCore/Spider/DrpyEngine.swift`
- `ios/Sources/WebHTVCore/Spider/SpiderPack.swift`
- `ios/WebHTVApp/Sources/WebHTVApp.swift`
- `ios/WebHTVApp/Info.plist`
- `third_party/python-ios-lock.json`
- `LICENSE.md`
