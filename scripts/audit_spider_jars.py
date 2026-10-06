#!/usr/bin/env python3
"""Batch static audit of the CatVod `csp_*` spider JARs referenced by a TVBox config.

Two questions, one per subcommand:

  audit     what would it take to reimplement each spider class on iOS?
  baseline  record a rename-insensitive fingerprint of the original class behind every ported adapter
  compat    is a configured class that is *not* ported the same protocol as one that is? (IOS-POC-55)

It never assumes a JAR is unportable because it holds DEX or ships a `.so`. It reads the DEX
type/string tables, decompiles with jadx, and classifies each class from what it actually
references. A class whose visible body is an empty shim is reported as `protected-payload`, which is
a statement about that JAR's loader, not about the spider's logic.

Usage:
    scripts/audit_spider_jars.py audit --config wang-movie.json --archive recha-main.zip --out build/audit
    scripts/audit_spider_jars.py baseline --jars DIR
    scripts/audit_spider_jars.py compat --config https://…/wang-movie.json [--config …] [--runtime]

`compat` downloads the JARs a configuration actually references, records their real SHA-256, and only
emits a mapping (`build/compat/mappings.json`, packed by `spider_pack.py build --mappings`) for a class
whose fingerprint equals exactly one adapter's baseline **and** whose site passed the existing live
golden test through that adapter. Everything else is reported as pending, with the reasons.
"""

from __future__ import annotations

import argparse
import collections
import datetime
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import urllib.parse
import urllib.request
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
        native = [n for n in names if n.endswith(".so")]
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


def classify(source: str | None, native: bool) -> tuple[str, dict, list[str]]:
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


def audit(args) -> None:
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
            category, flags, notes = classify(source, native)
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


# --- IOS-POC-55: is an unported class the same protocol as a ported one? -------------------------
#
# A Type-2 clone check (Roy, Cordy & Koschke 2009) that is deliberately *stricter* than Type-2: every
# identifier the JAR itself declares — class, helper, method, field, local, obfuscated package — is
# replaced by a placeholder, because renaming them changes nothing a site sees. String and number
# literals, and the names of library/SDK APIs, are kept verbatim, because that is where a spider's
# protocol lives: paths, parameters, headers, keys, cipher modes, response fields, play flags. A call
# into the JAR's own code is replaced by the *content* of the method it calls (to `CALL_DEPTH`
# levels), so calling `md5` instead of `sha1` through a renamed helper is still a difference.
# Two classes are compatible only when the multisets of their members' digests are equal.

ALGORITHM = 1
CALL_DEPTH = 3
OWN_PREFIX = "Lcom/github/catvod/"
SDK_PREFIX = "Lcom/github/catvod/crawler/"   # the app's own Spider SDK, never part of a JAR's logic
# CatVod's Spider contract. An override keeps its name so a difference can be reported per method.
SPIDER_API = {"init", "homeContent", "homeVideoContent", "categoryContent", "detailContent",
              "searchContent", "playerContent", "liveContent", "destroy", "manualVideoCheck",
              "isVideoFormat", "proxyLocal", "action"}
KEYWORDS = set("""abstract assert boolean break byte case catch char class const continue default do
double else enum extends final finally float for goto if implements import instanceof int interface
long native new package private protected public return short static strictfp super switch
synchronized this throw throws transient try void volatile while true false null var""".split())
MEMBER_ROLE = {"playerContent": "播放處理", "detailContent": "詳情請求／回應", "categoryContent": "分類請求／回應",
               "homeContent": "首頁請求／回應", "homeVideoContent": "首頁請求／回應",
               "searchContent": "搜尋請求／回應", "init": "初始化（ext／預設值）"}
PROTECTED = {"protected-payload": "空殼類別，邏輯在原生／加密載入的 payload 裡",
             "jni-native": "宣告 native 方法或載入 .so",
             "reflection-obfuscation": "執行期動態載入類別"}
TOKEN = re.compile(r'''
    (?P<ws>\s+|//[^\n]*|/\*.*?\*/)
  | (?P<str>"(?:\\.|[^"\\\n])*")
  | (?P<chr>'(?:\\.|[^'\\\n])+')
  | (?P<num>0[xX][0-9a-fA-F_]+[lL]?|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?[fFdDlL]?)
  | (?P<id>[^\W\d]\w*)
  | (?P<op>.)''', re.S | re.X)


def is_own(descriptor: str) -> bool:
    return descriptor.startswith(OWN_PREFIX) and not descriptor.startswith(SDK_PREFIX)


def external_names(jar: str) -> set[str]:
    """Identifiers a class can only have got from a library or the SDK, read from the DEX tables:
    simple names of every type outside the JAR's own code, and every member name declared on one."""
    names: set[str] = set()
    with zipfile.ZipFile(jar) as archive:
        for entry in archive.namelist():
            if not entry.endswith(".dex"):
                continue
            data = archive.read(entry)
            n_str, o_str = struct.unpack_from("<II", data, 56)
            n_typ, o_typ = struct.unpack_from("<II", data, 64)
            n_fld, o_fld = struct.unpack_from("<II", data, 80)
            n_met, o_met = struct.unpack_from("<II", data, 88)

            def string(index: int) -> str:
                length, payload = uleb128(data, struct.unpack_from("<I", data, o_str + 4 * index)[0])
                return data[payload:payload + length].decode("utf-8", "replace")
            types = [string(struct.unpack_from("<I", data, o_typ + 4 * i)[0]) for i in range(n_typ)]
            for descriptor in types:
                if descriptor.startswith("L") and not is_own(descriptor):
                    names.update(re.split(r"[/$]", descriptor[1:-1].rsplit("/", 1)[-1]))
            for base, count in ((o_fld, n_fld), (o_met, n_met)):
                for i in range(count):
                    owner, _, name = struct.unpack_from("<HHI", data, base + 8 * i)
                    if not is_own(types[owner]):
                        names.add(string(name))
    return names


def tokenize(text: str) -> list[tuple[str, str]]:
    return [(m.lastgroup, m.group()) for m in TOKEN.finditer(text) if m.lastgroup != "ws"]


def digest_of(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:16]


class Tree:
    """The JAR's own classes in a jadx output directory, keyed by jadx's fully-qualified name."""

    def __init__(self, root: str):
        self.files: dict[str, str] = {}
        for base, _, files in os.walk(root):
            for name in files:
                if name.endswith(".java"):
                    path = os.path.join(base, name)
                    fqn = os.path.relpath(path, root)[:-5].replace(os.sep, ".")
                    if is_own("L" + fqn.replace(".", "/") + ";"):
                        self.files[fqn] = path
        self._parsed: dict[str, dict] = {}

    def cls(self, fqn: str) -> dict:
        if fqn not in self._parsed:
            self._parsed[fqn] = parse_class(self.files[fqn], fqn)
        return self._parsed[fqn]

    def resolve(self, cls: dict, simple: str | None) -> str | None:
        """An own class referred to by its simple name from inside `cls`."""
        if not simple:
            return None
        if simple == cls["simple"]:
            return cls["fqn"]
        fqn = cls["imports"].get(simple) or cls["package"] + "." + simple
        return fqn if fqn in self.files else None


def class_body(tokens: list) -> tuple[list, list]:
    for i, (_, text) in enumerate(tokens):
        if text == "{":
            depth = 0
            for j in range(i, len(tokens)):
                depth += {"{": 1, "}": -1}.get(tokens[j][1], 0)
                if depth == 0:
                    return tokens[:i], tokens[i + 1:j]
    return tokens, []


def members_of(body: list) -> list[list]:
    members, current, depth = [], [], 0
    for token in body:
        current.append(token)
        if token[1] == "{":
            depth += 1
        elif token[1] == "}":
            depth -= 1
            first = next(k for k, t in enumerate(current) if t[1] == "{")
            # A field initialiser (`= {…}`, an anonymous class) still ends at its `;`.
            if depth == 0 and not any(t[1] == "=" for t in current[:first]):
                members.append(current)
                current = []
        elif token[1] == ";" and depth == 0:
            members.append(current)
            current = []
    return members + ([current] if current else [])


def arg_count(tokens: list, open_index: int) -> int:
    depth, commas, empty = 0, 0, True
    for _, text in tokens[open_index:]:
        if text in ("(", "[", "{"):
            depth += 1
        elif text in (")", "]", "}"):
            depth -= 1
            if depth == 0:
                break
        elif depth == 1:
            empty = False
            commas += text == ","
    return 0 if empty else commas + 1


def describe_member(tokens: list) -> tuple[str, str, int]:
    """(kind, name, parameter count) of one class member."""
    if len(tokens) > 1 and tokens[0][1] == "static" and tokens[1][1] == "{":
        return "init", "<clinit>", 0
    head, k = [], 0
    while k < len(tokens) and tokens[k][1] not in ("{", "=", ";"):
        if tokens[k][1] == "@":                 # an annotation, with or without arguments
            k += 2
            if k < len(tokens) and tokens[k][1] == "(":
                depth = 0
                while k < len(tokens):
                    depth += {"(": 1, ")": -1}.get(tokens[k][1], 0)
                    k += 1
                    if depth == 0:
                        break
            continue
        head.append((k, tokens[k]))
        k += 1
    for position, (k, token) in enumerate(head):
        if token[1] == "(":
            return "method", head[position - 1][1][1] if position else "?", arg_count(tokens, k)
        if token[1] in ("class", "interface", "enum") and position + 1 < len(head):
            return "type", head[position + 1][1][1], 0
    if head and head[-1][1][0] == "id":
        return "field", head[-1][1][1], 0
    return "init", "<init>", 0


def parse_class(path: str, fqn: str) -> dict:
    text = open(path, encoding="utf-8", errors="replace").read()
    imports = {m.group(1).rsplit(".", 1)[1]: m.group(1)
               for m in re.finditer(r"^import\s+([\w.]+);", text, re.M)}
    tokens, kept, i = tokenize(text), [], 0
    while i < len(tokens):                      # package and import statements carry no behaviour
        if tokens[i][1] in ("package", "import") and (not kept or kept[-1][1] in (";", "}")):
            while i < len(tokens) and tokens[i][1] != ";":
                i += 1
        else:
            kept.append(tokens[i])
        i += 1
    header, body = class_body(kept)
    parent = next((header[k + 1][1] for k, t in enumerate(header[:-1]) if t[1] == "extends"), None)
    members = []
    for member in members_of(body):
        kind, name, args = describe_member(member)
        members.append({"kind": kind, "name": name, "args": args, "tokens": member})
    return {"fqn": fqn, "simple": fqn.rsplit(".", 1)[1], "package": fqn.rsplit(".", 1)[0],
            "parent": parent, "imports": imports, "members": members, "source": text}


def collapse_qualified(tree: Tree, tokens: list) -> list:
    """`com.github.catvod.spider.merge.FM.p013m.c.n(` → `<own class c> . n (`: an obfuscated
    package path is a name like any other, so it must not survive into the fingerprint."""
    out, i = [], 0
    while i < len(tokens):
        if tokens[i] == ("id", "com") and i + 2 < len(tokens) and tokens[i + 1][1] == ".":
            parts, j = [tokens[i][1]], i
            while j + 2 < len(tokens) and tokens[j + 1][1] == "." and tokens[j + 2][0] == "id":
                j += 2
                parts.append(tokens[j][1])
            known = next((n for n in range(len(parts), 0, -1) if ".".join(parts[:n]) in tree.files), 0)
            if known:
                out.append(("own", ".".join(parts[:known])))
                for rest in parts[known:]:
                    out += [("op", "."), ("id", rest)]
                i = j + 1
                continue
        out.append(tokens[i])
        i += 1
    return out


class Fingerprinter:
    def __init__(self, tree: Tree, external: set[str], depth: int = CALL_DEPTH):
        self.tree, self.external, self.depth = tree, external | SPIDER_API, depth
        self.memo: dict[tuple, str] = {}

    def callees(self, fqn: str | None, name: str, args: int, seen: tuple = ()) -> list[tuple[str, int]]:
        """Own methods `name`/`args` on `fqn`, else on its own superclasses."""
        if not fqn or fqn not in self.tree.files or fqn in seen:
            return []
        cls = self.tree.cls(fqn)
        found = [(fqn, k) for k, m in enumerate(cls["members"])
                 if m["kind"] == "method" and m["name"] == name and m["args"] == args]
        return found or self.callees(self.tree.resolve(cls, cls["parent"]), name, args, seen + (fqn,))

    def digest(self, fqn: str, index: int, level: int) -> str:
        key = (fqn, index, level)
        if key not in self.memo:
            self.memo[key] = "cycle"
            self.memo[key] = digest_of(" ".join(self.normalized(fqn, index, level)))
        return self.memo[key]

    def normalized(self, fqn: str, index: int, level: int) -> list[str]:
        cls = self.tree.cls(fqn)
        tokens = collapse_qualified(self.tree, cls["members"][index]["tokens"])
        names: dict[str, str] = {}
        # `e eVar = …` / `(e eVar)`: a local of an own type, so `eVar.h(` can be resolved to `e.h`.
        typed = {tokens[k + 1][1]: self.tree.resolve(cls, text) for k, (kind, text) in enumerate(tokens[:-1])
                 if kind == "id" and tokens[k + 1][0] == "id" and self.tree.resolve(cls, text)}
        out = []
        for k, (kind, text) in enumerate(tokens):
            if kind == "str":
                # The class's own name as a literal (a log tag, `init`'s label) is a rename artefact.
                out.append('"$SELF"' if text[1:-1] == cls["simple"] else text)
                continue
            if kind == "own":
                out.append("$T")
                continue
            if kind != "id" or text in KEYWORDS:
                out.append(text)
                continue
            following = tokens[k + 1][1] if k + 1 < len(tokens) else ""
            previous = tokens[k - 1][1] if k else ""
            owner = tokens[k - 2] if k > 1 else ("", "")
            if following == "(":
                target = None
                if previous == ".":
                    if owner[0] == "own":
                        target = owner[1]
                    elif owner == ("id", "this"):
                        target = fqn
                    elif owner[0] == "id":
                        target = typed.get(owner[1]) or (None if owner[1] in names
                                                         else self.tree.resolve(cls, owner[1]))
                elif previous == "new":
                    target = self.tree.resolve(cls, text)
                else:
                    target = fqn
                found = self.callees(target, text, arg_count(tokens, k + 1)) if target and level else []
                if found:
                    out.append("@" + "+".join(sorted(self.digest(f, i, level - 1) for f, i in found)))
                elif previous == "new" and target:
                    out.append("$T")                # an own type with only its implicit constructor
                elif text in self.external:
                    out.append(text)
                else:
                    out.append("$call")
                continue
            if self.tree.resolve(cls, text):
                out.append("$T")
            elif text in self.external:
                out.append(text)
            else:
                names.setdefault(text, f"${len(names)}")
                out.append(names[text])
        return out

    def fingerprint(self, fqn: str) -> dict:
        """Every member of the class and of its own superclasses (an inherited method is behaviour
        too), each with a call-resolved digest, its body without call resolution, and its literals."""
        members, chain, current = [], [], fqn
        while current and current in self.tree.files and current not in chain:
            chain.append(current)
            cls = self.tree.cls(current)
            for k, member in enumerate(cls["members"]):
                members.append({
                    "label": member["name"] if member["name"] in SPIDER_API else member["kind"],
                    "deep": self.digest(current, k, self.depth),
                    "shallow": self.digest(current, k, 0),
                    "literals": sorted({t for kind, t in member["tokens"] if kind == "str" and t[1:-1] != cls["simple"]}),
                })
            current = self.tree.resolve(cls, cls["parent"])
        return {"fingerprint": digest_of(" ".join(sorted(m["deep"] for m in members))),
                "chain": [c.rsplit(".", 1)[1] for c in chain], "members": members}


def literal_kind(text: str) -> str:
    value = text[1:-1]
    if re.search(r"AES|DES|RSA|MD5|SHA|Hmac|PKCS|ECB|CBC|GCM|NoPadding", value, re.I):
        return "簽章／加解密"
    if value.startswith("/") or "://" in value or re.match(r"^[\w-]+(\.[\w-]+)*\.[a-zA-Z]{2,}(:\d+)?(/|$)", value):
        return "API 路徑／主機"
    return "字串常數"


def compare(candidate: dict, baseline: dict) -> list[str]:
    """Why two fingerprints differ, one line per difference. Empty means identical."""
    if candidate["fingerprint"] == baseline["fingerprint"]:
        return []
    left = list(baseline["members"])
    right = list(candidate["members"])
    for member in list(left):                   # identical members are not differences
        match = next((m for m in right if m["deep"] == member["deep"]), None)
        if match:
            left.remove(member)
            right.remove(match)
    reasons = []

    def similarity(a: dict, b: dict) -> float:
        x, y = set(a["literals"]), set(b["literals"])
        return len(x & y) / len(x | y) if x | y else (1.0 if a["label"] == b["label"] else 0.0)

    for member in left:
        pool = [m for m in right if m["label"] == member["label"] and member["label"] in SPIDER_API] or \
               [m for m in right if m["shallow"] == member["shallow"]] or \
               [m for m in right if similarity(m, member) >= 0.5]
        role = MEMBER_ROLE.get(member["label"], "helper／欄位")
        if not pool:
            reasons.append(f"{role}：少了基準裡的一個 {member['label']}")
            continue
        match = max(pool, key=lambda m: similarity(m, member))
        right.remove(match)
        if match["shallow"] == member["shallow"]:
            reasons.append(f"{role}：本身相同，但呼叫的 helper 實作不同")
            continue
        gone = collections.Counter(member["literals"]) - collections.Counter(match["literals"])
        added = collections.Counter(match["literals"]) - collections.Counter(member["literals"])
        if not gone and not added:
            reasons.append(f"{role}：字串相同，程式結構（流程、數值或 API 呼叫）不同")
            continue
        for kind in sorted({literal_kind(t) for t in gone + added}):
            lost = [t for t in gone if literal_kind(t) == kind][:4]
            extra = [t for t in added if literal_kind(t) == kind][:4]
            reasons.append(f"{role}：{kind}不同（基準有 {', '.join(lost) or '—'}；這裡有 {', '.join(extra) or '—'}）")
    for member in right:
        reasons.append(f"{MEMBER_ROLE.get(member['label'], 'helper／欄位')}：多了基準沒有的一個 {member['label']}")
    return reasons or ["成員相同但順序或數量不同"]


def overlap(candidate: dict, baseline: dict) -> float:
    a = collections.Counter(m["deep"] for m in candidate["members"])
    b = collections.Counter(m["deep"] for m in baseline["members"])
    return sum((a & b).values()) / max(sum(a.values()), sum(b.values()), 1)


def decide(name: str, fingerprint: dict | None, category: str | None, registry: dict,
           baselines: dict) -> dict:
    """One configured class in one JAR → existing / candidate / pending, with the reasons."""
    if fingerprint is None:
        return {"status": "pending", "reasons": ["JAR 讀不到，或 JAR 裡沒有這個類別"]}
    target = registry["aliases"].get(name, name)
    if name in registry["ported"]:
        record = {"status": "existing", "adapter": target, "reasons": []}
        if category in PROTECTED:
            record["reasons"] = [f"類別本身是原生／加密載入（{PROTECTED[category]}）；App 依人工確認的 alias 驅動"]
        elif target in baselines:
            diff = compare(fingerprint, baselines[target])
            record["reasons"] = ["與基準相同"] if not diff else ["App 依名稱直接綁定（既有行為不變），但與基準不同："] + diff
        return record
    if category in PROTECTED:
        return {"status": "pending", "reasons": [f"原生／加密載入：{PROTECTED[category]}"]}
    exact = sorted(adapter for adapter, base in baselines.items() if base["fingerprint"] == fingerprint["fingerprint"])
    if len(exact) == 1:
        return {"status": "candidate", "adapter": exact[0], "reasons": [f"特徵與 {exact[0]} 的基準完全相同"]}
    if exact:
        return {"status": "pending", "candidates": exact, "reasons": [f"多個 adapter 的基準都相同，無法排除：{', '.join(exact)}"]}
    ranked = sorted(baselines, key=lambda a: -overlap(fingerprint, baselines[a]))
    closest = ranked[0] if ranked and overlap(fingerprint, baselines[ranked[0]]) > 0 else None
    if not closest:
        return {"status": "pending", "reasons": ["沒有任何既有 adapter 的基準和它有相同的成員：需要新 adapter"]}
    diff = compare(fingerprint, baselines[closest])
    only_constants = all("字串常數" in r or "API 路徑／主機" in r for r in diff)
    advice = ("只差常數：可評估以資料（ext／規則）補齊或讓 adapter 參數化，不會自動套用" if only_constants
              else "協定或能力不同：需要新 adapter 或補 host 能力，不會自動新增")
    return {"status": "pending", "closest": closest, "overlap": round(overlap(fingerprint, baselines[closest]), 2),
            "reasons": [f"最接近 {closest}，但不相同；{advice}"] + diff}


def registry_names(path: str = "ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift") -> dict:
    """What the app already binds by name: `SpiderRegistry.ported` and its hand-proven aliases."""
    text = open(path, encoding="utf-8").read()
    ported = re.search(r"static let ported: Set = \[(.*?)\n    \]", text, re.S).group(1)
    aliases = re.search(r"static let aliases = \[(.*?)\]", text).group(1)
    return {"ported": set(re.findall(r'^\s*"(\w+)",', ported, re.M)),
            "aliases": dict(re.findall(r'"(\w+)":\s*"(\w+)"', aliases))}


def sha256_file(path: str) -> str:
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def class_fingerprint(work: str, jar_path: str, class_name: str, cache: dict) -> tuple[dict | None, str | None]:
    """(fingerprint, audit category) of `com.github.catvod.spider.<class_name>` in one JAR file."""
    sha = sha256_file(jar_path)
    if sha not in cache:
        staged = os.path.join(work, "jars", sha[:16] + ".jar")
        os.makedirs(os.path.dirname(staged), exist_ok=True)
        if not os.path.exists(staged):
            shutil.copyfile(jar_path, staged)
        source_root = decompile(staged, os.path.join(work, "src"))
        if source_root is None:
            sys.exit("jadx is required for baseline/compat")
        inventory = jar_inventory(staged)
        tree = Tree(os.path.join(source_root, "sources"))
        cache[sha] = (tree, Fingerprinter(tree, external_names(staged)),
                      bool(inventory["native"] or inventory["hidden_native"]))
    tree, printer, native = cache[sha]
    fqn = "com.github.catvod.spider." + class_name
    if fqn not in tree.files:
        return None, None
    category, _, _ = classify(tree.files[fqn], native)
    return printer.fingerprint(fqn), category


def baseline(args) -> int:
    """Fingerprint the original class behind every port, from exactly the JAR it was ported from."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from spider_pack import DEFAULT_ORIGINS
    cache: dict = {}
    result, problems = {}, []
    for adapter, origin in sorted(DEFAULT_ORIGINS.items()):
        path = os.path.join(args.jars, origin["originJar"])
        if not os.path.exists(path) or sha256_file(path) != origin["jarSha256"]:
            problems.append(f"{adapter}: {origin['originJar']} missing or not the pinned {origin['jarSha256'][:16]}…")
            continue
        fingerprint, category = class_fingerprint(args.work, path, origin.get("originClass", adapter), cache)
        if fingerprint is None:
            problems.append(f"{adapter}: class not found in {origin['originJar']}")
            continue
        result[adapter] = {"originJar": origin["originJar"], "jarSha256": origin["jarSha256"],
                           "class": origin.get("originClass", adapter), "category": category, **fingerprint}
        print(f"  {adapter:<10} {fingerprint['fingerprint']} {len(fingerprint['members'])} members")
    for problem in problems:
        print(f"  ! {problem}")
    if problems:
        return 1
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump({"algorithm": ALGORITHM, "callDepth": CALL_DEPTH, "baselines": result},
                  handle, ensure_ascii=False, indent=1, sort_keys=True)
        handle.write("\n")
    print(f"{len(result)} baselines -> {args.out}")
    return 0


def fetch_to(url: str, path: str) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "okhttp/3.12.13"})
    with urllib.request.urlopen(request, timeout=120) as response, open(path, "wb") as handle:
        handle.write(response.read())


def golden_site(site: dict, adapter: str, config_url: str) -> dict:
    """The site exactly as configured, with `api` pointed at the adapter and relative `ext` paths
    resolved the way `CSPSourceResolver.resolvedExtend` resolves them."""
    copy = dict(site, api="csp_" + adapter)
    ext = site.get("ext")
    if isinstance(ext, str) and ext.startswith(("./", "../")):
        copy["ext"] = urllib.parse.urljoin(config_url, ext)
    elif isinstance(ext, dict):
        copy["ext"] = {k: urllib.parse.urljoin(config_url, v) if isinstance(v, str) and v.startswith("./") else v
                       for k, v in ext.items()}
    return copy


def run_golden(site: dict) -> tuple[bool, str]:
    """The existing live golden test (`SpiderGoldenTests`), driven through the adapter."""
    env = dict(os.environ, CSP_GOLDEN_SITE=json.dumps(site, ensure_ascii=False))
    run = subprocess.run(["swift", "test", "--package-path", "ios", "--filter",
                          "appGetDrivesTheWholeCatVodFlowAgainstTheLiveSite"],
                         capture_output=True, text=True, env=env, timeout=1800)
    output = run.stdout + run.stderr
    passed = run.returncode == 0 and "[golden] player:" in output
    lines = [l for l in output.splitlines() if "[golden]" in l or "✘" in l or "error:" in l]
    return passed, " | ".join(lines[-6:])[:600]


def compat(args) -> int:
    os.makedirs(args.work, exist_ok=True)
    data = json.load(open(args.baselines, encoding="utf-8"))
    if data.get("algorithm") != ALGORITHM or data.get("callDepth") != CALL_DEPTH:
        sys.exit(f"{args.baselines} was made by another algorithm; run `baseline` again")
    baselines = data["baselines"]
    registry = registry_names()
    adapters_dir = "ios/Sources/WebHTVCore/Resources/Spiders"
    jar_files: dict[str, tuple[str, str] | None] = {}
    cache: dict = {}
    analysed: dict[tuple, dict] = {}
    report = {"generated": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
              "algorithm": ALGORITHM, "jars": {}, "sites": []}

    for config_url in args.config:
        local = os.path.join(args.work, "config-" + digest_of(config_url) + ".json")
        fetch_to(config_url, local)
        config = json.load(open(local, encoding="utf-8"))
        shared = config.get("spider", "")
        for site in config.get("sites", []):
            if site.get("type") != 3 or not str(site.get("api", "")).startswith("csp_"):
                continue
            reference = site.get("jar") or shared        # FongMi `Site.objectFrom`: own jar, else `spider`
            declared = reference.split(";md5;")[1].strip() if ";md5;" in reference else None
            # Percent-encoded the way `URL(string:relativeTo:)` encodes `./jar/愛影.jar`, so the app
            # compares the same string it resolves.
            jar_url = urllib.parse.quote(urllib.parse.urljoin(config_url, reference.split(";")[0].strip()),
                                         safe=":/?&=%#@+,;~")
            if jar_url not in jar_files:
                target = os.path.join(args.work, "download-" + digest_of(jar_url) + ".jar")
                try:
                    fetch_to(jar_url, target)
                    jar_files[jar_url] = (target, sha256_file(target))
                    with open(target, "rb") as handle:
                        md5 = hashlib.md5(handle.read()).hexdigest()
                    report["jars"][jar_url] = {"sha256": jar_files[jar_url][1], "md5": md5,
                                               "declaredMd5": declared, "size": os.path.getsize(target)}
                except Exception as error:      # noqa: BLE001 - recorded as a pending reason
                    jar_files[jar_url] = None
                    report["jars"][jar_url] = {"error": f"{type(error).__name__}: {error}"}
            name = site["api"][4:]
            located = jar_files[jar_url]
            key = (located[1] if located else jar_url, name)
            if key not in analysed:
                fingerprint, category = class_fingerprint(args.work, located[0], name, cache) if located else (None, None)
                analysed[key] = {"fingerprint": fingerprint, **decide(name, fingerprint, category, registry, baselines)}
            decision = analysed[key]
            report["sites"].append({
                "config": config_url, "site": site["key"], "name": site.get("name", ""), "class": name,
                "jar": jar_url, "jarSha256": located[1] if located else None, "declaredMd5": declared,
                **{k: v for k, v in decision.items() if k != "fingerprint"}, "reasons": list(decision["reasons"]),
                "classFingerprint": decision["fingerprint"]["fingerprint"] if decision["fingerprint"] else None,
                "_site": site})

    mappings = []
    for entry in report["sites"]:
        site = entry.pop("_site")
        if entry["status"] != "candidate":
            continue
        if not args.runtime:
            entry["reasons"].append("尚未跑 runtime 驗證（加 --runtime）")
            continue
        passed, evidence = run_golden(golden_site(site, entry["adapter"], entry["config"]))
        entry["runtime"] = evidence
        if not passed:
            entry["status"] = "pending"
            entry["reasons"].append("靜態特徵相同，但 live golden 沒通過：無法驗證（不判定來源失效）")
            continue
        entry["status"] = "mapped"
    # A key CatVod does not require to be unique is only mapped when every site wearing it passed.
    blocked = {(e["config"], e["site"], e["class"], e["jar"]) for e in report["sites"] if e["status"] != "mapped"}
    for entry in report["sites"]:
        scope = (entry["config"], entry["site"], entry["class"], entry["jar"])
        if entry["status"] != "mapped":
            continue
        if scope in blocked:
            entry["status"] = "pending"
            entry["reasons"].append("同一個 key 的另一個站沒通過驗證")
            continue
        adapter_path = os.path.join(adapters_dir, entry["adapter"] + ".js")
        base = baselines[entry["adapter"]]
        mapping = {"config": entry["config"], "site": entry["site"], "class": entry["class"],
                   "jar": entry["jar"], "jarSha256": entry["jarSha256"], "adapter": entry["adapter"],
                   "adapterSha256": sha256_file(adapter_path),
                   "evidence": {"baseline": f"{base['class']}@{base['originJar']}#{base['jarSha256'][:16]}",
                                "fingerprint": entry["classFingerprint"], "runtime": entry["runtime"],
                                "analysed": report["generated"]}}
        if mapping not in mappings:
            mappings.append(mapping)

    with open(os.path.join(args.work, "report.json"), "w", encoding="utf-8") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=1)
    with open(os.path.join(args.work, "mappings.json"), "w", encoding="utf-8") as handle:
        json.dump({"mappings": mappings}, handle, ensure_ascii=False, indent=1)
        handle.write("\n")
    with open(os.path.join(args.work, "report.md"), "w", encoding="utf-8") as handle:
        handle.write(markdown_report(report))
    counts = collections.Counter(e["status"] for e in report["sites"])
    print(f"{len(report['sites'])} csp_ sites: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    print(f"{len(mappings)} mapping(s) -> {os.path.join(args.work, 'mappings.json')}")
    return 0


def markdown_report(report: dict) -> str:
    lines = [f"# JAR 相容分析（{report['generated']}，algorithm {report['algorithm']}）", "",
             "## JAR", "", "| JAR | SHA-256 | md5 | 設定宣告的 md5 |", "|---|---|---|---|"]
    for url, jar in report["jars"].items():
        if "error" in jar:
            lines.append(f"| {url} | 讀不到：{jar['error']} | | |")
            continue
        stale = "" if not jar["declaredMd5"] or jar["declaredMd5"] == jar["md5"] else "（**不符**）"
        lines.append(f"| {url} | `{jar['sha256'][:16]}…` | `{jar['md5'][:8]}…` | "
                     f"{'`' + jar['declaredMd5'][:8] + '…`' if jar['declaredMd5'] else '—'}{stale} |")
    groups = collections.defaultdict(list)
    for entry in report["sites"]:
        groups[(entry["status"], entry["class"], entry["jar"].rsplit("/", 1)[-1], entry.get("adapter"),
                tuple(entry["reasons"]))].append(entry)
    for status in ("mapped", "candidate", "pending", "existing"):
        rows = [(k, v) for k, v in groups.items() if k[0] == status]
        if not rows:
            continue
        lines += ["", f"## {status}（{sum(len(v) for _, v in rows)} 站）", ""]
        for (_, name, jar, adapter, reasons), entries in sorted(rows, key=lambda kv: kv[0][1:3]):
            configs = sorted({e["config"].rsplit("/", 1)[-1] for e in entries})
            lines.append(f"- `{name}` @ `{jar}`" + (f" → `{adapter}`" if adapter else "") +
                         f"：{len(entries)} 站（{', '.join(configs)}）")
            lines += [f"  - {reason}" for reason in reasons[:8]]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    a = sub.add_parser("audit")
    a.add_argument("--config", required=True)
    a.add_argument("--archive", required=True)
    a.add_argument("--out", default="build/audit")
    a.set_defaults(func=audit)
    b = sub.add_parser("baseline")
    b.add_argument("--jars", required=True, help="directory holding every origin JAR named in DEFAULT_ORIGINS")
    b.add_argument("--work", default="build/compat")
    b.add_argument("--out", default="scripts/spider_baselines.json")
    b.set_defaults(func=baseline)
    c = sub.add_parser("compat")
    c.add_argument("--config", action="append", required=True, help="configuration URL; repeatable")
    c.add_argument("--baselines", default="scripts/spider_baselines.json")
    c.add_argument("--work", default="build/compat")
    c.add_argument("--runtime", action="store_true", help="run the live golden test for every candidate")
    c.set_defaults(func=compat)
    # The pre-IOS-POC-55 invocation had no subcommand; keep it working.
    argv = sys.argv[1:]
    if argv and argv[0].startswith("--"):
        argv = ["audit"] + argv
    args = parser.parse_args(argv)
    return args.func(args) or 0


if __name__ == "__main__":
    sys.exit(main())
