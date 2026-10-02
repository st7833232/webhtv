/**
 * csp_HemaDJ — ported from `com.github.catvod.spider.HemaDJ` (xiaosa-0807.jar, 292 lines) and its
 * request helper `merge/A/d0.b1` with `merge/g/a3`.
 *
 * 河马短剧's free-video portal. Every call is a POST to `/free-video-portal/portal/<code>` whose body
 * is base64(AES-128-CBC/PKCS5(JSON)) under a fixed key and IV; the device profile travels the same
 * way in a `datas` header built once per session, and the reply's `data` (or `datas`) is the same
 * cipher again. On code 8 the original rebuilds `datas` and retries once, and so does this.
 *
 * IOS-POC-44A. Measured 2026-10-02: home (8 channel groups), a category, a 70-chapter detail, the
 * chapter's mp4 (206 `ftypisom`) and search all answered.
 */
var spider = (function () {
  'use strict';

  var BASE = 'https://freevideo.zqqds.cn/free-video-portal/portal/';
  var KEY = 'dzkjgfyxgshylgzm', IV = 'apiupdownedcrypt';
  var PAGE = 18;
  // The player's UA in the original, with `Build.MODEL` filled in.
  var PLAYER_UA = 'aliplayer(appv=2.7.1&av=7.1.0&av2=7.1.0_46933858&os=android&ov=11&dm=M2012K10C)';

  var datas = null;

  function encrypt(object) { return host.aesEncrypt(JSON.stringify(object), KEY, IV, 'CBC'); }

  function uuid() {
    var h = host.random(32, '0123456789abcdef');
    return h.slice(0, 8) + '-' + h.slice(8, 12) + '-4' + h.slice(13, 16) + '-a' + h.slice(17, 20)
      + '-' + h.slice(20, 32);
  }

  function pad(n) { return (n < 10 ? '0' : '') + n; }

  /** `d0.l()`: the device profile, fixed except for the session ids and the install time. */
  function deviceProfile() {
    var d = new Date(), session = uuid();
    var stamp = '' + d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate())
      + pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds());
    return encrypt({
      version: '3.6.0', pname: 'com.dz.hmjc', channelCode: 'HMJC1000001',
      utdidTmp: 'A' + stamp + 'TVBX', token: '', utdid: '7d2e96f3ed64e228ef1b337de386cdce',
      os: 'android', osv: 30, brand: 'Redmi', model: 'M2012K10C', manu: 'Xiaomi', userId: '',
      launch: 'shortcut', mchid: 'HMJC1000001', nchid: 'HMJC1000004',
      session1: session, session2: session, startScene: 'shortcut', recSwitch: true,
      installTime: host.now(), p: 36
    });
  }

  /** `d0.b1(path, body, retried)`. An error reply comes back as `{}`, which the app reports. */
  function api(code, body, retried) {
    if (!datas) datas = deviceProfile();
    var res = host.post(BASE + code, encrypt(body), {
      headers: { 'User-Agent': 'okhttp/4.10.0', 'Content-Type': 'application/json; charset=utf-8',
                 'alg': 'HG45LKBS', 'datas': datas, 'x-request-id': uuid() },
      timeout: 20000
    });
    var o = res.json || {};
    var cipher = o.data || o.datas;
    if (typeof cipher !== 'string' || !cipher) {
      if (o.code === 8 && !retried) { datas = null; return api(code, body, true); }
      return o.code && o.code !== 0 ? {} : o;
    }
    try { return JSON.parse(host.aesDecrypt(cipher, KEY, IV, 'CBC', 'base64')); } catch (e) { return {}; }
  }

  /** `b(JSONArray)`. */
  function listing(items) {
    return (items || []).map(function (v) {
      var remarks = v.finishStatusCn || '';
      if (v.updateNum != null && v.updateNum !== '') remarks += '/' + v.updateNum + '集';
      return { vod_id: v.bookId, vod_name: v.bookName || '', vod_pic: v.coverWap || '', vod_remarks: remarks };
    });
  }

  /** `c(JSONObject)`: the column lists, or the flat list when there are no columns. */
  function videos(o) {
    var out = [];
    (o.columnData || []).forEach(function (column) {
      if (column && column.videoData) out = out.concat(listing(column.videoData));
    });
    return out.length ? out : listing(o.videoData);
  }

  function firstHttp(value) {
    if (typeof value === 'string') return value.indexOf('http') === 0 ? value : '';
    if (Array.isArray(value)) {
      for (var i = 0; i < value.length; i++) {
        if (typeof value[i] === 'string' && value[i].indexOf('http') === 0) return value[i];
      }
    }
    return '';
  }

  /** `d(content, flag)`: `mp4Url`, then `mp4SwitchUrl`, then any field that holds an address. */
  function mediaURL(content, flag) {
    if (!content) return '';
    if (typeof content !== 'object') return firstHttp(content);
    var picks = [content[flag], content.mp4Url, content.mp4SwitchUrl];
    for (var name in content) picks.push(content[name]);
    for (var i = 0; i < picks.length; i++) if (firstHttp(picks[i])) return firstHttp(picks[i]);
    return '';
  }

  return {
    init: function () { datas = null; return ''; },

    homeContent: function () {
      var o = api('1125', { recSwitch: true, pageFlag: '', theaterSubscriptSwitch: true });
      var classes = [], filters = {};
      (o.channelGroupData || []).forEach(function (group) {
        var id = String(group.channelGroupId || 0);
        classes.push({ type_id: id, type_name: group.channelGroupName === '全部' ? '推荐' : group.channelGroupName });
        var channels = (group.channelData || []).map(function (c) {
          return { n: c.channelName, v: (c.channelId || 0) + '@' + c.channelName };
        });
        if (channels.length) filters[id] = [{ key: 'class', name: '类型', value: channels }];
      });
      return host.result.home(classes, videos(o), filters);
    },

    categoryContent: function (tid, page, filter, extend) {
      var pg = parseInt(page, 10) || 1;
      var body = { recSwitch: true, pageFlag: pg > 1 ? String(pg - 1) : '', theaterSubscriptSwitch: true,
                   channelGroupId: parseInt(tid, 10) || 0 };
      var cls = String((extend && extend['class']) || '');
      var channel = cls.indexOf('@') > 0 ? parseInt(cls.split('@')[0], 10) : 0;
      if (channel > 0) body.channelId = channel;
      var o = api('1125', body), items = videos(o);
      var more = o.hasMore === undefined ? items.length >= PAGE : !!o.hasMore;
      var count = more ? pg + 1 : pg;
      return host.result.page(items, pg, count, PAGE, count * PAGE);
    },

    detailContent: function (ids) {
      var id = String(ids[0]);
      var o = api('1131', { bookId: id, needNextChapter: 0, isNeedAlias: '', bookAlias: '', resolutionRate: '1080P' });
      var info = o.videoInfo || o;
      var chapters = o.chapterList || info.chapterList || [];
      var episodes = chapters.map(function (c) { return c.chapterName + '$' + id + '@' + c.chapterId; });
      // The original writes this one list three times under a single flag name, so its flag and URL
      // groups do not line up; one copy is what it means.
      return host.result.detail({
        vod_id: id,
        vod_name: info.bookName || '',
        vod_pic: info.coverWap || '',
        vod_remarks: info.finishStatusCn || '',
        vod_content: info.introduction || '',
        vod_actor: info.protagonist || '',
        vod_play_from: episodes.length ? '河马' : '',
        vod_play_url: episodes.join('#')
      });
    },

    searchContent: function (key) {
      var o = api('1803', { keyword: String(key || '').trim(), page: 1, size: 15, hotWordType: 2 });
      return host.result.list(listing(o.searchVos || o.content));
    },

    playerContent: function (flag, id) {
      var value = String(id), at = value.indexOf('@');
      if (at <= 0 || at >= value.length - 1) return host.result.play('', false);
      var book = value.slice(0, at), chapter = value.slice(at + 1);
      var o = api('1139', {
        bookId: book, chapterId: chapter, unClockType: 'load', tierPlaySource: null, chapterIds: [chapter],
        omap: { expId: null, logId: null, originName: 'bigdata_rec', recId: null, scene: 'dzmf_video_sc_reco',
                sceneId: 'dzmf_video_sc_reco', strategyId: 'godum7go', strategyName: 'omap' }
      });
      var info = Array.isArray(o.chapterInfo) ? o.chapterInfo[0] : o.chapterInfo;
      var url = info ? mediaURL(info.content, flag) : '';
      if (!url && o.ad) url = mediaURL(o.ad.content, flag);
      return host.result.play(url, false, { 'User-Agent': PLAYER_UA });
    },

    isVideoFormat: function (url) { return /\.(m3u8|mp4|mkv|flv)(\?|$)/i.test(String(url)); },
    manualVideoCheck: function () { return false; },
    destroy: function () { datas = null; }
  };
})();

module.exports = spider;
