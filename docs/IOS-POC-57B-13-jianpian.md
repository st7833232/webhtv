# IOS-POC-57B-13：荐片（qist 0825 `csp_Jianpian`）alias 到 JianPian

> Recovery anchor（2026-10-13 17:50 CST）：已實作，單元測試與全測試通過（W-104，guard `QIST-JIANPIAN-ALIAS`，`--no-tag`）。閘門 W-99 GO：`.herdr-synapse/webhtv-dev/artifacts/qist-Jianpian-gate-2026-10-13.md`；審查預備 `review-prep-W-104-2026-10-13.md`。使用者「先把爬蟲工具補齊」視同核准。Simulator 6 項 PASS（見「驗證」）。下一步：Reviewer code review。

## 決定

0825 的站設定是 `{"key":"荐片弹幕版","name":"荐片","type":3,"api":"csp_Jianpian",…,"ext":"./json/jianpian.json$$$1"}`。它自己的舊 API 主機已經 404；它的列表參數和篩選 id 在 JianPian.js 用的新 API 上可以用（閘門 W-99）。所以不另寫 adapter，改成 alias 到既有的 `JianPian.js`，只在 JS 加兩處相容。

## 改動

| 檔案 | 內容 |
|---|---|
| `SpiderRegistry.swift` | `ported` 加 `"Jianpian"`，附依據的註解；單行的 `aliases` 加 `"Jianpian": "JianPian"`，其他 7 對逐字保留。audit 腳本的 `registry_names()` 讀得到（`True JianPian`） |
| `JianPian.js`（2 行） | ① `init`：`cfg.ext = String(extend \|\| '').split('$$$')[0]`。0825 的 ext 結尾 `$$$1` 是彈幕開關；不含 `$$$` 的 ext 結果和原本完全相同，ext 裡單個 `$` 也原樣保留。② 一般分類：`sort=` 用 `query.sort \|\| query.by \|\| ''`，`sort` 優先。只給 `sort` 或兩者都沒有時和原本相同；短劇（67）維持 `'update'`。`CLASSES` 沒動（不加 `0`） |
| `JianpianAliasTests.swift`（新） | T1：不經過 Bundle，直接檢查 `ported`／`aliases`，並對每個 ported 名稱做分大小寫的檔名比對。T3：0825 的站用 `ConfigSource.remote(…/0825.json)` 解析，`resolvedExtend` 是 `…/json/jianpian.json$$$1`，script 和 `csp_JianPian` 相同。T4：用純 JS 的 `__http` 檢查 `init` 抓篩選檔時不帶 `$$$1`，無尾巴、含單個 `$` 的 ext 都原樣送出。T5：`sort`／`by` 的三種組合與短劇 |
| `SpiderGoldenTests.swift` | 黃金清單在 `"JianPian"` 和 `"Jpys"` 之間加 `"Jianpian"` |
| `scripts/spider_pack.py`、`spider-pack/` | JS 改了，所以相容包重建為 `2026-10-13.6`，只改 `JianPian` 那一列。pack alias 加上 `"Jianpian"`：裝了新包的舊 App 也能透過包驅動 `csp_Jianpian`，兩個荐片站跑同一份 pack 腳本（review-prep R2）。pack 與內建 byte 相同（sha256 `c01b6b0d…cd4b`）；verify 0 problems |

## 少掉的功能（不是完整等價）

- **彈幕**：iOS 沒有彈幕，0825 ext 的 `$$$1` 會被忽略；片源不受影響。
- `ftp_list` 不接（iOS 沒有 ftp 播放）。
- 0825 舊版的 `vod_id` 形狀和 JianPian.js 不同，但這站在 iOS 從來沒能用過，沒有舊的收藏或觀看紀錄要遷移。閘門對「新舊 id 是同一套」的說法是推論。
- `by` 的值（`hot`／`updata`／`rating`）新 API 認不認，單元測試只能證明請求帶了 `sort=hot`，實際效果看 GUI。

## 驗證

| 項目 | 結果 | 證據 |
|---|---|---|
| 先紅 | 4 個新測試都紅（ported／alias 不存在、`csp_Jianpian` 沒有 script）；`resolvedExtend` 那條斷言一開始就綠，證實 `$$$1` 會原樣留在解析後的 ext | `artifacts/w104-logs/red.log` |
| 後綠 | JianpianAlias 4 個＋Registry 測試＋既有 jianPian 測試，8/8 | `green.log` |
| Mutant（review-prep §4） | M1 拿掉 alias：T1 紅，`registryClaimsOnlyWhatIsActuallyPorted` 也紅，代表 Bundle 查資源本身分大小寫，B1 陷阱在測試環境抓得到；M2 拿掉 ported、M3 改成 `by` 優先、M4 不認 `by`、M5 取 `[1]`、M6 用單個 `$` 切、M7 不去尾，全部變紅。全部還原，sha256 與原檔一致 | `mut-*.log` |
| 全測試 | `swift test` 1171 tests／39 suites 全部通過 | `full-summary.txt` |
| 相容包 | `2026-10-13.6` verify 0 problems；manifest 只改版本號與 JianPian 一列 | `manifest.before.json` 對照 |
| Ponytail review | Ship，沒有 finding | — |
| Simulator（iPhone 18 Pro／iOS 27，BC4948DD） | 6 項 PASS：0825 設定選「荐片」後打到 JianPian.js 的亂數子網域，舊主機 `api2.rinhome.com` 0 次；電影、電視劇各 15 部；篩選列（地區／年份／排序）出現；地區「中國香港」有效；排序「評分」有效，「熱門」和預設結果相同，分不出是預設就是熱門還是參數被忽略；只有 5 個分類、沒閃退；《霸王別姬》原生 2831ms 起播，00:07 → 00:21、stalls=0。容器還原 BYTE-IDENTICAL。17:36–17:38 主 session 曾交錯操作，判定以 agent 自己的截圖為準（RESULT §3） | `.herdr-synapse/webhtv-dev/artifacts/w104-gui-evidence/RESULT.md`（sha256 `c48fd5fb…134a`） |

沒驗到：篩選檔網址不帶 `$$$1` 只有單元測試和「篩選列有出現」間接證明（App 不記請求路徑）；既有 JianPian／JPianAmns 站沒做 GUI 回歸；實機沒測。

## 回滾

一個 commit；`git revert` 會拿掉 alias、ported 那一行、JS 兩處相容、測試與相容包的變動。
