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

## IOS-POC-7F — P2b：直譯器在 App 裡起得來（2026-09-21）

P2 的第二段，也是整個 Python 階段風險最高的一段：**CPython 到底能不能在這個 App 內初始化**。
這個問題沒有任何 macOS 測試能回答，因為 XCFramework 沒有 macOS slice。

### 結果

```
[python] boot running(version: "3.13.15")
```

在 iPhone 17 Pro 模擬器上的 WebHTVApp 內取得。**同時 `swift test` 的 143 條仍全過**——這證實了
本階段最重要的架構約束成立：Python 只進 App target，`WebHTVCore` 在 macOS 上照常建置與測試。

### 架構決定：Python 只能住在 App target

| | 為什麼 |
|---|---|
| `PythonBoot` 放 App target | XCFramework 只有 iOS slice；`WebHTVCore` 必須在 macOS 上跑那 143 條測試 |
| 不放進 SwiftPM package | binaryTarget 會讓 macOS 解析失敗，整套測試就沒了 |
| 之後 `PythonSpiderRuntime` 也在 App target | 它要 `import Python`；core 只留最小 seam 讓既有 routing 接得上 |

### 三個實際踩到的坑（都不是猜的）

1. **`import Python` 解析不到。** 上游把 module map 放在 `Python.framework/Headers/`，但 clang 找的是
   `Modules/`。加了一個在 `Sources` **之前**執行的 `Prepare Python` phase 補上。
2. **補上之後仍失敗**：upstream 那份是 plain module，放進 framework 必須宣告 `framework module`，
   否則 clang 去錯的地方找 umbrella header。Prepare phase 改成 `sed` 轉寫而不是直接複製。
3. **`install_python` 路徑重複串接**：它的參數是**相對於 `$PROJECT_DIR`**（上游註解寫明），我原本傳
   絕對路徑。同時上游也明講這一步要在 **framework embedding 之前**跑，phase 順序照改。

最終 phase 順序：`Prepare Python → Sources → Frameworks → Resources → Install Python → Embed Frameworks`。

### 驗證方式，以及它為什麼可信

Python 自己的 stdout **不會**進到 `simctl launch --console-pty` 抓得到的 console，所以證據是回傳碼：

- 正向：`import sys, json, re` 外加一個 `assert`，讓標準庫真的做事而不只是 resolve → 回傳 0
- **負向對照**：`raise RuntimeError(...)` → 必須回傳非 0

沒有負向對照的話，一個什麼都沒執行的 `PyRun_SimpleString` 看起來會跟成功一模一樣，整個檢查就沒有意義。
能走到 `.running` 代表兩者都如預期。

`ponytail:` 用 `PYTHONHOME` 環境變數而不是 `PyConfig_InitIsolatedConfig`——後者的 `PyStatus` 在 Swift
裡不好橋接，而兩者回答同一個問題。等到真的需要 isolation 或 argv 再換。

`ponytail:` `Prepare Python` 每次建置都改寫 `third_party/python-ios/` 底下的 module map。冪等、untracked、
理由寫在腳本裡，但更正確的家是 `scripts/fetch_python_ios.sh`；下次動那支腳本時搬過去。

### 尚未開始

`base/spider.py` shim、`PythonSpiderRuntime`、P3 routing 與安全邊界、P4 端到端、P5 覆蓋量測。

## IOS-POC-7G — P2 完成：`base/spider.py` shim 與 `PythonSpiderRuntime`（2026-09-21）

### 結果

```
[python] boot running(version: "3.13.15")
[python] selfcheck 13/13 methods OK, errors propagate
```

一支寫死的假 spider **以文字形式送進去**（跟真腳本從 HTTP 來的形式相同），13 個方法全部走通。
`swift test` 的 143 條仍全過。

### 橋接設計：全部用字串過，Swift 不碰 `PyObject` 容器

`SpiderRuntime` 本來就是 text in / text out，所以橋接只有**一個** Swift 函式：
`webhtv_runtime.<fn>(str, str, ...) -> str`。參數在 Swift 端編成 JSON 陣列，回傳是一個信封
`{"ok": bool, "value"|"error"}`。

好處是 dict→JSON 的轉換留在 Python（本來就是它的資料），Swift 端沒有任何 PyObject 型別判斷或
生命週期管理——只有一個 tuple 與一個結果的 refcount。

**CatVod 的 Python spider 回傳 dict 而不是 JSON 字串**（Java 與 JS 版都是字串），這個差異由
`webhtv_runtime.invoke` 吸收：`None`→空字串、`str` 原樣、`bool`→`"true"`/`"false"`、其餘 `json.dumps`。

### `base/spider.py`：實作了什麼、沒實作什麼

依據是**實際數過的呼叫次數**，不是猜測：`fetch` 47、`post` 20、`log` 16、`getCache` 5、`setCache` 3、
`getProxyUrl` 3。

| 成員 | 處置 |
|---|---|
| `fetch` / `post` | **stdlib `urllib.request`** + 一個 `requests.Response` 相容物件（`.text`/`.json()`/`.content`/`.status_code`/`.headers`） |
| `log` | print |
| `getCache` / `setCache` | 每站一個 JSON 檔 |
| `getProxyUrl` | 回空字串（iOS 沒有本機 proxy server，專案已排除） |
| `regStr`/`removeHtmlTags`/`cleanText`/`str2json`/`json2str` | 照 Android 原版 |
| `html` / `loadSpider` / `loadModule` | **拋具名錯誤**，不是靜默缺席 |

`ponytail:` 沒有 vendoring 真的 `requests`。量出來的事實是 **31 支裡 23 支直接 `import requests`、
8 支不用**（`皮皮虾.py` 屬於後者）。那 23 支卡在打包，不是卡在這個類別；先用 stdlib 讓 P3/P4 走得下去，
P5 會把「8 可驅動 / 23 需要 requests」量成數字，vendoring 就變成有數據支撐的後續工作。

`ponytail:` cache 用檔案而不是既有的 `SpiderStorage`。接那個要把 Swift callable 橋進 Python 只為了
兩個字串操作，而且沒有任何站會同時是 JS 與 Python spider，沒有共用狀態要保。升級路徑就是那座橋。

### 四個實際踩到的坑

1. **`Python/` 資料夾參照解析到 `Sources/Python`**，因為它被放進 `path = Sources` 的 group。
2. 更嚴重的是**大小寫碰撞**：`install_python` 已經在 bundle 放了 `python/`，macOS 檔案系統不分大小寫，
   我的 `Python/` 會跟它合併。改成由 Install phase `rsync` 到 `webhtv-python/`，資料夾參照整個不用。
3. **`sys.path` 插不進去**。`PyRun_SimpleString` 會吞掉自己的錯誤，所以失敗完全看不見。改用
   `PySys_GetObject("path")` + `PyList_Insert` 走 C API，沒有字串要引號，也沒有錯誤會消失。
4. **失敗訊息是空的**。原本 bridge 在每個失敗點呼叫 `PyErr_Clear()`，把原因丟掉。加了
   `PythonBoot.takePythonError()`（`PyErr_Fetch` + `Normalize` + `__name__`/`str`），第 3 點才查得出來
   ——它回報的是 `ModuleNotFoundError: No module named 'webhtv_runtime'`，一句話指出真因。

### 驗證

- 假 spider 13 個方法全部回傳預期內容；`init` 存下的 `extend` 能在後續 `detailContent` 取回，
  證明實例狀態是活的而不是每次重建
- 兩個 bool（`isVideoFormat` 真/假、`manualVideoCheck`）分別驗
- **錯誤傳播**：一支 `init` 就 `raise ValueError('boom')` 的 spider，錯誤帶著 `boom` 傳回 Swift，
  不是崩潰也不是空頁
- `swift test` 143 條全過 → `WebHTVCore` 仍在 macOS 上建置與測試

`ponytail:` `selfCheck()` 掛在 DEBUG 啟動路徑上。它是本階段的驗收證據，但正確的家是一個
iOS Simulator test target；P4 需要更完整的端到端驅動時一起搬。

### 尚未開始

P3（`Site.isPythonSpider`、routing、same-origin + HTTPS + size limit + fail closed）、
P4（`皮皮虾.py` 端到端取得 media bytes）、P5（Tier-1 覆蓋量測）。

## IOS-POC-7H — P3：routing 與安全邊界（2026-09-21）

### 結果

模擬器上來源數 **67 → 109**，正好 +42 —— 等於設定檔裡 `.py` 站的數量。`swift test` 從 143 條變
**151 條，全過**（8 條新的都是平台中立的，跑在 macOS 上）。

### 安全邊界：重用，不重述

`PythonSpiderSource` 直接呼叫 `DrpyEngine.checked`（HTTPS＋同 host＋同 port）與 `DrpyEngine.download`
（硬上限）。**不是抄一份規則，是共用同一份實作**，所以兩者不可能漂移。

規則是設定檔的傳輸規則，不是某個引擎的：

| 規則 | 處置 |
|---|---|
| 跨 origin | 拒絕。設定檔裡那 3 支（其中 2 支是明文 HTTP）維持拒絕，**覆蓋率不是放寬的理由** |
| 明文 HTTP（腳本或設定檔任一方） | 拒絕 |
| 超過 256 KB | 中止下載 |
| 匯入的本機設定檔 | **直接拒絕** —— 它沒有 origin，永遠不可能通過同源檢查 |
| 任何失敗 | fail closed，且帶具名原因 |

上限 256 KB 有量測支撐：31 支同源腳本共 569 KB，最大一支 `油管-6.py` 是 93.7 KB。

### 沒有 runtime 就不上架

`canResolve` 對 Python 站多問一件事：這個 build 有沒有直譯器。沒有就**完全不顯示**，而不是顯示了
再在點下去時失敗 —— 跟 registry 對未移植 `csp_*` 類別的處置一致。

這需要一個 seam，因為 `WebHTVCore` 必須在 macOS 上建置，而 CPython 沒有 macOS slice：

```swift
PythonSpiderSupport.makeRuntime: ((String, String) throws -> SpiderRuntime)?
```

App 在啟動時裝上去。core 一行都不用連結直譯器。

### routing 完全沿用既有的

`CSPSourceResolver.session(for:)` 多一個分支，回傳的還是 `SpiderSession`；`SourceClient`、
`WatchHistory`、UI 全部不知道底下是 Python。`ext` 走的是與所有 spider 相同的 `resolvedExtend`。
Python 站的腳本**本身就是 spider**，所以沒有引擎要先抓——一次同源下載就齊了，比 drpy 還少一步。

### 8 條新測試

分類（含大小寫、`.python` 這種近似名、type 非 3 的情況）、沒 runtime 時不上架、有 runtime 時上架、
匯入設定檔永遠不上架、跨 origin 拒絕、明文設定檔拒絕、超大腳本中止、以及腳本確實送達 runtime。

`ponytail:` 這個 suite 標了 `.serialized`。`PythonSpiderSupport.makeRuntime` 是行程全域狀態——那正是
讓 App 裝上 core 造不出的東西的機制——所以兩條測試平行跑會看到彼此的 stub 或彼此的拆除。第一次跑就
是這樣失敗的。全域是刻意的 seam，`.serialized` 是它的代價。

### 順手修掉的一個真缺陷

設定頁那行「目前支援 N 個來源：…以及已移植的 csp_* Spider」在 drpy 進來之後就已經是錯的，現在更錯。
改成把 drpy 與 Python 也講出來，並寫明腳本只從設定檔自己的來源、且必須 HTTPS 才會載入。

### 尚未開始

P4（`皮皮虾.py` 端到端並由 MediaProbe 取得 media bytes）、P5（Tier-1 覆蓋量測）。

## IOS-POC-7J — P4 的量測工具，與它立刻找到的兩個缺陷（2026-09-21）

`PythonLiveCheck` 讀 App **已經安裝的**設定檔與來源網址，挑一個 resolver 願意驅動的 Python 站，
走 `CSPSourceResolver → SpiderSession → MediaProbe`——也就是 UI 走的同一條路。不是另外湊一條。

### 跑到哪裡

```
[python] live FAILED [🏆｜銅牌｜高清] init → home(5 classes) → category(21 items) → detail ✗ …
```

`皮皮虾.py` 在 App 的直譯器上**真的跑起來了**：初始化、首頁回 5 個分類、分類頁回 21 筆、詳情成功。
這已經證明整條鏈（同源下載 → CPython → shim → dict→JSON → SourceClient 契約）是通的。

### 缺陷 1：`requests` 真的擋住了 23 支

第一次跑挑到 `aidianying.py`，直接 `ModuleNotFoundError: No module named 'requests'`。這不是推論，
是執行結果——P1 量到的「23 支直接 import requests」現在有了執行期證據。

### 缺陷 2：shim 的 `fetch` 沒有百分比編碼 URL

```
File "<spider:皮皮虾>", line 76, in searchContent
File ".../base/spider.py", line 64, in _request
UnicodeEncodeError: 'ascii' codec can't encode characters in position 32-33
```

搜尋詞是中文，`requests` 會自動 quote URL，`urllib.request` **不會**。這是我在 IOS-POC-7G 用 stdlib
取代 `requests` 時帶進來的真缺陷，不是腳本的問題。修在 `_request`，不是修呼叫端。

### 這個工具本身的一個 bug，也記著

第一版用 `sorted { left, _ in left.api.contains("皮皮虾") }` 排序——**那個比較函式忽略右運算元，
不是合法的排序關係**，結果是任意順序，所以它先跑了 `aidianying` 而不是指定的最輕量腳本。改成明確
把偏好項提出來再串接。順帶把「只回報最後一次失敗」改成回報每一次嘗試，因為 P5 要數的就是這些。

### 尚未完成

缺陷 2 的修正與重跑（P4 的成功條件是 `MediaProbe` 取得 media bytes），然後 P5 覆蓋量測。

## IOS-POC-7K — P4 完成：真實 Python 來源取得媒體位元組（2026-09-21）

```
[python] live OK [🏆｜銅牌｜高清] init → home(5 classes) → category(21 items) → detail
                                → search(6 hits) → player → probe(media)
```

`皮皮虾.py`（設定檔裡的「🏆｜銅牌｜高清」，`ext` 是它的 host）在 iPhone 17 Pro 模擬器上走完
**完整契約**，最後 `MediaProbe.classify` 回 **`.media`** —— 這是 P4 的成功條件：真的取到媒體位元組，
不是只把 JSON 解出來。

走的是 `CSPSourceResolver → SpiderSession → MediaProbe`，也就是 UI 走的同一條路。

### 這一段唯一的修正

IOS-POC-7J 找到的缺陷 2：`base/spider.py` 的 `_request` 沒有把 URL 百分比編碼。

`requests` 會自動 quote，`urllib.request` **不會**，而腳本是把搜尋詞直接內插進 URL 的
（`皮皮虾` 的 `searchContent` 就是），所以每一次中文搜尋都會死在
`UnicodeEncodeError: 'ascii' codec can't encode characters`。

修在 `_request` 的入口，不是修呼叫端——所有經過 `fetch`/`post` 的腳本一次都好。`%` 列為 safe，
所以已經編碼過的 URL 不會被編第二次。四個情況都驗過：

| 輸入 | 輸出 |
|---|---|
| `?wd=皮皮虾` | `?wd=%E7%9A%AE%E7%9A%AE%E8%99%BE` |
| `/路徑/a.php?x=1` | `/%E8%B7%AF%E5%BE%91/a.php?x=1` |
| `?wd=%E7%9A%AE`（已編碼） | 不變 |
| `?a=b&c=d`（純 ASCII） | 不變 |

### 現在確定成立的事

從**同源下載腳本** → **CPython 執行** → **`base.spider` shim** → **dict→JSON 橋** →
**`SpiderSession` 契約** → **`SourceClient`** → **`MediaProbe` 取得位元組**，整條鏈在真實來源上打通。

### 尚未開始

P5：量出 Tier-1 實際能驅動幾支，分類記錄 stdlib+base、requests、pure-Python extras、Crypto、
lxml/pyquery、cross-origin/HTTP rejected。

## IOS-POC-7L — P5：Tier-1 實際覆蓋量測（2026-09-21）

兩個獨立量測，問的是不同問題，**結論不一樣而且都對**。

### 靜態：`scripts/audit_python_spiders.py`（42 站全數）

可重跑，照 `scripts/audit_spider_jars.py` 的先例。它用**App 實際打包的那份 3.13 標準庫**判定什麼算
stdlib（不是這台 Mac 的），並套用與 App 相同的同源＋HTTPS 規則，所以稽核與 App 不會對不上。

| tier | sites | distinct scripts |
|---|---:|---:|
| Crypto | 17 | 10 |
| requests | 13 | 13 |
| lxml / pyquery | 5 | 5 |
| cross-origin / HTTP 拒絕 | 4 | — |
| **stdlib + base** | **3** | **3** |

### 執行期：`PythonLiveCheck.survey()`（42 站全數，模擬器）

```
driven 4/42: 🏆｜銅牌｜高清(5), 🏆｜蛋塔｜高清(6), ？｜麒麟｜3倍◎無廣(5), 🎡｜櫻花動漫(4)
refused: missing requests×23, missing Crypto×10, cross-origin rejected×4, missing urllib3×1
```

### 為什麼兩邊數字不同 —— 這是重點，不是誤差

- **靜態依「最壞的阻礙」分類**：一支同時需要 Crypto 和 requests 的腳本算在 Crypto，因為只補 requests
  它還是動不了。回答的是「要讓它能跑，需要什麼」。
- **執行期依「第一個阻礙」分類**：同一支腳本在 import 順序上先撞到 requests 就記 requests。回答的是
  「今天是什麼擋住它」。

所以 `Crypto 17 / requests 13`（靜態）與 `requests 23 / Crypto 10`（執行期）描述同一批腳本。

### `init → home` 通過不等於能用 —— 麒麟這一案

執行期說 driven 4，靜態說 stdlib-only 只有 3。差的是 **麒麟影视.py**：它的 `import requests` 在
**方法內**（`def fetch` 裡），所以模組層 exec 會過、`homeContent` 也回了 5 個分類 —— 但那條路一走就炸。

第一版 survey 的門檻是 `init → home`，會把它算成可驅動。**那個門檻在說謊**，已改成跑完整條鏈到
`MediaProbe`，一個站只有拿到媒體位元組才算數。

### 所以 Tier-1 現在的真實覆蓋

| | |
|---|---|
| 已證明端到端取得媒體位元組 | **1 站**（🏆｜銅牌｜高清 / `皮皮虾.py`，IOS-POC-7K） |
| 靜態純 stdlib、可載入可列表 | **3 站**（銅牌、蛋塔、櫻花動漫） |
| 載入可列表但深處會斷 | 1 站（麒麟，方法內 import requests） |
| **42 站中 Tier-1 上限** | **3** |

**vendoring `requests` 會多解 13 站**（→ 16）。**Crypto 是最大單一阻礙，17 站**，而且 `CatVodHost`
已經有 AES/DES/MD5/SHA/HMAC，一個 `Crypto.Cipher` 蓋層是最高槓桿的下一步 —— 但那超出本階段範圍。

### 一個量測本身的危害，必須記下來

survey 會**對設定檔來源每站抓一支腳本**。在稽核腳本剛抓完 38 支之後又連跑兩輪，GitLab 就完全停止回應
（連 `wang-movie.json` 都是 `000`），而那會讀成「driven 0/42」—— **那是對程式碼的誣告，不是量測結果**。

已在每站之間加 400 ms 間隔。全鏈版的 survey 在來源恢復後要再跑一次確認；本節的 4/42 是 home-deep
那一輪的有效結果，1 站端到端是 IOS-POC-7K 的有效結果。

### 我在稽核腳本裡犯了跟 shim 一樣的錯

第一次跑回報 30 站 `unfetchable: 'ascii' codec can't encode characters` —— 腳本檔名是中文，而
`urllib` 不會自動編碼。跟 IOS-POC-7K 修的是同一個缺陷，修法也相同。

### 全鏈 survey 的確認結果（2026-09-21，來源恢復後重跑）

上一節留了一句「全鏈版要等來源恢復再跑一次」。跑完了：

```
live   OK [🏆｜銅牌｜高清] init → home(5) → category(21) → detail → search(1) → player → probe(media)
survey driven 1/42
```

| 結果 | 站數 | 性質 |
|---|---:|---|
| 走完全鏈並取得媒體位元組 | **1** | 銅牌 / `皮皮虾.py` |
| `category` 回空清單 | 2 | **不是相依性問題** |
| 解析出的 URL 不是媒體 | 1 | **不是相依性問題** |
| missing `requests` | 23 | 相依性 |
| missing `Crypto` | 10 | 相依性 |
| missing `urllib3` | 1 | 相依性 |
| cross-origin / 明文 拒絕 | 4 | 政策，刻意 |
| 合計 | 42 | |

**最後三項要分開看。** 那三站（與 home-deep 那輪比對可知是蛋塔、麒麟、櫻花動漫）**腳本載得起來、
方法也跑得動**，斷在內容層：分類回空、或我的通用驅動器挑到的集數解不出媒體。把它們記成
「Tier-1 驅動不了」會低估實際能力，記成「可驅動」又會高估——所以分開列。

誠實的總結是三個數字，不是一個：

- **Tier-1 能執行的腳本：4 / 42 站**（載入、建構、方法回得了資料）
- **端到端到媒體位元組：1 / 42 站**（其餘 3 站斷在內容或驅動器選擇，非相依性）
- **被相依性擋住：34 站**；**被政策拒絕：4 站**

麒麟那 1 站仍要記得：它的 `import requests` 在方法內，所以它落在「能執行」那格是暫時的——
走到那個方法就會變成第 23 支的同類。

## IOS-POC-7N — 失敗訊息是給人看的，traceback 是給 log 的（2026-09-21）

使用者選 `七味.py` 時，畫面上出現的是**整面 Python traceback**，含模擬器絕對路徑，一路排到
`ModuleNotFoundError: No module named 'urllib3'`。

**那個站本身沒有問題**——它就是 IOS-POC-7L 量到的 `missing urllib3 ×1`，是 34 個被相依性擋住的站之一，
行為完全如預期。**有問題的是呈現**：我在 IOS-POC-7G 讓錯誤帶著完整 traceback 跨回 Swift（那是對的，
沒有它 IOS-POC-7K 的 `sys.path` 問題根本查不出來），但忘了那個字串會直接進 `ContentUnavailableView`。

修法：traceback **照樣 print 到 console**，丟給 UI 的只留一行。缺少模組是遠遠最常見的情況
（42 站裡 34 站），所以那一行直接把模組名講出來：

> Spider script error: 這個來源需要 urllib3 模組，App 內建的 Python 沒有它

保留了什麼、丟掉了什麼，分得很清楚：診斷資訊一個位元沒少，只是換了去處。

`ponytail:` `Spider script error:` 這個英文前綴來自 core 的 `SpiderError.scriptFailed`，所有 spider
共用，不是這次帶進來的。要讓它也中文化是另一件事，會動到 core 的錯誤描述，不在這裡做。

## IOS-POC-7P — vendoring `requests`：1 → 6 站端到端（2026-09-21）

使用者在看過 IOS-POC-7L 的數字後選擇做這個。

### 打包方式與直譯器一致

五個 **`py3-none-any`** wheel，全部純 Python、零編譯，釘在 `third_party/python-ios-lock.json` 的
`python_packages`（版本、URL、bytes、sha256、授權），由 `scripts/fetch_python_ios.sh` 下載、驗證、
解壓到 untracked 的 `third_party/python-ios/site-packages`。失敗一律 fail closed。

| 套件 | 版本 | wheel |
|---|---|---:|
| requests | 2.34.2 | 71 KB |
| urllib3 | 2.8.0 | 133 KB |
| certifi | 2026.7.22 | 134 KB |
| idna | 3.20 | 68 KB |
| charset-normalizer | 3.5.1 | 67 KB |
| | **合計** | **472 KB**（解開後 1.6 MB） |

**沒有任何東西要編譯**：內建直譯器已經帶著 `_ssl`、`_socket`、`_hashlib`、`select`，這是先查過才動手的。

在 bundle 裡放 `python-packages/`，與我們自己的 `webhtv-python/` **分開**，所以哪些是我們的、哪些是
第三方，在 bundle 裡跟在 repo 裡一樣一目瞭然。`sys.path` 兩個都掛，我們的優先。

### shim 現在用真的 requests

`base/spider.py` 的 `fetch`/`post` 在 `requests` 可用時就是 **Android 原版逐字照抄**；urllib 那條
保留為 fallback。這很重要——腳本會碰 `.cookies`、`.raise_for_status()`、`Session`，只有真品才會照
作者測過的樣子行為。我先前用 stdlib 頂替只是 `fetch` 一個函式就踩到 URL 編碼那個坑。

### 結果（42 站，全鏈 survey）

| | IOS-POC-7L | **IOS-POC-7P** |
|---|---:|---:|
| 走完全鏈取得媒體位元組 | 1 | **6** |
| 載入並執行（含內容層失敗） | 4 | **14** |
| 被相依性擋住 | 34 | **24** |
| 被政策拒絕 | 4 | 4 |

端到端的六站：YouTube、銅牌、鐵牌、耐看、七猫、大眾。

`requests` 與 `urllib3` **從阻礙清單上完全消失**。剩下的相依性阻礙：`Crypto` 17、`lxml` 3、
`pyquery` 2、**`bs4` 2**——最後這個是新浮現的，原本被 requests 擋在後面看不見。bs4 也是純 Python，
用同一條路就能解，但**沒有順手做**。

靜態分析當初預測「requests 解 13 站」，實際是執行數 4 → 14（+10）。差額就是那 2 支 bs4 與 1 支
`TypeError`，都是被 requests 遮住的第二層問題。預測與實測的落差本身是有用的資訊，不是誤差。

### 一個第二次踩到的坑

`fetch_python_ios.sh --force` 會 `rm -rf` 整個 payload，連 `Prepare Python` 建的 module map 一起，
而 Xcode 在 `Products/` 裡的 `Python.framework` 副本是**陳舊的**，於是 `import Python` 解析失敗。
清掉那份副本重建即可。Prepare phase 修得了來源，修不了 Xcode 已經複製走的東西。

## 政策拒絕的四站：維持拒絕（使用者決定，2026-09-21）

被同源＋HTTPS 規則擋下的就是這四支，逐一列名，免得日後有人把「放寬可以多 4 站」當成待辦：

| 站 | 協定 | 腳本 |
|---|---|---|
| 🥇｜木兮｜只能看高清 | **HTTP** | `itv666.cc/pyplugin/木兮.py` |
| 📡｜虎牙｜Live | **HTTP** | `itv666.cc/星河传媒/py/网络直播.py` |
| ⚽｜咖啡｜體育 | **HTTP** | `itv666.cc/星河传媒/py/kafei2.py` |
| 📺｜星芽短劇 | HTTPS | `git.yylx.win/.../NewTVBox/main/movie/py/XYDJ.py` |

**使用者在看過後果後決定維持現狀，不放寬。**

### 為什麼這條規則是承重的，不是多餘的

那三支走明文 HTTP。HTTP 沒有完整性保證，所以網路路徑上的任何一方都能把回應換成別的 Python，而那段
Python 會在 App 內以 App 的權限執行。**而且 `NSAllowsArbitraryLoads` 已於 IOS-POC-4B 全域開啟**——
傳輸層不會擋它們。現在唯一擋住這三支的就是這條政策。把它拿掉，就沒有第二道防線。

第四支走 HTTPS，沒有中間人風險，但等於把 `git.yylx.win` 上那個帳號的擁有者加進信任清單：他改檔案，
App 下次啟動就跑新的，沒有通知也沒有審核。

### 真的想要某一支時，正確的做法不是放寬政策

**把腳本複製到使用者自己的 repo，改設定檔指過去。** 這樣它變成同源＋HTTPS，一行政策都不用動，而且
內容的控制權在自己手上——上游改壞了不會直接炸到 App。

### 記下來但沒有做：雜湊釘選

跨 origin 要安全，唯一的路是內容必須符合 App 內記錄的 SHA-256——就是 IOS-POC-6B 對 drpy 那九個函式庫
用的招數。代價是腳本一更新雜湊就不符、站就掛掉，而這四支放在別人伺服器上的理由通常正是要常更新。
**沒有實作，列為選項而非待辦。**


## 真機驗證（2026-09-21，IOS-POC-9F）——本文件先前的「從未在真機執行」已不成立

iPhone 18 Pro `00008160-00124C8200214036`，`devicectl` 安裝後由啟動路徑取得：

```
[python] boot running(version: "3.13.15")
[python] selfcheck 13/13 methods OK, errors propagate
[python] live OK [🏆｜銅牌｜高清] init → home(5 classes) → category(21 items)
                               → detail → search(1 hits) → player → probe(media)
```

**`皮皮虾.py` 在真機上走完整條鏈並取得真實媒體位元組**：同源下載腳本 → 內建 CPython 3.13.15 →
`base` shim → dict→JSON 橋 → `SpiderSession` 契約 → `SourceClient` → `MediaProbe`。
13 個 ABI 方法的 selfcheck 也通過，含刻意的負向對照。

本文件與 `docs/AGENT_HANDOFF.md` 自 IOS-POC-7E 起反覆寫著「Nothing Python has ever run on a
device」「全部是模擬器證據」。**那些句子到此為止。**

### 全 42 站 survey 也在真機上跑完了

上一段原本寫「42 站的 survey 本輪未跑完」，那句話在寫下幾分鐘後就被它自己的背景工作推翻——照實更正：

```
[python] survey driven 5/42: 🏆｜銅牌｜高清, 🏆｜鐵牌｜藍光, 🏆｜耐看｜高清◎秒播,
                            🏆｜七猫｜高清◎秒播(浮水印廣告), 🥇｜大眾｜1080P
```

| 結果 | 真機（9F） | 模擬器（7P） | 性質 |
|---|---:|---:|---|
| 走完全鏈取得媒體位元組 | **5** | 6 | — |
| `Crypto` 缺失 | **17** | 17 | 相依性 |
| `lxml` 缺失 | **3** | 3 | 相依性 |
| `pyquery` 缺失 | **2** | 2 | 相依性 |
| `bs4` 缺失 | **2** | 2 | 相依性 |
| 同源／HTTPS 政策拒絕 | **4** | 4 | 政策，刻意 |
| 解析出的 URL 不是媒體 | 4 | — | **內容層** |
| 分類回空清單 | 3 | — | **內容層** |
| `TypeError`／`JSONDecodeError` | 各 1 | — | 腳本層 |

**相依性與政策那四類數字，真機與模擬器一模一樣。** 差別全在內容層——少的那一站落在
「解析出的 URL 不是媒體」或「分類回空」，那是 provider 當下的狀態，不是裝置差異。

所以 **IOS-POC-7P 量到的覆蓋率在真實硬體上成立**，6 與 5 的差距是 provider 噪音而不是退步。
本文件一貫的紀律仍然適用：單次 sweep 是樣本不是判決。
