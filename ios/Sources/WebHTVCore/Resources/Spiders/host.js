/**
 * CatVod compatibility SDK, shared by the `csp_*` ports and the drpy spiders.
 *
 * Native pieces (`__http`, `__crypto`, `__store`, `__util`) are installed by CatVodHost.swift.
 * Everything expressible in JavaScript lives here so there is one implementation of HTML parsing,
 * result building and the drpy-style `pdfh`/`pdfa`/`pd` helpers, and no spider re-implements them.
 */
var host = (function () {
  'use strict';

  // ---- HTTP -------------------------------------------------------------
  function req(url, options) {
    options = options || {};
    var res = __http.request(url, {
      method: options.method || 'GET',
      headers: options.headers || {},
      body: typeof options.body === 'object' ? encodeForm(options.body) : (options.body || ''),
      timeout: options.timeout || 15000,
      redirect: options.redirect !== false
    });
    if (options.json !== false && res.body && (res.body[0] === '{' || res.body[0] === '[')) {
      try { res.json = JSON.parse(res.body); } catch (e) { /* body is not JSON; leave it */ }
    }
    return res;
  }
  function get(url, options) { return req(url, Object.assign({}, options, { method: 'GET' })); }
  function post(url, body, options) {
    return req(url, Object.assign({}, options, { method: 'POST', body: body }));
  }
  function encodeForm(object) {
    return Object.keys(object)
      .map(function (k) { return enc(k) + '=' + enc(String(object[k])); })
      .join('&');
  }

  // ---- encoding ---------------------------------------------------------
  function enc(s) { return __util.urlencode(String(s)); }
  function dec(s) { return __util.urldecode(String(s)); }
  var base64 = {
    encode: function (s) { return __crypto.b64encode(String(s)); },
    decode: function (s) { return __crypto.b64decode(String(s)); }
  };

  // ---- crypto -----------------------------------------------------------
  // `mode` is CBC or ECB; `inputEncoding` is base64 or hex for decryption.
  function aesDecrypt(text, key, iv, mode, inputEncoding) {
    return __crypto.symmetric('aes', false, String(text), String(key), String(iv || ''),
                              mode || 'CBC', inputEncoding || 'base64');
  }
  function aesEncrypt(text, key, iv, mode) {
    return __crypto.symmetric('aes', true, String(text), String(key), String(iv || ''), mode || 'CBC', 'base64');
  }
  // AES-CBC where the IV rides in front of the ciphertext: `aesEncryptIV` picks a fresh one and
  // returns base64(iv+ct), `aesDecryptIV` strips it back off. `App99` talks this dialect.
  function aesEncryptIV(text, key) { return __crypto.symmetricIV(true, String(text), String(key)); }
  function aesDecryptIV(text, key) { return __crypto.symmetricIV(false, String(text), String(key)); }
  function desDecrypt(text, key, iv, mode) {
    return __crypto.symmetric('des', false, String(text), String(key), String(iv || ''), mode || 'CBC', 'base64');
  }
  function md5(s) { return __crypto.digest('md5', String(s)); }
  function sha1(s) { return __crypto.digest('sha1', String(s)); }
  function sha256(s) { return __crypto.digest('sha256', String(s)); }
  function hmac(algorithm, s, key) { return __crypto.hmac(algorithm, String(s), String(key)); }

  // ---- storage ----------------------------------------------------------
  var local = {
    get: function (k) { return __store.get(String(k)); },
    set: function (k, v) { __store.set(String(k), String(v)); },
    del: function (k) { __store.del(String(k)); }
  };

  // ---- util -------------------------------------------------------------
  function now() { return Math.floor(__util.now()); }
  function timestamp() { return Math.floor(__util.now() / 1000); }
  function random(length, alphabet) {
    alphabet = alphabet || 'abcdefghijklmnopqrstuvwxyz0123456789';
    var out = '';
    for (var i = 0; i < length; i++) out += alphabet.charAt(Math.floor(Math.random() * alphabet.length));
    return out;
  }
  function match(text, pattern, group) {
    var m = new RegExp(pattern).exec(String(text || ''));
    return m ? (m[group === undefined ? 1 : group] || '') : '';
  }

  // ---- HTML -------------------------------------------------------------
  // A small forgiving parser. Real-world spider pages are malformed often enough that a strict
  // parser is the wrong tool; this one only needs to support the selectors spiders actually use.
  var VOID = { area:1, base:1, br:1, col:1, embed:1, hr:1, img:1, input:1, link:1, meta:1, param:1, source:1, track:1, wbr:1 };

  function parse(html) {
    var root = { tag: '#root', attrs: {}, children: [], parent: null, text: '' };
    var current = root;
    // The attribute run is matched loosely as "anything up to >". Real pages routinely omit the
    // space between attributes (`class="pic"style="..."`) and double their quotes; a strict
    // attribute grammar drops those tags entirely and silently loses the whole subtree.
    var re = /<!--[\s\S]*?-->|<(\/?)([a-zA-Z][\w:-]*)([^>]*?)(\/?)>|([^<]+)/g;
    var m;
    while ((m = re.exec(html)) !== null) {
      if (m[0].indexOf('<!--') === 0) continue;
      if (m[5] !== undefined) { current.text += m[5]; continue; }
      var closing = m[1] === '/', tag = m[2].toLowerCase();
      if (closing) {
        var node = current;
        while (node && node.tag !== tag) node = node.parent;
        if (node && node.parent) current = node.parent;
      } else {
        var el = { tag: tag, attrs: attributes(m[3] || ''), children: [], parent: current, text: '' };
        current.children.push(el);
        if (!VOID[tag] && m[4] !== '/') current = el;
        // <script>/<style> bodies are not markup; skip to the matching close tag.
        if (tag === 'script' || tag === 'style') {
          var close = html.toLowerCase().indexOf('</' + tag, re.lastIndex);
          if (close !== -1) { el.text = html.slice(re.lastIndex, close); re.lastIndex = close; }
        }
      }
    }
    return root;
  }

  function attributes(source) {
    var out = {}, re = /([a-zA-Z_:][\w:.-]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s">]+)))?/g, m;
    while ((m = re.exec(source)) !== null) {
      out[m[1].toLowerCase()] = m[2] !== undefined ? m[2] : (m[3] !== undefined ? m[3] : (m[4] || ''));
    }
    return out;
  }

  function textOf(node) {
    var out = node.text || '';
    for (var i = 0; i < node.children.length; i++) out += textOf(node.children[i]);
    return out;
  }

  // Supports `tag`, `.class`, `#id`, `[attr]`, `[attr=value]`, descendant and `>` combinators,
  // plus the `:eq(n)` drpy rules rely on.
  function selectorPart(part) {
    // Hiker writes an index as a trailing ",N"; drpy writes ":eq(N)". Same meaning.
    var comma = /,(-?\d+)$/.exec(part);
    var index = null;
    if (comma) { index = parseInt(comma[1], 10); part = part.slice(0, comma.index); }
    // ":has(sel)" keeps elements containing a match; only the tag part is matched here and the
    // containment is checked in `matches`.
    var has = /:has\(([^)]*)\)/.exec(part);
    if (has) part = part.replace(has[0], '');
    // `:eq(n)`, `:gt(n)` and `:lt(n)` are jQuery's positional filters, which drpy rule files use
    // and chain — 去看吧's class_parse is `li:gt(0):lt(6)`. They are collected in written order and
    // applied to the matched list in that order, which is what jQuery does.
    var slicers = [];
    var positional = /:(eq|gt|lt)\((-?\d+)\)/g, slice;
    while ((slice = positional.exec(part)) !== null) {
      slicers.push({ kind: slice[1], n: parseInt(slice[2], 10) });
    }
    var eq = slicers.length && slicers[0].kind === 'eq' && slicers.length === 1 ? slicers[0] : null;
    part = part.replace(/:(eq|gt|lt)\((-?\d+)\)/g, '');
    var tag = (/^[a-zA-Z*][\w:-]*/.exec(part) || ['*'])[0].toLowerCase();
    var classes = (part.match(/\.[^.#\[\s:]+/g) || []).map(function (c) { return c.slice(1); });
    var id = (/#([^.#\[\s:]+)/.exec(part) || [])[1];
    var attrs = [];
    var re = /\[\s*([\w:.-]+)\s*(?:([~^$*|]?=)\s*"?([^\]"]*?)"?)?\s*\]/g, m;
    while ((m = re.exec(part)) !== null) attrs.push({ name: m[1], op: m[2], value: m[3] });
    return { tag: tag, classes: classes, id: id, attrs: attrs, has: has ? has[1] : null,
             index: eq ? eq.n : index, slicers: slicers };
  }

  function matches(node, part) {
    if (part.tag !== '*' && node.tag !== part.tag) return false;
    if (part.id && node.attrs.id !== part.id) return false;
    var nodeClasses = (node.attrs['class'] || '').split(/\s+/);
    for (var i = 0; i < part.classes.length; i++) {
      if (nodeClasses.indexOf(part.classes[i]) === -1) return false;
    }
    if (part.has && !descendants(node, []).some(function (d) { return matches(d, selectorPart(part.has)); })) return false;
    for (var j = 0; j < part.attrs.length; j++) {
      var a = part.attrs[j], v = node.attrs[a.name.toLowerCase()];
      if (v === undefined) return false;
      if (a.op === '=' && v !== a.value) return false;
      if (a.op === '*=' && v.indexOf(a.value) === -1) return false;
      if (a.op === '^=' && v.indexOf(a.value) !== 0) return false;
    }
    return true;
  }

  function descendants(node, out) {
    for (var i = 0; i < node.children.length; i++) { out.push(node.children[i]); descendants(node.children[i], out); }
    return out;
  }

  function select(root, selector) {
    // Comma separates selector groups ("a, b"), but Hiker also writes an index as ",N" on a single
    // part (".sDes,-1"). Only split on a comma that is not introducing an index.
    var groups = String(selector).split(/,(?!-?\d)/);
    var found = [];
    for (var g = 0; g < groups.length; g++) {
      var parts = groups[g].trim().split(/\s+/);
      var scope = [root];
      for (var p = 0; p < parts.length; p++) {
        if (parts[p] === '>') { p++; scope = childrenMatching(scope, selectorPart(parts[p])); continue; }
        // Jsoup's `Element.select()` collects from the element itself, not only its descendants, so
        // a rule evaluated against a node may match that node. Rule files depend on it: 巴士动漫
        // picks episodes with `a` and then reads each one with `a&&href`, which finds nothing if
        // the <a> cannot match itself. Only the first part self-matches — later parts are descendant
        // combinators and must keep descending.
        scope = descendantsMatching(scope, selectorPart(parts[p]), p === 0);
      }
      found = found.concat(scope);
    }
    return found;
  }

  function applyIndex(list, part) {
    var out = list;
    var slicers = part.slicers || [];
    for (var s = 0; s < slicers.length; s++) {
      var n = slicers[s].n;
      if (slicers[s].kind === 'eq') {
        var i = n < 0 ? out.length + n : n;
        out = out[i] ? [out[i]] : [];
      } else if (slicers[s].kind === 'gt') {
        out = out.slice(n < 0 ? out.length + n + 1 : n + 1);
      } else {
        out = out.slice(0, n < 0 ? out.length + n : n);
      }
    }
    // Hiker's trailing ",N" index, which is only set when no positional filter was written.
    if (!slicers.length && part.index !== null) {
      var k = part.index < 0 ? out.length + part.index : part.index;
      out = out[k] ? [out[k]] : [];
    }
    return out;
  }
  function descendantsMatching(scope, part, includeSelf) {
    var out = [];
    for (var i = 0; i < scope.length; i++) {
      var all = descendants(scope[i], []);
      if (includeSelf) all = [scope[i]].concat(all);
      for (var j = 0; j < all.length; j++) if (matches(all[j], part)) out.push(all[j]);
    }
    return applyIndex(out, part);
  }
  function childrenMatching(scope, part) {
    var out = [];
    for (var i = 0; i < scope.length; i++) {
      for (var j = 0; j < scope[i].children.length; j++) {
        if (matches(scope[i].children[j], part)) out.push(scope[i].children[j]);
      }
    }
    return applyIndex(out, part);
  }

  /**
   * Hiker/drpy rule: "selector&&attr". The selector itself may be several `&&`-joined steps
   * ("body&&.list&&li"), the attribute may offer fallbacks ("data-echo||data-src||src"), and a
   * trailing "!text" strips a label prefix from the result ("Text!简介:").
   */
  function splitRule(rule) {
    var strip = '';
    rule = String(rule);
    var bang = rule.indexOf('!');
    if (bang !== -1 && rule.lastIndexOf('&&') < bang) { strip = rule.slice(bang + 1); rule = rule.slice(0, bang); }
    var parts = rule.split('&&');
    // A bare "Text" or "Html" asks for this node's own content, not for a tag called Text.
    if (parts.length === 1 && (parts[0] === 'Text' || parts[0] === 'Html')) {
      return { selector: '', attr: parts[0], strip: strip };
    }
    var attr = parts.length > 1 ? parts.pop() : 'Text';
    return { selector: parts.join(' '), attr: attr, strip: strip };
  }

  function nodeValue(node, attr) {
    if (!node) return '';
    // "data-echo||data-src||src": take the first that is present.
    var names = String(attr).split('||');
    for (var i = 0; i < names.length; i++) {
      var name = names[i];
      if (name === 'Text') return textOf(node).replace(/\s+/g, ' ').trim();
      if (name === 'Html') return textOf(node);
      var value = node.attrs[name.toLowerCase()];
      if (value) return value;
    }
    return '';
  }

  /** First match — drpy's `pdfh`. `html` may be a string or a parsed node. */
  function pdfh(html, rule) {
    // No rule means the rule file did not define that field, which is not the same as asking for
    // this node's whole text. Returning the text made every undefined 详情 field come back as the
    // entire page — 巴士动漫 reported its `vod_year` as the full HTML document's text.
    if (!String(rule === undefined || rule === null ? '' : rule).trim()) return '';
    var r = splitRule(rule);
    var root = typeof html === 'string' ? parse(html) : html;
    var found = r.selector ? select(root, r.selector) : [root];
    var value = nodeValue(found[0], r.attr);
    if (r.strip && value.indexOf(r.strip) === 0) value = value.slice(r.strip.length).trim();
    return value;
  }

  /** All matching nodes — drpy's `pdfa`. Returns nodes, to be fed back into `pdfh`. */
  /**
   * All matching nodes — drpy's `pdfa`, and Hiker's array rules.
   *
   * Hiker joins steps with `&&`, and each intermediate step descends into its **first** match, not
   * into every match: `#leftTabBox&&ul&&li` means "inside #leftTabBox, inside its first ul, every
   * li". Treating `&&` as a plain descendant combinator picks up every nested list instead, which
   * on a real page silently mixes the line tabs in with the episodes.
   */
  function pdfa(html, selector) {
    var root = typeof html === 'string' ? parse(html) : html;
    var steps = String(selector).split('&&');
    var scope = root;
    for (var i = 0; i < steps.length - 1; i++) {
      var found = select(scope, steps[i]);
      if (!found.length) return [];
      scope = found[0];
    }
    return select(scope, steps[steps.length - 1]);
  }

  /** `pdfh` with the result resolved against a base URL — drpy's `pd`. */
  function pd(html, rule, base) {
    return urljoin(base || '', pdfh(html, rule));
  }

  function urljoin(base, path) {
    if (!path) return '';
    if (/^https?:\/\//i.test(path)) return path;
    if (!base) return path;
    if (path.indexOf('//') === 0) return (base.split(':')[0] || 'https') + ':' + path;
    var m = /^(https?:\/\/[^/]+)(.*)$/i.exec(base);
    if (!m) return path;
    if (path.charAt(0) === '/') return m[1] + path;
    var dir = m[2].replace(/[^/]*$/, '');
    return m[1] + (dir || '/') + path;
  }


  // ---- XBPQ text slicing ------------------------------------------------
  // XBPQ rules slice between two markers rather than query a DOM: "前綴&&後綴", with optional
  // modifiers the engine appends. Recovered from the decompiled XBPQ by decoding its obfuscated
  // string table (hex + XOR "wxEesU"); these are the modifiers its sites actually use.
  function cut(text, rule) {
    text = String(text || '');
    if (!rule) return '';
    var include = null, exclude = null, replaces = [];
    rule = String(rule).replace(/\[(包含|不包含|替换):([^\]]*)\]/g, function (_, kind, value) {
      if (kind === '包含') include = value;
      else if (kind === '不包含') exclude = value;
      else replaces.push(value.split('>>'));
      return '';
    });
    var parts = rule.split('&&');
    var head = parts[0] || '', tail = parts.length > 1 ? parts[1] : '';
    var out = [];
    var from = 0;
    while (true) {
      var start = head ? text.indexOf(head, from) : from;
      if (start === -1) break;
      start += head.length;
      var end = tail ? text.indexOf(tail, start) : text.length;
      if (end === -1) break;
      var piece = text.slice(start, end);
      for (var i = 0; i < replaces.length; i++) {
        piece = piece.split(replaces[i][0]).join(replaces[i][1] === undefined ? '' : replaces[i][1]);
      }
      var keep = true;
      if (include !== null && piece.indexOf(include) === -1) keep = false;
      if (exclude !== null && piece.indexOf(exclude) !== -1) keep = false;
      if (keep) out.push(piece);
      from = end + (tail ? tail.length : 1);
      if (!head && !tail) break;
    }
    return out;
  }
  function cut1(text, rule) { var r = cut(text, rule); return r.length ? r[0] : ''; }

  /**
   * Gson-lenient JSON. The Android originals parse a rule file with Gson, which tolerates `//` and
   * block comments and trailing commas; `JSON.parse` does not. Real rule files rely on it —
   * `巴士动漫.json` and `動漫巴士.json` both comment keys out with `//` — and a strict parse turning
   * those into `{}` is indistinguishable, in the UI, from a site that simply returned nothing.
   *
   * Returns null when the text is genuinely not JSON, so a caller can tell "unparseable" from
   * "parsed to an empty object".
   */
  function parseJSON(text) {
    var s = String(text == null ? '' : text);
    try { return JSON.parse(s); } catch (e) { /* fall through to the lenient pass */ }
    var out = '', i = 0, n = s.length;
    while (i < n) {
      var c = s.charAt(i);
      if (c === '"') {
        // Copy strings verbatim so a `//` inside one — every `https://` URL has one — survives.
        var j = i + 1;
        while (j < n) {
          if (s.charAt(j) === '\\') { j += 2; continue; }
          if (s.charAt(j) === '"') break;
          j++;
        }
        out += s.slice(i, Math.min(j + 1, n));
        i = j + 1;
        continue;
      }
      if (c === '/' && s.charAt(i + 1) === '/') {
        var nl = s.indexOf('\n', i);
        if (nl === -1) break;
        i = nl;
        continue;
      }
      if (c === '/' && s.charAt(i + 1) === '*') {
        var end = s.indexOf('*/', i + 2);
        i = end === -1 ? n : end + 2;
        continue;
      }
      out += c;
      i++;
    }
    out = out.replace(/,\s*([}\]])/g, '$1');
    try { return JSON.parse(out); } catch (e) { return null; }
  }

  function stripTags(html) {
    return String(html || '').replace(/<[^>]*>/g, '').replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"').replace(/\s+/g, ' ').trim();
  }

  // ---- CatVod result builders ------------------------------------------
  // Keeps every spider from hand-rolling the same JSON, and keeps the shape the app already parses.
  function vod(item) {
    return {
      vod_id: String(item.vod_id === undefined ? '' : item.vod_id),
      vod_name: item.vod_name || '',
      vod_pic: item.vod_pic || '',
      vod_remarks: item.vod_remarks || ''
    };
  }
  var result = {
    list: function (items) { return { list: (items || []).map(vod) }; },
    page: function (items, page, pagecount, limit, total) {
      return {
        list: (items || []).map(vod),
        page: parseInt(page, 10) || 1,
        pagecount: pagecount === undefined ? 9999 : pagecount,
        limit: limit === undefined ? ((items || []).length || 20) : limit,
        total: total === undefined ? 999999 : total
      };
    },
    home: function (classes, items, filters) {
      var out = { 'class': (classes || []).map(function (c) {
        return { type_id: String(c.type_id), type_name: String(c.type_name) };
      }) };
      if (items) out.list = items.map(vod);
      if (filters) out.filters = filters;
      return out;
    },
    detail: function (item) { return { list: [item] }; },
    play: function (url, parse_, headers) {
      var out = { parse: parse_ ? 1 : 0, url: url };
      if (headers) out.header = headers;
      return out;
    }
  };

  return {
    req: req, get: get, post: post, encodeForm: encodeForm,
    enc: enc, dec: dec, base64: base64,
    aesDecrypt: aesDecrypt, aesEncrypt: aesEncrypt, desDecrypt: desDecrypt,
    aesEncryptIV: aesEncryptIV, aesDecryptIV: aesDecryptIV,
    md5: md5, sha1: sha1, sha256: sha256, hmac: hmac,
    local: local, now: now, timestamp: timestamp, random: random, match: match,
    parse: parse, select: select, text: textOf, pdfh: pdfh, pdfa: pdfa, pd: pd, urljoin: urljoin,
    cut: cut, cut1: cut1, stripTags: stripTags, parseJSON: parseJSON,
    result: result
  };
})();
