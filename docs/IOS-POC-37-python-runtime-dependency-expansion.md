# IOS-POC-37 — Python Runtime Dependency Expansion

## Recovery anchor

- 目標：依實測依賴矩陣，把 Python spider 缺的第三方套件以可重現、可驗證的方式加進 App 內建的 CPython，受影響的 spider 跑完 smoke test，且不改 Python runtime 架構、不碰 AVPlayer／MPV、不碰 Android `main`。
- 驗收：每個新套件有來源／版本／平台／SHA-256／授權；build／fetch／lock 流程可重現；import＋關鍵 API 在模擬器通過；requests 系不退步；受影響站跑到 `init/home/category/search/detail/player/media`；`swift test`、模擬器 build、Release 裝置 build 通過。
- 狀態：**37A～37F 完成（模擬器），已發布為 `0.1.33 (34)`**（2026-09-29，使用者授權；tag `ios-v0.1.33-b34` → `062fcf99`，IPA 29,313,282 bytes，見 IOS-POC-11 第三十四次發布）。真機未驗證。
- IOS-POC-37.1（第十二節，2026-09-29）：cache context 改由各 spider 持有、native stamp 納入 CPython payload identity；已 push，**尚未發布**（`0.1.33 (34)` 不含）。
- 唯一下一步：請使用者在 iPhone 上用 `0.1.33 (34)` 開第九節「真機待驗」列出的站，回報結果後填進第九節；37.1 的真機項目等下一版發布（第 12.4 節）。

## 1. 起點

| | |
|---|---|
| 日期 | 2026-09-29，開始 16:23 CST |
| 分支 | `ios-poc`，`git fetch` 後 HEAD＝`origin/ios-poc`＝`8fca4181ed921f0bb37d963d986b4d0e84ad2fb1`，ahead/behind 0/0，worktree 乾淨 |
| 前置 | IOS-POC-12 完成；IOS-POC-13 已撤銷（無限期暫緩）；IOS-POC-36 播放器整體驗收延後到本任務之後 |
| 工具鏈 | Xcode 27.0（27A266a）、iPhoneOS／iPhoneSimulator SDK 27.0、host Python 3.13.15（Homebrew `python@3.13`，本任務安裝，只用來驅動交叉編譯） |
| 模擬器 | iPhone 17 Pro（iOS 27.0，`E0A41D48-2210-46B8-B18C-9432B77DECC4`） |

## 2. 37A — 依賴盤點

### 2.1 設定檔現況（2026-09-29 從 `https://gitlab.com/st7833232/recha/-/raw/main/wang-movie.json` 抓）

| | 數量 |
|---|---:|
| 設定檔站台 | 200 |
| Python spider 站（`type 3`、`.py`） | **44**（IOS-POC-7 時是 42；新增 `8movie`、`kkys20`） |
| 同源＋HTTPS（App 會載入） | 40 |
| 跨來源或明文 HTTP（政策拒絕，使用者 2026-09-21 決定維持） | 4（木兮、虎牙、咖啡、星芽短劇 XYDJ） |
| 不重複腳本（同源） | 33（金牌系列 5 站共用 `又是一個金牌.py`，APP 系列 4 站共用 `getapp.py`） |

**注意**：模擬器 App 裡原本存的是舊版 42 站設定檔。37F 之前已把目前的 44 站版本（同一個網址）放進 App 的 `Application Support/wang-movie.json`，基線那一輪（2.4 節）仍是 42 站。

### 2.2 每支腳本的第三方 import 與實際用到的 API

靜態掃描（AST，含方法內的 import；`self.html()` 視為需要 lxml——這次沒有任何腳本呼叫它）。「Crypto 實際用到」是在原始碼裡找到的呼叫，不只是 import。

| 站 key | 名稱 | 腳本 | 第三方 import | Crypto 實際用到 |
|---|---|---|---|---|
| YouTube | 🇹🇼｜YouTube｜PY | `油管-6.py` | requests | |
| 8movie | 8Movie | `8movie.py` | requests（方法內） | |
| kkys20 | 可可影視 | `kkys.py` | requests（方法內） | |
| 皮皮虾 | 🏆｜銅牌｜高清 | `皮皮虾.py` | — | |
| py_aidianying | 🏆｜鐵牌｜藍光 | `aidianying.py` | requests | |
| Uvod | 🏆｜Uvod｜備用 | `Uvod.py` | Crypto | AES-CBC、pad/unpad、RSA.import_key、PKCS1_v1_5（Cipher） |
| dttv | 🏆｜蛋塔｜高清 | `蛋挞TV.py` | — | |
| py_耐看点播 | 🏆｜耐看｜高清◎秒播 | `耐看点播.py` | requests | |
| py_永乐视频 | 🏆｜永樂｜高清◎秒播 | `永乐视频修复搜索.py` | bs4（`html.parser`）、requests | |
| py_麒麟影视 | ？｜麒麟｜3倍◎無廣 | `麒麟影视.py` | requests（方法內） | |
| qmvm | 🏆｜七猫｜高清◎秒播(浮水印廣告) | `七猫影视.py` | requests | |
| 8tdy | 🏆｜八天｜高清(浮水印廣告) | `八天电影.py` | lxml（`etree.HTML`＋27 處 xpath）、requests | |
| 真狼影视.py | 🏆｜真狼｜普畫 + 官源採集 | `真狼影视.py` | lxml（`HTMLParser`／`fromstring`）、pyquery、requests、urllib3 | |
| cbh | 🥇｜茶杯狐｜普清◎秒播(有時候線路失敗) | `茶杯狐.py` | requests | |
| 山楂 | 🥇｜山楂｜不怎樣 + py | `山楂.py` | Crypto | RSA.import_key、PKCS1_v1_5（Cipher） |
| nmvm | 🥇｜農民｜秒播(只有線路2能看) | `农民影视.py` | pyquery、requests | |
| qw | 🥇｜七味.py | `七味.py` | pyquery、requests（含 `HTTPAdapter`）、urllib3 | |
| ysxq | 🥇｜映像｜普畫◎秒播 | `映像星球.py` | bs4（`html.parser`）、requests | |
| py_愛電影.py 等 5 站 | 🥇｜金牌系列 ×5 | `又是一個金牌.py` | Crypto、requests | MD5、SHA1 |
| 大眾 | 🥇｜大眾｜1080P | `大众.py` | requests | |
| 悟空 | 🥇悟空｜1080P(廣告多) | `悟空影视.py` | requests | |
| py_哇哇APP | 📱｜哇哇｜APP | `哇哇APP.py` | Crypto | AES-ECB、unpad、MD5、SHA256、RSA.import_key、`Signature.pkcs1_15` |
| py_八天_APP、py_元咲_APP、py_曼波_APP、py_咕咕_APP | APP 系列 ×4 | `getapp.py` | Crypto | AES-CBC、pad/unpad |
| FreeOK.py | 📱｜FreeOK｜不怎麼樣 | `FreeOK.py` | lxml、pyquery、requests、urllib3 | |
| djjh | 📺｜短剧聚合 | `短剧聚合.py` | requests | |
| 星芽短剧 | 📺｜星芽短剧｜瀟灑 | `星芽短剧.py` | Crypto、bs4、requests | AES-ECB、pad |
| py_喜福短剧 | 📺｜喜福短剧 | `喜福短剧.py` | Crypto、bs4、requests | 只 import（`ARC4`、`AES`、`pad`），未呼叫 |
| py_悟圣短剧 | 📺｜悟圣短剧 | `悟圣短剧.py` | Crypto、bs4、requests | 只 import，未呼叫 |
| py_bi星河影视ili | 🎖︎｜bili看電影 | `哔哩.py` | requests | |
| py_西瓜卡通 | 🎡｜西瓜 | `西瓜卡通.py` | requests | |
| 花子 | 🎡｜花子｜1080P | `huazi.py` | Crypto、requests | AES-GCM、RSA.import_key、PKCS1_OAEP、SHA1／SHA256 |
| MiFun | 🎡｜MiFun | `MiFun动漫.py` | Crypto、requests | AES-CBC、pad/unpad、MD5 |
| py_樱花动漫 | 🎡｜櫻花動漫 | `樱花动漫🔞.py` | — | |

所以 Crypto 要的不是某一兩個 primitive：**AES 的 ECB／CBC／GCM、PKCS#7 pad、ARC4、MD5／SHA1／SHA256、RSA 的 PKCS#1 v1.5 加解密、OAEP、PKCS#1 v1.5 簽章**全部有人用。bs4 的 5 支全部用 `html.parser`（stdlib），不需要 lxml。

### 2.3 「缺少套件 → 影響站台」矩陣（加入前，requests 系已在 App 裡）

| 缺少套件 | 影響站數 | 只缺它的站數 | 影響腳本數 | 失敗的執行階段 | 錯誤 |
|---|---:|---:|---:|---|---|
| Crypto（pycryptodome） | 17 | 14 | 10 | load（模組層 import） | `ModuleNotFoundError: No module named 'Crypto'` |
| bs4 | 5 | 2 | 5 | load | `No module named 'bs4'` |
| pyquery | 4 | 2 | 4 | load | `No module named 'pyquery'` |
| lxml | 3 | 1 | 3 | load | `No module named 'lxml'` |

沒有發現其他缺少的第三方套件：40 站同源腳本的 import 除了上面四個，全部是 stdlib、`base` 或已打包的 requests 系。

依序補上後，**靜態上**「不缺任何套件」的站數（40 站同源中）：

| 步驟 | 站數 | 本步新增 |
|---|---:|---:|
| 基線（requests 系） | 16 | |
| ＋Crypto（37B） | 30 | +14 |
| ＋bs4（37C） | 35 | +5 |
| ＋lxml（37D） | 36 | +1 |
| ＋pyquery（37E） | 40 | +4 |

### 2.4 基線執行期（加入前，模擬器，App 內存的舊 42 站設定）

`PythonLiveCheck.survey()`，每站走 `load → init → home → category → detail → search → player → media`：

```
reached: load 14, init 13, home 12, category 7, search 6, detail 7, player 7, media 3
outcome: dependency:Crypto×17, content×7, complete×3, dependency:lxml×3, dependency:pyquery×2,
         dependency:bs4×2, content(parse=1)×2, policy×4, site/network×1, script×1
```

到 media 的 3 站：鐵牌、耐看、七猫。

### 2.5 分類與實作順序

| 套件 | 分類 | 做法 |
|---|---|---|
| bs4（beautifulsoup4 4.15.0）＋ soupsieve 2.10 ＋ typing-extensions 4.16.0 | pure Python | PyPI `py3-none-any` wheel，照 requests 的做法釘 SHA-256 |
| pyquery 2.1.0 ＋ cssselect 1.5.0 | pure Python，但**硬相依 lxml** | 同上；沒有 lxml 就 import 失敗，所以排在 lxml 之後 |
| Crypto（pycryptodome 3.23.0） | 可預編譯 native extension（40 個 C 模組，無額外系統庫） | 從 sdist 交叉編譯 |
| lxml 6.1.3 | native extension ＋ 需額外系統庫（libxml2、libxslt；zlib、iconv 用 iOS SDK 內建） | libxml2／libxslt 從 GNOME 原始碼編成靜態庫，lxml 從 sdist 交叉編譯 |
| 不可合理支援 | — | 本批沒有 |

順序照建議的 37B Crypto → 37C bs4 → 37D lxml → 37E pyquery，理由是實測收益：Crypto 一個套件解 14 站，遠大於其他；bs4 最便宜；pyquery 必須等 lxml。因為 native 兩個套件共用同一套交叉編譯流程，37B 與 37D 在同一支腳本裡實作，但**依賴與驗證仍逐項記錄**。

## 3. 設計研究（AGENTS.md §7）

### 3.1 問題

PyPI 上 pycryptodome 3.23.0（41 個檔）與 lxml 6.1.3（176 個檔）**都沒有任何 iOS wheel**（PyPI JSON API，2026-09-29）。macOS wheel 在 iOS 上不能載入（Mach-O 的 `LC_BUILD_VERSION` platform 不同，dyld 拒絕），不能拿來充數。要在 iOS 上有這兩個套件，只能自己從原始碼編。

### 3.2 證據

| # | 來源 | 版本／存取 | 等級 | 支持的結論 |
|---|---|---|---|---|
| E1 | Python-Apple-support `3.13-b15` payload：`Python.xcframework/*/platform-config/*/make_cross_venv.py`、`_cross_*.py`、`build/utils.sh` | sha256 `80175765…c5d1`，2026-09-29 讀原始碼 | A（上游原始碼） | 上游隨 payload 附官方 cross-venv 工具：把 host 的 3.13 venv 轉成 iOS 交叉編譯環境（`sys.platform=ios`、iOS sysconfigdata、`arm64-apple-ios-clang` 包裝器）。`install_python <xcframework> <路徑…>` 會把該路徑下每個 `.so` 搬進 `Frameworks/<模組全名>.framework` 並簽章，原處留 `.fwork` 標記 |
| E2 | 同 payload 的 CPython 3.13 `importlib/_bootstrap_external.py` `AppleFrameworkLoader` | 同上 | A | CPython 讀 `.fwork` 的內容，以 `dirname(sys.executable)` 為基準找 framework binary。這就是 stdlib 那 68 個 `lib-dynload` 模組在 App 裡已經在用的機制 |
| E3 | pycryptodome 3.23.0 sdist `lib/Crypto/Util/_raw_api.py` `load_pycryptodome_raw_lib` | sdist sha256 `447700a6…44ef` | A | pycryptodome 不是用 import 載入它的 C 模組，而是用 ctypes 依 `EXTENSION_SUFFIXES` 找 `.so` 檔名；**`.so` 被搬走後它找不到**，這是它在 iOS 上唯一要補的地方 |
| E4 | Legrandin/pycryptodome issue #584（2021，App Store 拒收 `.so`）、#907（2026-03-14，要求 iOS 交叉編譯，open） | GitHub API，2026-09-29 | A（上游 issue） | 維護者 2025-03-20 回覆「this is not a supported platform」。沒有上游修正可等 |
| E5 | lxml 6.1.3 sdist：`buildlibxml.py`（`ARCHIVE_HASHES`、`LIBRARY_PATCHES`）、`setupinfo.py`（`XML2_CONFIG`／`XSLT_CONFIG`、`WITHOUT_OBJECTIFY`）、`CHANGES.txt` | sdist sha256 `45222d94…dd21` | A | lxml 自己的靜態建置參數；6.1.1 起 Linux wheel 用打過 CVE-2025-7424／CVE-2025-11731 backport 的 libxslt 1.1.43，patch 隨 sdist 附（`libxslt-1.1.43-backport1.patch`） |
| E6 | lxml `.github/workflows/wheels.yml` at tag `lxml-6.1.3` | GitHub raw，2026-09-29 | A | 官方 6.1.3 wheel：`LIBXML2_VERSION 2.14.6`、`LIBXSLT_VERSION 1.1.43`。host 上 macOS 版 6.1.3 wheel 回報的也是 libxml2 2.14.6／libxslt 1.1.43 |
| E7 | GNOME `libxml2-2.14.6.sha256sum`、`libxslt-1.1.43.sha256sum` | download.gnome.org，2026-09-29 | A | 與 E5 的 `ARCHIVE_HASHES` 一致——兩個獨立來源對同一雜湊 |
| E8 | BeeWare mobile-forge `recipes/`、`pypi.anaconda.org/beeware` | GitHub API／index，2026-09-29 | B（成熟相關專案） | BeeWare 的 iOS wheel 配方有 cryptography、cffi 等，**沒有 pycryptodome、lxml**，也沒有現成 iOS wheel 可比對。只好自己編；做法與 mobile-forge／cibuildwheel 相同（cross-venv） |
| E9 | 本 repo `chaquo/src/main/python/app.py`（Android 端 loader） | repo | A（被移植的原始契約） | Android 是 `SourceFileLoader(name, path).load_module().Spider()`：腳本存成實體檔、不要求繼承 `base.spider.Spider`、`init` 的回傳值丟掉 |

論文、部落格、benchmark 這類證據本題不適用：問題是建置與載入機制，E1～E9 的一手原始碼已能決定做法；多讀二手文章不會改變結論。

### 3.3 方案比較

**Crypto**

| 方案 | 評估 |
|---|---|
| 不做 | 17 站永遠打不開。拒絕 |
| 原封不動用上游 | PyPI 沒有 iOS wheel，上游不支援 iOS。不可行 |
| 自寫 `Crypto` 相容層（pure-Python AES／RSA，或橋接 `CatVodHost` 的 Swift 加密） | 要重造 GCM、OAEP、PKCS#1 v1.5 簽章與整套 API；橋接 Swift 還要改 Python runtime 架構（任務禁止）。重造密碼學 API 出錯的代價高。拒絕 |
| **從 pinned sdist 用官方 cross-venv 交叉編譯，加一處 `.fwork` 載入 patch（採用）** | 腳本拿到的就是作者測過的 pycryptodome；patch 只有 9 行，行為與 CPython 自己的 `AppleFrameworkLoader` 相同 |

**lxml／pyquery**

| 方案 | 評估 |
|---|---|
| 不做 | 5 站（八天、真狼、農民、七味、FreeOK）打不開 |
| 用 macOS wheel | 在 iOS 上不能載入，且違反「不得用其他平台 binary 假裝成功」。禁止 |
| pure-Python 模擬（html.parser＋elementpath 假冒 `lxml.etree`，或 pyquery 改寫在 bs4 上） | 行為會悄悄不同（xpath、HTML 修補、`.text`／`.tail` 語意），出錯時看起來像網站問題。拒絕 |
| **libxml2／libxslt 從 GNOME 原始碼編成靜態庫、lxml 從 sdist 交叉編譯（採用）** | 與 lxml 官方 wheel 同版本同參數；zlib、iconv 用 iOS SDK 的系統庫；`lxml.objectify` 不編（沒有腳本用，省約 2 MB） |

判斷：這是對上游的 **supplement**——上游方案不變，只補 iOS 缺的兩件事（`.fwork` 載入、交叉編譯流程）。

## 4. 實作

### 4.1 新增的依賴

| 套件 | 版本 | 來源 | 平台 | SHA-256（來源檔） | 授權 |
|---|---|---|---|---|---|
| beautifulsoup4 | 4.15.0 | PyPI wheel | py3-none-any | `d6f88de62e1d4e38ecb1077eb9724cd0eff29d2a08ca16a401e9b9e93f117cf9` | MIT |
| soupsieve | 2.10 | PyPI wheel | py3-none-any | `8596eb8967d744174820280fa62b4542a2e955bfaccca73ed8a13c6eb8e9b502` | MIT |
| typing-extensions | 4.16.0 | PyPI wheel | py3-none-any | `481caa481374e813c1b176ada14e97f1f67a4539ce9cfeb3f350d78d6370c2e8` | PSF-2.0 |
| pyquery | 2.1.0 | PyPI wheel | py3-none-any | `74c9e65ea0cfbcf644a8c3fd438a3dedbcbbd497b9cb366a4f360dba72f8aebb` | BSD-3-Clause |
| cssselect | 1.5.0 | PyPI wheel | py3-none-any | `1d1aded98e82bdde447ded990a191fd6916177c4f0c914fb62eccd58e2ffcdcc` | BSD-3-Clause |
| pycryptodome | 3.23.0 | PyPI sdist，本機交叉編譯 | ios arm64 device／arm64 simulator | `447700a657182d60338bab09fdb27518f8856aecd80ae4c6bdddb67ff5da44ef` | BSD-2-Clause 與 Unlicense（public domain 部分） |
| lxml | 6.1.3 | PyPI sdist，本機交叉編譯 | 同上 | `45222d94ddd511536f3b2f7d9deae3b2339b4ce0f075f1ca25703b07cad9dd21` | BSD-3-Clause |
| libxml2 | 2.14.6 | download.gnome.org，靜態連進 lxml | 同上 | `7ce458a0affeb83f0b55f1f4f9e0e55735dbfc1a9de124ee86fb4a66b597203a` | MIT |
| libxslt | 1.1.43（＋lxml 的 CVE backport patch） | download.gnome.org，靜態連進 lxml | 同上 | `5a3d6b383ca5afc235b171118e90f5ff6aa27e9fea3303065231a6d403f0183a` | MIT |
| setuptools（只在建置時用，不進 App） | 84.0.0 | PyPI wheel | py3-none-any | `51a52592b3b99e102b609654876bd65f19f999935166d1352678931132b0c670` | MIT |

全部寫在 `third_party/python-ios-lock.json`（`python_packages.wheels` 與新的 `python_native_packages`），腳本每次下載都驗大小與 SHA-256，任何不符 fail closed。

本機編出來的 wheel（Xcode 27.0、SDK 27.0；編譯產物不會跨 Xcode 版本逐位元相同，所以這是**紀錄**不是釘選，寫在各 sdk 樹的 `BUILD-INFO.json`）：

| wheel | bytes | SHA-256 |
|---|---:|---|
| `pycryptodome-3.23.0-cp37-abi3-ios_13_0_arm64_iphoneos.whl` | 1,627,777 | `c2418641204700dbcb3f4caf024739cad920fa856d63abfe1c96afc3b5f0d523` |
| `lxml-6.1.3-cp313-cp313-ios_13_0_arm64_iphoneos.whl` | 2,186,017 | `22b7ab45c9938e2bbb8c6b05fb1462e6af0c66509c7f65ae5fc6604ee1945147` |
| `pycryptodome-3.23.0-cp37-abi3-ios_13_0_arm64_iphonesimulator.whl` | 1,646,745 | `14e234f561b943c984c85bdbb7200da7cd1e81d78f604335e3a0c3cee4395021` |
| `lxml-6.1.3-cp313-cp313-ios_13_0_arm64_iphonesimulator.whl` | 2,233,970 | `c4e28e0ddea8c9279ebfd2e41d4a8e37fd37ef059331d62c95b9d4e890a1c783` |

### 4.2 流程

```
scripts/fetch_python_ios.sh [--sdk iphoneos|iphonesimulator]
  ├─ CPython payload（原有，stamp .payload-sha256）
  ├─ 純 Python wheel（stamp 改為 .wheels-sha256，lock 新增 wheel 才會重抓）
  └─ scripts/build_python_ios_native.sh --sdk …（新）
       host python3.13 venv ＋ pinned setuptools → make_cross_venv.py（payload 內附）
       ├─ pycryptodome sdist ＋ third_party/python-ios-patches/pycryptodome-3.23.0-ios-fwork.patch → pip wheel
       ├─ libxml2、libxslt（＋lxml 的 backport patch）configure --host --disable-shared → 靜態庫
       └─ lxml sdist（XML2_CONFIG／XSLT_CONFIG 指向上面，WITHOUT_OBJECTIFY，-liconv）→ pip wheel
       → third_party/python-ios/native/<sdk>/（untracked）：解開、裁掉 SelfTest／型別 stub／C header、strip -x
       → 拒收條件：任何 .so 不是 arm64-only，或 LC_BUILD_VERSION platform 不是該 sdk（iOS=2、Simulator=7）
       → stamp：lock 區段＋腳本＋patch 的 SHA-256；一致就跳過
```

- 建置在乾淨環境（`env -i`）裡跑，Xcode build phase 的 `SDKROOT`／deployment target 不會滲進來。最低 iOS 用 lock 的 13.0，與 payload 其他模組一致。
- **Xcode `Prepare Python`**：`fetch_python_ios.sh --sdk "$PLATFORM_NAME"`，只編當前 sdk。clone 後或 lock 變更後第一次 build 會多約 1.5 分鐘（本機實測模擬器 1:26、裝置 1:23），之後 stamp 一致直接跳過，也不再需要 host Python。
- **Xcode `Install Python`**：純 Python wheel 與該 sdk 的 native 樹合併 rsync 到 bundle 的 `python-packages/`，再由上游 `install_python "$REL" python-packages` 把每個 `.so` 轉成簽好章的 framework（原本只處理 stdlib）。找不到該 sdk 的 native 樹就直接報錯，不會靜默少套件。
- **CI（`ios-sidestore-release.yml`）**：新增 `actions/setup-python@v5`（3.13），`fetch_python_ios.sh --sdk iphoneos` 以 `PYTHON_HOST` 指向它。發布 `0.1.33 (34)` 的 run `36548879889` 是第一次在 CI 上跑：1 分 49 秒完成，之後 Xcode `Prepare Python` 看到 stamp 一致直接跳過。
- `x86_64` 模擬器不支援：上游 `install_stdlib` 複製的是 `lib-$ARCHS`，模擬器建置本來就是單一架構，而這個專案只在 Apple silicon 上建置；Intel 模擬器會在 import 時明確失敗，不會默默少功能。

### 4.3 runtime 端的改動

| 檔案 | 改動 |
|---|---|
| `ios/WebHTVApp/Python/base/spider.py` | `html()` 從「拋錯」改成 Android 原版 `etree.HTML(content)`；lxml 在呼叫時才 import，不讓每支 spider 載入時都拉進最大的 native 模組 |
| `ios/WebHTVApp/Python/webhtv_runtime.py` | 三個相容性 bug，見第五節 |
| `ios/WebHTVApp/Python/webhtv_selfcheck.py`（新） | DEBUG 啟動時的依賴自檢：每個套件跑 spider 真正會用的 API，並對已知答案 |
| `ios/WebHTVApp/Sources/PythonBoot.swift` | DEBUG `selfCheck()` 印出依賴自檢結果 |
| `ios/WebHTVApp/Sources/PythonSpiderRuntime.swift` | Python 失敗改由內部 `PythonFailure` 帶完整 traceback，到類別邊界才轉成給人看的一行（行為與原本相同）；DEBUG 下記錄每站最後一次失敗的方法與 traceback，供 matrix 分類 |
| `ios/WebHTVApp/Sources/PythonLiveCheck.swift` | survey 改成逐站逐階段 matrix：每階段 45 秒上限、失敗分類成 dependency／site-network／content／script／policy、`parse=1` 走 App 同一條 `MediaSniffer` 路徑再 probe |
| `ios/Sources/WebHTVCore/RuntimeABI.swift`、`ios/Tests/WebHTVCoreTests/RuntimeABITests.swift` | `python.host` 1.0 → **1.1**（只有新增），能力清單加 7 個套件；指紋把 native 來源也算進去；1.0 那列保留（已隨 IPA 出貨，append-only） |
| `scripts/audit_python_spiders.py` | 已打包套件改從 lock 讀；輸出每個 import 的影響站數與是否已打包 |

## 5. 測試中找到並修掉的正式程式 bug（根因都在 `webhtv_runtime.py` 的共用入口）

| # | 現象 | 根因 | 修法 | 受影響 |
|---|---|---|---|---|
| B1 | 「短剧聚合」`init` 就失敗：`TypeError: Object of type Spider is not JSON serializable` | 腳本的 `init` 以 `return self` 結尾；我們的 `invoke` 對每個方法的回傳值都做 JSON 序列化。CatVod 的 `init`／`destroy` 是 void，Android 丟掉回傳值（E9） | `init`、`destroy` 的回傳值一律忽略 | 短剧聚合（1 站）→ 到 media |
| B2 | 「映像」載入失敗：`NameError: name '__file__' is not defined` | Android 從實體檔載入腳本，所以有 `__file__`；我們 `exec` 進一個空模組 | 模組帶 `__file__`（Android 會放的位置；不寫檔） | 映像（1 站） |
| B3 | 「永樂」載入失敗：`the script's Spider does not subclass base.spider.Spider` | 我們的 loader 要求繼承 `base.spider.Spider`，Android 不要求（`load_module().Spider()`）；這支腳本是一個自帶全部方法的普通 `class Spider:` | 只要求 `Spider` 是類別；沒有類別仍 fail closed | 永樂（1 站） |

B2、B3 原本被「缺 bs4」擋在後面看不到，補上 bs4 才浮現——與 IOS-POC-7P 補 requests 後才看到 bs4 是同一種情形。

## 6. 驗證

### 6.1 依賴自檢（模擬器 DEBUG 啟動，iPhone 17 Pro／iOS 27.0）

```
[python] boot running(version: "3.13.15")
[python] deps OK requests: requests 2.34.2, urllib3 2.8.0
[python] deps OK Crypto: pycryptodome 3.23.0: AES ECB/CBC/GCM, pad, ARC4, MD5/SHA1/SHA256
[python] deps OK Crypto.RSA: RSA import_key, PKCS1_v1_5, PKCS1_OAEP, pkcs1_15 sign/verify
[python] deps OK bs4: beautifulsoup4 4.15.0 (html.parser + soupsieve)
[python] deps OK lxml: lxml 6.1.3, libxml2 2.14.6, libxslt 1.1.43
[python] deps OK pyquery: pyquery + cssselect: selectors, attr, text
[python] deps OK base.html: base.spider.html()
[python] selfcheck 13/13 methods OK, errors propagate
```

已知答案：AES-128-ECB＝FIPS-197 附錄 C.1；AES-CBC＝NIST SP 800-38A F.2.1；AES-GCM＝GCM 規格 test case 2；ARC4＝key `Key`／`Plaintext`；MD5／SHA1／SHA256 對 stdlib `hashlib`；RSA 每次產生 1024-bit 金鑰做 PKCS1_v1_5／OAEP 來回與 pkcs1_15 簽章驗證；lxml 另驗 GBK 位元組經系統 iconv 解碼。這些測試向量先在 host（macOS 版同版本套件）跑過，確認測試本身正確。**requests／urllib3／certifi／idna／charset-normalizer 沒有退步**（第一行，且全部 requests 系站點照常運作，見 6.3）。

### 6.2 建置與測試

| 項目 | 結果 |
|---|---|
| `build_python_ios_native.sh --sdk iphonesimulator` | 通過，1:26，樹 9.1 MB |
| `build_python_ios_native.sh --sdk iphoneos` | 通過，1:23，樹 9.8 MB；`lxml.etree` platform 2、minos 13.0，連結 `/usr/lib/libiconv.2.dylib`、`/usr/lib/libz.1.dylib`，libxml2／libxslt 靜態 |
| 模擬器 Debug build | 通過；bundle 142 個 framework（原 96＋46），`python-packages/` 裡 0 個 `.so`、46 個 `.fwork` |
| Release 裝置 build（unsigned，參數與 CI 相同） | 通過；46 個新 framework 為 iOS 平台、ad-hoc 簽章 |
| `swift test --package-path ios` | 577 個全部通過（6.4） |
| host 對照 | `webhtv_selfcheck` 在 macOS 同版本套件上全過（驗測試向量本身）；host 差分見 6.3 |

### 6.3 逐站 smoke matrix（37F）

模擬器 DEBUG 啟動後的 `PythonLiveCheck.survey()`，目前 44 站設定。每站 `load → init → home → category → detail → search → player → media`，每階段上限 45 秒；`category`／`detail`／`player` 各試前幾個候選；`parse=1` 的播放頁照 App 的 `SourceClient.target` 交給 `MediaSniffer`，再 probe 取到的網址；**只有 probe 讀到媒體位元組才算 media**。「加入前」是 2.4 節的基線（舊 42 站設定，所以 8Movie、可可影視沒有）。

| 階段 | 加入前（42 站） | 加入後（44 站） |
|---|---:|---:|
| load | 14 | 40 |
| init | 13 | 37 |
| home | 12 | 34 |
| category | 7 | 25 |
| search | 6 | 20 |
| detail | 7 | 25 |
| player | 7 | 25 |
| media | 3 | 19 |

| # | 站 | 加入前 | 加入後：到達 | 加入後：結果 | search |
|---:|---|---|---|---|---|
| 1 | 🇹🇼｜YouTube｜PY | content | player | content：the resolved URL served unknown: http://127.0.0.1:9978/proxy?do=py&typ | ✓ |
| 2 | 8Movie | （舊設定檔沒有此站） | media | media ✓（sniffer） | ✓ |
| 3 | 可可影視 | （舊設定檔沒有此站） | media | media ✓ | ✓ |
| 4 | 🏆｜銅牌｜高清 | site/network | init | site/network：requests.exceptions.ConnectionError: HTTPConnectionPool(host=\'43.248. | — |
| 5 | 🏆｜鐵牌｜藍光 | media ✓ | media | media ✓ | ✓ |
| 6 | 🏆｜Uvod｜備用 | dependency:Crypto | media | media ✓ | ✓ |
| 7 | 🏆｜蛋塔｜高清 | content | home | content：no category returned items | — |
| 8 | 🏆｜耐看｜高清◎秒播 | media ✓ | media | media ✓ | ✓ |
| 9 | 🏆｜永樂｜高清◎秒播 | dependency:bs4 | home | content：no category returned items | — |
| 10 | ？｜麒麟｜3倍◎無廣 | content | player | content：the resolved URL served unknown: https://v14.wsyzym3u8.com/202609/21/A | ✓ |
| 11 | 🏆｜七猫｜高清◎秒播(浮水印廣告) | media ✓ | media | media ✓ | ✓ |
| 12 | 🏆｜八天｜高清(浮水印廣告) | dependency:lxml | home | content：no category returned items | — |
| 13 | 🏆｜真狼｜普畫 + 官源採集 | dependency:lxml | player | content(parse=1)：parse=1 page yielded no stream to the sniffer: http://www.iqiyi.com/v_ | 0 筆 |
| 14 | 🥇｜茶杯狐｜普清◎秒播(有時候線路失敗) | content(parse=1) | media | media ✓（sniffer） | ✓ |
| 15 | 🥇｜山楂｜不怎樣 + py | dependency:Crypto | init | site/network：requests.exceptions.ConnectTimeout: HTTPConnectionPool(host=\'qkys.quk | — |
| 16 | 🥇｜農民｜秒播(只有線路2能看) | dependency:pyquery | media | media ✓（sniffer） | ✓ |
| 17 | 🥇｜七味.py | dependency:pyquery | player | content：the resolved URL served unknown: push://https://pan.baidu.com/s/18LklX | 0 筆 |
| 18 | 🥇｜映像｜普畫◎秒播 | dependency:bs4 | home | content：no category returned items | — |
| 19 | 🥇｜木兮｜只能看高清 | policy | — | policy：rejected(reference: "http://itv666.cc/pyplugin/木兮.py", reason: "drpy r | — |
| 20 | 🥇｜金牌系列-愛電影 | dependency:Crypto | media | media ✓ | ✓ |
| 21 | 🥇｜金牌系列-界界 | dependency:Crypto | init | site/network：requests.exceptions.ReadTimeout: HTTPSConnectionPool(host=\'www.sizhen | — |
| 22 | 🥇｜金牌系列-zjuys | dependency:Crypto | media | media ✓ | ✓ |
| 23 | 🥇｜金牌系列-jiabaide | dependency:Crypto | media | media ✓ | ✓ |
| 24 | 🥇｜金牌系列-cqzuoer | dependency:Crypto | media | media ✓ | ✓ |
| 25 | 🥇｜大眾｜1080P | content | home | content：no category returned items | — |
| 26 | 🥇悟空｜1080P(廣告多) | content | home | content：no category returned items | — |
| 27 | 📱｜哇哇｜APP | dependency:Crypto | load | script:KeyError：'content': KeyError: \'content\' | — |
| 28 | 📱｜八天｜APP | dependency:Crypto | load | site/network：requests.exceptions.ConnectionError: HTTPSConnectionPool(host=\'dy.8tt | — |
| 29 | 📱｜FreeOK｜不怎麼樣 | dependency:lxml | home | content：no category returned items | — |
| 30 | 📺｜短剧聚合 | script:TypeError | media | media ✓ | ✓ |
| 31 | 📺｜星芽短劇 | policy | — | policy：rejected(reference: "https://git.yylx.win/raw.githubusercontent.com/Pi | — |
| 32 | 📺｜星芽短剧｜瀟灑 | dependency:Crypto | media | media ✓ | ✓ |
| 33 | 📺｜喜福短剧 | dependency:Crypto | media | media ✓ | ✗ |
| 34 | 📺｜悟圣短剧 | dependency:Crypto | media | media ✓ | ✗ |
| 35 | 🎖︎｜bili看電影 | content | player | content：the resolved URL served unknown: http://127.0.0.1:9978/proxy?do=py&typ | ✗ |
| 36 | 🎡｜西瓜 | content(parse=1) | player | content(parse=1)：parse=1 page yielded no stream to the sniffer: https://cn1.xgcartoon.c | ✓ |
| 37 | 🎡｜花子｜1080P | dependency:Crypto | home | content：no category returned items | — |
| 38 | 🎡｜MiFun | dependency:Crypto | media | media ✓ | ✓ |
| 39 | 🎡｜元纓动漫 | dependency:Crypto | media | media ✓ | ✓ |
| 40 | 🎡｜曼波动漫 | dependency:Crypto | load | site/content(unexpected answer)：requests.exceptions.JSONDecodeError: Expecting value: line 2 column 1  | — |
| 41 | 🎡｜咕咕动漫 | dependency:Crypto | media | media ✓ | ✓ |
| 42 | 🎡｜櫻花動漫 | content | home | content：no category returned items | — |
| 43 | 📡｜虎牙｜Live | policy | — | policy：rejected(reference: "http://itv666.cc/星河传媒/py/网络直播.py", reason: "drpy  | — |
| 44 | ⚽｜咖啡｜體育 | policy | — | policy：rejected(reference: "http://itv666.cc/星河传媒/py/kafei2.py", reason: "drp | — |

**加入後的結果分類（44 站）**：complete（到 media）19、content 15、site/network 4、site/content 1、script 1、policy 4、**dependency 0**。

content／site 類是不是真的網站問題，而不是 iOS runtime 的問題，是用 **host 差分**確認的：同一支腳本、同一個 `webhtv_runtime.py`、同版本的套件（macOS wheel，只用來當對照組），在這台 Mac 上直接跑，結果與 App 內一致——

| 站 | host 上看到的 |
|---|---|
| 蛋塔 | `ConnectTimeoutError`（www.dantatv.cc） |
| 大眾 | `NameResolutionError`（www.dazhongs.com 解析不到） |
| 悟空、八天、FreeOK、櫻花、永樂 | 首頁有分類，分類頁回空清單、無錯誤 |
| 花子 | `_init_api error: Expecting value`（API 回非 JSON） |
| 映像 | `NameResolutionError`（www.yxxq41.cc） |
| 哇哇 APP | `init` 同樣 `KeyError: 'content'`（API 回應少了欄位）——表中記成 script，實為網站回應改變 |
| 曼波 APP | `init` 同樣 `JSONDecodeError` |

其餘非 media 的站：銅牌（43.248.117.123:4680 連不上）、山楂／界界／八天 APP（逾時或連不上）是 site/network；YouTube、bili 的播放網址是 `127.0.0.1:9978/proxy`（Android 本機 proxy，iOS 已排除）；麒麟的 m3u8 probe 非 2xx；七味給的是百度網盤 `push://`；真狼（iqiyi 頁）、西瓜的 `parse=1` 頁 sniffer 12 秒內沒抓到串流；喜福、悟圣的 search 回傳非 JSON（這兩站 media 仍到）。**這些都不是缺套件，也沒有一站是 dependency 失敗。**

**每個套件的實際解鎖（執行期）**

| 套件 | 需要它的站 | 加入後可載入 | 加入後到 media | 到 media 的站 |
|---|---:|---:|---:|---|
| Crypto | 17 | 17 | 11 | Uvod、金牌 ×4（愛電影、zjuys、jiabaide、cqzuoer）、星芽瀟灑、喜福、悟圣、MiFun、元纓、咕咕 |
| bs4 | 5 | 5（永樂、映像要 B2／B3 一起） | 3 | 星芽瀟灑、喜福、悟圣（三站同時需要 Crypto） |
| lxml（直接用） | 3 | 3 | 0 | 八天、FreeOK 分類回空（網站），真狼 parse=1 頁抓不到串流 |
| pyquery（＋lxml） | 4 | 4 | 1 | 農民（經 sniffer） |
| loader 修正 B1～B3 | 3 | 3 | 1 | 短剧聚合 |

基線 3 站 → 19 站的來源：Crypto +11（其中 3 站同時靠 bs4）、pyquery/lxml +1、B1 +1、設定檔新站 +2（8Movie、可可影視）、survey 改走 App 的 sniffer 路徑 +1（茶杯狐；8Movie、農民也經 sniffer）。基線的 3 站（鐵牌、耐看、七猫）全部仍到 media，**requests 系沒有退步**。

survey 中途有一次 App 被結束：模擬器 log 記錄為 App 切換器的使用者滑掉（`user-quit`、`isUserKill:1`，16:59:05），不是 crash；重新啟動後完整跑完，上表是那一輪。

### 6.4 `swift test`

第一次跑（改 lock 之後、改 ABI 之前）：577 個中 2 個失敗，都在 `RuntimeABITests`——IOS-POC-12 凍結的 `python.host` 1.0 指紋與「能力清單＝lock 裡的套件」兩條。這正是它設計要攔的：新套件是新能力。依它自己的規則（已出貨的版本 append-only）把 `python.host` 升為 1.1、能力清單加 7 個套件、指紋把 native 來源算進去、新增 1.1 那列（`b93c7a05…843a`），1.0 那列不動。

最後一次：`swift test --package-path ios` **577 個全部通過**（14 個 suite，5.0 秒）。

## 7. 體積

量法：Release 裝置 build 依 CI 的 `ditto -c -k --sequesterRsrc --keepParent Payload` 打包（只在 scratchpad 量測，不是發布產物）。

| | 大小 |
|---|---:|
| 本機 IPA（含新依賴） | 30,138,639 bytes |
| 其中新依賴單獨壓縮 | **3,734,042 bytes（約 +3.6 MB）** |
| 參考：已發布 `0.1.32 (33)`（CI 建置） | 25,806,175 bytes |
| 已發布 `0.1.33 (34)`（CI 建置，含本任務） | 29,313,282 bytes（**+3,507,107**） |
| 安裝後新增 | 約 **+11.4 MB**：46 個 framework 8.0 MB（`lxml.etree` 2.9 MB 最大），Python 檔 3.4 MB（Crypto 1.4、lxml 1.2、bs4 0.4 MB） |

CPU／啟動：native 模組只在 import 時載入，沒有 spider 用到就不載入；`base.spider` 不會主動 import lxml。SideStore 重簽時多 46 個 framework 要簽，安裝會稍慢——**未在真機量**。

## 8. 刻意沒做的事

| 項目 | 理由 |
|---|---|
| `lxml.objectify` | 沒有腳本用，省約 2 MB |
| x86_64 模擬器 slice | 見 4.2；Intel 模擬器會明確失敗 |
| 4 支跨來源／明文腳本 | 使用者 2026-09-21 決定維持拒絕，本任務不動 |
| bili、YouTube 的本機 proxy（`127.0.0.1:9978`） | Android 本機 proxy server，iOS 已排除；不是套件問題 |
| `Crypto.SelfTest`、`.pyi`、C header | 不在 App 裡執行 |

## 9. 真機待驗（全部未驗證）

1. 內建 Python 在 iPhone 上 import pycryptodome／lxml（framework 動態載入、SideStore 重簽後的 46 個 framework）。
2. 到 media 的新站在真機播放：Uvod、金牌系列 4 站、星芽瀟灑、喜福、悟圣、MiFun、元纓、咕咕、農民、短剧聚合、8Movie、可可影視、茶杯狐。
3. SideStore 安裝／更新時間是否明顯變長。

## 10. 回滾

- 還沒 push：`git revert` 本任務的 commit；untracked 的 `third_party/python-ios/native/` 與 `build/python-ios-native/` 可以直接刪。
- 只想拿掉 native 套件：從 lock 移除 `python_native_packages` 與對應 wheel、還原兩個 build phase；`base.spider.html()` 會回到明確的 `SpiderError`。

## 11. 其他

- 意圖中的使用者可見變化：原本顯示「這個來源需要 X 模組」的站現在可以載入；三個 loader 相容性修正讓短剧聚合、映像、永樂不再在載入時失敗。沒有 UI、播放器或設定的變化。
- Ponytail review：skipped（選配）。
- 時間：開工時預估 6.5 小時（預計 23:00 完成）；實際 16:23 → 約 17:25，約 1 小時。差距來自兩個 native 套件各只要約 1.5 分鐘就編完、payload 內附的 cross-venv 一次就能用。

## 12. IOS-POC-37.1 — Python per-spider cache isolation 與 native stamp 納入 CPython payload（2026-09-29）

使用者查核 IOS-POC-37 後指出兩個缺口。只處理這兩件，不動 Crypto／lxml／bs4／pyquery，不動播放器；沒有 bump 版本、沒有 tag、沒有發布。起點 HEAD＝`origin/ios-poc`＝`69fab22a`，0/0，worktree 乾淨。`0.1.33 (34)` 的 run `36548879889` 事前已讀實際結果：全部步驟 success（見 IOS-POC-11 第三十四次發布），這次沒有再發布。

### 12.1 cache 隔離

**重現**：新增 `ios/Tests/Python/test_cache_isolation.py`（stdlib unittest，驅動真的 `webhtv_runtime.load/invoke`；兩站 site key 不同、cache 目錄也不同，順序 A 寫 → B 載入並寫同一個 key → A 讀、再寫）。修正前執行：

```
AssertionError: 'from-b' != 'from-a'      # A 在 B 載入之後讀到的是 B 的值
```

**根因**：`base/spider.py` 的 `_site_key`、`_cache_dir` 是模組全域，`webhtv_runtime.load()` 每載入一站就覆寫；`_cache_file()` 在**呼叫時**才讀全域。所以只要 B 在 A 之後載入（全站搜尋 IOS-POC-20 會同時建好幾個 Python spider），A 之後的 `getCache`／`setCache` 就讀寫 B 的檔。現有設定檔中真的受影響的是 MiFun（`did`）與山楂（`ldid`）：裝置識別值可能寫進別站的檔、下次讀不到而重新產生；兩站若用同一個 key 會互相覆蓋。

**修法**：`load()` 建好實例後把 `_webhtv_site_key`、`_webhtv_cache_dir` 設在**該實例**上，`base.spider` 從 `self` 讀；兩個模組全域刪除，沒有任何替代的單一全域。每次 `load` 都 `exec` 出新的模組與類別，所以同一支腳本的多個站（金牌 ×5、getapp ×4）也各自獨立。腳本若在自己的 `__init__` 裡就碰 cache（設定檔裡沒有），那時 context 還沒設定，讀到空、寫入不做，而不是猜別人的 context。

**與 Android 的關係**：API 形狀不變（`getCache(key)`／`setCache(key, value)`）。Android 的 cache 是走本機 proxy 的 `/cache`、以 key 為**全域**，而且讀取時會把 dict/list JSON 還原並處理 `expiresAt`；iOS 自 7G 起是每站一個 JSON 檔、存取字串——這是既有的刻意偏離，本次沒有改。唯一會存 dict 的 YouTube 只在 `localProxy` 路徑讀回，iOS 本來就走不到；MiFun、山楂存的是字串，行為相同。

**測試**：
- host：`python3.13 -m unittest discover -s ios/Tests/Python` → 修正前 FAILED（上面那行），修正後 OK。檢查 A、B 讀到各自的值，A 目錄只有 `site-a.json`、B 目錄只有 `site-b.json`，兩檔內容分別是 `{"did": "from-a-again"}`、`{"did": "from-b"}`。
- App 內（iOS 內建 CPython，經 Swift 的兩個 `PythonSpiderRuntime`）：`PythonBoot.cacheIsolationCheck()` 做同樣的 A→B→A 並檢查兩個目錄的檔名與內容 → `[python] cache A→B→A OK: keys, directories and contents stay per site`。

### 12.2 native stamp 納入 CPython payload identity

**缺口**：`STAMP_WANT` 只涵蓋 `python_native_packages`、建置腳本與 patch。CPython payload 換版時，`third_party/python-ios/native/<sdk>` 仍會被判定為 current，而 extension 是對舊 payload 的 header／sysconfigdata 編的。

**修法**（`scripts/build_python_ios_native.sh`）：
- stamp 最前面加入 lock 釘選的 payload identity：`payload <upstream.release> <contents.python> <upstream.sha256>`（目前是 `3.13-b15 3.13.15 80175765…c5d1`）。不用時間戳。
- 已安裝的 payload 必須就是 lock 釘的那一個：比對 `fetch_python_ios.sh` 驗過下載後才寫的 `.payload-sha256`；不符就 fail closed，要求先跑 `fetch_python_ios.sh`。

**驗證**（本機，Xcode 27.0）：

| 情況 | 結果 |
|---|---|
| 改腳本後第一次跑（兩個 sdk） | 兩個都重建：stamp `51734c1c…` → `b1a3da74…`，2 分 21 秒 |
| 什麼都不變再跑 | 兩個都 `already current` |
| 只把 lock 的 payload SHA 改成別的值（已安裝的仍是舊的） | fail closed：`installed CPython payload (80175765…) is not the one the lock pins (0000…0001)` |
| 模擬 payload 更新（lock 與已安裝 payload 同時換成新 SHA） | iphonesimulator 重建，stamp 變成 `22f2ef19…` |
| 還原真正的 payload identity | 重建，stamp 回到 `b1a3da74…`（stamp 是決定性的）；再跑一次兩個都 `already current` |

測試用的 lock 修改已 `git checkout` 還原並確認 `git diff` 為空。

### 12.3 回歸檢查

| 項目 | IOS-POC-37 | IOS-POC-37.1 |
|---|---|---|
| `swift test --package-path ios` | 577/577 | **577/577**（`python.host` 1.1 已隨 `0.1.33 (34)` 出貨，依 append-only 規則升為 **1.2** 並新增一列指紋 `b34f1a61…efba`；1.0、1.1 兩列不動） |
| 依賴自檢 | 7/7 | **7/7**；13/13 methods 不變 |
| App 內 cache A→B→A | — | **OK** |
| 模擬器 Debug build | 通過 | **通過** |
| Release 裝置 build（unsigned，同 CI 參數） | 通過 | **通過**；142 個 framework、46 個 `.fwork`，bundle 內是修正後的 `base/spider.py` |
| 44 站 survey | load 40、init 37、home 34、category 25、search 20、detail 25、player 25、**media 19** | load 40、init 37、home 35、category 26、search 21、detail 26、player 26、**media 20** |

逐站比對兩輪：**沒有任何一站、任何一個階段從 ✓ 變成 ✗**。多出的一站是「金牌系列-界界」——上一輪是網站 `ReadTimeout`，這一輪網站有回應並到 media，屬網站端波動，不是本次修正的效果。requests 系、Crypto、lxml、bs4、pyquery 的站維持原結果。WatchHistory 不經過 Python cache（Swift 端），本次沒有碰。

### 12.4 真機待驗（全部未驗證）

1. 第九節既有項目（`0.1.33 (34)` 上 import pycryptodome／lxml、新增到 media 的站實際播放、SideStore 重簽 46 個 framework 的安裝時間）。
2. 本節修正尚未出現在任何已發布 IPA（`0.1.33 (34)` 仍是修正前）：下一版發布後，在 iPhone 上先開 MiFun、再開山楂、再回 MiFun，確認兩站的裝置識別各自保留（重開 App 後仍相同）。
3. App 內 A→B→A 自檢只在 DEBUG 跑；Release 真機沒有等價自動檢查。
