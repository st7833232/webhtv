/**
 * QingtingFM (蜻蜓FM) spider: live radio.
 * Port of com.github.catvod.spider.QingtingFM from qist spider.jar (IOS-POC-57B-10, design W-64).
 * Source hosts: https://webbff.qtfm.cn (GraphQL lists) and https://webapi.qtfm.cn (station details);
 * streams are live MP3 at a fixed https://lhttp-hw.qtfm.cn/live/<id>/64k.mp3 with no signature or expiry.
 */
(function () {
  'use strict';

  var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36';
  var HEADERS = { 'User-Agent': UA, 'Referer': 'https://www.qtfm.cn' };
  // Upstream's 44 regions and genres, in its order (QingtingFM.java:67–75).
  var CLASSES = ('217 广东|99 浙江|3 北京|5 天津|7 河北|83 上海|19 山西|31 内蒙古|44 辽宁|59 吉林|69 黑龙江|85 江苏|111 安徽|'
    + '129 福建|139 江西|151 山东|169 河南|187 湖北|202 湖南|239 广西|254 海南|257 重庆|259 四川|281 贵州|291 云南|316 陕西|'
    + '327 甘肃|351 宁夏|357 新疆|308 西藏|342 青海|433 资讯|442 音乐|429 交通|439 经济|432 文艺|441 都市|430 体育|431 双语|'
    + '440 综合|438 生活|435 旅游|436 曲艺|434 方言').split('|');
  var DIGITS = /^\d+$/;

  function text(value) { return value === null || value === undefined ? '' : String(value); }

  function pageNumber(pg) {
    var s = text(pg);
    return /^[+-]?\d+$/.test(s) ? Math.max(1, parseInt(s, 10)) : 1;
  }

  function json(res) { return res.status === 200 && res.json && typeof res.json === 'object' ? res.json : {}; }

  // Upstream only checks for "https" and so turns http://… into https:http://…; only a scheme-relative URL needs one.
  function image(url) { var s = text(url); return s.indexOf('//') === 0 ? 'https:' + s : s; }

  var spider = {
    init: function (extend) { return ''; },

    homeContent: function (filter) {
      return host.result.home(CLASSES.map(function (c) {
        var parts = c.split(' ');
        return { type_id: parts[0], type_name: parts[1] };
      }));
    },

    // Upstream's GraphQL text, byte for byte (QingtingFM.java:31); cid and page are checked to be whole numbers
    // first, so a crafted tid cannot rewrite the query.
    categoryContent: function (tid, pg, filter, extend) {
      var cid = text(extend && extend.cateId ? extend.cateId : tid), page = pageNumber(pg);
      if (!DIGITS.test(cid)) return host.result.page([], page, page, 12, 0);
      var body = '{"query":"{\\n    radioPage(cid:' + cid + ', page:' + page + '){\\n      contents\\n    }\\n  }"}';
      var res = host.post('https://webbff.qtfm.cn/www', body, {
        headers: Object.assign({ 'Content-Type': 'application/json' }, HEADERS), timeout: 15000
      });
      var d = json(res).data, items = d && d.radioPage && d.radioPage.contents && d.radioPage.contents.items;
      var list = [];
      (Array.isArray(items) ? items : []).forEach(function (item) {
        if (!item || typeof item !== 'object' || !DIGITS.test(text(item.id))) return;
        list.push({ vod_id: text(item.id), vod_name: text(item.title), vod_pic: image(item.imgUrl), vod_remarks: text(item.desc) });
      });
      // Upstream's paging: a full page of 12 means there may be another (:45).
      return host.result.page(list, page, list.length < 12 ? page : page + 1, 12, 0);
    },

    detailContent: function (ids) {
      var id = text(ids && ids[0]);
      if (!DIGITS.test(id)) return host.result.list([]);
      var album = json(host.get('https://webapi.qtfm.cn/api/pc/radio/' + id, { headers: HEADERS, timeout: 15000 })).album;
      // album.id comes back as a number: make it text before checking it (W-64 review).
      if (!album || typeof album !== 'object' || !DIGITS.test(text(album.id))) return host.result.list([]);
      return host.result.detail({
        vod_id: id,
        vod_name: text(album.title),
        vod_pic: text(album.cover),
        vod_content: text(album.description),
        vod_play_from: '蜻蜓FM',
        vod_play_url: text(album.title).replace(/[$#]/g, ' ') + '$' + text(album.id)
      });
    },

    // A live stream: the station id is the whole address (QingtingFM.java:77–81).
    playerContent: function (flag, id, vipFlags) {
      var station = text(id);
      if (!DIGITS.test(station)) return host.result.play('', false);
      return host.result.play('https://lhttp-hw.qtfm.cn/live/' + station + '/64k.mp3', false, HEADERS);
    },

    // The configuration marks the site unsearchable; upstream's searchResultsPage query is not ported.
    searchContent: function (key, quick, pg) { return host.result.list([]); }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
