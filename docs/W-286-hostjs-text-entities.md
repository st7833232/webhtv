# W-286 host.js 的 Text 解碼 HTML 實體

- 任務：W-286（Manager 派工，源自 W-281 發現 #7644）。範圍調整經 Manager #7692 同意。
- 分支 `task/W-286`。

## 1. 問題與根因
爬蟲用選擇器規則取 `Text`（`host.pdfh(x, '…&&Text')`、`host.pdfa` 後再 `pdfh`）時，host.js 的小型 HTML 解析器把文字原樣保留，`&amp;`、`&nbsp;`、`&#25105;` 會直接出現在片名、簡介、分類名。FongMi 用 Jsoup，`text()` 會解碼，所以同一條規則兩平台結果不同（W-281：《飙马野郎 JOJO的奇妙冒险 第二&amp;第三赛段》）。

根因在共用處 `host.js` 的 `nodeValue(node, 'Text')`，一次修正。

## 2. 修正
- `host.js` 新增 `decodeEntities`，`Text` 先解碼再壓空白（與 Jsoup 先解碼後 normalise 同序）：
  - 所有數字實體 `&#..;`、`&#x..;`（含 `&#X..;`）；指向 0、代理區、超過 U+10FFFF 的回 U+FFFD（同 Jsoup）。
  - 具名實體：`amp lt gt quot apos nbsp copy reg trade hellip mdash ndash lsquo rsquo ldquo rdquo middot bull times divide laquo raquo deg yen`。其他名稱與沒有 `;` 的寫法原樣保留（`shortcut:` 註記：不是 HTML5 全部 2,231 個名稱，遇到再補表）。
  - 只解一次：`&amp;lt;` → 文字 `&lt;`。
  - `&nbsp;` 解成 U+00A0，屬空白，連續空白壓成一個空格（同 Jsoup text()）。
- **刻意不改**：`host.text(node)`（規則引擎 XYQHiker 截取模式、XBPQ 線路標籤用原文切割）、屬性值（`href` 等）、`stripTags`。這三者不在本單驗收範圍，改了會動到規則引擎的截取邊界；需要時另開單。
- ABI：改 host.js 依凍結規則升 `js.host` 1.5 → **1.6**（`RuntimeABI.swift` 說明、`RuntimeABITests.swift` 新凍結列與 `hostApiVersion == 6`）；`scripts/spider_pack.py` 的 `HOST_API` 同步為 6。發包 manifest 仍宣告 `minHostApi` 2（`BASE_HOST_API`），舊 App 照常載入整包。

## 3. 呼叫端與受影響範圍
走 `pdfh/pdfa … Text` 的地方（現在會解碼）：

| 呼叫端 | 用途 |
| --- | --- |
| AnimeBashi、Djuu、FirstAid、Ikanbot、Libvio、Sports88、SaoHuo、Wwys、XingChen、AnimeXifan | 片名、備註、簡介、線路名 |
| XBPQ（`.detail&&Text` 等 4 處）、XYQHiker（規則欄位取 Text 的 5 處） | 規則引擎欄位，影響所有用這兩個引擎的設定站 |
| `js-spider.js`（T3 JS 爬蟲的 `pdfh/pdfa`） | 設定檔裡的 JS 爬蟲 |

drpy 不受影響（drpy 用自己的 cheerio，不走 host 選擇器）。

已有的自處理：XingChen `txt()` 會把 `&nbsp;`／U+00A0 換空白 — 修正後仍正確（輸入已是 U+00A0）。AnimeXifan 用 `host.stripTags` 繞道 — **保留**：爬蟲包會送到 host 1.5 的舊 App（現行 0.1.100），拿掉會讓舊 App 片名再出現 `&amp;`。**等使用者 App 全部 ≥ host 1.6 再拿掉**（Manager #7692）。

## 4. 驗證
- 新測試 `HostTextEntitiesTests.textDecodesCharacterReferencesLikeJsoup`：具名、`&nbsp;` 壓空白、十進位／十六進位、無效碼點、只解一次、未知名稱保留、`host.text` 與屬性維持原文。
- `AnimeXifanSpiderTests` 6 個：在 AnimeXifan 拿掉 stripTags 的情況下試跑也過（證明共用處理可取代繞道），之後依 §3 還原保留。
- 完整 `swift test`（1551）：golden（`registryClaimsOnlyWhatIsActuallyPorted` 與各爬蟲 golden）、`RuntimeABITests`（新凍結列、相容包閘門）全過。失敗只有 `CMSClientTests.aType4PlayAnswerCarriesItsSubtitles`（底稿 W-283 的過期斷言，Reviewer #7678，dev-2 修）與 `OfflineDarwinTests.offlineSubtitleRedirects…`（負載逾時，單獨重跑通過）。
- `python3 scripts/test_pack_exclusions.py`：PASS。
- 未做 Simulator：變更在共用 JS 層，單元與 golden 已覆蓋；要在 App 看到效果需新版 App（host 1.6）。

## 5. Ponytail
`ponytail-review`：無發現（單次解碼、未知名稱保留、無效碼點、`hasOwnProperty` 防原型名、未改 `host.text`／屬性、舊 App 相容）。

## 6. 回滾
revert 本單 commit（host.js、ABI 1.6 列與 `HOST_API` 一起回去）。1.6 一旦進了發布的 IPA，凍結列只能新增不能改。
