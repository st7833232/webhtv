#!/usr/bin/env python3
"""Neither pack tool may ship a folder port: the compatibility pack never (FOLDER-04, spider_pack.IPA_ONLY),
the first official pack not yet (runtime_pack.NOT_IN_FIRST_OFFICIAL_PACK). Builds both from the repository's
scripts into a temporary directory and reads the manifests. Run from the repository root:
python3 -I scripts/test_pack_exclusions.py"""
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "ios/Sources/WebHTVCore/Resources/Spiders"
FOLDER_PORTS = {"Ikanbot", "Djuu"}


def classes(command: list, out: pathlib.Path, key: str) -> set:
    subprocess.run([sys.executable, "-I", *command, "--out", str(out)], cwd=ROOT, check=True, capture_output=True)
    return {entry["class"] for entry in json.loads((out / "manifest.json").read_text())[key]}


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        compat = classes(["scripts/spider_pack.py", "build", "--scripts", str(SCRIPTS), "--version", "test"],
                         tmp / "compat", "scripts")
        official = classes(["scripts/runtime_pack.py", "build", "--sequence", "1", "--version", "test"],
                           tmp / "official", "files")
    present = {path.stem for path in SCRIPTS.glob("*.js")}
    problems = []
    if not compat or not official:
        problems.append("a pack built empty")
    for name, packed in (("compatibility", compat), ("official", official)):
        if packed & FOLDER_PORTS:
            problems.append(f"{name} pack carries {sorted(packed & FOLDER_PORTS)}")
    if not FOLDER_PORTS & present:
        problems.append("no folder port in the scripts, so this test proves nothing")
    for problem in problems:
        print(f"FAIL: {problem}")
    if not problems:
        print(f"PASS: compatibility {len(compat)} and official {len(official)} scripts, none of "
              f"{sorted(FOLDER_PORTS & present)}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
