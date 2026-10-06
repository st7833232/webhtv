#!/usr/bin/env python3
"""Offline check of the IOS-POC-55 rules in `audit_spider_jars.py` on small decompiled-looking trees.

    python3 scripts/test_spider_compat.py
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from audit_spider_jars import Fingerprinter, Tree, classify, compare, decide  # noqa: E402

EXTERNAL = {"Spider", "String", "HashMap", "Map", "put", "MessageDigest", "getInstance", "digest", "getBytes",
            "JSONObject", "toString", "Override", "StringBuilder", "append", "Exception", "post"}

SPIDER = """package com.github.catvod.spider;
import com.github.catvod.crawler.Spider;
import com.github.catvod.spider.merge.%(pkg)s.%(helper)s;
import java.util.HashMap;
import java.util.Map;
public class %(name)s extends Spider {
    private String %(field)s = "https://api.example.com";
    private Map<String, String> %(headers)s() {
        HashMap map = new HashMap();
        map.put("User-Agent", "okhttp/3.12.0");
        %(referer)s
        return map;
    }
    @Override
    public String homeContent(boolean z) {
        String %(local)s = %(helper)s.%(sign)s("%(name)s" + this.%(field)s + "/api/home");
        return %(helper)s.%(post)s(this.%(field)s + "/api/home?sign=" + %(local)s, %(headers)s());
    }
}
"""
HELPER = """package com.github.catvod.spider.merge.%(pkg)s;
import java.security.MessageDigest;
import java.util.Map;
public class %(helper)s {
    public static String %(md5)s(String str) throws Exception {
        return new String(MessageDigest.getInstance("%(algo)s").digest(str.getBytes()));
    }
    public static String %(sha)s(String str) throws Exception {
        return new String(MessageDigest.getInstance("SHA-1").digest(str.getBytes()));
    }
    public static String %(post)s(String str, Map map) {
        return new JSONObject().toString();
    }
}
"""
SHIM = """package com.github.catvod.spider;
public class %(name)s extends Loader {
}
"""


def tree(root, name, pkg="a", helper="b", field="a", headers="c", local="str", md5="d", sha="e", post="f",
         sign=None, algo="MD5", referer='map.put("Referer", "https://api.example.com/");'):
    values = dict(name=name, pkg=pkg, helper=helper, field=field, headers=headers, local=local, md5=md5,
                  sha=sha, post=post, sign=sign or md5, algo=algo, referer=referer)
    spider = os.path.join(root, "sources/com/github/catvod/spider")
    os.makedirs(os.path.join(spider, "merge", pkg), exist_ok=True)
    open(os.path.join(spider, name + ".java"), "w").write(SPIDER % values)
    open(os.path.join(spider, "merge", pkg, helper + ".java"), "w").write(HELPER % values)
    return Fingerprinter(Tree(os.path.join(root, "sources")), EXTERNAL).fingerprint(
        "com.github.catvod.spider." + name)


def main():
    with tempfile.TemporaryDirectory() as work:
        def at(label, **kwargs):
            return tree(os.path.join(work, label), **kwargs)

        base = at("base", name="Orig")
        baselines = {"Orig": base}

        # Renaming the class, its helper class and package, every method, field and local changes nothing.
        renamed = at("renamed", name="Copy", pkg="zz", helper="q", field="x", headers="y", local="s9",
                     md5="m", sha="n", post="p")
        assert compare(renamed, base) == [], compare(renamed, base)
        assert decide("Copy", renamed, "http-crypto", {"ported": set(), "aliases": {}}, baselines)["status"] == "candidate"

        # Looks the same, sends one header fewer: a request difference, reported, never mapped.
        lookalike = at("lookalike", name="Copy", referer="")
        reasons = compare(lookalike, base)
        assert reasons and any("Referer" in r for r in reasons), reasons
        decision = decide("Copy", lookalike, "http-crypto", {"ported": set(), "aliases": {}}, baselines)
        assert decision["status"] == "pending" and decision["closest"] == "Orig", decision

        # The class is byte-for-byte the same; only the helper it calls was updated (md5 -> sha-256).
        updated = at("updated", name="Copy", algo="SHA-256")
        reasons = compare(updated, base)
        assert any("helper 實作不同" in r for r in reasons), reasons

        # Calling the helper's *other* method is a signing difference even though every name is
        # obfuscated: calls are compared by what they call, not by what they are called.
        other_call = at("other_call", name="Copy", sign="e")
        assert compare(other_call, base), "a call to sha1 instead of md5 must not look identical"

        # Two adapters whose originals are the same protocol: no automatic choice.
        decision = decide("Copy", renamed, "http-crypto", {"ported": set(), "aliases": {}},
                          {"Orig": base, "Twin": at("twin", name="Twin")})
        assert decision["status"] == "pending" and decision["candidates"] == ["Orig", "Twin"], decision

        # The same class name in two JARs is two decisions, made on each JAR's own bytes.
        assert decide("Copy", renamed, None, {"ported": set(), "aliases": {}}, baselines)["status"] == "candidate"
        assert decide("Copy", lookalike, None, {"ported": set(), "aliases": {}}, baselines)["status"] == "pending"

        # An empty shim over an encrypted loader is pending, whatever its name suggests.
        shim_dir = os.path.join(work, "shim/sources/com/github/catvod/spider")
        os.makedirs(shim_dir)
        open(os.path.join(shim_dir, "OrigAmns.java"), "w").write(SHIM % {"name": "OrigAmns"})
        category, _, _ = classify(os.path.join(shim_dir, "OrigAmns.java"), False)
        decision = decide("OrigAmns", renamed, category, {"ported": set(), "aliases": {}}, baselines)
        assert decision["status"] == "pending" and "原生／加密載入" in decision["reasons"][0], decision

        # A name the app already drives keeps its binding and is only reported on.
        decision = decide("Orig", lookalike, "http-crypto", {"ported": {"Orig"}, "aliases": {}}, baselines)
        assert decision["status"] == "existing" and len(decision["reasons"]) > 1, decision
    print("ok: rename, lookalike, helper update, call target, ambiguity, per-JAR, protected, existing")


if __name__ == "__main__":
    main()
