/**
 * csp_QimaoDJ — ported from `com.github.catvod.spider.QimaoDJ` (xiaosa-0807.jar, 287 lines).
 *
 * 七猫短剧's playlet API. `init` reads the two API hosts from a domain file (`bc` lists and searches,
 * `ks` serves the playlet with every episode's address). Every GET carries a `sign` query parameter,
 * md5 of the sorted `k=v` pairs plus a salt, and a `qm-params` header: the device profile as base64
 * with every letter and digit swapped through a fixed table, itself signed into a header `sign`.
 *
 * IOS-POC-44B. Measured 2026-10-02: the domain file, home tags, a category, an 80-episode detail, the
 * m3u8 (206) and search all answered.
 */
var spider = (function () {
  'use strict';

  var DOMAINS = 'https://neptune.qmplaylet.com/playlet-domain-android.json';
  var SALT = 'd3dGiJc651gSQ8w1';
  var DIGITS = 'MUlErYWbdJ', UPPER = '9saI0oy_HGitgNA8Fk3hfRqC4p', LOWER = 'mBOuc6Kx5T-2zSZ1VvjQ7DwnLe';
  var PAGE = 20;

  var store = 'https://api-store.qmplaylet.com', read = 'https://api-read.qmplaylet.com';

  /** The device profile, base64 with the original's character table applied. */
  function qmParams() {
    var profile = {
      'static_score': '0.8', 'uuid': '00000000-6f7c-e347-0000-000000000000',
      'device-id': '202504012213236fa2ed536aed584e0cc8a6a09fe2f2d4016cdc5bc74f2d5f', 'mac': '',
      'sourceuid': '9494817a02a93435', 'refresh-type': '0', 'model': 'M2012K10C', 'wlb-imei': '',
      'AUTHORIZATION': '6bcc46919d10d06a', 'brand': 'Redmi', 'oaid': '', 'oaid-no-cache': '',
      'sys-ver': '11', 'trusted-id': '', 'phone-level': 'H', 'imei': '', 'wlb-uid': '6bcc46919d10d06a',
      'session-id': String(host.now())
    };
    return host.base64.encode(JSON.stringify(profile)).replace(/[+\/0-9A-Za-z]/g, function (c) {
      if (c === '+') return 'P';
      if (c === '/') return 'X';
      if (c <= '9') return DIGITS.charAt(c.charCodeAt(0) - 48);
      if (c <= 'Z') return UPPER.charAt(c.charCodeAt(0) - 65);
      return LOWER.charAt(c.charCodeAt(0) - 97);
    });
  }

  /** `a(host, path, params)`: a signed GET. */
  function api(base, path, params) {
    var signed = Object.keys(params).sort().map(function (k) { return k + '=' + params[k]; }).join('');
    var query = Object.keys(params).map(function (k) { return k + '=' + host.enc(params[k]); });
    query.push('sign=' + host.md5(signed + SALT));
    var qm = qmParams();
    var headers = {
      'authorization': '', 'reg': '', 'is-white': '', 'user-agent': 'webviewversion/0', 'net-env': '1',
      'channel': 'va-vivo_lf', 'platform': 'android', 'application-id': 'com.duoduo.read',
      'app-version': '10001', 'qm-params': qm, 'no-permiss': '3',
      'sign': host.md5('AUTHORIZATION=app-version=10001application-id=com.duoduo.readchannel=va-vivo_lf'
                       + 'is-white=net-env=1platform=androidqm-params=' + qm + 'reg=' + SALT)
    };
    return (host.get(base + path + '?' + query.join('&'), { headers: headers, timeout: 20000 }).json || {}).data || {};
  }

  /** `b(JSONArray)`: the first cover the item has, and its episode count. */
  function listing(items) {
    var out = [];
    (items || []).forEach(function (v) {
      var id = String(v.playlet_id || v.id || '');
      if (!id) return;
      var pic = ['image_link', 'image', 'cover', 'vertical_cover', 'playlet_cover']
        .map(function (k) { return v[k]; }).filter(function (p) { return p; })[0] || '';
      var count = [v.total_episode_num, v.total_num, v.sub_title]
        .filter(function (n) { return n != null && n !== ''; })[0];
      out.push({ vod_id: id, vod_name: String(v.title || '').replace(/<[^>]+>/g, ''), vod_pic: pic,
                 vod_remarks: count == null ? '' : String(count) });
    });
    return out;
  }

  return {
    init: function () {
      var data = (host.get(DOMAINS, { headers: { 'User-Agent': 'okhttp/4.10.0' }, timeout: 15000 }).json || {}).data || {};
      if (data.bc) store = String(data.bc).replace(/\/$/, '');
      if (data.ks) read = String(data.ks).replace(/\/$/, '');
      return '';
    },

    homeContent: function () {
      var tags = api(store, '/api/v1/playlet/index', { tag_id: '0', playlet_privacy: '1', operation: '1' }).tag_items || [];
      return host.result.home(tags.filter(function (t) { return t.tag_id != null && t.tag_id !== ''; })
        .map(function (t) { return { type_id: t.tag_id, type_name: t.tag_name || '' }; }));
    },

    categoryContent: function (tid, page) {
      var pg = parseInt(page, 10) || 1;
      var items = listing(api(store, '/api/v1/playlet/index', {
        tag_id: String(tid), next_id: String(page || '1'), playlet_privacy: String(tid) === '0' ? '0' : '1'
      }).list);
      return host.result.page(items, pg, items.length ? pg + 1 : pg, PAGE);
    },

    detailContent: function (ids) {
      var id = String(ids[0]);
      var data = api(read, '/player/api/v1/playlet/info', { playlet_id: id });
      var episodes = [];
      (data.play_list || []).forEach(function (ep, i) {
        if (ep && ep.video_url) episodes.push('第' + (ep.sort || i + 1) + '集$' + ep.video_url);
      });
      return host.result.detail({
        vod_id: id,
        vod_name: data.title || id,
        vod_pic: data.image_link || data.image || data.cover || '',
        vod_content: data.intro || '',
        vod_play_from: episodes.length ? '七猫' : '',
        vod_play_url: episodes.join('#')
      });
    },

    searchContent: function (key) {
      var word = String(key || '').trim();
      if (!word) return host.result.list([]);
      return host.result.list(listing(api(store, '/api/v1/playlet/search', {
        extend: '', page: '1', wd: word, read_preference: '0', '0': '6bcc46919d10d06a' + host.now()
      }).list));
    },

    playerContent: function (flag, id) {
      var url = String(id || '');
      return host.result.play(url, false, url ? {
        'User-Agent': 'webviewversion/0', 'Referer': 'Dalvik/2.1.0 (Linux; U; Android 11; M2012K10C Build/RP1A.200720.011)'
      } : undefined);
    },

    isVideoFormat: function (url) { return /\.(m3u8|mp4|mkv|flv)(\?|$)/i.test(String(url)); },
    manualVideoCheck: function () { return false; },
    destroy: function () {
      store = 'https://api-store.qmplaylet.com';
      read = 'https://api-read.qmplaylet.com';
    }
  };
})();

module.exports = spider;
