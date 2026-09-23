# IOS-POC-8L — Core Real-Device Acceptance Matrix（核心真機驗收矩陣）

- **2026-09-23 更新（IOS-POC-17）**：外部播放器已從產品移除（⑪ 移到 7.4）、雙內部播放核心落地
  （新增 ⑮–⑲）、點集數直接進播放畫面。RC 內容與 release notes 草稿已同步更新（第三節）。
- 狀態：**驗收準備完成；真機驗收尚未開始**。本文件只整理「要驗什麼、用哪個 build、用哪個來源、
  怎麼判定」，**沒有任何一項因為本文件而變成已驗證**。
- 日期：2026-09-23（CST）
- Lane：`assessment`（僅文件；沒有改任何 functional code、Xcode 專案、workflow、`source.json`）
- 所屬：IOS-POC-8 real-device acceptance（8A–8K 是先前幾次真機回報與修正）
- 這一輪刻意不做：新功能、CSP／Python 擴充、MPV、runtime hot update、重調 IOS-POC-15、
  IOS-POC-12／13、tag、publish、觸發 SideStore workflow、建立 GitHub Release。

## 一、最新 code state（2026-09-23 16:04 CST 以 `git fetch` 後的 remote 為準）

| 項目 | 值 |
|---|---|
| 分支 | `ios-poc` |
| 本機 `HEAD` | `f0495b8b56dca82be06293e47af6825d44222e7a` |
| `origin/ios-poc` | `f0495b8b56dca82be06293e47af6825d44222e7a`（與使用者在 GitHub 核對的一致） |
| ahead / behind | `0 0` |
| worktree | clean |
| 最後一個 functional commit | `63040bb3` feat(ios): the configuration's rules decide what the sniffer accepts（5S-3） |
| `63040bb3..HEAD` | 兩個 docs-only commit（`547d2c1e`、`f0495b8b`），`git diff --stat 63040bb3 HEAD` 只有 `docs/AGENT_HANDOFF.md` 與 `docs/current-task-state.md` |

**結論：最新 HEAD 的 functional tree 與 `63040bb3` 完全相同。** 所以下面第六節直接引用
`63040bb3` 的 297／296 與 Simulator BUILD SUCCEEDED，沒有為了形式重跑。

## 二、目前 public release 為什麼不足以驗 5S-3

| | 值 |
|---|---|
| 目前 SideStore 版本 | `WebHTV 0.1.7 (8)`，tag `ios-v0.1.7-b8` |
| tag 指向 | `add580074c1ecbac421d18ce5009bb0fb61e32b9`（`git rev-parse ios-v0.1.7-b8^{commit}`） |
| `63040bb3` 是否為 `add58007` 的祖先 | **否**（`git merge-base --is-ancestor 63040bb3 add58007` 失敗） |

也就是說 **`0.1.7 (8)` 不含 5S-3**（`SnifferRules`、`MediaSniffer.snifferRules`、`didFinish`
的 `script` 執行）。裝在手機上的版本本身就沒有 rules → sniffer 這條路徑，拿它測 ① 只會量到
「沒有 rules 的舊行為」。

`0.1.7 (8)` **已經包含**（`merge-base --is-ancestor` 逐一確認）：5S-1 ads、5S-2 片頭片尾、
PiP foreground restore（`8d1ab371`、`a25f6b24`）、IOS-POC-16 自建控制列（`2deac879`、
`4899a49c`、`ecb0c3c4`、`006ac6e3`）、IOS-POC-15（`d7247b91`，含 2.5×／3× 音訊修正與
seek 後 buffered bar 修正）。所以**除了 ① 以外的項目，現在手機上的 `0.1.7 (8)` 都能先測**；
但為了讓整份驗收對應同一個 build，建議全部在下一個 RC 上做。

## 三、下一個 acceptance release candidate：`0.1.8 (9)`

| 項目 | 規劃 |
|---|---|
| 版本 | `MARKETING_VERSION = 0.1.8`、`CURRENT_PROJECT_VERSION = 9`（目前專案是 `0.1.7`／`8`；`source.json` 最新一筆是 `0.1.7`；`0.1.8`／`9` 未被使用過） |
| 內容 | 最新 `ios-poc` HEAD：**5S-3 + 5S-1 + 5S-2 + IOS-POC-15 + 2.5×／3× 音訊修正 + PiP foreground restore + IOS-POC-16**，**加上 IOS-POC-17**（外部播放器移除、雙核心架構與播放器選擇、點集數直接播放、AVPlayer 失敗顯示原因）。**MPV 已依使用者 2026-09-23 決定在正式版開放**（17E），真機 first frame 尚未驗證，保護是 10 秒 first-frame watchdog 自動回原生；畫質選單移進控制列 |
| tag / asset | `ios-v0.1.8-b9` / `WebHTV-0.1.8-9.ipa`（workflow 依 input 自動命名） |
| 本輪已做的預檢（**在 `63040bb3` 的 tree 上做的；IOS-POC-17 之後尚未重跑 iphoneos Release 預建置**） | **本機 unsigned `iphoneos` Release build，`BUILD SUCCEEDED`**（旗標與 workflow 相同，以命令列覆寫 `MARKETING_VERSION=0.1.8 CURRENT_PROJECT_VERSION=9`，**沒有改專案檔**）。產物 `Info.plist`：`com.webhtv.ios.poc` / `0.1.8` / build `9` / minimum iOS `17.0`；主執行檔 36,684,144 bytes，`strings` 找得到 `SnifferRules`／`snifferRules`。62 條 warning 分布在 `MPVProbeView.swift` 13、`WebHTVApp.swift` 7、`HTTPHost.swift` 7 等檔，與 IOS-POC-15／5S-3 記錄過的既有 warning 同檔，**本輪沒有逐條對 base 比對** |
| 本輪**沒有**做 | 版號 commit、tag、push、`workflow_dispatch`、GitHub Release、`source.json` 更新、IPA 下載回驗 |

**發布時（需要使用者另外明確授權）的最短序列**，與 `0.1.6`／`0.1.7` 相同：

1. 一個 commit：`project.pbxproj` 兩處 `MARKETING_VERSION = 0.1.8`、`CURRENT_PROJECT_VERSION = 9`
   （`release(ios): the project carries 0.1.8 (9)`）。不改的話 workflow 的「輸入留空就讀專案值」
   會指向已發布的 `0.1.7 (8)`。
2. push 該 commit（需授權）。
3. `workflow_dispatch`：`version=0.1.8`、`build_number=9`、`release_notes=<下面的草稿>`。
   **注意：推一個 `ios-v*-b*` tag 也會觸發同一個 workflow**（`on.push.tags`），所以不要手動建 tag。
4. 下載回 `WebHTV-0.1.8-9.ipa` 驗：`Payload/` 只有一個 `.app`、`Info.plist` 版本與 build、
   二進位含 `SnifferRules`。

### Release notes 草稿（不宣稱真機驗收通過）

```text
WebHTV 0.1.8 (9) — 驗收候選版（未經真機驗收）

新增
- 設定檔的 rules 接進嗅探：依規則的 hosts 決定 exclude／regex 是否接受候選網址，
  script 只在嗅探用的 WebView 內執行。沒有規則命中時行為與先前相同。
- 只使用 App 內建播放器：移除 Infuse／Fileball／SenPlayer／VidHub。
- 點選集數直接進入播放畫面（不再經過「選擇播放器」頁）。
- 新增 MPV 播放器：設定頁「預設播放器」可選原生播放器或 MPV，播放控制列顯示並可切換目前使用的播放器，
  切換時保留位置、速度與集數。MPV 為新加入的相容播放器，尚未完成真機驗收；
  若 MPV 載入後 10 秒內沒有畫面，會自動切回原生播放器。
- 畫質選單移到播放控制列（來源提供多個畫質時才出現）。
- 播放失敗時顯示原因（網路、HTTP 狀態、格式不支援），不再只有黑畫面。

沿用並一併帶上
- 設定檔 ads 網域封鎖（只作用在嗅探 WebView）。
- 片頭／片尾：在控制列設定，起播跳過片頭、片尾觸發既有的下一集流程（取樣間隔約 5 秒）。
- 播放緩衝與下一集預解析（IOS-POC-15）：VOD forward buffer 60／90／120 秒、
  下一集在本集最後 90 秒內預先解析。效能尚未有真機量測數字。
- 2.5×／3× 播放速度的聲音修正。
- 從子母畫面（PiP）回到 App 時恢復一般播放器。
- 自建播放控制列：關閉、播放／暫停、±10 秒、進度條與已緩衝區段、速度、片頭／片尾、
  字幕／音軌（多於一個選項時才出現）、AirPlay。

已知限制
- MPV 暫不支援子母畫面、AirPlay 與字幕／音軌選單（選 MPV 時這些按鈕會隱藏）。
- 本版為驗收用候選版，真機驗收結果尚未回報。
```

## 四、驗收時的可觀察性限制（先讀，否則會誤判）

1. **App 的診斷行全部是 `print`**（`[playback]`、`[sniffer]`、`[spider]`…，
   `ios/WebHTVApp/Sources/WebHTVApp.swift` 各處）。Release build 經 SideStore 安裝、沒有接
   Xcode 除錯器時，`print` 寫到 stdout，**不會進統一日誌**，Console.app 也看不到。
   這是 iOS 平台行為，**本輪沒有在這支手機上實測**。所以本輪所有判定都以「畫面上看得到的結果」為準，
   不以 log 為準。IOS-POC-15 §8 那套以 `[playback]` 行量測的方法，在 SideStore 安裝上**同樣看不到**，
   之後使用者自行做效能驗收時要先解決觀測管道（這不是本輪要做的事，只是記下來）。
2. **嗅探 WebView 不顯示在畫面上**（`MediaSniffer.Collector`，`ios/Sources/WebHTVCore/MediaSniffer.swift:249`，
   用完即丟），而且程式裡**沒有**設 `isInspectable`，Safari Web Inspector 附掛不上。
   所以「某個廣告請求被擋」「某條 rule 改變了哪個候選被接受」**在手機上沒有任何可見訊號**，
   只看得到最終結果：那一集有沒有播起來、播的是不是正片。
3. 設定檔以 **`wang-movie.json`（SHA-256 `b17576e3…`，本輪重新下載比對一致）** 為準。
   要從遠端 URL 載入，drpy 與 Python 來源才會出現（本機匯入檔只列 62 個來源，遠端 109 個）。

## 五、`wang-movie.json` 對 ①② 的實測盤點（本輪桌面檢查）

**做法**：讀設定檔的 `rules` 與 `ads`；比對全部 167 個 site 的欄位；再把 site 引用的
**40 個 config-relative 資源**（`./json/*`、`./py/*`、`./drpy_libs/*`，以 400 ms 間隔抓取，
39 個成功，`json/4k.js` 404 是既知狀態）全文搜尋每一個 rule host 與 ad host。

### `rules`（10 條）

| rule | hosts | 內容 | 在 `wang-movie.json` 找得到會碰到它的來源嗎 |
|---|---|---|---|
| `农民嗅探` | `toutiaovod.com` | regex `video/tos/cn` | **有候選**：`🥇｜农民｜高清`（key `csp_Wwys`，`csp_XYQHiker`，ext `./json/农民影视.json`），其規則檔自己寫了 `手动嗅探视频链接关键词 … video/tos` |
| `夜市` | `yeslivetv.com` | **script** 點播放鈕 | **沒有**。沒有任何 site 欄位或已抓取資源提到 `yeslivetv` |
| `毛驴` | `www.maolvys.com` | **script** 點確認鈕 | **沒有**。同上 |
| `七新嗅探` `czzy` `bdys` `bdys10` `火山嗅探` `抖音嗅探` `cl` | 各自 hosts | regex／exclude | **沒有**。`哔哩.py`、`aidianying.py` 只出現 `sf1-cdn-tos.huoshanstatic.com`，它**不**命中 `huoshan.com`（不是子字串、也不整串匹配） |

**關鍵事實：即使 `农民｜高清` 真的走到嗅探，`农民嗅探` 也不會改變肉眼可見的結果。**
內建關鍵字 `MediaSniffer.defaultKeywords` 本來就含 `video/tos`
（`ios/Sources/WebHTVCore/MediaSniffer.swift:63`），所以 `…toutiaovod.com/…/video/tos/cn/…`
在沒有規則時也會被接受。規則只有在「內建會拒絕、規則會接受」或 `exclude` 擋掉內建會接受的網址時
才會讓結果不同，而這份設定檔裡**找不到**這樣的來源。
另外它的 XYQHiker 端在 2026-09-17 golden 裡回的是 `parse:0` 直連 m3u8，根本沒進嗅探——
**是否走嗅探取決於當下線路與 provider 狀態，本輪沒有 live 驗證。**

→ ① 在這份設定檔上**無法做成「真機看到 rule 改變嗅探行為」的正向驗收**，兩個 `script` 來源
（`yeslivetv.com`、`www.maolvys.com`）**在這份設定檔裡不存在**。
能在真機上做的只剩非回歸：會走嗅探的來源照常播放。正向行為的最強證據仍是
`SnifferRulesTests.swift` 的 31 條（含真 socket＋真 `WKWebView` 證明 script 只在嗅探 WebView 執行、
頁面 host 沒規則就不注入）。
**「script 只在 sniffer WebView、WebHome 不受影響」是結構事實**：整個 iOS 樹只有兩處建立
`WKWebView`——`MediaSniffer.swift:249`（Collector）與 `WebHTVApp.swift:3307`（WebHome bridge）——
而 `snifferRules` 只在 `MediaSniffer.swift:201` 交給 Collector。`wang-movie.json` 也沒有任何
WebHome site，所以真機上沒有 WebHome 頁面可以拿來對照。

### `ads`（1 筆）

`wang-movie.json` 的 `ads` 只有 **`mozai.4gtv.tv`** 一個網域（62 筆 ad host 在 `wang-sex.json`）。
上面 40 個資源與全部 site 欄位**都沒有提到 `mozai` 或 `4gtv`**，而封鎖只作用在看不見的嗅探 WebView。
→ ② 的「已知廣告請求被擋」在這份設定檔＋SideStore 安裝上**沒有可觀察的正向案例**；
能在真機上驗的是「沒有過度封鎖」：走嗅探的來源、海報、字幕、API、媒體照常。
正向證據仍是 5S-1 的真 `WKContentRuleList`＋真 `WKWebView`＋真 socket 測試。

**若使用者要在真機上看到①②的正向行為，需要使用者提供一個會載入 `yeslivetv.com`／
`www.maolvys.com` 頁面、或會請求 ad host 的來源，並且要有可見的觀察管道。**
本輪不為此新增任何診斷功能（使用者指示不新增功能）；需要的話是另一個獨立決定。

## 六、Verification baseline（引用，不是重跑）

| 檢查 | 結果 | 證據等級 |
|---|---|---|
| `swift test --package-path ios` | **297 tests / 296 pass**；唯一失敗 `reportsLiveType4SitesFromProvidedConfig`（88看球 解析成 HTML `qq-kbs.html`，provider 天氣，**不修**） | **引用** `63040bb3` 2026-09-23 的量測；HEAD functional tree 與它相同，所以仍成立。**本輪未重跑** |
| **更新 2026-09-23，IOS-POC-17B 之後** `WANG_MOVIE_JSON=<使用者設定> swift test --package-path ios` | **322 tests，全部通過**（297 − 1 移除 + 1 移除檢查 + 25 雙核心）；那條天氣測試這次也通過 | 本輪實測，macOS |
| Simulator Debug build（`id=7B4E9557-4774-4EB9-B408-BB544DCC8657`） | **BUILD SUCCEEDED** | **引用**，同上 |
| iphoneos Release unsigned build（RC 預檢，`0.1.8`／`9` 覆寫） | **BUILD SUCCEEDED**，Info.plist 版本正確 | **本輪實測**（2026-09-23 16:06–16:07 CST） |
| Ponytail | **本輪沒有跑 functional Ponytail**，因為沒有 functional diff。不宣稱執行過 | — |

## 七、完整真機驗收矩陣

狀態只有四種：**已驗證**（有人在真機上看過）／**這輪要驗**／**延後驗證**／**不適用**。
「這輪要驗」全部由**使用者操作手機並回報**；本工作階段無法驅動實體裝置，也不直接安裝（SideStore 政策）。
建議全部在 `0.1.8 (9)` 上做；標 ★ 的在現有 `0.1.7 (8)` 上也能測。

### 7.1 已驗證（先前真機回報，維持不回滾）

| 項目 | 證據 |
|---|---|
| 全新安裝可接受遠端設定並列出來源；CJK 與 emoji 正確；App icon | IOS-POC-8A／8C |
| 搜尋欄與黑帶（8F／8G） | 使用者 iPhone 16 Pro 確認（8H） |
| 麻豆(js)（CatVod JS spider，`wang-sex.json`）列出並播放 | 10V，`0.1.1 (2)` |
| 荐片冷啟動有篩選列 | 10Z，`0.1.1 (2)` |
| **一集播完自動接下一集，最後一集關閉播放器**（IOS-POC-14） | 使用者確認，`0.1.2 (3)` |
| CPython 走完整條鏈到真實媒體位元組；libmpv 初始化 | 9F（Xcode 直裝的 Debug build） |

### 7.2 這輪要驗（使用者操作、回報）

| # | 項目 | 程式路徑 | 建議來源 | 步驟與通過標準 | 回報格式 |
|---|---|---|---|---|---|
| ①a | 5S-3 rules 非回歸 | `SnifferRules.verdict`／`script(for:)`；`MediaSniffer.Collector`（`MediaSniffer.swift:280`、`:322`） | `🥇｜农民｜高清`（XYQHiker）；另找一個已知走嗅探的：`🧲｜優酷｜高清` 的 `ukyun` 線路（5G 在模擬器上走過嗅探）、`🧲｜非凡`、`🧲｜量子` | **只能在 `0.1.8 (9)` 上測**。選集 → 能播且是正片、沒有卡在嗅探逾時（約 12 秒）後失敗 | 每個來源：能播／不能播＋畫面描述 |
| ①b | 5S-3 正向（rule 改變行為、script 被執行） | 同上 | **`wang-movie.json` 內沒有**（見第五節） | 使用者若有會載入 `yeslivetv.com`／`www.maolvys.com` 的來源再測；否則維持 unit-level 證據 | 有／沒有這樣的來源 |
| ②a ★ | 5S-1 ads 非過度封鎖 | `AdBlockList`、`MediaSniffer.contentRules()`（`MediaSniffer.swift:113`） | 同①a 的嗅探來源 | 走嗅探的來源能播；海報、字幕、分類 API 正常 | 同①a |
| ②b | 5S-1 正向（廣告被擋） | 同上 | `wang-movie.json` 唯一 ad host `mozai.4gtv.tv` 無來源會請求 | 無可見訊號（第四節），維持 unit-level 證據；若使用者用 `wang-sex.json`（62 個 host），同樣只看得到非回歸 | — |
| ③ ★ | 5S-2 片頭／片尾 | `WatchHistory.startPosition(resuming:)`、`hasReachedEnding`；`PlaybackSession.markOpening`／`markEnding`（`WebHTVApp.swift:1905`、`:1913`）；取樣器 `:2135` → `finished()` `:2188` | 任一有多集的來源（例：`🏆｜王子` 稀有祖宗） | 在控制列設片頭（設為目前位置／±1 秒／清除）→ 關閉 → 重開同一部片：從片頭後開始。設片尾 → 播到片尾前：**約 5 秒內**跳下一集（既有取樣器誤差，不另開 timer）；最後一集則關閉播放器。換一集仍沿用同一部片的設定 | 起播秒數、片尾觸發時多播了幾秒、有沒有接到下一集 |
| ④ ★ | PiP foreground restore（**至少連續 2 次**） | `PlayerSurface.Coordinator`（`WebHTVApp.swift:2698`，`didBecomeActive` → `allowsPictureInPicturePlayback` false→true `:2735`） | 任一可播來源 | 播放中 → 離開 App（自動進 PiP）→ 回 App：PiP 消失、一般播放器回來；位置、速度、播放／暫停狀態保留；無重複聲音。**重複 2 次以上**；另測一次 PiP 中先暫停再回來 | 每一輪：PiP 是否消失、位置差幾秒、速度、播放/暫停、有無雙聲 |
| ⑤ ★ | IOS-POC-16 控制列逐項 | `PlayerControlBar`（`WebHTVApp.swift:2294`）；速度 `[0.5, 1, 1.25, 1.5, 2, 2.5, 3]`（`:2328`）；`setRate`（`:1873`）；`seek(toSeconds:)`（`:1883`）；AirPlay `AVRoutePickerView`（`:2575`）；字幕／音軌 `MediaSelection`（`:2604`）；自動隱藏 5 秒且暫停時不隱藏（`scheduleHide`，`:2958`） | 同上 | 逐項：**關閉（最高風險，唯一出口）**、播放／暫停、⏪10／⏩10、進度條拖曳（放開才 seek）、已緩衝區段、速度每一檔、**2.5× 與 3× 要有聲音**、片頭／片尾按鈕、AirPlay 選單出現、字幕／音軌（只有來源多於一個選項才出現，沒出現不算失敗）、點畫面叫出／5 秒自動隱藏、暫停時不隱藏 | 每項 ✅／❌＋一句描述 |
| ⑥ | CMS 瀏覽＋播放 | `CMSClient`；`SourceClient` | type-1：`🧲｜360｜高清` 或 `🧲｜如意｜高清(各種廣告)`；type-4：`🏆｜愛瓜｜PHP`（莲花楼，5R 在模擬器走完整條） | 首頁 → 分類 → 分頁 → 搜尋 → 詳情 → 選集 → 內建播放器出畫面 | 各步驟 ✅／❌ |
| ⑦ | 可移植 `csp_*` 播放 | `SpiderSession`／`JavaScriptSpiderRuntime`；`AppGet.js` | `🏆｜王子｜高畫 + 都採集`（`csp_AppGet`，8I／8J 在模擬器走過） | 首頁 → 篩選列 → 詳情 → 選集 → 播放 | 同上 |
| ⑧ | drpy 來源播放 | `DrpyEngine` + `JavaScriptSpiderRuntime` | **遠端設定**下的 `🎡｜去看动漫`、`🎡｜爱动漫`、`🎡｜七色番动漫`（6B 四站都到過媒體位元組） | 同上 | 同上 |
| ⑨ | Bili：`Referer` + 瀏覽器 UA 經 AVPlayer | `PlaybackTarget.headers` → `AVURLAsset(url:options: ["AVURLAssetHTTPHeaderFieldsKey": headers])`（`WebHTVApp.swift:2282`） | `🎖︎｜bilbil合集｜`（`csp_Bili`） | 選集 → 內建播放器**能播**＝headers 在真機生效（bilibili CDN 缺 Referer 或瀏覽器 UA 會回 403，2026-09-18 以 curl 量過）。**這一項同時回答 `AVURLAssetHTTPHeaderFieldsKey` 在真機是否生效**；麻豆的成功不算，因為它沒有 header 也回 200 | 能播／不能播；不能播時錯誤訊息原文 |
| ⑩ | WatchHistory／resume | `WatchHistoryStore`；`PlaybackSession.open`（`WebHTVApp.swift:1808`，`startPosition(resuming:)` `:1846`）；`persist` `:1942` | 任一 CMS 或 `csp_*` 來源 | 播放 > 10 秒 → 關閉 → 記錄分頁出現「看到 m:ss / 總長」→ 從記錄或詳情再開：**從上次位置續播**（>10 秒且不在片尾區才續）；詳情頁標出上一集；線路／集數與記錄一致；看完的片重播從片頭（或 0） | 續播秒數、記錄文字、詳情頁標記 |
| ~~⑪~~ | ~~外部播放器 URL handoff~~ | **Superseded by dual internal-player decision, 2026-09-23**：外部播放器已從產品移除（IOS-POC-17A），不再是驗收項目，見 7.4 | — | — | — |
| ⑫ ★ | auto-next 回歸 smoke | `playNext`（`WebHTVApp.swift:1364`）；`finished()` `:2188` | 多集來源 | 播到結尾 → 自動接下一集；最後一集關閉 | ✅／❌ |
| ⑬ | 既有功能 bounded 回歸 | 開播用記住的或預設畫質（`Playback.start()`，IOS-POC-17C 起選單頁已移除）；速度沿用 `chosenRate` 以 `WatchHistory.key` 為鍵（`:1814`）；PiP 自動進入 `canStartPictureInPictureAutomaticallyFromInline`（`:2681`）；AirPlay | 同上 | 詳情頁線路列可切換；同一部片換集速度沿用、換來源重設（14C 決定）；離開 App 自動進 PiP；AirPlay 可投（若手邊有裝置） | 每項 ✅／❌ |
| ⑭ ★ | IOS-POC-15 最基本 smoke（**不是效能驗收**） | `PlaybackBufferPolicy`、`PlaybackTargetPrefetch` | 任一 | 影片能播、2.5×／3× 有聲（與⑤重疊）、播放一段時間沒有明顯 crash | ✅／❌ |
| ⑮ | 點集數直接播放（17C） | `Playback.start()`；`VodView` 的 `fullScreenCover(item:)` | 任一 | 點集數 → 直接進播放畫面（沒有中間頁）→ 續播位置正確 → X 回到詳情頁 → 再點另一集正常 | ✅／❌ |
| ⑯ | 「預設播放器」設定與控制列標籤（17B／17E） | `PlaybackEnginePreference`；`SettingsView` 的「預設播放器」；`PlayerControlBar.engineMenu` | — | 設定頁有「原生播放器 ✓／MPV」且兩者都能選；選 MPV 後新開的影片從 MPV 開始；控制列顯示實際的播放器；關閉再開回到預設 | ✅／❌ |
| ⑰ | AVPlayer 失敗顯示原因（17B） | `AVPlayerEngine.report`；`PlaybackFailure.classify`；播放畫面的失敗訊息 | 一個已知會 403／404 的來源（若遇到） | 失敗時畫面中央出現「網路錯誤：HTTP 403」一類的訊息，而不是只有黑畫面 | 訊息原文 |
| ⑱ | **MPV 真機 first frame**（9G） | `MPVProbeView`（「範例」三個串流）；`MPVEngine` | Apple 測試串流 | Metal／OpenGL × 軟解／硬解四格：`VIDEO_RECONFIG`＋`PLAYBACK_RESTART` 出現**且有畫面** | 每格：事件序列＋有無畫面 |
| ⑲ | **MPV 真機切換與 fallback**（17B） | `PlayerRouter.select`／`engineFailed`；`MPVRequestHeaders` | 一般來源＋Bili（驗 headers） | 原生 ↔ MPV 切換保留位置／速度／暫停／集數／線路；Bili 在 MPV 能播＝headers 送到；MPV 播不出畫面時 10 秒內自動回原生 | 每項 ✅／❌ |

**⑱⑲ 自 `0.1.8 (9)` 起可直接在正式版測**：使用者 2026-09-23 決定開放 MPV（17E）。⑱ 的四格探針仍是 Debug-only；
在正式版上以「設定 → 預設播放器 → MPV」或播放中的控制列切到 MPV，看有沒有畫面即可。

**建議操作順序**（風險高的先做，任何一項卡住不影響其他項）：⑤關閉鈕 → ④PiP ×2 → ⑤其餘 →
⑮直接播放 → ⑨Bili → ⑥CMS → ⑦csp → ⑧drpy → ⑩resume → ③片頭片尾 → ⑫⑬⑭⑯⑰ → ①a②a →（有 MPV build 時）⑱⑲。

### 7.3 延後驗證（依使用者決定，不是本輪 blocker）

| 項目 | 原因 |
|---|---|
| **IOS-POC-15 完整效能量測**：startup latency、30／60 秒 buffer-ahead、60／90／120 policy 生效、stall／rebuffer、throughput、ABR 降級與恢復、下一集 handoff 耗時 | 使用者 2026-09-23 決定延後自行做。**不是本輪 release blocker**；狀態維持 `device verification pending`，不得寫 closed。另見第四節：SideStore 安裝看不到 `[playback]` log |
| ~~MPV rendering~~ | **Superseded 2026-09-23**：使用者決定保留 MPV 為第二內部核心（沒有 keep/drop decision 了）；黑畫面根因已找到並修正，模擬器 Metal／OpenGL 都出畫面（IOS-POC-9G）。真機驗證改為 ⑱⑲ |
| 片尾與 PiP 同時發生、真實 WebHome 頁讀帶值的 `app.history.opening/ending`、舊手機既有 history 升級後仍在 | 5S-2 記錄的殘留缺口，不在本輪 14 項內；有機會順手看，不強制 |
| 鎖定畫面／控制中心 now-playing | IOS-POC-16 風險 4，非核心 |

### 7.4 不適用（這一輪、這份設定檔）

| 項目 | 原因 |
|---|---|
| ①b／②b 的**正向**真機觀察 | 第五節：`wang-movie.json` 沒有會碰到 `script` rule host 或 ad host 的來源；嗅探 WebView 不可見且無 log 管道 |
| WebHome 頁面對照「不受 rules 影響」 | `wang-movie.json` 沒有 WebHome site；結構事實見第五節 |
| 手動 PiP 按鈕 | 使用者決定不畫（IOS-POC-16 §八） |
| 外部播放器（Infuse／Fileball／SenPlayer／VidHub） | **Superseded by dual internal-player decision, 2026-09-23**：已從產品移除（IOS-POC-17A） |
| MPV 的 PiP／AirPlay／字幕音軌選單 | MPV 第一階段不提供（capability 關閉），第二階段才補 |
| Python `Crypto`／`lxml`／`pyquery`／`bs4` 那 24 站、未移植的 23 個 `csp_*`、被 native 加密保護的 34 站 | backlog，不在核心驗收範圍 |

## 八、凍結核心 playback／runtime contract 需要的最小集合

IOS-POC-12 要凍結的是 `ConfigSource`、`SourceClient`、`PlaybackTarget`、`PlaybackSession`、
spider/resolver 邊界、`WatchHistory`、WebHome bridge ABI，**以及 IOS-POC-17 的 engine 邊界**
（`PlaybackEngine`、`PlayerRouter`、`PlaybackEngineSelection`、`PlaybackFailure`）。**足以凍結**的最小證據是
7.2 裡 ④⑤（播放器外殼與唯一出口）、⑥⑦⑧（三種解析路徑）、⑨（headers → AVPlayer）、⑩（history）
全部 ✅，且 ①a②a③⑫⑮ 沒有回歸，**加上 ⑱⑲（MPV 真機 first frame 與切換）**——MPV 已確定保留，
它的真機證據是凍結 engine 邊界的前提。①b②b 與 7.3 不在凍結門檻內。之後進 IOS-POC-12、IOS-POC-13。

## 九、回滾

本文件是 docs-only，`git revert` 即可，不影響任何 build。

## Recovery anchor

- 目標：核心真機驗收準備（矩陣＋RC 計畫），不是新功能。
- 已完成：Git 核對（HEAD＝origin＝`f0495b8b`、`0 0`、clean）；`0.1.7 (8)`＝`add58007` 不含
  `63040bb3` 的證明；`wang-movie.json` rules／ads 盤點（第五節）；`0.1.8 (9)` iphoneos Release
  預建置成功；本矩陣。
- 未完成：7.2 全部真機結果（**等使用者回報**；⑪ 已 superseded，⑮–⑲ 為 IOS-POC-17 新增）；
  `0.1.8 (9)` 的發布（**等使用者授權**；IOS-POC-17 之後要先重跑一次 iphoneos Release 預建置）；
  ⑱⑲ 需要能開 MPV 的 device build（使用者決定走 IPA 或開發者開關）。
- 下一個動作（唯一）：使用者授權發布 `0.1.8 (9)` 後，依第三節四步發布；或使用者直接在
  `0.1.7 (8)` 上先回報 ★ 項目。收到回報後把結果逐列填進 7.2，並把通過的列移到 7.1。
