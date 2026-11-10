/**
 * AnimeHuazi (花子动漫) spider.
 * Port of com.github.catvod.spider.AnimeHuazi from spider.jar (W-266; triage W-255 `artifacts/w255/spider-jar-triage.md`).
 * Source host: https://www.huazidm.com (plain JSON API; play addresses come from its own /api/play/resolve).
 *
 * Differences from upstream, all deliberate (docs/W-266-spider-jar-port-7.md):
 * - Search answers an empty list when the site asks for a captcha (code 4001), as upstream does; it is never solved.
 *   The keyword is URL-encoded, which upstream forgot.
 * - Nothing is saved for danmaku; the episode id stays upstream's `sourceCode|url`.
 */
(function () {
  'use strict';

  var HOST = 'https://www.huazidm.com';
  var HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36',
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'Content-Type': 'application/json;charset=UTF-8',
    'Referer': HOST + '/'
  };
  var CLASSES = [['1', 'TV动画'], ['2', '剧场'], ['3', '美漫'], ['4', '特摄'], ['20', '连载动画']];

  function text(v) { return v === null || v === undefined ? '' : String(v); }
  function pageNumber(pg) { var n = parseInt(pg, 10); return n > 1 ? n : 1; }
  function api(path) { return host.get(HOST + path, { headers: HEADERS }).json || {}; }
  function vods(items) {
    return (items || []).map(function (v) {
      return { vod_id: text(v.vodId), vod_name: text(v.vodName), vod_pic: text(v.vodPic), vod_remarks: text(v.vodRemarks) };
    }).filter(function (v) { return /^\d+$/.test(v.vod_id); });
  }

  var spider = {
    init: function () { return ''; },

    homeContent: function (filter) {
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }));
    },

    // Upstream's home: this week's ten most watched.
    homeVideoContent: function () {
      return host.result.list(vods(api('/api/videos?page=1&pageSize=10&sort=week').list));
    },

    categoryContent: function (tid, pg, filter, extend) {
      var n = pageNumber(pg), id = text(tid);
      if (!/^\d+$/.test(id)) return host.result.page([], n, n, 0, 0);
      var res = api('/api/videos?page=' + n + '&pageSize=24&typeId=' + id + '&sort=time');
      var size = parseInt(res.pageSize, 10) > 0 ? parseInt(res.pageSize, 10) : 24;
      var total = parseInt(res.total, 10) || 0;
      var list = vods(res.list);
      return host.result.page(list, n, Math.max(n, Math.ceil(total / size)), size, total);
    },

    detailContent: function (ids) {
      var id = text(ids && ids[0]);
      if (!/^\d+$/.test(id)) return host.result.list([]);
      var v = api('/api/videos/' + id).data;
      if (!v) return host.result.list([]);
      var from = [], urls = [];
      (v.playSources || []).forEach(function (src) {
        var code = text(src.sourceCode);
        var eps = (src.episodes || []).filter(function (e) { return text(e.url); }).map(function (e) {
          return text(e.name).replace(/[$#]/g, ' ') + '$' + code + '|' + text(e.url);
        });
        if (!code || !eps.length) return;
        from.push(text(src.sourceName) || code);
        urls.push(eps.join('#'));
      });
      return host.result.detail({
        vod_id: text(v.vodId) || id, vod_name: text(v.vodName), vod_pic: text(v.vodPic), vod_remarks: text(v.vodRemarks),
        type_name: text(v.vodClass), vod_year: text(v.vodYear), vod_area: text(v.vodArea), vod_actor: text(v.vodActor),
        vod_director: text(v.vodDirector), vod_content: text(v.vodContent),
        vod_play_from: from.join('$$$'), vod_play_url: urls.join('$$$')
      });
    },

    searchContent: function (key, quick, pg) {
      var wd = text(key).trim();
      if (!wd || pageNumber(pg) > 1) return host.result.list([]);
      var res = api('/api/search?q=' + host.enc(wd) + '&page=1&pageSize=24');
      return host.result.list(res.code === 4001 ? [] : vods(res.list));
    },

    playerContent: function (flag, id, vipFlags) {
      var at = text(id).indexOf('|');
      if (at <= 0) return host.result.play('', false);
      var res = host.post(HOST + '/api/play/resolve',
                          JSON.stringify({ url: text(id).slice(at + 1), sourceCode: text(id).slice(0, at) }),
                          { headers: HEADERS }).json || {};
      var url = text(res.playUrl);
      return host.result.play(/^https?:\/\//.test(url) ? url : '', false);
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
