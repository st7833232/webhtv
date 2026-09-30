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
 *   - explicit slicing rules, "前綴&&後綴" with [包含:]/[不包含:]/[替换:a>>b] modifiers → cut() below
 *   - no rules at all, in which case the engine falls back to the 苹果CMS/stui template that most
 *     of these sites run. `果果短剧` configures only 4 keys and relies entirely on that fallback.
 */
var spider = (function () {
  'use strict';

  var rule = {};
  var headers = {};
  var categoryTemplate = '';
  var categoryCache = null;

  /** The original's `F()`: an empty value and the word `空` both mean "not configured". */
  function text(key, fallback) {
    var value = rule[key];
    if (value === undefined || value === null) return fallback || '';
    value = String(value);
    return value === '' || value === '空' ? (fallback || '') : value;
  }

  /** The original's G/H/I/J/K alias chains: the first configured key wins. */
  function pick(keys, fallback) {
    for (var i = 0; i < keys.length; i++) {
      var value = text(keys[i]);
      if (value) return value;
    }
    return fallback || '';
  }

  /** `分类url` and `搜索url` may end in `;;<flags>`, a per-site switch string that is not part of the URL. */
  function beforeFlags(url) {
    var i = url.indexOf(';;');
    return i === -1 ? url : url.slice(0, i);
  }

  /**
   * The four shapes `ext` takes in the original's `init`. A rule file arrives here as the https URL
   * `CSPSourceResolver.resolvedExtend` made of `./json/x.json`, and must be downloaded, not parsed.
   */
  function parseRule(raw) {
    raw = String(raw || '').trim();
    if (/^https?:\/\//i.test(raw)) {
      if (raw.indexOf('{cateId}') !== -1) return { '分类url': raw };
      return host.parseJSON((host.get(raw, { timeout: 20000 }).body || '').replace(/^﻿/, '')) || {};
    }
    if (!raw || raw.charAt(0) === '{') return host.parseJSON(raw || '{}') || {};
    // `键:值,键:值`, with `\,` for a comma inside a value.
    var out = {};
    raw.replace(/\\,/g, '\u0000').split(',').forEach(function (pair) {
      var i = pair.indexOf(':');
      if (i > 0) out[pair.slice(0, i)] = pair.slice(i + 1).replace(/\u0000/g, ',');
    });
    return out;
  }

  // ---- the original's slicing grammar (a0/b0/c0) ------------------------------------------
  // Lives here rather than in host.cut so that a compatibility pack can carry it; host.js cannot.
  // ponytail: not ported — numeric `3&&-2` slices, `$$` as a second separator, `整页`, `url:`
  // segments, [含序号:]/[不含序号:], Base64/urlDecode wrappers. No configured site uses them.

  var ESCAPED = { '[': '', ']': '', '*': '', '&': '', '#': '', '+': '' };
  /** `\[ \] \* \& \# \+ \( \)` are literal characters, not syntax. */
  function hide(s) { return s.replace(/\\([\[\]*&#+()])/g, function (_, c) { return ESCAPED[c] || c; }); }
  function reveal(s) {
    return s.replace(/[-]/g, function (c) { return '[]*&#+'.charAt(c.charCodeAt(0) - 0xE000); });
  }
  function literal(s) { return reveal(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
  function values(list) { return list.split('#').filter(Boolean).map(reveal); }

  /** `[替换:a>>b#c>>d]`: `>>空` (or a bare `>>`) deletes, `a>>>b` means `a>` → `b`, `*` spans text. */
  function replaceIn(value, spec) {
    var out = value, pairs = spec.split('#');
    for (var i = 0; i < pairs.length; i++) {
      var pair = /[^>]>>$/.test(pairs[i]) ? pairs[i] + '空' : pairs[i];
      var at = pair.indexOf('>>>') !== -1 ? pair.indexOf('>>>') + 1 : pair.indexOf('>>');
      // The original throws on a pair without `>>` and keeps the text as it was.
      if (at === -1) return value;
      var from = pair.slice(0, at), to = reveal(pair.slice(at + 2));
      if (from === '空') return to === '空' ? '' : to;
      if (to === '空') to = '';
      if (from.indexOf('*') === -1) { out = out.split(reveal(from)).join(to); continue; }
      var parts = from.split('*');
      var pattern = !parts[0] ? '[\\S\\s]*?' + literal(parts[1])
        : !parts[1] ? literal(parts[0]) + '[\\S\\s]*'
        : literal(parts[0]) + '[\\S\\s]*?' + literal(parts[1]);
      out = out.replace(new RegExp(pattern, 'g'), function () { return to; });
    }
    return out;
  }

  /** One `前&&後[修饰]` rule over `text`: every match, in order. `rule` has already been through `hide`. */
  function sliceAll(textValue, rule) {
    var at = rule.indexOf('&&');
    if (at === -1) {
      // No `&&` is a literal, or — with [替换:] — the whole text with the replacements applied.
      var whole = /\[仅?替换[:：](.*?)\]/.exec(rule);
      return [whole ? replaceIn(textValue, whole[1]) : reveal(rule)];
    }
    var head = rule.slice(0, at), tail = rule.slice(at + 2).split('&&')[0], mods = '';
    var open = tail.indexOf('[');
    // The original takes the modifiers from the *last* bracket, and cuts the tail at the first.
    if (open !== -1) { mods = tail.slice(tail.lastIndexOf('[')); tail = tail.slice(0, open); }
    var group = 1, headPattern = '^';
    if (head) {
      var wide = head.indexOf('**') !== -1, parts = head.split(wide ? '**' : '*');
      headPattern = parts.map(literal).join(wide ? '([\\S\\s]*?)' : '([^>]*?)');
      group = parts.length;
    }
    var replace = /\[仅?替换[:：](.*?)\]/.exec(mods);
    var include = /\[包含:(.*?)\]/.exec(mods), exclude = /\[不包含:(.*?)\]/.exec(mods);
    var re = new RegExp(headPattern + '([\\S\\s]*?)' + (tail ? literal(tail) : '$'), 'g');
    var out = [], m;
    while ((m = re.exec(textValue)) !== null) {
      if (m[0] === '') re.lastIndex++;
      var piece = replace ? replaceIn(m[group], replace[1]) : m[group];
      if (include && !values(include[1]).some(function (v) { return piece.indexOf(v) !== -1; })) continue;
      if (exclude && values(exclude[1]).some(function (v) { return piece.indexOf(v) !== -1; })) continue;
      out.push(piece);
    }
    return out;
  }

  /** `A+B+C` joins each part's first value; a part without `&&` is literal text, like `🌹+alt="&&"`. */
  function cut(textValue, ruleValue) {
    if (!ruleValue) return [];
    var textIn = String(textValue || ''), rule = hide(String(ruleValue));
    if (rule.indexOf('+') === -1) return sliceAll(textIn, rule);
    var joined = '';
    rule.split('+').forEach(function (part) {
      if (!part) return;
      var value = (sliceAll(textIn, part)[0] || '').trim();
      if (/^http/.test(value)) joined = '';
      joined += value;
    });
    return [joined];
  }
  function cut1(textValue, ruleValue) { var r = cut(textValue, ruleValue); return r.length ? r[0] : ''; }

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

  /** The original's `主页url` chain, ending in the host of whichever listing URL is configured. */
  function homeUrl() {
    var home = pick(['主页url', '首页推荐链接', '网站地址', 'url', 'homeUrl']);
    if (home) return home;
    var m = /(https?:\/\/[^/]+)/i.exec(categoryTemplate || beforeFlags(pick(['搜索url', '搜索链接'])));
    return m ? m[1] : '';
  }

  var site = function () {
    var m = /^(https?:\/\/[^/]+)/i.exec(homeUrl());
    return m ? m[1] : '';
  };

  /** `名&名` paired with `值&值` (the original's `T()`); no values, or `*`, makes each name its own id. */
  function pairCategories(names, values) {
    var n = names.split('&');
    var v = !values || values === '*' ? n : values.split('&');
    return n.map(function (name, i) { return name + '$' + (v[i] === undefined ? name : v[i]); }).join('#');
  }

  /**
   * The original's `m()`, minus its XPath guess at a navigation bar: explicit `名$id` pairs, names
   * paired with values, or `分类数组` sliced out of the home page.
   */
  function categories() {
    if (categoryCache) return categoryCache;
    var spec = text('分类');
    if (spec) {
      if (spec.indexOf('&') !== -1) spec = pairCategories(spec, text('分类值'));
    } else if (text('分类名称')) {
      spec = pairCategories(text('分类名称'), text('分类名称替换词'));
    } else if (text('class_name')) {
      spec = pairCategories(text('class_name'), text('class_value'));
    }
    if (spec.indexOf('$') === -1) {
      var arrayRule = text('分类数组');
      spec = '';
      // ponytail: a `//` rule is XPath and the automatic guess needs XPath too; neither is ported.
      if (arrayRule.indexOf('&&') !== -1 && arrayRule.indexOf('//') !== 0) {
        var html = fetch(homeUrl());
        var narrowed = text('分类二次截取') ? cut1(html, text('分类二次截取')) : '';
        if (narrowed) html = narrowed;
        spec = cut(html, arrayRule).map(function (block) {
          var name = host.stripTags(cut1(block + '</a>', text('分类标题', '>&&</a>'))).replace(/[<>]/g, '');
          var id = cut1(block, pick(['分类ID', '分类链接', 'cateId'], 'href="&&"')).trim();
          return name && id && name !== '不要' ? name + '$' + id : '';
        }).filter(Boolean).join('#');
      }
    }
    categoryCache = parseCategories(spec);
    return categoryCache;
  }

  /**
   * The original's `f()` and `N()`: the first page may have its own URL (`地址[firstPage=地址]` or
   * `地址|地址`), pages count from `起始页`, and a placeholder nothing fills is removed together with
   * a `/名/` segment of the same name — `.../area/{area}/by/{by}/id/1` becomes `.../id/1`.
   */
  function categoryUrl(tid, page) {
    var first = pick(['起始页', '分类起始页码', 'qishiye', 'firstpage'], '1');
    var start = parseInt(first, 10);
    var pg = String((parseInt(page, 10) || 1) - 1 + (isNaN(start) ? 1 : start));
    var url = categoryTemplate;
    if (/[\[|]/.test(url)) {
      url = pg === first
        ? url.replace(/.*[\[|].*(http[^\]]*)\]?.*/, '$1').replace('firstPage=', '')
        : url.replace(/\|\|/g, '|').replace(/(.*)[\[|].*/, '$1');
    }
    if (url.charAt(0) === '/' && url.charAt(1) !== '/') url = site() + url;
    url = url.split('{cateId}').join(tid).split('{catePg}').join(pg);
    (url.match(/\{.*?\}/g) || []).forEach(function (placeholder) {
      url = url.split(placeholder).join('').split('/' + placeholder.slice(1, -1) + '/').join('');
    });
    return url.split('://').map(function (part) { return part.replace(/\/{2,}/g, '/'); }).join('://');
  }

  /**
   * The 苹果CMS/stui listing shape these sites share. Used when a site configures no list rules,
   * which is the common case — XBPQ auto-detects rather than requiring every site to spell it out.
   */
  function defaultList(html) {
    var out = [];
    var nodes = host.pdfa(html, '.stui-vodlist li');
    if (!nodes.length) nodes = host.pdfa(html, 'ul.stui-vodlist__media li');
    if (!nodes.length) nodes = host.pdfa(html, '.myui-vodlist li');
    // The newer 苹果CMS skin (永乐影视) uses `module-items module-poster-items-base` and no
    // `*-vodlist` class at all, so without this the chain fell through to the bare `li` below and
    // picked up the category nav instead of the titles.
    if (!nodes.length) nodes = host.pdfa(html, '.module-items a');
    if (!nodes.length) nodes = host.pdfa(html, 'li');
    for (var i = 0; i < nodes.length; i++) {
      var link = host.pdfh(nodes[i], 'a&&href');
      var title = host.pdfh(nodes[i], 'a&&title');
      if (!link || !title) continue;
      // A listing link points at a detail page; the nav and filter lists do not.
      // A real detail link, not a category or type nav entry that happens to end in a number.
      if (!/\/\d+\.html|id[=/]\d+|\/\d+\/?$/.test(link)) continue;
      // `(vod)?` matters: 永乐's nav links are `/vodtype/1/`, where `type` is not preceded by a
      // slash, so they sailed through this filter and rendered as four titles called 电影, 剧集,
      // 综艺 and 动漫. `/voddetail/<id>/` is unaffected — `detail` is deliberately not listed.
      if (/\/(vod)?(type|show|label|search|area|year|by|class|lang)\//i.test(link)) continue;
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
    var blocks = cut(html, arrayRule);
    var out = [];
    for (var i = 0; i < blocks.length; i++) {
      var block = blocks[i];
      var link = cut1(block, text('分类链接')) || host.pdfh(block, 'a&&href');
      var title = cut1(block, text('分类标题')) || host.pdfh(block, 'a&&title');
      if (!link || !title) continue;
      out.push({
        vod_id: host.urljoin(site(), link),
        vod_name: host.stripTags(title),
        vod_pic: host.urljoin(site(), cut1(block, text('分类图片')) || host.pdfh(block, 'img&&data-original') || host.pdfh(block, 'img&&src')),
        vod_remarks: host.stripTags(cut1(block, text('分类备注')) || host.pdfh(block, '.pic-text&&Text'))
      });
    }
    return out;
  }

  return {
    init: function (extend) {
      rule = parseRule(extend);
      categoryCache = null;
      categoryTemplate = beforeFlags(pick(['分类url', '分类链接', '分类页', 'class_url', 'cateUrl']));
      headers = parseHeaders(pick(['请求头', '请求头参数']));
      if (!headers['User-Agent']) headers['User-Agent'] = parseHeaders('u$MOBILE_UA').u;
      return '';
    },

    homeContent: function () {
      return host.result.home(categories(), []);
    },

    homeVideoContent: function () {
      var list = categories();
      if (!list.length) return { list: [] };
      return host.result.list(this.categoryList(list[0].type_id, '1'));
    },

    categoryList: function (tid, page) {
      if (!categoryTemplate) return [];
      return listFrom(fetch(categoryUrl(tid, page)));
    },

    categoryContent: function (tid, page) {
      return host.result.page(this.categoryList(tid, String(page || '1')), page);
    },

    detailContent: function (ids) {
      var url = String(ids[0]);
      var html = fetch(url);
      var name = cut1(html, text('片名')) || host.pdfh(html, 'h1&&Text') || host.pdfh(html, '.title&&Text');
      var pic = host.pdfh(html, '.stui-content__thumb a&&data-original')
             || host.pdfh(html, '.myui-content__thumb a&&data-original')
             || host.pdfh(html, '.stui-content__thumb img&&data-original')
             || host.pdfh(html, '.lazyload&&data-original');
      var desc = host.stripTags(cut1(html, text('简介')) || host.pdfh(html, '.detail&&Text'));

      // Play lists: one <ul> of episodes per line, with the line names alongside.
      var flagNames = [];
      var flagRule = text('线路数组'), titleRule = text('线路标题');
      if (flagRule) {
        var blocks = cut(html, flagRule);
        for (var i = 0; i < blocks.length; i++) {
          flagNames.push(host.stripTags(titleRule ? cut1(blocks[i], titleRule) : blocks[i]));
        }
      }
      if (!flagNames.length) {
        // 苹果CMS ships two template families, stui and myui; both name their lines in a heading
        // next to each play list.
        var tabs = host.pdfa(html, '.stui-pannel__head h3');
        if (!tabs.length) tabs = host.pdfa(html, '.myui-panel__head h3');
        if (!tabs.length) tabs = host.pdfa(html, '.nav-tabs li a');
        // The newer skin names each line in a tab chip instead of a panel heading:
        // <div class="module-tab-item" data-dropdown-value="大陆0线"><span>大陆0线</span><small>1</small></div>
        // Taking the <span> avoids the episode count in the <small>.
        if (!tabs.length) tabs = host.pdfa(html, '.module-tab-item span');
        for (var t = 0; t < tabs.length; t++) flagNames.push(host.text(tabs[t]).trim());
      }

      var froms = [], urls = [];
      var lists = host.pdfa(html, 'ul.stui-content__playlist');
      if (!lists.length) lists = host.pdfa(html, 'ul.myui-content__list');
      if (!lists.length) lists = host.pdfa(html, 'ul.content__playlist');
      // The newer skin uses a div, not a ul, and puts the links directly inside it.
      if (!lists.length) lists = host.pdfa(html, '.module-play-list-content');
      for (var l = 0; l < lists.length; l++) {
        // `li a` for the ul-based skins; a bare `a` for the div-based one, which has no li.
        var items = host.pdfa(lists[l], 'li a');
        if (!items.length) items = host.pdfa(lists[l], 'a');
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
      var template = pick(['搜索url', '搜索链接']);
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
