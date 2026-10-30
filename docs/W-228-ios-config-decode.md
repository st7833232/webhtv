# W-228 — iOS 讀 FongMi 加密設定格式

## 需求

使用者選擇「XC.json 只做 iOS 讀加密設定，不加站」（Manager #5346）。iOS 載入設定時要跟 FongMi `Decoder.verify`（`app/src/main/java/com/fongmi/android/tv/api/Decoder.java`，origin/main）一樣，支援兩種包裝：

1. 含 `**`：取第一個 `[A-Za-z0-9]{8}**` 之後的內容，做 base64 解碼。
2. 以 `2423` 開頭的 hex AES-CBC：hex 轉字串並轉小寫；key 取 `$#`…`#$` 之間，iv 取最後 13 字，兩者都補 `0` 到 16 字；密文取 `2324` 之後到倒數 26 字之前；AES-CBC／PKCS5。

本來就是 JSON 物件的設定照舊。只做 FongMi 讀標準設定格式的這套解碼，不碰 jar 內的字串加密或原生程式。

## 設計

- 修在共用處：`ConfigLoader.decode` 先呼叫 `ConfigLoader.unwrapped(_:)`，再交給原本的 JSON5 解碼。遠端 `fetch`、匯入、啟動快取、重建都經過 `validate` → `decode`（`WebHTVApp.swift` 378、399、585、715 行）。DEBUG 用的 `PythonLiveCheck` 原本自己呼叫 `JSONDecoder`，改成也走 `ConfigLoader.decode`。
- 判斷順序照 FongMi：已經是 JSON 物件就原樣回傳 → 含 `**` 做 base64 → 以 `2423` 開頭做 CBC（所以 base64 包著 CBC 也能解）。任何一步解不開就保持原文，交給 JSON 解碼器拒絕，不會閃退。
- AES 直接用現有的 `CryptoHost.run(algorithm: "aes", mode: "CBC", inputEncoding: "hex")`，PKCS7 和 PKCS5 對 16 位元組的區塊是同一件事。
- 快取存的是原始（包裝過的）位元組，每次載入都會重新解開。

## 驗證

- 單元測試（`ios/Tests/WebHTVCoreTests/ConfigLoaderTests.swift`，在測試裡自己產生合成設定，不放 XC.json 原檔）：
  - `decodesFongMiBase64AndCBCWrappedConfigs`：base64（前面有註解行）、CBC、CBC 中間有空白換行、base64 包著 CBC，四種都解出同一份設定。
  - `leavesJSONAloneAndRejectsBrokenWrappers`：值裡含 `**` 和 `2423` 的 JSON 原樣不動；壞 hex、密文太短、被截斷、key 不對、base64 不合法、標記不足 8 字，全部都會丟錯，不會閃退。
- `swift test` 全量：1425 個測試全部通過（11:05）。
- Ponytail 審查：Ship；唯一一點「錯誤輸入測試寫得隱晦」已改。
- Simulator：見下方「實測」。

## 實測

- 2026-10-30 11:11，Simulator webhtv-w185，W-228 版 Debug build（`~/.cache/webhtv-dev2-gui/dd-w228`）。用本機 HTTPS 提供未修改的 XC.json 原檔（sha256 `32ad2e9e60bc12ed…`，內容是 `2423` 開頭的 hex），App 的設定網址指向 `https://127.0.0.1:18444/XC.json`。
- 伺服器 log：11:11:13 `GET /XC.json` 200。App 解開後完成載入：`[spider-tool] site list ready … 2026-10-29.1 seq 14`。
- 首頁自動選了第一個 iOS 能跑的站，分類 4 個，來源片單「已載入 12 部」，並有精選影片（截圖 `artifacts/w228-config-decode/01-xc-launch.png`）。
- 選站清單（`02-xc-picker.png`、`03-xc-picker-2.png`）列出 22 站：W-227 判定為 iOS 可用的 20 個影視站、Jpys 那一站，以及 1 個 drpy 聽書站；加密殼和網盤類沒有出現。
- 實測後裝回原版 App，設定改回原值，關閉 XC 伺服器。

## 版本說明（一行）

App 現在可以直接載入 TVBox 常見的加密設定（base64 與 AES 包裝格式），和 Android 版讀法相同。

## 回復

`git revert` 本單的 commit 即可；沒有改資料格式，也沒有改快取。
