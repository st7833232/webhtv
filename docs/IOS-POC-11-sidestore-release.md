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

- 狀態：本地實作與驗證完成，待提交及 GitHub workflow。
- 已驗證：shell／Python／JSON／workflow YAML 靜態檢查；SideStore 官方 schema；Xcode 27.0 無 Apple secrets 的 fresh device Release build；IPA `Payload/WebHTVApp.app/Info.plist` 為 `com.webhtv.ios.poc`、`0.1`、build `1`；IPA 為 25,122,382 bytes，SHA-256 `a1b7acce84755994742f33547eac7bde617db737a49015e59bd65fe6abddad90`。
- 尚待：提交、push、實際 `macos-26` workflow、Release 與公開 URL 驗證。
- 下一步：以 task guard 建立原子 commit 並 push `ios-poc`。
