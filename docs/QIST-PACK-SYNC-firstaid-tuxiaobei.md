# QIST-PACK-SYNC：FirstAid、TuXiaoBei 本機相容包同步（W-7）

> Recovery anchor（2026-10-12 13:42 CST）：已完成；`spider-pack/` 為 `2026-10-12.1`（23 支），`verify` 0 problems，以 guard `QIST-PACK-SYNC` commit `--no-tag`。沒有發布、沒有 push。下一步：Reviewer 檢查來源與相容性。

## 目標與範圍

- 目標：把已核准並整合到 `ios-poc` 的 `FirstAid`（IOS-POC-57B-1）與 `TuXiaoBei`（IOS-POC-57B-2）加進本機相容包，manifest 帶完整來源資訊；既有 21 個 entry 不變。
- 工單：`.herdr-synapse/webhtv-dev/artifacts/qist-pack-preflight-2026-10-08.md` 第 3 節（W-12／W-22 修訂版）。
- 範圍（guard `QIST-PACK-SYNC`）：`spider-pack/`、`scripts/spider_pack.py`、本文件。不改播放器、host ABI、App 內建腳本；不發布、不 push、不 tag。

## 步驟與結果

| 步驟 | 內容 | 結果 |
|---|---|---|
| 1 依賴 | W-1 merge `F=7ec799dc6cdab7d2b67620c5e089eb7097339ceb`、W-2 `T=18e758d5762b21c14bc040bcecaba8a3246b8e3b`；`git merge-base --is-ancestor` F、T 對 HEAD `2e580b72e9414db893611d08bcf32e641cd28d3b` | 兩個都是祖先；`git status --porcelain -- ios/Sources/WebHTVCore/Resources/Spiders spider-pack scripts/spider_pack.py` 為空 |
| 3 entry host 門檻 | 掃 HEAD 的兩支腳本有沒有用到 js.host 1.3／1.4 功能（`rsaEncrypt`、`rsaDecrypt`、`bytes`、`aesEncrypt` hex、`bodyBase64`、`responseType`，以及 1.4 的九個原語） | 都沒有。FirstAid 只用 `host.get`、`pdfa`、`pdfh`、`urljoin`、`result.*`；TuXiaoBei 只用 `host.get`、`parseJSON`、`result.*`（都在 base host API 2 內）。判定：兩個 entry **不帶** `minHostApi`（繼承頂層 2） |
| 4 來源 | `DEFAULT_ORIGINS` 加 `FirstAid`：`spider.jar` `391065e92e19437e73109e9d3c79feff6676baa8ed4fec3cdb04f4e7cca77314`（`docs/IOS-POC-57B-1-firstaid.md:8`）；`TuXiaoBei`：`spider.jar` `72a1f3928eca281d878e44fc57162ff6a1f3ef779a2da05a2b351b241b110d69`（`docs/IOS-POC-57B-2-tu-xiao-bei.md:23`，qist/tvbox `14c12ddb39dc81d5b48f62ecfffa3641ca69e3fa`） | 工具其他部分不動 |
| 5 build | 原版號 `2026-10-08.2` 不是今天 → `2026-10-12.1`；`python3 -I scripts/spider_pack.py build --out spider-pack --version 2026-10-12.1 --mappings <scratchpad>/empty-mappings.json`（內容 `{"mappings": []}`） | 退出碼 0；`23 scripts -> spider-pack/manifest.json (version 2026-10-12.1, minHostApi 2)`；兩個新 entry 都沒有 `minHostApi`，與步驟 3 相同 |
| 6 檔案範圍 | `git status --porcelain -- spider-pack`；`git ls-files --others --exclude-standard -- spider-pack` | 正好是 ` M spider-pack/manifest.json`、`?? spider-pack/scripts/FirstAid.js`、`?? spider-pack/scripts/TuXiaoBei.js`；未追蹤只有這兩支 |
| 7 來源 bytes | `git hash-object` 對 `git rev-parse` | FirstAid：pack＝HEAD＝F＝`b09fa386c0ae7990bf45c247b8821750f70fe99b`（sha256 `ab0646a5…e8ff`）；TuXiaoBei：pack＝HEAD＝T＝`33181b38fcf67f2264ed06c7f5025f6e201e0ec9`（sha256 `57116b5b…22d5`） |
| 8 舊 entry 保護 | `python3 -I` 比對 `git show HEAD:spider-pack/manifest.json` 與新 manifest | 原 21 個 entry 的整個 JSON 物件相同、順序不變；`schema`、頂層 `minHostApi`、`mappings: []` 不變；只多 FirstAid、TuXiaoBei，只有 `version` 改變 |
| 9 verify | `python3 -I scripts/spider_pack.py verify --url spider-pack` 一次 | `pack 2026-10-12.1: 23 scripts, 0 mapping(s), 0 problem(s)`。`verify` 不檢查 entry `minHostApi`，那一項由步驟 3、5 確認 |

- Ponytail review：Ship（沒有 finding）。
- 兩個 entry 都叫 `spider.jar`，但 digest 不同（兩次讀的是不同版本的 qist `spider.jar`）。之後用同一個 `spider.jar` 跑 `fingerprint`，其中一支一定顯示 CHANGED；這是正確提示（該支的來源 JAR 確實換過），不是工具錯誤。本工單依 preflight 不跑 `fingerprint`。

## 回滾

- `git revert <本 commit>`：manifest 回到 `2026-10-08.2`、21 支，兩支新腳本從 `spider-pack/scripts/` 移除。App 內建腳本不受影響（相容包只是覆蓋）。沒有發布，不需要遠端回滾。
