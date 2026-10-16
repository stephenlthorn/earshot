# Brand sources

Everything here is editable source for the Earshot graphics. The rendered files live in `docs/images/` and the app icon in `App/AppIcon.icon`.

- `icon/work/gen.py` writes the Icon Composer icon (`icon/AppIcon.icon`) and the flat marks (`icon/mark-*.svg`). Run it with no arguments to rebuild the shipped icon, or pass `key=value` pairs to try variations.
- `icon/work/render.sh` exports the icon with Xcode's `ictool` and makes the sized PNGs (`icon/icon-*.png`). It needs Xcode 26 and Python with Pillow.
- `icon/work/marks.sh` renders the flat marks with headless Google Chrome and builds the menu bar preview.
- `art/src/build.sh` renders the README banner (light and dark) and the social preview from the HTML templates, using the 512 px icon.
- The diagrams are hand-written SVG in `docs/images/*.svg`. Render a PNG with headless Chrome at 2x, for example:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu \
  --hide-scrollbars --force-device-scale-factor=2 --window-size=1600,1000 \
  --screenshot=docs/images/architecture-light.png docs/images/architecture-light.svg
```

After changing the icon, copy `icon/AppIcon.icon` over `App/AppIcon.icon` and the PNGs you need into `docs/images/`.
