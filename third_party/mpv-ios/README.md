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
