# What the bundled third-party packages can actually do, checked at launch in Debug builds.
#
# An import proves little on its own. pycryptodome imports its Python half and only loads a native
# module when a cipher is built; lxml is one native module behind a pure-Python package. So every
# check here exercises the API the configured spiders call (IOS-POC-37 inventory), against a
# published known answer wherever one exists, and a failing check is reported rather than raised.
#
# IOS-POC-37.


def _requests_stack():
    import os

    import certifi
    import charset_normalizer
    import idna
    import requests
    import urllib3
    assert idna.encode('例え.テスト') == b'xn--r8jz45g.xn--zckzah'
    assert charset_normalizer.from_bytes('中文測試文字'.encode('utf-8')).best() is not None
    assert os.path.isfile(certifi.where())
    return f'requests {requests.__version__}, urllib3 {urllib3.__version__}'


def _stdlib_https_trust():
    import ssl

    import certifi
    # What `urllib.request` verifies with. It has to trust exactly the certifi bundle that
    # webhtv_runtime installs; anything else is OpenSSL's /etc/ssl, which an iOS app cannot use.
    # IOS-POC-37.2.
    reference = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    reference.load_verify_locations(certifi.where())
    stats = ssl.create_default_context().cert_store_stats()
    assert stats['x509_ca'] > 0 and stats == reference.cert_store_stats(), stats
    return f"stdlib ssl trusts certifi ({stats['x509_ca']} CAs)"


def _crypto_symmetric():
    import hashlib

    from Crypto.Cipher import AES, ARC4
    from Crypto.Hash import MD5, SHA1, SHA256
    from Crypto.Util.Padding import pad, unpad
    h = bytes.fromhex
    # FIPS-197 appendix C.1.
    ecb = AES.new(h('000102030405060708090a0b0c0d0e0f'), AES.MODE_ECB)
    assert ecb.encrypt(h('00112233445566778899aabbccddeeff')) == h('69c4e0d86a7b0430d8cdb78070b4c55a')
    # NIST SP 800-38A F.2.1.
    key, iv = h('2b7e151628aed2a6abf7158809cf4f3c'), h('000102030405060708090a0b0c0d0e0f')
    block = h('6bc1bee22e409f96e93d7e117393172a')
    assert AES.new(key, AES.MODE_CBC, iv).encrypt(block) == h('7649abac8119b246cee98e9b12e9197d')
    # GCM spec test case 2: zero key, zero IV, one zero block.
    gcm = AES.new(bytes(16), AES.MODE_GCM, nonce=bytes(12))
    sealed, tag = gcm.encrypt_and_digest(bytes(16))
    assert (sealed, tag) == (h('0388dace60b6a392f328c2b971b2fe78'), h('ab6e47d42cec13bdf53a67b21257bddf'))
    assert AES.new(bytes(16), AES.MODE_GCM, nonce=bytes(12)).decrypt_and_verify(sealed, tag) == bytes(16)
    padded = pad(b'abc', AES.block_size)
    assert padded == b'abc' + b'\x0d' * 13 and unpad(padded, AES.block_size) == b'abc'
    # The RC4 vector everyone quotes: key "Key", plaintext "Plaintext".
    assert ARC4.new(b'Key').encrypt(b'Plaintext') == h('bbf316e8d940af0ad3')
    for ours, theirs in ((MD5, 'md5'), (SHA1, 'sha1'), (SHA256, 'sha256')):
        assert ours.new(b'webhtv').hexdigest() == hashlib.new(theirs, b'webhtv').hexdigest()
    import Crypto
    return f'pycryptodome {Crypto.__version__}: AES ECB/CBC/GCM, pad, ARC4, MD5/SHA1/SHA256'


def _crypto_rsa():
    from Crypto.Cipher import PKCS1_OAEP, PKCS1_v1_5
    from Crypto.Hash import SHA256
    from Crypto.PublicKey import RSA
    from Crypto.Signature import pkcs1_15
    key = RSA.generate(1024)
    public = RSA.import_key(key.publickey().export_key())
    private = RSA.import_key(key.export_key())
    message = b'webhtv'
    assert PKCS1_v1_5.new(private).decrypt(PKCS1_v1_5.new(public).encrypt(message), None) == message
    assert PKCS1_OAEP.new(private).decrypt(PKCS1_OAEP.new(public).encrypt(message)) == message
    digest = SHA256.new(message)
    pkcs1_15.new(public).verify(digest, pkcs1_15.new(private).sign(digest))  # raises when wrong
    return 'RSA import_key, PKCS1_v1_5, PKCS1_OAEP, pkcs1_15 sign/verify'


def _bs4():
    import bs4
    soup = bs4.BeautifulSoup('<div class="a"><a href="/x">片名</a></div>', 'html.parser')
    link = soup.select('div.a a')[0]  # select() is soupsieve
    assert (link['href'], link.get_text()) == ('/x', '片名')
    return f'beautifulsoup4 {bs4.__version__} (html.parser + soupsieve)'


def _lxml():
    from lxml import etree
    tree = etree.HTML('<div><a href="/x">片名</a></div>')
    assert tree.xpath('//a/@href') == ['/x'] and tree.xpath('//a/text()') == ['片名']
    parsed = etree.fromstring('<ul><li>a</li></ul>', etree.HTMLParser())
    assert parsed.xpath('string(//li)') == 'a'
    # GBK bytes decoded by libxml2 through the SDK's iconv — what a GB2312/GBK site's raw body needs.
    page = '<html><head><meta charset="gbk"></head><body><p>中文</p></body></html>'.encode('gbk')
    assert etree.HTML(page).xpath('//p/text()') == ['中文']
    version = '.'.join(map(str, etree.LXML_VERSION[:3]))
    libxml2 = '.'.join(map(str, etree.LIBXML_VERSION))
    libxslt = '.'.join(map(str, etree.LIBXSLT_VERSION))
    return f'lxml {version}, libxml2 {libxml2}, libxslt {libxslt}'


def _pyquery():
    from pyquery import PyQuery
    doc = PyQuery('<ul><li class="x"><a href="/p">第一集</a></li><li>b</li></ul>')
    assert doc('li.x a').attr('href') == '/p' and doc('li.x').text() == '第一集'
    assert [PyQuery(li).text() for li in doc('li')] == ['第一集', 'b']
    import pyquery
    return 'pyquery + cssselect: selectors, attr, text'


def _base_html():
    from base.spider import Spider
    assert Spider().html('<p>x</p>').xpath('//p/text()') == ['x']
    return 'base.spider.html()'


CHECKS = [
    ('requests', _requests_stack),
    ('ssl', _stdlib_https_trust),
    ('Crypto', _crypto_symmetric),
    ('Crypto.RSA', _crypto_rsa),
    ('bs4', _bs4),
    ('lxml', _lxml),
    ('pyquery', _pyquery),
    ('base.html', _base_html),
]


def run():
    results = []
    for name, check in CHECKS:
        try:
            results.append({'name': name, 'ok': True, 'detail': check()})
        except Exception as error:  # the failure is the report
            results.append({'name': name, 'ok': False, 'detail': f'{type(error).__name__}: {error}'})
    return results
