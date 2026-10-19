# IOS-POC-59：iOS 直播電視 L1 設計研究與計畫（W-93 LIVE-L1-DESIGN）

> 性質：**任務文件**（2026-10-15 由設計 `artifacts/live-l1-design-2026-10-15.md` 原樣搬入，再依 §14 拍板與 W-128 審查預備 B-1～B-5、N-1～N-4 修正；修正處標「（W-124 修正）」）。§0～§12 是設計原文，實作紀錄從 §15 起往後追加，每段（U1～U4）各一節。
> 撰寫：Reviewer 子代理，2026-10-15 11:19–12:30 CST（Asia/Taipei）。基準 HEAD：`b1b2060634e7d77050bad2497744d4cb791f1779`（ios-poc）。iOS 行號都用 `git show HEAD:<path>` 對過。Android 的 `app/` 在 `644a2b16..HEAD` 之間沒有任何改動，所以審查清單裡的 Android 行號照樣有效。
> 日後要搬到 `docs/IOS-POC-59-live-tv.md`，內容可以原樣搬（59 這個編號目前沒人用，已核）。
> 記號：`W/` 指 `ios/WebHTVApp/Sources/WebHTVApp.swift`（HEAD 8877 行），`C/` 指 `ios/Sources/WebHTVCore/`，`A/` 指 `app/src/main/java/com/fongmi/android/tv/`，`M/LiveActivity` 指 `app/src/mobile/java/com/fongmi/android/tv/ui/activity/LiveActivity.java`，`G§n` 指 W-92 資料閘門 `artifacts/live-l1-data-gate-2026-10-13.md` 第 n 節，`#n` 指設定檔 `lives` 的第 n 個源（和 W-92 表格的編號一樣）。

---

## 0. 一頁摘要（給一般使用者）

**要做什麼**：讓 iOS 版能看設定檔裡的「直播」頻道。設定檔目前列了 20 個直播源，其中 13 個抓得到，合計約 2.4 萬個頻道、3.5 萬條線路（G§1）。iOS 現在完全沒有直播入口，這些頻道等於全部用不到。

**建議方案（C：照 iOS 的現況改編，不照搬 Android）**：
- 首頁上方 `WebHTV` 標題旁邊加一個「直播」按鈕，**不新增第 6 個分頁**。
- 按下去之後，左欄是群組，右欄是頻道。點頻道就用現有的播放器播放，原生和 MPV 兩個引擎都沿用。
- 在播放畫面中央上下快速一滑就換台，左右兩側的上下拖曳照舊調亮度和音量。
- 一條線路播不出來，就自動換下一條。每條線路最多等 15 秒；源有設 `timeout` 就用源的值，但不少於 10 秒。所有線路都試過還是不行，就顯示「此頻道目前無法播放」，**不會自己跳到別台**。
- 記住上次看的頻道，回來時可以一鍵繼續看。可以收藏頻道，收藏只在同一份設定、同一個直播源裡算數。
- 群組名稱帶密碼的（Android 會藏起來，要輸入密碼才看得到，很可能是成人內容）：**L1 一律隱藏**，密碼解鎖畫面留到 L2。
- 直播**不寫進**「片庫 → 記錄」，也**不會動到**點播的 10 秒起播逾時。

**L1 的實際範圍（一句話）**：讀設定檔 `lives` 裡 type 0 的 URL 源，解析 **m3u 和 txt** 清單（**不做 JSON**，因為 13 份清單裡一份 JSON 都沒有），從首頁入口進兩欄清單，用現有播放器播 http(s) 線路，加上上下滑換台、自動換線、記住上次頻道、收藏。

**明確不做**：DRM（ClearKey 和 Widevine）、P2P 類（`p3p`／`mitv`／`tvbus`、thunder）、csp `api` 型直播、YouTube 網頁、`video://` 嗅探、`parse=1` 解析、EPG 節目表、回看、密碼解鎖 UI、直播彈幕、低延遲控制、頻道台標、設定檔頂層的 `proxy` 欄位。遇到這類線路，畫面標示「iOS 不支援」，不能點、也不參與自動換線。

**不能保證的事**：W-92 只做了靜態分類和抽樣探測，**沒有實際播放過任何頻道**。62% 是「理論上 AVPlayer 能播」的估計，不是承諾。驗收只看指定樣本頻道在 Simulator 和實機上能不能播。

**需要使用者決定的事**（詳見 §12，回覆編號即可）：
1. 是否核准 L1，以及分 4 段實作的順序。
2. 每條線路的等待上限（建議 15 秒，源有設的話不少於 10 秒）。
3. 入口位置（建議首頁標題列按鈕）。
4. 帶密碼群組在 L1 隱藏（建議）。
5. JSON 清單不做（建議）。
6. 只有 `lives`、沒有 `sites` 的設定檔，L1 先不支援（建議）。
7. 進直播頁時不自動播放，只標出上次頻道並提供「繼續看」按鈕（建議）。

---

## 1. 範圍與 W-92 數據對應

### 1.1 L1 功能 → 資料支撐

| # | L1 功能 | W-92 資料支撐 | 決定 |
|---|---|---|---|
| F-1 | 讀設定檔 `lives`（寬鬆解碼） | 20 個 live 源，全部是 type 0 的 URL 清單，沒有 csp `api` 源（G§1-1） | 做。一個 live 欄位有錯不能拖垮整份設定（§6.1） |
| F-2 | `sites` 改成可選 | 本設定有 169 個 sites（本文件已核 `raw/config-wang-movie.json`）。資料**不需要**支援「只有 lives」的設定 | 只把 `sites` 解碼改成 `decodeIfPresent ?? []`。`ConfigLoader.validate` **不改**，所以只有 lives 的設定還是會被拒絕（§6.1、§12-6） |
| F-3 | txt 解析 | 10 份 txt（G§3） | 做 |
| F-4 | m3u 解析 | 3 份 m3u：#3、#7、#8（G§3） | 做 |
| F-5 | JSON 陣列清單 | **0 份**（G§3；本文件重掃 `L*.body` 也是 0） | **L1 不做**。遇到 JSON 陣列就顯示「此直播源格式 iOS 尚未支援」，不影響其他源（§12-5） |
| F-6 | ua／referer／origin／header 繼承 | 18 個源層 `ua`、1 個源層 `header`，1037 個頻道帶 ua 或 header。#17 的 10 行清單內設定影響 1034 個頻道（G§1-1、G§4） | 做。m3u 和 txt 的設定生命週期分開實作（§6.2） |
| F-7 | `#` 多線路與 `$` 線路名稱 | #9：564 頻道／2343 線路；#10：7255／9041；#6 有 154 條帶 `$` 後綴（G§3） | 做 |
| F-8 | `_` 群組密碼「只解析」 | #7 有 1 個帶 `_` 的群組（38 個頻道／46 條線路；W-124 修正 B-1，46 是 `#EXTINF` 筆數），#10 有 4 個 `#genre#` 群組帶 `_`；#17 有 15 個，但 #17 設了 `pass: true`（本文件重掃 L07／L10／L17 確認） | 做解析。**帶密碼的群組 L1 一律隱藏**（§6.2.6） |
| F-9 | 首頁入口＋群組／頻道兩欄 | 13 份清單有資料可以顯示 | 做（§6.4） |
| F-10 | 沿用 PlayerView／PlaybackSession 播放 | 靜態估計 AVPlayer 可播 62.26%，要看轉址 31.72%，MPV 2.49%（G§4） | 做。只送 http(s) 線路，rtmp／rtsp 「嘗試但不保證」（§6.3） |
| F-11 | 上下滑換台 | 是 UI 行為，資料只證明頻道數量值得做（單一群組可能有上千個頻道） | 做（§6.4.3） |
| F-12 | 出錯自動換線 | 有多線路的源很多（#9 平均每台 4.2 條線路） | 做。換線有自己的計時器，不只靠 `onFailure`（§6.3） |
| F-13 | 記住上次頻道 | UI 行為 | 做，排在第 4 段（§9 U4） |
| F-14 | 收藏 | UI 行為 | 做，排在第 4 段（§9 U4） |

**為什麼收藏和上次頻道還是放 L1**：上千個頻道的清單沒有這兩項就很難用。Android 這兩項也是直播的基本功能。不過它們排在最後一段（U4），使用者可以只核准 U1–U3，先看播放品質再說。

### 1.2 明確排除（L1 不做，UI 怎麼處理）

| 項目 | 資料量 | 歸屬 | UI 處理 |
|---|---|---|---|
| DRM：`#KODIPROP` license、ClearKey、DASH `manifest_type=mpd`（含 Widevine） | ClearKey 81、mpd 78，都只在 tv123（#3／#11）；Widevine 0 | L3（ClearKey）；Widevine 不承諾 | 解析時記成 `unsupported(.drm)`，整份清單照常解析。線路標「iOS 不支援」 |
| `p3p://`、`mitv://`、`tvbus://`、thunder | 合計 0.93% | 不承諾 | 「iOS 不支援」 |
| csp `api` 型直播（spider `liveContent`） | 本設定 0 個 | 不承諾 | 有 `api` 欄位的 live 源不列進直播源清單 |
| YouTube 網頁（`youtube.com`、`youtu.be`） | 2.21%，#20 全部是 | 不承諾 | 「iOS 不支援」。#20 整個源的頻道都會變灰 |
| `video://`（網頁嗅探） | 0.30% | L3 | 「iOS 不支援」 |
| `parse=1` 頻道 | #17 的 1034 個頻道 | L3 | 「iOS 不支援」（這些線路要先經過網頁解析） |
| `abc://`、格式錯誤的線路 | 0.08% | — | （W-124 修正 B-2）照 Android `isPlayableUrl`：含 `://` 就保留，標 `unsupported(.other)`「iOS 不支援」；沒有 `://` 的才丟（Android 也丟）。AC-5 #9＝2343 靠這條 |
| `proxy://` | 0 | — | 「iOS 不支援」 |
| 設定檔頂層 `proxy` 欄位（代理主機清單） | 本設定有，型別是 list | 不支援 | 忽略。W-92 直連就抓得到 raw.githubusercontent.com |
| 非 JSON 的設定網址（Android 會把整個網址當成單一直播清單，`A/api/config/LiveConfig.java:126-128`、`:153-155`） | — | 不支援 | 照舊走設定解碼失敗的錯誤訊息 |
| 直播彈幕、低延遲控制（LL-HLS 調校、追直播邊緣） | — | 不承諾 | 沒有 UI |
| 頻道台標（`tvg-logo`、源層 `logo` 樣板） | — | L2 以後 | L1 不載入圖片，只顯示文字 |
| `playerType` | 6 個源設 2（MPV） | L1 忽略 | 一律從全域預設引擎開始，失敗再換（§6.3.4） |

### 1.3 L2 只預留介面（L1 不實作、不驗收）

L1 解析器**只把原始字串存進資料模型**，不寫任何使用這些欄位的程式，也不另外定義沒有用到的 protocol：

| L2 功能 | L1 保留的欄位 | 日後的介面（只寫在文件，不寫成程式碼） |
|---|---|---|
| EPG `{name}/{date}` JSON API | `LiveSource.epg: String?`、`LiveChannel.tvgID`、`tvgName` | `func guide(for channel: LiveChannel, on day: Date) async throws -> [Programme]` |
| XMLTV `x-tvg-url`／`url-tvg` | `LivePlaylist.tvgURL: String?`（只在源沒有設 `epg` 時才填，和 `A/api/parser/LiveParser.java:106-108` 一樣） | 同上，資料來源換成 XMLTV |
| 回看（append／default／PLTV） | `LiveChannel.catchup: LiveCatchupRaw?`（type、source、replace 三個原始字串），清單標頭層的 catchup 存在 `LivePlaylist.catchup` | `func catchupURL(for line: LiveLine, programme: Programme) -> URL?` |
| 密碼群組解鎖 | `LiveGroup.password: String?` | `LiveStateStore.unlockedGroups`，解鎖畫面 |
| 頻道台標 | `LiveChannel.logo: String?` | — |

---

## 2. 研究證據（AGENTS.md §7）

所有外部來源的存取日期都是 **2026-10-15**，由本任務的研究子代理實際讀過原文，不是只看搜尋摘要。證據等級：**A**＝規格或官方原碼，**B**＝官方文件，**C**＝成熟專案原碼或文件，**D**＝論文或技術文章。

### 2.1 E-1 上游原碼

| 來源 | revision | 等級 | 支持的主張 | WebHTV 適用性／限制 | 對決策的影響 |
|---|---|---|---|---|---|
| 本 repo Android fork：`A/api/parser/LiveParser.java`、`A/bean/{Live,Channel,Group}.java`、`A/api/config/LiveConfig.java`、`M/LiveActivity.java`、`app/src/mobile/.../ui/custom/CustomKeyDown.java`、`A/player/PlayerManager.java` | HEAD `b1b20606…`；LiveParser 最後一次改動是 `eda307c7443a8894f89ffeb73ebcb477535ad8a8`（2026-08-09） | A | 清單格式判斷、setting 生命週期、繼承規則、密碼群組、收藏、記住上次頻道、換線、手勢的實際行為（§4） | 這是使用者 Android 版實際跑的程式，所以「和 Android 一樣」以它為準 | 解析規則全部以它為基準，iOS 只在 §5.3 列出的地方偏離 |
| 上游 FongMi/TV `LiveParser.java` | `28f504c491f902fbed1cff31d76d289b6e80de26`（2026-07-28，「Add cookie parsing for live playlists」），用 GitHub API 查到 | A | 上游最新的直播解析改動是 cookie 解析 | fork 的 `LiveParser.java:199` 已經有 `#EXTVLCOPT:http-cookie`，代表 fork 比上游這個 commit 新或已經包含它 | 用 fork 原碼就夠，不用另外對上游 |

### 2.2 E-2 官方規格

| 來源 | revision | 等級 | 支持的主張 | WebHTV 適用性／限制 | 對決策的影響 |
|---|---|---|---|---|---|
| RFC 8216（HLS），https://www.rfc-editor.org/rfc/rfc8216.txt | 2017-08，Informational | A | §4.3.3.4：`EXT-X-ENDLIST` 表示「不會再加入 Media Segment」。§6.3.4：沒有 ENDLIST 的清單，client **必須**定期重新載入。§6.3.3：不要從離結尾不到 3 個 target duration 的 segment 開始播 | 這是 W-86「沒有長度就當直播」的依據。有 DVR 視窗的直播 duration 可能是有限值，所以 duration 判斷**不是**完全可靠（§11 R-21） | L1 沿用 W-86 的 duration 判斷，不另外加旗標（§6.3.6） |
| Apple `AVPlayerItem.duration`（developer.apple.com tutorials JSON） | 文件頁沒有 revision | B | 「The value of duration may remain indefinite for live streams.」 | 和 W-86 的判斷一致 | 同上 |
| Apple AVURLAsset Initialization Options | 同上 | B | 公開的 option 一共 12 個，**沒有** `AVURLAssetHTTPHeaderFieldsKey`。有公開的 `AVURLAssetHTTPUserAgentKey`（iOS 16 以上）和 `AVURLAssetHTTPCookiesKey` | `W/:6432-6440` 用的是沒有公開文件的 header key。`C/PlaybackEngine.swift:120` 也寫著它「never been confirmed on a device」。App 的 deployment target 是 17.0（pbxproj），所以可以用公開的 UA key | 列為實機第一個驗證點（§11 R-15）。實機如果確認 header 沒送出去，最小補救是另開一張單，對 User-Agent 加上公開的 key。L1 不動 `asset(for:)`，因為它也是點播共用的 |
| Apple ATS：`NSAllowsArbitraryLoads`／`NSAllowsArbitraryLoadsForMedia` | 同上 | B | `NSAllowsArbitraryLoads` 會對所有網域關掉 ATS。如果同時有 `...ForMedia`，就會忽略 `NSAllowsArbitraryLoads` | `ios/WebHTVApp/Info.plist:5-9` 已經設了 `NSAllowsArbitraryLoads=true`，而且沒有 `...ForMedia` | `http://` 直播源不用改 ATS。L1 **不碰** Info.plist（加 `...ForMedia` 反而會讓現有的全域例外失效） |
| M3U／`#EXTINF` | — | — | **沒有正式規格**。只有事實上的格式（Winamp extended M3U、IPTV 圈的 `tvg-*`／`group-title` 慣例） | 事實標準以 Kodi pvr.iptvsimple README 為準（E-3） | 解析器照 Android 的實際行為寫，碰到有爭議的地方參考 Kodi |
| VLC `modules/access/http/access.c` | `f1369aeb95f89d1afb8ebec4403c30b45ff3e863`（3.0.x） | A | 定義了 `http-referrer`（送 `Referer`）和 `http-user-agent` 兩個 option，標記為 `change_safe`，也就是可以對單一 input 設定 | `#EXTVLCOPT:http-user-agent`／`http-referrer` 是單一項目的設定，和 Android m3u「每條網址之後清掉」的行為一致 | 支持 m3u 的 setting 每條網址之後就清掉 |
| Kodi `#KODIPROP`（inputstream.adaptive） | 見 E-3 | C | `#KODIPROP` 是傳給 Kodi 的 `key=value` | L1 只辨識出來，不實作 | 標成 L3 排除項 |
| XMLTV | — | — | L1 不適用（EPG 屬於 L2），L2 再查 | — | — |

### 2.3 E-3 成熟相關專案

| 來源 | revision | 等級 | 支持的主張 | WebHTV 適用性／限制 | 對決策的影響 |
|---|---|---|---|---|---|
| Kodi pvr.iptvsimple README（Omega 分支） | `2b34dec5be76955722b97da4dc8f870724f07310`（2025-04-13）。預設分支已經改成 Piers（`4bf3de80…`），本次只讀 Omega | C | `group-title` 可以用分號列多個群組。catchup 支援 `default`／`append`。`#EXTVLCOPT` 的 `http-user-agent`／`http-referrer` 會加到該網址上。網址後面接 `\|user-agent=…` 可以設 header。`x-tvg-url` 只在設定裡沒有 EPG 位置時才用 | 「`\|` header 屬於那一條網址」是 Kodi 的語意。Android txt 會讓 `\|` header 一直沿用到下一個 `#genre#`，這是 Android 的副作用 | iOS 的 `\|` header **只套用在該條線路**（修正，§5.3）。分號多群組 L1 不做（Android 也不做） |
| iptv-org iptv-playlist-parser `src/index.js` | `b6a3d65881b6d99957522b59185701f108ad43aa`（0.15.2，2026-03-01） | C | 屬性只認雙引號。`#EXTVLCOPT` 會蓋掉 `#EXTINF` 的值。**不支援一台多線路**：沒有新的 `#EXTINF` 就出現的第二行網址會被丟掉 | 本設定的 m3u 靠「連續網址行」和「同名合併」做多線路，這個 parser 不能直接用 | 不引入外部 parser。自己寫，照 Android 的同名合併 |
| M3UKit（Swift） | tag 0.8.1 `a84b4d72…`；main 最後一次 commit `b1bcb665…`（2024-06-14），看起來已經沒在維護 | C | 支援 tvg-* 和 group-title，有 async 解析。README 宣稱能解析數十萬項，但沒有附 benchmark。**不處理** `#EXTVLCOPT` 和 header，**不支援** txt | 缺 header、txt、setting 行，拿來用也要大改 | 不加這個依賴（加了也只能解決一小部分，還多一個沒人維護的套件） |
| IPTVnator（`libs/m3u-state/.../favorites.reducers.ts` 等） | master `2139ddd5c0ee31ad592c4611a294f36cde68865e`（2026-10-14） | C | M3U 收藏**以頻道網址當 key、按播放清單分開存**。跨來源的統一收藏用 `{sourceType}::{playlistId}::{sourceItemId}` | 「按清單分開」跟本設計一致。用網址當 key 不適合本資料，因為 tv123 的網址帶會過期的 `sid` | 收藏 key 用「設定來源＋直播源名稱＋頻道名稱」（§6.5）。有沒有自動回到上次頻道：**沒有確認**（沒讀它的測試） |

上千頻道的效能：上面幾個專案都沒有可以引用的量測。Android 的同名合併是線性搜尋（`A/bean/Group.java:141-152`），O(n²)。iOS 改用字典索引（§6.2.8），量測目標寫在 §7 AC-24。

### 2.4 E-4 論文／技術文章／實測報告

| 來源 | revision | 等級 | 支持的主張 | WebHTV 適用性／限制 | 對決策的影響 |
|---|---|---|---|---|---|
| Fleury, Pedersen, Larsen，〈Acceptable Channel Switching Delays for Mobile TV〉，EuroITV '11，DOI 10.1145/2000119.2000159（預印本 https://vbn.aau.dk/ws/files/74627597/euroitv_amf.pdf） | 2011 | D | 文中引用 ITU：換台延遲建議低於 2 秒。他們自己的行動裝置實驗：**超過 5.7 秒會讓受試者不耐煩**。DVB-H 行動電視的典型值是 6–8 秒 | 本專案的線路來自不穩定的公開源，L1 **不承諾低延遲**。這個數字拿來設定「卡住多久要換」的合理範圍 | 換線計時不宜太長，15 秒已經接近使用者忍耐的上限。所以不採「原生 10 秒＋MPV 20 秒＝30 秒」的疊加（§6.3.3） |
| TU Delft 2012 zapping 論文（nas-new.ewi.tudelft.nl） | — | — | **取不到**：TLS「unable to verify the first certificate」，研判是公司 Fortinet 攔截 | — | 不影響決策，已經有上一筆可以用 |
| Apple WWDC 直播串流場次 | — | — | **取不到可用的內容**：抓到的頁面只有影片索引，沒有逐字稿 | — | 不影響決策。L1 不做低延遲調校 |

### 2.5 研究邊界與未解閘門

這次研究只回答一個決策問題：「L1 的解析、換線、儲存要照 Android 到什麼程度，哪些要改編」。下面幾項**不能**靠讀文件解決，要到實作階段才能驗證，所以列為閘門，不在這裡下結論：

- G-1：AVPlayer 用沒有公開文件的 key 帶 header，在實機上有沒有效（R-15）。
- G-2：MPVKit 有沒有編進 rtmp 和 rtsp（R-16）。
- G-3：`.php` 和無副檔名的線路，轉址到 FLV 時 AVPlayer 是報錯還是卡住（R-18）。這會決定「起播失敗」和「起播逾時」兩種情況各占多少，但兩種都已經有換線機制，所以不影響設計，只影響換線要等多久。

---

## 3. iOS 現況（HEAD `b1b20606`）

| 主題 | 位置 | 現況與設計含意 |
|---|---|---|
| 設定模型 | `C/WebHTVConfig.swift:3-40`；`CodingKeys` `:19-21` 只有 `sites, ads, rules, spider, parses, flags` | 不讀 `lives` |
| `sites` 嚴格解碼 | `C/WebHTVConfig.swift:32-37`（`values.decode([Site].self…)`，接著回填 `jar` 和 `parsing`） | 缺 `sites` 就丟 `keyNotFound`。改成可選時，`jar` 和 `parsing` 的回填要原樣保留 |
| 寬鬆解碼的既有做法 | `C/WebHTVConfig.swift:27-29`（`try? decodeIfPresent([Lenient<T>])`）；`Lenient` 在 `C/GlobalParse.swift:77-80` | `lives` 照這個做法 |
| 驗證 | `C/ConfigLoader.swift:51-62`（`:58-60`：沒有 native CMS 也沒有可跑的 spider，就丟 `noSupportedSites`）；錯誤訊息在 `:35` | 只有 lives 的設定會被拒絕。L1 不改（F-2） |
| 解碼 | `C/ConfigLoader.swift:41-47`（`allowsJSON5`） | 不改 |
| 設定使用端 | `W/:452-458`（`rebuildSites`）、`W/:485-491`（`adopt`）、`W/:575-579`（`restore`） | 這三處都是在設定採用時重算 `sites`，`lives` 也要在同樣這三處設定 |
| 快取 | 存的是驗證過的原始 bytes（`C/ConfigLoader.swift:64-66`，`W/:487` 直接寫檔） | 舊快取重新解碼就會有 `lives`，**不用遷移** |
| 沒有設定時的畫面 | `W/:151`（`if sites.isEmpty` 顯示「尚未載入設定」） | 這也是 lives-only 設定不支援的另一個原因：要改主畫面的門檻 |
| 分頁 | `W/:178-234` 五個分頁：首頁(0)、搜尋(3)、片庫(1)、下載(4)、設定(2)。**系統 tab bar 是隱藏的**（`.toolbar(.hidden, for: .tabBar)`），實際顯示的是自製的 `CinematicTabBar`（`W/:677-700`，五個等寬按鈕） | 加第 6 個分頁**不會**出現系統的「更多」（更正審查清單 T-5 的前提），但會把 5 個等寬按鈕擠成 6 個，在大字體下更容易截字。`W/:191-192` 的 IOS-POC-48 已經有先例：為了避免第 6 個分頁，把收藏和記錄合併成「片庫」 |
| 首頁標題列 | `W/:879` `private struct HomeView`；`W/:1070-1086` `homeHeader`（「WebHTV」標題＋來源切換按鈕） | 入口按鈕放在這裡（§6.4.1） |
| PlaybackSession | `W/:4759-4760`（`@MainActor final class`，`static let shared`） | internal，同一個 App target 的新檔案可以直接用 |
| 開播 | `W/:5314-5365` `open(url:headers:…history:…retry:…)`；`history == nil` 就不讀也不寫觀看紀錄（`W/:5338-5342`）；`W/:5368-5375` `open(_ target:)` | 直播用 `open(url:headers:title:history: nil, retry: nil)` |
| 寫入觀看紀錄 | `W/:5539-5548` `persist`：`guard let current = record …`；W-110 的 `measured` 閘門在 `C/WatchHistory.swift:217-223`（`position > 0` 而且 `started \|\| duration > 0`） | `record` 是 nil，`persist` 一開頭就 return，W-110 閘門根本不會執行到。直播**不會**寫進 `history.json` |
| 觀看紀錄頁 | `W/:3222-3227`（`duration` 不大於 0 就顯示「看過」） | 直播沒有紀錄，所以不會冒出一堆「看過」 |
| 載入 | `W/:6084-6141` `load`：一開始就呼叫 `onFailure?(nil)` 清掉錯誤（`W/:6092`），接著 `watchStartup()`（`W/:6129`）、`router.open(...)`（`W/:6137`） | 換線監聽要忽略 `onFailure(nil)` |
| 起播監看 | `W/:6252-6300` `watchStartup`：原生 10 秒、MPV 20 秒；AirPlay／PiP 時原生也用 20 秒（`W/:6266-6271`）；逾時呼叫 `router.startupTimedOut()`（`W/:6279`）；起播成功時設定 `startupMilliseconds`（`W/:6286-6293`） | 起播成功的那一刻就是換線計時器取消的掛點 |
| 引擎選擇 | `C/PlaybackEngine.swift:76-79` `startSession`（回到全域預設）、`:83` `beginAttempt`（**引擎維持原樣**，只重置備援額度）、`:95-100` `fallback`（每次嘗試最多換一次）；`PlayerRouter.open` 在 `:405-415`（session 已經開著就走 `beginAttempt`） | 換台時會一直停在 MPV（R-4）。§6.3.4 處理 |
| 起播逾時不算失敗 | `C/PlaybackEngine.swift:449-462` `startupTimedOut`：「**Never shown as a failure.**」換不了引擎就什麼都不做 | 換線不能只掛 `onFailure`（R-3） |
| 起播逾時秒數 | `C/PlaybackEngine.swift:445-447`（原生 10、MPV 20；`:435-443` 的註解記錄使用者 2026-10-06 指定原生 10 秒） | **不改** |
| 失敗種類 | `C/PlaybackEngine.swift:127-148`（`offline`、`source` 不換引擎，其他會換） | 換線看的是「已經沒辦法再換引擎」之後送出的失敗 |
| 不可恢復的失敗 | `W/:5047-5064`（`router.onUnrecoverable` → 有 `retryWithoutPrefetch` 就先重試一次，否則 `onFailure`） | 直播傳 `retry: nil`，不會多重試 |
| 回呼的擁有者 | `W/:8236-8263`：PlayerView 出現時設定 `session.onFailure`／`onNotice`／`onEngineChange`，關閉時清成 nil | 這些是**單一槽位**，已經被 PlayerView 用掉。直播控制器要另外有自己的觀察槽（§6.3.5） |
| header 傳遞 | 原生：`W/:6432-6440`（沒有公開文件的 asset option）；MPV：`ios/WebHTVApp/Sources/MPVEngine.swift:588-589`（`http-header-fields`） | 沿用 |
| W-86 直播判定 | 原生 duration：`W/:6576`；網路策略 `W/:5443` → `.liveOrUnknown`；重載位置 `W/:5393`；總長顯示 `--:--` `W/:7020-7021`；MPV duration `MPVEngine.swift:1040`；不續播 `C/WatchHistory.swift:152` 的註解、`:206` `startPosition` | 只看執行時的 duration |
| PlayerView | `W/:8041` **`private struct PlayerView`**；使用處 `W/:2496`、`:3958`、`:8602`、`:8610`（都是 `fullScreenCover { PlayerView() }`） | 不改存取等級，改用同檔的 internal 包裝（§6.6） |
| 播放器手勢 | `W/:8203-8207`（`simultaneousGesture(DragGesture(minimumDistance: 12))`）；`W/:8438-8441` `classify`：水平是拖進度，垂直時左半邊調亮度、右半邊調音量 | **整個畫面的垂直拖曳都已經被占用**，上下滑換台會直接衝突（§6.4.3） |
| log 遮罩 | `C/PlaybackActivity.swift:159-174`（`urlSummary` 只留 host 和副檔名；`comment`）；`[playback]` log 用 `privacy: .public` 記 `itemTitle`（例如 `W/:6280`） | header 和網址沿用 `urlSummary`。頻道名稱的處理見 §6.7 |
| 收藏（點播） | `C/Favorites/Favorite.swift:15-37`（`FavoriteIdentity`＝configSourceID＋siteID＋vodID）；`C/Favorites/FavoriteStore.swift:20-23`（actor、`favorites.json`）、`:11`（壞檔另存成 `favorites.corrupt-…`）、`:166`、`:194`（schemaVersion） | 直播頻道沒有 siteID／vodID，不適用。另外開一個檔案 |
| 觀看紀錄儲存 | `C/WatchHistory.swift:289`（`WatchHistoryStore` actor）、`:303`（`history.json`） | 不使用 |
| 清除無效檔案 | `C/StorageMaintenance.swift:64-65`（`supportKeep` 白名單）、`:95-110`（Application Support 裡不在白名單上的項目一律列成 `.unknown` 等著刪）；`:150-158` `clearAll` 清掉全部 | **新的 `LiveTV` 資料夾一定要加進 `supportKeep`**，不然「清除無效檔案」會把收藏刪掉。「重設」會一起清掉，這是預期行為 |
| 設定來源身分 | `C/ConfigSource.swift:28-33` `identity`（匯入檔是自己的 id，遠端是網址） | 收藏和上次頻道用它分開存 |
| 相對路徑 | `C/ConfigSource.swift:51` `resourceURL(for:)` | live 的 url 如果是相對路徑就用它（本設定 20 個都是絕對網址） |
| 播放目標 | `C/SourceClient.swift:213-239` `PlaybackTarget`（url＋headers） | 一條線路對應一個 target |
| 離線下載 | `C/Offline/OfflinePackage.swift:141`（直播串流拒絕下載） | 直播畫面不提供下載 |
| Xcode 專案 | pbxproj 逐檔明列，沒有 synchronized group。先例是 `MPVEngine.swift`：`project.pbxproj:22`（PBXBuildFile）、`:36`（PBXFileReference）、`:111`（group）、`:226`（Sources phase） | App target 新增的檔案要改這 4 處。Core 的檔案由 SwiftPM 自動收錄（`ios/Package.swift:10`） |
| 測試 | `ios/Tests/WebHTVCoreTests/ConfigSourceTests.swift:46-57`（`{"sites":[]}` 要丟 `noSupportedSites`）、`ConfigLoaderTests.swift`、`GlobalParseTests.swift`；testTarget 沒有 resources（`ios/Package.swift:12`），fixture 都是內嵌字串 | 新的 fixture 也用內嵌字串，不放真實清單（避免成人內容進 repo） |
| ATS | `ios/WebHTVApp/Info.plist:5-9` `NSAllowsArbitraryLoads = true` | http 直播源不用改 |
| 名稱很像但無關的檔案 | `ios/WebHTVApp/Sources/PythonLiveCheck.swift` | Python spider 的自檢，和直播電視無關（G§7） |

---

## 4. Android 對照（fork 原碼，`app/` 自 `644a2b16` 起沒有改動）

| 主題 | 位置 | 行為 |
|---|---|---|
| Live 欄位 | `A/bean/Live.java:37-121` | `name, url, type, playerType, api, ext, jar, click, logo, epg, ua, origin, referer, timeZone, keep, timeout(Integer), header(Map，HeaderAdapter), catchup, core, groups, boot, pass(boolean)` |
| 逾時 | `A/bean/Live.java:253-255`；`A/Constant.java:13` | 沒設就用 15 秒；有設就用設定值，最少 1 秒。#16、#17 設 5 秒 |
| 播放逾時的效果 | `A/player/PlayerManager.java:425`（`callback.onError(error_play_timeout)`）→ `M/LiveActivity:1352-1359` `onError` → `startFlow` | **逾時就算失敗**，接著換線（和 iOS 不同） |
| 抓清單 | `LiveParser.java:66-69`、`Live.java:382-388`（header 加上 ua／origin／referer） | 抓清單時帶源層 header。清單逾時 30 秒（`Constant.java:10`） |
| 格式判斷 | `LiveParser.java:23`、`:59-64`、`:71-76` | JSON 陣列 → 有 `#EXTM3U` 而且同一行沒有 `#genre#` → 其他都是 txt |
| m3u | `LiveParser.java:93-135` | 標頭的 catchup 和 tvg-url（`:102-108`）；`#EXTINF` 取 name、group-title、`http-user-agent`、tvg-*、catchup（`:109-126`）；說明用的頻道直接跳過（`:111-114`）；網址行 `url\|header`（`:127-131`）；**每條網址之後 `setting.copy(channel).clear()`（`:132`）** |
| txt | `LiveParser.java:137-160` | `#genre#` 開新群組並 `setting.clear()`（`:144-145`）；`,` 右邊用 `#` 切多條線路（`:148`）；`\|` header 寫進 setting（`:154`），**不會清掉**；沒有群組時建預設群組（`:151`）；同名頻道合併（`:153`） |
| 換行 | `LiveParser.java:97`、`:139` | `\r\n` 換成 `\n`，再把**單獨的 `\r` 直接刪掉**（不是當成換行） |
| Setting 行 | `LiveParser.java:185-209` | 用 `startsWith("ua")` 這種方式比對前綴（沒有要求後面接 `=`） |
| Setting 套用 | `LiveParser.java:211-221` | 只蓋掉有值的欄位；`header` 是整包取代 |
| header 解析 | `LiveParser.java:331-369` | `#EXTHTTP:`／`header=` 是 JSON；`headers=`、`\|`、`&` 是 `k=v` |
| 頻道繼承源層 | `A/bean/Channel.java:359-368` | ua、origin、referer **各自**在頻道值是空的時候才用源層的值；**header 整包取代**（`:362`） |
| 播放 header | `Channel.java:370-376` | header 加上 UA／Origin／Referer，後三者蓋掉 header 裡的同名鍵 |
| `$` 線路名稱 | `Channel.java:323-327`（播放網址切掉 `$` 後面；有 DRM 時不切）、`:347-352`（`$` 後面當線路名，沒有就顯示「線路 n」） | — |
| 頻道層 header 的存放 | `Channel` 一個頻道只有**一組** ua／header（不是每條線路各一組） | 同名合併時，後面那條線路的 setting 會蓋掉前面的（Android 的副作用） |
| 群組密碼 | `A/bean/Group.java:37-42`、`:62-67`、`:117` | 名稱有 `_` 時，**名稱一律截到 `_` 之前**；`live.pass` 為 false 時，`_` 後面的部分當密碼。有密碼就是 `isHidden` |
| 隱藏群組 | `M/LiveActivity:476-481`（hidden 的群組放進 `mHides`，不顯示）；`:1479-1491` `unlock` | 輸入密碼才顯示 |
| 收藏 | `M/LiveActivity:1026-1033`（長按；**隱藏群組不能收藏**）、`:1048-1054`（`Keep` type=1，**key 只有頻道名**）；`A/api/config/LiveConfig.java:216-222`（套用時連隱藏群組也一起掃） | 跨源同名頻道會被當成同一個收藏 |
| 記住上次頻道 | `LiveConfig.java:212-214`（隱藏群組不記）；`Live.java:349-352`（存成 `群組@@@頻道@@@目前網址`）；`LiveConfig.java:224-238`（依群組名＋頻道名找回，再用網址還原線路；找不到就回 `{1,0}`） | 存的是**完整網址**，包含 `sid` 這類 token |
| 自動換線 | `M/LiveActivity:1527-1530` `startFlow`（`LiveSetting.isChange()` 打開，而且不是最後一條線路才換，**不會繞回**）、`:1583-1589` `nextLine`、`:1214-1220` | 從第 k 條開始的話，只會試 k 到最後一條 |
| 換台 | `M/LiveActivity:1556-1572`（`isAcross()` 決定到頭時是跨群組還是在群組內繞回）、`:1532-1554`（跨群組時跳過收藏群組） | — |
| 手勢 | `CustomKeyDown.java:104-108`（`isSide`：畫面寬度的左 1/4 和右 1/4）、`:137-147`（拖曳）、`:163-187`（fling：**不在兩側**、角度大於 70°、距離超過 100px 才換台）、`:189-193`（兩側才調亮度和音量） | 換台和亮度／音量**用畫面區域分開**，所以不衝突 |
| playerType | `A/setting/PlayerSetting.java:11-13`（EXO=0、IJK=1、MPV=2） | 取自 G§6 |

---

## 5. 三案比較

### 5.1 三個方案

- **A. 不做（no change）**：維持現狀。20 個源、13 份清單、24,295 個頻道全部用不到（G§1）。Android 和 iOS 的功能落差一直存在。
- **B. 照搬 Android**：把 LiveActivity、LiveParser、Keep 這套原封不動移植過來，包含 JSON 清單、`LiveSetting` 的各種開關（isChange／isAcross／isInvert）、單一引擎加逾時就當失敗、收藏只用頻道名當 key、上次頻道存完整網址、密碼解鎖 UI、`playerType` 指定引擎、線性合併、txt 的 `|` header 一路沿用下去。
- **C. WebHTV 改編（建議）**：解析規則照 Android 的**實際行為**寫（確保 #17 這種清單得到一樣的 header）；播放、儲存、入口、手勢則照 iOS 現有的架構改編。逐項差異見 §5.3。

### 5.2 逐項比較

| 面向 | A 不做 | B 照搬 Android | C 改編（建議） |
|---|---|---|---|
| 正確性 | 不適用 | 解析和 Android 一致。但 txt 的 `\|` header 會一路沿用、同名合併時 header 互相蓋掉，這些副作用也會一起照搬 | 解析和 Android 一致；只修正 3 個有明確證據的副作用（§5.3） |
| 相容性（點播不能壞） | 不受影響 | 要動 `sites` 解碼和 validate，還要接受只有 lives 的設定，回歸面大 | `lives` 寬鬆解碼；`validate` 不改；點播行為不變（AC-1～AC-4） |
| 效能 | 不適用 | 線性合併 O(n²)，#10 有 7,255 個頻道 | 字典索引 O(n)；解析不在 main thread（AC-24） |
| 品質／UX | 沒有直播 | Android 的設定項 iOS 都沒有。逾時疊加：Android 15 秒加上 iOS 雙引擎的 10＋20 秒，或者只用單一引擎、放棄 MPV 備援 | 每條線路有時間上限；同一條線路內保留換引擎的機會；手勢照 Android 用畫面區域分開 |
| 生命週期（換台、背景、PiP） | 不適用 | Android 的 service／Activity 模型對不上 iOS | 完全沿用 PlaybackSession 現有的背景、PiP、AirPlay 行為 |
| ABI／native | 無 | 無 | 無（不動 MPVKit 和 FFmpeg） |
| 安全與隱私 | 無 | 上次頻道存完整網址（含 `sid`）；收藏跨源串在一起；隱藏群組的頻道可能透過收藏露出來（`LiveConfig.java:216-222` 掃的是全部群組） | 不存網址，只存線路名稱或序號；收藏 key 包含設定來源和直播源；隱藏群組完全不參與；header 和網址不進 log |
| 成人內容 | 無 | 照搬密碼 UI（L1 範圍外） | L1 隱藏帶密碼的群組；fixture 不放真實名稱 |
| 來源可追溯 | — | 高 | 高。每個偏離都在 §5.3 附理由 |
| 維護 | 無 | 要維護一套和 iOS 架構不合的移植 | 解析器、換線狀態機、儲存都是 Core 裡的純 Swift，可以單元測試 |
| 驗證成本 | 0 | 高（每個 LiveSetting 組合都要測） | 中（§8） |
| 上線 | — | 一次全上 | 分 4 段，每段可以單獨上 |
| 回滾 | — | 很難 | 每段都可以單獨 `git revert`（§10） |
| 結論 | 不建議：數據顯示需求真實存在 | 不建議：照搬的副作用和架構衝突比改編的工作量還大 | **建議**：表上沒有未處理的紅燈；剩下的風險都是實機才能驗的閘門（G-1～G-3） |

### 5.3 C 案對 Android 的每一處偏離（§7 要求寫明是優化、修正、補充還是拒絕）

| # | Android 行為 | C 的做法 | 類型 | 理由 |
|---|---|---|---|---|
| X-1 | JSON 陣列清單 | 不做 | 拒絕（L1） | 0／13 份清單；只能用自製 fixture 驗證 |
| X-2 | 逾時就當播放失敗，單一引擎 | 每條線路一個時間上限（§6.3.3）；上限內保留換引擎的機會 | 改編 | iOS 的起播逾時本來就不算失敗（`C/PlaybackEngine.swift:449-462`），而且雙引擎是 iOS 的優勢 |
| X-3 | 從第 k 條線路開始只試到最後一條，不繞回 | 每台每次開播時，所有支援的線路都試一次（會繞回），試完就停 | 修正 | 從記住的線路開始時，Android 會漏掉第 k 條之前的線路 |
| X-4 | txt 的 `\|` header 一路沿用到下一個 `#genre#` | `\|` header 只套用在那一條線路 | 修正 | Kodi 的語意是「`\|` 屬於那一條網址」（E-3）；W-92 資料裡 `\|` header 是 0，所以這個修正不會改變現有資料的結果 |
| X-5 | 頻道只有一組 ua／header，同名合併時後面的會蓋掉前面的 | header 存在每條線路上（`LiveLine.headers`） | 修正 | 同一台的不同線路可能來自不同主機，需要不同的 UA |
| X-6 | 單獨的 `\r` 直接刪掉 | 單獨的 `\r` 當成換行；並且去掉 UTF-8 BOM | 修正 | Android 遇到只用 `\r` 換行的檔案，所有行會黏成一行。13 份清單都沒有這兩種情況（本文件已掃），所以結果相同 |
| X-7 | setting 行用 `startsWith("ua")` 比對 | 要求 `key=` 的形式（`ua=`、`parse=` 等）；`#EXTHTTP:`／`#EXTVLCOPT:`／`#KODIPROP:` 照舊 | 修正 | Android 的實作要那一行同時含有 `ua=` 才會真的取值，所以實際結果一樣；這樣寫可以避免名稱是 `ua` 開頭的頻道被誤判 |
| X-8 | 同名合併用線性搜尋 | 每個群組一個 `[name: index]` 字典 | 優化 | O(n²) → O(n) |
| X-9 | 收藏只用頻道名當 key | 設定來源 identity＋直播源名稱＋頻道名稱 | 修正 | 避免跨源同名互相影響。不加群組名，這樣清單作者改群組名時收藏還在 |
| X-10 | 上次頻道存 `群組@@@頻道@@@完整網址` | 存群組名、頻道名、線路名稱（`$` 後綴）和線路序號，**不存網址** | 修正 | 網址可能帶 `sid` 這類 token，存下來會讓 token 落地；而且 token 過期後網址也比對不到 |
| X-11 | 收藏套回時連隱藏群組也掃 | 只比對看得見的群組 | 修正 | 不讓帶密碼群組的頻道透過收藏露出來 |
| X-12 | `playerType` 指定引擎 | L1 忽略，一律從全域預設引擎開始 | 拒絕（L1） | 真正有影響的只有 #5、#6（#1、#2、#19 抓不到，#20 全是 YouTube）。直接用 MPV 會讓 HLS 失去 AirPlay／PiP 而且起播比較慢；現有的自動換引擎已經能接住 FLV／TS |
| X-13 | `LiveSetting` 的 isChange／isAcross／isInvert 開關 | 不做設定項：自動換線固定開啟，換台固定在群組內繞回，方向固定（往上滑＝上一台） | 拒絕（L1） | 每多一個開關就多一組測試組合；先用 Android 的預設值 |
| X-14 | 密碼群組輸入密碼解鎖 | L1 只解析，一律隱藏 | 補充（分到 L2） | 見 §6.2.6 |
| X-15 | 打開直播頁就自動播上次的頻道 | 只標出上次頻道並提供「繼續看」按鈕 | 改編 | iOS 進頁面就出聲比較突兀，也可能吃行動網路；這點交給使用者決定（§12-7） |
| X-16 | m3u 的 `Live.find` 只用名稱合併群組（`Live.java:324-327`），先出現 `X`、後出現 `X_密碼` 時，帶密碼群組的頻道會併進可見群組 | 合併 key 用「名稱＋密碼」，帶密碼群組永遠自成一組 | 修正（W-124，N-4） | 不讓帶密碼的頻道透過同名可見群組露出來；W-92 資料沒有這種碰撞（#7 已核），數字不變 |
| X-17 | 任何一個欄位型別錯，`Live.objectFrom` 的 catch 回傳空 `Live()`，接著被 `removeIf(Live::isEmpty)` 拿掉（`LiveConfig.java:200-205`、`Live.java:137-147`） | 逐欄容錯，保留這個 live（`type` 讀不出來時不收，以免把 csp 源當 URL 清單） | 改編（W-124，N-2） | AC-2 要求一個欄位壞掉不拖垮整個 live；本設定 20 個源都沒有型別錯誤 |
| X-18 | txt 的 setting 行（例如 `ua=… KHTML, like Gecko`）也會當成頻道行再處理一次 | setting 行只當 setting，不再當頻道行 | 修正（W-124，X-7 補充） | Android 只在 setting 行逗號右邊剛好含 `://` 時才會多出假頻道；13 份清單統計和 Android 完全一致，證明現有資料沒有這種行 |
| X-19 | header map 分大小寫（HashMap），`user-agent` 和 `User-Agent` 會同時存在 | 寫入 header 時不分大小寫取代同名鍵 | 修正（W-124） | 避免同一個 header 送兩次；現有資料影響是 0 |
| X-20 | 線路網址原樣存（只在 `isPlayableUrl` 判斷時 trim），播放時才切 `$` | 解析時就 trim 並切 `$`（`LiveLine.url`／`label`） | 修正（W-124） | 前後有空白的網址 `URL(string:)` 會回 nil（#6 有 76 條、#17 有 24 條） |

---

## 6. 設計

### 6.1 設定解碼（Core）

```swift
// C/WebHTVConfig.swift（示意）
public let lives: [LiveSource]
case sites, ads, rules, spider, parses, flags, lives
sites = ((try values.decodeIfPresent([Site].self, forKey: .sites)) ?? []).map { … }   // map 內容原樣保留
lives = ((try? values.decodeIfPresent([Lenient<LiveSource>].self, forKey: .lives)) ?? nil)?
          .compactMap(\.value).filter(\.isURLList) ?? []
```

- `sites` 只把「缺鍵」改成空陣列；**有 `sites` 但裡面有壞資料時照舊丟錯**（保留目前嚴格解碼的行為，不在本任務擴大範圍）。`jar` 和 `parsing` 的回填照舊。
- `lives` 有兩層保護：外層 `try?`（`lives` 不是陣列時）＋內層 `Lenient`（單一個 live 壞掉時）。`LiveSource.init(from:)` 每個欄位都用 `try?` 加型別容錯：`timeout` 接受整數或數字字串；`pass` 接受布林、`"true"`（W-124 修正 N-1：字串照 Android Gson，`"1"` 是 false；數字 `1` 當 true 是**偏離**——Android `Live.pass` 是基本型別 `boolean`，Gson 遇到數字會拋錯、整個 live 被丟掉，iOS 保留並把非 0 當 true，屬 X-17 那類寬鬆偏離；W-125 依 W-124 審查 N-1 更正）；`header` 接受 JSON 物件（其他型別就忽略）；`type` 缺少時當成 0。`name` 或 `url` 是空的就丟掉這個 live。
- `isURLList`：`type == 0`（或沒有 type），`api` 是空的，`url` 不是空的。本設定 20 個全部符合，#20 雖然有 `jar` 但沒有 `api`，所以照樣收進來。
- `ConfigLoader.validate` **不改**：只有 lives、沒有 sites 的設定，照舊丟 `noSupportedSites`（L1 的邊界，§12-6）。`ConfigSourceTests.swift:55` 的 `{"sites":[]}` 照舊被拒絕。
- 快取不用遷移（§3）。
- `W/` 在三個採用點（`:452-458`、`:485-491`、`:575-579`）加一行 `lives = config.lives`。`@State var lives: [LiveSource]` 傳給 `HomeView`。

### 6.2 清單解析（Core，`C/Live/LivePlaylistParser.swift`）

資料模型（`C/Live/LivePlaylist.swift`）：

```swift
public struct LivePlaylist { groups: [LiveGroup]; tvgURL: String?; catchup: LiveCatchupRaw? }
public struct LiveGroup   { name: String; password: String?; channels: [LiveChannel]; var isHidden: Bool { password != nil } }
public struct LiveChannel { name: String; lines: [LiveLine]; tvgID, tvgName, logo: String?; catchup: LiveCatchupRaw? }
public struct LiveLine    { url: String /* 已切掉 $ */; label: String? /* $ 後綴 */; headers: [String: String]; support: LineSupport }
public enum LineSupport   { case playable, attempt /* rtmp／rtsp */, unsupported(Reason) }   // Reason: drm, p2p, youtube, sniff, parse, proxy
```

#### 6.2.1 文字前處理
1. 先用 UTF-8 解碼；失敗就用 GB18030；兩種都失敗，就顯示「清單編碼無法辨識」（13 份清單全部是 UTF-8，本文件已掃）。
2. 去掉開頭的 BOM。`\r\n` 換成 `\n`，單獨的 `\r` 也換成 `\n`（X-6）。

#### 6.2.2 格式判斷（順序和 Android 一致）
1. 修剪空白後以 `[` 開頭，而且能解析成 JSON 陣列 → `unsupportedFormat`（X-1）。
2. 用 regex `^(?!.*#genre#).*#EXTM3U.*`（multiline）找得到 → m3u。
3. 其他都當 txt。

#### 6.2.3 Setting 行（m3u 和 txt 共用的解析，生命週期不同）
- 認得的形式：`ua=`、`parse=`、`click=`、`header=`（JSON）、`format=`、`origin=`、`referer=`、`forceKey=`、`#EXTHTTP:`（JSON）、`#EXTVLCOPT:http-user-agent=`／`http-referrer=`／`http-origin=`／`http-cookie=`、`#KODIPROP:inputstream.adaptive.*`（X-7）。
- 值的處理和 `LiveParser.java:223-249` 一樣：去掉前後空白和 `"`。`#EXTVLCOPT:http-referrer` 寫進 Referer。`http-cookie` 寫進 header 的 `Cookie`。
- `#KODIPROP` 有 `license_key`／`license_type`，或者 `format`／`manifest_type` 是 `mpd` 時，記成 `drm` 旗標，**套用到該頻道的線路後標成 `unsupported(.drm)`**；整份清單不會因此失敗。
- `parse=` 的值不是 0 時，記成 `parse` 旗標 → 線路標成 `unsupported(.parse)`。
- **m3u 生命週期**：setting 從前面的 setting 行一路累積，遇到網址行時套用到那一條線路，**然後清空**（`LiveParser.java:132`）。
- **txt 生命週期**：setting 一路累積，套用到後面**每一條**線路；**只有遇到 `#genre#` 那一行才清空**（`LiveParser.java:144`）。#17 的 `parse=`／`ua=` 行出現在第 26–30 個群組裡（本文件已核 L17：第 2693–3630 行），靠的就是這個沿用規則，才能套到 1034 個頻道。
- **`|` header**：只套用在那一條線路，不寫進累積中的 setting（X-4）。解析方式照 `LiveParser.java:340-369`（`headers=`、`|`、`&`、`k=v`；`drmScheme`／`drmLicense` 會設 DRM 旗標）。

#### 6.2.4 m3u
- `#EXTM3U` 標頭行：catchup（type、source、replace）存成原始字串；`x-tvg-url`／`tvg-url`／`url-tvg` 只在源沒有設 `epg` 時存起來（L2 預留）。
- `#EXTINF:`：名稱是最後一個 `,` 之後的文字。說明用的頻道（`更新时间`、`更新日期`、`update time`、`update date`、`last update`，不分大小寫）直接跳過，而且把「目前頻道」清掉，讓它後面的網址行也被忽略（`:111-114`）。用 `group-title` 找到或建立群組（同名群組合併，和 `live.find` 一樣），再用名稱找到或建立頻道（同名合併）。`http-user-agent` 屬性就是這個頻道接下來線路的 UA。`tvg-id`／`tvg-name`／`tvg-logo`／`catchup*` 存成原始欄位。
- 網址行（不是 `#` 開頭，而且前面有目前頻道）：切 `|`。`|` 左邊要含 `://`，否則忽略。產生一條 `LiveLine`，套用 setting 後清空 setting。
- 不支援 `group-title` 用分號列多個群組（Android 也不支援）。

#### 6.2.5 txt
- 每一行先判斷是不是 setting 行；含 `#genre#` 就清空 setting，並用 `,` 左邊的文字開一個**新**群組（txt 不合併同名群組，和 `:145` 一樣）。
- 有 `,` 而且不是 `#genre#` 行：左邊是頻道名（說明用的頻道就跳過），右邊用 `#` 切成多條線路，每條再切 `|`，左邊要含 `://`。沒有群組的話先建一個預設群組，名稱是「直播」。同一個群組裡的同名頻道合併線路。

#### 6.2.6 群組密碼（`_`）
- 群組名稱含 `_` 時：名稱**一律**截到第一個 `_` 之前（和 `Group.java:62-67` 一樣，`pass: true` 時也要截）。`live.pass == false` 而且 `_` 後面有文字的話，`_` 後面就是 `password`。
- **L1 決定：`isHidden` 的群組完全不出現**，包括群組欄、頻道欄、換台順序、收藏群組、上次頻道、收藏比對。理由：L1 沒有解鎖 UI；如果照常顯示，就會把 Android 刻意藏起來的群組（#7 的 38 個頻道、#10 的 4 個群組，很可能是成人內容）直接攤開。
- #17 設了 `pass: true`，所以它的 15 個 `_` 群組會**顯示**，名稱截到 `_` 之前（和 Android 一致）。
- 整個源的群組都被隱藏時，顯示空狀態「此直播源沒有可顯示的頻道」。

#### 6.2.7 繼承與 header 組合（套用順序）
1. **線路自己的值**：m3u 的 `http-user-agent`、setting（`ua`／`origin`／`referer`／`header`）、`|` header。
2. **源層的值**（`LiveSource` 的 `ua`／`origin`／`referer`／`header`）：ua、origin、referer **各自**在線路值是空的時候才補上；源層 `header` 只在線路 header **整包都是空的**時候才用（整包取代，和 `Channel.java:362` 一樣，不逐鍵合併）。
3. 最後組成播放 header：先放 header map，再用 `User-Agent`／`Origin`／`Referer` 覆蓋同名鍵（`Channel.java:370-376`）。
4. 抓清單用的 header：源層 header，加上 ua／origin／referer（`Live.java:382-388`）。

#### 6.2.8 線路分類（`LineSupport`）
- `http`／`https`：host 是 `youtube.com`／`youtu.be`（含子網域）就是 `unsupported(.youtube)`；否則看 DRM／parse 旗標；都沒有就是 `playable`。
- `rtmp`／`rtsp`：`attempt`。照常送進播放器（AVPlayer 不支援這兩種 scheme，會很快失敗並換到 MPV），**不承諾能播**（G-2）。
- `video://` → `.sniff`；`p3p`／`mitv`／`tvbus`／`thunder` → `.p2p`；`proxy://` → `.proxy`；其他有 `://` 但不認得的 scheme（含 `abc://`、`ttp://`、`,http://`）→ `.other`「不支援」（W-124 修正 B-2）。DRM／parse 旗標先判定，不管 scheme。
- 頻道的所有線路都不支援時，整個頻道變灰，不能點，也不參與換台。

#### 6.2.9 效能
- 每個群組在解析期間保留 `[String: Int]` 名稱索引（X-8），群組也用一個索引（m3u）。
- 解析在 `Task.detached` 裡跑，畫面只拿到結果。

### 6.3 播放與換線（狀態機）

#### 6.3.1 元件
- **`LiveLineSwitcher`（Core，純值型別，可單元測試）**：輸入是這個頻道的線路陣列和起始序號。它維持「這一輪還沒試過的支援線路」，提供 `next() -> Int?`（下一條要試的線路；跳過不支援的；繞回；回到起點就回 nil）和 `select(_:)`（手動選線路時，從那一條重新開始一輪）。
- **`LiveTVController`（App，`@MainActor`）**：持有目前的源、群組、頻道、switcher、`attemptID`，以及換線計時器的 `Task`。

#### 6.3.2 狀態

```
idle ──tap channel──▶ opening(line i, attemptID n, deadline = now + budget)
opening ──.started(n)──────────────────────▶ playing(line i)
opening ──.failed(n) 或 deadline 到期──────▶ switcher.next() = j ? opening(line j, attemptID n+1) : exhausted
playing ──.failed(n)（播放中斷、送出不可恢復的錯誤）──▶ 同上（從下一條開始）
exhausted ──「重試」──▶ opening(起始線路，新的一輪)
任何狀態 ──換台／手動選線路／關閉播放器──▶ 取消計時器，attemptID+1，開新的 opening 或回到 idle
```

#### 6.3.3 每條線路的時間上限（budget）
- `budget = max(live.timeout ?? 15, 10)` 秒（建議值，§12-2）。15 是 Android 的預設（`Constant.java:13`）；下限 10 秒是為了不比 iOS 原生引擎的起播逾時還短。#16、#17 設 5 秒，在 iOS 會變成 10 秒，因為 AVPlayer 起播有實測約 6 秒的紀錄（`C/PlaybackEngine.swift:435-440` 的註解）。
- budget 從**開這條線路**開始算，不管中間換了幾次引擎；**起播成功就取消**。
- **點播的 `PlayerRouter.startupTimeout(for:)`（原生 10、MPV 20）一行都不改**。直播的 budget 是另外一個計時器，蓋在它上面：
  - 線路格式不對（例如 FLV）→ AVPlayer 很快報錯 → router 換到 MPV（同一條線路內，`fallback`）→ MPV 播出來，或報不可恢復的錯誤 → 換線。
  - 線路卡住不動 → 10 秒時 router 把原生換成 MPV → 15 秒時 budget 到期 → 換線（MPV 只拿到 5 秒，是刻意的取捨：死掉的伺服器換引擎也救不回來；使用者實驗的忍耐上限是 5.7 秒左右，E-4）。
  - AirPlay／PiP 時，原生的起播逾時是 20 秒（`W/:6266-6271`），比 budget 長，所以這時候是 budget 先到期、直接換線，不會換到 MPV。這正好符合現有的意圖：在 AirPlay／PiP 下不要切到 MPV。
- 最壞情況：每條線路 15 秒（源設了 timeout 的話是 `max(timeout,10)`），而不是 30 秒。

#### 6.3.4 換線時的引擎（處理 R-4）
- `PlayerRouter.open` 加一個參數：`open(_ request:, freshEngine: Bool = false)`。`freshEngine` 是 true 時，就算 session 已經開著也呼叫 `selection.startSession()`（回到全域預設引擎），不呼叫 `beginAttempt()`。預設值 false，所以點播的所有呼叫端行為不變。
- `PlaybackSession.open(url:…)` 加上同名參數，一路傳到 `load` → `router.open`。
- 直播**每次開一條線路（換台、換線、重試）都用 `freshEngine: true`**：前一台換到 MPV，不會讓下一台的 HLS 也跑在 MPV 上。
- 代價：使用者在控制列手動選了 MPV，換台之後會回到預設引擎。這在文件裡寫明；需要的話使用者可以把全域預設改成 MPV。

#### 6.3.5 事件來源（處理 R-3，以及回呼槽被 PlayerView 占用的問題）
- `PlaybackSession` 加一個**直播專用的觀察槽** `var lineObserver: ((LiveLineEvent) -> Void)?`，`enum LiveLineEvent { case started, failed(PlaybackFailure) }`：
  - `.started`：在 `watchStartup` 設定 `startupMilliseconds` 的地方（`W/:6286-6293`）送出。
  - `.failed`：在 `W/:5054` 和 `W/:5062` 這兩個送出**非 nil** `onFailure` 的地方，一起送出。`W/:6092` 的 `onFailure?(nil)` 是清除用的，**不送**。
- 不重用 `onFailure`：它是單一槽位，PlayerView 在 `W/:8262` 用它顯示錯誤，關閉時清成 nil（`W/:8242`）。
- **防止舊回呼誤觸（審查清單 T-3 提到的快速換台 race）**：控制器每開一條線路就把 `attemptID` 加 1。計時器和事件處理都先檢查 `attemptID` 有沒有變，再檢查 `session` 目前的網址是不是這條線路。快速上下滑時，舊頻道的事件會被丟掉，不會讓新頻道換線。
- 播到結尾（MP4 類「直播」）：`session.advance` 設為 nil，`onPlaylistFinished` 顯示「播放結束」和「重新播放」，不算成失敗，也不會自動換線或換台。
- `retry: nil`：直播不會被 `retryWithoutPrefetch` 多重試一次（`W/:5051-5064`）。

#### 6.3.6 直播判定與觀看紀錄
- 直播判定**沿用 W-86**，只看執行時的 duration（`W/:5443`、`W/:6576`、`MPVEngine.swift:1040`），不加「從直播頁打開的就是直播」的旗標。理由：播放器的總長顯示、續播、網路策略都已經依 duration 運作；另外加旗標會變成兩套判斷。已知限制：有 DVR 視窗的直播 duration 可能是有限值，這時候會顯示進度條（R-21），但不影響換線，也不會寫紀錄。
- **直播一律 `history: nil`**：不讀也不寫 `history.json`（`W/:5338-5342`；`persist` 在 `W/:5540` 的 guard 就 return，W-110 的 `measured` 閘門不會執行到）。片庫的「記錄」不會出現頻道。「上次看的頻道」由 §6.5 的 `LiveStateStore` 負責。

#### 6.3.7 沿用而不是新功能
背景播放、PiP、AirPlay、鎖定畫面資訊（標題用頻道名稱，透過 `open(title:)`）、音訊 session、網路策略 `.liveOrUnknown`、下載拒絕直播（`OfflinePackage.swift:141`），全部**沿用現有行為**，不另外實作。

### 6.4 畫面流程

#### 6.4.1 入口（處理 R-7）
- **首頁標題列**（`W/:1070-1086` 的 `homeHeader`）：在來源切換按鈕左邊加一個「直播」按鈕（`antenna.radiowaves.left.and.right` 圖示＋文字，最小點擊區 44pt，VoiceOver 標籤「直播電視」）。**只有 `lives` 不是空的時候才顯示**。
- 點下去用 `NavigationStack` push 到 `LiveTVView`（保留底部分頁列，返回就回首頁）。
- 為什麼不新增第 6 個分頁：自製的 `CinematicTabBar` 是 5 個等寬按鈕，加到 6 個在大字體下會截字。IOS-POC-48（`W/:191-192`）已經用同樣的理由拒絕過第 6 個分頁（HIG：避免溢位分頁）。為什麼不取代既有分頁：5 個分頁都有人在用。為什麼不放設定頁：太深，找不到。其他選項列在 §12-3。

#### 6.4.2 直播清單 `LiveTVView`
- 頂部：直播源選單（`Menu`，列出所有 live 源名稱；抓不到或解析失敗的源旁邊顯示原因，例如「HTTP 404」「逾時」「格式不支援」；預設選上次的源，沒有的話選第一個）、重新整理按鈕。
- 主體兩欄：
  - **iPhone 直向**：左欄群組，固定寬度 112pt（大字體時 140pt，名稱最多 2 行），右欄頻道。
  - **橫向和 iPad**：左欄改成約 30% 寬。
  - 群組欄最上面是「收藏」（有收藏時才出現），接著是看得見的群組。
  - 頻道列：名稱；線路數（「3 條線路」）；收藏星號；不支援時整列變灰並標「iOS 不支援」。上次的頻道加上「上次觀看」標記。
- 用 `List` 做懶載入，只建立看得見的列。只顯示目前群組的頻道，切換群組時才換資料。
- 進入頁面時：捲到上次的群組和頻道，上方顯示「繼續看：<頻道名>」按鈕，**不自動播放**（X-15，§12-7）。
- 點頻道：用 `fullScreenCover` 打開直播播放畫面（§6.6），開始 §6.3 的流程。長按（或右滑）頻道 → 加入／取消收藏。帶密碼的群組本來就不顯示，所以不會有它的收藏操作。
- 狀態：載入中（顯示 `ProgressView` 和「最多 30 秒」）、錯誤（原因加上「重試」）、空狀態。

#### 6.4.3 播放畫面（直播模式）與手勢（處理 T-5 的手勢衝突）
- 沿用 PlayerView。直播模式下**隱藏點播專用的控制**（倍速、選集／下一集、片頭片尾設定，實作時逐一列出），另外疊一層 `LivePlayerOverlay`：頻道名、「線路 2／5：<線路名>」、上一台／下一台按鈕、線路選單、收藏切換、「頻道清單」側邊面板（列出目前群組）。
- 換台失敗、所有線路都試過的時候：顯示「此頻道目前無法播放（已試 N 條線路）」，下面有「重試」和「換台」，**不會自動跳到下一台**（Android 也不跳）。
- **手勢（照 Android 用畫面區域分開，`CustomKeyDown.java:104-108`、`:163-193`）**：
  - 直播模式下，垂直拖曳**起點在左 1/4** 是亮度，**起點在右 1/4** 是音量，**起點在中間 1/2** 是換台；換台要放手時垂直位移超過 80pt 而且角度大於 70°：往上滑是上一台，往下滑是下一台（和 Android 的預設方向一樣）。
  - 水平拖曳（拖進度）照現有行為（duration 是 0 時本來就沒有意義）。
  - **點播模式完全不變**：左半邊亮度、右半邊音量（`W/:8438-8441`）。
  - 實作方式：`classify` 多一個 `.zap` 種類，只在 `live != nil` 時才會出現；`dragEnded` 判斷要不要換台。
- 換台順序：在目前群組裡換，到頭就繞回（Android 預設 `isAcross` 關閉）；跳過整台不支援的頻道；在「收藏」群組裡就在收藏之間換。
- 無障礙：上一台／下一台都有按鈕，播放畫面也提供 VoiceOver 的 `accessibilityAction`（「上一台」「下一台」）。

### 6.5 儲存（記住上次頻道、收藏）

- 位置：`Application Support/LiveTV/live-state.json`，由 `actor LiveStateStore`（Core）負責，寫入用 `.atomic`。
- **不放進** `favorites.json` 或 `history.json`：`FavoriteIdentity`（`C/Favorites/Favorite.swift:15-37`）需要 siteID／vodID，而且有自己的 schema 版本和遷移流程（`FavoriteStore.swift:166`、`:194`）。
- 格式：

```json
{ "schemaVersion": 1,
  "configs": { "<ConfigSource.identity>": {
      "lastLive": "<live 名稱>",
      "last": { "<live 名稱>": { "group": "…", "channel": "…", "lineLabel": "…或 null", "lineIndex": 0 } },
      "favorites": { "<live 名稱>": ["<頻道名稱>", …] } } } }
```

- **收藏 key**：`ConfigSource.identity`＋live 名稱＋頻道名稱（X-9）。顯示時，每個收藏的頻道只出現一次，用的是它在**看得見的群組**裡第一次出現的那一筆（X-11）。清單更新後找不到的收藏會留著，不會刪掉，等清單恢復時又會出現。
- **上次頻道**：每個設定來源、每個 live 源各記一筆。只在線路**起播成功**（`.started`）之後才寫，避免記到一直播不出來的頻道。隱藏群組永遠不寫（本來就看不到）。**不存網址**（X-10）。
- **還原順序**：同名群組裡找到同名頻道 → 其他看得見的群組裡的同名頻道 → 第一個看得見的群組裡第一個有支援線路的頻道。線路的還原：先用 `lineLabel` 比對，比對不到再用 `lineIndex`，序號超出範圍就用 0。
- 切換設定來源時用新來源的 identity 讀取，不會串到別的來源。
- **壞檔**：讀不懂的檔案另存成 `live-state.corrupt-<時間>.json`，然後從空狀態開始（`FavoriteStore.swift:11` 的做法）。讀寫失敗**只影響直播**，點播完全不受影響。`schemaVersion` 比目前大的時候也另存備份，當成空的。
- **清除資料**：`StorageMaintenance.supportKeep`（`C/StorageMaintenance.swift:64-65`）加上 `"LiveTV"`，這樣「清除無效檔案」不會刪掉它；「重設」（`clearAll`）會一起清掉，這是預期行為。
- 遷移：這是新檔案，不需要遷移。
- **清單快取**：L1 只在記憶體裡快取（每個 live 源一份，存活到 App 結束），提供手動重新整理。程式碼要加註 `shortcut: in-memory only; #12/#14 take ~20 s per cold fetch, add a Caches/ copy with TTL if that hurts`。抓清單的逾時是 30 秒（`Constant.java:10`），切換源或離開頁面時取消。

### 6.6 模組切分（處理 R-8、R-9）

| 檔案 | target | 責任 | 對外介面 | 估計行數 |
|---|---|---|---|---|
| `ios/Sources/WebHTVCore/Live/LiveSource.swift` | Core | 設定裡的 live 欄位，寬鬆解碼 | `LiveSource`（name、url、ua、origin、referer、header、timeout、pass、epg、playerType、`isURLList`、`listHeaders`、`lineBudget`） | 90 |
| `…/Live/LivePlaylist.swift` | Core | 清單資料模型、`LineSupport` | 見 §6.2 | 70 |
| `…/Live/LivePlaylistParser.swift` | Core | 編碼、格式判斷、m3u、txt、setting、繼承、分類 | `static func parse(_ data: Data, source: LiveSource) throws -> LivePlaylist` | 260 |
| `…/Live/LiveListLoader.swift` | Core | 帶 header 抓清單，30 秒逾時，記憶體快取 | `func playlist(for: LiveSource, base: ConfigSource, refresh: Bool) async throws -> LivePlaylist` | 70 |
| `…/Live/LiveLineSwitcher.swift` | Core | 換線順序的純狀態機 | `next()`、`select(_:)` | 50 |
| `…/Live/LiveStateStore.swift` | Core | live-state.json 的讀寫 | `last(…)`、`setLast(…)`、`favorites(…)`、`toggleFavorite(…)` | 130 |
| `C/WebHTVConfig.swift` | Core | 加 `lives`；`sites` 改可選 | — | +8 |
| `C/PlaybackEngine.swift` | Core | `PlayerRouter.open(_:freshEngine:)` | — | +4 |
| `C/StorageMaintenance.swift` | Core | `supportKeep` 加 `"LiveTV"` | — | +1 |
| `ios/WebHTVApp/Sources/LiveTVView.swift` | App | 清單畫面、`LiveTVController`、`LivePlayerOverlay` | `LiveTVView(lives:source:)` | 450 |
| `W/`（WebHTVApp.swift） | App | `lives` state 和三個採用點；首頁按鈕；`PlaybackSession.lineObserver`／`freshEngine`；PlayerView 的 `live` 參數、直播模式的控制隱藏與手勢；同檔加一個 internal 的 `LivePlayerScreen` 包裝 | — | 約 +130 |
| `project.pbxproj` | App | `LiveTVView.swift` 的 4 處 file reference（照 `MPVEngine.swift` 在 `:22`、`:36`、`:111`、`:226` 的先例） | — | +4 |

- **PlayerView 維持 `private`**：同一個檔案（`WebHTVApp.swift`）裡加一個 internal 的 `struct LivePlayerScreen: View { let controller: LiveTVController; var body: some View { PlayerView(live: controller) } }`。檔案層級的 `private` 等於 fileprivate，同檔的 internal 型別可以在 `body` 裡使用。`LiveTVView.swift` 只看得到 `LivePlayerScreen`。這樣就不用放寬 PlayerView 的存取等級。
- `PlaybackSession.shared` 本來就是 internal（`W/:4760`），新檔案可以直接用。
- R-9 防範：U2 的驗收要包含 **App target 建置成功**（不能只跑 SwiftPM 測試）。

### 6.7 header、隱私與 log（處理 R-6）
- 新的 `[live]` log 只記：源的序號（不記名稱）、群組和頻道的序號、線路序號、`PlaybackLogRedaction.urlSummary(url)`（只有 host 和副檔名）、HTTP 狀態碼、耗時、換線原因（`failed`／`budget`）。**不記** header 的值、完整網址、query（例如 tv123 的 `sid`）。
- 抓清單失敗的錯誤訊息只顯示「HTTP 404」「逾時」「無法連線」，不帶網址和 header。
- 頻道名稱：現有的 `[playback]` log 用 `privacy: .public` 記 `itemTitle`（例如 `W/:6280`）。直播把頻道名稱當成 title 傳進去，所以頻道名稱會出現在本機的 unified log 裡。**L1 決定沿用**，理由：點播片名（包含成人影片）本來就是同樣的處理；unified log 只有接上電腦或 sysdiagnose 才看得到；改成遮罩要動共用的 log 格式，超出範圍。帶密碼的群組本來就不會被播放，所以不會出現在 log 裡。
- 跨主機轉址時 header 會不會跟過去：URLSession 的預設行為**沒有確認**（R-22）。資料裡會受影響的只有 #19 的 `X-Api-key`，而 #19 目前回 404。L1 接受這個風險並記錄下來，不另外寫轉址 delegate。
- TLS：不關閉驗證，不加 ATS 例外（現有的 `NSAllowsArbitraryLoads` 已經涵蓋 http）。
- fixture 和文件：不放成人源的群組名或頻道名；測試用的資料全部是自製的，或者已經去識別化。

---

## 7. L1 驗收條件（每一條都可以測）

> 「W-92 清單」指 `artifacts/live-l1-data-gate-logs/raw/lists/Lxx.body`（**不進 repo**）。網路未判定的源（#2、#12、#13、#14）**不當驗收樣本**。「實機」是使用者透過 SideStore 安裝的 IPA。

| # | 輸入 | 操作 | 預期 | 證據 |
|---|---|---|---|---|
| AC-1 | 既有測試的所有設定 fixture | 跑 `WebHTVCoreTests` | 全部通過，既有測試**一行都不改** | 測試輸出 |
| AC-2 | `{"sites":[…一個 CMS…],"lives":[{"name":"a","url":"http://x/a.txt","pass":"yes","timeout":"5","header":3},{"name":"b","url":"http://x/b.m3u"}]}` | `ConfigLoader.validate` | 成功；`sites` 和沒有 `lives` 時完全相同；`lives` 有 a、b 兩個（a 的 timeout=5，pass=false，header 空的） | 單元測試 |
| AC-3 | `lives` 是 `"oops"`，或者整個鍵不存在 | 解碼 | 成功，`lives` 是空的；首頁不顯示「直播」按鈕 | 單元測試＋Simulator 截圖 |
| AC-4 | `{"lives":[…]}`（沒有 sites） | `validate` | 照舊丟 `noSupportedSites`（L1 的邊界）；`{"sites":[]}` 也照舊被拒絕 | 單元測試 |
| AC-5 | W-92 清單 #8、#9、#4、#15 | 本機跑解析統計測試（§8.2） | #8＝11／114／114、#9＝15／564／2343、#4＝11／1635／1712、#15＝4／49／49（群組／頻道／線路，和 G§3 一致）。如果有差異，要逐項解釋是哪一條規則造成的，而且要符合 Android | 測試輸出存到 task 文件 |
| AC-6 | W-92 #17 | 同上 | 帶清單內 `ua=` 的頻道正好 1034 個（G§4），都在第 26–30 個群組；這些頻道的線路是 `unsupported(.parse)`；其他群組的線路帶源層 UA；15 個 `_` 群組都顯示，名稱截到 `_` 之前 | 同上 |
| AC-7 | W-92 #7、#10 | 同上 | #7 有 1 個群組（38 個頻道、46 條線路，W-124 修正 B-1）是 `isHidden`；#10 有 4 個群組是 `isHidden`；UI 的群組欄看不到這些群組 | 測試＋Simulator 截圖（只截群組數，不截名稱） |
| AC-8 | 自製 fixture（§8.1 列表） | 單元測試 | 每條規則都有正反兩個案例，而且通過 | 測試輸出 |
| AC-9 | 有 lives 的設定 | 打開首頁 | 標題列有「直播」按鈕，VoiceOver 唸「直播電視」；點下去進入兩欄清單；返回就回首頁 | Simulator 截圖＋操作錄影 |
| AC-10 | #8 任一頻道 | 點頻道 | Simulator 上用原生引擎播出畫面；log 有 `[playback] started … on 原生`；`history.json` 的 sha256 播放前後一樣；片庫的「記錄」沒有新增項目 | log 片段、sha256、截圖 |
| AC-11 | #15 的 FLV 頻道 | 點頻道 | 原生失敗或逾時之後換到 MPV 並播出；log 有 `on MPV`，而且 `reason` 不是 `viewer` | log 片段 |
| AC-12 | 自製直播源（本機 HTTP server 提供）：線路 1＝`http://127.0.0.1:9/a.m3u8`（拒絕連線）、線路 2＝接受連線但永遠不回應、線路 3＝#8 的一條 HLS | 點頻道 | 依序換到線路 3 並播出；線路 2 在 15±1 秒換掉；log 有 `[live] line 1→2 reason=failed`、`line 2→3 reason=budget` | log 片段（含時間戳） |
| AC-13 | 同上，但線路 3 也是拒絕連線 | 點頻道 | 三條線路都試過後顯示「此頻道目前無法播放（已試 3 條線路）」和「重試」；**不會**自動換台 | 截圖＋log |
| AC-14 | 先播 #15（會換到 MPV），再換到 #8 的頻道 | 往下滑換台 | #8 的頻道從**原生**開始（log `reason=open on 原生`） | log 片段 |
| AC-15 | #8 | 3 秒內連續往下滑 5 次 | 只有最後一台播放；log 裡前 4 台沒有任何 `[live] line … reason=` 換線紀錄 | log 片段 |
| AC-16 | 直播播放中 | 中間上下滑；左 1/4 和右 1/4 上下拖曳 | 中間滑會換台；兩側會調亮度和音量。**點播**播放器的左半邊／右半邊行為不變（回歸） | 錄影 |
| AC-17 | — | 單元測試 | `PlayerRouter.startupTimeout(for: .native) == 10`、`.mpv == 20`（不變）；`open(_:freshEngine: false)` 的行為和改動前一樣（session 開著時引擎維持原樣），`true` 時回到全域預設 | 單元測試 |
| AC-18 | #8 | 播頻道 X（線路 2）→ 結束 App → 重開 → 進直播 | 頻道 X 有「上次觀看」標記，「繼續看：X」會從線路 2 開始播 | 截圖＋log |
| AC-19 | 兩個直播源都有一個叫「CCTV1」的頻道（自製 fixture，或用真實清單找到同名頻道） | 在源 1 收藏它 | 源 1 的「收藏」群組出現；源 2 的同名頻道**沒有**星號；重開 App 之後還在；隱藏群組裡的頻道沒有收藏操作 | 截圖 |
| AC-20 | 把 `live-state.json` 寫成 `garbage` | 重開 App → 進直播 | 清單正常；檔案被另存成 `live-state.corrupt-…`；點播完全正常 | 截圖＋檔案清單 |
| AC-21 | 有收藏的狀態 | 設定 → 清除無效檔案 | 清單裡**沒有** `LiveTV`；收藏還在 | 截圖 |
| AC-22 | 播放 #17（有源層 ua）和 tv123 頻道 | 匯出 Simulator 的 log 並 grep | 找不到 `okhttp/` 這類 header 值、`sid=`、完整的 `http://…?…` 網址 | grep 指令和結果 |
| AC-23 | #17、#20、tv123 | 看清單 | YouTube、`p3p`、`parse=1`、DRM 的線路或頻道標「iOS 不支援」，不能點；#20 的頻道全部變灰；自動換線會跳過不支援的線路 | 截圖＋單元測試 |
| AC-24 | W-92 #10（782KB，9,041 條線路）、#3（803KB） | 本機解析測試（Simulator 或 macOS） | 解析時間記錄到 task 文件，**目標 ≤ 500 ms**（Simulator）。清單最大群組捲動時沒有明顯卡頓 | 測試輸出的耗時＋捲動錄影 |
| AC-25 | 實機（SideStore IPA） | 使用者播 #8 一台，以及 #17 一台帶清單內 UA 的頻道 | 能播，或者記下失敗現象（G-1 閘門） | 使用者回報 |

不寫成驗收的：「可播 62%」這類比例（只是靜態估計）、EPG、回看、密碼解鎖。

---

## 8. 測試計畫

### 8.1 單元測試（Swift Testing，fixture 全部內嵌在測試檔案）

`ios/Tests/WebHTVCoreTests/Live/` 底下：
- `LiveSourceDecodingTests`：AC-2～AC-4；每個欄位型別錯誤時的容錯；`api`／type≠0 的源被過濾掉。
- `LivePlaylistParserTests`：
  - 格式判斷：JSON 陣列 → unsupported；`#EXTM3U` 和 `#genre#` 在同一行 → txt。
  - m3u：標頭的 catchup／tvg-url；`#EXTINF` 屬性；同名合併；說明用的頻道會連同後面的網址一起跳過；**setting 每條網址後清空**（第二條網址沒有前一條的 `#EXTVLCOPT` UA）。
  - txt：**setting 一路沿用到下一個 `#genre#`**（模仿 #17：`#genre#`、`parse=1`、`ua=X`、三個頻道 → 三個都帶 X 而且都是 parse；下一個 `#genre#` 之後就沒有）；`#` 多線路；`$` 線路名稱；沒有群組時建預設群組；同名群組不合併。
  - `|` header 只套用在那一條線路（X-4），解析 `&` 和 `headers=`。
  - 繼承：線路 UA 優先於源層 UA；源層 header 整包取代（線路有任何 header 時就不用源層的）；Origin／Referer／UA 覆蓋 header 裡的同名鍵。
  - 群組密碼：`A_123` 在 pass=false 時 → 名稱 A、密碼 123、hidden；pass=true 時 → 名稱 A、不 hidden；`A_`（後面沒有文字）→ 名稱 A、不 hidden。
  - 線路分類：youtube／p3p／video:///rtmp／KODIPROP DRM／沒有 `://`。
  - 換行：`\r\n`、單獨的 `\r`、BOM；GB18030 編碼的文字。
  - 空清單、只有說明用的頻道。
- `LiveLineSwitcherTests`：從序號 k 開始，繞一圈就停；跳過不支援的線路；`select` 重新開始一輪；只有一條線路；全部都不支援。
- `LiveStateStoreTests`：寫入後再讀回；兩個設定來源互相隔離；壞檔另存；schemaVersion 比較新時另存；還原的退回順序。
- `PlaybackEngineTests` 新增 `freshEngine` 的兩個案例（AC-17）。
- `StorageMaintenanceTests` 新增「`LiveTV` 不會被列出」。

### 8.2 真實清單統計（不進 repo 的資料）
- 一個測試在環境變數 `WEBHTV_LIVE_FIXTURES` 指到 W-92 的 `raw/lists/` 時才執行，否則略過。它對 #4、#7、#8、#9、#10、#15、#17 輸出群組、頻道、線路、hidden 群組、帶清單內 UA 的頻道數，以及解析耗時（AC-5～AC-7、AC-24）。
- 結果（數字和耗時）記在 task 文件裡。測試只輸出數字，**不印**群組名或頻道名。

### 8.3 GUI（Simulator，由 Claude 安裝和操作）
- 依團隊規則，Claude 自己在 Simulator 安裝並操作這次的 build，而且要證明是這次的 build（設定頁的版本號或 build 號，加上安裝紀錄）。Codex 負責審查情境和證據。
- 情境：AC-9～AC-16、AC-18～AC-23。AC-12／AC-13 在 Mac 上用 `python3 -m http.server` 加一個自製的小 server（線路 2 只接受連線、不回應），Simulator 可以連到 `127.0.0.1`。
- Simulator **驗不了**的：AVPlayer 用 header key 的實機行為（G-1）、行動網路、實機效能。這些交給 AC-25。

### 8.4 實機（SideStore）
- 不直接安裝到 iPhone。Claude 用實機目標建置，證明可以編譯，然後交 IPA 給使用者。
- 使用者驗證 AC-25：先試一台需要 UA 的頻道（R-15 的第一個實機驗證點），再試一般的 HLS 頻道。

### 8.5 Ponytail
- 設計階段是可選的。**實作的每一段（U1～U4）都要對最終 diff 跑 `ponytail:ponytail-review`**（AGENTS.md §4），結果記在 task 文件。

---

## 9. 分段實作單位（每段一個 guard session、一個 commit）

> 預估的是本 agent 的實際耗時（包含建置和 Simulator 操作），不是人工工時。

| 段 | 內容 | 檔案 | 驗收 | 預估 |
|---|---|---|---|---|
| **U1 解析核心** | `LiveSource`、`LivePlaylist`、`LivePlaylistParser`、`LiveLineSwitcher`；`WebHTVConfig` 加 `lives`、`sites` 改可選；單元測試＋真實清單統計 | Core＋Tests（沒有 UI） | AC-1～AC-8、AC-24（解析耗時） | 2.5–3.5 小時 |
| **U2 入口、清單與播放** | `LiveListLoader`；`LiveTVView`（清單、源選單、隱藏群組、不支援的標示）；首頁按鈕；`lives` 的三個採用點；用 PlaybackSession 點播（`history: nil`）；`LivePlayerScreen` 包裝；pbxproj | Core＋App | AC-9、AC-10、AC-11、AC-22、AC-23；App target 建置成功 | 3–4 小時 |
| **U3 換台與自動換線** | `PlayerRouter.open(freshEngine:)`；`PlaybackSession.lineObserver`；`LiveTVController` 狀態機和 budget；`LivePlayerOverlay`（上一台／下一台、線路選單）；直播模式的手勢和控制隱藏 | Core＋App | AC-12～AC-17 | 3–4 小時 |
| **U4 記住上次頻道與收藏** | `LiveStateStore`；收藏群組；「繼續看」；`StorageMaintenance.supportKeep` | Core＋App | AC-18～AC-21 | 2–3 小時 |
| **實機** | 交 IPA 給使用者 | — | AC-25 | 要等使用者，不計入 |

- 相依關係：U2 依賴 U1；U3 依賴 U2；U4 依賴 U3（§14 拍板：先 U3 再 U4，收藏歸 U4）。
- 每段完成都要有 Ponytail review 和該段的驗收紀錄，才能 commit。
- 實作階段的 task 文件：`docs/IOS-POC-59-live-tv.md`（由本文件搬過去之後持續更新）。交接寫在 `artifacts/webhtv-dev-claude-dev-2-handoff.md`（直播線歸 webhtv-dev-claude-dev-2，Manager #2207），**不寫** `docs/current-task-state.md`（Manager 管理，R-20）。

---

## 10. 回滾

| 回滾 | 影響 | 留下的東西 | 是否無害 |
|---|---|---|---|
| revert U4 | 沒有收藏和「繼續看」；換線和播放照常 | 裝置上的 `Application Support/LiveTV/` | 無害：沒有程式會讀它；「清除無效檔案」會把它列成 `.unknown`，可以清掉 |
| revert U3 | 回到「點頻道就播放」，沒有自動換線和上下滑換台；`freshEngine` 參數消失 | 無 | 無害：點播呼叫端本來就是預設的 false |
| revert U2 | 首頁沒有直播入口；Core 的解析器還在，但沒有人用 | 無 | 無害 |
| revert U1 | `lives` 被忽略；`sites` 回到必填 | 無（設定快取存的是原始 bytes） | 無害：點播設定照常可以用 |

回滾順序：U4 → U3 → U2 → U1 反向進行（§14：U4 依賴 U3，不再寫成可單獨 revert）。每段都是一個 commit，用 `git revert <commit>`。

---

## 11. 風險

| # | 風險 | 處理 | 剩餘風險 |
|---|---|---|---|
| R-1 | 嚴格解碼 `lives` 弄壞點播 | 兩層寬鬆解碼；AC-2、AC-3 | 低 |
| R-2 | 帶密碼的群組被攤開 | L1 隱藏；AC-7 | 低 |
| R-3 | 卡住不動的線路不會自動換 | 獨立的 budget 計時器＋`lineObserver`；AC-12 | 低 |
| R-4 | 換台後一直停在 MPV | `freshEngine`；AC-14 | 低 |
| R-5 | txt 的 setting 沿用規則寫錯，#17 的 header 錯 | 分開實作兩種生命週期；AC-6＋單元測試 | 低 |
| R-6 | header 或 `sid` 進了 log | §6.7；AC-22 | 低 |
| R-7 | 入口位置 | 首頁標題列；理由見 §6.4.1 | 等使用者決定（§12-3） |
| R-8 | `PlayerView` 是 private | 同檔的 internal 包裝 | 低 |
| R-9 | pbxproj 漏加新檔 | U2 驗收要求 App target 建置 | 低 |
| R-10 | O(n²) 合併或在 main thread 解析 | 字典索引＋detached task；AC-24 | 中（還沒量測） |
| R-11 | 承諾了可播比例 | 驗收只用指定樣本 | 低 |
| R-12 | L2 混進 L1 | §1.3 只保留欄位 | 低 |
| R-13 | 沒有資料支撐的 JSON 寫成必做 | 不做（§12-5） | 低 |
| R-14 | 直播寫進點播的觀看紀錄 | `history: nil`；AC-10 | 低 |
| R-15 | AVPlayer 用沒有公開文件的 header key，實機從沒確認過 | 實機第一個驗證點（AC-25）；有問題的話另開一張單，對 UA 改用公開的 `AVURLAssetHTTPUserAgentKey`（iOS 16 以上，E-2） | **中**，要到實機才知道 |
| R-16 | MPVKit 的 rtmp／rtsp 支援沒驗證 | 標成「嘗試」，不承諾 | 中（只占 0.84%） |
| R-17 | 設定頂層 `proxy` 欄位 | L1 不支援（§1.2） | 低 |
| R-18 | `.php`／無副檔名的線路占 31.72%，轉址到 FLV 時 AVPlayer 的失敗方式不明 | 報錯和卡住兩種情況都已經有換線機制 | 中（影響的是換線要等多久） |
| R-19 | 文件的行號會過期 | 以 HEAD `b1b20606` 為準；實作開始時重新對過 | 低 |
| R-20 | 交接文件的位置 | 寫 `artifacts/webhtv-dev-claude-dev-2-handoff.md` | 低 |
| R-21 | 有 DVR 視窗的直播，duration 是有限值，會被當成點播顯示 | 沿用 W-86；不影響換線，也不寫紀錄 | 低（只是顯示問題） |
| R-22 | 跨主機轉址時 header 會不會跟過去，沒確認 | 只有 #19 的 X-Api-key 會受影響，而 #19 是 404；記錄在案 | 低 |
| R-23 | budget 到期時，MPV 只拿到剩下的 5 秒，可能錯過「MPV 慢一點就能播」的線路 | 刻意的取捨（§6.3.3）；使用者可以手動選線路重試 | 中（取決於使用者對 §12-2 的選擇） |
| R-24 | 清單只快取在記憶體，冷啟動時 #12、#14 要約 20 秒 | `shortcut:` 註記；手動重新整理 | 中（UX） |

---

## 12. 待使用者決定（回覆編號即可）

**12-1 L1 核准與分段**
1. 核准 L1，依 U1 → U2 → U3／U4 的順序分段實作，每段完成都要驗收和 commit（建議）
2. 只核准 U1、U2（解析、入口、播放），看過實機播放再決定 U3、U4
3. 暫緩直播

**12-2 每條線路的等待上限**
1. 預設 15 秒；源有設 `timeout` 就用源的值，但不少於 10 秒（#16、#17 會是 10 秒）（建議）
2. 完全照 Android：預設 15 秒，源設 5 秒就是 5 秒（AVPlayer 比較慢的線路會被提早放棄）
3. 一律 20 秒（MPV 有比較多時間，但死線路要等更久）

**12-3 入口位置**
1. 首頁標題列加「直播」按鈕（建議）
2. 新增第 6 個分頁（自製分頁列會變成 6 等分，大字體時容易截字）
3. 放在「片庫」裡

**12-4 帶密碼的群組（L1）**
1. 一律隱藏，L2 再做密碼解鎖（建議）
2. 照常顯示（會攤開 Android 藏起來的群組）

**12-5 JSON 格式的清單**
1. L1 不做（目前 13 份清單裡沒有任何一份是 JSON）（建議）
2. L1 照 Android 一起做（只能用自製資料驗證）

**12-6 只有直播、沒有點播來源的設定檔**
1. L1 不支援，照舊顯示「此設定沒有 iOS 可用的來源」（建議）
2. L1 就支援（要改設定驗證和主畫面的進入條件，回歸面比較大）

**12-7 進入直播頁時**
1. 不自動播放，標出上次的頻道，提供「繼續看」按鈕（建議）
2. 照 Android，一進來就自動播上次的頻道

---

## 附錄 A：審查檢查表（review-prep-W-93）→ 本文件章節

| 檢查表項目 | 本文件位置 |
|---|---|
| §0-1 只能有文件 diff | 文件開頭的性質說明；§9（實作另外核准） |
| §0-2 §7 外部證據讀過原文 | §2（每一筆都有 URL／revision／存取日期；取不到的寫在 §2.4） |
| §0-3 群組密碼 | §6.2.6、§12-4、AC-7 |
| §0-4 自動換線不只靠 onFailure | §6.3.3、§6.3.5、AC-12 |
| D-1 任務文件路徑、不另開 plans | 文件開頭（日後搬到 `docs/IOS-POC-59-live-tv.md`） |
| D-2 Android 原碼 | §4、§2.1 |
| D-3 iOS 現況 | §3 |
| D-4 證據類別 | §2.1～§2.4 |
| D-5 三案比較 | §5.2 |
| D-6 優化／修正／補充／拒絕 | §5.3 |
| D-7 畫面流程 | §6.4 |
| D-8 模組切分 | §6.6 |
| D-9 驗收、測試、回滾 | §7、§8、§10 |
| D-10 實作另外核准、分段 | 文件開頭；§9；§12-1 |
| D-11 研究邊界、未解閘門 | §2.5 |
| E-1 上游原碼（含上游 commit） | §2.1 |
| E-2 官方規格（RFC 8216、AVFoundation、M3U 沒有正式規格、EXTVLCOPT、KODIPROP、XMLTV） | §2.2 |
| E-3 成熟專案 | §2.3 |
| E-4 論文／技術文章 | §2.4 |
| E-5 證據欄位 | §2 各表的欄位 |
| S-1 lives 讀取、sites 可選 | §1.1 F-1／F-2、§6.1 |
| S-2 m3u／txt | §6.2.4、§6.2.5 |
| S-3 JSON | §1.1 F-5、§12-5 |
| S-4 繼承 | §6.2.7 |
| S-5 `$` | §6.2.5、§4 |
| S-6 `#` 多線路 | §6.2.5 |
| S-7 群組密碼（a）（b）（c） | §6.2.6 |
| S-8 UI 功能都放 L1 的理由 | §1.1 最後一段 |
| S-9 只送 http(s)、rtmp／rtsp | §6.2.8 |
| S-10 playerType | §5.3 X-12 |
| S-11 timeout | §6.3.3、§12-2 |
| S-12 明文排除項 | §1.2 |
| S-13 L2 只預留介面 | §1.3 |
| S-14 不承諾可播比例 | §0、§7 最後一段 |
| T-1 sites 可選的相容性（解碼不變、寬鬆 lives、validate、非 JSON 網址、快取、測試、sites 為空時的使用端） | §6.1、§1.2、§3、AC-1～AC-4（`validate` 不改，所以 `sites` 為空時的畫面維持現狀，`W/:151`） |
| T-2 解析規則對照 | §6.2（全部子節）、§5.3 X-4～X-8 |
| T-3 播放：W-86、紀錄、換線順序、逾時不算失敗、引擎延續、終點、retryWithoutPrefetch、race、PiP、點播控制 | §6.3.3～§6.3.7、§6.4.3 |
| T-4 儲存與遷移 | §6.5 |
| T-5 入口、空狀態、版面、手勢 | §6.4.1～§6.4.3（更正：自製分頁列不會出現系統的「更多」） |
| T-6 拆檔 | §6.6 |
| T-7 效能（最大清單、不在 main thread、O(n)、lazy、清單快取、抓清單逾時、logo） | §6.2.9、§6.4.2、§6.5（清單快取）、§1.2（logo）、AC-24 |
| T-8 header 與隱私（log、sid、頻道名、轉址、成人 fixture、TLS／ATS） | §6.7、§2.2（ATS） |
| §4 三案比較是否實質（具體內容、同一組面向、每處偏離、用數字說 no change 的代價、結論一致） | §5.1～§5.3 |
| V-1 驗收可測 | §7 |
| V-2 解析器 fixture | §8.1 |
| V-3 回歸 | AC-1、AC-16、AC-17 |
| V-4 分段 | §9 |
| V-5 回滾路徑 | §10 |
| V-6 Simulator／實機 | §8.3、§8.4 |
| V-7 網路未判定的源不當樣本 | §7 開頭說明 |
| V-8 Ponytail | §8.5 |
| R-1～R-20 | §11（另外補了 R-21～R-24） |

## 附錄 B：審查檢查表的行號更新（`644a2b16` → `b1b20606`）

`W/` 在 `:5537` 之前的行號都不變；`:5548` 之後一律往前 1 行（W-110 的 `persist` 少了 1 行）。主要的對照：`PlayerView` `:8042`→`:8041`；`fullScreenCover` `:8603`／`:8611`→`:8602`／`:8610`；`asset(for:)` `:6434-6440`→`:6432-6440`；`[playback]` 起播逾時的 log `:6281`→`:6280`；總長 `--:--` `:7021-7022`→`:7020-7021`。`C/PlaybackEngine.swift`：「Never shown as a failure」所在的段落是 `:449-462`（函式在 `:455`）。`MPVEngine.swift` 的 `http-header-fields` `:583-584`→`:588-589`。`C/WatchHistory.swift`：`WatchHistoryStore` 在 `:289`、`history.json` 在 `:303`，W-110 的 `measured` 在 `:217-223`。pbxproj：新增檔案的先例 `MPVEngine.swift` 在 `:22`／`:36`／`:111`／`:226`。Android（`app/`）沒有改動。

另外有兩點**更正**審查清單的前提：
1. T-5／R-7：App 用的是自製的 `CinematicTabBar`，系統 tab bar 是隱藏的。加第 6 個分頁**不會**出現系統的「更多」，問題是分頁列被擠成 6 等分（§3、§6.4.1）。
2. 審查清單 1.2 說「`W/:6434` 的註解寫著『從未在實機確認』」：HEAD 上這句話實際在 `C/PlaybackEngine.swift:120`（「never been confirmed on a device」）；`W/:6432-6438` 的註解只說明這個 key 沒有出現在公開 header 裡。

## 13. 使用者決定（2026-10-15）

使用者回覆「1，直播 L1 全部照建議開工，排在爬蟲抽離 W-119～W-122 之後」：12-1＝1（U1→U2→U3／U4，每段驗收並 commit）、12-2＝1（15 秒，源 timeout 不少於 10 秒）、12-3＝1（首頁標題列按鈕）、12-4＝1（帶密碼群組隱藏）、12-5＝1（不做 JSON）、12-6＝1（只有 lives 不支援）、12-7＝1（不自動播放，提供「繼續看」）。工單 W-124～W-127。

## 14. W-128 審查預備後 Manager 拍板（2026-10-15 05:40 UTC）
- B-1：#7 隱藏群組為 38 頻道／46 線路，F-8、AC-7 照改。
- B-2：照 Android `isPlayableUrl`，含 `://` 的線路保留並標不支援（§1.2 改為不丟棄）；AC-5 #9 = 2343。
- B-3：m3u UA 優先序為清單內 setting > `#EXTINF http-user-agent` > 源層 ua。
- B-4：空 group-title 補「直播」。
- B-5：空群組照 Android `LiveParser` 現行行為，實作時寫明出處。
- #17 硬性期望 1034 頻道／1070 線路。
- W-129 拍板（2026-10-15 05:58 UTC）：先 U3 再 U4，收藏歸 U4（補 AC）；直播固定 1×；清單 30 秒為總時長，換源作廢舊結果；空群組照 Android 顯示；U2 選第一個源，記住上次的源歸 U4；freshEngine 一次性；15 秒換線預算在暫停或背景時不計時；直播源重名照 Android 去重。

## 15. U1 解析核心實作紀錄（W-124，webhtv-dev-claude-dev-2，2026-10-15 14:33–15:05 CST）

### 15.1 範圍與檔案
- 分支 `task/W-124`（從 origin/ios-poc `47c1d023` 開），guard `LIVE-L1-U1`，一個 commit，`--no-tag`。只動 Core＋Tests＋本文件；`ios/WebHTVApp/`、pbxproj、`app/` 都沒動。
- 新檔：`ios/Sources/WebHTVCore/Live/LiveSource.swift`（`LiveSource` 逐欄寬鬆解碼、`isURLList`、`lineBudget`、`listHeaders`；`LiveHeaders.set` 不分大小寫寫 header）、`Live/LivePlaylist.swift`（`LivePlaylist`／`LiveGroup`／`LiveChannel`／`LiveLine`／`LineSupport`／`LiveCatchupRaw`）、`Live/LivePlaylistParser.swift`（`static func parse(_:source:) throws`，純函式，不寫 log、不做簡轉繁）、`Live/LiveLineSwitcher.swift`（`next()`／`select(_:)`）。
- 改檔：`ios/Sources/WebHTVCore/WebHTVConfig.swift`：加 `lives`（外層 `try?`＋內層 `Lenient`，照 Android `.distinct()` 依名稱去重保留第一個，再過濾 `isURLList`）；`sites` 改 `decodeIfPresent ?? []`，`map` 內容一字未改；`ConfigLoader.validate` 未改。
- 測試：`ios/Tests/WebHTVCoreTests/Live/` 下 `LiveSourceDecodingTests`（10）、`LivePlaylistParserTests`（27）、`LiveLineSwitcherTests`（4）、`LiveRealListTests`（2，`WEBHTV_LIVE_FIXTURES` 才跑）。fixture 全部自製內嵌；真實清單不進 repo；統計只印數字。

### 15.2 審查預備 B-1～B-5、N-1～N-4 的處理（Manager #2158／§14）
| 項 | 處理 | 出處／證據 |
|---|---|---|
| B-1 | #7 隱藏群組＝1 個、38 頻道、46 線路；F-8、AC-7、§6.2.6 已改 | 統計 `#7 … 1(38/46)` |
| B-2 | 照 `LiveParser.isPlayableUrl`（`:54-57`）含 `://` 就保留，標 `unsupported(.other)`；§1.2、§6.2.8 已改 | #9＝15/564/2343；mutant M-14 |
| B-3 | m3u UA：清單內 setting ＞ `#EXTINF http-user-agent` ＞ 源層 ua（`LiveParser.java:117`、`:132`/`:212`、`Channel.java:360`） | `m3uUserAgentIsListSettingThenEXTINFThenSource`；M-18 |
| B-4 | 空名稱（判斷在切 `_` 之前，和 `Group.java:41` 的參數遮蔽一致）補「直播」：m3u 空／缺 `group-title`、txt `,#genre#`、txt 第一個 `#genre#` 前的預設群組 | `m3uMergesGroups…`、`theDefaultGroupIsMade…` |
| B-5 | 空群組照 Android 保留：txt 每個 `#genre#` 行都 `live.getGroups().add(...)`（`LiveParser.java:145`），不管後面有沒有頻道；顯示層也不過濾（`M/LiveActivity:476-481`）。解析層保留，#17＝40 組（4 個空） | `emptyGroupsAreKept`；統計 #17 empty＝4 |
| N-1 | `pass`：布林照收；字串只有 `"true"`（不分大小寫）是 true，`"1"` 是 false（和 Android Gson 一致）；**數字非 0 當 true 是偏離**（Android 遇到數字整個 live 被丟掉，W-124 審查 N-1；W-125 更正本列）。真實設定的 pass 全是布林，沒有實際影響 | `eachLiveFieldToleratesItsOwnBadType` |
| N-2 | 逐欄容錯保留 live（X-17，列入 §5.3）。`header` 物件只收字串值；`type` 缺或 null 當 0、`"0"` 收、讀不出來就不收 | 同上 |
| N-3 | 直播源重名照 Android 去重（`LiveConfig.java:200` `.distinct()`）；去重在 `isURLList` 過濾之前，和 Android 順序一致 | `aRepeatedLiveNameKeepsTheFirst` |
| N-4 | m3u 群組合併 key＝名稱＋密碼（X-16，列入 §5.3） | `m3uKeepsAPasswordGroupApart…`；M-17 |

其他寫明的規則：txt 頻道名不修剪（照 Android；修剪與否各清單頻道數都不變）、線路網址修剪並在第一個 `$` 切 label（X-20）；全形逗號不當分隔；換行用字串層 `replacingOccurrences` 先把 `\r\n`、單獨 `\r` 換成 `\n` 再切（避開 Swift `"\r\n"` 是一個 Character 的陷阱；U+2028／NEL 不當換行）；DRM＝`license_key`／`license_type`／`drm_legacy`／KODIPROP header 的 `drmScheme`/`drmLicense`，或 `format`/`manifest_type` 是 `mpd`/`dash`；DRM 與 parse 旗標先於 scheme 判定。header 名稱不分大小寫合併（X-19）。`LiveLineSwitcher.next()` 第一次回傳起點本身（起點不支援就從後面第一條支援的開始），繞一圈後回 nil；「重試」＝`select(起點)`；U1 沒放 attemptID（屬 U3）。

**已知的可見變化**：缺 `sites` 或 `"sites": null` 的設定，錯誤從 `DecodingError` 變成 `noSupportedSites`（「此設定沒有 iOS 可用的來源…」）。現有測試沒有斷言這點。

### 15.3 先紅後綠
- 紅：新測試先寫，`swift test --filter Live` 編譯失敗 27 個 error（`cannot find type 'LiveSource'／'LivePlaylist'／'LiveLineSwitcher'…`），log `artifacts/w124-logs/red.log`。
- 綠：`swift test --filter Live` 57 tests passed（含 `WEBHTV_LIVE_FIXTURES`、`WANG_MOVIE_JSON`），log `artifacts/w124-logs/green-final.log`。
- 改動前 sites 指紋（`47c1d023`，`artifacts/w124-logs/fingerprint-before.log`）：`169 424a5aae3cb81bcae2a28e2bfdaedb1e2691d241ba0b8f389bddc49e51a43a57 1 10 19 0`（sites 數、id|jar|type 的 sha256、ads、rules、parses、flags）；改動後同值（`realConfigDecodesToTheSameSitesAsBeforeLives` 斷言），真實設定 `lives.count == 20`。
- 全量 `swift test`（帶兩個環境變數）：1256 個測試，1255 過，1 個失敗＝`ConfigLoaderTests.decodesProvidedWangMovieConfig` 期望 `sites.count == 167`，但 W-92 存的設定快照有 169 個 site；改動前的程式解碼同一份檔也是 169（指紋 log），所以是**舊期望值配新快照**，與本改動無關，未修（範圍外）。不帶 `WANG_MOVIE_JSON` 時該測試直接略過。log `artifacts/w124-logs/full.log`。

### 15.4 Mutant（`artifacts/w124-logs/mutants.log`）
| # | mutant | 結果 |
|---|---|---|
| M-1 | txt 每條網址後清空 setting | 殺：`txtSettingsLastUntilTheNextGenre`、真實統計 |
| M-2 | m3u 不清空 setting | 殺：`m3uSettingsClearAfterEachURL` 等 4 個 |
| M-3 | txt `#genre#` 不清空 | 殺：`aSettingBeforeAGenreIsClearedByIt`、#17 統計等 5 個 |
| M-4 | 密碼丟掉 | 殺：`anUnderscoreSplitsTheGroupPassword`、真實統計等 4 個 |
| M-5 | 忽略 `pass` | 殺：`anUnderscoreSplits…`、#17 測試 |
| M-6 | 同名頻道不合併 | 殺：5 個（含真實統計） |
| M-7 | m3u 群組不合併 | 殺：3 個（含真實統計） |
| M-8 | 不去 BOM | **存活 → 證明是死碼**：Foundation 的 UTF-8 解碼本來就會去 BOM（scratch 實測首字元 U+0023），已刪掉那行；行為由 `aByteOrderMarkIsDropped` 鎖住 |
| M-9 | 不換 `\r\n` 直接切 `\n` | 殺：`everyLineEndingSplitsLines`、真實統計 |
| M-10 | `lives` 嚴格解碼 | 殺：`oneBrokenLiveCostsOnlyItself` |
| M-11 | `sites` 包 `try?` | 殺：`aBrokenSiteListStillFailsToDecode` |
| M-12a／b | `lineBudget` 用 min／switcher 不繞回 | 殺：budget 測試／3 個 switcher 測試 |
| M-13 | `#EXTINF` 名稱取第一個逗號後 | 殺：`m3uNameIsAfterTheLastComma…` |
| M-14 | 丟掉 `,http://` 這類線路 | 殺：分類測試、#9 統計 |
| M-15 | 源層 header 逐鍵合併 | 殺：`theSourceFillsOnlyWhatALineLeavesEmpty` |
| M-16 | txt setting 行也當頻道行 | 殺：`aSettingLineWithACommaMakesNoChannel` |
| M-17 | m3u 群組 key 不含密碼 | 殺：`m3uKeepsAPasswordGroupApart…` |
| M-18 | `#EXTINF` UA 蓋過清單 setting | 殺：`m3uUserAgentIsListSetting…` |

### 15.5 真實清單統計（debug build，`swift test` 預設；macOS 26 arm64，本機 Mac，非 Simulator；耗時為 5 次中位數）
| # | 格式 | G/C/L | 空群組 | 隱藏 G(C/L) | 清單內 UA C/L | playable | attempt | drm | parse | youtube | p2p | sniff | proxy | other | 整台不支援 | ms |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 3 | m3u | 21/2112/2253 | 0 | 0 | 3/3 | 2172 | 0 | 81 | 0 | 0 | 0 | 0 | 0 | 0 | 81 | 122.1 |
| 4 | txt | 11/1635/1712 | 0 | 0 | 0 | 1712 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 25.2 |
| 5 | txt | 62/3421/3793 | 0 | 0 | 0 | 3621 | 0 | 0 | 0 | 60 | 0 | 106 | 0 | 6 | 157 | 63.5 |
| 6 | txt | 28/1335/1661 | 0 | 0 | 0 | 1621 | 39 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | 28.2 |
| 7 | m3u | 33/1233/1288 | 0 | 1(38/46) | 0 | 1263 | 25 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 48.9 |
| 8 | m3u | 11/114/114 | 0 | 0 | 0 | 114 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 9.9 |
| 9 | txt | 15/564/2343 | 0 | 0 | 0 | 2342 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 | 37.7 |
| 10 | txt | 38/7255/9041 | 0 | 4(3299/3331) | 0 | 8935 | 105 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 | 148.3 |
| 12 | txt | 82/965/2920 | 0 | 0 | 0 | 2880 | 36 | 0 | 0 | 0 | 0 | 0 | 0 | 4 | 3 | 41.4 |
| 14 | txt | 4/919/2761 | 0 | 0 | 0 | 2722 | 36 | 0 | 0 | 0 | 0 | 0 | 0 | 3 | 3 | 36.8 |
| 15 | txt | 4/49/49 | 0 | 0 | 0 | 49 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.7 |
| 17 | txt | 40/4367/6726 | 4 | 0 | 1034/1070 | 4887 | 51 | 0 | 1070 | 381 | 325 | 0 | 0 | 12 | 1606 | 115.6 |
| 20 | txt | 24/326/331 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 331 | 0 | 0 | 0 | 0 | 326 | 4.9 |

- 和 W-92 的 G/C/L、Reviewer 依 Android 規則重算的參考表（review-prep §5.2）**逐格相同**；參考表的「http」含 parse／drm 線路，扣掉後即本表 playable（#3：2253−81＝2172；#17：5957−1070＝4887）。沒有需要解釋的差異。
- AC-6：#17 清單內 UA 正好 1034 頻道／1070 線路，全在第 26～30 群組，1070 條都是 `unsupported(.parse)`；其他群組每條線路都帶源層 UA；`pass: true` 下 15 個 `_` 群組都看得見、名稱不含 `_`、password 都是 nil；`pass` 關掉時正好 15 個變隱藏。
- AC-24：最慢 #10 148 ms（debug），#3 122 ms、#17 116 ms，都低於 500 ms 目標，不需另附 release 數字。名稱索引 O(n)（X-8），無整數 offset 取 index。Simulator 捲動部分屬 U2。

### 15.6 Ponytail review（對最終 diff）
- 1（Should fix）`Setting` 用假字串（`"legacy"`、`"header"`）代表 DRM 旗標 → 已改成單一 `hasLicence` 布林，少 6 行。
- 2（Nice to have）`#KODIPROP …stream_headers/common_headers` 沒有測試 → 已補 `kodiStreamHeadersReachTheLineAndTheirDRMSchemeMarksIt`。
- Verdict：兩項修完 Ship。未查：Android `HeaderAdapter` 遇到非物件 `header` 是拋錯還是忽略（iOS 忽略，X-17 已記）。

### 15.7 風險與未完成
- `timeout` 沒有上限（`shortcut:` 註記在 `LiveSource.lineBudget`），U3 再評估。
- `LiveSource.listHeaders` 只供 U2 抓清單用；U2 不能用 `ConfigSource.resourceURL`（`;` 截斷）或 webHTV 的 10 秒逾時抓清單（§14：30 秒總時長）。
- 去重在 `isURLList` 前：若 csp `api` 源和 URL 源同名，URL 源會被去掉（和 Android 一致；本設定沒有）。
- Simulator／實機都沒測（U1 沒有 UI）；AC-7 的 UI 部分、AC-24 的捲動在 U2。

### 15.8 Recovery anchor
- 目標：W-124 U1 送審。狀態：實作、測試、mutant、統計、Ponytail 完成；commit 由 guard finish 建立，SHA 記在看板與 work done。
- 下一步：Reviewer 審 W-124 → Manager 推 origin → 開 W-125（U2）。

## 16. U2 入口、清單與播放實作紀錄（W-125，webhtv-dev-claude-dev-2，2026-10-15 16:13 起）

### 16.1 範圍與拍板
- 分支 `task/W-125`（從 origin/ios-poc `31161856` 開），guard `LIVE-L1-U2`，一個 commit，`--no-tag`。
- Manager #2158（W-129）：B2-1 直播固定 1×；B2-2 清單 30 秒為**總時長**、換源時舊結果作廢；B2-3 空群組照 Android 顯示（#17＝40 組）；B2-4 U2 先選第一個源（記住上次的源歸 U4）。另依 #2246 修 W-124 審查 N-1（§6.1、§15.2 更正為偏離）、N-2（`LiveLineSwitcher` 起點超出範圍時繞回，不再當掉）。
- 檔案：Core 新 `Live/LiveListLoader.swift`；`Live/LiveLineSwitcher.swift`（N-2）；App 新 `LiveTVView.swift`（＋pbxproj 4 處，照 `MPVEngine.swift` 先例）；`WebHTVApp.swift`：`ConfigView.lives`（在唯一採用點 `show(_:from:)` 設定——W-121 之後 rebuild／adopt／restore 三處都走它）、`HomeView`／`CMSView` 傳 `lives`、`homeHeader` 的「直播」按鈕（`lives` 空時不顯示；資料夾頁沒有 `homeHeader`）、`PlaybackSession.open(url:…, rate:)`（直播傳 1）、`LivePlayerScreen`（`PlayerView` 維持 private）。

### 16.2 設計落地
- `LiveListLoader`（actor，`shared`）：網址只有 `./`、`../` 才對設定位址解析，**不經** `ConfigSource.resourceURL`（它會在第一個 `;` 截斷）；絕對網址只收 http(s)。送 `LiveSource.listHeaders`。總時長用 task group 和 `Task.sleep(limit)` 賽跑（預設 30 秒，測試注入 0.3 秒），`URLRequest.timeoutInterval` 同值；不用 `URLSession.webHTV`（10 秒閒置）。非 2xx →「HTTP <碼>」、逾時 →「逾時」、其他連線錯誤 →「無法連線」，訊息不含網址或 header（D§6.7）。上限 8 MB（比照 `HLSAdSkip`）。記憶體快取 key＝網址＋排序後的 listHeaders；`refresh: true` 重抓。解析在 actor 上跑（不在 main actor）。
- `LiveTVView`：源選單（Menu＋Picker）、載入中「載入清單中（最多 30 秒）」、失敗頁「無法載入此直播源」＋原因＋重試（原因也顯示在源選單旁）、兩欄（群組欄 112pt，跟字級放大但最多 140pt）。過濾 `isHidden` 群組；空群組點下去顯示「此群組沒有頻道」；整個源沒有可顯示的群組時顯示「此直播源沒有可顯示的頻道」；整台不支援的頻道變灰、標「iOS 不支援」、不能點。`.task(id: (源, 重載次數))`：換源或重試會取消前一個請求，取消後不寫入畫面（B2-2 的作廢）。點頻道：`LiveLineSwitcher` 第一條可試的線路，`history: nil`、`rate: 1`，開播前清掉上一部的 `advance`／`episodeStepper`／`episodeSteps`。
- Ponytail review 後加的兩點：設定重新整理讓 `lives` 變短時，選中的源以夾住範圍的計算屬性取得（原本 `lives[sourceIndex]` 會越界當掉）；已載入的清單可下拉重新整理（清單網址可能帶短效 token，例如 tv123 的 `sid`）。

### 16.3 測試
- 先紅：`LiveListLoaderTests` 編譯失敗（`cannot find 'LiveListLoader'`，`artifacts/w125-logs/red.log`）；N-2 測試在修正前讓測試程序以 `Index out of range` 當掉（`red-switcher.log`）。
- 綠：`swift test --filter Live` 64 個全過（`green-core.log`）：`LiveListLoaderTests` 6 個（header 與 `;` 網址原樣、相對網址與匯入設定無 base、失敗訊息只有狀態碼、總時長期限、快取與 refresh、過大與 JSON 清單）＋`aStartOutsideTheLinesWraps`。
- 全量 `swift test`：1283 tests／47 suites 全過（`full.log`）。
- App：`xcodebuild … -destination id=107AA88B… build` 成功（`app-build.log`）。
- 補測（mutant 後）：`theWholeFetchHasOneDeadline` 加一個「每 0.1 秒送 1 位元組、永不結束」的假站，只有總時長期限能讓它結束（閒置逾時永遠不會觸發）；加 `.timeLimit(.minutes(1))`，拿掉期限時測試會失敗而不是卡住。重跑 `swift test --filter Live` 64 個全過（`green-final.log`）。

### 16.4 Mutant（`artifacts/w125-logs/mutants.log`）
| # | 突變 | 結果 |
|---|---|---|
| M2-1 | 網址在第一個 `;` 截斷（`resourceURL` 的行為） | 殺：`aListIsFetchedWithTheSourceHeadersAtItsAddressAsWritten` |
| M2-3 | 不送 `listHeaders` | 殺：同上 |
| M2-x | 快取 key 不含 header | 殺：`aListIsFetchedOnceUntilRefreshed` |
| M2-y | 拿掉總時長期限（只剩 request 閒置逾時） | 第一輪**存活**（永不回應的假站兩種逾時分不出來）→ 補 trickle 假站後第二輪卡住 600 秒 → 加 `.timeLimit` 後殺：`theWholeFetchHasOneDeadline` |
| M2-z | 非 2xx 也當成功 | 殺：`aFailedFetchSaysOnlyWhatWentWrong` |
| N-2 | （修正前）起點負數 | 修正前測試程序 `Index out of range` 當掉（`red-switcher.log`） |
- App 層（M2-4～M2-10）沒有單元測試能殺，由 §16.5 的 Simulator 情境證明：M2-4 對 `history.json`、M2-5 對 #7／#10 群組數、M2-6 對灰色不能點、M2-7 對 2.5× 仍原生、M2-9 對 App build、M2-10 對 AC-3。

### 16.5 Simulator（`artifacts/w125-gui-evidence/RESULT.md`，背景 fork 執行）
- 受測 build：本單工作樹（parent `31161856`）。`WebHTVApp` `0b3cefa8…`、`WebHTVApp.debug.dylib` `447f289d…` 在 .app 與 Simulator 容器相同；新 dylib 含 `LiveTVView` 字串 4 次（W-41 版 0 次）。Simulator `WebHTV-dev2`（`107AA88B-F2E2-430A-B3CC-500C7ED07B1E`）；設定用本機 `python3 -m http.server` 提供 W-92 設定檔副本（末尾多一個回 404 的「本機404」源）與拿掉 `lives` 的副本。容器測後還原 BYTE-IDENTICAL。
- 結果（全部 PASS）：
  1. AC-9：標題列「直播」，accessibility label「直播電視」，點擊區 47×44pt；進入源選單＋兩欄；返回首頁；分頁仍 5 個。
  2. AC-3：沒有 `lives` 的設定沒有按鈕。
  3. AC-7：#7 群組欄 32、#17 40（空群組點下去「此群組沒有頻道」）；**#10 是 35 不是 34**——live 清單在 W-92 之後多了 1 個群組（現在 39 組，隱藏的仍是那 4 個），不是過濾錯誤。證據只記數字，不留名稱。
  4. AC-10：#8 原生 1.0× 播出（`started … on 原生 in 3839ms`），畫面變化；`history.json` 播放前後都不存在；片庫「記錄」仍空。
  5. AC-11：#15 原生失敗（`on MPV … reason=failure: … NSURLError -1`）後 MPV 1× 播出，reason 不是 viewer。
  6. B2-1：設定預設倍速 2.5× 後播 #8，仍 `on 原生 … @1.0x`，沒有換 MPV；測後改回 1×。
  7. AC-23：#20 抽樣列、#3 的 DRM 群組、#17 的 `parse=` 群組（第 26 組）都變灰、標「iOS 不支援」，點了不開播放器。
  8. AC-24：#10 979 台的群組快速滑 12 次，肉眼沒有卡頓；選源後 6–10 秒出清單（含網路）。含成人名稱的錄影已刪，只留文字紀錄。
  9. 404 源：「無法載入此直播源」＋「HTTP 404」，源選單旁也有原因；重試送出第二次請求。
  10. AC-22：app log `okhttp/` 0、帶 query 的網址 0；唯一的 `sid=` 是 MPV 字幕欄位 `sid=auto`，不是 token。
  11. 回歸：一般點播站（荐片）的詳情頁沒有「直播」按鈕、影片照常原生播放、分頁 5 個。
  12. 下拉重新整理：本機清單收到新的 GET（#8 自己的請求在 network log 裡分不出來）。
- 未驗：實機、AirPlay、PiP、VoiceOver 實際朗讀（只核 accessibility label）。

### 16.6 Ponytail review（對最終 diff 跑過）
- 1（Must fix）設定重新整理讓 `lives` 變短時，`lives[sourceIndex]` 越界當掉 → 改成夾住範圍的 `source` 計算屬性，`lives` 空時顯示「此設定沒有直播源」。
- 2（Should fix）已載入的清單沒辦法重抓（token 過期就只能重開 App）→ 加下拉重新整理。
- 未查：所有源的清單都留在記憶體時的用量（上限是源的數量，本設定 20 個）。

## 17. U3 換台與自動換線實作紀錄（W-126，webhtv-dev-claude-dev-2，2026-10-15 17:24 起）

### 17.1 範圍與拍板
- 分支 `task/W-126`，疊在 W-125 審過並 rebase 後的 `af08cfed`（Manager #2431：發布凍結期間不等推送）；guard `LIVE-L1-U3`，一個 commit，`--no-tag`。W-127（U4：上次頻道與收藏）已改派 claude-dev（#2435／#2436），本單做完交棒。
- Manager #2158（W-129）：X-B1 先 U3 再 U4，**收藏切換與收藏群組內換台不在 U3**（歸 U4）；B3-1 `freshEngine` 一次性、不存成 session 旗標；B3-2 15 秒換線預算在暫停或背景時不計時。
- 檔案：Core `PlaybackEngine.swift`（`PlayerRouter.open(_:freshEngine:)`）、`Live/LivePlaylist.swift`（`[LiveChannel].zap(from:by:)`）；測試 `PlaybackEngineTests.aFreshEngineOpenStartsOnTheDefaultAgain`、新 `Live/LiveZapTests.swift`；App `WebHTVApp.swift`、`LiveTVView.swift`。

### 17.2 設計落地
- **`freshEngine`（AC-17，B3-1）**：`PlayerRouter.open(_:freshEngine: Bool = false)`：true 時就算 session 開著也 `startSession()`（回到全域預設、fallback 額度重置），false 時照舊 `beginAttempt()`。`PlaybackSession.open(url:…, freshEngine:)` 把它存進 `freshEngineOnce`，`load` 呼叫 `router.open(…, freshEngine: freshEngineOnce)` 後**立刻清掉**，所以 inline 播放清單的下一項等後續 `load` 都照舊沿用 session 的引擎；點播所有呼叫端沒有傳這個參數，行為不變。
- **事件槽**：`PlaybackSession.lineObserver: ((LiveLineEvent) -> Void)?`，`enum LiveLineEvent { started, failed }`。`.started` 在 `watchStartup` 起播成功處送出；`.failed` 在 `router.onUnrecoverable` 兩個送出非 nil `onFailure` 的地方一起送出（`load` 裡清除用的 `onFailure?(nil)` 不送）。`closePlayer` 一律清掉 `lineObserver`，關閉後的晚到事件不會再被收到。
- **`LiveTVController`（App，`@MainActor @Observable`）**：持有源、目前群組的頻道、頻道序號、`LiveLineSwitcher`、`attempt` 與預算 `Task`。每開一條線路 `attempt += 1`；事件和預算都先比對 `attempt`，舊線路晚到的事件丟掉。開線路：`history: nil`、`rate: 1`、`freshEngine: true`，並清掉上一部的 `advance`／`episodeStepper`／`episodeSteps`。一輪試過所有可試線路（繞回）後停在「此頻道目前無法播放（已試 N 條線路）」＋「重試」「換台」，**不自動換台**。播到結尾（`onPlaylistFinished`）顯示「播放結束」＋「重新播放」，不算失敗。
- **預算（B3-2）**：`LiveSource.lineBudget` 秒（`max(timeout ?? 15, 10)`），每 0.25 秒累加一次，只在 `session.activity.showsPause`（引擎 rate≠0 且不是 idle，和起播監看同一個「使用者想播放」）而且 App 不在背景時才累加；起播成功就取消。點播的 `startupTimeout`（原生 10、MPV 20）一行都沒改。
- **log**：`[live] line <i>→<j> reason=failed|budget`、`[live] line <i> reason=… — all <N> lines tried`，只記序號與原因（D§6.7）。
- **換台**：`[LiveChannel].zap(from:by:)`（Core，可單元測試）：在目前群組內繞回、跳過整台不支援（含沒有線路）的頻道；Android 預設不跨群組。
- **播放畫面（直播模式）**：`PlayerView(live:)`。手勢：直播時垂直拖曳起點在左 1/4＝亮度、右 1/4＝音量、中間 1/2＝換台（放手時垂直位移 > 80pt 且角度 > 70°；往上＝上一台、往下＝下一台，拖曳中顯示「上一台／下一台」）；點播仍是左半亮度、右半音量（`classify` 只有 `live != nil` 才會回 `.zap`）。控制列：直播隱藏倍速按鈕（`PlayerControlBar.live`）；上一集／下一集因 `episodeStepper` 為 nil 不顯示；片頭／片尾因沒有觀看紀錄（`watching` nil）不顯示。PlayerView 自己的錯誤泡泡在直播時不顯示，改由直播卡片說明，避免兩層訊息。`LivePlayerOverlay`：隨控制列出現的「頻道名＋線路 i／n：名稱」選單、上一台／下一台按鈕（44pt），以及不隨控制列消失的失敗／結束卡片。VoiceOver：直播時播放畫面有「上一台」「下一台」自訂動作（點播沒有，Ponytail 修正）。關閉按鈕先 `live.stop()` 再 dismiss，計時器不必等關閉動畫。

### 17.3 測試
- 先紅：新測試先寫，`[LiveChannel]` 沒有 `zap`、`open` 沒有 `freshEngine` → 編譯失敗（`artifacts/w126-logs/red.log`）。
- 綠：`PlaybackEngineTests`＋`aNativeStartIsGivenUpOnSoonerThanAnMPVStart`＋Live 共 114 個全過（`green-core.log`），含既有的 `theNextEpisodeStaysOnTheSessionsEngine`（AC-17 的 false 側）與 10／20 秒起播逾時。
- 全量 `swift test`：1286 tests／47 suites 全過（`full.log`）。App `xcodebuild` 成功（`app-build.log`）。
- Mutant（`artifacts/w126-logs/mutants.log`）：M3-3 router 忽略 `freshEngine` → 殺（`aFreshEngineOpenStartsOnTheDefaultAgain`）；M3-4 `freshEngine` 預設 true → 殺（`theNextEpisodeStaysOnTheSessionsEngine` 等 6 個）；M3-11 換台不跳過不能播的頻道 → 殺（2 個 zap 測試）；換台不繞回 → 殺。App 層（M3-1 沒有預算、M3-5 拿掉 attempt、M3-7 試完自動換台、M3-8 點播也能換台、M3-10 關閉沒停計時器）沒有單元測試能殺，由 §17.4 的 Simulator 情境證明。

### 17.4 Simulator
- **第一輪 FAIL**（`artifacts/w126-gui-evidence/RESULT.md`）：點任何直播頻道都打開一個全黑、沒有控制列、關不掉的播放畫面（聲音在底下照播）。原因：`fullScreenCover(isPresented:)` 的內容在同一次更新裡讀到還是 nil 的 `controller`。log 部分已證明：AC-12 線路 1→2 `reason=failed`（17:42:23.333）、線路 2 開於 23.336、10 秒換 MPV（33.431）、線路 2→3 `reason=budget`（38.918，距開線 15.58 秒）、線路 3 原生起播（40.498）；AC-13 三條試完後 38 秒內沒有重開、沒有換台；點播回歸 PASS。
- 修正：改成 `.fullScreenCover(item: $controller)`（`LiveTVController: Identifiable`），另存一份 `running` 參照，讓封面不論怎麼關閉都會 `stop()` 計時器。
- **第二輪**（2026-10-16 09:33–10:02，`artifacts/w126-gui-evidence/run2/RESULT.md`）：咪咕與 FYTV 清單這輪連不上，可播線路改用本機 ffmpeg 產生的 HLS／FLV 測試片。AC-12 PASS（line 1→2 failed、2→3 budget，疊層「線路 3／3」；距線路 2 開 16.03 秒，超出 15±1 上緣 0.03 秒）；AC-13 PASS（卡片「已試 3 條線路」、無錯誤泡泡、30 秒不自動換台、重試與換台可用）；AC-14 PASS（FLV 台在 MPV，中間下滑換到 HLS 台從原生開始）；AC-15 PASS（2.37 秒內下滑 5 次，停在最後一台，沒有換線紀錄）；AC-16 PASS（直播兩側亮度／音量、中間換台；點播中間仍是亮度／音量）；直播隱藏倍速 PASS；線路選單 PASS（不支援的線路變灰，選乙線後「線路 2／3」）；點播回歸 PASS。**情境 8 部分 FAIL**：換線中關閉播放器後約 14 秒，未起播的線路自行失敗，router 的失敗交棒在背景把它交給 MPV 重開（點播一向是關閉後保留項目，直播線路常卡住才暴露）。
- 修正（三點，只改 `LiveTVView.swift`）：①`LiveTVController.stop()` 多呼叫既有的 `session.control("stop")`，關閉直播時卸載項目（點播的關閉行為不變）；②預算改用 `ContinuousClock` 的實際經過時間累計，不再每 tick 固定加 0.25 秒（高負載時 sleep 超時，造成 16.03 秒）；③讀碼發現：最後一條線路因預算用完而進入 exhausted 時，舊碼遞增 `attempt` 並清掉 `lineObserver`，那條線路晚起播時卡片會蓋在播放畫面上——改成 exhausted 不遞增、保留 observer，`.started` 時轉 playing，exhausted 後的 `.failed` 不再重跑一輪。App build 成功（`artifacts/w126-logs/app-build-2.log`）。
- **第三輪定點複驗**（`artifacts/w126-gui-evidence/run3/RESULT.md`）：A AC-12 兩次 line 2→3 budget 於 15.06／15.04 秒 PASS；B AC-13 卡片、30 秒不換台、`all 3 lines tried` 每輪只一次、重試 PASS；C 線路 2 時關閉，之後 40 秒以上沒有任何 `[playback]`／`[live]`、沒有 MPV 交棒、hang server 沒有新連線 PASS；D 慢台（18 秒後才回應）15.09 秒出現「已試 1 條線路」，開線後 17.6 秒在 MPV 起播、卡片消失、疊層「線路 1／1」PASS；E 點播回歸 PASS（點播關閉後仍保留項目）。安裝的是這次 build（hash 相同），data 還原 BYTE-IDENTICAL，工作樹前後不變。第三輪沒有重跑 AC-14／15／16 與線路選單（修正沒動到這些路徑，第二輪已 PASS）。
- Ponytail（最終 diff）：Ship；一項 nice-to-have 未採用、記在這裡：群組裡沒有其他可播頻道時，卡片的「換台」與上一台／下一台按鈕仍顯示但按了沒反應（`zap` 回 nil），不會出錯。
- 未驗：VoiceOver 的「上一台／下一台」自訂動作（自動化工具讀不到）、實機、AirPlay、PiP；直播關閉時卸載項目對 AirPlay 的影響（會一併結束投放）未在實機看過。

## 18. U4 上次頻道與收藏實作紀錄（W-127，webhtv-dev-claude-dev-2，2026-10-16 10:25 起）

### 18.1 範圍與拍板
- 分支 `task/W-127`，疊在 W-126 審過的 `4ce27614`（Manager #2633；W-125～W-127 等 U4 完成後一起 rebase 到當時的 origin 再推）；guard `LIVE-L1-U4`，一個 commit，`--no-tag`。
- 檔案：Core 新 `Live/LiveStateStore.swift`、`StorageMaintenance.swift`（`supportKeep` 加 `LiveTV`）；測試新 `Live/LiveStateStoreTests.swift`、`StorageMaintenanceTests.swift`（kept 清單加 `LiveTV/live-state.json`）；App `LiveTVView.swift`、`WebHTVApp.swift`（入口多傳 `config: source.identity`）。
- 一併處理 W-126 審查（`artifacts/w126-review-2026-10-16.md`）：N-3 線路選單點擊高 32→44pt；N-1、N-2 記在 §18.5。

### 18.2 設計落地
- **`LiveStateStore`（actor，`Application Support/LiveTV/live-state.json`）**：格式照 D§6.5（`schemaVersion` 1、`configs[identity].lastLive`、`last[live]`、`favorites[live]`），`.atomic` 寫入、先寫檔才採用。壞檔另存 `live-state.corrupt-<秒>-<8碼>.json` 後從空開始；比目前新的 schema 先複製成 `live-state.schema<N>.backup.json` 再當空的；檔案存在但讀不到、或搬不走時，什麼都不載入也不寫（`FavoriteStore` 的做法）。不存網址（X-10）。
- **還原（`LiveLastChannel.locate(in:)`）**：同名群組裡的同名頻道 → 其他看得見群組的第一個同名頻道 → 找不到就回 nil；線路先比 `lineLabel`、再用 `lineIndex`、超出用 0。整台不支援的頻道不算找到。**偏離 D§6.5 的第三層**（「第一個群組的第一個可播頻道」）：那不是上次看的頻道，不該標「上次觀看」或出現在「繼續看」；畫面本來就開在第一個群組，所以效果等同，只是不冒充。
- **收藏群組（`[LiveGroup].withFavorites(_:)`）**：傳入的是已濾掉帶密碼群組的清單，所以隱藏群組的頻道不會經由收藏露出（X-11）；每個收藏只取第一次出現的那筆，照收藏順序；清單裡暫時找不到的收藏保留在檔案裡。收藏 key＝設定 identity＋直播源名稱＋頻道名稱（X-9）。
- **畫面**：第一次進入先讀 `lastLive` 選源（找不到就第一個），之後換源就寫 `lastLive`；群組改用名稱記選取，「收藏」出現或消失時不會跳到別的群組。清單上方「繼續看：<頻道>」只在找得到上次頻道時出現，**不自動播放**（X-15）；群組欄捲到選取的群組、頻道欄捲到上次頻道。頻道列：「上次觀看」標記、收藏星號；長按選單「加入收藏／取消收藏」，VoiceOver 有同名動作；不支援的頻道沒有收藏操作。播放疊層加星號按鈕；在「收藏」群組裡打開時，換台就在收藏之間換（controller 的 channels 是收藏群組）。關閉播放器後重讀收藏與上次頻道。
- **寫入時機**：`LiveTVController` 收到 `.started` 才寫上次頻道（群組名＝打開時顯示的群組，包括「收藏」），同時把 `lastLive` 設成這個源。

### 18.3 測試
- 先紅：新測試與 `StorageMaintenanceTests` 的 kept 項先寫，`LiveStateStore`／`LiveLastChannel`／`LivePosition`／`withFavorites` 不存在 → 編譯失敗（`artifacts/w127-logs/red.log`）。
- 綠：`LiveStateStore|StorageMaintenance|Live` 80 個全過（`green-core.log`）。
- 全量 `swift test`：1292 tests／47 suites 中 5 個失敗，都是 WebKit 嗅探或「5 秒內結束」的計時測試（`theProbeReadsOnlyTheHeadOfABodyThatNeverEnds`、`aSniffEndsWhenItsCallerGivesUp`、`MediaSnifferTests` 三支），當時主機 load average 308（Simulator 同時在跑）；負載降到約 75 時單獨重跑 5 個全過（`rerun-load.log`），本單沒有碰這些程式（`full.log`）。App build 成功（`app-build.log`；`generic/platform=iOS Simulator` 會因 Python.xcframework 的雙架構路徑失敗，與本單無關，改用 WebHTV-dev2 的 destination）。
- Mutant 8/8 殺（`mutants.log`）：M4-1 不先找自己的群組、M4-2 不比線路名、M4-3 不支援的頻道也算找到、M4-4 壞檔不另存、M4-5 新 schema 照讀、M4-6 收藏不分直播源、M4-7 收藏群組列出每一筆同名、M4-8 清除無效檔案不保留 `LiveTV`。App 層（選源還原、捲動、不自動播放、`.started` 才寫）由 §18.4 Simulator 證明。

### 18.4 Simulator
`artifacts/w127-gui-evidence/RESULT.md`（2026-10-16 10:33–11:17，WebHTV-dev2，安裝的是這次 build、工作樹前後不變、data 還原 BYTE-IDENTICAL；本機兩個直播源、同名 CCTV1、源 1 有帶密碼群組與一台兩條具名線路）：
- 首次進入：開在源 1，只顯示看得見的群組，沒有「收藏」也沒有「繼續看」。PASS
- AC-18：選線台切到乙線起播 → 結束 App → 重開：選取央視群組、「上次觀看」、「繼續看：選線台」，進頁面沒有任何開播 log；按下去從「線路 2／2：乙線」開始；`live-state.json` 只有群組名、頻道名、lineLabel、lineIndex，沒有網址。上次在源 2 播時重開就開源 2。PASS
- AC-19：長按 CCTV1 加入收藏 → 群組欄最上面「收藏」；源 2 的同名 CCTV1 沒有星號；重開後還在；帶密碼群組從不出現。收藏群組裡換台只在收藏之間換；疊層星號可取消，關閉後清單同步。PASS
- AC-20：檔案寫成 `garbage` → 首頁與直播清單正常、從空開始，原檔另存為 `live-state.corrupt-…json`。PASS
- AC-21：清除無效檔案只列兩個快取資料夾，沒有 `LiveTV`；刪除後收藏和 `live-state.json` 都還在。PASS
- 回歸：三線台 line 1→2 failed、2→3 budget（15.29 秒）、線路 3 起播；點播荐片起播、有倍速、沒有上一台，關閉後 5 個分頁。線路選單 88×44pt（N-3）。PASS
- 未驗：VoiceOver 的收藏動作、長清單捲到上次頻道（測試群組只有兩台）、實機、AirPlay、PiP。

Ponytail（最終 diff）：Ship。兩項 nice-to-have：①評論位置錯（`.onChange` 插在 `fullScreenCover` 的說明之上）——已移正，只動註解順序；②下拉重新整理會跳到上次頻道的群組（之前是跳到第一個群組，不是退步）——未採用，記在這裡。

### 18.5 已知限制（W-126 審查 N-1、N-2）
- N-1：直播關閉播放器會卸載項目（W-126 修背景換 MPV 重開的必要代價），所以在 PiP 中或 AirPlay 投放中關閉播放畫面，直播會一起停；點播照舊保留。實機未驗。
- N-2：起播後無限緩衝但沒有錯誤時不會換線（狀態機在 `.playing` 只聽 `.failed`）；MPV 對直播斷線若回 EOF，畫面顯示「播放結束／重新播放」而不換線——是 EOF 還是 error 未在 log 確認。
- N-4（只記錄）：播放中失敗會接著試同一輪剩下的線路，不回頭試先前播得好的線路；試完顯示卡片，可按重試。

## 19. L1 發布（W-151 紀錄）

- 2026-10-16：U2（W-125 `57562e59`）、U3（W-126 `00931cca`）、U4（W-127 `61f0b060`）審過後一起推上 `ios-poc`（`13bfac42..61f0b060`），隨 App `0.1.80 (81)` 發布：run `38845998865`（headSha `61f0b060`），tag `ios-v0.1.80-b81`，`source.json` `085cd974`，IPA 35,603,927 B。完整紀錄見 `docs/IOS-POC-11-sidestore-release.md`「第八十一次發布」。
- 使用者決定直播多畫質／多音軌不擋本版；W-149 發布後實測。W-127 審查 N-1（清單自帶「收藏」群組撞名）、N-2 待評估。真機尚未驗收。

## 20. W-154 換引擎沿用音軌語言（2026-10-19）

- **問題**（W-149 F-1）：原生播放器選了 Japanese，切到 MPV 後回到 English（`live-tracks-check/applog.txt`：`engine=AVPlayer selected=Japanese … language=ja` 之後是 `engine=MPV selected=English … language=en`）。點播與直播都一樣。
- **根因**：`PlaybackSession` 的 `router.onEngineChange`（`ios/WebHTVApp/Sources/WebHTVApp.swift:5353`，改前行號）在換引擎時把 `tracksToRestore` 清成 nil、`mediaSelection` 清空；唯一的還原機制 `PlaybackMediaSelection.reselections(after:)`（`ios/Sources/WebHTVCore/PausedBackgroundReload.swift:103`）只比對 id，而 id 屬於各引擎（`native-audio-N`／`mpv-audio-N`），所以換引擎後沒有任何東西把語言帶過去，新引擎停在自己的預設。
- **改法**：
  - Core：`PlaybackMediaTrack.reselection(carryingLanguage:)`（`PlaybackMediaSelection.swift`）——純函式，給上一個引擎選中音軌的語言，回傳新引擎要選的 id；語言用既有的 `canonicalLanguageCode` 正規化（大小寫、`_`/`-`、`jpn`＝`ja`、`ja-JP`＝`ja`），完整標籤相同（如 `zh-HK`）優先於同語系；沒有語言、沒有同語言音軌、或預設已是該語言時回 nil（保留預設）。
  - App：`onEngineChange` 在清空前記下 `audioLanguageToCarry`（只在同一項目的換引擎：觀眾切換、失敗改用、起播逾時；`switchReason == "open"` 的新項目不帶）；`router.onMediaSelectionChange` 收到新引擎第一份音軌清單時呼叫 `carryAudioLanguage` 決定一次，經 `selectMedia(.audio, id:)` 選取，並寫一行 `[audio] switch to <引擎>: carried language=… id=…`／`kept default for language=…`。`load()` 開新項目時清掉。
  - 所有換引擎都走 `PlayerRouter.run` → `onEngineChange` 這一條：觀眾切換（`selectEngine`）、速度超過 AVPlayer 能力（`nativeCannotPlayRate`）、播放失敗改用（`engineFailed`）、起播逾時（`startupTimedOut`），所以一次修好。**直播換線不在範圍**：換線是 `session.open(freshEngine: true)` 開新項目（`switchReason == "open"`），照舊回到預設引擎與預設音軌。
  - 沒動音軌選單 UI、自動換引擎規則、直播換線邏輯。
- **驗證**：
  - 先紅後綠：`swift test --filter AudioLanguageCarryTests` 7 個測試，stub 回 nil 時 4 個失敗（`red.log`），實作後 7/7 通過（`green.log`）。涵蓋原生 ja → MPV 選 ja、MPV ja → 原生選 ja、沒有同語言保留預設、沒有先前選擇保留預設、預設已是該語言不動、`jpn`/`ja-JP`/`JA_jp` 互通、`zh-HK` 優先。
  - 全部 `swift test`：1325 個測試、50 個 suite 全過（`full.log`）。
  - App 以 Simulator 為目標 Debug 建置：`** BUILD SUCCEEDED **`（`app-build.log`），改動處沒有新增警告。
  - log 位置：`.herdr-synapse/webhtv-dev/artifacts/w154-logs/`。
  - Simulator（`artifacts/w154-gui-evidence/RESULT.md`，2026-10-19 13:42–13:58 CST）：暫存機 iPhone 18 Pro／iOS 27.0（測完刪除，BC4948DD 全程關機），安裝後雜湊與 build 相同。樣本是本機 ffmpeg 合成的 HLS（300 秒、English 440 Hz 預設＋Japanese 880 Hz，`127.0.0.1:18154`，掛在自製直播源，不連外網），點擊用 XCUITest 單次腳本。A 原生選 Japanese → 切 MPV：`switch to MPV: carried language=ja id=mpv-audio-2` → `engine=MPV selected=Japanese`，選單勾 Japanese；B1 接著切回原生：`switch to 原生: carried language=ja id=native-audio-1` → `engine=AVPlayer selected=Japanese`；B2 在 MPV 親手由 English 改選 Japanese 再切回原生，同樣沿用；C 對照組沒改音軌就切換：`kept default for language=en`，一直是 English。全部 PASS。新引擎會先回報一次預設 English，30–90 ms 內改成 Japanese（在 `started` 之前）；關掉播放器重新開（`open`）回到 English，和設計一致。
  - Ponytail（最終 diff）：Ship，沒有 finding。純函式一個、App 三處接線（記下、套用一次、開新項目清掉），沒有多餘選項；只決定一次是刻意的，避免之後蓋掉觀眾手動的選擇。
- **沒驗到**：
  - Simulator 只測觀眾手動切換（`viewer`）；播放失敗改用、起播逾時、速度造成的自動切換走同一條 `onEngineChange`，只讀碼。新引擎沒有該語言的情況只由單元測試涵蓋。判斷依據是 log 與選單勾選，沒有聽聲音。真實直播、換線、Release、實機都沒測（樣本有 ENDLIST，App 當點播處理）。
  - 兩個引擎回報的語言碼：W-149 的合成樣本兩邊都是 `en`／`ja`（原生取 `extendedLanguageTag ?? locale.identifier`，MPV 取 `track-list/N/lang`）。其他來源（如 MKV 的 `jpn`、原生的 `ja-JP`）只由單元測試涵蓋，沒有實機證據。
  - MPV 第一份音軌清單是否列出所有 HLS 替代音軌：合成樣本上是（A 情境直接 carried）；其他來源若第一份不完整，會記 `kept default` 而不沿用（只決定一次，避免之後蓋掉觀眾的手動選擇）。
