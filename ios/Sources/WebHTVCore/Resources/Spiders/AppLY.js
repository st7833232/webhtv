/**
 * AppLY (戏曲多多) spider.
 * Port of com.github.catvod.spider.AppLY from qist spider.jar (IOS-POC-57B-6, design W-60).
 * Source host: https://fly.daoran.tv/API_ROP (JSON POST with a fixed md5 header); plays are HLS whose
 * auth_key is fetched again on every play, so no address is ever stored.
 */
(function () {
  'use strict';

  var API = 'https://fly.daoran.tv/API_ROP/';
  var IMAGE = 'https://ottphoto.daoran.tv/HD/';
  // Upstream's headers (AppLY.java:16–26); md5 is a fixed shared value, not a per-request signature.
  var HEADERS = { 'Content-Type': 'application/json;charset=utf-8', 'User-Agent': 'okhttp/3.9.1',
                  'md5': 'SkvyrWqK9QHTdCT12Rhxunjx+WwMTe9y4KwgeASFDhbYabRSPskR0Q==' };
  // Album and resource codes mix letters and digits (W60-01); anything else never reaches a request or a play list.
  var CODE = /^[A-Za-z0-9]+$/;

  function text(value) { return value === null || value === undefined ? '' : String(value); }

  function pageNumber(pg) {
    var s = text(pg);
    return /^[+-]?\d+$/.test(s) ? Math.max(1, parseInt(s, 10)) : 1;
  }

  // A JSON string, not an object: host.post would form-encode an object (W-45). Field order is the gate's (probe.py).
  function api(path, body) {
    var res = host.post(API + path, JSON.stringify(body), { headers: HEADERS, timeout: 15000 });
    return res.status === 200 && res.json && typeof res.json === 'object' ? res.json : {};
  }

  function rows(reply) {
    var pb = reply.pb && typeof reply.pb === 'object' ? reply.pb : {};
    return { list: Array.isArray(pb.dataList) ? pb.dataList : [], totalPage: pb.totalPage };
  }

  function image(img) { return typeof img === 'string' ? IMAGE + img : ''; }

  var spider = {
    init: function (extend) { return ''; },

    // The classes are whatever the server lists (AppLY.java:82–99); none when that fails, as upstream.
    homeContent: function (filter) {
      var sects = api('page/setinf/get', { leastNum: '0', memberId: 'yszyz', project: 'lyhxcx', userId: 'yszyz' }).sects;
      var classes = [];
      (Array.isArray(sects) ? sects : []).forEach(function (s) {
        if (s && typeof s.code === 'string' && s.code && typeof s.name === 'string') classes.push({ type_id: s.code, type_name: s.name });
      });
      return host.result.home(classes);
    },

    categoryContent: function (tid, pg, filter, extend) {
      var sect = text(tid), page = pageNumber(pg);
      if (!/^[A-Za-z0-9_]+$/.test(sect)) return host.result.page([], page, page, 20, 0);
      var data = rows(api('search/album/list', { cur: String(page), free: '0', item: 'o5', pageSize: '20', sect: [sect] }));
      var list = [];
      data.list.forEach(function (item) {
        if (!item || typeof item !== 'object' || !CODE.test(text(item.code))) return;
        list.push({ vod_id: item.code, vod_name: text(item.name), vod_pic: image(item.img), vod_remarks: text(item.publishTime) });
      });
      var total = data.totalPage;
      var pagecount = typeof total === 'number' && total > 0 && Math.floor(total) === total ? total : (list.length ? page + 1 : page);
      return host.result.page(list, page, pagecount, 20);
    },

    detailContent: function (ids) {
      var id = text(ids && ids[0]);
      if (!CODE.test(id)) return host.result.list([]);
      var reply = api('album/res/list', { albumCode: id, cur: '1', project: 'lyhxcx', pageSize: '2147483647', selectFlag: '0', userId: 'yszyz' });
      var album = reply.album;
      if (!album || typeof album !== 'object') return host.result.list([]);
      var episodes = [];
      rows(reply).list.forEach(function (res) {
        if (!res || typeof res !== 'object' || !CODE.test(text(res.code))) return;
        var name = text(res.name).replace(/[$#]/g, ' ').trim();
        episodes.push((name || '第' + (episodes.length + 1) + '集') + '$' + res.code);
      });
      return host.result.detail({
        vod_id: id,
        vod_name: text(album.name),
        vod_pic: image(album.img),
        type_name: text(album.sect),
        vod_content: text(album.des),
        vod_actor: text(album.artistName),
        vod_director: text(album.vod_director),
        vod_year: text(album.publishTime),
        vod_play_from: '在线播放',
        vod_play_url: episodes.join('#')
      });
    },

    // Upstream plays with no header (AppLY.java:105–116); the address is fetched fresh every time.
    playerContent: function (flag, id, vipFlags) {
      var code = text(id);
      if (!CODE.test(code)) return host.result.play('', false);
      var res = api('play/get/playurl', { item: 'y9', nodeCode: '001000', project: 'lyhxcx', px: '2', resCode: code,
                                          userId: '92315ec6e58a45ba7f47fd143b3d7956' }).playres;
      var url = res && typeof res === 'object' ? text(res.playurl) : '';
      return host.result.play(/^https?:\/\//.test(url) ? url : '', false);
    },

    // Upstream defers to the base Spider, which finds nothing; the configuration marks it unsearchable.
    searchContent: function (key, quick, pg) { return host.result.list([]); }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
