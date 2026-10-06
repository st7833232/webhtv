/**
 * csp_MiaoWu — ported from `com.github.catvod.spider.MiaoWu` (xiaosa-0807.jar, 339 lines).
 *
 * 喵呜动漫's app API. The API base is published as a DoH TXT record (`doh.catw.moe` via `doh.pub`)
 * whose value is base64(AES-256-ECB(url)) under a fixed UTF-8 key; it is resolved once per session,
 * and when that fails the compiled-in `http://app.nyafun.vip/app/api/` stays. Replies carry `data`
 * as base64(AES-256-ECB(JSON)) under a second key. A file id that names the `mwvod` host is not
 * playable as it is: `vod/parse` trades it, with its player code, for a signed address.
 *
 * IOS-POC-44D. Measured 2026-10-06: the TXT record decrypted to `http://app.nyafun.vip`; config,
 * listing (12 a page, `class` and `year` honoured), detail, search, direct m3u8 lines and a
 * `vod/parse` answer (an R2 presigned mp4, 206 `ftypisom`) all answered.
 */
var spider = (function () {
  'use strict';

  var DATA_KEY = 'c55c019c59a9fbe196ef9fc7d2a0b351';
  var DOH_KEY = '6516c20a87257caa418c721caf6a8c12';
  var DOH = 'https://doh.pub/resolve?name=doh.catw.moe&type=txt';
  var DEFAULT = 'http://app.nyafun.vip/app/api/';
  var HEADERS = { 'User-Agent': 'Dart/3.5 (dart:io)', 'content-type': 'application/json' };
  var PAGE = 12;

  var base = DEFAULT;

  /** `f(url)`: any configured host, normalised to end in `/app/api/`. */
  function apiBase(url) {
    var s = String(url).trim();
    if (/\/app\/api$/.test(s)) return s + '/';
    if (/\/app\/api\/$/.test(s)) return s;
    return s + (/\/$/.test(s) ? 'app/api/' : '/app/api/');
  }

  /**
   * `d()`: once per session, from `init`, and a success replaces even a configured `ext` host. The
   * original also calls it before each request behind a flag; `init` always runs first here.
   */
  function resolve() {
    var answer = ((host.get(DOH, { headers: HEADERS, timeout: 20000 }).json || {}).Answer || [])[0];
    var data = String((answer && answer.data) || '');
    var first = data.indexOf('"'), last = data.lastIndexOf('"');
    var cipher = first >= 0 && last > first ? data.slice(first + 1, last) : data.trim().replace(/"/g, '');
    if (!cipher) return;
    var url = host.aesDecrypt(cipher, DOH_KEY, '', 'ECB', 'base64').trim();
    if (url.indexOf('http') === 0) base = url.replace(/\/+$/, '') + '/app/api/';
  }

  /** `h(body)`: an encrypted `data` replaces the envelope; anything else is the envelope itself. */
  function open(body) {
    var o;
    try { o = JSON.parse(body || '{}'); } catch (e) { return {}; }
    var data = o && o.data;
    if (typeof data !== 'string' || data.length <= 16 || /^\s*[{[]/.test(data)) return o || {};
    try { return JSON.parse(host.aesDecrypt(data, DATA_KEY, '', 'ECB', 'base64')); } catch (e) { return {}; }
  }

  function api(path) {
    return open(host.get(base + path, { headers: HEADERS, timeout: 20000, json: false }).body);
  }

  /** `g(o)`: `filter_vods` or `search_full`, skipping entries without an id or a name. */
  function listing(o) {
    var out = [];
    (o.filter_vods || o.search_full || []).forEach(function (v) {
      if (!v) return;
      var id = String(v.id !== undefined ? v.id : (v.vod_id == null ? '' : v.vod_id)).trim();
      var name = String(v.vod_name == null ? '' : v.vod_name).trim();
      if (!id || !name || id === 'null') return;
      out.push({ vod_id: id, vod_name: name, vod_pic: v.vod_pic || '', vod_remarks: v.vod_remarks || '' });
    });
    return out;
  }

  /**
   * `a(rows, key, name, values)`: a comma list from `type_extend`, led by 全部. The original also
   * drops any list longer than 80 characters, and every `class` and `year` list the API sends today
   * is longer, so it shows no filters at all — and its `categoryContent` never sends them. Measured
   * 2026-10-06, `content/filter` does honour `class` and `year`, so the rows are offered and sent;
   * the notice the API puts in a filter slot (`PC请使用…`) is still dropped by the 请／建议 check.
   */
  function filterRow(rows, key, name, values) {
    values = String(values == null ? '' : values);
    if (!values || values.indexOf('请') !== -1 || values.indexOf('建议') !== -1) return;
    var options = values.split(',').map(function (v) { return v.trim(); }).filter(function (v) { return v; })
      .map(function (v) { return { n: v, v: v }; });
    if (options.length) rows.push({ key: key, name: name, value: [{ n: '全部', v: '' }].concat(options) });
  }

  return {
    init: function (extend) {
      var ext = String(extend || '').trim();
      if (ext.indexOf('{') === 0) {
        try { var url = JSON.parse(ext).url; if (url) base = apiBase(url); } catch (e) { /* keep the default */ }
      } else if (ext.indexOf('http') === 0) {
        base = apiBase(ext);
      }
      resolve();
      return '';
    },

    homeContent: function () {
      var classes = [], filters = {};
      (api('config?platform=android').ac_vod_type || []).forEach(function (t) {
        if (!t) return;
        var id = String(t.type_id == null ? '' : t.type_id).trim(), name = String(t.type_name || '').trim();
        if (!id || !name || id === 'null') return;
        classes.push({ type_id: id, type_name: name });
        var rows = [];
        if (t.type_extend) {
          filterRow(rows, 'class', '类型', t.type_extend['class']);
          filterRow(rows, 'year', '年份', t.type_extend.year);
        }
        if (rows.length) filters[id] = rows;
      });
      return host.result.home(classes, null, filters);
    },

    categoryContent: function (tid, page, filter, extend) {
      var pg = parseInt(String(page || '1').trim(), 10) || 1;
      var path = 'content/filter?page=' + pg + '&sort=0&type=' + host.enc(tid);
      if (extend && extend['class']) path += '&class=' + host.enc(extend['class']);
      if (extend && extend.year) path += '&year=' + host.enc(extend.year);
      var items = listing(api(path));
      var count = items.length < PAGE ? pg : pg + 1;
      return host.result.page(items, pg, count, PAGE, count * PAGE);
    },

    detailContent: function (ids) {
      var id = String(ids[0] || '').trim();
      if (!id) return host.result.detail({});
      var d = api('vod/' + host.enc(id));
      var froms = [], urls = [];
      (d.playerData || []).forEach(function (line, i) {
        if (!line) return;
        var player = String(line.player || '').trim();
        var episodes = [];
        (line.vids || []).forEach(function (vid, n) {
          var value = String(vid).trim();
          if (!value || value === 'null') return;
          episodes.push((value.indexOf('$') !== -1 ? value : '第' + (n + 1) + '集$' + value) + '|||' + player);
        });
        if (!episodes.length) return;
        var name = String(line.name || '').trim() || '线路' + (i + 1);
        // Every line is named 请移步牛番 today. The app finds a watched line by its name, so a
        // repeated name always resumes on the first such line; the player code tells them apart.
        if (froms.indexOf(name) !== -1) name += ' ' + player;
        froms.push(name);
        urls.push(episodes.join('#'));
      });
      return host.result.detail({
        vod_id: id,
        vod_name: d.vod_name || '',
        vod_pic: d.vod_pic || '',
        type_name: d.vod_class || '',
        vod_year: d.vod_year == null ? '' : String(d.vod_year),
        vod_content: d.vod_content || '',
        vod_actor: d.vod_author || '',
        vod_remarks: d.vod_remarks || '',
        vod_play_from: froms.join('$$$'),
        vod_play_url: urls.join('$$$')
      });
    },

    /** One page: `search/full` ignores paging and answers every match at once. */
    searchContent: function (key) {
      if (!key) return host.result.list([]);
      return host.result.list(listing(api('search/full?q=' + host.enc(key))));
    },

    /** The id is `vid|||player`; `vid` is a file address, or a `mwvod` id `vod/parse` signs. */
    playerContent: function (flag, id) {
      var value = String(id || '').trim(), player = '';
      var cut = value.lastIndexOf('|||');
      if (cut >= 0) { player = value.slice(cut + 3); value = value.slice(0, cut); }
      if (value.indexOf('$') !== -1) value = value.slice(value.lastIndexOf('$') + 1);
      if (value.indexOf('http') !== -1 && value.indexOf('mwvod') === -1) return host.result.play(value, false, HEADERS);
      var res = host.post(base + 'vod/parse', JSON.stringify({ vid: value, player: player }), {
        headers: { 'User-Agent': HEADERS['User-Agent'], 'Content-Type': 'application/json; charset=utf-8' },
        timeout: 20000, json: false
      });
      return host.result.play(String(open(res.body).play_url || ''), false, HEADERS);
    },

    isVideoFormat: host.isVideoFormat,
    manualVideoCheck: function () { return false; },
    destroy: function () { base = DEFAULT; }
  };
})();

module.exports = spider;
