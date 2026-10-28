# W-202: `getCache`/`setCache` read back the way Android's chaquo base does, and `webhtv_runtime.proxy`
# turns a `localProxy` answer into the text the Swift bridge decodes. Host-runnable, stdlib only:
#
#     python3.13 -m unittest discover -s ios/Tests/Python
import base64
import json
import pathlib
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'WebHTVApp/Python'))
import webhtv_runtime  # noqa: E402

SCRIPT = '''
import json
from base.spider import Spider

class Spider(Spider):
    def action(self, action):
        op, _, value = action.partition('=')
        if op == 'set':
            key, _, raw = value.partition(':')
            self.setCache(key, json.loads(raw))
            return ''
        return json.dumps({'value': self.getCache(value)})

    def getProxyUrl_(self):
        return self.getProxyUrl()

    def localProxy(self, param):
        kind = param.get('kind')
        if kind == 'bytes':
            return [206, 'video/mp4', b'\\x00\\x01\\x02', {'Content-Range': 'bytes 0-2/10'}]
        if kind == 'text':
            return [200, 'application/dash+xml', '<BaseURL>' + self.getProxyUrl() + '&type=media</BaseURL>']
        if kind == 'base64':
            return [200, 'image/png', 'data:image/png;base64,' + 'aGk=', None, 1]
        return [404, 'text/plain', None]
'''


def call(handle, name, *args):
    answer = json.loads(webhtv_runtime.invoke(handle, name, json.dumps(list(args))))
    assert answer['ok'], answer
    return answer['value']


def proxy(handle, params):
    answer = json.loads(webhtv_runtime.proxy(handle, json.dumps(params)))
    assert answer['ok'], answer
    value = json.loads(answer['value'])
    value['body'] = base64.b64decode(value['body'])
    return value


class LocalProxyTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.assertTrue(json.loads(webhtv_runtime.load('P', 'site-p', self.root.name, SCRIPT))['ok'])

    def tearDown(self):
        webhtv_runtime.unload('P')
        self.root.cleanup()

    def get(self, key):
        return json.loads(call('P', 'action', 'get=' + key))['value']

    def set(self, key, value):
        call('P', 'action', 'set=%s:%s' % (key, json.dumps(value)))

    def test_cache_round_trips_objects_like_android(self):
        self.set('d', {'a': 1, 'expires': 9})
        self.set('l', [1, 2])
        self.set('s', 'plain')
        self.set('n', 42)
        self.assertEqual(self.get('d'), {'a': 1, 'expires': 9})
        self.assertEqual(self.get('l'), [1, 2])
        self.assertEqual(self.get('s'), 'plain')
        self.assertEqual(self.get('n'), '42')
        self.assertIsNone(self.get('missing'))

    def test_an_expired_entry_is_none_and_deleted(self):
        self.set('old', {'expiresAt': int(time.time()) - 5})
        self.set('new', {'expiresAt': int(time.time()) + 60})
        self.assertIsNone(self.get('old'))
        self.assertEqual(self.get('new')['expiresAt'] > 0, True)
        stored = json.loads((pathlib.Path(self.root.name) / 'site-p.json').read_text())
        self.assertNotIn('old', stored)

    def test_get_proxy_url_is_androids(self):
        self.assertEqual(call('P', 'getProxyUrl_'), 'http://127.0.0.1:9978/proxy?do=py')

    def test_proxy_answers_bytes_text_and_base64(self):
        raw = proxy('P', {'kind': 'bytes'})
        self.assertEqual((raw['code'], raw['mime'], raw['body']), (206, 'video/mp4', b'\x00\x01\x02'))
        self.assertEqual(raw['headers'], {'Content-Range': 'bytes 0-2/10'})
        text = proxy('P', {'kind': 'text'})
        self.assertEqual(text['body'], b'<BaseURL>http://127.0.0.1:9978/proxy?do=py&type=media</BaseURL>')
        self.assertEqual(text['headers'], {})
        self.assertEqual(proxy('P', {'kind': 'base64'})['body'], b'hi')
        self.assertEqual(proxy('P', {})['body'], b'')


if __name__ == '__main__':
    unittest.main()
