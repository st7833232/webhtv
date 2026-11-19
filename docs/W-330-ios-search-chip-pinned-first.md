# W-330 搜尋站台晶片：自訂順序的站優先，其餘依回應先後

- 分支 `task/W-330`，從 ios-poc `28399b99`（0.1.107 發版 commit）開。只提交、不推送。
- 證據在 `.herdr-synapse/webhtv-dev/artifacts/w330/`（不進 git）。

## 1. 需求

搜尋結果上方的晶片列：「全部」→ 使用者在「站點順序與搜尋」排過的站（依使用者順序，有結果才出現）→ 其餘依回應先後。使用者點過晶片、捲動結果或橫向捲晶片列之後，已顯示的晶片不再移動，晚到的接在最後。「全部」與單站清單內容、合併卡、略過、關站都不變。

原本：`groups` 依回應先後 append，晶片列直接照 `groups` 排。

## 2. 做法

- Core `SiteOrder.chips(_:site:key:pinned:kept:)`：
  - 沒凍結：已排站照使用者順序在前，其餘照回應先後（stable sort）。
  - 凍結後：凍結當下已顯示的晶片照當時的規則順序保留在前；之後才到的（包含已排站）**一律照回應先後接在最後**。晚到的已排站不會插到其他晚到晶片前面，否則已顯示的晚到晶片會被推開。
- `AggregateSearchView`：
  - 搜尋開始時記下該倉的已排站 `pinnedSites`（與發問順序用同一份）。
  - `frozenChips`（凍結當下的晶片 index）：在既有的 `freeze()`（點晶片、點卡片、捲動結果）設定。晶片列新增「橫向捲動超過 8 pt 也呼叫 `freeze()`」，用既有的 `onGeometryChange` 寫法，支援 iOS 16。
  - 「有 N 筆新結果，點這裡重新排序」會同時把晶片重排，因為這是使用者主動要求重排。
  - `clear()` 清掉凍結。
- 「全部」清單、單站清單、合併卡、略過、關站都沒動。

## 3. 驗證

- Core：`swift test` 1622 項全過（`swift-test.log`）。`chipsPutPinnedSitesFirstAndKeepTheirPlacesOnceTouched` 測三種情況：
  - 已排站依使用者順序在前、其餘依回應先後。
  - 凍結後晚到的已排站接尾、不插隊。
  - 凍結後先到的一般站不會被後到的已排站推開。
- App：Simulator Debug 建置成功（`app-build.log`）。
- Simulator（2026-11-19 15:40–16:15，webhtv-w308，熱點 172.20.10.1）：設定 `https://raw.githubusercontent.com/st7833232/recha/bb69e04c4ad38d867cfb9826f5581bbc002badd1/wang-movie.json`，GitHub recha `main` = `bb69e04c4ad38d867cfb9826f5581bbc002badd1`（`recha-main-sha.txt`）。截圖與 log 在 `sim/`。

| 驗收項目 | 結果 | 證據（`sim/`） |
|---|---|---|
| 已排站在前、依使用者順序 | 已排 [洛雪TV, 王子]：王子 0.8 s 先回、洛雪TV 3.0 s 才回，晶片仍是「全部 → 洛雪TV → 王子」 | `q4a.png`、`q3-search.log` |
| 其餘依回應先後 | 接著 bilbil、bili漫畫屋、bili聽書趣、bili靜聽歌、YouTube，與 log 回應順序一致 | `q5a.png`、`q5-end.png`、`q3-search.log` |
| 沒結果的站不顯示 | 已排的 搜TV啦 這次沒結果，晶片列沒有它 | `q2a.png`、`q1-search.log` |
| 點晶片後晚到的已排站不插隊（修正前的建置） | 已排 [洛雪TV, 圍觀短劇]，在 5/51 時點 bili靜聽歌；之後才回的 圍觀短劇 排在凍結當下的 5 個晶片之後，沒有插到選中晶片旁邊 | `g2b.png`、`g3a.png`–`g3-end.png`、`g2-search.log` |
| 同一輪發現的問題 → 已修 | 同一輪 愛看機器人（2.4 s）比 圍觀短劇（3.2 s）早到、已經顯示，卻被晚到的已排站排到後面，已顯示的晶片移動了。改成凍結後晚到的一律依回應先後接尾，並加上單元測試 | `g3-end.png`、`SiteOrderTests` |
| 修正後重跑 | 試了 3 輪（已排站換成 圍觀短劇、七貓短劇、艾旦），探針每步約 1–2 秒延遲，已排站都在點晶片前就回來了，沒抓到「凍結後已排站才到」的時機；這幾輪都顯示已排站在前（`h1b`、`k1b`、`m1b`） | `h1b.png`、`k1b.png`、`m1b.png` |

- 已排站的設定方式：在「站點順序與搜尋」用拖曳把 王子 排到最前（`s2a.png`）。之後幾輪改已排站時直接寫偏好 `webhtv.siteOrder`（模擬器關機時改，與拖曳存的格式相同），原因是：清單在一般模式下長按拖曳也會排序，用拖曳捲動清單會誤排其他站（`s2-end.png`）。拖曳排序本身已在 W-317／W-322 驗過。
- 這輪 `g2` 的搜尋欄因清除失敗變成「庆余年庆余年」，不影響晶片排序的判斷。
- 收尾：Simulator 偏好整份換回測試前（`prefs-before.plist`：`https://127.0.0.1:18448/wang-sex.json`、沒有自訂順序）並關機；App 建置與探針資料夾已刪。

## 4. Ponytail

`ponytail:ponytail-review` 審全部差異：Ship。查過以下各點，都沒有問題：
- 重試略過的站時，新一批的 index 接在後面；凍結時接尾，沒凍結時已排站在前。
- 點回「全部」時仍維持凍結。
- 「重新排序」會一起重排晶片，這是使用者主動的動作。
- 晶片列只有 `groups` 不為空時才出現。

上面 Simulator 抓到的「已顯示的晚到晶片被推開」已修正並補測試。

## 5. 沒驗到的

- 修正後的「凍結後已排站才到」在 Simulator 沒抓到時機，只有單元測試；修正前的建置有畫面證據證明不會插到前面。
- 真機。
