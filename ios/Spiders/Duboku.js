/**
 * Duboku (独播库) spider.
 * Port of com.github.catvod.spider.Duboku from qist spider.jar (IOS-POC-57B-5, design W-25).
 * Source host: https://api.dbokutv.com (signed JSON GET); media is HLS on vid.dbokutv.com.
 */
(function () {
  'use strict';

  var API = 'https://api.dbokutv.com';
  var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36';
  // Upstream's `Connection: Keep-Alive` is hop-by-hop; URLSession manages the connection itself.
  var HEADERS = { 'User-Agent': UA, 'Referer': 'https://www.duboku.tv/' };
  var CLASSES = [['1', '电影'], ['2', '电视剧'], ['3', '综艺'], ['4', '动漫'], ['21', '短剧'],
                 ['20', '港剧'], ['13', '陆剧'], ['15', '日韩剧'], ['14', '台泰剧']];
  var ALPHA_SIGN = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
  var ALPHA_TOKEN = 'XYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVW';

  // ---- filters: Duboku.java:180, rebuilt from its three distinct sets (a test pins the exact JSON).
  // W-177: 2026 prepended to each year row — the live API already serves 2026 titles (fixtures) and
  // accepts any year, so the dropdown just needs it; upstream Duboku.java adds the new year yearly. ----
  function row(key, names) {
    return { key: key, name: key, value: names.split(' ').map(function (n) { return { n: n, v: n === '时间' ? '' : n }; }) };
  }
  var LETTER = row('letter', 'A B C D E F G H I J K L M N O P Q R S T U V W X Y Z 0~9');
  var BY = row('by', '时间 人气 评分');
  var MOVIE = [row('class', '喜剧 爱情 恐怖 动作 科幻 剧情 警匪 战争 犯罪 动画 奇幻 武侠 冒险 悬疑 惊悚 古装 同性'),
               row('area', '大陆 香港 台湾 韩国 英国 法国 加拿大 澳大利亚'), row('year', '2026 2025 2024 2023 2022 2020 2019'),
               row('lang', '国语 粤语 韩语 英语 法语'), LETTER, BY];
  var SERIES = [row('class', '悬疑 武侠 科幻 都市 爱情 古装 战争 青春 偶像 喜剧 家庭 奇幻 剧情 乡村 年代 警匪 谍战 历险 罪案 宫廷 经典 动作 惊悚 历史 穿越 同性'),
                row('area', '大陆 香港 台湾 韩国 日本 新加坡 泰国'), row('year', '2026 2025 2024 2023 2022 2021 2020 2019 2018 2017 更早'),
                row('lang', '国语 粤语 韩语 泰语 日语'), LETTER, BY];
  var VARIETY = [row('class', '真人秀 选秀 竞演 情感 旅游 音乐 美食 纪实 生活 游戏互动 竞技 搞笑 脱口秀'),
                 row('area', '大陆 韩国'), row('year', '2026 2025 2024 2023 2022 2021 2020 2019 更早'),
                 row('lang', '国语 韩语'), LETTER, BY];
  var FILTERS = { '1': MOVIE, '2': SERIES, '3': VARIETY, '4': SERIES, '13': SERIES, '14': SERIES,
                  '15': SERIES, '20': SERIES, '21': SERIES };

  // ---- java.util.Random, whose sequence the server checks (Random.java :395, :424–426, :510–521) ----
  var MULTIPLIER = 0x5DEECE66Dn, MASK = (1n << 48n) - 1n;
  function JavaRandom(seed) { this.seed = (BigInt(seed) ^ MULTIPLIER) & MASK; }
  JavaRandom.prototype.next = function (bits) {
    this.seed = (this.seed * MULTIPLIER + 0xBn) & MASK;
    return Number(BigInt.asIntN(32, this.seed >> BigInt(48 - bits)));
  };
  // shortcut: no power-of-two branch; the only bounds here are 62 and 800000000. Add Java's branch before using a power of two.
  JavaRandom.prototype.nextInt = function (bound) {
    var u = this.next(31), r = u % bound;
    // Java's `u - r + (bound - 1) < 0` is an int overflow test; Number arithmetic is exact, so compare with 2^31 - 1.
    while (u - r + bound - 1 > 0x7fffffff) { u = this.next(31); r = u % bound; }
    return r;
  };

  function pick(length, seed, alphabet) {
    var random = new JavaRandom(seed), out = '';
    for (var i = 0; i < length; i++) out += alphabet.charAt(random.nextInt(alphabet.length));
    return out;
  }

  // Duboku.java:45–70, from one clock reading (upstream reads it four times and can straddle a second).
  // ssid has no trailing newline, unlike Android's Base64.DEFAULT; the server accepts it (W-19).
  function sign() {
    var ms = host.now(), t = Math.floor(ms / 1000), r = new JavaRandom(t).nextInt(800000000);
    var a = String(100000000 + r) + String(900000000 - r), b = String(ms), mixed = '';
    var n = Math.min(a.length, b.length);
    for (var i = 0; i < n; i++) mixed += a.charAt(i) + b.charAt(i);
    mixed += a.substring(n) + b.substring(n);
    // a(60, 60 + t, 33) and a(38, t + 38, 88) add the current second again inside a(): seeds 2t+60 and 2t+38.
    return '?sign=' + pick(60, 2 * t + 60, ALPHA_SIGN) + '&ssid=' + host.base64.encode(mixed).replace(/=/g, '.')
      + '&token=' + pick(38, 2 * t + 38, ALPHA_TOKEN);
  }

  // Duboku.java:78–88: reverse every 10 characters, '.' back to '=', base64. '' when it does not decode.
  function decode(value) {
    var s = text(value), flipped = '';
    for (var i = 0; i < s.length; i += 10) flipped += s.substring(i, i + 10).split('').reverse().join('');
    return host.base64.decode(flipped.replace(/\./g, '='));
  }

  function text(value) { return value === null || value === undefined ? '' : String(value); }

  function pageNumber(pg) {
    var s = text(pg);
    return /^[+-]?\d+$/.test(s) ? Math.max(1, parseInt(s, 10)) : 1;
  }

  // `path` already starts with '/'; the signature is the whole query, so it goes right after the path.
  function api(path, query) {
    var res = host.get(API + path + sign() + (query || ''), { headers: HEADERS, timeout: 15000 });
    return res.status === 200 && res.json ? res.json : null;
  }

  // Tag, else Rating as Java prints a double ("8.0分"), else nothing (Duboku.java:120–126).
  function remarks(item) {
    if (typeof item.Tag === 'string') return item.Tag;
    if (typeof item.Rating === 'number') return (Number.isInteger(item.Rating) ? item.Rating.toFixed(1) : String(item.Rating)) + '分';
    return '';
  }

  // vod_id is d(DId), e.g. /voddetail/149953: the same from home, category and search, so history stays stable.
  function vods(list) {
    var out = [];
    (Array.isArray(list) ? list : []).forEach(function (item) {
      if (!item || typeof item !== 'object') return;
      var id = decode(item.DId);
      if (id.indexOf('/voddetail/') !== 0) return;
      out.push({ vod_id: id, vod_name: text(item.Name), vod_pic: decode(item.TnId), vod_remarks: remarks(item) });
    });
    return out;
  }

  var spider = {
    init: function (extend) { return ''; },

    homeContent: function (filter) {
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }), null, FILTERS);
    },

    // Upstream's homeContent also lists /home (Duboku.java:181–200); here it is the home video row.
    homeVideoContent: function () {
      var sections = api('/home');
      var all = [];
      (Array.isArray(sections) ? sections : []).forEach(function (section) {
        all = all.concat(vods(section && section.VodList));
      });
      return host.result.list(all);
    },

    // /vodshow/{cateId}-{area}-{by}-{class}-{lang}----{pg}---{year} (Duboku.java:96–107), each part URL-encoded.
    categoryContent: function (tid, pg, filter, extend) {
      var ext = extend || {}, page = pageNumber(pg);
      function part(key, fallback) { return encodeURIComponent(text(ext[key] === undefined ? fallback : ext[key])); }
      var path = '/vodshow/' + part('cateId', tid) + '-' + part('area', '') + '-' + part('by', '') + '-'
        + part('class', '') + '-' + part('lang', '') + '----' + page + '---' + part('year', '');
      var data = api(path);
      // Upstream's paging, unbounded: 48 a page, ceil(2^31-1 / 48) pages (Duboku.java:111, :130).
      return host.result.page(vods(data && data.VodList), page, 44739243, 48, 2147483647);
    },

    detailContent: function (ids) {
      var id = text(ids && ids[0]);
      if (id.indexOf('/voddetail/') !== 0) return host.result.list([]);
      var d = api(id);
      if (!d || !Array.isArray(d.Playlist)) return host.result.list([]);
      // Play ids are just d(VId): upstream's "|episode|title" tail only fed its danmaku proxy.
      var episodes = [];
      d.Playlist.forEach(function (ep) {
        var path = ep && typeof ep === 'object' ? decode(ep.VId) : '';
        if (!/^\/vodplay\/[^$#]*$/.test(path)) return;
        episodes.push(text(ep.EpisodeName).replace(/[$#]/g, ' ') + '$' + path);
      });
      return host.result.detail({
        vod_id: id,
        vod_name: text(d.Name),
        vod_pic: decode(d.TnId),
        vod_year: text(d.ReleaseYear),
        vod_content: text(d.Description),
        // Upstream sends the Actor array's JSON text; the app shows vod_actor as plain text, so names joined by ','.
        vod_actor: Array.isArray(d.Actor) ? d.Actor.filter(function (a) { return typeof a === 'string'; }).join(',') : '',
        vod_director: text(d.Director),
        vod_play_from: episodes.length ? '独播库' : '',
        vod_play_url: episodes.join('#')
      });
    },

    // Upstream asks once and ignores the page (Duboku.java:229–252).
    searchContent: function (key, quick, pg) {
      var wd = text(key).trim();
      if (!wd) return host.result.list([]);
      return host.result.list(vods(api('/vodsearch', '&wd=' + encodeURIComponent(wd))));
    },

    // Accepts upstream's older "path|episode|title" ids too (Duboku.java:213–219).
    playerContent: function (flag, id, vipFlags) {
      var path = text(id).split('|')[0];
      var d = path.indexOf('/vodplay/') === 0 ? api(path) : null;
      var url = d ? decode(d.HId) : '';
      if (!/^https?:\/\//.test(url)) return host.result.play('', false);
      return host.result.play(url, false, { 'User-Agent': UA, 'Origin': 'https://w.duboku.io', 'Referer': 'https://w.duboku.io/' });
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
