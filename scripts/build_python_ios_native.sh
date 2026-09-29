#!/bin/bash
# Cross-compile the Python packages that carry native code — pycryptodome and lxml (with libxml2 and
# libxslt) — for the iOS device and the Simulator, from pinned upstream sources.
#
# Why build rather than fetch: PyPI has no iOS wheel for either, and a macOS or Linux wheel will not
# load on iOS (a different platform in the Mach-O load commands), so there is nothing trustworthy to
# download. Every input is named in third_party/python-ios-lock.json → python_native_packages with
# its size and SHA-256, and every failure is closed. The compiler is Xcode's; the Python that drives
# the build is a host CPython of the same minor version, turned into an iOS cross environment with
# the make_cross_venv.py that Python-Apple-support ships in each slice — the same mechanism
# cibuildwheel uses for iOS.
#
# Output: third_party/python-ios/native/<sdk>/, untracked, one site-packages-shaped tree per sdk. The
# Install Python build phase copies the tree for the sdk being built and converts each .so into a
# framework with upstream's own install_python. Idempotent: a stamp over the lock section, this
# script and the patches skips a tree that is already current.
#
# IOS-POC-37.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/third_party/python-ios-lock.json"
XCF="$ROOT/third_party/python-ios/Python.xcframework"
OUT="$ROOT/third_party/python-ios/native"
WORK="${WEBHTV_NATIVE_WORK:-$ROOT/build/python-ios-native}"
SDKS=()

usage() {
  cat <<'EOF'
Usage: scripts/build_python_ios_native.sh [--sdk iphoneos|iphonesimulator]...

Builds every native package named in third_party/python-ios-lock.json for the given
sdks (both when none is given) into third_party/python-ios/native/<sdk>/.
Needs Xcode and a host python3.13 (or PYTHON_HOST=/path/to/python3.13), and the CPython
payload from scripts/fetch_python_ios.sh, which calls this script itself.
EOF
}

die() { printf 'build_python_ios_native: %s\n' "$*" >&2; exit 1; }
say() { printf 'build_python_ios_native: %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sdk) [[ $# -ge 2 ]] || die "--sdk needs a value"; SDKS+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ ${#SDKS[@]} -gt 0 ]] || SDKS=(iphoneos iphonesimulator)

[[ -f "$LOCK" ]] || die "missing lock file: $LOCK"
[[ -d "$XCF" ]] || die "no CPython payload at $XCF; run scripts/fetch_python_ios.sh"

# Every read of the lock goes through here, so the lock stays the single source of truth.
lock() { /usr/bin/python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['python_native_packages']; $1" "$LOCK" "${@:2}"; }

WANT_PY="$(lock 'print(d["host_python"])')"
MIN_IOS="$(lock 'print(d["min_ios"])')"
HOST_PY=""

# Only looked for when something has to be built: an Xcode build phase runs with a PATH that has no
# Homebrew on it, and a current tree must not need a host Python at all.
host_python() {
  [[ -z "$HOST_PY" ]] || return 0
  local candidate
  for candidate in "${PYTHON_HOST:-}" "$(command -v "python$WANT_PY" || true)" "/opt/homebrew/bin/python$WANT_PY" \
      "/usr/local/bin/python$WANT_PY" "/Library/Frameworks/Python.framework/Versions/$WANT_PY/bin/python$WANT_PY"; do
    [[ -n "$candidate" && -x "$candidate" ]] && { HOST_PY="$candidate"; break; }
  done
  [[ -n "$HOST_PY" ]] || die "no host python$WANT_PY (brew install python@$WANT_PY, or set PYTHON_HOST)"
  local got
  got="$("$HOST_PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  [[ "$got" == "$WANT_PY" ]] || die "host python is $got; extension modules must be built by $WANT_PY"
}

# What the trees are built from. Any change to it rebuilds them.
STAMP_WANT="$( { lock 'print(json.dumps(d, sort_keys=True))'; cat "$0" "$ROOT"/third_party/python-ios-patches/*; } \
  | shasum -a 256 | awk '{print $1}')"

# Download once into the work cache, then verify size and hash on every use. Fail closed.
verified() {  # name url bytes sha256 -> path
  local name="$1" url="$2" bytes="$3" sha="$4" file
  file="$WORK/downloads/$(basename "$url")"
  mkdir -p "$WORK/downloads"
  if [[ ! -f "$file" ]]; then
    curl -fL --retry 3 -o "$file.part" "$url" >&2 || die "download failed: $url"
    mv "$file.part" "$file"
  fi
  [[ "$(wc -c < "$file" | tr -d ' ')" == "$bytes" ]] || { rm -f "$file"; die "$name size mismatch (lock says $bytes)"; }
  [[ "$(shasum -a 256 "$file" | awk '{print $1}')" == "$sha" ]] || { rm -f "$file"; die "$name sha256 mismatch"; }
  printf '%s\n' "$file"
}

source_file() {  # name -> verified path of that source
  local row
  row="$(lock 'print(*next((s["name"], s["url"], s["bytes"], s["sha256"]) for s in d["sources"] if s["name"] == sys.argv[2]))' "$1")"
  # shellcheck disable=SC2086
  verified $row
}

unpack() {  # archive destination-parent -> unpacked directory
  local archive="$1" parent="$2" top
  mkdir -p "$parent"
  top="$(tar tf "$archive" | head -1 | cut -d/ -f1)"
  rm -rf "${parent:?}/$top"
  tar xf "$archive" -C "$parent"
  printf '%s\n' "$parent/$top"
}

build_sdk() {
  local sdk="$1" slice config clang_name
  read -r slice config clang_name < <(lock \
    'print(*next((t["slice"], t["platform_config"], t["clang"]) for t in d["targets"] if t["sdk"] == sys.argv[2]))' "$sdk") \
    || die "the lock names no target for sdk $sdk"
  local dest="$OUT/$sdk" work="$WORK/$sdk"
  if [[ -f "$dest/.stamp" && "$(cat "$dest/.stamp")" == "$STAMP_WANT" ]]; then
    say "$sdk already current ($dest)"
    return
  fi
  host_python
  say "building for $sdk with $HOST_PY"
  rm -rf "$work" "$dest"
  mkdir -p "$work/src" "$work/wheels"

  local bin="$XCF/$slice/bin"
  [[ -x "$bin/$clang_name" ]] || die "payload has no $bin/$clang_name"
  # A clean environment, so an Xcode build phase's SDKROOT, deployment target or compiler flags cannot
  # leak in and make the same inputs produce different binaries depending on who ran this.
  local -a env_clean=(env -i HOME="$HOME" PATH="$bin:/usr/bin:/bin:/usr/sbin:/sbin"
    LANG=C LC_ALL=C IPHONEOS_DEPLOYMENT_TARGET="$MIN_IOS" PIP_DISABLE_PIP_VERSION_CHECK=1)
  [[ -n "${DEVELOPER_DIR:-}" ]] && env_clean+=(DEVELOPER_DIR="$DEVELOPER_DIR")

  # The cross environment: a host venv with the pinned setuptools, then converted in place.
  local setuptools_row setuptools
  setuptools_row="$(lock 'print(*next((t["name"], t["url"], t["bytes"], t["sha256"]) for t in d["build_tools"] if t["name"] == "setuptools"))')"
  # shellcheck disable=SC2086
  setuptools="$(verified $setuptools_row)"
  "${env_clean[@]}" "$HOST_PY" -m venv "$work/venv"
  "${env_clean[@]}" "$work/venv/bin/python" -m pip install --quiet --no-index --no-deps "$setuptools"
  "${env_clean[@]}" "$HOST_PY" "$XCF/$slice/platform-config/$config/make_cross_venv.py" "$work/venv"
  local py="$work/venv/bin/python"
  [[ "$("${env_clean[@]}" "$py" -c 'import sys; print(sys.platform)')" == "ios" ]] || die "cross venv for $sdk did not take"
  local -a pip_wheel=("${env_clean[@]}" "$py" -m pip wheel --no-deps --no-build-isolation --no-cache-dir
    --no-index --wheel-dir "$work/wheels")

  # pycryptodome, with the one-line-of-behaviour loader patch it needs to find its own raw
  # libraries once install_python has moved them into frameworks.
  local crypto
  crypto="$(unpack "$(source_file pycryptodome)" "$work/src")"
  patch -d "$crypto" -p1 --quiet < "$ROOT/third_party/python-ios-patches/pycryptodome-3.23.0-ios-fwork.patch" \
    || die "pycryptodome patch did not apply"
  "${pip_wheel[@]}" "$crypto" > "$work/pycryptodome.log" 2>&1 || die "pycryptodome build failed; see $work/pycryptodome.log"

  # libxml2 and libxslt as static archives, configured the way lxml's own buildlibxml.py configures
  # them for its release wheels, except that zlib and iconv are the SDK's.
  local prefix="$work/xml" lxml_src libxml2 libxslt
  lxml_src="$(unpack "$(source_file lxml)" "$work/src")"
  local -a configure=(--host=aarch64-apple-darwin --prefix="$prefix" --disable-shared --enable-static
    --disable-dependency-tracking --without-python)
  local -a cross_cc=(CC="$bin/$clang_name" CFLAGS="-O2 -fPIC" AR="$bin/${clang_name%-clang}-ar")
  libxml2="$(unpack "$(source_file libxml2)" "$work/src")"
  ( cd "$libxml2" && "${env_clean[@]}" "${cross_cc[@]}" ./configure "${configure[@]}" \
      --with-zlib --with-iconv --without-lzma --without-http --without-icu --without-readline \
      && "${env_clean[@]}" make -j"$(sysctl -n hw.ncpu)" && "${env_clean[@]}" make install ) \
    > "$work/libxml2.log" 2>&1 || die "libxml2 build failed; see $work/libxml2.log"
  libxslt="$(unpack "$(source_file libxslt)" "$work/src")"
  ( cd "$lxml_src" && "$HOST_PY" -c 'import sys; from patch_lxml_deplibs import apply_patch_file; apply_patch_file(*sys.argv[1:])' \
      libxslt-1.1.43-backport1.patch "$libxslt" ) > "$work/libxslt-patch.log" 2>&1 \
    || die "lxml's libxslt backport patch did not apply; see $work/libxslt-patch.log"
  ( cd "$libxslt" && "${env_clean[@]}" "${cross_cc[@]}" ./configure "${configure[@]}" \
      --with-libxml-prefix="$prefix" --without-crypto \
      && "${env_clean[@]}" make -j"$(sysctl -n hw.ncpu)" && "${env_clean[@]}" make install ) \
    > "$work/libxslt.log" 2>&1 || die "libxslt build failed; see $work/libxslt.log"
  [[ -f "$prefix/lib/libxml2.a" && -f "$prefix/lib/libxslt.a" && -f "$prefix/lib/libexslt.a" ]] \
    || die "libxml2/libxslt left no static archives in $prefix/lib"

  # lxml against those archives. `-liconv` because libxml2 was built with it and lxml's own link line
  # only names xslt, exslt, xml2, z and m.
  "${env_clean[@]}" XML2_CONFIG="$prefix/bin/xml2-config" XSLT_CONFIG="$prefix/bin/xslt-config" \
    WITHOUT_OBJECTIFY=true LDFLAGS="-liconv" \
    "$py" -m pip wheel --no-deps --no-build-isolation --no-cache-dir --no-index --wheel-dir "$work/wheels" \
    "$lxml_src" > "$work/lxml.log" 2>&1 || die "lxml build failed; see $work/lxml.log"

  # Unpack into the tree the app bundles, drop what never runs, and strip local symbols.
  local staging="$dest.partial" wheel
  rm -rf "$staging"
  mkdir -p "$staging"
  for wheel in "$work/wheels"/*.whl; do
    /usr/bin/unzip -q -o "$wheel" -d "$staging" || die "could not unpack $wheel"
  done
  lock 'print("\n".join(d["trim"]))' | while IFS= read -r pattern; do
    [[ -n "$pattern" ]] || continue
    if [[ "$pattern" == \** ]]; then
      find "$staging" -name "$pattern" -prune -exec rm -rf {} +
    else
      rm -rf "${staging:?}/$pattern"
    fi
  done
  find "$staging" -name '*.so' -exec strip -x {} +

  # Refuse a tree that is not what it claims to be: every binary must be an arm64 Mach-O for this
  # sdk's platform (2 = iOS, 7 = iOS Simulator), and both packages must be there.
  local want_platform so
  want_platform=$([[ "$sdk" == iphoneos ]] && echo 2 || echo 7)
  [[ -f "$staging/Crypto/Cipher/_raw_aes.abi3.so" ]] || die "$sdk tree has no pycryptodome AES"
  ls "$staging"/lxml/etree*.so > /dev/null 2>&1 || die "$sdk tree has no lxml.etree"
  while IFS= read -r so; do
    [[ "$(lipo -archs "$so")" == "arm64" ]] || die "$so is not arm64-only"
    otool -l "$so" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}' | grep -qx "$want_platform" \
      || die "$so is not built for $sdk"
  done < <(find "$staging" -name '*.so')

  # What was built, with which toolchain: compiled output is not byte-reproducible across Xcode
  # versions, so its hashes are a record, not a pin.
  "$HOST_PY" - "$staging/BUILD-INFO.json" "$sdk" "$work/wheels" <<'PY'
import hashlib, json, pathlib, subprocess, sys
out, sdk, wheels = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
info = {
    "sdk": sdk,
    "xcode": subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).stdout.split(),
    "sdk_version": subprocess.run(["xcrun", "--sdk", sdk, "--show-sdk-version"], capture_output=True, text=True).stdout.strip(),
    "wheels": {w.name: {"bytes": w.stat().st_size, "sha256": hashlib.sha256(w.read_bytes()).hexdigest()}
               for w in sorted(wheels.glob("*.whl"))},
}
pathlib.Path(out).write_text(json.dumps(info, indent=2) + "\n")
PY
  rm -rf "$dest"
  mv "$staging" "$dest"
  printf '%s' "$STAMP_WANT" > "$dest/.stamp"
  say "$sdk ready at $dest ($(du -sh "$dest" | awk '{print $1}'))"
}

for sdk in "${SDKS[@]}"; do
  build_sdk "$sdk"
done
