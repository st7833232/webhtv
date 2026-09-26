# IOS-POC-27 — 原生播放器：部分線路黑畫面、2 倍速容易中斷、卡住時按鍵沒反應

- 狀態：**27A、27B 已實作，兩輪對抗式查核的修正已套用，已隨 `0.1.25 (26)` 發布（Release build 第一次即編譯成功，第十二節）；單元測試未執行、真機未驗證。** 使用者 2026-09-26 核准 27A、27B（上限 120 秒）與發布。
- 版本：使用者在 `0.1.24 (25)` 上回報。
- 使用者原始回報（2026-09-26）：
  1. 「幫我加大 avplayer 的快取或暫存，很容易影片中斷，中斷時播放、暫停、前進後退都不能使用，mpv 的緩衝就可以下載的很快。」
  2. 「我都會使用 2 倍速觀看。」
  3. 「原本預設使用 mpv 播放，後來改成預設使用原生，卻無法播放。」
  4. 核准後追加（2026-09-26）：「無法播放需要切換播放器的秒數需要縮短」「縮短到 5 秒」；「從原生切到 mpv 會黑一陣子才有畫面，mpv 切到原生卻很快就有畫面」。
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
   - `git diff 450bd061 5da03a4a`（0.1.22 → 0.1.24）中，App 原始碼只改了 `HLSAdSkip.swift`，而且改的是 MPV 專用的路徑；其餘是 MPV 的 Libavformat 二進位（`ios/Vendor/MPVKit/Package.swift`、連結參數）與測試。原生路徑沒有變。
   - 0.1.22 真機上原生有畫面（IOS-POC-25 文件第 444 行）。
   - 預設核心一直是原生（`PlaybackEngine.swift:59`），只是使用者之前把預設設成 MPV，所以沒遇到。
2. **畫面讀數：原生沒有在播，而且當時還不知道長度（推論）。**
   - 原生控制列的秒數與總長只由 periodic time observer 寫入（`WebHTVApp.swift:4379-4404`），它在時間前進、跳動、開始或停止時觸發（`AVPlayer.h:569-570`）。最後一次觸發後就沒有東西再更新總長。
   - 所以「上次的秒數＋總長 00:00」只能說明：最後一次更新時，播放器沒有在播，長度也還未知。它無法區分「一直沒進入可播放狀態」、「已可播放但在等資料」、「長度不定（例如播放清單沒有 `EXT-X-ENDLIST`）」。27A 的記錄會把項目狀態一起記下來，用來區分。
   - 按播放沒有反應：播放器在等資料時 `rate` 仍是非零（`AVPlayer.h:231-238`），再呼叫 `play()` 不會改變任何事。
3. **App 會在 20 秒後自動改用 MPV，但使用者看不出來。**
   - `watchStartup` 在引擎仍是 `.preparing` 或 `.buffering`、而且超過 `PlayerRouter.startupTimeout`（20 秒）時換引擎（`WebHTVApp.swift:2951-2966`、`PlaybackEngine.swift:409, 417-421`）。模擬器上驗證過（IOS-POC-17 文件第 284 行）。
   - 第二輪查核逐步走過「從集數列表或觀看紀錄開啟、帶續播位置」的路徑：`load()` 啟動檢查，`router.open` 重設換核心額度，AVPlayer 在 `play()` 後等資料，20 秒後以自動播放交給 MPV。續播位置不會阻擋。只有在項目曾經回報「正在播」、在暫停中變成可播放、播放器被關掉，或發生暫停重新載入時才不會觸發，都與回報不符。
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
3. AVPlayer 在目標附近就停止預讀：模擬器上 1 倍時預讀到約 60 秒後維持在 60 秒左右，當時網速約為所需的 11 倍（IOS-POC-22 文件第 20 行，實測）。`AVPlayerItem.h:622-624` 只說明「緩衝滿時暫停 I/O」，沒有說「滿」就是這個設定值；兩者的關聯是推論，由 27B 的 30 秒記錄確認。
4. 調整倍速後不會立即重新套用；最快等下一次 5 秒取樣，而且只有設定值有變才寫入（`WebHTVApp.swift:2334-2337, 2425, 2525`）。
5. MPV 快的原因：iOS 的 MPV 沒設快取參數（`MPVEngine.swift:316-346`），採 mpv v0.41.0 預設：前向約 150 MiB、後向 50 MiB，時間幾乎不設限，緩衝 1 秒即恢復播放。模擬器上預讀 238～555 秒（IOS-POC-22 文件第 25 行）。網路相同，差別在允許預讀多遠。

### 3. 卡住時按鍵沒反應：按鍵看的是「正在播」，不是「想要播」

1. 播放／暫停鍵的圖示與動作都取自 `playing`（`WebHTVApp.swift:3627-3634`），原生是 `timeControlStatus == .playing`（`:4386`）。
2. 等資料時不算正在播，按鍵顯示「播放」，按下呼叫 `play()`，沒有作用；暫停按不到，雖然 AVPlayer 在任何狀態都接受 `pause()`（`AVPlayer.h:231-238`）。
3. ±10 秒以精確位置 seek（容許誤差 0），沒有完成回呼（`WebHTVApp.swift:3145-3148`）；新的 seek 會取消前一個（`AVPlayerItem.h:408-420`）。資料到之前完成不了，畫面上也沒有任何提示。
4. 同一個問題 IOS-POC-23 已診斷過（該文件第 32-38 行），當時列為 O4（緩衝指示），使用者 2026-09-25 決定先不處理（該文件第 355 行）。IOS-POC-12 的 G20 與 IOS-POC-26 的 A1 也記錄了「緩衝中手動換核心會以暫停抵達；開播前按暫停，20 秒後仍會切換並自動播放」。本次回報是新的真機證據。

## 三、最佳實務研究（2026-09-26 讀取）

證據等級：A＝Apple 官方文件、SDK header、WWDC；B＝Apple 工程師回答或成熟開源專案程式碼；C＝論壇、部落格。SDK header 行號取自第三方鏡像 `github.com/xybp888/iOS-SDKs` @ `ad607cb07fe4ad1c9b91cf970bd228c2a9253207` 的 iPhoneOS18.0.sdk，內容為 Apple 原文，iOS 13 版本措辭相同。

| # | 來源 | 等級 | 支持的論點 | 對決策的影響 |
|---|---|---|---|---|
| E1 | `AVPlayerItem.h:644-650`；developer.apple.com/documentation/avfoundation/avplayeritem/preferredforwardbufferduration | A | 單位是影片時間；0 由系統決定；系統「may buffer less」；無數值上限說明 | 加大只能「要求」，不能保證 |
| E2 | `AVPlayerItem.h:622-624` | A | 內部緩衝滿時「further I/O is suspended」 | 「滿」與設定值的關聯需實測 |
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
| E19 | `AVAssetResourceLoader.h:47-49, 237-239` | A | 轉址只能到 HTTP 網址；由 delegate 載入媒體資料時應關閉自動等待 | 佐證 E18 的方向，本身不直接限制 HLS 分段 |
| E20 | developer.apple.com/documentation/avfoundation/avassetdownloadtask | A | 邊下載邊播只在變體相同時有效，需背景 session，會顯示即時動態 | 不適合一般 2 倍速觀看 |
| E22 | `github.com/mpv-player/mpv` v0.41.0 @ `41f6a645068483470267271e1d09966ca3b9f413`（App 使用的版本，`third_party/mpv-ios-lock.json:18-21`）：`demux/demux.c:132-136`；`DOCS/man/options.rst` 的 `--cache-pause-wait`（預設 1） | B | 預設前向 150 MiB、後向 50 MiB，時間幾乎不限；緩衝 1 秒即恢復 | 解釋 MPV「下載很快」 |
| E25 | `github.com/androidx/media` @ `081a432e7d9adb86123d4c14f53ccde8aa7cefc2`：`DefaultLoadControl.java:64-102, 777-817` | B | 倍速大於 1 時，把「最低緩衝」（恢復下載的門檻）換算成影片時間放大，但不超過未放大的最大值；開播與恢復判斷以播放時間計 | 成熟做法：依倍速放大，但以既有上限封頂 |
| E26 | `github.com/videolan/vlc` @ `b11917943e3a32578d65edd54f3d12023da29d46`：`BufferingLogic.cpp:39-42` | B | HLS 預設最大緩衝 30 秒 | 成熟播放器不一定用超大緩衝 |
| E27 | `github.com/kingslay/KSPlayer` @ `92c18fae716f63a080541c4bcc77247ade181426`：`KSAVPlayer.swift` | B | 包裝 AVPlayer 時即時更新預讀設定；換項目時取消未完成的 seek | 設定改變應立即套用 |
| E28 | `github.com/ChangbaDevs/KTVHTTPCache` @ `388da9af7891ea081e2631e09483ff5cbb09639b`：README | B | 本機 HTTP 代理快取可行，但綁 localhost 時 AirPlay 失效 | 代理快取成本高，列為最後手段 |

未能讀取或未能再次核對的來源：代理封鎖 nonstrict.eu、asciiwwdc.com、medium.com、mux.com 等；WWDC16 session 503、WWDC18 session 502 的頁面已下架；第二輪查核時 Apple 論壇（E4、E5、E17、E18）回傳安全驗證頁，只有第一輪讀取的內容。「設定一小時只緩衝 2～3 分鐘」只在搜尋摘要出現，未採用。

不適用的證據類別：本任務不涉及上游合併候選，沒有對應的上游 commit；黑畫面線路的串流樣本無法取得，無法做格式實測。

## 四、現況審查

| 位置 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/PlaybackNetworkPolicy.swift:47-53` | `rate` 的設計說明：倍速只透過「還剩多少」影響狀態，不另加第二套機制（IOS-POC-15 文件第 61-66 行同一決定） |
| `PlaybackNetworkPolicy.swift:100-103` | 剩餘緩衝除以倍速（已處理 NaN 與小於 1） |
| `PlaybackNetworkPolicy.swift:153-155, 204-233` | 預讀目標 60／90／120 秒，無倍速參數；直播與未知長度為 0 |
| `PlaybackNetworkPolicy.swift:307-314` | 一旦卡頓立即進入「卡過」狀態（120 秒），之後每 30 秒回升一級 |
| `PlaybackNetworkPolicy.swift:340-342` | `ingest` 回傳的 policy 不帶倍速 |
| `ios/WebHTVApp/Sources/WebHTVApp.swift:2041-2045` | `[playback]` 記錄的隱私約定：`.public` 只放時間、次數、集數名稱 |
| `WebHTVApp.swift:2069` | `automaticallyWaitsToMinimizeStalling = true` |
| `WebHTVApp.swift:2185, 2307` | 手動切引擎、換畫質以 `isPlaying` 決定是否自動播放，卡住時會變成暫停載入 |
| `WebHTVApp.swift:2334-2337` | `setRate` 不重新套用緩衝設定 |
| `WebHTVApp.swift:2425, 2449-2505` | 5 秒取樣；只在狀態或設定改變時記錄一行（`:2485-2491` 說明此約定） |
| `WebHTVApp.swift:2524-2535` | `apply(_:to:)` 寫入 `preferredForwardBufferDuration` |
| `WebHTVApp.swift:2664-2672` | 暫停重新載入不重新啟動開播檢查的理由（逾時會以自動播放交接） |
| `WebHTVApp.swift:2951-2978` | 開播檢查：20 秒內未播換引擎；計時只在 `load()` 與換引擎時重設；第一次 `isPlaying` 就結束；暫停中也會逾時並以自動播放交接 |
| `WebHTVApp.swift:3023-3032` | 建立項目時不設預讀，第一次取樣才套用；每個項目重設監測 |
| `WebHTVApp.swift:3145-3148` | 原生 seek 容許誤差 0 |
| `WebHTVApp.swift:3193-3200` | 原生 `isPlaying` 與狀態對應；等資料一律對應 `.buffering` |
| `WebHTVApp.swift:3399-3409` | 原生 teardown 會清掉目前項目，之後讀不到 error log |
| `WebHTVApp.swift:3486` | 倍速選單：0.5、1、1.25、1.5、2、2.5、3 |
| `WebHTVApp.swift:3627-3634` | 播放／暫停鍵依 `playing` |
| `WebHTVApp.swift:4363-4404` | MPV 用 0.25 秒計時器；原生只用 periodic observer，並由它寫入位置、總長、播放中、速率、已緩衝 |
| `WebHTVApp.swift:4469-4499` | 手勢讀數 `hud`，0.6 秒後清除，不適合顯示原因 |
| `ios/Sources/WebHTVCore/PlaybackEngine.swift:399-421, 494-503` | `select(_:playing:)`、`startupTimedOut()`、失敗時交接（沿用原請求的自動播放） |
| `ios/Tests/WebHTVCoreTests/PlaybackNetworkPolicyTests.swift` | 固定 60／90／120 與倍速語意的測試（第 34-58、130-139、171-181、347-380 行）；沒有測試以大於 1 的倍速呼叫 `ingest` |
| `docs/IOS-POC-12-runtime-architecture-reconciliation.md:185, 195, 241, 360` | IOS-POC-12 規劃中的契約列 K29（交接）、K39（門檻，暫定）、A21（policy 表）、G20（已知的開播暫停問題） |
| `docs/IOS-POC-26-engine-switch-position.md:25` | A1：緩衝中切換以暫停載入 |

## 五、方案比較

| 方案 | 內容 | 能否改善回報 | 主要風險 |
|---|---|---|---|
| O0 不改 | 使用者把預設改回 MPV | 能避開全部症狀 | 失去原生的 AirPlay 等功能；原生問題持續 |
| O1 所有倍速都加大 | 60／90／120 改成更大 | 部分 | 1 倍沒有問題也一起放大；可能被系統限制；記憶體 |
| O2 預讀依倍速放大，上限 120 秒（建議，27B） | 各狀態乘上倍速，不超過目前已使用過的最大值 120 秒 | 2 倍速一般狀態實際預讀 30→60 秒、吃力 45→60 秒；卡過之後不變（60 秒） | 網速低於 2 倍位元率時只延後中斷；AVPlayer 可能不完全遵守；2 倍速下「卡過就加大」的效果消失 |
| O2+ 上限 240 秒 | 同 O2，上限放寬 | 2 倍速各狀態 120／180／240 | 有報告實際上限約 100 秒（E5）；高位元率片源記憶體風險；若恢復門檻跟著目標，卡住後的等待可能拉長 |
| O3 看得到載入、按得動（建議，27A） | 轉圈指示、按鍵依意圖、開播檢查只計算想播的時間、切 MPV 時保留播放意圖 | 按鍵問題解決；黑畫面變成「載入中」並在 20 秒自動改 MPV | 卡住若永遠不恢復，轉圈也不會停（IOS-POC-23 O4 的疑慮）；可手動切 MPV 脫困 |
| O4 原生開不了時說明原因（建議，27A） | 20 秒改用 MPV 前擷取等待原因與 error log，畫面顯示簡短原因 | 讓黑畫面線路的原因可回報 | 只顯示，不加速 |
| O5 卡頓看門狗與 seek 串接（延後，27C） | 卡住 N 秒後重新載入或改用 MPV；`playImmediately`；QA1820 seek 串接 | 可能 | 誤判面大，需要 27A 的 log |
| O6 原生「第一個畫面」檢查（延後） | 播放中卻沒畫面時改用 MPV | 本次證據不支持（播放器沒有在播） | 純音訊內容會被誤判 |
| O7 本機代理或 resource loader 快取（不採用） | 自行下載分段 | 可能 | HLS 分段只能轉址（E18）；AirPlay、headers、儲存耗損；IOS-POC-15 已明確排除 |
| O8 2 倍速自動改用 MPV（不採用為預設） | 依倍速選核心 | 是 | 2 倍速是原生支援的範圍（E15）；使用者可自行把預設設為 MPV |

判斷：

1. **27B 採用成熟做法，並推翻 IOS-POC-15 的一項設計決定。** Media3 依倍速放大緩衝，但以既有上限封頂（E25）；O2 同一模式：放大，但不超過目前已用過的最大值 120 秒。IOS-POC-15 原本決定倍速只透過「還剩多少」影響狀態、不另加機制（IOS-POC-15 文件第 61-66 行、`PlaybackNetworkPolicy.swift:47-53`）；這個機制只在緩衝已經變薄之後才加大目標，對一路 2 倍速觀看的使用者來說太晚，所以本任務改為目標直接依倍速放大，並同步修訂兩處說明。
2. **27A 補充既有設計**：按鍵、載入指示與開播檢查的意圖判斷。

## 六、建議：27A 與 27B，各自一個 guard session、一個 commit

### 27A 看得到載入、卡住時按得動、原生開不了會說原因

1. **純邏輯（WebHTVCore，可單元測試）**
   - 由引擎狀態、播放意圖（`rate != 0`）、是否有錯誤，算出「按鍵顯示暫停」與「顯示轉圈」。
   - 開播逾時判斷：只累計「想播」的時間。意圖由 0 變成非 0 時重新計時；暫停中不逾時。
   - 網址摘要：只輸出主機與副檔名，供記錄使用。
2. **控制列按鍵依意圖切換**：想播就顯示暫停、按下暫停；已暫停才顯示播放。
3. **轉圈指示**：想播但在準備或等待資料、沒有錯誤時，連續兩次 0.25 秒讀數都成立才顯示（約 0.25～0.5 秒）；不攔截觸控。
4. **原生控制列加 0.25 秒計時器**：意圖、狀態、總長、已緩衝由計時器讀取（與 MPV 相同）；periodic observer 只保留寫入位置，避免兩者互相覆蓋造成按鍵閃爍。效果：卡住時與項目變成可播放後讀數會更新。項目一直沒進入可播放狀態時總長仍是 00:00（長度本來就未知）。
5. **開播檢查只計算想播的時間**：套用第 1 點的判斷。開播中按暫停不會在逾時後自動交接並播放；按回播放後重新計時（逾時秒數見第 9 點）。已暫停載入的項目按播放時，不會因為先前的暫停時間被立即交接。同步修訂 `WebHTVApp.swift:2664-2672` 的說明。
6. **卡住時手動切 MPV、換畫質保留播放意圖**：`select(_:playing:)` 與換畫質改傳意圖（`rate != 0`），切過去會自動開始播放。
7. **原生開不了時留下原因**
   - 在呼叫 `router.startupTimedOut()` **之前**擷取項目狀態、項目錯誤、`reasonForWaitingToPlay`、最後一筆 error log 的狀態碼、網域與截短的說明；交接後原項目就被清掉，讀不到。只有交接成功時才記錄與顯示。
   - 網址只記主機與副檔名；不記錄 error log 的完整 `uri` 與 `serverAddress`。同步修訂 `WebHTVApp.swift:2041-2045` 的隱私說明。
   - 畫面顯示：`PlaybackSession` 新增 `onNotice`，播放畫面以獨立狀態顯示約 4 秒，例如「原生播放器無法開始播放（伺服器回應 403），已改用 MPV」。等待原因與 HTTP 狀態碼對應成簡短中文。
8. **卡頓記錄**：原生在等資料時，5 秒取樣每次記錄一行：等待原因、已預讀秒數、觀測與所需位元率。可據此估計每次卡頓約多久（5 秒精度）。
9. **原生開播逾時 20 → 5 秒（使用者 2026-09-26 核准後追加指定）**：`PlayerRouter.startupTimeout(for:)` 原生 5 秒、MPV 維持 20 秒。風險：目前唯一的開播實測在偏慢的模擬器網路上約 6 秒（IOS-POC-15 文件第 424 行），所以慢但能播的原生開播也可能被交給 MPV；使用者接受這個取捨（這些影片在 MPV 都能播）。MPV 維持 20 秒，避免 MPV 慢開播被交給較不容忍的原生。**例外（27A 查核後追加）**：原生正在 AirPlay 或 AVKit 子母畫面時仍用 20 秒，因為 MPV 沒有 AirPlay、也接不走 AVKit 的子母畫面視窗，5 秒就交接會讓影片離開電視或讓小視窗變黑。

範圍外（明確不做）：項目失敗時的交接仍沿用原請求的自動播放（開播中按暫停後若項目失敗，MPV 仍會自動播放，屬既有行為）；不改 seek 的容許誤差；不加卡頓看門狗；不改 MPV。

文件同步：IOS-POC-12 的 K29、G20，IOS-POC-26 的 A1。

### 27B 2 倍速時預讀量跟著倍速放大

1. **倍速正規化**：把 `PlaybackNetworkPolicy.swift:101` 的判斷抽成一個共用函式；NaN、無限大、0、負數與小於 1 一律當 1 倍。剩餘緩衝的計算與預讀目標共用它。
2. `PlaybackBufferPolicy.policy` 增加 `rate` 參數（預設 1）：預讀目標 ＝ min（各狀態目前的值 × 正規化倍速，120 秒）。直播與未知長度維持 0。

   | 倍速 | 一般／吃力／卡過（影片秒數） | 實際可撐 | 與現況比較 |
   |---|---|---|---|
   | 1× | 60／90／120 | 60／90／120 秒 | 不變 |
   | 1.25× | 75／112.5／120 | 60／90／96 秒 | 一般、吃力放大 |
   | 1.5× | 90／120／120 | 60／80／80 秒 | 一般、吃力放大 |
   | 2× | 120／120／120 | 60／60／60 秒 | 一般 30→60、吃力 45→60、卡過不變 |

3. `ingest` 傳入取樣的倍速。
4. **調整倍速時立即重新套用**：在 `setRate` 中（目前是原生、已套用過第一次、有項目），以目前的網路狀態直接計算 policy 並呼叫 `apply`，**不**呼叫 `ingest`，避免多算一次取樣而縮短狀態回升的時間。有寫入時記錄一行「倍速 → 預讀目標」。
5. **每 30 秒記錄一次**：原生播放中每 6 次取樣記錄「已預讀秒數／目標／倍速／網路狀態／卡頓次數」；計數器每個項目重設；放在「只在改變時記錄」的判斷之前。同步修訂 `WebHTVApp.swift:2485-2490` 的說明。用來確認 AVPlayer 是否真的預讀到 120 秒，以及中斷發生在第一次卡頓前或後。
6. 不改：吞吐量判斷門檻、解析度上限、預載下一集的條件、1× 的所有數值、`level(of:)` 與 `limit(of:)`。
7. **文件同步**：`PlaybackNetworkPolicy.swift:47-53` 的說明、IOS-POC-15 文件第 61-66 行（倍速的設計決定）、IOS-POC-12 的 K39（暫定）與 A21。

選 120 秒上限的理由：這是目前在「卡過」狀態已經會要求的值，影片秒數不超過現況的最大值，也不拉長卡住後的恢復等待；但**記憶體可能變多**：多畫質來源在 1× 只有「卡過」才要求 120 秒且上限 720p，2× 的一般狀態則是 120 秒的最高畫質，T6 即記憶體檢查；超過約 100 秒是否有效（E5）要先由第 5 點的記錄確認。**限制**：一旦卡頓過，1× 與 2× 都已經是 120 秒，27B 對「卡過之後」沒有幫助；若記錄顯示中斷多半發生在第一次卡頓之後，需要 O2+ 或 27C。

### 27C（延後，需要 27A、27B 的真機記錄）

1. 依記錄找出黑畫面線路的原因，再決定是修 headers、提早改用 MPV，或其他。
2. 卡頓看門狗（O5）、seek 串接、原生第一個畫面檢查（O6）、項目失敗時的交接也依意圖、暫停重新載入（`reloadPaused`）後是否重新啟動開播檢查（IOS-POC-23 已在真機接受不啟動）。
3. 若記錄顯示 AVPlayer 確實遵守超過 120 秒而 2 倍速仍常中斷，再評估 O2+。

## 七、驗收標準

1. **單元測試（有 Mac 時執行 `swift test`）**
   - 新增：按鍵與轉圈判斷的每一種狀態組合。
   - 新增：開播逾時判斷。想播滿逾時秒數才逾時；暫停中不逾時；暫停超過逾時秒數後按播放要再等滿整段逾時；已在播放就結束；`startupTimeout(for:)` 原生為 5、MPV 為 20。
   - 新增：網址摘要只含主機與副檔名，不含路徑、查詢字串與權杖。
   - 新增：倍速 0.5、1、1.25、1.5、2、3 下每個狀態的預讀目標；NaN、無限大、0、負數得到 1× 的值；任何倍速都不超過 120；直播在 2 倍速仍為 0；`ingest(healthy(rate: 2))` 為 120。
   - 既有測試不修改且全部通過。
2. **編譯**：Release workflow 第一次即編譯成功（本環境沒有 Swift 工具鏈，CI 不跑單元測試）。
3. **真機**：第八節 T1～T12 全部符合。

## 八、真機測試（SideStore，無 Console 時以畫面判斷）

| # | 步驟 | 預期 |
|---|---|---|
| T1 | 黑畫面線路用原生開啟，不碰 | 約 0.25～0.5 秒後出現轉圈；約 5 秒改用 MPV，畫面顯示原因約 4 秒；MPV 從上次位置播放 |
| T2 | 同上，轉圈時按暫停 | 按鍵顯示暫停並可按；暫停中不會自動改用 MPV 播放；再按播放後重新計 5 秒 |
| T3 | 正常線路原生 1 倍開播 | 與現在相同；開播後轉圈消失 |
| T4 | 2 倍速播放中遇到卡頓 | 出現轉圈；暫停可按；再按播放會恢復等待 |
| T5 | 卡頓時從控制列切 MPV | MPV 自動開始播放 |
| T6 | 2 倍速看完整一集（約 45 分鐘） | 不閃退；中斷次數與以前比較（主觀） |
| T7 | 1 倍改 2 倍 | 播放不受影響 |
| T8 | 2.5×／3× | 照舊改用 MPV |
| T9 | 直播 | 照舊 |
| T10 | 有廣告的影片（智慧去廣開） | 照舊跳過 |
| T11 | 暫停後離開 App 再回來（IOS-POC-23 T1） | 照舊以暫停狀態恢復，不會自動播放或自動改用 MPV |
| T12 | AirPlay 中或原生子母畫面中，自動換到開播較慢的下一集 | 最多等 20 秒才改用 MPV，不會 5 秒就改 |

## 九、回滾

1. 27A、27B 各自一個 commit，可分別 `git revert`。
2. 27B 的快速回滾：上限改回 60，或倍速係數固定為 1。
3. 使用者端的立即替代方案：設定頁把預設播放器改回 MPV。

## 十、未解與後續

1. 黑畫面線路的真正原因：需要 27A 的原因提示或接 Mac 的 Console log。
2. seek 在卡頓時仍要等資料到才完成：27A 只讓等待看得見，27C 才處理。
3. 27B 無法保證 AVPlayer 遵守 120 秒；網速低於 2 倍位元率時只能延後中斷；卡頓過之後 27B 沒有幫助；多畫質來源在 2× 的記憶體用量可能高於以前（T6 檢查）。
4. 開播中按暫停後若項目失敗，MPV 仍會自動播放（第六節 27A 範圍外）。
5. **原生切到 MPV 要黑一陣子才有畫面，MPV 切到原生很快**（使用者 2026-09-26 追加回報）：不在 27A／27B 範圍。候選（未驗證）：交接時新建 MPV 引擎與 Metal 畫面、MPV 以精確位置開始時要從前一個關鍵畫面解碼、MPV 開播前等待快取。需另外研究，列入 27C 之後的待辦，先不處理。

## 十一、第二輪查核（2026-09-26）

兩個獨立查核：一個逐條核對引用，一個逐項檢驗 27A／27B 在程式碼中的可行性。沒有阻擋性問題；已修正：

1. E25：Media3 放大的是「最低緩衝」並以未放大的最大值封頂，不是放大目標；第五節判斷改寫。
2. E19：header 沒有直接說 HLS 分段只接受轉址，該論點只由 E18 支持。
3. 第二節之一第 2 點：畫面讀數改為推論，無法區分三種狀態，由 27A 的記錄區分。
4. 第二節之二第 3 點：「在目標附近停止預讀」改為引用 IOS-POC-22 實測，header 只作佐證。
5. E22：改為 App 實際使用的 mpv v0.41.0。
6. 第二節之一第 1 點：0.1.22 → 0.1.24 的差異描述補齊。
7. 27B：倍速 NaN 的處理、各狀態實際效益、推翻 IOS-POC-15 設計決定的說明、1.25×、重新套用的方式、30 秒記錄的位置。
8. 27A：開播計時只算想播的時間、失敗交接的範圍外說明、交接前擷取原因、`onNotice` 顯示管道、記錄的隱私、observer 只保留位置、卡頓記錄改用 5 秒取樣。
9. 契約列：K39 為暫定；補上 K29、G20 與 IOS-POC-26 A1。

## 十二、實作紀錄（2026-09-26）

| commit | 內容 | 驗證 |
|---|---|---|
| `96b714dfb2007ab5b0e62de1bdbbfd1a0f0683ad` | 27A 第六節第 1～9 點：`PlaybackActivity.swift`（按鍵與轉圈判斷、`PlaybackStartupWatch`、`PlaybackStartupReason`、`PlaybackLogRedaction`）與 `PlaybackActivityTests.swift`；`startupTimeout(for:)` 原生 5 秒、MPV 20 秒；App 接線 | 未編譯、單元測試未執行 |
| `80f949ffa66422b49ad594cfdf6a6ebf2f184334` | 27B：`policy(for:…rate:)`、`speedFactor`、`maximumForwardBufferSeconds` 120 秒；`setRate` 立即重新套用；每 30 秒 `holding` 記錄；`PlaybackNetworkPolicyTests` 新增 6 個（共 32 個） | 未編譯、單元測試未執行 |
| `25b917390e94fb90065be31707dbdc109b30f7e3` | 27B 對抗式查核（3 個角度、確認 5 項、推翻 1 項）：倍速記錄補上 kind、variants、cap；IOS-POC-22 改用 MPV 前不再寫入目標；目標記錄到小數一位；修正記憶體說明 | 未編譯 |
| `a21bad25607dfb6181bfe4548169474d9067a279` | 27A 對抗式查核（3 個角度、確認 15 項、推翻 1 項）：測試中 `#expect` 內呼叫 mutating 方法的編譯錯誤（與 IOS-POC-25 同一類）；`startupTimeout(for:)` 加 `nonisolated`，避免 Swift 6 下測試無法編譯；AirPlay／子母畫面時原生維持 20 秒；子母畫面中關閉播放畫面時停止計時器；記錄的隱私說明；文件與契約列同步 | 未編譯 |

- 使用者選擇：27B 上限 120 秒（未採用 240 秒的 O2+）；原生逾時 5 秒（使用者指定，風險見第六節 27A 第 9 點）。
- 兩個查核都沒有執行任何編譯；Release workflow 只編譯 App target，不編譯測試，所以測試的編譯與執行要等有 Mac 時做。
- **發布 `0.1.25 (26)`**（使用者授權）：版號 commit `96d20a98`，`ios-poc` 快轉到該 commit，run `36255311859` 成功，tag `ios-v0.1.25-b26`，`source.json` `99410d5a`；IPA 25,129,553 bytes，SHA-256 `3ed1f4ab184ab98419d75d8f0705af311b50c909a7edcf2a0db3fcafcfc4ca65`，下載回驗含本任務的記錄字串。**這是 27A、27B 第一次在 Xcode 上編譯，一次成功**；單元測試仍未執行。詳見 IOS-POC-11 第二十六次發布。

## Recovery anchor

- 目標：解決原生播放器的部分線路黑畫面、2 倍速容易中斷、卡住時按鍵沒反應。建議 27A 與 27B（第六節），驗收見第七、八節。
- 狀態（2026-09-26）：27A、27B 與兩輪查核修正已隨 `0.1.25 (26)` 發布（Release build 編譯成功）；單元測試未執行、真機未驗證。
- 相關檔案：`ios/Sources/WebHTVCore/PlaybackActivity.swift`、`ios/Sources/WebHTVCore/PlaybackNetworkPolicy.swift`、`ios/Sources/WebHTVCore/PlaybackEngine.swift`、`ios/WebHTVApp/Sources/WebHTVApp.swift`、`ios/Tests/WebHTVCoreTests/PlaybackActivityTests.swift`、`ios/Tests/WebHTVCoreTests/PlaybackNetworkPolicyTests.swift`。
- 未解：第十節。
- 下一步（唯一）：等使用者在 `0.1.25 (26)` 上做第八節 T1～T12 並回報，逐列填入。
