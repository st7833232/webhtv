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
