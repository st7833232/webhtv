/**
 * csp_Douban — ported from `com.github.catvod.spider.Douban` (river-fman.jar, 270 lines; IOS-POC-57B-20).
 *
 * A ranking source, not a player: frodo.douban.com lists (hot movies, hot series, rankings, filtered
 * recommendations) whose every title is `msearch:<douban id>`. Such an id has no lines; the App opens a
 * search for the title across the other sites instead (the `msearch:` route, W-175 commit B). So
 * detail, player and search are empty here, as they are upstream.
 *
 * No signature: a fixed apikey (a plain constant upstream, Douban.java:24) and the WeChat mini-program
 * Referer/UA. Measured 2026-10-20 (W-173 gate): home, hot_gaia, tv_hot, anime_hot, movie filter and a
 * ranking answered 200 from frodo; `api.douban.com` only 301s there, so this asks frodo directly.
 */
var spider = (function () {
  'use strict';

  var API = 'https://frodo.douban.com/api/v2/';
  var KEY = 'apikey=0ac44ae016490db2204ce0a042db2916';
  var HEADERS = {
    'Referer': 'https://servicewechat.com/wx2f9b06c1de1ccfca/84/page-frame.html',
    'User-Agent': 'Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/53.0.2785.143 '
      + 'Safari/537.36 MicroMessenger/7.0.9.501 NetType/WIFI MiniProgramEnv/Windows WindowsWechat'
  };
  // img*.doubanio.com answers 418 without this Referer (gate); the App's ImageRequest reads the suffix.
  var PIC = '@Referer=https://api.douban.com/@User-Agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    + 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36';
  var PAGE = 20;
  var UPDATE = { from: '豆瓣片單（需更新 App）', url: '請更新 WebHTV 到 0.1.82 以上$msearch:update' };

  var CLASSES = [['hot_gaia', '热门电影'], ['tv_hot', '热播剧集'], ['anime_hot', '热门动漫'], ['show_hot', '热播综艺'],
                 ['movie', '电影筛选'], ['tv', '电视筛选'], ['rank_list_movie', '电影榜单'], ['rank_list_tv', '电视剧榜单']];

  function opts(names) { return names.map(function (n) { return { n: n, v: n }; }); }
  function all(label, names) { return [{ n: label, v: '' }].concat(opts(names)); }
  var YEARS = ['2026', '2025', '2024', '2023', '2022', '2021', '2020', '2019', '2010年代', '2000年代', '90年代'];
  var ORDER = function (first) { return [{ n: '近期热度', v: 'T' }, { n: first, v: 'R' }, { n: '高分优先', v: 'S' }]; };
  // Upstream's filter table (Douban.java:265), unchanged.
  var FILTERS = {
    hot_gaia: [
      { key: 'sort', name: '排序', value: [{ n: '热度', v: 'recommend' }, { n: '最新', v: 'time' }, { n: '评分', v: 'rank' }] },
      { key: 'area', name: '地区', value: opts(['全部', '华语', '欧美', '韩国', '日本']) }],
    tv_hot: [{ key: 'type', name: '分类', value: [{ n: '综合', v: 'tv_hot' }, { n: '国产剧', v: 'tv_domestic' },
      { n: '欧美剧', v: 'tv_american' }, { n: '日剧', v: 'tv_japanese' }, { n: '韩剧', v: 'tv_korean' }, { n: '动画', v: 'tv_animation' }] }],
    anime_hot: [
      { key: '类型', name: '类型', value: all('全部', ['热血', '搞笑', '恋爱', '校园', '科幻', '奇幻', '悬疑', '治愈', '运动', '机甲', '少女', '少年']) },
      { key: '地区', name: '地区', value: all('全部', ['日本', '中国大陆', '美国', '韩国', '英国', '法国']) },
      { key: 'sort', name: '排序', value: ORDER('首播时间') },
      { key: '年代', name: '年代', value: all('全部', YEARS.concat(['更早'])) }],
    show_hot: [{ key: 'type', name: '分类', value: [{ n: '综合', v: 'show_hot' }, { n: '国内', v: 'show_domestic' }, { n: '国外', v: 'show_foreign' }] }],
    movie: [
      { key: '类型', name: '类型', value: all('全部类型', ['喜剧', '爱情', '动作', '科幻', '动画', '悬疑', '犯罪', '惊悚', '冒险', '音乐', '历史',
        '奇幻', '恐怖', '战争', '传记', '歌舞', '武侠', '情色', '灾难', '西部', '纪录片', '短片']) },
      { key: '地区', name: '地区', value: all('全部地区', ['华语', '欧美', '中国', '美国', '中国香港', '中国台湾', '韩国', '日本', '英国', '法国',
        '菲律宾', '德国', '意大利', '西班牙', '印度', '泰国', '俄罗斯', '加拿大', '澳大利亚', '爱尔兰', '瑞典', '巴西', '丹麦']) },
      { key: 'sort', name: '排序', value: ORDER('首映时间') },
      { key: '年代', name: '年代', value: all('全部年代', YEARS.concat(['80年代', '70年代', '60年代', '更早'])) }],
    tv: [
      { key: '类型', name: '类型', value: all('不限', ['电视剧', '综艺']) },
      { key: '电视剧形式', name: '电视剧形式', value: all('不限', ['喜剧', '爱情', '悬疑', '动画', '武侠', '古装', '家庭', '犯罪', '科幻', '恐怖',
        '历史', '战争', '动作', '冒险', '传记', '剧情', '奇幻', '惊悚', '灾难', '歌舞', '音乐']) },
      { key: '综艺形式', name: '综艺形式', value: all('不限', ['真人秀', '脱口秀', '音乐', '歌舞']) },
      { key: '地区', name: '地区', value: all('全部地区', ['华语', '欧美', '中国', '美国', '中国香港', '韩国', '日本', '英国', '泰国', '中国台湾',
        '意大利', '法国', '德国', '西班牙', '俄罗斯', '瑞典', '巴西', '丹麦', '印度', '加拿大', '爱尔兰', '澳大利亚']) },
      { key: 'sort', name: '排序', value: ORDER('首播时间') },
      { key: '年代', name: '年代', value: all('全部', YEARS.concat(['80年代', '70年代', '60年代', '更早'])) },
      { key: '平台', name: '平台', value: all('全部', ['腾讯视频', '爱奇艺', '优酷', '湖南卫视', 'Netflix', 'HBO', 'BBC', 'NHK', 'CBS', 'NBC', 'tvN']) }],
    rank_list_movie: [{ key: '榜单', name: '榜单', value: [{ n: '实时热门电影', v: 'movie_real_time_hotest' },
      { n: '一周口碑电影榜', v: 'movie_weekly_best' }, { n: '豆瓣电影Top250', v: 'movie_top250' }] }],
    rank_list_tv: [{ key: '榜单', name: '榜单', value: [{ n: '实时热门电视', v: 'tv_real_time_hotest' },
      { n: '华语口碑剧集榜', v: 'tv_chinese_best_weekly' }, { n: '全球口碑剧集榜', v: 'tv_global_best_weekly' },
      { n: '国内口碑综艺榜', v: 'show_chinese_best_weekly' }, { n: '国外口碑综艺榜', v: 'show_global_best_weekly' }] }]
  };

  function get(path) {
    return host.get(API + path + (path.indexOf('?') === -1 ? '?' : '&') + KEY, { headers: HEADERS, timeout: 15000 }).json || {};
  }

  /** `c()`: every title is `msearch:<id>`; the picture carries the Referer douban's image host wants. */
  function vods(items) {
    return (items || []).map(function (v) {
      var pic = v.pic && v.pic.normal ? v.pic.normal + PIC : '';
      var rating = v.rating && v.rating.value !== undefined && v.rating.value !== null ? '评分：' + v.rating.value : '';
      return { vod_id: 'msearch:' + v.id, vod_name: v.title || '', vod_pic: pic, vod_remarks: rating };
    });
  }

  /**
   * `b()`: the chosen filter values joined by commas, sort excluded. Upstream walks a HashMap and keeps
   * empty values (`喜剧,,2024`); this keeps the table's key order and drops the empty ones.
   */
  function tags(tid, extend) {
    return (FILTERS[tid] || []).map(function (f) { return f.key === 'sort' ? '' : String(extend[f.key] || ''); })
      .filter(Boolean).join(',');
  }

  /** The address and the array that holds its titles, per category (Douban.java:165–241, anime :92–131). */
  function listing(tid, start, extend) {
    var sort = extend.sort || 'T';
    var page = '&start=' + start + '&count=' + PAGE;
    var collection = function (name) { return ['subject_collection/' + host.enc(name) + '/items?' + page.slice(1), 'subject_collection_items']; };
    switch (tid) {
      case 'hot_gaia':
        return ['movie/hot_gaia?sort=' + host.enc(extend.sort || 'recommend') + '&area=' + host.enc(extend.area || '全部') + page, 'items'];
      case 'tv_hot': return collection(extend.type || 'tv_hot');
      case 'show_hot': return collection(extend.type || 'show_hot');
      case 'rank_list_movie': return collection(extend['榜单'] || 'movie_real_time_hotest');
      case 'rank_list_tv': return collection(extend['榜单'] || 'tv_real_time_hotest');
      case 'anime_hot':
        return ['tv/recommend?sort=' + host.enc(sort) + '&tags=' + host.enc(['动画', tags(tid, extend)].filter(Boolean).join(',')) + page, 'items'];
      case 'tv':
        return ['tv/recommend?sort=' + host.enc(sort) + '&tags=' + host.enc(tags(tid, extend)) + page, 'items'];
      default:
        return ['movie/recommend?sort=' + host.enc(sort) + '&tags=' + host.enc(tags('movie', extend)) + page, 'items'];
    }
  }

  return {
    init: function () { return ''; },

    // Upstream hides categories not named in the App's files/config.json `homePage`; WebHTV has no such
    // file (and upstream throws without it), so every category shows.
    homeContent: function () {
      var classes = CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; });
      var hot = get('subject_collection/subject_real_time_hotest/items');
      return host.result.home(classes, vods(hot.subject_collection_items), FILTERS);
    },

    categoryContent: function (tid, page, filter, extend) {
      var pg = Math.max(parseInt(page, 10) || 1, 1);
      var target = listing(String(tid), (pg - 1) * PAGE, extend || {});
      var items = get(target[0])[target[1]] || [];
      // `filterItemsWithoutPic`: recommendations mix in list entries (高分经典喜剧片榜…) that have no picture.
      var list = vods(items).filter(function (v) { return v.vod_pic; });
      // Upstream never ends (pagecount MAX); a short page before that filter is the honest end.
      return host.result.page(list, pg, items.length < PAGE ? pg : pg + 1, PAGE);
    },

    // `msearch:` titles have no lines: the App (0.1.82+) searches the other sites for the name instead and never asks
    // for this detail. An older App does ask; upstream answers nothing and that App spins on 載入詳情 forever, so it
    // gets one line that says why, whose play answers no address (W-175 review D-1, as Libvio's DISK_ONLY).
    detailContent: function (ids) {
      return host.result.detail({ vod_id: String(ids[0]), vod_name: '', vod_pic: '', vod_remarks: '',
        vod_play_from: UPDATE.from, vod_play_url: UPDATE.url });
    },
    searchContent: function () { return { list: [] }; },
    playerContent: function () { return host.result.play('', false); },

    isVideoFormat: host.isVideoFormat,
    manualVideoCheck: function () { return false; },
    destroy: function () {}
  };
})();

module.exports = spider;
