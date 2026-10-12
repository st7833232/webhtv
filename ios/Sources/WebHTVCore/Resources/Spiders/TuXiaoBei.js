/**
 * TuXiaoBei (兔小贝) spider.
 * Port of com.github.catvod.spider.TuXiaoBei from qist spider.jar (IOS-POC-57B-2).
 * Source host: https://www.tuxiaobei.com
 */
(function () {
  'use strict';

  var BASE = 'https://www.tuxiaobei.com/';
  // The JAR's desktop UA now gets 404 for the list and subject pages; the mobile one is served (TXB-04).
  var HEADERS = {
    'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
    'Referer': 'https://www.tuxiaobei.com/'
  };
  var CATEGORIES = [['2', '大类·儿歌'], ['3', '大类·故事'], ['4', '大类·国学'], ['25', '大类·启蒙']];
  var SUBJECTS = [
    ['17', '兔小贝原创儿歌'], ['16', '睡前儿歌'], ['1', 'Everybody动起来'], ['2', '爸爸妈妈小时候的儿歌'], ['3', '宝宝吃饭香'],
    ['4', '乖宝宝不哭闹'], ['5', '好宝宝爱上学'], ['6', '欢快儿歌'], ['9', '经典儿歌'], ['10', '快乐的节日'],
    ['11', '快乐的童年'], ['12', '流行儿歌'], ['13', '美丽四季'], ['14', '男孩最爱'], ['15', '女孩最爱'],
    ['19', '我爱爸爸妈妈'], ['20', '我的动物朋友'], ['21', '我的祖国和我'], ['22', '舞蹈音乐'], ['23', '英文儿歌'],
    ['24', '粤语儿歌'], ['25', '早教好习惯'], ['56', '放暑假啦'], ['57', '我能照顾好自己'], ['58', '画一个梦'],
    ['59', '哆啦A梦的神奇口袋'], ['60', '你是我的小天使'], ['61', '最动听的笑声'], ['62', '许个愿吧'], ['63', '阳光下的我们'],
    ['89', '智慧成语故事'], ['90', '名人成语故事'], ['88', '励志成语故事'], ['87', '神话成语故事'], ['39', '古诗启蒙'],
    ['43', '三字经'], ['46', '弟子规'], ['48', '千字文'], ['54', '十万个为什么'], ['55', '神奇的大自然'],
    ['50', '英语宝典'], ['51', '数学课堂'], ['53', '动物奇缘'], ['84', '安全教育']
  ];
  var ITEM = /href="\/play\/(\d+)"[\s\S]*?mip-img[^>]+src="([^"]+)"[\s\S]*?class="title">([^<]+)<\/p>[\s\S]*?class="time">([^<]+)<\/span>/gi;

  // Only a 200 is read, so an error page is never parsed as content.
  function fetch(path) {
    var res = host.get(BASE + path, { headers: HEADERS, timeout: 15000 });
    return res.status === 200 ? String(res.body || '') : '';
  }

  function text(value) { return value === null || value === undefined ? '' : String(value); }
  function absolute(src) { return src.indexOf('//') === 0 ? 'https:' + src : src; }
  function first(html, pattern) { var m = pattern.exec(html); return m ? m[1].trim() : ''; }

  // Upstream's `id|||typeId` splits one video's watch history by entry point; the bare id is the key (TXB-09).
  function videoId(id) { return text(id).split('|||')[0]; }

  function pageNumber(pg) {
    var s = text(pg);
    return /^[+-]?\d+$/.test(s) ? Math.max(1, parseInt(s, 10)) : 1;
  }

  function apiList(typeId, page) {
    var body = fetch('list/mip-data?typeId=' + typeId + '&page=' + page + '&callback=jsonp').trim();
    // Up to the last ')', not the first ');', so a name holding ");" cannot cut the JSON short (TXB-05).
    if (body.indexOf('jsonp(') === 0 && body.lastIndexOf(')') > 5) body = body.slice(6, body.lastIndexOf(')'));
    var json = host.parseJSON(body);
    var items = json && json.data && Array.isArray(json.data.items) ? json.data.items : [];
    var list = [];
    for (var i = 0; i < items.length; i++) {
      var item = items[i];
      if (!item || typeof item !== 'object') continue;
      var id = text(item.video_id);
      if (!/^\d+$/.test(id) || parseInt(id, 10) === 0) continue;
      list.push({
        vod_id: String(parseInt(id, 10)),
        vod_name: text(item.name),
        vod_pic: absolute(text(item.image)),
        vod_remarks: text(item.duration_string) || text(item.play_num)
      });
    }
    return list;
  }

  // The JAR's pattern, first occurrence of each id kept in order; bare /play/ links only when it finds none.
  function subjectList(html) {
    var seen = {}, list = [], m;
    ITEM.lastIndex = 0;
    while ((m = ITEM.exec(html)) !== null) {
      if (seen[m[1]]) continue;
      seen[m[1]] = true;
      list.push({ vod_id: m[1], vod_name: m[3].trim(), vod_pic: absolute(m[2]), vod_remarks: m[4].trim() });
    }
    if (list.length) return list;
    var bare = /href="\/play\/(\d+)"/g;
    while ((m = bare.exec(html)) !== null) {
      if (seen[m[1]]) continue;
      seen[m[1]] = true;
      list.push({ vod_id: m[1], vod_name: '视频' + m[1], vod_pic: '', vod_remarks: '' });
    }
    return list;
  }

  // Title, poster and mp4 of one video page, by the JAR's rules (TuXiaoBei.java:180–212).
  function playPage(id) {
    var html = fetch('play/' + id);
    if (!html) return null;
    var title = first(html, /<h1[^>]*>([^<]+)<\/h1>/i);
    if (!title) title = first(html, /<title>([^<]+)<\/title>/i).split('-')[0].trim().split('_')[0].trim();
    var mp4 = first(html, /video-src="(https:\/\/resource-cdn\.tuxiaobei\.com\/[^"]+\.mp4)"/i);
    if (!mp4) mp4 = (html.match(/https:\/\/resource-cdn\.tuxiaobei\.com\/video\/[^"'\s]+\.mp4/) || [''])[0];
    var poster = first(html, /poster="(https:\/\/resource-cdn\.tuxiaobei\.com\/[^"]+)"/i);
    if (!poster) poster = (html.match(/https:\/\/resource-cdn\.tuxiaobei\.com\/video\/[^"'\s]+\.(png|jpg|webp)/i) || [''])[0];
    return { title: title, poster: poster, mp4: mp4 };
  }

  var spider = {
    init: function (extend) { return ''; },

    homeContent: function (filter) {
      var classes = CATEGORIES.map(function (c) { return { type_id: 'api_' + c[0], type_name: c[1] }; })
        .concat(SUBJECTS.map(function (s) { return { type_id: 'sub_' + s[0], type_name: s[1] }; }));
      return host.result.home(classes, []);
    },

    categoryContent: function (tid, pg, filter, extend) {
      var id = text(tid), page = pageNumber(pg);
      if (id.indexOf('api_') === 0) {
        var list = apiList(id.slice(4), page);
        return host.result.page(list, page, list.length ? page + 1 : page, list.length, 9999);
      }
      // A subject is one page; page 2 and anything unknown are empty, so paging stops.
      var items = id.indexOf('sub_') === 0 && page === 1 ? subjectList(fetch('subject/' + id.slice(4))) : [];
      return host.result.page(items, page, 1, items.length, items.length);
    },

    detailContent: function (ids) {
      var id = videoId(ids && ids[0]);
      var video = playPage(id);
      if (!video) return host.result.list([]);
      // A "$" or "#" in the title would split the play list into extra episodes (as in Bili.js).
      var episode = video.title.replace(/[$#]/g, ' ').trim() || '播放';
      return host.result.detail({
        vod_id: id,
        vod_name: video.title || id,
        vod_pic: video.poster,
        vod_play_from: '兔小贝',
        vod_play_url: episode + '$' + (video.mp4 || id)
      });
    },

    searchContent: function (key, quick, pg) {
      return host.result.list(subjectList(fetch('search/index?key=' + encodeURIComponent(text(key)))));
    },

    playerContent: function (flag, id, vipFlags) {
      var url = text(id);
      if (url.indexOf('http') !== 0) {
        var video = playPage(videoId(url));
        if (video && video.mp4) url = video.mp4;
      }
      return host.result.play(url, false, HEADERS);
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
