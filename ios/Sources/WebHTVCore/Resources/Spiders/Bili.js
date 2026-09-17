/**
 * csp_Bili — ported from `com.github.catvod.spider.Bili` (river-fman.jar, 284 lines).
 *
 * The public bilibili web API, no crypto and no login required for what the four configured sites
 * ask of it: each one points `ext.json` at a static CatVod home document whose every `type_id` is a
 * search keyword, so browsing is `search/type` and playing is `player/playurl`.
 *
 * Two deliberate departures from the original, both forced by the platform (see
 * `docs/IOS-POC-5L-appqi-app99-app3q-bili.md`):
 *
 *   1. **No DASH.** The original hands the player `Proxy.getUrl()?do=bili&…&type=mpd` and then
 *      synthesises an MPD from the `dash` response inside the Android app's own HTTP server. iOS has
 *      no such server, and `AVPlayer` cannot play MPEG-DASH in any case, so this port asks for
 *      `fnval=1` and returns the progressive `durl` MP4 instead.
 *   2. **`wbi/view` instead of `view`.** `/x/web-interface/view` now answers with an HTML error page
 *      for every aid and bvid (measured 2026-09-17, with and without a fresh `buvid3`);
 *      `/x/web-interface/wbi/view` returns the same document and, today, needs no `w_rid`.
 *
 * Not ported: the `<mid>/{pg}` up-主 branch of `categoryContent`, which needs wbi query signing —
 * none of the 73 categories the four sites configure uses it. Danmaku, as everywhere, is dropped.
 */
var spider = (function () {
  'use strict';

  var DEFAULT_COOKIE = 'buvid3=04E9092E-4D34-B728-CB76-E5BCBEC43B5129057infoc';
  var cfg = { cookie: DEFAULT_COOKIE, json: '' };

  function headers(referer) {
    return {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0',
      'Referer': referer || 'https://www.bilibili.com',
      'cookie': cfg.cookie
    };
  }

  function api(url, referer) {
    var res = host.get(url, { headers: headers(referer), timeout: 20000 });
    var body = res.json || {};
    // bilibili answers an HTML error page rather than JSON when it dislikes the session, and the
    // SESSDATA three of the four configured sites carry expired in 2025. One retry as the anonymous
    // visitor turns that from an empty category into a listing; measured, it is not rare.
    if (body.code !== 0 && cfg.cookie !== DEFAULT_COOKIE) {
      var previous = cfg.cookie;
      cfg.cookie = DEFAULT_COOKIE;
      res = host.get(url, { headers: headers(referer), timeout: 20000 });
      body = res.json || {};
      if (body.code !== 0) cfg.cookie = previous;
    }
    return body.code === 0 ? (body.data || {}) : {};
  }

  /** A search hit: the API marks the matched words with `<em>`, which is not part of the title. */
  function searchList(results) {
    return (results || []).filter(function (r) { return r.bvid || r.aid; }).map(function (r) {
      return {
        vod_id: String(r.bvid || r.aid),
        vod_name: host.stripTags(String(r.title || '')),
        vod_pic: String(r.pic || '').replace(/^\/\//, 'https://'),
        vod_remarks: r.duration || r.author || ''
      };
    });
  }

  /** `categoryContent` and `searchContent` are the same keyword search in the original. */
  function browse(tid, page, extend) {
    var order = (extend && extend.order) || 'totalrank';
    var duration = (extend && extend.duration) || '0';
    var keyword = String(tid);
    if (extend && extend.tid) keyword += ' ' + extend.tid;
    var data = api('https://api.bilibili.com/x/web-interface/search/type?search_type=video'
                   + '&keyword=' + host.enc(keyword) + '&order=' + order
                   + '&duration=' + duration + '&page=' + (page || '1'),
                   'https://search.bilibili.com');
    return host.result.page(searchList(data.result), page || '1');
  }

  return {
    init: function (extend) {
      var ext = {};
      try { ext = JSON.parse(extend || '{}'); } catch (e) { ext = {}; }
      cfg.json = ext.json || '';
      var cookie = String(ext.cookie || '');
      // A `cookie` that is a URL points at `{"cookie": "…"}`. One configured site points it at
      // TVBox's own `http://127.0.0.1:9978/file/…`, which cannot exist here; the fetch simply
      // fails and the anonymous buvid3 below carries the session, as it does on Android.
      if (cookie.indexOf('http') === 0) {
        var fetched = host.get(cookie, { timeout: 10000 }).json || {};
        cookie = String(fetched.cookie || '').trim();
      }
      cfg.cookie = cookie || DEFAULT_COOKIE;
      return '';
    },

    /** The site's own static document already is a CatVod home response; hand it over verbatim. */
    homeContent: function () {
      if (!cfg.json) return host.result.home([], []);
      var body = host.get(cfg.json, { timeout: 20000 }).body || '';
      try { return JSON.parse(body); } catch (e) { return host.result.home([], []); }
    },

    categoryContent: function (tid, page, filter, extend) { return browse(tid, page, extend); },

    detailContent: function (ids) {
      var id = String(ids[0]);
      var field = id.indexOf('BV') === 0 ? 'bvid=' : 'aid=';
      var view = api('https://api.bilibili.com/x/web-interface/wbi/view?' + field + host.enc(id));
      var aid = view.aid || id;
      // Every page of a multi-part video is one episode; `qn` travels with it so playerContent can
      // ask for the best quality this session is allowed, exactly as the original does.
      var quality = api('https://api.bilibili.com/x/player/playurl?avid=' + aid
                        + '&cid=' + (view.cid || '') + '&qn=64&fnval=1&fourk=1');
      var accepted = (quality.accept_quality || [64]).join(':');
      var episodes = (view.pages || []).map(function (page) {
        return (page.part || ('P' + page.page)) + '$' + aid + '+' + page.cid + '+' + accepted;
      });
      return host.result.detail({
        vod_id: id,
        vod_name: view.title || '',
        vod_pic: String(view.pic || '').replace(/^\/\//, 'https://'),
        vod_remarks: view.duration ? (Math.round(view.duration / 60) + '分鐘') : '',
        vod_content: view.desc || '',
        vod_actor: (view.owner || {}).name || '',
        vod_director: (view.owner || {}).name || '',
        vod_play_from: 'B站',
        vod_play_url: episodes.join('#')
      });
    },

    // The original's searchContent is literally categoryContent with the keyword as the tid.
    searchContent: function (key, quick, page) { return browse(key, page || '1', {}); },

    playerContent: function (flag, id, vipFlags) {
      var parts = String(id).split('+');
      var aid = parts[0], cid = parts[1];
      var qualities = String(parts[2] || '64').split(':');
      // `accept_quality` comes back best first; without a login anything above 80 is refused and
      // the API silently downgrades, so asking for the first entry is safe.
      var data = api('https://api.bilibili.com/x/player/playurl?avid=' + aid + '&cid=' + cid
                     + '&qn=' + qualities[0] + '&fnval=1&fourk=1');
      var durl = (data.durl || [])[0] || {};
      var url = durl.url || (durl.backup_url || [])[0] || '';
      if (url) return host.result.play(url, false, headers());
      // No progressive stream: let the sniffer try the watch page.
      return host.result.play('https://www.bilibili.com/video/' + (aid.indexOf('BV') === 0 ? aid : 'av' + aid),
                              true, headers());
    },

    isVideoFormat: function (url) { return /\.(m3u8|mp4|mkv|flv)(\?|$)/i.test(String(url)); },
    manualVideoCheck: function () { return false; },
    destroy: function () { cfg = { cookie: DEFAULT_COOKIE, json: '' }; }
  };
})();

module.exports = spider;
