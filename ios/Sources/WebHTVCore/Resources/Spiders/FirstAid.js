/**
 * FirstAid (急救教學) spider.
 * Port of com.github.catvod.spider.FirstAid from qist spider.jar.
 * Source host: https://m.youlai.cn
 */
(function () {
  'use strict';

  var BASE = 'https://m.youlai.cn';

  function headers() {
    return {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36'
    };
  }

  var spider = {
    init: function (extend) {
      return '';
    },

    homeContent: function (filter) {
      var classes = [
        { type_id: 'jijiu|0', type_name: '急救技能' },
        { type_id: 'jijiu|1', type_name: '家庭生活' },
        { type_id: 'jijiu|2', type_name: '急危重症' },
        { type_id: 'jijiu|3', type_name: '常见损伤' },
        { type_id: 'jijiu|4', type_name: '动物致伤' },
        { type_id: 'jijiu|5', type_name: '海洋急救' },
        { type_id: 'jijiu|6', type_name: '中毒急救' },
        { type_id: 'jijiu|7', type_name: '意外事故' }
      ];
      return host.result.home(classes, []);
    },

    categoryContent: function (tid, pg, filter, extend) {
      var parts = String(tid || '').split('|');
      var pathSegment = parts[0] || 'jijiu';
      var index = parseInt(parts[1] || '0', 10);
      if (extend && extend.cateId) {
        pathSegment = extend.cateId;
      }

      var targetUrl = host.urljoin(BASE, '/' + pathSegment);
      var res = host.get(targetUrl, { headers: headers(), timeout: 15000 });
      var html = res.body || '';

      var blocks = host.pdfa(html, '.block100');
      var pic = '';
      if (blocks && blocks.length > index) {
        pic = host.urljoin(BASE, host.pdfh(blocks[index], 'img&&src') || host.pdfh(blocks[index], '&&src'));
      }

      var titles = host.pdfa(html, '.jj-title-li');
      var items = [];
      if (titles && titles.length > index) {
        var subItems = host.pdfa(titles[index], '.list-br3');
        for (var i = 0; i < subItems.length; i++) {
          var a = subItems[i];
          var link = host.pdfh(a, 'a&&href');
          var text = host.pdfh(a, 'a&&Text');
          items.push({
            vod_id: host.urljoin(BASE, link),
            vod_name: text,
            vod_pic: pic,
            vod_remarks: ''
          });
        }
      }

      // One fixed list per category: a single page stops the app requesting page 2, 3, ... forever.
      return host.result.page(items, 1, 1, items.length, items.length);
    },

    detailContent: function (ids) {
      var fullUrl = String(ids[0] || '');
      var res = host.get(fullUrl, { headers: headers(), timeout: 15000 });
      var html = res.body || '';

      var title = host.pdfh(html, '.video-title.h1-title&&Text');
      var pic = host.urljoin(BASE, host.pdfh(html, '.video-cover.list-flex-in img&&src'));
      var docName = host.pdfh(html, 'span.doc-name&&Text');
      var desc = host.pdfh(html, '.img-text-con&&Text');

      var videoSrc = host.pdfh(html, '#video source&&src');
      if (!videoSrc) {
        videoSrc = host.pdfh(html, '#video&&src');
      }
      videoSrc = host.urljoin(BASE, videoSrc);

      var playUrl = title + '$' + videoSrc;

      return host.result.detail({
        vod_id: fullUrl,
        vod_name: title,
        vod_pic: pic,
        type_name: docName,
        vod_year: '中国',
        vod_content: desc,
        vod_play_from: 'Qile',
        vod_play_url: playUrl
      });
    },

    searchContent: function (key, quick, pg) {
      var searchUrl = host.urljoin(BASE, '/cse/search?q=' + encodeURIComponent(key));
      var res = host.get(searchUrl, { headers: headers(), timeout: 15000 });
      var html = res.body || '';

      var items = host.pdfa(html, '.search-video-li.list-br2');
      var results = [];
      for (var i = 0; i < items.length; i++) {
        var it = items[i];
        var link = host.urljoin(BASE, host.pdfh(it, 'a&&href'));
        var name = host.pdfh(it, 'h5.line-clamp1&&Text');
        var pic = host.urljoin(BASE, host.pdfh(it, 'dt.logo-bg img&&src'));
        results.push({
          vod_id: link,
          vod_name: name,
          vod_pic: pic,
          vod_remarks: ''
        });
      }

      return host.result.list(results);
    },

    playerContent: function (flag, id, vipFlags) {
      return host.result.play(id, false, headers());
    }
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = spider;
  }
  return spider;
})();
