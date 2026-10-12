# IOS-POC-57B-3：咕噜（qist `csp_Gulu`）— js.host 1.4 上的第一個 adapter

> Recovery anchor：Stage 1（W-37，js.host 1.4 九個原語）commit `83a0c584`＋W37-01 測試補強；Stage 2（W-44，本文件）＝`Gulu.js`、Registry 一行、測試、相容包列。設計：`.herdr-synapse/webhtv-dev/artifacts/qist-gulu-native-gate-2026-10-08.md`（snapshot 45fd4e3b，使用者 #127 選方案 A，設計 PASS）。

## 1. 來源

- 設定：dianshi:25、jsm:26，`{"key":"咕噜","name":"咕噜 • APP","type":3,"api":"csp_Gulu","searchable":1,"quickSearch":1,"filterable":1}`，無 `ext`。
- JAR：qist/tvbox `14c12ddb39dc81d5b48f62ecfffa3641ca69e3fa` 的 `jar/spider.jar`，sha256 `72a1f3928eca281d878e44fc57162ff6a1f3ef779a2da05a2b351b241b110d69`（md5 `b6fc17ade72f89a0c9594c4bde5ebf13`＝兩份設定的 pin）。
- 反編譯：jadx 1.5.6 `Gulu.java` 1012 行，sha256 `c41c847fd0b3d9b89bdbe2742345d931a530ab73e214a492e211b70d917a1a1e`（備份 `.herdr-synapse/webhtv-dev/artifacts/gulu-stage2-inputs/`，含 SHA256SUMS.txt）。vod 欄位對照取自同 JAR 的 `merge/c/e.java`（`j`=vod_id、`k`=vod_name、`l`=vod_pic、`o`=vod_remarks、`q`=vod_year、`f`=vod_actor、`i`=vod_director、`g`=vod_area、`h`=vod_content、`e`=type_name、`m`／`n`=play_from／play_url）。

## 2. 移植對照

| 上游（Gulu.java） | `Gulu.js` | 差異與理由 |
|---|---|---|
| `handshake()` :223–301 | `handshake()` | 相同協定：P-256（`ecdhP256Generate`，私鑰不出 native）、hello protobuf zlib 包裝後 AES-256-CBC（key＝32 個 hex 字元的 UTF-8）、HKDF-SHA256（salt＝session id 的 UTF-8、info `v2-session`、32 B）。上游 deflate level 5，原語固定 6；伺服器只解壓，結果相同 |
| `callApi()` :161–221 | `callApi()` | 相同：`{1 ts,2,3,4 device,5 空,6 payload,7 ts}` raw deflate → AES-GCM（nonce 由 native 產生）；回應欄位 2 → open → raw inflate → 欄位 4 |
| `boot()` :126–159 | `bootPayload()`＋`ensure()` | 照送 App／裝置資訊；回應欄位 7 的解析模板**不讀**（設計 §5） |
| `init()` 背景執行緒握手 | `init()` 只產生 device id | 握手延到第一次需要資料時（同上游 `d()`），載入站台不連網 |
| `homeContent()` :847–880 | 同 | 上游先 `d()` 握手；本移植首頁只回固定類別與篩選，不連網（結果相同，載入較快） |
| `homeVideoContent()` :882–893 | 同 | 相同（`(3,66)`、類別 9、取 24 筆） |
| `categoryContent()` :650–683 | 同 | 相同；`pg` 非數字或 ≤0 時用 1（上游負數會送出巨大 varint） |
| `detailContent()` :686–845 | 同 | **只留 http 開頭的集**（設計 §5：前綴 id 要交給 JAR 內建金鑰的第三方解析，不移植）；集名的 `$`、`#` 換空白（同 Bili.js／TuXiaoBei.js，避免切出多餘的集）；非數字 id 直接回空 |
| `playerContent()` :914–983 | 同 | http：m3u8／`m.php` 直接播（parse 0），其他交嗅探（parse 1），帶 Dalvik UA，m3u8 照上游改寫成 2000k／1080p 路徑；前綴 id 回空網址；不加彈幕 |
| `searchContent()` :989–1011 | 同 | 上游回應 ≤200 B 時隔 0.5、1、2 秒重試；runtime 沒有 sleep，本移植只送一次（`shortcut:` 註記）。回應 <200 B 視為無結果（同上游） |
| `PbUtil.decode` :420–459 | `decode()` | 依設計 GULU-A-04：varint 最多 10 bytes，累加前檢查不超過 `2^53−1`；長度越界、varint 未完、未知 wire type 一律整段判畸形回空（上游保留已解析的部分） |

## 3. 測試（`ios/Tests/WebHTVCoreTests/GuluSpiderTests.swift`，`@Suite(.serialized)`）

- 伺服器端在測試內用 CryptoKit（P-256、HKDF、AES-GCM）、CommonCrypto（CBC）、system zlib／Foundation（壓縮）與自己的 protobuf 寫入器實作，不共用 adapter 任何程式；固定私鑰、session id、GCM nonce。
- 回應用 2026-10-08 live 保存的明文 fixture（`list-tv-p1.pb` sha256 `c5fc72ae…3eaf33`、`detail-902056.pb` `3aeee602…77a3`），raw deflate＋base64 內嵌，載入時驗 sha256。
- 8 個測試函式：首頁 12 類＋篩選且不連網；分類（握手標頭、device id、boot 一次、查詢欄位、session 沿用、模板主機從不被請求、21 筆首筆 `902056 兰香如故`）；詳情（只剩 5 條直連線路 `腾讯视频$$$电影天堂$$$暴风资源$$$量子资源$$$非凡资源`、各 47 集、全部 http、欄位對照）；搜尋（21 筆、短回應→空）；播放（m3u8 改寫 parse 0、頁面 parse 1、前綴 id 空網址）；6 種壞回應（CBC padding 0x11、GCM tag、壞 deflate、壞 protobuf、HTTP 500、空 body）都回空或由 runtime 報 `SiteUnreachable(.httpStatus(500))`；varint 邊界（`2^53−1` 成功；`2^53`、`2^53+1`、11 bytes、未完 → 空）；live（`GULU_LIVE=1`，預設略過）。
- 說明：設計 §7 把 parser 層與傳輸層分開；本測試的 parser 斷言是經過模擬加密傳輸送進 adapter 的，比只測 parser 涵蓋更多，不另寫只測 parser 的測試。

## 4. 驗證紀錄

| 項目 | 指令 | 結果 | log（`.herdr-synapse/webhtv-dev/artifacts/w44-logs/`） |
|---|---|---|---|
| Stage 2 proof＋回歸 | `swift test --package-path ios --filter 'GuluSpiderTests\|RuntimeABITests\|theCompatibilityPackGate\|SpiderHostTests\|SpiderPackTests\|RuntimePackManifestTests\|SpiderGoldenTests\|TuXiaoBeiSpiderTests\|FirstAidSpiderTests\|ShortDramaSpiderTests\|<8 個 Stage 1 測試>\|registryClaimsOnlyWhatIsActuallyPorted'` | 125 個通過、0 失敗；live 預設略過 | `w44-tests.log` `a7571630f652a930…` |
| live | `GULU_LIVE=1 swift test --filter liveHandshakeListingDetailAndM3u8`（草稿 worktree，2026-10-12 約 05:58 UTC） | 通過（2.48 s）：真實握手→分類→詳情→m3u8 HTTP 200。草稿與本 commit 的 `Gulu.js` 是同一個 git blob `7491cd7483b4634c9a52a13fe656e3f701f38e47`，所以沒有在本 checkout 重跑 | `w44-live-draft.log` `b43f3b7a68266431…` |
| 相容包 | `python3 -I scripts/spider_pack.py build --out spider-pack --version 2026-10-12.2 --mappings <空 mappings>`；`verify --url spider-pack` | 24 支、0 problems；原 23 個 entry 物件與順序不變；Gulu entry `minHostApi 4`；pack 的 `Gulu.js` blob 等於內建 | `w44-pack-build.log` `99a25f7540bc63b3…`、`w44-pack-checks.log` `169a140f83f50fdb…` |
| Ponytail review | — | Ship；唯一建議（文件測試數 9→8）已修正 | — |

## 5. 回滾

- `git revert <Stage 2 commit>`：移除 `Gulu.js`、Registry 的 `Gulu`、測試、`DEFAULT_ORIGINS` 列與相容包裡的 Gulu。Stage 1 原語保留（只新增、不改既有行為）。1.4 隨 IPA 發出前，Stage 1 也可整個 revert（見設計 §7 限制）。

## 6. 未驗證

- App GUI、Simulator、真機播放；前綴線路（刻意不做）；live 只驗了一部片的一個 m3u8 回 200，沒有驗子清單與 TS 分段。
