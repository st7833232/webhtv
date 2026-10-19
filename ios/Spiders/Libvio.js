/**
 * Libvio (LIBVIO) spider: an HTML video site behind a CDN SHA-256 proof-of-work.
 * Port of com.github.catvod.spider.Libvio from 摸魚's jar (IOS-POC-57B-19, gates W-162/W-165
 * `spider-gate-batch3-2026-10-19.md` §4). Lists and play pages are the old `stui` layout, the detail page the new `vod-*`.
 *
 * Differences from upstream, all deliberate (docs/IOS-POC-57B-19-libvio.md):
 * - Only the site's own online lines are listed; net-disk lines (夸克, 迅雷, …) are never listed or played, since
 *   upstream hands them to its Cloud base class, which this app does not have.
 * - When the detail page has no online panel, the first play page's tabs give the lines (W-165 N-1 fallback).
 * - `encrypt` 3, which upstream leaves to its default branch, is used as is when it is an http(s) address.
 * - No funcdn captcha fallback and no cookie typed in by hand; a challenge that survives one answer fails the call.
 */
(function () {
  'use strict';

  // shortcut: release pages (fabu, libvio.app, github.io) are skipped, not read for their xorDecode('lv2025') backup
  // list (W-162 #2), so a failed init request is never blamed for later listings; upgrade when all three fixed
  // mirrors stop answering.
  var MIRRORS = ['https://libvio.host', 'https://libviobd.com', 'https://www.libvio.to'];
  var RELEASE = /fabu|libvio\.app|github\.io/i;  // upstream E()
  var UA = 'Mozilla/5.0 (Linux; Android 11; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36';
  // Without a browser Accept the CDN answers a plain 403 (`x-cdn-challenge: required`, W-162 #3).
  var HEADERS = { 'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                  'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8' };
  // Upstream's net-disk line names ($host$62d5…), plus 百度 and 网盘.
  var NETDISK_NAME = /夸克|UC|优视|阿里|天翼|天意|移动|迅雷|百度|网盘|pan123|123原画|123无限|115/;
  var NETDISK_FROM = /^(kuake|quark|xunlei|thunder|uc|ali|aliyun|alipan|baidu|tianyi|115|123pan)$/i;
  var NETDISK_HOST = /^https?:\/\/([^/]+\.)?(quark\.cn|uc\.cn|aliyundrive\.com|alipan\.com|xunlei\.com|baidu\.com|189\.cn|139\.com|115\.com|115cdn\.com|123pan\.com|123pan\.cn|123684\.com|123865\.com|123912\.com|123592\.com)(\/|$)/i;
  // A web address with no "$" or "#", which would split the play list into extra episodes.
  var WEB = /^https?:\/\/[^$#\s]*$/;
  var TOKEN = /^[\w.~-]+$/;
  var POW_SECONDS = 8;  // iPhone estimate: about 1% of challenges run out (gate「PoW 在 iOS 上的成本」)

  var bases = MIRRORS.slice(), current = 0;

  function text(v) { return v === null || v === undefined ? '' : String(v); }
  function pageNumber(pg) { var n = parseInt(pg, 10); return n > 1 ? n : 1; }

  function request(url, cookie) {
    var headers = Object.assign({}, HEADERS);
    if (cookie) headers.Cookie = cookie;
    return host.req(url, { headers: headers, redirect: false, timeout: 15000 });
  }
  // Checked on every reply: the jar ignores Max-Age, so an expired __cdn_verified is still sent (gate N-2).
  function challenged(res) { return res.status === 403 && /js-pow/i.test(text(res.headers && res.headers['x-cdn-challenge'])); }

  // The challenge page's own rule: the first i whose sha256(SIG + i) in hex starts with DIFF, tried at most EXPECT * 32
  // times and for POW_SECONDS. The answer is the cookie `POW=TS_MODE_nonce_SIG`, or '' when there is none.
  function solve(page) {
    function v(name) { return host.match(page, '\\b' + name + '\\s*=\\s*([\'"])([^\'"]*)\\1', 2); }
    var ts = v('TS'), sig = v('SIG'), diff = v('DIFF').toLowerCase(), mode = v('MODE') || 'auto', pow = v('POW') || '__cdn_pow';
    var expect = parseInt(host.match(page, '\\bEXPECT\\s*=\\s*(\\d+)'), 10) || 65536;
    if (!/^[0-9a-f]{1,64}$/.test(diff) || ![ts, sig, mode, pow].every(function (t) { return TOKEN.test(t); })) return '';
    var limit = Math.min(expect * 32, 2100000), deadline = host.now() + POW_SECONDS * 1000;
    for (var i = 0; i < limit; i++) {
      if (host.sha256(sig + i).indexOf(diff) === 0) return pow + '=' + ts + '_' + mode + '_' + i + '_' + sig;
      if ((i & 255) === 255 && host.now() > deadline) break;
    }
    return '';
  }

  // One page of the site, through the challenge when there is one; '' on any failure. A mirror that cannot be reached
  // passes the request to the next, which the session then keeps.
  function fetch(path) {
    for (var n = 0; n < bases.length; n++) {
      var at = (current + n) % bases.length, url = bases[at] + path, res = request(url);
      if (challenged(res)) {
        var cookie = solve(res.body || '');
        if (!cookie) return '';
        // Not following the 302 is what lets the jar keep its set-cookie (HTTPHost stores only the 302 it is handed).
        request(url, cookie);
        res = request(url);
      }
      if (res.status === 0 || res.status >= 500) continue;
      current = at;
      return res.status === 200 && !challenged(res) ? res.body || '' : '';
    }
    return '';
  }

  // Upstream l(): the thumbnails' links to /detail/, poster data-original, then data-src, then src.
  function vods(html) {
    var out = [], seen = {};
    host.pdfa(html, 'a.stui-vodlist__thumb[href*=/detail/]').forEach(function (a) {
      var id = host.match(host.pdfh(a, 'a&&href'), '/detail/(\\d+)');
      var name = host.pdfh(a, 'a&&title') || host.pdfh(a, 'Text');
      if (!id || !name || seen[id]) return;
      seen[id] = true;
      out.push({ vod_id: id, vod_name: name, vod_pic: host.pdfh(a, 'a&&data-original||data-src||src'),
                 vod_remarks: host.pdfh(a, '.pic-text&&Text') });
    });
    return out;
  }

  function episode(a) {
    var id = host.match(host.pdfh(a, 'a&&href'), '/(?:play|w)/([\\w-]+)');
    var name = host.pdfh(a, 'Text').replace(/[$#]/g, ' ').trim();
    return id && name ? name + '$' + id : '';
  }
  function episodes(nodes) { return nodes.map(episode).filter(Boolean).join('#'); }

  // The detail page's online panels: playlist-panel without netdisk-panel, named by its h3.
  function panels(root) {
    var from = [], urls = [];
    host.pdfa(root, 'div.playlist-panel').forEach(function (panel) {
      var name = host.pdfh(panel, 'h3&&Text');
      if (/\bnetdisk-panel\b/.test(text(panel.attrs['class'])) || !name || NETDISK_NAME.test(name)) return;
      var list = episodes(host.pdfa(panel, 'a[href]'));
      if (list) { from.push(name); urls.push(list); }
    });
    return { from: from, urls: urls };
  }

  // The play page's tabs and their episode lists, paired in order (W-165 播放頁 4).
  function tabs(html) {
    var from = [], urls = [], lists = host.pdfa(html, 'div.play-item');
    host.pdfa(html, 'ul.play-tab li a').forEach(function (a, i) {
      var name = host.pdfh(a, 'Text');
      if (!name || NETDISK_NAME.test(name) || !lists[i]) return;
      var list = episodes(host.pdfa(lists[i], 'ul.stui-play__list a[href*=/w/]'));
      if (list) { from.push(name); urls.push(list); }
    });
    return { from: from, urls: urls };
  }

  var spider = {
    init: function (extend) {
      var raw = text(extend).trim(), ext = null, list;
      try { ext = JSON.parse(raw); } catch (e) { ext = null; }
      list = ext && typeof ext === 'object' ? [].concat(ext.site || [], ext.sites || []) : [raw];
      bases = list.map(function (s) { return text(s).trim().replace(/\/+$/, ''); })
        .filter(function (s) { return /^https?:\/\/[^/?#\s]+$/.test(s) && !RELEASE.test(s); })
        .concat(MIRRORS)
        .filter(function (s, i, all) { return all.indexOf(s) === i; });
      current = 0;
      return '';
    },

    homeContent: function (filter) {
      var html = fetch('/'), classes = [], seen = {};
      host.pdfa(html, 'a[href^=/type/]').forEach(function (a) {
        var id = host.match(host.pdfh(a, 'a&&href'), '^/type/(\\d+)\\.html$'), name = host.pdfh(a, 'Text');
        if (!id || !name || seen[id]) return;
        seen[id] = true;
        classes.push({ type_id: id, type_name: name });
      });
      return host.result.home(classes, vods(html));
    },

    categoryContent: function (tid, pg, filter, extend) {
      var id = text(tid), n = pageNumber(pg);
      if (!/^\d+$/.test(id)) return host.result.page([], n, n, 0, 0);
      var html = fetch('/show/' + id + '--------' + n + '---.html'), list = vods(html);
      // 「1/265」
      var count = parseInt(host.match(host.pdfh(html, 'ul.stui-page__item li.active.num&&Text'), '/\\s*(\\d+)'), 10) || n;
      return host.result.page(list, n, count, list.length, count * list.length);
    },

    detailContent: function (ids) {
      var id = text(ids && ids[0]);
      if (!/^\d+$/.test(id)) return host.result.list([]);
      var html = fetch('/detail/' + id + '.html');
      if (!html) return host.result.list([]);
      var root = host.parse(html);
      var meta = host.pdfa(root, 'div.vod-info div.vod-meta');
      var items = meta[0] ? host.pdfa(meta[0], 'span.meta-item') : [];
      function item(i) { return items[i] ? host.pdfh(items[i], 'Text') : ''; }
      function row(i, label) { return meta[i] ? host.pdfh(meta[i], 'Text').replace(label, '').trim() : ''; }
      var lines = panels(root);
      if (!lines.from.length) {
        var first = host.match(host.pdfh(root, 'div.play-btn a&&href'), '^(/w/[\\w-]+\\.html)$');
        if (first) lines = tabs(fetch(first));
      }
      return host.result.detail({
        vod_id: id,
        vod_name: host.pdfh(root, 'div.vod-info h1.title&&Text'),
        vod_pic: host.pdfh(root, 'div.vod-poster img&&data-original||src'),
        type_name: item(0),
        vod_area: item(1),
        vod_year: item(2),
        vod_actor: row(1, /^主演[：:]/),
        vod_director: row(2, /^导演[：:]/),
        vod_remarks: host.pdfh(root, 'div.vod-info .vod-rating .score&&Text').replace('分', '').trim(),
        vod_content: host.pdfh(root, 'div.vod-info span.detail-content&&Text'),
        vod_play_from: lines.from.join('$$$'),
        vod_play_url: lines.urls.join('$$$')
      });
    },

    // Upstream's search route answers one page.
    searchContent: function (key, quick, pg) {
      var wd = text(key).trim();
      if (!wd || pageNumber(pg) > 1) return host.result.list([]);
      return host.result.list(vods(fetch('/search/-------------.html?wd=' + encodeURIComponent(wd))));
    },

    playerContent: function (flag, id, vipFlags) {
      var vid = text(id), none = host.result.play('', false);
      if (!/^[\w-]+$/.test(vid) || NETDISK_NAME.test(text(flag))) return none;
      var path = '/w/' + vid + '.html', html = fetch(path), player = null;
      try { player = JSON.parse(host.match(html, 'player_aaaa\\s*=\\s*(\\{[\\s\\S]*?\\})\\s*;?\\s*</script>')); } catch (e) { player = null; }
      if (!player || typeof player !== 'object' || NETDISK_FROM.test(text(player.from))) return none;
      var url = text(player.url), encrypt = parseInt(player.encrypt, 10);
      // encrypt 3 (W-165 播放頁 4) is a plain https address, which upstream's default branch also passes through.
      if (!/^https?:\/\//.test(url)) {
        if (encrypt === 2) url = host.dec(host.base64.decode(url));
        else if (encrypt === 1) url = host.dec(url);
      }
      if (!WEB.test(url) || NETDISK_HOST.test(url)) return none;
      return host.result.play(url, false, { 'Referer': bases[current] + path, 'User-Agent': UA });
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
