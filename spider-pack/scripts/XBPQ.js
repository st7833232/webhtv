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
  var flags = '';

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

  function fetch(url) {
    return host.get(url, { headers: headers, timeout: 20000 }).body || '';
  }

  /**
   * A page as the original's `k()` hands it to its rules: every whitespace character except the
   * plain space removed, so a rule written as `/div></div>` matches `</div>\n</div>`. Only the rule
   * slicing reads this; the 苹果CMS DOM templates keep the page as sent, where a line break may be
   * the only thing between a tag's name and its first attribute. Detail and play pages: S4.
   */
  function compact(html) { return String(html || '').replace(/[\t\n\x0B\f\r]+/g, '').trim(); }

  // ---- detail and play (the original's detailContent/playerContent, IOS-POC-39 S4) -------------

  function yes(value) { return value === '1' || value === '是'; }

  /** The list link is the play page itself: `直接播放` (or `force_play`) is 1, or the flags carry `z`. */
  function playsDirectly() { return yes(pick(['直接播放', 'force_play'])) || flags.indexOf('z') !== -1; }

  /**
   * The original's `isVideoFormat`: a `嗅探词` in the address and no `过滤词`. `.mkv` is added to the
   * original's default list because this port accepted it before, and a site relying on it must not lose it.
   */
  function isVideo(url) {
    var u = String(url || '').toLowerCase();
    if (u.indexOf('http') !== 0 && u.indexOf('magnet') !== 0) return false;
    var words = pick(['嗅探词', 'VideoFormat'], 'm3u8#.mp4#.flv#.mp3#.m4a#.mkv#magnet:#ed2k:#ftp:#thunder:#push:#tvbox-xg:').split('#');
    var skips = pick(['过滤词', 'VideoFilter'], 'url=http#;post;#.js').split('#');
    function has(w) { return w && u.indexOf(w.toLowerCase()) !== -1; }
    return words.some(has) && !skips.some(has);
  }

  /** A link as a page hands it over: JSON-escaped slashes undone, joined to the site. */
  function absolute(link) {
    link = String(link || '').trim().replace(/\\\//g, '/');
    return link ? host.urljoin(site(), link) : '';
  }

  // ponytail: only %xx sequences are decoded; Java's URLDecoder also turns `+` into a space, which
  // would break a signed stream address.
  function urlDecode(value) {
    if (!/%[0-9a-fA-F]{2}/.test(value)) return value;
    try { return decodeURIComponent(value); } catch (e) { return value; }
  }

  /** One line's episodes, `标题$链接`, with the configured rules or the original's defaults. */
  function episodesIn(block) {
    var listRule = pick(['播放列表', '播放剧集截取数组', 'bfyjiequshuzuqian', 'epi_arr_pre'], '<a&&</a>');
    var titleRule = pick(['播放标题', '播放剧集标题', 'bfbiaotiqian', 'epi_title'], '>&&</a>');
    var linkRule = pick(['播放链接', '播放剧集链接', 'bflianjieqian', 'epi_url'], 'href="&&"');
    var prefix = pick(['播放链接前缀', '播放剧集链接前缀', 'bfqianzhui', 'epiurl_prefix']);
    var suffix = pick(['播放链接后缀', '播放剧集链接后缀', 'bfhouzhui', 'epiurl_suffix']);
    return cut(block, listRule).map(function (episode) {
      // The title is read with the closing tag the array cut consumed, as the original does.
      var title = clean(cut1(episode + '</a>', titleRule));
      var link = cut1(episode, linkRule).trim();
      if (!title || !link) return '';
      if (prefix) link = cut1(episode, prefix) + link;
      if (suffix) link += cut1(episode, suffix);
      return title + '$' + absolute(link);
    }).filter(Boolean);
  }

  /** 苹果CMS play lists read off the DOM — the stui, myui and newer module skins. */
  function templateLists(raw) {
    var lists = host.pdfa(raw, 'ul.stui-content__playlist');
    if (!lists.length) lists = host.pdfa(raw, 'ul.myui-content__list');
    if (!lists.length) lists = host.pdfa(raw, 'ul.content__playlist');
    // The newer skin uses a div, not a ul, and puts the links directly inside it.
    if (!lists.length) lists = host.pdfa(raw, '.module-play-list-content');
    return lists.map(function (list) {
      // `li a` for the ul-based skins; a bare `a` for the div-based one, which has no li.
      var items = host.pdfa(list, 'li a');
      if (!items.length) items = host.pdfa(list, 'a');
      return items.map(function (item) {
        var href = host.pdfh(item, 'a&&href') || item.attrs.href;
        var label = host.text(item).trim();
        return href && label ? label + '$' + host.urljoin(site(), href) : '';
      }).filter(Boolean);
    });
  }

  /** Line names, one per list: `线路数组`/`线路标题`, else the templates' headings. */
  function lineNames(raw, html) {
    var arrayRule = pick(['线路数组', '线路名截取数组', 'xljiequshuzuqian', '线路名截取数组前', 'tab_arr_pre']);
    var titleRule = pick(['线路标题', 'xlbiaotiqian', '线路名标题', '线路名标题前', 'tab_title'], '>&&</a>');
    if (arrayRule) {
      var narrowRule = pick(['线路二次截取', '线路名二次截取', 'xljiequqian', '线路名截取前', 'tab_twice_pre']);
      var flat = (narrowRule && cut1(html, narrowRule)) || html;
      return cut(flat, arrayRule).map(function (block) { return clean(cut1(block, titleRule)); });
    }
    // 苹果CMS ships two template families, stui and myui; both name their lines in a heading
    // next to each play list.
    var tabs = host.pdfa(raw, '.stui-pannel__head h3');
    if (!tabs.length) tabs = host.pdfa(raw, '.myui-panel__head h3');
    if (!tabs.length) tabs = host.pdfa(raw, '.nav-tabs li a');
    // The newer skin names each line in a tab chip instead of a panel heading:
    // <div class="module-tab-item" data-dropdown-value="大陆0线"><span>大陆0线</span><small>1</small></div>
    // Taking the <span> avoids the episode count in the <small>.
    if (!tabs.length) tabs = host.pdfa(raw, '.module-tab-item span');
    return tabs.map(function (tab) { return host.text(tab).trim(); });
  }

  /** Every line of a detail page, as parallel `froms`/`urls`. */
  function playLines(raw, html) {
    var narrowRule = pick(['播放二次截取', 'bfjiequqian', 'list_twice_pre']);
    var flat = (narrowRule && cut1(html, narrowRule)) || html;
    var arrayRule = pick(['播放数组', 'bfjiequshuzuqian', 'list_arr_pre']);
    // Without `播放数组` only the 苹果CMS templates are read. ponytail: the original's automatic
    // episode rules are not ported — on 歐視 they turned an episode-less page into seven links to
    // its introduction pages, and no configured site needed them (IOS-POC-39 section 6.3).
    var lists = arrayRule ? cut(flat, arrayRule).map(episodesIn) : templateLists(raw);
    var names = lineNames(raw, html);
    var reverse = yes(pick(['倒序', '倒序播放', '是否反转选集序列', 'epi_reverse'])) ||
                  (flags.indexOf('d') !== -1 && flags.indexOf('d0') === -1);
    var froms = [], urls = [];
    lists.forEach(function (list, i) {
      if (!list.length) return;
      froms.push(names[i] || ('线路' + (i + 1)));
      urls.push((reverse ? list.slice().reverse() : list).join('#'));
    });
    if (yes(pick(['线路合并', '不分线路'])) && urls.length > 1) {
      froms = [froms[0]];
      urls = [urls.join('#')];
    }
    return { froms: froms, urls: urls };
  }

  /**
   * `跳转播放链接` and the up to four hops after it (`二次`～`五次跳转播放链接`), each read off the page
   * the previous one pointed at. `urlDecode(规则)` decodes once more, and the result is decoded
   * unless the flags carry `u0`, as the original's jumpCut does.
   */
  function jumpedUrl(html) {
    var rules = [pick(['跳转播放链接', '播放链接二次截取']),
                 text('二次跳转播放链接'), text('三次跳转播放链接'), text('四次跳转播放链接'), text('五次跳转播放链接')];
    var url = '', pageText = html;
    for (var i = 0; i < rules.length && rules[i]; i++) {
      if (i > 0) pageText = compact(fetch(url));
      var wrapped = /urlDecode\((.*?)\)/.exec(rules[i]);
      var value = cut1(pageText, wrapped ? wrapped[1] : rules[i]).trim().replace(/\\\//g, '/');
      if (flags.indexOf('u0') === -1) value = urlDecode(value);
      if (wrapped) value = urlDecode(value);
      if (!value) break;
      url = absolute(value);
      if (isVideo(url)) break;
    }
    return url;
  }

  /** 免嗅: the `player_*` JSON 苹果CMS players publish, including its encrypt 1 and 2. */
  function macPlayerUrl(raw) {
    var blob = host.match(raw, 'player_[a-zA-Z0-9_]*\\s*=\\s*(\\{[\\s\\S]*?\\})\\s*<\\/script>');
    if (!blob) return '';
    var data;
    try { data = JSON.parse(blob); } catch (e) { return ''; }
    var url = String(data.url || '').replace(/\\\//g, '/');
    try {
      if (String(data.encrypt) === '2') url = host.dec(host.base64.decode(url));
      else if (url && (String(data.encrypt) === '1' || !/^https?:/i.test(url))) url = host.dec(url);
    } catch (e2) { /* keep raw */ }
    return url;
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
      // Port XPath for both once a configured site writes its category array that way.
      if (arrayRule.indexOf('&&') !== -1 && arrayRule.indexOf('//') !== 0) {
        var html = compact(fetch(homeUrl()));
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

  /** Tags and HTML entities out, the way the original cleans a title or a remark. */
  function clean(value) {
    return host.stripTags(String(value || '').replace(/&#?[a-zA-Z0-9]{1,10};/g, '')).replace(/[<>]/g, '');
  }

  var LINK_RULE = 'href="&&"[不包含:script#/hot/#type#search#.xml#.js#=http]';
  // The original's automatic mode, tried in this order when a site names no `数组`.
  var AUTO_ARRAYS = ['<li*>&&</li>[不包含:首页#剧集#连续剧#电视剧#综艺#动漫#我想看#追剧#留言#APP#观看纪录#求片#福利#推荐]',
                     '<a&&</a>', '<div&&</div>'];

  // The keys and defaults each field is read with: the listing's (`A()`) and the search page's (`Z()`).
  var LIST_FIELDS = {
    title: [['标题', '列表标题', 'biaotiqian', 'catjsonname', 'cat_title'], 'title="&&"'],
    pic: [['图片', '列表图片', 'tupianqian', 'catjsonpic', 'cat_pic'], 'original="&&"'],
    link: [['链接', '列表链接', 'lianjieqian', 'catjsonid', 'cat_url'], LINK_RULE],
    remark: [['副标题', '列表副标题', 'fubiaotiqian', 'catjsonstitle', 'cat_subtitle'], 'class="pic-text*>&&<'],
    prefix: [['链接前缀', '列表链接前缀', 'ljqianzhui', 'cat_prefix'], ''],
    suffix: [['链接后缀', '列表链接后缀', 'ljhouzhui', 'cat_suffix'], '']
  };

  /** One `数组` block per title, each field read with `fields` (the list keys unless told otherwise). */
  function itemsFrom(html, arrayRule, fields) {
    fields = fields || LIST_FIELDS;
    function rule(name) { return pick(fields[name][0], fields[name][1]); }
    var titleRule = rule('title'), picRule = rule('pic'), linkRule = rule('link');
    var remarkRule = rule('remark'), prefix = rule('prefix'), suffix = rule('suffix');
    return cut(html, arrayRule).map(function (block) {
      var title = clean(cut1(block, titleRule) || cut1(block, 'alt="&&"'));
      var link = (cut1(block, linkRule) || cut1(block, LINK_RULE.replace(/"/g, "'"))).trim();
      if (!title || !link) return null;
      if (prefix) link = cut1(block, prefix) + link;
      if (suffix) link += cut1(block, suffix);
      return {
        vod_id: host.urljoin(site(), link),
        vod_name: title,
        vod_pic: host.urljoin(site(), (cut1(block, picRule) || cut1(block, 'src="&&"')).trim()),
        vod_remarks: clean(cut1(block, remarkRule)).replace(/更新/g, '更')
      };
    }).filter(Boolean);
  }

  /**
   * A configured `数组` is the site's own rule and wins. Without one, the 苹果CMS templates run
   * first — that is what the working sites rely on — and the original's automatic mode after them.
   */
  function listFrom(html) {
    var flat = compact(html);
    var narrowRule = pick(['二次截取', 'jiequqian', 'cat_twice_pre']);
    if (text('列表二次截取').indexOf('&&') !== -1) narrowRule = text('列表二次截取');
    var narrowed = narrowRule ? cut1(flat, narrowRule) : '';
    if (narrowed) html = flat = narrowed;
    var arrayRule = pick(['数组', '列表截取数组', 'cateVodNode', 'jiequshuzuqian', 'catjsonlist', 'cat_arr_pre']);
    // ponytail: a `//` array is the original's XPath mode, which no configured site uses.
    if (arrayRule) return arrayRule.indexOf('//') === 0 ? [] : itemsFrom(flat, arrayRule);
    var out = defaultList(html);
    for (var i = 0; !out.length && i < AUTO_ARRAYS.length; i++) out = itemsFrom(flat, AUTO_ARRAYS[i]);
    return out;
  }

  return {
    init: function (extend) {
      rule = parseRule(extend);
      categoryCache = null;
      var category = pick(['分类url', '分类链接', '分类页', 'class_url', 'cateUrl']);
      categoryTemplate = beforeFlags(category);
      // The original reads the flags off 分类url, or off 搜索url when 分类url has none.
      var flagged = category.indexOf(';;') !== -1 ? category : pick(['搜索url', '搜索链接']);
      flags = flagged.indexOf(';;') !== -1 ? flagged.slice(flagged.indexOf(';;') + 2) : '';
      headers = parseHeaders(pick(['请求头', '请求头参数']));
      if (!headers['User-Agent']) headers['User-Agent'] = parseHeaders('u$MOBILE_UA').u;
      return '';
    },

    homeContent: function () {
      return host.result.home(categories(), []);
    },

    /**
     * `首页` as the original reads it: a number is how many titles of the home page to show, `0`
     * turns the home list off, a name (or `名$数`) lists that category instead. A site that does not
     * set it keeps listing its first category, which is what the working sites were built against.
     */
    homeVideoContent: function () {
      var list = categories();
      var spec = pick(['首页', '热门', 'homeContent', 'shouye']);
      if (!spec) return list.length ? host.result.list(this.categoryList(list[0].type_id, '1')) : { list: [] };
      if (spec === '1' || spec === '首页') spec = '40';
      var name = spec, limit = 40;
      if (spec.indexOf('$') !== -1) {
        name = spec.slice(0, spec.indexOf('$'));
        limit = parseInt(spec.slice(spec.indexOf('$') + 1), 10);
      } else if (/^\d+$/.test(spec)) {
        name = '首页';
        limit = parseInt(spec, 10);
      }
      // The original throws on a count that is not a number, and shows no home list.
      if (!(limit > 0)) return { list: [] };
      if (name === '首页') return host.result.list(listFrom(fetch(homeUrl())).slice(0, limit));
      var named = list.filter(function (c) { return c.type_name === name; })[0];
      return named ? host.result.list(this.categoryList(named.type_id, '1').slice(0, limit)) : { list: [] };
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
      var raw = fetch(url), html = compact(raw);
      var name = cut1(html, text('片名')) || host.pdfh(raw, 'h1&&Text') || host.pdfh(raw, '.title&&Text');
      var pic = host.pdfh(raw, '.stui-content__thumb a&&data-original')
             || host.pdfh(raw, '.myui-content__thumb a&&data-original')
             || host.pdfh(raw, '.stui-content__thumb img&&data-original')
             || host.pdfh(raw, '.lazyload&&data-original');
      var desc = host.stripTags(cut1(html, text('简介')) || host.pdfh(raw, '.detail&&Text'));
      // A site that plays directly has no episode list: the listing's link is the play page. The
      // original names that line 直播列表 and the episode after the title.
      var lines = playsDirectly()
        ? { froms: ['直播列表'], urls: [(clean(name) || '立即播放') + '$' + url] }
        : playLines(raw, html);

      return host.result.detail({
        vod_id: url,
        vod_name: host.stripTags(name),
        vod_pic: host.urljoin(site(), pic),
        vod_remarks: '',
        vod_content: desc,
        vod_play_from: lines.froms.join('$$$'),
        vod_play_url: lines.urls.join('$$$')
      });
    },

    /**
     * The original's `Z()`. The search address is the first of its aliases that carries `{wd}` —
     * `搜索链接` is also the name of the result link rule (妻妹 sets it to one), so a value is only
     * an address if it has somewhere to put the keyword. With `搜索数组` the results are read with the
     * search keys; without it the page goes through the listing, as the original hands it to `A()`.
     * ponytail: not ported — `搜索模式`, `搜索前`+`搜索后缀` concatenation, POST bodies, and the
     * original's fallback of filtering home and category pages by title when a site has no address.
     * `搜索模式` waits on the user's decision (IOS-POC-39 S5 item 3); the rest, once a configured
     * site needs one of them.
     */
    searchContent: function (key, quick, page) {
      var aliases = ['搜索url', '搜索链接', '搜索前', 'sousuoqian', 'search_url', 'searchUrl'];
      var template = aliases.map(function (k) { return text(k); })
        .filter(function (v) { return v.indexOf('{wd}') !== -1; })[0];
      if (!template) return { list: [] };
      var pg = String(page || '1');
      var url = template.split(';')[0].split('{wd}').join(host.enc(key));
      ['{pg}', '{catePg}', '{SearchPg}', '{searchPg}'].forEach(function (p) { url = url.split(p).join(pg); });
      if (url.charAt(0) === '/' && url.charAt(1) !== '/') url = site() + url;
      var html = fetch(url);
      var arrayRule = pick(['搜索数组', '搜索截取数组', 'ssjiequshuzuqian', 'sea_arr_pre']);
      if (!arrayRule) return host.result.list(listFrom(html));
      var flat = compact(html);
      var narrowRule = pick(['搜索二次截取', 'ssjiequqian', 'sea_twice_pre']);
      var narrowed = narrowRule ? cut1(flat, narrowRule) : '';
      // `搜索链接` only counts as the link rule when it is not the address itself.
      var linkKeys = (text('搜索链接') === template ? [] : ['搜索链接']).concat(['sslianjieqian', 'sea_url']);
      return host.result.list(itemsFrom(narrowed || flat, arrayRule, {
        title: [['搜索标题', 'ssbiaotiqian', 'sea_title'], 'title="&&"'],
        pic: [['搜索图片', 'sstupianqian', 'sea_pic'], 'original="&&"'],
        link: [linkKeys, 'href="&&"'],
        remark: [['搜索副标题', 'ssfubiaotiqian', 'sea_subtitle'], ''],
        prefix: [['搜索链接前缀', 'ssljqianzhui'], ''],
        suffix: [['搜索链接后缀', 'sslianjiehou'], '']
      }));
    },

    playerContent: function (flag, id) {
      var target = String(id);
      if (isVideo(target)) return host.result.play(target, false, headers);
      var raw = fetch(target);
      var url = jumpedUrl(compact(raw));
      if (!isVideo(url) && pick(['免嗅', 'mac', 'Anal_MacPlayer'], '1') !== '0') url = macPlayerUrl(raw) || url;
      if (!isVideo(url)) url = host.match(raw, '"url"\\s*:\\s*"([^"]+)"').replace(/\\\//g, '/') || url;
      // Several stui templates publish the stream as `var now="https://.../index.m3u8"` instead.
      if (!isVideo(url)) url = host.match(raw, 'var\\s+now\\s*=\\s*"([^"]+)"').replace(/\\\//g, '/') || url;
      // Last resort, and what the original's 嗅探 amounts to: the page contains exactly one stream.
      if (!isVideo(url)) url = host.match(raw, '(https?:[^"\'\\s\\\\$#]+\\.(?:m3u8|mp4|mkv|flv)[^"\'\\s\\\\$#]*)') || url;
      if (isVideo(url)) return host.result.play(url, false, headers);
      return host.result.play(target, true, headers);
    },

    isVideoFormat: function (url) { return isVideo(url); },
    manualVideoCheck: function () { return false; },
    destroy: function () { rule = {}; headers = {}; flags = ''; }
  };
})();

module.exports = spider;
