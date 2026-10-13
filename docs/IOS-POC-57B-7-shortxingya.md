# IOS-POC-57B-7：星芽短剧（qist `csp_ShortXingya`）

> Recovery anchor（2026-10-13 13:50 CST）：已實作，單元測試與全測試通過（W-74，guard `QIST-SHORTXINGYA-IMPL`，`--no-tag`）。設計：`.herdr-synapse/webhtv-dev/artifacts/qist-shortxingya-gate-2026-10-12.md` D1–D6（W-61 PASS）；資料閘門 W-51 PASS；使用者 2026-10-12 已核准實作。Simulator 實播 a–h 都 PASS（`w74-gui-evidence`）。下一步：Reviewer code review。

## 來源

- JAR：qist/tvbox `spider.jar` sha256 `72a1f3928eca281d878e44fc57162ff6a1f3ef779a2da05a2b351b241b110d69`；`ShortXingya.java` 188 行，sha256 `36ea21a186288add56997620cf6e15826dc44027ec98f3c1f12731842afa82d8`。

## 改動

| 檔案 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/Resources/Spiders/ShortXingya.js`（新） | 設計 D2／D3。第一次呼叫時先登入：`POST https://u.shytkjgs.com/user/v3/account/login`，body 是裝置 JSON（欄位順序照上游，`timestamp` 用 `host.now()`）經 AES-128-ECB 加密後的 base64 字串，標頭 `platform`、`user_agent`、JSON content-type 都照上游。token 只放在 closure 變數，不寫入 storage、不寫 log、不回傳。API（`app.whjzjx.cn`）帶 `authorization`、`platform: 1`、`version_name: 3.8.3.1`。只有回應是「HTTP 200＋JSON＋`code: "ok"`」才採用；其他回應一律清掉 token，下一次呼叫會重新登入，這一次不重試（上游根本不會重登）。分類固定 5 個；tid／詳情 id 必須是數字，否則不送請求；分類 `limit 90`、`total 9999` 照上游，`is_end === true` 時 pagecount＝page；集名用 `num`（`$`／`#` 換成空白），空的就用原始位置 `i+1`；`son_video_url`／`video_url` 必須符合 `^https?://[^$#]*$`；只有 `video_url` 時線路是 `星芽`，兩者都沒有時線路是 `无播放源`；搜尋是 `POST /v3/search`，body 用 `JSON.stringify({text})`，帶 JSON content-type（N7）；播放 parse 0，帶上游原樣的 `User-Agent`（缺 `Mozilla/5.0 (` 開頭，gate 用這個值拿到 206） |
| `ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift` | `ported` 加 `ShortXingya` |
| `ios/Tests/WebHTVCoreTests/SpiderGoldenTests.swift` | 預期清單在 `ShortWeiguan` 與 `SportsGuazi` 之間加 `ShortXingya` |
| `ios/Tests/WebHTVCoreTests/ShortXingyaSpiderTests.swift`（新） | D5 的 10 個測試。fixture 用 gate 的 `category.json`（24 筆）、`detail.json`（79 集），raw deflate＋base64 內嵌並驗 sha256；登入回應用遮蔽後的結構，換上假 token。測試內容：gate 的登入 body 黃金向量（固定 `host.now()`）、標頭全值比對、只登入一次、壞輸入不送請求、詳情的各種退路、被拒時清 token 並重新登入、播放 UA、搜尋 JSON、失敗時指出是哪個主機 |
| `scripts/spider_pack.py`、`spider-pack/` | `DEFAULT_ORIGINS` 加 `ShortXingya`（`spider.jar` `72a1f392…`，只用 base host API：`host.get`／`post`／`aesEncrypt`／`now`／`result`）。相容包重建為 `2026-10-13.2`（30 支）：只新增 ShortXingya，舊 entry 全部不變；pack 與內建腳本 byte 相同（sha256 `43f1c231…eceb`）；`verify` 0 problems |

### 與設計的差異

- 設計沒寫的實作選擇（review-prep N7）：搜尋帶 `content-type: application/json; charset=utf-8`；`video_url` 和 `son_video_url` 一樣要檢查網址格式；任何不是「200＋JSON＋ok」的回應都清 token（包含 HTTP 401）。

## 驗證

| 項目 | 結果 | 證據 |
|---|---|---|
| 先紅 | 腳本已放進 Resources，但 Registry 還沒列：10 個測試全紅，而且能編譯 | `artifacts/w74-logs/red.log` |
| 後綠 | `ShortXingyaSpiderTests` 10 個＋`registryClaimsOnlyWhatIsActuallyPorted`，11/11 通過 | `green1.log` |
| Mutant | 失敗時不清 token → 2 個測試失敗；搜尋不帶 JSON content-type → 1 個失敗；`playable` 只檢查非空 → 1 個失敗。三次都已還原，sha256 `43f1c231…eceb` 與原檔一致 | `mut-*.log` |
| 全測試 | `swift test` 1147 tests／36 suites 全部通過 | `full-summary.txt` |
| 相容包 | build `2026-10-13.2`，verify 0 problems；manifest 的差異只有版本號和新增的一列 | `manifest.before.json` 對照 |
| Ponytail review | Ship，沒有 finding | — |
| Simulator 實播（iPhone 18 Pro／iOS 27.0；HEAD `50e84821`＋本單工作樹；`ShortXingya.js` `43f1c231…` 在 checkout、.app、容器三處相同） | a–h 都 PASS：選「星芽 • 短劇」才開始登入，登入與 API 都回 200 → 首頁 5 類順序正確，24 部，替代海報 0 個 → 劇場往下捲 24→32→51 → 詳情「星芽 · 60 集」→ 第 1 集原生起播，相隔 15 秒進度 00:16→00:31／01:23，stalls=0 → 第 60 集原生 00:06→00:21／02:15 → 從觀看紀錄重開，每次都重新打 detail（網址重新簽名），第 3 次從 1:17 續播，原生 01:30→01:44 → 搜「真千金」80 筆，點進去「星芽 · 70 集」，伺服器接受 JSON 搜尋。媒體是 `qcapp.xingya.com.cn` 明文 HTTP，只有 ATS 警告、沒有錯誤；applog 裡 `authorization` 0 行，`token` 只出現在系統元件。還原：App 1571 個檔、Library 17 個檔都 BYTE-IDENTICAL | `artifacts/w74-gui-evidence/RESULT.md` `407c1436…2831` |

### 實播觀察（不是本單要修的範圍）

- 從觀看紀錄第 1 次續播（0:32）卡住：原生 10 秒沒起播，自動改 MPV 後停在 00:33。同一集從頭播、播放中快轉、第 2／3 次續播都正常，當時網址只取得 1 分鐘，所以不是網址失效。原因沒查出來，已交 Manager 決定要不要開單。
- 同一個 App 程序登入了兩次（點分類時），兩次之間沒有失敗的回應。推測是 App 為分類另外建立了 spider 實例，每個實例各有自己記憶體裡的 token；功能正常。
- 分類各頁內容會重疊（第 2 頁只多 8 部），第 4 頁起沒有新片；App 用 id 去重，所以畫面沒有重複。這是站方回應，上游一樣。
- 沒拿到 `ShortXingya type: js path: Spiders` 這行 log。改以三點間接證明是 JS 版：設定列是 `csp_ShortXingya`、測前的舊 App 沒有這支腳本、三處 hash 相同。
- 還原時為了讓 bundle 目錄名回到原樣做了一次 `simctl uninstall`，所以 data 容器裡的 `Documents/`、`tmp/`、`SystemData/` 是重新建立的空目錄。備份只有 `Library/`（作法和 W-87b 相同），這三個目錄測前有沒有內容無法證明。

## 未驗證

- 實機；新劇／熱播／星選／陽光四個分類沒有在 GUI 點開（單元測試只有手寫回應）；第 1 集總長沒有和 API 的 `video_time` 對照；token 的有效期與失效時的回應格式；寫死的裝置資料被站方封鎖時整個來源都會失效（設計 D6）；4 小時網址到期是 App 既有限制。

## 回滾

一個 commit；`git revert` 會移除 adapter、Registry 那一行、測試與相容包那一列，不影響其他來源。
