/**
 * csp_App3Q — ported from `com.github.catvod.spider.App3Q`
 * (river-fman.jar 265 lines, xiaosa-0807.jar 285, 愛影.jar 269).
 *
 * A plain JSON app API, no body encryption: every request is a GET whose authenticity rests on one
 * header, `x-sign` = uppercase SHA-256 hex of
 * `finger=<finger>&id=<pkg>&nonce=<nonce>&sk=<sk>&time=<time>&v=<ver>` — the fields sorted
 * alphabetically, which is the whole "signature".
 *
 * The two builds disagree about where those fields live: river-fman compiles them in and treats
 * `ext` as a bare host string, xiaosa reads them all from an `ext` object. The port takes `ext` when
 * it is JSON and falls back to the compiled-in constants otherwise, so one script serves both.
 */
var spider = (function () {
  'use strict';

  // river-fman's compiled-in identity; the xiaosa build sends the site's own instead.
  var cfg = {
    url: 'https://bbys.app',
    finger: 'SF-C3B2B41F6EFFFF9869176CF68F6790E8F07506FC88632C94B4F5F0430D5498CA',
    pkg: 'com.sunshine.tv',
    sk: 'SK-thanks',
    ver: '4',
    brand: 'OnePlus',
    model: 'HD1900',
    updateId: '73dc2ffc-8350-c022-fac9-da982c95f513',
    time: '',
    nonce: ''
  };

  function headers() {
    var payload = 'finger=' + cfg.finger + '&id=' + cfg.pkg + '&nonce=' + cfg.nonce
                + '&sk=' + cfg.sk + '&time=' + cfg.time + '&v=' + cfg.ver;
    return {
      'user-agent': 'okhttp/4.12.0',
      // The xiaosa build adds these two; sending them everywhere is harmless and keeps one path.
      'accept': 'application/json',
      'x-platform': 'android',
      'x-ave': cfg.ver,
      'x-aid': cfg.pkg,
      'x-time': cfg.time,
      'x-nonc': cfg.nonce,
      'x-sign': host.sha256(payload).toUpperCase(),
      'x-device-id': '0b4328287a5d953e',
      'x-device-brand': cfg.brand,
      'x-device-model': cfg.model,
      'x-update-id': cfg.updateId
    };
  }

  function api(path) {
    var res = host.get(cfg.url + path, { headers: headers(), timeout: 20000 });
    return res.json || {};
  }

  function vodList(array) {
    return (array || []).map(function (v) {
      return { vod_id: v.vod_id, vod_name: v.vod_name, vod_pic: v.vod_pic, vod_remarks: v.vod_remarks };
    });
  }

  return {
    init: function (extend) {
      var ext = null;
      try { ext = JSON.parse(extend || 'null'); } catch (e) { ext = null; }
      if (ext && typeof ext === 'object') {
        cfg.url = ext.host || cfg.url;
        cfg.finger = ext.finger || cfg.finger;
        cfg.pkg = ext.pkg || cfg.pkg;
        cfg.sk = ext.sk || cfg.sk;
        cfg.ver = ext.ver || cfg.ver;
        cfg.brand = ext.deviceBrand || cfg.brand;
        cfg.model = ext.deviceModel || cfg.model;
        cfg.updateId = ext.updateId || cfg.updateId;
      } else if (extend && String(extend).indexOf('http') === 0) {
        // river-fman/愛影: `ext` is the host itself, or empty for the compiled-in default.
        cfg.url = String(extend).trim();
      }
      cfg.url = String(cfg.url).replace(/\/+$/, '');
      cfg.time = String(host.timestamp());
      cfg.nonce = String(Math.floor(Math.random() * 999) + 1);
      return '';
    },

    homeContent: function () {
      var data = api('/api.php/app/index/home').data || {};
      // The site keys a category by its name, so type_id and type_name are the same string.
      var classes = (data.categories || []).map(function (c) {
        return { type_id: c.type_name, type_name: c.type_name };
      });
      return host.result.home(classes, vodList(data.recommend));
    },

    categoryContent: function (tid, page) {
      var data = api('/api.php/app/filter/vod?type_name=' + host.enc(tid)
                     + '&page=' + (page || '1') + '&sort=hits');
      return host.result.page(vodList(data.data), page || '1');
    },

    detailContent: function (ids) {
      var body = api('/api.php/app/vod/get_detail?vod_id=' + ids[0]);
      var v = (body.data || [])[0] || {};
      // `vodplayer` renames each play_from code to something a human reads.
      var names = {};
      (body.vodplayer || []).forEach(function (p) { names[p.from] = p.show; });
      var froms = String(v.vod_play_from || '').split('$$$');
      var groups = String(v.vod_play_url || '').split('$$$');
      var urls = groups.map(function (group, index) {
        var from = froms[index] || '';
        return group.split('#').map(function (episode) {
          var parts = episode.split('$');
          var label = parts[0] || '';
          var number = label.replace(/\D+/g, '') || '1';
          // The flag travels with every episode because playerContent needs it for `vodFrom`.
          return label + '$' + (parts[1] || '') + '@' + from + '@' + (v.vod_name || '') + '@' + number;
        }).join('#');
      });
      return host.result.detail({
        vod_id: String(ids[0]),
        vod_name: v.vod_name || '',
        vod_pic: v.vod_pic || '',
        vod_remarks: v.vod_remarks || '',
        vod_content: String(v.vod_content || '').trim(),
        vod_actor: v.vod_actor || '',
        vod_director: v.vod_director || '',
        type_name: v.vod_class || '',
        vod_play_from: froms.map(function (f) { return names[f] || f; }).join('$$$'),
        vod_play_url: urls.join('$$$')
      });
    },

    searchContent: function (key, quick, page) {
      var data = api('/api.php/app/search/index?wd=' + host.enc(key)
                     + '&page=' + (page || '1') + '&limit=15');
      return host.result.list(vodList(data.data));
    },

    playerContent: function (flag, id, vipFlags) {
      var parts = String(id).split('@');
      var target = (parts[0] || '').trim(), from = (parts[1] || '').trim();
      // The UA the spider reaches the site with travels to the player too, as in every other port.
      var play = { 'User-Agent': 'okhttp/4.12.0' };
      if (/(m3u8|mp4|flv|avi|mov|mkv)/i.test(target)) return host.result.play(target, false, play);
      // The original retries this three times before giving up; the challenge branch it also
      // contains computes a token and then discards it, so it is not reproduced.
      for (var attempt = 0; attempt < 3; attempt++) {
        var res = api('/api.php/app/decode/url/?url=' + host.enc(target) + '&vodFrom=' + from);
        var data = String(res.data || '').trim();
        if (data.indexOf('http') === 0) return host.result.play(data, false, play);
        if (data) break;
      }
      return host.result.play(target, true, play);
    },

    isVideoFormat: function (url) { return /\.(m3u8|mp4|mkv|flv)(\?|$)/i.test(String(url)); },
    manualVideoCheck: function () { return false; },
    destroy: function () { cfg.time = ''; cfg.nonce = ''; }
  };
})();

module.exports = spider;
