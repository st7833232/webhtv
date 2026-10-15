/**
 * csp_AppDrama — ported from `com.github.catvod.spider.AppDrama` (river-fman.jar, 435 lines).
 *
 * A 苹果CMS-style app backend that speaks protobuf. Every listing, detail, search and play-address
 * call is a POST of `SecureRequest` bytes and answers `ApiResult` bytes whose `data` is the page;
 * only the category list and the home tags are JSON. Each request also carries `publicParams`:
 * the device JSON, signed with RSA (PKCS#1, the ext's `publicKey` or the key the zone handshake
 * returns) and AES-ECB under `dataIv`, then AES-128-CBC encrypted and written as **hex**.
 *
 * Field numbers are the ones `com/base/model/proto/*` in the same JAR declares. The handshake in
 * `init` is the original's: when it fails the ext's key is used, which is what the original falls
 * back to as well (measured 2026-10-02: the server answers "RSA解密失败" and keeps serving).
 *
 * IOS-POC-44G. Needs js.host 1.3 (RSA, binary HTTP, AES hex output).
 */
var spider = (function () {
  'use strict';

  var CBC_KEY = 'ed5fdsgucxumegqa';
  var MEDIA = /\.(mp4|m3u8|flv|mkv|avi|ts|mov|mpd|m4a|wmv)(\?.*)?$/i;
  var FILTER_NAMES = { 'class': '類型', lang: '語言', area: '地區', year: '年份', extend_sort: '排序' };
  var cfg = {}, api = '', zoneKey = '';

  // ---- protobuf (proto3: varint and length-delimited are all these messages use) ----------------
  function varint(n) {
    var out = [];
    while (n > 127) { out.push((n % 128) | 128); n = Math.floor(n / 128); }
    out.push(n);
    return out;
  }
  function encode(fields) {
    var out = [];
    fields.forEach(function (f) {
      if (typeof f[1] === 'number') { out = out.concat(varint(f[0] * 8), varint(f[1])); return; }
      var bytes = host.bytes.fromUtf8(f[1]);
      out = out.concat(varint(f[0] * 8 + 2), varint(bytes.length), bytes);
    });
    return out;
  }
  /** Field number → list of values: a number for a varint, a byte array for anything delimited. */
  function decode(bytes) {
    var fields = {}, i = 0;
    function read() {
      var n = 0, scale = 1, b;
      do { b = bytes[i++]; n += (b & 127) * scale; scale *= 128; } while (b & 128 && i < bytes.length);
      return n;
    }
    while (i < bytes.length) {
      var key = read(), number = Math.floor(key / 8), type = key % 8, value;
      if (type === 0) value = read();
      else if (type === 2) { var length = read(); value = bytes.slice(i, i + length); i += length; }
      else if (type === 1) { i += 8; continue; }
      else if (type === 5) { i += 4; continue; }
      else break;
      (fields[number] = fields[number] || []).push(value);
    }
    return fields;
  }
  function text(fields, n) { var v = (fields[n] || [])[0]; return v === undefined ? '' : (typeof v === 'number' ? String(v) : host.bytes.toUtf8(v)); }
  function messages(fields, n) { return (fields[n] || []).map(decode); }

  // ---- request signing -------------------------------------------------------------------------
  function random(n) { return host.random(n - 1, '1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz') + '='; }

  /** `d()`: the device the original reports. Android's own values become a fixed, plausible phone. */
  function device() {
    var uuid = host.random(32, '0123456789ABCDEF');
    return {
      country: 'CN', vName: cfg.version || '', cpuId: 'MT6893Z%2FCZA', young: 0, facturer: 'Xiaomi',
      pkg: cfg.pkg || '', uuid: uuid, resolution: '1080x2272', mac: '02%3A00%3A00%3A00%3A00%3A00', abid: '397',
      model: 'M2012K11AC', plat: 'android', udid: uuid, dpi: '440', net: '1', lang: 'zh', brand: 'Redmi',
      density: '2.75', appName: cfg.appName || '', cpu: 'arm64-v8a', chid: '10000',
      carrier: '%E8%81%94%E9%80%9A', _vOsCode: 33, vOs: '13', v: 1, tenantId: '',
      vApp: String(cfg.version || '').replace(/\./g, ''), device: 0, androidID: host.random(16, '0123456789abcdef')
    };
  }

  function publicParams(json) {
    return JSON.stringify({ paramsData: host.aesEncrypt(JSON.stringify(json), CBC_KEY, CBC_KEY, 'CBC', 'hex') });
  }

  /** `c()`: headers for a protobuf call, with the RSA and ECB signatures in the device JSON. */
  function protoHeaders() {
    var json = device(), ts = Date.now(), nonce = random(16);
    var sig2 = host.aesEncrypt(ts + nonce, cfg.dataIv || '', '', 'ECB');
    json.sig = host.rsaEncrypt(ts + nonce + (json.vApp || '3019'), zoneKey || cfg.publicKey || '');
    json.random_str = nonce;
    json.timestamp = ts;
    json.sig2 = sig2.substring(0, 8);
    json.sig3 = sig2.substring(8);
    return { 'User-Agent': 'okhttp/3.12.1', 'Accept': 'application/x-protobuf',
             'Content-Type': 'application/x-protobuf', 'publicParams': publicParams(json) };
  }

  /** `e()`: headers for a JSON call. */
  function jsonHeaders() {
    return { 'User-Agent': 'okhttp/3.12.1', 'Accept': 'application/json',
             'Content-Type': 'application/json; charset=utf-8', 'publicParams': publicParams(device()) };
  }

  /** `g(map)`: the query, AES-ECB under `dataKey`, split across `SecureRequest`'s first two fields. */
  function secureRequest(params) {
    var ts = Date.now(), nonce = random(8);
    var query = Object.keys(params).filter(function (k) { return params[k]; })
      .map(function (k) { return k + '=' + params[k]; }).join('&');
    var sealed = nonce + host.aesEncrypt(query + ts, cfg.dataKey || '', '', 'ECB');
    return encode([[1, sealed.substring(0, 20)], [2, sealed.substring(20)], [3, random(20)], [4, ts], [5, nonce]]);
  }

  /** POST protobuf, answer `ApiResult.data` decoded; throws on a transport or envelope failure. */
  function proto(path, body) {
    var res = host.req(api + path, { method: 'POST', headers: protoHeaders(), bodyBase64: host.bytes.toBase64(body),
                                     responseType: 'base64', timeout: 20000 });
    if (res.status !== 200 || !res.bodyBase64) throw new Error('AppDrama: ' + path + ' HTTP ' + res.status);
    var envelope = decode(host.bytes.fromBase64(res.bodyBase64));
    if (!envelope[3]) throw new Error('AppDrama: ' + path + ' ' + (text(envelope, 2) || 'no data'));
    return decode(envelope[3][0]);
  }

  function dramas(page) {
    return messages(page, 1).map(function (d) {
      var cover = messages(d, 2)[0] || {};
      return { vod_id: text(d, 3), vod_name: text(d, 5), vod_pic: text(cover, 2), vod_remarks: text(d, 13) };
    });
  }

  function ecbDecrypt(data, key) { return host.aesDecrypt(data, key, '', 'ECB'); }

  return {
    init: function (extend) {
      try { cfg = JSON.parse(String(extend || '{}')) || {}; } catch (e) { cfg = {}; }
      api = cfg.host || '';
      zoneKey = '';
      if (cfg.site) {
        var site = host.get(cfg.site, { timeout: 15000 });
        var domain = site.json && site.json.domain;
        if (domain) api = String(domain);
      }
      api = api.replace(/\/+$/, '');
      // The zone handshake: its key replaces the ext's when the server gives one. The original's
      // `d` stays empty on failure and signs with the ext's key, so a failure here is not an error.
      try {
        var ts = Date.now(), nonce = random(16);
        var zone = proto('/api/v5/find/app/zone', encode([[1, ts], [2, host.rsaEncrypt(ts + nonce, cfg.publicKey || '')],
                                                         [3, random(16)], [4, nonce], [5, random(16)]]));
        zoneKey = text(zone, 2) + text(zone, 3) + text(zone, 4) + text(zone, 5);
      } catch (e) { zoneKey = ''; }
      return '';
    },

    homeContent: function (filter) {
      var res = host.get(api + '/api/v3/drama/getCategory?orderBy=type_id', { headers: jsonHeaders(), timeout: 20000 });
      var classes = [], filters = {};
      ((res.json && res.json.data) || []).forEach(function (c) {
        if (c.name === '公告') return;
        var id = String(c.id);
        classes.push({ type_id: id, type_name: c.name });
        var extra = null;
        try { extra = c.converUrl ? JSON.parse(c.converUrl) : null; } catch (e) { extra = null; }
        if (!extra) return;
        var rows = ['class', 'lang', 'area', 'year', 'extend_sort'].filter(function (k) { return extra[k]; })
          .map(function (k) {
            return { key: k, name: FILTER_NAMES[k], value: String(extra[k]).split(',').map(function (v) { return { n: v, v: v }; }) };
          });
        if (rows.length) filters[id] = rows;
      });
      return host.result.home(classes, null, filter ? filters : undefined);
    },

    homeVideoContent: function () {
      var res = host.get(api + '/api/ex/v3/security/tag/list', { headers: jsonHeaders(), timeout: 20000 });
      var data = res.json && res.json.data;
      if (!data) return host.result.list([]);
      if (typeof data === 'string' && String(cfg.decrypt) !== '0') data = ecbDecrypt(ecbDecrypt(data, cfg.dataKey), cfg.dataIv);
      if (typeof data === 'string') data = host.parseJSON(data) || [];
      var items = [];
      (data || []).forEach(function (tag) {
        (tag.sections || []).forEach(function (section) {
          (section.vodList || []).forEach(function (v) {
            items.push({ vod_id: String(v.id), vod_name: v.name, vod_pic: (v.coverImage || {}).path || '', vod_remarks: v.remark || '' });
          });
        });
      });
      return host.result.list(items);
    },

    categoryContent: function (tid, page, filter, extend) {
      extend = extend || {};
      var pg = String(page || '1');
      var list = dramas(proto('/api/proto/v5/drama/category', secureRequest({
        pagesize: '21', typeId1: String(tid), page: pg, vodOrderBy: extend.extend_sort || '最新',
        vodArea: extend.area || '', vodLang: extend.lang || '', vodClass: extend['class'] || '', vodYear: extend.year || ''
      })));
      return host.result.page(list, pg, list.length ? 9999 : parseInt(pg, 10));
    },

    detailContent: function (ids) {
      var id = String(ids[0]);
      var d = proto('/api/proto/v5/drama/getDetail', secureRequest({ id: id }));
      var lines = {}, order = [];
      messages(d, 29).forEach(function (v) {
        var from = text(v, 10) || '橘汁', path = text(v, 4);
        if (!MEDIA.test(path)) path = host.base64.encode(JSON.stringify({ vodPlayFrom: text(v, 9), playUrl: path }));
        if (!lines[from]) { lines[from] = []; order.push(from); }
        lines[from].push(text(v, 2) + '$' + path);
      });
      var cover = messages(d, 2)[0] || {};
      return host.result.detail({
        vod_id: id, vod_name: text(d, 9), vod_pic: text(cover, 2) || text(cover, 1), type_name: text(d, 13),
        vod_area: text(d, 1), vod_year: text(d, 18), vod_remarks: text(d, 26), vod_actor: text(d, 25),
        vod_director: '', vod_content: text(d, 6),
        vod_play_from: order.join('$$$'),
        vod_play_url: order.map(function (k) { return lines[k].join('#'); }).join('$$$')
      });
    },

    searchContent: function (key, quick, page) {
      var pg = String(page || '1');
      return host.result.page(dramas(proto('/api/proto/v5/drama/search',
        secureRequest({ searchKeys: String(key || ''), page: pg, pagesize: '21' }))), pg);
    },

    playerContent: function (flag, id) {
      if (MEDIA.test(id)) return host.result.play(id, false, {});
      var params = JSON.parse(host.base64.decode(id));
      var parsed = proto('/api/proto/v5/videoUsableUrl', secureRequest(params));
      var headers = {};
      messages(parsed, 6).forEach(function (entry) { headers[text(entry, 1)] = text(entry, 2); });
      // Some lines' parser answers its own opaque token rather than an address (`zijian_…`, `vwnet-…`,
      // measured 2026-10-06); the original hands that to the player, which fails on it. An empty
      // URL lets the app say there is nothing to play instead. Headers are handed over even when
      // empty, as the original does.
      var url = text(parsed, 1);
      return host.result.play(/^https?:\/\//i.test(url) ? url : '', false, headers);
    },

    isVideoFormat: host.isVideoFormat,
    manualVideoCheck: function () { return true; },
    destroy: function () { api = ''; zoneKey = ''; }
  };
})();
module.exports = spider;
