/**
 * csp_XYQHiker — ported from `com.github.catvod.spider.XYQHiker`
 * (xyqxbpq.jar 23487 lines, river-fman.jar 8270 lines).
 *
 * The second rule engine, and like XBPQ one port serves every site configured for it. Where XBPQ
 * slices text between markers, Hiker rules are Jsoup selectors — "`.sTit&&Text`",
 * "`img&&data-echo||data-src||src`", "`.sDes,-1&&Text`", "`Text!简介:`" — so they map straight onto
 * the shared host selector engine and no parsing lives in this file.
 *
 * A site's `ext` is a path to its rule file (`./json/农民影视.json`), resolved against the
 * configuration's own directory by `ConfigSource.resourceURL(for:)` before the session starts, so
 * this spider receives either a URL to fetch or the rules inline.
 */
var spider = (function () {
  'use strict';

  var rule = {};
  var headers = {};
  var searchHeaders = {};

  function text(key, fallback) {
    var value = rule[key];
    return value === undefined || value === null ? (fallback === undefined ? '' : fallback) : String(value);
  }

  function parseHeaders(spec) {
    var out = {};
    String(spec || '').split('#').forEach(function (pair) {
      var i = pair.indexOf('$');
      if (i === -1) return;
      var name = pair.slice(0, i), value = pair.slice(i + 1);
      if (value === '手机' || value === 'MOBILE_UA') {
        value = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
      } else if (value === '电脑' || value === 'PC_UA') {
        value = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36';
      }
      out[name] = value;
    });
    if (!out['User-Agent']) {
      out['User-Agent'] = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
    }
    return out;
  }

  /** "电影&电视剧&综艺" paired with "1&2&3" → [{type_id, type_name}]. */
  function categories() {
    var names = text('分类名称').split('&').filter(Boolean);
    var ids = text('分类名称替换词').split('&').filter(Boolean);
    return names.map(function (name, i) {
      return { type_id: ids[i] === undefined ? name : ids[i], type_name: name };
    });
  }

  function fill(template, values) {
    return String(template || '').replace(/\{([a-zA-Z]+)\}/g, function (_, name) {
      return values[name] === undefined ? '' : values[name];
    });
  }

  function fetch(url, options) {
    return host.get(url, { headers: (options && options.headers) || headers, timeout: 20000 }).body || '';
  }

  /**
   * One list block, shared by home, category and search: they differ only in which rule keys name
   * the array, the fields and the link prefix.
   */
  function extract(html, keys) {
    var scope = html;
    if (keys.outer && text(keys.outer)) {
      var outer = host.pdfa(html, text(keys.outer));
      if (outer.length) scope = outer[0];
    }
    var nodes = host.pdfa(scope, text(keys.array));
    var prefix = text(keys.prefix), suffix = text(keys.suffix);
    var out = [];
    for (var i = 0; i < nodes.length; i++) {
      var link = host.pdfh(nodes[i], text(keys.url));
      var title = host.pdfh(nodes[i], text(keys.title));
      if (!link || !title) continue;
      out.push({
        vod_id: prefix + link + suffix,
        vod_name: title,
        vod_pic: host.urljoin(prefix, host.pdfh(nodes[i], text(keys.pic))),
        vod_remarks: keys.remark ? host.pdfh(nodes[i], text(keys.remark)) : ''
      });
    }
    return out;
  }

  var HOME = { outer: '首页列表数组规则', array: '首页片单列表数组规则', title: '首页片单标题',
               url: '首页片单链接', pic: '首页片单图片', remark: '首页片单副标题',
               prefix: '首页片单链接加前缀', suffix: '首页片单链接加后缀' };
  var CATEGORY = { array: '分类列表数组规则', title: '分类片单标题', url: '分类片单链接',
                   pic: '分类片单图片', remark: '分类片单副标题',
                   prefix: '分类片单链接加前缀', suffix: '分类片单链接加后缀' };
  var SEARCH = { array: 'sea_arr_rule', title: 'sea_title', url: 'sea_url', pic: 'sea_pic',
                 remark: '搜索片单副标题', prefix: '搜索片单链接加前缀', suffix: '搜索片单链接加后缀' };

  return {
    init: function (extend) {
      var raw = String(extend || '').trim();
      // The session hands over either the rules themselves or a URL to fetch them from.
      if (raw.charAt(0) !== '{' && /^https?:\/\//i.test(raw)) {
        raw = host.get(raw, { timeout: 20000 }).body || '{}';
      }
      rule = host.parseJSON(raw) || {};
      headers = parseHeaders(text('请求头参数') || text('请求头'));
      searchHeaders = parseHeaders(text('搜索请求头参数') || text('请求头参数'));
      return '';
    },

    homeContent: function () { return host.result.home(categories(), []); },

    homeVideoContent: function () {
      var url = text('首页推荐链接');
      if (!url || text('是否开启获取首页数据') === '0') return { list: [] };
      return host.result.list(extract(fetch(url), HOME));
    },

    categoryContent: function (tid, page, filter, extend) {
      var url = fill(text('分类链接'), {
        cateId: tid, catePg: String(page || text('分类起始页码', '1')),
        by: (extend && extend.by) || '', year: (extend && extend.year) || '',
        area: (extend && extend.area) || '', 'class': (extend && extend['class']) || '',
        lang: (extend && extend.lang) || '', letter: ''
      });
      if (!url) return { list: [] };
      return host.result.page(extract(fetch(url), CATEGORY), page);
    },

    detailContent: function (ids) {
      var url = String(ids[0]);
      var html = fetch(url);
      var prefix = text('播放链接加前缀') || text('分类片单链接加前缀');

      var froms = [], urls = [];
      var lineNodes = text('线路列表数组规则') ? host.pdfa(html, text('线路列表数组规则')) : [];
      var listNodes = text('播放列表数组规则') ? host.pdfa(html, text('播放列表数组规则')) : [];
      var episodePrefix = text('选集链接加前缀') || prefix || url;
      var episodeSuffix = text('选集链接加后缀');
      var reverse = text('是否反转选集序列') === '1';
      for (var l = 0; l < listNodes.length; l++) {
        var items = host.pdfa(listNodes[l], text('选集列表数组规则') || 'li');
        var episodes = [];
        for (var e = 0; e < items.length; e++) {
          var link = host.pdfh(items[e], text('选集链接') || 'a&&href');
          var label = host.pdfh(items[e], text('选集标题') || 'a&&Text');
          if (!link || !label) continue;
          // A "$" inside either half would corrupt the name$url encoding the app splits on.
          episodes.push(label.split('$').join('') + '$' +
                        host.urljoin(episodePrefix, link) + episodeSuffix);
        }
        if (reverse) episodes.reverse();
        if (episodes.length) {
          froms.push(lineNodes[l] ? host.pdfh(lineNodes[l], text('线路标题') || 'Text') : ('线路' + (l + 1)));
          urls.push(episodes.join('#'));
        }
      }

      return host.result.detail({
        vod_id: url,
        // These pages put a breadcrumb in <h1>, so the document title is the better fallback
        // when a rule file names no title rule of its own.
        vod_name: host.pdfh(html, text('详情标题') || 'title&&Text').split(/[-_|]/)[0].trim(),
        vod_pic: host.pdfh(html, text('详情图片') || 'img&&src'),
        vod_year: host.pdfh(html, text('年代详情')),
        vod_area: host.pdfh(html, text('地区详情')),
        vod_actor: host.pdfh(html, text('演员详情')),
        type_name: host.pdfh(html, text('类型详情')),
        vod_content: host.pdfh(html, text('简介详情')),
        vod_play_from: froms.join('$$$'),
        vod_play_url: urls.join('$$$')
      });
    },

    searchContent: function (key, quick, page) {
      var spec = text('search_url');
      if (!spec) return { list: [] };
      // "url;post" selects the method; the body template lives in sea_PtBody.
      var parts = spec.split(';');
      var url = fill(parts[0], { wd: host.enc(key), SearchPg: String(page || '1') });
      var isPost = (parts[1] || '').toLowerCase() === 'post';
      var body = fill(text('sea_PtBody'), { wd: key, SearchPg: String(page || '1') });
      var res = isPost
        ? host.post(url, body, { headers: searchHeaders, timeout: 20000 })
        : host.get(url, { headers: searchHeaders, timeout: 20000 });
      return host.result.list(extract(res.body || '', SEARCH));
    },

    playerContent: function (flag, id) {
      if (text('链接是否直接播放') === '1') {
        return host.result.play(text('直接播放链接加前缀') + id + text('直接播放链接加后缀'),
                                false, parseHeaders(text('直接播放直链视频请求头')));
      }
      var html = fetch(String(id));
      var url = host.match(html, '"url"\\s*:\\s*"([^"]+)"').replace(/\\\//g, '/');
      if (!url) url = host.match(html, 'var\\s+now\\s*=\\s*"([^"]+)"');
      if (!url) url = host.match(html, '(https?:[^"\'\\s\\\\$#]+\\.(?:m3u8|mp4|mkv|flv)[^"\'\\s\\\\$#]*)');
      if (url && /\.(m3u8|mp4|mkv|flv)/i.test(url)) return host.result.play(url, false, headers);
      return host.result.play(String(id), true, headers);
    },

    isVideoFormat: function (url) { return /\.(m3u8|mp4|mkv|flv)(\?|$)/i.test(String(url)); },
    manualVideoCheck: function () { return false; },
    destroy: function () { rule = {}; headers = {}; searchHeaders = {}; }
  };
})();

module.exports = spider;
