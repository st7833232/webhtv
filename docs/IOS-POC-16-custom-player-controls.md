# IOS-POC-16 — 自建播放控制列

- 狀態：**方案 C 已實作。控制列本身已在模擬器上目視確認渲染正確**（截圖為證，見第十節），
  **但互動逐項測試沒有完成**——工具來回比自動隱藏視窗還長，做不到。使用者 2026-09-23 接手 UI 測試。
- **已隨 `0.1.6 (7)` 發布**（tag `ios-v0.1.6-b7`，2026-09-23），含後續三項修正：
  速度選單改為 `0.5 / 1 / 1.25 / 1.5 / 2 / 2.5 / 3`、標籤去除多餘小數、
  切換速度不再誤報「片頭…片尾…」（那個回報 closure 原本被速度與字幕選單共用，只為了強迫重繪）。
  使用者選擇方案 C，並指示**不要畫手動 PiP 按鈕**。
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

## 八、使用者的決定（2026-09-23）

**做 C，而且手動 PiP 按鈕不用畫。** 兩件事同時解決了：C 本來就拿不到
`startPictureInPicture()`，而使用者也不要那顆鈕。離開 App 自動進 PiP 不受影響。

## 九、實作（方案 C）

`AVPlayerViewController` 保留，`showsPlaybackControls = false`，控制列由
`PlayerControlBar`（SwiftUI）自己畫。

| 元件 | 實作 |
|---|---|
| 關閉 | **自己的 X。這是唯一出口** —— 10I 量過 AVKit 的 X 有效所以刪掉了下滑手勢，AVKit 控制列一關那個出口就沒了 |
| 字幕／音軌 | `MediaSelection` 非同步載 `AVMediaSelectionGroup`；**只有超過一個選項才顯示**（同 5Q 的畫質選單規則）。字幕的「關閉」是 `select(nil, in:)`，不是拿某個選項當替身 |
| 速度 | `PlaybackSession.setRate` 同時寫 `defaultRate` 與 `chosenRate`。**不能只寫 `rate`**：14B 那個觀察者只看得到非零的 `rate`，暫停時選速度會被忘掉 |
| AirPlay | `AVRoutePickerView`，公開元件直接放 |
| ±10 秒／播放暫停 | 走既有 `PlaybackSession.control()` 與新的 `seek(toSeconds:)` |
| 進度條 | 自繪。`Slider` 畫不出已緩衝區段，而那是爛線路上使用者最想看到的東西。緩衝資料來自 `loadedTimeRanges`——**IOS-POC-15 要量的 buffer-ahead 是同一份** |
| 片頭／片尾 | 5S-2 的四個操作原封不動，**現在在 bar 裡，所以跟著 bar 一起走** |
| 顯示／隱藏 | **我們自己的 `controlsVisible`**，四秒自動隱藏、每次互動重算、暫停時不隱藏。點擊用 `simultaneousGesture(TapGesture())`——10A2／10J 量過普通 SwiftUI 手勢會輸給 AVKit 底下的辨識器 |

`showsPlaybackControls = false` **在 `makeUIViewController` 與 `updateUIViewController` 都設**。
只在建立時設一次是不夠的（見下一節的實測）。

## 十、驗證狀態：建置與測試通過，視覺零驗證

| 檢查 | 結果 |
|---|---|
| 模擬器 Debug build | **BUILD SUCCEEDED** |
| `swift test --package-path ios` | **228 條，227 過**。唯一失敗是 `reportsLiveType4SitesFromProvidedConfig`，durable 紀錄已列為天氣不是門檻，與本階段無關 |
| Ponytail final-diff | 新增的每個型別與方法都有呼叫端；debug 殘留為 0 |
| **這條 bar 長什麼樣子** | **完全沒有驗過。一次都沒有。** |

### 已在模擬器上確認的（2026-09-23，wang-movie 設定、荐片來源、《交锋》第1集）

| 項目 | 結果 |
|---|---|
| **AVKit 控制列消失** | **確認**。`showsPlaybackControls = false` 生效，畫面上沒有 AVKit 的 X／AirPlay／靜音／進度條 |
| **影片播放中畫面乾淨** | **確認**。自動隱藏後整個畫面沒有任何我們畫的東西——使用者要的就是這個 |
| **控制列完整渲染** | **確認**。把 `opacity` 暫時強制成 1 拍到：X、`1×`、AirPlay、`⏪10 / ⏸ / ⏩10`、進度條（thumb 在正確位置）、`02:49 … 片頭 片尾 … 46:37`。版面與設計一致 |
| **自動隱藏會動** | **確認**（反覆觀察到畫面自己變乾淨） |
| **點擊會切換** | **確認**（bar 反覆被叫回來） |

### 沒能逐項測到的原因：工具來回比自動隱藏還長

自動隱藏是 5 秒，而模擬器控制工具每一次 tap／screenshot 的來回約 5 秒。
於是「點一下叫出 bar」→「再點某個按鈕」這種兩步操作，第二步永遠落在 bar 已經隱藏之後，
第二次點擊只會再次把 bar 叫出來。**這是工具限制，不是產品缺陷**，但它讓逐項互動測試做不到。
自動隱藏從 4 秒改為 5 秒是對齊 AVKit 並考量「關閉鈕是唯一出口」的產品決定，不是為了遷就工具。

### 另一個會坑死人的陷阱（已修正安裝流程）

本輪花了很長時間在模擬器上「觀察」這條 bar，得到一連串結論——AVKit 控制列還在、
bar 只畫得出一個 X、版面塌掉——**那些結論全部是假的**。

原因：`xcodebuild` 的產物在
`~/Library/Developer/Xcode/DerivedData/WebHTVApp-*/Build/Products/Debug-iphonesimulator/`，
而 repo 裡的 `ios/.build/out/Build/Products/Debug-iphonesimulator/WebHTVApp.app` 是
**2026-09-21 留下的舊產物**。安裝腳本挑了後者，所以每一次「重建→安裝→觀察」都是在看兩天前的 App。
`BUILD SUCCEEDED` 照樣印出來，因為建置本身確實成功了，只是寫到別處。

> **驗證前先比對 binary 的 mtime 或 SHA-256。**
> ```bash
> xcodebuild ... -showBuildSettings | grep BUILT_PRODUCTS_DIR   # 產物在哪
> xcrun simctl get_app_container <udid> <bundle-id>              # 裝的是哪一份
> ```
> 兩者的 `WebHTVApp` 必須是同一個檔。不同就是在看舊 build，任何觀察都不作數。

陷阱找出來並修正安裝路徑之後，真正的新 build 有裝進去，但當時可用的設定檔是使用者指明
**不要用來測試**的那一份，所以驗證停在這裡，沒有繼續。

### 還沒驗的，交給使用者

**最高風險先測**：

1. **關閉鈕（X）能不能關掉播放器。** 這是唯一出口——AVKit 的 X 已經不存在，10I 又刪掉了下滑手勢。
   若它壞了，使用者會被關在播放畫面裡，只能砍掉 App。**這一項不過就不要發布。**
2. **暫停時控制列不隱藏**（`timeControlStatus != .playing` 才不隱藏）。
3. **片頭／片尾四個操作**：設為目前位置／+1 秒／−1 秒／清除，以及設定後的實際跳轉。
4. `⏪10` / `⏸` / `⏩10`。
5. **進度條拖曳**（放開才 seek）與**已緩衝區段**顯示。
6. **速度選單**，以及 14A/14B 的跨集速度沿用沒有壞。
7. **字幕／音軌選單**（只有多於一個選項才會出現；這次的來源只有單軌，所以沒看到是正常的）。
8. **AirPlay**（模擬器沒有裝置可投，要真機）。
9. **PiP 自動進入**（離開 App 時）——手動 PiP 鈕依使用者指示不畫。
10. 既有行為無回歸：續播、自動播下一集、多畫質、觀看紀錄。
11. **真機一次都沒有。**

### 一個已修正的安裝陷阱

本輪稍早花了很長時間在模擬器上「觀察」，得到一連串結論——AVKit 控制列還在、bar 只畫得出一個 X、
版面塌掉——**那些全部是假的**。

`xcodebuild` 的產物在
`~/Library/Developer/Xcode/DerivedData/WebHTVApp-*/Build/Products/Debug-iphonesimulator/`，
而 repo 裡的 `ios/.build/out/Build/Products/Debug-iphonesimulator/WebHTVApp.app` 是
**2026-09-21 留下的舊產物**。安裝腳本挑了後者，所以每一次「重建→安裝→觀察」都是在看兩天前的 App。
`BUILD SUCCEEDED` 照樣印出來，因為建置本身確實成功了，只是寫到別處。

> **驗證前先比對 binary 的 SHA-256。**
> ```bash
> xcodebuild ... -showBuildSettings | grep BUILT_PRODUCTS_DIR   # 產物在哪
> xcrun simctl get_app_container <udid> <bundle-id>              # 裝的是哪一份
> ```
> 兩者的 `WebHTVApp` 必須是同一個檔。不同就是在看舊 build，任何觀察都不作數。

### 怎麼把測試環境準備好（避免用錯設定檔）

模擬器上直接餵 `.importedFile` 路徑最乾淨，不必在 UI 裡捲很長的來源清單：

```bash
xcrun simctl terminate <udid> com.webhtv.ios.poc
DATA=$(xcrun simctl get_app_container <udid> com.webhtv.ios.poc data)
rm -f "$DATA/Library/Preferences/com.webhtv.ios.poc.plist" "$DATA/Library/Application Support"/*.json
cp wang-movie.json "$DATA/Library/Application Support/wang-movie.json"
xcrun simctl launch <udid> com.webhtv.ios.poc
```

## 十一、Recovery anchor

- 目標：把 5S-2 的片頭／片尾控制從「永遠浮在影片上」移進一條自建控制列。
- 已完成：設計調查、方案比較、**方案 C 的實作**、建置與測試、**控制列渲染的模擬器目視確認**。
  互動逐項測試未完成（工具來回 > 自動隱藏視窗），已交給使用者。
- 已量測並可直接引用，不需重查：第一節那兩張 API 表、虛構方法名的對照實驗、
  `AVPlayerViewController` 無公開 start/stop PiP、`ContentSource` 在 iOS 只吃 `AVPlayerLayer`、
  `AVPlayerViewController` 不暴露 `playerLayer`、`showsPlaybackControls` 在 iOS 可用。
- 下一步（唯一）：**使用者自己做 UI 功能測試**，清單見第十節「還沒驗的，交給使用者」。
