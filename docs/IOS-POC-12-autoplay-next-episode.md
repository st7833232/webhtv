# IOS-POC-12A — 一集播完自動播下一集，整條線播完就關閉播放器

- 狀態：**已實作**，尚未有人在 App 裡看著它發生。
- 基線 HEAD `7b7ad584`
- 來源：使用者 2026-09-22 回報「當該集播完應該要自動播放下一集；如果全部播完，可以返回關閉播放器」

## 根因：不是沒寫，是清單從來沒交出去

`PlaybackSession.finished()` **本來就會**續播：

```swift
if looping { control("replay") } else { start(at: index + 1) }
```

但 `start(at:)` 第一行是 `guard items.indices.contains(index) else { return }`，而 App 自己的播放路徑走的是
`open(url:headers:title:artwork:history:)`——**只交出一個已解析的位址**：

```swift
items = [.init(name: "", url: url)]
```

所以 `index + 1` 永遠不存在，續播靜靜地什麼也沒做。**WebHome bridge 那條路（`open(_ vod:)`）反而早就會續播**，
因為它交的是整個 inline 播放清單。

### 為什麼不能比照 bridge 一次交出整季

站台的每一集要經過 `playerContent` 呼叫、可能還要 sniff，才會變成一個位址。
一次解析整季既慢又會對 provider 打出一堆沒人要的請求。
所以**清單留在詳情頁，播放器用問的**。

## 做法：兩個 optional closure，不造第二套播放狀態

| 新增 | 位置 | 作用 |
|---|---|---|
| `PlaybackSession.advance: (() async -> Bool)?` | app | 「這一集完了，還有下一集嗎？」`true` 代表已經開始播下一集 |
| `PlaybackSession.onPlaylistFinished: (() -> Void)?` | app | 沒有下一集了，請關閉播放器 |
| `Flag.episode(after:)` | **core** | 純規則，所以測得到 |

`finished()` 的新順序：inline 播放清單優先（bridge 那條路**完全不變**）→ 問 `advance` → 都沒有就通知關閉。

`PlaybackSession` **依然不知道**站台、線路、或一集怎麼變成位址。詳情頁 `VodView` 擁有這些，所以由它回答。

### 三個刻意的決定

**1. 以位址比對下一集，不是用名稱或索引。** 這份設定檔裡有把多集併在一行的來源，
同一個標籤會印兩次（IOS-POC-8J）；而呼叫端持有的索引在播放器問過來的時候可能已經過期。
位址才是真正識別「現在在播什麼」的東西。

**2. 自動續播不 resume。** `WatchHistory.key` 是「站台＋影片」，**一整部片共用一筆記錄**，
不是每集一筆。所以直接沿用會把新的一集 seek 到上一集停的位置。
`open(..., resuming: false)` 明確表示「這是新的一集，不是重開這部片」。
near-ending 規則通常會蓋掉這個問題，但**一個沒有 duration 的來源就不會**。

**3. 解析失敗也回 `false`。** 那會關閉播放器。停在一集解不出來的黑畫面上，看起來就是當掉。

### 順帶修掉一個既有的競態

`finished()` 原本寫著「Record the end before moving on」，但程式是
`Task { @MainActor in await persist() }` 後**沒有等**就往下走。
註解宣稱的順序與程式碼不符，而且自 IOS-POC-12A 起，緊接著就會有人去讀那份記錄（resume 查詢）。
現在整段在同一個 `Task` 裡依序執行。

## 生命週期

- 選單關閉（取消，或改用外部播放器）→ 清掉 `advance` 與 `playingEpisode`。
- 播放器關閉 → 清掉 `onPlaylistFinished`。

外部播放器透過 URL scheme 開啟，**沒有回程**，所以它本來就不會有自動續播——這與 WatchHistory
只記錄內建播放器（IOS-POC-5R K6）是同一個限制。

## 驗證

| 檢查 | 結果 |
|---|---|
| `NextEpisodeTests`（新增 6 條，core） | 全過：下一集、最後一集回 nil、單集線、不屬於這條線的一集、**重複名稱不混淆**、空清單 |
| 全套 | **203 條，1 條失敗**——`completesLiveCMSFlowFromProvidedConfig` 遇到 provider 的 TLS 暫時性錯誤（`-1200`）。**`curl` 當場回 HTTP 200，單獨重跑該測試也通過**，所以是網路天氣不是迴歸 |
| 模擬器 build | BUILD SUCCEEDED |

## 尚未驗證

**沒有人看著一集播完自動接下一集，也沒有人看著整條線播完後播放器關閉。** 上面全部是單元測試
與 build 證據。核心規則（下一集是哪一集）有測試釘住，但「播放器真的接上去了」只有程式碼證據。
真機或模擬器的目視確認仍然欠著。

## 回滾

單一 commit，`git revert` 即可。`advance` 與 `onPlaylistFinished` 都是 optional，設成 nil
就回到原本「播完就停」的行為。
