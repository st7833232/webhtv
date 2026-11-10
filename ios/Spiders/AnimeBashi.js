/**
 * AnimeBashi (动漫巴士) spider.
 * Port of com.github.catvod.spider.AnimeBashi from spider.jar (W-266; triage W-255 `artifacts/w255/spider-jar-triage.md`).
 * Source host: https://dmbus.cc (HTML lists). A play page embeds hhjx.hhplayer.com, whose page carries url/t/key that
 * its /api/parse turns into the media address.
 *
 * Differences from upstream, all deliberate (docs/W-266-spider-jar-port-7.md):
 * - 导演 and 主演 land in vod_director and vod_actor; upstream swapped them.
 * - vod_id is the detail page's number (/v/<id>.html) instead of the whole path.
 * - Line names are the site's own tabs (线路1…), with upstream's 线路N when a tab is missing.
 */
(function () {
  'use strict';

  var HOST = 'https://dmbus.cc';
  var PARSER = 'https://hhjx.hhplayer.com';
  var UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
  var HEADERS = { 'User-Agent': UA, 'Referer': HOST + '/' };
  var CLASSES = [['1', '国漫'], ['2', '日漫'], ['3', '欧美动漫'], ['4', '动漫电影']];

  function text(v) { return v === null || v === undefined ? '' : String(v); }
  function pageNumber(pg) { var n = parseInt(pg, 10); return n > 1 ? n : 1; }
  function get(url) {
    var res = host.get(url, { headers: HEADERS });
    return res.status === 200 ? res.body || '' : '';
  }
  function abs(u) { u = text(u); return !u || /^https?:\/\//.test(u) ? u : HOST + (u[0] === '/' ? '' : '/') + u; }
  function idOf(href) { return host.match(href, '/v/(\\d+)\\.html'); }

  function cards(html) {
    var out = [];
    host.pdfa(html, 'ul.v_list li div.item').forEach(function (item) {
      var id = idOf(host.pdfh(item, 'a.title&&href'));
      var name = (host.pdfh(item, 'a.title&&title') || host.pdfh(item, 'a.title&&Text')).replace(/​/g, '').trim();
      if (!id || !name) return;
      out.push({ vod_id: id, vod_name: name, vod_pic: abs(host.pdfh(item, 'a.cover&&data-bg')),
                 vod_remarks: host.pdfh(item, 'span.desc&&Text') });
    });
    return out;
  }

  var spider = {
    init: function () { return ''; },

    homeContent: function (filter) {
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }));
    },

    categoryContent: function (tid, pg, filter, extend) {
      var n = pageNumber(pg), id = text(tid);
      if (!/^\d+$/.test(id)) return host.result.page([], n, n, 0, 0);
      var html = get(HOST + '/list-' + id + '-' + n + '.html');
      var list = cards(html);
      // The pager's highest link is the last page (list-1-10.html). A global scan, not a leading [\s\S]*, which
      // backtracks for seconds over a page with no pager.
      var re = new RegExp('/list-' + id + '-(\\d+)\\.html', 'g'), m, last = n;
      while ((m = re.exec(html))) last = Math.max(last, parseInt(m[1], 10));
      return host.result.page(list, n, last, list.length);
    },

    detailContent: function (ids) {
      var id = text(ids && ids[0]);
      if (!/^\d+$/.test(id)) return host.result.list([]);
      var html = get(HOST + '/v/' + id + '.html');
      if (!html) return host.result.list([]);
      var root = host.parse(html);
      var intro = {};
      host.pdfa(root, 'div#intro&&p').forEach(function (p) {
        var m = /^(剧情|导演|主演)：([\s\S]*)$/.exec(host.pdfh(p, 'Text'));
        if (m) intro[m[1]] = m[2].trim();
      });
      var tabs = host.pdfa(root, 'ul.play_from&&li').map(function (li) { return host.pdfh(li, 'Text'); });
      var from = [], urls = [];
      host.pdfa(root, 'div#play_list&&ul.play_list').forEach(function (ul, i) {
        // The site lists the newest episode first; upstream plays them oldest first.
        var eps = host.pdfa(ul, 'li').map(function (li) {
          var href = host.pdfh(li, 'a&&href');
          return href ? host.pdfh(li, 'a&&Text').replace(/[$#]/g, ' ') + '$' + href : '';
        }).filter(Boolean).reverse();
        if (!eps.length) return;
        from.push(tabs[i] || '线路' + (i + 1));
        urls.push(eps.join('#'));
      });
      return host.result.detail({
        vod_id: id,
        vod_name: host.pdfh(root, 'h1.v_title&&a&&Text'),
        vod_pic: abs(host.pdfh(root, 'div.cover&&img&&src')),
        vod_remarks: host.pdfh(root, 'p.v_desc&&span.desc&&Text'),
        vod_content: intro['剧情'] || '', vod_director: intro['导演'] || '', vod_actor: intro['主演'] || '',
        vod_play_from: from.join('$$$'), vod_play_url: urls.join('$$$')
      });
    },

    searchContent: function (key, quick, pg) {
      var wd = text(key).trim();
      if (!wd || pageNumber(pg) > 1) return host.result.list([]);
      return host.result.list(cards(get(HOST + '/s----------.html?wd=' + host.enc(wd))));
    },

    // Play page -> hhplayer iframe (url, t, key) -> /api/parse -> media address.
    playerContent: function (flag, id, vipFlags) {
      var path = text(id);
      if (path[0] !== '/') return host.result.play('', false);
      var frame = host.pdfh(get(HOST + path), 'div.p_box&&iframe&&src');
      if (frame.indexOf(PARSER + '/') !== 0) return host.result.play('', false);
      var page = get(frame);
      var url = host.match(page, '"url":\\s*"([^"]+)"'), key = host.match(page, '"key":\\s*"([^"]+)"');
      var t = parseInt(host.match(page, '"t":\\s*(\\d+)'), 10) || 0;
      if (!url || !key) return host.result.play('', false);
      var res = host.post(PARSER + '/api/parse', JSON.stringify({ url: url, t: t, key: key, client_fallback: false }),
                          { headers: { 'User-Agent': UA, 'Referer': HOST + '/', 'Content-Type': 'application/json',
                                       'Origin': PARSER } }).json || {};
      var media = text(res.url).replace(/^http:\/\//, 'https://');
      return host.result.play(/^https:\/\//.test(media) ? media : '', false);
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
