# W-159：換播放引擎時沿用字幕

> Recovery anchor（2026-10-19 CST）：webhtv-dev-claude-dev-2，guard `W-159`，`--no-tag`。來源：W-154 審查非阻擋項（音軌已沿用，字幕沒有）。

## 做了什麼

換引擎（觀眾按的、失敗交棒、起播逾時）時，沿用觀眾的**內嵌字幕**：語言與種類（一般、CC、SDH、強制），或「關閉」。線上字幕本來就由 router 帶到每個引擎，不在這裡處理。開新項目（`reason=open`，含直播換台／換線）從引擎預設開始。

- Core `PlaybackMediaSelection.swift`：`PlaybackSubtitleCarry`（從舊引擎的選擇取出：`off` 或 `track(language:role:)`；線上字幕、沒有語言也不是 CC 的軌回 nil）與 `PlaybackMediaTrack.reselection(carrying:)` → `select(id)`／`matched`／`unavailable`／`wait`。語言比對沿用 W-154（`canonicalLanguageCode`，同種類優先、再同完整標籤）；沒有語言的 CC 比對 CC；**不比對 build 解不了的字幕**（teletext／ARIB，MPV 會再關掉）；「關閉」**不關 forced 軌**（外語對白的那幾行）。
- App `WebHTVApp.swift`（`PlaybackSession`）：換引擎時記下 `subtitleToCarry`；**新引擎開始播放後的 20 秒內持續維持**——每次字幕清單更新，偏離了就選回來；新引擎沒有這個字幕就放棄；觀眾自己在選單選字幕立刻結束沿用（`selectMedia`），沿用自己的選擇走 router，不會結束自己；開新項目清掉；換引擎時若上一個沿用還在，保留原本的（中間那個引擎只是顯示自己的預設）。log：`[subtitle] switch to <引擎>: carried <語言>/<種類> id=…`、`kept the default, no …`、`stopped holding …`。

### 為什麼不是「套用一次」（和 W-154 音軌不同）

Simulator 第一輪照音軌的做法（第一份清單套用一次）兩個方向失敗：
1. 原生「關閉」→ MPV：MPV 第一份清單還沒選任何軌（判成已經關閉、沿用結束），之後 MPV 自己挑了 English。
2. MPV English → 原生：套用了，但原生在 readyToPlay 套自己的預設，3 秒後變回關閉。

第二輪改成「維持 20 秒、偏離就拉回」：選單對了，但**原生在起播前選的字幕只記在選單、畫面不畫**。第三輪改成「新引擎真的在播才套用」（`watchStartup`／`watchHandoff` 起播那一刻再問一次），全部通過。最後依 Ponytail 把 20 秒從「起播那一刻」才開始算，暫停時換引擎、之後（60 秒內，見下方 N-1）才按播放也會沿用。

## 驗證

| 項目 | 結果 | 證據（`.herdr-synapse/webhtv-dev/artifacts/`） |
|---|---|---|
| 先紅 | 新測試先寫：`PlaybackSubtitleCarry`、`reselection(carrying:)` 不存在 → 編譯失敗 | `w159-logs/red.log` |
| 單元測試 | `SubtitleLanguageCarryTests` 5 個（含 W-154 的音軌 7 個共 12 個）全過：原生↔MPV 中文、關閉沿用（含 MPV 尚未選、forced 不關）、CC 等待與其他語言放棄、同種類與同標籤優先、解不了的 teletext 不算、線上字幕與無標籤軌不沿用、log 描述 | `w159-logs/green3.log` |
| 全量 `swift test` | 1352 tests／53 suites 全過（最終程式） | `w159-logs/full3.log` |
| App build | 成功（最終程式） | `w159-logs/app-build4.log` |
| Simulator 第一輪 | 原生中文→MPV PASS；MPV English→原生、原生關閉→MPV FAIL（見上）；開新項目不沿用 PASS | `w159-gui-evidence/RESULT.md` |
| Simulator 第二輪 | 關閉兩方向、手動優先 PASS；原生 English 選單對但畫面不畫 | `w159-gui-evidence/run2/RESULT.md` |
| Simulator 第三輪 | 5/5 PASS：MPV English→原生畫面真的出現「ENGLISH SUB W159」（切換後 5、15 秒）；原生中文→MPV；原生關閉→MPV 6 秒與 53 秒後都無字；切換後 8 秒手動選 English 20 秒後仍是 English；log 無網址 | `w159-gui-evidence/run3/RESULT.md` |
| Ponytail review | 第一次 3 項（手動選字幕會被 CC 等待蓋掉、關閉會關掉 forced、連續切換蓋掉原沿用）全部採用；最終版 1 項（暫停時換引擎不會沿用）採用；另自查加了「不比對解不了的字幕」 | — |

測試片：本機 `subs.mp4`（120 秒，兩條 mov_text：eng、chi），用支援 Range 的本機伺服器提供（原生需要 Range），經直播清單播放；不走外網。

## 未驗證／風險

- 最後一個改動（20 秒從起播才開始算）只跑了單元測試、全量測試與 App build，沒有再跑 Simulator；它只改視窗的起點，第三輪的流程都是在播放中換引擎。
- CC 晚出現時的沿用（沒有兩個引擎都列得出 CC 的測試片）、失敗交棒時的沿用、真實多字幕串流、實機。
- 沿用期間若引擎不斷拒絕選擇，20 秒內每份清單都會再選一次（解不了的字幕已排除）。

## 回滾

一個 commit；`git revert` 移除 Core 的沿用型別、PlaybackSession 的接線與測試，音軌沿用（W-154）不受影響。

## 審查退回後修正（W-159 review F-1、N-1，`artifacts/w159-review-2026-10-19.md`）

- **F-1（阻擋）沿用期間會蓋掉線上字幕**：線上字幕（字幕搜尋套用的、來源預設的）走 `router.setExternalSubtitles`，不經 `selectMedia`，所以不會結束沿用；`reselection(carrying:)` 又把選中的線上字幕當成偏離，拉回內嵌軌或關掉。修：`reselection(carrying:)` 一看到選中的是線上字幕（`PlaybackExternalSubtitle.isExternalID`）就回新的 `.online`，`carrySubtitle` 結束沿用並記 `an online subtitle is showing, stopped holding …`；換引擎時只保留**還沒到期**的沿用（到期但因為沒有新清單而沒被清掉的不再延續）。測試 `anOnlineSubtitleShowingEndsTheCarry`（off、語言、CC 三種沿用都回 `.online`）。
- **N-1 暫停時換引擎的上限**：沿用在新引擎開始播放時套用，而換引擎後的起播監看（`watchHandoff`）只等 60 秒；暫停中換引擎、**超過 60 秒**才按播放時，只有等到引擎再送一份字幕清單才會套用，引擎可能不再送，這時沿用不會發生。60 秒內按播放都會沿用。
- 驗證：單元 13 個（含音軌）全過、全量 `swift test`、App build（見 commit）；依審查意見不重跑 Simulator。
