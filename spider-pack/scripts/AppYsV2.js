/**
 * csp_AppYsV2 — ported from `com.github.catvod.spider.AppYsV2` (river-fman.jar, 969 lines), the
 * `.vod` dialect only, which is the one this configuration uses (`ext` =
 * `https://www.nntv.in/api.php/v1.vod`). The original also speaks `api.php/app`, `xgapp`, the
 * `iopenyun` variant and a plain `api.php/*\/vod` dialect; an `ext` in any of those answers nothing
 * here rather than being guessed at.
 *
 * Plain JSON, no signing. jadx renders the detail conversion as one method whose `.vod` branch falls
 * through into the `api.php/app` code (`data.vod_url_with_player`); in the bytecode the branches are
 * exclusive, so `.vod` reads only `data.vod_play_list` here.
 *
 * IOS-POC-44E. Measured 2026-10-06: 10 types with class/area/lang/year, filtered listings (`total`
 * and `limit` in the reply), ranking, detail with three lines, search and the m3u8 lines' media all
 * answered.
 */
var spider = (function () {
  'use strict';

  var UA = 'okhttp/4.1.0';  // `h(url)` for a `.vod` address
  var HIDDEN = ['伦理', '情色', '福利'];
  var FILTER_NAMES = { 'class': '类型', area: '地区', lang: '语言', year: '年份' };
  var SORT = [['全部', ''], ['最新', 'time'], ['最热', 'hits'], ['评分', 'score']];
  var VIDEO = ['.m3u8', '.mp4', '.flv', '.avi', '.mkv', '.rm', '.wmv', '.mpg', 'video/tos', '.mp3', '.m4a', 'mime_type=video_mp4'];

  var base = '';

  function get(url) {
    if (!base) return {};
    return host.get(url, { headers: { 'User-Agent': UA }, timeout: 20000 }).json || {};
  }

  /** `.vod` lists in `data.list`; the original's `list` and array-`data` are the other dialects'. */
  function rows(o) { return o.data && Array.isArray(o.data.list) ? o.data.list : []; }

  function listing(items) {
    return items.filter(function (v) { return v && v.vod_id != null; }).map(function (v) {
      return { vod_id: String(v.vod_id), vod_name: v.vod_name, vod_pic: v.vod_pic, vod_remarks: v.vod_remarks };
    });
  }

  /** `data.total` over `data.limit` (`totalpage`/`pagecount` are the other dialects'). */
  function pages(o) {
    var d = o.data || {};
    if (typeof d.total === 'number' && typeof d.limit === 'number' && d.limit > 0) return Math.ceil(d.total / d.limit);
    return 9999;
  }

  /**
   * `q(url, type_extend)`: one row per class/area/lang/year the type publishes, in its order, led by
   * 全部, then the dialect's own 排序 row. A value is trimmed and empties are dropped, as Java's
   * `split` drops the trailing one a list such as `喜剧, 爱情, …网络电影,` ends in.
   */
  function filterRows(extend) {
    var out = [];
    Object.keys(extend || {}).forEach(function (key) {
      if (!FILTER_NAMES[key]) return;
      var values = String(extend[key] == null ? '' : extend[key]).split(',').map(function (v) { return v.trim(); })
        .filter(function (v) { return v && HIDDEN.indexOf(v) === -1; });
      out.push({ key: key, name: FILTER_NAMES[key], value: [{ n: '全部', v: '' }].concat(values.map(function (v) { return { n: v, v: v }; })) });
    });
    out.push({ key: '排序', name: '排序', value: SORT.map(function (s) { return { n: s[0], v: s[1] }; }) });
    return out;
  }

  /** `ku.e`: a media token in the address and no `=http`, `?http` or `.html`. */
  function isVideo(url) {
    var u = String(url).toLowerCase();
    if (/=http|\?http|\.html/.test(u)) return false;
    return VIDEO.some(function (t) { return u.indexOf(t) !== -1; });
  }

  return {
    init: function (extend) {
      var first = String(extend || '').split('###')[0].trim();
      base = first.indexOf('.vod') !== -1 ? first : '';
      return '';
    },

    homeContent: function (filter) {
      var classes = [], filters = {};
      rows(get(base + '/types')).forEach(function (t) {
        if (!t || HIDDEN.indexOf(t.type_name) !== -1) return;
        var id = String(t.type_id);
        classes.push({ type_id: id, type_name: t.type_name });
        if (filter) filters[id] = filterRows(t.type_extend);
      });
      return host.result.home(classes, null, filter ? filters : undefined);
    },

    /**
     * `vodPhbAll`: every `vod_list` anywhere in the reply, each title once. (The original looks for
     * `vlist` first, which only the `api.php/app` dialect sends.)
     */
    homeVideoContent: function () {
      var lists = [];
      (function collect(o) {
        if (Array.isArray(o)) { o.forEach(collect); return; }
        if (!o || typeof o !== 'object') return;
        Object.keys(o).forEach(function (k) {
          if (k === 'vod_list' && Array.isArray(o[k])) lists.push(o[k]);
          collect(o[k]);
        });
      })(get(base + '/vodPhbAll'));
      var seen = {}, items = [];
      lists.forEach(function (list) {
        listing(list).forEach(function (v) { if (!seen[v.vod_id]) { seen[v.vod_id] = true; items.push(v); } });
      });
      return host.result.list(items);
    },

    categoryContent: function (tid, page, filter, extend) {
      var e = extend || {};
      var pg = String(page || '1');
      var o = get(base + '?type=' + tid + '&class=' + host.enc(e['class'] || '') + '&area=' + host.enc(e.area || '')
                  + '&lang=' + host.enc(e.lang || '') + '&year=' + host.enc(e.year || '') + '&by=' + host.enc(e['排序'] || '')
                  + '&limit=18&page=' + pg);
      return host.result.page(listing(rows(o)), pg, pages(o), 18);
    },

    detailContent: function (ids) {
      var id = String(ids[0]);
      var d = get(base + '/detail?vod_id=' + id).data || {};
      var froms = [], urls = [];
      (d.vod_play_list || []).forEach(function (line) {
        var info = line.player_info || {};
        froms.push(String(info.from || '').trim() || String(info.show || '').trim());
        urls.push(String(line.url || ''));
      });
      return host.result.detail({
        vod_id: d.vod_id == null ? id : String(d.vod_id),
        vod_name: d.vod_name || '',
        vod_pic: d.vod_pic || '',
        type_name: d.vod_class || '',
        vod_year: d.vod_year == null ? '' : String(d.vod_year),
        vod_area: d.vod_area || '',
        vod_remarks: d.vod_remarks || '',
        vod_actor: d.vod_actor || '',
        vod_director: d.vod_director || '',
        vod_content: d.vod_content || '',
        vod_play_from: froms.join('$$$'),
        vod_play_url: urls.join('$$$')
      });
    },

    /** The original leaves `page=` empty; the API pages its search, so the page is passed on. */
    searchContent: function (key, quick, page) {
      var pg = String(page || '1');
      var o = get(base + '?wd=' + host.enc(String(key || '')) + '&page=' + pg);
      return host.result.page(listing(rows(o)), pg, pages(o));
    },

    /**
     * Every line of this source ships empty `parse`/`parse2` (measured 2026-10-06), so the
     * original's parser walk has nothing to try: a media address plays, anything else is a page for
     * the sniffer.
     */
    playerContent: function (flag, id) {
      var url = String(id);
      return host.result.play(url, !isVideo(url), { 'User-Agent': UA });
    },

    isVideoFormat: isVideo,
    manualVideoCheck: function () { return true; },
    destroy: function () { base = ''; }
  };
})();

module.exports = spider;
