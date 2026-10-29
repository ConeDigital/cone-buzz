"""The in-app rebrand's raster assets, from the two SVGs (Slice 36 decision 3).

Run from the repository root:
  bin/uv run --with resvg-py==0.5.0 --with Pillow==12.2.0 python cone/rebrand/make-rebrand-assets.py

Inputs (tracked):
  cone/rebrand/files/desktop/public/buzz.svg      the Cone mark (square; replaces upstream's favicon + in-app mark)
  cone/rebrand/wordmark.svg                       the Cone wordmark as delivered (777x326, white rect, lettering top-left)
  cone/icons/icon-1024.png                        the app icon tile (Slice 29)

Outputs (tracked, under cone/rebrand/files/, each replacing the upstream file of the same path):
  desktop/public/landing/buzz-wordmark.png        the wordmark cropped to its glyphs, 2x (the first onboarding screen)
  desktop/public/app-icon@2x.png, @3x.png          the app icon at 112 and 168 px (pairing and consent dialogs)
  desktop/src-tauri/assets/card_template.png      a plain persona-card frame, 718x1024: dark interior, gradient border,
                                                  name banner top, round badge top-right, text box lower third, the mark
                                                  bottom-left — the layout the card prompt's lines.tsv rows describe
and (not a replacement; read by the tray block through include_bytes!):
  cone/rebrand/src-tauri/tray-mask.rgba           43x43 RGBA alpha mask of the mark for the macOS template tray icon
"""

from __future__ import annotations

import io
import re
from pathlib import Path

import resvg_py
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT / "cone" / "rebrand"
FILES = HERE / "files"
MARK_SVG = FILES / "desktop" / "public" / "buzz.svg"
WORDMARK_SVG = HERE / "wordmark.svg"
ICON_1024 = ROOT / "cone" / "icons" / "icon-1024.png"

PURPLE = (0x78, 0x20, 0x6A)
ORANGE = (0xF1, 0x6B, 0x09)
INTERIOR = (0x24, 0x27, 0x2E)
BANNER = (0x16, 0x18, 0x1D)


def render(svg: str, width: int) -> Image.Image:
    png = resvg_py.svg_to_bytes(svg_string=svg, width=width)
    return Image.open(io.BytesIO(bytes(png))).convert("RGBA")


def wordmark_png() -> None:
    svg = WORDMARK_SVG.read_text()
    # Strip the delivered white background: the landing screen is a gradient.
    svg = re.sub(r'<rect width="777" height="326" fill="white"\s*/>', "", svg)
    probe = render(svg, 7770)  # 10x, for a tight crop
    bbox = probe.getchannel("A").getbbox()
    assert bbox, "wordmark renders empty"
    x0, y0, x1, y1 = (v / 10 for v in bbox)
    pad = 4
    vb = f"{x0 - pad:.1f} {y0 - pad:.1f} {x1 - x0 + 2 * pad:.1f} {y1 - y0 + 2 * pad:.1f}"
    svg = re.sub(r'width="777" height="326" viewBox="0 0 777 326"', f'viewBox="{vb}"', svg)
    assert f'viewBox="{vb}"' in svg, "viewBox not rewritten"
    out = render(svg, 1554)  # upstream's 777 px box, at 2x
    target = FILES / "desktop" / "public" / "landing" / "buzz-wordmark.png"
    target.parent.mkdir(parents=True, exist_ok=True)
    out.save(target, optimize=True)
    print(f"wordmark: {target.relative_to(ROOT)} {out.size}, viewBox {vb}")


def app_icons() -> None:
    tile = Image.open(ICON_1024).convert("RGBA")
    for name, px in (("app-icon@2x.png", 112), ("app-icon@3x.png", 168)):
        target = FILES / "desktop" / "public" / name
        tile.resize((px, px), Image.LANCZOS).save(target, optimize=True)
        print(f"app icon: {target.relative_to(ROOT)} {px}px")


def tray_mask() -> None:
    size = 43  # upstream's tray image height; the mark is square
    big = render(MARK_SVG.read_text(), size * 8)
    # Crop to the mark itself: its box has margins (the mark fills 66% x 77%
    # of it), which made the menu-bar icon small beside its neighbours.
    alpha = big.getchannel("A")
    alpha = alpha.crop(alpha.getbbox())
    w, h = alpha.size
    scale = size / max(w, h)
    glyph = alpha.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS)
    alpha = Image.new("L", (size, size), 0)
    alpha.paste(glyph, ((size - glyph.width) // 2, (size - glyph.height) // 2))
    rgba = bytearray()
    for a in alpha.getdata():
        rgba += bytes((0, 0, 0, a))
    target = HERE / "src-tauri" / "tray-mask.rgba"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(bytes(rgba))
    print(f"tray mask: {target.relative_to(ROOT)} {size}x{size} RGBA, {len(rgba)} bytes")


def card_frame() -> None:
    w, h = 718, 1024
    img = Image.new("RGBA", (w, h), INTERIOR + (255,))
    d = ImageDraw.Draw(img)
    # Gradient border, 18 px, purple (bottom-left) to orange (top-right).
    border = 18
    for y in range(h):
        for x in range(w):
            if x < border or x >= w - border or y < border or y >= h - border:
                t = (x / w + (1 - y / h)) / 2
                c = tuple(int(PURPLE[i] + (ORANGE[i] - PURPLE[i]) * t) for i in range(3))
                img.putpixel((x, y), c + (255,))
    # Name banner top, round badge top-right, text box lower third (the layout
    # upstream's prompt typesets into).
    d.rounded_rectangle((60, 36, 560, 120), radius=24, fill=BANNER + (255,), outline=ORANGE + (255,), width=4)
    d.ellipse((596, 30, 690, 124), fill=BANNER + (255,), outline=ORANGE + (255,), width=4)
    d.rounded_rectangle((44, 650, 674, 880), radius=28, fill=BANNER + (255,), outline=ORANGE + (255,), width=4)
    # The mark, bottom-left, over the border.
    mark = render(MARK_SVG.read_text(), 96)
    img.alpha_composite(mark, (30, h - 30 - 96))
    target = FILES / "desktop" / "src-tauri" / "assets" / "card_template.png"
    target.parent.mkdir(parents=True, exist_ok=True)
    img.convert("RGB").save(target, optimize=True)
    print(f"card frame: {target.relative_to(ROOT)} {img.size}")


if __name__ == "__main__":
    wordmark_png()
    app_icons()
    tray_mask()
    card_frame()
