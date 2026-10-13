# W-97 JS-HOST-BINARY-HMAC：js.host 1.5 二進位 HMAC

> Recovery anchor（2026-10-13 14:05 CST）：已完成，guard `JS-HOST-BINARY-HMAC-W97` commit `--no-tag`；沒有 push、tag、發布。下一步：Reviewer（w1:p7）審查。

## 目標與範圍

- 目標：`host.hmac` 可以對二進位的 key／訊息做 HMAC，讓 Gz360 的 `old_key`（HMAC-SHA1 計算 4＋4＋2＋4 個打包位元組，`Gz360.java`:350–373）能移植。輸出仍是 hex；舊的三參數呼叫行為不變。
- 工單：Manager W-97；依據 `.herdr-synapse/webhtv-dev/artifacts/qist-batch3-shortlist-2026-10-13.md` §4。
- 範圍：`CryptoHost.swift`、`host.js`、`RuntimeABI.swift`、`RuntimeABITests.swift`、`SpiderHostTests.swift`、`scripts/spider_pack.py`、本文件。不改 adapter、不做 Gz360 本體、不重建相容包。

## 契約（js.host 1.5）

- `host.hmac(algorithm, s, key, options)`：`options.input` 與 `options.key` 各為 `utf8`（預設）、`hex` 或 `base64`，名稱不分大小寫。回傳 hex 摘要。
- hex 必須是完整的 ASCII 兩位一組；base64 必須是標準、帶 padding、沒有雜字元。格式錯誤時回傳 `""`，不會拿解析後剩下的位元組去算簽章。這一點和 `rsaEncrypt` 的寬鬆 `decode` 不同，是刻意的設計。
- 舊呼叫：host.js 的三參數呼叫會補上 `'utf8'`；直接用三個參數呼叫原生 `__crypto.hmac` 時，缺的兩個參數會變成字串 `"undefined"`，同樣走 UTF-8 分支。`Feiyu.js` 的兩個呼叫，以及 `SpiderHostTests` 的隨機差分測試都證實行為不變。
- 版本：`RuntimeABI.Surface.jsHost` 1.4→1.5；`SpiderPackStore.hostApiVersion`＝5；`spider_pack.py` `HOST_API = 5`。1.4 已隨 IPA 出貨，所以它的凍結列保留不動，另外新增 1.5 列 `3365611ebd6bf66305599e2e40ce1698ed8a3db00d2336ee70533946aefda712`。現有相容包的 entry 最高 `minHostApi` 4，不需要重建。

## Gz360 其他原語盤點（不實作）

依 `Gz360.java`（jadx-spider）:115–183、:350–387：

| 需要的功能 | host 現況 |
|---|---|
| 請求：AES/CBC/PKCS5，UTF-8 key／iv，輸出大寫 hex | 有：`aesEncrypt(text, key, iv, 'CBC', 'hex')`，結果自己 `toUpperCase()` |
| 請求：RSA 公鑰（X.509）PKCS#1 加密，base64 輸出 | 有：`rsaEncrypt(text, pem)` |
| 回應：RSA 私鑰（PKCS#8，PEM 標頭寫成 RSA PRIVATE KEY）解密 base64 | 有：`rsaDecrypt(text, pem)`，PEM 標頭會被正規式去掉 |
| 回應：AES/CBC 解密 hex 密文，UTF-8 key／iv | 有：`aesDecrypt(text, key, iv, 'CBC', 'hex')` |
| 簽名 MD5、`new_key` SHA-1 | 有：`md5`、`sha1` |
| `old_key` HMAC-SHA1 打包位元組 | **本單新增**：`hmac('sha1', hex, key, {input: 'hex'})`。Gz360 要的是摘要的 base64，用 hex 轉 bytes 再 `host.bytes.toBase64` 就能在 JS 完成 |
| Java `String.hashCode`、`Random.nextInt`、大端 int 打包 | JS 幾行即可，不需要 host |

結論：本單完成後，Gz360 已沒有 host 缺口。剩下的是 adapter 本身的工作：網域輪換、裝置註冊、`signIn`／`signUp` 流程。

## 驗證

| 項目 | 結果 |
|---|---|
| 先紅 | 新測試 `hmacSignsBinaryKeysAndMessagesGivenAsHexOrBase64` 在實作前有 10 個 issue，只有兩個 UTF-8 回歸案例通過（`/private/tmp/webhtv-w97/red.log`） |
| 向量 | RFC 2202 SHA-1 case 1／3／4、HMAC-MD5 case 1；RFC 4231 SHA-256 case 1／2／3；Gz360 形狀（UTF-8 key＋14 個打包位元組）對照 Python `hmac`：`17d0dc53…789b`；奇數長度 hex、非 hex、含空白的 base64 都回 `""` |
| 後綠 | 目標測試＋`RuntimeABITests`＋既有 crypto 測試，8/8 通過 |
| 全測試 | `swift test` 1137 tests／35 suites 全部通過（`/private/tmp/webhtv-w97/full.log`） |
| Mutant | 把 hex 改回寬鬆的 `Data(hex:)` → oddHex、badHex 失敗；把 base64 改成 `.ignoreUnknownCharacters` → badBase64 失敗。兩次都已還原，sha256 `77e39e4c…68fa2` 與原檔一致 |
| 相容包 | `spider_pack.py verify --url spider-pack`：29 scripts，0 problem |
| Ponytail | `ponytail:ponytail-review`：Ship。Nice-to-have 1：不認得的編碼名稱（例如 `b64`）會當成 UTF-8，和 1.3 `rsa` 的 `decode` 一致。我判斷不在本單修，以保持兩者行為相同 |

沒驗：實際的 Gz360 伺服器（不在本單範圍）；Simulator／實機（本單沒有改 UI 或播放）。
