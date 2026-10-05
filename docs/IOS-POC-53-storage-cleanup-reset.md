# IOS-POC-53：設定頁「清除無效檔案」與「初始化」

## Recovery anchor

- 目標：
  - 使用者 2026-10-05 要求在設定頁加一個按鈕，刪除已存來源、記錄、收藏以外的沒用檔案，擔心 IOS-POC-52 的修改清不到舊版本留下的無效檔案。
  - 接著再要求一個「初始化」按鈕：把剛安裝時不會有的檔案和資料夾都清光。
- 使用者選擇（AskUserQuestion）：
  - 離線下載「全部保留，只清無效殘留」；
  - 可重建資料「不清，只清無效殘留」。
- 狀態：Core 測試完成（Linux 116／116，突變 5／5）。App 端只經發布建置編譯，沒有在真機上執行。
- 下一步：隨 IOS-POC-52 一起發布。

## 1. 介面

- 設定頁新增「儲存空間」連結，指向獨立頁面 `StorageMaintenanceView`。
  - 寫成獨立頁面，是避免設定頁 body 再變大而觸發編譯器逾時（IOS-POC-49-1 的教訓）。
- **清除無效檔案：**
  - 按「掃描無效檔案」，列出每一項的檔名、原因和大小，以及總和。
  - 按「刪除這 N 項」後還要再確認一次，完成後顯示已釋放的大小。
  - 沒有找到時顯示「沒有找到無效檔案」。
- **初始化：**
  - 第一次確認列出會刪除的資料，第二次確認提醒「此動作無法復原」。
  - 執行順序：所有離線下載走唯一刪除入口（先停止傳輸）→ WebKit 網站資料、Cookie、URL 快取 → 線上字幕帳號金鑰（Keychain）→ App Support、Caches、tmp、Documents 的全部內容 → UserDefaults → `exit(0)`。
  - 結束 App 的原因：記憶體中的觀看記錄、收藏等仍會寫回檔案，只有結束程式才能保證下次啟動等同剛安裝。

## 2. 清除規則（`StorageMaintenance.invalidItems`）

| 位置 | 保留 | 列為無效 |
|---|---|---|
| Application Support | `saved-sources.json`、`WatchHistory`、`Favorites`、`OfflineMedia`、`site-health.json`、`SpiderPack`、`wang-movie.json`、已存來源與目前來源的設定快取 | 已移除來源的設定快取（base64url 檔名）、`SpiderPack-staging-*`、中斷寫入的隱藏暫存檔（`.…tmp-…`、`.dat.nosync…`）、其他本版不會寫的名稱 |
| Caches | `python-spider`、App 自己的 bundle id 資料夾、`WebKit`、`Snapshots`、`com.apple.*` | `python-selfcheck-cache`、其他名稱；`com.apple.nsurlsessiond` 裡的檔案只在沒有任何未完成下載時列出 |
| tmp | 離線下載暫存區（由下載管理器判斷）、線上字幕暫存（每次啟動已清） | 10 分鐘內沒有修改的其他項目；`CFNetworkDownload_*` 只在沒有未完成下載時列出 |
| Documents | 本版不使用，也沒有開放給「檔案」App | 全部 |
| OfflineMedia（`OfflineDownloadManager.invalidFiles`） | 每一個下載（任何狀態）與無法讀取的資料夾 | 沒有紀錄的資料夾、中斷寫入的暫存檔、已完成下載殘留的計畫、request 與 partial、沒有傳輸會接手的暫存檔 |

- 不在白名單上的名稱一律只「列出」，由使用者看過清單後才刪。即使有我沒預料到的舊檔名，也不會在沒有顯示的情況下被刪掉。
- 「未完成的下載」包括排隊、準備中、下載中、暫停、失敗。這些下載的續傳資料指向系統暫存檔，所以只要還有未完成的下載，系統暫存檔就不列出。

## 3. 驗證

- Linux `swift test` 116／116。新增 `StorageMaintenanceTests` 5 項：
  - 一套完整的安裝資料加上各種殘留：只列出殘留，刪除後保留項目都還在，10 分鐘內的暫存檔不動；
  - 沒有未完成下載時，才列出背景下載的部分檔案；
  - 初始化後四個資料夾都空了，隱藏檔也清掉；
  - 離線資料夾的殘留不包含任何下載，正在進行的下載的暫存檔保留；
  - `deleteEverything` 經由刪除入口，傳輸被取消、資料夾刪除。
- 突變 5／5 被抓到：
  - 不保留已存來源的快取；
  - 背景下載的部分檔案不檢查是否有未完成下載；
  - 拿掉 10 分鐘保護；
  - 正在進行的下載的暫存檔被列出；
  - 初始化略過隱藏檔。
- 未驗證：
  - App 端 UI 與初始化流程沒有在真機執行；
  - 真機上 App 實際有哪些舊檔案，由使用者掃描後看清單。
- Ponytail：unavailable / skipped。

## 4. Rollback

- revert 本 commit 即可。功能只在使用者按下按鈕時執行，不影響其他流程。
