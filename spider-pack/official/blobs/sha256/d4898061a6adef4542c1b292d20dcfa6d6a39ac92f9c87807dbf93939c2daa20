/**
 * csp_AppYQK — ported from `com.github.catvod.spider.AppYQK` (xiaosa-0807.jar, 342 lines).
 *
 * 一起影视's web API. Every call is a JSON POST whose body carries `sign` = md5 of the fields as
 * `k=v&…` with `appKey=…` appended; the original's field orders are all alphabetical, so the fields
 * are sorted here. Its `udid` is the millisecond clock as 16 hex digits (`getUUID` builds a UUID and
 * then returns only that), its `requestId` 32 random alphanumerics.
 *
 * Playback is two-step: `epDetail` lists an episode's qualities and `playUrl` signs one address per
 * quality. Only qualities marked `canPlay` are requested — the web API refuses the others ("网页版
 * 不支持该清晰度"; measured 2026-10-06, 超清 is marked `APP独享` and refused).
 *
 * IOS-POC-44E. Measured 2026-10-06: channels, topic lists, detail with 18 lines, qualities, a 标清
 * m3u8 whose TS segments read, and search with its `nextVal` cursor all answered; a bad sign gets
 * `sign error`.
 */
var spider = (function () {
  'use strict';

  var API = 'https://yzy0916.n0z6fkpuk.com';
  var APP_KEY = '3359de478f8d45638125e446a10ec541';
  var ALNUM = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  var HEADERS = { 'User-Agent': 'Dart/3.1 (dart:io)', 'Origin': 'https://yqk1.app', 'Referer': 'https://yqk1.app/' };
  var SKIPPED = ['短剧', '体育'];

  // Search pages by cursor: the `nextVal` page n answered is what page n+1 must send.
  var cursors = {};

  /** `getSign` over the common fields plus `fields`, posted as JSON. */
  function api(path, fields) {
    var all = { appId: 'e6ddefe09e0349739874563459f56c54', cus1tom: 'aabbcc', deviceInfo: 'Android',
                reqDomain: 'yqk1.app', requestId: host.random(32, ALNUM),
                udid: ('000000000000000' + host.now().toString(16)).slice(-16), version: '1.2.7.104' };
    Object.keys(fields).forEach(function (k) { all[k] = String(fields[k]); });
    var body = {};
    Object.keys(all).sort().forEach(function (k) { body[k] = all[k]; });
    var signed = Object.keys(body).map(function (k) { return k + '=' + body[k]; }).join('&');
    body.sign = host.md5(signed + '&appKey=' + APP_KEY);
    var res = host.post(API + path, JSON.stringify(body), {
      headers: Object.assign({ 'Content-Type': 'application/json; charset=utf-8' }, HEADERS), timeout: 20000
    });
    return res.json || {};
  }

  /** A listing; the topic lists repeat titles across topics, and one page shows each once. */
  function listing(items) {
    var seen = {}, out = [];
    (items || []).forEach(function (v) {
      var id = String(v.vodId);
      if (seen[id]) return;
      seen[id] = true;
      out.push({ vod_id: id, vod_name: v.vodName || '', vod_pic: v.coverImg || '',
                 vod_remarks: v.remark == null ? '' : String(v.remark) });
    });
    return out;
  }

  function names(list) {
    return (list || []).map(function (w) { return w.vodWorkerName || ''; }).filter(function (n) { return n; }).join(' ');
  }

  return {
    init: function () { cursors = {}; return ''; },

    homeContent: function () {
      var channels = ((api('/v2/api/home/header', {}).data || {}).channeList || []).filter(function (c) {
        return SKIPPED.indexOf(c.channelName) === -1;
      });
      return host.result.home(channels.map(function (c) {
        return { type_id: String(c.channelId), type_name: c.channelName };
      }), []);
    },

    /** A channel is one curated page of topics; the API takes no page number. */
    categoryContent: function (tid, page) {
      var pg = parseInt(page, 10) || 1;
      var topics = pg > 1 ? [] : ((api('/v2/api/channel/topicListView', { channelId: tid }).data || {}).topicList || []);
      var items = listing([].concat.apply([], topics.map(function (t) { return t.vodList || []; })));
      return host.result.page(items, pg, pg, items.length || 1, items.length);
    },

    detailContent: function (ids) {
      var id = String(ids[0]);
      var d = api('/v2/api/vodInfo/index', { vodId: id }).data || {};
      var froms = [], urls = [];
      (d.playerList || []).forEach(function (p, i) {
        // The original labels a line `<name>共(<count>)集`. The app finds a watched line again by
        // its label, and the count grows with every new episode, so the label is the name alone.
        var name = String(p.playerName || '') || '线路' + (i + 1);
        if (froms.indexOf(name) !== -1) name += ' ' + (i + 1);
        froms.push(name);
        // The original's id is `epId|title|epName` for its danmaku proxy; the title changes as a
        // release is updated (`…-8月31日-HD高清`), so only the episode id is kept.
        urls.push((p.epList || []).map(function (ep) { return ep.epName + '$' + ep.epId; }).join('#'));
      });
      return host.result.detail({
        vod_id: id,
        vod_name: d.vodName || '',
        vod_pic: d.coverImg || '',
        vod_remarks: d.updateRemark == null ? '' : String(d.updateRemark),
        type_name: (d.tagList || []).join(','),
        vod_area: d.areaName || '',
        vod_year: d.year == null ? '' : String(d.year),
        vod_actor: names(d.actorList),
        vod_director: names(d.directorList),
        vod_content: d.intro || '',
        vod_play_from: froms.join('$$$'),
        vod_play_url: urls.join('$$$')
      });
    },

    searchContent: function (key, quick, page) {
      var pg = parseInt(page, 10) || 1, word = String(key || '');
      var fields = { keyword: word, nextCount: '15' };
      if (pg > 1) {
        var cursor = cursors[word + '\n' + pg];
        if (!cursor) return host.result.page([], pg, pg);
        fields.nextVal = cursor;
      }
      var data = api('/v1/api/search/search', fields).data || {};
      if (data.hasNext && data.nextVal) cursors[word + '\n' + (pg + 1)] = String(data.nextVal);
      var items = listing((data.items || []).filter(function (v) { return String(v.flags || '').indexOf('短剧') === -1; }));
      return host.result.page(items, pg, data.hasNext ? pg + 1 : pg, 15);
    },

    /** Every quality the web API will serve, as CatVod's `[name, url, …]` list. */
    playerContent: function (flag, id) {
      var ep = String(id).split('|')[0];
      var qualities = (api('/v2/api/vodInfo/epDetail', { vodEpId: ep }).data || []).filter(function (q) {
        return String(q.canPlay) === 'true';
      });
      var pairs = [];
      qualities.forEach(function (q) {
        var url = (api('/v2/api/vodInfo/playUrl', { epId: ep, vodResolution: q.vodResolution }).data || {}).playUrl;
        if (url) pairs.push(String(q.showName), String(url));
      });
      return host.result.play(pairs.length ? pairs : '', false, HEADERS);
    },

    isVideoFormat: host.isVideoFormat,
    manualVideoCheck: function () { return false; },
    destroy: function () { cursors = {}; }
  };
})();

module.exports = spider;
