#!/usr/bin/env python3
"""Builds and verifies WebHTV's official spider pack (IOS-POC-61 S2, W-120).

The official pack is the `webhtv.runtime-pack` format the App's `RuntimePackUpdater` reads from
`ios-poc:spider-pack/official/`: `manifest.json` plus content-addressed `blobs/sha256/<hex>`. It is a
different thing from the compatibility pack `scripts/spider_pack.py` builds into `spider-pack/` (schema 1,
served beside a configuration), and the two live side by side; this tool never touches that one.

**Unsigned** by the user's 2026-10-15 decision: there is no `sign` or `keygen`. The trust is the App's
compiled-in HTTPS address, every blob's SHA-256 and the sequence floor.

    build  --sequence N --version V [--scripts DIR] --out DIR   write the pack; existing blobs are kept
    verify --dir DIR                                            0 problems or exit 1

Provenance, per-script `minHostApi` and pack aliases come from `spider_pack.DEFAULT_ORIGINS`, and the
App's own Swift aliases (`SpiderRegistry.aliases`) are added, so every name the App binds runs the
official script. Nothing here is a second copy of either table.
"""
import argparse, hashlib, json, pathlib, re, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import spider_pack  # noqa: E402
from audit_spider_jars import registry_names  # noqa: E402

FORMAT = "webhtv.runtime-pack"
SCHEMA = 1
PACK_ID = "webhtv.spiders"
# The whole pack asks only for the base js.host; a script that needs more says so itself (minHostApi),
# so an older App skips that one script instead of refusing the pack.
JS_HOST = {"major": 1, "minMinor": spider_pack.BASE_HOST_API}
# catvod.result 1.0: the ported spiders' results are additions-only over it (subs, jx, vod_tag), which an
# older App simply ignores.
CATVOD_RESULT = {"major": 1, "minMinor": 0}
# RuntimePackLimits (RuntimePackManifest.swift).
MANIFEST_BYTES, FILE_BYTES, PACK_BYTES, FILES, PATH_BYTES = 64 * 1024, 512 * 1024, 2 * 1024 * 1024, 64, 128
CLASS = re.compile(r"^[A-Za-z0-9_]{1,64}$")
PATH = re.compile(r"^[A-Za-z0-9._/-]+$")
RESERVED = {name.removesuffix(".js") for name in spider_pack.NOT_PACKABLE}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def encode(manifest: dict) -> bytes:
    return (json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def build(args) -> int:
    scripts = pathlib.Path(args.scripts)
    out = pathlib.Path(args.out)
    blobs = out / "blobs" / "sha256"
    blobs.mkdir(parents=True, exist_ok=True)
    swift_aliases = registry_names(args.registry)["aliases"]
    files = []
    for source in sorted(scripts.glob("*.js")):
        if source.name in spider_pack.NOT_PACKABLE:
            continue
        name = source.stem
        origin = spider_pack.DEFAULT_ORIGINS.get(name, {})
        data = source.read_bytes()
        digest = sha256(data)
        blob = blobs / digest
        if not blob.exists():  # content-addressed: an existing blob is the same bytes, and old ones stay
            blob.write_bytes(data)
        aliases = set(origin.get("aliases", [])) | {a for a, target in swift_aliases.items() if target == name}
        entry = {"path": f"spiders/{name}.js", "logicalType": "spider.js", "class": name,
                 "bytes": len(data), "sha256": digest}
        if aliases:
            entry["aliases"] = sorted(aliases)
        if origin.get("minHostApi", spider_pack.BASE_HOST_API) > spider_pack.BASE_HOST_API:
            entry["minHostApi"] = origin["minHostApi"]
        files.append(entry)
    manifest = {"format": FORMAT, "schema": SCHEMA, "packId": PACK_ID, "scope": {"kind": "global"},
                "sequence": args.sequence, "version": args.version,
                "requires": {"abi": {"js.host": JS_HOST, "catvod.result": CATVOD_RESULT}},
                "files": files}
    (out / "manifest.json").write_bytes(encode(manifest))
    print(f"official pack {args.version} (sequence {args.sequence}): {len(files)} scripts → {out}")
    return verify_dir(out)


def problems_in(directory: pathlib.Path) -> list[str]:
    raw = (directory / "manifest.json").read_bytes()
    if len(raw) > MANIFEST_BYTES:
        return [f"manifest is {len(raw)} bytes, over {MANIFEST_BYTES}"]
    manifest = json.loads(raw)
    found = []
    expect = {"format": FORMAT, "schema": SCHEMA, "scope": {"kind": "global"}}
    found += [f"{key} is {manifest.get(key)!r}, not {value!r}" for key, value in expect.items() if manifest.get(key) != value]
    if not isinstance(manifest.get("sequence"), int) or manifest["sequence"] < 1:
        found.append("sequence must be a whole number ≥ 1")
    abi = manifest.get("requires", {}).get("abi", {})
    if abi.get("js.host") != JS_HOST:
        found.append(f"requires.abi js.host is {abi.get('js.host')}, not the base {JS_HOST}")
    if "catvod.result" not in abi:
        found.append("requires.abi has no catvod.result")
    for key in ("revokeKeyIds", "directive"):
        if key in manifest:
            found.append(f"{key} is not used by the unsigned official pack")
    files = manifest.get("files", [])
    if not files or len(files) > FILES:
        found.append(f"{len(files)} files (1…{FILES})")
    seen, total = set(), 0
    for file in files:
        path = file.get("path", "")
        if (len(path.encode()) > PATH_BYTES or not PATH.match(path) or not path.endswith(".js")
                or any(part in ("", ".", "..") for part in path.split("/"))):
            found.append(f"{path!r}: not a relative spiders path")
        if path.lower() in seen:
            found.append(f"{path}: listed twice")
        seen.add(path.lower())
        names = [file.get("class", "")] + file.get("aliases", [])
        found += [f"{path}: class or alias {n!r} is not allowed" for n in names if not CLASS.match(n) or n in RESERVED]
        if file.get("logicalType") != "spider.js":
            found.append(f"{path}: logicalType {file.get('logicalType')!r}")
        if "minHostApi" in file and not (isinstance(file["minHostApi"], int) and file["minHostApi"] >= 1):
            found.append(f"{path}: minHostApi must be ≥ 1")
        size = file.get("bytes", 0)
        total += size if isinstance(size, int) else 0
        if not isinstance(size, int) or not 0 < size <= FILE_BYTES:
            found.append(f"{path}: {size} bytes (1…{FILE_BYTES})")
        blob = directory / "blobs" / "sha256" / file.get("sha256", "")
        if not blob.is_file():
            found.append(f"{path}: blob {file.get('sha256')} is missing")
            continue
        data = blob.read_bytes()
        if sha256(data) != file.get("sha256") or sha256(data) != blob.name:
            found.append(f"{path}: blob content does not hash to its name {blob.name}")
        if len(data) != size:
            found.append(f"{path}: blob is {len(data)} bytes, manifest says {size}")
    if total > PACK_BYTES:
        found.append(f"pack is {total} bytes, over {PACK_BYTES}")
    return found


def verify_dir(directory: pathlib.Path) -> int:
    found = problems_in(directory)
    for problem in found:
        print(f"  problem: {problem}")
    print(f"official pack at {directory}: {len(found)} problem(s)")
    return 1 if found else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build")
    b.add_argument("--scripts", default="ios/Sources/WebHTVCore/Resources/Spiders")
    b.add_argument("--registry", default="ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift")
    b.add_argument("--out", required=True)
    b.add_argument("--sequence", type=int, required=True)
    b.add_argument("--version", required=True)
    v = sub.add_parser("verify")
    v.add_argument("--dir", required=True)
    args = parser.parse_args()
    if args.command == "build":
        if args.sequence < 1:
            parser.error("--sequence must be ≥ 1")
        return build(args)
    return verify_dir(pathlib.Path(args.dir))


if __name__ == "__main__":
    sys.exit(main())
