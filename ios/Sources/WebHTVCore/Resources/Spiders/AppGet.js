/**
 * csp_AppGet — ported from `com.github.catvod.spider.AppGet`
 * (river-fman.jar 483 lines, xiaosa-0807.jar 476 lines; the two differ only cosmetically).
 *
 * A 苹果CMS "App API" client. Every response arrives as `{"data": "<base64>"}` whose plaintext is
 * AES-CBC/PKCS7 with the site's own key and IV, both supplied in `ext`. The original reaches that
 * through `C0393a.a(data, key, iv)`, which is `Cipher.getInstance("AES/CBC/PKCS7Padding")` — stock,
 * so it is reimplemented against host.crypto rather than carried over.
 *
 * Only what is genuinely site-specific lives here: endpoints, request params, the response mapping
 * and the player parsing. HTTP, crypto, encoding and the CatVod result shapes all come from host.js.
 */
var spider = (function () {
  'use strict';

  var cfg = { url: '', key: '', iv: '', ua: 'okhttp/3.14.9', version: '', deviceId: '', token: '' };

  /** `AppGet.a(path, body)`: POST, then AES-decrypt the `data` envelope. */
  function api(path, body) {
    var headers = {
      'User-Agent': cfg.ua,
      // The original builds the body with MediaType "application/json; charset=utf-8"
      // (merge/p036k/c.java): the header map says form-urlencoded, but OkHttp sends the body's own
      // type. Posting form-urlencoded makes vodDetail silently return no `vod` at all.
      'Content-Type': 'application/json; charset=utf-8',
      'app-user-device-id': cfg.deviceId,
      'app-version-code': cfg.version,
      'app-api-verify-time': String(host.timestamp()),
      'app-ui-mode': 'light'
    };
    if (cfg.token) headers['app-user-token'] = cfg.token;
    var res = host.post(cfg.url + '/api.php' + path, body, { headers: headers, timeout: 20000 });
    if (!res.json || !res.json.data) return {};
    var plain = host.aesDecrypt(res.json.data, cfg.key, cfg.iv, 'CBC', 'base64');
    try { return JSON.parse(plain); } catch (e) { return {}; }
  }

  /** `parseVodList`: the four fields every listing returns. */
  function vodList(array) {
    return (array || []).map(function (v) {
      return { vod_id: v.vod_id, vod_name: v.vod_name, vod_pic: v.vod_pic, vod_remarks: v.vod_remarks };
    });
  }

  // The original hides these categories; keeping the filter keeps the class list identical.
  var HIDDEN = ['正版QQ群', '伦理', '福利', '小影院'];

  return {
    init: function (extend) {
      var ext = {};
      try { ext = JSON.parse(extend || '{}'); } catch (e) { ext = {}; }
      cfg.key = ext.dataKey || '';
      cfg.iv = ext.dataIv || '';
      cfg.ua = ext.ua || cfg.ua;
      cfg.version = ext.version || '';
      cfg.deviceId = ext.deviceId || '';
      cfg.token = ext.token || '';
      cfg.url = ext.url || '';
      // `site` points at a text file listing candidate hosts, one per line; take the first that works.
      if (!cfg.url && ext.site) {
        var body = host.get(ext.site, { timeout: 15000 }).body || '';
        var lines = body.split('\n');
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i].trim();
          if (/^https?:\/\//.test(line)) { cfg.url = line; break; }
        }
      }
      cfg.url = String(cfg.url).replace(/\/+$/, '');
      return '';
    },

    homeContent: function () {
      var data = api('/getappapi.index/initV119', '{}');
      var classes = [];
      (data.type_list || []).forEach(function (t) {
        if (HIDDEN.indexOf(t.type_name) === -1) {
          classes.push({ type_id: String(t.type_id), type_name: t.type_name });
        }
      });
      return host.result.home(classes, vodList(data.recommend_list));
    },

    categoryContent: function (tid, page, filter, extend) {
      var body = { type_id: String(tid), page: String(page || '1') };
      // The original maps the UI's `by` onto the API's `sort` and passes the rest through.
      ['class', 'lang', 'area', 'year'].forEach(function (k) {
        if (extend && extend[k]) body[k] = extend[k];
      });
      if (extend && extend.by) body.sort = extend.by;
      var data = api('/getappapi.index/typeFilterVodList?page=' + body.page, JSON.stringify(body));
      return host.result.page(vodList(data.recommend_list), body.page);
    },

    detailContent: function (ids) {
      var data = api('/getappapi.index/vodDetail', JSON.stringify({ vod_id: String(ids[0]) }));
      var v = data.vod || {};
      var froms = [], urls = [];
      (data.vod_play_list || []).forEach(function (group) {
        var info = group.player_info || {};
        var episodes = (group.urls || []).map(function (ep) {
          // The episode id carries what playerContent needs: the (possibly encrypted) url, the
          // vod name and the nid, joined exactly as the original does.
          var target = /^https?:\/\//.test(ep.parse_api_url || '')
            ? ep.parse_api_url
            : 'parse_api=' + (info.parse || '') + '&url=' + host.base64.encode(ep.url || '') + '&token=' + (ep.token || '');
          return (ep.name || '') + '$' + target + '|' + (v.vod_name || '') + '|' + (ep.nid || '');
        });
        if (episodes.length) { froms.push(info.show || 'default'); urls.push(episodes.join('#')); }
      });
      return host.result.detail({
        vod_id: String(ids[0]),
        vod_name: v.vod_name || '',
        vod_pic: v.vod_pic || '',
        vod_remarks: v.vod_remarks || '',
        vod_content: v.vod_content || '',
        vod_actor: v.vod_actor || '',
        vod_director: v.vod_director || '',
        type_name: v.vod_class || '',
        vod_play_from: froms.join('$$$'),
        vod_play_url: urls.join('$$$')
      });
    },

    searchContent: function (key, quick, page) {
      var data = api('/getappapi.index/searchList',
                     JSON.stringify({ type_id: 0, keywords: String(key), page: parseInt(page || 1, 10) }));
      return host.result.list(vodList(data.search_list));
    },

    playerContent: function (flag, id, vipFlags) {
      var parts = String(id).split('|');
      var target = parts[0];
      var headers = { 'User-Agent': cfg.ua };

      // Already a playable file: hand it straight over, as the original does.
      if (/\.(m3u8|mp4|mkv|flv)(\?|$)/i.test(target)) return host.result.play(target, false, headers);

      // A parse endpoint that answers with {"url": ...}.
      if (/^https?:\/\//.test(target)) {
        var res = host.get(target, { headers: headers, timeout: 20000 });
        var url = (res.json && (res.json.url || (res.json.data && res.json.data.url)))
               || host.match(res.body, '"url"\\s*:\\s*"([^"]+)"');
        if (url) return host.result.play(url.replace(/\\\//g, '/'), false, headers);
        return host.result.play(target, true, headers);
      }

      // `parse_api=<endpoint>&url=<base64 aes>&token=<token>`: the url is AES-encrypted with the
      // same site key, so it decrypts locally without calling the parse endpoint at all.
      var encoded = host.match(target, 'url=([^&]+)');
      if (encoded) {
        var plain = host.aesDecrypt(host.dec(encoded), cfg.key, cfg.iv, 'CBC', 'base64');
        if (/^https?:\/\//.test(plain)) return host.result.play(plain, false, headers);
      }
      var parseApi = host.match(target, 'parse_api=([^&]+)');
      if (parseApi) {
        var parsed = host.get(parseApi, { headers: headers, timeout: 20000 });
        var found = (parsed.json && parsed.json.data && parsed.json.data.url)
                 || host.match(parsed.body, '"url"\\s*:\\s*"([^"]+)"');
        if (found) return host.result.play(found.replace(/\\\//g, '/'), false, headers);
      }
      return host.result.play(target, true, headers);
    },

    isVideoFormat: function (url) { return /\.(m3u8|mp4|mkv|flv)(\?|$)/i.test(String(url)); },
    manualVideoCheck: function () { return false; },
    destroy: function () { cfg = { url: '', key: '', iv: '', ua: 'okhttp/3.14.9', version: '', deviceId: '', token: '' }; }
  };
})();

module.exports = spider;
