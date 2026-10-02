/**
 * csp_Jpys — ported from `com.github.catvod.spider.Jpys` (river-fman.jar, 326 lines). Also drives
 * `csp_Jys` (324 lines), whose body is this one with a different line label (星河) and no
 * Origin/Referer on the stream; `SpiderRegistry.aliases` maps it here.
 *
 * The mw-movie "anonymous" API. Every GET carries `sign = sha1(md5(query&key=K&t=T))` and `T` in
 * headers. `ext` is a comma-separated mirror list; the first that answers is used, and when none does
 * the class falls back to its compiled-in default host.
 *
 * IOS-POC-44C. Measured 2026-10-02: `y2s52n7.com`, `www.hkybqufgh.com` and Jys's `www.ndhfiohk.com`
 * return the same listing, detail and episode ids, i.e. one backend. Jys's host has a certificate
 * that expired on 2026-08-07, so the TLS check fails it here exactly as the original's
 * `HttpURLConnection` check does on Android, and both land on the default host.
 */
var spider = (function () {
  'use strict';

  var KEY = 'cb808529bae6b6be45ecfab29a4889bc';
  var DEFAULT = 'https://www.hkybqufgh.com';
  var API = '/api/mw-movie/anonymous/';
  var PLAYER_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
    + 'Chrome/117.0.0.0 Safari/537.36';
  var CLASSES = [['1', '电影'], ['2', '电视剧'], ['4', '动漫'], ['3', '综艺']];

  var base = DEFAULT;

  /** The original's filter rows, built rather than carried as a 4 KB literal. */
  function filters() {
    function row(name, key, values) {
      return { name: name, key: key, value: [{ n: '全部', v: '' }].concat(values.map(function (v) { return { n: v, v: v }; })) };
    }
    function years(from, to) { var out = []; for (var y = from; y >= to; y--) out.push(String(y)); return out; }
    var areas = ['中国大陆', '中国香港', '中国台湾', '美国', '日本', '韩国', '泰国', '印度', '其他'];
    var full = years(2026, 2010).concat(['2009~2000', '90年代', '80年代']);
    return {
      '1': [row('地区', 'area', areas), row('年份', 'year', full)],
      '2': [row('地区', 'area', areas), row('年份', 'year', full)],
      '3': [row('地区', 'area', areas), row('年份', 'year', years(2026, 2020).concat(['更早']))],
      '4': [row('地区', 'area', ['中国大陆', '美国', '日本', '其他']), row('年份', 'year', full.concat(['更早']))]
    };
  }

  /** A signed GET. `signed` is the query as the original signs it: raw values, its own order. */
  function api(root, path, query, signed, timeout) {
    var t = String(host.now());
    var sign = host.sha1(host.md5((signed ? signed + '&' : '') + 'key=' + KEY + '&t=' + t));
    var res = host.get(root + API + path + (query ? '?' + query : ''), {
      headers: { 'sign': sign, 'T': t, 'Deviceid': 'Deviceid' }, timeout: timeout || 20000
    });
    return (res.json || {}).data;
  }

  function listing(items, remarks) {
    return (items || []).map(function (v) {
      return { vod_id: String(v.vodId), vod_name: v.vodName || '', vod_pic: v.vodPic || '',
               vod_remarks: String(v[remarks] == null ? '' : v[remarks]) };
    });
  }

  return {
    // The original keeps the first mirror whose HEAD answers 200–399. Measured 2026-10-02, HEAD
    // disagreed with the API on two of the six mirrors (403 while the API served, and the reverse),
    // so a mirror counts here when the signed hotSearch the home page needs actually answers.
    init: function (extend) {
      base = DEFAULT;
      var mirrors = String(extend || '').split(',');
      for (var i = 0; i < mirrors.length; i++) {
        var candidate = mirrors[i].trim().replace(/\/+$/, '');
        if (candidate && api(candidate, 'home/hotSearch', '', '', 10000)) { base = candidate; break; }
      }
      return '';
    },

    homeContent: function () {
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }),
                              listing(api(base, 'home/hotSearch', '', ''), 'vodVersion'), filters());
    },

    categoryContent: function (tid, page, filter, extend) {
      var area = (extend && extend.area) || '', year = (extend && extend.year) || '';
      if (area === '全部') area = '';
      if (year === '全部') year = '';
      var pg = String(page || '1');
      var data = api(base, 'video/list',
                     'type1=' + tid + '&pageNum=' + pg + '&area=' + host.enc(area) + '&year=' + host.enc(year),
                     'area=' + area + '&pageNum=' + pg + '&type1=' + tid + '&year=' + year) || {};
      return host.result.page(listing(data.list, 'vodVersion'), pg, data.totalPage);
    },

    detailContent: function (ids) {
      var id = String(ids[0]);
      var d = api(base, 'video/detail', 'id=' + id, 'id=' + id) || {};
      var episodes = (d.episodeList || []).map(function (ep) { return ep.name + '$' + id + '@' + ep.nid; });
      return host.result.detail({
        vod_id: id,
        vod_name: d.vodName || '',
        vod_pic: d.vodPic || '',
        vod_remarks: d.vodRemarks || '',
        vod_year: d.vodYear == null ? '' : String(d.vodYear),
        vod_area: d.vodArea || '',
        vod_actor: d.vodActor || '',
        vod_director: d.vodDirector || '',
        type_name: d.vodClass || '',
        vod_content: d.vodBlurb || d.vodContent || '',
        vod_play_from: episodes.length ? '在线播放' : '',
        vod_play_url: episodes.join('#')
      });
    },

    searchContent: function (key) {
      var word = String(key || '');
      var data = api(base, 'video/searchByWord', 'keyword=' + host.enc(word) + '&pageNum=1&pageSize=8',
                     'keyword=' + word + '&pageNum=1&pageSize=8') || {};
      var items = ((data.result || {}).list || []).filter(function (v) { return v.vodClass !== '伦理'; });
      return host.result.list(listing(items, 'vodRemarks'));
    },

    /** The id is `vodId@nid`; the first of the episode's addresses is the one the original plays. */
    playerContent: function (flag, id) {
      var parts = String(id).split('@');
      var data = api(base, 'v2/video/episode/url', 'id=' + parts[0] + '&nid=' + parts[1],
                     'id=' + parts[0] + '&nid=' + parts[1]) || {};
      var url = ((data.list || [])[0] || {}).url || '';
      return host.result.play(url, false, { 'User-Agent': PLAYER_UA, 'Origin': base, 'Referer': base });
    },

    isVideoFormat: function (url) { return /\.(m3u8|mp4|mkv|flv)(\?|$)/i.test(String(url)); },
    manualVideoCheck: function () { return false; },
    destroy: function () { base = DEFAULT; }
  };
})();

module.exports = spider;
