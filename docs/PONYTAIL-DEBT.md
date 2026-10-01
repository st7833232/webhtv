# Ponytail 技術債清單

- 掃描：2026-10-01，`ios-poc` `7b15fb74`，`ponytail:ponytail-debt`。
- 範圍：程式與腳本裡的 `ponytail:` 註記（`ios/Sources`、`ios/WebHTVApp/Sources`、`ios/WebHTVApp/Python`、`scripts`）；不含 `docs/`、`.codex/` 的 patch 與紀錄、`ios/Vendor`，也不含 `AGENTS.md` 裡說明慣例的文字。
- 慣例：`ponytail: <上限>, <升級路徑>`（全域 `CLAUDE.md`：刻意的簡化或暫時方案要寫明限制與升級路徑）。
- 結果：**27 處，7 處沒寫升級條件（`no-trigger`）**，其中 3 處是刻意的取捨、4 處有被遺忘的風險；另有 1 處升級條件已經達成、註解過時。
- 這份清單只記錄現況，沒有改任何程式。重新產生：再跑一次 `ponytail:ponytail-debt`，或 `grep -rn 'ponytail:' ios/Sources ios/WebHTVApp/Sources ios/WebHTVApp/Python scripts`。行號以掃描當時為準。

## 需要處理的

| 項目 | 狀態 | 建議 |
|---|---|---|
| `ios/WebHTVApp/Python/base/spider.py:26` | **升級條件已經達成**：IOS-POC-7P 已經打包真正的 `requests`（`scripts/fetch_python_ios.sh:103-130`），`spider.py:73` 會優先 import 它，`_Response` 只剩找不到 `requests` 時的備援 | 改寫註解，說明它現在是備援 |
| `ios/Sources/WebHTVCore/Resources/Spiders/XBPQ.js:383` | `no-trigger` | 補上「有設定的站用 XPath 寫分類時」 |
| `ios/Sources/WebHTVCore/Resources/Spiders/XBPQ.js:603` | `no-trigger`；`搜索模式` 由 IOS-POC-39 S5 第 3 項追蹤，等使用者決定 | 補上觸發條件，或指向 IOS-POC-39 |
| `ios/WebHTVApp/Sources/MPVEngine.swift:441` | `no-trigger`；實際上是等實機量測 | 補上「實機量過 `hwdec` 之後」 |
| `ios/WebHTVApp/Sources/MPVEngine.swift:1070` | `no-trigger` | 補上「子母畫面狀態晚 0.5 秒有可見問題時，改用引擎事件」 |

## 全部註記

### ios/Sources/WebHTVCore/

| 位置 | 簡化了什麼 | 上限 | 升級條件 |
|---|---|---|---|
| `CMSClient.swift:428` | 用網址副檔名猜媒體類型 | 沒副檔名或副檔名錯的網址會猜錯 | 有真實站台需要時才去探 content type |
| `MediaSniffer.swift:115` | 編譯過的廣告規則清單一直留在 `WKContentRuleListStore` | 每換一組不同的 `ads` 設定就多一筆，每筆約幾 KB | 使用者累積的設定多到有影響時，清掉 `webhtv-ads-` 開頭的項目 |
| `PlayerChrome.swift:80` | 面板位置假設畫面是 16:9 | 4:3、2.39:1、直式影片會放錯位置 | 位置錯到有影響時改讀 `presentationSize` |
| `PlayURL.swift:108` | 只解析預設的那一條網址 | 畫質選單裡其他網址沒有經過解析 | 真的出現多網址來源、而且非預設那條需要解析時，經 `SourceClient` 解析 |
| `PlayURL.swift:181` | 用網站自填的文字猜畫質高低 | 沒見過的寫法會排錯 | 有來源排錯時把它的寫法加進清單，不要寫成解析器 |
| `SourceClient.swift:105` | 換畫質直接開來源給的網址，不探測、不嗅探 | 非預設畫質沒有經過解析 | 有多網址來源需要時再延後解析（掃描時 62 個來源都沒有回網址陣列） |
| `Spider/DrpyEngine.swift:164` | 只把這幾個檔案實際用到的 import 寫法改寫掉，不是 ES module loader | 其他模組寫法不支援 | 沒改寫到的會讓 JS 引擎報 SyntaxError、該站直接失敗，這本身就是警報 |
| `WatchHistory.swift:184` | 觀看記錄用片名對應，與 Android 相同 | 同一條線上同名的兩集共用同一個位置 | `no-trigger`（刻意的取捨：改用網址對應，網址會變的站反而記不住位置） |
| `Resources/Spiders/XBPQ.js:71` | 部分規則語法沒移植（數字切片 `3&&-2`、`$$`、`整页`、`url:`、含序號、Base64／urlDecode） | 用到這些語法的站解析失敗 | 有設定的站用到時（註解沒明寫，是推斷） |
| `Resources/Spiders/XBPQ.js:220` | 只解碼 `%xx`，不像 Java 的 URLDecoder 把 `+` 轉成空白 | 用 `+` 代表空白的值會留著 `+` | `no-trigger`（刻意的取捨：轉了會弄壞有簽章的串流網址） |
| `Resources/Spiders/XBPQ.js:290` | 原版的自動集數規則沒移植 | 沒設 `播放数组` 的站只讀蘋果 CMS 樣板 | 有設定的站需要時（註解沒明寫，是推斷；IOS-POC-39 第 6.3 節） |
| `Resources/Spiders/XBPQ.js:383` | `//` 開頭的分類規則（XPath）和自動猜測都沒移植 | 用 XPath 寫分類的站拿不到分類 | `no-trigger` |
| `Resources/Spiders/XBPQ.js:513` | `//` 開頭的陣列規則（XPath）沒移植 | 這類站片單是空的 | 有設定的站用到時（註解沒明寫，是推斷） |
| `Resources/Spiders/XBPQ.js:603` | 搜尋的部分功能沒移植（`搜索模式`、`搜索前`＋`搜索后缀`、POST、沒有搜尋網址時用片名過濾首頁） | 這類站搜不到 | `no-trigger`（`搜索模式` 由 IOS-POC-39 S5 第 3 項追蹤） |

### ios/WebHTVApp/Sources/

| 位置 | 簡化了什麼 | 上限 | 升級條件 |
|---|---|---|---|
| `MPVEngine.swift:441` | 實機上 `hwdec=auto-safe` 的效果沒量過 | 不知道實機硬體解碼的實際表現 | `no-trigger`（實際上就是等實機量測） |
| `MPVEngine.swift:786` | 子母畫面的軟體輸出寬度固定上限 1280 px | 所有裝置用同一個 CPU 上限 | MPV parity P1 量過各裝置之後 |
| `MPVEngine.swift:1016` | 進出子母畫面都要重建 mpv 的影像輸出 | 進去和回來各會短暫卡一下 | libmpv 在 iOS 有能同時畫 App 內和背景的輸出時 |
| `MPVEngine.swift:1038` | 回前景後固定等 300 ms 才決定要不要自己結束子母畫面 | 猜錯 iOS 的事件順序會閃一下或晚結束 | 用實機的 `[pip]` log 量出真正的間隔再定這個值 |
| `MPVEngine.swift:1070` | 每 0.5 秒輪詢一次引擎狀態，同步給子母畫面 | 子母畫面的狀態最多晚 0.5 秒 | `no-trigger` |
| `PythonBoot.swift:91` | 用環境變數 `PYTHONHOME` 而不是 `PyConfig` 設定 Python | 沒有隔離設定，也不能控制 argv | 真的需要隔離或 argv 時改用 `PyConfig_InitIsolatedConfig` |
| `WebHTVApp.swift:2816` | 觀看記錄每 5 秒整個檔案重寫一次 | 記錄到幾百筆以內沒問題 | 檔案大到有影響時，改成合併寫入，或只在暫停／進背景時寫 |
| `WebHTVApp.swift:3054` | 片尾偵測靠每 5 秒一次的取樣 | 片尾最多會多播 5 秒才跳 | 這點延遲值得處理時，改用每秒的 time observer 或 `forwardPlaybackEndTime` |
| `WebHTVApp.swift:3430` | 每 0.1 秒輪詢「開始播放了沒」（只用來記 log 與開播監看） | 時間點粗；MPV 可能比第一格畫面早一點報「播放中」 | 太粗時改用引擎的「開始播放」回呼 |
| `WebHTVApp.swift:4549` | 進度條沒有刻度、章節標記、震動回饋 | 就是少這些 | `no-trigger`（刻意不做：這些是額外功能，不是缺漏） |
| `WebHTVApp.swift:5409` | 模擬器字型不齊的暫時處理 | 只是顯示問題 | 模擬器內建完整字型的那天刪掉 |

### ios/WebHTVApp/Python/base/

| 位置 | 簡化了什麼 | 上限 | 升級條件 |
|---|---|---|---|
| `spider.py:26` | 用 urllib 寫的 `requests` 替身（`_Response`） | 原本是 31 個腳本裡 23 個要真正的 `requests` | 把真正的 `requests` 放上 `sys.path`——**已經達成**（IOS-POC-7P），註解過時 |
| `spider.py:187` | Python 腳本的快取不跟 JS 腳本的 `SpiderStorage` 共用 | 兩邊的狀態不同步 | 兩邊需要互相對得上時，做 Swift 到 Python 的橋接 |
