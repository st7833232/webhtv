/**
 * csp_AppQi — ported from `com.github.catvod.spider.AppQi`
 * (river-fman.jar 494 lines, xiaosa-0807.jar 531, 愛影.jar 498).
 *
 * The same 苹果CMS "App API" family as the ported `AppGet`, under the `/qijiappapi.index/` prefix:
 * every response is `{"data": "<base64>"}` whose plaintext is AES-CBC/PKCS7 with the site's own
 * `dataKey` / `dataIv`. Three things are genuinely its own, and are why this is a second script
 * rather than a flag on `AppGet.js`:
 *
 *   1. the episode payload is `base64(AES(url))`, not plain base64 — the site's own `vodParse`
 *      endpoint consumes it, so the encryption is not internal to the spider,
 *   2. `vodParse` is a POST signed with `app-api-verify-sign: base64(AES(timestamp))`, whose
 *      decrypted reply nests the answer one JSON level deeper: `{"json": "{\"url\": …}"}`,
 *   3. the newer xiaosa/愛影 build answers `code 1001` on search until a slider challenge is
 *      echoed back — `target_x` is handed to us, so "solving" it is one more request.
 *
 * `init` and `search` method names come from `ext` because the sites disagree about them
 * (`initV120` / `initV122`, `searchList` / `mineInfo`). Danmaku is dropped: those URLs are
 * `Proxy.getUrl()`-relative and iOS has no local HTTP server.
 */
var spider = (function () {
  'use strict';

  var cfg = { url: '', key: '', iv: '', ua: 'okhttp/3.14.9', version: '', deviceId: '',
              init: 'initV120', search: 'searchList' };

  function headers() {
    return {
      'User-Agent': cfg.ua,
      'Content-Type': 'application/x-www-form-urlencoded',
      'app-user-device-id': cfg.deviceId,
      'app-version-code': cfg.version,
      'app-api-verify-time': String(host.timestamp()),
      'app-ui-mode': 'light'
    };
  }

  /** `AppQi.a`/`b`: POST and hand back both the envelope and its decrypted payload. */
  function api(path, body) {
    var res = host.post(cfg.url + '/api.php' + path, body, { headers: headers(), timeout: 20000 });
    var envelope = res.json || {};
    return { envelope: envelope, data: decrypt(envelope.data) };
  }

  function decrypt(payload) {
    if (!payload) return {};
    var plain = host.aesDecrypt(payload, cfg.key, cfg.iv, 'CBC', 'base64');
    try { return JSON.parse(plain); } catch (e) { return {}; }
  }

  /** `performSliderVerification`: the challenge ships its own answer in `target_x`. */
  function solveSlider() {
    var challenge = api('/qijiappapi.index/getSlider', '').data;
    if (!challenge.slider_id) return false;
    var reply = api('/qijiappapi.index/verifySlider', JSON.stringify({
      pos_x: challenge.target_x, slider_id: challenge.slider_id, timestamp: host.timestamp()
    }));
    return reply.envelope.code === 1;
  }

  function vodList(array) {
    return (array || []).map(function (v) {
      return { vod_id: v.vod_id, vod_name: v.vod_name, vod_pic: v.vod_pic, vod_remarks: v.vod_remarks };
    });
  }

  // The original hides these three (note it does *not* hide AppGet's 正版QQ群).
  var HIDDEN = ['伦理', '福利', '小影院'];
  var FILTER_KEYS = ['class', 'area', 'lang', 'year', 'sort'];
  var FILTER_NAMES = { 'class': '類型', area: '地區', lang: '語言', year: '年份', sort: '排序' };

  return {
    init: function (extend) {
      var ext = {};
      try { ext = JSON.parse(extend || '{}'); } catch (e) { ext = {}; }
      cfg.key = ext.dataKey || '';
      cfg.iv = ext.dataIv || '';
      cfg.ua = ext.ua || cfg.ua;
      cfg.version = ext.version || '';
      cfg.deviceId = ext.deviceId || '';
      cfg.init = ext.init || cfg.init;
      cfg.search = ext.search || cfg.search;
      cfg.url = ext.url || '';
      // `site` is a text file of candidate hosts, one per line. The original HEADs each line and
      // takes the first that answers 200/301/302; every configured file holds exactly one URL, so
      // taking the first well-formed line costs one request less and picks the same host.
      if (!cfg.url && ext.site) {
        var lines = (host.get(ext.site, { timeout: 15000 }).body || '').split('\n');
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i].trim();
          if (/^https?:\/\//.test(line)) { cfg.url = line; break; }
        }
      }
      cfg.url = String(cfg.url).replace(/\/+$/, '');
      return '';
    },

    homeContent: function () {
      var data = api('/qijiappapi.index/' + cfg.init, '{}').data;
      var classes = [], filters = {};
      (data.type_list || []).forEach(function (t) {
        if (HIDDEN.indexOf(t.type_name) !== -1) return;
        var id = String(t.type_id);
        classes.push({ type_id: id, type_name: t.type_name });
        var rows = [];
        (t.filter_type_list || []).forEach(function (f) {
          if (FILTER_KEYS.indexOf(f.name) === -1) return;
          var options = (f.list || []).map(function (v) {
            var label = String(v);
            // 全部 means "no constraint" and must travel empty; the original sends the literal
            // word, which the API would then filter by. Same rule as AppGet.js since IOS-POC-5J.
            return { n: label, v: label === '全部' ? '' : label };
          });
          if (!options.length) return;
          if (options[0].v !== '') options.unshift({ n: '全部', v: '' });
          // `sort` is renamed `by`, the rename createFilterItem does, and categoryContent undoes.
          rows.push({ key: f.name === 'sort' ? 'by' : f.name, name: FILTER_NAMES[f.name], value: options });
        });
        if (rows.length) filters[id] = rows;
      });
      return host.result.home(classes, vodList(data.recommend_list), filters);
    },

    categoryContent: function (tid, page, filter, extend) {
      var body = { type_id: String(tid) };
      ['class', 'lang', 'area', 'year'].forEach(function (k) {
        if (extend && extend[k]) body[k] = extend[k];
      });
      if (extend && extend.by) body.sort = extend.by;
      body.page = String(page || '1');
      var data = api('/qijiappapi.index/typeFilterVodList?page=' + body.page, JSON.stringify(body)).data;
      return host.result.page(vodList(data.recommend_list), body.page);
    },

    detailContent: function (ids) {
      var data = api('/qijiappapi.index/vodDetail', JSON.stringify({ vod_id: String(ids[0]) })).data;
      var v = data.vod || {};
      var froms = [], urls = [];
      (data.vod_play_list || []).forEach(function (group) {
        var info = group.player_info || {};
        var episodes = (group.urls || []).map(function (ep) {
          var direct = String(ep.parse_api_url || '');
          // Unlike AppGet the fallback is base64(AES(url)): the site decrypts it in vodParse.
          var target = /^https?:\/\//.test(direct)
            ? direct
            : 'parse_api=' + (info.parse || '')
              + '&url=' + host.aesEncrypt(String(ep.url || ''), cfg.key, cfg.iv, 'CBC')
              + '&token=' + (ep.token || '');
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
      var path = '/qijiappapi.index/' + cfg.search;
      var body = JSON.stringify({ type_id: 0, keywords: String(key), page: parseInt(page || 1, 10) });
      var res = api(path, body);
      // 1001 is the newer build asking for the slider before it will answer.
      if (res.envelope.code === 1001 && solveSlider()) res = api(path, body);
      return host.result.list(vodList(res.data.search_list));
    },

    playerContent: function (flag, id, vipFlags) {
      var parts = String(id).split('|');
      // A four-part id carries an extra field the original drops before reading [0].
      var target = parts[0];
      var play = { 'User-Agent': cfg.ua };

      // An endpoint that answers with {"url": …}.
      if (/^https?:\/\//.test(target) && (target.indexOf('?url=') !== -1 || target.indexOf('?key=') !== -1)) {
        var res = host.get(target, { headers: play, timeout: 20000 });
        var found = (res.json && res.json.url) || host.match(res.body, '"url"\\s*:\\s*"([^"]+)"');
        if (found) return host.result.play(found.replace(/\\\//g, '/'), false, play);
      }
      if (/(m3u8|mp4|mkv)/i.test(target)) return host.result.play(target, false, play);

      // `parse_api=<endpoint>&url=<base64(AES(url))>&token=…`. Decrypting the payload gives the
      // real target outright whenever the site put one there.
      var encoded = host.match(target, 'url=([^&]+)');
      var plain = encoded ? host.aesDecrypt(host.dec(encoded), cfg.key, cfg.iv, 'CBC', 'base64') : '';
      if (/^https?:\/\//.test(plain)) return host.result.play(plain, false, play);
      // `eduAesDecode` + `(parse_api=)(.*?)(?=&token)` in the original: the captured group is the
      // parse endpoint *with* `&url=<decrypted>` still glued to it, which is what gets fetched.
      var parseApi = host.match(target, 'parse_api=([^&]*)');
      if (parseApi && /^https?:\/\//.test(parseApi)) {
        var parsed = host.get(parseApi + '&url=' + plain, { headers: play, timeout: 20000 });
        var direct = (parsed.json && parsed.json.data && parsed.json.data.url)
                  || (parsed.json && parsed.json.url)
                  || host.match(parsed.body, '"url"\\s*:\\s*"([^"]+)"');
        if (direct) return host.result.play(direct.replace(/\\\//g, '/'), false, play);
      }

      // Last resort, and the site's own route: POST the whole string to vodParse, signed.
      var stamp = String(host.timestamp());
      var signed = host.post(cfg.url + '/api.php/qijiappapi.index/vodParse', target, {
        headers: {
          'User-Agent': cfg.ua,
          'Connection': 'Keep-Alive',
          'Content-Type': 'application/x-www-form-urlencoded',
          'app-version-code': cfg.version,
          'app-ui-mode': 'light',
          'app-user-device-id': cfg.deviceId,
          'app-api-verify-time': stamp,
          'app-api-verify-sign': host.aesEncrypt(stamp, cfg.key, cfg.iv, 'CBC')
        },
        timeout: 20000
      });
      var payload = decrypt((signed.json || {}).data);
      var nested = payload.json;
      if (nested) {
        try { nested = JSON.parse(nested); } catch (e) { nested = {}; }
        if (nested.url) return host.result.play(nested.url, false, play);
      }
      // Nothing resolved: hand the target back for the sniffer rather than a dead result.
      return host.result.play(target, true, play);
    },

    isVideoFormat: function (url) { return /\.(m3u8|mp4|mkv|flv)(\?|$)/i.test(String(url)); },
    manualVideoCheck: function () { return false; },
    destroy: function () { cfg.url = ''; cfg.key = ''; cfg.iv = ''; }
  };
})();

module.exports = spider;
