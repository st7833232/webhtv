/**
 * csp_Bili — ported from `com.github.catvod.spider.Bili` (river-fman.jar, 284 lines).
 *
 * The public bilibili web API, no crypto and no login required. The home is a static CatVod document
 * whose `type_id`s this port searches for as keywords, so browsing is `search/type` and playing is
 * `player/playurl`. The document comes from `ext.json` (the original's form, which the four
 * `wang-movie.json` sites use), from `ext.n` naming one that qist/tvbox's `spider.jar` compiles in,
 * or from an `ext` that is itself the URL of qist/tvbox `XYQ.jar`'s `{cookie, classes, filter}`
 * document (IOS-POC-57A).
 *
 * Three deliberate departures from the original (see `docs/IOS-POC-5L-appqi-app99-app3q-bili.md`
 * and `docs/IOS-POC-5Q-playback-quality.md`); the first two are forced by the platform:
 *
 *   1. **No DASH.** The original hands the player `Proxy.getUrl()?do=bili&…&type=mpd` and then
 *      synthesises an MPD from the `dash` response inside the Android app's own HTTP server. iOS has
 *      no such server, and `AVPlayer` cannot play MPEG-DASH in any case, so this port asks for
 *      `fnval=1` and returns the progressive `durl` MP4 instead.
 *   2. **`wbi/view` instead of `view`.** `/x/web-interface/view` now answers with an HTML error page
 *      for every aid and bvid (measured 2026-09-17, with and without a fresh `buvid3`);
 *      `/x/web-interface/wbi/view` returns the same document and, today, needs no `w_rid`.
 *   3. **One line per quality.** The original plays whatever `qn` it asked for and offers no
 *      choice. Every quality's real address needs its own `playurl` call, so a `url` array would
 *      cost one extra request per quality on every episode; as lines the choice is made before
 *      `playerContent` runs and costs nothing (IOS-POC-5Q, decision D10).
 *
 * Not ported: the `<mid>/{pg}` up-主 branch of `categoryContent`, which needs wbi query signing —
 * none of the 73 categories the four sites configure uses it. Danmaku, as everywhere, is dropped.
 */
var spider = (function () {
  'use strict';

  var DEFAULT_COOKIE = 'buvid3=04E9092E-4D34-B728-CB76-E5BCBEC43B5129057infoc';
  var cfg = { cookie: DEFAULT_COOKIE, json: '', home: null };

  /**
   * qist/tvbox `spider.jar`: `ext.n` names a home document compiled into the class. Copied from it
   * verbatim, minus 我的关注/最新动态/历史记录 in 哔哩合集 — those read the signed-in account's
   * follows and history, and there is no account here, only the anonymous buvid3 (IOS-POC-57).
   */
  var BUILTIN = {
    "哔哩合集": {"class":[{"type_name":"搞笑","type_id":"搞笑"},{"type_name":"游戏","type_id":"游戏"},{"type_name":"影视集锦","type_id":"影视集锦"},{"type_name":"科技数码","type_id":"科技数码"},{"type_name":"音乐","type_id":"音乐"},{"type_name":"明星娱乐","type_id":"明星娱乐"},{"type_name":"三农","type_id":"三农"},{"type_name":"播客","type_id":"播客"},{"type_name":"体育运动","type_id":"体育运动"},{"type_name":"知识","type_id":"知识"},{"type_name":"美妆穿搭","type_id":"美妆穿搭"},{"type_name":"VLOG","type_id":"VLOG"},{"type_name":"动物星球","type_id":"动物星球"},{"type_name":"家庭生活","type_id":"家庭生活"},{"type_name":"美食","type_id":"美食"},{"type_name":"动画漫画","type_id":"动画漫画"},{"type_name":"汽车","type_id":"汽车"},{"type_name":"手工绘画","type_id":"手工绘画"},{"type_name":"资讯","type_id":"资讯"},{"type_name":"舞蹈","type_id":"舞蹈"}],"filters":{"搞笑":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}],"游戏":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}],"影视集锦":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}],"科技数码":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}],"音乐":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}],"明星娱乐":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}],"三农":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}],"播客":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}],"体育运动":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}],"知识":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}],"美妆穿搭":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}],"VLOG":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}],"动物星球":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}],"家庭生活":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}],"美食":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}],"动画漫画":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}],"汽车":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}],"手工绘画":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}],"资讯":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}],"舞蹈":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}]}},
    "哔哩听书": {"class":[{"type_name":"有声小说","type_id":"有声小说"},{"type_name":"玄幻有声小说","type_id":"玄幻有声小说"},{"type_name":"奇幻有声小说","type_id":"奇幻有声小说"},{"type_name":"都市有声小说","type_id":"都市有声小说"},{"type_name":"言情有声小说","type_id":"言情有声小说"},{"type_name":"武侠有声小说","type_id":"武侠有声小说"},{"type_name":"仙侠有声小说","type_id":"仙侠有声小说"},{"type_name":"科幻有声小说","type_id":"科幻有声小说"},{"type_name":"重生有声小说","type_id":"重生有声小说"},{"type_name":"穿越有声小说","type_id":"穿越有声小说"},{"type_name":"恐怖惊悚有声小说","type_id":"恐怖惊悚有声小说"},{"type_name":"网游竞技有声小说","type_id":"网游竞技有声小说"}]},
    "哔哩戏曲": {"class":[{"type_name":"二人转","type_id":"二人转"},{"type_name":"潮剧","type_id":"潮剧"},{"type_name":"粤剧","type_id":"粤剧"},{"type_name":"京剧","type_id":"京剧"},{"type_name":"越剧","type_id":"越剧"},{"type_name":"芗剧","type_id":"芗剧"},{"type_name":"蒲剧","type_id":"蒲剧"},{"type_name":"闽剧","type_id":"闽剧"},{"type_name":"喊麦","type_id":"喊麦"},{"type_name":"陕北说书","type_id":"陕北说书"},{"type_name":"庐剧","type_id":"庐剧"},{"type_name":"吕剧","type_id":"吕剧"},{"type_name":"眉户","type_id":"眉户"},{"type_name":"歌仔戏","type_id":"歌仔戏"},{"type_name":"黄梅戏","type_id":"黄梅戏"},{"type_name":"黄梅戏","type_id":"黄梅戏"},{"type_name":"评剧","type_id":"评剧"},{"type_name":"豫剧","type_id":"豫剧"},{"type_name":"沪剧","type_id":"沪剧"},{"type_name":"昆曲","type_id":"昆曲"},{"type_name":"花鼓戏","type_id":"花鼓戏"},{"type_name":"超清潮剧","type_id":"超清潮剧"},{"type_name":"百花潮剧院","type_id":"百花潮剧院"},{"type_name":"香港潮剧","type_id":"香港潮剧"},{"type_name":"潮剧院","type_id":"潮剧院"},{"type_name":"潮剧团","type_id":"潮剧团"},{"type_name":"潮剧全剧","type_id":"潮剧全剧"},{"type_name":"潮剧选段","type_id":"潮剧选段"},{"type_name":"名家潮剧","type_id":"名家潮剧"},{"type_name":"潮汕小品","type_id":"潮汕小品"},{"type_name":"潮汕讲古","type_id":"潮汕讲古"},{"type_name":"河北梆子","type_id":"河北梆子"},{"type_name":"梆子腔","type_id":"梆子腔"},{"type_name":"晋剧","type_id":"晋剧"},{"type_name":"龙江剧","type_id":"龙江剧"},{"type_name":"越调","type_id":"越调"},{"type_name":"河南曲剧","type_id":"河南曲剧"},{"type_name":"山东梆子","type_id":"山东梆子"},{"type_name":"淮剧","type_id":"淮剧"},{"type_name":"滑稽戏","type_id":"滑稽戏"},{"type_name":"婺剧","type_id":"婺剧"},{"type_name":"绍剧","type_id":"绍剧"},{"type_name":"徽剧","type_id":"徽剧"},{"type_name":"雁剧","type_id":"雁剧"},{"type_name":"上党梆子","type_id":"上党梆子"},{"type_name":"秦腔","type_id":"秦腔"},{"type_name":"武安平调","type_id":"武安平调"},{"type_name":"二人台","type_id":"二人台"},{"type_name":"吉剧","type_id":"吉剧"},{"type_name":"高腔","type_id":"高腔"}]},
    "哔哩相声": {"class":[{"type_name":"单口相声","type_id":"单口相声"},{"type_name":"群口相声","type_id":"群口相声"},{"type_name":"德云社","type_id":"德云社"},{"type_name":"青曲社","type_id":"青曲社"},{"type_name":"郭德纲","type_id":"郭德纲"},{"type_name":"岳云鹏","type_id":"岳云鹏"},{"type_name":"曹云金","type_id":"曹云金"}]},
    "哔哩小品": {"class":[{"type_name":"春晚小品","type_id":"春晚小品"},{"type_name":"赵本山","type_id":"赵本山"},{"type_name":"陈佩斯","type_id":"陈佩斯"},{"type_name":"冯巩","type_id":"冯巩"},{"type_name":"宋小宝","type_id":"宋小宝"},{"type_name":"赵丽蓉","type_id":"赵丽蓉"},{"type_name":"郭达","type_id":"郭达"},{"type_name":"潘长江","type_id":"潘长江"},{"type_name":"郭冬临","type_id":"郭冬临"},{"type_name":"严顺开","type_id":"严顺开"},{"type_name":"文松","type_id":"文松"},{"type_name":"开心麻花","type_id":"开心麻花"}]},
    "哔哩音乐": {"class":[{"type_name":"演唱会筛选","type_id":"演唱会超清"},{"type_name":"粤语","type_id":"粤语歌曲超清"},{"type_name":"热榜","type_id":"2022年热们歌曲超清"},{"type_name":"抖音神曲","type_id":"抖音神曲超清"},{"type_name":"经典老歌","type_id":"经典老歌超清"},{"type_name":"DJ","type_id":"DJ歌曲超清"},{"type_name":"网红翻唱","type_id":"网红翻唱歌曲超清"},{"type_name":"韩国女团","type_id":"韩国女团演唱会超清"}],"filters":{"演唱会超清":[{"key":"order","name":"排序","value":[{"n":"综合排序","v":"0"},{"n":"最多点击","v":"click"},{"n":"最新发布","v":"pubdate"},{"n":"最多弹幕","v":"dm"},{"n":"最多收藏","v":"stow"}]},{"key":"tid","name":"分类","value":[{"n":"全部","v":"演唱会超清"},{"n":"A阿杜","v":"阿杜演唱会超清"},{"n":"A阿黛尔","v":"阿黛尔演唱会超清"},{"n":"BBeyond","v":"Beyond演唱会超清"},{"n":"BBy2","v":"By2演唱会超清"},{"n":"BBIGBANG","v":"BIGBANG演唱会超清"},{"n":"B布兰妮","v":"布兰妮演唱会超清"},{"n":"B坂井泉水","v":"坂井泉水演唱会超清"},{"n":"C陈奕迅","v":"陈奕迅演唱会超清"},{"n":"C蔡依林","v":"蔡依林演唱会超清"},{"n":"C初音未来","v":"初音未来演唱会超清"},{"n":"C蔡健雅","v":"蔡健雅演唱会超清"},{"n":"C陈小春","v":"陈小春演唱会超清"},{"n":"C草蜢","v":"草蜢演唱会超清"},{"n":"C陈慧娴","v":"陈慧娴演唱会超清"},{"n":"C崔健","v":"崔健演唱会超清"},{"n":"C仓木麻衣","v":"仓木麻衣演唱会超清"},{"n":"D戴荃","v":"戴荃演唱会超清"},{"n":"D动力火车","v":"动力火车演唱会超清"},{"n":"D邓丽君","v":"邓丽君演唱会超清"},{"n":"D丁当","v":"丁当演唱会超清"},{"n":"D刀郎","v":"刀郎演唱会超清"},{"n":"D邓紫棋","v":"邓紫棋演唱会超清"},{"n":"D戴佩妮","v":"戴佩妮演唱会超清"},{"n":"D邓丽君","v":"邓丽君演唱会超清"},{"n":"F飞儿乐队","v":"飞儿乐队演唱会超清"},{"n":"F费玉清","v":"费玉清演唱会超清"},{"n":"F费翔","v":"费翔演唱会超清"},{"n":"F方大同","v":"方大同演唱会超清"},{"n":"F房东的猫","v":"房东的猫演唱会超清"},{"n":"F凤飞飞","v":"凤飞飞演唱会超清"},{"n":"F凤凰传奇","v":"凤凰传奇演唱会超清"},{"n":"G郭采洁","v":"郭采洁演唱会超清"},{"n":"G光良","v":"光良演唱会超清"},{"n":"G郭静","v":"郭静演唱会超清"},{"n":"G郭富城","v":"郭富城演唱会超清"},{"n":"H胡彦斌","v":"胡彦斌演唱会超清"},{"n":"H胡夏","v":"胡夏演唱会超清"},{"n":"H韩红","v":"韩红演唱会超清"},{"n":"H黄品源","v":"黄品源演唱会超清"},{"n":"H黄小琥","v":"黄小琥演唱会超清"},{"n":"H花儿乐队","v":"花儿乐队演唱会超清"},{"n":"H黄家强","v":"黄家强演唱会超清"},{"n":"H后街男孩","v":"后街男孩演唱会超清"},{"n":"J经典老歌","v":"经典老歌演唱会超清"},{"n":"J贾斯丁比伯","v":"贾斯丁比伯演唱会超清"},{"n":"J金池","v":"金池演唱会超清"},{"n":"J金志文","v":"金志文演唱会超清"},{"n":"J焦迈奇","v":"焦迈奇演唱会超清"},{"n":"K筷子兄弟","v":"筷子兄弟演唱会超清"},{"n":"L李玟","v":"李玟演唱会超清"},{"n":"L林忆莲","v":"林忆莲演唱会超清"},{"n":"L李克勤","v":"李克勤演唱会超清"},{"n":"L刘宪华","v":"刘宪华演唱会超清"},{"n":"L李圣杰","v":"李圣杰演唱会超清"},{"n":"L林宥嘉","v":"林宥嘉演唱会超清"},{"n":"L梁静茹","v":"梁静茹演唱会超清"},{"n":"L李健","v":"李健演唱会超清"},{"n":"L林俊杰","v":"林俊杰演唱会超清"},{"n":"L李玉刚","v":"李玉刚演唱会超清"},{"n":"L林志炫","v":"林志炫演唱会超清"},{"n":"L李荣浩","v":"李荣浩演唱会超清"},{"n":"L李宇春","v":"李宇春演唱会超清"},{"n":"L洛天依","v":"洛天依演唱会超清"},{"n":"L林子祥","v":"林子祥演唱会超清"},{"n":"L李宗盛","v":"李宗盛演唱会超清"},{"n":"L黎明","v":"黎明演唱会超清"},{"n":"L刘德华","v":"刘德华演唱会超清"},{"n":"L罗大佑","v":"罗大佑演唱会超清"},{"n":"L林肯公园","v":"林肯公园演唱会超清"},{"n":"LLadyGaga","v":"LadyGaga演唱会超清"},{"n":"L旅行团乐队","v":"旅行团乐队演唱会超清"},{"n":"M莫文蔚","v":"莫文蔚演唱会超清"},{"n":"M毛不易","v":"毛不易演唱会超清"},{"n":"M梅艳芳","v":"梅艳芳演唱会超清"},{"n":"M迈克尔杰克逊","v":"迈克尔杰克逊演唱会超清"},{"n":"N南拳妈妈","v":"南拳妈妈演唱会超清"},{"n":"P朴树","v":"朴树演唱会超清"},{"n":"Q齐秦","v":"齐秦演唱会超清"},{"n":"Q青鸟飞鱼","v":"青鸟飞鱼演唱会超清"},{"n":"R容祖儿","v":"容祖儿演唱会超清"},{"n":"R任贤齐","v":"任贤齐演唱会超清"},{"n":"S水木年华","v":"水木年华演唱会超清"},{"n":"S孙燕姿","v":"孙燕姿演唱会超清"},{"n":"S苏打绿","v":"苏打绿演唱会超清"},{"n":"SSHE","v":"SHE演唱会超清"},{"n":"S孙楠","v":"孙楠演唱会超清"},{"n":"T陶喆","v":"陶喆演唱会超清"},{"n":"T谭咏麟","v":"谭咏麟演唱会超清"},{"n":"T田馥甄","v":"田馥甄演唱会超清"},{"n":"T谭维维","v":"谭维维演唱会超清"},{"n":"T逃跑计划","v":"逃跑计划演唱会超清"},{"n":"T田震","v":"田震演唱会超清"},{"n":"T谭晶","v":"谭晶演唱会超清"},{"n":"T屠洪刚","v":"屠洪刚演唱会超清"},{"n":"T泰勒·斯威夫特","v":"泰勒·斯威夫特演唱会超清"},{"n":"W王力宏","v":"王力宏演唱会超清"},{"n":"W王杰","v":"王杰演唱会超清"},{"n":"W吴克群","v":"吴克群演唱会超清"},{"n":"W王心凌","v":"王心凌演唱会超清"},{"n":"W王靖雯","v":"好声音王靖雯演唱会超清"},{"n":"W汪峰","v":"汪峰演唱会超清"},{"n":"W伍佰","v":"伍佰演唱会超清"},{"n":"W王菲","v":"王菲演唱会超清"},{"n":"W五月天","v":"五月天演唱会超清"},{"n":"W汪苏泷","v":"汪苏泷演唱会超清"},{"n":"X徐佳莹","v":"徐佳莹演唱会超清"},{"n":"X弦子","v":"弦子演唱会超清"},{"n":"X萧亚轩","v":"萧亚轩演唱会超清"},{"n":"X许巍","v":"许巍演唱会超清"},{"n":"X薛之谦","v":"薛之谦演唱会超清"},{"n":"X许嵩","v":"许嵩演唱会超清"},{"n":"X小虎队","v":"小虎队演唱会超清"},{"n":"X萧敬腾","v":"萧敬腾演唱会超清"},{"n":"X谢霆锋","v":"谢霆锋演唱会超清"},{"n":"X徐小凤","v":"徐小凤演唱会超清"},{"n":"X信乐队","v":"信乐队演唱会超清"},{"n":"Y夜愿乐队","v":"夜愿乐队演唱会超清"},{"n":"Y羽泉","v":"羽泉演唱会超清"},{"n":"Y郁可唯","v":"郁可唯演唱会超清"},{"n":"Y叶倩文","v":"叶倩文演唱会超清"},{"n":"Y杨坤","v":"杨坤演唱会超清"},{"n":"Y庾澄庆","v":"庾澄庆演唱会超清"},{"n":"Y尤长靖","v":"尤长靖演唱会超清"},{"n":"Y易烊千玺","v":"易烊千玺演唱会超清"},{"n":"Y袁娅维","v":"袁娅维演唱会超清"},{"n":"Y杨丞琳","v":"杨丞琳演唱会超清"},{"n":"Y杨千嬅","v":"杨千嬅演唱会超清"},{"n":"Y杨宗纬","v":"杨宗纬演唱会超清"},{"n":"Z郑秀文","v":"郑秀文演唱会超清"},{"n":"Z周杰伦","v":"周杰伦演唱会超清"},{"n":"Z张学友","v":"张学友演唱会超清"},{"n":"Z张信哲","v":"张信哲演唱会超清"},{"n":"Z张宇","v":"张宇演唱会超清"},{"n":"Z周华健","v":"周华健演唱会超清"},{"n":"Z张韶涵","v":"张韶涵演唱会超清"},{"n":"Z周深","v":"周深演唱会超清"},{"n":"Z纵贯线","v":"纵贯线演唱会超清"},{"n":"Z赵雷","v":"赵雷演唱会超清"},{"n":"Z周传雄","v":"周传雄演唱会超清"},{"n":"Z张国荣","v":"张国荣演唱会超清"},{"n":"Z周慧敏","v":"周慧敏演唱会超清"},{"n":"Z张惠妹","v":"张惠妹演唱会超清"},{"n":"Z周笔畅","v":"周笔畅演唱会超清"},{"n":"Z郑中基","v":"郑中基演唱会超清"},{"n":"Z张艺兴","v":"张艺兴演唱会超清"},{"n":"Z张震岳","v":"张震岳演唱会超清"},{"n":"Z张雨生","v":"张雨生演唱会超清"},{"n":"Z郑智化","v":"郑智化演唱会超清"},{"n":"Z卓依婷","v":"卓依婷演唱会超清"},{"n":"Z中岛美雪","v":"中岛美雪演唱会超清"}]},{"key":"duration","name":"时长","value":[{"n":"全部","v":"0"},{"n":"60分钟以上","v":"4"},{"n":"30~60分钟","v":"3"},{"n":"10~30分钟","v":"2"},{"n":"10分钟以下","v":"1"}]}]}}
  };

  function headers(referer) {
    return {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0',
      'Referer': referer || 'https://www.bilibili.com',
      'cookie': cfg.cookie
    };
  }

  function api(url, referer) {
    var res = host.get(url, { headers: headers(referer), timeout: 20000 });
    var body = res.json || {};
    // bilibili answers an HTML error page rather than JSON when it dislikes the session, and the
    // SESSDATA three of the four configured sites carry expired in 2025. One retry as the anonymous
    // visitor turns that from an empty category into a listing; measured, it is not rare.
    if (body.code !== 0 && cfg.cookie !== DEFAULT_COOKIE) {
      var previous = cfg.cookie;
      cfg.cookie = DEFAULT_COOKIE;
      res = host.get(url, { headers: headers(referer), timeout: 20000 });
      body = res.json || {};
      if (body.code !== 0) cfg.cookie = previous;
    }
    return body.code === 0 ? (body.data || {}) : {};
  }

  /** A search hit: the API marks the matched words with `<em>`, which is not part of the title. */
  function searchList(results) {
    return (results || []).filter(function (r) { return r.bvid || r.aid; }).map(function (r) {
      return {
        vod_id: String(r.bvid || r.aid),
        vod_name: host.stripTags(String(r.title || '')),
        vod_pic: String(r.pic || '').replace(/^\/\//, 'https://'),
        vod_remarks: r.duration || r.author || ''
      };
    });
  }

  /**
   * The qualities a `playurl` response says this session may have, best first.
   *
   * `accept_quality` and `accept_description` are parallel arrays and the API is the only authority
   * on the wording ('高清 720P', '流畅 360P'), so no local qn-to-name table is kept. They already
   * arrive best first; sorting anyway means the ordering is a property of this code rather than of
   * today's server behaviour.
   */
  function acceptedQualities(playurl) {
    var qns = playurl.accept_quality || [];
    var names = playurl.accept_description || [];
    var lines = qns.map(function (qn, index) {
      // `$` and `#` are CatVod's own separators, so a label carrying one would split a flag list.
      var name = String(names[index] || ('QN ' + qn)).replace(/[$#]/g, ' ').trim();
      return { qn: Number(qn), name: name || ('QN ' + qn) };
    }).filter(function (line) { return line.qn > 0; });
    if (!lines.length) return [{ qn: 64, name: '默認' }];
    return lines.sort(function (a, b) { return b.qn - a.qn; });
  }

  /** `categoryContent` and `searchContent` are the same keyword search in the original. */
  function browse(tid, page, extend) {
    var order = (extend && extend.order) || 'totalrank';
    var duration = (extend && extend.duration) || '0';
    var keyword = String(tid);
    if (extend && extend.tid) keyword += ' ' + extend.tid;
    var data = api('https://api.bilibili.com/x/web-interface/search/type?search_type=video'
                   + '&keyword=' + host.enc(keyword) + '&order=' + order
                   + '&duration=' + duration + '&page=' + (page || '1'),
                   'https://search.bilibili.com');
    return host.result.page(searchList(data.result), page || '1');
  }

  return {
    init: function (extend) {
      var ext = {};
      try { ext = JSON.parse(extend || '{}'); } catch (e) { ext = {}; }
      cfg.json = ext.json || '';
      cfg.home = BUILTIN[ext.n] || null;
      // qist/tvbox `XYQ.jar`: `ext` is the URL of `{"cookie", "classes", "filter"}` itself.
      var source = String(extend || '').trim();
      if (source.indexOf('http') === 0) {
        var doc = host.get(source, { timeout: 20000 }).json || {};
        cfg.home = { 'class': doc.classes || [], filters: doc.filter || {} };
        ext.cookie = doc.cookie;
      }
      var cookie = String(ext.cookie || '');
      // A `cookie` that is a URL points at `{"cookie": "…"}`. TVBox's own file server
      // (`http://127.0.0.1:9978/file/…`) and its `clan://` storage cannot exist here, so neither they
      // nor any other URL whose host is `127.0.0.1` or `localhost` are fetched: the request could only
      // fail, and every later empty page would report it as the reason. The anonymous buvid3 below
      // carries the session, as it does on Android.
      if (/^https?:\/\/(127\.0\.0\.1|localhost)([:/?#]|$)/i.test(cookie) || /^clan:/i.test(cookie)) {
        cookie = '';
      } else if (cookie.indexOf('http') === 0) {
        var fetched = host.get(cookie, { timeout: 10000 }).json || {};
        cookie = String(fetched.cookie || '').trim();
      }
      cfg.cookie = cookie || DEFAULT_COOKIE;
      return '';
    },

    /** The site's own static document already is a CatVod home response; hand it over verbatim. */
    homeContent: function () {
      if (cfg.home) return cfg.home;
      if (!cfg.json) return host.result.home([], []);
      var body = host.get(cfg.json, { timeout: 20000 }).body || '';
      try { return JSON.parse(body); } catch (e) { return host.result.home([], []); }
    },

    categoryContent: function (tid, page, filter, extend) { return browse(tid, page, extend); },

    detailContent: function (ids) {
      var id = String(ids[0]);
      var field = id.indexOf('BV') === 0 ? 'bvid=' : 'aid=';
      var view = api('https://api.bilibili.com/x/web-interface/wbi/view?' + field + host.enc(id));
      var aid = view.aid || id;
      // One `playurl` call, only to learn which qualities this session may have. Its `durl` is
      // discarded: playerContent fetches the one the user actually chose.
      var quality = api('https://api.bilibili.com/x/player/playurl?avid=' + aid
                        + '&cid=' + (view.cid || '') + '&qn=64&fnval=1&fourk=1');
      var lines = acceptedQualities(quality);
      var pages = view.pages || [];
      // Each quality is a *line*, not a `url` array entry, because every quality's real address
      // needs its own `playurl` request: as lines the choice happens before playerContent runs and
      // costs nothing, and the detail screen's existing line UI already presents it.
      var froms = [], urls = [];
      lines.forEach(function (line) {
        froms.push('B站 ' + line.name);
        urls.push(pages.map(function (page) {
          // As with a quality's label: `#` would split the episode list, `$` a name from its address.
          var name = String(page.part || '').replace(/[$#]/g, ' ').trim();
          return (name || ('P' + page.page)) + '$' + aid + '+' + page.cid + '+' + line.qn;
        }).join('#'));
      });
      return host.result.detail({
        vod_id: id,
        vod_name: view.title || '',
        vod_pic: String(view.pic || '').replace(/^\/\//, 'https://'),
        vod_remarks: view.duration ? (Math.round(view.duration / 60) + '分鐘') : '',
        vod_content: view.desc || '',
        vod_actor: (view.owner || {}).name || '',
        vod_director: (view.owner || {}).name || '',
        vod_play_from: froms.join('$$$'),
        vod_play_url: urls.join('$$$')
      });
    },

    // The original's searchContent is literally categoryContent with the keyword as the tid.
    searchContent: function (key, quick, page) { return browse(key, page || '1', {}); },

    playerContent: function (flag, id, vipFlags) {
      var parts = String(id).split('+');
      var aid = parts[0], cid = parts[1];
      // The chosen line put its own `qn` here. The `:`-split survives an id minted by an older
      // version of this script, which listed every accepted quality in one episode.
      var qn = String(parts[2] || '64').split(':')[0];
      // Without a login anything above 80 is refused and the API silently downgrades rather than
      // erroring, so an unauthorised `qn` costs quality, never the stream.
      var data = api('https://api.bilibili.com/x/player/playurl?avid=' + aid + '&cid=' + cid
                     + '&qn=' + qn + '&fnval=1&fourk=1');
      var durl = (data.durl || [])[0] || {};
      var url = durl.url || (durl.backup_url || [])[0] || '';
      if (url) return host.result.play(url, false, headers());
      // No progressive stream: let the sniffer try the watch page.
      return host.result.play('https://www.bilibili.com/video/' + (aid.indexOf('BV') === 0 ? aid : 'av' + aid),
                              true, headers());
    },

    isVideoFormat: host.isVideoFormat,
    manualVideoCheck: function () { return false; },
    destroy: function () { cfg = { cookie: DEFAULT_COOKIE, json: '', home: null }; }
  };
})();

module.exports = spider;
