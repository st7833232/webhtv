# IOS-POC-37.1: two Python spiders loaded side by side must not share `getCache`/`setCache` context.
#
# Drives the real `webhtv_runtime.load/invoke` the Swift bridge calls, with two sites that differ in
# both site key and cache directory, in the order A → B → A: A writes, B loads and writes the same
# key, then A reads and writes again. Host-runnable, stdlib only:
#
#     python3.13 -m unittest discover -s ios/Tests/Python
#
# The same A → B → A runs inside the app on the bundled CPython, through Swift, in PythonBoot.selfCheck.
import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'WebHTVApp/Python'))
import webhtv_runtime  # noqa: E402

SCRIPT = '''
from base.spider import Spider

class Spider(Spider):
    def action(self, action):
        op, _, value = action.partition('=')
        if op == 'set':
            self.setCache('did', value)
            return 'ok'
        return self.getCache('did')
'''


def call(handle, value):
    answer = json.loads(webhtv_runtime.invoke(handle, 'action', json.dumps([value])))
    assert answer['ok'], answer
    return answer['value']


class CacheIsolation(unittest.TestCase):
    def test_a_then_b_then_a(self):
        with tempfile.TemporaryDirectory() as root:
            dir_a, dir_b = pathlib.Path(root, 'a'), pathlib.Path(root, 'b')
            self.assertTrue(json.loads(webhtv_runtime.load('A', 'site-a', str(dir_a), SCRIPT))['ok'])
            call('A', 'set=from-a')
            self.assertTrue(json.loads(webhtv_runtime.load('B', 'site-b', str(dir_b), SCRIPT))['ok'])
            call('B', 'set=from-b')
            # A after B loaded: A must still see its own key, its own directory and its own value.
            self.assertEqual(call('A', 'get'), 'from-a')
            call('A', 'set=from-a-again')
            self.assertEqual(call('B', 'get'), 'from-b')
            self.assertEqual(call('A', 'get'), 'from-a-again')

            self.assertEqual(sorted(p.name for p in dir_a.iterdir()), ['site-a.json'])
            self.assertEqual(sorted(p.name for p in dir_b.iterdir()), ['site-b.json'])
            self.assertEqual(json.loads((dir_a / 'site-a.json').read_text()), {'did': 'from-a-again'})
            self.assertEqual(json.loads((dir_b / 'site-b.json').read_text()), {'did': 'from-b'})
            for handle in ('A', 'B'):
                webhtv_runtime.unload(handle)


if __name__ == '__main__':
    unittest.main()
