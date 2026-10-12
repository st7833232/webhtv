/**
 * Gulu (咕噜) spider.
 * Port of com.github.catvod.spider.Gulu from qist spider.jar (IOS-POC-57B-3), on js.host 1.4.
 * Source host: http://103.45.132.22:19987/app/bn/v2, a private protobuf API: a P-256 handshake sealed
 * with AES-CBC over zlib, then every call AES-GCM over raw deflate under the HKDF-derived session key.
 * Only direct (http) lines are offered: the JAR's prefixed ids go to third-party parse services with
 * keys built into it, and the boot reply's templates point at the same services, so neither is used.
 */
(function () {
  'use strict';

  var API = 'http://103.45.132.22:19987/app/bn/v2';
  var UA = 'Dalvik/2.1.0 (Linux; U; Android 11; Pixel 4)';
  var TYPES = { movie: 8, tv: 9, variety: 10, anime: 11, short: 12, doc: 6,
                cn: 34, hk: 41, tw: 42, us: 35, kr: 36, jp: 38, th: 39, uk: 37, ru: 45 };
  var CLASSES = [['movie', '电影'], ['tv', '电视剧'], ['variety', '综艺'], ['anime', '动漫'], ['short', '短剧'],
                 ['doc', '纪录片'], ['cn', '大陆剧'], ['hk', '港剧'], ['tw', '台剧'], ['us', '美剧'], ['kr', '韩剧'], ['jp', '日剧']];
  var LINES = { dyttm3u8: '电影天堂', bfzym3u8: '暴风资源', lzm3u8: '量子资源', ffm3u8: '非凡资源', qq: '腾讯视频',
                qiyi: '爱奇艺', youku: '优酷', newxfyun: '咕噜4K', xfyun: '咕噜4K二线', CO4K: '咖啡4K超清',
                jplink: '金牌极速', rose: '玫瑰4K', NBY: '蚂蚁资源', qsvip: '旋风VIP', qingshan: '青山资源' };

  var deviceId = '';
  var session = null; // { id, key, booted }

  function text(value) { return value === null || value === undefined ? '' : String(value); }
  function utf8(array) { return array ? host.bytes.toUtf8(array) : ''; }
  function b64(array) { return host.bytes.toBase64(array); }
  function raw(base64) { return host.bytes.fromBase64(base64); }
  function hex(base64) {
    return raw(base64).map(function (b) { return (b < 16 ? '0' : '') + b.toString(16); }).join('');
  }

  function pageNumber(pg) {
    var s = text(pg);
    return /^[+-]?\d+$/.test(s) ? Math.max(1, parseInt(s, 10)) : 1;
  }

  // ---- protobuf: varints and length-delimited fields; anything malformed decodes to null (GULU-A-04) ----
  var MAX = 9007199254740991; // Number.MAX_SAFE_INTEGER: a varint above it would already be rounded

  function varint(n) {
    var out = [];
    while (n > 127) { out.push(n % 128 + 128); n = Math.floor(n / 128); }
    out.push(n);
    return out;
  }

  /** [[field, number | string | byte array]] in order: a number is a varint, the rest length-delimited. */
  function encode(fields) {
    var out = [];
    fields.forEach(function (f) {
      if (typeof f[1] === 'number') { out = out.concat(varint(f[0] * 8), varint(f[1])); return; }
      var bytes = typeof f[1] === 'string' ? host.bytes.fromUtf8(f[1]) : f[1];
      out = out.concat(varint(f[0] * 8 + 2), varint(bytes.length), bytes);
    });
    return out;
  }

  // At most 10 bytes, and checked before adding, so 2^53 and above are refused rather than rounded.
  function readVarint(bytes, at) {
    var value = 0, scale = 1;
    for (var i = 0; i < 10 && at.i < bytes.length; i++) {
      var b = bytes[at.i++], low = b & 0x7f;
      if (low > (MAX - value) / scale) return -1;
      value += low * scale;
      if (b < 0x80) return value;
      scale *= 128;
    }
    return -1;
  }

  /** The fields in order as { n, wt, v }: v is a number (wire type 0) or a byte array (wire type 2). */
  function decode(bytes) {
    if (!bytes) return null;
    var fields = [], at = { i: 0 };
    while (at.i < bytes.length) {
      var key = readVarint(bytes, at);
      if (key < 0) return null;
      var n = Math.floor(key / 8), wt = key % 8, v;
      if (wt === 0) {
        if ((v = readVarint(bytes, at)) < 0) return null;
        fields.push({ n: n, wt: 0, v: v });
      } else if (wt === 2) {
        if ((v = readVarint(bytes, at)) < 0 || v > bytes.length - at.i) return null;
        fields.push({ n: n, wt: 2, v: bytes.slice(at.i, at.i + v) });
        at.i += v;
      } else if (wt === 1 || wt === 5) {
        at.i += wt === 1 ? 8 : 4;
        if (at.i > bytes.length) return null;
      } else {
        return null;
      }
    }
    return fields;
  }

  function field(fields, n) {
    for (var i = 0; fields && i < fields.length; i++) if (fields[i].n === n && fields[i].wt === 2) return fields[i].v;
    return null;
  }

  // ---- transport (Gulu.java GuluCrypto) ---------------------------------------------------------------
  function headers(extra) {
    var out = { 'User-Agent': UA, 'X-Player-Page-Protection': '1' };
    Object.keys(extra).forEach(function (k) { out[k] = extra[k]; });
    return out;
  }

  // A fresh P-256 key, sent zlib-wrapped and AES-256-CBC sealed under a random 32-hex-character key whose
  // UTF-8 bytes are the AES key; the reply's session id salts HKDF over the ECDH secret (Gulu.java:223–301).
  function handshake() {
    var pair = host.ecdhP256Generate();
    var keyText = hex(host.randomBytes(16)), iv = host.randomBytes(16);
    if (!pair || keyText.length !== 32 || !iv) return null;
    var key = b64(host.bytes.fromUtf8(keyText));
    var hello = encode([[1, raw(pair.publicKey)], [2, '1.0.0'], [3, encode([[1, 1], [2, 1], [3, 1]])]]);
    var sealed = host.aesCbc(true, key, iv, host.deflate(b64(hello), true));
    if (!sealed) return null;
    var res = host.req(API, { method: 'POST', body: b64(raw(iv).concat(raw(sealed))), timeout: 15000,
                              headers: headers({ 'Content-Type': 'text/plain', 'X-Handshake-Key': keyText }) });
    var reply = res.status >= 200 && res.status < 300 ? raw(res.body) : [];
    if (reply.length < 32) return null;
    var plain = host.aesCbc(false, key, b64(reply.slice(0, 16)), b64(reply.slice(16)));
    var fields = plain ? decode(raw(host.inflate(plain, true))) : null;
    var id = utf8(field(fields, 1)), peer = field(fields, 2);
    if (!id || !peer) return null;
    var secret = host.ecdhP256Derive(pair.handle, b64(peer));
    var sessionKey = secret ? host.hkdfSha256(secret, b64(host.bytes.fromUtf8(id)), b64(host.bytes.fromUtf8('v2-session')), 32) : '';
    return sessionKey ? { id: id, key: sessionKey, booted: false } : null;
  }

  /** One API call: its result (field 4 of the opened reply) as bytes, or null (Gulu.java:161–221). */
  function callApi(group, method, payload) {
    if (!session) return null;
    var now = Date.now();
    var inner = encode([[1, now], [2, group], [3, method], [4, deviceId], [5, []], [6, payload], [7, now]]);
    var sealed = host.aesGcmSeal(session.key, host.deflate(b64(inner), false));
    if (!sealed) return null;
    var res = host.req(API, { method: 'POST', bodyBase64: b64(encode([[1, now], [2, raw(sealed)]])), responseType: 'base64',
                              timeout: 15000, headers: headers({ 'Content-Type': 'application/x-protobuf', 'X-Session-Id': session.id }) });
    if (res.status < 200 || res.status >= 300 || !res.bodyBase64) return null;
    var combined = field(decode(raw(res.bodyBase64)), 2);
    if (!combined || combined.length < 28) return null;
    var opened = host.aesGcmOpen(session.key, b64(combined));
    var plain = opened ? host.inflate(opened, false) : '';
    return plain ? field(decode(raw(plain)), 4) : null;
  }

  // The JAR's app and device identity; the reply's parse templates (field 7) are deliberately ignored.
  function bootPayload() {
    var app = encode([[1, '咕噜咕噜'], [2, '2.1.2'], [3, 'com.jymqfh.xee'], [4, deviceId], [5, '212']]);
    var device = encode([[1, deviceId], [2, 0], [3, '11'], [4, 'Pixel 4'], [5, 'google/redfin/redfin:11/RQ3A.211001.001'],
                         [6, 'google'], [7, 'redfin'], [8, 0], [9, 'unknown'], [10, 'unknown'], [11, 0], [12, 30]]);
    return encode([[1, 'v1'], [2, 'Android 11'], [3, 'gulu'], [4, app], [5, device]]);
  }

  // As the JAR: handshake and boot until one boot answers; a failed boot keeps the session for this call.
  function ensure() {
    if (session && session.booted) return;
    session = handshake();
    if (session) session.booted = callApi(1, 0, bootPayload()) !== null;
  }

  // ---- results (Gulu.java:533–636, 686–846) -----------------------------------------------------------
  function item(bytes) {
    var vod = { vod_id: '', vod_name: '', vod_pic: '', vod_remarks: '' };
    (decode(bytes) || []).forEach(function (f) {
      if (f.wt === 0) {
        if (f.n === 1) vod.vod_id = String(f.v);
      } else if (f.n === 3) {
        vod.vod_name = utf8(f.v);
      } else if (f.n === 6) {
        vod.vod_pic = utf8(f.v);
      } else if (f.n === 11 || (f.n === 9 && !vod.vod_remarks)) {
        vod.vod_remarks = utf8(f.v);
      }
    });
    return vod.vod_id && vod.vod_name ? vod : null;
  }

  /** A listing's items in the JAR's three shapes: under field 66, the entry itself, or under field 3. */
  function items(bytes, limit) {
    var list = [], outer = decode(bytes) || [];
    function add(vod) { if (vod) list.push(vod); }
    for (var k = 0; k < outer.length && list.length < limit; k++) {
      if (outer[k].wt !== 2 || outer[k].v.length < 30) continue;
      var inner = decode(outer[k].v) || [];
      var nested = inner.filter(function (g) { return g.n === 66 && g.wt === 2; });
      if (nested.length) {
        nested.forEach(function (g) { add(item(g.v)); });
      } else if (inner.some(function (g) { return g.n === 2 && g.wt === 0; })) {
        add(item(outer[k].v));
      } else {
        inner.forEach(function (g) { if (g.n === 3 && g.wt === 2 && g.v.length > 30) add(item(g.v)); });
      }
    }
    return list.slice(0, limit);
  }

  /** Field 75: a line code and its episodes { 1: number, 3: play id, 4: name }. */
  function line(bytes) {
    var code = '', episodes = [];
    (decode(bytes) || []).forEach(function (f) {
      if (f.n === 1 && f.wt === 2) code = utf8(f.v);
      if (f.n !== 2 || f.wt !== 2 || f.v.length <= 10) return;
      var no = '', id = '', name = '';
      (decode(f.v) || []).forEach(function (e) {
        if (e.n === 1 && e.wt === 0) no = String(e.v);
        else if (e.n === 3 && e.wt === 2) id = utf8(e.v);
        else if (e.n === 4 && e.wt === 2) name = utf8(e.v);
      });
      if (id) episodes.push([name || '第' + no + '集', id]);
    });
    return { code: code, episodes: episodes };
  }

  // The JAR asks for a higher bitrate of an m3u8 by rewriting its path (Gulu.java:638–647).
  function upgrade(url) {
    return url.indexOf('.m3u8') < 0 ? url :
      url.replace(/\/\d{3,4}k[bB]?\//g, '/2000k/').replace(/index_\d+k/g, 'index_2000k').replace(/\/720[pP]\//g, '/1080p/');
  }

  function listing(list, page, full) {
    return host.result.page(list, page, list.length >= full ? page + 1 : page, Math.max(list.length, 12), list.length);
  }

  var spider = {
    init: function (extend) {
      deviceId = hex(host.randomBytes(8));
      return '';
    },

    homeContent: function (filter) {
      var years = [{ n: '全部', v: '' }];
      for (var y = 2026; y >= 2010; y--) years.push({ n: String(y), v: String(y) });
      years.push({ n: '更早', v: '2009' });
      var sorts = [{ n: '最热', v: 'vod_hits_week' }, { n: '最新', v: 'vod_time' }, { n: '评分', v: 'vod_score' }];
      var filters = {};
      CLASSES.forEach(function (c) {
        filters[c[0]] = [{ key: 'year', name: '年份', init: '', value: years },
                         { key: 'sort', name: '排序', init: 'vod_hits_week', value: sorts }];
      });
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }), null, filters);
    },

    homeVideoContent: function () {
      ensure();
      return host.result.list(items(callApi(3, 66, encode([[1, 9], [2, 1]])), 24));
    },

    categoryContent: function (tid, pg, filter, extend) {
      ensure();
      var page = pageNumber(pg), ext = extend || {};
      var type = Object.prototype.hasOwnProperty.call(TYPES, tid) ? TYPES[tid] : 9;
      var query = [[1, type], [2, page]];
      if (ext.year) query.push([3, text(ext.year)]);
      if (ext.sort) query.push([5, encode([[1, 1], [2, 0], [3, text(ext.sort)]])]);
      return listing(items(callApi(3, 66, encode(query)), 100), page, type >= 8 && type <= 12 ? 10 : type === 6 ? 3 : 2);
    },

    detailContent: function (ids) {
      var id = text(ids && ids[0]);
      if (!/^\d+$/.test(id) || Number(id) > MAX) return host.result.list([]);
      ensure();
      var fields = decode(callApi(3, 62, encode([[1, Number(id)], [4, 'APP_PLATFORM_ANDROID_TV'], [5, 0]])));
      if (!fields || !fields.length) return host.result.list([]);
      var vod = { vod_id: id }, actors = [], directors = [], types = [], from = [], urls = [], seen = {};
      var keys = { 5: 'vod_name', 13: 'vod_pic', 21: 'vod_content', 22: 'vod_remarks', 28: 'vod_area', 30: 'vod_year' };
      var lists = { 17: actors, 18: directors, 12: types };
      function addLine(group) {
        // Direct lines only: a prefixed id would need the JAR's keyed third-party parse services.
        var episodes = group.episodes.filter(function (e) { return e[1].indexOf('http') === 0; })
          // A "$" or "#" in a name would split the play list into extra episodes (as in Bili.js).
          .map(function (e) { return (e[0].replace(/[$#]/g, ' ').trim() || '播放') + '$' + e[1]; });
        if (!episodes.length) return;
        var name = Object.prototype.hasOwnProperty.call(LINES, group.code) ? LINES[group.code] : group.code;
        if (seen[name]) name += '2';
        seen[name] = true;
        from.push(name);
        urls.push(episodes.join('#'));
      }
      fields.forEach(function (f) {
        if (f.wt !== 2) return;
        if (keys[f.n]) vod[keys[f.n]] = utf8(f.v);
        else if (lists[f.n]) lists[f.n].push(utf8(f.v));
        else if (f.n === 75) addLine(line(f.v));
      });
      vod.vod_actor = actors.slice(0, 12).join('、');
      vod.vod_director = directors.join('、');
      vod.type_name = types.slice(0, 4).join('/');
      vod.vod_play_from = from.join('$$$');
      vod.vod_play_url = urls.join('$$$');
      return host.result.detail(vod);
    },

    // shortcut: one call; the JAR retries a short (≤200 B) reply twice after 0.5 s and 1 s, which needs
    // a host sleep this runtime does not offer. Add the retries if search proves flaky live.
    searchContent: function (key, quick, pg) {
      ensure();
      var page = pageNumber(pg);
      var reply = callApi(3, 61, encode([[1, text(key)], [2, page], [5, encode([[1, 1], [2, 0], [3, 'vod_hits_week']])]]));
      return listing(reply && reply.length >= 200 ? items(reply, 100) : [], page, 10);
    },

    playerContent: function (flag, id, vipFlags) {
      var url = text(id);
      if (url.indexOf('http') !== 0) return host.result.play('', false);
      // An m3u8 (or the m.php relay) plays directly; anything else is a page to sniff.
      var direct = url.indexOf('.m3u8') >= 0 || url.indexOf('m.php') >= 0;
      return host.result.play(upgrade(url), !direct, { 'User-Agent': UA });
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
