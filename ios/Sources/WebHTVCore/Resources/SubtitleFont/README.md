# WebHTV Subtitle CJK

IOS-POC-45D. The CJK font MPV (libass) draws subtitles with. libass reads fonts through FreeType,
and FreeType 2.14.3 cannot read iOS 18+'s PingFang (`PingFangUI.ttc` keeps its outlines only in
Apple's `hvgl` table), so Chinese subtitles were boxes. This is a subset of Noto Sans CJK TC with
CFF outlines, which FreeType reads.

`fonts/` must hold this one file and nothing else: mpv passes the folder as `sub-fonts-dir`, and
libass reads every file in it into memory.

## Source

- `https://raw.githubusercontent.com/notofonts/noto-cjk/f8d157532fbfaeda587e826d4cd5b21a49186f7c/Sans/OTF/TraditionalChinese/NotoSansCJKtc-Regular.otf`
  - 16,435,884 bytes, SHA-256 `dce08bd4fd91aa8aa76ed8fea4b694c2dfb8550f67871e326843212ddbeb88b4`
  - Noto Sans CJK TC 2.004
- `LICENSE`: `Sans/LICENSE` at the same commit (SIL Open Font License 1.1), SHA-256
  `6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2`.

## Subset and rename (fontTools 4.66.1)

Coverage: every BMP character of Big5-HKSCS and GB2312, all 8,105 characters of the 通用规范汉字表
(2013; 196 of them beyond the BMP), KS X 1001 Hangul, kana, Latin, Greek, Cyrillic, punctuation and
symbols. 23,668 code points requested, 22,330 present in the source, all 22,330 kept (22,354
glyphs). Left out: GBK Han outside these lists, most of CJK Extension A, Hangul outside KS X 1001
and emoji; libass falls back to CoreText for those.

The standard table comes from `shengdoushi/common-standard-chinese-characters-table`
`d9b599a9c9cc0dd2d58cad829e285bc780cd4451` (`level-1.txt`, `level-2.txt`, `level-3.txt`, cloned
as `tgscc/`).

```sh
python3 - > unicodes.txt <<'PY'
cps = set()
def dbcs(enc, leads, trails):
    for a in leads:
        for b in trails:
            try:
                s = bytes((a, b)).decode(enc)
            except UnicodeDecodeError:
                continue
            if len(s) == 1 and ord(s) < 0x10000:
                cps.add(ord(s))
dbcs("big5hkscs", range(0x81, 0xFF), list(range(0x40, 0x7F)) + list(range(0xA1, 0xFF)))
dbcs("gb2312", range(0xA1, 0xF8), range(0xA1, 0xFF))
dbcs("euc_kr", range(0xB0, 0xC9), range(0xA1, 0xFF))
for a, b in [(0x20, 0x7E), (0xA0, 0x24F), (0x370, 0x4FF), (0x1E00, 0x1EFF), (0x2000, 0x206F), (0x20A0, 0x20CF),
             (0x2100, 0x21FF), (0x2460, 0x257F), (0x25A0, 0x26FF), (0x3000, 0x30FF), (0x31F0, 0x31FF),
             (0xFE30, 0xFE4F), (0xFF00, 0xFFEF)]:
    cps.update(range(a, b + 1))
import pathlib
for level in ("level-1.txt", "level-2.txt", "level-3.txt"):
    cps.update(ord(c) for c in pathlib.Path("tgscc", level).read_text(encoding="utf-8") if not c.isspace())
print("\n".join(f"U+{c:04X}" for c in sorted(cps)))
PY
pyftsubset NotoSansCJKtc-Regular.otf --unicodes-file=unicodes.txt --no-hinting \
  --layout-features-='locl,vert,vrt2' --name-IDs='*' --notdef-outline --output-file=sub.otf
```

Renamed (Noto is a trademark; the OFL allows a modified version under another name; name IDs 0,
13 and 14 keep the copyright and license):

```python
from fontTools.ttLib import TTFont
FAM, FULL, PS = "WebHTV Subtitle CJK", "WebHTV Subtitle CJK Regular", "WebHTVSubtitleCJK-Regular"
f = TTFont("sub.otf")
for r in f["name"].names:
    v = {1: FAM, 3: "2.004;WEBHTV;" + PS, 4: FULL, 6: PS, 16: FAM, 17: "Regular"}.get(r.nameID)
    if v:
        r.string = v
c = f["CFF "].cff
c.fontNames[0] = PS
t = c.topDictIndex[0]
for k, v in (("FamilyName", FAM), ("FullName", FULL)):
    if hasattr(t, k):
        setattr(t, k, v)
f.save("WebHTVSubtitleCJK-Regular.otf")
```

Result: `fonts/WebHTVSubtitleCJK-Regular.otf`, 4,966,308 bytes (4,200,451 gzipped), SHA-256
`f8259c8d8ee658a8f9161e9a0a5f9d3069d682ec9f3cd248a9ad632842495cec`. Checked: `CFF ` present, no
`hvgl` or `glyf`; name ID 1 is `WebHTV Subtitle CJK`; 啰镕祎还请伤啲嘅咗喺♪這們한の all mapped and drawn
with ink by FreeType 2.13.2 (freetype-py).
