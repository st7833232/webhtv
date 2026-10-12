# QIST-POSTER-IMPL：受 Referer 保護海報的最小請求適配（W-39）

> Recovery anchor（2026-10-12 14:25 CST）：已實作並驗證，以 guard `QIST-POSTER-IMPL` commit `--no-tag`；未 push。設計：`.herdr-synapse/webhtv-dev/artifacts/qist-poster-design-2026-10-11.md`（W-32 PASS，snapshot `dd280761`），使用者 2026-10-12 核准實作。下一步：Reviewer code review；GUI 驗收隨 Ikanbot adapter（W-41）。

## 目標

TVBox 來源可在海報網址後面帶圖片請求標頭（`<url>@Headers={json}`、`@Referer=…`、`@User-Agent=…`、`@Cookie=…`）。豆瓣海報不帶 Referer 會回 418（設計 §1）。iOS 的 `AsyncImage` 只收 URL，而且這種字串會讓 `URL(string:)` 失敗，所以這類海報原本完全不顯示。

## 改動

| 檔案 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/ImageRequest.swift`（新） | `ImageRequest.parse(_:) -> (url, headers)?`：網址取到**第一個已知標記**（不是第一個 `@`）；每個值截到下一個已知標記（POSTER-03）；header 白名單沿用 `SourceSubtitleProvider.anyHost`（Referer、User-Agent），輸出標準名稱；`@Cookie=` 與 JSON 裡的其他 key 一律丟棄；值含 CR 或 LF（以 `unicodeScalars` 判斷，POSTER-01）丟棄；JSON 壞掉只丟 header；非 http(s) 或沒有標記回 `nil` |
| `ios/WebHTVApp/Sources/WebHTVApp.swift` | 新 `private struct RemoteImage`：`parse` 回 `nil` 時就是原本的 `AsyncImage(url:)`；有標記時用 `URLRequest`（`httpShouldHandleCookies = false`、只套白名單 header、`URLSession.shared` 與 `URLCache.shared`）抓圖，2xx 且 `UIImage(data:)` 成功才算成功。結果與所屬網址一起存（`loaded`），網址改變時先畫 `.empty`，被取消的 task（`Task.isCancelled`、`CancellationError`、`URLError(.cancelled)`）不寫任何狀態（POSTER-04）。4 個入口 `CinematicPosterArt`、`CinematicHeroArt`、觀看紀錄列、`VodPoster` 各換一行，closure 不動 |
| `ios/Tests/WebHTVCoreTests/ImageRequestTests.swift`（新） | 設計 §5 全部 Core 案例，加上 Reviewer W48-02：贝乐虎海報網址本身帶 `@c_1,…%7C…`（圖片處理參數）→ `parse` 回 `nil`、網址整條保留；後面再接 `@Referer=` 時網址仍完整 |

不改：host.js、js.host ABI、catvod 結果欄位、播放器、相容包、ATS、TLS、`URLCache` 設定。

## 與設計的差異

- Ponytail 建議：設計只寫「task 一開始先把狀態設為 `.empty`」；實作改成把結果和它的網址一起存，網址不符就畫 `.empty`。效果相同，而且多擋掉一種情況：同一個 view 換網址後、task 還沒開始的那一次繪製，不會畫出上一張圖。

## 驗證

| 項目 | 指令 | 結果 |
|---|---|---|
| Core 單元測試 | `swift test --package-path ios --filter 'readsIkanbots\|sendsOnlyReferer\|dropsAnyValue\|keepsAnAtSign'` | 4 個測試全過（最後一次修改後重跑） |
| App 建置 | `xcodebuild -project ios/WebHTVApp/WebHTVApp.xcodeproj -scheme WebHTVApp -destination "platform=iOS Simulator,id=BC4948DD-E901-4550-B253-633F80C7ABF9" -configuration Debug build` | `** BUILD SUCCEEDED **`，改動區段沒有新警告 |
| Ponytail review | — | Ship；唯一建議（換網址時的舊圖殘影）已採用 |

## 未驗證

- App GUI：目前沒有任何來源會輸出帶標頭的海報，`RemoteImage` 的標頭路徑、取消行為與快速捲動都要等 Ikanbot adapter（W-41）時一起驗（設計 §5）。一般海報走的仍是原本的 `AsyncImage`，本次沒有另做 GUI 回歸。
- 真機。

## 回滾

一個 commit；`git revert` 後 4 個入口回到 `AsyncImage(url: URL(string:))`，帶標頭的海報再次不顯示，其他不受影響。
