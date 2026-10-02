/**
 * csp_WeiguanDJ — ported from `com.github.catvod.spider.WeiguanDJ` (xiaosa-0807.jar, 144 lines).
 *
 * 围观短剧's own app API. Plain JSON, no crypto: every request carries the same device query string,
 * whose only per-install value is `clientInfo`, the md5 of ten random characters chosen in `init`.
 * Categories are the API's tags, a listing is a POST to `search` with the tag as `subject`, and the
 * detail returns every episode with its quality list already signed, so playback needs no further
 * request: the episode id is that list, base64-encoded exactly as the original does.
 *
 * IOS-POC-44A. Measured 2026-10-02: tags, listing, search, a 30-episode detail and the mp4 itself
 * (206 `ftypisom`) all answered.
 */
var spider = (function () {
  'use strict';

  var API = 'https://api.drama.9ddm.com/drama/home/';
  var UA = 'okhttp/5.1.0';
  var PAGE = 30;
  // `Build.MODEL` / `Build.BRAND` on Android. The API only records them.
  var MODEL = 'Pixel7', BRAND = 'Google';

  var clientInfo = '';

  /** `c()`: the device query string every endpoint takes. */
  function query() {
    return '?version_code=1600&version_name=1.6.0&device_name=' + MODEL
      + '&device_type=phone&is_first_day=true&is_first_24h=true&app_launch_way=icon'
      + '&default_homepage=homepage_interaction&device_owning_firm=' + BRAND
      + '&font_scale=default&os_type=1&clientInfo=' + clientInfo;
  }

  function getJSON(path, params) {
    return host.get(API + path + query() + (params || ''),
                    { headers: { 'User-Agent': UA }, timeout: 20000 }).json || {};
  }

  /** The original's `b.f(url, json, headers)`: a JSON POST. */
  function search(body) {
    var res = host.post(API + 'search' + query(), JSON.stringify(body), {
      headers: { 'User-Agent': UA, 'Content-Type': 'application/json; charset=utf-8' }, timeout: 20000
    });
    return (res.json || {}).data || [];
  }

  /** `b(JSONArray)`. `episodeCount` is a number in the JSON; the list shape wants a string. */
  function listing(items) {
    return (items || []).map(function (v) {
      return { vod_id: v.oneId, vod_name: v.title || '', vod_pic: v.horzPoster || '',
               vod_remarks: v.episodeCount == null ? '' : String(v.episodeCount) };
    });
  }

  return {
    init: function () {
      clientInfo = host.md5(host.random(10));
      return '';
    },

    homeContent: function () {
      var tags = getJSON('shortVideoTags').tags || [];
      return host.result.home(tags.map(function (t) { return { type_id: t, type_name: t }; }));
    },

    categoryContent: function (tid, page, filter, extend) {
      var subject = (extend && extend.cateId) || tid;
      var pg = parseInt(page, 10) || 1;
      var items = listing(search({ audience: '全部', order: '最新', page: pg, pageSize: PAGE,
                                   searchWord: '', subject: subject }));
      // The original's paging: a full page means there may be another one.
      return host.result.page(items, pg, items.length < PAGE ? pg : pg + 1, PAGE, 0);
    },

    detailContent: function (ids) {
      var id = String(ids[0]);
      var o = getJSON('shortVideoDetail', '&oneId=' + id + '&page=1&pageSize=1000&userId=0&queryAll=true');
      var episodes = (o.data || []).map(function (ep) {
        return ep.playOrder + '$' + host.base64.encode(JSON.stringify(ep.videoClarityList || []));
      });
      return host.result.detail({
        vod_id: id,
        vod_name: o.title || '',
        vod_pic: o.vertPoster || '',
        vod_remarks: '短剧',
        vod_content: o.description || '',
        vod_play_from: episodes.length ? '短剧' : '',
        vod_play_url: episodes.join('#')
      });
    },

    searchContent: function (key) {
      return host.result.list(listing(search({ audience: '', order: '', page: 1, pageSize: PAGE,
                                               searchWord: String(key || '').trim(), subject: '' })));
    },

    /** The id is the episode's quality list; hand it over as `name, url` pairs, best first. */
    playerContent: function (flag, id) {
      var list = [];
      try { list = JSON.parse(host.base64.decode(String(id))); } catch (e) { list = []; }
      var pairs = [];
      list.forEach(function (q) { pairs.push(q.name || '', q.url || ''); });
      return host.result.play(pairs, false, { 'User-Agent': UA });
    },

    isVideoFormat: function (url) { return /\.(m3u8|mp4|mkv|flv)(\?|$)/i.test(String(url)); },
    manualVideoCheck: function () { return false; },
    destroy: function () { clientInfo = ''; }
  };
})();

module.exports = spider;
