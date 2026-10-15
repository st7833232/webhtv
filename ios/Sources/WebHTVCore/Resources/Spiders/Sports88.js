/**
 * Sports88 (88看球) spider: live sports, also driving qist 0825's csp_Kanqiu (the same site on a mirror).
 * Port of com.github.catvod.spider.Sports88 from qist spider.jar (IOS-POC-57B-14, gate W-102, task W-105).
 * Source host: https://www.88kanqiu.la (HTML lists, a base64-wrapped JSON of lines per match).
 *
 * Differences from upstream, all deliberate:
 * - Only matches that are live are listed: the others have no lines, and upstream gave them all one id.
 * - Every detail asks /live/<id>/source; Kanqiu's own `<play>-url` route answers 404 (gate #4, #6).
 * - Only play.88player.top/m3u8.html wrappers become lines, unwrapped to the HLS address in their `url`
 *   parameter and played as is; the third-party pages upstream hands to the sniffer are left out (Manager).
 * - The categories are Kanqiu's ""/1/8/21, which its filter rows (cateId) match; Sports88's 4/23/21 did not.
 * A vod_id is the match number only: the stream addresses carry a time-limited auth_key, so a reopened
 * history entry asks /source again.
 */
(function () {
  'use strict';

  var HOST = 'https://www.88kanqiu.la';
  var HEADERS = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36' };
  var CLASSES = [['', '全部直播'], ['1', '篮球直播'], ['8', '足球直播'], ['21', '其他直播']];
  function kinds(pairs) {
    return [{ key: 'cateId', name: '类型', value: pairs.map(function (p) { return { n: p[0], v: p[1] }; }) }];
  }
  // Upstream's rows for 1 and 8; its row "29" has no category to hang on.
  var FILTERS = {
    '1': kinds([['NBA', '1'], ['CBA', '2'], ['篮球综合', '4'], ['纬来体育', '21']]),
    '8': kinds([['英超', '8'], ['西甲', '9'], ['意甲', '10'], ['欧冠', '12'], ['欧联', '13'], ['德甲', '14'], ['法甲', '15'],
                ['欧国联', '16'], ['足总杯', '27'], ['国王杯', '33'], ['中超', '7'], ['亚冠', '11'], ['足球综合', '23'],
                ['欧协联', '28'], ['美职联', '26']])
  };
  var site = HOST;

  function value(v) { return v === null || v === undefined ? '' : String(v); }
  function text(v) { return typeof v === 'string' ? v : ''; }

  // http(s) or rtmp(s) without the CatVod separators (W59-01).
  function playable(url) { return /^(https?|rtmps?):\/\/[^$#]*$/.test(value(url)); }

  // The HLS address inside a 88player wrapper page (it only feeds `url` to hls.js, gate #10); '' for anything else.
  function unwrap(url) {
    var m = /^https?:\/\/play\.88player\.top\/m3u8\.html\?(.*)$/.exec(url);
    if (!m) return '';
    var params = m[1].split('&');
    for (var i = 0; i < params.length; i++) {
      if (params[i].indexOf('url=') === 0) {
        var inner = host.dec(params[i].slice(4));
        return playable(inner) ? inner : '';
      }
    }
    return '';
  }

  // The `links` of a /source reply: data is six junk characters, base64 of the JSON, two junk characters.
  function links(data) {
    if (typeof data !== 'string' || data.length < 8) return [];
    var b64 = data.slice(6, -2);
    while (b64.length % 4) b64 += '=';
    try {
      var o = JSON.parse(host.base64.decode(b64));
      return o && Array.isArray(o.links) ? o.links : [];
    } catch (e) { return []; }
  }

  var spider = {
    init: function (extend) {
      var ext = value(extend).trim();
      site = /^https?:\/\/[^\s]+$/.test(ext) ? ext.replace(/\/+$/, '') : HOST;
      return '';
    },

    homeContent: function (filter) {
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }), null, FILTERS);
    },

    // One page of live matches; a filter's cateId replaces the category, as upstream (Sports88.java:34–36).
    categoryContent: function (tid, pg, filter, extend) {
      var id = extend && extend.cateId !== undefined ? value(extend.cateId) : value(tid);
      if (!/^\d*$/.test(id) || (parseInt(pg, 10) || 1) > 1) return host.result.page([], 1, 1);
      var res = host.get(site + (id ? '/match/' + id + '/live' : '/'), { headers: HEADERS, timeout: 15000 });
      if (res.status !== 200 || !res.body) return host.result.page([], 1, 1);
      var seen = {}, items = [];
      host.pdfa(res.body, '.list-group-item').forEach(function (li) {
        var m = /\/live\/(\d+)\/play/.exec(host.pdfh(li, '.btn.btn-primary&&href'));
        if (!m || seen[m[1]]) return;  // a time row, a match not live, or one already listed
        seen[m[1]] = true;
        var state = host.pdfh(li, '.btn.btn-primary&&Text');
        var name = host.pdfh(li, '.row.d-none&&Text') || host.pdfh(li, 'Text');
        if (state && name.slice(-state.length) === state) name = name.slice(0, -state.length).trim();
        items.push({ vod_id: m[1], vod_name: name, vod_pic: host.urljoin(site, host.pdfh(li, '.col-xs-1 img&&src')), vod_remarks: state });
      });
      return host.result.page(items, 1, 1);
    },

    detailContent: function (ids) {
      var id = value(ids && ids[0]);
      if (!/^\d+$/.test(id)) return host.result.list([]);
      var res = host.get(site + '/live/' + id + '/source', { headers: HEADERS, timeout: 15000 });
      if (res.status !== 200) return host.result.list([]);
      var episodes = [], named = {};
      links(res.json && res.json.data).forEach(function (l, i) {
        var url = l && typeof l === 'object' ? unwrap(text(l.url)) : '';
        if (!url) return;
        // Brackets go too: the App does not split lines at a '#' inside an open bracket (CMSClient episode parsing).
        var name = text(l.name).replace(/[$#()（）\[\]【】《》]/g, ' ').replace(/\s+/g, ' ').trim() || '线路' + (i + 1);
        named[name] = (named[name] || 0) + 1;
        episodes.push((named[name] > 1 ? name + ' (' + named[name] + ')' : name) + '$' + url);
      });
      // No line: both play fields stay empty so the App offers no play button, never a placeholder.
      return host.result.detail({
        vod_id: id,
        vod_content: episodes.length ? '' : '暂无可播放线路',
        vod_play_from: episodes.length ? '88看球' : '',
        vod_play_url: episodes.join('#')
      });
    },

    searchContent: function (key, quick, pg) { return host.result.list([]); },

    playerContent: function (flag, id, vipFlags) {
      return host.result.play(playable(id) ? value(id) : '', false, HEADERS);
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
