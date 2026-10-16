#!/usr/bin/env python3
"""The compatibility pack never ships a folder port (FOLDER-04, spider_pack.IPA_ONLY); since IOS-POC-61 S5 the
official pack is the only way they reach an App, so it must carry every one. Builds both from the repository's
scripts into a temporary directory and reads the manifests. Run from the repository root:
python3 -I scripts/test_pack_exclusions.py"""
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "ios/Spiders"
FOLDER_PORTS = {"Ikanbot", "Djuu"}


def classes(command: list, out: pathlib.Path, key: str) -> set:
    subprocess.run([sys.executable, "-I", *command, "--out", str(out)], cwd=ROOT, check=True, capture_output=True)
    return {entry["class"] for entry in json.loads((out / "manifest.json").read_text())[key]}


def names(manifest: pathlib.Path) -> set:
    """Every class name an official pack drives: its classes and their aliases."""
    return {name for entry in json.loads(manifest.read_text())["files"]
            for name in [entry["class"], *entry.get("aliases", [])]}


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        compat = classes(["scripts/spider_pack.py", "build", "--scripts", str(SCRIPTS), "--version", "test"],
                         tmp / "compat", "scripts")
        official = classes(["scripts/runtime_pack.py", "build", "--sequence", "1", "--version", "test"],
                           tmp / "official", "files")
        # W-141 M-3: the App counts `SpiderRegistry.ported` as what the 爬蟲工具 brings; the pack must bring exactly that.
        sys.path.insert(0, str(ROOT / "scripts"))
        from audit_spider_jars import registry_names
        shipped = names(tmp / "official" / "manifest.json")
        ported = registry_names(str(ROOT / "ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift"))["ported"]
    present = {path.stem for path in SCRIPTS.glob("*.js")}
    problems = []
    if not compat or not official:
        problems.append("a pack built empty")
    if compat & FOLDER_PORTS:
        problems.append(f"compatibility pack carries {sorted(compat & FOLDER_PORTS)}")
    if FOLDER_PORTS - official:
        problems.append(f"official pack lacks {sorted(FOLDER_PORTS - official)}")
    if shipped != ported:
        problems.append(f"official pack names differ from SpiderRegistry.ported: only in pack {sorted(shipped - ported)}, "
                        f"only in ported {sorted(ported - shipped)}")
    if not FOLDER_PORTS & present:
        problems.append("no folder port in the scripts, so this test proves nothing")
    for problem in problems:
        print(f"FAIL: {problem}")
    if not problems:
        print(f"PASS: compatibility {len(compat)} scripts without {sorted(FOLDER_PORTS & present)}, "
              f"official {len(official)} with them")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
