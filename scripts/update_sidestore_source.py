#!/usr/bin/env python3
import argparse
import json
import plistlib
import zipfile
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"update_sidestore_source: {message}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--description", required=True)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--expected-build", required=True)
    args = parser.parse_args()

    source = json.loads(args.source.read_text())
    if source.get("identifier") != "com.webhtv.sidestore.source":
        fail("unexpected source identifier")
    if len(source.get("apps", [])) != 1:
        fail("source must contain exactly one app")
    app = source["apps"][0]

    with zipfile.ZipFile(args.ipa) as archive:
        info_paths = [
            name
            for name in archive.namelist()
            if name.startswith("Payload/")
            and name.count("/") == 2
            and name.endswith(".app/Info.plist")
        ]
        if len(info_paths) != 1:
            fail(f"expected one Payload/*.app/Info.plist, found {len(info_paths)}")
        info = plistlib.loads(archive.read(info_paths[0]))

    bundle = info.get("CFBundleIdentifier")
    version = info.get("CFBundleShortVersionString")
    build = info.get("CFBundleVersion")
    if bundle != app.get("bundleIdentifier"):
        fail(f"bundle identifier mismatch: IPA={bundle!r}, source={app.get('bundleIdentifier')!r}")
    if version != args.expected_version:
        fail(f"version mismatch: IPA={version!r}, expected={args.expected_version!r}")
    if build != args.expected_build:
        fail(f"build mismatch: IPA={build!r}, expected={args.expected_build!r}")

    release = {
        "version": version,
        "date": args.date,
        "localizedDescription": args.description,
        "downloadURL": args.download_url,
        "size": args.ipa.stat().st_size,
    }
    if minimum_os := info.get("MinimumOSVersion"):
        release["minOSVersion"] = minimum_os

    versions = [item for item in app["versions"] if item.get("version") != version]
    app["versions"] = [release, *versions]
    args.source.write_text(json.dumps(source, ensure_ascii=False, indent=2) + "\n")

    print(
        json.dumps(
            {
                "bundleIdentifier": bundle,
                "version": version,
                "buildVersion": build,
                "size": release["size"],
                "infoPlist": info_paths[0],
            }
        )
    )


if __name__ == "__main__":
    main()
