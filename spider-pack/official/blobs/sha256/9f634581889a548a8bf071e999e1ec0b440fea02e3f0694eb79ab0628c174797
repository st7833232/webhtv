/**
 * TingBokan (博看听书) spider.
 * Port of com.github.catvod.spider.TingBokan from qist spider.jar (IOS-POC-57B-9, design W-63).
 * Source hosts: https://api.bookan.com.cn (lists, units) and https://es.bookan.com.cn (search); audio is
 * plain-HTTP m4a on audio.bookan.com.cn with no signature or expiry.
 */
(function () {
  'use strict';

  var API = 'https://api.bookan.com.cn/voice';
  var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36';
  var HEADERS = { 'User-Agent': UA };
  // The first 11 of upstream's 18 classes, as its homeContent lists them (TingBokan.java:17–18, :84–90).
  var CLASSES = [['1303', '故事会'], ['1304', '儿童文学'], ['1305', '少年读物'], ['1306', '文艺少年'], ['1307', '青春励志'],
                 ['1308', '个人提升'], ['1309', '育儿心经'], ['1310', '心理哲学'], ['1311', '家庭健康'], ['1312', '历史小说'],
                 ['1313', '科技科普']];
  // A web address with no "$" or "#", which would split the play list into extra episodes.
  var WEB = /^https?:\/\/[^$#]*$/;
  // Guards against a server that reports an absurd page count: 50 pages of 200 is 10,000 episodes.
  var MAX_PAGES = 50;

  function text(value) { return value === null || value === undefined ? '' : String(value); }

  function pageNumber(pg) {
    var s = text(pg);
    return /^[+-]?\d+$/.test(s) ? Math.max(1, parseInt(s, 10)) : 1;
  }

  function positive(value) { return typeof value === 'number' && value > 0 && Math.floor(value) === value; }

  // `data` of a 200 JSON reply whose code is 0, else null (TingBokan.java:29, :59).
  function data(url) {
    var res = host.get(url, { headers: HEADERS, timeout: 15000 });
    var json = res.status === 200 ? res.json : null;
    return json && json.code === 0 && json.data && typeof json.data === 'object' ? json.data : null;
  }

  // vod_id is upstream's <id>@<name>; the detail splits it at the first "@" only, so a name may contain one.
  function books(list, pressWhenNoAuthor) {
    var out = [];
    (Array.isArray(list) ? list : []).forEach(function (item) {
      if (!item || typeof item !== 'object' || !positive(item.id) || typeof item.name !== 'string') return;
      var extra = item.extra && typeof item.extra === 'object' ? item.extra : null;
      var author = extra ? text(extra.author) : '';
      if (!author && extra && pressWhenNoAuthor) author = text(item.press);
      out.push({ vod_id: item.id + '@' + item.name, vod_name: item.name, vod_pic: text(item.cover), vod_remarks: author });
    });
    return out;
  }

  var spider = {
    init: function (extend) { return ''; },

    homeContent: function (filter) {
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }));
    },

    categoryContent: function (tid, pg, filter, extend) {
      var id = text(tid), page = pageNumber(pg);
      if (!/^\d+$/.test(id)) return host.result.page([], page, page, 24, 0);
      var d = data(API + '/book/list?instance_id=25304&page=' + page + '&category_id=' + id + '&num=24');
      var last = d && positive(d.last_page) ? d.last_page : page;
      return host.result.page(books(d && d.list, false), page, last, 24, last * 24);
    },

    detailContent: function (ids) {
      var id = text(ids && ids[0]), at = id.indexOf('@');
      var album = at > 0 ? id.substring(0, at) : '';
      if (!/^\d+$/.test(album)) return host.result.list([]);
      var episodes = [], remarks = '', last = 1;
      for (var page = 1; page <= Math.min(last, MAX_PAGES); page++) {
        var d = data(API + '/album/units?album_id=' + album + '&page=' + page + '&num=200&order=1');
        if (!d) break;
        if (positive(d.last_page)) last = d.last_page;
        var units = Array.isArray(d.list) ? d.list : [];
        if (page === 1 && units.length && units[0] && typeof units[0] === 'object') remarks = '更新于 ' + text(units[0].updated_at);
        units.forEach(function (unit) {
          if (!unit || typeof unit !== 'object' || !WEB.test(text(unit.file))) return;
          var title = text(unit.title).replace(/[$#]/g, ' ').trim();
          episodes.push((title || String(episodes.length + 1)) + '$' + unit.file);
        });
      }
      return host.result.detail({
        vod_id: id,
        vod_name: id.substring(at + 1),
        vod_pic: '',
        vod_remarks: remarks,
        vod_play_from: '博看听书',
        vod_play_url: episodes.join('#')
      });
    },

    playerContent: function (flag, id, vipFlags) {
      var url = text(id);
      return WEB.test(url) ? host.result.play(url, false, { 'User-Agent': UA }) : host.result.play('', false);
    },

    searchContent: function (key, quick, pg) {
      var wd = text(key).trim();
      if (!wd) return host.result.list([]);
      var d = data('https://es.bookan.com.cn/api/v3/voice/book?instanceId=25304&keyword=' + encodeURIComponent(wd)
                   + '&pageNum=1&limitNum=20');
      return host.result.list(books(d && d.list, true));
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
