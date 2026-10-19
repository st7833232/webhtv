/**
 * TingShijie (世界听书) spider: audiobooks.
 * Port of com.github.catvod.spider.TingShijie from qist spider.jar (IOS-POC-57B-18, gate W-148).
 * Source host: https://app.365ting.com/listen/Apitzg2025/ (JSON with `status`); audio is a direct m4a on
 * audio.tingshijie.com, signed by `auth_key`, that Cloudflare serves only to an okhttp User-Agent.
 */
(function () {
  'use strict';

  // Upstream's init first asks http://101.43.48.231:8090/config/tingchina2025.txt for a root and falls back to this
  // one (TingShijie.java:131–144). That host timed out on both gate tries (#1, #26), and a failed init request would be
  // blamed for every later empty listing (JavaScriptSpiderRuntime's initFailure), so this port uses the fallback only.
  var ROOT = 'https://app.365ting.com/listen/Apitzg2025/';
  var API_HEADERS = { 'User-Agent': 'TingShiJie/1.8.8 (m.i275.com)' };  // TingShijie.java:21–23
  // The audio CDN answers 403 to every User-Agent tried but okhttp's (gate #8–#16); upstream's empty header
  // works on Android only because its player is OkHttp.
  var AUDIO_HEADERS = { 'User-Agent': 'okhttp/4.12.0' };
  var SALT = 'J9gSpfUlzYxE8Hn5IXiGaD2jVMrwAm0K';  // TingShijie.java:162
  var CLASSES = [['6', '玄幻奇幻'], ['7', '都市言情'], ['8', '宫斗女频'], ['9', '官场商战'], ['10', '武侠仙侠'], ['11', '刑侦推理'],
                 ['12', '探险科幻'], ['13', '重生穿越'], ['14', '恐怖惊悚'], ['15', '文学历史'], ['49', '两性情感']];
  var PAGE_SIZE = 120;
  // A web address with no "$" or "#", which would split the play list into extra episodes.
  var WEB = /^https?:\/\/[^$#\s]*$/;
  // Guards against an absurd `count`: 20 pages of 1000 is 20,000 chapters.
  var MAX_PAGES = 20;

  function text(value) { return value === null || value === undefined ? '' : String(value); }

  function pageNumber(pg) {
    var s = text(pg);
    return /^[+-]?\d+$/.test(s) ? Math.max(1, parseInt(s, 10)) : 1;
  }

  // The JSON of a 200 reply whose `status` is 0, else null. The API labels it text/html (gate #2).
  function ok(url) {
    var res = host.get(url, { headers: API_HEADERS, timeout: 15000 });
    var json = res.status === 200 ? res.json : null;
    return json && json.status === 0 ? json : null;
  }

  function books(list) {
    var out = [];
    (Array.isArray(list) ? list : []).forEach(function (item) {
      if (!item || typeof item !== 'object' || !/^\d+$/.test(text(item.id))) return;
      out.push({ vod_id: text(item.id), vod_name: text(item.bookTitle), vod_pic: text(item.bookImage),
                 vod_remarks: text(item.bookAnchor) });
    });
    return out;
  }

  var spider = {
    init: function (extend) { return ''; },

    homeContent: function (filter) {
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }));
    },

    // Upstream claims 100 pages whatever the class holds; a page that is not full is the last.
    categoryContent: function (tid, pg, filter, extend) {
      var id = text(tid), page = pageNumber(pg);
      if (!/^\d+$/.test(id)) return host.result.page([], page, page, PAGE_SIZE, 0);
      var json = ok(ROOT + 'appHomeByCategory?categoryId=' + id + '&page=' + page + '&size=' + PAGE_SIZE);
      var list = books(json && json.data);
      var last = list.length >= PAGE_SIZE ? page + 1 : page;
      return host.result.page(list, page, last, PAGE_SIZE, (page - 1) * PAGE_SIZE + list.length);
    },

    detailContent: function (ids) {
      var id = text(ids && ids[0]);
      if (!/^\d+$/.test(id)) return host.result.list([]);
      var json = ok(ROOT + 'book?bookId=' + id);
      var book = json && json.data && json.data.bookData;
      if (!book || typeof book !== 'object') return host.result.list([]);
      // `count` is a string on the wire (gate #3); chapters come 1000 a page (TingShijie.java:74–76).
      var count = parseInt(text(book.count), 10) || 0;
      var pages = Math.min(Math.ceil(count / 1000), MAX_PAGES), episodes = [];
      for (var page = 1; page <= pages; page++) {
        var chapters = ok(ROOT + 'chapter?size=1000&page=' + page + '&sort=asc&bookId=' + id);
        var list = chapters && chapters.data && Array.isArray(chapters.data.list) ? chapters.data.list : [];
        list.forEach(function (chapter) {
          if (!chapter || typeof chapter !== 'object' || !/^\d+$/.test(text(chapter.chapterId))) return;
          // The title says 「第N集」; upstream named episodes by position, which drifts once bonus chapters appear.
          var title = text(chapter.title).replace(/[$#]/g, ' ').trim();
          episodes.push((title || text(chapter.position)) + '$' + id + '|' + chapter.chapterId);
        });
      }
      return host.result.detail({
        vod_id: id,
        vod_name: text(book.bookTitle),
        vod_pic: text(book.bookImage),
        vod_content: text(book.bookDesc),
        vod_play_from: '世界听书',
        vod_play_url: episodes.join('#')
      });
    },

    // A chapter the site cannot resolve (`status 1 分集地址解析失败`, gate #7) gives no address, as upstream does; the
    // app then says the episode has nothing to play. The signed address expires, so every play asks again.
    playerContent: function (flag, id, vipFlags) {
      var m = /^(\d+)\|(\d+)$/.exec(text(id));
      if (!m) return host.result.play('', false);
      var ts = String(host.now());
      var sign = host.md5(host.md5(ts + SALT) + SALT);
      var json = ok(ROOT + 'AppGetChapterUrl2023?timeStamp=' + ts + '&uid=&chapterId=' + m[2] + '&addItParapet=' + sign
                    + '&bookId=' + m[1]);
      var src = json ? text(json.src) : '';
      return WEB.test(src) ? host.result.play(src, false, AUDIO_HEADERS) : host.result.play('', false);
    },

    // One page, as upstream (TingShijie.java:187–218); it left the keyword to OkHttp to encode.
    searchContent: function (key, quick, pg) {
      var wd = text(key).trim();
      if (!wd || pageNumber(pg) > 1) return host.result.list([]);
      var json = ok(ROOT + 'appSearch?client=babala-android&search=' + encodeURIComponent(wd) + '&app_token=abcSEARCH-2025');
      return host.result.list(books(json && json.data && json.data.bookData));
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
