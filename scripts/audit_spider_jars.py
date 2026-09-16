#!/usr/bin/env python3
"""Batch static audit of the CatVod `csp_*` spider JARs referenced by a TVBox config.

Answers one question per spider class: what would it take to reimplement this on iOS?

It never assumes a JAR is unportable because it holds DEX or ships a `.so`. It reads the DEX
type/string tables, decompiles with jadx, and classifies each class from what it actually
references. A class whose visible body is an empty shim is reported as `protected-payload`, which is
a statement about that JAR's loader, not about the spider's logic.

Usage:
    scripts/audit_spider_jars.py --config wang-movie.json --archive recha-main.zip --out build/audit
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import re
import shutil
import struct
import subprocess
import zipfile

# DEX type descriptors that tell us what a class needs from its host.
DEPENDENCY_MARKERS = {
    "okhttp": ["Lokhttp3/"],
    "jsoup": ["Lorg/jsoup/"],
    "gson": ["Lcom/google/gson/"],
    "orgjson": ["Lorg/json/"],
    "regex": ["Ljava/util/regex/"],
    "base64": ["Landroid/util/Base64;", "Ljava/util/Base64"],
    "crypto": ["Ljavax/crypto/"],
    "messagedigest": ["Ljava/security/MessageDigest;"],
    "cookie": ["Lokhttp3/Cookie", "Landroid/webkit/CookieManager;"],
    "webview": ["Landroid/webkit/WebView;", "Landroid/webkit/WebSettings;"],
    "reflection": ["Ljava/lang/reflect/"],
    "dynamicload": ["Ldalvik/system/DexClassLoader;", "Ldalvik/system/InMemoryDexClassLoader;",
                    "Ldalvik/system/PathClassLoader;", "Ldalvik/system/BaseDexClassLoader;"],
    "androidapi": ["Landroid/content/", "Landroid/os/", "Landroid/app/"],
}

# Shared CatVod helpers. A class using only these plus HTTP is a pure mapping job.
CATVOD_HELPERS = ["Lcom/github/catvod/net/OkHttp;", "Lcom/github/catvod/util/", "Lcom/github/catvod/bean/"]

NATIVE_SUFFIXES = (".so",)


def uleb128(data: bytes, offset: int) -> tuple[int, int]:
    result = shift = 0
    while True:
        byte = data[offset]
        offset += 1
        result |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            return result, offset


def read_dex(data: bytes) -> tuple[list[str], list[str]]:
    """Return (strings, type descriptors) from a classes.dex without any external tool."""
    string_ids_size, string_ids_off = struct.unpack_from("<II", data, 56)
    type_ids_size, type_ids_off = struct.unpack_from("<II", data, 64)
    strings = []
    for index in range(string_ids_size):
        offset = struct.unpack_from("<I", data, string_ids_off + 4 * index)[0]
        length, payload = uleb128(data, offset)
        strings.append(data[payload:payload + length].decode("utf-8", "replace"))
    types = [strings[struct.unpack_from("<I", data, type_ids_off + 4 * index)[0]]
             for index in range(type_ids_size)]
    return strings, types


def jar_inventory(path: str) -> dict:
    """`jar tf` equivalent plus `file`-style identification of every native payload."""
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        dex = [n for n in names if n.endswith(".dex")]
        native = [n for n in names if n.endswith(NATIVE_SUFFIXES)]
        # A .so renamed to hide it still starts with the ELF magic.
        hidden_native = []
        for name in names:
            if name in native or name.endswith((".dex", ".xml", ".properties")):
                continue
            try:
                head = archive.read(name)[:4]
            except Exception:
                continue
            if head[:4] == b"\x7fELF":
                hidden_native.append(name)
        strings: list[str] = []
        types: list[str] = []
        for entry in dex:
            s, t = read_dex(archive.read(entry))
            strings += s
            types += t
    return {"dex": dex, "native": native, "hidden_native": hidden_native,
            "strings": strings, "types": types, "entries": len(names)}


def decompile(jar: str, out: str) -> str | None:
    if not shutil.which("jadx"):
        return None
    target = os.path.join(out, os.path.splitext(os.path.basename(jar))[0])
    if not os.path.isdir(target):
        subprocess.run(["jadx", "-d", target, "--no-res", "-q", jar],
                       capture_output=True, timeout=900)
    return target


def find_source(root: str | None, class_name: str) -> str | None:
    if not root:
        return None
    for base, _, files in os.walk(root):
        if f"{class_name}.java" in files:
            return os.path.join(base, f"{class_name}.java")
    return None


def classify(source: str | None, jar_types: set[str], native: bool) -> tuple[str, dict, list[str]]:
    """Return (category, per-class dependency flags, notes)."""
    notes: list[str] = []
    if source is None:
        return "resource-missing", {}, ["class not found in any downloaded JAR"]

    with open(source, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    body = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    lines = [l for l in body.splitlines() if l.strip()]

    flags = {
        "okhttp": "okhttp3" in body,
        "jsoup": "org.jsoup" in body,
        "gson": "com.google.gson" in body,
        "orgjson": "org.json" in body,
        "regex": "java.util.regex" in body,
        "base64": "Base64" in body,
        "crypto": "javax.crypto" in body or "Cipher" in body,
        "digest": "MessageDigest" in body,
        "cookie": "Cookie" in body,
        "webview": "android.webkit.WebView" in body,
        "reflection": "java.lang.reflect" in body,
        "dynamicload": "DexClassLoader" in body or "InMemoryDexClassLoader" in body,
        "jni": bool(re.search(r"\bnative\s+\w", body)) or "System.load" in body,
        "androidapi": "android.content.Context" in body or "android.os." in body,
    }

    # An empty subclass whose parent resolves through a native loader: the logic is not here.
    declares_methods = re.search(r"\b(public|protected|private)\s+[\w<>\[\],. ]+\s+\w+\s*\(", body)
    if len(lines) <= 12 and not declares_methods:
        parent = re.search(r"class\s+\w+\s+extends\s+([\w.]+)", body)
        notes.append(f"empty shim extending {parent.group(1) if parent else 'unknown'}")
        return "protected-payload", flags, notes

    if flags["jni"] or native and flags["dynamicload"]:
        return "jni-native", flags, notes + ["declares native methods or loads a library"]
    if flags["dynamicload"]:
        return "reflection-obfuscation", flags, notes + ["loads classes at runtime"]
    if flags["webview"]:
        return "webview-sniffing", flags, notes
    if flags["crypto"] or flags["digest"]:
        return "http-crypto", flags, notes
    if flags["jsoup"] or flags["gson"]:
        return "http-helper", flags, notes
    return "http-json", flags, notes


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--archive", required=True)
    parser.add_argument("--out", default="build/audit")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    jars_dir = os.path.join(args.out, "jars")
    os.makedirs(jars_dir, exist_ok=True)

    config = json.load(open(args.config, encoding="utf-8"))
    archive = zipfile.ZipFile(args.archive)
    members = {n.split("recha-main/", 1)[-1]: n for n in archive.namelist()}
    shared_jar = config.get("spider", "").split(";")[0].lstrip("./")

    sites = [s for s in config["sites"] if s.get("type") == 3 and str(s.get("api", "")).startswith("csp_")]
    by_jar: dict[str, list[dict]] = collections.defaultdict(list)
    for site in sites:
        jar = (site.get("jar") or shared_jar).split(";")[0].lstrip("./")
        by_jar[jar].append(site)

    report: dict = {"sites": len(sites),
                    "classes": len({s["api"] for s in sites}),
                    "jars": {}, "spiders": []}

    for jar, jar_sites in sorted(by_jar.items(), key=lambda kv: -len(kv[1])):
        present = jar in members
        record: dict = {"present": present, "sites": len(jar_sites),
                        "classes": sorted({s["api"][4:] for s in jar_sites})}
        decompiled = None
        jar_types: set[str] = set()
        if present:
            local = os.path.join(jars_dir, os.path.basename(jar))
            with open(local, "wb") as handle:
                handle.write(archive.read(members[jar]))
            inventory = jar_inventory(local)
            jar_types = set(inventory["types"])
            record.update({
                "size": os.path.getsize(local),
                "dex": inventory["dex"],
                "native": inventory["native"],
                "hidden_native": inventory["hidden_native"],
                "jar_dependencies": sorted(
                    name for name, markers in DEPENDENCY_MARKERS.items()
                    if any(any(t.startswith(m) for t in jar_types) for m in markers)),
            })
            decompiled = decompile(local, os.path.join(args.out, "src"))
        report["jars"][jar] = record

        native = bool(record.get("native") or record.get("hidden_native"))
        for class_name in record["classes"]:
            source = find_source(decompiled, class_name)
            category, flags, notes = classify(source, jar_types, native)
            report["spiders"].append({
                "class": class_name,
                "jar": os.path.basename(jar),
                "jar_present": present,
                "sites": sum(1 for s in jar_sites if s["api"] == "csp_" + class_name),
                "lines": sum(1 for _ in open(source, errors="replace")) if source else 0,
                "category": category,
                "dependencies": sorted(k for k, v in flags.items() if v),
                "notes": notes,
            })

    with open(os.path.join(args.out, "audit.json"), "w", encoding="utf-8") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=1)

    buckets = collections.Counter(s["category"] for s in report["spiders"])
    covered = collections.Counter()
    for spider in report["spiders"]:
        covered[spider["category"]] += spider["sites"]
    print(f"{report['sites']} csp_ sites, {report['classes']} classes, {len(by_jar)} jars\n")
    print(f"{'category':<24}{'classes':>8}{'sites':>7}")
    for category, count in buckets.most_common():
        print(f"{category:<24}{count:>8}{covered[category]:>7}")
    print(f"\nwrote {os.path.join(args.out, 'audit.json')}")


if __name__ == "__main__":
    main()
