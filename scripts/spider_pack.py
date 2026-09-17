#!/usr/bin/env python3
"""Build and verify an iOS Spider compatibility pack.

A pack is a manifest plus the JavaScript spiders it describes, published at any HTTPS location the
app's configuration can reach. The app verifies every script against the SHA-256 in the manifest
before adopting it, so this tool's job is to produce hashes that are true and to tell you when the
JAR a script was written from has changed underneath it.

  build        emit manifest.json + scripts/ from a directory of spiders
  verify       fetch a published pack and re-check schema, hashes and completeness
  fingerprint  re-hash the origin JARs and report which scripts were written from a different build

This tool never decompiles, executes or unpacks a JAR. It reads bytes and computes a digest.
"""

import argparse, hashlib, json, os, pathlib, shutil, sys, urllib.request

SCHEMA = 1
HOST_API = 1
# host.js is the runtime's own SDK, not compatibility logic: it is what `minHostApi` describes, so it
# ships with the app and is deliberately not packable.
NOT_PACKABLE = {"host.js"}

# Provenance for the ports this repository carries: which JAR each one was read from, that JAR's
# SHA-256 at the time it was read, and any configured class name the script also serves. Used as the
# default for `build --origins` and as the baseline for `fingerprint`. Recording a digest is not
# unpacking anything: the JAR is a specification to read, never something to ship or execute.
DEFAULT_ORIGINS = {
    "AppGet":   {"originJar": "river-fman.jar",
                 "jarSha256": "3133519d148c35d03b947dc4b571ae7d59214422a181772ae5e4fe29ec680392"},
    "AppQi":    {"originJar": "river-fman.jar",
                 "jarSha256": "3133519d148c35d03b947dc4b571ae7d59214422a181772ae5e4fe29ec680392",
                 "notes": "xiaosa-0807 and 愛影 carry variants; the port covers their union"},
    "App99":    {"originJar": "river-fman.jar",
                 "jarSha256": "3133519d148c35d03b947dc4b571ae7d59214422a181772ae5e4fe29ec680392",
                 "notes": "xiaosa-0807 variant parses through /app/vodParser"},
    "App3Q":    {"originJar": "river-fman.jar",
                 "jarSha256": "3133519d148c35d03b947dc4b571ae7d59214422a181772ae5e4fe29ec680392"},
    "Bili":     {"originJar": "river-fman.jar",
                 "jarSha256": "3133519d148c35d03b947dc4b571ae7d59214422a181772ae5e4fe29ec680392",
                 "notes": "progressive durl instead of the original's DASH proxy; AVPlayer has no DASH"},
    "JianPian": {"originJar": "river-fman.jar",
                 "jarSha256": "3133519d148c35d03b947dc4b571ae7d59214422a181772ae5e4fe29ec680392",
                 "aliases": ["JPianAmns"],
                 "notes": "JPianAmns is a protected shim; this drives the same API"},
    "XBPQ":     {"originJar": "xyqxbpq.jar",
                 "jarSha256": "7b732f2289236619b791d9c5a0d862d42c9bf3e5bb6123a6982736329bbe9e16"},
    "XYQHiker": {"originJar": "xyqxbpq.jar",
                 "jarSha256": "7b732f2289236619b791d9c5a0d862d42c9bf3e5bb6123a6982736329bbe9e16"},
}


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=30) as response:
        return response.read()


def build(args) -> int:
    scripts_dir = pathlib.Path(args.scripts)
    out = pathlib.Path(args.out)
    (out / "scripts").mkdir(parents=True, exist_ok=True)
    known = json.loads(pathlib.Path(args.origins).read_text()) if args.origins else DEFAULT_ORIGINS

    entries = []
    for path in sorted(scripts_dir.glob("*.js")):
        if path.name in NOT_PACKABLE:
            continue
        body = path.read_bytes()
        name = path.stem
        meta = known.get(name, {})
        entry = {
            "class": name,
            "path": f"./scripts/{name}.js",
            "sha256": sha256_bytes(body),
        }
        for key in ("aliases", "originJar", "jarSha256", "minHostApi", "notes"):
            if meta.get(key) is not None:
                entry[key] = meta[key]
        entries.append(entry)
        shutil.copyfile(path, out / "scripts" / f"{name}.js")

    manifest = {"schema": SCHEMA, "version": args.version, "minHostApi": args.min_host_api, "scripts": entries}
    (out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(f"{len(entries)} scripts -> {out/'manifest.json'} (version {args.version}, minHostApi {args.min_host_api})")
    for entry in entries:
        print(f"  {entry['class']:<12} {entry['sha256'][:16]}… {entry.get('originJar', '-')}")
    return 0


def verify(args) -> int:
    manifest = json.loads(fetch(args.url))
    problems = []
    if manifest.get("schema") != SCHEMA:
        problems.append(f"schema {manifest.get('schema')} != {SCHEMA}")
    if (manifest.get("minHostApi") or 0) > HOST_API:
        problems.append(f"minHostApi {manifest['minHostApi']} > this tool's {HOST_API}")
    base = args.url.rsplit("/", 1)[0] + "/"
    for entry in manifest.get("scripts", []):
        url = entry["path"] if entry["path"].startswith("http") else base + entry["path"].lstrip("./")
        try:
            actual = sha256_bytes(fetch(url))
        except Exception as error:                      # noqa: BLE001 - reported, not raised
            problems.append(f"{entry['class']}: {type(error).__name__} {error}")
            continue
        status = "ok" if actual == entry["sha256"] else "MISMATCH"
        if status != "ok":
            problems.append(f"{entry['class']}: declared {entry['sha256'][:16]}… served {actual[:16]}…")
        print(f"  {entry['class']:<12} {status}")
    print(f"pack {manifest.get('version')}: {len(manifest.get('scripts', []))} scripts, {len(problems)} problem(s)")
    for problem in problems:
        print(f"  ! {problem}")
    return 1 if problems else 0


def fingerprint(args) -> int:
    """Which ports were written from a JAR that has since changed?

    Unchanged digest  -> nothing to do.
    Changed digest    -> read that one class again and diff it against the port. If the behaviour is
                         the same, update jarSha256 and republish the manifest; if the protocol moved,
                         update the script too. Neither case rebuilds the app unless the script needs
                         a host primitive this build does not have.
    """
    manifest = json.loads(pathlib.Path(args.manifest).read_text())
    if not manifest.get("scripts"):
        print("manifest has no scripts")
        return 1
    changed = []
    for entry in manifest.get("scripts", []):
        origin, declared = entry.get("originJar"), entry.get("jarSha256")
        if not origin or not declared:
            print(f"  {entry['class']:<12} no fingerprint recorded")
            continue
        location = os.path.join(args.jars, origin) if not origin.startswith("http") else origin
        try:
            data = fetch(location) if location.startswith("http") else pathlib.Path(location).read_bytes()
        except Exception as error:                      # noqa: BLE001
            print(f"  {entry['class']:<12} {origin}: unreadable ({type(error).__name__})")
            continue
        actual = sha256_bytes(data)
        same = actual == declared
        print(f"  {entry['class']:<12} {origin} {'unchanged' if same else 'CHANGED'}")
        if not same:
            changed.append((entry["class"], origin, actual))
    if changed:
        print("\nre-read these classes, then update jarSha256 (and the script only if behaviour moved):")
        for name, origin, actual in changed:
            print(f"  {name}: {origin} -> {actual}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    b = sub.add_parser("build")
    b.add_argument("--scripts", default="ios/Sources/WebHTVCore/Resources/Spiders")
    b.add_argument("--out", default="build/spider-pack")
    b.add_argument("--version", required=True)
    b.add_argument("--min-host-api", type=int, default=HOST_API)
    b.add_argument("--origins", help="JSON of per-class aliases/originJar/jarSha256/notes")
    b.set_defaults(func=build)

    v = sub.add_parser("verify")
    v.add_argument("--url", required=True)
    v.set_defaults(func=verify)

    f = sub.add_parser("fingerprint")
    f.add_argument("--manifest", required=True)
    f.add_argument("--jars", default=".", help="directory of JARs, or ignored when originJar is a URL")
    f.set_defaults(func=fingerprint)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
