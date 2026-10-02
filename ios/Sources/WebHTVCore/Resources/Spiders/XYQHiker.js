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
  var VIDEO = /\.(m3u8|mp4|mkv|flv)(\?|$)/i;

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

  /**
   * Hiker lets a listing template carry `[firstPage=<template>]`: the first page uses that
   * template and every later page the main one. 巴士动漫 and 動漫巴士 list page 1 at
   * `/list-{cateId}.html` and the rest at `/list-{cateId}-{catePg}.html`; ignoring the marker
   * requests a literal "…html[firstPage=…]" and the category comes back empty.
   */
  function pickTemplate(raw, page, startPage) {
    var match = /^([\s\S]*?)\[firstPage=([\s\S]*?)\]\s*$/.exec(String(raw || ''));
    if (!match) return String(raw || '');
    return String(page) === String(startPage) ? match[2] : match[1];
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
  /** First key that the rule file actually defines; a key may name a fallback after itself. */
  function ruleFor(spec) {
    var names = typeof spec === 'string' ? [spec] : (spec || []);
    for (var i = 0; i < names.length; i++) {
      var value = text(names[i]);
      if (value) return value;
    }
    return '';
  }

  /**
   * A site that now writes absolute links behind a rule whose prefix is only its origin (小嫂子,
   * Ujizzcn) would otherwise get "https://a.comhttps://…". A prefix with a path or query is kept
   * as written: "https://jx.example/?url=" in front of an absolute link is a parse API.
   */
  function joinPrefix(prefix, link) {
    return /^https?:\/\//i.test(link) && /^https?:\/\/[^\/?#]+\/?$/i.test(prefix) ? link : prefix + link;
  }

  /**
   * The stream a play page names in its own HTML: a player config's "url", MacCMS's `var now`, or
   * the first media URL whose extension ends its path ("preview.m3u8.jpg" is a thumbnail). A
   * "…?url=https://…" parse wrapper is peeled off (jiedm's 155jx.com).
   */
  function mediaIn(html) {
    var url = host.match(html, '"url"\\s*:\\s*"([^"]+)"').replace(/\\\//g, '/');
    if (!url) url = host.match(html, 'var\\s+now\\s*=\\s*"([^"]+)"');
    if (!url) url = host.match(html, '(https?:[^"\'\\s\\\\$#]+\\.(?:m3u8|mp4|mkv|flv)(?=[?"\'\\s\\\\]|$)[^"\'\\s\\\\$#]*)');
    url = url.replace(/^https?:\/\/[^?#]*\?url=(https?:)/i, '$1');
    // ponytail: path words catch the pre-roll ads seen so far (正妹AV's /media/ads/, /media/preroll/);
    // collect every candidate and pick one if an ad elsewhere starts winning.
    return VIDEO.test(url) && !/\/(ads?|preroll)\//i.test(url) ? url : '';
  }

  function extract(html, keys) {
    var scope = html;
    if (keys.outer && text(keys.outer)) {
      var outer = host.pdfa(html, text(keys.outer));
      if (outer.length) scope = outer[0];
    }
    var urlRule = ruleFor(keys.url);
    // An empty rule makes `pdfh` fall back to the node's own text, which would make every field —
    // including `vod_id` — the title. `detailContent` then fetches that title as a URL and the
    // whole listing silently yields no episodes, which is exactly how 巴士动漫 presented.
    if (!urlRule) return [];
    var nodes = host.pdfa(scope, ruleFor(keys.array));
    var prefix = ruleFor(keys.prefix), suffix = ruleFor(keys.suffix);
    var titleRule = ruleFor(keys.title), picRule = ruleFor(keys.pic), remarkRule = ruleFor(keys.remark);
    var out = [];
    for (var i = 0; i < nodes.length; i++) {
      var link = host.pdfh(nodes[i], urlRule);
      var title = host.pdfh(nodes[i], titleRule);
      if (!link || !title) continue;
      out.push({
        vod_id: joinPrefix(prefix, link) + suffix,
        vod_name: title,
        vod_pic: host.urljoin(prefix, host.pdfh(nodes[i], picRule)),
        vod_remarks: remarkRule ? host.pdfh(nodes[i], remarkRule) : ''
      });
    }
    return out;
  }

  // A rule file may give the home block only its array rules and leave the per-field ones to the
  // 分类片单* set — 巴士动漫 and 動漫巴士 both do. Each field therefore names its own key first and
  // the category key as the fallback, which is what Hiker does.
  var HOME = { outer: '首页列表数组规则', array: '首页片单列表数组规则',
               title: ['首页片单标题', '分类片单标题'],
               url: ['首页片单链接', '分类片单链接'],
               pic: ['首页片单图片', '分类片单图片'],
               remark: ['首页片单副标题', '分类片单副标题'],
               prefix: ['首页片单链接加前缀', '分类片单链接加前缀'],
               suffix: ['首页片单链接加后缀', '分类片单链接加后缀'] };
  var CATEGORY = { array: '分类列表数组规则', title: '分类片单标题', url: '分类片单链接',
                   pic: '分类片单图片', remark: '分类片单副标题',
                   prefix: '分类片单链接加前缀', suffix: '分类片单链接加后缀' };
  // The original reads the Chinese search keys and falls back to the English ones; 45 of the 47 adult
  // rule files, 巴士动漫 and 動漫巴士 write only the Chinese, so their search always came back empty.
  var SEARCH = { array: ['搜索列表数组规则', 'sea_arr_rule'], title: ['搜索片单标题', 'sea_title'],
                 url: ['搜索片单链接', 'sea_url'], pic: ['搜索片单图片', 'sea_pic'],
                 remark: '搜索片单副标题', prefix: '搜索片单链接加前缀', suffix: '搜索片单链接加后缀' };

  /**
   * 搜索截取模式 0 means the search answers JSON — MacCMS's `ajax/suggest` in all 15 rule files that
   * set it. The array rule is a dotted path and each field rule names a key, defaulting to the
   * original's `list`, `name`, `id` and `pic`.
   */
  function listFromJSON(body) {
    var items = (ruleFor(SEARCH.array) || 'list').split('.').reduce(function (node, name) {
      return node && node[name];
    }, host.parseJSON(body));
    var title = ruleFor(SEARCH.title) || 'name', link = ruleFor(SEARCH.url) || 'id';
    var pic = ruleFor(SEARCH.pic) || 'pic', prefix = ruleFor(SEARCH.prefix), suffix = ruleFor(SEARCH.suffix);
    var out = [];
    (Array.isArray(items) ? items : []).forEach(function (item) {
      if (!item || !item[title] || item[link] === undefined) return;
      out.push({ vod_id: joinPrefix(prefix, String(item[link])) + suffix, vod_name: String(item[title]),
                 vod_pic: host.urljoin(prefix, String(item[pic] || '')), vod_remarks: '' });
    });
    return out;
  }

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
      var startPage = text('分类起始页码', '1');
      var pageNumber = String(page || startPage);
      var url = fill(pickTemplate(text('分类链接'), pageNumber, startPage), {
        cateId: tid, catePg: pageNumber,
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
      // These pages put a breadcrumb in <h1>, so the document title is the better fallback
      // when a rule file names no title rule of its own.
      var name = host.pdfh(html, text('详情标题') || 'title&&Text').split(/[-_|]/)[0].trim();
      // Hiker's direct-play mode never reads the playlist rules: the listing's link is the play
      // page and the title its only episode. 44 of the 47 adult rule files set it, most beside a
      // template `.line` playlist rule that matches nothing, so every one showed no episodes.
      var direct = /^(1|是)$/.test(text('链接是否直接播放') || text('force_play'));

      var froms = [], urls = [];
      var lineNodes = text('线路列表数组规则') ? host.pdfa(html, text('线路列表数组规则')) : [];
      var listNodes = !direct && text('播放列表数组规则') ? host.pdfa(html, text('播放列表数组规则')) : [];
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
      if (direct) {
        // "$" and "#" would split the name$url#name$url encoding the app reads.
        var label = name.replace(/[$#]/g, '') || '播放';
        froms = [label];
        urls = [label + '$' + url];
      }

      return host.result.detail({
        vod_id: url,
        vod_name: name,
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
      var spec = text('搜索链接') || text('search_url');
      if (!spec) return { list: [] };
      // "url;post" selects the method; the body template lives in POST请求数据 (sea_PtBody).
      var parts = spec.split(';');
      var url = fill(parts[0], { wd: host.enc(key), SearchPg: String(page || '1') });
      var isPost = (parts[1] || '').toLowerCase() === 'post';
      var body = fill(text('POST请求数据') || text('sea_PtBody'), { wd: key, SearchPg: String(page || '1') });
      var res = isPost
        ? host.post(url, body, { headers: searchHeaders, timeout: 20000 })
        : host.get(url, { headers: searchHeaders, timeout: 20000 });
      return host.result.list(/^(0|否)$/.test(text('搜索截取模式') || text('search_mode'))
        ? listFromJSON(res.body || '') : extract(res.body || '', SEARCH));
    },

    playerContent: function (flag, id) {
      if (/^[12]$/.test(text('链接是否直接播放') || text('force_play'))) {
        var target = joinPrefix(text('直接播放链接加前缀'), String(id)) + text('直接播放链接加后缀');
        var playHeaders = text('直接播放直链视频请求头') ? parseHeaders(text('直接播放直链视频请求头')) : headers;
        if (VIDEO.test(target)) return host.result.play(target, false, playHeaders);
        // The original hands the page to Android's sniffer, which sees every request the page makes,
        // iframes included. `MediaSniffer`'s script hook misses most of these players, so read what
        // the page and its embed frame say first and only then let the app sniff.
        var page = fetch(target);
        var found = mediaIn(page);
        var embed = found ? '' : host.match(page, '<iframe[^>]+src=["\']([^"\']*embed[^"\']*)');
        if (embed) found = mediaIn(fetch(host.urljoin(target, embed)));
        return found ? host.result.play(found, false, playHeaders) : host.result.play(target, true, playHeaders);
      }
      var url = mediaIn(fetch(String(id)));
      return url ? host.result.play(url, false, headers) : host.result.play(String(id), true, headers);
    },

    isVideoFormat: function (url) { return VIDEO.test(String(url)); },
    manualVideoCheck: function () { return false; },
    destroy: function () { rule = {}; headers = {}; searchHeaders = {}; }
  };
})();

module.exports = spider;
