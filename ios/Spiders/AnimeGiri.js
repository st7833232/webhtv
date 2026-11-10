/**
 * AnimeGiri (girigirilove) spider.
 * Port of com.github.catvod.spider.AnimeGiri from spider.jar (W-266; triage W-255 `artifacts/w255/spider-jar-triage.md`).
 * Source host: https://m3u8.girigirilove.com/api.php (maccms JSON API; every episode is a direct HLS address).
 *
 * Differences from upstream, all deliberate (docs/W-266-spider-jar-port-7.md):
 * - A detail poster given as a site path is joined to jpg.girigirilove.com, where list posters live; upstream joins it
 *   to m3u8.girigirilove.com, which answers 404.
 * - Search keeps upstream's single page of 24, with the keyword URL-encoded (upstream sent it raw).
 */
(function () {
  'use strict';

  var API = 'https://m3u8.girigirilove.com/api.php';
  var IMG = 'https://jpg.girigirilove.com/';
  var HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36',
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'Referer': 'https://girigirilove.com/'
  };
  var CLASSES = [['2', '日番'], ['3', '美番'], ['20', '真人番剧'], ['21', '剧场版'], ['24', 'BD副音轨'], ['26', '演唱会及其他']];

  function text(v) { return v === null || v === undefined ? '' : String(v); }
  function pageNumber(pg) { var n = parseInt(pg, 10); return n > 1 ? n : 1; }
  function api(path) {
    var json = host.get(API + path, { headers: HEADERS }).json;
    return json && json.code === 1 ? json.info : null;
  }
  function pic(p) { p = text(p); return !p || /^https?:\/\//.test(p) ? p : IMG + p.replace(/^\/+/, ''); }
  function vods(rows) {
    return (rows || []).map(function (v) {
      return { vod_id: text(v.vod_id), vod_name: text(v.vod_name), vod_pic: pic(v.vod_pic), vod_remarks: text(v.vod_remarks) };
    }).filter(function (v) { return /^\d+$/.test(v.vod_id); });
  }

  var spider = {
    init: function () { return ''; },

    homeContent: function (filter) {
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }));
    },

    homeVideoContent: function () {
      return host.result.list(vods(api('/App2/likeList')));
    },

    categoryContent: function (tid, pg, filter, extend) {
      var n = pageNumber(pg), id = text(tid);
      if (!/^\d+$/.test(id)) return host.result.page([], n, n, 0, 0);
      var info = api('/Vod/get_list?type_id=' + id + '&offset=' + (n - 1) * 20 + '&limit=20') || {};
      var size = parseInt(info.limit, 10) > 0 ? parseInt(info.limit, 10) : 20;
      var total = parseInt(info.total, 10) || 0;
      return host.result.page(vods(info.rows), n, Math.max(n, Math.ceil(total / size)), size, total);
    },

    detailContent: function (ids) {
      var id = text(ids && ids[0]);
      if (!/^\d+$/.test(id)) return host.result.list([]);
      var v = api('/Vod/get_detail?vod_id=' + id);
      if (!v) return host.result.list([]);
      return host.result.detail({
        vod_id: text(v.vod_id) || id, vod_name: text(v.vod_name), vod_pic: pic(v.vod_pic), vod_remarks: text(v.vod_remarks),
        type_name: text(v.vod_class), vod_year: text(v.vod_year), vod_area: text(v.vod_area), vod_actor: text(v.vod_actor),
        vod_director: text(v.vod_director), vod_content: text(v.vod_content),
        vod_play_from: text(v.vod_play_from), vod_play_url: text(v.vod_play_url)
      });
    },

    searchContent: function (key, quick, pg) {
      var wd = text(key).trim();
      if (!wd || pageNumber(pg) > 1) return host.result.list([]);
      return host.result.list(vods((api('/Vod/get_list?offset=0&limit=24&vod_name=' + host.enc(wd)) || {}).rows));
    },

    playerContent: function (flag, id, vipFlags) {
      var url = text(id);
      return host.result.play(/^https?:\/\//.test(url) ? url : '', false);
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
