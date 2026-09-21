# The iOS half of CatVod's `base.spider`, the module every Python spider imports.
#
# Modelled on the Android original at chaquo/src/main/python/base/spider.py, which is read-only
# reference here. The differences are deliberate and named below rather than silently absent.
#
# What the 31 same-origin scripts in the user's configuration actually call, counted rather than
# assumed: fetch 47, post 20, log 16, getCache 5, setCache 3, getProxyUrl 3. Everything else in this
# file exists because the Android original has it and a script may reach for it.
#
# IOS-POC-7G.
import json
import re
import urllib.error
import urllib.parse
import urllib.request
from abc import ABCMeta


class SpiderError(Exception):
    """Raised for a capability iOS does not have. Named, so a failure says which one."""


class _Response:
    """The part of `requests.Response` the scripts touch, over urllib.

    ponytail: `requests` itself is pure Python and could be vendored — 23 of the 31 scripts import
    it directly and will need that. Those 23 are blocked on the packaging, not on this class; the
    8 that only go through `self.fetch` are not, and this is what unblocks them today. Upgrade path
    is to drop real `requests` on sys.path, at which point this class is only used if it is missing.
    """

    def __init__(self, url, status, headers, body):
        self.url = url
        self.status_code = status
        self.headers = headers
        self.content = body
        self.encoding = 'utf-8'
        self.cookies = {}

    @property
    def text(self):
        return self.content.decode(self.encoding, errors='replace')

    def json(self):
        return json.loads(self.text)

    def __repr__(self):
        return f'<Response [{self.status_code}]>'


def _request(method, url, params=None, data=None, json_body=None, headers=None, timeout=5):
    if params:
        url = url + ('&' if '?' in url else '?') + urllib.parse.urlencode(params)
    body = None
    headers = dict(headers or {})
    if json_body is not None:
        body = json.dumps(json_body).encode()
        headers.setdefault('Content-Type', 'application/json')
    elif data is not None:
        body = urllib.parse.urlencode(data).encode() if isinstance(data, dict) else (
            data.encode() if isinstance(data, str) else data)
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as answer:
            return _Response(url, answer.status, dict(answer.headers), answer.read())
    except urllib.error.HTTPError as error:
        # A spider reads the body of a 403 as often as of a 200, so an error is a response.
        return _Response(url, error.code, dict(error.headers or {}), error.read())


class Spider(metaclass=ABCMeta):
    """The contract a script subclasses. Every method has a do-nothing body, as on Android."""

    def __init__(self):
        pass

    def init(self, extend=""):
        pass

    def homeContent(self, filter):
        pass

    def homeVideoContent(self):
        pass

    def categoryContent(self, tid, pg, filter, extend):
        pass

    def detailContent(self, ids):
        pass

    def searchContent(self, key, quick, pg="1"):
        pass

    def playerContent(self, flag, id, vipFlags):
        pass

    def liveContent(self, url):
        pass

    def localProxy(self, param):
        pass

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self):
        return False

    def action(self, action):
        pass

    def destroy(self):
        pass

    def getName(self):
        return type(self).__name__

    def getDependence(self):
        return []

    # --- host services -------------------------------------------------------------------------

    def fetch(self, url, params=None, cookies=None, headers=None, timeout=5, verify=True,
              stream=False, allow_redirects=True):
        return _request('GET', url, params=params, headers=headers, timeout=timeout)

    def post(self, url, params=None, data=None, json=None, cookies=None, headers=None, timeout=5,
             verify=True, stream=False, allow_redirects=True):
        return _request('POST', url, params=params, data=data, json_body=json, headers=headers,
                        timeout=timeout)

    def log(self, msg):
        if isinstance(msg, (dict, list)):
            print('[spider]', json.dumps(msg, ensure_ascii=False))
        else:
            print('[spider]', msg)

    # A JSON file per site, under a directory the runtime hands over.
    #
    # ponytail: not the `SpiderStorage` the JavaScript spiders use. Reaching that would mean
    # bridging Swift callables into Python for two string operations, and no site is both a
    # JavaScript and a Python spider, so there is no shared state to keep. Upgrade path is the
    # bridge, if these two ever need to agree with anything.
    def _cache_file(self):
        import os
        os.makedirs(_cache_dir, exist_ok=True)
        safe = re.sub(r'[^A-Za-z0-9_.-]', '_', _site_key or 'unknown')
        return os.path.join(_cache_dir, f'{safe}.json')

    def _cache_all(self):
        try:
            with open(self._cache_file(), 'r', encoding='utf-8') as handle:
                return json.load(handle)
        except (OSError, ValueError):
            return {}

    def getCache(self, key):
        if not _cache_dir:
            return ''
        return self._cache_all().get(key, '')

    def setCache(self, key, value):
        if not _cache_dir:
            return
        store = self._cache_all()
        store[key] = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
        try:
            with open(self._cache_file(), 'w', encoding='utf-8') as handle:
                json.dump(store, handle, ensure_ascii=False)
        except OSError:
            pass  # a cache that cannot be written is not a reason to fail a page

    def getProxyUrl(self, local=True):
        # Android answers with its local proxy server's address. iOS runs no such server — the
        # project ruled one out — so this is empty and the three scripts that read it degrade
        # rather than receive a URL that goes nowhere. Same handling as the WebHome bridge's
        # existing deviations.
        return ''

    # --- pure helpers, copied from the Android original ---------------------------------------

    def regStr(self, reg, src, group=1):
        found = re.search(reg, src)
        return found.group(group) if found else ''

    def removeHtmlTags(self, src):
        return re.sub(r'<[^>]+>', '', src)

    def cleanText(self, src):
        return re.sub(
            '[\U0001F600-\U0001F64F\U0001F300-\U0001F5FF\U0001F680-\U0001F6FF\U0001F1E0-\U0001F1FF]',
            '', src)

    def str2json(self, text):
        return json.loads(text)

    def json2str(self, value):
        return json.dumps(value, ensure_ascii=False)

    # --- the Tier-1 boundary, stated rather than missing ---------------------------------------

    def html(self, content):
        raise SpiderError('html() needs lxml, which is a C extension and outside Tier 1')

    def loadSpider(self, name):
        raise SpiderError('loadSpider() is not implemented on iOS')

    def loadModule(self, name):
        raise SpiderError('loadModule() is not implemented on iOS')


# Installed by `webhtv_runtime.load`, per site.
_cache_dir = ''
_site_key = ''
