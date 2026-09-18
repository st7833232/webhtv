/**
 * drpy2 → `SpiderRuntime`.
 *
 * Not an engine. The engine is `drpy_libs/drpy2.min.js`, fetched from the configuration's own
 * origin and hash-verified by `DrpyEngine` before any of it is evaluated; by the time this script
 * loads it is already in the same `JSContext`, registered under `__drpyModules["drpy2.min"]`.
 * This file is the twenty lines of name-mapping between its default export and the thirteen-method
 * contract `Spider.java` defines, which is what every ported `csp_*` spider already answers.
 *
 * drpy2's own export is:
 *
 *   {runMain, getRule, init, home, homeVod, category, detail, play, search,
 *    proxy, sniffer, isVideo, fixAdM3u8Ai, DRPY}
 *
 * so the mapping is close to one for one. It brings its own HTML parsing (cheerio) and its own
 * crypto (crypto-js, node-rsa, jsencrypt), and therefore does not use `host.pdfh` / `pdfa` / `pd`
 * at all — the only things it needs from us are HTTP and storage, which `CatVodHost` already has.
 */
var spider = (function () {
  'use strict';

  function engine() {
    var modules = globalThis.__drpyModules || {};
    var drpy = modules['drpy2.min'];
    // Fail closed: a missing engine must be an error naming itself, never a spider that loads and
    // then answers nothing.
    if (!drpy) throw new Error('drpy: engine not loaded');
    return drpy;
  }

  /** drpy2 answers objects; `JavaScriptSpiderRuntime` serialises either shape, so pass them on. */
  function call(name, args) {
    var drpy = engine();
    if (typeof drpy[name] !== 'function') return '';
    return drpy[name].apply(drpy, args || []);
  }

  return {
    /**
     * `extend` is the site's rule script, already fetched and origin-checked by `DrpyEngine.rule`.
     * drpy2's own `init` accepts the text, so nothing here reaches the network.
     */
    init: function (extend) { return call('init', [extend]); },

    homeContent: function (filter) { return call('home', [filter]); },
    homeVideoContent: function () { return call('homeVod', []); },
    categoryContent: function (tid, page, filter, extend) {
      return call('category', [tid, page, filter, extend]);
    },
    detailContent: function (ids) { return call('detail', [String(ids[0])]); },
    searchContent: function (key, quick, page) { return call('search', [key, quick, page]); },
    playerContent: function (flag, id, vipFlags) { return call('play', [flag, id, vipFlags]); },

    isVideoFormat: function (url) { return call('isVideo', [url]); },
    manualVideoCheck: function () { return false; },
    proxy: function (params) { return call('proxy', [params]); },

    // `sniffer` and `fixAdM3u8Ai` are drpy2's own extras with no place in the Spider ABI: iOS
    // sniffs natively above the spider (IOS-POC-5G), and m3u8 ad stripping is explicitly out of
    // scope. Deliberately not exposed rather than mapped to something that would misreport.
    destroy: function () {}
  };
})();

module.exports = spider;
