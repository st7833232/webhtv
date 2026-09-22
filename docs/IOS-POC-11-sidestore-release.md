# IOS-POC-11：SideStore 發布流程

## 目標與範圍

- 使用者已核准在 `ios-poc` 建立自動 IPA、GitHub Release 與 SideStore source。
- 保留 App bundle identifier `com.webhtv.ios.poc`；source identifier 固定為 `com.webhtv.sidestore.source`。
- 不保存 Apple ID、密碼、憑證或 provisioning profile；不部署網站，不修改其他分支。
- 基準：`ios-poc` `54b9e89dd028d3fda748264f4d04e4db1f7812f4`，工作樹原先乾淨。

## 現況與選案

1. 不變更：沒有 iOS release workflow，也沒有 `source.json`，無法發布。
2. GitHub runner 使用 Apple distribution secrets：可以簽章，但對 SideStore 裝置端重簽是不必要的秘密與維運風險。
3. WebHTV 適配：建立 unsigned device `.app`，只以 ad-hoc identity 處理 CPython 內嵌 frameworks，再封裝 IPA 交給 SideStore 重簽。採此案。

本機第一次 fresh build 證明兩個包裝前提：`import Python` 需要 module map 在 Xcode 規劃前存在；上游 `install_python` 即使 App 不簽章仍要求 framework identity。前者移入既有 fetch script，workflow 先執行該 script；後者使用 `EXPANDED_CODE_SIGN_IDENTITY=-`，未引入個人憑證。本機 Xcode 27.0 的 `iphoneos` Release build 已通過。

## 依據

- SideStore `sidestore-source-types` `02d31fa6301deac10bae11e91e1316b656598882`，2026-09-22：`schema.json` 要求 source 的 `name`、`identifier`、`apps`，App 的 bundle identifier 與 IPA 一致，`versions[0]` 視為最新版，size 是 IPA byte 數。workflow 每次從官方 schema 下載並嚴格驗證。
- AltStore 官方 *Make a Source* 與 *Updating Apps*，2026-09-22：版本須對應 `CFBundleShortVersionString`，download URL 指向 IPA，最新版置於陣列第一筆。
- GitHub `actions/runner-images` `5257d1b466f9b19d009114c096e17e963f8f1b6c`，2026-09-22：`macos-26` 是 GA arm64 runner，含 Xcode 26 系列，符合此專案 iOS 17、Swift 6 與 arm64 device build。
- 不適用：沒有引入或更新 upstream player commit、ABI、codec、renderer 或依賴版本，因此沒有 commit ledger、效能論文或其他播放器實作比較。

## 驗收與回復

- GitHub Actions 在 `macos-26` 無 Apple secrets build 成功。
- IPA 只有一個 `Payload/*.app/Info.plist`；bundle、短版本、build version、minimum OS 與 source metadata 一致。
- SideStore 官方 schema 驗證通過；Release URL 公開下載內容與剛建立的 IPA byte-for-byte 相同。
- `source.json` 只由 release workflow 更新，最新版位於第一筆。
- 回復方式：revert 本任務 commit；若已發布，另外刪除該 GitHub Release 與 tag。

## Recovery anchor

- 狀態：完成，且已發過**五個**版本，最新是 `0.1.4 (5)`。
- 實作 commit：`7db9aadbfb2dc830cd3a7ac3eadb09b3d6b175a6`；workflow 產生的 source commit：`7d18cf4a4f4e52cca4a013aa697b24758eb00d68`；release tag：`ios-v0.1-b1`。
- 已驗證：本機 shell／Python／JSON／workflow YAML；SideStore 官方 schema；Xcode 27.0 fresh device Release build。GitHub `macos-26` run `35696142695` 的 build、IPA/schema、Release、公開 URL byte comparison 與 source publish 全部通過。
- 發布結果：`WebHTV-0.1-1.ipa`，24,563,162 bytes，GitHub asset SHA-256 `fcbf1531d9480f678ee0fac7ec5ce49010f3de51fc11b79f0ba88372e85812ed`；IPA plist 為 `com.webhtv.ios.poc`、`0.1`、build `1`、minimum iOS `17.0`。
- Source URL：`https://raw.githubusercontent.com/st7833232/webhtv/ios-poc/source.json`。
- 下一步：無；使用者可在 SideStore 加入 Source URL。

## 第二次發布（2026-09-22，`0.1.1 (2)`）

**目前最新版是 `0.1.1 (2)`，不是 `0.1 (1)`。** 上面的 Recovery anchor 記的是首發，保留不動。

- 觸發方式：`workflow_dispatch`，輸入 `version=0.1.1`、`build_number=2` 與中文 release notes。
  使用者明確授權了這一次 push 與這一次觸發。
- 專案檔一併改成 `MARKETING_VERSION = 0.1.1`、`CURRENT_PROJECT_VERSION = 2`（commit `0d18b25c`），
  否則 workflow 的「輸入留空就讀專案值」會指向一個已經發布過的版號。
- run `35698143404` 在 `macos-26` 上 **success，2 分 57 秒，11 個步驟全綠**。
- 產物：`WebHTV-0.1.1-2.ipa`，**24,563,735 bytes**，tag `ios-v0.1.1-b2`。
- workflow 自行把 `source.json` 推回 `ios-poc`（commit `20c4bd53`），`versions` 現在有兩筆，
  最新的在第一筆。
- **下載回來逐項驗過**，不是只看 CI 綠燈：`Info.plist` 為 `0.1.1` / build `2` /
  `com.webhtv.ios.poc`；`JianPian.js` 與 `js-spider.js` 與 HEAD **逐位元組相同**。
- 使用者以 SideStore 安裝此版並確認荐片冷啟動即有篩選列。
- **自 2026-09-22 起，不要直接把 App 裝到使用者手機**；需要上機時產 IPA 或在授權後觸發此 workflow。

## 後續版本（2026-09-22）

每一版都是 `workflow_dispatch`，帶明確的 version／build／中文 release notes，並在觸發前把
`project.pbxproj` 的 `MARKETING_VERSION`／`CURRENT_PROJECT_VERSION` 一併改掉——
否則 workflow 的「輸入留空就讀專案值」會指向一個已經發布過的版號。

| 版本 | tag | build 自 | 內容 | 大小 |
|---|---|---|---|---:|
| `0.1.2 (3)` | `ios-v0.1.2-b3` | `98d4ecfb` | 5S-1 廣告封鎖、IOS-POC-14 自動接下一集 | 24,576,193 |
| `0.1.3 (4)` | `ios-v0.1.3-b4` | `0ab59ecf` | 換集沿用播放速度（當時是跨影片沿用） | 24,576,894 |
| `0.1.4 (5)` | `ios-v0.1.4-b5` | `81eef32f` | 播放速度收窄成只在同一部片內沿用 | 24,577,093 |

每一版都**下載回來驗過** `Info.plist` 的版本與 build 號；`0.1.2` 另外確認了
`AdBlockList` 型別與 `ContentRuleList` 參照確實在二進位裡。

**使用者已確認**：`0.1.2 (3)` 的自動接下一集在真機上可用。
**尚未確認**：廣告封鎖在 App 裡真的擋到東西、播放速度是否跟著換集。
