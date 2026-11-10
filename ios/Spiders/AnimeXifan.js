/**
 * AnimeXifan (稀饭动漫) spider.
 * Port of com.github.catvod.spider.AnimeXifan from spider.jar (W-281; evaluation W-273 `artifacts/w273/spider-jar-batch2-eval.md`).
 * Source hosts: https://next.xifanacg.com (Next.js pages: lists from the schema.org ItemList, detail from the page's
 * line/episode JSON) and https://api.xifanacg.com (Supabase: search RPC, the issue-web-playback function for play).
 *
 * The search RPC needs Supabase's `apikey` header. The key below is the site's own **publishable** key, copied
 * unchanged from the upstream jar (recha c953e7c spider.jar, AnimeXifan.searchContent); publishable keys are the
 * ones Supabase meant to ship in public clients and only reach what the site's row-level security already exposes to
 * anonymous visitors. Nothing else uses it: lists, detail and play need no key. If the site rotates it, search
 * answers empty until a new pack ships the new key (docs/W-281-animexifan-port.md §5). The user approved embedding
 * this key on 2026-11-10 (W-273 decision); no other key is ever used.
 *
 * Differences from upstream, all deliberate (docs/W-281-animexifan-port.md):
 * - vod_id is the numeric anime id, not the page URL, so detail only ever fetches this site's /anime/<id>.
 * - An episode id is `<episode id>@<source id>`, the source id read from the line itself; upstream maps the line
 *   code through a fixed table (AL 1, CS 2, xfy2 5, anything else 4), which the page's ids agree with today.
 * - A category page reports one more page while it is full (24), so paging continues; upstream reports none.
 * - No danmaku (upstream's addDanmaku): the app has no danmaku layer.
 */
(function () {
  'use strict';

  var SITE = 'https://next.xifanacg.com';
  var API = 'https://api.xifanacg.com';
  var APIKEY = 'sb_publishable_OBIVAWACIX6lPXrO98_z24_HcsmalkA';   // upstream jar's publishable key (see above)
  var HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    'Referer': SITE + '/'
  };
  var CLASSES = [['tv', 'TV动画'], ['movie', '剧场版'], ['ova', 'OVA'], ['web', 'Web动画'], ['other', '其他']];
  var PAGE_SIZE = 24;

  function text(v) { return v === null || v === undefined ? '' : String(v); }
  function pageNumber(pg) { var n = parseInt(pg, 10); return n > 1 ? n : 1; }
  function jsonHeaders(extra) { return Object.assign({ 'Content-Type': 'application/json' }, HEADERS, extra); }
  function get(url) { var res = host.get(url, { headers: HEADERS, json: false }); return res && res.status === 200 ? text(res.body) : ''; }
  function postJSON(url, body, extra) {
    var res = host.post(url, JSON.stringify(body), { headers: jsonHeaders(extra) });
    return res && res.status === 200 ? res.json : null;
  }
  // `$` and `#` split CatVod play lists; never let a title carry them.
  function clean(s) { return text(s).replace(/[$#]/g, ' ').replace(/\s+/g, ' ').trim(); }
  function idOf(url) { var m = /\/anime\/(\d+)/.exec(text(url)); return m ? m[1] : ''; }

  /** Upstream's scan: from the `{` before "ItemList" to its balanced `}`, skipping braces inside strings. */
  function itemList(page) {
    var at = page.indexOf('ItemList'), start = at < 0 ? -1 : page.lastIndexOf('{', at);
    if (start < 0) return [];
    var depth = 0, inString = false, escaped = false, end = -1;
    for (var i = start; i < page.length; i++) {
      var c = page.charAt(i);
      if (escaped) escaped = false;
      else if (c === '\\') escaped = true;
      else if (c === '"') inString = !inString;
      else if (!inString && c === '{') depth++;
      else if (!inString && c === '}' && --depth === 0) { end = i + 1; break; }
    }
    if (end < 0) return [];
    var json = host.parseJSON(page.substring(start, end));
    return (json && json.itemListElement) || [];
  }

  function cards(page, withDate) {
    return itemList(page).map(function (entry) {
      var item = (entry && entry.item) || {};
      return { vod_id: idOf(item.url), vod_name: text(item.name), vod_pic: text(item.image),
               vod_remarks: withDate ? text(item.datePublished) : '' };
    }).filter(function (v) { return v.vod_id && v.vod_name; });
  }

  var spider = {
    init: function () { return ''; },

    homeContent: function (filter) {
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }));
    },

    homeVideoContent: function () {
      // The home page carries its list inside the RSC payload, quotes escaped.
      return host.result.list(cards(get(SITE).replace(/\\"/g, '"'), false));
    },

    categoryContent: function (tid, pg, filter, extend) {
      var n = pageNumber(pg), id = text(tid);
      if (!CLASSES.some(function (c) { return c[0] === id; })) return host.result.page([], n, n, 0, 0);
      var list = cards(get(SITE + '/browse?type=2&format=' + id + '&sort=created_at&page=' + n), true);
      return host.result.page(list, n, list.length >= PAGE_SIZE ? n + 1 : n, PAGE_SIZE);
    },

    detailContent: function (ids) {
      var raw = text(ids && ids[0]), id = /^\d+$/.test(raw) ? raw : idOf(raw);
      if (!id) return host.result.list([]);
      var page = get(SITE + '/anime/' + id);
      if (!page) return host.result.list([]);
      var flat = page.replace(/\\"/g, '"');
      var poster = '';
      host.pdfa(page, 'img').some(function (img) {
        var src = host.pdfh(img, 'img&&src');
        if (src.indexOf('img2.xfmanga.top') >= 0) { poster = src; return true; }
        return false;
      });
      var from = [], urls = [];
      var lines = flat.match(/\{"id":\d+,"code":"[^"]*","name":"[^"]*","episodes":\[.*?\]\}/g) || [];
      lines.forEach(function (line) {
        var source = /^\{"id":(\d+)/.exec(line)[1];
        var name = clean(/"name":"([^"]*)"/.exec(line)[1]);
        var eps = [], re = /\{"id":(\d+),"kind":"[^"]*","title":"([^"]*)",[^}]*?"episode_number":(\d+)/g, m;
        while ((m = re.exec(line)) !== null) eps.push(clean(m[3] + ' ' + m[2]) + '$' + m[1] + '@' + source);
        if (eps.length) { from.push(name || ('线路' + (from.length + 1))); urls.push(eps.join('#')); }
      });
      return host.result.detail({
        vod_id: id,
        // host's Text keeps entities (`&amp;`) where Jsoup decodes them; stripTags decodes the common ones.
        vod_name: host.stripTags(host.pdfh(page, 'h1&&Text')),
        vod_pic: poster,
        vod_content: host.stripTags(host.pdfh(page, 'p.whitespace-pre-line&&Text')),
        vod_play_from: from.join('$$$'),
        vod_play_url: urls.join('$$$')
      });
    },

    searchContent: function (key, quick, pg) {
      var wd = text(key).trim();
      if (!wd || pageNumber(pg) > 1) return host.result.list([]);
      var rows = postJSON(API + '/rest/v1/rpc/search_animes', { search_term: wd, page_number: 1, items_per_page: PAGE_SIZE,
                          sort_by: 'created_at', sort_order: 'desc' }, { 'apikey': APIKEY });
      return host.result.list((Array.isArray(rows) ? rows : []).map(function (r) {
        var id = parseInt(r && r.id, 10);
        return { vod_id: id > 0 ? String(id) : '', vod_name: text(r && r.title), vod_pic: text(r && r.cover_url),
                 vod_remarks: [text(r && r.release_year), text(r && r.bangumi_score)].filter(Boolean).join(' · ') };
      }).filter(function (v) { return v.vod_id && v.vod_name; }));
    },

    playerContent: function (flag, id, vipFlags) {
      var m = /^(\d+)@(\d+)$/.exec(text(id));
      if (!m) return host.result.play('', false);
      var json = postJSON(API + '/functions/v1/issue-web-playback',
                          { action: 'fallback', episode_id: parseInt(m[1], 10), source_id: parseInt(m[2], 10) });
      var url = text(json && json.url);
      return host.result.play(/^https?:\/\//.test(url) ? url : '', false);
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
