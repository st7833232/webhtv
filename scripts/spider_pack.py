#!/usr/bin/env python3
"""Check the JARs the bundled iOS spider ports were written from.

The schema-1 compatibility pack this tool used to build and verify was removed in IOS-POC-13; runtime
packs are built, signed and verified by `webhtv-runtime-pack` (`swift run --package-path ios
webhtv-runtime-pack`). What stays here is the maintenance half that has nothing to do with a pack
format:

  fingerprint  re-hash the origin JARs and report which ports were written from a different build

This tool never decompiles, executes or unpacks a JAR. It reads bytes and computes a digest.
"""

import argparse, hashlib, os, pathlib, sys, urllib.request

# Provenance for the ports this repository carries: which JAR each one was read from, that JAR's
# SHA-256 at the time it was read, and any configured class name the script also serves. The baseline
# for `fingerprint`. Recording a digest is not
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


def fingerprint(args) -> int:
    """Which ports were written from a JAR that has since changed?

    Unchanged digest  -> nothing to do.
    Changed digest    -> read that one class again and diff it against the port. If the behaviour is
                         the same, update jarSha256 here; if the protocol moved, update the script and
                         publish it in a runtime pack. Neither case rebuilds the app unless the script
                         needs a host primitive this build does not have.
    """
    changed = []
    for name, entry in sorted(DEFAULT_ORIGINS.items()):
        entry = dict(entry, **{"class": name})
        origin, declared = entry.get("originJar"), entry.get("jarSha256")
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

    f = sub.add_parser("fingerprint")
    f.add_argument("--jars", default=".", help="directory of JARs, or ignored when originJar is a URL")
    f.set_defaults(func=fingerprint)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
