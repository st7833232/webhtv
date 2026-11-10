/**
 * AppFox spider: the Appfox app API (`/api.php/Appfox/*`) on a host the config's ext names.
 * Port of com.github.catvod.spider.AppFox from spider.jar (W-266; triage W-255 `artifacts/w255/spider-jar-triage.md`).
 * ext: "http://host", or JSON {host, ver, ua, parse, custom_first, category, from}. A host that is not a bare origin is
 * fetched once for its apiDomain (or its trimmed text), as upstream does.
 *
 * Differences from upstream, all deliberate (docs/W-266-spider-jar-port-7.md):
 * - ext `cms` (a maccms /vod mirror) and `category: 2` (msearch ids) are not ported; no known config uses either, and
 *   a config that sets `cms` still runs on the Appfox API.
 * - Category filters send their own values; upstream sent the 地区 value for every key and never sent 排序.
 * - An episode id is `playerCode@address`; upstream also carried the title for its TVBox-proxy danmaku, which is dropped.
 * - The player/jiexi config is read once per session, not on every detail.
 */
(function () {
  'use strict';

  var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  var PLAYER_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1';
  var DIRECT = /^https?:\/\/.*\.(m3u8|mp4|flv|mkv)/;
  var FILTER_NAMES = { 'class': '类型', area: '地区', lang: '语言', year: '年份', sort: '排序' };
  var HIDDEN = /^(全部|QQ|juo\.one)$|企鹅群/;

  var api = '', ver = 1, category = 1, searchFrom = '', customFirst = 0, timeout = 5000;
  var ua = {}, defaultUA = UA, customParse = {}, players = null;

  function text(v) { return v === null || v === undefined ? '' : String(v); }
  function pageNumber(pg) { var n = parseInt(pg, 10); return n > 1 ? n : 1; }
  function headers(op) { return { 'User-Agent': ua[op] || defaultUA, 'Accept-Language': 'zh-CN,zh;q=0.8', 'Cache-Control': 'no-cache' }; }
  function get(url, op) { return host.get(url, { headers: headers(op), timeout: timeout }); }
  function call(path, op) { return api ? get(api + '/api.php/Appfox/' + path, op).json || {} : {}; }
  function vods(items) {
    return (items || []).map(function (v) {
      return { vod_id: text(v.vod_id), vod_name: text(v.vod_name), vod_pic: text(v.vod_pic), vod_remarks: text(v.vod_remarks) };
    }).filter(function (v) { return /^\d+$/.test(v.vod_id); });
  }

  // playerCode -> display name and jiexi addresses, from /config.
  function playerConfig() {
    if (players) return players;
    var data = call('config', 'config').data || {};
    players = { names: {}, jiexi: {} };
    (data.playerList || []).forEach(function (p) { players.names[text(p.playerCode)] = text(p.playerName); });
    (data.jiexiDataList || []).forEach(function (j) {
      if (/^http/.test(text(j.url))) players.jiexi[text(j.playerCode)] = text(j.url);
    });
    return players;
  }

  // Upstream's resolver order: the site's jiexi then the config's parse map (custom_first swaps them). A `parse:`
  // prefix hands the joined address to the player's own parsing; anything else must answer {"url": "http…"}.
  function resolve(code, url) {
    var maps = [playerConfig().jiexi, customParse];
    if (customFirst === 1) maps.reverse();
    for (var m = 0; m < maps.length; m++) {
      var keys = Object.keys(maps[m]);
      for (var k = 0; k < keys.length; k++) {
        if (keys[k].indexOf(code) === -1) continue;
        var values = [].concat(maps[m][keys[k]]);
        for (var v = 0; v < values.length; v++) {
          var p = text(values[v]);
          if (p.indexOf('parse:') === 0) return { url: p.slice(6) + url, parse: 1 };
          var json = host.parseJSON(get(p + url, 'parse').body);
          if (json && /^http/.test(text(json.url))) return { url: text(json.url), parse: 0 };
        }
      }
    }
    return null;
  }

  var spider = {
    init: function (extend) {
      var ext = text(extend).trim(), base = ext;
      if (!ext) return '';
      if (!/^http/.test(ext)) {
        var cfg = host.parseJSON(ext) || {};
        base = text(cfg.host);
        ver = String(cfg.ver) === '2' ? 2 : 1;
        searchFrom = text(cfg.from);
        customFirst = parseInt(cfg.custom_first, 10) || 0;
        category = cfg.category === undefined ? 1 : parseInt(cfg.category, 10);
        if (cfg.parse && typeof cfg.parse === 'object') customParse = cfg.parse;
        if (typeof cfg.ua === 'string') defaultUA = cfg.ua;
        else if (cfg.ua && typeof cfg.ua === 'object') ua = cfg.ua;
        if (parseInt(cfg.timeout, 10) > 0) timeout = parseInt(cfg.timeout, 10) * 1000;
      }
      if (base && !/^https?:\/\/[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)*(:\d+)?\/?$/.test(base)) {
        var body = text(get(base, 'host').body), json = host.parseJSON(body);
        var found = json && json.apiDomain ? text(json.apiDomain) : body.trim();
        if (/^http/.test(found)) base = found;
      }
      api = /^https?:\/\//.test(base) ? base.replace(/\/+$/, '') : '';
      return '';
    },

    homeContent: function (filter) {
      if (!api || category === 0) return host.result.home([]);
      var classes = [], filters = {};
      ((call('init', 'home').data || {}).type_list || []).forEach(function (t) {
        var name = text(t.type_name);
        if (!name || HIDDEN.test(name)) return;
        classes.push({ type_id: text(t.type_id), type_name: name });
        var list = (t.filter_type_list || []).filter(function (f) { return (f.list || []).length; }).map(function (f) {
          var key = text(f.name);
          return { key: key === 'sort' ? 'by' : key, name: FILTER_NAMES[key] || key,
                   value: f.list.map(function (v) { return { n: text(v), v: text(v) }; }) };
        });
        if (list.length) filters[text(t.type_id)] = list;
      });
      return host.result.home(classes, undefined, filters);
    },

    // ver 2: the first navigation tab's feed; otherwise /index. Banners and every category's videos, in order.
    homeVideoContent: function () {
      if (!api || category === 0) return host.result.list([]);
      var path = 'index';
      if (ver === 2) {
        var nav = (call('nav', ua.homeVideo ? 'homeVideo' : 'home').data || []).filter(function (n) { return n && n.navigationId !== undefined; })[0];
        if (!nav) return host.result.list([]);
        path = 'nav_video?id=' + host.enc(text(nav.navigationId));
      }
      var out = [];
      (call(path, ua.homeVideo ? 'homeVideo' : 'home').data || []).forEach(function (block) {
        out = out.concat(block.banner || []);
        (block.categories || []).forEach(function (c) { out = out.concat(c.videos || []); });
      });
      return host.result.list(vods(out));
    },

    categoryContent: function (tid, pg, filter, extend) {
      var n = pageNumber(pg), id = text(tid);
      if (!api || !/^\d+$/.test(id)) return host.result.page([], n, n, 0, 0);
      var e = extend || {};
      function f(key) { return host.enc(text(e[key]) || '全部'); }
      var res = call('vodList?type_id=' + id + '&page=' + n + '&class=' + f('class') + '&area=' + f('area') +
                     '&lang=' + f('lang') + '&year=' + f('year') + '&sort=' + f('by'), 'category');
      var list = vods((res.data || {}).recommend_list);
      return host.result.page(list, n, list.length ? n + 1 : n, list.length);
    },

    detailContent: function (ids) {
      var id = text(ids && ids[0]);
      if (!api || !/^\d+$/.test(id)) return host.result.list([]);
      var v = (call('vod?ac=detail&ids=' + id, ua.detail ? 'detail' : 'search').list || [])[0];
      if (!v) return host.result.list([]);
      var names = playerConfig().names;
      var codes = text(v.vod_play_from).split('$$$'), lines = text(v.vod_play_url).split('$$$'), from = [], urls = [];
      codes.forEach(function (code, i) {
        var eps = text(lines[i]).split('#').map(function (ep) {
          var at = ep.indexOf('$');
          return at > 0 && ep.slice(at + 1) ? ep.slice(0, at) + '$' + code + '@' + ep.slice(at + 1) : '';
        }).filter(Boolean);
        if (!code || !eps.length) return;
        var name = names[code];
        from.push(!name || name === code ? code : name + ' (' + code + ')');
        urls.push(eps.join('#'));
      });
      return host.result.detail({
        vod_id: text(v.vod_id) || id, vod_name: text(v.vod_name), vod_pic: text(v.vod_pic), vod_remarks: text(v.vod_remarks),
        vod_year: text(v.vod_year), vod_area: text(v.vod_area), vod_actor: text(v.vod_actor), vod_director: text(v.vod_director),
        type_name: text(v.type_name), vod_content: host.stripTags(text(v.vod_content)).trim(),
        vod_play_from: from.join('$$$'), vod_play_url: urls.join('$$$')
      });
    },

    searchContent: function (key, quick, pg) {
      var wd = text(key).trim(), n = pageNumber(pg);
      if (!api || !wd) return host.result.list([]);
      var res = call('vod?ac=detail&wd=' + host.enc(wd) + '&page=' + n + (searchFrom ? '&from=' + host.enc(searchFrom) : ''), 'search');
      var list = vods(res.list);
      return host.result.page(list, n, parseInt(res.pagecount, 10) || n, list.length, parseInt(res.total, 10) || list.length);
    },

    playerContent: function (flag, id, vipFlags) {
      var at = text(id).indexOf('@'), code = text(id).slice(0, at), url = text(id).slice(at + 1);
      if (at <= 0 || !url) return host.result.play('', false);
      var header = { 'User-Agent': ua.player || PLAYER_UA };
      if (DIRECT.test(url)) return host.result.play(url, false, header);
      var hit = resolve(code, url);
      if (hit) return host.result.play(hit.url, hit.parse === 1, header);
      // Nothing resolved it: leave it to the app's own parse services, as upstream's jx 1 does.
      return { parse: 0, jx: 1, url: url, header: header };
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
