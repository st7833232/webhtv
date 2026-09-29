# IOS-POC-35 — 播放器的上一集／下一集，與詳情頁的「立即播放」

- 狀態：**已實作，模擬器驗證通過（2026-09-29）；尚未發布，真機未驗證。**
- 使用者要求（2026-09-29）：「幫我在播放器加上上一集、下一集按鈕，然後在選擇線路的畫面加上立即播放。若是第一次觀看的就是選擇第一個線路的第一集播放，若有觀看就是從上次觀看的線路跟進度繼續播放。」
- 使用者的選擇（2026-09-29）：按鈕只寫「立即播放」，不加說明；在第一集／最後一集時上一集／下一集按鈕變灰、不能按；鎖定畫面與控制中心的上一首／下一首這次不做。

## 一、研究

| 來源 | 內容 | 影響 |
|---|---|---|
| Android `VideoActivity`（`origin/main` `5856232743d2b8ddd5b3730e676b197ff2c0a264`，`app/src/mobile/java/com/fongmi/android/tv/ui/activity/VideoActivity.java`） | `checkNext()`／`checkPrev()` 以 `getAdjacentEpisode(±1)` 換到同一條線路的相鄰一集；已在端點時影片模式跳出「已經是最後一集了！」／「已經是第一集了！」（`values-zh-rTW` `error_play_next`／`error_play_prev`），音訊模式的按鈕以 `setEnabled(hasPrev/hasNext)` 變灰（`updateAudioStageControls`） | 相鄰一集、同一條線路；端點依使用者選擇採「變灰」 |
| 同檔 `onItemClick` 附近（約 4480-4492 行） | 換集前 `updatePlaybackHistoryPosition()` 存好目前這集的進度；新的一集 `setPosition(C.TIME_UNSET)`，從頭播 | 換集前先 `persist()`；新的一集 `resuming: false`（片頭照樣跳過） |
| 同檔 `seamless`、約 1605、1616 行 | 進詳情時以歷史的集數名稱（`flag.find(history.getVodRemarks())`）找回上次那一集並直接播放 | 「立即播放」以線路名稱＋集數比對；線路不存在時在第一條線路以集數名稱找 |
| Apple Human Interface Guidelines — Playing video（developer.apple.com/design/human-interface-guidelines/playing-video，2026-09-29 未重新讀取） | — | 未讀取原文，不作為依據；本設計只依 Android 與 WebHTV 既有的控制列慣例（48 pt 觸控範圍、無障礙標籤） |
| WebHTV 現有程式 | `VodView.play(_:flag:)` 經 `Playback.start()` → `PlaybackSession.open(resuming: true)`，由 `WatchHistory.carryingOver` 以集數名稱接回進度（IOS-POC-21）；`VodView.start(_:flag:usingPrefetch:)` 是自動下一集的換集路徑（IOS-POC-14／15C，可用預先解析的網址）；`Flag.episode(after:)` 以網址找下一集；控制列 `PlayerControlBar.transport` 目前是 ⟲10／播放／⟳10；`PlaybackSession.onNotice` 顯示提示 | 全部重用，不新增播放路徑 |

## 二、方案

| 方案 | 內容 | 結論 |
|---|---|---|
| 不改 | — | 否（使用者要求） |
| 照 Android：進詳情就自動播放 | 開詳情頁直接播上次那一集 | 否：使用者要的是一個按鈕，詳情頁仍要能選集 |
| **WebHTV：詳情頁按鈕＋控制列兩個按鈕，重用既有換集與續播路徑**（實施） | 見第三節 | 實施 |

## 三、行為

### 1. 立即播放（詳情頁，線路列上方）

1. 有觀看記錄、上次的線路還在：播那條線路上次那一集（先以網址比對，找不到再以集數名稱比對），從記錄的進度接著播；那一集不在了就播那條線路第一個可播的集數。
2. 有觀看記錄、上次的線路不在了：在第一條有可播集數的線路以集數名稱找；找不到就播它的第一個可播集數。
3. 沒有觀看記錄：第一條有可播集數的線路的第一個可播集數。
4. 「可播」與集數格相同：網址是 http(s)（`Episode.mediaURL != nil`）。解析中與集數格一樣停用。
5. 進度由既有的 `PlaybackSession.open(resuming: true)` 決定：同一集（集數名稱相同）才接回進度，片頭照舊跳過。

### 2. 上一集／下一集（播放器控制列）

1. 排列：`⏮ ⟲10 ⏯ ⟳10 ⏭`；按鈕間距由 36 pt 縮為 20 pt，直向 402 pt 寬的螢幕放得下；觸控範圍維持 48 pt。
2. 只有從詳情頁播放時才出現（`PlaybackSession` 有換集的處理者）；WebHome 的內嵌播放清單與單一網址不出現。
3. 同一條線路的相鄰一集（`Flag.episode(after:)`，新增 `episode(before:)`，都以網址比對）；沒有上一集／下一集時按鈕變灰、不能按，VoiceOver 讀「上一集」「下一集」與「無法使用」。
4. 按下後：先存好目前這集的進度（`persist()`），再以自動下一集的同一條路徑開始（`start(_:flag:usingPrefetch:)`，下一集可用預先解析的網址），新的一集從頭播（有片頭就跳過）。換集進行中兩個按鈕都停用。
5. 解析失敗：保留目前這集繼續播，顯示「上一集無法播放」／「下一集無法播放」。
6. 速度沿用（同一部片，IOS-POC-14B）；畫質沿用記錄。

## 四、驗收標準

1. 單元測試：`Flag.episode(before:)`（第一集沒有、重複網址取第一次出現）；「立即播放」的選集規則（第三節之一的 1～4，含線路改名、集數消失、全部不可播）。`swift test` 全部通過。
2. 模擬器（本機測試站，五集的測試片）：
   - 沒有記錄時按「立即播放」播第 1 集（A）。
   - 播 C 一段時間後關閉，再按「立即播放」回到 C、從剛才的位置接著播。
   - 在 A 時「上一集」變灰；按「下一集」到 B，從頭播；在 E 時「下一集」變灰；在 C 按「上一集」回到 B。
   - 換集後觀看記錄指向新的一集。
3. 真機：未驗證（使用者以 SideStore 測）。

## 五、實作與驗證（2026-09-29）

1. `ios/Sources/WebHTVCore/CMSClient.swift`：`Flag.episode(before:)`、`Flag.playNow(in:watchedFlag:watchedURL:watchedName:)`。
2. `ios/WebHTVApp/Sources/WebHTVApp.swift`：
   - `PlaybackSession`：`episodeStepper`、`episodeSteps`（新的 `EpisodeSteps`）、`steppingEpisode`、`stepEpisode(forward:)`（先 `persist()`，失敗時 `onNotice` 顯示「上一集無法播放」／「下一集無法播放」）。
   - `VodView`：「立即播放」按鈕（白底、深色文字：App 的強調色是白色，第一版的白字在白底上看不見，模擬器截圖時發現並修正）；`step(forward:flag:)`、`publishEpisodeSteps(flag:)`、`playNow(_:)`；`play` 與 `start` 更新 `episodeSteps`；關閉播放器時清掉處理者；`start` 多一個 `liveReason`，讓上一集的 log 寫 `live, previous episode` 而不是「重試」。
   - `PlayerView`／`PlayerControlBar`：每 0.25 秒讀 `episodeSteps`；控制列加 ⏮／⏭（`backward.end.fill`／`forward.end.fill`，間距 20 pt，沒有時變灰並 `disabled`）。
3. `swift test`：**537 個全部通過**（新增 8 個：`episode(before:)` 2 個、`PlayNowTests` 6 個）。
4. 模擬器（iPhone 17 Pro iOS 26.3、本機測試站；因為控制工具一次來回 5～10 秒，比 5 秒自動隱藏長，測試時暫時把 `PlayerChrome.autoHideSeconds` 改為 60 秒建置，測完原始碼已還原，未 commit；最後裝回的是正式設定的 build）：

   | # | 步驟 | 結果 |
   |---|---|---|
   | T1 | 沒有觀看記錄，按「立即播放」 | 播 A（第一條線路第一集），從 0 秒開始；⏮ 變灰、⏭ 可按 |
   | T2 | ⏭ | 換到 B，從頭播（畫面 00:13 時條碼 13.44 秒）；⏮、⏭ 都可按 |
   | T3 | ⏭，再 ⏮ | C → 回到 B（log `live, previous episode` 修正前顯示為重試標籤） |
   | T4 | B 播約 20 秒後關閉 | 觀看記錄：線路 `local`、B、49,282 ms；詳情頁 B 標為上次觀看 |
   | T5 | 按「立即播放」 | 回到 B，從記錄的進度接著播（幾秒後畫面 00:53） |
   | T6 | ⏭ 三次到 E | C（用了預先解析的網址 `resolve 0ms (prefetched)`）→ D → E；在 E 時 ⏭ 變灰 |

5. 未驗證：解析失敗時的提示（本機測試站不會失敗）；MPV 上的操作（換集走同一條 `start` 路徑，未另外測）；VoiceOver；橫向版面；真機。

## 六、回滾

revert 本任務的 commit。沒有設定開關：兩個功能都只增加入口，不改既有的集數格與自動下一集。

## Recovery anchor

- 目標：播放器上一集／下一集按鈕；詳情頁「立即播放」（第三節）。
- 狀態（2026-09-29）：已實作，單元測試 537 個通過，模擬器 T1～T6 通過（第五節）；尚未發布、真機未驗證。
- 相關檔案：`ios/WebHTVApp/Sources/WebHTVApp.swift`（`VodView`、`PlaybackSession`、`PlayerControlBar`、`PlayerView`）、`ios/Sources/WebHTVCore/CMSClient.swift`（`Flag`）、`ios/Tests/WebHTVCoreTests/CMSClientTests.swift`。
- 下一步（唯一）：等使用者決定是否發布含本任務與 IOS-POC-25-4／25-5 的新版本，或回報真機結果。
