#!/bin/bash
# Put the CPython iOS payload where the Xcode project expects it.
#
# The payload is an official Python-Apple-support release asset, not something this project builds,
# so it is fetched rather than committed: re-downloading reproduces it byte for byte (checked on two
# separate days, see third_party/python-ios-lock.json), and 30 MB of immutable upstream binary in Git
# history buys nothing. third_party/python-ios/ is ignored; this script is how it comes to exist.
#
# Everything it needs is in the lock file, which stays the single source of truth for the version,
# the URL, the hash and what gets trimmed. IOS-POC-7E.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/third_party/python-ios-lock.json"
DEST="$ROOT/third_party/python-ios"
FORCE=0
SDK_ARGS=()

usage() {
  cat <<'EOF'
Usage: scripts/fetch_python_ios.sh [--force] [--sdk iphoneos|iphonesimulator]...

Downloads, verifies and unpacks the CPython iOS payload and the pure-Python wheels named by
third_party/python-ios-lock.json into third_party/python-ios/, then builds the native
packages (scripts/build_python_ios_native.sh) for the given sdks, or for both.

Does nothing when everything is already present and matches the lock, so it is safe to
run from a build phase. --force re-downloads regardless.
EOF
}

die() { printf 'fetch_python_ios: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --sdk) [[ $# -ge 2 ]] || die "--sdk needs a value"; SDK_ARGS+=(--sdk "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ -f "$LOCK" ]] || die "missing lock file: $LOCK"
command -v shasum >/dev/null || die "shasum not found"

field() { /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upstream"][sys.argv[2]])' "$LOCK" "$1"; }

URL="$(field url)"
WANT_SHA="$(field sha256)"
WANT_BYTES="$(field bytes)"
RELEASE="$(field release)"
STAMP="$DEST/.payload-sha256"

prepare_module_maps() {
  local slice headers
  for slice in "$DEST/Python.xcframework"/ios-*; do
    [[ -d "$slice" ]] || continue
    headers="$slice/Python.framework/Headers/module.modulemap"
    [[ -f "$headers" ]] || continue
    mkdir -p "$slice/Python.framework/Modules"
    sed 's/^module Python {/framework module Python {/' "$headers" \
      > "$slice/Python.framework/Modules/module.modulemap"
  done
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ $FORCE -eq 0 && -f "$STAMP" && "$(cat "$STAMP")" == "$WANT_SHA" ]]; then
  printf 'fetch_python_ios: %s already present (%s)\n' "$RELEASE" "$DEST"
else
printf 'fetch_python_ios: downloading %s\n' "$RELEASE"
curl -fL --retry 3 -o "$TMP/payload.tar.gz" "$URL" || die "download failed: $URL"

# Fail closed on both size and hash. A truncated download hashes differently anyway; the size check
# is here so the common failure reports the obvious thing rather than a hash mismatch.
GOT_BYTES="$(wc -c < "$TMP/payload.tar.gz" | tr -d ' ')"
[[ "$GOT_BYTES" == "$WANT_BYTES" ]] || die "size mismatch: got $GOT_BYTES, lock says $WANT_BYTES"
GOT_SHA="$(shasum -a 256 "$TMP/payload.tar.gz" | awk '{print $1}')"
[[ "$GOT_SHA" == "$WANT_SHA" ]] || die "sha256 mismatch: got $GOT_SHA, lock says $WANT_SHA"

printf 'fetch_python_ios: verified sha256 %s\n' "$GOT_SHA"

rm -rf "$DEST"
mkdir -p "$DEST"
tar xzf "$TMP/payload.tar.gz" -C "$DEST"

# Trim the obvious non-shippables named by the lock. Paths that are already absent are not an error:
# a future release may drop one of them on its own.
/usr/bin/python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["trim"]))' "$LOCK" |
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    rm -rf "${DEST:?}/$path"
  done

[[ -d "$DEST/Python.xcframework/ios-arm64/Python.framework" ]] || die "unpacked payload has no device slice"
[[ -d "$DEST/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework" ]] || die "unpacked payload has no simulator slice"
[[ -f "$DEST/Python.xcframework/lib/python3.13/os.py" ]] || die "unpacked payload has no standard library"
printf '%s' "$WANT_SHA" > "$STAMP"
fi
prepare_module_maps

# The pure-Python wheels a spider's `import requests` needs. Same discipline as the interpreter:
# every one pinned by size and hash in the lock, every failure closed. Nothing here compiles — the
# interpreter already carries _ssl, _socket, _hashlib and select. Their own stamp, so adding a wheel
# to the lock (IOS-POC-37) reaches a checkout whose interpreter is already current.
PACKAGES="$DEST/site-packages"
WHEELS_STAMP="$DEST/.wheels-sha256"
WANT_WHEELS="$(/usr/bin/python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["python_packages"], sort_keys=True))' "$LOCK" | shasum -a 256 | awk '{print $1}')"
if [[ $FORCE -eq 0 && -f "$WHEELS_STAMP" && "$(cat "$WHEELS_STAMP")" == "$WANT_WHEELS" ]]; then
  printf 'fetch_python_ios: pure-Python wheels already present\n'
else
rm -rf "$PACKAGES"
mkdir -p "$PACKAGES"
/usr/bin/python3 -c 'import json,sys
for w in json.load(open(sys.argv[1]))["python_packages"]["wheels"]:
    print(w["name"], w["version"], w["bytes"], w["sha256"], w["url"])' "$LOCK" |
  while read -r name version bytes sha url; do
    wheel="$TMP/$name.whl"
    printf 'fetch_python_ios: %s %s\n' "$name" "$version"
    curl -fL --retry 3 -o "$wheel" "$url" || die "download failed: $url"
    got_bytes="$(wc -c < "$wheel" | tr -d ' ')"
    [[ "$got_bytes" == "$bytes" ]] || die "$name size mismatch: got $got_bytes, lock says $bytes"
    got_sha="$(shasum -a 256 "$wheel" | awk '{print $1}')"
    [[ "$got_sha" == "$sha" ]] || die "$name sha256 mismatch: got $got_sha, lock says $sha"
    # A wheel is a zip. Its `.dist-info` is metadata for an installer there is none of here.
    /usr/bin/unzip -q -o "$wheel" -d "$PACKAGES" || die "could not unpack $name"
  done
rm -rf "$PACKAGES"/*.dist-info
[[ -f "$PACKAGES/requests/__init__.py" ]] || die "requests did not unpack"
[[ -f "$PACKAGES/bs4/__init__.py" && -f "$PACKAGES/pyquery/__init__.py" ]] || die "bs4/pyquery did not unpack"
printf '%s' "$WANT_WHEELS" > "$WHEELS_STAMP"
fi

# The packages with C code are built, not fetched: there is no iOS binary of them to trust.
"$ROOT/scripts/build_python_ios_native.sh" ${SDK_ARGS[@]+"${SDK_ARGS[@]}"}

printf 'fetch_python_ios: %s ready at %s (%s)\n' "$RELEASE" "$DEST" "$(du -sh "$DEST" | awk '{print $1}')"
