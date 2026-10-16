/**
 * csp_Feiyu — ported from `com.github.catvod.spider.Feiyu` (xiaosa-0807.jar, 404 lines).
 *
 * 飛魚's app API on `4kyszx.top`. No cipher, but every GET is signed twice over: `init` derives a
 * secret as HMAC-SHA256(salt, deviceId) in hex, and each request sends
 * `x-signature = HMAC-SHA256(secret, "GET\n<path>\n<query>\n<seconds>\n<nonce>\n<version>")`.
 * The listing and search sign the query with raw values while the URL carries them encoded; the
 * ranking signs the encoded form. Measured 2026-10-06: the server verifies against its own sorted
 * copy of the parameters, which is why only alphabetical parameter orders are ever sent here.
 *
 * IOS-POC-44D. Measured 2026-10-06: categories, listing (82,057 films), ranking, detail with six
 * lines, search with paging all answered; a bad signature gets 403 `签名验证失败`.
 */
var spider = (function () {
  'use strict';

  var API = 'https://4kyszx.top';
  var DEVICE = 'f45a775875e2e004adbcea78e3312218';
  var SALT = 'cms_device_salt_v1_2024cms_app_sign_key_v1_2024_secure';
  var VERSION = '2.6.8+1';
  var ALNUM = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  var PAGE = 20;
  var UA = 'Dart/3.10 (dart:io)';
  // The original plays with no headers; every port here sends the UA it reached the site with.
  var PLAY = { 'User-Agent': UA };

  var secret = '';

  /** org.json's `optString(key, fallback)`: the fallback only when the key is absent or null. */
  function opt(o, key, fallback) { return o[key] == null ? fallback : String(o[key]); }

  /**
   * `e(path, params, raw)`. `params` is an array of `[key, value]` in the original's insertion
   * order. The original also sends `host: 4kyszx.top`, which URLSession sets from the URL itself.
   */
  function api(path, params, raw) {
    params = params || [];
    var stamp = String(host.timestamp());
    var nonce = host.base64.encode(host.random(16, ALNUM));
    var signed = params.map(function (p) { return p[0] + '=' + (raw ? p[1] : host.enc(p[1])); }).join('&');
    var query = params.map(function (p) { return p[0] + '=' + host.enc(p[1]); }).join('&');
    var res = host.get(API + path + (query ? '?' + query : ''), {
      headers: {
        'x-signature': host.hmac('sha256', ['GET', path, signed, stamp, nonce, VERSION].join('\n'), secret),
        'user-agent': UA, 'x-nonce': nonce, 'accept': 'application/json',
        'x-timestamp': stamp, 'x-device-id': DEVICE, 'content-type': 'application/json',
        'x-app-version': VERSION, 'x-platform': 'android'
      },
      timeout: 20000
    });
    return res.json || {};
  }

  /** `data` is an array or `{list: [...]}`, depending on the endpoint. */
  function listing(data) {
    return (Array.isArray(data) ? data : ((data && data.list) || [])).map(function (v) {
      return { vod_id: String(parseInt(v.id, 10) || 0), vod_name: opt(v, 'name', opt(v, 'title', '')),
               vod_pic: opt(v, 'pic', opt(v, 'cover', '')), vod_remarks: opt(v, 'remarks', opt(v, 'subTitle', '')) };
    });
  }

  /** The original's pagecount is a constant 999; the API reports its real total, so use that. */
  function pages(data) {
    var total = data && !Array.isArray(data) ? parseInt(data.total, 10) : NaN;
    return total > 0 ? Math.ceil(total / PAGE) : 999;
  }

  /** `c(name)`: the original's quality rank, which orders the lines best first. */
  function rank(name) {
    var n = String(name).toLowerCase();
    if (n.indexOf('4k') !== -1) return 100;
    if (n.indexOf('藍光') !== -1 || n.indexOf('2k') !== -1) return 90;
    if (n.indexOf('高清') !== -1 || n.indexOf('hd') !== -1) return 80;
    return /m3u8|採集|資源|zy/.test(n) ? 10 : 50;
  }

  return {
    init: function () {
      secret = host.hmac('sha256', DEVICE, SALT);
      return '';
    },

    homeContent: function () {
      var data = api('/api/app/categories').data;
      // The original sends an empty `filters` object: the API publishes no filter options.
      return host.result.home((Array.isArray(data) ? data : []).map(function (c) {
        return { type_id: String(parseInt(c.id, 10) || 0), type_name: opt(c, 'name', '') };
      }));
    },

    homeVideoContent: function () {
      var data = api('/api/app/ranking/list', [['category', '1']]).data;
      return host.result.list((Array.isArray(data) ? data : []).map(function (v) {
        return { vod_id: String(parseInt(v.id, 10) || 0), vod_name: opt(v, 'title', opt(v, 'name', '')),
                 vod_pic: opt(v, 'cover', opt(v, 'pic', '')), vod_remarks: opt(v, 'subtitle', opt(v, 'remarks', '')) };
      }));
    },

    categoryContent: function (tid, page) {
      var pg = String(page || '1');
      var data = api('/api/app/categories/' + tid + '/videos', [['page', pg], ['page_size', String(PAGE)]], true).data;
      return host.result.page(listing(data), pg, pages(data), PAGE);
    },

    detailContent: function (ids) {
      var d = api('/api/app/videos/' + ids[0]).data;
      if (!d || typeof d !== 'object') return { list: [] };
      // A stable sort, as Java's `List.sort` is: equal ranks keep the API's order.
      var groups = (d.playGroups || []).slice().sort(function (a, b) {
        return rank(opt(b, 'name', opt(b, 'code', ''))) - rank(opt(a, 'name', opt(a, 'code', '')));
      });
      return host.result.detail({
        vod_id: String(parseInt(d.id, 10) || 0),
        vod_name: opt(d, 'name', ''),
        vod_pic: opt(d, 'pic', ''),
        type_name: opt(d, 'categoryName', ''),
        vod_year: opt(d, 'year', ''),
        vod_area: opt(d, 'area', ''),
        vod_actor: opt(d, 'actor', ''),
        vod_director: opt(d, 'director', ''),
        vod_content: opt(d, 'content', ''),
        vod_remarks: opt(d, 'remarks', opt(d, 'subTitle', '')),
        vod_play_from: groups.map(function (g) { return opt(g, 'name', opt(g, 'code', '')); }).join('$$$'),
        // The episode id is `parseApi||url`: an empty parseApi means the url plays as it is.
        vod_play_url: groups.map(function (g) {
          var parseApi = opt(g, 'parseApi', '');
          return (g.playUrls || []).map(function (u) {
            return opt(u, 'name', '') + '$' + parseApi + '||' + opt(u, 'url', '');
          }).join('#');
        }).join('$$$')
      });
    },

    /** The original always asks for page 1; the API pages its search, so the page is passed on. */
    searchContent: function (key, quick, page) {
      var pg = String(page || '1');
      var data = api('/api/app/videos/search', [['keyword', String(key || '')], ['page', pg],
                                                ['page_size', String(PAGE)]], true).data;
      return host.result.page(listing(data), pg, pages(data), PAGE);
    },

    playerContent: function (flag, id) {
      var parts = String(id).split('||');
      var parseApi = parts[0], url = parts.length > 1 ? parts[1] : '';
      if (!parseApi) return host.result.play(url, false, PLAY);
      if (parseApi.indexOf('json') !== -1 || parseApi.indexOf('api') !== -1) {
        var res = host.get(parseApi + url, { headers: { 'User-Agent': 'Mozilla/5.0' }, timeout: 20000 });
        var found = res.json && res.json.url ? String(res.json.url) : '';
        // The original takes any `url`; an expired parse account answers a relative error clip
        // (`/mizhicdn/video/error.mp4`, measured 2026-10-06), which is not an address.
        if (/^https?:\/\//.test(found)) return host.result.play(found, false, PLAY);
      }
      // What the parse service could not resolve goes to the sniffer, as `parse:1` does on Android.
      return host.result.play(parseApi + url, true, PLAY);
    },

    isVideoFormat: host.isVideoFormat,
    manualVideoCheck: function () { return false; },
    destroy: function () { secret = ''; }
  };
})();

module.exports = spider;
