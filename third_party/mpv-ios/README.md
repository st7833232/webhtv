# MPV iOS build inputs

The iOS app plays through the LGPL `MPVKit` product of
[MPVKit](https://github.com/mpvkit/MPVKit) 1.0.0. Every binary it links is the
upstream 1.0.0 release asset except `Libmpv.xcframework`, which WebHTV
rebuilds from the same recipe with two changes to mpv. The first is
`video/out/vulkan/context_moltenvk.m` (IOS-POC-17I). The upstream context reads
the layer size only when the video output is configured, so after a rotation
mpv kept drawing the old rectangle until the app rebuilt the whole output. The
WebHTV context reports layer resizes to mpv as they happen. The second
(IOS-POC-24) gives mpv's two iOS audio outputs an option to leave the app's
audio session alone, because the app also plays through AVPlayer and owns the
one session both engines share.

`../mpv-ios-lock.json` pins every input and the published artifact.
`.github/workflows/ios-libmpv-build.yml` is the only build path and the only
reader of the lock. `MANIFEST.sha256` lists the files in this directory.

The app takes the artifact through `ios/Vendor/MPVKit/Package.swift`, MPVKit
1.0.0's manifest copied unchanged except for the `Libmpv` target's `url` and
`checksum`, which are the lock's `artifact.url` and `artifact.sha256`. A new
build has to change both files.

## Files

- `patches/libmpv/0001-player-add-moltenvk-context.patch` replaces the MPVKit
  patch of the same name. It is the upstream patch with a new
  `context_moltenvk.m`:
  - `VOCTRL_CHECK_EVENTS` compares the layer's `drawableSize` with the last
    size it used; on a change it resizes the swapchain and reports
    `VO_EVENT_RESIZE`, which makes mpv recompute its rectangles and redraw.
  - `wait_events` caps the video thread's sleep at 100 ms, so a rotation while
    paused is noticed without a seek or a rebuild. Nothing else wakes that
    thread when only the layer changes.
  - Sizes of 1 pixel or less are ignored (a layer that is not laid out reports
    0x0 and MoltenVK can leave it at 1x1), and an unusable size at configure
    time keeps the current swapchain instead of failing the output, as the
    upstream context does.

  The resize approach comes from edde746/MPVKit
  `e6b129fdd31347b25d5d862f73f52c23f9e55624`, committed while that repository
  was LGPL; the file keeps mpv's LGPL-2.1-or-later header.
  `docs/IOS-POC-17I-mpv-resize-libmpv.md` records the research and the
  changes made to it.
- `patches/libmpv/0004-ao-app-owned-audio-session.patch` is applied after the
  recipe's own patches (the workflow copies it in as `0004`, and the recipe
  applies patches in file-name order). It adds
  `audiounit-skip-session-management` to `audio/out/ao_audiounit.m` and
  `avfoundation-skip-session-management` to `audio/out/ao_avfoundation.m`,
  both off by default. When set, the output does not set the session's
  category or mode, does not activate it, and does not deactivate it when the
  output goes away; it still sets the preferred number of output channels.
  The option follows media-kit's libmpv patch
  (`media-kit/libmpv-darwin-build`
  `159703a6f8b17bdb756d5a687d1ec1e29d90d366`,
  `763a7fa17a1d66ebf29b8fe2fb46c15769d3a12e`);
  `docs/IOS-POC-24-audio-session-ownership.md` records the research and what
  WebHTV changed.
- `patches/buildscripts/0001-restore-prebuilt-ffmpeg.patch` changes the
  recipe to restore FFmpeg from the 1.0.0 `FFmpeg-all.zip` instead of
  compiling it, so libmpv is the only thing built.
- `licenses/` holds the notices of everything the LGPL `MPVKit` product links
  on iOS.
- `patches/ffmpeg/0001`…`0006` (IOS-POC-26-2b) are the FFmpeg patches of the
  second lane, `.github/workflows/ios-ffmpeg-build.yml`. Applied in order to
  FFmpeg `n8.1.2` (`38b88335f99e76ed89ff3c93f877fdefce736c13`), they give HLS
  packet timestamps the playlist timeline across `EXT-X-DISCONTINUITY`, which
  FFmpeg ignores: without it mpv's `time-pos` inside an inserted ad is the ad's
  own clock, and a seek from there lands near the start of the episode.
  `0002` and `0003` are upstream `caa3fa6af070c1eeee59da027fdcde326fc64a89`
  and `e27ad5760c0c8eca7c95bb907dc6e4e62dbf129b` (`0001` and `0004` carry
  their test), `0005` is FongMi/FFmpeg
  `5805f9364c2e9a5f6ce625c9077b308c3ed4014d`, the fix WebHTV Android ships, and
  `0006` is the WebHTV adaptation recorded in
  `docs/IOS-POC-26-engine-switch-position.md`. Only libavformat's internals
  change; no installed header does.
- `patches/buildscripts/0002-build-ffmpeg-only.patch` ends the recipe after
  FFmpeg in that lane, which uses neither the WebHTV libmpv patches nor
  `0001-restore-prebuilt-ffmpeg.patch`.

## Build and checks

The workflow runs on `macos-26` with the pinned Xcode and meson. It checks out
the recipe at `recipe.build_commit` in the directory the 1.0.0 release was
built in, verifies the upstream patches, swaps in the WebHTV 0001, adds the WebHTV 0004, places every
dependency zip from the lock (the recipe then never downloads), and runs
`make build platform=ios`: `-Dgpl=false`, device arm64 plus the arm64 and
x86_64 simulator. Before publishing it requires the device slice to match the
upstream `Libmpv` in:

- the embedded `Configuration:` and `List of enabled features:` strings;
- the static library's members and its defined external symbols;
- every framework file other than the binary.

It also requires the WebHTV changes to be in the result: the moltenvk context's
reference to `vo_wait_default`, and the `skip-session-management` option name.

Undefined symbols may differ only through the `context_moltenvk` member, with
one named exception accepted on 2026-09-25: `_wcslen`, as long as
`filters/f_hwtransfer.c` is its only user. Xcode 26's clang compiles the loop
there that counts the zero-terminated `supported_formats` list into a `wcslen`
call, which is the same loop on Apple platforms (`wchar_t` is a 32-bit `int`);
the upstream build, made with Xcode 15.4, keeps the loop. The result is
published as a prerelease under `artifact.release_tag`, with the
build manifest, the comparison report and the build log. The workflow refuses
to replace a published tag, so a new build needs a new tag in the lock.

## FFmpeg lane (IOS-POC-26-2b)

`.github/workflows/ios-ffmpeg-build.yml` reads the lock's `ffmpeg` section. It
uses the same recipe checkout, toolchain and dependency zips as the libmpv
lane except `FFmpeg-all.zip`, places `patches/ffmpeg` where the recipe applies
FFmpeg patches (the recipe has none of its own, and the workflow fails if that
changes), and runs `make build platform=ios` with the `0002` buildscripts patch.
Before publishing `Libavformat.xcframework.zip` as a prerelease under
`ffmpeg.artifact.release_tag`, it requires the device slices to show:

- `Libavutil`, which no patch touches, identical to upstream 1.0.0 in its
  configuration string, archive members and defined and undefined external
  symbols (the evidence that the lane reproduces the recipe's FFmpeg build);
- `Libavformat` identical to upstream 1.0.0 in its configuration and version
  strings and every framework file but the binary, with exactly one added
  member (`hls_timestamp.o`), exactly six added defined symbols
  (`ff_hls_timestamp_*`), nothing removed, and undefined symbols changed only
  through `hls.o` and `hls_timestamp.o`.

Two toolchain differences are allowed by name, accepted by the user on
2026-09-26 after run `36215262840` (this lane uses Xcode 26.6; the upstream
build used Xcode 15.4). `dashdec.o` may call `free`/`realloc` where upstream
calls libxml2's `xmlFree`/`xmlRealloc`, because the Xcode 26.6 SDK's libxml2
headers map them so; it must be the only user of those four symbols on each
side. `Headers/config.h` may differ only in `CC_IDENT` and three probes
(`HAVE_AS_ARCHEXT_DOTPROD_DIRECTIVE`, `HAVE_AS_ARCHEXT_I8MM_DIRECTIVE`,
`HAVE_KVTQPMODULATIONLEVEL_DEFAULT`), with Xcode 26.6's values; the probes only
reach libavcodec's assembly and the VideoToolbox encoder. `Libavutil`, compared
in full, showed no difference at all.

Since IOS-POC-26-2b-2 the app's `Libavformat` target is that artifact
(`ffmpeg-n8.1.2-webhtv.1`, run `36226970983`). Like the libmpv lane's
`Libmpv`, it carries only the iOS device and simulator slices.

## Corresponding source

The modified library is mpv `v0.41.0`
(`41f6a645068483470267271e1d09966ca3b9f413`) with, in order, the WebHTV
`0001` above and MPVKit's `0002-revert-build-static.patch` and
`0003-enable-avfoundation-ao-tvos.patch` from recipe commit
`9d057f9c19fa704e242b199d26bc6c5cf23dd5d6`, then the WebHTV `0004` above. The workflow and the lock rebuild
it from those inputs. `Libavformat` is FFmpeg `n8.1.2`
(`38b88335f99e76ed89ff3c93f877fdefce736c13`) with `patches/ffmpeg/0001`…`0006`
above, rebuilt by the FFmpeg lane from the lock's `ffmpeg` section. The other
FFmpeg libraries and the other libraries are unmodified upstream binaries;
their versions are in the lock and in `licenses/`.

## Licences

`licenses/` holds the upstream licence files of everything the LGPL `MPVKit`
product links on iOS, copied byte for byte from the source revision behind
each 1.0.0 binary. Versions were read from the recipe and from each
`mpvkit/*-build` repository at the tag the lock pins (2026-09-25); four files
were rechecked against independent clones. The libbluray, libudfread and
uchardet files were fetched from their upstream repositories by a one-off
GitHub Actions job (runs `36087320182` and `36088056862`), because their
hosts are blocked from the environment that collected the rest; each file's
git blob id matches the tagged tree.

| Component (binaries) | Source | Licence as stated upstream | Files |
|---|---|---|---|
| mpv (`Libmpv`, the WebHTV build) | v0.41.0 `41f6a645` | LGPL-2.1-or-later (`-Dgpl=false`) | `LICENSE.mpv`, `LICENSE.mpv.Copyright` |
| FFmpeg (`Libavcodec`, `Libavdevice`, `Libavfilter`, `Libavformat`, `Libavutil`, `Libswresample`, `Libswscale`) | n8.1.2 `38b88335` | LGPL, version 3 or later in this build (`--enable-version3`, no `--enable-gpl`) | `LICENSE.ffmpeg`, `LICENSE.ffmpeg.COPYING.LGPLv3`, `LICENSE.ffmpeg.COPYING.GPLv3`, `LICENSE.ffmpeg.COPYING.LGPLv2.1` |
| OpenSSL (`Libssl`, `Libcrypto`) | 3.3.5 `f10934c4` | Apache-2.0 | `LICENSE.openssl` |
| GnuTLS (`gnutls`) | 3.8.11 `b841c70e` | LGPL-2.1-or-later (library) | `LICENSE.gnutls`, `LICENSE.gnutls.COPYING` |
| inih, crau and CRYPTOGAMS code inside `gnutls` | same | BSD-3-Clause; MIT OR Unlicense; CRYPTOGAMS licence | `LICENSE.gnutls.lib-inih-LICENSE.txt`, `LICENSE.gnutls.lib-crau-*`, `LICENSE.gnutls.devel-perlasm-license.txt` |
| Nettle (`nettle`, `hogweed`) | 3.10 `b8c841dc` | LGPL-3.0-or-later OR GPL-2.0-or-later | `LICENSE.nettle`, `LICENSE.nettle.COPYINGv2`, `LICENSE.nettle.COPYINGv3` |
| GMP (`gmp`) | 6.2.1 `2bbd5270` | LGPL-3.0-or-later OR GPL-2.0-or-later | `LICENSE.gmp`, `LICENSE.gmp.COPYING`, `LICENSE.gmp.COPYINGv2`, `LICENSE.gmp.COPYINGv3` |
| libass (`Libass`) | 0.17.5 `4a05d812` | ISC | `LICENSE.libass` |
| FreeType (`Libfreetype`) | 2.14.3 `0a0221a1` | FTL OR GPL-2.0-or-later; the BDF and PCF drivers carry X11-style notices | `LICENSE.freetype`, `LICENSE.freetype.docs-FTL.TXT`, `LICENSE.freetype.docs-GPLv2.TXT`, `LICENSE.freetype.src-bdf-README`, `LICENSE.freetype.src-pcf-README` |
| FriBidi (`Libfribidi`) | 1.0.16 `68162bab` | LGPL-2.1-or-later | `LICENSE.fribidi` |
| HarfBuzz (`Libharfbuzz`) | 14.2.0 `b0ffab42` | Old MIT; `src/ms-use` MIT | `LICENSE.harfbuzz`, `LICENSE.harfbuzz.src-ms-use-COPYING` |
| libunibreak (`Libunibreak`) | 6.1 `304585d8` | Zlib | `LICENSE.libunibreak` |
| MoltenVK (`MoltenVK`) | 1.4.2 `db660224` | Apache-2.0 | `LICENSE.moltenvk` |
| SPIRV-Cross, cereal and Vulkan-Headers inside `MoltenVK` | `6c09849f`, `a56bad8b`, `e3b1eec0` | Apache-2.0 OR MIT, with Khronos free-use headers; BSD-3-Clause; Apache-2.0 OR MIT | `LICENSE.spirv-cross*`, `LICENSE.cereal`, `LICENSE.vulkan-headers*` |
| SPIRV-Tools and SPIRV-Headers inside `MoltenVK` and `Libshaderc_combined` | pinned by each | Apache-2.0; MIT | `LICENSE.spirv-tools`, `LICENSE.spirv-headers*` |
| shaderc (`Libshaderc_combined`) | 2025.5 `c4b0af6c` | Apache-2.0 | `LICENSE.shaderc`, `LICENSE.shaderc.third_party-LICENSE.*` |
| glslang inside `Libshaderc_combined` | `7a47e253` | BSD-3-Clause, BSD-2-Clause, MIT, Apache-2.0, and GPL-3.0 with the Bison exception | `LICENSE.glslang` |
| Little CMS (`lcms2`) | 2.17 `51763476` | MIT | `LICENSE.lcms2` |
| libplacebo (`Libplacebo`) | 7.360.1 `cee9b076` | LGPL-2.1-or-later | `LICENSE.libplacebo` |
| fast_float and glad inside `Libplacebo` | `97b54ca9`, `73db193f` | Apache-2.0 OR BSL-1.0 OR MIT; MIT, with Khronos parts | `LICENSE.fast_float.*`, `LICENSE.glad` |
| libdovi (`Libdovi`) | 3.3.2 `4fd2b223` | MIT | `LICENSE.libdovi` |
| dav1d (`Libdav1d`) | 1.5.3 `b546257f` | BSD-2-Clause, plus the AOM Patent License 1.0 | `LICENSE.dav1d`, `LICENSE.dav1d.doc-PATENTS` |
| uavs3d (`Libuavs3d`) | 1.2.1; the recipe builds master, file taken from `0e20d2c2` | BSD-3-Clause | `LICENSE.uavs3d` |
| libbluray (`Libbluray`) | 1.4.0 `9f07fbb2` | LGPL-2.1-or-later | `LICENSE.libbluray` |
| libudfread inside `Libbluray` (`-Dembed_udfread=true`) | 1.2.0 `c3cd5cbb`, the submodule commit in libbluray 1.4.0 | LGPL-2.1-or-later | `LICENSE.libbluray.contrib-libudfread-COPYING` |
| uchardet (`Libuchardet`) | v0.0.8 `ae6302a0` | MPL-1.1 OR GPL-2.0-or-later OR LGPL-2.1-or-later; `COPYING` holds all three texts | `LICENSE.uchardet` |

The source headers agree with these files. In libbluray 1.4.0, 145 of the
157 C sources and headers carry the LGPL-2.1-or-later notice; the JNI headers
(`jni/jni.h` and six `jni/*/jni_md.h`) are MPL-1.1 OR GPL-2.0-or-later OR
LGPL-2.1-or-later, four JNI headers in `src/libbluray/bdj/native/` carry no
notice, and the one
GPL-2.0-or-later file, `src/devtools/bdj_test.c`, is a developer tool the
build turns off (`-Denable_devtools=false`). All 11 libudfread sources carry
the LGPL-2.1-or-later notice, and 75 of the 76 uchardet sources the
MPL/GPL/LGPL block; no CMakeLists.txt refers to the remaining one,
`build-mac/uchardet.cpp`. libbluray's `contrib/asm` (BSD-3-Clause) is Java
code for the BD-J jar, which the build disables (`-Dbdj_jar=disabled`), so it
is not collected.

### Rust code in `Libdovi`

`Libdovi` comes from `cargo cinstall -Zbuild-std=std,panic_abort` in
dovi_tool's `dolby_vision` directory (libdovi-build 3.3.2), so it carries its
own build of the Rust standard library and of every crate below. The workflow
installs the current nightly; the release job finished at 10:06 UTC on
2025-12-22, and nightly-2025-12-22 (`rustc 1.94.0-nightly (a6525d526
2025-12-21)`) was published at 01:32 UTC that day. The binary embeds rust-src
paths but no rustc commit; nightly-2025-12-21 pins the same crate versions and
has byte-identical licence files, so either gives the same notices. The Rust
files come from that nightly's rust-src component (SHA-256 as listed in its
channel manifest) and from the crates.io archives, each of which matched the
checksum in its lock file. Crate versions come from the nightly's
`library/Cargo.lock` and from `dolby_vision/Cargo.lock` at `4fd2b223`;
`cargo tree` for `aarch64-apple-ios` gives the same set, and the archive
members and embedded source paths of the `ios-arm64` slice confirm it.

| Component | Version | Licence as stated upstream | Files |
|---|---|---|---|
| Rust standard library: std, core, alloc, panic_abort, unwind, std_detect and the rustc-std-workspace shims | rust-src nightly-2025-12-22 | MIT OR Apache-2.0 | `LICENSE.rust.COPYRIGHT`, `LICENSE.rust.LICENSE-APACHE`, `LICENSE.rust.LICENSE-MIT` |
| backtrace-rs inside `std`; core_arch (stdarch) and core_simd (portable-simd) inside `core` | same | MIT OR Apache-2.0 | `LICENSE.rust.library-backtrace-*`, `LICENSE.rust.library-stdarch-crates-core_arch-*`, `LICENSE.rust.library-portable-simd-crates-core_simd-*` |
| compiler_builtins, including its libm code (the slice defines `fmaf128`, `roundeven` and others) | same | MIT AND Apache-2.0 WITH LLVM-exception; libm MIT | `LICENSE.rust.library-compiler-builtins-LICENSE.txt`, `LICENSE.rust.library-compiler-builtins-libm-LICENSE.txt` |
| addr2line | 0.25.1 | Apache-2.0 OR MIT | `LICENSE.addr2line.*` |
| adler2 | 2.0.1 | 0BSD OR MIT OR Apache-2.0 | `LICENSE.adler2.*` |
| cfg-if | 1.0.4 | MIT OR Apache-2.0 | `LICENSE.cfg-if.*` |
| gimli | 0.32.3 | MIT OR Apache-2.0 | `LICENSE.gimli.*` |
| hashbrown | 0.16.1 | MIT OR Apache-2.0 | `LICENSE.hashbrown.*` |
| libc | 0.2.178 for std, 0.2.172 for libdovi; the licence files are identical | MIT OR Apache-2.0 | `LICENSE.libc.*` |
| memchr | 2.7.6 | Unlicense OR MIT | `LICENSE.memchr.*` |
| miniz_oxide | 0.8.9 | MIT OR Zlib OR Apache-2.0 | `LICENSE.miniz_oxide.*` |
| object | 0.37.3 | Apache-2.0 OR MIT | `LICENSE.object.*` |
| rustc-demangle | 0.1.26 | MIT/Apache-2.0 | `LICENSE.rustc-demangle.*` |
| anyhow | 1.0.98 | MIT OR Apache-2.0 | `LICENSE.anyhow.*` |
| bitstream-io | 2.6.0 | MIT/Apache-2.0 | `LICENSE.bitstream-io.*` |
| bitvec | 1.0.1 | MIT | `LICENSE.bitvec` |
| bitvec_helpers | 3.1.6 | MIT | `LICENSE.bitvec_helpers` |
| crc | 3.3.0 | MIT OR Apache-2.0 | `LICENSE.crc.*` |
| crc-catalog | 2.4.0 | MIT OR Apache-2.0 | `LICENSE.crc-catalog.*` |
| funty | 2.0.0 | MIT | `LICENSE.funty` |
| radium | 0.7.0 | MIT | `LICENSE.radium` |
| tap | 1.0.1 | MIT | `LICENSE.tap` |
| tinyvec | 1.9.0 | Zlib OR Apache-2.0 OR MIT | `LICENSE.tinyvec.*` (CRLF line endings, as published) |
| wyz | 0.5.1 | MIT | `LICENSE.wyz` |

The first ten crates come in through the standard library (libc also through
libdovi), the rest through libdovi with its `capi` feature. Not linked, so not
collected: the LLVM libunwind sources in rust-src (Apple targets use the system
unwinder, and the slice defines no unwinder symbols) and panic_unwind
(`-Cpanic=abort`).

Provenance notes:

- nettle and GMP were first copied from GitHub mirrors. The runner job then
  matched every recorded file against upstream: nettle's own repository at
  tag `nettle_3.10_release_20240616` (`b8c841dc`), and the GMP 6.2.1 release
  tarball from ftp.gnu.org (SHA-256
  `fd4829912cddd12f84181c3451cc752be224643e87fac497b69edddadc49b4f2`).
- The recipe builds uavs3d from master, and the exact commit behind the
  binary is not reachable upstream. `COPYING` has not changed upstream since
  `74109648` (2022-03-01), so every upstream commit since then, including
  `0e20d2c2`, carries the recorded file.

The in-app attribution screen that IOS-POC-9A L4 asks for is a separate task.
