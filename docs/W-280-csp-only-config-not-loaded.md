# W-280 只有爬蟲站的設定檔顯示「尚未載入設定」

- 工單：W-280（CSP-ONLY-CONFIG-STATE），來自 W-266 審查 N-4（#7402）與 W-266 文件 §3.3 的觀察。
- 分支：`task/W-280`（自 origin/ios-poc `9eb73479`；Simulator 用 `774f1daf` 的 Debug 建置，和 `9eb73479` 的 iOS 程式只差一行註解）。
- 證據：`.herdr-synapse/webhtv-dev/artifacts/w280/`（`new-launch.png`、`restore-offline.png`、`https.log`、`applog-launch.txt`、驅動 `w280.sh`）；測試設定 `artifacts/w243/work/srv/w280/`。

## 1. 結論

**不需要改程式。** W-266 在 App 0.1.82 看到的「尚未載入設定」，根因和 W-271（`368a1ea9`，已在 ios-poc）修掉的是同一個。目前的 ios-poc 在「冷啟動抓遠端設定」與「從快取讀回」兩條路上，只有爬蟲站的設定檔都能正常列出站點（第 4 節）。含 type 1 站的設定檔沒有任何程式改動，行為不變。

## 2. 根因（與 W-271 同一個）

W-266 當時用的是：直接把 App 偏好設定的 `configSourceURL` 改成只有 `csp_*` 站的設定檔，再冷啟動。那些類別只在設定檔旁邊的相容包裡，App 已裝的官方包與相容包都沒有。

1. `restore()`：這個來源沒有快取的設定檔，直接返回 → `sites`、`waitingSites` 都是空的。
2. 啟動時 `refreshRemote(quiet: true)` → `load(remote:)` → `ConfigLoader.fetch`。0.1.82 的 `validate` 只用「已安裝」的包判斷，三種站都不算 → `noSupportedSites`，設定檔不寫入。
3. 接著 `refreshSpiderPack()` 雖然下載了相容包，但 `rebuildSites()` 讀不到設定檔就返回 → 畫面停在 `sites.isEmpty && needSpiderTool == 0` 的「尚未載入設定」。

W-271 讓 `ConfigLoader.validate(_:from:packs:)` 在 `noSupportedSites` 時，下載並用該設定檔自己的相容包再驗一次，通過才安裝並回傳。`fetch` 是所有遠端載入的唯一入口，所以冷啟動這條路也一起修好。W-271 的 Simulator 驗證只做了「設定頁加入網址」，本單補驗冷啟動與快取讀回。

## 3. 「是否已載入設定」的所有判斷與呼叫端（`ios/WebHTVApp/Sources/WebHTVApp.swift`，`9eb73479`）

畫面判斷只看兩個狀態：`sites` 與 `waitingSites`（`needSpiderTool`）。兩者只在 `show(_:from:)`（`:606`）裡一起設定。

| 判斷 | 位置 | 作用 |
| --- | --- | --- |
| `!officialLoaded` | `:180` | 官方包讀完前顯示轉圈 |
| `sites.isEmpty && needSpiderTool == 0` | `:182` | 「尚未載入設定」 |
| `sites.isEmpty`（且有待下載的站） | `:211` | 「需要爬蟲工具」頁 |
| `needSpiderTool > 0, !sites.isEmpty` | `:292` | 爬蟲工具橫幅 |

`show` 的呼叫端與各自的驗證：

| 呼叫端 | 何時 | 驗證 | 只有爬蟲站的設定檔 |
| --- | --- | --- | --- |
| `restore()` `:728` | 啟動，讀快取設定 | `ConfigLoader.validate(data)`（已安裝的包；W-260 起啟動時先讀相容包再列站） | 快取存在代表之前已被接受且相容包已裝 → 正常（第 4 節 `restore-offline.png`） |
| `adopt(_:config:from:)` `:646` ← `load(remote:)` `:414` | 啟動重抓、設定頁加入網址、手動重新整理 | `ConfigLoader.fetch` → `validate(_:from:packs:)`（W-271） | 正常（第 4 節 `new-launch.png`；W-271 已驗加入網址） |
| `adopt` ← `load(_ url:)` `:393` | 匯入本機檔案 | `ConfigLoader.validate(data)` | 本機檔案旁邊沒有相容包可抓；類別不在已裝的包裡時拒絕並跳出「無法載入」，屬預期行為，不是這個 bug |
| `rebuildSites()` `:598` | 官方包或相容包更新後 | `ConfigLoader.validate(data)` | 讀磁碟上已接受的設定檔，包已更新 → 正常 |

## 4. 驗證（2026-11-10，Simulator w202，iPhone，熱點網路）

測試設定 `w280/w280-test.json` 只有一個站 `csp_W280Giri`，類別只在旁邊的 `w280/spiders/manifest.json`（腳本借 AnimeGiri.js，類別名稱獨一無二）。啟動前 App 已裝的相容包是 `w271-v1`（只有 `W271Giri`），確定沒有 W280Giri。來源直接寫進偏好設定的 `configSourceURL`，這個來源沒有快取檔（W-266 的情境）。

| 情境 | 結果 | 證據 |
| --- | --- | --- |
| 冷啟動（`774f1daf` Debug 建置） | 首頁直接列出「W280 只有爬蟲站」：6 個分類、首頁 12 部。伺服器 14:36:08 依序收到設定檔 → `spiders/manifest.json` → `W280Giri.js`（W-271 的驗證下載），接著 `refreshSpiderPack` 再取一次；設定檔已寫入快取 | `new-launch.png`、`https.log`（`--- marker` 之後） |
| 關掉伺服器再冷啟動（快取讀回） | 一樣列出站點與 12 部 | `restore-offline.png` |

紅燈：這次沒有在修正前的建置上重新截到。W-266 §3.3 已在 0.1.82 觀察到現象，W-271 的 `red.log` 是同一根因的紅燈單元測試。本單第一次在 0.1.82 截的 `old-launch.png` **不能當證據**：當時共用測試憑證剛好在 14:00:52 到期，App 每個請求都是 `-1202`（`applog-launch.txt`），根本沒抓到設定檔。

另發現並已處理（環境，不在 repo）：GUI 測試共用的 TLS 憑證 `~/.cache/webhtv-dev2-gui/tls/`（W195 Test CA 2）今天到期，App 安靜地載不到設定。已在原位重發（W195 Test CA 3，到 2027-11-10，舊檔在 `tls/expired-20261110/`），w202 已信任新 CA，並在看板通知全隊（#7440）。

## 5. 回滾

只新增本文件，沒有程式改動。

## 6. 狀態

完成，待審。Ponytail：本單沒有程式 diff（只有文件），沒有可審的程式碼。
