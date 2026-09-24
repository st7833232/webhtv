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

- 狀態：完成，且已發過**十五個**版本，最新是 `0.1.14 (15)`（見文末各次發布）。
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

## 第七次發布（2026-09-23，`0.1.6 (7)`）

**目前最新版是 `0.1.6 (7)`。** 前面六版都已被取代。

- 內容：IOS-POC-16 自建播放控制列（AVKit 的 transport bar 在 iOS 無法擴充，也無法得知它何時顯示，
  兩者都是 tvOS 專用 API），片頭／片尾移進控制列因此跟著它一起出現與隱藏；速度選單改為
  `0.5 / 1 / 1.25 / 1.5 / 2 / 2.5 / 3` 並修掉標籤的多餘小數；修掉切換速度會誤報片頭片尾。
- 專案檔先改成 `MARKETING_VERSION = 0.1.6`、`CURRENT_PROJECT_VERSION = 7`（commit `6abc56e5`），
  否則 workflow 的「輸入留空就讀專案值」會指向已發布過的版號。
- 觸發：`workflow_dispatch`，`version=0.1.6`、`build_number=7`、中文 release notes。
  使用者明確授權了這一次 push 與這一次發布。
- run `35816498572` 在 `macos-26` **success，11 個步驟全綠**。
- 產物：`WebHTV-0.1.6-7.ipa`，**24,650,445 bytes**，tag `ios-v0.1.6-b7`，
  SHA-256 `24aaa21245512a92330e60dd269de3740bc9db8f93509c7d95402833efb571bf`。
- workflow 自行把 `source.json` 推回 `ios-poc`，`versions` 現在有 **7** 筆，最新的在第一筆。
- **下載回來逐項驗過**：`Payload/` 只有一個 `WebHTVApp.app`；`Info.plist` 為
  `com.webhtv.ios.poc` / `0.1.6` / build `7` / minimum iOS `17.0`；下載位元組數與 Release asset 一致。
- **這一版的 UI 功能測試由使用者進行**，清單見 `docs/IOS-POC-16-custom-player-controls.md` 第十節。
  控制列的渲染已在模擬器目視確認，但個別控制（含關閉鈕）沒有被驅動過。

## 第八次發布（2026-09-23，`0.1.7 (8)`）

**目前最新版是 `0.1.7 (8)`。** 前面七版都已被取代。

- 內容：**IOS-POC-15 播放緩衝與下一集預解析**——VOD forward buffer 60／90／120 秒的
  hysteresis 狀態機（live 與長度未知維持系統管理）、只對真正多 variant 的 HLS 做 1080p／720p
  畫質上限、`preferredPeakBitRate` 全程 0、下一集在本集最後 90 秒內預解析一個 `PlaybackTarget`
  （含 headers），以及四類 diagnostics。
  順帶修掉**2.5 倍／3 倍速沒有聲音**（`audioTimePitchAlgorithm` 改 `.timeDomain`）
  與 **seek 後進度條已緩衝範圍顯示錯誤**（`loadedTimeRanges.first` 兩處）。
- 專案檔先改成 `MARKETING_VERSION = 0.1.7`、`CURRENT_PROJECT_VERSION = 8`（commit `add58007`），
  否則 workflow 的「輸入留空就讀專案值」會指向已發布過的版號。
  **這一版在觸發前先在本機跑了 unsigned `iphoneos` Release build**，
  `BUILD SUCCEEDED` 且產物 `Info.plist` 讀到 `0.1.7` / build `8`——
  讓編譯錯誤在本機出現，而不是變成一次失敗的公開發布。
- 觸發：`workflow_dispatch`，`version=0.1.7`、`build_number=8`、中文 release notes。
  使用者以「發一版讓我裝來測」明確授權這一次發布。
- run `35827470170` 在 `macos-26` **success，3 分 35 秒，11 個步驟全綠**。
- 產物：`WebHTV-0.1.7-8.ipa`，**24,689,841 bytes**，tag `ios-v0.1.7-b8`，
  SHA-256 `338a49435f4fa55e3a3d7af2bf0e4842547b55f0cabb898f04f87ea600a1d4ae`。
- workflow 自行把 `source.json` 推回 `ios-poc`（commit `04161f85`），`versions` 現在有 **8 筆**，
  最新的在第一筆，`size` 與下載回來的 IPA 位元組數相符。
- **下載回來逐項驗過**，不是只看 CI 綠燈：`Payload/` 只有一個 `.app`；
  `Info.plist` 為 `com.webhtv.ios.poc` / `0.1.7` / build `8` / minimum iOS `17.0`；
  二進位裡找得到 `PlaybackNetworkMonitor`、`PlaybackBufferPolicy`、`PlaybackTargetPrefetch`、
  `PlaybackPrefetchGate`、`NextPlaybackTarget` 五個型別，以及
  `setAudioTimePitchAlgorithm:`、`setPreferredForwardBufferDuration:`、
  `setPreferredMaximumResolution:`、`setPreferredPeakBitRate:` 四個 selector——
  **本版真的帶著這些改動，不是只有版號動了**。
- **一個 rebase**：觸發前遠端多了 `40b293de docs(ios): defer IOS-POC-15 device performance pass`
  （倉庫擁有者自己推的 docs-only commit，記錄「真機驗收延後、不阻塞 5S-3」）。
  版號 commit rebase 到它之上，沒有衝突。

**尚未確認**：本版的效能改善全部沒有真機數字。驗收項目見
`docs/IOS-POC-15-playback-buffering-preload.md` 第八節。

## 第九次發布：`0.1.8 (9)`（2026-09-23，**已發布**）

**發布當時最新版是 `0.1.8 (9)`**（已被 `0.1.9 (10)` 取代，見第十次發布）。前面八版都已被取代。

**已發布（2026-09-23）**：使用者以「修改完成直接PUSH 發佈」授權。版號 commit `0a57d545`，
push `2a46c3fb..0a57d545`，`workflow_dispatch` run `35846736589`（`macos-26`，**success，3 分 29 秒**），
tag `ios-v0.1.8-b9`（workflow 建立，target `0a57d545`），workflow 推回 `source.json`（`30af13f5`）。
產物 `WebHTV-0.1.8-9.ipa` **24,754,269 bytes**，SHA-256
`e6aff90423e6b6af20f98e95e6c0e8935af259f95c3c121b0127b70124526757`。**下載回來驗過**：`Payload/` 只有
`WebHTVApp.app`；`Info.plist` 為 `com.webhtv.ios.poc` / `0.1.8` / build `9` / minimum iOS `17.0`；
`source.json` 第一筆為 `0.1.8`、size 與 IPA 相同；二進位含 `PlayerRouter`、`AVPlayerEngine`、`MPVEngine`、
`MPVPlayerCore`、`PlaybackQualityChoice`。發布前本機 unsigned `iphoneos` Release 預建置 **BUILD SUCCEEDED**。
內容：5S-3、IOS-POC-17（外部播放器移除、雙核心、**MPV 開放**、畫質選單進控制列、點集數直接播放、失敗顯示原因）
以及 `0.1.7 (8)` 已有的全部。**真機驗收尚未回報。**

以下是發布前的規劃紀錄，保留：

- 目的：**核心真機驗收用的候選版**。`0.1.7 (8)` 建自 `add58007`，**不含 5S-3**（`63040bb3`
  不是它的祖先），所以無法在手機上驗 config `rules` → sniffer。
- 內容：最新 `ios-poc` HEAD——5S-3、5S-1、5S-2、IOS-POC-15、2.5×／3× 音訊修正、
  PiP foreground restore、IOS-POC-16，**以及 2026-09-23 的 IOS-POC-17**（外部播放器移除、雙核心與
  「預設播放器」、點集數直接播放；Release 版 MPV 顯示「尚未開放」）。IOS-POC-17 之後**尚未重跑**
  iphoneos Release 預建置，發布前要先做。
- **本機預檢**：unsigned `iphoneos` Release build，旗標與 workflow 相同、以命令列覆寫
  `MARKETING_VERSION=0.1.8 CURRENT_PROJECT_VERSION=9`，`BUILD SUCCEEDED`；產物 `Info.plist`
  為 `com.webhtv.ios.poc` / `0.1.8` / build `9` / minimum iOS `17.0`。**專案檔未改。**
- **本輪沒有**：版號 commit、push、tag、`workflow_dispatch`、GitHub Release、`source.json` 更新。
  注意 `ios-v*-b*` tag 一推上去就會觸發本 workflow，所以不要手動建 tag。
- 發布序列（需使用者另外明確授權）與中文 release notes 草稿：
  `docs/IOS-POC-8L-core-real-device-acceptance.md` 第三節。

## 第十次發布：`0.1.9 (10)`（2026-09-23，**已發布**）

**發布當時最新版是 `0.1.9 (10)`**（已被 `0.1.10 (11)` 取代，見第十一次發布）。前面九版都已被取代。

- 內容：`0.1.8 (9)` 的全部，加上 IOS-POC-18 來源識別修正（commit `8df71c12`，Task-Guard
  `IOS-POC-18-source-identity`，版號 `0.1.9`／`10` 在同一個 commit）：靈虎等 object-ext 來源重開 App 後
  不再跳回第一個站台；因來源 ID 漂移而變灰的觀看記錄升級後自動遷移；來源識別改為穩定 canonical identity，
  Spider ext 行為不變。
- 發布：tag `ios-v0.1.9-b10` → `8df71c12`，`workflow_dispatch` run `35874971373`（success，
  2026-09-23 14:32:50Z → 14:38:04Z），workflow 推回 `source.json`（`dde455ba`）。
- 產物：`WebHTV-0.1.9-10.ipa` **24,767,406 bytes**，GitHub asset SHA-256
  `46385529d25368dd14b77a25f646d2a3e0322845006190be0428672722b4df3d`；`source.json` 共十筆，第一筆 `0.1.9`、
  size 與 IPA 相同（2026-09-24 以 `gh release view` 與 `source.json` 重新核對）。
- 驗證：commit 記錄 `swift test --package-path ios` PASS；2026-09-24 在 `dde455ba` 實測 **326／325**
  （唯一失敗是天氣測試 `reportsLiveType4SitesFromProvidedConfig`）。**真機驗收尚未回報。**
- 之後的 IOS-POC-16B、15D、17F **不在這一版裡**，已於 `0.1.10 (11)` 發布。

## 第十一次發布：`0.1.10 (11)`（2026-09-24，**已發布**）

**發布當時最新版是 `0.1.10 (11)`**（已被 `0.1.11 (12)` 取代，見第十二次發布）。前面十版都已被取代。

- 授權：使用者 2026-09-24「push 上 git，然後發布新版本」。版號沿用 `0.1.x` 遞增（`0.1.10`，build `11`）。
- 內容：`0.1.9 (10)` 的全部，加上 IOS-POC-16B `a5f2678e`（控制列二級選單改自有 panel）、IOS-POC-15D `6416c4d4`
  （緩衝／預解析契約補缺口＋`os.Logger` 量測）、IOS-POC-17F `b37751d2`（播不出來就主動切換播放核心）。
- 發布序列：版號 commit `5dadcd04`（`project.pbxproj` 兩處 `MARKETING_VERSION = 0.1.10`、`CURRENT_PROJECT_VERSION = 11`）
  → push `dde455ba..5dadcd04` → `workflow_dispatch` run `35953397506`（`version=0.1.10`、`build_number=11`，
  success，2026-09-24 03:54:30Z → 03:57:56Z）→ workflow 建 tag `ios-v0.1.10-b11`（target `5dadcd04`）並推回
  `source.json`（`d7a6e35e`，共十一筆，第一筆 `0.1.10`、size 與 IPA 相同）。**沒有手動建 tag。**
- 產物：`WebHTV-0.1.10-11.ipa` **24,851,830 bytes**，SHA-256
  `01ff7bb60f230fbef8c77ed83fc8c32bd3c9e65316b0d3272e342367a9f205f0`（與 GitHub asset digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`Info.plist` 為 `com.webhtv.ios.poc` / `0.1.10` / build `11` /
  minimum iOS `17.0`；主執行檔含 `PlayerChrome`（16B）、`prefetched address failed`（15D）、`startupTimedOut`、
  `not started on`、`沒有網路連線`（17F）。
- 發布前驗證：`swift test` 344／344（17F 後）；Simulator Debug build。**本機沒有另跑 iphoneos Release 預建置**——
  workflow 的 Release device build 就是這一關，而且它成功了。**真機驗收尚未回報。**

### Release notes（實際送出的內容）

```text
WebHTV 0.1.10 (11)（未經真機驗收）

新增
- 播不出來時自動改用另一個播放器：遇到網路錯誤或無法辨識的錯誤，會換另一個播放器再試一次；目前的播放器 20 秒內仍未開始播放，也會自動切換。每一集最多切換一次，不會來回切；沒有網路連線時不切換。
- 播放控制列的速度、畫質、播放器、字幕、音軌、片頭、片尾選單改成自己的面板：面板開著時控制列不會自動隱藏，按鈕更好點；直向從下方展開、橫向從右側展開。

改進
- 緩衝：只有真的卡頓時才加大緩衝；自己選的畫質不會被自動降低。
- 下一集預先解析：換畫質時立即作廢舊的預解析；預先解析的網址失效時，會自動重新解析一次，不直接顯示錯誤；預解析只讀取極少量資料，不再可能整集下載。
- MPV 播放時不再沿用上一段原生播放器的網路狀態。
```

## 第十二次發布：`0.1.11 (12)`（2026-09-24，**已發布**）

**發布當時最新版是 `0.1.11 (12)`**（已被 `0.1.12 (13)` 取代，見第十三次發布）。前面十一版都已被取代。

- 授權：使用者 2026-09-24「push 並發布下一版到 SideStore」。版號沿用 `0.1.x` 遞增（`0.1.11`，build `12`）。
- 內容：`0.1.10 (11)` 的全部，加上 IOS-POC-17G `257553f2`（MPV 旋轉後以新尺寸重畫）與 IOS-POC-17H `8824c8ee`
  （MPV 子母畫面，`docs/IOS-POC-17H-mpv-picture-in-picture.md`）；兩者都是 tag 目標 commit 的祖先（`git merge-base --is-ancestor` 驗過）。
- 發布序列：版號 commit `aa30bc0f`（Task-Guard `IOS-RELEASE-0.1.11-b12`，`project.pbxproj` 兩處 `MARKETING_VERSION = 0.1.11`、
  `CURRENT_PROJECT_VERSION = 12`）→ push `96ece1d1..aa30bc0f` → `workflow_dispatch` run `35968750165`（`version=0.1.11`、
  `build_number=12`，success，2026-09-24 07:16:39Z → 07:20:20Z）→ workflow 建 tag `ios-v0.1.11-b12`（target `aa30bc0f`）並推回
  `source.json`（`d681a72d`，共十二筆，第一筆 `0.1.11`、size 與 IPA 相同）。**沒有手動建 tag。**
- 產物：`WebHTV-0.1.11-12.ipa` **24,877,389 bytes**，SHA-256
  `bbdbf06c2097ff65f72928b20a34d9e8590b7b57e0521651de0a5b94c41548ae`（與 GitHub asset digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`Info.plist` 為 `com.webhtv.ios.poc` / `0.1.11` / build `12` /
  minimum iOS `17.0`；主執行檔含 `MPVPictureInPicture`、`MPVSoftwareRenderer`、`mpv will start`、`sw-fast`（17H）。
- 發布前驗證：17H 的 final Simulator Debug build（17H 文件第六節之三）；Core 自 17F 後沒有變動，`swift test` 沿用 344／344，
  本次沒有重跑；workflow 的 Release device build 成功。**真機驗收尚未回報；17H 的 PiP 畫面、自動 PiP、PiP 控制只能在真機驗。**

### Release notes（實際送出的內容）

```text
WebHTV 0.1.11 (12)（未經真機驗收）

新增
- MPV 播放器支援子母畫面：用 MPV 播放影片時回到主畫面，會自動進入子母畫面，和原生播放器一樣；回到 App 就結束子母畫面、從原位置繼續播放。純音訊、載入失敗或播完時不會自動開啟。進入與離開子母畫面時會短暫停頓一下。

修正
- MPV 直向、橫向旋轉後畫面跑版：旋轉後會以新的尺寸重新繪製。
```

## 第十三次發布：`0.1.12 (13)`（2026-09-24，**已發布**）

**發布當時最新版是 `0.1.12 (13)`**（已被 `0.1.13 (14)` 取代，見第十四次發布）。前面十二版都已被取代。

- 授權：使用者 2026-09-24「push 並發布下一版到 SideStore」（第二次）。版號 `0.1.12`，build `13`。
- 內容：`0.1.11 (12)` 的全部，加上 IOS-POC-17H 解析度修正 `5613517a`（使用者真機回報「MPV PIP時解析度會降低」：PiP render size
  其實是點，換成像素；擋掉視窗尺寸來回跳的迴圈；`docs/IOS-POC-17H-mpv-picture-in-picture.md` 第六節之六），以及只有文件的
  IOS-POC-19／20 計畫 `9b48e600`。
- 發布序列：版號 commit `4548bf7b`（Task-Guard `IOS-RELEASE-0.1.12-b13`）→ push `75fc13a5..4548bf7b` → `workflow_dispatch` run
  `35971952291`（`version=0.1.12`、`build_number=13`，success，2026-09-24 07:51:58Z → 07:55:56Z）→ workflow 建 tag `ios-v0.1.12-b13`
  （target `4548bf7b`）並推回 `source.json`（`57b32ef2`，共十三筆，第一筆 `0.1.12`、size 與 IPA 相同）。**沒有手動建 tag。**
- 產物：`WebHTV-0.1.12-13.ipa` **24,877,616 bytes**，SHA-256
  `a7170a0b3bb864aa46744845867d7f7284e8eb86343d9cf404260ea71ecb5f2f`（與 GitHub asset digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.12` / build `13` / minimum iOS `17.0`；
  `5613517a` 是 tag 目標 commit 的祖先。
- 發布前驗證：解析度修正的模擬器驗證與 final Simulator Debug build（17H 第六節之六）；workflow 的 Release device build 成功。
  **真機尚未回報修正後的 PiP 清晰度。**

### Release notes（實際送出的內容）

```text
WebHTV 0.1.12 (13)（未經真機驗收）

修正
- MPV 子母畫面變模糊：子母畫面現在以視窗實際的解析度繪製。
- MPV 子母畫面視窗的尺寸不再持續微幅跳動（原本會一直重建畫面緩衝、浪費效能）。
```

## 第十四次發布：`0.1.13 (14)`（2026-09-24，**已發布**）

**發布當時最新版是 `0.1.13 (14)`**（已被 `0.1.14 (15)` 取代，見第十五次發布）。前面十三版都已被取代。

- 授權：使用者 2026-09-24「push 並發布下一版到 SideStore」（第三次）。版號 `0.1.13`，build `14`。
- 內容：`0.1.12 (13)` 的全部，加上 IOS-POC-19 `4d703da3`（每個資訊源記住自己的站台）與 IOS-POC-21 `6c348650`
  （換集從頭播、同一集續播）；兩者都是 tag 目標 commit 的祖先。
- 發布序列：版號 commit `8db58a0d`（Task-Guard `IOS-RELEASE-0.1.13-b14`）→ push `7f4f0a44..8db58a0d` → `workflow_dispatch` run
  `35976794989`（`version=0.1.13`、`build_number=14`，success，2026-09-24 08:42:14Z → 08:46:15Z）→ workflow 建 tag `ios-v0.1.13-b14`
  （target `8db58a0d`）並推回 `source.json`（`1635289c`，共十四筆，第一筆 `0.1.13`、size 與 IPA 相同）。**沒有手動建 tag。**
- 產物：`WebHTV-0.1.13-14.ipa` **24,880,231 bytes**，SHA-256
  `41ab26d0a9ef4b2c659e1fc0950eb63c71fb42e0a931e4dca7fbdfc84a553b08`（與 GitHub asset digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.13` / build `14` / minimum iOS `17.0`。
- 發布前驗證：`swift test` 351／351（21 之後）；IOS-POC-19／21 的模擬器情境與 Simulator Debug build；workflow 的 Release device build 成功。
  **真機尚未回報。**

### Release notes（實際送出的內容）

```text
WebHTV 0.1.13 (14)（未經真機驗收）

新增
- 每個資訊源記住自己的站台：在某個資訊源選過的站台，切回那個資訊源時會自動回到它；重開 App 後也一樣。刪除已存的資訊源時，它記住的站台一併清除。

修正
- 播放中切換到別的集數，不再跳到上一集看到的位置：換集從頭開始（有設片頭仍會略過片頭）；同一集回來、或同一集換線路，仍會接著上次的位置播放。其他劇的記錄不受影響。
```

## 第十五次發布：`0.1.14 (15)`（2026-09-24，**已發布**）

**目前最新版是 `0.1.14 (15)`。** 前面十四版都已被取代。

- 授權：使用者 2026-09-24「先幫我push跟發佈」。版號 `0.1.14`，build `15`。
- 內容：`0.1.13 (14)` 的全部，加上 IOS-POC-22 `53557061`（原生播放器在不能快轉的片源上選 2.5×／3× 時交給 MPV）與其診斷文件 `47cf0d82`。
- 發布序列：版號 commit `618d6365`（Task-Guard `IOS-RELEASE-0.1.14-b15`）→ push `82d96ed4..618d6365` → `workflow_dispatch` run
  `35982550285`（`version=0.1.14`、`build_number=15`，success，2026-09-24 09:39:23Z → 09:42:45Z）→ workflow 建 tag `ios-v0.1.14-b15`
  （target `618d6365`）並推回 `source.json`（`13ef19d4`，共十五筆，第一筆 `0.1.14`、size 與 IPA 相同）。**沒有手動建 tag。**
- 產物：`WebHTV-0.1.14-15.ipa` **24,881,108 bytes**，SHA-256
  `13ae6d001296b245a4ecde9fdca8f0bfb29edcab1a87f6aa39692873626af584`（與 GitHub asset digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.14` / build `15` / minimum iOS `17.0`；主執行檔含 22 的 log 字串。
- 發布前驗證：`swift test` 354／354；IOS-POC-22 的模擬器情境與 Simulator Debug build；workflow 的 Release device build 成功。**真機尚未回報。**

### Release notes（實際送出的內容）

```text
WebHTV 0.1.14 (15)（未經真機驗收）

修正
- 原生播放器選 2.5×／3× 時音訊與畫面異常：原生播放器在不支援超過 2 倍速的片源上，會自動改用 MPV 在同一位置、同一集數、線路與畫質，以選定的 2.5×／3× 繼續播放（暫停中切換則維持暫停）。0.5×～2× 與支援高倍速的片源不受影響，速度選單不變。
```
