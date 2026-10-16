#!/usr/bin/env python3
"""sheet.py <dir> [<dir> ...]: build <dir>/sheet.png (64/32/16 px enlarged 8x with
nearest neighbour on light and dark, plus 1x copies) and <dir>/renditions.png.
With several dirs, also writes a side-by-side compare.png in the first dir's parent."""
import os
import sys
from PIL import Image, ImageDraw

LIGHT, DARK = (242, 242, 247, 255), (28, 28, 30, 255)


def tile(d, bg):
    w, h = 3 * 256 + 4 * 24 + 200, 256 + 48
    im = Image.new("RGBA", (w, h), bg)
    x = 24
    for s in (64, 32, 16):
        src = Image.open(os.path.join(d, f"icon-{s}.png")).convert("RGBA")
        big = src.resize((256, 256), Image.NEAREST)
        im.alpha_composite(big, (x, 24))
        x += 256 + 24
    y = 40
    for s in (64, 32, 16):
        src = Image.open(os.path.join(d, f"icon-{s}.png")).convert("RGBA")
        im.alpha_composite(src, (x + 40, y))
        y += s + 24
    return im


def sheet(d):
    a, b = tile(d, LIGHT), tile(d, DARK)
    im = Image.new("RGBA", (a.width, a.height * 2))
    im.paste(a, (0, 0)); im.paste(b, (0, a.height))
    im.save(os.path.join(d, "sheet.png"))
    rs = [Image.open(os.path.join(d, "work", f"rend-{r}.png")).convert("RGBA").resize((512, 512), Image.LANCZOS)
          for r in ("Default", "Dark", "ClearLight", "TintedDark")]
    strip = Image.new("RGBA", (4 * 512 + 5 * 16, 512 + 32), (128, 128, 132, 255))
    for i, r in enumerate(rs):
        strip.alpha_composite(r, (16 + i * 528, 16))
    strip.save(os.path.join(d, "renditions.png"))
    return im


if __name__ == "__main__":
    ims = [sheet(d) for d in sys.argv[1:]]
    if len(ims) > 1:
        out = Image.new("RGBA", (ims[0].width, sum(i.height for i in ims) + 16 * len(ims)), (255, 0, 255, 255))
        y = 0
        for i in ims:
            out.paste(i, (0, y)); y += i.height + 16
        out.save(os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), "work", "compare.png"))
