/**
 * Ikanbot (爱看机器人) spider.
 * Port of com.github.catvod.spider.Ikanbot from qist j-spider.jar (W-41, gate W-14/W-18 `qist-ikanbot-gate-2026-10-09.md`).
 * Source host: https://www1.ikanbot.com (HTML lists and detail, a JSON line list from /api/getResN).
 *
 * Differences from upstream, all deliberate (gate §6.4):
 * - Every list gives the canonical href (`/play/995772`) as vod_id, not `href$$$name$$$poster`, so watch history
 *   survives a poster change; detail still accepts the old compound id.
 * - The 片单 (kanlist) category returns folders: its result is built here with `vod_tag`, because
 *   `host.result.page` drops it. Folder posters are not wrapped by `d()`, video posters are (upstream).
 * - Filters apply whenever extend has a value: iOS always passes `filter = false` (gate §6.3).
 * - `[排序:]` moves every matching line once, in key order (upstream skips the second of two adjacent matches).
 * - Detail takes its title from `h1` and its poster from `img.cover@data-src`, not from the compound id.
 */
(function () {
  'use strict';

  var HOST = 'https://www1.ikanbot.com';
  var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36';
  var CLASSES = [['hot/index-movie-热门', '电影'], ['hot/index-tv-热门', '剧集'], ['billboard', '榜单'], ['kanlist/全部', '片单']];
  // Ikanbot.java:313, verbatim (its stray spaces included: "kanlist/ 科幻", "豆瓣高 分", "冷 门佳片").
  var FILTERS = JSON.parse('{"kanlist/全部":[{"name":"分类","value":[{"v":"","n":"全部"},{"v":"kanlist/剧情","n":"剧情"},{"v":"kanlist/情感","n":"情感"},{"v":"kanlist/治愈","n":"治愈"},{"v":"kanlist/爱情","n":"爱情"},{"v":"kanlist/颁奖","n":"颁奖"},{"v":"kanlist/喜剧","n":"喜剧"},{"v":"kanlist/获奖","n":"获奖"},{"v":"kanlist/ 科幻","n":"科幻"},{"v":"kanlist/漫威","n":"漫威"},{"v":"kanlist/甜蜜","n":"甜蜜"},{"v":"kanlist/悬疑","n":"悬疑"},{"v":"kanlist/励志","n":"励志"},{"v":"kanlist/烧脑","n":"烧脑"},{"v":"kanlist/友情","n":"友情"}],"key":"cateId"}],"billboard":[],"hot/index-movie-热门":[{"name":"分类","value":[{"v":"","n":"全部"},{"v":"hot/index-movie-最新","n":"最新"},{"v":"hot/index-movie-经典","n":"经典"},{"v":"hot/index-movie-豆瓣高 分","n":"豆瓣高分"},{"v":"hot/index-movie-冷门佳片","n":"冷 门佳片"},{"v":"hot/index-movie-华语","n":"华语"},{"v":"hot/index-movie-欧美","n":"欧美"},{"v":"hot/index-movie-韩国","n":"韩国"},{"v":"hot/index-movie-日本","n":"日本"},{"v":"hot/index-movie-动作","n":"动作"},{"v":"hot/index-movie-喜剧","n":"喜剧"},{"v":"hot/index-movie-爱情","n":"爱情"},{"v":"hot/index-movie-科幻","n":"科幻"},{"v":"hot/index-movie-悬疑","n":"悬疑"},{"v":"hot/index-movie-恐怖","n":"恐怖"},{"v":"hot/index-movie-成长","n":"成长"},{"v":"hot/index-movie-豆瓣top250","n":"豆瓣top250"}],"key":"cateId"}],"hot/index-tv-热门":[{"name":"分类","value":[{"v":"","n":"全部"},{"v":"hot/index-tv-美剧","n":"美剧"},{"v":"hot/index-tv-英剧","n":"英剧"},{"v":"hot/index-tv-韩剧","n":"韩剧"},{"v":"hot/index-tv-日剧","n":"日剧"},{"v":"hot/index-tv-国产剧","n":"国产剧"},{"v":"hot/index-tv-港剧","n":"港剧"},{"v":"hot/index-tv-日本动画","n":"日本动画"},{"v":"hot/index-tv-综艺","n":"综艺"},{"v":"hot/index-tv-纪录片","n":"纪录片"}],"key":"cateId"}]}');
  var MAX = 2147483647;

  // Instance state, set by init (Ikanbot.java keeps the host in a static field, :23, :364).
  var site = HOST, order = '';

  function text(v) { return typeof v === 'string' ? v : (v === null || v === undefined ? '' : String(v)); }
  function pageNumber(pg) { var n = parseInt(pg, 10); return n > 1 ? n : 1; }
  function replaceAll(s, from, to) { return s.split(from).join(to); }
  function headers() { return { 'User-Agent': UA, 'Referer': site }; }

  // Ikanbot.java:26–40: a douban poster needs this Referer (a bare request answers 418).
  function d(pic) { return pic ? pic + '@Headers=' + JSON.stringify({ 'User-Agent': UA, 'Referer': 'https://www.douban.com' }) : ''; }

  function page(url) {
    var res = host.get(url, { headers: headers() });
    return res.status === 200 ? res.body || '' : '';
  }

  // Ikanbot.java:42–62. Java throws (and so returns "") on a short or non-numeric id or a short token; JS
  // would quietly slice, so those are checked.
  function getTks(id, token) {
    id = text(id);
    token = text(token);
    var tail = id.slice(-4), out = '';
    if (id.length < 4 || !/^\d{4}$/.test(tail)) return '';
    for (var k = 0; k < 4; k++) {
      var i = parseInt(tail.charAt(k), 10) % 3;
      if (token.length < i + 9) return '';
      out += token.substring(i + 1, i + 9);
      token = token.substring(i + 9);
    }
    return out;
  }

  function video(node, nameRule) {
    return { vod_id: host.pdfh(node, 'a&&href'), vod_name: host.pdfh(node, nameRule), vod_pic: d(host.pdfh(node, 'img&&data-src')), vod_remarks: '' };
  }

  // [排序:k1,k2]: the lines whose name contains k1, then k2, ahead of the rest, each moved once (gate §6.3, IKAN-D-05).
  function sorted(names, urls) {
    if (order.indexOf('[排序:') === -1) return { names: names, urls: urls };
    var keys = order.split('[排序:')[1].split(']')[0].split(','), rest = names.map(function (_, i) { return i; }), front = [];
    keys.forEach(function (key) {
      rest = rest.filter(function (i) {
        if (names[i].indexOf(key) === -1) return true;
        front.push(i);
        return false;
      });
    });
    var all = front.concat(rest);
    return { names: all.map(function (i) { return names[i]; }), urls: all.map(function (i) { return urls[i]; }) };
  }

  var spider = {
    // Ikanbot.java:358–370. `$$$proxy` suffixes (0825's variant) are out of scope (gate §6.6).
    init: function (extend) {
      var ext = text(extend);
      site = HOST;
      order = '';
      if (ext.indexOf('http') === 0) site = ext.split('[')[0];
      if (ext.indexOf('[排序:') !== -1) order = '[' + ext.split('[')[1];
      return '';
    },

    homeContent: function (filter) {
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }), null, FILTERS);
    },

    // Ikanbot.java:322–356: every div.v-list on the home page (it has two).
    homeVideoContent: function () {
      var html = page(site), items = [];
      if (html) {
        host.pdfa(html, 'body div.v-list').forEach(function (list) {
          host.pdfa(list, 'div.item').forEach(function (node) { items.push(video(node, 'p&&Text')); });
        });
      }
      return host.result.list(items);
    },

    // Ikanbot.java:80–152. The result is built here so 片单 items keep `vod_tag: "folder"`.
    categoryContent: function (tid, pg, filter, extend) {
      var id = text(tid), n = pageNumber(pg), kanlist = id.indexOf('kanlist') !== -1;
      var article = id.indexOf('article') !== -1, billboard = id.indexOf('billboard') !== -1;
      var empty = { list: [], page: n, pagecount: n, limit: 0, total: 0 };
      var template = site + '/{cateId}.html';
      if (kanlist) template = site + '/{cateId}-p-' + n + '.html';
      if (article) template = site + id;
      if (n !== 1) {
        if (billboard || article) return empty;
        template = site + '/{cateId}-p-' + n + '.html';
      }
      // Upstream only does this when `filter` is true; iOS never passes true (gate §6.3).
      var ext = extend && typeof extend === 'object' ? extend : {};
      Object.keys(ext).forEach(function (key) {
        var value = text(ext[key]);
        if (value) template = replaceAll(template, '{' + key + '}', value);
      });
      var html = page(replaceAll(template, '{cateId}', id));
      if (!html) return empty;
      var list;
      if (kanlist) {
        list = host.pdfa(html, 'div.reslut-list div.media').map(function (node) {
          return { vod_id: host.pdfh(node, 'a&&href'), vod_name: host.pdfh(node, 'h5&&Text'),
                   vod_pic: host.pdfh(node, 'img&&data-src'), vod_remarks: '', vod_tag: 'folder' };
        });
      } else {
        var rule = billboard || article ? ['div#video-list div.item', '.title&&Text'] : ['div.v-list div.item', 'p&&Text'];
        list = host.pdfa(html, rule[0]).map(function (node) {
          var item = video(node, rule[1]);
          item.vod_tag = 'file';
          return item;
        });
      }
      if (!list.length) return empty;
      return { list: list, page: n, pagecount: MAX, limit: list.length, total: MAX };
    },

    // Ikanbot.java:165–254.
    detailContent: function (ids) {
      var id = text(ids && ids[0]).split('$$$')[0];
      var none = host.result.list([]);
      if (id.charAt(0) !== '/') return none;
      var html = page(site + id);
      function field(name) { var m = new RegExp('id="' + name + '" value="([^"]*)"').exec(html); return m ? m[1] : ''; }
      var videoId = field('current_id'), mtype = field('mtype'), token = getTks(videoId, field('e_token'));
      if (!html || !token) return none;
      var res = host.get(site + '/api/getResN?videoId=' + videoId + '&mtype=' + mtype + '&token=' + token, {
        headers: { 'User-Agent': UA, 'Referer': site + id, 'Accept': '*/*', 'X-Requested-With': 'XMLHttpRequest' }
      });
      var data = res.status === 200 ? host.parseJSON(res.body) : null;
      var rows = data && data.data && Array.isArray(data.data.list) ? data.data.list : null;
      if (!rows) return none;
      var names = [], urls = [];
      rows.forEach(function (row) {
        var raw = row && typeof row === 'object' ? text(row.resData) : '';
        if (!raw) return;
        var episodes;
        try { episodes = JSON.parse(raw); } catch (e) { return; }
        if (!Array.isArray(episodes) || !episodes.length || !episodes[0] || typeof episodes[0] !== 'object') return;
        var flag = text(episodes[0].flag);
        names.push(replaceAll(flag, 'm3u8', '线路'));
        urls.push(episodes.map(function (ep) {
          var url = text(ep && ep.url);
          return flag ? replaceAll(replaceAll(url, '$' + flag + '#', ''), '$' + flag, '') : url;
        }).join('#'));
      });
      var lines = sorted(names, urls);
      var pic = host.pdfh(html, 'img.cover&&data-src');
      return host.result.detail({
        vod_id: id,
        vod_name: host.pdfh(html, 'h1&&Text'),
        vod_pic: d(pic),
        vod_year: host.pdfh(html, 'div.detail > .year&&Text'),
        vod_area: host.pdfh(html, 'div.detail > .country&&Text'),
        vod_actor: host.pdfh(html, 'div.detail > .celebrity&&Text'),
        vod_content: '',
        vod_play_from: lines.names.join('$$$'),
        vod_play_url: lines.urls.join('$$$')
      });
    },

    // Ikanbot.java:255–296. encodeURIComponent, so a space is %20 (upstream's URLEncoder writes +).
    searchContent: function (key, quick, pg) {
      var wd = text(key).trim(), n = pageNumber(pg);
      if (!wd) return host.result.list([]);
      var html = page(site + '/search?q=' + encodeURIComponent(wd) + (n > 1 ? '&p=' + n : ''));
      if (!html) return host.result.list([]);
      return host.result.list(host.pdfa(html, 'body .media').map(function (node) {
        var item = video(node, '.title-text&&Text');
        item.vod_name = item.vod_name.replace(/\s\d{4}$/, '').trim();
        item.vod_remarks = host.pdfh(node, 'span.label&&Text');
        return item;
      }));
    },

    // Ikanbot.java:371–386: direct play with the desktop user agent, and only that header.
    playerContent: function (flag, id, vipFlags) {
      return host.result.play(text(id), false, { 'User-Agent': UA });
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
