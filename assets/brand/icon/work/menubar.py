#!/usr/bin/env python3
"""menubar.py <dir>: menubar-preview.png (44x44 black template glyph, 36 px tall at 2x)
plus work/menubar-zoom.png, a look at it in light and dark menu bars at 1x, 2x and 8x."""
import os
import sys
from PIL import Image, ImageOps

d = sys.argv[1]
src = Image.open(os.path.join(d, "work", "mark-template.png")).convert("RGBA")
# mark-template.png comes from an svg whose glyph is centred in a square viewBox
glyph = src.crop(src.getbbox())
h = 36
w = round(glyph.width * h / glyph.height)
small = glyph.resize((w, h), Image.LANCZOS)
tpl = Image.new("RGBA", (44, 44), (0, 0, 0, 0))
tpl.alpha_composite(small, ((44 - w) // 2, (44 - h) // 2))
tpl.save(os.path.join(d, "menubar-preview.png"))

def tinted(img, rgb):
    out = Image.new("RGBA", img.size, rgb + (0,))
    out.putalpha(img.getchannel("A"))
    return out

zoom = Image.new("RGBA", (44 * 8 * 2 + 60, 44 * 8 + 160), (128, 128, 132, 255))
for i, (bg, fg) in enumerate((((236, 236, 240), (0, 0, 0)), ((40, 40, 46), (255, 255, 255)))):
    bar = Image.new("RGBA", (44 * 8, 44 * 8 + 140), bg + (255,))
    g = tinted(tpl, fg)
    bar.alpha_composite(g.resize((352, 352), Image.NEAREST), (0, 140))
    bar.alpha_composite(g, (40, 40))
    bar.alpha_composite(g.resize((22, 22), Image.LANCZOS), (140, 51))
    zoom.alpha_composite(bar, (20 + i * (352 + 20), 10))
zoom.save(os.path.join(d, "work", "menubar-zoom.png"))
