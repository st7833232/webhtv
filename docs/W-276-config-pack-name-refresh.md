# W-276 設定頁「設定檔相容包」名稱即時更新

- 任務：W-276（W-271 Reviewer 非阻擋 N-1、N-2）。quick-fix，只動顯示更新，不改載入流程。
- 分支 `task/W-276`，底稿 `task/W-286` `9b683bce`（W-281＋W-286 已核准，可快轉到 `origin/ios-poc` `bde74eac` 之上）。

## 1. 問題
在設定頁「加入設定來源」載入一個只靠自身相容包（`./spiders/manifest.json`）才能用的設定檔時，W-271 讓載入過程把該相容包裝好，但設定頁的「設定檔相容包」一列還是舊名稱，要到下次啟動才更新。

根因：`packStatus` 只在啟動（`.task`）與 `refreshSpiderPack()` 更新；`load(remote:)` 在 `adopt` 成功後沒有更新。啟動路徑在 `refreshRemote` 之後會接著跑 `refreshSpiderPack()`，所以只有手動加入／重新整理來源這條路看得到舊名稱。

## 2. 修正
`ios/WebHTVApp/Sources/WebHTVApp.swift` `load(remote:)`：`adopt` 成功後讀一次已安裝的相容包，設定 `packStatus = Self.describe(pack)`（1 行＋註解）。沒有相容包時維持原值；載入失敗不改。載入流程不變。

N-2（`CspOnlyConfigLoadTests.swift:51` 多餘 `try` 警告）：警告來自 W-271 commit 前的版本，已提交的 `368a1ea9` 該行已是 `await keepingInstalledPack {`；本單強制重編該檔沒有警告，**不需修改**。

## 3. 驗證（Simulator webhtv-w202，本分支 Debug 建置）
證據 `artifacts/w276/`，驅動 `w276.sh`，設定由本機 HTTPS 18445 提供。

1. 啟動時設定來源是 `w276-test.json`（只有 `csp_W276Only`，類別只在它旁邊的相容包 `w276-v1`）：設定頁顯示 `相容性套件 w276-v1，1 支腳本`（`s1-settings3.png`）。
2. **不重啟**，在設定頁「加入設定來源」輸入 `https://127.0.0.1:18445/b/w276b-test.json`（只有 `csp_W276B`，相容包 `w276-v2`）並按「載入」（`s3-typed.png`）。伺服器記錄抓了設定檔、manifest、腳本（`https.log` 17:16:03）。
3. 回到設定頁：來源已換成 `b/w276b-test.json`，「設定檔相容包」立即顯示 `相容性套件 w276-v2，1 支腳本`（`s3-after.png`、`s3-after.labels`）。

修正前的行為以 W-271 Reviewer N-1 的記錄為準（W-271 文件 §7），本單沒有另跑舊版對照。

## 4. Ponytail
`ponytail-review`：無發現（成功後才更新、失敗不動；沒有相容包時保留原值，與已安裝狀態一致）。

## 5. 回滾
revert 本單 commit。
