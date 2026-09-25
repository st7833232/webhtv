# MPV iOS build inputs

The iOS app plays through the LGPL `MPVKit` product of
[MPVKit](https://github.com/mpvkit/MPVKit) 1.0.0. Every binary it links is the
upstream 1.0.0 release asset except `Libmpv.xcframework`, which WebHTV
rebuilds from the same recipe with one changed file, mpv's
`video/out/vulkan/context_moltenvk.m` (IOS-POC-17I). The upstream context reads
the layer size only when the video output is configured, so after a rotation
mpv kept drawing the old rectangle until the app rebuilt the whole output. The
WebHTV context reports layer resizes to mpv as they happen.

`../mpv-ios-lock.json` pins every input and the published artifact.
`.github/workflows/ios-libmpv-build.yml` is the only build path and the only
reader of the lock. `MANIFEST.sha256` lists the files in this directory.

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
- `patches/buildscripts/0001-restore-prebuilt-ffmpeg.patch` changes the
  recipe to restore FFmpeg from the 1.0.0 `FFmpeg-all.zip` instead of
  compiling it, so libmpv is the only thing built.
- `licenses/` holds the notices of everything the LGPL `MPVKit` product links
  on iOS.

## Build and checks

The workflow runs on `macos-26` with the pinned Xcode and meson. It checks out
the recipe at `recipe.build_commit` in the directory the 1.0.0 release was
built in, verifies the upstream patches, swaps in the WebHTV 0001, places every
dependency zip from the lock (the recipe then never downloads), and runs
`make build platform=ios`: `-Dgpl=false`, device arm64 plus the arm64 and
x86_64 simulator. Before publishing it requires the device slice to match the
upstream `Libmpv` in:

- the embedded `Configuration:` and `List of enabled features:` strings;
- the static library's members and its defined external symbols;
- every framework file other than the binary.

Undefined symbols may differ only through the `context_moltenvk` member, with
one named exception accepted on 2026-09-25: `_wcslen`, as long as
`filters/f_hwtransfer.c` is its only user. Xcode 26's clang compiles the loop
there that counts the zero-terminated `supported_formats` list into a `wcslen`
call, which is the same loop on Apple platforms (`wchar_t` is a 32-bit `int`);
the upstream build, made with Xcode 15.4, keeps the loop. The result is
published as a prerelease under `artifact.release_tag`, with the
build manifest, the comparison report and the build log. The workflow refuses
to replace a published tag, so a new build needs a new tag in the lock.

## Corresponding source

The modified library is mpv `v0.41.0`
(`41f6a645068483470267271e1d09966ca3b9f413`) with, in order, the WebHTV
`0001` above and MPVKit's `0002-revert-build-static.patch` and
`0003-enable-avfoundation-ao-tvos.patch` from recipe commit
`9d057f9c19fa704e242b199d26bc6c5cf23dd5d6`. The workflow and the lock rebuild
it from those inputs. FFmpeg and the other libraries are unmodified upstream
binaries; their versions are in the lock and in `licenses/`.

## Licences

`licenses/` holds the upstream licence files of everything the LGPL `MPVKit`
product links on iOS, copied byte for byte from the source revision behind
each 1.0.0 binary. Versions were read from the recipe and from each
`mpvkit/*-build` repository at the tag the lock pins (2026-09-25); four files
were rechecked against independent clones.

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

Not collected yet:

- libbluray 1.4.0 (`Libbluray`), the libudfread 1.2.0 embedded in it, and
  uchardet 0.0.8 (`Libuchardet`). Their hosts, code.videolan.org and
  gitlab.freedesktop.org, were blocked from the environment that collected
  these files. Package metadata lists LGPL-2.1-or-later for libbluray and
  MPL-1.1 OR GPL-2.0-or-later OR LGPL-2.1-or-later for uchardet; neither is
  checked against the source yet.
- The Rust standard library and crates statically linked into `Libdovi`.
- Provenance caveats: nettle and GMP were copied from GitHub mirrors (the GMP
  one is the mirror the recipe itself uses), and the exact uavs3d commit
  behind the binary is not reachable upstream.

The in-app attribution screen that IOS-POC-9A L4 asks for is a separate task.
