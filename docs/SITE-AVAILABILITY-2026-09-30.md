# 設定檔站台可用性：`wang-movie.json` 與 `wang-sex.json`（2026-09-30）

使用者 2026-09-30 要求「測試 movie.json 跟 sex.json，查看裡面有多少資源站台是可用跟不可用」，並要逐站列出。repo `st7833232/recha` 沒有 `movie.json`、`sex.json`（404），只有 `wang-movie.json`、`wang-sex.json`，所以測這兩份。

## 方法

| | |
|---|---|
| 時間與網路 | 2026-09-30 約 13:35～14:05 CST，Mac 走使用者的個人熱點（公司網路封鎖 gitlab.com，見 IOS-POC-37 第 15.4 節） |
| 程式 | `ios-poc` 含 IOS-POC-37.3.1（＝已發布的 `0.1.38 (39)` 的內容） |
| 設定檔 | `wang-movie.json` 169 站（SHA-256 `a567f33f6b29d58b…`）、`wang-sex.json` 266 站（`b87f15d715397b20…`），都從 GitLab 當下抓 |
| 非 Python 站 | `swift test --filter sweepsEveryDrivableSource`（`SWEEP_CONFIG`／`SWEEP_BASE` 指向該設定檔）：走 App 同一條 `SourceClient` 路徑，首頁 → 第一部片（首頁沒有片時改用第一個分類）→ 詳情 → 第一集 → 播放網址 → `MediaProbe` 讀前幾個位元組。8 站同時跑、每站上限 90 秒；兩份設定同時跑（各約 2 分鐘） |
| Python 站 | iPhone 17 Pro 模擬器 DEBUG 的 `PythonLiveCheck.survey()`：load → init → home → category → detail → search → player → probe(media)，每階段上限 45 秒、各試前幾個候選。`wang-movie.json` 用 13:35 那一輪（IOS-POC-37 第 15.4 節，設定檔與現在相同）；`wang-sex.json` 是 13:48 另跑一輪（App 設定暫時指向 sex，跑完已還原） |
| 「可用」的定義 | **讀到影片位元組**才算。只解析出網址、但網址是網頁／404／其他內容，都算不可用 |

**限制**：非 Python 站只試第一部片、第一集；標為不可用的站，其他片或其他線路仍可能播得動。網站狀態會變（同一站兩輪之間可能不同，例如 IOS-POC-37 第 14.4、15.4 節的界界、cqzuoer）。模擬器與 macOS 測試不等於真機。

## 結果

| 設定檔 | 總站數 | 可用 | 不可用 | App 不提供 |
|---|---:|---:|---:|---:|
| `wang-movie.json` | 169 | **44**（Python 20、其他 24） | 67 | 58 |
| `wang-sex.json` | 266 | **54**（Python 25、其他 29） | 203 | 9 |

「App 不提供」：iOS 沒有這個來源的實作（Android JAR 裡的 `csp_*` 類別未移植，或不支援的來源型態），在 App 的來源清單裡看不到。

### 抽查：不可用是網站還是 iOS

- `wang-sex.json` 的 104 個 XBPQ 站全部「首頁與分類都沒有片」。抽查 4 站的網站本身：麻豆（gcmd.cc）200、頁面有 20 筆詳情連結；SEAJAV 200、60 張封面；野鸡資源 200、16 筆；AG動漫（`wang-movie.json`）500。**網站有正常回片單而 iOS 取到 0 部**，所以這一群大多是 iOS 移植的 XBPQ 解析不了這些站的規則寫法（同一個 XBPQ 在 `wang-movie.json` 的「果果短剧」可以播）。未逐站確認。
- XYQHiker：170av 的網域已連不上（規則檔註明已搬到 190av.cc）；18AV 網站正常，iOS 取得到首頁 60 部片但詳情頁沒有集數——原因未查。
- 「解析得到播放網址，但抓到的不是影片」有兩種（依 sweep 記下的網址）：`/play/<id>`、`/share/<id>` 這種**網頁播放器**網址，不是影片檔（`wang-movie.json` 14 站中約 6 站、`wang-sex.json` 9 站中 2 站）；其餘是 `.m3u8` 或影片檔網址但讀到的不是影片（CDN 拒絕、網址過期或錯誤頁；例如 `wang-sex.json` 的 type-0 站給的是 2022 年的影片路徑）。


## `wang-movie.json`：依結果分組

- **可用（44）**
  🥇｜三秋｜普畫◎秒播、🏆｜王子｜高畫 + 都採集、🏆｜靈虎｜高清◎秒播、🎖︎｜bilbil合集｜、🎖︎｜bili漫畫屋、🎖︎｜bili聽書趣、🎖︎｜bili靜聽歌、🎯荐片、🎡｜去看动漫、8Movie、可可影視、🇹🇼｜YouTube｜PY、🎡｜MiFun、🎡｜元纓动漫、🎡｜咕咕动漫、🏆｜Uvod｜備用、🏆｜七猫｜高清◎秒播(浮水印廣告)、🏆｜耐看｜高清◎秒播、🏆｜鐵牌｜藍光、📺｜喜福短剧、📺｜悟圣短剧、📺｜星芽短剧｜瀟灑、📺｜短剧聚合、🥇｜茶杯狐｜普清◎秒播(有時候線路失敗)、🥇｜農民｜秒播(只有線路2能看)、🥇｜金牌系列-jiabaide、🥇｜金牌系列-zjuys、🥇｜金牌系列-愛電影、🥇｜金牌系列-界界、📺｜紅果短剧｜瀟灑、🎡｜巴士动漫、🥇｜农民｜高清、🎡｜魔都动漫、🧲｜夢想網頁版｜嚴禁外流、🧲｜360｜高清、🧲｜天涯｜高清◎順播、🧲｜艾旦｜高清(浮水印廣告+圖壞)、🧲｜菠菜｜高清、🧲｜豆瓣｜高清◎順播(浮水印廣告)、🧲｜量子｜高清(賭城廣告+成人)、🧲｜非凡｜高清◎速播(賭城廣告+成人)、🧲｜魔都｜高清(浮水印廣告+成人動畫)、🏆｜愛瓜｜PHP、🧲｜楓林｜高清(浮水印廣告)

- **不可用：首頁與第一個分類都沒有片（15）**
  🎡｜双星动漫、🏆｜劇圈｜高畫 + 開頭被剪掉、🥇｜橙子丨高清◎秒播、🥇｜聽心｜高清◎秒播、🎡｜方舟动漫、🏆｜不錯｜高畫 + 普通、🥇｜獵豹｜高清◎秒播、🏆｜愛影｜5倍◎無廣、🏆｜愛盈｜高清◎秒播、🏆｜星河｜4K、📱｜愛影｜普畫 + APP、📱｜懷桑｜普畫 + APP、🥇｜咕噜｜高清◎秒播、🏆｜無水｜(T4)、📻｜听友｜有聲(道長)

- **不可用：網站有回應但取不到片或播不了（14）**
  ？｜麒麟｜3倍◎無廣、🎖︎｜bili看電影、🎡｜櫻花動漫、🎡｜花子｜1080P、🎡｜西瓜、🏆｜八天｜高清(浮水印廣告)、🏆｜永樂｜高清◎秒播、🏆｜真狼｜普畫 + 官源採集、🏆｜蛋塔｜高清、📱｜FreeOK｜不怎麼樣、🥇悟空｜1080P(廣告多)、🥇｜七味.py、🥇｜大眾｜1080P、🥇｜映像｜普畫◎秒播

- **不可用：解析得到播放網址，但抓到的不是影片（14）**
  🧲｜優質｜高清、🧲｜優酷｜高清(浮水印廣告)、🧲｜光速｜高清◎慢播(浮水印廣告)、🧲｜如意｜高清(各種廣告)、🧲｜如意｜高清(賭城廣告+成人)、🧲｜无忧｜高清(賭城廣告+成人)、🧲｜極速｜高清(浮水印廣告)、🧲｜索尼｜高清(浮水印廣告)、🧲｜红牛｜高清(浮水印廣告)、🧲｜虎牙｜高清(浮水印廣告)、🧲｜豪華｜高清(浮水印廣告)、🧲｜順播｜高清(浮水印廣告)、⚽｜88｜體育、🧲｜采集集合｜PHP

- **不可用：XBPQ 規則取不到片（6）**
  ️🥇｜歐視｜高清、🎡｜AG動漫、🎡｜天天動漫、🥇｜歐吉｜高清、🥇｜永樂｜高清、🥇｜永樂｜高清

- **不可用：網站連不上或逾時（5）**
  🏆｜銅牌｜高清、📱｜八天｜APP、📱｜哇哇｜APP、🥇｜山楂｜不怎樣 + py、🥇｜金牌系列-cqzuoer

- **不可用：腳本跨來源或明文 HTTP（政策拒絕）（4）**
  ⚽｜咖啡｜體育、📡｜虎牙｜Live、📺｜星芽短劇、🥇｜木兮｜只能看高清

- **不可用：有集數，解析不出播放網址（3）**
  📱｜雲朵｜普畫 + APP、🎡｜七色番动漫、🎡｜動漫巴士

- **不可用：連線錯誤、憑證錯誤或逾時（3）**
  🏆｜步步｜4K、🧲｜無盡｜高清(浮水印廣告)、🧲｜飘零｜高清(浮水印廣告)

- **不可用：有片單，詳情頁沒有集數（2）**
  🎡｜爱动漫、🎡｜爱动漫

- **不可用：腳本執行錯誤（1）**
  🎡｜曼波动漫

- **App 不提供：Android JAR 類別，iOS 未移植（58）**
  🏆｜愛瓜｜嗷源、🏆｜愛壹帆｜、🎡｜喵嗚动漫、🏆｜天堂｜高清◎秒播、🏆｜橘子｜？、🏆｜苹果｜秒播、🥇｜薯條｜高清◎秒播、🎡｜漫国动漫、🥇｜大師兄｜高清◎秒播、🥇｜大师兄｜秒播、🥇｜大師｜、🥇①／菠菜专线、🥇②／菠菜专线、🥇③／菠菜专线、🥇④／菠菜专线、🥇⑤／菠菜专线、🥇⑥／菠菜专线、🥇⑦／菠菜专线、🥇⑧／菠菜专线、🥇⑨／菠菜专线、📱｜一起｜畫質爛 + APP、🥇｜奴娜丨高清◎秒播(d線)、🏆｜奥特｜多线、📺｜拜拜短剧、🏆｜哔嘀｜2K、🏆｜哔嘀｜2K、🏆｜比特｜、🇹🇼｜熱播排行榜｜可選站、🇹🇼｜熱播排行榜｜自動切換、🏆｜獨播庫｜、🎡｜番薯、📱｜飛魚｜很難形容、⚽｜瓜子｜體育、📺｜好看短剧、📺｜好看短剧｜瀟灑、📺｜河马短剧｜瀟灑、📺｜嗷嗚漫劇、📺｜嗷嗚短劇、🏆｜韓圈｜高畫 + 有點慢、🏆｜韓劇｜高清、🏆｜金牌｜高清◎秒播、🏆｜金牌｜高清、🏆｜文采｜秒播、🏆｜異界｜高清、🎡｜喵呜动漫｜瀟灑、🎡｜魔都动漫｜瀟灑、🏆｜糯米｜秒播、🥇｜歐樂｜(賭城廣告)、🥇｜山楂｜瀟灑、📺｜七猫短剧｜瀟灑、📺｜七猫短剧、🏆｜奶酪｜秒播、🏆｜Uvod｜藍光、📺｜围观短剧｜瀟灑、🥇｜農民｜無廣、📺｜星星短剧、🏆｜銀牌｜高清、🏆｜優影｜高清


## `wang-sex.json`：依結果分組

- **可用（54）**
  🔞UAA(點選點播才有東西)、🔞麻豆(js)、⏭｜MissAv(沐辰)｜PYTHON、⏭｜Pornhub(new)｜PYTHON、⏭｜Pornhub(嗷嗚)｜PYTHON、⏭｜xvideos｜PYTHON、⏭｜好色(恰逢)｜PYTHON、⏭｜愛豆AV｜PYTHON、⏭｜禁片天堂(恰逢)｜PYTHON、⏭｜黄豆短剧｜PYTHON、✨花都影视(关梯)✨、✨黄色仓库动态版✨、🔞8X8X.py、🔞91porn.py、🔞EPORNER.py、🔞Jable.py、🔞Pornhub.py、🔞TOPTV.py、🔞Xvideos.py、🔞xhamster.py、🔞久久視頻.py、🔞九个区.py、🔞咪TV.py、🔞怦然心动.py、🔞撸一天.py、🔞香肠派对.py、🔞麻豆社.py、🔞Boba、🔞大地资源、🔞大地采集、🔞黄AV、🔞黄AV资源、️🔞乐播采集、🔞155专场、🔞CK资源、🔞lovedan艾旦、🔞奥斯卡、🔞奥斯卡资源、🔞奶香资源、🔞森林资源、🔞湿乐园、🔞滴滴、🔞玉兔资源、🔞玉兔资源、🔞番号资源、🔞精东资源、🔞精品、🔞老色逼、🔞老色逼资源(采集)、🔞艾蛋資源、🔞辣椒、🔞送AV采集、🔞鲨鱼、🔞鲨鱼资源

- **不可用：XBPQ 規則取不到片（104）**
  🇹🇼【老王成人專區】🇹🇼、🔞 AVMobTV、🔞13AV.COM、🔞13AV.ICU、🔞18XXX、🔞18j、🔞55视频、🔞83视频、🔞941c、🔞AV.GL、🔞AV小次郎、🔞AV帝国、🔞AV影视、🔞Airav、🔞GDD视频、🔞KISSAV、🔞KISSAV(女优)、🔞KISSAV(标签)、🔞SAOO、🔞SEAJAV(聚合)、🔞TaiAv2、🔞sexBJcam、🔞一个纯粹的x站、🔞一区、🔞七色谷、🔞三区、🔞亚瑟影库、🔞今晚打手槍、🔞传媒二区、🔞偷拍自拍、🔞公子别走、🔞初の体验、🔞四区、🔞夜夜新郎、🔞天堂岛、🔞天天、🔞天美、🔞女优色库、🔞妻妹(點選點播才有東西)、🔞婶婶(點選點播才有東西)、🔞小姨子、🔞小幺女、🔞弟弟、🔞微密猫(點選點播才有東西)、🔞成人重口、🔞成鸡思汉、🔞我爱AV、🔞我爱AV社区、🔞手鸡助手、🔞文件夹、🔞新香蕉国产传媒、🔞新香蕉超清资源〔xBPQ〕、🔞旺仔小乔、🔞暗网(點選點播才有東西)、🔞果冻、🔞果冻破解、🔞樱樱女子、🔞比卡(無圖)、🔞比卡比卡、🔞水果派、🔞流氓兔、🔞淘精岁月、🔞游击队、🔞溏心次元、🔞猛男日妓、🔞疯猫av、🔞癢癢、🔞百灵鸟在线、🔞百香草、🔞看AV、🔞神社影视、🔞窜天猴、🔞精工厂、🔞纤纤倫理、🔞绝美视频、🔞美人吹箫、🔞肉視頻(點選點播才有東西)、🔞自排偷拍、🔞色岛、🔞色花堂、🔞花影视(點選點播才有東西)、🔞蓝金鱼AV、🔞蜜桃屯、🔞蜜桃影视、🔞醉奶吧、🔞醉奶吧、🔞野鸡資源、🔞金陵撸铁汉、🔞顶级网曝、🔞风流、🔞香蕉AV解说、🔞香蕉中文资源、🔞香蕉久久热、🔞香蕉废柴网、🔞骏马、🔞高清小黄片、🔞高清黑料3、🔞高端外泄、🔞魔法少女1、🔞魔法少女2、🔞魔法少女3、🔞魔法少女4、🔞麻玉、🔞黃色都市

- **不可用：XYQHiker 規則取不到片（30）**
  🔞170av、🔞444咖啡(點選點播才有東西)、🔞ACG漫画网(XYQHiker)、🔞ACG漫画网(點選點播才有東西)、🔞Hanime1、🔞MOTV、🔞P影院、🔞Tktube、🔞Xtoons动漫(XYQHiker)、🔞Xtoons动漫(點選點播才有東西)、🔞Youjizz、🔞playav、🔞sexsex、🔞xHamster、🔞中国性味、🔞丽丽AV(點選點播才有東西)、🔞亚洲色吧(點選點播才有東西)、🔞台湾kiss、🔞台湾kiss、🔞小丑撸、🔞有爱爱uaa(點選點播才有東西)、🔞朱古力、🔞杏吧视频、🔞热骚、🔞直播1、🔞直播2、🔞直播大全、🔞紫色成人、🔞色库TV、🔞酷爱成人网

- **不可用：有片單，詳情頁沒有集數（29）**
  🔞色最色(點選點播才有東西)、🔞18AV、🔞300分类、🔞300分类、🔞AVbebe(XYQHiker)、🔞AVbebe(點選點播才有東西)、🔞AirAV(點選點播才有東西)、🔞HOHOJ、🔞IXXXJ、🔞KANAV、🔞OWOAV、🔞PPP、🔞Qinav、🔞ThisAV、🔞Ujizzcn、🔞bongacams直播(點選點播才有東西)、🔞jiedmAV(XYQHiker)、🔞jiedmAV(點選點播才有東西)、🔞xgroovy、🔞亚色影库、🔞亞洲情色網、🔞动漫PRO(XYQHiker)、🔞动漫PRO(點選點播才有東西)、🔞好色TV、🔞小嫂子、🔞正妹AV(點選點播才有東西)、🔞鲨鱼av、🔞黄色仓库123、🔞黄色仓库啦

- **不可用：連線錯誤、憑證錯誤或逾時（15）**
  🔞博天堂、🔞富二代、👖TG频道@stymei丨香蕉丨12852部片、🔞998资源、🔞AIvin、🔞JKUN、🔞Sexnguon、🔞丝袜资源、🔞优异资源、🔞秀人、🔞老鸨资源、🔞色猫资源、🔞葡萄、🔞蜜桃社、🔞黄瓜

- **不可用：解析得到播放網址，但抓到的不是影片（9）**
  🔞最爱扒裤衩、🔞开心果、🔞淫水机资源、🔞白嫖资源、🔞美少女、🔞香奶儿资源、🔞 成人频道[ikun](點選點播才有東西)、🔞 成人频道[光速](點選點播才有東西)、🔞 成人频道[速播](點選點播才有東西)

- **不可用：網站有回應但取不到片或播不了（6）**
  ⏭｜py_stripchat、⏭｜射我裡面｜PYTHON、✨推特APP✨、🔞Javmenu、🔞VHUB.py、🔞洋馬

- **不可用：有集數，解析不出播放網址（3）**
  🔞一点视频(點選點播才有東西)、🔞爱爱影院、🔞黑料不打烊-z

- **不可用：腳本執行錯誤（3）**
  ⏭｜小淫书(嗷嗚)｜PYTHON、🔞色色直播、🔞蹦迪(點選點播才有東西)

- **不可用：網站連不上或逾時（3）**
  🔞4K歐美、🔞FullHD.py、🔞香蕉

- **不可用：首頁與第一個分類都沒有片（1）**
  🔞色猫(FQ)

- **App 不提供：Android JAR 類別，iOS 未移植（6）**
  🔞SupJav、🔞XOJAV、🔞Jable、🔞Jable(海外)、🔞迷妹、最色

- **App 不提供：App 不支援這種來源（3）**
  ️🔞女優、️🔞番號、️🔞薇薇珊


## 逐站表

### wang-movie.json（169 站）

| 結果 | 站數 |
|---|---:|
| 可用 | 44 |
| 不可用 | 67 |
| App 不提供 | 58 |

| # | 站名 | key | 類型 | 結果 | 不可用的原因 |
|---:|---|---|---|---|---|
| 1 | 🥇｜三秋｜普畫◎秒播 | 三秋影视 | App3Q | 可用 |  |
| 2 | 🏆｜王子｜高畫 + 都採集 | 王子 | AppGet | 可用 |  |
| 3 | 🏆｜靈虎｜高清◎秒播 | 灵虎 | AppGet | 可用 |  |
| 4 | 🎖︎｜bilbil合集｜ | bili | Bili | 可用 |  |
| 5 | 🎖︎｜bili漫畫屋 | bilimanhua | Bili | 可用 |  |
| 6 | 🎖︎｜bili聽書趣 | bilitingshu | Bili | 可用 |  |
| 7 | 🎖︎｜bili靜聽歌 | biligequ | Bili | 可用 |  |
| 8 | 🎯荐片 | 薦片 | JPianAmns | 可用 |  |
| 9 | 🎡｜去看动漫 | drpy_js_去看吧 | JS/drpy | 可用 |  |
| 10 | 8Movie | 8movie | Python | 可用 |  |
| 11 | 可可影視 | kkys20 | Python | 可用 |  |
| 12 | 🇹🇼｜YouTube｜PY | YouTube | Python | 可用 |  |
| 13 | 🎡｜MiFun | MiFun | Python | 可用 |  |
| 14 | 🎡｜元纓动漫 | py_元咲_APP | Python | 可用 |  |
| 15 | 🎡｜咕咕动漫 | py_咕咕_APP | Python | 可用 |  |
| 16 | 🏆｜Uvod｜備用 | Uvod | Python | 可用 |  |
| 17 | 🏆｜七猫｜高清◎秒播(浮水印廣告) | qmvm | Python | 可用 |  |
| 18 | 🏆｜耐看｜高清◎秒播 | py_耐看点播 | Python | 可用 |  |
| 19 | 🏆｜鐵牌｜藍光 | py_aidianying | Python | 可用 |  |
| 20 | 📺｜喜福短剧 | py_喜福短剧 | Python | 可用 |  |
| 21 | 📺｜悟圣短剧 | py_悟圣短剧 | Python | 可用 |  |
| 22 | 📺｜星芽短剧｜瀟灑 | 星芽短剧 | Python | 可用 |  |
| 23 | 📺｜短剧聚合 | djjh | Python | 可用 |  |
| 24 | 🥇｜茶杯狐｜普清◎秒播(有時候線路失敗) | cbh | Python | 可用 |  |
| 25 | 🥇｜農民｜秒播(只有線路2能看) | nmvm | Python | 可用 |  |
| 26 | 🥇｜金牌系列-jiabaide | py_jiabaide | Python | 可用 |  |
| 27 | 🥇｜金牌系列-zjuys | py_zjuys.py | Python | 可用 |  |
| 28 | 🥇｜金牌系列-愛電影 | py_愛電影.py | Python | 可用 |  |
| 29 | 🥇｜金牌系列-界界 | py_文才 | Python | 可用 |  |
| 30 | 📺｜紅果短剧｜瀟灑 | 果果短剧 | XBPQ | 可用 |  |
| 31 | 🎡｜巴士动漫 | 巴士动漫 | XYQHiker | 可用 |  |
| 32 | 🥇｜农民｜高清 | csp_Wwys | XYQHiker | 可用 |  |
| 33 | 🎡｜魔都动漫 | 魔都 | type0 | 可用 |  |
| 34 | 🧲｜夢想網頁版｜嚴禁外流 | vod_蜜雪 | type0 | 可用 |  |
| 35 | 🧲｜360｜高清 | vod_360 | type1 | 可用 |  |
| 36 | 🧲｜天涯｜高清◎順播 | vod_天涯 | type1 | 可用 |  |
| 37 | 🧲｜艾旦｜高清(浮水印廣告+圖壞) | vod_艾旦 | type1 | 可用 |  |
| 38 | 🧲｜菠菜｜高清 | tufun采集 | type1 | 可用 |  |
| 39 | 🧲｜豆瓣｜高清◎順播(浮水印廣告) | vod_豆瓣 | type1 | 可用 |  |
| 40 | 🧲｜量子｜高清(賭城廣告+成人) | 量子采集资源 | type1 | 可用 |  |
| 41 | 🧲｜非凡｜高清◎速播(賭城廣告+成人) | 非凡采集资源 | type1 | 可用 |  |
| 42 | 🧲｜魔都｜高清(浮水印廣告+成人動畫) | vod_魔都 | type1 | 可用 |  |
| 43 | 🏆｜愛瓜｜PHP | 爱瓜TV | type4 | 可用 |  |
| 44 | 🧲｜楓林｜高清(浮水印廣告) | drpyS_枫林影视 | type4 | 可用 |  |
| 45 | 📱｜雲朵｜普畫 + APP | 云朵影视 | App3Q | 不可用 | 有集數，解析不出播放網址 |
| 46 | 🎡｜双星动漫 | 双星99 | App99 | 不可用 | 首頁與第一個分類都沒有片 |
| 47 | 🏆｜劇圈｜高畫 + 開頭被剪掉 | 剧圈99 | App99 | 不可用 | 首頁與第一個分類都沒有片 |
| 48 | 🥇｜橙子丨高清◎秒播 | 橙子99 | App99 | 不可用 | 首頁與第一個分類都沒有片 |
| 49 | 🥇｜聽心｜高清◎秒播 | 听心99 | App99 | 不可用 | 首頁與第一個分類都沒有片 |
| 50 | 🎡｜方舟动漫 | 方舟动漫 | AppGet | 不可用 | 首頁與第一個分類都沒有片 |
| 51 | 🏆｜不錯｜高畫 + 普通 | 不戳 | AppGet | 不可用 | 首頁與第一個分類都沒有片 |
| 52 | 🥇｜獵豹｜高清◎秒播 | 猎豹 | AppGet | 不可用 | 首頁與第一個分類都沒有片 |
| 53 | 🏆｜愛影｜5倍◎無廣 | csp_AppQi_爱影 | AppQi | 不可用 | 首頁與第一個分類都沒有片 |
| 54 | 🏆｜愛盈｜高清◎秒播 | 爱影 | AppQi | 不可用 | 首頁與第一個分類都沒有片 |
| 55 | 🏆｜星河｜4K | 星河 | AppQi | 不可用 | 首頁與第一個分類都沒有片 |
| 56 | 📱｜愛影｜普畫 + APP | 爱影 | AppQi | 不可用 | 首頁與第一個分類都沒有片 |
| 57 | 📱｜懷桑｜普畫 + APP | 怀桑 | AppQi | 不可用 | 首頁與第一個分類都沒有片 |
| 58 | 🥇｜咕噜｜高清◎秒播 | gulu | AppQi | 不可用 | 首頁與第一個分類都沒有片 |
| 59 | 🎡｜七色番动漫 | hipy_js_七色番[漫] | JS/drpy | 不可用 | 有集數，解析不出播放網址 |
| 60 | 🎡｜爱动漫 | drpy_js_爱弹幕 | JS/drpy | 不可用 | 有片單，詳情頁沒有集數 |
| 61 | 🎡｜爱动漫 | hipy_js_爱弹幕[漫] | JS/drpy | 不可用 | 有片單，詳情頁沒有集數 |
| 62 | 🏆｜步步｜4K | bubutv | JS/drpy | 不可用 | 錯誤：drpy could not fetch 4k.js: HTTP 404 |
| 63 | ⚽｜咖啡｜體育 | 咖啡 | Python | 不可用 | 停在 — 之後：policy: rejected(reference: "http://itv666.cc/星河传媒/py/kafei2.py", reason: "drpy refuses a  |
| 64 | ？｜麒麟｜3倍◎無廣 | py_麒麟影视 | Python | 不可用 | 停在 player 之後：content: the resolved URL served unknown: https://v14.wsyzym3u8.com/202609/23/4iJZvGas1p27 |
| 65 | 🎖︎｜bili看電影 | py_bi星河影视ili | Python | 不可用 | 停在 player 之後：content: the resolved URL served unknown: http://127.0.0.1:9978/proxy?do=py&type=mpd&aid=2 |
| 66 | 🎡｜曼波动漫 | py_曼波_APP | Python | 不可用 | 停在 load 之後：site/content(unexpected answer): scriptFailed("requests.exceptions.JSONDecodeError: Expect |
| 67 | 🎡｜櫻花動漫 | py_樱花动漫 | Python | 不可用 | 停在 home 之後：content: no category returned items |
| 68 | 🎡｜花子｜1080P | 花子 | Python | 不可用 | 停在 home 之後：content: no category returned items |
| 69 | 🎡｜西瓜 | py_西瓜卡通 | Python | 不可用 | 停在 player 之後：content(parse=1): parse=1 page yielded no stream to the sniffer: https://cn1.xgcartoon.com |
| 70 | 🏆｜八天｜高清(浮水印廣告) | 8tdy | Python | 不可用 | 停在 home 之後：content: no category returned items |
| 71 | 🏆｜永樂｜高清◎秒播 | py_永乐视频 | Python | 不可用 | 停在 home 之後：content: no category returned items |
| 72 | 🏆｜真狼｜普畫 + 官源採集 | 真狼影视.py | Python | 不可用 | 停在 player 之後：content(parse=1): parse=1 page yielded no stream to the sniffer: http://www.iqiyi.com/v_jk |
| 73 | 🏆｜蛋塔｜高清 | dttv | Python | 不可用 | 停在 home 之後：content: no category returned items |
| 74 | 🏆｜銅牌｜高清 | 皮皮虾 | Python | 不可用 | 停在 init 之後：site/network: scriptFailed("requests.exceptions.ConnectionError: HTTPConnectionPool(host=\ |
| 75 | 📡｜虎牙｜Live | 虎牙 | Python | 不可用 | 停在 — 之後：policy: rejected(reference: "http://itv666.cc/星河传媒/py/网络直播.py", reason: "drpy refuses a no |
| 76 | 📱｜FreeOK｜不怎麼樣 | FreeOK.py | Python | 不可用 | 停在 home 之後：content: no category returned items |
| 77 | 📱｜八天｜APP | py_八天_APP | Python | 不可用 | 停在 load 之後：site/network: scriptFailed("requests.exceptions.ConnectionError: HTTPSConnectionPool(host= |
| 78 | 📱｜哇哇｜APP | py_哇哇APP | Python | 不可用 | 停在 load 之後：site/network: scriptFailed("requests.exceptions.ReadTimeout: HTTPSConnectionPool(host=\'gi |
| 79 | 📺｜星芽短劇 | 星芽短剧 | Python | 不可用 | 停在 — 之後：policy: rejected(reference: "https://git.yylx.win/raw.githubusercontent.com/PizazzGY/NewTV |
| 80 | 🥇悟空｜1080P(廣告多) | 悟空 | Python | 不可用 | 停在 home 之後：content: no category returned items |
| 81 | 🥇｜七味.py | qw | Python | 不可用 | 停在 player 之後：content: the resolved URL served unknown: https://vd2.bdstatic.com/mda-nj5kxa8kr7wgq6ie/sc |
| 82 | 🥇｜大眾｜1080P | 大眾 | Python | 不可用 | 停在 home 之後：content: no category returned items |
| 83 | 🥇｜山楂｜不怎樣 + py | 山楂 | Python | 不可用 | 停在 init 之後：site/network: scriptFailed("requests.exceptions.ConnectTimeout: HTTPConnectionPool(host=\' |
| 84 | 🥇｜映像｜普畫◎秒播 | ysxq | Python | 不可用 | 停在 home 之後：content: no category returned items |
| 85 | 🥇｜木兮｜只能看高清 | 4kmx | Python | 不可用 | 停在 — 之後：policy: rejected(reference: "http://itv666.cc/pyplugin/木兮.py", reason: "drpy refuses a non |
| 86 | 🥇｜金牌系列-cqzuoer | py_cqzuoer | Python | 不可用 | 停在 init 之後：site/network: scriptFailed("requests.exceptions.ReadTimeout: HTTPSConnectionPool(host=\'cq |
| 87 | ️🥇｜歐視｜高清 | csp_If101 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 88 | 🎡｜AG動漫 | csp_AG動漫 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 89 | 🎡｜天天動漫 | csp_天天動漫 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 90 | 🥇｜歐吉｜高清 | csp_歐樂影院ORG | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 91 | 🥇｜永樂｜高清 | csp_YLSP | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 92 | 🥇｜永樂｜高清 | 永乐影视 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 93 | 🎡｜動漫巴士 | csp_動漫巴士 | XYQHiker | 不可用 | 有集數，解析不出播放網址 |
| 94 | 🧲｜優質｜高清 | vod_优质 | type1 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 95 | 🧲｜優酷｜高清(浮水印廣告) | vod_优酷 | type1 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 96 | 🧲｜光速｜高清◎慢播(浮水印廣告) | vod_光速 | type1 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 97 | 🧲｜如意｜高清(各種廣告) | 如意 | type1 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 98 | 🧲｜如意｜高清(賭城廣告+成人) | 如意采集资源 | type1 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 99 | 🧲｜无忧｜高清(賭城廣告+成人) | 无忧采集资源 | type1 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 100 | 🧲｜極速｜高清(浮水印廣告) | vod_极速 | type1 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 101 | 🧲｜無盡｜高清(浮水印廣告) | vod_無盡 | type1 | 不可用 | 錯誤：DecodingError.dataCorrupted: Data was corrupted. Debug description: The given data was not |
| 102 | 🧲｜索尼｜高清(浮水印廣告) | vod_索尼 | type1 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 103 | 🧲｜红牛｜高清(浮水印廣告) | vod_红牛 | type1 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 104 | 🧲｜虎牙｜高清(浮水印廣告) | vod_虎牙 | type1 | 不可用 | 解析得到播放網址，但抓到的不是影片（page） |
| 105 | 🧲｜豪華｜高清(浮水印廣告) | vod_豪华 | type1 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 106 | 🧲｜順播｜高清(浮水印廣告) | vod_順播 | type1 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 107 | 🧲｜飘零｜高清(浮水印廣告) | vod_飘零 | type1 | 不可用 | 錯誤：invalidHTTPStatus(403) |
| 108 | ⚽｜88｜體育 | 88看球 | type4 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 109 | 🏆｜無水｜(T4) | php_无水印资源 | type4 | 不可用 | 首頁與第一個分類都沒有片 |
| 110 | 📻｜听友｜有聲(道長) | drpyS_听友[听] | type4 | 不可用 | 首頁與第一個分類都沒有片 |
| 111 | 🧲｜采集集合｜PHP | 采集集合 | type4 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 112 | 🏆｜愛瓜｜嗷源 | AiGua | AiGuaAmns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 113 | 🏆｜愛壹帆｜ | Aiyf | AiyfAmns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 114 | 🎡｜喵嗚动漫 | AowuDmMw | AowuDmAmns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 115 | 🏆｜天堂｜高清◎秒播 | 天堂 | AppDrama | App 不提供 | Android JAR 類別，iOS 未移植 |
| 116 | 🏆｜橘子｜？ | 橘汁 | AppDrama | App 不提供 | Android JAR 類別，iOS 未移植 |
| 117 | 🏆｜苹果｜秒播 | 苹果 | AppDrama | App 不提供 | Android JAR 類別，iOS 未移植 |
| 118 | 🥇｜薯條｜高清◎秒播 | 薯条 | AppDrama | App 不提供 | Android JAR 類別，iOS 未移植 |
| 119 | 🎡｜漫国动漫 | 漫国动漫 | AppSy | App 不提供 | Android JAR 類別，iOS 未移植 |
| 120 | 🥇｜大師兄｜高清◎秒播 | 大师兄 | AppV6 | App 不提供 | Android JAR 類別，iOS 未移植 |
| 121 | 🥇｜大师兄｜秒播 | AppV6Dxs | AppV6Amns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 122 | 🥇｜大師｜ | AppV6Dxs | AppV6Amns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 123 | 🥇①／菠菜专线 | AppV7Fz | AppV7Amns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 124 | 🥇②／菠菜专线 | AppV7Xy | AppV7Amns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 125 | 🥇③／菠菜专线 | AppV7Zjdr | AppV7Amns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 126 | 🥇④／菠菜专线 | AppV7Xyz | AppV7Amns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 127 | 🥇⑤／菠菜专线 | AppV7Xnm | AppV7Amns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 128 | 🥇⑥／菠菜专线 | AppV7Mtq | AppV7Amns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 129 | 🥇⑦／菠菜专线 | AppV7Llq | AppV7Amns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 130 | 🥇⑧／菠菜专线 | AppV7Xsz | AppV7Amns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 131 | 🥇⑨／菠菜专线 | AppV7Xhr | AppV7Amns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 132 | 📱｜一起｜畫質爛 + APP | 一起影视 | AppYQK | App 不提供 | Android JAR 類別，iOS 未移植 |
| 133 | 🥇｜奴娜丨高清◎秒播(d線) | 奴娜 | AppYsV2 | App 不提供 | Android JAR 類別，iOS 未移植 |
| 134 | 🏆｜奥特｜多线 | 奥特 | AueteGuard | App 不提供 | Android JAR 類別，iOS 未移植 |
| 135 | 📺｜拜拜短剧 | Bddj | BddjAmns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 136 | 🏆｜哔嘀｜2K | Bidys | BidysAmns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 137 | 🏆｜哔嘀｜2K | Bidys | BidysAmns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 138 | 🏆｜比特｜ | 比特 | BttwooGuard | App 不提供 | Android JAR 類別，iOS 未移植 |
| 139 | 🇹🇼｜熱播排行榜｜可選站 | 豆瓣-搜索 | Douban | App 不提供 | Android JAR 類別，iOS 未移植 |
| 140 | 🇹🇼｜熱播排行榜｜自動切換 | 豆瓣 | Douban | App 不提供 | Android JAR 類別，iOS 未移植 |
| 141 | 🏆｜獨播庫｜ | Dubk | DubkAmns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 142 | 🎡｜番薯 | FanShu | FanShuAmns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 143 | 📱｜飛魚｜很難形容 | 飞娱影视 | Feiyu | App 不提供 | Android JAR 類別，iOS 未移植 |
| 144 | ⚽｜瓜子｜體育 | 瓜子体育 | GuaziTY | App 不提供 | Android JAR 類別，iOS 未移植 |
| 145 | 📺｜好看短剧 | HHkk | HHkkAmns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 146 | 📺｜好看短剧｜瀟灑 | 好看短剧 | HaokanDJ | App 不提供 | Android JAR 類別，iOS 未移植 |
| 147 | 📺｜河马短剧｜瀟灑 | 河马短剧 | HemaDJ | App 不提供 | Android JAR 類別，iOS 未移植 |
| 148 | 📺｜嗷嗚漫劇 | MjHggg | HgggAmns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 149 | 📺｜嗷嗚短劇 | DjHggg | HgggAmns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 150 | 🏆｜韓圈｜高畫 + 有點慢 | 韩圈 | Hxq | App 不提供 | Android JAR 類別，iOS 未移植 |
| 151 | 🏆｜韓劇｜高清 | Hxq | HxqAmns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 152 | 🏆｜金牌｜高清◎秒播 | JinPai | JinPaiAmns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 153 | 🏆｜金牌｜高清 | 金牌影视 | Jpys | App 不提供 | Android JAR 類別，iOS 未移植 |
| 154 | 🏆｜文采｜秒播 | 文采 | JpysGuard | App 不提供 | Android JAR 類別，iOS 未移植 |
| 155 | 🏆｜異界｜高清 | py_jieyingshi | Jys | App 不提供 | Android JAR 類別，iOS 未移植 |
| 156 | 🎡｜喵呜动漫｜瀟灑 | 喵呜动漫 | MiaoWu | App 不提供 | Android JAR 類別，iOS 未移植 |
| 157 | 🎡｜魔都动漫｜瀟灑 | 魔都动漫 | MoDu | App 不提供 | Android JAR 類別，iOS 未移植 |
| 158 | 🏆｜糯米｜秒播 | 糯米 | NmyswvGuard | App 不提供 | Android JAR 類別，iOS 未移植 |
| 159 | 🥇｜歐樂｜(賭城廣告) | Olyy | OlyyAmns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 160 | 🥇｜山楂｜瀟灑 | 山楂影视 | PianKu8 | App 不提供 | Android JAR 類別，iOS 未移植 |
| 161 | 📺｜七猫短剧｜瀟灑 | 七猫短剧 | QimaoDJ | App 不提供 | Android JAR 類別，iOS 未移植 |
| 162 | 📺｜七猫短剧 | Qmdj | QmdjAmns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 163 | 🏆｜奶酪｜秒播 | 奶酪 | T4Guard | App 不提供 | Android JAR 類別，iOS 未移植 |
| 164 | 🏆｜Uvod｜藍光 | Qile优视频2 | Uvod | App 不提供 | Android JAR 類別，iOS 未移植 |
| 165 | 📺｜围观短剧｜瀟灑 | 围观短剧 | WeiguanDJ | App 不提供 | Android JAR 類別，iOS 未移植 |
| 166 | 🥇｜農民｜無廣 | 农民影视 | Wwys | App 不提供 | Android JAR 類別，iOS 未移植 |
| 167 | 📺｜星星短剧 | Xydj | XydjAmns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 168 | 🏆｜銀牌｜高清 | YIys | YIysAmns | App 不提供 | Android JAR 類別，iOS 未移植 |
| 169 | 🏆｜優影｜高清 | Ysp | YspAmns | App 不提供 | Android JAR 類別，iOS 未移植 |

### wang-sex.json（266 站）

| 結果 | 站數 |
|---|---:|
| 可用 | 54 |
| 不可用 | 203 |
| App 不提供 | 9 |

| # | 站名 | key | 類型 | 結果 | 不可用的原因 |
|---:|---|---|---|---|---|
| 1 | 🔞UAA(點選點播才有東西) | hipy_js_UAA[密] | JS/drpy | 可用 |  |
| 2 | 🔞麻豆(js) | js_madou | JS/drpy | 可用 |  |
| 3 | ⏭｜MissAv(沐辰)｜PYTHON | py_MissAv | Python | 可用 |  |
| 4 | ⏭｜Pornhub(new)｜PYTHON | py_phb.py | Python | 可用 |  |
| 5 | ⏭｜Pornhub(嗷嗚)｜PYTHON | 小红书 | Python | 可用 |  |
| 6 | ⏭｜xvideos｜PYTHON | py_xvd.py | Python | 可用 |  |
| 7 | ⏭｜好色(恰逢)｜PYTHON | py_好色 | Python | 可用 |  |
| 8 | ⏭｜愛豆AV｜PYTHON | py_愛豆AV | Python | 可用 |  |
| 9 | ⏭｜禁片天堂(恰逢)｜PYTHON | 禁片天堂 | Python | 可用 |  |
| 10 | ⏭｜黄豆短剧｜PYTHON | 黄豆短剧 | Python | 可用 |  |
| 11 | ✨花都影视(关梯)✨ | 花都影视(关梯) | Python | 可用 |  |
| 12 | ✨黄色仓库动态版✨ | 黄色仓库动态版 | Python | 可用 |  |
| 13 | 🔞8X8X.py | 8X8X | Python | 可用 |  |
| 14 | 🔞91porn.py | 91porn | Python | 可用 |  |
| 15 | 🔞EPORNER.py | eporner | Python | 可用 |  |
| 16 | 🔞Jable.py | Jable | Python | 可用 |  |
| 17 | 🔞Pornhub.py | Pornhub | Python | 可用 |  |
| 18 | 🔞TOPTV.py | TOPTV | Python | 可用 |  |
| 19 | 🔞Xvideos.py | Xvideos | Python | 可用 |  |
| 20 | 🔞xhamster.py | xhamster | Python | 可用 |  |
| 21 | 🔞久久視頻.py | ggsp | Python | 可用 |  |
| 22 | 🔞九个区.py | 九个区.py | Python | 可用 |  |
| 23 | 🔞咪TV.py | 猫咪TV | Python | 可用 |  |
| 24 | 🔞怦然心动.py | prsd | Python | 可用 |  |
| 25 | 🔞撸一天.py | lyt | Python | 可用 |  |
| 26 | 🔞香肠派对.py | scpd | Python | 可用 |  |
| 27 | 🔞麻豆社.py | 麻豆社 | Python | 可用 |  |
| 28 | 🔞Boba | Boba影视 | type0 | 可用 |  |
| 29 | 🔞大地资源 | *大地资源 | type0 | 可用 |  |
| 30 | 🔞大地采集 | 大地专场 | type0 | 可用 |  |
| 31 | 🔞黄AV | hav6.beauty | type0 | 可用 |  |
| 32 | 🔞黄AV资源 | www.pgxdy.com | type0 | 可用 |  |
| 33 | ️🔞乐播采集 | 乐播 | type1 | 可用 |  |
| 34 | 🔞155专场 | 155专场 | type1 | 可用 |  |
| 35 | 🔞CK资源 | CK资源 | type1 | 可用 |  |
| 36 | 🔞lovedan艾旦 | 艾旦影视 | type1 | 可用 |  |
| 37 | 🔞奥斯卡 | 奥斯卡 | type1 | 可用 |  |
| 38 | 🔞奥斯卡资源 | 奥斯卡资源 | type1 | 可用 |  |
| 39 | 🔞奶香资源 | Naixxzy.com | type1 | 可用 |  |
| 40 | 🔞森林资源 | 森林资源🔞 | type1 | 可用 |  |
| 41 | 🔞湿乐园 | 湿乐园 | type1 | 可用 |  |
| 42 | 🔞滴滴 | didizy.com | type1 | 可用 |  |
| 43 | 🔞玉兔资源 | apiyutu.com | type1 | 可用 |  |
| 44 | 🔞玉兔资源 | 玉兔资源🔞 | type1 | 可用 |  |
| 45 | 🔞番号资源 | *番号资源 | type1 | 可用 |  |
| 46 | 🔞精东资源 | chujia.cc | type1 | 可用 |  |
| 47 | 🔞精品 | jingpinx.com | type1 | 可用 |  |
| 48 | 🔞老色逼 | laosebizy.com | type1 | 可用 |  |
| 49 | 🔞老色逼资源(采集) | 老色逼资源 | type1 | 可用 |  |
| 50 | 🔞艾蛋資源 | 艾蛋影视 | type1 | 可用 |  |
| 51 | 🔞辣椒 | 辣椒资源 | type1 | 可用 |  |
| 52 | 🔞送AV采集 | 18+採集 | type1 | 可用 |  |
| 53 | 🔞鲨鱼 | *鲨鱼资源 | type1 | 可用 |  |
| 54 | 🔞鲨鱼资源 | 鲨鱼资源 | type1 | 可用 |  |
| 55 | 🔞一点视频(點選點播才有東西) | hipy_js_一点视频[密] | JS/drpy | 不可用 | 有集數，解析不出播放網址 |
| 56 | 🔞爱爱影院 | hipy_js_爱爱影院[密] | JS/drpy | 不可用 | 有集數，解析不出播放網址 |
| 57 | 🔞黑料不打烊-z | hipy_js_黑料不打烊-z | JS/drpy | 不可用 | 有集數，解析不出播放網址 |
| 58 | ⏭｜py_stripchat | py_stripchat | Python | 不可用 | 停在 detail 之後：content: player returned no URL |
| 59 | ⏭｜射我裡面｜PYTHON | 射我裡面.py | Python | 不可用 | 停在 player 之後：content: the resolved URL served unknown: https://thm3u8.co/20260929/cba4965e50388f87/inde |
| 60 | ⏭｜小淫书(嗷嗚)｜PYTHON | 小红书 | Python | 不可用 | 停在 load 之後：script:ValueError: not enough values to unpack (expected 3, got 0): scriptFailed("ValueErr |
| 61 | ✨推特APP✨ | 推特APP | Python | 不可用 | 停在 player 之後：content: the resolved URL served unknown: https://vdpimc.tggyiriy.xyz/jpc/20250901/o5/3x/a |
| 62 | 🔞4K歐美 | py_4k | Python | 不可用 | 停在 detail 之後：site/network: scriptFailed("requests.exceptions.ConnectionError: HTTPSConnectionPool(host= |
| 63 | 🔞FullHD.py | fullhd | Python | 不可用 | 停在 detail 之後：site/network: scriptFailed("requests.exceptions.ConnectionError: HTTPSConnectionPool(host= |
| 64 | 🔞Javmenu | Javmenu.py | Python | 不可用 | 停在 player 之後：content(parse=1): parse=1 page yielded no stream to the sniffer: https://t.me/secretwebmas |
| 65 | 🔞VHUB.py | VHUB | Python | 不可用 | 停在 home 之後：content: no category returned items |
| 66 | 🔞洋馬 | py_洋馬 | Python | 不可用 | 停在 detail 之後：content: no category returned items |
| 67 | 🔞色色直播 | py_色播 | Python | 不可用 | 停在 home 之後：script:ValueError: invalid literal for int() with base 10: '': scriptFailed("ValueError: i |
| 68 | 🔞蹦迪(點選點播才有東西) | py_dsys | Python | 不可用 | 停在 home 之後：site/content(unexpected answer): scriptFailed("requests.exceptions.JSONDecodeError: Expect |
| 69 | 🔞香蕉 | py_香蕉 | Python | 不可用 | 停在 load 之後：site/network: scriptFailed("requests.exceptions.ConnectionError: HTTPSConnectionPool(host= |
| 70 | 🇹🇼【老王成人專區】🇹🇼 | 麻豆 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 71 | 🔞 AVMobTV | AVMobTV | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 72 | 🔞13AV.COM | 13AV.COM | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 73 | 🔞13AV.ICU | 13AV.ICU | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 74 | 🔞18XXX | 18XXX | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 75 | 🔞18j | 18 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 76 | 🔞55视频 | 55视频 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 77 | 🔞83视频 | 83视频 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 78 | 🔞941c | 941 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 79 | 🔞AV.GL | avgle | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 80 | 🔞AV小次郎 | AV小次郎 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 81 | 🔞AV帝国 | AV帝国 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 82 | 🔞AV影视 | av影视 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 83 | 🔞Airav | airav | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 84 | 🔞GDD视频 | GDD视频 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 85 | 🔞KISSAV | KISSAV(主题) | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 86 | 🔞KISSAV(女优) | KISSAV(女优) | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 87 | 🔞KISSAV(标签) | KISSAV(标签) | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 88 | 🔞SAOO | SAOO | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 89 | 🔞SEAJAV(聚合) | SEAJAV | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 90 | 🔞TaiAv2 | TaiAv | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 91 | 🔞sexBJcam | sexBJcam | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 92 | 🔞一个纯粹的x站 | 一个纯粹的x站 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 93 | 🔞一区 | 一区 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 94 | 🔞七色谷 | 七色谷 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 95 | 🔞三区 | 三区 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 96 | 🔞亚瑟影库 | 亚色影库 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 97 | 🔞今晚打手槍 | 今晚打手槍 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 98 | 🔞传媒二区 | 传媒二区 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 99 | 🔞偷拍自拍 | 偷拍自拍 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 100 | 🔞公子别走 | 公子别走 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 101 | 🔞初の体验 | 初の体验 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 102 | 🔞四区 | 四区 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 103 | 🔞夜夜新郎 | csp_XBPQ_yyxl | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 104 | 🔞天堂岛 | 天堂岛 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 105 | 🔞天天 | csp_XBPQ_天天 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 106 | 🔞天美 | 天美 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 107 | 🔞女优色库 | 女优色库 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 108 | 🔞妻妹(點選點播才有東西) | 小姨子的诱惑 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 109 | 🔞婶婶(點選點播才有東西) | 婶婶影视 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 110 | 🔞小姨子 | 小姨子 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 111 | 🔞小幺女 | 小幺女／床吧 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 112 | 🔞弟弟 | 色弟弟 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 113 | 🔞微密猫(點選點播才有東西) | 微密猫 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 114 | 🔞成人重口 | 成人重口 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 115 | 🔞成鸡思汉 | 成鸡思汉 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 116 | 🔞我爱AV | 我爱AV | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 117 | 🔞我爱AV社区 | 我爱AV | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 118 | 🔞手鸡助手 | 手鸡助手 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 119 | 🔞文件夹 | 文件夹 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 120 | 🔞新香蕉国产传媒 | csp_xBPQ_香蕉国产 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 121 | 🔞新香蕉超清资源〔xBPQ〕 | csp_xBPQ香蕉超清 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 122 | 🔞旺仔小乔 | 旺仔小乔 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 123 | 🔞暗网(點選點播才有東西) | 暗网色库 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 124 | 🔞最爱扒裤衩 | 最爱扒裤衩 | XBPQ | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 125 | 🔞果冻 | 果冻破解版 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 126 | 🔞果冻破解 | 果冻破解版 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 127 | 🔞樱樱女子 | 樱樱女子 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 128 | 🔞比卡(無圖) | 比卡 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 129 | 🔞比卡比卡 | csp_XYBQ | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 130 | 🔞水果派 | 水果派 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 131 | 🔞流氓兔 | 流氓兔 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 132 | 🔞淘精岁月 | 淘精岁月 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 133 | 🔞游击队 | 游击队 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 134 | 🔞溏心次元 | 溏心次元 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 135 | 🔞猛男日妓 | 🔞猛男日妓 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 136 | 🔞疯猫av | csp_XBPQ_疯猫av | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 137 | 🔞癢癢 | csp_XBPQ_癢癢 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 138 | 🔞百灵鸟在线 | 百灵鸟在线 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 139 | 🔞百香草 | 百草香 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 140 | 🔞看AV | kanav | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 141 | 🔞神社影视 | 俺要社 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 142 | 🔞窜天猴 | 窜天猴 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 143 | 🔞精工厂 | 精工厂 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 144 | 🔞纤纤倫理 | 纤纤影视福利版 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 145 | 🔞绝美视频 | 绝美视频 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 146 | 🔞美人吹箫 | 美人吹箫 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 147 | 🔞肉視頻(點選點播才有東西) | 肉视频 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 148 | 🔞自排偷拍 | 自排偷拍 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 149 | 🔞色岛 | 色岛 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 150 | 🔞色最色(點選點播才有東西) | 色最色 | XBPQ | 不可用 | 有片單，詳情頁沒有集數 |
| 151 | 🔞色花堂 | csp_色花堂 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 152 | 🔞花影视(點選點播才有東西) | 花影视 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 153 | 🔞蓝金鱼AV | 蓝金鱼AV | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 154 | 🔞蜜桃屯 | 蜜桃屯 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 155 | 🔞蜜桃影视 | 乐哥特供-蜜桃屯 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 156 | 🔞醉奶吧 | 醉奶吧 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 157 | 🔞醉奶吧 | 醉奶吧 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 158 | 🔞野鸡資源 | 野鸡TV | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 159 | 🔞金陵撸铁汉 | 撸铁汉 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 160 | 🔞顶级网曝 | csp_顶级网曝 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 161 | 🔞风流 | 风流视频\n | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 162 | 🔞香蕉AV解说 | csp_xBPQ_香蕉AV解说 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 163 | 🔞香蕉中文资源 | csp_香蕉资源 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 164 | 🔞香蕉久久热 | csp_xBPQ_香蕉久久热 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 165 | 🔞香蕉废柴网 | csp_香蕉废柴网 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 166 | 🔞骏马 | csp_XBPQ_骏马 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 167 | 🔞高清小黄片 | XHP | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 168 | 🔞高清黑料3 | 高清xxxx黑料 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 169 | 🔞高端外泄 | 高端外泄 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 170 | 🔞魔法少女1 | 魔法少女 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 171 | 🔞魔法少女2 | 魔法少女2 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 172 | 🔞魔法少女3 | 魔法少女3 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 173 | 🔞魔法少女4 | 魔法少女4 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 174 | 🔞麻玉 | 麻 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 175 | 🔞黃色都市 | 黃色都市 | XBPQ | 不可用 | 首頁與第一個分類都沒有片 |
| 176 | 🔞170av | csp_XYQHiker_170av | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 177 | 🔞18AV | csp_XYQHiker_18av | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 178 | 🔞300分类 | csp_XYQHiker_300分类 | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 179 | 🔞300分类 | csp_XYQHiker_300分类 | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 180 | 🔞444咖啡(點選點播才有東西) | csp_XYQHiker_444咖啡 | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 181 | 🔞ACG漫画网(XYQHiker) | csp_XYQHiker_ACG漫画网 | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 182 | 🔞ACG漫画网(點選點播才有東西) | csp_XYQHiker_ACG漫画网 | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 183 | 🔞AVbebe(XYQHiker) | csp_XYQHiker_avbebe | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 184 | 🔞AVbebe(點選點播才有東西) | csp_XYQHiker_avbebe | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 185 | 🔞AirAV(點選點播才有東西) | csp_XYQHiker_airav | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 186 | 🔞HOHOJ | csp_XYQHiker_hohoj | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 187 | 🔞Hanime1 | csp_XYQHiker_hanimi1 | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 188 | 🔞IXXXJ | csp_XYQHiker_ixxxj | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 189 | 🔞KANAV | csp_XYQHiker_kanav | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 190 | 🔞MOTV | csp_XYQHiker_MOTV | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 191 | 🔞OWOAV | csp_XYQHiker_owoAV | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 192 | 🔞PPP | csp_XYQHiker_ppp | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 193 | 🔞P影院 | csp_XYQHiker_p影院 | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 194 | 🔞Qinav | csp_XYQHiker_qinav | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 195 | 🔞ThisAV | csp_XYQHiker_thisav | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 196 | 🔞Tktube | csp_XYQHiker_tktube | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 197 | 🔞Ujizzcn | csp_XYQHiker_ujizzcn | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 198 | 🔞Xtoons动漫(XYQHiker) | csp_XYQHiker_xtoons | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 199 | 🔞Xtoons动漫(點選點播才有東西) | csp_XYQHiker_xtoons | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 200 | 🔞Youjizz | csp_XYQHiker_youjizz | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 201 | 🔞bongacams直播(點選點播才有東西) | csp_XYQHiker_bongacams直播 | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 202 | 🔞jiedmAV(XYQHiker) | csp_XYQHiker_jiedm | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 203 | 🔞jiedmAV(點選點播才有東西) | csp_XYQHiker_jiedm | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 204 | 🔞playav | csp_XYQHiker_playav | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 205 | 🔞sexsex | csp_XYQHiker_sexsex | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 206 | 🔞xHamster | csp_XYQHiker_xHamster | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 207 | 🔞xgroovy | csp_XYQHiker_xgroovy | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 208 | 🔞中国性味 | csp_XYQHiker_中国性味 | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 209 | 🔞丽丽AV(點選點播才有東西) | csp_XYQHiker_丽丽AV | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 210 | 🔞亚洲色吧(點選點播才有東西) | csp_XYQHiker_亚洲色吧 | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 211 | 🔞亚色影库 | csp_XYQHiker_亚色影库 | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 212 | 🔞亞洲情色網 | csp_XYQHiker_asianssex | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 213 | 🔞动漫PRO(XYQHiker) | csp_XYQHiker_动漫PRO | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 214 | 🔞动漫PRO(點選點播才有東西) | csp_XYQHiker_动漫PRO | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 215 | 🔞台湾kiss | csp_XYQHiker_台湾kiss | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 216 | 🔞台湾kiss | csp_XYQHiker_台湾kiss | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 217 | 🔞好色TV | csp_XYQHiker_好色TV | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 218 | 🔞小丑撸 | csp_XYQHiker_小丑撸 | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 219 | 🔞小嫂子 | csp_XYQHiker_小嫂子av | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 220 | 🔞有爱爱uaa(點選點播才有東西) | csp_XYQHiker_有爱爱uaa | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 221 | 🔞朱古力 | csp_XYQHiker_朱古力 | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 222 | 🔞杏吧视频 | csp_XYQHiker_杏吧视频 | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 223 | 🔞正妹AV(點選點播才有東西) | csp_XYQHiker_正妹AV | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 224 | 🔞热骚 | csp_XYQHiker_热骚 | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 225 | 🔞直播1 | csp_XYQHiker_直播1 | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 226 | 🔞直播2 | csp_XYQHiker_直播2 | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 227 | 🔞直播大全 | csp_XYQHiker_直播大全 | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 228 | 🔞紫色成人 | csp_XYQHiker_紫色成人 | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 229 | 🔞色库TV | csp_XYQHiker_色库TV | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 230 | 🔞酷爱成人网 | csp_XYQHiker_酷爱成人网> | XYQHiker | 不可用 | 首頁與第一個分類都沒有片 |
| 231 | 🔞鲨鱼av | csp_XYQHiker_鲨鱼av | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 232 | 🔞黄色仓库123 | csp_XYQHiker_黄色仓库123 | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 233 | 🔞黄色仓库啦 | csp_XYQHiker_黄色仓库la | XYQHiker | 不可用 | 有片單，詳情頁沒有集數 |
| 234 | 🔞博天堂 | 博天堂 | type0 | 不可用 | 錯誤：Error Domain=NSURLErrorDomain Code=-1003 "A server with the specified hostname could not b |
| 235 | 🔞富二代 | 富二代 | type0 | 不可用 | 錯誤：invalidHTTPStatus(404) |
| 236 | 🔞开心果 | kxgav | type0 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 237 | 🔞淫水机资源 | 淫水机资源 | type0 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 238 | 🔞白嫖资源 | 白嫖资源 | type0 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 239 | 🔞美少女 | *美少女资源 | type0 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 240 | 🔞香奶儿资源 | *香奶儿资源 | type0 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 241 | 👖TG频道@stymei丨香蕉丨12852部片 | XJCJ | type1 | 不可用 | 錯誤：Error Domain=NSURLErrorDomain Code=-1202 "The certificate for this server is invalid. You  |
| 242 | 🔞 成人频道[ikun](點選點播才有東西) | ikun | type1 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 243 | 🔞 成人频道[光速](點選點播才有東西) | 光速 | type1 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 244 | 🔞 成人频道[速播](點選點播才有東西) | 速播 | type1 | 不可用 | 解析得到播放網址，但抓到的不是影片（unknown） |
| 245 | 🔞998资源 | 998资源(采集) | type1 | 不可用 | 錯誤：Error Domain=NSURLErrorDomain Code=-1004 "Could not connect to the server."  |
| 246 | 🔞AIvin | AIvin(采集) | type1 | 不可用 | 錯誤：invalidHTTPStatus(502) |
| 247 | 🔞JKUN | JKUN(采集) | type1 | 不可用 | 錯誤：DecodingError.dataCorrupted: Data was corrupted. Debug description: The given data was not |
| 248 | 🔞Sexnguon | api.sexnguon.com | type1 | 不可用 | 錯誤：Error Domain=NSURLErrorDomain Code=-1004 "Could not connect to the server."  |
| 249 | 🔞丝袜资源 | *丝袜资源 | type1 | 不可用 | 錯誤：Error Domain=NSURLErrorDomain Code=-1004 "Could not connect to the server."  |
| 250 | 🔞优异资源 | 优异资源 | type1 | 不可用 | 錯誤：DecodingError.dataCorrupted: Data was corrupted. Debug description: The given data was not |
| 251 | 🔞秀人 | 秀人 | type1 | 不可用 | 錯誤：DecodingError.dataCorrupted: Data was corrupted. Debug description: The given data was not |
| 252 | 🔞老鸨资源 | 老鸨资源 | type1 | 不可用 | 錯誤：Error Domain=NSURLErrorDomain Code=-1003 "A server with the specified hostname could not b |
| 253 | 🔞色猫(FQ) | semaozy.com | type1 | 不可用 | 首頁與第一個分類都沒有片 |
| 254 | 🔞色猫资源 | *色猫资源 | type1 | 不可用 | 錯誤：invalidHTTPStatus(521) |
| 255 | 🔞葡萄 | *葡萄资源 | type1 | 不可用 | 錯誤：Error Domain=NSURLErrorDomain Code=-1003 "A server with the specified hostname could not b |
| 256 | 🔞蜜桃社 | 蜜桃社(采集)🔞 | type1 | 不可用 | 錯誤：DecodingError.dataCorrupted: Data was corrupted. Debug description: The given data was not |
| 257 | 🔞黄瓜 | 黄瓜资源 | type1 | 不可用 | 錯誤：Error Domain=NSURLErrorDomain Code=-1004 "Could not connect to the server."  |
| 258 | 🔞SupJav | supjav | GM | App 不提供 | Android JAR 類別，iOS 未移植 |
| 259 | 🔞XOJAV | XOJAV | GM | App 不提供 | Android JAR 類別，iOS 未移植 |
| 260 | 🔞Jable | Jable | Jable | App 不提供 | Android JAR 類別，iOS 未移植 |
| 261 | 🔞Jable(海外) | Jable | Jable | App 不提供 | Android JAR 類別，iOS 未移植 |
| 262 | 🔞迷妹 | MiMei | MiMei | App 不提供 | Android JAR 類別，iOS 未移植 |
| 263 | 最色 | Zuise | Zuise | App 不提供 | Android JAR 類別，iOS 未移植 |
| 264 | ️🔞女優 | vv001 | type4 | App 不提供 | App 不支援這種來源 |
| 265 | ️🔞番號 | vv002 | type4 | App 不提供 | App 不支援這種來源 |
| 266 | ️🔞薇薇珊 | vv003 | type4 | App 不提供 | App 不支援這種來源 |
