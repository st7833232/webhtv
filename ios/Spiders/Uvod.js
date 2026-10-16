/**
 * csp_Uvod — ported from `com.github.catvod.spider.Uvod` (custom_spider.jar, 223 lines).
 *
 * Every call is a POST whose body is `base64(AES-CBC(json)).base64(RSA(key))`: a fresh 32-character
 * key per request, IV `abcdefghijklmnop`, the key sealed with the site's RSA public key. The reply
 * has the same shape but its key is the server's own, so it opens only with the RSA **private** key
 * the original carries. A `x-signature` header is md5 of the request's parameters and timestamp.
 *
 * The host is fixed: the original assigns `ext` to a field its endpoint constants were already built
 * from, so `ext` never changes where it talks to (and this configuration sets none).
 *
 * IOS-POC-44G. Needs js.host 1.3 (RSA decryption).
 */
var spider = (function () {
  'use strict';

  var API = 'https://api-h5.uvod.tv';
  var IV = 'abcdefghijklmnop';
  var PUBLIC_KEY = 'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCeBQWotWOpsuPn3PAA+bcmM8YDfEOzPz7hb/vItV43vBJV2FcM72Hdcv3DccIFuEV9LQ8vcmuetld98eksja9vQ1Ol8rTnjpTpMbd4HedevSuIhWidJdMAOJKDE3AgGFcQvQePs80uXY2JhTLkRn2ICmDR/fb32OwWY3QGOvLcuQIDAQAB';
  var PRIVATE_KEY = 'MIICdwIBADANBgkqhkiG9w0BAQEFAASCAmEwggJdAgEAAoGBAJ4FBai1Y6my4+fc8AD5tyYzxgN8Q7M/PuFv+8i1Xje8ElXYVwzvYd1y/cNxwgW4RX0tDy9ya562V33x6SyNr29DU6XytOeOlOkxt3gd5169K4iFaJ0l0wA4koMTcCAYVxC9B4+zzS5djYmFMuRGfYgKYNH99vfY7BZjdAY68ty5AgMBAAECgYB1rbvHJj5wVF7Rf4Hk2BMDCi9+zP4F8SW88Y6KrDbcPt1QvOonIea56jb9ZCxf4hkt3W6foRBwg86oZo2FtoZcpCJ+rFqUM2/wyV4CuzlL0+rNNSq7bga7d7UVld4hQYOCffSMifyF5rCFNH1py/4Dvswmpi5qljf+dPLSlxXl2QJBAMzPJ/QPAwcf5K5nngQtbZCD3nqDFpRixXH4aUAIZcDzS1RNsHrT61mEwZ/thQC2BUJTQNpGOfgh5Ecd1MnURwsCQQDFhAFfmvK7svkygoKXt55ARNZy9nmme0StMOfdb4Q2UdJjfw8+zQNtKFOM7VhB7ijHcfFuGsE7UeXBe20ng/XLAkEAv9SoT2hgJaQxxUk4MCF8pgddstJlq8Z3uTA7JMa4x+kZfXTm/6TOo6I82VbXZLsYYe8op0lvsoHMFvBSBljV0QJBAKhxyoYRa98dZB5qZRskciaXTlge0WJkkA4vvh3/o757izRlQMgrKTfng1GVfIZFqKtnBiIDWTXQw2N9cnqXtH8CQAx+CD5tl1iT0cMdjvlMg2two3SnpOjpo7gALgumIDHAmsUWhocLtcrnJI032VQSUkNnLq9zEIfmHDz0TPVNHBQ=';
  var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  var PLAY_HEADERS = { 'User-Agent': UA, 'referer': 'https://www.uvod.tv/', 'origin': 'https://www.uvod.tv' };
  var CLASSES = [['101', '电视剧'], ['100', '电影'], ['106', '粤台专区'], ['102', '综艺'], ['103', '动漫'],
                 ['104', '体育'], ['105', '纪录片']];
  var QUALITY = { '4': '1080p', '3': '720p', '2': '480p', '1': '360p' };

  /** `b()`: the body, sealed under a fresh key that only travels RSA-encrypted. */
  function seal(json) {
    var key = host.random(32, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789');
    // Android `Base64.encodeToString(…, NO_PADDING)` for the cipher text, DEFAULT for the key.
    return host.aesEncrypt(json, key, IV, 'CBC').replace(/=+$/, '') + '.' + host.rsaEncrypt(key, PUBLIC_KEY);
  }

  /** `a()`: open a reply. Throws when it is not one, so a broken answer is never an empty page. */
  function open(body, path) {
    var parts = String(body || '').replace(/\s/g, '').split('.');
    var key = parts.length === 2 ? host.rsaDecrypt(parts[1], PRIVATE_KEY) : '';
    var json = key ? host.parseJSON(host.aesDecrypt(parts[0].replace(/\\/g, ''), key, IV, 'CBC')) : null;
    if (!json || typeof json !== 'object') throw new Error('Uvod: ' + path + ' 的回應無法解密');
    return json.data || {};
  }

  /** `URLEncoder.encode(s).toLowerCase()`: Java's form encoding, then the whole string lower-cased. */
  function javaEncode(s) {
    return encodeURIComponent(String(s)).replace(/%20/g, '+')
      .replace(/[!'()~]/g, function (c) { return '%' + c.charCodeAt(0).toString(16); }).toLowerCase();
  }

  function call(path, json, signed) {
    var ts = String(Date.now());
    var res = host.post(API + path, seal(json), { timeout: 20000, json: false, headers: {
      'User-Agent': UA, 'referer': 'https://www.uvod.tv/', 'origin': 'https://www.uvod.tv',
      'content-type': 'application/json', 'accept': '*/*',
      'x-signature': host.md5('-' + signed + '-' + ts), 'x-timestamp': ts, 'x-token': ''
    } });
    if (res.status !== 200 || !res.body) throw new Error('Uvod: ' + path + ' HTTP ' + res.status);
    return open(res.body, path);
  }

  function videos(data) {
    return (data.video_latest_list || data.video_list || []).map(function (v) {
      return { vod_id: String(v.id || ''), vod_name: v.title || '', vod_pic: v.pic || '',
               vod_remarks: (v.state || '') + (v.last_fragment_symbol || '') };
    });
  }

  function query(fields) {
    return '{"parent_category_id":' + fields.parent + ',"category_id":null,"language":null,"year":null,' +
      '"region":null,"state":null,"keyword":' + JSON.stringify(fields.keyword) + ',"paid":null,"page":' + fields.page +
      ',"pagesize":42,"sort_field":"","sort_type":"asc"' + (fields.fragment ? ',"need_fragment":1' : '') + '}';
  }

  return {
    init: function () { return ''; },

    homeContent: function () {
      var list = videos(call('/video/latest', '{"parent_category_id":101}', 'parent_category_id=101'));
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }), list, {});
    },

    categoryContent: function (tid, page) {
      var pg = String(page || '1');
      var list = videos(call('/video/list', query({ parent: JSON.stringify(String(tid)), keyword: '', page: pg }),
                             'page=' + pg + '&pagesize=42&parent_category_id=' + tid + '&sort_type=asc'));
      return host.result.page(list, pg, list.length < 42 ? parseInt(pg, 10) : 9999);
    },

    detailContent: function (ids) {
      var id = String(ids[0]);
      var data = call('/video/info', JSON.stringify({ id: id }), 'id=' + id);
      var v = data.video || data.video_soruce || {};
      var episodes = (data.video_fragment_list || []).map(function (f) {
        var qualities = (f.qualities || []).slice().sort(function (a, b) { return b - a; });
        return (f.symbol || '') + '$' + id + '|' + (f.id || '') + '|[' + qualities.join(', ') + ']';
      });
      return host.result.detail({
        vod_id: id, vod_name: v.title || '', vod_pic: v.pic || '', type_name: v.language || '',
        vod_year: v.year == null ? '' : String(v.year), vod_area: v.region || '', vod_remarks: v.state || '',
        vod_actor: v.starring || '', vod_director: v.director || '', vod_content: v.description || '',
        vod_play_from: 'Qile', vod_play_url: episodes.join('#')
      });
    },

    searchContent: function (key) {
      var list = videos(call('/video/list', query({ parent: 'null', keyword: String(key || ''), page: 1, fragment: true }),
                             'keyword=' + javaEncode(key) + '&need_fragment=1&page=1&pagesize=42&sort_type=asc'));
      return host.result.page(list, '1', 1);
    },

    /** One address per quality, best first, as `name, url, name, url` — what `PlayURL` reads. */
    playerContent: function (flag, id) {
      var parts = String(id).split('|');
      var urls = [];
      parts[2].replace(/[\[\]\s]/g, '').split(',').filter(Boolean).forEach(function (q) {
        var data = call('/video/source', '{"video_id":"' + parts[0] + '","video_fragment_id":' + parts[1] +
                        ',"quality":' + q + ',"seek":null}',
                        'quality=' + q + '&video_fragment_id=' + parts[1] + '&video_id=' + parts[0]);
        var url = (data.video || data.video_soruce || {}).url;
        if (url) urls.push(QUALITY[q] || q, url);
      });
      return host.result.play(urls, false, PLAY_HEADERS);
    },

    isVideoFormat: host.isVideoFormat,
    manualVideoCheck: function () { return true; },
    destroy: function () {}
  };
})();

module.exports = spider;
