/**
 * csp_GuaziTY — ported from `com.github.catvod.spider.GuaziTY` (river-fman.jar, 127 lines).
 *
 * 瓜子体育's live-match API. Every call is a form POST whose `parameter` is base64(AES-128-CBC(JSON))
 * under a fixed key and IV, and the reply's `data` is the same cipher again. A category is one list
 * of matches: only those that started within the last 24 hours or have not started, and that are
 * not over (`m_status` 0 not started, 1 live, 2 finished). There is no search and no second page.
 *
 * A category with no such match answers an empty list; a reply that does not decrypt to the match
 * list is an error, as in the original (`new JSONArray(...)` throws there), so the two are never
 * confused. A match that has not started has its line already, but its stream answers 404 until
 * kick-off (measured 2026-10-06).
 *
 * IOS-POC-44F. Measured 2026-10-06: all four categories, details and live lines decrypted, and a
 * live match's m3u8 served TS segments.
 */
var spider = (function () {
  'use strict';

  var API = 'https://api.46d5umpk.com/gz/live/';
  var KEY = 'KANGEQIU@8868!~.', IV = '0200010900030207';
  var HEADERS = { 'User-Agent': 'okhttp/3.12.0', 'content-type': 'application/x-www-form-urlencoded',
                  'user-platform': 'null', 'client-version': '3.0.1.1', 'client-channel': '', 'token': '' };
  var CLASSES = [['hot', '热门'], ['nba', 'NBA'], ['football', '足球'], ['basketball', '篮球']];
  var QUERIES = {
    hot: '{"frame":"0","hot":"1","tag":"0","type":"0"}',
    nba: '{"frame":"0","hot":"0","tag":"37","type":"0"}',
    football: '{"frame":"0","hot":"0","tag":"0","type":"1"}',
    basketball: '{"frame":"0","hot":"0","tag":"0","type":"2"}'
  };

  /** POST and decrypt. `null` when the request itself failed; throws when the reply does not open. */
  function api(path, plain) {
    var res = host.post(API + path + '?parameter=key', { parameter: host.aesEncrypt(plain, KEY, IV, 'CBC') },
                        { headers: HEADERS, timeout: 20000 });
    if (res.status !== 200 || !res.body) return null;  // the runtime reports the failed request
    var data = res.json && res.json.data;
    var value = null;
    if (typeof data === 'string') {
      try { value = JSON.parse(host.aesDecrypt(data.replace(/\\/g, ''), KEY, IV, 'CBC', 'base64')); } catch (e) { value = null; }
    }
    if (value === null || typeof value !== 'object') throw new Error('瓜子体育: ' + path + ' 的回應無法解密');
    return value;
  }

  function pad(n) { return (n < 10 ? '0' : '') + n; }

  function score(remarks, home, visiting) {
    var h = parseInt(home.score, 10) || 0, v = parseInt(visiting.score, 10) || 0;
    return h > 0 || v > 0 ? remarks + ' 比分' + h + '-' + v : remarks;
  }

  return {
    init: function () { return ''; },

    homeContent: function () {
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }), null, {});
    },

    categoryContent: function (tid, page) {
      var pg = parseInt(page, 10) || 1;
      // One page, always: the API takes no page number.
      if (pg !== 1 || !QUERIES[tid]) return host.result.page([], pg, 1);
      var matches = api('sports', QUERIES[tid]);
      if (matches === null) return host.result.page([], 1, 1);
      if (!Array.isArray(matches)) throw new Error('瓜子体育: 賽事清單不是陣列');
      var since = host.now() - 86400000;
      var items = [];
      matches.forEach(function (m) {
        var at = m.match_time * 1000;
        if (at < since || !(m.m_status < 2)) return;
        var d = new Date(at);  // the device's own zone, as SimpleDateFormat's default
        var when = pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
        items.push({
          vod_id: String(m.mid),
          vod_name: m.home.name + ' vs ' + m.visiting.name,
          vod_pic: m.home.logo || '',
          vod_remarks: score(m.event_name + ' ' + when + ' ' + m.match_status_info, m.home, m.visiting)
        });
      });
      return host.result.page(items, 1, 1);
    },

    detailContent: function (ids) {
      var id = String(ids[0]);
      var m = api('detail', JSON.stringify({ mid: id }));
      if (m === null) return { list: [] };
      var status = score(String(m.match_status_info), m.home, m.visiting);
      return host.result.detail({
        vod_id: id,
        vod_name: m.home.name + ' vs ' + m.visiting.name,
        vod_pic: m.home.logo || '',
        vod_remarks: status,
        vod_content: status,
        vod_play_from: ' 瓜子 ',
        vod_play_url: (m.live_line || []).map(function (l) { return l.name + '$' + l.m3u8; }).join('#')
      });
    },

    /** The original has no search. */
    searchContent: function () { return host.result.list([]); },

    playerContent: function (flag, id) {
      return host.result.play(String(id), false, { 'User-Agent': 'Lavf/57.83.100', 'Referer': 'http://WJiZxLXA2.com/' });
    },

    isVideoFormat: host.isVideoFormat,
    manualVideoCheck: function () { return false; },
    destroy: function () {}
  };
})();

module.exports = spider;
