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

- 狀態：完成，且已發過**二十九個**版本，最新是 `0.1.28 (29)`（見文末各次發布；`0.1.5 (6)` 沒有獨立段落，記在 `docs/current-task-state.md`）。
- 實作 commit：`7db9aadbfb2dc830cd3a7ac3eadb09b3d6b175a6`；workflow 產生的 source commit：`7d18cf4a4f4e52cca4a013aa697b24758eb00d68`；release tag：`ios-v0.1-b1`。
- 已驗證：本機 shell／Python／JSON／workflow YAML；SideStore 官方 schema；Xcode 27.0 fresh device Release build。GitHub `macos-26` run `35696142695` 的 build、IPA/schema、Release、公開 URL byte comparison 與 source publish 全部通過。
- 發布結果：`WebHTV-0.1-1.ipa`，24,563,162 bytes，GitHub asset SHA-256 `fcbf1531d9480f678ee0fac7ec5ce49010f3de51fc11b79f0ba88372e85812ed`；IPA plist 為 `com.webhtv.ios.poc`、`0.1`、build `1`、minimum iOS `17.0`。
- Source URL：`https://raw.githubusercontent.com/st7833232/webhtv/ios-poc/source.json`。
- 下一步：無；使用者可在 SideStore 加入 Source URL。

## 第二次發布（2026-09-22，`0.1.1 (2)`）

**發布當時最新版是 `0.1.1 (2)`，不是 `0.1 (1)`**（已被 `0.1.2 (3)` 取代，見「後續版本」）。上面的 Recovery anchor 記的是首發，保留不動。

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

**發布當時最新版是 `0.1.6 (7)`**（已被 `0.1.7 (8)` 取代，見第八次發布）。前面六版都已被取代。

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

**發布當時最新版是 `0.1.7 (8)`**（已被 `0.1.8 (9)` 取代，見第九次發布）。前面七版都已被取代。

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
  workflow 的 Release device build 就是這一關，而且它成功了。**真機驗收尚未回報。**（2026-09-25 更正：使用者 2026-09-24 回報此版 SideStore 更新正常、MPV 有畫面，但 MPV 直橫旋轉跑版、沒有子母畫面，見 `docs/IOS-POC-8L-core-real-device-acceptance.md` ⑱⑲ 表格下方與 `docs/IOS-POC-17-dual-internal-player.md` 第十二之三節。）

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
  本次沒有重跑；workflow 的 Release device build 成功。**真機驗收尚未回報；17H 的 PiP 畫面、自動 PiP、PiP 控制只能在真機驗。**（2026-09-25 更正：使用者 2026-09-24 在此版回報「MPV PIP時解析度會降低」，表示真機 PiP 視窗有畫面，解析度修正隨 `0.1.12 (13)` 發布；自動 PiP、控制等其他項目仍未回報，見 `docs/IOS-POC-17H-mpv-picture-in-picture.md` 第六節之六。）

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

**發布當時最新版是 `0.1.14 (15)`**（已被 `0.1.15 (16)` 取代，見第十六次發布）。前面十四版都已被取代。

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

## 第十六次發布：`0.1.15 (16)`（2026-09-24，**已發布**）

**發布當時最新版是 `0.1.15 (16)`**（已被 `0.1.16 (17)` 取代，見第十七次發布）。前面十五版都已被取代。

- 補登：本節由 2026-09-25 接手的工作階段依 Git、GitHub Release 與 Actions 紀錄補寫。這次發布的 commit 都沒有 Task-Guard trailer 或驗證紀錄，授權原文也沒有留在文件裡。版號 `0.1.15`，build `16`。
- 內容：`0.1.14 (15)` 的全部，加上 MPV 播放時保持螢幕常亮 `34d9043b`、`951426b3`：`MPVEngine` 依使用者的播放意圖（載入時的 autoplay、play／pause）設定 App 層級的 `UIApplication.isIdleTimerDisabled`；緩衝中仍保持常亮；進背景、暫停、播放結束、失敗與 teardown 都會釋放。
- 發布序列：版號 commit `0678deda` → 暫時把 workflow 觸發改成 push `ios-poc` 並寫死 release notes（`ae80b963`），隨即還原（`787ceaa0`）→ 在 `main` 暫時加入 recovery workflow（`b191d72e`），run
  `36005131032`（success，2026-09-24 13:21:47Z → 13:25:34Z）建立 tag `ios-v0.1.15-b16`（target `0678deda`）、上傳 IPA，並推回 `source.json`（`882e6993`）→ `main` 移除 recovery workflow（`21f8c912`）。
- 產物：`WebHTV-0.1.15-16.ipa` **24,882,568 bytes**，SHA-256
  `b3340f6d3ac317b862e97f69d716004d4a9f278092196677696f7bbd39732781`（與 GitHub asset digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.15` / build `16` / minimum iOS `17.0`。
- 發布前驗證：**沒有紀錄**（沒有 `swift test`、模擬器情境或 Simulator build 的證據）；只有 workflow 的 Release device build 成功。**真機尚未回報。**

### Release notes（實際送出的內容）

```text
WebHTV 0.1.15 (16)

修正
- MPV 長時間播放時螢幕不再因系統自動鎖定計時而變暗或鎖定；暫停、播放結束、失敗或離開 MPV 播放時會恢復正常自動鎖定。
```

## 第十七次發布：`0.1.16 (17)`（2026-09-24，**已發布**）

**發布當時最新版是 `0.1.16 (17)`**（已被 `0.1.17 (18)` 取代，見第十八次發布）。前面十六版都已被取代。

- 補登：同第十六次發布，本節依 Git、GitHub Release 與 Actions 紀錄補寫，授權原文沒有留在文件裡。版號 `0.1.16`，build `17`。
- 內容：`0.1.15 (16)` 的全部，加上 `637d3597`（AVPlayer 與 MPV 共用內嵌音軌／字幕選擇；音軌列顯示語言、codec 與聲道；MPV 以 `track-list`、`aid`／`sid` 切換；診斷 log）與編譯修正 `7acb5db1`。
  任務文件是 `docs/P10-IOS-EMBEDDED-TRACK-SELECTION.md`，範圍與 IOS-POC-17 第十四節的 MPV parity P3 重疊。
- 發布序列：版號 commit `1d94d340` → 觸發嘗試 `04cad376`、`ad2ca1ef`（runs `36020145528`、`36020215545`，皆失敗，本紀錄未追查原因）→ 還原觸發 `bef780bf`
  → `main` 暫時的 recovery workflow `399c5597`，run `36020545714` 在「Build unsigned device app」失敗 → 編譯修正 `7acb5db1`
  → `2d08423f` 的 push run `36020708081` 建置與打包成功，在「Create or update GitHub Release」失敗 → 還原觸發 `5a488f7a`
  → `main` 改指向修正後的 commit（`cb23e72c`），run `36021136999`（success，2026-09-24 15:34:04Z → 15:37:43Z）建立 tag `ios-v0.1.16-b17`（target `7acb5db1`）、上傳 IPA，
  並推回 `source.json`（`507c49b6`，共十七筆，第一筆 `0.1.16`、size 與 IPA 相同）→ `main` 移除 recovery workflow（`58562327`）。
- 產物：`WebHTV-0.1.16-17.ipa` **24,919,831 bytes**，SHA-256
  `5c20e0797b8299118758a1cc1024f00b9f47cb2eb329f917eb5bd354219d4e9b`（與 GitHub asset digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.16` / build `17` / minimum iOS `17.0`。
- 發布前驗證：**沒有紀錄**。第一次 device build 編譯失敗，修正後 workflow 的 Release device build 成功；`swift test`、模擬器與真機都沒有證據。
- 收尾狀態：`ios-sidestore-release.yml` 與 `0.1.14 (15)` 發布時的內容相同；`main` 上兩個暫時的 recovery workflow 都已移除。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.16 (17)

新增
- AVPlayer 與 MPV 共用內嵌音軌／字幕選擇介面。
- 音軌顯示語言／名稱、codec 與 Mono / Stereo / 5.1 / 7.1。
- MPV 讀取 track-list 並使用 aid / sid 切換音軌與字幕。
- 新增音訊 codec、channel count / layout、selected track diagnostics。

調整
- MPV trackSelection 正式開啟。
- 不強制 downmix，維持來源聲道配置交由播放器與 iOS audio route 處理。
```

## 第十八次發布：`0.1.17 (18)`（2026-09-25，**已發布**）

**發布當時最新版是 `0.1.17 (18)`**（已被 `0.1.18 (19)` 取代，見第十九次發布）。前面十七版都已被取代。

- 授權：使用者 2026-09-25 在選擇題中選「發布 0.1.17 (18)」。版號 `0.1.17`，build `18`。
- 內容：`0.1.16 (17)` 的全部，加上 IOS-POC-20 `ee597124`：
  - 底部「搜尋」分頁：同時搜尋目前資訊源的所有可搜尋站台，可載入更多。
  - 全站台與單站搜尋都先繁轉簡。
  - WebHome 的 `app.search` 改開全站台搜尋。
  - Python 呼叫移到各自的 serial queue。
  - 同一天的文件 commit：`5e67e1be`（補登 0.1.15／0.1.16）與 `d43b86df`（IOS-POC-20 設計研究）。
- 發布序列：
  1. 版號 commit `b3c19fd4`（Task-Guard `IOS-RELEASE-0.1.17-b18`）。
  2. push `ee597124..b3c19fd4`。
  3. `workflow_dispatch` run `36034238374`（`version=0.1.17`、`build_number=18`，success，2026-09-24 17:25:50Z → 17:29:43Z）。
  4. workflow 建立 tag `ios-v0.1.17-b18`（target `b3c19fd4`），並推回 `source.json`（`0dff1af1`，共十八筆，第一筆 `0.1.17`，size 與 IPA 相同）。

  **沒有手動建 tag**，也沒有動 workflow 或 `main`。
- 產物：`WebHTV-0.1.17-18.ipa` **25,017,556 bytes**，SHA-256
  `e9e5b5ddce9e8e219ad7493ba5c148f5e0a8e43882f7247f5a82f33feb2ce3f5`（與 GitHub asset digest 相同）。
  **下載回來驗過**：
  - `Payload/` 只有 `WebHTVApp.app`。
  - `com.webhtv.ios.poc` / `0.1.17` / build `18` / minimum iOS `17.0`。
  - 主執行檔含 IOS-POC-20 的字串（`[search] ask`、`is still busy with an earlier search`、「搜尋所有站台」）。
- 發布前驗證：
  - 這是 IOS-POC-20 的**第一次編譯**：本工作階段在 Linux 容器，沒有 Swift 編譯器，由 workflow 的 Release device build 編譯並一次成功。
  - `swift test` 依使用者選擇未執行，沒有模擬器情境。
  - **真機尚未回報。**（2026-09-25 更正：使用者回報此版送出搜尋後閃退，見第十九次發布。）

### Release notes（實際送出的內容）

```text
WebHTV 0.1.17 (18)（未經真機驗收）

新增
- 底部新增「搜尋」分頁：同時搜尋目前資訊源所有可搜尋的站台，結果隨到隨顯示並標出站台；可依站台篩選並載入更多；較慢的站台 30 秒後標示逾時，不影響其他站台。

調整
- 首頁單站搜尋與全站台搜尋都會先把繁體關鍵字轉成簡體再送出。
- WebHome 的搜尋改為開啟全站台搜尋。
- Python 站台改在各自的佇列執行，不再佔用 App 共用的執行緒。
```

## 第十九次發布：`0.1.18 (19)`（2026-09-25，**已發布**）

**發布當時最新版是 `0.1.18 (19)`**（已被 `0.1.19 (20)` 取代，見第二十次發布）。前面十八版都已被取代。

- 授權：使用者 2026-09-25 在選擇題中選「發布 0.1.18 (19)」。版號 `0.1.18`，build `19`。
- 內容：`0.1.17 (18)` 的全部，加上 IOS-POC-20 的閃退修正 `0786a46e`：Release 版延後啟動 Python 時，多個 Python 站台同時建立會讓多條執行緒一起進入 `Py_Initialize`；現在 `PythonBoot.start()` 在鎖內只啟動一次。
  使用者回報的症狀是 `0.1.17 (18)`「輸入關鍵字、按鍵盤上的『搜尋』後」閃退。
- 發布序列：
  1. 版號 commit `ccfad785`（Task-Guard `IOS-RELEASE-0.1.18-b19`）。
  2. push `0786a46e..ccfad785`。
  3. `workflow_dispatch` run `36036441567`（`version=0.1.18`、`build_number=19`，success，2026-09-24 17:44:47Z → 17:48:59Z）。
  4. workflow 建立 tag `ios-v0.1.18-b19`（target `ccfad785`），並推回 `source.json`（`86eab8bb`，共十九筆，第一筆 `0.1.18`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.18-19.ipa` **25,017,725 bytes**，SHA-256
  `8b5e203ed9ff745b6a4cec6c7785977733243321e893cf270bff37ddb275583c`（與 GitHub asset digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.18` / build `19` / minimum iOS `17.0`。
- 發布前驗證：修正沒有在本機編譯（本環境沒有 Swift 工具鏈），由 workflow 的 Release device build 編譯成功；閃退原因是依程式碼與使用者設定檔推定，沒有 crash log。**真機：使用者 2026-09-25 回報「可以搜尋了，沒有閃退」。**

### Release notes（實際送出的內容）

```text
WebHTV 0.1.18 (19)（未經真機驗收）

修正
- 送出全站台搜尋後 App 閃退：多個 Python 站台同時啟動時，Python 直譯器現在只會啟動一次，其他站台會等它啟動完成。
```

## 第二十次發布：`0.1.19 (20)`（2026-09-25，**已發布**）

**發布當時最新版是 `0.1.19 (20)`**（已被 `0.1.20 (21)` 取代，見第二十一次發布）。前面十九版都已被取代。

- 授權：使用者 2026-09-25 在選擇題中選「發布 0.1.19 (20)（建議）」。版號 `0.1.19`，build `20`。
- 內容：`0.1.18 (19)` 的全部，加上 IOS-POC-17I-2（`9186a272`）：App 改用本地 `ios/Vendor/MPVKit` package，`Libmpv` 換成 WebHTV 自建的 `mpvkit-1.0.0-webhtv.1`，其 `moltenvk` context 會自己跟著 layer 尺寸 resize；17G 的 300 ms 等待、vo 重建與 exact seek 都已移除。細節見 `docs/IOS-POC-17I-mpv-resize-libmpv.md` 第十三、十四節。
- 發布序列：
  1. 版號 commit `777aff2d`（Task-Guard `IOS-RELEASE-0.1.19-b20`）。
  2. push `9186a272..777aff2d`。
  3. `workflow_dispatch` run `36089814077`（`version=0.1.19`、`build_number=20`，success，2026-09-25 03:18:18Z → 03:21:04Z）。
  4. workflow 建立 tag `ios-v0.1.19-b20`（target `777aff2d`），並推回 `source.json`（`883509b4`，共二十筆，第一筆 `0.1.19`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.19-20.ipa` **25,018,946 bytes**，SHA-256
  `b8ad1d1f3fc6adfc7b2f57c9f76672322c60b637218cebd22ada981dc56c0a02`（與 GitHub asset digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.19` / build `20` / minimum iOS `17.0`。
  執行檔含 `_moltenvk_wait_events`（只有 WebHTV 的 patch 有這個函式），內嵌的 mpv 建置時間是 `Sep 25 2026 02:21:46`（17I-1 的建置），確認連結的是 WebHTV 的 `Libmpv`。
- 發布前驗證：17I-2 沒有在本機編譯（本環境沒有 Swift 工具鏈），由本次 workflow 的 Release device build 第一次編譯即成功。**真機尚未驗收。**

### Release notes（實際送出的內容）

```text
WebHTV 0.1.19 (20)（未經真機驗收）

修正
- MPV 直向與橫向切換時畫面短暫跑版：改用 WebHTV 自建的 libmpv，旋轉時直接調整畫面尺寸，不再重建影片輸出或跳回目前位置；暫停中旋轉也會更新畫面。
```

## 第二十一次發布：`0.1.20 (21)`（2026-09-25，**已發布**）

**發布當時最新版是 `0.1.20 (21)`**（已被 `0.1.21 (22)` 取代，見第二十二次發布）。前面二十版都已被取代。

- 授權：使用者 2026-09-25 在選擇題中選「要，修正後發布 0.1.20 (21)（建議）」。版號 `0.1.20`，build `21`。
- 內容：`0.1.19 (20)` 的全部，加上 IOS-POC-23 第一階段（`440d671e`）與 MPV snapshot 修正（`51501cde`）：暫停中被系統暫停執行後，回到 App 時以同一核心在原位置以暫停狀態重新載入，恢復音軌與字幕，按播放前重新啟用音訊；MPV 暫停中重新載入或換畫質後不再誤判為播放中。細節見 `docs/IOS-POC-23-pause-background-resume-stall.md` 第十一節。
- 發布序列：
  1. 版號 commit `957dc518`（Task-Guard `IOS-RELEASE-0.1.20-b21`）。
  2. push `51501cde..957dc518`。
  3. `workflow_dispatch` run `36100831753`（`version=0.1.20`、`build_number=21`，success，2026-09-25 05:58:50Z → 06:02:56Z 前後；以 GitHub MCP 觸發）。
  4. workflow 建立 tag `ios-v0.1.20-b21`（target `957dc518`），並推回 `source.json`（`dfbd997a`，共二十一筆，第一筆 `0.1.20`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.20-21.ipa` **25,029,164 bytes**，SHA-256
  `b62548957d82b448fab17ad17bf5c40946379e3ff3baf1774a4f92ce1910ab70`（與 GitHub asset digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.20` / build `21` / minimum iOS `17.0`。
  執行檔含 IOS-POC-23 的 `[lifecycle]` 字串，也仍含 `_moltenvk_wait_events`（WebHTV 的 `Libmpv`）。
- 發布前驗證：IOS-POC-23 沒有在本機編譯（本環境沒有 Swift 工具鏈），由本次 workflow 的 Release device build 第一次編譯即成功；單元測試未執行。**真機尚未驗收。**（2026-09-25 更正：使用者以 SideStore 安裝此版，IOS-POC-23 的 T1～T15 全部通過，見 `docs/IOS-POC-23-pause-background-resume-stall.md` 第十二節。）

### Release notes（實際送出的內容）

```text
WebHTV 0.1.20 (21)（未經真機驗收）

修正
- 暫停後離開 App（回主畫面或鎖螢幕）再回來，畫面變黑、沒有聲音、按播放沒反應：App 被系統暫停執行過時，回來會在原位置以暫停狀態自動重新載入，並恢復原本選的音軌與字幕；按播放前重新啟用音訊。原生與 MPV 都適用；子母畫面中不會重新載入。
- MPV 暫停中換畫質（或上述重新載入）後，App 誤以為正在播放，播放鍵按了沒反應。
```

## 第二十二次發布：`0.1.21 (22)`（2026-09-25，**已發布**）

**發布當時最新版是 `0.1.21 (22)`**（已被 `0.1.22 (23)` 取代，見第二十三次發布）。前面二十一版都已被取代。

- 授權：使用者 2026-09-25 在選擇題中選「審查後發布 0.1.21 (22)（建議）」。版號 `0.1.21`，build `22`。
- 內容：`0.1.20 (21)` 的全部，加上 IOS-POC-24（`f2dc8e65` Libmpv 選項、`45357898` App 改用 `mpvkit-1.0.0-webhtv.2` 並擁有音訊工作階段、`c472798b` 審查修正）。細節見 `docs/IOS-POC-24-audio-session-ownership.md` 第十節。
- 發布序列：
  1. 版號 commit `255f4d8e`（Task-Guard `IOS-RELEASE-0.1.21-b22`）。
  2. push `c472798b..255f4d8e`。
  3. `workflow_dispatch` run `36121327712`（`version=0.1.21`、`build_number=22`，success，2026-09-25 09:57:34Z 建立，10:01:31Z 發布；以 GitHub MCP 觸發）。
  4. workflow 建立 tag `ios-v0.1.21-b22`（target `255f4d8e`），並推回 `source.json`（`4c15e7de`，共二十二筆，第一筆 `0.1.21`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.21-22.ipa` **25,030,951 bytes**，SHA-256
  `877db6d8c6114ae43f43061337f997388ad9c7342dfd783e52dac8dbf37c2c15`（與 GitHub asset digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.21` / build `22` / minimum iOS `17.0` / `UIBackgroundModes` `audio`。
  執行檔含 `audiounit-skip-session-management`、`avfoundation-skip-session-management`（App 設定的選項名稱）、`[audio] session not activated`，也仍含 `_moltenvk_wait_events`（WebHTV 的 `Libmpv`）。
- 發布前驗證：IOS-POC-24 的 Swift 改動沒有在本機編譯（本環境沒有 Swift 工具鏈），由本次 workflow 的 Release device build 第一次編譯即成功；Libmpv 由 run `36118969804` 建置並通過與上游的比對。單元測試未執行。**真機尚未驗收。**

### Release notes（實際送出的內容）

```text
WebHTV 0.1.21 (22)（未經真機驗收）

修正
- MPV 播放時會和其他 App 的音樂混在一起；用過 MPV 之後，原生播放也變成混音。現在兩個播放核心都和原生一樣：開始播放時，其他 App 的音樂會停止。
- 從 MPV 換到原生時，原生可能被停掉或沒有聲音。
- MPV 被來電、Siri 或其他 App 的聲音打斷後，畫面停住卻仍顯示播放中；現在會暫停，按播放即可繼續。

內部
- MPV 改用 WebHTV 自建的 Libmpv mpvkit-1.0.0-webhtv.2：mpv 不再改動 App 的音訊設定，由 App 統一管理。
```

## 第二十三次發布：`0.1.22 (23)`（2026-09-26，**已發布**）

**發布當時最新版是 `0.1.22 (23)`**（已被 `0.1.23 (24)` 取代，見第二十四次發布）。前面二十二版都已被取代。

- 授權：使用者 2026-09-25 要求 IOS-POC-26「開發完成發佈」；2026-09-26 在選擇題中選「現在發，連 IOS-POC-25 一起」。版號 `0.1.22`，build `23`。
- 內容：`0.1.21 (22)` 的全部，加上：
  - IOS-POC-26-1（`a6652cc3`）：MPV 與原生互切時，原生接手以零容差 seek 精確落在切換當下的時間。細節見 `docs/IOS-POC-26-engine-switch-position.md` 第四節。
  - IOS-POC-25（`7530acf9`、`3243e9e0`，另一個 session 開發）：HLS 點播影片中段廣告自動跳過（設定頁「智慧去廣」，預設開啟）。MPV 在有 `EXT-X-DISCONTINUITY` 的播放清單上不跳。細節見 `docs/IOS-POC-25-hls-midstream-ad-skip.md`。
  - 文件：IOS-POC-12 規劃（`4227fc82`）、IOS-POC-26-2 研究（`08378702`）。
- 發布序列：
  1. 版號 commit `450bd061`（Task-Guard `IOS-RELEASE-0.1.22-b23`）。
  2. push `08378702..450bd061`。
  3. `workflow_dispatch` run `36205981537`（`version=0.1.22`、`build_number=23`，success，2026-09-26 00:45:03Z 建立，00:47:36Z 發布；以 GitHub MCP 觸發）。
  4. workflow 建立 tag `ios-v0.1.22-b23`（target `450bd061`），並推回 `source.json`（`b69583b2`，共二十三筆，第一筆 `0.1.22`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.22-23.ipa` **25,107,276 bytes**，SHA-256
  `4065b6bdbcfc9f237029d6c9bd4cb6c3190ae41307e6d11a9119a0ac7e87fd3f`（與 GitHub asset digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.22` / build `23` / minimum iOS `17.0` / `UIBackgroundModes` `audio`。
  執行檔含 IOS-POC-26 的 `exact=` log 字串與 IOS-POC-25 的 `[adskip]`，也仍含 `_moltenvk_wait_events` 與 `audiounit-skip-session-management`（WebHTV 的 `Libmpv`）。
- 發布前驗證：IOS-POC-25 與 IOS-POC-26-1 的 Swift 改動沒有在本機編譯（本環境沒有 Swift 工具鏈），由本次 workflow 的 Release device build 第一次編譯即成功；單元測試未執行（IOS-POC-20 Q6）。**真機尚未驗收。**

### Release notes（實際送出的內容）

```text
WebHTV 0.1.22 (23)（未經真機驗收）

修正
- MPV 與原生互切時，換過去的播放器從切換當下的時間接著播：原生接手改為精確落點，不再退回前一個關鍵影格。

新增
- 智慧去廣（設定頁，預設開啟）：HLS 點播影片中段插播的廣告自動跳過，偵測規則與 Android 相同；手動拖進廣告時落在廣告結束；判斷不確定時一律不跳。

已知限制
- 含插播廣告的影片（播放清單有 EXT-X-DISCONTINUITY）：MPV 不會自動跳廣告，快轉或倒退可能回到片頭，請先改用原生播放器。修正（自建 FFmpeg 對齊時間軸）開發中。
- 含插播廣告的影片在兩個播放器之間切換，位置可能差一段廣告長度。
```

## 第二十四次發布：`0.1.23 (24)`（2026-09-26，**已發布**）

**發布當時最新版是 `0.1.23 (24)`**（已被 `0.1.24 (25)` 取代，見第二十五次發布）。前面二十三版都已被取代。

- 授權：使用者 2026-09-26 要求 26-2b 完成後「pull merge 在 push 發佈」，並選 A（H1 記錄為已知限制後出貨）。版號 `0.1.23`，build `24`。
- 內容：`0.1.22 (23)` 的全部，加上 IOS-POC-26-2b：
  - 26-2b-1：FFmpeg patch 0006 第三輪最終版（`c1bb4d19`）；FFmpeg lane run `36226970983` 建置並通過與上游的比對，發布 prerelease `ffmpeg-n8.1.2-webhtv.1`（`Libavformat.xcframework.zip` 3,133,759 bytes，SHA-256 `ba3e718df7a81fcdda220068b8df74b37a2bcdde3f5edb5ae759c967a614c8ff`）。
  - 26-2b-2：App 的 `Libavformat` 改用它（`e5f15c73`），README 記錄來源（`a3ca072c`）。
  - 細節見 `docs/IOS-POC-26-engine-switch-position.md` 第六節之五與第八節。
- 發布序列：
  1. 版號 commit `9ef8116d`（Task-Guard `IOS-RELEASE-0.1.23-b24`）。
  2. fetch 並 merge `origin/ios-poc`（已是最新），push `c1bb4d19..9ef8116d`。
  3. `workflow_dispatch` run `36227910147`（`version=0.1.23`、`build_number=24`，success，2026-09-26 07:48:40Z 建立，07:51:32Z 發布；以 GitHub MCP 觸發）。
  4. workflow 建立 tag `ios-v0.1.23-b24`（target `9ef8116d`），並推回 `source.json`（`7097b677`，共二十四筆，第一筆 `0.1.23`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.23-24.ipa` **25,114,842 bytes**，SHA-256
  `cfc4a7130bc01a74d1ae9003437ee0fa07495875895f2359fdaf042857f0e029`（與 GitHub asset digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.23` / build `24` / minimum iOS `17.0` / `UIBackgroundModes` `audio`。
  執行檔含 patch 0005 的 `HLS timestamp discontinuity in playlist`（`0.1.22 (23)` 沒有，證明連結的是 WebHTV 的 `Libavformat`），也仍含 IOS-POC-26-1 的 `exact=`、IOS-POC-25 的 `[adskip]`，以及 `_moltenvk_wait_events` 與 `audiounit-skip-session-management`（WebHTV 的 `Libmpv`）。
- 發布前驗證：`Libavformat` 由 FFmpeg lane 比對（`Libavutil` 與上游逐項相同；`Libavformat` 只多 `hls_timestamp.o` 與 6 個符號，另兩項具名的工具鏈例外）；patch 在 Linux 以 76 個合成素材、FATE 與單元測試驗證。App 改用新二進位後的編譯由本次 workflow 的 Release device build 第一次即成功；單元測試未執行（IOS-POC-20 Q6）。**真機尚未驗收**，驗收項目見 IOS-POC-26 文件 5.5 與第七節。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.23 (24)（未經真機驗收）

修正
- MPV 播放含插播廣告的影片（播放清單有 EXT-X-DISCONTINUITY）時，快轉、倒退或拖進度條會回到片頭，多操作幾次後 MPV 無法播放、要重啟 App。現在 iOS 改用自建的 FFmpeg Libavformat（與 Android 同源的時間軸對齊，並針對常見廣告配置調整）：廣告內與廣告後的時間接在影集的時間軸上，seek 落在指定位置。
- 含插播廣告的影片在 MPV 與原生之間切換，位置不再差一段廣告長度。
- 沒有插播標記的影片，MPV 的行為不變。

已知限制
- 含插播廣告的影片在 MPV 上連續播放、中間沒有 seek 時，顯示時間可能比播放清單時間多約 0.1～0.2 秒，經過多段廣告會累加，seek 後歸零；影音同步不受影響。
- 含插播廣告標記的影片，MPV 仍不會自動跳廣告（智慧去廣的限制不變）。
```

## 第二十五次發布：`0.1.24 (25)`（2026-09-26，**已發布**）

前面二十四版都已被取代，本版又被 `0.1.25 (26)` 取代。

- 授權：使用者 2026-09-26 看完 IOS-POC-25-2 的交付報告後回覆「發佈」。版號 `0.1.24`，build `25`。
- 內容：`0.1.23 (24)` 的全部，加上 IOS-POC-25-2（`45be83c4`）：
  - MPV 在有 `#EXT-X-DISCONTINUITY` 的播放清單上也自動跳廣告，位置讀到區間起點 0.25 秒後才觸發（避開 IOS-POC-26 的 H1 與 mpv demuxer cache 造成的位置超前）；手動 seek 進廣告落在終點前 0.1 秒。
  - App target 以 `-Wl,-u,_ff_hls_timestamp_map_segment` 綁定 WebHTV `Libavformat`。
  - 細節見 `docs/IOS-POC-25-hls-midstream-ad-skip.md` 第二十二節。
- 發布序列：
  1. 版號 commit `5da03a4a`（Task-Guard `IOS-RELEASE-0.1.24-b25`）。
  2. fetch 並 merge `origin/ios-poc`（已是最新），push `45be83c4..5da03a4a`。
  3. `workflow_dispatch` run `36230882448`（`version=0.1.24`、`build_number=25`，success，2026-09-26 08:48:22Z 建立，08:52:13Z 發布；以 GitHub MCP 觸發）。
  4. workflow 建立 tag `ios-v0.1.24-b25`（target `5da03a4a`），並推回 `source.json`（`d22fead2`，共二十五筆，第一筆 `0.1.24`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.24-25.ipa` **25,114,911 bytes**，SHA-256
  `f817206adea80a41aaf388957c51b80092fd66adf0e53b2ab5f2137bb62a7fd7`（與 GitHub asset digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.24` / build `25` / minimum iOS `17.0` / `UIBackgroundModes` `audio`。
  執行檔含 patch 0005 的 `HLS timestamp discontinuity in playlist`（WebHTV 的 `Libavformat`）、IOS-POC-25 的 `[adskip]`、IOS-POC-26-1 的 `exact=`，以及 `_moltenvk_wait_events` 與 `audiounit-skip-session-management`（WebHTV 的 `Libmpv`）。
- 發布前驗證：IOS-POC-25-2 在本環境沒有 Swift，只以 Python 逐行轉寫（24／24 個情境）、ld64.lld-18 代理連結與三角度審查驗證（IOS-POC-25 第二十二節之六）。本次 workflow 的 Release device build 第一次即成功，**這是 IOS-POC-25-2 與 `-u` 連結檢查第一次在 Xcode 上編譯與連結**；單元測試未執行，也不在這個 build 內（IOS-POC-20 Q6）。**真機尚未驗收**，驗收項目見 IOS-POC-25 文件第二十二節之七。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.24 (25)（未經真機驗收）

新增
- MPV 播放含插播廣告的影片（播放清單有 EXT-X-DISCONTINUITY）時，「智慧去廣」也會自動跳過廣告：播到廣告約 0.25 秒後跳到廣告結束前 0.1 秒；拖進度條到廣告中會落在廣告尾端。
- 原生播放器、沒有插播標記的影片，行為不變。

已知限制
- MPV 在這類影片上，每段廣告會先露出約 0.25～0.45 秒的開頭，以及最後 0.1 秒。
- 連續經過多段廣告後，MPV 的時間可能比播放清單多出 0.25 秒以上，這時廣告前最後一小段正片可能被跳掉；發現時請回報。
- 設定頁關閉「智慧去廣」即可停用。
```

## 第二十六次發布：`0.1.25 (26)`（2026-09-26，**已發布**）

前面二十五版都已被取代，本版又被 `0.1.26 (27)` 取代。

- 授權：使用者 2026-09-26 核准 IOS-POC-27 的 27A、27B 時一併選「授權發布」（bump 版本、建 tag、發布 SideStore release），並在發布前選「快轉 ios-poc 後發布」。版號 `0.1.25`，build `26`。
- 內容：`0.1.24 (25)` 的全部，加上：
  - IOS-POC-27A（`96b714df`、查核修正 `a21bad25`）：載入轉圈、播放／暫停鍵依意圖、開播檢查只計算想播的時間、原生開播逾時 5 秒（AirPlay／子母畫面 20 秒；MPV 20 秒）、原生開不了時顯示原因、卡住時切 MPV 或換畫質保留播放。
  - IOS-POC-27B（`80f949ff`、查核修正 `25b91739`）：原生預讀依倍速放大，上限 120 秒。
  - IOS-POC-28（`f5c7d889`）：影片卡的點擊範圍限於卡片本身。
  - 細節見 `docs/IOS-POC-27-avplayer-2x-buffer-stall-controls.md` 第十二節。
- 發布序列：
  1. 版號 commit `96d20a98`（Task-Guard `IOS-RELEASE-0.1.25-b26`），在工作分支 `claude/avplayer-cache-buffer-ddpwrd` 上。
  2. `ios-poc` 從 `50b43ef8` 快轉到 `96d20a98`（使用者核准；不改歷史）。
  3. `workflow_dispatch` run `36255311859`（ref `ios-poc`，版號與 build 取專案值，success，2026-09-26 16:23:59Z 建立，16:27:04Z 完成；以 GitHub MCP 觸發）。
  4. workflow 建立 tag `ios-v0.1.25-b26`（target `96d20a98`），並推回 `source.json`（`99410d5a`，共二十六筆，第一筆 `0.1.25`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.25-26.ipa` **25,129,553 bytes**，SHA-256
  `3ed1f4ab184ab98419d75d8f0705af311b50c909a7edcf2a0db3fcafcfc4ca65`。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.25` / build `26` / minimum iOS `17.0` / `UIBackgroundModes` `audio`。
  執行檔含 IOS-POC-27 的 `native start given up`、`[playback] waiting reason=`、`[playback] holding buffer=`、`[playback] speed ` 與「無法開始播放」。
- 發布前驗證：本環境沒有 Swift；27A、27B 各經一輪三角度對抗式查核（27A 確認 15 項、27B 確認 5 項，皆已修正）。本次 workflow 的 Release device build 第一次即成功，**這是 IOS-POC-27A、27B、28 第一次在 Xcode 上編譯**；單元測試未執行，也不在這個 build 內（IOS-POC-20 Q6），`PlaybackActivityTests` 與新增的 `PlaybackNetworkPolicyTests` 要等有 Mac 時跑。**真機尚未驗收**，驗收項目見 IOS-POC-27 文件第八節 T1～T12。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.25 (26)（未經真機驗收）

修正
- 原生播放器開不了的線路：原本黑畫面 20 秒才改用 MPV，現在 5 秒就改用 MPV，並在畫面上方顯示原因約 4 秒。AirPlay 或子母畫面中仍等 20 秒。
- 載入或卡住時顯示轉圈。
- 播放／暫停鍵依「想不想播」切換：卡住時可以按暫停；開播中按暫停，不會被自動改用 MPV 並播放。
- 卡住時從控制列切到 MPV 或換畫質，會繼續播放。
- 首頁與搜尋結果：點左邊影片卡的右半部，不再開到右邊的影片。

改善
- 原生播放器的預讀量依倍速放大：2 倍速時實際緩衝由約 30 秒增為約 60 秒（上限 120 秒影片時間）；1 倍不變。

已知限制
- 慢但能播的原生開播（超過 5 秒）也可能改用 MPV。
- 卡住時快轉／倒退仍要等資料到才完成。
- 原生切到 MPV 會先黑一陣子，尚未處理。
```

## 第二十七次發布：`0.1.26 (27)`（2026-09-26，**已發布**）

前面二十六版都已被取代，本版又被 `0.1.27 (28)` 取代。

- 授權：使用者 2026-09-26 核准 IOS-POC-29 時一併選「授權發布」（流程與 `0.1.25` 相同：快轉 `ios-poc`、bump 版本、建 tag、發布 SideStore release）。版號 `0.1.26`，build `27`。
- 內容：`0.1.25 (26)` 的全部，加上：
  - IOS-POC-29（`06c77537`、查核修正 `95e507fa`）：設定頁「預設播放速度」。
  - IOS-POC-30（`a52ab2dd`、查核修正 `1e8677b7`、`6f14069d`）：觀看記錄的清除與滑動刪除只影響目前來源；沒有來源的舊記錄只從目前來源隱藏；WebHome 的 `app.history` 只回目前來源。
- 發布序列：
  1. 版號 commit `c6502228`（Task-Guard `IOS-RELEASE-0.1.26-b27`），在工作分支 `claude/avplayer-cache-buffer-ddpwrd` 上。
  2. `ios-poc` 從 `e46a0543` 快轉到 `c6502228`（不改歷史）。
  3. `workflow_dispatch` run `36257981098`（ref `ios-poc`，success，2026-09-26 17:08:55Z 建立，17:11:49Z 完成；以 GitHub MCP 觸發）。
  4. workflow 建立 tag `ios-v0.1.26-b27`（target `c6502228`），並推回 `source.json`（`db76a8c3`，共二十七筆，第一筆 `0.1.26`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.26-27.ipa` **25,139,377 bytes**，SHA-256
  `5d2825d2afa79900971c046feda904a2a904aaf6c604a48d79e332faa6960191`。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.26` / build `27` / minimum iOS `17.0` / `UIBackgroundModes` `audio`。
  執行檔含 IOS-POC-29 的「預設播放速度」與 `webhtv.playback.defaultSpeed`，以及 IOS-POC-27 的 `native start given up`。
- 發布前驗證：本環境沒有 Swift；IOS-POC-29、30 各經對抗式查核（29 確認 6 項、30 共兩輪確認 3 項，皆已修正）。本次 Release device build 第一次即成功，**這是 IOS-POC-29、30 第一次在 Xcode 上編譯**；單元測試未執行（IOS-POC-20 Q6）。**真機尚未驗收**。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.26 (27)（未經真機驗收）

新增
- 設定頁「預設播放速度」（0.5～3×）：開新的影片時以此速度開始。同一部片換集沿用播放中調整的速度；播放中調整不會改變設定。

修正
- 觀看記錄的「清除」只刪除目前來源的記錄，不再刪到其他來源。
- 單筆滑動刪除同樣只影響目前來源。較早期、沒有標記來源的記錄在每個來源都會顯示，清除或滑動刪除時只從目前來源隱藏。

已知限制
- 2.5×、3× 在原生播放器不支援的影片上會改用 MPV。
- 直播或長度未知的影片也會以預設速度開始。
```

## 第二十八次發布：`0.1.27 (28)`（2026-09-27，**已發布**）

前面二十七版都已被取代，本版又被 `0.1.28 (29)` 取代。

- 授權：使用者 2026-09-27 看完 IOS-POC-31 的設計建議後選「授權發布」（流程與前兩版相同）。版號 `0.1.27`，build `28`。
- 內容：`0.1.26 (27)` 的全部，加上 IOS-POC-31（`97417be4`、查核修正 `616b3fc9`）：設定頁的預設播放器、預設播放速度改為下拉選單；內容來源收成一列，推入頁開在目前來源。
- 發布序列：
  1. 版號 commit `67d7fe78`（Task-Guard `IOS-RELEASE-0.1.27-b28`），在工作分支上。
  2. `ios-poc` 從 `ff83e4bc` 快轉到 `67d7fe78`（不改歷史）。
  3. `workflow_dispatch` run `36281807118`（ref `ios-poc`，success，2026-09-27 00:12:42Z 建立，00:16:55Z 完成；以 GitHub MCP 觸發）。
  4. workflow 建立 tag `ios-v0.1.27-b28`（target `67d7fe78`），並推回 `source.json`（`2a4ce060`，共二十八筆，第一筆 `0.1.27`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.27-28.ipa` **25,149,798 bytes**，SHA-256
  `096730d9ef34075e0e9175e334077c5c4440b58eb4bb37bfc090286b84550a2e`。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.27` / build `28` / minimum iOS `17.0` / `UIBackgroundModes` `audio`。
  執行檔含 IOS-POC-31 的 `SiteChoiceList` 型別（`0.1.26 (27)` 沒有）。「目前來源」這類 15 bytes 以內的字串是 Swift 的短字串，嵌在指令裡，無法以位元組搜尋驗證。
- 發布前驗證：本環境沒有 Swift；IOS-POC-31 經對抗式查核（確認 1 項次要、已修正）。本次 Release build 第一次即成功，這是 IOS-POC-31 第一次在 Xcode 上編譯；單元測試未執行。**真機尚未驗收**。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.27 (28)（未經真機驗收）

改善
- 設定頁變短：預設播放器、預設播放速度改成一列的下拉選單。
- 內容來源收成一列「目前來源」，點進去是會捲到目前來源的清單；選了照舊跳回首頁。

其他設定（智慧去廣、已存來源、設定來源）不變。
```

## 第二十九次發布：`0.1.28 (29)`（2026-09-27，**已發布**）

前面二十八版都已被取代，本版又被 `0.1.29 (30)` 取代。

- 授權：使用者 2026-09-27 對「階段 A 要不要發布」選「等 B 一起發布」，並選擇接著做階段 B；階段 B 完成並查核後依此發布。版號 `0.1.28`，build `29`。
- 內容：`0.1.27 (28)` 的全部，加上 IOS-POC-32 階段 A（`73c96c56`、`5d393196`、`e6771a5f`：詳情頁海報在標題上方、完整顯示）與階段 B（`07a18fd1`、查核修正 `96e9997b`：詳情頁顯示年份、地區、類型、導演、演員、簡介）。
- 發布序列：
  1. 版號 commit `f5fe582c`（Task-Guard `IOS-RELEASE-0.1.28-b29`），在工作分支上。
  2. `ios-poc` 從 `96e9997b` 快轉到 `f5fe582c`（不改歷史）。
  3. `workflow_dispatch` run `36291272405`（ref `ios-poc`，success，2026-09-27 03:23:39Z 建立，03:28:00Z 完成；以 GitHub MCP 觸發）。
  4. workflow 建立 tag `ios-v0.1.28-b29`（target `f5fe582c`），並推回 `source.json`（`d8d1302e`，共二十九筆，第一筆 `0.1.28`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.28-29.ipa` **25,180,758 bytes**，SHA-256
  `08d75500f663184439df385202b65695e77cbfbef1cbfd7883c790b9359c590c`。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.28` / build `29` / minimum iOS `17.0` / `UIBackgroundModes` `audio`。
  執行檔含階段 B 的 `VodText`、`metadataRows`、`decodeText` 與 `vod_blurb`、`vod_director`、`vod_class` 等欄位名稱。
- 發布前驗證：本環境沒有 Swift；階段 A 經三個角度對抗式查核（確認 1 項，只改註解），階段 B 經五個角度對抗式查核（確認 11 項次要或建議修正，已修正）；`VodText` 的預期值以 Python 移植版逐條執行 21／21 符合。本次 Release build 第一次即成功，這是階段 A、B 第一次在 Xcode 上編譯；單元測試未執行（使用者選擇只靠編譯與真機）。**真機尚未驗收**。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.28 (29)（未經真機驗收）

改善
- 詳情頁的海報移到標題上方，整張圖完整顯示，不再蓋到標題或超出畫面。
- 詳情頁顯示年份、地區、類型、導演、演員與簡介（來源有提供才顯示）；簡介預設 4 行，可按「更多」展開。

搜尋與播放不變。
```

## 第三十次發布：`0.1.29 (30)`（2026-09-28，**已發布**）

**發布當時最新版是 `0.1.29 (30)`**（已被 `0.1.30 (31)` 取代，見第三十一次發布）。前面二十九版都已被取代。

- 授權：使用者 2026-09-28 對「要不要把 IOS-POC-32 C 和 IOS-POC-33 一起發布成 `0.1.29 (30)`」回答「好」。版號 `0.1.29`，build `30`。
- 內容：`0.1.28 (29)` 的全部，加上 IOS-POC-32 階段 C（`1e9d24e3`：來源的簡體中文只在畫面上顯示為台灣繁體，OpenCC `s2tw` 衍生、統一用「台」）與 IOS-POC-33（`2e6c7309`、複審紀錄 `1a10287a`：輸入繁體時簡體與原文各搜一次，同一站合併後顯示；搜尋分頁、WebHome 搜尋、首頁站內搜尋）。
- 發布序列：
  1. 版號 commit `6ffd6e15`（Task-Guard `IOS-RELEASE-0.1.29-b30`），在工作分支上。
  2. `ios-poc` 從 `1a10287a` 快轉到 `6ffd6e15`（不改歷史）。
  3. `workflow_dispatch` run `36373454196`（ref `ios-poc`，success，2026-09-28 03:22:15Z 建立，03:25:43Z 完成；以 GitHub MCP 觸發）。
  4. workflow 建立 tag `ios-v0.1.29-b30`（target `6ffd6e15`），並推回 `source.json`（`b5f1c78e`，共三十筆，第一筆 `0.1.29`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.29-30.ipa` **25,685,782 bytes**（比 `0.1.28 (29)` 多 505,024 bytes，主要是 OpenCC 字典），SHA-256
  `ed5bd4f66893c5ac79064f7c0580a64612d14bd10624e6738343e7ef380f2343`（與 GitHub 記錄的 digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.29` / build `30` / minimum iOS `17.0` / `UIBackgroundModes` `audio`。
  `WebHTVCore_WebHTVCore.bundle/OpenCC/` 內 8 個檔案與 repo 逐位元組相同；執行檔含 `TaiwanTraditional`、`DualScriptSearch`、`TaiwanDisplay` 與 `[zhtw] dictionaries loaded`、`timed out after` 等 log 字串。
- 發布前驗證：本環境沒有 Swift。階段 C 的轉換以 Python 對照實作對 OpenCC 官方工具比對 134,127 行，0 差異；IOS-POC-33 經兩輪對抗式查核（第一輪確認 9 項次要問題並修正，第二輪 0 項）。本次 Release build 第一次即成功，這是階段 C 與 IOS-POC-33 第一次在 Xcode 上編譯；單元測試未執行（使用者選擇只靠編譯與真機）。**真機尚未驗收**。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.29 (30)（未經真機驗收）

改善
- 來源送來的簡體中文，畫面上改顯示成台灣繁體（統一用「台」）；日文不轉，演員、導演保留于、朴、范、姜、余、沈等姓氏。
- 搜尋輸入繁體時，會同時用簡體與輸入的原文各搜一次，同一站的結果合併後顯示；載入更多時兩種寫法各自翻頁。首頁站內搜尋與 WebHome 搜尋也一樣。

已知限制
- 用繁體搜尋時，spider 類站台的搜尋時間約為兩倍。

輸入簡體、英文或數字時，搜尋與之前相同；播放不變。
```

## 第三十一次發布：`0.1.30 (31)`（2026-09-29，**已發布**）

**發布當時最新版是 `0.1.30 (31)`**（已被 `0.1.31 (32)` 取代，見第三十二次發布）。前面三十版都已被取代。

- 授權：使用者 2026-09-29「push 並發布 0.1.30」。版號 `0.1.30`，build `31`。
- 內容：`0.1.29 (30)` 的全部，加上 IOS-POC-25-4（`43c197b2`：相接的廣告區間一次跳過）、IOS-POC-25-5（`4fd5ae0a`：MPV 在沒有 discontinuity 的清單上看到時間軸跳動就停止跳過；MPV 子母畫面快轉改走 `PlaybackSession.seek`）、IOS-POC-35（`1dfcc0db`：播放器上一集／下一集、詳情頁「立即播放」），以及文件與 `scripts/ios_adskip_sim`（`c4d13ea7`、`2f93753e`）。
- 發布序列（第一次在 Mac 上發布）：
  1. 版號 commit `6b5c6739`（Task-Guard `IOS-RELEASE-0.1.30-b31`）。
  2. push `5e089633..6b5c6739`。
  3. `gh workflow run ios-sidestore-release.yml --ref ios-poc -f release_notes=…` → run `36518735965`（success，2026-09-29 03:47:58Z → 03:50:57Z）。
  4. workflow 建立 tag `ios-v0.1.30-b31`（target `6b5c6739`），並推回 `source.json`（`94cc7aa2`，共三十一筆，第一筆 `0.1.30`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.30-31.ipa` **25,703,216 bytes**，SHA-256
  `463e1cf18f3068d44c135e895cf8fd00bbca2c71618b66d7770f938cb23eb801`（與 GitHub 記錄的 digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.30` / build `31` / minimum iOS `17.0` / `UIBackgroundModes` `audio`。
  執行檔含 `timeline-jump`、`live, previous episode`、`下一集無法播放`，也仍含 `_moltenvk_wait_events`（WebHTV 的 `Libmpv`）。
- 發布前驗證：**第一次在發布前於 Mac 上執行單元測試**：`swift test` 537 個全部通過；三項都以 Debug 模擬器 build 驗收（IOS-POC-25 第二十四、二十五節，IOS-POC-35 第五節）。Release device build 由本次 workflow 編譯，第一次即成功。**真機尚未驗收**。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.30 (31)（未經真機驗收）

新增
- 播放器控制列加上「上一集」「下一集」：換到同一條線路的相鄰一集，第一集、最後一集時按鈕變灰。換集前會先存好目前進度，新的一集從頭播（有設片頭就跳過）。
- 詳情頁線路上方加上「立即播放」：沒看過就播第一條線路第一集；看過就回到上次的線路與集數，從上次的進度接著播。

改善
- 智慧去廣：一個廣告被切成兩段時改為一次跳過，露出的廣告時間約減少一半。

修正
- 智慧去廣：MPV 在沒有 DISCONTINUITY 標記、廣告自帶時間戳的影片上可能跳掉一段正片；現在偵測到時間軸跳動，該集就停止自動跳過（廣告會照播）。
- MPV 子母畫面的快轉按鈕也套用智慧去廣的落點（快轉進廣告時落在廣告結束處）。
```

## 第三十二次發布：`0.1.31 (32)`（2026-09-29，**已發布**）

**發布當時最新版是 `0.1.31 (32)`**（已被 `0.1.32 (33)` 取代，見第三十三次發布）。前面三十一版都已被取代。

- 授權：使用者 2026-09-29 對「要 push 並發布成 `0.1.31 (32)`，讓你在真機上測子母畫面嗎？」回答「好」。版號 `0.1.31`，build `32`。
- 內容：`0.1.30 (31)` 的全部，加上 IOS-POC-17H-2（`631a7684`：MPV 子母畫面期間與回到 App 後、第一格新畫面前隱藏 Metal view，不再閃出舊畫格或變形）。
- 發布序列：
  1. 版號 commit `a826d6e2`（Task-Guard `IOS-RELEASE-0.1.31-b32`）。
  2. push `9e41b92c..a826d6e2`。
  3. `gh workflow run ios-sidestore-release.yml --ref ios-poc -f release_notes=…` → run `36528804774`（success，2026-09-29 05:59:37Z → 06:03:10Z）。
  4. workflow 建立 tag `ios-v0.1.31-b32`（target `a826d6e2`），並推回 `source.json`（`90807975`，共三十二筆，第一筆 `0.1.31`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.31-32.ipa` **25,704,617 bytes**，SHA-256
  `4c66b1b6c44ec17cdbb50f40905ada4296a8b19d1d2acbfe0b235b919a2078a3`（與 GitHub 記錄的 digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.31` / build `32` / minimum iOS `17.0` / `UIBackgroundModes` `audio`；執行檔仍含 `timeline-jump` 與 `_moltenvk_wait_events`。
- 發布前驗證：iPad mini 模擬器重現並驗證修正（17H 文件「真機回報的模擬器重現與修法」第六節）；Release device build 由本次 workflow 編譯，第一次即成功。**真機尚未驗收**；PiP 期間暫停的情況未驗證。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.31 (32)（未經真機驗收）

修正
- MPV 子母畫面結束、回到 App 時，畫面會先閃出進入子母畫面前的舊畫格（看起來像進度往回），而且可能被放大或拉伸變形。現在子母畫面期間 App 內改顯示子母畫面的提示（與原生播放器相同），回到 App 後等 MPV 畫出新畫面才顯示，中間停在子母畫面最後的畫面。

已知限制
- MPV 回到 App 時仍會為了對齊聲音重新定位一次，位置可能往回數十毫秒（藍牙耳機約 0.1～0.3 秒）。
```

## 第五十次發布：`0.1.49 (50)`（2026-10-02，**已發布**）

**目前最新版是 `0.1.49 (50)`。** 前面四十九版都已被取代。

- 授權：使用者 2026-10-02 指示「push 並發佈新版本」，release notes 修正為不帶站台內容後「允許發布，照這版 release notes 繼續」。版號 `0.1.49`，build `50`。
- 內容：`0.1.48 (49)` 的全部，加上：
  - IOS-POC-42A（`c33bfa60`）：XYQHiker 直接播放模式的影片有集數。
  - IOS-POC-42B（`f1cbfe89`）：直接播放頁先靜態擷取影片網址（略過片頭廣告、embed 一層、拆解析外層），再交給嗅探。
  - IOS-POC-42C（`05f58a20`）：XYQHiker 搜尋讀中文鍵，支援 JSON 搜尋。
  - 其餘是文件（`60932b30` assessment、`b785502e` 交接）與 `0.1.48 (49)` 的 `source.json`（`f1c11850`）。
- 發布序列：
  1. 版號 commit `f4231299`（Task-Guard `IOS-RELEASE-0.1.49-b50`，兩個 build configuration 的 `MARKETING_VERSION`／`CURRENT_PROJECT_VERSION`，沒有其他行變動）。第一次嘗試被 Claude Code auto mode 擋下，使用者允許後重做；另一次 guard 以不合法的 `--mode release` 啟動失敗，工作區還原後以 `standard` 重做，沒有留下錯誤的 commit。
  2. push `05f58a20..f4231299`（push 前先 pull merge，遠端沒有新 commit；`b785502e..05f58a20` 已在前一步 push）。
  3. `gh workflow run ios-sidestore-release.yml --ref ios-poc -f version=0.1.49 -f build_number=50 -f release_notes=…` → run `36973731602`（conclusion success，2026-10-02 06:28:43Z → 06:33:26Z；未逐一檢查各步驟）。
  4. workflow 建立 tag `ios-v0.1.49-b50`（target `f4231299`），並推回 `source.json`（`3fc121b4`，共五十筆，第一筆 `0.1.49`，size 29,433,746 與 IPA 相同）。本機以 pull merge fast-forward 到 `3fc121b4`。

  **沒有手動建 tag。**
- 產物：
  - GitHub Release `WebHTV 0.1.49 (50)`：不是 draft／prerelease，2026-10-02 06:33:18Z 發布。
  - `WebHTV-0.1.49-50.ipa`：**29,433,746 bytes**，狀態 uploaded；GitHub 記錄的 digest SHA-256 為 `a8ff95e7c86a8cffc55e1d6f9f15110a468c621ac47d455ebd1549f021f774b0`。
  - **IPA 已下載核對**（GET 200，SHA-256 與 digest 相同）：bundle `com.webhtv.ios.poc`，`CFBundleShortVersionString` `0.1.49`、`CFBundleVersion` `50`，`MinimumOSVersion` 與 `minos` 都是 `17.0`，`sdk 26.5`；`Translation.framework` 與 `_Translation_SwiftUI.framework` 仍為 `LC_LOAD_WEAK_DYLIB`。
- 發布前驗證（這一版有做）：
  - `swift test --package-path ios` 653／653；
  - 模擬器 Debug 與 generic iOS 不簽章 Release build（`05f58a20` 的程式狀態；版號 commit 只改版號欄位）；
  - 熱點下與修改前副本背對背的 sweep 與搜尋探測，模擬器實看農民播放與 App 內「檢查來源」；
  - 詳見 IOS-POC-42 第 14～16 節。
- **真機尚未驗收**。

### Release notes（實際送出的內容）

使用者 2026-10-02 指示 release notes 不帶站台內容（站名、設定檔名、站數、成人站），第一版草稿因此改寫。

```text
WebHTV 0.1.49 (50)（XYQHiker 規則來源的集數、播放與搜尋修正；真機未驗收）

修正
- XYQHiker 規則的來源中，設定為直接播放的影片不再沒有集數：照原版把影片頁本身當成唯一一集，可以直接播放。
- 播放這類影片時，先從網頁或其中的播放框架找出影片網址，並略過片頭廣告；找不到才改用網頁嗅探。
- XYQHiker 規則來源的搜尋：支援規則檔的中文欄位與 JSON 格式的搜尋結果，原本搜不到東西的來源現在可以搜尋。

已知限制
- 發布前通過自動測試（653 項）與模擬器建置、檢查；真機尚未驗收。
- 需要網頁嗅探的影片，能不能播放取決於網站與當下的網路。
- 其餘同 0.1.48 (49)。
```

## 第四十九次發布：`0.1.48 (49)`（2026-10-02，**已發布**，已被 `0.1.49 (50)` 取代）

- 授權：使用者 2026-10-02 指示「發佈」（IOS-POC-41C push 之後）。版號 `0.1.48`，build `49`。
- 內容：`0.1.47 (48)` 的全部，加上：
  - IOS-POC-41A（`c1459372`）：首頁／分類因網站問題回空時說明原因。
  - IOS-POC-41B（`99f6ef66`）：來源清單的健康圓點、站點健康排序與清除。
  - IOS-POC-41C（`cb38e30b`）：設定頁「檢查來源」與報告。
  - `9e5b71d8`：MPV 每個檔案記錄 `hwdec-current`。
  - `c1a4743c`：剛 clone 的 repo 不必手動準備 Python 就能 build，只影響建置。
  - `4ac71c27`：`isJapanese` 移到 `JapaneseTranslation`，行為不變。
  - 其餘是文件與 `0.1.47 (48)` 的 `source.json`（`667a056d`）。
- 發布序列：
  1. 版號 commit `72ad9891`（Task-Guard `IOS-RELEASE-0.1.48-b49`，兩個 build configuration 的 `MARKETING_VERSION`／`CURRENT_PROJECT_VERSION`，沒有其他行變動）。
  2. push `cb38e30b..72ad9891`（push 前先 pull merge，遠端沒有新 commit）。
  3. `gh workflow run ios-sidestore-release.yml --ref ios-poc -f version=0.1.48 -f build_number=49 -f release_notes=…` → run `36959157260`（conclusion success，2026-10-02 03:12:45Z → 03:18:46Z；未逐一檢查各步驟）。
  4. workflow 建立 tag `ios-v0.1.48-b49`（target `72ad9891`），並推回 `source.json`（`f1c11850`，共四十九筆，第一筆 `0.1.48`，size 29,432,118 與 IPA 相同）。本機以 pull merge fast-forward 到 `f1c11850`。

  **沒有手動建 tag。**
- 產物：
  - GitHub Release `WebHTV 0.1.48 (49)`：不是 draft／prerelease，2026-10-02 03:18:38Z 發布。
  - `WebHTV-0.1.48-49.ipa`：**29,432,118 bytes**，狀態 uploaded；GitHub 記錄的 digest SHA-256 為 `15202803ed4f0ef4bc29cab0aa97c24e4c667ab2c2fff3db1f6d512a3ed7482f`。
  - **IPA 已下載核對**（GET 200，SHA-256 與 digest 相同）：bundle `com.webhtv.ios.poc`，`CFBundleShortVersionString` `0.1.48`、`CFBundleVersion` `49`，`MinimumOSVersion` 與 `minos` 都是 `17.0`，`sdk 26.5`；`Translation.framework` 與 `_Translation_SwiftUI.framework` 仍為 `LC_LOAD_WEAK_DYLIB`。
- 發布前驗證（這一版有做）：
  - `swift test --package-path ios` 643／643；
  - 模擬器 Debug 與 generic iOS 不簽章 Release build；
  - 模擬器實看：41A 的原因文字、41B 的圓點與排序、41C 的檢查與報告；
  - 熱點下真實 sweep 的結果與 IOS-POC-39 第 7.3 節一致。
  - 詳見 IOS-POC-41 第 11～13 節。
- **真機尚未驗收**。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.48 (49)（來源健康：說明為什麼沒有內容、來源清單的健康圓點、一鍵檢查來源；真機未驗收）

新功能
- 來源打不開時說明原因：首頁或分類回空、而且背後的請求失敗時，不再只顯示「沒有內容」，而是寫出原因（找不到網域、連線逾時、無法連線、安全連線失敗、Cloudflare 驗證、HTTP 錯誤、需要執行 JavaScript 的驗證或跳轉頁），並註明是不是網站本身的問題。網站正常回應但沒有片時，仍顯示「沒有內容」。
- 來源清單的健康圓點：照 Android 的站點健康記錄，平常瀏覽、搜尋、詳情與播放的結果，會在首頁來源選單與設定頁的來源清單顯示綠（正常）、黃（不確定）、紅（常失敗）點；沒用過的站沒有圓點。設定頁「站點健康排序」（預設開）把較健康的來源排在前面，也可以清除記錄。
- 設定頁「檢查來源」：一次檢查目前設定的所有來源，逐站確認讀得到影片，結果依原因分組，可以分享文字報告，也會更新健康圓點。同時檢查 8 站、每站最多 90 秒。

改善
- MPV 每個檔案都會在記錄中寫下實際使用的解碼器，方便診斷。

已知限制
- 發布前通過自動測試（643 項）與模擬器檢查；真機尚未驗收。
- 檢查來源的結果取決於當下的網路，例如公司網路可能把很多站判成連不上。
- 其餘同 0.1.47 (48)。
```

## 第四十八次發布：`0.1.47 (48)`（2026-10-02，**已發布**，已被 `0.1.48 (49)` 取代）

- 授權：使用者 2026-10-02 指示「發佈」（IOS-POC-32D-2 push 之後）。版號 `0.1.47`，build `48`。
- 內容：`0.1.46 (47)` 的全部，加上 IOS-POC-32D-2（`fc74afa9`：翻譯列改為永不為空的 `VStack`，語言檢查才會執行）；其餘是 `0.1.46 (47)` 的 `source.json` 與紀錄（`bbae28de`、`67cdbfa8`）。
- 發布序列：
  1. 版號 commit `6fcc8555`（Task-Guard `IOS-RELEASE-0.1.47-b48`，兩個 build configuration 的 `MARKETING_VERSION`／`CURRENT_PROJECT_VERSION`，沒有其他行變動）。
  2. push `fc74afa9..6fcc8555`（push 前先 pull merge，遠端沒有新 commit）。
  3. GitHub MCP `actions_run_trigger` `run_workflow` `ios-sidestore-release.yml` ref `ios-poc`，`version=0.1.47`、`build_number=48`、`release_notes=…` → run `36945601982`（conclusion success，2026-10-02 00:21:49Z → 00:28:20Z；未逐一檢查各步驟）。
  4. workflow 建立 tag `ios-v0.1.47-b48`（target `6fcc8555`），並推回 `source.json`（`667a056d`，共四十八筆，第一筆 `0.1.47`，size 29,326,712 與 IPA 相同）。本機以 pull merge fast-forward 到 `667a056d`。

  **沒有手動建 tag。**
- 產物：GitHub Release `WebHTV 0.1.47 (48)`（不是 draft／prerelease，2026-10-02 00:28:08Z 發布），`WebHTV-0.1.47-48.ipa` **29,326,712 bytes**、狀態 uploaded，GitHub 記錄的 digest SHA-256
  `35164ac1a159de16f968348d1a49aaedd5f32c98f483f19dd8a53d1fa4d33e3c`。**IPA 已下載**（GET 200，SHA-256 與 digest 相同）：`minos 17.0`、`sdk 26.5`，`Translation.framework` 與 `_Translation_SwiftUI.framework` 仍為 `LC_LOAD_WEAK_DYLIB`。
- 發布前驗證：**沒有**（本環境無 Swift toolchain）；Release device build 由本次 workflow 第一次編譯，第一次即成功。**真機尚未驗收**（清單：IOS-POC-32 第七節之 3、之 6）。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.47 (48)（日文翻譯按鈕永遠不出現的修正；發布前沒有編譯與自動測試，真機未驗收）

修正
- 日文翻譯：0.1.45、0.1.46 的詳情頁從來沒有檢查語言，所以「翻譯成中文」按鈕與「不支援」說明都不會出現。現在設定為「詢問」或「自動」時，標題下方會顯示其中一個。

已知限制
- 此版發布前沒有執行自動測試，也沒有模擬器或真機驗收；這一版由發布流程第一次編譯。
- 其餘同 0.1.46 (47)。
```

## 第四十七次發布：`0.1.46 (47)`（2026-10-01，**已發布**，已被 `0.1.47 (48)` 取代）

- 授權：使用者 2026-10-01 指示「發佈」（IOS-POC-32D-1 push 之後）。版號 `0.1.46`，build `47`。
- 內容：`0.1.45 (46)` 的全部，加上 IOS-POC-32D-1（`60d4f932`：詳情頁打開時才讀「日文翻譯」設定；繁體中文取自框架的語言清單；不支援時顯示說明）；其餘是 `0.1.45 (46)` 的 `source.json` 與紀錄（`b8c857a3`、`e2d48c3b`）與 IOS-POC-40 真機紀錄（`9b33b19f`）。
- 發布序列：
  1. 版號 commit `20b86b49`（Task-Guard `IOS-RELEASE-0.1.46-b47`，兩個 build configuration 的 `MARKETING_VERSION`／`CURRENT_PROJECT_VERSION`，沒有其他行變動）。
  2. push `60d4f932..20b86b49`（push 前先 pull merge，遠端沒有新 commit）。
  3. GitHub MCP `actions_run_trigger` `run_workflow` `ios-sidestore-release.yml` ref `ios-poc`，`version=0.1.46`、`build_number=47`、`release_notes=…` → run `36898386121`（conclusion success，2026-10-01 17:18:18Z → 17:26:55Z；未逐一檢查各步驟）。
  4. workflow 建立 tag `ios-v0.1.46-b47`（target `20b86b49`），並推回 `source.json`（`bbae28de`，共四十七筆，第一筆 `0.1.46`，size 29,326,747 與 IPA 相同）。本機以 pull merge fast-forward 到 `bbae28de`。

  **沒有手動建 tag。**
- 產物：GitHub Release `WebHTV 0.1.46 (47)`（不是 draft／prerelease，2026-10-01 17:26:42Z 發布），`WebHTV-0.1.46-47.ipa` **29,326,747 bytes**、狀態 uploaded，GitHub 記錄的 digest SHA-256
  `d50175dfc698cdfbb5a836b4958fb99a84bc88ebb011f519671ed4b2dac22a0b`。**IPA 已下載**（GET 200，SHA-256 與 digest 相同）：`minos 17.0`、`sdk 26.5`，`Translation.framework` 與 `_Translation_SwiftUI.framework` 仍為 `LC_LOAD_WEAK_DYLIB`。
- 發布前驗證：**沒有**（本環境無 Swift toolchain）；Release device build 由本次 workflow 第一次編譯，第一次即成功。**真機尚未驗收**（清單：IOS-POC-32 第七節之 3、之 5）。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.46 (47)（日文翻譯按鈕沒有出現的修正；發布前沒有編譯與自動測試，真機未驗收）

修正
- 日文翻譯：在設定頁打開「日文翻譯」後，回到首頁點片子的詳情頁會立即套用（以前要重開 App 才會生效，按鈕不會出現）。
- 日文翻譯：繁體中文改用系統翻譯功能自己提供的語言；手機不支援時會顯示「這支手機目前不支援把日文翻成繁體中文。」，不再什麼都不顯示。

已知限制
- 此版發布前沒有執行自動測試，也沒有模擬器或真機驗收；這一版由發布流程第一次編譯。
- 其餘同 0.1.45 (46)。
```

## 第四十六次發布：`0.1.45 (46)`（2026-10-01，**已發布**，已被 `0.1.46 (47)` 取代）

- 授權：使用者 2026-10-01 指示「發佈版本」（IOS-POC-32 D push 之後；同一輪先問過是否新增只編譯的 workflow，使用者選擇直接發布）。版號 `0.1.45`，build `46`。
- 內容：`0.1.44 (45)` 的全部，加上 IOS-POC-32 D（`b6c9185e`：iOS 18 以上在裝置上把日文片名與簡介翻成繁體中文，設定「日文翻譯」預設關）；其餘是 `0.1.44 (45)` 的 `source.json` 與紀錄（`58d8d703`、`9fe0c925`）。
- 發布序列：
  1. 版號 commit `715b7731`（Task-Guard `IOS-RELEASE-0.1.45-b46`，兩個 build configuration 的 `MARKETING_VERSION`／`CURRENT_PROJECT_VERSION`，沒有其他行變動）。
  2. push `b6c9185e..715b7731`（push 前先 pull merge，遠端沒有新 commit）。
  3. GitHub MCP `actions_run_trigger` `run_workflow` `ios-sidestore-release.yml` ref `ios-poc`，`version=0.1.45`、`build_number=46`、`release_notes=…` → run `36896587110`（conclusion success，2026-10-01 17:03:41Z → 17:10:06Z；未逐一檢查各步驟）。
  4. workflow 建立 tag `ios-v0.1.45-b46`（target `715b7731`），並推回 `source.json`（`b8c857a3`，共四十六筆，第一筆 `0.1.45`，size 29,326,100 與 IPA 相同）。本機以 pull merge fast-forward 到 `b8c857a3`。

  **沒有手動建 tag。**
- 產物：GitHub Release `WebHTV 0.1.45 (46)`（不是 draft／prerelease，2026-10-01 17:09:55Z 發布），`WebHTV-0.1.45-46.ipa` **29,326,100 bytes**、狀態 uploaded，GitHub 記錄的 digest SHA-256
  `6ec4e25ea16e40bc3c6a0d810ddc5af39fcac30ea17c771a4b22f77200684468`。**IPA 已下載**（GET 200，29,326,100 bytes，SHA-256 與 digest 相同），以 Python 解析 `WebHTVApp` 的 Mach-O：`minos 17.0`、`sdk 26.5`；`Translation.framework` 與 `_Translation_SwiftUI.framework` 都是 `LC_LOAD_WEAK_DYLIB`（IOS-POC-32 第七節之 2 第 6 點、之 3 第 6 點通過）。
- 發布前驗證：**沒有**。本環境是 Linux、沒有 Swift toolchain，IOS-POC-32 D 沒有在本機編譯、`swift test` 沒有執行；Release device build 由本次 workflow 第一次編譯，第一次即成功。**真機尚未驗收**（清單：IOS-POC-32 第七節之 3；IOS-POC-40 第四節；IOS-POC-36 第十六節之 8 與第十七節之 8）。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.45 (46)（新增日文片名與簡介翻譯；發布前沒有編譯與自動測試，真機未驗收）

新功能
- 日文翻譯（iOS 18 以上）：設定頁「日文翻譯」可選關、詢問、自動，預設為關。開啟後，詳情頁的日文片名與簡介可以翻成繁體中文，翻譯在手機上進行，文字不會送出。
  - 詢問：標題下方顯示「翻譯成中文」按鈕；第一次使用會出現系統的語言下載提示。
  - 自動：語言已下載時直接翻譯；未下載時一樣顯示按鈕。
  - 譯文旁標「機器翻譯」，可切換「顯示原文」。翻譯失敗時保留原文，可重試。
  - 中文片名配日文簡介時只翻簡介；演員、導演不翻。

已知限制
- 此版發布前沒有執行自動測試，也沒有模擬器或真機驗收；這一版由發布流程第一次編譯。
- 假名很少的日文片名（例如「進撃の巨人」）不會被判斷為日文，因此不會出現翻譯按鈕。
- iOS 17 沒有這個功能，設定頁也不顯示。
- 其餘同 0.1.44 (45)。
```

## 第四十五次發布：`0.1.44 (45)`（2026-10-01，**已發布**，已被 `0.1.45 (46)` 取代）

- 授權：使用者 2026-10-01 指示「你先push並發佈版本」（IOS-POC-40 commit 之後）。版號 `0.1.44`，build `45`。
- 內容：`0.1.43 (44)` 的全部，加上 IOS-POC-40（`da10fe87`：spider 站集數值不是網址時，例如金牌系列的 `id@@nid`，詳情頁的集數與「立即播放」可以點選）；其餘是 `0.1.43 (44)` 的 `source.json` 與紀錄（`fd10a7a0`、`f0c2f3f9`）與 README（`277d4ac7`）。
- 發布序列：
  1. 版號 commit `25f9f780`（Task-Guard `IOS-RELEASE-0.1.44-b45`，兩個 build configuration 的 `MARKETING_VERSION`／`CURRENT_PROJECT_VERSION`，沒有其他行變動）。
  2. push `da10fe87..25f9f780`（push 前先 pull merge，遠端沒有新 commit）。
  3. GitHub MCP `actions_run_trigger` `run_workflow` `ios-sidestore-release.yml` ref `ios-poc`，`version=0.1.44`、`build_number=45`、`release_notes=…` → run `36892907513`（conclusion success，2026-10-01 16:33:39Z → 16:39:55Z；未逐一檢查各步驟）。
  4. workflow 建立 tag `ios-v0.1.44-b45`（target `25f9f780`），並推回 `source.json`（`58d8d703`，共四十五筆，第一筆 `0.1.44`，size 29,300,289 與 IPA 相同）。本機以 pull merge fast-forward 到 `58d8d703`。

  **沒有手動建 tag。**
- 產物：GitHub Release `WebHTV 0.1.44 (45)`（不是 draft／prerelease，2026-10-01 16:39:46Z 發布），`WebHTV-0.1.44-45.ipa` **29,300,289 bytes**、狀態 uploaded，GitHub 記錄的 digest SHA-256
  `b2cb6e690dc3c6c83ce321e384073d8522c918e26a07350664d4bde4991531d9`。本環境對 `source.json` 下載網址的 HEAD 回 401（經 egress proxy），**下載網址未驗證**；**IPA 未下載回來驗內容。**
- 發布前驗證：**沒有**。本環境是 Linux、沒有 Swift toolchain，IOS-POC-40 沒有編譯、`swift test` 沒有執行、沒有模擬器驗證；Release device build 由本次 workflow 第一次編譯，第一次即成功。**真機尚未驗收**（清單：IOS-POC-40 第四節；IOS-POC-36 第十六節之 8 與第十七節之 8 仍待驗）。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.44 (45)（金牌系列等來源的集數按不下去的修正；發布前沒有編譯與自動測試，真機未驗收）

修正
- 金牌系列（jiabaide、zjuys、愛電影、界界、cqzuoer）這類集數不是網址的來源：詳情頁的集數與「立即播放」以前是灰色、按不下去，現在可以點選播放。

已知限制
- 此修正發布前沒有執行自動測試，也沒有模擬器或真機驗收；這一版由發布流程第一次編譯。
- 可可影視詳情頁沒有年份、演員：來源腳本沒有提供這些欄位，此版未修正。
- 其餘同 0.1.43 (44)。
```

## 第四十四次發布：`0.1.43 (44)`（2026-10-01，**已發布**，已被 `0.1.44 (45)` 取代）

- 授權：使用者 2026-10-01 指示「發佈 0.1.43」（IOS-POC-36.5 push 之後）。版號 `0.1.43`，build `44`。
- 內容：`0.1.42 (43)` 的全部，加上 IOS-POC-36.4 的 D11（`c59577c9`：位置超過片長的觀看記錄算看到結尾，再打開從頭播）與 IOS-POC-36.5 的 D12（`1355aa98`：子母畫面中播完最後一集，小視窗跟著結束、session 照常關閉）；其餘是文件（`046c717b`、`5df6bb9e`、`4f11edfb`）與 `0.1.42 (43)` 的 `source.json`（`499e791f`）。
- 發布序列：
  1. 版號 commit `42ccc865`（Task-Guard `IOS-RELEASE-0.1.43-b44`，兩個 build configuration 的 `MARKETING_VERSION`／`CURRENT_PROJECT_VERSION`，沒有其他行變動）。
  2. push `1355aa98..42ccc865`（push 前先 pull merge，遠端沒有新 commit）。
  3. `gh workflow run ios-sidestore-release.yml --ref ios-poc -f version=0.1.43 -f build_number=44 -f release_notes=…` → run `36840330287`（conclusion success，job `release` success，2026-10-01 09:04:23Z → 09:09:50Z；未逐一檢查各步驟）。
  4. workflow 建立 tag `ios-v0.1.43-b44`（target `42ccc865`），並推回 `source.json`（`fd10a7a0`，共四十四筆，第一筆 `0.1.43`，size 29,300,051 與 IPA 相同）。本機以 pull merge fast-forward 到 `fd10a7a0`。

  **沒有手動建 tag。**
- 產物：GitHub Release `WebHTV 0.1.43 (44)`（不是 draft／prerelease，2026-10-01 09:09:40Z 發布），`WebHTV-0.1.43-44.ipa` **29,300,051 bytes**、狀態 uploaded，GitHub 記錄的 digest SHA-256
  `cdc40a588aec8f59656fd2ff458338ccfe9de0507135e82e84d4f74bc7096840`；`source.json` 的下載網址 HEAD 回 200、`content-length` 29,300,051。**IPA 未下載回來驗內容。**
- 發布前驗證：`swift test` 622/622；本機模擬器 Debug、generic iOS 不簽章 Release build 在 `1355aa98` 的程式上通過；D11、D12 的模擬器實測（IOS-POC-36 第十七節之 3、之 8）。Release device build 另由本次 workflow 編譯，第一次即成功。**真機尚未驗收**（清單：IOS-POC-36 第十六節之 8 與第十七節之 8）。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.43 (44)（看完的片子重新打開從頭播、子母畫面播完最後一集後殘留視窗的修正；只有自動測試、模擬器與本機建置驗證，真機未驗收）

修正
- 一集播到結尾後再打開同一部片（立即播放或點同一集）：會從頭播放（以前有時停在結尾、馬上結束，接著跳到下一集或關閉）；觀看記錄也會正確顯示「已看完」。
- 在子母畫面中播完最後一集：小視窗會跟著關掉（以前原生播放器會留下停在最後一格的小視窗，再開新片時小視窗和播放器會同時播放；MPV 會留下黑色的「直播」視窗）。

已知限制
- 此版沒有真機驗收；子母畫面的修正只在 iPad 模擬器驗過，0.1.39 (40) 起的播放修正也都還沒有真機驗收。
- 其餘同 0.1.42 (43)。
```

## 第四十三次發布：`0.1.42 (43)`（2026-10-01，**已發布**，已被 `0.1.43 (44)` 取代）

**發布當時最新版是 `0.1.42 (43)`**（已被 `0.1.43 (44)` 取代，見第四十四次發布）。前面四十二版都已被取代。

- 授權：使用者 2026-10-01 指示「發佈」（IOS-POC-36.3 RC 驗收判定 `PASS_WITH_DEVICE_ACCEPTANCE_PENDING` 並 push 之後）。版號照序號 `0.1.42`，build `43`。
- 內容：`0.1.41 (42)` 的全部，加上 IOS-POC-36.2（`fc4a3282`、`f6d1bf30`：PiP 在背景關閉後的暫停 reload，PL-14／D9）、ponytail audit 第一批（`8bfe875a`、`f26ccae6`、`736023f8`）與第二批（`1ea1c732`、`3fd68923`、`53de9b61`）、IOS-POC-36.3（`2244dd3a`：D10，失敗之後原地開的新 item 不再蓋著上一個的失敗訊息；`eaa3af75`、`b9ff7e7e`、`4d5370da` 的測試與驗收紀錄）；其餘是文件。
- 發布序列：
  1. 版號 commit `04f6567e`（Task-Guard `IOS-RELEASE-0.1.42-b43`，兩個 build configuration 的 `MARKETING_VERSION`／`CURRENT_PROJECT_VERSION`，沒有其他行變動）。
  2. push `4d5370da..04f6567e`（push 前先 pull merge，遠端沒有新 commit）。
  3. `gh workflow run ios-sidestore-release.yml --ref ios-poc -f version=0.1.42 -f build_number=43 -f release_notes=…` → run `36821576390`（conclusion success，job `release` success，2026-10-01 05:48:42Z → 05:54:20Z；未逐一檢查各步驟）。
  4. workflow 建立 tag `ios-v0.1.42-b43`（target `04f6567e`），並推回 `source.json`（`499e791f`，共四十三筆，第一筆 `0.1.42`，size 29,300,453 與 IPA 相同）。本機以 pull merge fast-forward 到 `499e791f`。

  **沒有手動建 tag。**
- 產物：GitHub Release `WebHTV 0.1.42 (43)`（不是 draft／prerelease，2026-10-01 05:54:12Z 發布），`WebHTV-0.1.42-43.ipa` **29,300,453 bytes**、狀態 uploaded，GitHub 記錄的 digest SHA-256
  `117db406a2f5b64a7d2e77e52948a6a6359805fa6e40021cbf6a78da4163c858`；`source.json` 的下載網址 HEAD 回 200、`content-length` 29,300,453。**IPA 未下載回來驗內容。**
- 發布前驗證：`swift test` 620/620；本機模擬器 Debug、generic iOS 不簽章 Release 與 `WebHTVCore` iOS build 在 `2244dd3a` 的程式上通過；模擬器實測與 WebHome A→B（IOS-POC-36 第十六節）。Release device build 另由本次 workflow 編譯，第一次即成功。**真機尚未驗收**（清單：IOS-POC-36 第十六節之 8）。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.42 (43)（子母畫面在背景關閉後的續播、失敗訊息殘留修正；只有自動測試、模擬器與本機建置驗證，真機未驗收）

修正
- 播放中進子母畫面，在小視窗暫停或按 ✕ 關掉後，App 在背景被系統暫停執行：回到 App 時會在暫停的位置重新載入，按播放就能繼續（以前按播放沒有反應）。
- 一集在兩個播放器都無法播放之後，換到上一集／下一集、換畫質，或 WebHome 頁面再播放：畫面上的「無法播放」訊息會消失（以前會一直蓋在新的一集上）。

變更
- 播放器已經開著時，WebHome 頁面再呼叫播放，會在原本的播放器裡直接換片，不再關掉重開。
- 設定頁「加入設定來源」的網址欄位改用網址鍵盤。
- 內部清理：刪除 Debug 專用的 MPV 驗證畫面與啟動檢查；雜湊與 HMAC 改用系統的 CryptoKit（結果與以前逐位元相同）。

已知限制
- 此版沒有真機驗收；0.1.39 (40) 起的播放修正也都還沒有真機驗收。
- 其餘同 0.1.41 (42)。
```

## 第四十二次發布：`0.1.41 (42)`（2026-09-30，**已發布**，已被 `0.1.42 (43)` 取代）

**發布當時最新版是 `0.1.41 (42)`**（已被 `0.1.42 (43)` 取代，見第四十三次發布）。前面四十一版都已被取代。

- 授權：使用者 2026-09-30 指示「發布新版 0.1.41 (42)」（IOS-POC-36.1 push 之後）。版號 `0.1.41`，build `42`。
- 內容：`0.1.40 (41)` 的全部，加上 IOS-POC-36.1（`ea96268f`：loop 下同一段播放只處理一次結束，replay 的 seek 落地才允許再次結束；驗收矩陣證據稽核）；其餘是文件（`e0125176`、`d345552f`、`78324ef3`）。
- 發布序列：
  1. 版號 commit `46c0d36d`（Task-Guard `IOS-RELEASE-0.1.41-b42`，兩個 build configuration 的 `MARKETING_VERSION`／`CURRENT_PROJECT_VERSION`，沒有其他行變動）。
  2. push `ea96268f..46c0d36d`（push 前先 pull merge，遠端沒有新 commit）。
  3. `gh workflow run ios-sidestore-release.yml --ref ios-poc -f version=0.1.41 -f build_number=42 -f release_notes=…` → run `36698521242`（conclusion success，2026-09-30 09:49:05Z → 09:54:59Z；未逐一檢查各步驟）。
  4. workflow 建立 tag `ios-v0.1.41-b42`（target `46c0d36d`），並推回 `source.json`（`af6f8b5e`，共四十二筆，第一筆 `0.1.41`，size 29,344,346 與 IPA 相同）。本機以 pull merge fast-forward 到 `af6f8b5e`。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.41-42.ipa` **29,344,346 bytes**，GitHub 記錄的 digest SHA-256
  `247768a7f6f08ece47c1dd4408cca02878bbfbdb70610becb0bcce1159648735`。**IPA 未下載回來驗內容**（本次未取得下載授權）。
- 發布前驗證：`swift test` 613/613；本機模擬器 Debug build 與 generic iOS 不簽章 Release build 在 `ea96268f` 的最終版本上通過（IOS-POC-36 文件第十四節之 4）；Release device build 另由本次 workflow 編譯，第一次即成功。**真機尚未驗收。**

### Release notes（實際送出的內容）

```text
WebHTV 0.1.41 (42)（重複播放的結尾修正；只有自動測試與本機建置驗證，真機未驗收）

修正
- WebHome 頁面開了「重複播放」時，一集播完只從頭重播一次：片尾設定與真正播完不會再讓它重播兩次，重播途中關掉重複也不會跳到下一集。
- 重複播放開著時，上一集／下一集切換中剛好播到結尾，只換集，不會同時重播。

已知限制
- 此版沒有真機驗收；0.1.39 (40) 起的播放修正也都還沒有真機驗收。
- MPV 播到真正結尾之後，重複播放仍然無效（既有問題，未修）。
- 其餘同 0.1.40 (41)。
```

## 第四十一次發布：`0.1.40 (41)`（2026-09-30，**已發布**，已被 `0.1.41 (42)` 取代）

**發布當時最新版是 `0.1.40 (41)`**（已被 `0.1.41 (42)` 取代，見第四十二次發布）。前面四十版都已被取代。

- 授權：使用者 2026-09-30 指示「bump 版本並發布」（IOS-POC-39 S5 push 之後）。版號沿用序號 `0.1.40`，build `41`。
- 內容：`0.1.39 (40)` 的全部，加上 IOS-POC-39 S5 第 1、2 項（`49c7ca1e`：XBPQ 搜尋網址的 `{pg}`／`{catePg}`、`搜索*` 規則）；其餘是文件（`0982e4da`、`c929da15`、`d6dd49b1`、`421760fd`）。
- 發布序列：
  1. 版號 commit `25714bee`（Task-Guard `IOS-RELEASE-0.1.40-b41`，兩個 build configuration 的 `MARKETING_VERSION`／`CURRENT_PROJECT_VERSION`，沒有其他行變動）。
  2. push `d6dd49b1..25714bee`（push 前先 pull merge，遠端沒有新 commit）。
  3. `gh workflow run ios-sidestore-release.yml --ref ios-poc -f version=0.1.40 -f build_number=41 -f release_notes=…` → run `36692728317`（conclusion success，2026-09-30 08:55:07Z → 09:01:22Z；未逐一檢查各步驟）。
  4. workflow 建立 tag `ios-v0.1.40-b41`（target `25714bee`），並推回 `source.json`（`88ca9dab`，共四十一筆，第一筆 `0.1.40`，size 29,340,833 與 IPA 相同）。同一個工作目錄的另一個 session 在 workflow 執行期間 commit 了 `421760fd`（文件），並以 merge `c82a7b70` 併入 `88ca9dab` 後 push。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.40-41.ipa` **29,340,833 bytes**，GitHub 記錄的 digest SHA-256
  `c81a9f3f8ff7e7f95c30162aa9ffb7ffb8532416fddf4056f77c28e4cd628928`。**IPA 未下載回來驗內容**（本次未取得下載授權）。
- 發布前驗證：`swift test` 610/610；個人熱點的搜尋探測（IOS-POC-39 第 6.5 節：搜得到的 XBPQ 站 6→7）。本次沒有在本機建置 App，Release device build 由本次 workflow 編譯，第一次即成功。**真機尚未驗收。**

### Release notes（實際送出的內容）

```text
WebHTV 0.1.40 (41)（XBPQ 規則站的搜尋修正；只有自動測試與 CI 建置驗證，真機未驗收）

修正
- XBPQ 規則站的搜尋：搜尋網址裡的 {pg}、{catePg} 會代入頁碼（以前頁碼那一段是空的）；站台有設「搜索数组」等搜尋規則時照它解析結果，沒設時照列表規則。

已知限制
- 此版沒有真機驗收。個人熱點實測搜得到的 XBPQ 站只多了 1 站：大多數搜不到的站連片單都取不到（網站回 JavaScript 跳轉頁或網域失效），或根本沒有設搜尋網址。
- 其餘同 0.1.39 (40)。
```

## 第四十次發布：`0.1.39 (40)`（2026-09-30，**已發布**，已被 `0.1.40 (41)` 取代）

**發布當時最新版是 `0.1.39 (40)`**（已被 `0.1.40 (41)` 取代，見第四十一次發布）。前面三十九版都已被取代。

- 授權：使用者 2026-09-30 指示「整理git／bump 版本並發布」（IOS-POC-39 S4 push 之後）。版號沿用序號 `0.1.39`，build `40`。
- 內容：`0.1.38 (39)` 的全部，加上 IOS-POC-39 S1～S4（XBPQ 規則引擎：`ab490dfa`、`531093a1`、`0d0303c6`、`32706651`、`a0343257`）與 IOS-POC-36（播放器驗收矩陣與 D1～D7 修正，`2840c2e4`；handoff 記載「隨下一個發布版本」，本次一併發布）。
- 發布序列：
  1. 版號 commit `4b93443a`（Task-Guard `IOS-RELEASE-0.1.39-b40`，兩個 build configuration 的 `MARKETING_VERSION`／`CURRENT_PROJECT_VERSION`，沒有其他行變動）。
  2. push `a0343257..4b93443a`（push 前先 pull merge，遠端沒有新 commit）。
  3. `gh workflow run ios-sidestore-release.yml --ref ios-poc -f version=0.1.39 -f build_number=40 -f release_notes=…` → run `36689542773`（conclusion success，2026-09-30 08:24:49Z → 08:32:12Z；未逐一檢查各步驟）。
  4. workflow 建立 tag `ios-v0.1.39-b40`（target `4b93443a`），並推回 `source.json`（`3ec8d97b`，共四十筆，第一筆 `0.1.39`，size 29,340,174 與 IPA 相同）。本機以 pull merge fast-forward 到 `3ec8d97b`。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.39-40.ipa` **29,340,174 bytes**，GitHub 記錄的 digest SHA-256
  `cf9e988157167fc6cd41735117de7685d7313954dcd1021819fcd85624ddb8d5`。**IPA 未下載回來驗內容**（本次未取得下載授權）。
- 發布前驗證：`swift test` 607/607（含 IOS-POC-36 合併後）；IOS-POC-39 個人熱點 sweep（`wang-sex.json` 可播放 29→41、`wang-movie.json` 24 維持，見 IOS-POC-39 第 6.3 節）；IOS-POC-36 自己的模擬器驗收與 Debug／Release build（IOS-POC-36 文件第六節）。本次沒有另外在本機建置 App，Release device build 由本次 workflow 編譯，第一次即成功。**真機尚未驗收。**

### Release notes（實際送出的內容）

```text
WebHTV 0.1.39 (40)（XBPQ 規則站可以播了、播放切換修正；只有自動測試、模擬器與 CI 建置驗證，真機未驗收）

新功能
- XBPQ 規則站：讀得到 ./json/*.json 規則檔，分類、片單、詳情與播放改照原版的規則語意（含直接播放、跳轉播放連結）。個人熱點實測 wang-sex.json 可播放的站由 29 增加到 41。

修正
- 設了片尾、下一集又解析得慢時，不再跳過一集；上一集／下一集按到一半遇到結尾也只換一集。
- 核心播不了而自動換到另一個核心時，照你最後一次按的播放／暫停（以前暫停中失敗也會自己開始播）。
- MPV 播到一半失敗換到原生時，接在失敗的位置，不再回到開頭。
- 快速連按前進／倒退 10 秒會累加。
- 切換核心的瞬間不再從 0:00 起算。

已知限制
- 此版沒有真機驗收。
- XBPQ 的搜尋還沒改；部分 XBPQ 站因為網站回 JavaScript 跳轉頁或網域失效，仍然不可用。
```

## 第三十九次發布：`0.1.38 (39)`（2026-09-30，**已發布**，已被 `0.1.39 (40)` 取代）

**發布當時最新版是 `0.1.38 (39)`**（已被 `0.1.39 (40)` 取代，見第四十次發布）。前面三十八版都已被取代。

- 授權：使用者 2026-09-30 指示「發新版」（IOS-POC-37.3.1 push 之後）。版號沿用序號 `0.1.38`，build `39`。
- 內容：`0.1.37 (38)` 的全部，加上 IOS-POC-37.3.1（`97139580`：Python Spider 以標準 `Spider()` 語意建構、`python.host` 1.5）、其 survey 補充（`bd3a79b8`）與 `0.1.37 (38)` 的發布紀錄（`a858fe77`）。文件 IOS-POC-37 第十五節。
- 發布序列：
  1. 版號 commit `59d51115`（Task-Guard `IOS-RELEASE-0.1.38-b39`）。
  2. push `bd3a79b8..59d51115`。
  3. `gh workflow run ios-sidestore-release.yml --ref ios-poc -f version=0.1.38 -f build_number=39 -f release_notes=…` → run `36675114903`（conclusion success，2026-09-30 05:48:31Z → 05:54:26Z；未逐一檢查各步驟）。
  4. workflow 建立 tag `ios-v0.1.38-b39`（target `59d51115`），並推回 `source.json`（`49f30020`，共三十九筆，第一筆 `0.1.38`，size 與 IPA 相同）。本機由另一個 session（IOS-POC-36）在 13:56 fast-forward 到 `49f30020`。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.38-39.ipa` **29,318,975 bytes**，GitHub 記錄的 digest SHA-256
  `ededfb859bc52cf02be9de7d3c3636b2a039b2a6e52b1b0d96dc2435a79b6436`。**IPA 未下載回來驗內容**（本次未取得下載授權）。
- 發布前驗證：IOS-POC-37 第 15.4 節——host Python 10/10、`swift test` 578/578、模擬器依賴自檢 8/8、13/13、App 內 A→B→A、模擬器 Debug build、44 站 survey media 20（個人熱點）。**真機尚未驗收。**

### Release notes（實際送出的內容）

```text
WebHTV 0.1.38 (39)（Python 腳本的建構方式修正；只有模擬器驗證，真機未驗收）

修正
- Python 腳本的 Spider 改回與 Android 相同的標準建構方式：自訂的 metaclass 會照常執行；__init__ 回傳值時會像 Android 一樣載入失敗；同一個 Spider 實例不能同時給兩個站使用，避免兩站的快取互相覆蓋。目前設定檔沒有這些寫法的腳本，所以使用上不會看到差異。

已知限制
- 此版只有模擬器（依賴自檢 8/8、44 站 survey）與 CI 的 Release 建置驗證。
- 其餘同 0.1.37 (38)，包含 MPV 子母畫面修正仍待真機回報。
```

## 第三十八次發布：`0.1.37 (38)`（2026-09-30，**已發布**，已被 `0.1.38 (39)` 取代）

- 授權：使用者 2026-09-30 指示「發新版」（IOS-POC-37.3 push 之後）。版號沿用序號 `0.1.37`，build `38`。
- 內容：`0.1.36 (37)` 的全部，加上 IOS-POC-37.3（`3486006a`：Python spider 在 `__init__` 前就有自己的 cache context；native stamp 納入 Xcode／SDK／clang identity；`python.host` 1.4）與 `0.1.36 (37)` 的發布紀錄（`0e1509cc`）。文件 IOS-POC-37 第十四節。
- 發布序列：
  1. 版號 commit `d2879a08`（Task-Guard `IOS-RELEASE-0.1.37-b38`）。
  2. push `3486006a..d2879a08`。
  3. `gh workflow run ios-sidestore-release.yml --ref ios-poc -f version=0.1.37 -f build_number=38 -f release_notes=…` → run `36666442367`（conclusion success，2026-09-30 03:53:43Z → 04:00:25Z；未逐一檢查各步驟）。
  4. workflow 建立 tag `ios-v0.1.37-b38`（target `d2879a08`），並推回 `source.json`（`82ebcba0`，共三十八筆，第一筆 `0.1.37`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.37-38.ipa` **29,318,714 bytes**，GitHub 記錄的 digest SHA-256
  `cb7e9d68518b8fd9a484ff95a5a26aa5549ef8ed68cdf6bf184183a7c0d11652`。**IPA 未下載回來驗內容**（本次未取得下載授權）。
- 發布前驗證：IOS-POC-37 第 14.4 節——host Python 5/5、`swift test` 578/578、模擬器依賴自檢 8/8、App 內 A→B→A（含 constructor）、模擬器 Debug build、44 站 survey media 19。**真機尚未驗收。** 這是 CI 第一次跑納入 toolchain identity 的 native stamp（見 IOS-POC-37 第 14.6 節第 3 項）；run 成功，但沒有另外讀 Prepare Python 那一步是否印出 `already current`。
- 使用者中斷：workflow 觸發後，使用者貼上下一個任務（IOS-POC-37.3.1）。發布已在執行且事前明確授權，所以沒有取消，等它完成後再開始下一個任務。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.37 (38)（Python 執行環境的兩個小修正；只有模擬器驗證，真機未驗收）

修正
- Python 腳本若在建構時（__init__）就讀寫快取，現在會讀寫到自己站的資料。先前那時拿不到快取、讀到空的也寫不進去。目前設定檔沒有這樣寫的腳本，所以使用上不會看到差異。
- 開發端：Python 原生套件（pycryptodome、lxml）的建置記錄納入 Xcode、SDK 與編譯器版本，換版後會自動重新編譯。

已知限制
- 此版只有模擬器（依賴自檢 8/8、44 站 survey）與 CI 的 Release 建置驗證。
- 其餘同 0.1.36 (37)，包含 MPV 子母畫面修正仍待真機回報。
```

## 第三十七次發布：`0.1.36 (37)`（2026-09-30，**已發布**，已被 `0.1.37 (38)` 取代）


- 授權：使用者 2026-09-30 指示「A 和 B 一起改，改完發新版」（IOS-POC-17H-4）。版號沿用序號 `0.1.36`，build `37`。
- 內容：`0.1.35 (36)` 的全部，加上 IOS-POC-17H-4（`35eeebad`：MPV 進入子母畫面時先放上目前畫面、不再把第一張黑色重繪送進視窗；回到 App 時不再重複要求結束子母畫面）。文件 IOS-POC-17H 第八節。
- 發布序列：
  1. 版號 commit `27014705`（Task-Guard `IOS-RELEASE-0.1.36-b37`）。
  2. push `2c3e61ee..27014705`。
  3. `gh workflow run ios-sidestore-release.yml --ref ios-poc -f version=0.1.36 -f build_number=37 -f release_notes=…` → run `36660222721`（conclusion success，2026-09-30 02:31:16Z → 02:36:57Z；未逐一檢查各步驟）。
  4. workflow 建立 tag `ios-v0.1.36-b37`（target `27014705`），並推回 `source.json`（`7cd57e3f`，共三十七筆，第一筆 `0.1.36`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.36-37.ipa` **29,318,550 bytes**，GitHub 記錄的 digest SHA-256
  `812d7af9c943410076e89285038c6d703660c8d87aad0277946689a4d4b8dc26`。**IPA 未下載回來驗內容**（本次未取得下載授權）。
- 發布前驗證：IOS-POC-17H 第八節——`swift test` 578 項全過、Release 實機 build 成功（`MPVEngine.swift` 0 warning）、iPad 模擬器 hook 驗證截圖／PiP 開關／延後 stop。**真機尚未驗收。**

### Release notes（實際送出的內容）

```text
WebHTV 0.1.36 (37)（MPV 子母畫面修正；只有模擬器驗證，真機未驗收）

修正
- MPV 進入子母畫面時，視窗一出現就顯示目前的畫面，不再先黑一下。
- 從子母畫面按「回到 App」時，App 不再重複要求結束子母畫面（可能是放回前畫面閃一下的原因）。從主畫面點 App 圖示回來時，子母畫面約晚 0.3 秒結束。

已知限制
- 放回動畫會先放大成整個螢幕，這是 iOS 系統的動畫，App 無法指定。
- 此版只有模擬器與 CI 的 Release 建置驗證；閃一下原本是兩次才出現一次，請多試幾次。
- 系統播放器（AVPlayer）的子母畫面未修改。
```

## 第三十六次發布：`0.1.35 (36)`（2026-09-29，**已發布**，已被 `0.1.36 (37)` 取代）


- 授權：使用者 2026-09-29 指示「發佈」（IOS-POC-37.2 push 之後，模擬器與真機驗證之前）。版號沿用序號 `0.1.35`，build `36`。
- 內容：`0.1.34 (35)` 的全部，加上 IOS-POC-37.2（`30f26084`：stdlib `ssl` 預設信任 App 內附的 certifi，比照 Android Chaquopy；依賴自檢新增 `ssl`，7 → 8 項）。文件 IOS-POC-37 第十三節。
- 發布序列：
  1. 版號 commit `f73aabce`（Task-Guard `IOS-RELEASE-0.1.35-b36`）。
  2. push `30f26084..f73aabce`。
  3. 此環境沒有 `gh`，改用 GitHub MCP `actions_run_trigger`（`workflow_dispatch`，`ios-sidestore-release.yml`，ref `ios-poc`，`release_notes=…`）→ run `36581018292`（conclusion success，2026-09-29 14:13:18Z → 14:19:41Z；未逐一檢查各步驟）。
  4. workflow 建立 tag `ios-v0.1.35-b36`（target `f73aabce`），並推回 `source.json`（`4500e3f8`，共三十六筆，第一筆 `0.1.35`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.35-36.ipa` **29,314,249 bytes**，SHA-256
  `7a0dc4a67b6695dc945fe555542293e9d8ab0730a8c7b19bbc5dd4e7b5629c3d`（與 GitHub 記錄的 digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.35` / build `36` / minimum iOS `17.0`；`Frameworks/` 142 個；`python-packages/` 0 個 `.so`、46 個 `.fwork`，含 `certifi/cacert.pem`；`webhtv-python/webhtv_runtime.py` 含 `ssl.SSLContext.set_default_verify_paths = _load_bundled_cas`，`webhtv_selfcheck.py` 含 `ssl` 檢查。
- 發布前驗證：IOS-POC-37 第 13.4 節（Linux host 的 TLS 對照、`py_compile`）與 CI 的 Release 裝置 build。**沒有跑 `swift test`、模擬器自檢、44 站 survey；真機尚未驗收。**
- 紀錄：本節於 2026-09-30 補寫。發布當時要讀上一版紀錄時被自動權限判斷擋下，使用者 2026-09-30 授權後才寫。
- 發布後：使用者回報 SideStore 沒有看到新版（「沒有進版號」）。查證結果：IPA 內部版號 `0.1.35`／build `36`；`raw.githubusercontent.com/.../ios-poc/source.json` 第一筆 `0.1.35`；SideStore `develop` `0dd743f75afc358b0ba4a002feb5f19474492371` 的 `InstalledApp.hasUpdate` 取 `versions` 第一筆做 semver 比較，`0.1.35 > 0.1.34` 成立。判定來源端正確，可能原因是使用者在 `source.json` 推上（14:19:28Z）之前查看、SideStore 未重新整理，或 App 不是從此來源安裝。使用者 2026-09-30 回報 SideStore 已出現 `0.1.35` 更新。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.35 (36)（未經模擬器與真機驗收）

修正
- Python 站直接用標準函式庫（urllib）連 HTTPS 時，改用 App 內附的根憑證驗證，與 Android 相同。先前這類腳本在 iPhone 上會因憑證驗證失敗而拿不到內容（例如有分類、影片列表是空的）。

已知限制
- 此版發布前只有 CI 的 Release 建置，沒有跑模擬器自檢與站點 survey。
- 其餘同 0.1.34 (35)。
```

## 第三十五次發布：`0.1.34 (35)`（2026-09-29，**已發布**，已被 `0.1.35 (36)` 取代）

- 授權：使用者 2026-09-29 指示「先幫我發佈」（在回報金牌 zjuys 篩選問題之後、調查完成之前）。版號沿用序號 `0.1.34`，build `35`。
- 內容：`0.1.33 (34)` 的全部，加上 IOS-POC-37.1（`68ad62a5`：Python spider 的 cache context 改由各 spider 持有；native build stamp 納入 CPython payload identity；`python.host` ABI 1.2）。文件 IOS-POC-37 第十二節。
- 發布序列：
  1. 版號 commit `76f218f6`（Task-Guard `IOS-RELEASE-0.1.34-b35`）。
  2. push `68ad62a5..76f218f6`。
  3. `gh workflow run ios-sidestore-release.yml --ref ios-poc -f release_notes=…` → run `36552435557`（success，2026-09-29 09:56:50Z → 10:01:18Z，所有步驟 success）。
  4. workflow 建立 tag `ios-v0.1.34-b35`（target `76f218f6`），並推回 `source.json`（`7a3c6b7c`，共三十五筆，第一筆 `0.1.34`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.34-35.ipa` **29,313,638 bytes**，SHA-256
  `e054b254bd867edee7e02ba340b5be91ba9717e6bf30c82aceb61544931c0efb`（與 GitHub 記錄的 digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.34` / build `35` / minimum iOS `17.0`；`Frameworks/` 142 個；`python-packages/` 0 個 `.so`、46 個 `.fwork`；`webhtv-python/base/spider.py` 用 `_webhtv_cache_dir`、已無模組全域 `_cache_dir`。
- 發布前驗證：IOS-POC-37 第 12.3 節（`swift test` 577/577、依賴自檢 7/7、App 內 cache A→B→A、模擬器 Debug 與 Release 裝置 build、44 站 survey 到 media 20 站）。**真機尚未驗收。**

### Release notes（實際送出的內容）

```text
WebHTV 0.1.34 (35)（未經真機驗收）

修正
- Python 站的快取不再互相覆蓋：同時開過多個 Python 站（例如全站搜尋）之後，各站存的資料（如 MiFun、山楂的裝置識別）只會寫進自己那一站。

已知限制
- 金牌系列-zjuys 的分類篩選問題仍在調查中，此版尚未修正。
- 其餘同 0.1.33 (34)：部分 Python 站因網站本身連不上、分類回空、或播放需要 Android 的本機代理而無法播放。
```

## 第三十四次發布：`0.1.33 (34)`（2026-09-29，**已發布**，已被 `0.1.34 (35)` 取代）

- 授權：使用者 2026-09-29 指示「發布 0.1.33 (34) 到 SideStore」。版號 `0.1.33`，build `34`。
- 內容：`0.1.32 (33)` 的全部，加上 IOS-POC-37（`92b31ccf`：內建 Python 加入 pycryptodome 3.23.0、lxml 6.1.3、beautifulsoup4、pyquery 與其相依；三個 loader 相容性修正；`python.host` ABI 1.1）。文件 `docs/IOS-POC-37-python-runtime-dependency-expansion.md`。
- 發布序列：
  1. 版號 commit `062fcf99`（Task-Guard `IOS-RELEASE-0.1.33-b34`）。
  2. push `92b31ccf..062fcf99`。
  3. `gh workflow run ios-sidestore-release.yml --ref ios-poc -f release_notes=…` → run `36548879889`（success，2026-09-29 09:23:41Z → 09:29:55Z）。**這是 IOS-POC-37 新增的「Set up host Python」與 native 交叉編譯第一次在 CI 上跑**：runner 的 Python 3.13.15（`hostedtoolcache`）驅動 `build_python_ios_native.sh --sdk iphoneos`，1 分 49 秒完成（09:24:21Z → 09:26:10Z，樹 9.8 MB）；之後 Xcode `Prepare Python` 看到 stamp 一致直接跳過。
  4. workflow 建立 tag `ios-v0.1.33-b34`（target `062fcf99`），並推回 `source.json`（`ecd9b857`，共三十四筆，第一筆 `0.1.33`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.33-34.ipa` **29,313,282 bytes**（比 `0.1.32 (33)` 多 3,507,107 bytes），SHA-256
  `fa8637c945ab355e0ce1067457364a8578bbcada068ca5d4c4e97c6d4373e61f`（與 GitHub 記錄的 digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.33` / build `34` / minimum iOS `17.0`；`Frameworks/` 142 個（其中 `Crypto.*`、`lxml.*` 46 個，`lxml.etree` 為 platform 2、minos 13.0）；`python-packages/` 有 Crypto、lxml、bs4、soupsieve、typing_extensions、pyquery、cssselect 與原本的 requests 系，0 個 `.so`、46 個 `.fwork`。
- 發布前驗證：IOS-POC-37 第六節（模擬器依賴自檢 7/7、44 站 survey 到 media 19 站、`swift test` 577/577、本機 Release 裝置 build）。**真機尚未驗收。**

### Release notes（實際送出的內容）

```text
WebHTV 0.1.33 (34)（未經真機驗收）

新增
- 內建 Python 加入 Crypto（pycryptodome）、lxml、bs4、pyquery。原本顯示「這個來源需要某模組」的 Python 站現在可以載入；模擬器上 44 個 Python 站中能播到影片的由 3 站增加到 19 站。

修正
- 短剧聚合、映像、永樂等 Python 站不再在載入時就失敗。

已知限制
- 仍有部分 Python 站因網站本身連不上、分類回空、或播放需要 Android 的本機代理而無法播放。
- App 大小約增加 3.7 MB；SideStore 安裝時要多簽 46 個元件，可能稍慢。
```

## 第三十三次發布：`0.1.32 (33)`（2026-09-29，**已發布**，已被 `0.1.33 (34)` 取代）

- 授權：使用者 2026-09-29 對「要 push 並發布成 `0.1.32 (33)` 讓你在真機測嗎？」回答「好，push 並發布」。版號 `0.1.32`，build `33`。
- 內容：`0.1.31 (32)` 的全部，加上 IOS-POC-17H-3（`47f942e8`：MPV 子母畫面進入與接回時的兩處黑格、接回淡入、PiP 層改為影片矩形；文件 `1154413e`），以及另一個 session 同日的 IOS-POC-12（`b354c80e`、`5cd44076`）與 IOS-POC-13 實作後撤銷（`f4bddf64`…`9410fb68`，撤銷 `20fd462e`；執行檔已不含 `RuntimePackUpdater`）。
- 發布序列：
  1. 版號 commit `76d79787`（Task-Guard `IOS-RELEASE-0.1.32-b33`）。
  2. push `20fd462e..76d79787`。
  3. `gh workflow run ios-sidestore-release.yml --ref ios-poc -f release_notes=…` → run `36541592908`（success，2026-09-29 08:15:30Z → 08:18:07Z）。
  4. workflow 建立 tag `ios-v0.1.32-b33`（target `76d79787`），並推回 `source.json`（`17c9529f`，共三十三筆，第一筆 `0.1.32`，size 與 IPA 相同）。

  **沒有手動建 tag。**
- 產物：`WebHTV-0.1.32-33.ipa` **25,806,175 bytes**，SHA-256
  `42fd4794273b042c9e45cd41552842b69a2da75e98ee8d40d59a941c4dc297cc`（與 GitHub 記錄的 digest 相同）。
  **下載回來驗過**：`Payload/` 只有 `WebHTVApp.app`；`com.webhtv.ios.poc` / `0.1.32` / build `33` / minimum iOS `17.0` / `UIBackgroundModes` `audio`；執行檔含 `fadeMetalIn`、`refreshPlaceholder` 與 `_moltenvk_wait_events`，不含 `RuntimePackUpdater`。
- 發布前驗證：iPad mini 模擬器逐格驗證 17H-3（17H 文件第七節）；Release device build 由本次 workflow 編譯，第一次即成功。**真機尚未驗收**；放回動畫在 iPhone 上是否仍放大，只有真機能回答。

### Release notes（實際送出的內容）

```text
WebHTV 0.1.32 (33)（未經真機驗收）

修正
- MPV 子母畫面：進入時不再閃一格黑畫面；回到 App 時不再閃黑格，畫面改以 0.15 秒淡入接回。子母畫面的來源改為影片實際的顯示範圍，讓系統放回動畫有機會正好落在影片上。

已知限制
- 系統把子母畫面放回 App 的動畫本身（先放大再縮回有黑邊的大小）由 iOS 控制，App 無法指定目標；若此版在 iPhone 上仍會放大，請錄一段螢幕錄影提供分析。
- MPV 回到 App 時仍會為了對齊聲音重新定位一次，位置可能往回數十毫秒。
```
