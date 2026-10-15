/**
 * ShortXingya (星芽短剧) spider.
 * Port of com.github.catvod.spider.ShortXingya from qist spider.jar (IOS-POC-57B-7, design W-61).
 * Login on u.shytkjgs.com (AES-ECB device JSON) gives a token for the JSON API on app.whjzjx.cn;
 * media is plain-HTTP mp4 on qcapp.xingya.com.cn, signed for four hours, so nothing caches it.
 */
(function () {
  'use strict';

  var LOGIN = 'https://u.shytkjgs.com/user/v3/account/login';
  var API = 'https://app.whjzjx.cn';
  var KEY = 'B@ecf920Od8A4df7';
  var JSON_TYPE = 'application/json; charset=utf-8';
  var LOGIN_UA = 'Mozilla/5.0 (Linux; Android 9; V1938T Build/PQ3A.190705.08211809; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/91.0.4472.114 Safari/537.36';
  // Upstream's string as is, missing its opening "Mozilla/5.0 (" (ShortXingya.java:144–155); the gate got 206 with it.
  var PLAY_UA = 'Linux; Android 12; Pixel 3 XL) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/98.0.4758.101 Mobile Safari/537.36';
  var CLASSES = [['1', '剧场'], ['3', '新剧'], ['2', '热播'], ['7', '星选'], ['5', '阳光']];

  // In memory only: never stored, logged or returned (W-61 D2).
  var token = '';

  function text(value) { return value === null || value === undefined ? '' : String(value); }

  function pageNumber(pg) {
    var s = text(pg);
    return /^[+-]?\d+$/.test(s) ? Math.max(1, parseInt(s, 10)) : 1;
  }

  // Device JSON in upstream's field order (ShortXingya.java:47–56); the body is a string, so no form encoding.
  function login() {
    var device = '{"device":"2a50580e69d38388c94c93605241fb306","package_name":"com.jz.xydj",'
      + '"android_id":"ec1280db12795506","install_first_open":true,"first_install_time":1752505243345,'
      + '"last_update_time":1752505243345,"report_link_url":"","authorization":"","timestamp":' + host.now() + '}';
    var res = host.post(LOGIN, host.aesEncrypt(device, KEY, '', 'ECB'), {
      headers: { 'platform': '1', 'user_agent': LOGIN_UA, 'content-type': JSON_TYPE }, timeout: 15000
    });
    var data = res.status === 200 && res.json && res.json.data;
    token = data && typeof data.token === 'string' ? data.token : '';
    return token !== '';
  }

  // Logs in when there is no token. Anything but a 200 JSON with code 'ok' drops the token, so the next
  // call logs in again; this call is not retried (upstream never logs in again, ShortXingya.java:45–46).
  function api(path, body) {
    if (!token && !login()) return null;
    var options = { headers: { 'authorization': token, 'platform': '1', 'version_name': '3.8.3.1' }, timeout: 15000 };
    var res;
    if (body === undefined) {
      res = host.get(API + path, options);
    } else {
      // OkHttp sends upstream's string body as JSON (merge/p036k/c.java:53–55); without this it would go as a form.
      options.headers['content-type'] = JSON_TYPE;
      res = host.post(API + path, body, options);
    }
    if (res.status === 200 && res.json && res.json.code === 'ok') return res.json.data || null;
    token = '';
    return null;
  }

  // A positive integer id, number or digit string (upstream's optInt), as a string; '' otherwise.
  function positive(id) {
    var s = text(id);
    return /^[1-9]\d*$/.test(s) ? s : '';
  }

  // Upstream's c() (ShortXingya.java:26–42): theme, else play_amount_str.
  function vods(list, remark) {
    var out = [];
    (Array.isArray(list) ? list : []).forEach(function (item) {
      var t = item && item.theater;
      var id = t && typeof t === 'object' ? positive(t.id) : '';
      if (!id) return;
      out.push({ vod_id: id, vod_name: text(t.title), vod_pic: text(t.cover_url), vod_remarks: remark(t) });
    });
    return out;
  }
  function themeOrPlays(t) { return text(t.theme) || text(t.play_amount_str); }
  function plays(t) { return text(t.play_amount_str); }

  function playable(url) { return /^https?:\/\/[^$#]*$/.test(text(url)); }

  var spider = {
    init: function (extend) { return ''; },

    homeContent: function (filter) {
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }));
    },

    homeVideoContent: function () {
      var data = api('/v1/theater/home_page?theater_class_id=1&class2_id=4&page_num=1&page_size=24');
      return host.result.list(vods(data && data.list, plays));
    },

    categoryContent: function (tid, pg, filter, extend) {
      var id = text(tid), page = pageNumber(pg);
      if (!/^\d+$/.test(id)) return host.result.page([], page, page, 90, 9999);
      var data = api('/v1/theater/home_page?theater_class_id=' + id + '&page_num=' + page + '&page_size=24');
      // Upstream always reports a next page (ShortXingya.java:85); is_end says when there is none. Limit and total are upstream's.
      return host.result.page(vods(data && data.list, themeOrPlays), page,
        data && data.is_end === true ? page : page + 1, 90, 9999);
    },

    detailContent: function (ids) {
      var id = text(ids && ids[0]);
      if (!/^\d+$/.test(id)) return host.result.list([]);
      var d = api('/v2/theater_parent/detail?theater_parent_id=' + id);
      if (!d || typeof d !== 'object') return host.result.list([]);
      var from = '星芽', episodes = [];
      if (Array.isArray(d.theaters) && d.theaters.length > 0) {
        d.theaters.forEach(function (ep, i) {
          if (!ep || !playable(ep.son_video_url)) return;
          // The number as upstream's optString reads it, else its position in the list.
          episodes.push((text(ep.num).replace(/[$#]/g, ' ').trim() || String(i + 1)) + '$' + ep.son_video_url);
        });
      } else if (playable(d.video_url)) {
        // Upstream's value here is lost to decompilation (ShortXingya.java:101–104); W-61 fixes it as 星芽.
        episodes.push('1$' + d.video_url);
      } else {
        from = '无播放源';
      }
      var tags = Array.isArray(d.desc_tags) ? d.desc_tags : [];
      return host.result.detail({
        vod_id: id,
        vod_name: text(d.title) || id,
        vod_pic: text(d.cover_url),
        vod_remarks: text(d.filing),
        vod_content: text(d.introduction),
        vod_area: text(tags[0]),
        vod_play_from: from,
        vod_play_url: episodes.join('#')
      });
    },

    searchContent: function (key, quick, pg) {
      var wd = text(key).trim();
      if (!wd) return host.result.list([]);
      var data = api('/v3/search', JSON.stringify({ text: wd }));
      var found = data && data.theater && data.theater.search_data, out = [];
      (Array.isArray(found) ? found : []).forEach(function (item) {
        var id = item && typeof item === 'object' ? positive(item.id) : '';
        if (!id) return;
        out.push({ vod_id: id, vod_name: text(item.title), vod_pic: text(item.cover_url), vod_remarks: text(item.score_str) });
      });
      return host.result.list(out);
    },

    playerContent: function (flag, id, vipFlags) {
      var url = text(id);
      if (!/^https?:\/\//.test(url)) return host.result.play('', false);
      return host.result.play(url, false, { 'User-Agent': PLAY_UA });
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
