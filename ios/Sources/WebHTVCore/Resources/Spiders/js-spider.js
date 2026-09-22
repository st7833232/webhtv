/**
 * CatVod/TVBox **JS spider** → `SpiderRuntime`.
 *
 * The sibling of `drpy-bridge.js`, for the other JavaScript contract TVBox carries. A drpy rule
 * exposes a `rule` object for an engine to read; a JS spider is the spider itself and announces
 * that by defining `__jsEvalReturn()`, which returns
 * `{init, home, homeVod, category, detail, play, search}`.
 *
 * **There is no engine here.** That is the whole reason this file is twenty lines: `DrpyEngine`
 * fetches, origin-checks and rewrites the script, `moduleRuntime` already supplies the globals such
 * a script expects — `req` (with drpy's own `res.content` mapping), `pdfh`/`pdfa`/`pd`, `local`,
 * `print`/`log` — and `CatVodHost` is underneath all of it. A JS spider gains **no** native
 * capability over a `csp_*` port: same `JSContext`, same host, same cookie jar, same storage
 * namespace. It simply does not download drpy's 1.2 MB of libraries, because it does not use them.
 *
 * Measured against `drpy_js/麻豆.min.js` (IOS-POC-10T): the script needs exactly one global, `req`,
 * and reads exactly one field off its answer, `content`. Both were already here.
 */
var spider = (function () {
  'use strict';

  var api = null;

  function methods() {
    if (api) return api;
    var modules = globalThis.__drpyModules || {};
    var module = modules[globalThis.__jsSpiderModule] || {};
    var factory = module.__jsEvalReturn || globalThis.__jsEvalReturn;
    // Fail closed, and by name. A bridge that loaded and then answered nothing is the failure
    // IOS-POC-10P was diagnosing; it must not be reintroduced from this side.
    if (typeof factory !== 'function') throw new Error('js spider: no __jsEvalReturn');
    api = factory() || {};
    return api;
  }

  function call(name, args) {
    var fns = methods();
    if (typeof fns[name] !== 'function') return '';
    return fns[name].apply(fns, args || []);
  }

  return {
    /**
     * **An object, not text.** This is the one place the two JavaScript contracts genuinely differ:
     * `Spider.java` hands `init` a string and drpy2 accepts one, but a JS spider is handed the
     * parsed `ext` and writes to it — 麻豆's `init` does `extend.stype = '3'`, which on a string
     * primitive is a silent no-op in sloppy mode and a TypeError in strict. So parse when the text
     * is JSON and pass an object either way; a spider reading a plain-string `ext` still finds it
     * under the same name the Android host uses.
     */
    init: function (extend) {
      var value = {};
      if (extend) {
        try { value = JSON.parse(extend); } catch (e) { value = { ext: extend }; }
        if (value === null || typeof value !== 'object') { value = { ext: extend }; }
      }
      return call('init', [value]);
    },

    homeContent: function (filter) { return call('home', [filter]); },
    homeVideoContent: function () { return call('homeVod', []); },
    categoryContent: function (tid, page, filter, extend) {
      return call('category', [tid, page, filter, extend]);
    },
    detailContent: function (ids) { return call('detail', [String(ids[0])]); },
    searchContent: function (key, quick, page) { return call('search', [key, quick, page]); },
    playerContent: function (flag, id, vipFlags) { return call('play', [flag, id, vipFlags]); }

    // The contract has seven methods and that is all this maps. `isVideoFormat`,
    // `manualVideoCheck`, `liveContent` and `destroy` are **deliberately absent**:
    // `JavaScriptSpiderRuntime` already answers a missing method with the base class's own default,
    // so writing them here would be four lines restating what the layer below does. iOS also sniffs
    // natively above the spider (IOS-POC-5G), so there is nothing for `isVideoFormat` to add.
  };
})();

module.exports = spider;
