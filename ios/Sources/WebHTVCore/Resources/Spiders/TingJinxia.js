/**
 * TingJinxia (堇夏听书) spider: audiobooks.
 * Port of com.github.catvod.spider.TingJinxia from qist spider.jar (IOS-POC-57B-12, gate W-95).
 * Source host: https://m.ting15.com (HTML pages, a form POST for each episode's audio);
 * audio is m4a on oss-links.guoguo.org.cn, which answers 400 without the Referer.
 */
(function () {
  'use strict';

  var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36';
  // Upstream writes the poster headers with this host whatever the site's ext says (TingJinxia.java:91–92).
  var POSTER = '@Referer=https://m.ting15.com/@User-Agent=' + UA;
  var CLASSES = [['wuxiaxuanhuan', '武侠玄幻'], ['kongbulingyi', '恐怖灵异'], ['tuilixuanyi', '推理悬疑'],
                 ['dushiyanqing', '都市言情'], ['jiatinglunli', '家庭伦理'], ['wenxuemingzhu', '文学名著'],
                 ['jingdianpingshu', '经典评书'], ['quyixiqu', '曲艺戏曲'], ['xiangshengxiaopin', '相声小品']];
  var ORDER = [{ key: 'order', name: '排序', value: [{ n: '全部', v: '' }, { n: '热门', v: 'hits' }, { n: '最新', v: 'addtime' }] }];
  // Site paths this spider asks for or hands out: no '..', query or separator can get in.
  var PATH = /^\/[A-Za-z0-9_\/-]+\.html$/;

  var base = 'https://m.ting15.com';

  function value(v) { return v === null || v === undefined ? '' : String(v); }
  function clean(s) { return value(s).replace(/\s+/g, ' ').trim(); }
  function textOf(nodes) { return clean(nodes.map(function (n) { return host.text(n); }).join(' ')); }
  function attr(root, selector, name) {
    var nodes = host.select(root, selector);
    return nodes.length ? clean(nodes[0].attrs[name]) : '';
  }

  function pageNumber(pg) {
    var s = value(pg);
    return /^[+-]?\d+$/.test(s) ? Math.max(1, parseInt(s, 10)) : 1;
  }

  // TingJinxia.java:42–63, for this spider's own '/'-rooted paths.
  function page(path) {
    var res = host.get(base + path, { timeout: 15000, headers: {
      'User-Agent': UA, 'Referer': base + '/', 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    } });
    return host.parse(res.status === 200 ? value(res.body) : '');
  }

  function poster(src) { return src && src.indexOf('@Referer=') < 0 ? src + POSTER : src; }

  // Upstream's c() (:66–123), one card per book: the front page lists some books twice (W-106 §2.7).
  function books(root) {
    var links = host.select(root, '.clist > a[href]');
    // Upstream's fallback is `section a[href$=.html]:has(h3)`; host.js has no `$=` (gate adaptation 1).
    if (!links.length) {
      links = host.select(root, 'section a[href]:has(h3)').filter(function (a) { return /\.html$/.test(clean(a.attrs.href)); });
    }
    var out = [], seen = {};
    for (var i = 0; i < links.length && out.length < 95; i++) {
      var a = links[i], href = clean(a.attrs.href);
      if (!PATH.test(href) || seen[href]) continue;
      var name = textOf(host.select(a, 'h3')), close = name.indexOf(']');
      if (name.charAt(0) === '[' && close >= 0 && close + 1 < name.length) name = name.substring(close + 1).trim();
      if (!name) name = textOf([a]);
      if (!name) continue;
      var remarks = '听书', lines = host.select(a, 'dd p');
      for (var j = 0; j < lines.length; j++) {
        var line = textOf([lines[j]]);
        if (line.indexOf('连载') === 0 || line.indexOf('状态') === 0) {
          remarks = line.replace('状态：', '').replace('状态:', '').trim();
          if (remarks.indexOf('连载') === 0) remarks = remarks.replace('连载：', '').replace('连载:', '').trim();
          break;
        }
      }
      seen[href] = true;
      out.push({ vod_id: href, vod_name: name, vod_pic: poster(attr(a, 'dt img', 'src') || attr(a, 'img', 'src')), vod_remarks: remarks });
    }
    return out;
  }

  // The bytecode splits a `.cpage span` that **does** contain '/' (jadx prints the test inverted;
  // gate upstream-pagecount-bytecode.txt). Unreadable leaves the page itself.
  function pageCount(root, current) {
    var spans = host.select(root, '.cpage span');
    for (var i = 0; i < spans.length; i++) {
      var parts = textOf([spans[i]]).split('/');
      if (parts.length >= 2 && /^\d+$/.test(parts[1].trim())) return Math.max(parseInt(parts[1].trim(), 10), current);
    }
    return current;
  }

  // `.binfo p` that starts with `label` (:29–38).
  function info(root, label) {
    var lines = host.select(root, '.binfo p');
    for (var i = 0; i < lines.length; i++) {
      var line = textOf([lines[i]]);
      if (line.indexOf(label) === 0 && line.length > label.length) return line.substring(label.length).trim().replace(/：/g, '');
    }
    return '';
  }

  // Java's URLEncoder: like encodeURIComponent, but a space is '+' and !'()~ are escaped.
  function formEncode(s) {
    return encodeURIComponent(s).replace(/%20/g, '+').replace(/[!'()~]/g, function (c) {
      return '%' + c.charCodeAt(0).toString(16).toUpperCase();
    });
  }

  // Strips the reply's UTF-8 BOM (gate adaptation 3: host.js only parses JSON starting with { or [).
  function audioFrom(body) {
    var reply;
    try { reply = JSON.parse(value(body).replace(/^﻿/, '')); } catch (e) { return ''; }
    if (!reply || typeof reply !== 'object' || Number(reply.status) !== 1) return '';
    return value(reply.url) || value(reply.ourl);
  }

  var spider = {
    init: function (extend) {
      var ext = clean(extend);
      if (/^https?:\/\/[^\s\/]+/.test(ext)) base = ext.replace(/\/+$/, '');
      return '';
    },

    homeContent: function (filter) {
      var filters = {};
      CLASSES.forEach(function (c) { filters[c[0]] = ORDER; });
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }), null, filters);
    },

    // Upstream's homeContent also lists the front page (:254–257); here it is the home video row.
    homeVideoContent: function () {
      return host.result.list(books(page('/')));
    },

    categoryContent: function (tid, pg, filter, extend) {
      var id = value(tid), current = pageNumber(pg);
      if (!/^[a-z]+$/.test(id)) return host.result.page([], current, current, 0, 0);
      var order = value(extend && extend.order);
      if (order !== 'hits' && order !== 'addtime') order = '';
      // Upstream's `/<tid>/index<pg>` is a 404; the site's own next link has `.html` (gate adaptation 2).
      var path = order ? '/' + id + '/index' + current + '-order-' + order + '.html'
        : current <= 1 ? '/' + id + '/' : '/' + id + '/index' + current + '.html';
      var root = page(path), list = books(root);
      // Limit and total are this page's count, as upstream reports them (:164).
      return host.result.page(list, current, pageCount(root, current), list.length, list.length);
    },

    detailContent: function (ids) {
      var id = value(ids && ids[0]);
      if (!PATH.test(id)) return host.result.list([]);
      var root = page(id), content = '';
      var intro = host.select(root, '.intro p');
      for (var i = 0; i < intro.length; i++) {
        var line = textOf([intro[i]]);
        if (line && line.indexOf('看APP') < 0 && line.length > 20) { content = line; break; }
      }
      // One select and a join: a book here can run to thousands of episodes (3977 in the gate).
      var episodes = [];
      host.select(root, '.plist a.f').forEach(function (a) {
        var href = clean(a.attrs.href), name = textOf([a]).replace(/[$#]/g, ' ').trim();
        if (PATH.test(href) && name) episodes.push(name + '$' + href);
      });
      return host.result.detail({
        vod_id: id,
        vod_name: textOf(host.select(root, '.binfo h1')),
        vod_pic: poster(attr(root, '.bimg img', 'src')),
        vod_content: content,
        vod_actor: info(root, '作者'),
        vod_director: info(root, '播音'),
        type_name: info(root, '类型'),
        vod_remarks: info(root, '状态'),
        vod_play_from: '堇夏',
        vod_play_url: episodes.join('#')
      });
    },

    // The chapter page's meta, then the neoplay form POST for the audio (:279–334). Nothing found is
    // no address: upstream's chapter-page fallback would start the App's web sniffer for an audiobook.
    playerContent: function (flag, id, vipFlags) {
      var path = value(id);
      if (path.indexOf('$') >= 0) path = path.substring(path.lastIndexOf('$') + 1);
      if (path.charAt(0) !== '/') path = '/' + path;
      if (!PATH.test(path)) return host.result.play('', false);
      var root = page(path), book = attr(root, 'meta[name=_b]', 'content'), pay = attr(root, 'meta[name=_p]', 'content');
      var url = '';
      if (book && pay) {
        var form = { bookId: book, isPay: pay, page: attr(root, 'meta[name=_cp]', 'content') || '1' };
        var xt = attr(root, 'meta[name=_c]', 'content');
        if (xt) form.xt = xt;
        var res = host.post(base + '/?s=api-getneoplay', form, { timeout: 15000, headers: { 'User-Agent': UA, 'Referer': base + path } });
        url = res.status === 200 ? audioFrom(res.body) : '';
      }
      if (!url) url = attr(root, 'audio#player', 'src');
      if (!/^https?:\/\//.test(url)) return host.result.play('', false);
      // The path carries Chinese as is (gate adaptation 4); an address already escaped stays as it is.
      if (!/%[0-9A-Fa-f]{2}/.test(url)) url = encodeURI(url);
      return host.result.play(url, false, { 'User-Agent': UA, 'Referer': base + '/' });
    },

    // One page, as upstream asks (:337).
    searchContent: function (key, quick, pg) {
      var wd = value(key).trim();
      if (!wd) return host.result.list([]);
      return host.result.list(books(page('/?s=ting-search-wd-' + formEncode(wd))));
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
