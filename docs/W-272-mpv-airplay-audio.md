# W-272 MPV 播放時用 AirPlay 投聲音

工單 W-272（Manager #7216／#7218，使用者 11-10 要求）。分支 `task/W-272`，自 `origin/ios-poc` b168c4eb。
Reviewer 預審重點：webhtv-dev-codex-reviewer-2 #7224（6 點，本文逐點回應）。

## Recovery anchor

- 目標：MPV 播放時控制列也有 AirPlay；選了 AirPlay 喇叭或 Apple TV 後，聲音從那裡出，畫面留在手機，影音同步可接受。原生播放器的 AirPlay（含影片投放）完全不變。不做 MPV 影片投放。
- 狀態：**階段 1 設計，等 Reviewer 核准**。還沒改程式。
- 下一步：Reviewer 核准後照第五節實作（階段 2）。

## 一、現況（origin/ios-poc b168c4eb）

| 位置 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/PlaybackEngine.swift:28` | `supportsAirPlay: Bool { self == .native }`，註解寫「MPV's AirPlay Audio remains a later stage」（IOS-POC-17 第十四節 P7）。 |
| `ios/WebHTVApp/Sources/WebHTVApp.swift:8190` | 控制列唯一的使用處：`if engine.supportsAirPlay { RoutePickerButton() }`。`RoutePickerButton`（:8937 起）包一個 `AVRoutePickerView`，沒有設定任何屬性。 |
| `WebHTVApp.swift:55`、`:6867 activateAudioSession()` | 工作階段由 App 管：`.playback`／`.moviePlayback`、沒有 options；每次開始播放都重新啟用（IOS-POC-23／24）。 |
| `ios/WebHTVApp/Sources/MPVEngine.swift:552` | 設 `audiounit-skip-session-management`、`avfoundation-skip-session-management`（WebHTV patch `third_party/mpv-ios/patches/libmpv/0004-ao-app-owned-audio-session.patch`）：mpv 的 ao **不碰** category、options、active。 |
| `MPVEngine.swift`（全檔） | 沒有指定 `ao`，所以用 mpv 驅動清單的第一個：`audiounit`（mpv `audio/out/ao.c` 的 `audio_out_drivers[]`，`audiounit` 排在 `avfoundation` 前）。整個 App 沒有監聽 `AVAudioSession.routeChangeNotification`。 |
| 原生 | AVPlayer 自己處理 AirPlay：Apple TV 會投影片（`isExternalPlaybackActive`，`WebHTVApp.swift:7119`、`:7295`），喇叭走 AVPlayer 的加強緩衝。本單不碰。 |

## 二、研究證據

完整引文、網址、等級在 `.herdr-synapse/webhtv-dev/artifacts/w272/research-airplay.md`（2026-11-10 讀取）。mpv 原始碼是我們打包的版本：tag v0.41.0、commit `41f6a645068483470267271e1d09966ca3b9f413`（`third_party/mpv-ios-lock.json`），加上 WebHTV patch 0004。

| # | 結論 | 來源（等級） |
|---|---|---|
| E1 | `ao_audiounit` 在 **`start()`** 讀 `[AVAudioSession outputLatency]` 存到 `device_latency`（`audio/out/ao_audiounit.m` L221-229），render callback 把它加進這批聲音的播放時間（L97-99），mpv 的影音同步因此會把畫面延後同樣的量。**只在 `start()` 讀**：聲音持續播放時不會更新，也沒有監聽路由變更。 | mpv 原始碼（A），我已自己核對 |
| E2 | `ao_audiounit` 沒有 `set_pause`（`.reset = stop`、`.start = start`）。`audio/out/buffer.c` `ao_set_paused()` 對沒有 `set_pause` 的 ao：暫停呼叫 `driver->reset()`、取消暫停呼叫 `driver->start()`（L447-451）；拖動或重新開始也走 `driver->start()`（L380、L589、L679）。**所以每次暫停→繼續、每次拖動，都會重讀 `outputLatency`。** | mpv 原始碼（A），已核對 |
| E3 | Apple `outputLatency` 文件：「Using an AirPlay-enabled device for your audio content can result in a 2-second delay.」但**沒有**寫這個屬性一定回 AirPlay 的值、或路由變更後何時更新。 | Apple 文件（A）；沒找到的部分標明 |
| E4 | AirPlay 2 加強緩衝只給 AVPlayer／AVQueuePlayer，以及 AVSampleBufferAudioRenderer＋RenderSynchronizer。其他 API 是「real-time stream」，喇叭端幾秒緩衝。RemoteIO（`ao_audiounit`）走 real-time 這條是推論，Apple 沒點名。 | Apple「Supporting AirPlay in your app」（A）、WWDC17 509 第三方逐字稿（B/C） |
| E5 | `routeChangeNotification` 在任何輸出增減時送出，**在背景執行緒**；原因碼沒有 AirPlay 專用的，`currentRoute.outputs` 的 `.airPlay` port 可辨識。Apple 沒有寫「路由變更後重讀 outputLatency 來重新同步」，這是工程判斷。 | Apple 文件（A）、WebKit bug 209789（C） |
| E6 | `AVRoutePickerView` 預設就列出可收聲音的 AirPlay 裝置；`prioritizesVideoDevices` 預設 false，只影響排序與圖示。不用改設定。 | Apple 文件（A） |
| E7 | `ao_avfoundation`：靠 synchronizer 的時鐘，本身不加裝置延遲；輸出設定變更時 `stop`→`start` 並記「this will cause desync」。仍開著的問題：#14483（變速時聲音延遲）、#15014（靜音延遲）、#18461（結尾少一段）、暫停相關 PR #18788／#18390。 | mpv 原始碼與 issue（A/C） |
| E8 | `ao-reload` 存在，但 `input.rst` 寫明「Undocumented commands … (experimental/internal)」；它拆掉重建 ao 並做一次 refresh seek，會有聽得到的中斷。 | mpv 原始碼與文件（A） |
| E9 | mpv 沒有 iOS AirPlay 延遲的 issue／PR。macOS #4141 有人量到 AirPlay 約 −2000 ms 不同步（coreaudio ao，0.41.0 仍可重現）。 | mpv issue（C） |

**研究檔的更正**：研究檔第 0、2 節說 mpv 會把工作階段設成 `MixWithOthers`、因此和 long-form policy 衝突。那是上游 mpv 的行為；WebHTV 的 patch 0004 加了 `skip-session-management`，`init_audiounit` 不再設 category／options／active（patch 第 116-131 行）。WebHTV 播 MPV 時的工作階段就是 App 設的 `.playback`／`.moviePlayback`、沒有 options，和原生相同。

## 三、方案比較（AGENTS §7）

| 方案 | 做法 | 好處 | 問題 | 結論 |
|---|---|---|---|---|
| A 不改 | MPV 時不顯示 AirPlay | 零風險 | 使用者要求的功能沒有；只能從控制中心切，切了也沒有同步處理 | 不採用 |
| B 上游做法：只開放 picker | `supportsAirPlay` 對 MPV 也回 true | 一行；聲音確實會跟著系統路由走（RemoteIO 跟隨工作階段路由） | E1：**播放中**切到 AirPlay 時 `device_latency` 停在本機值（約幾十 ms），AirPlay 的延遲（E3 文件寫約 2 秒）沒被算進同步，聲音會比畫面慢，直到使用者自己暫停或拖動一次（E2）才會對上。AirPlay 斷線時 MPV 繼續從手機喇叭大聲播 | 不採用（同步不可接受） |
| **C WebHTV 調整版（建議）** | B ＋ MPV 監聽 `routeChangeNotification`：播放中路由有變就送一次「暫停→繼續」，讓 `ao_audiounit` 重新 `start()`、重讀 `outputLatency`（E2）；AirPlay 斷線（`oldDeviceUnavailable` 且舊路由有 `.airPlay`）時改成停在暫停 | 用 mpv 既有的重讀時機，不改 libmpv、不換 ao、不碰工作階段；中斷只是一次暫停→繼續（比 `ao-reload` 的拆掉重建＋refresh seek 小，E8）；斷線不會突然從手機外放 | 依賴 `outputLatency` 在收到通知時**已經**是 AirPlay 的值（E3／E5 文件沒保證，要實機確認）；real-time AirPlay 本身的延遲仍在，只是畫面跟著延後，所以按下播放到出聲會多約 2 秒 | **採用** |
| D 改用 `ao=avfoundation` | 設 `ao=avfoundation`，用 AVSampleBufferAudioRenderer | Apple 列名的加強緩衝 API（E4）；延遲由 synchronizer 處理 | 換掉**所有** MPV 播放的音訊輸出，不只 AirPlay；E7 的開放問題（變速、靜音、結尾、暫停）會直接影響現有 MPV 播放；輸出變更時會記 desync；我們的 patch 0004 對它也有作用，但它在 WebHTV 從沒被測過 | 不採用：回歸風險遠大於本單收益。若 C 的實機結果不能接受，再另開單評估 |
| E `ao-reload` 取代暫停→繼續 | 路由變更時送 `ao-reload` | 一定重新初始化 | 實驗性內部指令（E8）、聽得到的中斷、refresh seek 會讓畫面跳 | 不採用；保留為 C 實機失敗時的備案 |

## 四、對 Reviewer #7224 六點的回應

1. **怎麼放寬、原生不變**：`supportsAirPlay` 改成兩個 engine 都回 true（保留屬性，控制列與測試照舊用它）。原生路徑一行都不動：`RoutePickerButton` 本來就是同一顆。
2. **工作階段**：不動 `activateAudioSession`、不動 patch 0004、不改 category／mode／options／policy。路由監聽只呼叫 mpv 的 `pause` 屬性，不呼叫任何 `AVAudioSession` setter。
3. **同步證據**：E1、E2 是我們打包版本的原始碼（已逐行核對）。結論：mpv **會**把 `outputLatency` 算進同步，但**只在 `start()` 讀**；路由切換時不會自己更新 → 方案 C 補上這個時機。與 avfoundation 的比較在方案 D。
4. **路由切換情境**：
   - 播放中選 AirPlay：重新同步（暫停→繼續）。
   - 暫停中選 AirPlay：不做事；使用者按播放時 mpv 本來就會 `start()` 重讀（E2）。
   - AirPlay 斷線：停在暫停。這是設計選擇（避免斷線後突然從手機喇叭外放），不是 Apple 的規定；只限舊路由有 `.airPlay`，耳機拔掉的現有行為不在本單範圍，不改。
   - 播放中切 engine：MPV→原生，AVPlayer 照它原本的 AirPlay 行為（Apple TV 會投影片），本單不改；原生→MPV，若當時路由仍是 AirPlay，MPV 的 ao 第一次 `start()` 就讀到 AirPlay 延遲，不需要特別處理（AVPlayer 拆掉後路由會不會回到本機沒有證據，列入第七節）。
   - PiP：MPV 的 PiP 只換畫面輸出（IOS-POC-17H），聲音路徑相同，規則一樣適用。
   - 背景播放：通知在背景照樣送；暫停→繼續在背景也一樣有效。
   - 通知在背景執行緒（E5）：轉到 MPVEngine 現有的 mpv 佇列處理，不在通知執行緒上碰 mpv handle。
5. **§7 三方案**：第三節（A、B、C，另比較 D、E）。驗收與回退見第五、六節。
6. **Simulator 驗不到的**：第七節列明；實機交 IPA（SideStore 流程）由使用者測。

## 五、階段 2 實作（核准後）

- `PlaybackEngine.swift`：`supportsAirPlay` 兩者皆 true，註解改寫。
- 純邏輯（WebHTVCore，可單元測試）：`MPVAudioRoute.response(reason:previousHasAirPlay:currentHasAirPlay:paused:) -> .none | .resync | .pause`。
  - `paused` → `.none`；`oldDeviceUnavailable` 且 `previousHasAirPlay` 且現在沒有 → `.pause`；`newDeviceAvailable`、`oldDeviceUnavailable`、`override`、`routeConfigurationChange` → `.resync`；其他（`categoryChange`、`wakeFromSleep`、`unknown`…）→ `.none`。
- `MPVEngine.swift`：建立 handle 時註冊 `routeChangeNotification`、拆掉時移除；在 mpv 佇列上讀 `pause`，依 `.resync` 設 `pause=yes` 再 `pause=no`、依 `.pause` 設 `pause=yes`。記一行 log：`[audio] route <reason> airplay=<bool> latency=<ms> -> <response>`（不記裝置名稱），給實機驗證用。
- 測試：`supportsAirPlay` 兩個 engine 皆 true；控制列在 MPV 時顯示 AirPlay（照現有控制列測試的寫法）；`MPVAudioRoute` 每個原因碼的對照表。
- 預估：實作＋測試約 1.5 小時、Simulator 約 30 分鐘（目前 Mac 負載很高，可能更久）。

## 六、驗收與回退

- 驗收（Reviewer）：MPV 播放時控制列有 AirPlay；原生的控制列與 AirPlay 行為不變（現有測試全過）；`supportsAirPlay` 與控制列顯示有測試；`MPVAudioRoute` 對照表有測試；全量 `swift test` 通過；Simulator：MPV 播放中出現 AirPlay 按鈕、點了會跳系統選單、播放不中斷；文件寫明同步延遲的結論與未驗項目。
- 回退：revert 該提交即可。沒有設定、資料格式、libmpv 或鎖檔變更。

## 七、沒驗到（要實機）

Simulator 沒有真的 AirPlay 裝置，以下只能交 IPA 給使用者實機確認：

1. 選 AirPlay 喇叭／Apple TV 後 `outputLatency` 的實際值（預期約 2 秒），以及收到 `routeChangeNotification` 時它是否已經更新（log 會記）。若當下還是舊值，備案是延後一點再做暫停→繼續，或改用 `ao-reload`（E）。
2. 重新同步後的影音是否對得上（看嘴型）。
3. 選了 Apple TV 時，MPV 只投聲音、畫面留在手機；原生切回來仍然投影片。
4. AirPlay 斷線時停在暫停、不從手機外放。
5. 原生投到 Apple TV 時切到 MPV，路由是否留在 Apple TV（聲音）或回到手機。
