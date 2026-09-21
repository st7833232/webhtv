# IOS-POC-7A — Python runtime 最小可行性評估（使用者 roadmap 的 POC-4）

- 狀態：**已核可（A）**。**P1 量測完成**（見文末），P2–P5 未開始。尚未改任何 production 程式碼。
- 分支 `ios-poc`，基線 HEAD `a80cde63`
- 日期：2026-09-18
- 需要你決定的只有一件事：見「待你決定」

## 量到的事實（不是推論）

2026-09-18 從使用者自己的 GitLab 抓下 **31 支設定檔相對路徑的 `.py`**（共 560 KB）逐一分析。

### 42 站、35 支腳本，但只有 31 支在同源

| 位置 | 支數 | 處置 |
|---|---:|---|
| `./py/*.py`（設定檔同源） | 31 | 可用 |
| `http://itv666.cc/...`（2 支）、`https://git.yylx.win/...`（1 支） | 3 | **跨 origin 且其中兩支是明文 HTTP**。依 IOS-POC-6B 對 drpy 立下的同源＋HTTPS 規則，這三站要拒絕 |

### 相依分布

| 模組 | 幾支用到 | 性質 |
|---|---:|---|
| `base` | 30 | **宿主提供**，見下 |
| `requests` | 23 | **純 Python**（+ urllib3 / certifi / idna / charset_normalizer，全部有純 Python 路徑） |
| `Crypto`（pycryptodome） | 10 | **C 擴充** |
| `bs4` | 5 | 純 Python（可用 stdlib `html.parser`，不必然要 lxml） |
| `pyquery` | 4 | **C 擴充**（相依 lxml） |
| `lxml` | 3 | **C 擴充**（libxml2） |
| `urllib3` | 3 | 純 Python |

標準庫用到的：`re json sys os time base64 hashlib hmac urllib random uuid threading html datetime
mimetypes math socket ssl secrets ipaddress logging concurrent http binascii`。**全部是一般 CPython
build 就有的東西**，沒有任何需要特別開關的模組。

### 沒有任何 Android 相依

先前紀錄寫「38 支裡只有 1 支碰 `android.`」。這次逐一檢查那 5 支含 "android" 字樣的檔案，
**五處全是 User-Agent 字串或 `platform=android` 查詢參數**，沒有一處是 Android API。
本批 31 支的 Android 相依是 **0**。

### `base` 是什麼：repo 裡就有

`chaquo/src/main/python/base/spider.py`（149 行，Android 側，唯讀供比對）。它不只是抽象基底類別：

- 13 個 ABI 方法（與 `Spider.java`、與我們的 `SpiderRuntime` 一致）
- `fetch()` / `post()` — **薄薄包一層 `requests`**，回傳 `requests.Response`
- `html()` — `lxml.etree.HTML`
- `regStr` / `removeHtmlTags` / `cleanText` / `str2json` / `json2str` / `log` — 純 Python
- `getProxyUrl()` — `com.github.catvod.Proxy`，**Android 專屬**
- `loadSpider` / `loadModule` — `SourceFileLoader`

**這解釋了為什麼有 4 支腳本「零第三方相依」**：它們的 HTTP 全部走 `self.fetch()`，相依藏在 `base`
裡。所以 `base` 的實作方式，直接決定最小 POC 要不要帶 `requests`。

### 依相依重量排序（每一支都要 `base`）

| 相依 | 支數 | 例子 |
|---|---:|---|
| 無（只要 `base` + 標準庫） | 4 | `皮皮虾.py` 7.4 KB、`蛋挞TV.py`、`耐看点播.py`、`樱花动漫🔞.py` |
| 只要 `requests` | 6 | `茶杯狐.py` 6.9 KB、`麒麟影视.py`、`七猫影视.py`、`西瓜卡通.py`、`大众.py`、`悟空影视.py` |
| 需要 C 擴充（`Crypto` / `lxml` / `pyquery`） | **15** | — |
| 其他（`bs4`、`urllib3` 等純 Python） | 6 | — |

**所以最小 POC 可以完全不碰任何 C 擴充。**

## 嵌入方案

### CPython 官方自 3.13 起支援 iOS

PEP 730 把 iOS 納入 CPython 的正式支援層級（tier 3），自 **3.13** 起。這不是第三方 fork，是上游。
可用的取得方式：

| 方案 | 說明 | 評價 |
|---|---|---|
| **Python-Apple-support（BeeWare）** | 官方 iOS 支援的預編譯 XCFramework，含 device + simulator slice，隨 CPython 版本發佈 | **建議**。不用自己 cross-compile，與上游同步 |
| 自行依 PEP 730 交叉編譯 | 完全可控 | 成本高，POC 不需要 |
| kivy-ios | 較舊的路線 | 不建議，與上游脫節 |

**證據等級聲明**：以上關於 PEP 730 與 Python-Apple-support 的描述來自我的既有知識，**這一輪沒有
連網核對上游文件**。核可後的第一件事就是實際下載並核對版本、大小與 slice，再動任何程式碼——
與 drpy 那一輪「先量再說」的做法一致。

### iOS 的三個硬限制，以及它們為什麼不擋路

1. **不能 JIT／不能有可寫又可執行的記憶體。** CPython 是直譯器，不需要 JIT。不擋路。
2. **每個 C 擴充在 iOS 上必須包成自己的 `.framework`**（PEP 730 的規定）。這正是為什麼
   `Crypto`／`lxml` 貴，而**最小 POC 刻意不碰它們**。
3. **二進位大小**：CPython + 標準庫大約十幾 MB。這是要你知道的成本，不是技術阻礙。

使用者已明確指示：**不要因為 App Store 分發風險就否定 Personal/SideStore runtime**。本計畫照辦，
且**不**在本階段實作 Official/XPTV build profile。

## 設計

### 沿用既有路由，不新增第三套東西

drpy 那一輪已經證明形狀可行：`Site.isDrpySpider` → `CSPSourceResolver` → 既有 runtime。
Python 同理：

```
Site.isPythonSpider  (type == 3 && api 以 .py 結尾)
  → CSPSourceResolver.session(for:)   (已經是 async)
  → PythonSpiderRuntime : SpiderRuntime   ← 唯一的新 runtime，因為 JavaScriptCore 跑不了 Python
  → CatVod JSON → SourceClient → 既有 UI
```

**這裡確實需要一個新的 runtime 型別**，而那不違反「不要做第二套 JavaScript runtime」——那條規則
講的是 JavaScript。`SpiderRuntime` 這個 protocol 就是為了讓這件事不痛才存在的。

### `base` 的實作：iOS 版 shim

寫一份 `base/spider.py` 放進 App bundle，對照 Android 那份逐項實作：

| 成員 | iOS 作法 |
|---|---|
| 13 個 ABI 方法 | 照抄（抽象） |
| `fetch` / `post` | **Tier 1 決策點**，見下 |
| `html()` | 先不實作；呼叫到就拋出具名錯誤（fail closed）。需要它的腳本本來就在 lxml 那一層 |
| `regStr`/`removeHtmlTags`/`cleanText`/`str2json`/`json2str`/`log` | 純 Python，照抄 |
| `getProxyUrl` | 沒有本機 proxy server，回傳空字串並註記——與 WebHome bridge 既有的偏離處理一致 |
| `loadSpider`/`loadModule` | 先不實作 |

**`fetch`/`post` 的兩條路**：

- **(a) 帶 `requests` 進來**（純 Python，約 1.5 MB 原始碼）。照抄 Android 的實作，
  `requests.Response` 的語意完全一致，23 支腳本直接受惠。
- **(b) 用 `CatVodHost` 的 HTTP**，另外做一個 `Response` 相容物件。cookie jar、逾時、header
  與其他 spider 完全一致，但要維護一個假的 `Response`。

**建議 (a)**：腳本讀 `.json()`、`.text`、`.content`、`.encoding`、`.headers`、`.cookies`，
自己做一個相容物件是明確的重造輪子，而 `requests` 純 Python、不用交叉編譯。
(b) 留作升級路徑，若日後需要統一 cookie 行為再說。

### 切片

| 切片 | 內容 | 驗證 |
|---|---|---|
| **P1** | 取得並核對 Python-Apple-support：版本、slice、大小。**只量，不接線** | 記錄實際數字進本文件 |
| **P2** | `PythonSpiderRuntime`（`SpiderRuntime` 的實作）+ iOS 版 `base/spider.py` shim + `requests` | 單元測試：用一支寫死的假 Spider 腳本走完 13 個方法 |
| **P3** | 路由：`Site.isPythonSpider`、resolver 分支、同源＋HTTPS＋大小上限（照 `DrpyEngine` 的規則） | 單元測試：跨 origin 與明文 HTTP 的 3 站被拒絕 |
| **P4** | **一支真腳本 end-to-end golden**：`皮皮虾.py`（7.4 KB，零第三方相依），`home → category → detail → search → player`，最後要取得媒體位元組 | live golden，與 drpy 同形狀 |
| **P5** | 量出 Tier 1 實際覆蓋幾支，寫進文件。**不在本階段擴到 Crypto/lxml** | 逐站清單 |

### 之後的層級（不在本 POC）

- **`Crypto`（10 支）**：`CatVodHost` 已經有 AES／DES／MD5／SHA／HMAC。做一個 `Crypto.Cipher` 的
  薄 shim 轉呼叫它，可能比交叉編譯 pycryptodome 便宜得多。**這是下一階段最高 CP 值的一步。**
- **`lxml`／`pyquery`（最多 7 支）**：要交叉編譯 libxml2 並包成 framework。最貴，留到最後。
- **3 支跨 origin 腳本**：維持拒絕。

## 待你決定

**要不要把 CPython 嵌進這個 App？**

這是二進位與封裝層級的改變（約十幾 MB），AGENTS.md §7 要求先經你核可：

- **好處**：42 站裡的 31 支同源腳本進入射程；最小 POC 完全不需要任何 C 擴充；Android 相依是 0。
- **成本**：App 體積 +十幾 MB；多一個要跟上游版本的相依；C 擴充那一層（15 支）之後還要各自包
  framework。
- **邊界不變**：不執行 Android DEX/JAR；同源＋HTTPS＋大小上限照 drpy 那一套；沙箱不擴大。

**我的建議：做，而且照 P1→P5 一路只做到「零 C 擴充」為止。** 理由是那 4 支零相依腳本讓可行性
可以用極小的代價證明，而 Crypto／lxml 那兩層各自是獨立決策，不該綁在可行性驗證裡。

其他選項：**B** 只做 P1（量出版本與大小就停，不接線）；**C** 不做 Python，回頭處理真機驗證。

## 驗收條件

| # | 條件 | 怎麼驗 |
|---|---|---|
| H1 | CPython 在 iOS Simulator 上跑得起來並回得了字串 | P2 單元測試 |
| H2 | 一支寫死的假 Spider 走完 13 個方法 | P2 單元測試 |
| H3 | 跨 origin／明文 HTTP 的腳本被拒絕 | P3 單元測試 |
| H4 | `皮皮虾.py` 走完 `home → category → detail → search → player` 並取得媒體位元組 | P4 live golden |
| H5 | 既有 62 站與全部測試無退步 | `swift test` 全綠 + `xcodebuild` |
| H6 | 腳本抓取失敗、逾時、語法錯誤、缺 `base` 成員時全部 fail closed | P2/P3 單元測試 |

## 回滾

未 commit 直接 `git restore`；已 commit 未 push 用 `git revert`。Python runtime 是新增路徑，
既有 62 站一行都不動——最壞情況是 Python 站不可用，其餘不受影響。

## 風險

| # | 風險 | 對策 |
|---|---|---|
| Q1 | App 體積 +十幾 MB | 已列為你要決定的成本。Personal/SideStore 路線不受 App Store 體積政策約束 |
| Q2 | Python-Apple-support 的實際版本／slice 與我記憶中不同 | **P1 就是去量它**，量完才接線 |
| Q3 | `requests` 的純 Python 相依鏈有隱藏的 C 需求 | P2 會在實機前先在 Simulator 驗；真有就退回 (b) 方案用 `CatVodHost` |
| Q4 | 腳本用到 `html()`（lxml）才發現 | 呼叫時拋具名錯誤，該站 fail closed，不影響其他站 |
| Q5 | 31 支腳本裡有未預期的 C 相依 | P5 的逐站量測會抓出來；本 POC 的成功條件只綁在一支 |
| Q6 | CPython 啟動時間拖慢開站 | 與 drpy 的引擎一樣做 per-process 快取；量測後再談 |

## Ponytail（評估階段）

① 需要存在——使用者 roadmap 的 POC-4。② 已有的東西先用——路由、`SourceClient`、`SpiderSession`、
`SpiderRuntime` protocol、同源／HTTPS／大小上限規則全部沿用 drpy 那一輪；`base` 的契約直接抄
repo 裡現成的 Android 版。③ 標準庫——最小 POC 的 4 支腳本只要 CPython 標準庫。⑤ `requests` 用
現成純 Python 套件，不自己刻 `Response`。⑦ 最小可行：一個新 runtime 型別（因為 JavaScriptCore
跑不了 Python，這是不可避免的）、一份 `base` shim、一條 routing 分支。

刻意不做：`Crypto` 與 `lxml` 的 C 擴充、`html()`、`loadSpider`、本機 proxy server、
跨 origin 腳本、Official/XPTV build profile。


---

# P1 量測結果（2026-09-18）

實際下載 `Python-Apple-support 3.13-b15`（`Python-3.13-iOS-support.b15.tar.gz`，31 MB）並拆開量。
**兩個數字推翻了計畫裡的估計，照實更正。**

## 版本與 slice

| | |
|---|---|
| 來源 | `github.com/beeware/Python-Apple-support`，release `3.13-b15`（2026-09-04） |
| 選 3.13 的理由 | PEP 730 讓 iOS 成為 CPython 正式支援平台**自 3.13 起**。3.14/3.15 也有 iOS 建置，但 3.13 是第一個正式支援版，也最成熟 |
| slice | `ios-arm64`（實機）、`ios-arm64_x86_64-simulator`（模擬器）。**沒有 macOS slice** |
| 解壓後總計 | 116 MB（含兩個 slice、共用 stdlib 與建置腳本） |

## 實際要塞進 App 的東西

| 成分 | 大小 | 說明 |
|---|---:|---|
| `Python.framework/Python`（直譯器） | **5.2 MB** | 實機 slice |
| `lib-dynload/*.so` — 全部 68 個 | 15 MB | 每個在 iOS 上要各自包成 framework（PEP 730） |
| `lib-dynload/*.so` — **這 31 支腳本用得到的** | **約 9 MB** | `_ssl`／`_hashlib`／`_socket`／`_json`／`zlib`／`_decimal`／`unicodedata` 等 |
| 純 Python 標準庫（架構無關） | 50 MB **原始** | 其中 **35 MB 是 `test/`**；再扣掉 `idlelib` 1.9M、`ensurepip` 1.8M、`tkinter`、`pydoc_data` 後約剩 10–12 MB |

**修正計畫裡的估計**：先前寫「約十幾 MB」。實際精簡後大約
**5.2 + 9 + 10～12 ≈ 24 MB（未壓縮）**，App 瘦身與壓縮後會再小一些。**大約是原估計的兩倍**，
這是你當初核可時應該拿到的數字，所以在這裡更正。

**好消息**：`_ssl`、`_hashlib`、`_socket` 都是現成的預編譯 `.so`，所以
**標準庫的 HTTPS 開箱即用**，`urllib.request` 與 `requests` 都不用額外處理憑證以外的事。

## 一個會改變 P2 形狀的結構性發現

**這個 XCFramework 沒有 macOS slice，而 `swift test --package-path ios` 是在 macOS 上跑的**
（測試輸出寫著 `Target Platform: arm64e-apple-macos14.0`）。

也就是說 **現有的 143 條測試無法執行 Python runtime**。這不是問題，是事實，但它決定了 P2–P4 怎麼驗：

- **平台中立的部分**（路由、同源／HTTPS 檢查、大小上限、腳本抓取）留在 `WebHTVCore`，
  照舊用 `swift test` 在 macOS 上測——與 `DrpyEngine` 的做法一致。
- **真正跑直譯器的部分**（P4 的 `皮皮虾.py` 端到端 golden）**只能在模擬器上跑**，
  需要在 Xcode 專案裡新增一個 iOS 測試 target，或以驅動 App UI 的方式取證。
  這是 P2 之前要先決定的一件事，本文件先標記，不自行決定。

## P1 之後的狀態

- P1 **完成**。
- P2–P5 未開始。P2 會動到 Xcode 專案檔（加入 XCFramework），而那個檔案本輪已被 Xcode 自動改寫過
  兩次，要留意。

---

## IOS-POC-7E — P2a：payload 管線（2026-09-21）

P2 的第一段：**讓 CPython payload 有一個固定、可重現的位置**，還沒有任何 Swift 程式碼。

### 打包方式的決定：抓取，不提交

使用者在 2026-09-21 從兩個選項中選了 fetch 腳本。判斷依據是這個 repo 裡**兩種先例性質不同**：

| 先例 | 性質 | 為什麼那樣做 |
|---|---|---|
| `app/src/arm64_v8a/assets/mpv-libs/*.so`（43 MB，tracked） | 從 fork `FongMi/mpv-android` 某個 commit **自己編出來的** | 別處拿不到，提交是唯一能重現的方式 |
| `third_party/sources/`（gitignored） | 外部取得的來源 | 可重抓 |
| **Python-Apple-support** | **官方 release asset** | 可重抓，且已證實不可變 |

證據不是推論：`Python-3.13-iOS-support.b15.tar.gz` 在 **2026-09-18 與 2026-09-21 各下載一次，
sha256 完全相同**（`80175765…c5d1`，32,566,713 bytes）。為一個上游已不可變的東西在 git history
永久加 30 MB，換不到任何重現性；而且方向可逆 —— 日後要改成提交隨時可以，反過來得改寫歷史。

### 交付物

| 檔案 | 作用 |
|---|---|
| `third_party/python-ios-lock.json` | 唯一真相：版本、URL、sha256、bytes、bundled libraries、授權、要精簡掉的路徑 |
| `scripts/fetch_python_ios.sh` | 下載 → 驗 size + sha256 → 解壓 → 精簡 → 蓋 stamp。**fail closed**，且 idempotent |
| `.gitignore` | `third_party/python-ios/` |

### 量到的事

| | |
|---|---|
| 下載 | 31.0 MB，sha256 驗過 |
| 解壓精簡後 | **77 MB**（磁碟，未 tracked） |
| 共用標準庫 | 50 MB → **10 MB**（砍掉 `test` 35 MB、`idlelib`、`ensurepip`、`tkinter`、`pydoc_data`） |
| `lib-dynload` | 每個 arch 14 MB，**故意不砍** |
| framework 二進位 | device 5.2 MB、simulator 10.5 MB（fat） |
| slice | `ios-arm64`、`ios-arm64_x86_64-simulator` |

`ponytail:` 不砍 `lib-dynload` 是刻意的 —— 砍掉哪個 `.so` 就會在某支腳本 import 它的時候變成執行期
ImportError，而 payload 本來就不進 repo，磁碟很便宜。等到真的在量 App 體積時再回來。

### 驗證

- `./scripts/fetch_python_ios.sh` → 下載、`verified sha256 80175765…c5d1`、`ready … (77M)`
- 再跑一次 → `already present`，沒有重抓
- `git status --porcelain` → 只看得到 `.gitignore`、腳本、lock 三個檔，**payload 完全不可見**
- 解壓結果有 device slice、simulator slice、標準庫三項斷言，缺一即 fail

### 尚未開始

`PythonSpiderRuntime`、`base/spider.py` shim、Xcode 專案連結、P3 routing、P4 端到端、P5 覆蓋量測。
