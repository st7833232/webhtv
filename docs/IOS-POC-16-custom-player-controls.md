# IOS-POC-16 — 自建播放控制列

- 狀態：**計畫，未實作。** 依 AGENTS §7，未經使用者明確核准不得動程式碼。
- 基線 HEAD `38df1710`（2026-09-23）
- Lane：`standard`（實作時）；本文件本身是 `assessment`
- 起因：IOS-POC-5S-2 把片頭／片尾控制放在影片上，使用者要求移到調整 Bar、不要直接出現在影片上。

## 一、為什麼需要這個階段：兩件被證明做不到的事

動手前先量，不猜 API。以下全部對著 **iOS 27 SDK 的 `AVPlayerViewController.h`** 讀出來。

### 1. AVKit 的 transport bar 在 iOS 無法插入

| API | 可用平台 |
|---|---|
| `transportBarCustomMenuItems` | `API_AVAILABLE(tvos(15.0))` **`API_UNAVAILABLE(ios)`** |
| `customOverlayViewController` | `API_AVAILABLE(tvos(13.0))` **`API_UNAVAILABLE(ios)`** |
| `contextualActions` | `tvos(15.0)`, `visionos(1.0)` **`API_UNAVAILABLE(ios)`** |
| `infoViewActions` | `tvos(15.0)`, `visionos(1.0)` **`API_UNAVAILABLE(ios)`** |
| `transportBarIncludesTitleView` | `tvos(15.0)` **`API_UNAVAILABLE(ios)`** |

Apple 的自訂入口全部只給 tvOS／visionOS。**這不是「比較難」，是不存在。**

### 2. iOS 無法得知 AVKit 控制列何時顯示

這一條推翻了一份既有文件，必須寫清楚。

`docs/IOS-POC-10-plan-ux-and-sources.md` 的 10A 記載：關閉鈕改用
`playerViewController(_:willTransitionToVisibilityOfPlaybackControls:with:)`，稱其為「**公開 API**」，
並說「計時器、切換邏輯全部刪掉——按鈕不可能再相位相反」。

**那個方法不存在。** 協定裡真正的方法是：

```objc
- (void)playerViewController:(AVPlayerViewController *)playerViewController
    willTransitionToVisibilityOfTransportBar:(BOOL)visible
                    withAnimationCoordinator:(id<AVPlayerViewControllerAnimationCoordinator>)coordinator
    API_AVAILABLE(tvos(11.0)) API_UNAVAILABLE(ios, watchos, macCatalyst, visionos);
```

名稱是 `...VisibilityOfTransportBar`（不是 `...VisibilityOfPlaybackControls`），而且**也是 tvOS 專用**。
`AVPlayerViewControllerDelegate` 在 iOS 上沒有任何控制列可見度回呼。

**10A 的「編譯通過」不構成證據。** 對照實驗：

```swift
func playerViewController(_ c: AVPlayerViewController,
                          willTransitionToVisibilityOfCompletelyMadeUpThing isVisible: Bool,
                          with coordinator: UIViewControllerTransitionCoordinator) {}
```

這個**完全虛構**的方法名同樣 `swiftc -typecheck -target arm64-apple-ios17.0` 通過。原因：
`AVPlayerViewControllerDelegate` 的成員全是 ObjC `@optional`，所以在遵循型別上多寫一個不相干的方法
是合法的 Swift，編譯器沒有理由抱怨。**AVKit 永遠不會呼叫它。**

因果鏈因此是：方法不存在 → 協定要求全 optional，不報錯 → delegate 永不觸發 →
`chromeVisible` 永遠停在初始的 `true` → 關閉鈕永遠留在影片上。

**使用者 2026-09-23 的實測回報正是如此**：「原本的 X 鈕還是會一直出現在影片上，並沒有隨著控制列消失
跟著一起消失，是我看到控制列有才決定拿掉。」10H 把它當成「使用者不想要那顆鈕」而刪除，
**真正的原因是那個機制從來沒有運作過**。10A 自己也寫了「還沒有真的看著它淡出」——
那句話就是缺口，只是沒有人回頭補。

> **給未來的人：** 不要因為 Swift 編譯通過就相信一個 delegate 方法會被呼叫。
> 對著 header 確認它真的屬於該協定、且在目標平台可用。

## 二、現有實作（實作前的 code review）

| 位置 | 現況 |
|---|---|
| `PlayerSurface`（`WebHTVApp.swift`） | `UIViewControllerRepresentable` 包 `AVPlayerViewController`，控制列是 AVKit 自己的 |
| `PlayerSurface.Coordinator` | PiP delegate ＋ **2026-09-23 才落地的 foreground-restore 修正**，真機未驗 |
| `PlayerView` | 手勢：水平拖曳＝快轉、左半垂直＝亮度、右半垂直＝音量，共用一個 HUD readout |
| `PlayerView.skipControls` | IOS-POC-5S-2 的片頭／片尾，右側邊緣垂直置中，**永遠可見**——本階段要解決的就是這個 |
| `PlaybackSession` | 整個 App 生命週期一個 `AVPlayer`，`status()` 給毫秒 position/duration，`control()`、`chosenRate`（14A/14B）、五秒取樣器、`finished()`／`advance` |
| `WatchHistory.opening/ending` | 5S-2，資料層不需要改 |

**資料與播放邏輯完全不用動。** 本階段只換「控制列由誰畫」。

## 三、方案比較

### A. 不改

片頭／片尾繼續永遠浮在影片上。**使用者已明確拒絕。**

### B. 照 Apple 原樣做（用 AVKit 自己的 bar）

**不可能。** 見第一節，iOS 沒有插入點。列在這裡是因為 AGENTS §7 要求比較「未修改的上游做法」——
結論是這條路在本平台不存在，不是被評估後放棄。

### C. 自建控制列，蓋在 `AVPlayerViewController` 上（**建議**）

`showsPlaybackControls = false`（`API_UNAVAILABLE(watchos)`，**iOS 可用**），AVKit 只負責畫面與
播放管線，控制列由 SwiftUI 自己畫、自己決定何時顯示。

- **保留**：`AVPlayerViewController` 與整個 `PlayerSurface`／`Coordinator`，含 2026-09-23 那個 PiP 修正。
- **保留**：離開 App 自動進 PiP（`canStartPictureInPictureAutomaticallyFromInline`，是 controller 屬性，
  不是控制列功能）—— **需實測確認關掉控制列後仍然有效**。
- **失去**：**手動 PiP 按鈕**。`AVPlayerViewController` **沒有**公開的 `startPictureInPicture()`；
  那顆鈕是 AVKit 控制列給的，控制列關掉就沒了。
- AirPlay 用 `AVRoutePickerView`（公開）自己放一顆。

### D. 自建控制列，改用 `AVPlayerLayer` ＋ `AVPictureInPictureController`

- **取回**手動 PiP 按鈕：`AVPictureInPictureController` 有公開的 `startPictureInPicture()`
  **與 `stopPictureInPicture()`**。
- **順帶可能根治 PiP 缺陷**：`docs/bugs/IOS-PIP-foreground-restore.md` 現行修法的註解寫著
  「`AVPlayerViewController` has no public `stopPictureInPicture()`」，只好用「把
  `allowsPictureInPicturePlayback` 關掉再開」的迂迴。**改用 `AVPictureInPictureController` 就有正牌 API。**
  ⚠️ 這是**推論，不是實測**；該缺陷本身至今未在真機驗證過，不得宣稱已修。
- **代價**：丟掉 `AVPlayerViewController`，2026-09-23 的修正與其三條測試一併作廢或重寫；
  PiP 生命週期、還原、音訊路由等系統整合全部變成我們自己的責任。
- `AVPictureInPictureControllerContentSource` 在 iOS 只能由 `AVPlayerLayer` 建立，而
  `AVPlayerViewController` **不暴露**自己的 layer，所以 C 無法升級成 D，只能整段換掉。

### 建議

**先做 C。** 理由：它把改動限制在「控制列由誰畫」這一件事，資料層與播放層一行不動，
剛落地的 PiP 修正原封不動，而且**可用一個 flag 回滾**（`showsPlaybackControls` 改回 `true`、
移除自建 bar）。D 是把播放介面整個換掉，在 PiP 缺陷尚未真機驗證的此刻同時做，
會讓「哪個改動造成哪個行為」無法歸因。

**D 保留為獨立的後續決策**，觸發條件是：手動 PiP 鈕的缺席在實機上真的造成困擾，
或 PiP 缺陷的真機驗證顯示現行迂迴解無效。

## 四、C 的範圍

自建 bar 必須涵蓋 AVKit 原本給的東西，少一樣就是回歸：

| 元件 | 來源 | 備註 |
|---|---|---|
| 進度條（含已緩衝區段） | `addPeriodicTimeObserver`、`currentItem.duration`、`loadedTimeRanges` | 緩衝區段與 **IOS-POC-15** 要量的 buffer-ahead 是同一份資料 |
| 播放／暫停、±10 秒 | `PlaybackSession.control()` 既有 | 不新增播放狀態 |
| 時間標示（已播／總長） | `status()` 既有毫秒 | 沿用 5S-2 的 `clock()` |
| 速度選單 | `player.defaultRate`／`rate` | **必須接上 `chosenRate`（14A/14B）**，否則跨集速度記憶會回歸 |
| 字幕／音軌選單 | `AVMediaSelectionGroup` | 14 已決定不跨集沿用，但選單本身要在 |
| AirPlay | `AVRoutePickerView` | 公開元件，直接放 |
| **片頭／片尾** | 5S-2 既有的 `markOpening`／`setOpening`／`markEnding`／`setEnding` | **本階段的目的**；四個操作不改 |
| 自動隱藏 | 自己計時 | 這次是我們自己的狀態，不是猜 AVKit 的 |
| 關閉播放器 | 既有下滑手勢（10H） | AVKit 的 X 會一起消失，所以出口只剩手勢——**需確認仍可用** |
| 無障礙 | VoiceOver 標籤、動態字體 | AGENTS「不可簡化掉無障礙基本功能」 |

**不在範圍**：章節、A/V 同步調整、音訊增強、手勢改動（seek／音量／亮度維持 10J 現狀）、
MPV、IOS-POC-15 的緩衝調校。

## 五、風險

1. **AVKit 手勢衝突。** 10A2 與 10J 都踩過：AVKit 的辨識器在下層 UIKit view，普通 SwiftUI 手勢會輸。
   控制列關掉後這層是否還在、`simultaneousGesture` 是否仍必要，**需實測**。
2. **關閉出口。** AVKit 的 X 隨控制列一起消失；10H 的下滑手勢變成唯一出口，必須確認它仍運作，
   否則使用者會被關在播放畫面裡。**這是本階段最高風險項。**
3. **手動 PiP 鈕消失**（已知且刻意，見上）。
4. **鎖定畫面／控制中心** 的 now-playing 資訊由 `MPNowPlayingInfoCenter` 決定，不是控制列，
   理論上不受影響——**需實測**。
5. **速度記憶回歸**：`chosenRate` 是靠觀察 `player.rate` 抓的（14B 量測結果），自建速度選單若直接寫
   `rate` 會與那個觀察者互動，**必須測 14A/14B 的跨集速度沿用沒有壞掉**。

## 六、驗收標準

1. 片頭／片尾控制**只在自建控制列顯示時出現**，控制列隱藏時影片上沒有任何我們畫的東西。
2. 第四節表格每一列都能操作，且行為與 AVKit 原本一致或更好。
3. 播放器**關得掉**。
4. 既有行為零回歸：續播、片頭片尾、自動播下一集（14）、跨集速度（14A/14B）、
   多畫質（5Q）、`app.history`、觀看紀錄、PiP 自動進入。
5. `swift test` 不低於基線（現為 228／227 過，那 1 條是 live provider 的天氣）。
6. 模擬器 build 成功。
7. **真機驗證**：控制列顯示／隱藏、片頭片尾四個操作、關閉、PiP、速度、字幕。

## 七、回滾

單一 commit，`git revert` 即可。另有 flag 級回滾：`showsPlaybackControls` 改回 `true`
並移除自建 bar 的 overlay，AVKit 原本的控制列立刻回來——因為 C **沒有動播放管線**，
`AVPlayerViewController`、`PlaybackSession`、`WatchHistory` 都還在原位。

## 八、待使用者決定

**手動 PiP 按鈕的缺席可以接受嗎？**

- 可以接受 → 直接做 C。
- 不能接受 → 改做 D（取回按鈕、可能根治 PiP 缺陷，但整個播放介面換掉、剛落地的修正作廢）。

在收到答覆前**不動任何程式碼**。

## 九、Recovery anchor

- 目標：把 5S-2 的片頭／片尾控制從「永遠浮在影片上」移進一條自建控制列。
- 已完成：本文件（設計調查＋方案比較＋建議）。**零程式碼變更。**
- 已量測並可直接引用，不需重查：第一節那兩張 API 表、虛構方法名的對照實驗、
  `AVPlayerViewController` 無公開 start/stop PiP、`ContentSource` 在 iOS 只吃 `AVPlayerLayer`、
  `AVPlayerViewController` 不暴露 `playerLayer`、`showsPlaybackControls` 在 iOS 可用。
- 下一步（唯一）：取得第八節的答覆，然後依 C 或 D 開 `standard` lane 實作。
