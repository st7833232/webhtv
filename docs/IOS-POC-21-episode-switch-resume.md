# IOS-POC-21 — 切換集數時不再跳到上一集的位置

- 狀態：**已修正並在模擬器驗證**（2026-09-24）；`6c348650`，已於 2026-09-24 以 `0.1.13 (14)` 發布；真機未驗證。
- 使用者回報（2026-09-24，原文）：「有一條BUG，當播放器播到一半切換到別的集數，他會直接跳轉到上個集數看的位置；同部影片在切換集數應該重頭來，但是不能去影響別的劇」。
- Lane：`quick-fix`。範圍：`ios/Sources/WebHTVCore/WatchHistory.swift`、`ios/Tests/WebHTVCoreTests/WatchHistoryTests.swift`、`ios/WebHTVApp/Sources/WebHTVApp.swift`、本文件、`docs/current-task-state.md`。

## 根因

- 觀看記錄一部作品只有一筆（`WatchHistory.key`＝站台＋片 id），裡面的 `position` 屬於它記的那一集（`vodRemarks`）。
- `PlaybackSession.open(url:…)` 開播前把存著的那筆併進新建的記錄時，**無條件**複製 `position`／`duration`
  （`WebHTVApp.swift` 原 1906-1913 行）。從詳情頁手動點另一集走的是預設的 `resuming: true`，
  於是新的一集被 seek 到上一集停下的地方。只有自動下一集（IOS-POC-14）傳 `resuming: false` 才避開。
- 其他開始位置來源都查過：`selectQuality` 用的是同一集目前的位置（正確）；`PlaybackTarget.position` 是畫質選單的索引，不是時間。
  所以所有開播路徑都經過這一個合併點。

## 修正

- `WatchHistory.carryingOver(from:)`（Core）：片頭／片尾屬於整部作品，一律沿用；**只有新的一集和記錄裡那一集同名（不分大小寫）時**才沿用位置與長度，
  否則從頭開始（仍會套用片頭略過）。這是 Android `VideoActivity.updateHistory` 的規則（`Episode.matchesName`），
  所以同一集換線路仍會接著看。
- `PlaybackSession.open(url:…)` 改用它。其他作品的記錄是各自獨立的 key，不受影響。
- ponytail 限制（已寫在程式註解）：以名稱判斷，同一條線路若有兩個同名項目會共用位置；改用網址判斷會讓每次抓取網址都變的來源失去續播。

## 驗證

| 檢查 | 結果 | 等級 |
|---|---|---|
| `swift test --package-path ios` | **351／351**（新增 4 條：換集從頭開始但保留片頭略過、同一集續播、同一集換線路續播、片頭片尾跟著作品） | 單元 |
| Simulator Debug build（iPhone 17 Pro） | BUILD SUCCEEDED | 模擬器 |
| 荐片「交锋」：記錄是第1集 544.9 秒 → 點第2集 | 第2集 16:33:56 開始播，16:36:37 存的位置是 161.1 秒＝**從 0 開始**（修正前會跳到約 9:05） | 模擬器 |
| 關掉（第2集 231.5 秒）後再點第2集 | 16:38:26 開始，16:38:47 位置 250 秒＝**接著上次的位置** | 模擬器 |
| 其他作品不受影響 | 記錄以作品為 key，程式沒有動到其他作品的讀寫；未另外實測 | 靜態 |
| 真機 | — | **未驗證** |

- 測試時暫時把 `PlayerChrome.autoHideSeconds` 改成 60（模擬器工具一次來回比 5 秒自動隱藏長），測完已還原並重新 build；
  iPhone 17 Pro 模擬器 App 容器的偏好設定與 `Application Support`（含觀看記錄）測前備份、測後還原。

## 回滾

`git revert` 本 commit：回到換集會沿用上一集位置的行為。

## Recovery anchor

- 目前：已修正、模擬器驗證完成，`0.1.13 (14)` 發布。
- 下一步（唯一）：使用者更新到 `0.1.13 (14)` 後，在真機確認換集從頭播、同一集回來會續播。（2026-09-25 更正：使用者已更新到 `0.1.20 (21)`（目前最新，同樣含本修正），真機確認仍未回報。）
