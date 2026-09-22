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

  var cfg = { url: '', img: '', filters: null, ext: '' };

  /** Does this host answer at all? Any HTTP status does; only a transport failure is `status: 0`. */
  function reachable(url, timeout) {
    return host.get(url, { headers: { 'User-Agent': UA }, timeout: timeout || 5000 }).status !== 0;
  }

  /**
   * The first entry of a comma-separated domain list **that actually answers**.
   *
   * IOS-POC-10W. The original takes `[0]` blindly and the port copied that. Measured 2026-09-22,
   * `resourceDomainConfig` answered
   * `img.cdgbq.com,img.cqkgy.com,img.cqykm.com,img.szrnp.com` and **the first two did not connect
   * at all** while the last two served the same 27 KB JPEG — so every poster in the app was a URL
   * pointing at a dead host, and the grid drew placeholders. The class already probes its *API*
   * domains this way; the image list needed the same treatment and never got it.
   */
  function firstAnswering(list) {
    var entries = String(list || '').split(',');
    for (var i = 0; i < entries.length; i++) {
      var domain = entries[i].trim();
      if (domain && reachable('https://' + domain, 5000)) return domain;
    }
    return (entries[0] || '').trim();
  }

  /**
   * Remember what worked, and try it before anything else (IOS-POC-10X).
   *
   * Both of this class's slow spots are the same shape: a list of candidates where the entries that
   * work are not the ones at the front, re-discovered from scratch on every launch. `host.local` is
   * this site's own namespaced storage, so the answer survives a restart.
   */
  function remembered(key) { return host.local.get('jp_' + key) || ''; }
  function remember(key, value) { if (value) host.local.set('jp_' + key, String(value)); }

  /**
   * The filter rows, falling back to the last set that arrived.
   *
   * The rows live in a file beside the configuration, on a **different host from everything else
   * here**, and one failed request used to cost the site its filter rows entirely: the category
   * chips rendered with nothing under them. IOS-POC-10W added an immediate retry, which was the
   * wrong shape — a retry milliseconds later meets the same network. Caching the last good copy is
   * what actually survives, because the rows change about as often as the category list does.
   *
   * **Not reproduced on macOS**, where this file has never failed to load; what is fixed here is
   * that a transient failure is no longer permanent, not a diagnosis of why it fails on a phone.
   */
  function fetchFilters() {
    if (!/^https?:\/\//.test(String(cfg.ext || ''))) return null;
    var fresh = host.get(String(cfg.ext), { timeout: 15000 }).json;
    if (fresh) { remember('filters', JSON.stringify(fresh)); return fresh; }
    var saved = remembered('filters');
    if (!saved) return null;
    try { return JSON.parse(saved); } catch (e) { return null; }
  }

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
      // Whichever API host answered last time, tried first. Measured 2026-09-22, the DNS list led
      // with `hzhnl.com`, which does not connect at all, so **every launch burned its full 10-second
      // probe before reaching a live domain** — `init` took 12.3 s and the site felt broken before
      // it had done anything wrong. A remembered host skips all of that; when it has died too, the
      // loop below runs exactly as it always did.
      var saved = remembered('host');
      if (saved && reachable(saved, 6000)) { cfg.url = saved; }

      if (!cfg.url) {
        // The host list is published as a DNS TXT record, and each domain answers on any subdomain.
        var answer = (host.get(DOH, { timeout: 15000 }).json || {}).Answer || [];
        var domains = String((answer[0] || {}).data || '').replace(/^"|"$/g, '').split(',');
        for (var i = 0; i < domains.length; i++) {
          var domain = domains[i].trim();
          if (!domain) continue;
          var candidate = /^https?:\/\//.test(domain) ? domain : 'https://' + host.random(6) + '.' + domain;
          if (!cfg.url) cfg.url = candidate;         // the original's fallback: the first one
          if (host.get(candidate, { timeout: 10000 }).status === 200) { cfg.url = candidate; break; }
        }
      }
      remember('host', cfg.url);

      var settings = api('/api/v2/settings/resourceDomainConfig').data || {};
      // Same treatment for the image host: the remembered one first, the published list after.
      var savedImage = remembered('img');
      cfg.img = savedImage && reachable('https://' + savedImage, 6000)
        ? savedImage : firstAnswering(settings.imgDomain);
      remember('img', cfg.img);
      // The class hard-codes its filter rows; this configuration supplies the same rows as a JSON
      // file through `ext`, so fetch that instead of carrying 4 KB of constants that would go stale.
      cfg.ext = String(extend || '');
      cfg.filters = fetchFilters();
      return '';
    },

    homeContent: function () {
      var classes = CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; });
      // One failed request must not cost this site its filter rows for the whole life of the
      // session — `SpiderSessionStore` caches a session until the configuration reloads, so the
      // category chips sat with nothing under them until the user switched source and back. The
      // retry is cheap because `fetchFilters` now answers from storage when the network will not.
      if (!cfg.filters) { cfg.filters = fetchFilters(); }
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
    destroy: function () { cfg = { url: '', img: '', filters: null, ext: '' }; }
  };
})();

module.exports = spider;
