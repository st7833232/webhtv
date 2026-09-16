/**
 * csp_XBPQ — ported from `com.github.catvod.spider.XBPQ`
 * (xyqxbpq.jar 8140 lines, xiaosa-0807.jar 43768 lines).
 *
 * A rule engine, not a site scraper: one port serves every XBPQ-configured site, present and
 * future. Its rules live in the site's own `ext`, so nothing here is specific to any one provider.
 *
 * The original's strings are obfuscated with a hex + XOR("wxEesU") table (`merge/xbpq/HaB.d`),
 * which is why its rule vocabulary is not visible in the DEX string pool. Decoding that table
 * recovered all 331 rule keys; the ones the configured sites actually use are implemented here.
 *
 * Two extraction models, as the original has:
 *   - explicit slicing rules, "前綴&&後綴" with [包含:]/[不包含:]/[替换:a>>b] modifiers → host.cut
 *   - no rules at all, in which case the engine falls back to the 苹果CMS/stui template that most
 *     of these sites run. `果果短剧` configures only 4 keys and relies entirely on that fallback.
 */
var spider = (function () {
  'use strict';

  var rule = {};
  var headers = {};

  function text(key, fallback) {
    var value = rule[key];
    return value === undefined || value === null || value === '' ? (fallback || '') : String(value);
  }

  /** "User-Agent$MOBILE_UA#Referer$https://x" → a header map. */
  function parseHeaders(spec) {
    var out = {};
    String(spec || '').split('#').forEach(function (pair) {
      if (!pair) return;
      var i = pair.indexOf('$');
      if (i === -1) return;
      var name = pair.slice(0, i), value = pair.slice(i + 1);
      if (value === 'MOBILE_UA' || value === '手机') {
        value = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
      } else if (value === 'PC_UA' || value === '电脑') {
        value = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36';
      }
      out[name] = value;
    });
    return out;
  }

  /** "重生$1#穿越$2" → [{type_id, type_name}]. */
  function parseCategories(spec) {
    var out = [];
    String(spec || '').split('#').forEach(function (item) {
      if (!item) return;
      var i = item.lastIndexOf('$');
      if (i === -1) out.push({ type_id: item, type_name: item });
      else out.push({ type_id: item.slice(i + 1), type_name: item.slice(0, i) });
    });
    return out;
  }

  function fill(template, values) {
    return String(template || '').replace(/\{([a-zA-Z]+)\}/g, function (_, name) {
      return values[name] === undefined ? '' : values[name];
    });
  }

  function fetch(url) {
    return host.get(url, { headers: headers, timeout: 20000 }).body || '';
  }

  var site = function () {
    var base = text('分类url') || text('分类链接') || text('主页url') || text('网站地址');
    var m = /^(https?:\/\/[^/]+)/i.exec(base);
    return m ? m[1] : '';
  };

  /**
   * The 苹果CMS/stui listing shape these sites share. Used when a site configures no list rules,
   * which is the common case — XBPQ auto-detects rather than requiring every site to spell it out.
   */
  function defaultList(html) {
    var out = [];
    var nodes = host.pdfa(html, '.stui-vodlist li');
    if (!nodes.length) nodes = host.pdfa(html, 'ul.stui-vodlist__media li');
    if (!nodes.length) nodes = host.pdfa(html, '.myui-vodlist li');
    if (!nodes.length) nodes = host.pdfa(html, 'li');
    for (var i = 0; i < nodes.length; i++) {
      var link = host.pdfh(nodes[i], 'a&&href');
      var title = host.pdfh(nodes[i], 'a&&title');
      if (!link || !title) continue;
      // A listing link points at a detail page; the nav and filter lists do not.
      // A real detail link, not a category or type nav entry that happens to end in a number.
      if (!/\/\d+\.html|id[=/]\d+|\/\d+\/?$/.test(link)) continue;
      if (/\/(type|show|label|area|year|by|class|lang)\//i.test(link)) continue;
      var pic = host.pdfh(nodes[i], 'a&&data-original') || host.pdfh(nodes[i], 'a&&data-src')
             || host.pdfh(nodes[i], 'img&&data-original') || host.pdfh(nodes[i], 'img&&src');
      var remark = host.pdfh(nodes[i], '.pic-text&&Text') || host.pdfh(nodes[i], '.pic-tag&&Text')
                || host.pdfh(nodes[i], '.tag&&Text');
      out.push({
        vod_id: host.urljoin(site(), link),
        vod_name: title,
        vod_pic: host.urljoin(site(), pic),
        vod_remarks: remark
      });
    }
    return out;
  }

  /** Explicit rules win; the template fallback only runs when a site configures none. */
  function listFrom(html) {
    var arrayRule = text('分类数组') || text('列表分类');
    if (!arrayRule) return defaultList(html);
    var blocks = host.cut(html, arrayRule);
    var out = [];
    for (var i = 0; i < blocks.length; i++) {
      var block = blocks[i];
      var link = host.cut1(block, text('分类链接')) || host.pdfh(block, 'a&&href');
      var title = host.cut1(block, text('分类标题')) || host.pdfh(block, 'a&&title');
      if (!link || !title) continue;
      out.push({
        vod_id: host.urljoin(site(), link),
        vod_name: host.stripTags(title),
        vod_pic: host.urljoin(site(), host.cut1(block, text('分类图片')) || host.pdfh(block, 'img&&data-original') || host.pdfh(block, 'img&&src')),
        vod_remarks: host.stripTags(host.cut1(block, text('分类备注')) || host.pdfh(block, '.pic-text&&Text'))
      });
    }
    return out;
  }

  return {
    init: function (extend) {
      try { rule = JSON.parse(extend || '{}'); } catch (e) { rule = {}; }
      headers = parseHeaders(text('请求头') || text('请求头参数'));
      if (!headers['User-Agent']) headers['User-Agent'] = parseHeaders('u$MOBILE_UA').u;
      return '';
    },

    homeContent: function () {
      return host.result.home(parseCategories(text('分类')), []);
    },

    homeVideoContent: function () {
      var categories = parseCategories(text('分类'));
      if (!categories.length) return { list: [] };
      return host.result.list(this.categoryList(categories[0].type_id, '1'));
    },

    categoryList: function (tid, page) {
      var url = fill(text('分类url') || text('分类链接'), {
        cateId: tid, catePg: page, area: '', by: '', year: '', 'class': '', lang: '', letter: ''
      });
      if (!url) return [];
      return listFrom(fetch(url));
    },

    categoryContent: function (tid, page) {
      return host.result.page(this.categoryList(tid, String(page || '1')), page);
    },

    detailContent: function (ids) {
      var url = String(ids[0]);
      var html = fetch(url);
      var name = host.cut1(html, text('片名')) || host.pdfh(html, 'h1&&Text') || host.pdfh(html, '.title&&Text');
      var pic = host.pdfh(html, '.stui-content__thumb a&&data-original')
             || host.pdfh(html, '.myui-content__thumb a&&data-original')
             || host.pdfh(html, '.stui-content__thumb img&&data-original')
             || host.pdfh(html, '.lazyload&&data-original');
      var desc = host.stripTags(host.cut1(html, text('简介')) || host.pdfh(html, '.detail&&Text'));

      // Play lists: one <ul> of episodes per line, with the line names alongside.
      var flagNames = [];
      var flagRule = text('线路数组'), titleRule = text('线路标题');
      if (flagRule) {
        var blocks = host.cut(html, flagRule);
        for (var i = 0; i < blocks.length; i++) {
          flagNames.push(host.stripTags(titleRule ? host.cut1(blocks[i], titleRule) : blocks[i]));
        }
      }
      if (!flagNames.length) {
        // 苹果CMS ships two template families, stui and myui; both name their lines in a heading
        // next to each play list.
        var tabs = host.pdfa(html, '.stui-pannel__head h3');
        if (!tabs.length) tabs = host.pdfa(html, '.myui-panel__head h3');
        if (!tabs.length) tabs = host.pdfa(html, '.nav-tabs li a');
        for (var t = 0; t < tabs.length; t++) flagNames.push(host.text(tabs[t]).trim());
      }

      var froms = [], urls = [];
      var lists = host.pdfa(html, 'ul.stui-content__playlist');
      if (!lists.length) lists = host.pdfa(html, 'ul.myui-content__list');
      if (!lists.length) lists = host.pdfa(html, 'ul.content__playlist');
      for (var l = 0; l < lists.length; l++) {
        var items = host.pdfa(lists[l], 'li a');
        var episodes = [];
        for (var e = 0; e < items.length; e++) {
          var href = host.pdfh(items[e], 'a&&href') || items[e].attrs.href;
          var label = host.text(items[e]).trim();
          if (href && label) episodes.push(label + '$' + host.urljoin(site(), href));
        }
        if (episodes.length) {
          froms.push(flagNames[l] || ('线路' + (l + 1)));
          urls.push(episodes.join('#'));
        }
      }

      return host.result.detail({
        vod_id: url,
        vod_name: host.stripTags(name),
        vod_pic: host.urljoin(site(), pic),
        vod_remarks: '',
        vod_content: desc,
        vod_play_from: froms.join('$$$'),
        vod_play_url: urls.join('$$$')
      });
    },

    searchContent: function (key, quick, page) {
      var template = text('搜索url') || text('搜索链接');
      if (!template) return { list: [] };
      var url = fill(template.split(';')[0], { wd: host.enc(key), SearchPg: String(page || '1'), searchPg: String(page || '1') });
      return host.result.list(listFrom(fetch(url)));
    },

    playerContent: function (flag, id) {
      var html = fetch(String(id));
      // 苹果CMS players publish the stream in a player_*_data JSON blob.
      var blob = host.match(html, 'player_[a-zA-Z0-9_]*\\s*=\\s*(\\{[\\s\\S]*?\\})\\s*<\\/script>');
      var url = '';
      if (blob) {
        try { url = (JSON.parse(blob).url || '').replace(/\\\//g, '/'); } catch (e) { url = ''; }
        if (url && !/^https?:/i.test(url)) { try { url = host.dec(url); } catch (e2) { /* keep raw */ } }
      }
      if (!url) url = host.match(html, '"url"\\s*:\\s*"([^"]+)"').replace(/\\\//g, '/');
      // Several stui templates publish the stream as `var now="https://.../index.m3u8"` instead.
      if (!url) url = host.match(html, 'var\\s+now\\s*=\\s*"([^"]+)"').replace(/\\\//g, '/');
      // Last resort, and what the original's 嗅探 amounts to: the page contains exactly one stream.
      if (!url) url = host.match(html, '(https?:[^"\'\\s\\\\$#]+\\.(?:m3u8|mp4|mkv|flv)[^"\'\\s\\\\$#]*)');
      if (url && /\.(m3u8|mp4|mkv|flv)/i.test(url)) return host.result.play(url, false, headers);
      return host.result.play(String(id), true, headers);
    },

    isVideoFormat: function (url) { return /\.(m3u8|mp4|mkv|flv)(\?|$)/i.test(String(url)); },
    manualVideoCheck: function () { return false; },
    destroy: function () { rule = {}; headers = {}; }
  };
})();

module.exports = spider;
