# IOS-POC-14 — 一集播完自動播下一集，整條線播完就關閉播放器

> **Superseded by dual internal-player decision, 2026-09-23** — for every mention of third-party players here (Infuse / Fileball / SenPlayer / VidHub, URL-scheme handoff, "external player"): they were removed from the product; WebHTV plays only with its own AVPlayer and MPV engines. See `docs/IOS-POC-17-dual-internal-player.md`. The rest of this record stands as written.

- 狀態：**已實作**，尚未有人在 App 裡看著它發生。（2026-09-25 更正：使用者在 `0.1.20 (21)` 真機驗收 IOS-POC-23 T10（片尾前約 30 秒暫停、鎖螢幕 60 秒、回來播放）時回報「仍會自動播下一集」，見 `docs/IOS-POC-23-pause-background-resume-stall.md` 第十二節；「整條線播完關閉播放器」與 14A 換集沿用速度仍未在真機確認。）
- **編號更正**：本階段原先寫成 `IOS-POC-12A`，與 `docs/IOS-POC-12-13-runtime-update-roadmap.md`
  已經佔用的 12／13 相撞。實作的 commit message 仍寫著 `IOS-POC-12A`——commit 訊息不改寫，
  這一行就是兩者的對照。
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
註解宣稱的順序與程式碼不符，而且自 IOS-POC-14 起，緊接著就會有人去讀那份記錄（resume 查詢）。
現在整段在同一個 `Task` 裡依序執行。

## 生命週期

- 選單關閉（取消，或改用外部播放器）→ 清掉 `advance` 與 `playingEpisode`。
- 播放器關閉 → 清掉 `onPlaylistFinished`。

（2026-09-25 更正：IOS-POC-17C 起沒有選單頁，外部播放器也已移除；`advance`、`playingEpisode` 與 `onPlaylistFinished` 現在都在關閉播放器時，由 `VodView` 的 `fullScreenCover(item:onDismiss:)` 一起清掉（`ios/WebHTVApp/Sources/WebHTVApp.swift:1519-1528`）。）

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
真機或模擬器的目視確認仍然欠著。（2026-09-25 更正：自動接下一集已在 `0.1.20 (21)` 真機看到，見文首狀態；整條線播完關閉播放器仍未確認。）

## 回滾

單一 commit，`git revert` 即可。`advance` 與 `onPlaylistFinished` 都是 optional，設成 nil
就回到原本「播完就停」的行為。

---

# IOS-POC-14A — 換集後沿用播放速度

使用者測完自動續播後回報：**在原本那一集用 2 倍速，換到新的一集卻回到 1 倍。**

## 先量一個決定性事實，不猜

```
after setting defaultRate=2 : 2.0  rate: 0.0
after replaceCurrentItem    : 2.0  rate: 0.0
after play()                : 2.0  rate: 2.0
```

**`defaultRate` 不會被 `replaceCurrentItem` 重置，而且 `play()` 會照它跑。**

這條量測直接推翻了最直覺的假設：如果 AVKit 的速度選單設的是 `defaultRate`，速度**本來就會**沿用，
使用者也就不會看到 1 倍。所以 **AVKit 設的是 `rate`，不是 `defaultRate`**。

## 為什麼要用「播放中最後一個非零 rate」

選定的速度只有在**有東西正在播**的時候看得到，而且它只存在於 `rate`。
而一集播完時 `AVPlayer` 早已把 `rate` 歸零——**等到要開下一集才去讀，一定讀到 0**。

所以唯一抓得到的地方是觀察 `rate` 本身：KVO，記住最後一個大於 0 的值。
暫停（`rate` 變 0）不會覆蓋掉記住的速度。

換集時：`replaceCurrentItem` → **先設 `defaultRate`** → `play()`。
先設才會讓新的一集**一開始就是**那個速度，而不是先 1 倍再被修正一下。
`play()` 之後再對正在跑的 player 明講一次 `rate`，因為 AVKit 有可能直接動 `rate`。

## 範圍：只在同一部片內（IOS-POC-14B 收窄）

第一版讓速度跨**整個 App 生命週期**沿用，也就是開一部新片也會是 2 倍。
使用者看到文件裡那一段之後直接指定：**只要同一部片內沿用**。已收窄。

判斷依據是 `WatchHistory.key`——站台加影片，正好就是「同一部片或同一部劇」這個身分：

| 情境 | 速度 |
|---|---|
| 自動接下一集 | **沿用** |
| 在同一部片裡手動點另一集 | **沿用**（同一個 key，與自動續播一致） |
| 打開另一部片 | **回到 1 倍**（IOS-POC-29 起改為回到設定頁的「預設播放速度」，未設定時仍是 1 倍） |
| 沒有 key 的播放（bridge 的 `player.playUrl`、inline 播放清單） | **回到 1 倍**——沒有「哪一部片」可以歸屬（IOS-POC-29 起同樣改為預設播放速度） |

用身分比對而不是用程式路徑判斷，是因為手動點下一集走的是跟開新片同一條路；
只看路徑會把「同一部片的第 5 集」誤判成新片。

## 沒有一起沿用的東西，以及原因

**字幕與音軌選擇沒有沿用。** 那是 AVKit 對「那一個 asset」的選擇，
下一集是不同的 asset，軌道的編號與語言標記不保證對得上——硬套過去會選到錯的軌，
比回到預設更糟。這是刻意不做，不是漏掉。

音量與亮度是系統層級的，本來就不隨 item 變。

## 驗證

| 檢查 | 結果 |
|---|---|
| `defaultRate` 在換 item 後是否保留、`play()` 是否照用 | **實測：都是** |
| 全套 | **203 條，全過** |
| 模擬器 build | BUILD SUCCEEDED |

**沒有驗到的：沒有人看著 2 倍速真的跟著換到下一集。** 這一段全在 App target，
沒有測試宿主，而且要驗它必須有一個真的在播的來源、在 AVKit 自己的選單裡改速度、再等一集播完。
上面的量測證明了機制（`defaultRate` 會被 `play()` 採用），
但「AVKit 設的確實是 `rate`、而 KVO 確實抓得到」只有推論與程式碼證據。
**這一項請在實機上確認。**
（2026-09-25 更正：IOS-POC-16 起 AVKit 的速度選單已不存在，速度改由自建控制列經 `PlaybackSession.setRate` 寫入 `chosenRate`，再由 `AVPlayerEngine.setRate` 寫入 `defaultRate`（`ios/WebHTVApp/Sources/WebHTVApp.swift:2310-2313`、`:3034-3036`），不再依賴「AVKit 設的是 `rate`」這個推論；換集沿用速度本身仍未在真機確認。）

## 換站台會重置速度——使用者 2026-09-22 決定暫不修改

「一部片」的身分是 `WatchHistory.key`，也就是 `Site.id + "@@@" + vodId`，**含站台**。
直接後果：**同一部片換到另一個來源站台，速度會回到 1 倍**（IOS-POC-29 起改為回到設定頁的「預設播放速度」，未設定時仍是 1 倍）。

使用者問過這個邊界的定義，確認後回覆「先這樣暫不修改」。**這是決定，不是遺漏。**

- 沿用：自動接下一集、同一部片手動點另一集、**換線路**（key 不含線路）。
- 重置：另一部片、**同一部片換站台**、沒有 key 的播放（bridge 裸網址、inline 清單）。

要改的話只有一個動作：把判斷從 `key`（站台＋影片）換成只看 `vodId`。
**代價是兩個不同站台的同名影片會被當成同一部**——這份設定檔有四個重複的站台 key（IOS-POC-5L），
所以那不是假想的風險。觀看進度本來就是按站台分開記的，速度跟著同一個身分走才是一致的。
