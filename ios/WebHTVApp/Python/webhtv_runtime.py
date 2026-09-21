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
import sys
import traceback
import types

import base.spider

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
        base.spider._site_key = site_key
        base.spider._cache_dir = cache_dir

        module = types.ModuleType(f'webhtv_spider_{handle}')
        module.__dict__['__name__'] = f'webhtv_spider_{handle}'
        # `<spider:key>` rather than a path: it is what shows up in a traceback, and a script's own
        # filename would be a lie — the source arrived over HTTP.
        exec(compile(source, f'<spider:{site_key}>', 'exec'), module.__dict__)

        spider_class = module.__dict__.get('Spider')
        if spider_class is None:
            return _fail('the script defines no Spider class')
        if not isinstance(spider_class, type) or not issubclass(spider_class, base.spider.Spider):
            return _fail('the script\'s Spider does not subclass base.spider.Spider')

        _spiders[handle] = spider_class()
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
        if result is None:
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


def diagnostics():
    """What the runtime can see. Used by the launch check, not by the app's normal paths."""
    return _ok(json.dumps({
        'version': sys.version.split()[0],
        'prefix': sys.prefix,
        'loaded': sorted(_spiders.keys()),
        'path_entries': len(sys.path),
    }, ensure_ascii=False))
