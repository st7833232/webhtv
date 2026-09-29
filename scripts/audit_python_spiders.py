#!/usr/bin/env python3
"""Classify the Python spiders a configuration references, by what they import.

Answers IOS-POC-7L (P5): how many of the configured Python sites can Tier 1 drive, and what each of
the rest is waiting on. Re-runnable, because the numbers go stale the moment the configuration does.

It applies the same rules the app applies (`PythonSpiderSource`, IOS-POC-7H): a script is fetched
only from the configuration's own origin and only over HTTPS, so a cross-origin or cleartext script
is reported as refused rather than analysed — the audit and the app must not disagree about that.

    scripts/audit_python_spiders.py --config https://host/path/wang-movie.json
    scripts/audit_python_spiders.py --config local.json --origin https://host/path/wang-movie.json

Static analysis only. It reads imports; it does not run anything. A script that imports `requests`
inside a branch it never reaches still counts as needing it, which is the conservative direction.

IOS-POC-37: what the app bundles is read from third_party/python-ios-lock.json rather than listed
here, so the audit answers "what is still missing" for the build as it stands, and a call to
`self.html()` counts as needing lxml, because that is what `base.spider.html` is built on.
"""
from __future__ import annotations

import argparse
import ast
import json
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
HOST_MODULES = {"base", "base.spider"}
# The import name of each bundled distribution, where the two differ.
IMPORT_NAMES = {"beautifulsoup4": "bs4", "charset-normalizer": "charset_normalizer",
                "typing-extensions": "typing_extensions", "pycryptodome": "Crypto"}
NATIVE = {"Crypto", "Cryptodome", "lxml", "pyquery"}  # pyquery is pure Python over lxml


def _bundled() -> set[str]:
    """Import names the app carries, from the lock: the pure wheels and the natively built sources."""
    lock = json.loads((ROOT / "third_party/python-ios-lock.json").read_text(encoding="utf-8"))
    names = [w["name"] for w in lock.get("python_packages", {}).get("wheels", [])]
    names += [s["name"] for s in lock.get("python_native_packages", {}).get("sources", [])
              if s.get("kind") == "sdist"]
    return {IMPORT_NAMES.get(name, name.replace("-", "_")) for name in names}


BUNDLED = _bundled()

def _stdlib_names() -> set[str]:
    """What the **bundled** interpreter can import, not what this Mac can.

    The question is whether the app's own CPython resolves a name, so the answer is read out of the
    payload `scripts/fetch_python_ios.sh` installs. Falls back to the host's list when the payload is
    absent, which is less accurate and says so.
    """
    root = ROOT / "third_party/python-ios/Python.xcframework"
    library = next(iter(sorted(root.glob("lib/python3.*"))), None)
    if library is None:
        names = getattr(sys, "stdlib_module_names", None)
        if names is None:
            raise SystemExit("no bundled payload and this Python is too old to list its own stdlib;\n"
                             "run scripts/fetch_python_ios.sh first")
        print("warning: using this host's stdlib list; run scripts/fetch_python_ios.sh for the real one",
              file=sys.stderr)
        return set(names)
    found = set(sys.builtin_module_names)
    for entry in library.iterdir():
        if entry.suffix == ".py":
            found.add(entry.stem)
        elif entry.is_dir() and (entry / "__init__.py").exists():
            found.add(entry.name)
    for slice_dir in root.glob("ios-arm64/lib-arm64/python3.*/lib-dynload"):
        for module in slice_dir.glob("*.so"):
            found.add(module.name.split(".")[0])
    return found


STDLIB = _stdlib_names()


def imports_of(source: str) -> set[str]:
    """Top-level package names this script imports, wherever the import sits, plus `lxml` when it
    calls `self.html()`, which is lxml underneath."""
    try:
        tree = ast.parse(source)
    except SyntaxError as error:
        raise ValueError(f"does not parse: {error}") from error
    found: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            found.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
            found.add(node.module.split(".")[0])
    if re.search(r"\bself\.html\(", source):
        found.add("lxml")
    return found


def classify(names: set[str]) -> tuple[str, set[str]]:
    """The tier a script lands in, and the names that put it there. Anything missing wins, because
    that is the thing to fix first."""
    outside = {n for n in names if n not in STDLIB and n not in HOST_MODULES}
    missing = outside - BUNDLED
    if missing:
        return "missing", missing
    if outside & NATIVE:
        return "bundled native", outside
    if outside:
        return "bundled pure-Python", outside
    return "stdlib + base", set()


def encoded(url: str) -> str:
    """Percent-encode before urllib sees it.

    The scripts have CJK filenames — `./py/皮皮虾.py` — and `urllib.request` raises
    UnicodeEncodeError rather than quoting. The same defect the app's own shim had (IOS-POC-7K); it
    is fixed the same way, and `%` stays safe so an already-encoded path is left alone.
    """
    parts = urllib.parse.urlsplit(url)
    return urllib.parse.urlunsplit((
        parts.scheme, parts.netloc,
        urllib.parse.quote(parts.path, safe="/%:@"),
        urllib.parse.quote(parts.query, safe="=&%+,:@/?"),
        urllib.parse.quote(parts.fragment, safe="%"),
    ))


def same_origin(script_url: str, origin: str) -> bool:
    a, b = urllib.parse.urlsplit(script_url), urllib.parse.urlsplit(origin)
    return (a.scheme == "https" and b.scheme == "https"
            and a.hostname == b.hostname and a.port == b.port)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, help="configuration URL, or a local file")
    parser.add_argument("--origin", help="the configuration's URL, when --config is a local file")
    parser.add_argument("--timeout", type=float, default=15)
    args = parser.parse_args()

    origin = args.origin or args.config
    if args.config.startswith("http"):
        with urllib.request.urlopen(args.config, timeout=args.timeout) as answer:
            config = json.load(answer)
    else:
        with open(args.config, encoding="utf-8") as handle:
            config = json.load(handle)

    sites = [s for s in config.get("sites", [])
             if s.get("type") == 3 and str(s.get("api", "")).lower().endswith(".py")]
    print(f"{len(sites)} Python sites in the configuration\n")

    tally: dict[str, int] = {}
    scripts: dict[str, tuple[str, set[str]]] = {}
    imported: dict[str, set[str]] = {}
    rows = []
    for site in sites:
        api = site["api"]
        url = urllib.parse.urljoin(origin, api)
        if not same_origin(url, origin):
            rows.append((site["name"], api, "cross-origin/HTTP refused", ""))
            tally["cross-origin/HTTP refused"] = tally.get("cross-origin/HTTP refused", 0) + 1
            continue
        if api in scripts:
            tier, why = scripts[api]
        else:
            try:
                with urllib.request.urlopen(encoded(url), timeout=args.timeout) as answer:
                    source = answer.read().decode("utf-8", errors="replace")
                names = imports_of(source)
                imported[api] = {n for n in names if n not in STDLIB and n not in HOST_MODULES}
                tier, why = classify(names)
            except (urllib.error.URLError, ValueError, OSError) as error:
                tier, why = "unfetchable", {str(error)[:60]}
            scripts[api] = (tier, why)
        rows.append((site["name"], api, tier, ", ".join(sorted(why))))
        tally[tier] = tally.get(tier, 0) + 1

    width = max(len(r[0]) for r in rows) if rows else 10
    for name, api, tier, why in sorted(rows, key=lambda r: (r[2], r[1])):
        print(f"{name:<{width}}  {tier:<26} {why}")

    print(f"\n{'tier':<28} sites  scripts")
    for tier, count in sorted(tally.items(), key=lambda kv: -kv[1]):
        distinct = len({a for a, (t, _) in scripts.items() if t == tier})
        print(f"{tier:<28} {count:>5}  {distinct:>7}")
    # Per third-party import: how many sites need it, and whether this build carries it. A site
    # sharing a script with others (金牌 ×5, getapp ×5) counts once per site, as it does in the app.
    per_site = [(api, imported.get(api, set())) for _, api, tier, _ in rows if tier != "cross-origin/HTTP refused"]
    print(f"\n{'import':<22} sites  scripts  bundled")
    for name in sorted({n for _, needs in per_site for n in needs}):
        sites_needing = sum(1 for _, needs in per_site if name in needs)
        scripts_needing = len({api for api, needs in per_site if name in needs})
        print(f"{name:<22} {sites_needing:>5}  {scripts_needing:>7}  {'yes' if name in BUNDLED else 'NO'}")
    loadable = sum(count for tier, count in tally.items() if tier in ("stdlib + base", "bundled pure-Python", "bundled native"))
    print(f"\nNothing missing statically for {loadable} of {len(sites)} sites.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
