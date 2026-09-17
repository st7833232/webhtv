/**
 * csp_JianPian — ported from `com.github.catvod.spider.JianPian` (river-fman.jar, 351 lines).
 *
 * **This is the port that unblocks 薦片.** The configuration points that site at `csp_JPianAmns`,
 * which lives in `aowu.jar` and is an empty shim over a native-encrypted payload — there is no logic
 * in it to read. `JianPian` drives the same API without any of that protection, which is provable
 * rather than assumed: the site's own `ext` filter file declares categories `1,2,3,4,67` with keys
 * `type/area/year/sort` (and `category_id/sort` for 67), and those are exactly the placeholders this
 * class substitutes into its `/api/crumb/list` template, down to 67 being the one that goes to
 * `/api/crumb/shortList` instead. `SpiderRegistry` therefore serves this script for both names.
 *
 * No crypto anywhere. The only unusual part is how it finds its host: a DNS-over-HTTPS TXT lookup
 * returns a comma-separated domain list, and each candidate is reached through a random six-letter
 * subdomain.
 */
var spider = (function () {
  'use strict';

  var UA = 'Mozilla/5.0 (Linux; Android 7.1.2; V2049A Build/UP1A.231005.007; wv) AppleWebKit/537.36 '
         + '(KHTML, like Gecko) Version/4.0 Chrome/81.0.4044.117 Mobile Safari/537.36;webank/h5face;'
         + 'webank/1.0;netType:NETWORK_WIFI;appVersion:422;packageName:com.jp3.xg3';
  var DOH = 'https://dns.alidns.com/resolve?name=swrdsfeiujo25sw.cc&type=TXT';
  var CLASSES = [['1', '电影'], ['2', '电视剧'], ['3', '动漫'], ['4', '综艺'], ['67', '短剧']];
  var SHORT = '67';

  var cfg = { url: '', img: '', filters: null };

  function api(path) {
    var res = host.get(cfg.url + path, { headers: { 'User-Agent': UA }, timeout: 20000 });
    return res.json || {};
  }

  /** `c()`: a path-only cover is relative to the image domain `init` looked up. */
  function image(path) {
    var value = String(path || '');
    return value.indexOf('/') === 0 ? 'https://' + cfg.img + value : value;
  }

  function listing(items, tid) {
    return (items || []).map(function (v) {
      var pic = image(tid === SHORT ? v.cover_image : v.path);
      var remarks = v.mask || v.score || '';
      // detailContent needs the category back, and the detail endpoint returns neither title nor
      // cover for 短剧, so the original carries all four through vod_id. Keep that shape.
      return { vod_id: v.id + '$$$' + v.title + '$$$' + pic + '$$$' + tid,
               vod_name: v.title, vod_pic: pic, vod_remarks: remarks };
    });
  }

  return {
    init: function (extend) {
      // The host list is published as a DNS TXT record, and each domain answers on any subdomain.
      var answer = (host.get(DOH, { timeout: 15000 }).json || {}).Answer || [];
      var domains = String((answer[0] || {}).data || '').replace(/^"|"$/g, '').split(',');
      for (var i = 0; i < domains.length; i++) {
        var domain = domains[i].trim();
        if (!domain) continue;
        var candidate = /^https?:\/\//.test(domain) ? domain : 'https://' + host.random(6) + '.' + domain;
        if (!cfg.url) cfg.url = candidate;           // the original's fallback: the first one
        if (host.get(candidate, { timeout: 10000 }).status === 200) { cfg.url = candidate; break; }
      }
      var settings = api('/api/v2/settings/resourceDomainConfig').data || {};
      cfg.img = String(settings.imgDomain || '').split(',')[0];
      // The class hard-codes its filter rows; this configuration supplies the same rows as a JSON
      // file through `ext`, so fetch that instead of carrying 4 KB of constants that would go stale.
      if (/^https?:\/\//.test(String(extend || ''))) {
        cfg.filters = host.get(String(extend), { timeout: 15000 }).json || null;
      }
      return '';
    },

    homeContent: function () {
      var classes = CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; });
      return host.result.home(classes, [], cfg.filters || undefined);
    },

    categoryContent: function (tid, page, filter, extend) {
      var id = String(tid), query = extend || {};
      var path = id === SHORT
        ? '/api/crumb/shortList?fcate_pid=' + id + '&category_id=' + (query.category_id || '')
          + '&sort=' + (query.sort || 'update') + '&page=' + (page || '1')
        : '/api/crumb/list?fcate_pid=' + id + '&category_id=' + (query.category_id || '')
          + '&area=' + (query.area || '') + '&year=' + (query.year || '')
          + '&type=' + (query.type || '') + '&sort=' + (query.sort || '') + '&page=' + (page || '1');
      return host.result.page(listing(api(path).data, id), page || '1');
    },

    detailContent: function (ids) {
      var parts = String(ids[0]).split('$$$');
      var id = parts[0], title = parts[1] || '', pic = parts[2] || '', tid = parts[3] || '1';
      var data = api(tid === SHORT ? '/api/detail?vid=' + id : '/api/video/detailv2?id=' + id).data || {};
      var froms = [], urls = [];
      function episodes(list, label) {
        var written = (list || []).map(function (ep) {
          var url = String(ep.url || '');
          // TVBox rewrites ftp to its own `tvbox-xg:` scheme for an external downloader iOS has no
          // equivalent of; the raw address is at least honest about what it is.
          return url ? ((ep.title || ep.source_name || '') + '$' + url) : '';
        }).filter(function (line) { return line; });
        if (written.length) { froms.push(label); urls.push(written.join('#')); }
      }
      if (tid === SHORT) {
        episodes(data.playlist, '常规线路');
      } else {
        (data.source_list_source || []).forEach(function (group) {
          episodes(group.source_list, group.name || 'default');
        });
      }
      return host.result.detail({
        vod_id: String(ids[0]),
        vod_name: title,
        vod_pic: image(pic),
        vod_remarks: '',
        vod_year: data.year || '',
        vod_area: data.area || '',
        vod_content: data.description || '',
        vod_actor: (data.actors || []).map(function (a) { return a.name; }).join(', '),
        vod_director: '',
        vod_play_from: froms.join('$$$'),
        vod_play_url: urls.join('$$$')
      });
    },

    searchContent: function (key, quick, page) {
      var data = api('/api/v2/search/videoV2?key=' + host.enc(key)
                     + '&category_id=88&page=' + (page || '1') + '&pageSize=20').data || [];
      return host.result.list((data || []).map(function (v) {
        var pic = image(v.thumbnail);
        var tid = String(((v.top_category || {}).id) || '1');
        return { vod_id: v.id + '$$$' + v.title + '$$$' + pic + '$$$' + tid,
                 vod_name: v.title, vod_pic: pic, vod_remarks: v.mask || '' };
      }));
    },

    playerContent: function (flag, id, vipFlags) {
      var url = String(id);
      // The original sends `parse:1` only for the big VIP portals, whose links need a parse service.
      // iOS has none configured, so the same call sends them to the sniffer, which is the closest
      // thing this app has; everything else is a direct file.
      var vip = /\/\/[^/]*(iqiyi|v\.qq|youku|le|tudou|mgtv|sohu|acfun|bilibili|pptv|miguvideo|ixigua|1905|fun\.tv)\./i.test(url);
      return host.result.play(url, vip, { 'User-Agent': UA });
    },

    isVideoFormat: function (url) { return /\.(m3u8|mp4|mkv|flv)(\?|$)/i.test(String(url)); },
    manualVideoCheck: function () { return false; },
    destroy: function () { cfg = { url: '', img: '', filters: null }; }
  };
})();

module.exports = spider;
