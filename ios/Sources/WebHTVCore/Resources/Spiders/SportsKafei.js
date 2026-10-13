/**
 * SportsKafei (咖啡体育) spider: live football and basketball.
 * Port of com.github.catvod.spider.SportsKafei from qist spider.jar (IOS-POC-57B-11, design W-59).
 * Source host: https://kafeizhibo.cc (JSON GET); signals are live HLS (or rtmp, which MPV takes over).
 * A vod_id is a streamer's room, not a match: reopening it shows whatever that room carries now.
 */
(function () {
  'use strict';

  var API = 'https://kafeizhibo.cc/api/v1';
  // Upstream's truncated agent, as is (SportsKafei.java:20–22).
  var HEADERS = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36', 'Accept': 'application/json' };
  var CLASSES = [['hot', '热门'], ['1', '足球'], ['2', '篮球']];

  function text(value) { return typeof value === 'string' ? value : ''; }

  function pageNumber(pg) {
    var s = value(pg);
    return /^[+-]?\d+$/.test(s) ? Math.max(1, parseInt(s, 10)) : 1;
  }
  function value(v) { return v === null || v === undefined ? '' : String(v); }

  // A string or number id (upstream's getString reads both); '' otherwise.
  function roomId(v) { return typeof v === 'string' || typeof v === 'number' ? String(v) : ''; }

  // http(s) or rtmp(s) without the CatVod separators (W59-01: rtmp stays, AVPlayer failing falls back to MPV).
  function playable(url) { return /^(https?|rtmps?):\/\/[^$#]*$/.test(value(url)); }

  // Only an HTTP 200 whose JSON says code 200 counts (SportsKafei.java:24, :63).
  function api(path) {
    var res = host.get(API + path, { headers: HEADERS, timeout: 15000 });
    return res.status === 200 && res.json && res.json.code === 200 ? res.json.data : null;
  }

  var spider = {
    init: function (extend) { return ''; },

    homeContent: function (filter) {
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }));
    },

    // One card per room: a streamer carries several matches, and the App keys cards by vod_id, so a
    // repeated room keeps its live match if it has one, else its first (Manager #1412).
    categoryContent: function (tid, pg, filter, extend) {
      var id = value(tid), page = pageNumber(pg);
      if (id !== 'hot' && !/^\d+$/.test(id)) return host.result.page([], page, page, 30, 0);
      var data = api('/schedule?type=' + id + '&page=' + page + '&size=30');
      var chosen = {};
      (Array.isArray(data) ? data : []).forEach(function (item, i) {
        var room = item && typeof item === 'object' && item.archor && typeof item.archor === 'object'
          ? roomId(item.archor.room_id) : '';
        if (!room) return;
        var live = item.status === 'live', kept = chosen[room];
        if (kept && (kept.live || !live)) return;
        chosen[room] = { at: i, live: live, vod: {
          vod_id: room,
          vod_name: text(item.home_team) + ' VS ' + text(item.away_team),
          vod_pic: text(item.home_team_logo),
          vod_remarks: text(item.league_name) + (live ? ' 直播中' : '')
        } };
      });
      var list = Object.keys(chosen).map(function (k) { return chosen[k]; })
        .sort(function (a, b) { return a.at - b.at; }).map(function (c) { return c.vod; });
      // Upstream's pagecount 100 / total 6000 are made up (:47–49); stop when a page brings nothing.
      return host.result.page(list, page, list.length ? page + 1 : page, 30, list.length);
    },

    detailContent: function (ids) {
      var id = value(ids && ids[0]);
      if (!/^\d+$/.test(id)) return host.result.list([]);
      var d = api('/room/' + id), info = d && typeof d === 'object' ? d.room_info : null;
      if (!info || typeof info !== 'object') return host.result.list([]);
      // A missing signals list is no lines rather than no detail (upstream throws there, :68).
      var episodes = [];
      (Array.isArray(d.signals) ? d.signals : []).forEach(function (s, i) {
        if (!s || typeof s !== 'object' || !playable(s.stream_url)) return;
        episodes.push((text(s.name).replace(/[$#]/g, ' ').trim() || '线路' + (i + 1)) + '$' + s.stream_url);
      });
      return host.result.detail({
        vod_id: roomId(info.room_id) || id,
        vod_name: text(info.title),
        vod_director: text(info.league),
        vod_actor: text(info.home_team) + ' VS ' + text(info.away_team),
        vod_play_from: '咖啡体育',
        vod_play_url: episodes.join('#')
      });
    },

    searchContent: function (key, quick, pg) { return host.result.list([]); },

    // Upstream adds an empty header object (:133); none is the same to the App.
    playerContent: function (flag, id, vipFlags) {
      return host.result.play(playable(id) ? value(id) : '', false);
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
