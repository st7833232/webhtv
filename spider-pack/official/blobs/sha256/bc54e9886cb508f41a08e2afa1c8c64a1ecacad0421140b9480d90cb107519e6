/**
 * Wwys (旺旺影视) spider.
 * Port of com.github.catvod.spider.Wwys from qist spider.jar (W-152, gate W-148 `qist-Wwys-gate-2026-10-16.md`).
 * Source host: https://vip.wwgz.cn:5200 (maccms static-route HTML; every episode id is its own m3u8 address).
 *
 * Differences from upstream, all deliberate (gate 實作要點, docs/IOS-POC-57B-17-wwys.md):
 * - Only line ② (mac_from `lzm3u8`, standard HLS) is listed, under the site's label 线路②. Line ① (`monday`) hides its
 *   segments behind PNG headers on image hosts, which AVPlayer cannot play, so a title without line ② lists no line.
 *   Upstream puts the whole mac_url under one hard-coded 在线播放, so TVBox only ever showed line ①.
 * - Fixed categories without 小姐姐 (20: empty, and the only questionable one); upstream reads #topnav on every call.
 * - playerContent returns the m3u8 with parse 0. Upstream's wwgz.js / relay067 / lzm3u8.js chain is dead or echoes its
 *   input (gate #8, #12, #13); its danmaku needs TVBox's local proxy.
 * - Category pages carry the footer's page count and total, which upstream drops. Search answers page 1 only, since
 *   the site's search has no pages and upstream would repeat it for every page.
 */
(function () {
  'use strict';

  var HOST = 'https://vip.wwgz.cn:5200';
  var UA = 'Mozilla/5.0 (Linux; Android 13; SM-A037U) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.0.0 Mobile Safari/537.36  uacq';
  var CLASSES = [['1', '电影'], ['2', '连续剧'], ['3', '综艺'], ['4', '动漫'], ['26', '短剧'], ['31', '音乐']];
  // Upstream's 类型 filter on 电影 and 连续剧, with the sub-categories the site's own list pages offer (gate #2, #20).
  function types(list) {
    return [{ key: 'cateId', name: '类型', value: [{ n: '全部', v: '' }].concat(list.map(function (t) { return { n: t[1], v: t[0] }; })) }];
  }
  var FILTERS = {
    '1': types([['5', '动作片'], ['6', '喜剧片'], ['7', '爱情片'], ['8', '科幻片'], ['9', '恐怖片'], ['10', '剧情片'],
                ['11', '战争片'], ['16', '惊悚片'], ['17', '奇幻片']]),
    '2': types([['12', '国产剧'], ['13', '港台泰'], ['14', '日韩剧'], ['15', '欧美剧']])
  };
  var LINE = 'lzm3u8', LINE_NAME = '线路②';
  var site = HOST;

  function text(v) { return v === null || v === undefined ? '' : String(v); }
  function pageNumber(pg) { var n = parseInt(pg, 10); return n > 1 ? n : 1; }
  function page(path) {
    var res = host.get(site + path, { headers: { 'User-Agent': UA } });
    return res.status === 200 ? res.body || '' : '';
  }
  // Upstream's id: the digits of the detail link (/vod-detail-id-96319.html).
  function idOf(href) { return text(href).replace(/\D/g, ''); }

  // A home or category <li>; home posters are data-src on run-together <img … "<img …> tags, category ones src.
  function vods(nodes) {
    var out = [];
    nodes.forEach(function (li) {
      var id = idOf(host.pdfh(li, 'a&&href'));
      if (!id) return;
      out.push({ vod_id: id, vod_name: host.pdfh(li, 'a&&title'), vod_pic: host.pdfh(li, 'img&&data-src||src||data-echo'),
                 vod_remarks: host.pdfh(li, '.sBottom&&Text') });
    });
    return out;
  }

  // A .desc_item row by its label (状态/主演/导演/年代), as the joined text of its links or its <font>.
  function row(root, label, rule) {
    var item = host.pdfa(root, '.desc_item').filter(function (n) { return host.pdfh(n, 'span&&Text').indexOf(label) === 0; })[0];
    if (!item) return '';
    return host.pdfa(item, rule).map(function (n) { return host.pdfh(n, 'Text'); }).filter(Boolean).join(' ');
  }

  var spider = {
    init: function (extend) {
      var ext = text(extend).split('$$$')[0].trim().replace(/\/+$/, '');
      site = /^https?:\/\//.test(ext) ? ext : HOST;
      return '';
    },

    homeContent: function (filter) {
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }), undefined, FILTERS);
    },

    // 今日更新: the first .globalPicList on the home page.
    homeVideoContent: function () {
      return host.result.list(vods(host.pdfa(page('/'), '.globalPicList&&li')));
    },

    categoryContent: function (tid, pg, filter, extend) {
      var cate = text(extend && extend.cateId), id = /^\d+$/.test(cate) ? cate : text(tid), n = pageNumber(pg);
      if (!/^\d+$/.test(id)) return host.result.page([], n, n, 0, 0);
      var html = page('/vod-list-id-' + id + '-pg-' + n + '-order--by-time-class-0-year-0-letter--area--lang-.html');
      var list = vods(host.pdfa(html, '.resize_list > li'));
      // Footer: 共20720条数据&nbsp;当前:1/691页
      var count = parseInt(host.match(html, '当前:\\d+/(\\d+)页'), 10) || n;
      var total = parseInt(host.match(html, '共(\\d+)条数据'), 10) || list.length;
      return host.result.page(list, n, count, list.length, total);
    },

    detailContent: function (ids) {
      var id = text(ids && ids[0]);
      if (!/^\d+$/.test(id)) return host.result.list([]);
      var html = page('/vod-detail-id-' + id + '.html');
      if (!html) return host.result.list([]);
      var root = host.parse(html);
      // The play page's player variables hold every line; the detail page has only episode links.
      var play = page('/vod-play-id-' + id + '-src-1-num-1.html');
      var from = host.match(play, "mac_from='([^']*)'").split('$$$');
      var line = from.indexOf(LINE) >= 0 ? text(host.match(play, "mac_url='([^']*)'").split('$$$')[from.indexOf(LINE)]) : '';
      return host.result.detail({
        vod_id: id,
        vod_name: host.pdfh(root, '.title&&a&&title'),
        vod_pic: host.pdfh(root, '.page-hd&&img&&src'),
        vod_remarks: row(root, '状态', 'font'),
        vod_actor: row(root, '主演', 'a'),
        vod_director: row(root, '导演', 'a'),
        vod_year: row(root, '年代', 'a'),
        vod_content: host.pdfh(root, '.detail-con&&p&&Text').replace(/^简[\s\S]*?介[：:]\s*/, ''),
        vod_play_from: line ? LINE_NAME : '',
        vod_play_url: line
      });
    },

    searchContent: function (key, quick, pg) {
      var wd = text(key).trim();
      if (!wd || pageNumber(pg) > 1) return host.result.list([]);
      var out = [];
      host.pdfa(page('/index.php?m=vod-search&wd=' + encodeURIComponent(wd)), '#data_list > li').forEach(function (li) {
        var id = idOf(host.pdfh(li, '.pic&&a&&href'));
        if (!id) return;
        var des = host.pdfa(li, '.sDes')[1];
        out.push({ vod_id: id, vod_name: host.pdfh(li, '.sTit&&Text'), vod_pic: host.pdfh(li, 'img&&data-src||src'),
                   vod_remarks: des ? host.pdfh(des, 'Text').replace(/评分[：:]/, '') : '' });
      });
      return host.result.list(out);
    },

    playerContent: function (flag, id, vipFlags) {
      var url = text(id);
      return host.result.play(/^https?:\/\//.test(url) ? url : '', false, { 'User-Agent': UA });
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
