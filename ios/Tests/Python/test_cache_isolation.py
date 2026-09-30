# IOS-POC-37.1: two Python spiders loaded side by side must not share `getCache`/`setCache` context.
#
# Drives the real `webhtv_runtime.load/invoke` the Swift bridge calls, with two sites that differ in
# both site key and cache directory, in the order A → B → A: A writes, B loads and writes the same
# key, then A reads and writes again. Host-runnable, stdlib only:
#
#     python3.13 -m unittest discover -s ios/Tests/Python
#
# The same A → B → A runs inside the app on the bundled CPython, through Swift, in PythonBoot.selfCheck.
#
# IOS-POC-37.3: the same isolation for a script that uses its cache inside `__init__`. Until then the
# runtime handed a spider its context only after constructing it, so the constructor read '' and its
# writes went nowhere.
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


# Reads a key and counts its own constructions in `__init__`, as a script that keeps a device id would.
SCRIPT_INIT = '''
from base.spider import Spider

class Spider(Spider):
    def __init__(self):
        self.boot = self.getCache('did')
        self.setCache('inits', str(int(self.getCache('inits') or 0) + 1))

    def action(self, action):
        op, _, value = action.partition('=')
        if op == 'boot':
            return self.boot
        if op == 'set':
            self.setCache('did', value)
            return 'ok'
        return self.getCache(op)
'''


def load(handle, site_key, directory, source=SCRIPT_INIT):
    answer = json.loads(webhtv_runtime.load(handle, site_key, str(directory), source))
    assert answer['ok'], answer


def stored(directory, site_key):
    return json.loads(pathlib.Path(directory, f'{site_key}.json').read_text())


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


class ConstructorCache(unittest.TestCase):
    def tearDown(self):
        for handle in list(webhtv_runtime._spiders):
            webhtv_runtime.unload(handle)

    def test_the_constructor_reads_and_writes_its_own_site(self):
        with tempfile.TemporaryDirectory() as root:
            pathlib.Path(root, 'site-a.json').write_text(json.dumps({'did': 'seed-a'}))
            load('A', 'site-a', root)
            self.assertEqual(call('A', 'boot'), 'seed-a')
            self.assertEqual(call('A', 'inits'), '1')
            self.assertEqual(stored(root, 'site-a'), {'did': 'seed-a', 'inits': '1'})

    def test_a_then_b_then_a_across_constructors_and_methods(self):
        # One script, three sites: B shares A's directory (the app keeps every site in one) under its
        # own key, C has a directory of its own. A is loaded again after both.
        with tempfile.TemporaryDirectory() as root:
            shared, own = pathlib.Path(root, 'shared'), pathlib.Path(root, 'own')
            load('A', 'site-a', shared)
            call('A', 'set=from-a')
            load('B', 'site-b', shared)
            load('C', 'site-c', own)
            self.assertEqual((call('B', 'boot'), call('C', 'boot')), ('', ''))
            call('B', 'set=from-b')
            call('C', 'set=from-c')
            load('A2', 'site-a', shared)
            self.assertEqual(call('A2', 'boot'), 'from-a')
            self.assertEqual(call('A2', 'inits'), '2')
            self.assertEqual([call(h, 'did') for h in ('A', 'B', 'C', 'A2')], ['from-a', 'from-b', 'from-c', 'from-a'])
            self.assertEqual([call(h, 'inits') for h in ('A', 'B', 'C')], ['2', '1', '1'])

            self.assertEqual(sorted(p.name for p in shared.iterdir()), ['site-a.json', 'site-b.json'])
            self.assertEqual(sorted(p.name for p in own.iterdir()), ['site-c.json'])
            self.assertEqual(stored(shared, 'site-a'), {'did': 'from-a', 'inits': '2'})
            self.assertEqual(stored(shared, 'site-b'), {'did': 'from-b', 'inits': '1'})
            self.assertEqual(stored(own, 'site-c'), {'did': 'from-c', 'inits': '1'})

            # The context is each instance's alone: nothing on its class, on base.spider or its class.
            import base.spider
            spider = webhtv_runtime._spiders['A']
            for owner in (type(spider), base.spider.Spider, base.spider):
                self.assertFalse(hasattr(owner, '_webhtv_site_key'), owner)
                self.assertFalse(hasattr(owner, '_webhtv_cache_dir'), owner)
            self.assertEqual((spider._webhtv_site_key, spider.getName()), ('site-a', 'Spider'))

    def test_construction_still_fails_closed(self):
        with tempfile.TemporaryDirectory() as root:
            broken = SCRIPT_INIT.replace("self.boot = self.getCache('did')", "raise RuntimeError('no')")
            answer = json.loads(webhtv_runtime.load('X', 'site-x', root, broken))
            self.assertFalse(answer['ok'])
            self.assertIn('RuntimeError: no', answer['error'])
            self.assertNotIn('X', webhtv_runtime._spiders)

    def test_a_spider_that_does_not_subclass_base_still_loads(self):
        # 永乐视频's shape (IOS-POC-37 B3): a plain class with its own constructor.
        plain = 'class Spider:\n    def __init__(self):\n        self.ready = True\n' \
                '    def action(self, action):\n        return str(self.ready)\n'
        with tempfile.TemporaryDirectory() as root:
            load('P', 'site-p', root, plain)
            self.assertEqual(call('P', 'x'), 'True')


if __name__ == '__main__':
    unittest.main()
