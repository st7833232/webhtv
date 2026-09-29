# The Swift side's only entry point into Python.
#
# Everything crosses as strings, because that is already the `SpiderRuntime` contract: text in, text
# out. Keeping the bridge to two C strings in and one out means Swift never touches a `PyObject`
# beyond the call itself, which is the whole reason this file exists rather than the marshalling
# living in Swift.
#
# A CatVod Python spider returns dicts, not JSON text, unlike the Java and JavaScript ports. Turning
# them into the strings the rest of the app already consumes is this file's other job.
#
# IOS-POC-7G.
import json
import os
import re
import ssl
import sys
import traceback
import types

import base.spider


# Stdlib `ssl` looks for CAs where OpenSSL was compiled to look, /etc/ssl, which is not where an iOS
# app's trust store is. So a script that calls `urllib.request` itself (MissAV) failed every HTTPS
# certificate check, while `requests` passed because it brings certifi. Android's Chaquopy has the
# same gap and closes it by replacing this one method with its own bundle; this is that, with the
# certifi bundle `requests` already uses. An explicit cafile/capath/cadata never reaches it.
# IOS-POC-37.2.
def _load_bundled_cas(self):
    import certifi
    self.load_verify_locations(certifi.where())


ssl.SSLContext.set_default_verify_paths = _load_bundled_cas

_spiders = {}


def _ok(value):
    return json.dumps({'ok': True, 'value': value}, ensure_ascii=False)


def _fail(message):
    return json.dumps({'ok': False, 'error': message}, ensure_ascii=False)


def load(handle, site_key, cache_dir, source):
    """Run a spider script in its own module and keep the instance under `handle`.

    Fail closed: a syntax error, a missing `Spider` class, or anything raised while constructing it
    leaves nothing registered, and the caller gets the reason.
    """
    try:
        module = types.ModuleType(f'webhtv_spider_{handle}')
        module.__dict__['__name__'] = f'webhtv_spider_{handle}'
        # Android loads a script with `SourceFileLoader` from the file it wrote it to, so a script
        # may read `__file__` — 映像星球 puts its own directory on sys.path at import. The path
        # names where Android would have put it; nothing is written there. IOS-POC-37.
        safe = re.sub(r'[^A-Za-z0-9_.-]', '_', site_key or 'unknown')
        module.__dict__['__file__'] = os.path.join(cache_dir or '.', 'scripts', f'{safe}.py')
        # `<spider:key>` rather than a path: it is what shows up in a traceback, and a script's own
        # filename would be a lie — the source arrived over HTTP.
        exec(compile(source, f'<spider:{site_key}>', 'exec'), module.__dict__)

        # Any class named Spider, as on Android (`load_module().Spider()`): 永乐视频 defines a
        # plain `class Spider:` with every method itself and never imports base.spider. IOS-POC-37.
        spider_class = module.__dict__.get('Spider')
        if not isinstance(spider_class, type):
            return _fail('the script defines no Spider class')

        spider = spider_class()
        # The cache context belongs to this instance, never to the module: two sites loaded side by
        # side must not see each other's key or directory (IOS-POC-37.1).
        spider._webhtv_site_key = site_key
        spider._webhtv_cache_dir = cache_dir
        _spiders[handle] = spider
        return _ok('')
    except Exception:
        _spiders.pop(handle, None)
        return _fail(traceback.format_exc(limit=6))


def invoke(handle, name, args_json):
    """Call one method and bring its answer back as text.

    `None` becomes an empty string, a string passes through, and anything else is JSON — which is
    what a CatVod spider actually returns and what the app already knows how to decode.
    """
    spider = _spiders.get(handle)
    if spider is None:
        return _fail(f'no spider loaded for handle {handle}')
    try:
        method = getattr(spider, name, None)
        if method is None or not callable(method):
            return _fail(f'the spider does not implement {name}')
        result = method(*json.loads(args_json))
        # `init` and `destroy` are void in the CatVod contract: Android discards what they return,
        # and so does the Swift side. A script whose `init` ends in `return self` (短剧聚合 does)
        # must not fail on trying to turn its own instance into JSON. IOS-POC-37.
        if result is None or name in ('init', 'destroy'):
            return _ok('')
        if isinstance(result, bool):
            # `isVideoFormat` and `manualVideoCheck` are the two bools in the contract, and the
            # Swift side reads them as "true"/"false" rather than as JSON.
            return _ok('true' if result else 'false')
        if isinstance(result, str):
            return _ok(result)
        if isinstance(result, bytes):
            return _ok(result.decode('utf-8', errors='replace'))
        return _ok(json.dumps(result, ensure_ascii=False))
    except Exception:
        return _fail(traceback.format_exc(limit=6))


def unload(handle):
    spider = _spiders.pop(handle, None)
    if spider is None:
        return _ok('')
    try:
        spider.destroy()
    except Exception:
        pass  # a spider that cannot tidy up must not keep the app from dropping it
    return _ok('')


def dependencies():
    """The bundled packages' known-answer checks (`webhtv_selfcheck`). Debug launch check only."""
    try:
        import webhtv_selfcheck
        return _ok(json.dumps(webhtv_selfcheck.run(), ensure_ascii=False))
    except Exception:
        return _fail(traceback.format_exc(limit=6))


def diagnostics():
    """What the runtime can see. Used by the launch check, not by the app's normal paths."""
    return _ok(json.dumps({
        'version': sys.version.split()[0],
        'prefix': sys.prefix,
        'loaded': sorted(_spiders.keys()),
        'path_entries': len(sys.path),
    }, ensure_ascii=False))
