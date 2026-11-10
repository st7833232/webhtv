/**
 * SaoHuo (骚火电影) spider.
 * Port of com.github.catvod.spider.SaoHuo from spider.jar (W-266; triage W-255 `artifacts/w255/spider-jar-triage.md`).
 * Source host: the config's ext (https://shdy5.us), unless the mirror page http://shapp.us/ names a newer one first, as
 * upstream does. HTML lists; play resolves the play page's hhplayer iframe the way AnimeBashi does, and hands any
 * other iframe to the player's sniffer (parse 1) as upstream does for all of them.
 *
 * Differences from upstream, all deliberate (docs/W-266-spider-jar-port-7.md):
 * - The 类型 filter is applied (upstream offered it and ignored it), and the anime filter hangs on 动漫 (4), not on a
 *   category 3 that home never lists.
 * - vod_id is the detail page's path instead of the whole URL, so a mirror change keeps history and favourites.
 * - Session cookies ride the host's per-session cookie jar instead of upstream's single saved Set-Cookie.
 * - 主演 drops the trailing 剧情介绍 link text, and the synopsis drops the site's "…手机在线观看，由骚火电影友情提供" footer.
 * - An hhjx.hhplayer.com iframe (every play page sampled on 2026-11-09) is resolved through its /api/parse to the media
 *   address, falling back to the sniffer when that fails; the sniffer alone is slower and less reliable on iOS.
 */
(function () {
  'use strict';

  var MIRRORS = 'http://shapp.us/';
  var PARSER = 'https://hhjx.hhplayer.com';
  var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36';
  var HEADERS = { 'User-Agent': UA, 'accept-language': 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7' };
  var CLASSES = [['1', '电影'], ['2', '电视剧'], ['20', '国产剧'], ['4', '动漫']];
  function types(list) {
    return [{ key: 'cateId', name: '类型', value: list.map(function (t) { return { n: t[1], v: t[0] }; }) }];
  }
  var FILTERS = {
    '1': types([['1', '全部'], ['6', '喜剧'], ['7', '爱情'], ['8', '恐怖'], ['9', '动作'], ['10', '科幻'], ['11', '战争'],
                ['12', '犯罪'], ['13', '动画'], ['14', '奇幻'], ['15', '剧情'], ['16', '冒险'], ['17', '悬疑'], ['18', '惊悚'],
                ['20', '其他']]),
    '2': types([['2', '全部'], ['20', '国产剧'], ['21', 'TVB'], ['22', '韩剧'], ['23', '美剧'], ['24', '日剧'], ['25', '英剧'],
                ['26', '台剧'], ['27', '其他']]),
    '4': types([['4', '全部'], ['38', '搞笑'], ['39', '恋爱'], ['40', '热血'], ['41', '格斗'], ['42', '美少女'], ['43', '魔法'],
                ['44', '机战'], ['45', '校园'], ['46', '亲子'], ['47', '童话'], ['48', '冒险'], ['49', '真人'], ['50', 'LOLI'],
                ['51', '其他']])
  };
  var site = '';

  function text(v) { return v === null || v === undefined ? '' : String(v); }
  function pageNumber(pg) { var n = parseInt(pg, 10); return n > 1 ? n : 1; }
  function origin(u) { return host.match(text(u).trim(), '^(https?://[^/?#]+)'); }
  function page(path) {
    if (!site) return '';
    var res = host.get(site + path, { headers: HEADERS });
    return res.status === 200 ? res.body || '' : '';
  }
  function pathOf(href) { href = text(href); var o = origin(href); return o ? href.slice(o.length) : href; }

  function cards(html, max) {
    var out = [];
    host.pdfa(html, '.v_list .v_img').forEach(function (node) {
      if (max && out.length >= max) return;
      var path = pathOf(host.pdfh(node, 'a&&href')), name = host.pdfh(node, 'a&&title');
      if (path[0] !== '/' || !name) return;
      out.push({ vod_id: path, vod_name: name, vod_pic: host.pdfh(node, 'img&&data-original'),
                 vod_remarks: host.pdfh(node, '.v_note&&Text') });
    });
    return out;
  }

  var spider = {
    init: function (extend) {
      var res = host.get(MIRRORS, { headers: { 'User-Agent': UA } });
      site = origin(host.pdfh(res.status === 200 ? res.body || '' : '', '.content-top&&a&&href')) || origin(extend);
      return '';
    },

    homeContent: function (filter) {
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }), undefined, FILTERS);
    },

    // Upstream's home: the first six cards of the home page.
    homeVideoContent: function () {
      return host.result.list(cards(page('/'), 6));
    },

    categoryContent: function (tid, pg, filter, extend) {
      var n = pageNumber(pg), cate = text(extend && extend.cateId), id = /^\d+$/.test(cate) ? cate : text(tid);
      if (!/^\d+$/.test(id)) return host.result.page([], n, n, 0, 0);
      var list = cards(page('/list/' + id + '-' + n + '.html'));
      return host.result.page(list, n, list.length ? n + 1 : n, list.length);
    },

    detailContent: function (ids) {
      var path = text(ids && ids[0]);
      if (path[0] !== '/') path = pathOf(path);
      if (path[0] !== '/') return host.result.list([]);
      var html = page(path);
      if (!html) return host.result.list([]);
      var root = host.parse(html);
      var names = host.pdfa(root, '.play_from ul.from_list li').map(function (li) { return host.pdfh(li, 'Text'); });
      var from = [], urls = [];
      host.pdfa(root, '#play_link li').forEach(function (li, i) {
        // The site lists the newest episode first; upstream plays them oldest first.
        var eps = host.pdfa(li, 'a').map(function (a) {
          var href = pathOf(host.pdfh(a, 'a&&href'));
          return href[0] === '/' ? host.pdfh(a, 'Text').replace(/[$#]/g, ' ') + '$' + href : '';
        }).filter(Boolean).reverse();
        if (!eps.length) return;
        from.push(names[i] || '线路' + (i + 1));
        urls.push(eps.join('#'));
      });
      // "7.3分 / 美国 / 2026 / 动作 / 导演:… / 主演:…<a class="go_more">剧情介绍</a>"
      var line = host.pdfh(root, '.v_info_box&&p&&Text'), more = host.pdfh(root, '.v_info_box&&p&&a.go_more&&Text');
      if (more && line.slice(-more.length) === more) line = line.slice(0, -more.length);
      var info = line.split(/ \/ 导演:| \/ 主演:/), name = host.pdfh(root, 'h1.v_title&&Text');
      var content = host.pdfh(root, 'p.p_txt&&Text');
      return host.result.detail({
        vod_id: path, vod_name: name,
        type_name: text(info[0]).trim(), vod_director: text(info[1]).trim(), vod_actor: text(info[2]).trim(),
        vod_content: content.replace(name + '手机在线观看', '').replace(/[，,]?由骚火电影友情提供[\s\S]*$/, '').trim(),
        vod_play_from: from.join('$$$'), vod_play_url: urls.join('$$$')
      });
    },

    searchContent: function (key, quick, pg) {
      var wd = text(key).trim();
      if (!wd || pageNumber(pg) > 1) return host.result.list([]);
      return host.result.list(cards(page('/s----------.html?wd=' + host.enc(wd))));
    },

    // hhplayer iframe -> its /api/parse (url, t, key from its page); any other iframe, or a failed parse, goes to the
    // player's sniffer as upstream's parse 1 does.
    playerContent: function (flag, id, vipFlags) {
      var path = text(id);
      if (path[0] !== '/') return host.result.play('', false);
      var src = host.pdfh(page(path), 'iframe&&src');
      var frame = src ? host.urljoin(site + path, src) : '';
      if (!/^https?:\/\//.test(frame)) return host.result.play('', false);
      if (frame.indexOf(PARSER + '/') === 0) {
        var res = host.get(frame, { headers: { 'User-Agent': UA, 'Referer': site + '/' } });
        var body = res.status === 200 ? res.body || '' : '';
        var url = host.match(body, '"url":\\s*"([^"]+)"'), key = host.match(body, '"key":\\s*"([^"]+)"');
        var t = parseInt(host.match(body, '"t":\\s*(\\d+)'), 10) || 0;
        var json = url && key ? host.post(PARSER + '/api/parse', JSON.stringify({ url: url, t: t, key: key, client_fallback: false }),
                                          { headers: { 'User-Agent': UA, 'Referer': site + '/', 'Content-Type': 'application/json',
                                                       'Origin': PARSER } }).json : null;
        var media = text(json && json.url).replace(/^http:\/\//, 'https://');
        if (/^https:\/\//.test(media)) return host.result.play(media, false);
      }
      return host.result.play(frame, true, { 'User-Agent': UA });
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
