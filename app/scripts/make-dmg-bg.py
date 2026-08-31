#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""Renders the DMG background at @2x: brand-black, wordmark, arrow, bilingual hint.

Output: dist/dmg-bg@2x.png; make-dmg.sh folds it into a HiDPI TIFF via tiffutil.
Icon slots the background is drawn around (window points, icon centers):
  single row y=205 — sezish.app (150) -> Программы (410) with the arrow between.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H = 1120, 800  # 560x400 pt window @2x
BLACK = (10, 10, 10)
WHITE = (240, 240, 240)
GREY = (140, 140, 140)
DIM = (100, 100, 100)
RED = (226, 36, 36)  # sezish brand red


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    candidates = [
        ("/System/Library/Fonts/HelveticaNeue.ttc", 1 if bold else 0),
        ("/System/Library/Fonts/Helvetica.ttc", 1 if bold else 0),
    ]
    for path, index in candidates:
        try:
            return ImageFont.truetype(path, size, index=index)
        except OSError:
            continue
    return ImageFont.load_default(size)


img = Image.new("RGB", (W, H), BLACK)
d = ImageDraw.Draw(img)

# Wordmark: sezi.sh — the red dot IS the dot in the domain name.
brand = font(72, bold=True)
x, y = 64, 40
d.text((x, y), "sezi", font=brand, fill=WHITE)
x += d.textlength("sezi", font=brand)
r = 14
cx, cy = x + r + 10, y + 72 - r  # sits on the baseline like a period
d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=RED)
x = cx + r + 10
d.text((x, y), "sh", font=brand, fill=WHITE)

# Hint above the icons (window bottom gets clipped when Finder shows a toolbar).
hint = font(30)
lines = [
    "Drag sezish into Applications",
    "sezish’ni Applications’ga torting",
]
for i, line in enumerate(lines):
    lw = d.textlength(line, font=hint)
    d.text(((W - lw) / 2, 186 + i * 46), line, font=hint, fill=GREY if not i else DIM)

# Arrow between icon centers (app 300, Applications 820 in @2x; icons 110pt wide).
ay, x0, x1 = 410, 440, 690
d.line((x0, ay, x1 - 36, ay), fill=RED, width=10)
d.polygon((x1, ay, x1 - 52, ay - 30, x1 - 52, ay + 30), fill=RED)

dist = Path(__file__).resolve().parent.parent / "dist"
img.save(dist / "dmg-bg@2x.png", dpi=(144, 144))
print(dist / "dmg-bg@2x.png")
