# W-282 SP360（360影视）用現成 drpy 規則改設定檔接上

- 工單：W-282（使用者 2026-11-10；依 W-273 評估第二節）。使用者單次授權（Manager #7760）：兩個平台都實測起播、Reviewer 核准後，由 Manager 推 GitLab recha main。
- 底稿：GitLab recha main `6d228681`（`wang-movie.json` 87 站）。

## Recovery anchor

- 目標（原）：iOS 與 FongMi 都能列片、翻頁、搜尋、看詳情；至少一條線兩個平台都實際起播。
- 使用者決定（2026-11-11，Manager #7823）：**不測 Android**，只用 iOS 結果結算送審；Android 卡點寫成未驗證。
- 狀態：iOS 引擎層全部測完（第三節）。recha commit `d9ac1258759b060f811fc1a0c5300f796bf9cd93`（parent GitLab main `6d228681374dfe73448bb96b3eabc19f69902944`，淺複製 `~/.cache/w283-recha`）已做好，未推。
- 下一步：Reviewer 核准後，Manager 用 11-10 的單次授權推 GitLab recha main。

## 一、通用格式判斷（團隊規則：加站先走通用格式）

| 順序 | 格式 | 結論 |
| --- | --- | --- |
| ① | 苹果CMS 採集介面（type 0／1） | 不適用。360kan 不是苹果CMS，用的是自己的 JSON API（`api.web.360kan.com`、`api.so.360kan.com`）。 |
| ② | type 4 遠端介面 | 不適用。沒有公開的 type 4 服務，自架一個等於另寫程式。 |
| ③ | 規則引擎（XBPQ、XYQHiker、AppYsV2） | 不適用。這些引擎吃 HTML 或苹果CMS 的 app 介面，不吃 360kan 的 JSON（W-273 第二節）。 |
| ④ | drpy 規則 | **可用**。設定庫的 `_unused/drpy_js/` 已有現成規則，iOS 的 `DrpyEngine`、FongMi 的 drpy2 都能跑。不寫專用爬蟲。 |

## 二、選哪一支規則

`_unused/drpy_js/` 裡有三份：`360影视.js` 和 `360.js`（內容完全相同，md5 `afbf7742…`），以及 `360影视[官].js`（gzip＋base64，解開 6067 bytes，已存在 `artifacts/w282/360影视-官-decoded.js`）。三份的 API、`lazy`、`play_parse` 都一樣。差別如下：

| 規則 | 首頁／分類翻頁／搜尋 | 詳情 | 篩選 |
| --- | --- | --- | --- |
| `360影视.js` | 可以 | **iOS 取不到詳情**（搜尋結果 id 帶 `$`，詳情回空） | 沒有 |
| `360影视[官].js` | 可以 | 可以 | 有 4 組（排序、類型、年代、地區） |

結論：用 `360影视[官].js`。Manager #7760 寫的是 `360影视.js`，但那支在 iOS 進不了詳情。

## 三、iOS 實測（DrpyEngine，2026-11-10，macOS 上的引擎層）

做法：暫時的探測測試（`artifacts/w282/W282Probe.swift.txt`，沒有 commit），用 `SourceClient`、`GlobalParse`、`MediaProbe` 走 App 的實際路徑。設定檔是 GitLab 最新的 `wang-movie.json`，只留這兩站；`parses` 和 `rules` 原樣保留。規則從 GitLab raw 的 `_unused/drpy_js/` 讀，因為 drpy 只接受 HTTPS 資源。

- 首頁：4 個分類（电视剧、电影、综艺、动漫），推薦 9 部。
- 分類翻頁：电视剧第 1 頁 35 部、第 2 頁 35 部，兩頁第一部不同。
- 搜尋「狂飙」11 筆。
- 詳情《战狼2》：6 條平台線（douyin、imgo、youku、qiyi、qq、leshi），每條 1 集。

### 3.1 App 實際播放路徑（超級解析：全部解析服務一起跑）

| 線 | 結果 |
| --- | --- |
| douyin | 4.7 秒，`lf-douyin-pc-web.douyinstatic.com/…/uuu_265.mp4`。檔名看起來是抖音的預設影片，**不能算正片** |
| imgo | 9.4 秒，m3u8 |
| youku | 17 個解析服務都失敗 |
| qiyi | 14.4 秒，m3u8 |
| qq | 17 個解析服務都失敗 |
| leshi | 9.2 秒，m3u8 |

### 3.2 每個解析服務逐一測（`artifacts/w282/ios-parse-matrix.txt`）

JSON 服務（推荐、臻享、优选）對每條線都測；網頁服務只測 qiyi 和 youku。每個服務 25 秒預算；片長是把 m3u8 的 `EXTINF` 加總。

| 片 | 線 | 能出片的解析服務 | 片長 |
| --- | --- | --- | --- |
| 战狼2 | qiyi | 盘古、8090、M3u8TV | 123 分（正片） |
| 战狼2 | youku | M3u8TV | 讀不到片長 |
| 狂飙 | qiyi | 云解、淘片、盘古、8090、M3u8TV、CK | 45 分（一集） |

- 3 個 JSON 服務對全部線都失敗。
- 網頁服務 ikun、A6、虾米、咸鱼、冰豆、七七、夜幕、XY 都失敗。

結論：iOS 上爱奇艺線穩定可播（兩部片、多個解析服務、片長正確）。芒果、乐视也解析得出來，但沒有逐一測解析服務。优酷、腾讯幾乎不能用。抖音線只拿到預設影片。

## 四、Android 實測（FongMi 5.8.4，emulator-5560）

- 第一次：選站後首頁空白。logcat：`RuntimeModule$MissingException: QuickJS module is not installed`。這台 FongMi 只裝了 Python 模組，drpy 站在 Android 根本跑不了（W-223 當時也因此沒比較 drpy 站）。
- FongMi 官方 `module` release 有 `runtime-quickjs-1.1.0-arm64-v8a.apk`，已下載到 `artifacts/android-tools/`；sha256 `d8201b7f…` 和官方 `catalog.json` 一致。我的 `adb install` 被權限拒絕，沒有繞過；使用者已核准，由 Manager 安裝（#7783）。
- 安裝後（Manager 裝，#7793）：`IllegalStateException: Invalid QuickJS module`（`RuntimeModule.require`）。原因：FongMi 5.8.4 早於上游 `5cbfc564f89792600e2cdf4f678e5aab256a2ad3`（2026-10-30「Update crawler runtime compatibility profiles」），只接受相容版本 `fongmi-quickjs-ng-0.17-v11`；官方 module release 現在只有 v13 的 1.1.0（相容 ID 在 `c1c470b84e8111b0660316e842a9e4cb18fd83af` 的 `RuntimeModule.java:79`；release 已改成 5.8.5 以後用的版本）。舊版 v11 的模組已經下載不到。
- 結論：**FongMi 5.8.4 跑不了 drpy 站**。要做 Android 對照，只能把測試機的 FongMi 升到 5.8.7（catalog 對應 Python 1.1.3、QuickJS 1.1.0）。
- 使用者決定（2026-11-11，#7823）：不升級、不測 Android。**Android（FongMi）未驗證**：用 5.8.5 以後 FongMi 的使用者能不能看這站，沒有測過；5.8.4 的使用者選這站會是空白首頁（其他 drpy 站同樣如此）。
- 環境：5560 點播已還原 `18226/wang-sex.json`，冷開機確認後關機；QuickJS 模組依 Manager 指示保留。

## 五、設定變更（已做，未推）

recha commit `d9ac1258759b060f811fc1a0c5300f796bf9cd93`，parent `6d228681374dfe73448bb96b3eabc19f69902944`（2026-11-11 09:37 用 `git ls-remote` 確認仍是 GitLab main）。`wang-movie.json` 87 → 88 站，JSON 解析通過。設定裡原有的 `vod_360`（360zy.com 苹果CMS 資源站）是別的站，不重複。
- `wang-movie.json`：新增一個站物件，放在 `🎡｜七色番动漫` 後面（和其他 `🎡` drpy 站一起）；其他站都不動。

  ```json
  {"key":"drpy_js_360影视[官]","name":"🎡｜360影视","type":3,"searchable":1,"quickSearch":1,"filterable":1,
   "api":"./drpy_libs/drpy2.min.js","ext":"./drpy_js/360影视[官].js"}
  ```
- `_unused/drpy_js/360影视[官].js` 用 `git mv` 移到 `drpy_js/360影视[官].js`，內容不變。

## 六、回滾

revert 那一個 recha commit。App 沒有改動。

## 七、驗證與審查紀錄（2026-11-11）

- 已驗證：iOS 引擎層（第三節）；recha commit 的 JSON 可解析、88 站、新 key 不重複；`drpy_libs/drpy2.min.js` 與 `drpy_js/360影视[官].js` 在 commit 中都存在。
- 未驗證：Android（FongMi）全部（第四節，使用者決定不測）；iOS 只測引擎層與解析服務，沒有在 Simulator App 畫面上點播。
- Ponytail：已跑（ponytail-review，對 recha `d9ac1258` 的 diff）：無發現，可交。App 倉這次只有本文件，沒有程式改動；暫時探測檔 `W282Probe.swift` 已刪、未 commit。
