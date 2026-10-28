# W-201 iOS 爬蟲本機轉址服務（設計已核准，W-202 實作）

狀態：設計經使用者核准（方案 C），W-202 已實作；實測結果與限制見文末「實作結果（W-202）」。

## 白話摘要（給使用者）

- **問題**：YouTube｜PY 在 iOS 點播放會出現「無法播放（mpv error -13）」。原因是這支 Python 爬蟲按播放時，把影片交給「手機裡的一個小轉送站」（網址 `http://127.0.0.1:9978/proxy…`）。Android 版 FongMi 內建這個轉送站，iOS App 沒有，所以播放器連不上。bili看電影 也是同一個原因（IOS-POC-37 已記錄）。
- **要做的事**：在 iOS App 裡加一個「只有本 App 自己用得到」的小轉送站。播放器向它要影片時，它去問那支爬蟲的 `localProxy`，再把爬蟲回的內容交給播放器。
- **另外三件必要配套**：
  1. 這種影片是 DASH 格式。蘋果原生播放器不支援 DASH，所以要直接交給 MPV。
  2. MPV 讀這種 DASH 時會一次跟轉送站要「整部影片」，而爬蟲會把整段先讀進記憶體。轉送站要把大請求拆成一小段一小段跟爬蟲要，否則會吃光記憶體。
  3. iOS 版 Python 的「暫存」讀回來的格式和 Android 不同：Android 會把存進去的資料還原成原本的樣子，iOS 會變成一串文字。YouTube 腳本靠這份暫存找影片位址，所以也要改成和 Android 一樣。設定檔裡另外兩個有用暫存的站（山楂、MiFun）存的是純文字，不受影響。
- **只在模擬器驗**：你用的 iPhone（SideStore 安裝）上的記憶體和速度要等新版 IPA 才能實測，模擬器結果不能代表實機。
- **安全**：只聽本機（127.0.0.1），網址帶每次啟動隨機產生的通行碼，別的裝置連不到，手機上其他 App 也猜不到。Android 版 FongMi 的轉送站對整個區網開放，iOS 不照抄這點。
- **代價**：中型改動，約 1–2 個工作階段（新增一個小伺服器、Python 執行環境接上 `localProxy`、播放路由認 DASH）。不影響其他站：只有爬蟲回了 9978 網址才會啟動。
- **需要你決定**：是否核准實作（建議方案 C，見下）。

## 背景與根因（W-198，Reviewer #4091 核准）

- `py/油管-6.py`（GitLab，sha256 b147b324…）`playerContent`（:1769-1781）有音軌時回 `{'parse':0,'url':'http://127.0.0.1:9978/proxy?do=py&type=mpd&vid=…','format':'application/dash+xml'}`。
- 同腳本 `localProxy`（:1799-1808）：`type=mpd` 產 DASH MPD（:1841-1883），MPD 的 `BaseURL` 預設指回 `http://127.0.0.1:9978/proxy?do=py&type=media&…`（:1851）；`type=media` 依參數 `range` 以 `requests` 取 googlevideo，`r.content` **整段讀進記憶體**後回 `[status, mime, bytes, headers]`（:1885-1918）。`ext.seg=direct` 時 MPD 直接寫 googlevideo 網址（:1852）；使用者設定沒有 ext，預設 proxy。
- iOS：沒有任何 9978 服務；`SpiderRuntime.proxy(params:)`（ios/Sources/WebHTVCore/Spider/SpiderRuntime.swift:20,31）只有預設空實作且無呼叫端；Python `localProxy` 是空 stub（ios/WebHTVApp/Python/base/spider.py:129-130），`getProxyUrl` 回 ''（:221-226）。
- 證據：.herdr-synapse/webhtv-dev/artifacts/w198-youtube/（RESULT.md、applog-yt.txt「127.0.0.1:9978 Connection refused」、y03-play.png「mpv error -13」、fongmi-584-logcat.txt「本地代理端口:9978」）。

### 先前的決策（本單重議的對象）

IOS-POC-7A（docs/IOS-POC-7A-python-runtime.md:121,203,398）把「本機 proxy server」列為刻意不做，`getProxyUrl` 回空字串。當時的理由是範圍控制，不是技術上做不到。使用者 2026-10-27 要求 YouTube｜PY 在 iOS 能播（#4045），所以重議。若核准，`getProxyUrl` 的回傳行為與這段紀錄要一起更新。

## FongMi（Android）9978 代理協定

以本 repo 的 Android 原始碼（FongMi fork）為準，路徑相對 repo 根：

| 項目 | 行為 | 出處 |
|---|---|---|
| 啟動／埠 | 9978 起試到 9998，取第一個可用；`Proxy.set(port)` | app/src/main/java/com/fongmi/android/tv/server/Server.java:62-76 |
| 綁定 | NanoHTTPD 未指定 host，**聽所有介面**（區網可連） | server/Nano.java:31,37-38 |
| 路由 | `/proxy`（前綴比對）以外還有 /file、/m3u8、/parse、/manage、/action… | server/Nano.java:42-58,77-86 |
| 參數 | query 參數＋**所有請求標頭（小寫，如 `range`、`user-agent`）**合成一個 map | server/process/Proxy.java:37-39 |
| 分派 | 有 `siteKey` → 該站 spider；`do=js` → 最近使用的 JS spider；`do=py` → 最近使用的 Python spider；其他 → 各 jar 的靜態 `Proxy.proxy` | api/loader/BaseLoader.java:65-84；PyLoader.java:56-59 |
| 「最近」 | 每次首頁／分類／詳情／播放呼叫前設定，即使用者最後操作的站 | api/SiteApi.java:60,97,128,157 |
| 回傳 | `[status, mime, InputStream, headers?]`；Python 版 `[code, mime, body(bytes|str), headers?, base64旗標?]`，**整段緩衝成 ByteArrayInputStream** | server/process/Proxy.java:50-66；chaquo/src/main/java/com/fongmi/chaquo/Spider.java:89-98,124-130 |
| Range | `/proxy` 不自己處理，`range` 標頭交給爬蟲；爬蟲回 206＋Content-Range 就照轉 | Proxy.java:67-68；ProxyRangeResponsePolicy.java:8-26 |
| 回應 | 一律 chunked，無 Content-Length | Proxy.java:65 |
| 安全 | `/proxy` 沒有 token、Host 或 loopback 檢查 | Proxy.java:35-47；Nano.java:77-86 |
| 給爬蟲的網址 | Python `getProxyUrl()` = `http://127.0.0.1:<port>/proxy?do=py` | chaquo/src/main/python/base/spider.py:114-115 |

註：FongMi 5.8.4 官方版（GitHub FongMi/Release，mobile-arm64_v8a.apk sha256 f9972abc…）在模擬器啟動即印「本地代理端口:9978」，與上表一致；官方版跑 .py 需先在 Modules 安裝 Python 模組。Android 端實際播放 YouTube 的畫面對照**未做**（模擬器輪給 W-200）。

## iOS 現況

| 項目 | 現況 | 出處 |
|---|---|---|
| 播放回應解碼 | `SpiderPlayResponse` 只讀 parse/url/header/subs/jx/playUrl/flag，**不讀 `format`** | ios/Sources/WebHTVCore/SourceClient.swift:251-283（:270） |
| 直連判斷 | `isDirectMedia` 只認 m3u8/mp4/flv/mkv/ts/mov，不含 mpd | CMSClient.swift:535-537 |
| 引擎選擇 | 全域預設（未設定＝原生 AVPlayer），失敗後在特定錯誤類別才切 MPV 一次；不依網址或格式選 | PlaybackEngine.swift:44-46,76-101,141-146,176,188 |
| MPV 載入 | headers → `http-header-fields`，`loadfile url replace`，無 demuxer 選項 | WebHTVApp/Sources/MPVEngine.swift:507-551,584-598 |
| MPV 的 DASH | Libavformat 為 WebHTV 自建 ffmpeg-n8.1.2-webhtv.1，CI 驗證含 `dashdec.o`（libxml2）；**未在裝置上播過 DASH** | .github/workflows/ios-ffmpeg-build.yml:243-292；third_party/mpv-ios-lock.json:266；ios/Vendor/MPVKit/Package.swift:51,88 |
| 現有本機伺服器 | `OfflineMediaServer`：NWListener 只綁 `.ipv4(.loopback)`、OS 指派埠、每次啟動 UUID token、只收 GET/HEAD、支援 Range／206／416、512 KB 分塊串流、`Connection: close`、被系統暫停後以 HEAD 探活並換埠重開 | ios/Sources/WebHTVCore/Offline/OfflineMediaServer.swift:24,37-58,74-82,108-139,205-235,281-341；WebHTVApp.swift:6311-6321 |
| Python 執行緒 | 每站一條序列 DispatchQueue，同站呼叫一次一個（呼叫期間持有 GIL，socket I/O 時釋放） | ios/WebHTVApp/Sources/PythonSpiderRuntime.swift:14-43 |
| 本機網址的既有處理 | 字幕與解析服務遇 127.0.0.1／proxy:// 一律丟棄，不改寫 | SourceSubtitles.swift:81,233-248；GlobalParse.swift:43-49 |

## 外部證據

| 來源 | 存取 | 等級 | 支持的事實 | 對設計的影響 |
|---|---|---|---|---|
| FFmpeg `libavformat/dashdec.c`（GitHub FFmpeg/FFmpeg master，2026-10-27 讀） | 原始碼 | 一手 | 不解析 `SegmentBase`／`indexRange`；只有 BaseURL 的 Representation 建成單一 fragment、`size=-1`，`open_input` 不帶 offset，整檔一次讀 | MPV 讀這支腳本的 MPD 會向 `type=media` 要**整部**音／視訊軌；腳本 `r.content` 會整段緩衝 → 必須由轉送站把大請求拆成小 Range（見設計 4） |
| Apple Developer Forums thread 812077「Why doesn't AVPlayer / AVFoundation support MPEG-DASH」（2026-10-27） | 論壇（非官方聲明） | 二手 | AVFoundation 原生不播 .mpd，Apple 投資在 HLS | DASH 不能交 AVPlayer，要直接走 MPV |
| ByteArk iOS SDK 文件（docs.byteark.com，iOS Support） | 廠商文件 | 二手 | MPEG-DASH 在 Apple 平台不支援 | 同上 |
| FongMi 原始碼（本 repo fork，見上表） | 原始碼 | 一手（fork，未逐檔比對上游最新版） | 協定與回傳格式 | iOS 依同一回傳格式接 Python `localProxy` |
| 論文／部落格 | — | 不適用 | 這是 TVBox 生態的私有契約，沒有學術或規範文件；成熟同類實作就是 FongMi 本身 | — |

## 方案比較

| | A 不做 | B 照抄 FongMi 9978 | C 精簡版（**建議**） | D 只改設定 `seg=direct` |
|---|---|---|---|---|
| 內容 | 維持現狀 | 固定 9978、全部路由（/proxy /file /m3u8 …）、聽所有介面 | 只做 `/proxy` 的 `do=py`；隨機埠＋token；改寫 9978 網址；大請求拆 Range；DASH 直送 MPV | 使用者在 YouTube 站 ext 加 `{"seg":"direct"}`，MPD 直接寫 googlevideo |
| YouTube｜PY | 不能播 | 能播（Range 問題同 C 要處理） | 能播 | 仍需 MPD 代理（type=mpd 一樣是 9978），**單靠設定解不了** |
| bili看電影 | 不能播 | 可能能播 | 可能能播（同為 do=py，需另驗） | 無關 |
| 安全 | — | 差：區網任何人可呼叫 /proxy、/file、/delFile | 好：只聽 127.0.0.1＋通行碼 | — |
| 改動量 | 0 | 大（多數路由 iOS 用不到） | 中 | 0（App）；但改了 Android 行為 |
| 對其他站 | 無 | 常駐伺服器 | 只在爬蟲回 9978 網址時啟動 | 無 |

結論：**採 C**，以 FongMi 的 `/proxy` 契約為準做最小子集；不照抄 B 的區網開放與多餘路由（安全與範圍）；D 不能單獨解決，且會改變 Android 現有行為，不採用（實作後若 Range 拆分效能不佳，可作為使用者端的備援選項）。

## 建議設計（方案 C）

1. **SpiderProxyServer**（WebHTVCore 新類別，沿用 OfflineMediaServer 的模式）
   - NWListener 只綁 `.ipv4(.loopback)`，OS 指派埠；每次啟動一個隨機 token；網址 `http://127.0.0.1:<port>/<token>/proxy?…`。
   - 只收 GET／HEAD；路徑不是 `/<token>/proxy` 一律 404；`Connection: close`。
   - 延遲啟動：第一次遇到要改寫的 9978 網址才開；被系統暫停後照 OfflineMediaServer 以 HEAD 探活、換埠重開。
2. **網址改寫**（讓腳本寫死的 9978 也能用、同時保有通行碼）
   - 播放回應的 `url` 若以 `http://127.0.0.1:9978/proxy` 開頭，改成本服務位址。
   - 服務回應的內容型別為文字類（`application/dash+xml`、`application/vnd.apple.mpegurl`、`text/*`、`application/xml`）時，把內容裡的同一前綴也換掉（MPD 的 BaseURL 指回 9978）。二進位內容不動。
   - Python `getProxyUrl(local)` 改回傳本服務的 `…/proxy?do=py`（目前回 ''），讓用標準寫法的腳本也走得通。
3. **分派**（對齊 FongMi）
   - `do=py`（或無 `do`）→ 「最近一次 playerContent 的 Python 站」的 runtime。
   - 有 `siteKey` → 該站。
   - `do=js`、jar 類（`do=csp` 等）**本單不做**（iOS 沒有 jar；目前沒有 JS 站用到），回 404 並記 log。
   - 參數 = query ＋ 小寫請求標頭（`range`、`user-agent`），與 FongMi 相同。
4. **大請求拆段**（解 FFmpeg 整檔讀取＋腳本整段緩衝；Reviewer #4102 F2）
   - 段長暫定 2 MB，實測調整。任何要求範圍大於一段的請求都拆：沒有 Range、開放式 `bytes=N-`、以及有界但很大的 `bytes=0-999999999`。
   - 拆段方式：第一段以 `bytes=N-(N+段長-1)` 呼叫爬蟲。
     - 回 206 且 `Content-Range: bytes a-b/總長`：得知總長，之後逐段呼叫、逐段寫給播放器，記憶體上限約一段。
     - 回 200（爬蟲不支援 Range）：照原樣轉送，不再拆。
   - 對播放器的回應：
     - 一律帶 `Accept-Ranges: bytes`。
     - 原請求有 Range：回 206，`Content-Range: bytes 起-迄/總長`，`Content-Length` = 迄 − 起 + 1。
     - 原請求沒有 Range：回 200，`Content-Length` = 總長。
     - 有正確長度，FFmpeg 拖動時才會改發 Range 請求。
   - HEAD：只以 `bytes=0-0` 問爬蟲一次取得總長與型別，回標頭不回內容，絕不觸發整段抓取。
   - 播放器斷線（寫入失敗或連線關閉）：立刻停止後續分段呼叫，不再排入 Python 佇列。
   - 小檔（MPD 等文字、總長小於一段）不拆，照原樣轉送。
5. **Python runtime 接上 localProxy**
   - `PythonSpiderRuntime.proxy(params:)` 在該站序列佇列上呼叫 `localProxy(params)`。
   - 回傳依 FongMi 格式轉換：`[code, mime, body, headers?, base64旗標?]`；bytes 原樣、str 依旗標 base64 解碼。
   - 回應 headers 照轉；`Content-Length` 依實際內容重算。
6. **播放路由**
   - `SpiderPlayResponse` 多讀 `format`。
   - `format == application/dash+xml` 或網址副檔名為 `.mpd`：直接用 MPV（不先試 AVPlayer），並把 mpd 納入直連判斷。
7. **Python base 的 getCache／setCache 對齊 FongMi**（Reviewer #4102 F1，阻擋項）
   - 現況：
     - iOS `setCache` 把 dict／list 存成 JSON 字串，`getCache` 原樣回字串，找不到回 `''`（ios/WebHTVApp/Python/base/spider.py:205-217）。
     - FongMi `getCache`（chaquo/src/main/python/base/spider.py:123-145）：以 `{…}`／`[…]` 包住的值會 `json.loads` 回物件；dict 有 `expiresAt` 且已過期就刪除並回 `None`；找不到回 `None`。`setCache`：int／float 轉字串，dict／list 轉 JSON。
   - 油管-6.py 在 `playerContent` 以 `setCache` 存 dict（:1771-1779），`_proxy_mpd`／`_proxy_media` 接著在 try 之外對 `getCache` 的結果呼叫 `.get`（:1844-1850、:1888-1899）。不對齊的話，iOS 會丟 AttributeError，只做轉送站仍播不出來。
   - 設計：iOS `getCache` 改成與 FongMi 相同的解析與過期規則，找不到回 `None`；`setCache` 補 int／float 轉字串。儲存仍用現有的每站檔案，不經本機伺服器。
   - 對其他站的影響：設定檔（GitLab 線上版 2026-10-27，171 站）共有 44 支 PY 腳本，逐支下載檢查，只有 3 支呼叫 `getCache`：
     | 站 | 存的值 | 對齊後 |
     |---|---|---|
     | YouTube（油管-6.py） | dict（含 `expires` 欄，非 `expiresAt`） | 取回 dict，修好 |
     | 山楂 | 16 位十六進位字串 `ldid` | 不受影響（非 JSON 形狀，照樣回字串） |
     | MiFun | md5 字串 `did` | 同上 |

     找不到鍵時由 `''` 改成 `None`，兩支都是 `if not did` 判斷，結果相同。
   - 單元測試：
     - dict／list 存取來回一致。
     - 已過期 `expiresAt` 回 `None` 且被刪除。
     - 純字串原樣回傳。
     - 找不到回 `None`。
     - int 存入後取回字串。

## 安全

- 只綁 loopback，區網與其他裝置連不到（FongMi 是全介面，不照抄）。
- 通行碼每次啟動隨機產生。iOS 上其他 App 雖能連本機埠，但猜不到路徑；沒有通行碼一律 404。
- 只轉給已載入的爬蟲 `localProxy`，不提供任意網址轉送、檔案讀寫、上傳或管理路由。
- 只在需要時啟動；App 結束即消失。
- 爬蟲內容與連網對象仍由使用者設定檔決定（與現在相同的信任範圍）；本服務不繞過任何網站防護，只是把 Android 已有的本機契約在 iOS 補齊。

## 效能與相容

- **同站 Python 序列佇列**（Reviewer #4102 F3）
  - 現象：同一站的呼叫一次一個（PythonSpiderRuntime.swift:22-43）。每段 2 MB 下載期間，該站的其他呼叫都在排隊：另一軌的分段、下一集 `playerContent`、詳情等。
  - 單段逾時：轉送站等每次 `localProxy` 呼叫最多 20 秒，超過就對播放器回 504 並停止該請求的後續分段。
  - 限制：已在執行中的 Python 呼叫無法從外部中斷，佇列要等腳本自己的網路逾時才釋放（油管-6.py 媒體請求 timeout=30 秒）。最壞情況該站卡住約 30 秒。
  - 減輕：段長小（2 MB）讓單次呼叫短；播放器斷線就不再排新段；離開播放頁時取消該 session 尚未開始的分段。
  - 備案：若實測起播或拖動太慢，原型階段評估「每站另開一個專供 `localProxy` 的 Python runtime」。iOS 的 Python 暫存是每站共用的檔案，兩個 runtime 看得到同一份暫存。是否採用依量測結果，另行回報。
- 驗收要記數字：首幀時間（從按播放到出畫面）、拖動到中段後恢復播放的等待時間，各量 3 次取中位數。
- 每段多一次 googlevideo 往返，2 MB 段長是折衷。
- 記憶體上限：每個進行中的請求約一段大小。
- FFmpeg DASH 讀單檔時的拖動行為未知（dashdec 對單 fragment 的 seek）。要實測；若拖動不可用，記為已知限制或改段長策略。
- 其他站與既有播放：只有回 9978 網址的站會走新路徑；原生 AVPlayer、離線伺服器、字幕不受影響。
- 套件大小：純 Swift，無新相依。

## 驗收（實作單）

1. Simulator：YouTube｜PY 回放影片（如 TVBS 新聞回放）有畫面＋聲音，MPV 直接播放，不先經 AVPlayer。
2. 播放 5 分鐘期間 App 記憶體不隨影片長度成長（以 Xcode 記錄或 `footprint` 取樣，附數字）。
3. 拖動到中段能繼續播放；做不到要寫明限制。
4. 安全實證：`lsof` 顯示只聽 127.0.0.1；不帶通行碼或錯誤通行碼的請求得到 404。
5. 回歸：
   - 一般 m3u8／mp4 站、離線播放、YouTube 直播（腳本 HLS 分支）行為不變。
   - 不回 9978 的站不會啟動服務。
   - 山楂、MiFun（另外兩支用 getCache 的 PY 站）首頁與播放不退化。
6. bili看電影 同步測一次並記錄結果（不列為必過）。
6a. 首幀時間與拖動等待時間（各 3 次中位數）寫進任務文件。
6b. **實機未驗**（Reviewer #4102 F4）：本單只有 Simulator。使用者的 iPhone（SideStore 安裝）的記憶體、耗電與起播速度，要等發新版 IPA 後由使用者實測；發布說明與回報必須明寫「實機未驗」。
7. 單元測試：
   - 網址與 MPD 內文改寫。
   - Range 拆段：
     - 開放式、有界大範圍、無 Range 三種輸入。
     - 爬蟲回 200 的退回路徑。
     - HEAD 只送 `bytes=0-0`。
     - 回應的 Content-Length／Content-Range／Accept-Ranges 正確。
     - 斷線後不再呼叫。
     - 單段逾時回 504。
   - getCache／setCache 對齊（見設計 7）。
   - Python 回傳格式轉換（bytes／str／base64／headers）。
   - token 驗證。
   - `format` 解碼與 DASH 路由。

## 回退

- 單一 commit，revert 即回到現狀（YouTube｜PY 不能播，其他不受影響）。
- 實作時保留一個總開關，預設開，可在不發新版下停用：若 Reviewer 認為不需要可省略。

## 工作量與風險

- 估計 1–2 個工作階段：
  - 伺服器與改寫：約半天。
  - Python 接線、格式轉換、getCache 對齊：約半天。
  - 播放路由與 Simulator 驗證：半天到一天。
- 最大風險：
  1. FFmpeg DASH 對 YouTube 單檔 webm/mp4 的實際播放與拖動（未在裝置驗過）。
  2. 序列化 Python 呼叫造成的起播延遲。
  3. googlevideo 對頻繁分段請求的限速。
- 前兩項在實作第一步先用最小原型量測；不合格就回報使用者，不硬上。

## 未決事項（請使用者／Manager 決定）

1. 是否核准方案 C 進入實作（建議核准）。
2. 若實測拖動不可用，是否接受「能播但拖動受限」先上線。

## 實作結果（W-202）

只在 Simulator（iPhone 17 Pro／iOS 27，Debug build）驗；**實機未驗**，要等新版 IPA 由使用者實測。證據在團隊資料夾 `artifacts/w202-proxy/`（不進 git），`FINDINGS.md` 有完整過程。

**做了什麼**（和上面設計的差異用粗體標出）
- `SpiderProxyServer`：只聽 127.0.0.1、OS 指派埠、每次啟動一個隨機通行碼；改寫 9978 網址與文字內容；拆段讀取。
- 段長 **512 KB**（設計暫定 2 MB）：googlevideo 對 2 MB 的第一個音訊請求直接回 403。
- **爬蟲回 206 但不帶 Content-Range、長度剛好一段時**（py/哔哩.py 的 `get_media`），視為有照 Range 回、總長未知：逐段讀到短於一段或空的回應為止，回給播放器的回應不帶長度、以關連線結束。第二段以後**只接受 206**，有 Content-Range 時起點必須等於目前位置，否則停止串流、關連線（有總長時播放器會自己帶 Range 重新要；沒總長時播放器當成檔尾），不把錯的內容接進影片（Reviewer #4421 F1）。
- 播放網址含 **`type=mpd`** 也算 DASH（bili 沒給 `format`）。
- MPV 開本服務網址時用 `cache-secs=10,demuxer-readahead-secs=10` 限制預讀。
- 403 照原樣轉給播放器、**不重試**：YouTube 的配額是每個網址固定的，等待或重試都不會放行。
- Python：`proxy` 接上 `localProxy`；`getProxyUrl` 回 9978；`getCache`／`setCache`／`delCache` 對齊 FongMi 原始碼。
- Runtime ABI：`catvod.result` 1.4（`proxy` 成為有呼叫端的方法、多讀 `format`）、`python.host` 1.6。

**驗收結果**
| 項目 | 結果 |
|---|---|
| 1. YouTube｜PY 回放有畫面＋聲音、MPV 直接播 | MPV 直接開、有畫面聲音，**約 75 秒後中斷**（見下方限制） |
| 2. 5 分鐘記憶體 | bili看電影 播放中每 30 秒取樣：起播後 98–115 MB 並維持，不隨播放時間成長 |
| 3. 拖到中段 | bili看電影 可以；YouTube 不行（同上） |
| 4. 安全 | `lsof` 只聽 127.0.0.1；沒帶或帶錯通行碼回 404 |
| 5. 回歸 | YouTube 直播（HLS 分支，不經 9978）：改動前後的 build 行為相同（原生約 2 秒起播，之後 YouTube 回 403，是既有問題、另案）；MiFun：改動前後腳本回傳相同（站方佔位影片）；山楂：站點主機從 Mac 也連不上，無法驗 |
| 6. bili看電影 | 試看集數（第9／11話，腳本回 302 轉 CDN 的 MP4）：起播 4966／2317／2037 ms，中位數 2.32 s；拖動 1.05／1.13／0.09 s，中位數 1.05 s，落點都正確（512 KB）。B 站未登入只給 6 分鐘試看。完整一集的 DASH（第1話）起播不了，見已知限制 |
| 7. 單元測試 | 全量 `cd ios && swift test` 1402 個通過（含 `SpiderProxyServerTests`、Runtime ABI 升版）；`ios/Tests/Python` 14 個通過 |
| Ponytail 審查 | 第一次：唯一發現是一個沒人呼叫的 `write(body:more:)`，已刪。退回修正後再跑一次：唯一發現是分段迴圈註解寫「播放器會自己帶 Range 重新要」，但總長未知時播放器會當成檔尾、不會重新要，已改註解。未查：CDN 若在總長未知的串流中途回不滿一段，現在會提早結束（bili 實測每段都是滿的） |

**已知限制**
- **YouTube｜PY 透過 9978 只能播開頭約 75 秒、不能拖到中段。** googlevideo 對腳本拿到的網址有每個網址的讀取配額（音訊讀到 1 MB 之後一律 403）。Android FongMi 5.8.4＋Python 模組 1.1.0 同一部能播，是因為那邊腳本的 `playerContent` 因 Python Spider 沒有 `setCache` 而丟 `AttributeError`，改回 `parse: 1` 的 `youtube.com/embed` 網址，再由 FongMi 自己把 YouTube 網址轉成 DASH（直連 googlevideo），根本沒經過 9978。使用者已決定 iOS 也比照 FongMi 自己處理 YouTube 網址，另開 W-209 設計；不補 PO Token、不繞過 YouTube 防護。
- bili看電影 有一次從觀看紀錄續播時，CDN 對轉向後的 Range 請求回了 282 B，MPV 失敗後 App 自動改用原生播放器並播完；之後重試 6 次無法重現，判為 CDN 一次性回應。
- **bili看電影 完整一集的 DASH（第1話；MPD 用 `SegmentBase`、腳本回 206 不帶總長）在 MPV 起播不了**：MPV 20 秒內沒開始播 → 改用原生播放器也失敗（Operation Stopped）。退回前的 356035f0 build 播同一集結果完全一樣，不是退回修正造成的（`sim-bili-ep1-356035f0.log`、`sim-bili-ep1-f1.log`）。原因：FFmpeg 不讀 `SegmentBase`、整檔讀，總長未知時多次從 0 重開連線，每段約 0.7–1 秒，20 秒內讀不完；逾時後還在跑的 Python 呼叫會塞住同站的序列佇列，接著下一集的 MPD 也逾時。Manager #4490 決定另開單處理，**已由 W-210 修好**（見文末「bili 完整集數 DASH（W-210）」）。

**退回修正（Reviewer #4421，attempt 3）**
- F1：後續分段只接受起點相符的 206（見上「做了什麼」）；沒有 Content-Range 時短回應即為最後一段，不再往檔尾後面要（避免把錯誤頁接進影片）。新增單元測試：後續段回 200、起點不符、總長剛好整數段。
- F2：`getProxyUrl` 由 '' 改回 9978 的影響。現行設定 46 支 Python 爬蟲只有 MiFun、農民、真狼 呼叫它，9978 只會出現在播放網址與轉址服務回的文字內容（兩處都會改寫），不會進圖片、字幕或詳情。用 Mac 直接跑改前／改後的 Python runtime：農民 的 9978 路徑需要 `@` 格式的集數 id，但它的 detailContent 只產生完整網址 → 走不到；真狼 試 10 部各線路都是 `parse: 1`（站內播放頁回「播放页未返回媒体地址」或外站解析），代理那條也走不到；兩站改前改後輸出逐行相同（`f2-nongmin-py.log`、`f2-zhenlang-py.log`）。MiFun 先前已驗兩版相同。
- F3：`PlaybackEngine` 對 DASH 的 `selection.choose(.mpv)` 刻意在整個觀看 session 有效，已加註解。

## bili 完整集數 DASH（W-210）

**白話摘要**：bili看電影 的完整集數（例如 JOJO 黃金之風 第1話）以前在 iOS 按播放 20 秒都起不來，拖動或從觀看紀錄續播也會整集中斷。現在 2.6 秒起播，拖到片中任何位置約 2–4 秒接著播，下一集 1.4 秒起播。只改 App 內的本機轉址服務，沒有動 FFmpeg、Android 或站方的任何防護。

**根因（Simulator log 與 FFmpeg n8.1.2 原始碼取證）**
1. FFmpeg 的 DASH 讀取器（`libavformat/dashdec.c` `dash_read_header`）開檔時把 MPD 裡每個 Representation 都開來探測。bili 第1話有 6 種畫質＋3 條音軌，每個都從檔頭讀約 1.5 MB；爬蟲一次只處理一個請求、每 512 KB 約 0.8 秒，加起來超過 MPV 的 20 秒起播期限（`artifacts/w210-bili-dash/sim-ep1-before.log`：9 個不同檔依序從 0 讀）。
2. 腳本回 206 卻不帶 Content-Range（總長未知），FFmpeg 跳到別處時收不到起點就判錯（`http: Unexpected offset … got 0`），該集直接結束。
3. `SegmentBase` 的檔案被 dashdec 當成「單一片段」，而且它把內部讀取通道設成不可跳轉（`dashdec.c:1931` `seekable = 0`），往後跳只能從目前位置一路讀過去：從觀看紀錄續播到 19 分要先讀約 75 MB（`sim-ep1-resume.log`）。
4. 逾時後還在跑的 Python 呼叫塞住同站佇列：是 1. 的後果（9 條連線各排著呼叫）；起播不再逾時後就不再出現。Python 呼叫本身仍無法中途取消（設計如此，`SpiderProxyServer.call` 註解）。

**修法（`SpiderProxyServer`）**
- 回給 MPV 的 MPD 每種只留一個 Representation：H.264 中頻寬最高的（每支 iPhone 都能硬體解碼），沒有 H.264 就取頻寬最高的；音訊取頻寬最高的（`oneRepresentationPerType`）。
- 對本服務提供的 `SegmentBase` 檔，先向腳本要 `indexRange`（每檔一次約 4 KB 的呼叫），讀出 MP4 的 `sidx` 索引，把它改寫成 `SegmentList`（每段一個 `mediaRange`）＋ AdaptationSet 層的 `SegmentTimeline`（dashdec 只從這一層讀時間軸）。dashdec 因此能直接開啟目標時間所在的那一段（`segmentLists`）。改寫結果快取（FFmpeg 會讀同一份 MPD 兩次）。
- 由 `sidx` 算出檔案總長並記住（Mac 上對 9 個 CDN 檔逐一比對，和 CDN 回報的總長完全一致）；之後這個檔的片段回應都帶正確的 `Content-Range`／`Content-Length`（`sidx`、`sidxTotal`、`totals`）。
- log 多一欄 `file=`（`url` 參數的雜湊），能分辨同一份 MPD 的不同檔，不印出網址本身。

**驗收（Simulator iPhone 17 Pro／iOS 27，`artifacts/w210-bili-dash/sim-final.log`）**
| 項目 | 改前 | 改後 |
|---|---|---|
| 第1話起播 | MPV 20 s 逾時 → 退原生也失敗 | 2.65 s |
| 拖動 119→1067 s | 會整集結束 | 2.33 s 落點，之後有畫面（`after-seek-1067s.png`） |
| 拖動 1108→405 s（往回） | 會整集結束 | 2.58 s 落點 |
| 拖動 244→1437 s | — | 4.4 s 落點，直接跳讀檔尾片段（`sim-segmentlist.log`） |
| 下一集（第2話） | MPD 也逾時 | 1.40 s 起播 |
| 單元測試 | — | 全量 `cd ios && swift test` 1406 個通過（`SpiderProxyServerTests` 新增 5 個：精簡 MPD 兩例、sidx 總長與拖動、SegmentList 改寫＋快取＋片段 Content-Range） |

**限制**
- 畫質固定為上述規則選出的那一條，MPV 裡不能再切換 bili 的其他畫質（原本也沒有切換介面）。
- 只認頂層、非巢狀的 `sidx`；拿不到索引的檔維持原樣（舊行為）。
- 實機未驗，要等新版 IPA。
- Ponytail：已跑，沒有必須修的發現。未查：只在 Representation 上標 mimeType、AdaptationSet 沒標的 MPD 不會被精簡，且整組會套用最後一個 Representation 的時間軸（bili 與 YouTube 都標在 AdaptationSet 上）。
