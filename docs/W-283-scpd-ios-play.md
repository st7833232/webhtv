# W-283 香肠派对 iOS 沒有可播放網址

- 工單：W-283（從 W-250 拆出，Manager #7548、#7581、#7645）。
- 結果：根因在使用者設定庫的爬蟲 `py/香肠派对.py`，不在 App。修正方式是 recha 的單一 commit。App 這邊只有第一段（playUrl＋url）已經上線。

## Recovery anchor

- 目標：iOS Simulator 實際起播；Android 原本能播的行為不變；寫明根因。
- 狀態：第一段已在 ios-poc（`1431df33`、`07c3814f`）。第二段（爬蟲修正）是 recha 的 commit `6d228681374dfe73448bb96b3eabc19f69902944`（parent `30591e26fc64b24b195dcbcbd926c52d21422b9a`，GitLab main），待 Reviewer 核准，之後由 Manager 推（使用者單次授權 #7656）。
- 下一步：依審查意見修正；核准後 Manager 推 recha。

## 第一段：iOS 與 Android 讀播放結果的方式不一樣（已上線）

這支爬蟲有幾種取法只回 `{"parse":0,"playUrl":…}`，沒有 `url`。FongMi 播的是 `Result.getRealUrl()` = `playUrl + url`（`Result.java:339`、`PlaySpec.java:43`），iOS 原本只讀 `url`。修法：`parse` 與 `jx` 都是 0 時，爬蟲結果與 type 4 結果都改播 `playUrl + url`（`PlayURL.prefixed(by:)`、`SourceClient.playbackURL`）。測試：`aSpiderResultPlaysPlayUrlPlusUrlWhenNothingParses`、`aType4AnswerPlaysPlayUrlPlusUrlWhenNothingParses`。commit `1431df33`、`07c3814f`，已推上 ios-poc。

## 第二段：真正讓這一部播不了的原因（爬蟲本身）

1. playerContent 的「方法 1」在**任何平台**都不會成功，原因有兩個：
   - 正則 `var player_aaaa\s*=\s*({.*?});` 要求有分號，但播放頁是 `var player_aaaa={…}</script>`，後面沒有分號。
   - 就算對到了，下一行 `re.sub(r'(\w+):', r'"\1":', …)` 會把本來就合法的 JSON 改壞（`"flag":` 變成 `""flag"":`），`json.loads` 失敗後被 `except: pass` 吞掉。
2. 方法 2、3 找 iframe：iframe 是 `player.js` 執行時才產生的，原始 HTML 裡沒有，所以也找不到。最後爬蟲回 `{"parse":1,"url":播放頁}`，要求嗅探。
3. 播放頁的播放器是 `from:"aosika"`；`playerconfig.js` 裡 `aosika` 的設定是 `ps:"1"`、`parse:"https://aosikazyplayurl.com/?url="`，所以網頁會把 m3u8 包進這個外部解析頁的 iframe。這個解析頁 TLS 握手成功，但 HTTP 一直不回應（curl 12 秒、30 秒都逾時），iOS 嗅探 12 秒抓不到串流。
4. `player_aaaa.url`（`encrypt:0`）本身就是 m3u8。直接 GET：主清單 200 → 子清單 200（2395 段，有 `EXT-X-KEY`）→ 第一個 `.ts` 片段 200、`video/mp2t`、開頭是 TS 同步位元組。

### 修法（Manager #7645 選 A；Reviewer #7646 同意）

只改 `py/香肠派对.py` 的方法 1（以 GitLab main 最新版為底）：
- 正則改成 `var player_aaaa\s*=\s*(\{.*?\})\s*;?\s*</script>`，直接 `json.loads`，不再用 `re.sub` 改內容。
- `encrypt` 照苹果CMS 的規則解碼：1 是 `unquote`，2 是 base64 解碼後 `unquote`。
- 回傳 `{"parse":0,"url":m3u8,"header":…}`，兩個平台都直接播，不再依賴外部解析頁。
- 方法 2、3、4 和其他函式都不動。`init()` 存在、回傳 dict 的 FongMi PY 契約不變。

為什麼不改 App（方案 B：嗅探前先讀 `player_aaaa`）：根因在爬蟲，改爬蟲兩個平台都好；B 和 FongMi 的行為不同，要另案評估（Reviewer #7646）。

## 驗證

| 項目 | 結果 | 證據 |
| --- | --- | --- |
| Mac 以 iOS 的 `base/spider.py` 跑原版與修正版 | 原版：`parse:1`、播放頁；修正版：`parse:0`、m3u8 | `artifacts/w283/fix/run.py` |
| encrypt 0/1/2 × 有沒有分號，共 6 種（離線樣本） | 修正版 6 種全過；原版失敗 | `artifacts/w283/fix/enc_test.py` |
| m3u8 → 子清單 → `.ts` 片段 | 都是 200；片段是 `video/mp2t` | `artifacts/w283/fix/seg.py` |
| **iOS Simulator 實播**（w185，本機 https 相容包 `artifacts/w250/kissav/srv`，py 換成修正版） | 首頁 20 部 → 詳情 → 立即播放；25 秒時原生播放器 `00:34 / 1:59:43` | `artifacts/w283/ios/w283-0{1,2,3}-*.labels`（只留文字標籤，不留影片截圖） |
| **Android FongMi 5.8.4**（emulator-5560，本機 http 設定只放這一站） | **測不到播放**：分類列得出來，片單和搜尋都是空的。加了記錄的測試副本顯示，站台對模擬器裡的 Python 請求回 200、277 bytes 的 JS cookie 驗證頁（`fl_js_validator`，`window.location.reload()`），下一個請求直接斷線。這是站台的機器人檢查，依規定不繞過。首頁和分類的程式碼這次都沒有改，所以這個空白在修正前就存在（W-226 也記錄過兩次「載入失敗」）。 | `artifacts/w283/android/fongmi-fetch-log.txt` |

- 未驗證：Android 實際起播（被站台的 JS 驗證擋住）。修正後 Android 的播放路徑和 iOS 一樣，都是 `parse:0` 直接播 m3u8；FongMi 播的是 `getRealUrl()` = `playUrl("") + url`，不需要 App 做任何改動。
- 環境收尾：Simulator 已關；emulator-5560 的點播網址已改回 `http://10.0.2.2:18226/wang-sex.json`，冷開機確認後關機；測試伺服器已全停。

## 交給 Manager 的檔案

- recha commit：`6d228681374dfe73448bb96b3eabc19f69902944`（parent `30591e26fc64b24b195dcbcbd926c52d21422b9a`），淺複製在 `~/.cache/w283-recha`。
- 修正後檔案 sha256：`3bfb5cff5ac237a4c8809ade1642c65e4da7f60e8d63c545b523cd39e2d47aa9`。
- patch：`artifacts/w283/fix/recha-scpd.patch`；diff：`artifacts/w283/fix/香肠派对.py.diff`。

## 回滾

recha revert 這一個 commit 即可；App 沒有改動。
