/**
 * Yidong4K (移动4K) spider.
 * Port of com.github.catvod.spider.Yidong4K from spider.jar (W-266; triage W-255 `artifacts/w255/spider-jar-triage.md`).
 * Source host: https://vidsite.cloudseekr.com (JSON POST). Every title is one public 139 cloud share (yun.139.com).
 *
 * Upstream hands the share to its `Pan` base, whose 139 resolver (merge.b.P) lists the share anonymously and plays a
 * file's HLS. Only that resolver is ported, here, because it is the only kind of link the site gives (W-266 sample of
 * twelve titles over three categories, 2026-11-09). Differences, all deliberate (docs/W-266-spider-jar-port-7.md):
 * - A share that is not a 139 link lists no line; other cloud drives are never driven.
 * - Play returns the share's own master playlist and lets the player pick a rendition; upstream rewrote it into its
 *   own 2160/1080/720/480 list and pointed danmaku at TVBox's local proxy.
 * - Folders are walked at most three levels deep; episode labels carry the folder only when files sit in more than one.
 */
(function () {
  'use strict';

  var API = 'https://vidsite.cloudseekr.com/vidsite/vs/';
  var HEADERS = {
    'Origin': 'https://vidsite.cloudseekr.com',
    'Accept': 'application/json, text/plain, */*',
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36',
    'Referer': 'https://vidsite.cloudseekr.com/vid/app/',
    'Content-Type': 'application/json; charset=utf-8'
  };
  var CLASSES = [['1', '电影'], ['2', '电视剧'], ['3', '动漫']];
  var SHARE = 'https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IOutLink/';
  var SHARE_KEY = 'PVGDwmcvfs1uV3d1';
  var SHARE_HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    'Content-Type': 'application/json;charset=UTF-8',
    'Referer': 'https://yun.139.com/',
    'x-deviceinfo': '||3|12.27.0|chrome|131.0.0.0|1||windows 10|546X902|zh-CN|||',
    'hcy-cool-flag': '1',
    'authorization': ''
  };
  var LINE = '移动云盘';
  var VIDEO = /\.(mp4|mkv|avi|rmvb|rm|flv|mov|ts|m2ts|wmv|webm|m4v|mpg|mpeg|3gp|vob)$/i;
  var fprint = '';

  function text(v) { return v === null || v === undefined ? '' : String(v); }
  function pageNumber(pg) { var n = parseInt(pg, 10); return n > 1 ? n : 1; }
  function call(path, body) {
    var json = host.post(API + path, JSON.stringify(body), { headers: HEADERS }).json;
    return json && json.code === '000000' ? json : null;
  }
  function page(body, n) {
    var res = call('qryPageColumnVideo', body), data = res && res.data;
    if (!data) return host.result.page([], n, n, 9, 0);
    var list = (data.list || []).map(function (v) {
      return { vod_id: text(v.id), vod_name: text(v.title), vod_pic: text(v.appCoverUrl), vod_remarks: '' };
    }).filter(function (v) { return /^\d+$/.test(v.vod_id); });
    return host.result.page(list, n, parseInt(data.pages, 10) || n, 9, parseInt(data.total, 10) || list.length);
  }

  // ---- 139 public share (upstream merge.b.P) ---------------------------------------------------------------------
  function linkOf(url) { return host.match(url, 'yun\\.139\\.com/.*/w/i/([A-Za-z0-9]+)'); }
  function folder(link, parent) {
    var body = { getOutLinkInfoReq: { account: '', linkID: link, passwd: '', caSrt: 1, coSrt: 1, srtDr: 0, bNum: 1,
                                      pCaID: parent, eNum: 200 } };
    var res = host.post(SHARE + 'getOutLinkInfoV6', host.aesEncryptIV(JSON.stringify(body), SHARE_KEY),
                        { headers: SHARE_HEADERS, json: false });
    var json = host.parseJSON(host.aesDecryptIV(text(res.body).trim(), SHARE_KEY));
    return json && String(json.resultCode) === '0' && json.data ? json.data : null;
  }
  function size(bytes) {
    var n = Number(bytes) || 0;
    return n >= 1073741824 ? (n / 1073741824).toFixed(2) + ' GB' : (n / 1048576).toFixed(2) + ' MB';
  }
  function files(link, parent, dir, depth, out) {
    var data = folder(link, parent);
    if (!data) return out;
    (data.coLst || []).forEach(function (f) {
      if (VIDEO.test(text(f.coName)) && /^[\w-]+$/.test(text(f.coID))) out.push({ dir: dir, name: text(f.coName), id: text(f.coID), size: f.coSize });
    });
    if (depth < 3) (data.caLst || []).forEach(function (c) { files(link, text(c.path), text(c.caName), depth + 1, out); });
    return out;
  }
  function episodes(link) {
    var list = files(link, 'root', '', 1, []);
    var dirs = {};
    list.forEach(function (f) { dirs[f.dir] = true; });
    var many = Object.keys(dirs).length > 1;
    return list.map(function (f) {
      var label = (many && f.dir ? '[' + f.dir + ']' : '') + f.name.replace(/\.[^.]+$/, '') + ' [' + size(f.size) + ']';
      return label.replace(/[$#]/g, ' ') + '$' + link + '+' + f.id;
    }).join('#');
  }

  var spider = {
    // Upstream's device fingerprint: one md5 per session, sent with every detail request.
    init: function () {
      fprint = host.md5('AiNewYiDong4K_' + host.now() + '_' + Math.random());
      return '';
    },

    homeContent: function (filter) {
      return host.result.home(CLASSES.map(function (c) { return { type_id: c[0], type_name: c[1] }; }));
    },

    categoryContent: function (tid, pg, filter, extend) {
      var n = pageNumber(pg), id = text(tid);
      if (!/^\d+$/.test(id)) return host.result.page([], n, n, 9, 0);
      return page({ columnId: parseInt(id, 10), cateIdList: [0, 0, 0], pageIndex: n, pageSize: 9 }, n);
    },

    detailContent: function (ids) {
      var id = text(ids && ids[0]);
      if (!/^\d+$/.test(id)) return host.result.list([]);
      var body = { videoId: parseInt(id, 10), fprint: fprint };
      // The site serves a title's share only after the visit is recorded, as upstream does.
      var res = call('addAccessRecord', body) && call('qryVideoDetail', body), v = res && res.data;
      if (!v) return host.result.list([]);
      var link = linkOf(v.resUrl), eps = link ? episodes(link) : '';
      return host.result.detail({
        vod_id: text(v.id) || id, vod_name: text(v.title), vod_pic: text(v.appCoverUrl), vod_content: text(v.remark),
        type_name: (v.cateNameList || []).join(','), vod_actor: text(v.actor), vod_director: text(v.director),
        vod_remarks: v.score ? String(v.score) : '',
        vod_play_from: eps ? LINE : '', vod_play_url: eps
      });
    },

    searchContent: function (key, quick, pg) {
      var wd = text(key).trim(), n = pageNumber(pg);
      if (!wd) return host.result.list([]);
      return page({ columnId: 0, cateIdList: [0, 0, 0], pageIndex: n, pageSize: 9, searchKey: wd }, n);
    },

    // linkID+contentId -> the file's HLS master playlist, anonymously.
    playerContent: function (flag, id, vipFlags) {
      var m = /^([A-Za-z0-9]+)\+([\w-]+)$/.exec(text(id));
      if (!m) return host.result.play('', false);
      var body = { getContentInfoFromOutLinkReq: { contentId: m[2], linkID: m[1], account: '' },
                   commonAccountInfo: { account: '', accountType: 1 } };
      var json = host.post(SHARE + 'getContentInfoFromOutLink', JSON.stringify(body),
                           { headers: { 'User-Agent': SHARE_HEADERS['User-Agent'], 'Referer': 'https://yun.139.com/',
                                        'Content-Type': 'application/json' } }).json;
      var url = text(json && json.data && json.data.contentInfo && json.data.contentInfo.presentURL);
      return host.result.play(/^https?:\/\//.test(url) ? url : '', false);
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
