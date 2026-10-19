# IOS-POC-57B-19：LIBVIO（摸魚 `csp_Libvio`，CDN SHA-256 PoW 後面的 HTML 影視站）

> Recovery anchor（2026-10-19 CST）：W-167，分支 `task/W-167`，guard `W-167`（Manager 開），`--no-tag`。閘門 W-162／W-165 **GO**：`.herdr-synapse/webhtv-dev/artifacts/spider-gate-batch3-2026-10-19.md` §4，審查 `w162-review-2026-10-19.md`（N-1、N-2、W165-N1～N3）。程式與單元測試完成、mutant 全殺、全測試與 pack 試建已跑；Simulator 真網址驗收已完成（手機熱點，`artifacts/w167-gui-evidence/RESULT.md`）。

## 來源

- JAR：摸魚 `439065876_1_1791894280503.jar`（md5 `e521e2cc4db0d7de7c8c001d51a0bfd3`），sha256 `8adcedbd51c3ba467fd16ee3b127224dab0ee904c7975607453f64f5d77b138c`。jar 帶 `FishGuard-v7/v8.so`，但 `Libvio` 本體（`FishCrypto.beginHostEntry` 守衛後的 `$host$…`）是純 Java。
- 依據：閘門解混淆副本 `/private/tmp/w162-gate/deobf/moyu/Libvio.java`（1756 行，只讀）：首頁 `$host$1b26…`、分類 `$host$f9d7…`（:450–496）、詳情 `$host$6c1e…`（:260–420）、播放 `$host$62d5…`（:199–257）、搜尋 `$host$0b14…`、清單 `l()`（:1400）、PoW `L()`（:675–695）與 `m()`（:877–925）、header `y()`（:1748–1749）、ext 處理（:1300–1340，發布頁判斷 `E()` :544）。
- 站：摸魚 `moyu-config.json`:394（ext `site` 是 4 個**發布頁**）；老劉備、飯太硬系、oktv 的 ext 是 `Cloud-drive`，對本 port 沒有作用，走寫死的鏡像。

## 改動

| 檔案 | 內容 |
|---|---|
| `ios/Spiders/Libvio.js`（新） | 單一 `fetch(path)`：上游 UA／Accept／Accept-Language、`redirect:false`、不手寫 Cookie；每次回應都檢查 `403` + `x-cdn-challenge: js-pow`，解 PoW 後手寫 `Cookie: <POW>=<TS>_<MODE>_<nonce>_<SIG>` 送一次（不跟 302），再不帶 Cookie 重打原網址讓 jar 送 `__cdn_verified`；仍被擋就回空，不重試。首頁 `/type/<n>.html` 分類＋`stui` 清單；分類 `show/<tid>--------<pg>---.html`、`li.active.num` 頁數；詳情 `vod-*` 選擇器、非 `netdisk-panel` 的 `div.playlist-panel`，沒有時退回第一個播放頁的 `play-tab`／`stui-play__list`；播放 `player_aaaa`；搜尋 `search/-------------.html?wd=`。 |
| `ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift` | `ported` 加 `Libvio`（附一行註解），`aliases` 沒動 |
| `ios/Tests/WebHTVCoreTests/SpiderGoldenTests.swift` | 預期清單在 `Kanqiu` 與 `MiaoWu` 之間加 `Libvio` |
| `ios/Tests/WebHTVCoreTests/LibvioSpiderTests.swift`（新） | 13 個測試，假站 `LibvioSite`（URLProtocol）照閘門行為：沒有對的 `__cdn_verified` 就回 403 js-pow 頁；手寫 `__cdn_pow` 回**真的 302 轉址**（`wasRedirectedTo`，跟隨的話會再進假站），`Set-Cookie` 照 URLSession 的寫法用逗號接兩行；可設無法連線的鏡像。 |
| `scripts/spider_pack.py` | `DEFAULT_ORIGINS` 加 `Libvio`（摸魚 jar 名與 sha256、一行說明）。沒有重建 `spider-pack/` 相容包。 |
| `docs/IOS-POC-57B-19-libvio.md`（新） | 本文件 |

### Fixture

- 首頁、分類、詳情、兩個播放頁共 5 份是閘門的遮罩回應**整份嵌入**（raw-deflate＋base64，載入時比對 `SHA256SUMS` 記的 sha256，作法同 `TingBokanSpiderTests`）。
- 遮罩值在測試裡換成合成值：`player_aaaa.url` 的 `http…` 換成 `https://v.example.com/2026/a/S01E01.mp4`（或依 `encrypt` 2／1 編碼後的字串、網盤網址）；網盤頁的 `http…` 換成 `https://pan.quark.cn/s/4215abcd`。
- PoW 挑戰頁是**合成**的：只照真頁 `w165-libvio-cat-challenge.body`:156–160 的寫法放 `TS/SIG/DIFF/MODE/POW/EXPECT`。SIG `3f9a1c0d…2468`，`DIFF=00` 第 118 次解出、`DIFF=0` 第 14 次解出，測試用 CryptoKit 重算 nonce 比對 Cookie。
- 詳情頁的線上 `playlist-panel` 是合成的（閘門沒看到真的，N-1）：插在真詳情頁的網盤 panel 前面。

### 和上游不同的地方

- **發布頁不抓**（`// shortcut:` 註解在 `Libvio.js`）：ext `site`／`sites` 只收 http(s) 根網址，含 `fabu`／`libvio.app`／`github.io` 的發布頁（上游 `E()` 的判斷）略過，不去解 `xorDecode(…,'lv2025')` 備用名單；後面接寫死的 `libvio.host` → `libviobd.com` → `www.libvio.to`。原因：`init` 發的請求失敗會被 runtime 記成 `initFailure`，之後每個空結果都怪到它頭上。結果：摸魚設定（ext 全是發布頁）實際走寫死鏡像。升級時機：三個寫死鏡像都失效時。
- **鏡像切換**：某個鏡像連不上（status 0）或回 5xx 就換下一個，session 記住能用的那個。其他狀態（403、404）不換鏡像。
- **PoW 上限**：`min(EXPECT*32, 2,100,000)` 次且 8 秒（每 256 次看一次 `host.now()`），先到先停；`DIFF` 必須是 1–64 位 hex，`TS/SIG/MODE/POW` 必須是 `[\w.~-]+`（擋 Cookie header 注入），否則不送 Cookie 直接失敗。失敗時分類／首頁顯示 runtime 的「HTTP 403」原因，詳情／搜尋回空。
- **網盤一律不做**：上游把網盤線路交給 `Cloud` 父類別。本 port：詳情不列 `netdisk-panel`、也不列名稱含網盤字樣（上游清單＋`百度`、`网盘`）的線路；播放時線路名、`player_aaaa.from`（`kuake`、`xunlei`…）或網址網域是網盤就回空網址。只有網盤線路的片 → 播放清單空。
- **詳情退路**（N-1／N3）：沒有線上 panel 時，抓 `div.play-btn` 的第一個播放頁，`ul.play-tab li a` 名稱與 `div.play-item` 的 `ul.stui-play__list a[href*=/w/]` 依順序配對。
- **`encrypt=3`**：上游走預設分支原樣用；本 port 只要 `url` 以 http(s) 開頭就原樣用，否則 2＝base64 後 `dec`、1＝`dec`。最終網址必須是不含 `$`、`#`、空白的 http(s)。播放帶 `Referer: <播放頁網址>` 與站的 UA，`parse 0`（上游 `.m3u8` 與其他只差旗標）。
- **簡介**取 `span.detail-content`；上游的群組選擇器在 jsoup 會先選到外層 `p`（含摘要＋展開字樣，再刪「展开」），會重複一段摘要。
- **評分**放 `vod_remarks`（去掉「分」，同上游）。
- **id 檢查**：分類 id、詳情 id 只收數字；播放 id 只收 `[\w-]+`。不合格不發請求。
- **沒做**：funcdn 驗證碼退路、手填 Cookie、`libvio_cookie` 動作、PoW 統計寫 `local`。

## 驗證

證據：`.herdr-synapse/webhtv-dev/artifacts/w167-logs/`

| 項目 | 結果 | 證據 |
|---|---|---|
| 先紅 | 測試與 golden 名單先寫、Registry 與腳本都還沒有：13 個 Libvio 測試＋`registryClaimsOnlyWhatIsActuallyPorted` 全紅 | `red.log` |
| 後綠 | `swift test --filter 'Libvio|SpiderGolden'` 19 個全過 | `green.log` |
| Mutant | 24/24 被抓到：PoW 那次跟隨 302、重打仍手寫 Cookie、不重打、上限只用 EXPECT、不驗 DIFF、不驗 TS/SIG/MODE/POW、不排除 `netdisk-panel`、不略過網盤名稱、沒有播放頁退路、分頁都配第一個清單、`encrypt 2` 不 `dec`、播網盤 `from`、播網盤網域、不檢查網址、不帶 Referer、任何播放 id 都送出、關鍵字不編碼、連不上的鏡像不換、發布頁也去問、`data-src` 先於 `data-original`、詳情海報先取 `src`、頁數不讀、不看 `x-cdn-challenge`、不帶 Accept。結尾比對 `Libvio.js` sha256 `2814d472…feff` 已還原 | `mutants.log`（腳本在 scratchpad `w167_mutants.py`，每個 mutant 後還原，結尾比對 sha256） |
| 全測試 | `swift test` 1366 tests／54 suites 全過（5.7 s），沒有需要重跑的計時／WebKit 測試 | `full.log` |
| Ponytail review（最終 diff） | Ship，沒有 finding。查過所有外來值（分類／詳情／播放 id、挑戰頁的 TS/SIG/MODE/POW 不能注入 Cookie header、最終媒體網址）、PoW 次數與時間上限、只在連不上時換鏡像、挑戰失敗不迴圈、`init` 不發請求。沒測的：8 秒時間上限 | — |
| 官方包試建 | `runtime_pack.py build --sequence 7 --version 2026-10-19.w167`：38 支，`verify` 0 problem（試建輸出已刪）；`test_pack_exclusions.py` PASS（相容包 36 支不含 Djuu／Ikanbot，官方包 38 支含） | `pack.txt`、`pack-exclusions.txt` |

## 未驗證／風險

- **Simulator 真網址驗收（2026-10-19，手機熱點，暫存機 iPhone 18 Pro／iOS 27.0，本機 HTTPS 提供序號 7 試建包與只有本站的設定；`artifacts/w167-gui-evidence/RESULT.md`）**：
  - 裝上序號 7 → 首頁「已載入 48 部」、5 個分類；**從重開 App 到首頁片單 2.8 秒**（含啟動、PoW、首頁請求）；分類「電影」一頁 24 部；搜尋「蜘蛛」12 筆；整段沒有 403、驗證失敗或換鏡像。
  - **線上線路比例（審查 W165-N2）：抽 5 部只有 2 部（40%）有可播線路**（「BD5播放」）；另 3 部只有網盤線路，詳情沒有「線路與集數」區塊（照設計不列）。**請 Manager 重估產品價值。**
  - 播放：一部有線上線路的片第 1 集，**原生播放器失敗（`-11850 Operation Stopped`），App 既有的失敗交棒換到 MPV 後起播**（`started on MPV in 6333ms`，1920x1080），約 25 秒後關閉。原生為何拒絕這個站的 mp4（推測伺服器對 Range 請求的回應不合 AVPlayer 期待）沒有查；結果是每次多約 5 秒起播。
  - 未驗：媒體要不要 Referer（沒做不帶的對照）、只有網盤線路的片按「立即播放」的行為、iPhone 實機 PoW 耗時、備用鏡像切換。流量約 20–40 MB（主要是 MPV 緩衝 25 秒 1080p，估計值）。
- 詳情頁上線上線路的真實標記沒看過（只有播放頁看過），本 port 兩條路都有：合成的 `playlist-panel` 與真的播放頁退路。
- PoW 在 iPhone 的耗時沒量；8 秒上限的實際失敗率未知（閘門估約 1%）。時間上限沒有單元測試（要真的跑 8 秒）。
- `URLSession.webHTV` 的系統 cookie 儲存和 jar 並存的效果沒在 App 內驗（假站的請求裡只看到 jar 送的 Cookie）。
- 鏡像網域常換；寫死的三個會過期，發布頁名單沒有讀。
- `encrypt=3` 今天是明文 https；若站方改編碼，播放回空網址。
- 搜尋沒有真站回應可對照（閘門沒驗），用合成清單頁測。

## 回滾

一個 commit；`git revert` 移除 spider、Registry 一行、golden 名單一項、測試與 provenance 一列。已發出的官方包要等下一個序號才會拿掉。
