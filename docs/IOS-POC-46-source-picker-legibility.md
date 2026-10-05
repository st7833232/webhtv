# IOS-POC-46 首頁站台名稱在淺色背景上看不見

（2026-10-05 補建。原本只記在 `docs/current-task-state.md` 與 `docs/IOS-POC-11-sidestore-release.md` 第五十七次發布，內容以兩個 commit 的訊息與 diff 為準。）

## Recovery anchor

- 狀態：**已發布、已被 IOS-UI-A2 取代。** 修正隨 `0.1.56 (57)` 發布（tag `ios-v0.1.56-b57` → `22e9cf6b`）。IOS-UI-A2（`c361c637`，`0.1.62 (63)`）重做首頁頂部，移除了兩個呼叫點，`legibleToolbarLabel()` 現在沒有任何呼叫者。
- 未決：`ios/WebHTVApp/Sources/WebHTVApp.swift` 的 `legibleToolbarLabel()` 是死碼，可刪。刪除是程式修改，等使用者決定。
- 下一步：無。原本待真機確認的項目已因 A2 不適用；A2 之後的首頁頂部可讀性屬於 IOS-UI-A 的真機驗收。

## 1. 回報與成因（2026-10-03）

- 回報：iOS 26 首頁左上角的站台名稱（來源切換按鈕）看不見。
- 成因：iOS 26 把 toolbar item 畫在 Liquid Glass 上，玻璃在淺色桌布上變淺；標籤寫死 `.foregroundStyle(.white)`，融進背景。
- 使用者補充「Ios17、18也要避免」：iOS 17／18 沒有玻璃，但白字疊在桌布 `wallpaper_1` 左上，對比只有 1.4–1.6:1。

## 2. 修正

| 任務 | commit | 內容 |
|---|---|---|
| IOS-POC-46 | `22793b988422546a4d082cd209a585c255d04042` | iOS 26 起標籤改用隨玻璃翻轉的 `.primary`；更早版本維持白色 |
| IOS-POC-46-1 | `f5419a9070f1caf012700522ecbc50391cf9e5f2` | iOS 17／18 的白字加 50% 黑色膠囊，桌布最亮處對比 5.2:1；iOS 26 分支不變。helper 改名為 `legibleToolbarLabel()` |

範圍只有 `ios/WebHTVApp/Sources/WebHTVApp.swift` 與 `docs/current-task-state.md`。之後 IOS-POC-48（`f40c31a3`）也把詳情頁的收藏按鈕接上這個 helper。

## 3. 驗證

- 已驗證：白字與加膠囊後的對比是依桌布像素計算的（1.39–1.58:1 → 5.17:1）。發布 workflow 的 unsigned device Release build 成功（run `37103927388`）。
- 未驗證：兩個 commit 當時都沒有在本機編譯，iOS 26、iOS 17／18 都沒有在模擬器或真機上看過。
- 當時的已知風險：App 全域 `tint` 是白色，其他工具列文字按鈕（例如「關閉」）在 iOS 26 淺色背景上可能有同樣問題，未處理。IOS-UI-A 換掉桌布並加入深／淺主題後，這項風險改由 IOS-UI-A 的真機驗收涵蓋。

## 4. 後續

- IOS-UI-A 第一版（`d759a346`，`0.1.61 (62)`）把全域桌布換成深色漸層。
- IOS-UI-A2（`c361c637`，`0.1.62 (63)`）把首頁頂部改成品牌與小型來源入口，詳情頁收藏改成 44pt 圖示按鈕，兩處都不再呼叫 `legibleToolbarLabel()`。

## 5. Rollback

不需要：程式行為已由 IOS-UI-A2 取代。若要刪除死碼，另開任務刪除 `legibleToolbarLabel()`，靠 device build 確認沒有其他呼叫者。
