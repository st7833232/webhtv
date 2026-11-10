/**
 * XingChen (星辰影院) spider.
 * Port of com.github.catvod.spider.XingChen from spider.jar (W-266; triage W-255 `artifacts/w255/spider-jar-triage.md`).
 * Source host: https://www.ixcyy.tv (maccms "shoutu" HTML; the play page's player JSON holds an m3u8).
 *
 * Differences from upstream, all deliberate (docs/W-266-spider-jar-port-7.md):
 * - vod_id is the detail page's number (/d-<id>.html) instead of the whole path.
 * - Detail rows with an unknown label are skipped; upstream appended them to whichever row came before.
 * - Search keeps upstream's single page. The site may refuse a client outright (nginx 444); that is reported as an
 *   empty result and never worked around.
 */
(function () {
  'use strict';

  var HOST = 'https://www.ixcyy.tv';
  var HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    'Referer': HOST + '/'
  };
  var CLASSES = [['1', '电影'], ['2', '电视剧'], ['3', '综艺'], ['4', '动漫'], ['5', '短剧']];

  function text(v) { return v === null || v === undefined ? '' : String(v); }
  function pageNumber(pg) { var n = parseInt(pg, 10); return n > 1 ? n : 1; }
  function page(path) {
    var res = host.get(HOST + path, { headers: HEADERS });
    return res.status === 200 ? res.body || '' : '';
  }
  function abs(u) { u = text(u); return !u || /^https?:\/\//.test(u) ? u : HOST + (u[0] === '/' ? '' : '/') + u; }
  function idOf(href) { return host.match(href, '/d-(\\d+)\\.html'); }
  // The site writes literal &nbsp; into labels, which host.pdfh does not decode.
  function txt(node, rule) { return host.pdfh(node, rule).replace(/&nbsp;|\u00a0/g, ' ').replace(/\s+/g, ' ').trim(); }

  // A category or search card.
  function cards(html, nameRule) {
    var out = [];
    host.pdfa(html, 'div.public-list-box').forEach(function (box) {
      var id = idOf(host.pdfh(box, 'a.public-list-exp&&href'));
      var name = host.pdfh(box, nameRule) || host.pdfh(box, 'a.public-list-exp&&title') || host.pdfh(box, 'a.time-title&&Text');
      if (!id || !name) return;
      out.push({ vod_id: id, vod_name: name, vod_pic: abs(host.pdfh(box, 'img.gen-movie-img&&data-src')),
                 vod_remarks: host.pdfh(box, 'span.public-list-prb&&Text') });
    });
    return out;
  }

  var spider = {
    init: function () { return ''; },

    homeContent: function (filter) {
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }));
    },

    // Upstream's home: the carousel, posters from each slide's background-image.
    homeVideoContent: function () {
      var out = [];
      host.pdfa(page('/'), 'div.slide-time-list&&div.slide-time-bj').forEach(function (slide) {
        var id = idOf(host.pdfh(slide, 'a&&href')), name = host.pdfh(slide, 'h3.slide-info-title&&Text');
        if (!id || !name) return;
        var remarks = host.pdfa(slide, 'span.slide-info-remarks');
        out.push({ vod_id: id, vod_name: name,
                   vod_pic: host.match(host.pdfh(slide, 'div.slide-time-img3&&style'), "url\\(['\"]?([^'\")]+)['\"]?\\)"),
                   vod_remarks: remarks.length > 1 ? host.pdfh(remarks[1], 'Text') : '' });
      });
      return host.result.list(out);
    },

    categoryContent: function (tid, pg, filter, extend) {
      var n = pageNumber(pg), id = text(tid);
      if (!/^\d+$/.test(id)) return host.result.page([], n, n, 0, 0);
      var list = cards(page('/vs/' + id + '--------' + n + '---.html'), 'a.public-list-exp&&title');
      return host.result.page(list, n, list.length ? n + 1 : n, list.length);
    },

    detailContent: function (ids) {
      var id = text(ids && ids[0]);
      if (!/^\d+$/.test(id)) return host.result.list([]);
      var html = page('/d-' + id + '.html');
      if (!html) return host.result.list([]);
      var root = host.parse(html);
      var remarks = host.pdfa(root, 'span.slide-info-remarks').map(function (n) { return txt(n, 'Text'); });
      var rows = { director: [], actor: [], type: [] };
      host.pdfa(root, 'div.slide-info').forEach(function (info) {
        var label = host.pdfh(info, 'strong&&Text');
        var key = /^导演/.test(label) ? 'director' : /^(演员|主演)/.test(label) ? 'actor' : /^类型/.test(label) ? 'type' : '';
        if (key) host.pdfa(info, 'a').forEach(function (a) { rows[key].push(host.pdfh(a, 'Text')); });
      });
      var lists = host.pdfa(root, 'ul.anthology-list-play'), from = [], urls = [];
      host.pdfa(root, 'div.anthology-tab&&a').forEach(function (tab) {
        var name = txt(tab, 'Text').replace(/\d+$/, '').trim();
        if (!name || from.length >= lists.length) return;
        var eps = host.pdfa(lists[from.length], 'li a.this-link').map(function (a) {
          return host.pdfh(a, 'Text').replace(/[$#]/g, ' ') + '$' + host.pdfh(a, 'a&&href');
        });
        from.push(name);
        urls.push(eps.join('#'));
      });
      return host.result.detail({
        vod_id: id,
        vod_name: host.pdfh(root, 'h3.slide-info-title&&Text'),
        vod_pic: abs(host.pdfh(root, 'div.detail-pic&&img&&data-src')),
        vod_remarks: remarks[0] || '',
        vod_year: remarks.length >= 3 ? remarks[1] : '',
        vod_area: remarks.length >= 3 ? remarks[2] : '',
        vod_director: rows.director.join(','), vod_actor: rows.actor.join(','), type_name: rows.type.join(','),
        vod_content: txt(root, 'div#height_limit&&Text'),
        vod_play_from: from.join('$$$'), vod_play_url: urls.join('$$$')
      });
    },

    searchContent: function (key, quick, pg) {
      var wd = text(key).trim();
      if (!wd || pageNumber(pg) > 1) return host.result.list([]);
      return host.result.list(cards(page('/s' + host.enc(wd) + '.html'), 'div.thumb-txt&&Text'));
    },

    // The play page's player JSON: "url":"…m3u8…", with escaped slashes.
    playerContent: function (flag, id, vipFlags) {
      var path = text(id);
      if (path[0] !== '/') return host.result.play('', false);
      var url = host.match(page(path).replace(/\\\//g, '/'), '"url"\\s*:\\s*"([^"]+\\.m3u8[^"]*)"');
      return host.result.play(/^https?:\/\//.test(url) ? url : '', false);
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
