/**
 * csp_MoDu — ported from `com.github.catvod.spider.MoDu` (xiaosa-0807.jar, 139 lines).
 *
 * 魔都动漫 through the 苹果CMS JSON API on `www.mdzyapi.com`: five fixed anime classes, `ac=detail`
 * for listings, details and search, and episode addresses played as they are. The configuration also
 * carries two other 魔都 sources (type 0 `caiji.moduapi.cc`, type 1 `moduzy.com`); this one keeps its
 * own key and API, and nothing here merges them.
 *
 * IOS-POC-44F. Measured 2026-10-06: listings (classes 1–5, 20 a page with `pagecount`), detail, search
 * and m3u8s on the `modujx11/13/17` hosts answered; `modujx10` and `modujx12` present self-signed
 * certificates and 404.
 */
var spider = (function () {
  'use strict';

  var API = 'https://www.mdzyapi.com/api.php/provide/vod';
  var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36';
  var CLASSES = [['1', '国产动漫'], ['2', '日韩动漫'], ['3', '欧美动漫'], ['4', '港台动漫'], ['5', '动漫电影']];

  function get(url) { return host.get(url, { headers: { 'User-Agent': UA }, timeout: 20000 }).json || {}; }

  /** org.json's `optInt(key, fallback)`: numbers and numeric strings, else the fallback. */
  function int(value, fallback) { var n = parseInt(value, 10); return isNaN(n) ? fallback : n; }

  function listing(o) {
    return (o.list || []).filter(function (v) {
      return v && String(v.vod_id == null ? '' : v.vod_id).trim() && String(v.vod_name || '').trim();
    }).map(function (v) {
      return { vod_id: String(v.vod_id).trim(), vod_name: String(v.vod_name).trim(), vod_pic: v.vod_pic || '',
               vod_remarks: v.vod_remarks || '' };
    });
  }

  /** `c.m(page, pagecount, limit, total, list)` with the original's floors and fallbacks. */
  function paged(o, page, pagecountFallback) {
    var items = listing(o), pg = int(page, 1);
    return host.result.page(items, pg, Math.max(1, int(o.pagecount, pagecountFallback)),
                            Math.max(1, int(o.limit, items.length || 20)), Math.max(0, int(o.total, items.length)));
  }

  return {
    init: function () { return ''; },

    homeContent: function () {
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }));
    },

    categoryContent: function (tid, page) {
      var pg = String(page || '1');
      return paged(get(API + '?ac=detail&t=' + tid + '&pg=' + pg), pg, 1);
    },

    detailContent: function (ids) {
      var id = String(ids[0] || '').trim();
      var v = id ? (get(API + '?ac=detail&ids=' + host.enc(id)).list || [])[0] : null;
      if (!v) return host.result.detail({});
      var from = v.vod_play_from || '', url = v.vod_play_url || '';
      return host.result.detail({
        vod_id: id,
        vod_name: v.vod_name || '',
        vod_pic: v.vod_pic || '',
        type_name: v.type_name || '',
        vod_year: v.vod_year == null ? '' : String(v.vod_year),
        vod_area: v.vod_area || '',
        vod_actor: v.vod_actor || '',
        vod_director: v.vod_director || '',
        vod_content: v.vod_content || '',
        vod_remarks: v.vod_remarks || '',
        vod_play_from: !from && url ? '播放' : from,
        vod_play_url: url
      });
    },

    searchContent: function (key, quick, page) {
      if (!key) return host.result.list([]);
      var pg = String(page || '1');
      return paged(get(API + '/?ac=detail&pg=' + pg + '&wd=' + host.enc(key)), pg, 10);
    },

    playerContent: function (flag, id) {
      return host.result.play(String(id || '').trim(), false, { 'User-Agent': UA });
    },

    isVideoFormat: host.isVideoFormat,
    manualVideoCheck: function () { return false; },
    destroy: function () {}
  };
})();

module.exports = spider;
