/**
 * csp_App99 — ported from `com.github.catvod.spider.App99`
 * (river-fman.jar 556 lines, xiaosa-0807.jar / 愛影.jar 648).
 *
 * The most guarded of the App-API family, and the only one that logs in. Every request body is
 * AES-CBC/PKCS7 under a **random IV shipped in front of the ciphertext** — `base64(iv‖ct)` — keyed
 * by the client's own `uuid`, which also travels as a header so the server can answer the same way.
 * Authenticity is a second layer on top: `sign` = SHA-256 hex of `body:timestamp:nonce:token:appkey`.
 *
 * `init` therefore costs two round trips before any content: `/app/systemInit` for the category
 * tree, the player-name map and the parse list, then `LoginPath` (default `/app/userInfo`) posing as
 * a phone to collect `user_token`.
 *
 * The IV-prefix dialect is the one thing the host lacked; `host.aesEncryptIV` / `aesDecryptIV` were
 * added for it rather than a cipher inside this file.
 */
var spider = (function () {
  'use strict';

  var cfg = { url: '', appkey: '', uuid: '', ua: '', version: '', token: '' };
  var cache = { player: {}, parses: [], categories: [] };

  function uuid4() {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
      var r = Math.floor(Math.random() * 16);
      return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
    });
  }

  /** `e()`: a 16-byte nonce, base64. */
  function nonce() { return host.base64.encode(host.random(16)); }

  /** The AES key is the uuid with its dashes removed — 32 chars, so AES-256. */
  function key() { return String(cfg.uuid).replace(/-/g, ''); }

  function headers(nonceValue, timestamp, body) {
    return {
      'User-Agent': cfg.ua,
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'client_type': 'android',
      'uuid': cfg.uuid,
      'timestamp': timestamp,
      'sign': host.sha256(body + ':' + timestamp + ':' + nonceValue + ':' + cfg.token + ':' + cfg.appkey),
      'nonce': nonceValue,
      'appkey': cfg.appkey,
      'version': cfg.version,
      'api_version': 'v1'
    };
  }

  /** POST one encrypted JSON body and decrypt the reply. */
  function api(path, payload) {
    var n = nonce(), stamp = String(host.now());
    payload.token = payload.token === undefined ? cfg.token : payload.token;
    payload.timestamp = stamp;
    payload.nonce = n;
    var body = host.aesEncryptIV(JSON.stringify(payload), key());
    var res = host.post(cfg.url + path, body, { headers: headers(n, stamp, body), timeout: 20000 });
    if (!res.body) return {};
    var plain = host.aesDecryptIV(res.body, key());
    try { return JSON.parse(plain); } catch (e) { return {}; }
  }

  /** `b()`: this API names its fields without the `vod_` prefix. */
  function vodList(array) {
    return (array || []).map(function (v) {
      return { vod_id: v.id, vod_name: v.name, vod_pic: v.pic, vod_remarks: v.remarks };
    });
  }

  function listing(tid, page) {
    var data = api('/vod/search', {
      kw: '', page: String(page || '1'), limit: 21, pid: String(tid),
      orderBy: 'time', isCategory: 1
    });
    return { items: vodList(data.data), pages: data.page_count || 1 };
  }

  return {
    init: function (extend) {
      var ext = {};
      try { ext = JSON.parse(extend || '{}'); } catch (e) { ext = {}; }
      // The original refuses to run unless the whole app identity is present.
      if (!ext.host || !ext.appkey || !ext.name || !ext.buildSignature
          || !ext.buildNumber || !ext.versionName || !ext.package) return '';
      cfg.url = String(ext.host).replace(/\/+$/, '');
      cfg.appkey = ext.appkey;
      cfg.uuid = ext.uuid || uuid4();
      cfg.ua = ext.ua || 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.6299.95 Safari/537.36';
      cfg.version = ext.version || '0b4328287a5d953e';
      cfg.token = '';

      var system = api('/app/systemInit', {
        v: ext.versionName, n: ext.name, s: ext.buildSignature, pl: '1', apiVersion: 'v2', token: ''
      });
      if (system.player) cache.player = system.player;
      if (system.parser_api) cache.parses = system.parser_api;
      if (system.categorys && system.categorys.data) cache.categories = system.categorys.data;

      var installed = host.now();
      var login = api(ext.LoginPath || '/app/userInfo', {
        os: 'android', name: 'xiaomi', version: '15', sdkInt: 32, device: 'xiaomi', brand: 'xiaomi',
        manufacturer: 'xiaomi', product: 'b0q', hardware: 'xiaomi', isPhysicalDevice: true,
        androidId: 'V417IR', bootloader: 'unknown', display: 'V417IR release-keys',
        host: 'a11-gz01-test', tags: 'release-keys', type: 'user',
        finger: 'xiaomi/b0q/b0q:15/V619IR/613:user/release-keys',
        app: {
          version: ext.versionName, name: ext.name, 'package': ext.package,
          buildNumber: ext.buildNumber, buildSignature: ext.buildSignature,
          install: installed, update: installed
        },
        did: uuid4(), apiVersion: 'v2', channel: '', token: ''
      });
      if (login.userInfo && login.userInfo.user_token) cfg.token = login.userInfo.user_token;
      return '';
    },

    homeContent: function () {
      var classes = cache.categories.map(function (c) {
        return { type_id: String(c.id), type_name: c.name };
      });
      // No filter rows: the original builds them from `type_extend` and then reads every value in
      // categoryContent and throws it away. Dead chips are worse than none.
      return host.result.home(classes, listing('1', '1').items);
    },

    categoryContent: function (tid, page) {
      var result = listing(tid, page);
      return host.result.page(result.items, page || '1', result.pages);
    },

    detailContent: function (ids) {
      var data = api('/vod/detail', { id: String(ids[0]), eps: '1', v: '2.0.0', pl: 1 }).data || {};
      var names = {};
      Object.keys(cache.player || {}).forEach(function (k) {
        var entry = cache.player[k] || {};
        if (entry.code) names[String(entry.code).trim()] = String(entry.name || '').trim();
      });
      var froms = String(data.play_from || '').split('$$$');
      var urls = String(data.play_url || '').split('$$$').map(function (group, index) {
        var from = froms[index] || '';
        return group.split('#').map(function (episode) {
          var parts = episode.split('$');
          var label = parts[0] || '';
          return label + '$' + (parts[1] || '') + '@' + from + '@' + (data.name || '')
               + '@' + (label.replace(/\D+/g, '') || '1');
        }).join('#');
      });
      return host.result.detail({
        vod_id: String(data.id || ids[0]),
        vod_name: data.name || '',
        vod_pic: data.pic || '',
        vod_remarks: data.remarks || '',
        vod_year: data.year || '',
        vod_area: data.area || '',
        vod_content: data.content || '',
        vod_actor: data.actor || '',
        vod_director: data.director || '',
        type_name: data['class'] || '',
        vod_play_from: froms.map(function (f) { return names[f] || f; }).join('$$$'),
        vod_play_url: urls.join('$$$')
      });
    },

    searchContent: function (key_, quick, page) {
      var data = api('/vod/search', {
        kw: String(key_), page: parseInt(page || 1, 10), limit: 21,
        orderBy: 'vod_hits_month', sort: 'desc'
      });
      return host.result.list(vodList(data.data));
    },

    playerContent: function (flag, id, vipFlags) {
      var parts = String(id).split('@');
      var target = parts[0], from = parts[1];
      var player = (cache.player || {})[from] || {};
      // The original attaches no headers at all; every port in this app sends at least the UA it
      // used to reach the site, so a referer/UA-checked CDN has something to accept once
      // `PlayerView` learns to pass them through.
      var play = { 'User-Agent': cfg.ua };
      // type 0 is a direct file; anything else has to go through one of the site's parsers.
      if (player.type === 0) return host.result.play(target, false, play);

      var allowed = String(player.parseUrl || '').split(',').filter(function (v) { return v; });
      for (var i = 0; i < cache.parses.length; i++) {
        var parse = cache.parses[i] || {};
        var parseId = String(parse.id);
        if (allowed.length && allowed.indexOf(parseId) === -1) continue;
        var found = '';
        if (parse.api_url) {
          // river-fman: a plain GET of `api_url + url` answering {"url": …}.
          var res = host.get(parse.api_url + target, { headers: { 'User-Agent': cfg.ua }, timeout: 20000 });
          found = (res.json && res.json.url) || '';
        } else {
          // xiaosa: the site's own signed parser.
          found = String(api('/app/vodParser', { id: parse.id, url: target }).data || '');
        }
        // The decompiled loop keeps going and then clears what it found, which would leave every
        // parsed episode unplayable; the first resolved URL is plainly the intent.
        if (found.indexOf('http') === 0) return host.result.play(found, false, play);
      }
      // Nothing parsed: let the IOS-POC-5G sniffer look at the page rather than return nothing.
      return host.result.play(target, true, play);
    },

    isVideoFormat: function (url) { return /\.(m3u8|mp4|mkv|flv)(\?|$)/i.test(String(url)); },
    manualVideoCheck: function () { return false; },
    destroy: function () {
      cfg = { url: '', appkey: '', uuid: '', ua: '', version: '', token: '' };
      cache = { player: {}, parses: [], categories: [] };
    }
  };
})();

module.exports = spider;
