/**
 * Djuu (呦呦 DJ) spider.
 * Port of com.github.catvod.spider.Djuu from qist j-spider.jar (W-42, gate W-24/W-29 `qist-djuu-gate-2026-10-09.md`).
 * Source host: https://m.djuu.com (HTML lists, a JSON audio address from POST /play/music).
 *
 * Differences from upstream, all deliberate (gate §5.2–5.3):
 * - No state between calls. Upstream keeps the last folder page's songs in a static list and builds a playlist
 *   from it in detail, so a search or another folder in between changes what opens. Here a folder song's id
 *   carries its page (`/djlist/115_0_1_1.html#325541`) and detail fetches that page again.
 * - Song ids are the bare data-bs-id (search) or page#id (folder), not `id$$$name$$$pic$$$list`; detail still
 *   accepts the old compound id, as a single song.
 * - 曲库 returns folders: its result is built here with `vod_tag`, because `host.result.page` drops it.
 * - A failed or empty page gives an empty list, not "".
 */
(function () {
  'use strict';

  var HOST = 'https://m.djuu.com';
  var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36';
  var MAX = 2147483647;
  var FOLDER = /^\/djlist\/[^#]+\.html$/;

  function text(v) { return typeof v === 'string' ? v : (v === null || v === undefined ? '' : String(v)); }
  function pageNumber(pg) { var n = parseInt(pg, 10); return n > 1 ? n : 1; }
  function replaceAll(s, from, to) { return s.split(from).join(to); }
  // Djuu.java:54–58: requests send the Referer without a trailing slash.
  function headers() { return { 'User-Agent': UA, 'Referer': HOST }; }
  // Djuu.java:38–52: a site image with the headers it is fetched with (Referer with the slash).
  function image(path) { return HOST + path + '@Headers=' + JSON.stringify({ 'User-Agent': UA, 'Referer': HOST + '/' }); }
  var LOGO = image('/static/mobile/images/play/logo.png');

  function page(url) {
    var res = host.get(url, { headers: headers() });
    return res.status === 200 ? res.body || '' : '';
  }

  // Each song is an item's own data-bs-id: a page carries others (nine on an empty page) that are not songs.
  function songs(html, block) {
    var out = [];
    host.pdfa(html, 'div#' + block + ' div.djuu-list-item').forEach(function (node) {
      var id = text(node.attrs['data-bs-id']);
      if (id) out.push({ id: id, name: host.pdfh(node, 'div.me-2 > span&&Text') });
    });
    return out;
  }

  function detail(id, name, episodes) {
    return host.result.detail({ vod_id: id, vod_name: name, vod_pic: LOGO, vod_play_from: 'DJ呦呦网', vod_play_url: episodes.join('#') });
  }

  var spider = {
    init: function (extend) { return ''; },

    // Djuu.java:197–220: one category, the library.
    homeContent: function (filter) {
      return host.result.home([{ type_id: 'djlist', type_name: '曲库' }]);
    },

    // Djuu.java:61–138. The library's eleven playlists are folders; a folder id is a page path with `{pg}`.
    categoryContent: function (tid, pg, filter, extend) {
      var id = text(tid), n = pageNumber(pg), list = [];
      var empty = { list: [], page: n, pagecount: n, limit: 0, total: 0 };
      if (id === 'djlist') {
        if (n !== 1) return empty;
        var html = page(HOST + '/djlist');
        host.pdfa(html, 'div.my-3 div.mb-2').forEach(function (node) {
          var m = /\('([^']*)'\)/.exec(host.pdfh(node, 'div.fs-5&&onclick'));
          var pic = host.pdfh(node, 'img&&src');
          if (!m) return;
          list.push({ vod_id: replaceAll(m[1], '1_1.html', '1_{pg}.html'), vod_name: host.pdfh(node, 'div.fs-5&&Text'),
                      vod_pic: pic ? image(pic) : '', vod_remarks: '', vod_tag: 'folder' });
        });
      } else {
        if (id.indexOf('/djlist/') !== 0 || id.indexOf('{pg}') === -1) return empty;
        var path = replaceAll(id, '{pg}', String(n));
        list = songs(page(HOST + path), 'djuu-musiclist-djlist').map(function (s) {
          return { vod_id: path + '#' + s.id, vod_name: s.name, vod_pic: LOGO, vod_remarks: '', vod_tag: 'file' };
        });
      }
      // Past the last page the site answers 200 with no song: an empty list, so the App stops (DJUU-D-01).
      if (!list.length) return empty;
      return { list: list, page: n, pagecount: MAX, limit: list.length, total: MAX };
    },

    // Djuu.java:172–196, without its static list: the id says what to open (DJUU-D-03), in this order.
    detailContent: function (ids) {
      var id = text(ids && ids[0]), none = host.result.list([]);
      // ① upstream's `id$$$name$$$pic$$$list`, opened as that one song.
      if (id.indexOf('$$$') !== -1) {
        var parts = id.split('$$$'), song = parts[0], name = parts[1] || song;
        return song ? detail(song, name, [name + '$' + song]) : none;
      }
      // ② a folder song: its page's whole playlist, read again now.
      var cut = id.lastIndexOf('#'), path = id.slice(0, cut), wanted = id.slice(cut + 1);
      if (cut > 0 && FOLDER.test(path) && /^\d+$/.test(wanted)) {
        var html = page(HOST + path);
        if (!html) return none;
        var found = songs(html, 'djuu-musiclist-djlist');
        var episodes = found.map(function (s) { return s.name + '$' + s.id; });
        // The site adds songs at the top; one pushed off this page is put back last, so it can still play (DJUU-D-02).
        if (!found.some(function (s) { return s.id === wanted; })) episodes.push(wanted + '$' + wanted);
        return detail(id, host.pdfh(html, 'div.fs-4&&Text'), episodes);
      }
      // ③ a search song: its id is all there is, and the list showed its name.
      if (/^\d+$/.test(id)) return detail(id, id, [id + '$' + id]);
      return none;
    },

    // Djuu.java:140–170. encodeURIComponent, so a space is %20 (upstream's URLEncoder writes +).
    searchContent: function (key, quick, pg) {
      var wd = text(key).trim(), n = pageNumber(pg);
      if (!wd) return host.result.list([]);
      var html = page(HOST + '/search?musicname=' + encodeURIComponent(wd) + (n > 1 ? '&page=' + n : ''));
      return { list: songs(html, 'djuu-musiclist-search').map(function (s) {
        return { vod_id: s.id, vod_name: s.name, vod_pic: LOGO, vod_remarks: '', vod_tag: 'file' };
      }) };
    },

    // Djuu.java:225–257: POST the id, play data.url with the player headers. A refused reply plays nothing.
    playerContent: function (flag, id, vipFlags) {
      var res = host.post(HOST + '/play/music', 'id=' + encodeURIComponent(text(id)), { headers: headers() });
      var data = res.status === 200 ? host.parseJSON(res.body) : null;
      var url = data && String(data.code) === '0' && data.data && typeof data.data.url === 'string' ? data.data.url : '';
      if (!url) return host.result.play('', false);
      return host.result.play(url, false, { 'User-Agent': UA, 'Referer': HOST + '/' });
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
