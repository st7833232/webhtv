# OpenCC dictionaries (IOS-POC-32 C)

`TaiwanTraditional.swift` reads these files to show a source's Simplified Chinese as Taiwan
Traditional on screen. Search, identity values, history and the WebHome bridge never use them.

- Source: [OpenCC](https://github.com/BYVoid/OpenCC) at
  `528ae2624972301649fbd00bbd837ce4e085650b` (2026-09-25), Apache License 2.0 (`LICENSE`, copied
  from the same commit without its trailing blank line, which this repository's whitespace check
  rejects; the text is unchanged).
- Copied unmodified from `data/dictionary/`: `CJK_Compatibility_Ideographs.txt`,
  `STCharacters.txt`, `STPhrases.txt`, `TWVariants.txt`, `TWVariantsPhrases.txt`.
- `STPhrases_GeneratedFromRegionalPhrases.txt` is not in OpenCC's repository; its build generates
  it. It was generated at the same commit by OpenCC's own CMake build
  (`cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build`), which runs
  `data/scripts/generate_st_phrases_from_regional_phrases.py` over `HKPhrases.txt` and
  `TWPhrases.txt` with `t2s.json`, and copied unmodified from `build/data/`. Its header names only
  `s2hkp.json` and `s2twp.json`, but `data/config/s2tw.json` loads it too.
- These six files are exactly the dictionaries `data/config/s2tw.json` uses.

SHA-256:

| File | SHA-256 |
|---|---|
| `CJK_Compatibility_Ideographs.txt` | `e9623acec48d384f99d37d2760bd14a00b6d0cddad7707290dbb0b8c97a2904a` |
| `STCharacters.txt` | `a0ca1601c70648cf48b33c3c6210ccbecc5c7eead4b4c3daf76587ba2c03582b` |
| `STPhrases.txt` | `f6eab5e5c6dd7640597878d3dfc6599ee1279d2bc91561eadd8e114194e2925a` |
| `STPhrases_GeneratedFromRegionalPhrases.txt` | `9ab40618a9b162cca6dae9ec6767a8c4669017a20b2d6da5f94b7a7f99d09170` |
| `TWVariants.txt` | `245b94eb5842957e735dd44b7e7d4ff469a3643126cc8fa511adda5281e9cb86` |
| `TWVariantsPhrases.txt` | `36df033675a2e9152927fa8419f0732a061cb4909c5060f25a5cfc9b08ffff06` |
| `LICENSE` | `fb531487f666909d487239da6130e2256d8c86f26ec2674ce6aa5763bc7f8c56` |

The data is not changed. What WebHTV does differently from OpenCC's `s2tw` is in the Swift code:
only text that holds a Simplified-only character is converted, Japanese text is left alone, 臺 is
written 台, and a director or cast field keeps the surnames 于 朴 范 姜 余 沈 (钟 → 鍾).

To update: regenerate the generated file at the new commit the same way, replace all six files and
`LICENSE` together, update the commit and hashes here, and regenerate the expected values in
`TaiwanTraditionalTests` with OpenCC's own `opencc -c data/config/s2tw.json` tool.
