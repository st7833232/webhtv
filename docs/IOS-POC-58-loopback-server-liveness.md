# IOS-POC-58：本機播放伺服器失效時自動重開

## Recovery anchor

- 目標：使用者 2026-10-09 回報，SideStore 重新簽署之後離線影片無法播放：MPV 顯示 `mpv error -13`（`MPV_ERROR_LOADING_FAILED`），換 AVPlayer 也一樣，退出 App 重開就好。使用者 2026-10-11「實作」。
- 狀態：已實作。只在 Apple 平台編譯，雲端以語法檢查與模擬的 Network 模組做型別檢查；macOS 測試沒有執行；真機未驗證。
- 已隨 `0.1.73 (74)` 發布（run `38128728510`，tag `ios-v0.1.73-b74`），發布建置是第一次以真正的 SDK 編譯，成功。
- 下一步：使用者在真機確認（App 在背景待久之後回來播放離線影片）；本機 session 可補跑 macOS 測試。

## 1. 判斷

- 兩個播放器都讀不到，表示是來源出問題，與播放器無關；退出重開就好，表示下載的檔案沒有壞，問題在同一個 App 程序內的狀態。
- 已排除：檔案路徑寫死（紀錄與播放清單都是相對路徑，每次啟動依當下 App 資料夾組出位置）、片段以 symlink 指向舊位置（沒有 symlink）。
- 最可能的原因：App 在背景被暫停後，iOS 收回本機伺服器的連接埠，但 `NWListener` 仍回報 `.ready`。`start()` 看到 `.ready` 就直接交出原本的位址，所以之後每次播放都拿到失效的位址，直到 App 重開。
  - Apple TN2277：App 被暫停時，系統可能收回 listening socket，回前景應重開。
  - IOS-POC-52-8 查到 Quinn 的說法：沒註冊 Bonjour 的 `NWListener` 通常不會失效。與使用者的現象不符，所以不依賴「它會自己回報失敗」。
- 未驗證：沒有在真機上抓到 listener 的實際狀態；以上是依現象與文件的推論。

## 2. 做法

- `OfflineMediaServer.start()`：listener 回報 `.ready` 時，先用 `answers(port:)` 對自己送一個 `HEAD /` 請求（沒有 token，伺服器會回 400；任何 `HTTP/1.` 回應都算有回應），最多等 3 秒。
  - 有回應：照舊交出原本的位址。
  - 沒有回應、連線被拒或逾時：丟掉這個 listener，在另一個連接埠重開（同一個 port 約 1 分鐘內無法重用，FB8658821），寫一行 log `[offline] server stopped answering: reopening`。
- 新的位址：
  - 新開的一集直接用新位址（`OfflineDownloads.playbackSource` 每次都經過 `start()`）。
  - 已載入、暫停中的那一集，在 App 回前景重新載入或鎖定畫面播放時，沿用 IOS-POC-52-11（F12）的 `rebased(to:)` 換到新 port。
- `isAnswering` 是內部可替換的檢查函式，只給測試用。

## 3. 驗證

- Linux：
  - `swiftc -parse` 語法檢查通過；
  - 另建一個模擬的 Network 模組，在 Swift 6 嚴格並行模式下對 `OfflineMediaServer.swift` 做型別檢查，編譯通過。模擬模組的 API 與 Sendable 標註不一定與 Apple 完全相同，只是輔助。
  - 既有 Linux 測試不受影響（這個檔案在 Linux 不編譯）。
- macOS 測試（新增，**未執行**）：`OfflineMediaServerTests.aServerThatStopsAnsweringIsReopenedOnAnotherPort`：
  - 真的檢查能分辨有在聽的 port 與沒有東西在聽的 port（port 1）；
  - 檢查判定沒有回應時，在另一個 port 重開，同一個 token 下仍能取得檔案；再呼叫一次 `start()` 時回傳同一個新位址。
- 發布建置會實際編譯伺服器程式。
- 未驗證：真機上的實際情境（App 在背景待久、去 SideStore 重新簽署後回來播放）。
- Ponytail：unavailable / skipped（此 runtime 沒有 Ponytail）。

## 4. 風險

- 每次 `start()` 多一個本機請求，正常時只要幾毫秒；伺服器真的失效時，最多多等 3 秒才重開。
- 如果伺服器正在大量傳送片段而 3 秒內沒回應，會被誤判並換 port；正在串流的項目要靠重新載入才會換到新 port。實際上本機回應一個空的 400 遠低於 3 秒。

## 5. Rollback

- revert 本 commit。沒有資料格式變更。
