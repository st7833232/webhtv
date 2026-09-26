# IOS-POC-27 — 原生播放器：部分線路黑畫面、2 倍速容易中斷、卡住時按鍵沒反應

- 狀態：**研究與規劃完成（2026-09-26），等待使用者核准；核准前不實作。**
- 版本：使用者在 `0.1.24 (25)` 上回報。
- 使用者原始回報（2026-09-26）：
  1. 「幫我加大 avplayer 的快取或暫存，很容易影片中斷，中斷時播放、暫停、前進後退都不能使用，mpv 的緩衝就可以下載的很快。」
  2. 「我都會使用 2 倍速觀看。」
  3. 「原本預設使用 mpv 播放，後來改成預設使用原生，卻無法播放。」
- 本文件依 AGENTS.md §7 記錄最佳實務研究、現況審查、方案比較、建議、驗收標準與回滾。

## 一、症狀（使用者 2026-09-26 選擇題回答）

| 項目 | 回答 |
|---|---|
| 黑畫面的樣子 | 只有黑畫面；控制列顯示上次播放的秒數，總時間是 00:00 |
| 聲音 | 完全沒有 |
| 按播放鍵 | 沒有反應 |
| 重開 App | 仍然黑畫面 |
| 範圍 | 切到別的線路可以看，只有某條線路 |
| 同一集切 MPV | 可以正常播，能從上次看的地方接續 |
| 等 20 秒以上 | 之前沒等那麼久 |
| 2 倍速 | 一律用 2 倍速觀看；播放中容易中斷，中斷時播放、暫停、快轉倒退都沒反應 |

## 二、診斷

### 1. 黑畫面：原生播放器開不了這條線路，而且等待時什麼提示都沒有

1. **不是 0.1.24 改壞的。**
   - `git diff 450bd061 5da03a4a`（0.1.22 → 0.1.24）的 Swift 原始碼只改了 `HLSAdSkip.swift`，原生路徑的行為沒有變。
   - 0.1.22 真機上原生有畫面（IOS-POC-25 文件第 444 行）。
   - 預設核心一直是原生（`PlaybackEngine.swift:59`），只是使用者之前把預設設成 MPV，所以沒遇到。
2. **畫面上的讀數符合「原生項目一直沒進入可播放狀態」。**
   - 原生控制列的秒數與總長只由 periodic time observer 更新（`WebHTVApp.swift:4379-4404`）。它只在時間前進、跳動、開始或停止時觸發（`AVPlayer.h:569-570`）。
   - 開啟時先 seek 到續播位置（`WebHTVApp.swift:3040-3051`），時間跳了一次，所以顯示「上次的秒數」。這時項目還沒準備好，長度讀到 0，之後時間不再動，就一直停在 00:00。
   - 按播放沒有反應：播放器在等資料時 `rate` 仍是非零（`AVPlayer.h:231-238`），再呼叫 `play()` 不會改變任何事。
3. **App 其實會在 20 秒後自動改用 MPV，但使用者看不出來。**
   - `watchStartup` 在引擎仍是 `.preparing` 或 `.buffering`、而且超過 `PlayerRouter.startupTimeout`（20 秒）時換引擎（`WebHTVApp.swift:2951-2966`、`PlaybackEngine.swift:409, 417-421`）。模擬器上驗證過（IOS-POC-17 文件第 284 行）。
   - 使用者都在 20 秒內就手動切換或關掉，所以沒看到自動切換。
   - 播放畫面沒有任何載入指示（`WebHTVApp.swift:4210-4250` 只有黑底、影像層、錯誤文字與手勢讀數）。20 秒的黑畫面看起來就像壞掉。
4. **原生為什麼開不了這條線路：未知。**
   - 沒有真機 log。`reasonForWaitingToPlay` 只在暫停重新載入的路徑記錄（`WebHTVApp.swift:2676-2677`），AVPlayer 的 error log 從未記錄。
   - 候選（皆未驗證）：自訂 headers 走未公開的 `AVURLAssetHTTPHeaderFieldsKey`（`WebHTVApp.swift:3061-3069`），可能沒被送出；分段偽裝成圖片；H.265 放在 MPEG-TS；播放清單缺少 `EXT-X-ENDLIST`；伺服器的 Content-Type 不標準。FFmpeg 對這些的容忍度都比 AVFoundation 高。
5. **已排除：**
   - 2 倍速：速度不保存，重開 App 回到 1 倍；2.0 不會觸發改用 MPV（`PlaybackEngine.swift:343-347`）。
   - MPV 殘留的畫面層：畫面層依目前引擎決定，重開後重建（`WebHTVApp.swift:4215-4222`）。
   - 音訊工作階段、廣告跳過、背景重新載入、交接精確落點：冷啟動開新集數時都不會阻擋開播。
   - AirPlay：MPV 與原生共用 App 的音訊工作階段，若在 AirPlay，MPV 的聲音也會送到電視，與「MPV 正常」矛盾。

### 2. 2 倍速容易中斷：預讀量以影片秒數計，沒有跟著倍速放大

1. `preferredForwardBufferDuration` 是影片時間（`AVPlayerItem.h:644-650`）。目前一般 60、吃力 90、卡過 120 秒（`PlaybackNetworkPolicy.swift:153-155`）。
2. 目標值沒有倍速參數（`PlaybackNetworkPolicy.swift:204-233`）；只有「還剩多少」的判斷除以倍速（`:100-103`）。2 倍速下實際只撐 30、45、60 秒。
3. AVPlayer 把目標當上限：模擬器上 1 倍時預讀到約 60 秒就停止下載，當時網速約為所需的 11 倍（IOS-POC-22 文件第 20 行；`AVPlayerItem.h:623`「further I/O is suspended」）。
4. 調整倍速後不會立即重新套用；最快等下一次 5 秒取樣，而且只有設定值有變才寫入（`WebHTVApp.swift:2334-2337, 2425, 2525`）。
5. MPV 快的原因：iOS 的 MPV 沒設快取參數（`MPVEngine.swift:316-346`），採 mpv 預設，以位元組上限（約 150 MiB）決定能讀多遠，時間幾乎不設限。模擬器上預讀 238～555 秒（IOS-POC-22 文件第 25 行）。網路相同，差別在允許預讀多遠。

### 3. 卡住時按鍵沒反應：按鍵看的是「正在播」，不是「想要播」

1. 播放／暫停鍵的圖示與動作都取自 `playing`（`WebHTVApp.swift:3627-3634`），原生是 `timeControlStatus == .playing`（`:4386`）。
2. 等資料時不算正在播，按鍵顯示「播放」，按下呼叫 `play()`，沒有作用；暫停按不到，雖然 AVPlayer 在任何狀態都接受 `pause()`（`AVPlayer.h:231-238`）。
3. ±10 秒以精確位置 seek（容許誤差 0），沒有完成回呼（`WebHTVApp.swift:3145-3148`）；新的 seek 會取消前一個（`AVPlayerItem.h:408-420`）。資料到之前完成不了，畫面上也沒有任何提示。
4. 同一個問題 IOS-POC-23 已診斷過（該文件第 32-38 行），當時列為 O4（緩衝指示），使用者 2026-09-25 決定先不處理。本次回報是新的真機證據。

## 三、最佳實務研究（2026-09-26 讀取）

證據等級：A＝Apple 官方文件、SDK header、WWDC；B＝Apple 工程師回答或成熟開源專案程式碼；C＝論壇、部落格。SDK header 行號取自第三方鏡像 `github.com/xybp888/iOS-SDKs` @ `ad607cb07fe4ad1c9b91cf970bd228c2a9253207` 的 iPhoneOS18.0.sdk，內容為 Apple 原文，iOS 13 版本措辭相同。

| # | 來源 | 等級 | 支持的論點 | 對決策的影響 |
|---|---|---|---|---|
| E1 | `AVPlayerItem.h:644-650`；developer.apple.com/documentation/avfoundation/avplayeritem/preferredforwardbufferduration | A | 單位是影片時間；0 由系統決定；系統「may buffer less」；無數值上限說明 | 加大只能「要求」，不能保證 |
| E2 | `AVPlayerItem.h:623` | A | 緩衝滿時「further I/O is suspended」 | AVPlayer 到目標就停止下載 |
| E4 | developer.apple.com/forums/thread/649810（Apple 工程師，2020-06） | B | 此值是限制預讀量的手段；緩衝放在記憶體 | 不宜無上限加大 |
| E5 | developer.apple.com/forums/thread/63435 | C | 有人回報實際上限約 100 秒；有人回報要關掉自動等待才生效 | 超過約 100 秒可能無效，需真機量測 |
| E8 | `AVPlayer.h:266-269` | A | 卡住後，預測能以「指定速率」播完或緩衝滿才恢復 | 2 倍速恢復門檻更高 |
| E9 | `AVPlayer.h:469-485` | A | `automaticallyWaitsToMinimizeStalling` 的判斷依指定速率 | 同上 |
| E10 | `AVPlayer.h:312-316`；`playImmediately(atRate:)` 文件 | A | 可不等緩衝足夠就開始播 | 後續卡頓看門狗的工具（27C） |
| E11 | `AVPlayer.h:231-238` | A | 任何狀態都接受 pause；等待中 `rate` 表示將要播放的速率 | 按鍵應依意圖切換 |
| E12 | `AVPlayer.h:569-570` | A | periodic observer 依項目時間軸觸發，卡住時不觸發 | 原生控制列需要牆鐘計時器更新狀態 |
| E13 | `AVPlayerItem.h:408-431` | A | 新 seek 取消前一個；容許誤差 0 會增加解碼延遲 | seek 在卡住時完成不了 |
| E14 | developer.apple.com/library/archive/qa/qa1820 | A | 不要連續快速 seek；等前一個完成再 seek 到最新目標 | seek 串接（27C） |
| E15 | `AVPlayerItem.h:288` | A | 已就緒的項目都能播 1.0～2.0 倍 | 2 倍速不是核心限制，不必改用 MPV |
| E16 | `AVPlayerItem.h:1163-1176` | A | `indicatedBitrate` 是 1 倍所需的傳輸量 | 2 倍速時網速需約 2 倍 |
| E17 | developer.apple.com/forums/thread/680091（Apple 工程師，2021-06） | B | HLS 不會並行下載連續分段 | 差別不在連線數，在預讀上限 |
| E18 | developer.apple.com/forums/thread/113063（Apple 工程師，2020） | B | resource loader 對 HLS 分段只接受轉址 | 以 resource loader 做快取不可行 |
| E19 | `AVAssetResourceLoader.h:49, 237-239` | A | 同上 | 同上 |
| E20 | developer.apple.com/documentation/avfoundation/avassetdownloadtask | A | 邊下載邊播只在變體相同時有效，需背景 session，會顯示即時動態 | 不適合一般 2 倍速觀看 |
| E22 | `github.com/mpv-player/mpv` @ `0fd3430ee98d05f0a714c9e874a43e73516d2fa0`：`demux/demux.c:139-145`、`DOCS/man/options.rst:5526-5545` | B | 預設前向 150 MiB、後向 50 MiB，時間幾乎不限，緩衝 1 秒即恢復 | 解釋 MPV「下載很快」 |
| E25 | `github.com/androidx/media` @ `081a432e7d9adb86123d4c14f53ccde8aa7cefc2`：`DefaultLoadControl.java:64-102, 777-817` | B | 倍速大於 1 時，目標緩衝換算成影片時間放大 | 成熟做法：目標依倍速放大 |
| E26 | `github.com/videolan/vlc` @ `b11917943e3a32578d65edd54f3d12023da29d46`：`BufferingLogic.cpp:39-42` | B | HLS 預設最大緩衝 30 秒 | 成熟播放器不一定用超大緩衝 |
| E27 | `github.com/kingslay/KSPlayer` @ `92c18fae716f63a080541c4bcc77247ade181426`：`KSAVPlayer.swift` | B | 包裝 AVPlayer 時即時更新預讀設定；換項目時取消未完成的 seek | 設定改變應立即套用 |
| E28 | `github.com/ChangbaDevs/KTVHTTPCache` @ `388da9af7891ea081e2631e09483ff5cbb09639b`：README | B | 本機 HTTP 代理快取可行，但綁 localhost 時 AirPlay 失效 | 代理快取成本高，列為最後手段 |

未能讀取的來源：代理封鎖 nonstrict.eu、asciiwwdc.com、medium.com、mux.com 等；WWDC16 session 503、WWDC18 session 502 的頁面已下架。「設定一小時只緩衝 2～3 分鐘」只在搜尋摘要出現，未採用。

不適用的證據類別：本任務不涉及上游合併候選，沒有對應的上游 commit；黑畫面線路的串流樣本無法取得，無法做格式實測。

## 四、現況審查

| 位置 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/PlaybackNetworkPolicy.swift:100-103` | 剩餘緩衝除以倍速 |
| `PlaybackNetworkPolicy.swift:153-155, 204-233` | 預讀目標 60／90／120 秒，無倍速參數；直播與未知長度為 0 |
| `PlaybackNetworkPolicy.swift:340-342` | `ingest` 回傳的 policy 不帶倍速 |
| `ios/WebHTVApp/Sources/WebHTVApp.swift:2069` | `automaticallyWaitsToMinimizeStalling = true` |
| `WebHTVApp.swift:2185, 2307` | 手動切引擎、換畫質以 `isPlaying` 決定是否自動播放，卡住時會變成暫停載入 |
| `WebHTVApp.swift:2334-2337` | `setRate` 不重新套用緩衝設定 |
| `WebHTVApp.swift:2425, 2449-2505` | 5 秒取樣，只在狀態或設定改變時記錄一行 |
| `WebHTVApp.swift:2524-2535` | `apply(_:to:)` 寫入 `preferredForwardBufferDuration` |
| `WebHTVApp.swift:2951-2978` | 開播檢查：20 秒內未播換引擎；第一次 `isPlaying` 就結束；暫停中未就緒也會觸發自動播放的交接 |
| `WebHTVApp.swift:3023-3026` | 建立項目時不設預讀，第一次取樣才套用 |
| `WebHTVApp.swift:3145-3148` | 原生 seek 容許誤差 0 |
| `WebHTVApp.swift:3193-3200` | 原生 `isPlaying` 與狀態對應 |
| `WebHTVApp.swift:3627-3634` | 播放／暫停鍵依 `playing` |
| `WebHTVApp.swift:4363-4404` | MPV 用 0.25 秒計時器；原生只用 periodic observer |
| `ios/Sources/WebHTVCore/PlaybackEngine.swift:399-421` | `select(_:playing:)`、`startupTimedOut()` 交接 |
| `ios/Tests/WebHTVCoreTests/PlaybackNetworkPolicyTests.swift` | 固定 60／90／120 與倍速語意的測試（第 34-58、130-139、171-181、347-380 行） |
| `docs/IOS-POC-12-runtime-architecture-reconciliation.md:195, 241` | 門檻值與 policy 表是凍結契約列 K39、A21，變更時要同步修訂 |

## 五、方案比較

| 方案 | 內容 | 能否改善回報 | 主要風險 |
|---|---|---|---|
| O0 不改 | 使用者把預設改回 MPV | 能避開全部症狀 | 失去原生的 AirPlay 等功能；原生問題持續 |
| O1 所有倍速都加大 | 60／90／120 改成更大 | 部分 | 1 倍沒有問題也一起放大；可能被系統限制；記憶體 |
| O2 預讀依倍速放大，上限 120 秒（建議，27B） | 一般與吃力狀態乘上倍速，不超過目前已使用過的最大值 120 秒 | 2 倍速的實際預讀從 30 秒加倍到 60 秒 | 網速低於 2 倍位元率時只延後中斷；AVPlayer 可能不完全遵守 |
| O2+ 上限 240 秒 | 同 O2，上限放寬 | 可能更多 | 有報告實際上限約 100 秒（E5）；高位元率片源記憶體風險；卡住後等待可能拉長 |
| O3 看得到載入、按得動（建議，27A） | 轉圈指示、按鍵依意圖、開播暫停不被自動交接、切 MPV 時保留播放意圖 | 按鍵問題解決；黑畫面變成「載入中」並在 20 秒自動改 MPV | 卡住若永遠不恢復，轉圈也不會停（IOS-POC-23 O4 的疑慮）；可手動切 MPV 脫困 |
| O4 原生開不了時說明原因（建議，27A） | 20 秒改用 MPV 時記錄等待原因與 error log，畫面短暫顯示原因 | 讓黑畫面線路的原因可回報 | 只顯示，不加速 |
| O5 卡頓看門狗與 seek 串接（延後，27C） | 卡住 N 秒後重新載入或改用 MPV；`playImmediately`；QA1820 seek 串接 | 可能 | 誤判面大，需要 27A 的 log |
| O6 原生「第一個畫面」檢查（延後） | 播放中卻沒畫面時改用 MPV | 本次證據不支持（項目沒有進入播放） | 純音訊內容會被誤判 |
| O7 本機代理或 resource loader 快取（不採用） | 自行下載分段 | 可能 | HLS 分段只能轉址（E18、E19）；AirPlay、headers、儲存耗損；IOS-POC-15 已明確排除 |
| O8 2 倍速自動改用 MPV（不採用為預設） | 依倍速選核心 | 是 | 2 倍速是原生支援的範圍（E15）；使用者可自行把預設設為 MPV |

判斷：上游與成熟專案的做法是目標依倍速放大（E25），WebHTV 需要**修正並縮小**：放大但不超過目前已用過的最大值 120 秒，先以真機 log 確認 AVPlayer 是否遵守，再決定是否放寬。按鍵與載入指示屬於**補充**既有設計。

## 六、建議：27A 與 27B，各自一個 guard session、一個 commit

### 27A 看得到載入、卡住時按得動、原生開不了會說原因

1. **純邏輯判斷（WebHTVCore，可單元測試）**：由引擎狀態、播放意圖（`rate != 0`）、是否有錯誤，算出「按鍵顯示暫停」與「顯示轉圈」。
2. **控制列按鍵依意圖切換**：想播就顯示暫停，按下暫停；已暫停才顯示播放。
3. **轉圈指示**：想播但在準備或等待資料、沒有錯誤時，延遲 0.5 秒後顯示；不攔截觸控。
4. **原生控制列改用 0.25 秒計時器更新狀態**：意圖、狀態、總長、已緩衝範圍改由計時器讀取（與 MPV 相同）；位置仍由 periodic observer 更新。解決總長卡在 00:00 與卡住時讀數不更新。
5. **開播檢查只在想播時逾時**：開播中使用者按了暫停，就不自動交接並自動播放；按回播放後照常計時。
6. **卡住時手動切 MPV、換畫質保留播放意圖**：切過去會自動開始播放。
7. **原生開不了時留下原因**：20 秒改用 MPV 時，記錄 `reasonForWaitingToPlay`、項目狀態、最後一筆 error log 的狀態碼、網域與說明（網址只記主機與副檔名），並在畫面短暫顯示「原生無法開始播放（原因），已改用 MPV」。原生每次卡頓結束時記錄持續秒數與原因。

範圍外（明確不做）：不縮短 20 秒逾時；不改 seek 的容許誤差；不加卡頓看門狗；不改 MPV。

### 27B 2 倍速時預讀量跟著倍速放大

1. `PlaybackBufferPolicy.policy` 增加 `rate` 參數（預設 1）：預讀目標 ＝ min（各狀態目前的值 × max（倍速，1），120 秒）。直播與未知長度維持 0。

   | 倍速 | 一般／吃力／卡過（影片秒數） | 實際可撐 |
   |---|---|---|
   | 1× | 60／90／120（不變） | 60／90／120 秒 |
   | 1.5× | 90／120／120 | 60／80／80 秒 |
   | 2× | 120／120／120 | 60／60／60 秒 |

2. `ingest` 傳入取樣的倍速。
3. 調整倍速時立即重新套用（已套用過第一次、目前是原生、而且不是要改用 MPV 的倍速時）。
4. 原生播放中每 30 秒記錄一次「已預讀秒數／目標／倍速」，用來確認 AVPlayer 是否真的預讀到 120 秒。
5. 不改：吞吐量判斷門檻、解析度上限、預載下一集的條件、1× 的所有數值。
6. 同步修訂 IOS-POC-12 的 K39、A21 與 IOS-POC-15 的交叉連結。

選 120 秒上限的理由：這是目前在「卡過」狀態已經會要求的值，記憶體用量不超過現況的最大值，也不拉長卡住後的恢復等待；超過約 100 秒是否有效（E5）要先由第 4 點的 log 確認。

### 27C（延後，需要 27A 的真機 log）

1. 依 log 找出黑畫面線路的原因，再決定是修 headers、提早改用 MPV，或其他。
2. 卡頓看門狗（O5）、seek 串接、原生第一個畫面檢查（O6）。
3. 若 log 顯示 AVPlayer 確實遵守超過 120 秒而 2 倍速仍常中斷，再評估放寬上限。

## 七、驗收標準

1. **單元測試（有 Mac 時執行 `swift test`）**
   - 新增：按鍵與轉圈判斷的每一種狀態組合。
   - 新增：倍速 0.5、1、1.5、2、3、NaN 下每個狀態的預讀目標；任何倍速都不超過 120；直播在 2 倍速仍為 0；`ingest(healthy(rate: 2))` 為 120。
   - 既有測試不修改且全部通過。
2. **編譯**：Release workflow 第一次即編譯成功（本環境沒有 Swift 工具鏈，CI 不跑單元測試）。
3. **真機**：第八節 T1～T10 全部符合。

## 八、真機測試（SideStore，無 Console 時以畫面判斷）

| # | 步驟 | 預期 |
|---|---|---|
| T1 | 黑畫面線路用原生開啟，不碰 | 1 秒內出現轉圈；約 20 秒改用 MPV，畫面短暫顯示原因，MPV 從上次位置播放 |
| T2 | 同上，轉圈時按暫停 | 按鍵顯示暫停並可按；按下後不會自動改用 MPV 播放 |
| T3 | 正常線路原生 1 倍開播 | 與現在相同，開播後轉圈消失 |
| T4 | 2 倍速播放中遇到卡頓 | 出現轉圈；暫停可按；再按播放會恢復等待 |
| T5 | 卡頓時從控制列切 MPV | MPV 自動開始播放 |
| T6 | 2 倍速看完整一集（約 45 分鐘） | 不閃退；中斷次數與以前比較（主觀） |
| T7 | 1 倍改 2 倍 | 播放不受影響 |
| T8 | 2.5×／3× | 照舊改用 MPV |
| T9 | 直播 | 照舊 |
| T10 | 有廣告的影片（智慧去廣開） | 照舊跳過 |

## 九、回滾

1. 27A、27B 各自一個 commit，可分別 `git revert`。
2. 27B 的快速回滾：上限改回 60，或倍速係數固定為 1。
3. 使用者端的立即替代方案：設定頁把預設播放器改回 MPV。

## 十、未解與後續

1. 黑畫面線路的真正原因：需要 27A 的原因提示或接 Mac 的 Console log。
2. seek 在卡頓時仍要等資料到才完成：27A 只讓等待看得見，27C 才處理。
3. 27B 無法保證 AVPlayer 遵守 120 秒；網速低於 2 倍位元率時，只能延後中斷。

## Recovery anchor

- 目標：解決原生播放器的部分線路黑畫面、2 倍速容易中斷、卡住時按鍵沒反應。建議 27A（第六節）與 27B（第六節），驗收見第七、八節。
- 狀態（2026-09-26）：研究與規劃完成，未實作；使用者尚未核准。
- 相關檔案：`ios/Sources/WebHTVCore/PlaybackNetworkPolicy.swift`、`ios/Sources/WebHTVCore/PlaybackEngine.swift`、`ios/WebHTVApp/Sources/WebHTVApp.swift`、`ios/Tests/WebHTVCoreTests/PlaybackNetworkPolicyTests.swift`。
- 未解：第十節。
- 下一步（唯一）：等使用者核准 27A、27B（或其中之一）。
