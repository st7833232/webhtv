/**
 * BeiLeHu (贝乐虎) spider.
 * Port of com.github.catvod.spider.BeiLeHu from qist spider.jar (IOS-POC-57B-4).
 * Source host: https://vd.ubestkid.com (JSON POST); media on res1/resvd.ubestkid.com, plain mp4 with no expiry.
 */
(function () {
  'use strict';

  var API = 'https://vd.ubestkid.com/api/v1/bv/video';
  var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36';
  var CLASSES = [['56', '儿歌'], ['63', '故事'], ['62', '少儿'], ['61', '古诗'], ['64', '认知'], ['65', '习惯']];
  // A web address with no "$" or "#", which would split the play list into extra episodes.
  var WEB = /^https?:\/\/[^$#]*$/;

  function text(value) { return value === null || value === undefined ? '' : String(value); }

  function pageNumber(pg) {
    var s = text(pg);
    return /^[+-]?\d+$/.test(s) ? Math.max(1, parseInt(s, 10)) : 1;
  }

  // The upstream body, field for field and in order (BeiLeHu.java:32–39). A string: host.post form-encodes an object.
  function items(subcateId, page) {
    var body = JSON.stringify({ age: 1, appver: '6.1.9', egvip_status: 0, svip_status: 0, vps: 60, subcateId: subcateId, p: page });
    var res = host.post(API, body, { headers: { 'Content-Type': 'application/json', 'User-Agent': UA }, timeout: 15000 });
    var json = res.status === 200 ? host.parseJSON(res.body) : null;
    var result = json && json.errorCode === 0 && json.result && typeof json.result === 'object' ? json.result : null;
    return result && Array.isArray(result.items) ? result.items : [];
  }

  // endInterval / 10 seconds as m:ss, else the brand (BeiLeHu.java:67–89).
  function remarks(item) {
    var n = parseInt(text(item.endInterval), 10);
    if (n > 0) {
      var seconds = Math.floor(n / 10), rest = seconds % 60;
      return Math.floor(seconds / 60) + ':' + (rest < 10 ? '0' : '') + rest;
    }
    return typeof item.brand === 'string' ? item.brand : '';
  }

  // vod_id is upstream's url@@title@@image: the url never expires, so history and favourites can keep it.
  function vods(list) {
    var out = [];
    list.forEach(function (item) {
      if (!item || typeof item !== 'object' || typeof item.url !== 'string' || !WEB.test(item.url)) return;
      var title = typeof item.title === 'string' && item.title ? item.title : '贝乐虎';
      var image = typeof item.image === 'string' ? item.image : '';
      if ([item.url, title, image].some(function (s) { return s.indexOf('@@') >= 0; })) return;
      out.push({ vod_id: item.url + '@@' + title + '@@' + image, vod_name: title, vod_pic: image, vod_remarks: remarks(item) });
    });
    return out;
  }

  var spider = {
    init: function (extend) { return ''; },

    homeContent: function (filter) {
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }));
    },

    // Upstream asks for subcateId 1, which answers -100002 with or without a UA; 儿歌's first page stands in.
    homeVideoContent: function () {
      return host.result.list(vods(items(56, 1).slice(0, 20)));
    },

    categoryContent: function (tid, pg, filter, extend) {
      var id = text(tid), page = pageNumber(pg);
      if (!/^\d+$/.test(id)) return host.result.page([], page, page, 0, 0);
      var list = vods(items(parseInt(id, 10), page));
      return host.result.page(list, page, list.length ? page + 1 : page, list.length, 9999);
    },

    detailContent: function (ids) {
      var id = text(ids && ids[0]), parts = id.split('@@');
      if (!WEB.test(parts[0])) return host.result.list([]);
      return host.result.detail({
        vod_id: id,
        vod_name: parts[1] || '贝乐虎',
        vod_pic: parts[2] || '',
        type_name: '少儿',
        vod_play_from: '贝乐虎',
        vod_play_url: '播放$' + parts[0]
      });
    },

    // Upstream's two steps (BeiLeHu.java:128–136): before any "播放", then after the first "$".
    playerContent: function (flag, id, vipFlags) {
      var url = text(id);
      if (url.indexOf('播放') >= 0) url = url.split('播放')[0];
      if (url.indexOf('$') >= 0) url = url.substring(url.indexOf('$') + 1);
      return host.result.play(WEB.test(url) ? url : '', false, { 'User-Agent': UA });
    },

    searchContent: function (key, quick, pg) {
      return host.result.list([]);
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
