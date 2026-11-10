# W-287 相容包 manifest 雜湊與實際檔案不一致

- 任務：W-287（Manager 發 0.1.100 時發現）。只評估，不改程式。
- 底稿 `origin/ios-poc` `50971e77`，2026-11-10 claude-dev。

## 1. 結論
1. **repo 內的相容包 `spider-pack/manifest.json`（版本 `2026-10-15.1`，33 支）有 2 支雜湊不符**：XBPQ、Duboku。其餘 31 支相符。
2. **App 遇到雜湊不符會整包拒用**，不會照用、也不會只略過那一支：`SpiderPackStore.assemble` 在第一支不符時丟出 `hashMismatch`，什麼都不安裝，保留原本已安裝的相容包，設定頁「設定檔相容包」顯示更新失敗。
3. **目前沒有使用者會讀到這一包**：
   - App 找相容包的位置是**設定檔旁邊**的 `./spiders/manifest.json`（`SpiderPackStore.defaultReference`）。使用者設定庫 recha 沒有這個檔（GitLab `spiders/manifest.json` 回 404）。
   - `ios-poc:spider-pack/manifest.json` 只有在設定檔就放在 `spider-pack/` 旁邊，或用 `spiderPackURL` 偏好設定覆寫（沒有任何 UI 會寫它）時才會被讀到。
   - 使用者實際下載的是**官方包** `spider-pack/official/`（2026-11-10.2，序號 17，46 支）：`runtime_pack.py verify` 結果 0 problem。
4. 所以這是**倉庫裡過期的發布物**，不影響現有使用者；但任何人拿它當相容包發布，會被 App 整包拒用。

## 2. 雜湊對照（manifest 宣告 vs 檔案實算，前 12 碼）

| 類別 | manifest | 實際檔案 | 結果 | 第一次改壞的 commit |
| --- | --- | --- | --- | --- |
| XBPQ | `66e7f59df554` | `eaa6cfd85693` | **不符** | `60488824`（W-185，10-20）起共改 6 次（W-185、W-197、W-222、W-250×3），manifest 都沒重產 |
| Duboku | `3f900c986ad4` | `1e060dae103e` | **不符** | `b8ea3009`（W-177，10-20）、`1cd457fe`（W-213，10-28） |
| 其餘 31 支 | — | — | 相符 | — |

另外：`spider-pack/scripts/XYQHiker.js` 雜湊與 manifest 相符，但比 `ios/Spiders/XYQHiker.js` 舊（W-265 只改了 ios/Spiders）。其他 32 支與 `ios/Spiders` 相同。

成因：W-177／W-185／W-197／W-213／W-222／W-250 改爬蟲時同步改了 `spider-pack/scripts/` 的副本，卻沒有用 `scripts/spider_pack.py build` 重產 manifest；最後一次重產是 `b1b20606`（W-105，10-15）。沒有任何測試在檢查這兩者一致（`test_pack_exclusions.py` 只檢查名單）。

## 3. App 行為證據
- 現有單元測試 `SpiderPackTests.refusesAPackWhoseScriptDoesNotMatchItsDeclaredHash`：通過（雜湊不符 → `hashMismatch`、`installedPack()` 為 nil、registry 仍是原本的）。
- 實物重現（暫時測試，跑完已刪，repo 無變更）：把 repo 的 `spider-pack/manifest.json` 與 `scripts/` 原封不動餵給 App 的 `SpiderPackStore.refresh`，結果：
  ```
  [w287] refused: hashMismatch(className: "Duboku") — Duboku 的內容與 manifest 宣告的 SHA-256 不符。
  [w287] installedPack after: nil
  ```
  （manifest 依字母序，Duboku 比 XBPQ 先檢查，所以先在 Duboku 停下。）
- 程式依據：`ios/Sources/WebHTVCore/Spider/SpiderPack.swift` `assemble`（「A hash mismatch refuses the whole pack」）。

## 4. 建議最小修法（另開實作單）
1. **加一個一致性檢查**（建議，約 15 行）：在 `scripts/test_pack_exclusions.py`（或 Swift 測試）加「`spider-pack/manifest.json` 每支 sha256 等於 `spider-pack/scripts/` 實檔」，以後漏重產會在測試時就抓到。
2. **一次性重產**：`python3 scripts/spider_pack.py build` 從 `ios/Spiders` 重產 `spider-pack/`（會把 XBPQ、Duboku、XYQHiker 都對齊目前程式），版本號換新、附 CHANGELOG。
3. 另一個選項（交使用者／Manager 決定）：既然沒有使用者會讀到 repo 這包，也可以**不再維護 `spider-pack/scripts/` 副本**，只留官方包；但 IOS-POC-61 的決定是「相容包不動」，要撤掉需要使用者同意，本單不建議擅自做。

建議做 1＋2，一張 quick-fix 單。

## 5. W-288 修正（2026-11-10，claude-dev）
依 §4 建議 1＋2（Manager #7753；撤掉副本與否由 Manager 問使用者，本單照「保留並修好」）。

- **重產**：把 manifest 原本的 33 個類別從 `ios/Spiders/` 複製到暫存目錄，`python3 -I scripts/spider_pack.py build --scripts <暫存> --out spider-pack --version 2026-11-10.1`。結果只動 3 支：Duboku、XBPQ 只改雜湊（副本內容本來就是新的），XYQHiker 內容與雜湊都更新成目前的 `ios/Spiders`（W-265）。類別數仍 33，`minHostApi` 2 不變。工具不再寫空的 `"mappings": []`，App 讀不到欄位時視同空陣列（`manifest.mappings ?? []`）。
- **一致性檢查**：`RuntimeABITests.theRepositoryCompatibilityPackMatchesItsManifest` 逐支比對 `spider-pack/scripts/` 實檔 SHA-256 與 manifest，並要求目錄裡沒有 manifest 沒列的檔。放在每張單都會跑的 `swift test`（兩個 Python 檢查都不在 CI 裡）。
- 驗證：
  - 新測試在重產後通過；在 Duboku.js 尾端加一行、不重產，新測試失敗（`RuntimeABITests.swift:236`），還原後通過。
  - 暫時測試把重產後的 `spider-pack/` 餵給 App 的 `SpiderPackStore.refresh`：`installed 2026-11-10.1 scripts=33 rejected=[]`（跑完已刪）。
  - `runtime_pack.py verify --dir spider-pack/official`：0 problem；`test_pack_exclusions.py`：PASS；`RuntimeABITests`、`SpiderPackTests` 全過。
- 注意：之後改 `ios/Spiders/` 的爬蟲時，若同時改 `spider-pack/scripts/` 副本，要一起重產 manifest，否則這個測試會失敗。
- Ponytail（W-288）：1 項 Nice to have（目錄比對只看 `.js`，避免 Finder 的 `.DS_Store` 誤判）已修；其餘無發現。
