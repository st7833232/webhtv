# HG-NATIVE-1 — 原生播放器讀取整集 MP4 的 Python 代理

## Recovery anchor

- 目標：qist 類型的 `localProxy` 忽略 Range、回傳整集 200 MP4 時，WebHTV 仍向 AVPlayer 提供正確單一 byte-range、HEAD 與錯誤狀態；保留 MPV 備援與既有 206 串流。
- 基線：`origin/ios-poc` `b720ee104ede7ab6bb98e24a9941c38aad1789be`；分支 `codex/hongguo-native-playback`；起始工作區乾淨。
- 授權：使用者 2026-11-05「我要讓原生播放器也要能播放」，承接已討論的 qist MP4 代理相容性修正。
- 範圍：`SpiderProxyServer.swift`、`SpiderProxyServerTests.swift`、本檔。不修改上游 PY、解密演算法、播放器選擇規則、原生依賴、訂閱或發布設定。
- 計畫：先以 `bytes=0-1`／seek／HEAD 重現；只在完整 200 MP4 分支按原請求切片；既有 206 路徑不改；用真實 H.264/AAC MP4 和 AVPlayer 驗證代理。
- 狀態：修正與審查完成，31 項代理測試通過（含真實 AVPlayer 播放／seek）；下一步：在 iPhone 使用 qist 原檔驗收真實內容，發布需另行授權。

## 證據與決策（2026-11-05）

| 證據 | 版本／定位 | 支持的結論 |
|---|---|---|
| qist `py/红果短剧.py` | blob `f617a472d57fec517c6ab65ee595278a5874f923`，`_locked_play`／`localProxy` | 使用宿主 getProxyUrl，忽略 Range 並在下載、處理整集後回 `[200, video/mp4, body]`；這條路徑已是 MP4，不能把它當 DASH 強制選 MPV |
| 本地代理原碼／測試 | 上述基線，`handle`／`aSpiderThatIgnoresRangeIsForwardedAsItAnswered` | 現有行為刻意保留 200 整集；因此 AVPlayer 的 2-byte 探測會收到整集而非部分內容 |
| Apple AVError.serverIncorrectlyConfigured | https://developer.apple.com/documentation/avfoundation/averror-swift.struct/serverincorrectlyconfigured ，同日查閱 | 媒體伺服器不支援 byte range 是原生錯誤的可能原因；本題以本地重現驗證，不把它當真機錯誤已確診 |
| RFC9110 §14／§15.3.7 | https://www.rfc-editor.org/rfc/rfc9110.html#name-range-requests ，同日查閱 | GET 可支援單一 range，回 206 與精確 Content-Range；超界用 416；HEAD 不送 body |
| 現有 OfflineMediaServer | `byteRange`、檔案回應 | 已有 suffix／open-ended／clamp 的解析與正確標頭模式，沿用它而非另建播放器專用協議 |

這是既有共用代理的局部相容性修正，不移植上游或新增解密功能。額外的上游 PR、論文與效能比較不影響此一 HTTP 回應決策；不擴大搜尋。無法用這項修正保證網站接口、原始媒體編碼或所有劇集都有效。

方案比較：維持現狀仍讓 native probe 收整集；改 qist PY 不能惠及其他整集 MP4 來源且增加私人分支維護；採共用代理對完整 MP4 回應補 byte-range，範圍最小。只回應本次請求，不新增整集快取，避免額外常駐記憶體／磁碟與快取失效契約。來源既有的整集下載及 Base64 橋接成本不在本次改寫範圍。

## 驗收與回退

- GET `bytes=0-1` 回 206／2 bytes／精確總長。
- 中間 seek、suffix、超出尾端、HEAD 與無 Range 正確。
- 非 MP4、來源 403、正常 206 和 DASH→MPV 選擇不變。
- 以真實小型 H.264/AAC MP4 經本機代理，AVPlayer 載入、開始播放、seek 成功。
- 真實 qist 網路接口、1080p 原始編碼與 iPhone 真機另列驗證限制，不把測試 fixture 當實際紅果內容。
- 回退：撤銷本任務的單一 commit 即恢復原先 passthrough。

## 實作與驗證紀錄

- 先新增 native probe／open-ended／suffix／seek／HEAD／非法範圍測試；未改 production 時，27 項定向測試錄得 29 個預期斷言失敗。
- `rangedMP4` 僅轉換未壓縮的完整 `200 video/mp4`；沿用 `OfflineMediaServer.byteRange`，補精確 Content-Range、Accept-Ranges，交由既有 `forwarded` 重算 Content-Length。HEAD 不送 body。真正 206、manifest、403 與 compressed body 保持原樣。
- 獨立 Ponytail review：提出 If-Range 的 200 不應被轉為206、未知 range unit 應忽略兩項 Must fix；兩項已用 handler 測試先 RED 再修正。另指出既有 Int64 長度／分段尾端溢位；以 handler 邊界測試確認舊碼 signal5，修正安全差值與分段上界後轉 GREEN。沒有未處理的審查項目。
- 本機測試命令（cache 均在 /tmp）：`WEBHTV_NATIVE_PROXY_MP4=/tmp/hg-native-1080.mp4 CLANG_MODULE_CACHE_PATH=/tmp/hg-native-modulecache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/hg-native-modulecache swift test --package-path ios --cache-path /tmp/hg-native-swift-cache --config-path /tmp/hg-native-swift-config --security-path /tmp/hg-native-swift-security --disable-sandbox --filter SpiderProxyServerTests`。
- 結果：**31 項、零失敗**，原生測試實際啟用。fixture 為本機 FFmpeg 產生的 4 秒、1080×1920、H.264／AAC MP4，經真實 loopback listener／SpiderSession／整集200回應路徑，AVPlayer readyToPlay、時間推進與 seek 到1秒皆通過，最終耗時0.805秒。MPV 未介入。
- 編譯既有的 URLProtocol Sendable／不必要 await warnings 仍存在；未修改無關檔案。沒有新增依賴或套件／原生二進位。
- 限制：未執行完整 App／IPA build，未在 iPhone 驗收，未測 qist 真實 API、全劇、原始1080p編碼與解密效能。本修正不能解決上游接口失效或影片本身不支援；整集下載及 Base64 橋接成本保持原狀。
- 時間：16:51 預估20分鐘；首次 Swift module cache 權限調整、冷編譯及原生驗證準備使結束延至約17:20。完成31項定向驗證後停止額外測試，不擴大播放器改造。
