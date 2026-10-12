# QIST-CRYPTO-IV — CryptoHost 短 IV 的最小安全修正（方案 B）

## Recovery anchor

- **目標**：`CryptoHost.transform` 在呼叫 `CCCrypt` 前拒絕「非空且短於 block」的 CBC IV；ECB 不傳 IV；空 CBC IV（全 0）、長 IV（取前一個 block）、所有合法輸入的結果不變。
- **Lane／scope**：quick-fix，guard `QIST-CRYPTO-IV`，worktree `/private/tmp/webhtv-crypto-iv`，分支 `ios-poc-crypto-iv`，基準 `88ea5ce9a48c2453be3df38dd60f5448db4ca4e7`。只改 `ios/Sources/WebHTVCore/Spider/Host/CryptoHost.swift`、`ios/Tests/WebHTVCoreTests/SpiderHostTests.swift` 與本文件。
- **依據**：W-23 修正準備（`.herdr-synapse/webhtv-dev/artifacts/qist-crypto-iv-2026-10-09.md`，Reviewer PASS）；Manager 已定方案 B（board #442）。
- **狀態**：實作與 focused proof 完成、Ponytail Ship；等正式 Reviewer，PASS 後才以 guard `finish --no-tag` 本機提交（不 merge、不 push）。
- **下一步（唯一）**：Reviewer 審查本 diff；PASS 後在本 worktree 執行 guard `finish --no-tag`。

## 1. 官方契約

- iPhoneOS 27.0 SDK `usr/include/CommonCrypto/CommonCryptor.h`，`CCCrypt`（:620）的 `@param iv`（:272–280）：IV「If present, must be the same length as the selected algorithm's block size」；CBC 沒有 IV 時用全 0；ECB 時忽略。
- 演算法與 block 對應（`CryptoHost.run`，:82–84，未改）：`aes` → `kCCAlgorithmAES`／16；`des` → `kCCAlgorithmDES`／8；`des3` → `kCCAlgorithm3DES`／8。`ivPrefixed` 一律 16 bytes，不受影響。

## 2. 變更

- `CryptoHost.transform`：
  - `ecb = options` 含 `kCCOptionECBMode`；
  - `guard ecb || iv.isEmpty || iv.count >= blockSize else { return nil }`（呼叫端 `run` 回 `""`）；
  - 傳給 `CCCrypt` 的 IV 指標改成 `!ecb && !iv.isEmpty ? i.baseAddress : nil`（ECB 原本就被忽略，結果不變）。
- 長 IV（> block）照舊只用前一個 block（方案 B，不改目前可用的輸入）；嚴格相等（方案 A）未採用。

## 3. 驗證

- 新測試 `keepsEveryWorkingIVAndRefusesAShortOne`（SpiderHostTests.swift）：以 Swift 直接呼叫同一個 `CCCrypt` 當參考值逐位元比對——AES-CBC 16 字元 IV、空 IV（等於明確 16 個 0 byte）、17 字元 IV（等於 16 字元結果）、ECB 帶 IV 與不帶 IV 相同且等於參考值、DES-CBC 8 字元 IV 可解密；短 IV：AES 15 字元的加密與解密都回 `""`；DES 7 字元**只測解密**，回 `""`（host 沒有 DES 加密導出）。只在**新程式**上執行，不在舊程式上觸發未定義行為（RED 以舊 `transform` 沒有長度檢查的程式碼事實為證，不宣稱跑過 RED）。
- 既有 `reproducesTheExactCipherTheDecompiledSpidersUse`、`carriesTheIVInFrontOfTheCiphertextTheWayApp99Does` 不改。

## 4. 結果紀錄

- 2026-10-11 focused proof（只跑一次）：`swift test --package-path ios --filter 'SpiderHostTests|reproducesTheExactCipherTheDecompiledSpidersUse|keepsEveryWorkingIVAndRefusesAShortOne|carriesTheIVInFrontOfTheCiphertextTheWayApp99Does'`，exit 0，`Test run with 23 tests in 0 suites passed`（filter 比對到整個 SpiderHostTests 檔，實際執行 23 項），其中 `keepsEveryWorkingIVAndRefusesAShortOne`、`reproducesTheExactCipherTheDecompiledSpidersUse`、`carriesTheIVInFrontOfTheCiphertextTheWayApp99Does` 皆通過；完整 log `/private/tmp/webhtv-crypto-iv-proof.log`（sha256 `1f3d75574ac4fbea6ce74ed05ee460cb874dda528f10a65b97dd5f30a0024951`）。
- Ponytail review（final diff）：無 Must／Should 項，Ship。已核對 `transform` 兩個呼叫端（`run` 的 AES 16／DES、3DES 8 與 ECB 旗標；`ivPrefixed` 固定 16 bytes CBC）、全部 spider 呼叫端的 IV 長度，以及新測試的短 IV 斷言**依程式碼推論**會在移除長度檢查時失敗（靜態推論：未執行 mutation，也未在舊程式上跑未定義行為，不宣稱已取得 RED）。
- 未驗證：舊程式的短 IV 行為（未定義行為，刻意不執行）；完整 `swift test`；App GUI。

## 5. 回滾

- 單一 commit；`git revert` 即回到原行為（注意：revert 會重新引入短 IV 的越界讀取）。
