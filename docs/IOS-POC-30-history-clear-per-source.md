# IOS-POC-30 — 觀看記錄的清除會刪到其他來源的記錄

- 狀態：**已修正並隨 `0.1.26 (27)` 發布（Release build 編譯成功）；單元測試未執行、真機未驗證。**
- 使用者回報（2026-09-26）：「觀看紀錄的刪除全部應該只刪除該來源的全部，而不會去影響其他資源的觀看紀錄。」
- 分類：quick-fix（與 Android 行為一致、設計已確立，依 AGENTS.md §7 免設計研究門檻）。

## 一、原因

1. 觀看記錄畫面只列出目前設定來源的記錄：`WatchHistoryStore.records(for: source.identity)`。
2. 「清除」按鈕卻呼叫 `WatchHistoryStore.clear()`，把所有設定來源的記錄一起刪掉。
3. 對照 Android：`HistoryAdapter` 的清除呼叫 `History.deleteAndSync(VodConfig.getCid())`，只刪目前設定來源（`origin/main` `app/src/mobile/java/com/fongmi/android/tv/ui/adapter/HistoryAdapter.java:57`）。

## 二、修正

### 1. 規則

| 操作 | 目前來源擁有的記錄 | 沒有來源的舊記錄（IOS-POC-10E 以前寫入） | 其他來源擁有的記錄 |
|---|---|---|---|
| 清除 | 刪除 | 只對目前來源隱藏 | 不動 |
| 單筆滑動刪除 | 刪除 | 只對目前來源隱藏 | 不動 |
| 之後再看同一部片 | 照常更新 | 改為目前來源擁有，隱藏標記一併清除 | 照常 |

舊記錄沒有 `sourceID`，在每個來源都會列出。刪掉它會讓其他來源的列表也少一筆，保留它又會讓剛清除的列表還看得到它，所以改為「只對目前來源隱藏」。

### 2. 程式位置

- `ios/Sources/WebHTVCore/WatchHistory.swift`
  - `WatchHistory.hiddenFrom`（`:42`）：已隱藏這筆記錄的設定來源。為 Optional，手機上既有的記錄檔照常解碼。
  - `records(for:)`（`:304`）與 `isListed`（`:308`）：略過對該來源隱藏的舊記錄。
  - `remove(key:for:)`（`:371`）：只刪目前來源擁有的記錄；舊記錄改為隱藏；其他來源擁有的記錄不動。
  - `clear(for:)`（`:392`）：同上規則套用在整個列表。`clear()`（`:381`）保留，App 已不再呼叫。
- `ios/WebHTVApp/Sources/WebHTVApp.swift` `HistoryView`：滑動刪除（`:1880`）改呼叫 `remove(key:for:)`，「清除」（`:1898`）改呼叫 `clear(for:)`。
- `ios/Sources/WebHTVCore/WebHomeBridge.swift:345`：WebHome 的 `app.history` 改為只回目前來源的列表，與 Android `HomeWebBridge.history()`（`History.get()`，目前設定來源）一致。

### 3. 測試

- `ios/Tests/WebHTVCoreTests/WatchHistoryTests.swift`：`clearingOneSourcesListLeavesEveryOtherSourcesHistory`（`:134`）、`swipingARowAwayTakesItOffThisSourcesListOnly`（`:152`）、`watchingAHiddenRecordAgainListsItUnderThatSource`（`:171`）。
- `ios/Tests/WebHTVCoreTests/WebHomeBridgeTests.swift`：`appHistoryReportsOnlyThisConfigurationsList`（`:77`）。

## 三、提交與查核

| commit | 內容 |
|---|---|
| `a52ab2ddaa57abb686f6ae49f11ed795f3504473` | 第一版：新增 `clear(for:)`，連同舊記錄一起刪除 |
| `1e8677b7c002950245adc121cb44ef31e73f759d` | 第一輪查核確認：舊記錄在每個來源都會顯示，刪除會影響其他來源。改為 `hiddenFrom` 隱藏，並把滑動刪除也改成同一規則 |
| `6f14069d5707433ffc75d846e66f0860ff77542f` | 第二輪查核確認：滑動刪除在列表稍舊時（例如子母畫面中另一來源剛存了同一部片）會刪到其他來源的記錄，補上擁有者檢查；`app.history` 改為依來源 |

- 查核方式：每輪兩個角度（正確性、編譯與測試）的對抗式查核，每項發現再由獨立代理嘗試推翻。第一輪確認 1 項、推翻 1 項；第二輪確認 3 項（其中 2 項為同一問題）、推翻 2 項。
- 本環境沒有 Swift，未編譯、單元測試未執行；隨 `0.1.26 (27)` 發布時 Release build 編譯成功。Release build 不編譯測試，測試要等有 Mac 時執行。

## 四、真機測試

| # | 步驟 | 預期 |
|---|---|---|
| T1 | 在設定來源 A 的觀看記錄按「清除」，再切到設定來源 B | A 的列表是空的；B 的記錄都還在 |
| T2 | 在 A 滑動刪除一筆舊記錄（兩個來源都看得到的那種），切到 B | 那筆在 A 消失，在 B 仍在 |
| T3 | 在 A 重新看 T2 那部片，回到 A 的觀看記錄 | 重新出現在 A |

只有一個設定來源時，T1～T3 無法區分，照常清除即可。

## 五、回滾

依序 `git revert 6f14069d 1e8677b7 a52ab2dd`。回滾後 `hiddenFrom` 欄位留在記錄檔中無害：舊版的解碼會忽略不認得的欄位。

## Recovery anchor

- 狀態（2026-09-27）：已隨 `0.1.26 (27)` 發布；單元測試未執行、真機未驗證。
- 相關檔案：`ios/Sources/WebHTVCore/WatchHistory.swift`、`ios/Sources/WebHTVCore/WebHomeBridge.swift`、`ios/WebHTVApp/Sources/WebHTVApp.swift` `HistoryView`、兩個測試檔。
- 下一步（唯一）：等使用者做第四節 T1～T3 並回報。
