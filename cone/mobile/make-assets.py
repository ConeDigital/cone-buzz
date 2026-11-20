"""The Cone phone app's pictures (cone-buzz-infra Slice 43), from Cone's sources.

Run from the repository root (uv from hermit, or any uv; the pins are the Desktop overlays'):
  bin/uv run --with resvg-py==0.5.0 --with Pillow==12.2.0 python cone/mobile/make-assets.py

Inputs (tracked, copies of the Desktop overlays' — ConeDigital/cone-buzz `cone/icons/source.png`,
ConeDigital/cone-buzz-app `cone/rebrand/wordmark.svg`):
  cone/mobile/icons/source.png       Cone's mark, 1000 px, transparent background
  cone/mobile/rebrand/wordmark.svg   the Cone wordmark as delivered (777x326, white rect, ink #241F1F)

Outputs (tracked, under cone/mobile/rebrand/files/, each replacing the upstream file of the same path;
replacements.tsv pins each upstream file's hash):
  mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-*.png
      every size upstream's Contents.json lists: the mark on white, full bleed, RGB without alpha
      (iOS rejects an app icon with an alpha channel and draws its own corners)
  mobile/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage{,@2x,@3x}.png
      the mark in its colours on transparent, at upstream's 168/336/504 px (the launch screen is black)
  mobile/assets/images/buzz-icon.png
      the mark's shape in upstream's 294x197 box (Home's empty pane tints its alpha)
  mobile/assets/images/buzz-wordmark.png
      the wordmark's glyphs fitted to upstream's 777x326 box, ink on transparent (the welcome
      screen draws it as is, or recolours its alpha in shaders/onboarding_wordmark.frag)

Not generated: mobile/assets/images/welcome-bee.svg is the Desktop 1.0 overlay's one-colour mark
(cone-buzz-app `cone/rebrand/files/public/welcome-bee.svg`), copied as is.
"""

from __future__ import annotations

import io
import json
import re
from pathlib import Path

import resvg_py
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT / "cone" / "mobile"
FILES = HERE / "rebrand" / "files"
SOURCE = HERE / "icons" / "source.png"
WORDMARK_SVG = HERE / "rebrand" / "wordmark.svg"
APPICON = Path("mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset")
LAUNCH = Path("mobile/ios/Runner/Assets.xcassets/LaunchImage.imageset")
IMAGES = Path("mobile/assets/images")

WORDMARK_BOX = (777, 326)  # upstream's buzz-wordmark.png
WORDMARK_MARGIN = (28, 22)  # upstream's glyphs leave about this much on each side
INK = "#231E1E"  # upstream's wordmark ink (OnboardingWordmark's default colour)


def source() -> Image.Image:
    with Image.open(SOURCE) as im:
        return im.convert("RGBA")


def save(img: Image.Image, rel: Path) -> None:
    target = FILES / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    img.save(target, optimize=True)
    print(f"{rel}: {img.size[0]}x{img.size[1]} {img.mode}")


def app_icons() -> None:
    art = source()
    tile = Image.new("RGBA", art.size, (255, 255, 255, 255))
    tile.alpha_composite(art)
    tile = tile.convert("RGB")  # opaque: no alpha channel at all
    contents = json.loads((ROOT / APPICON / "Contents.json").read_text())
    for entry in contents["images"]:
        px = round(float(entry["size"].split("x")[0]) * float(entry["scale"].rstrip("x")))
        save(tile.resize((px, px), Image.Resampling.LANCZOS), APPICON / entry["filename"])


def launch_images() -> None:
    art = source()
    for name, px in (("LaunchImage.png", 168), ("LaunchImage@2x.png", 336), ("LaunchImage@3x.png", 504)):
        save(art.resize((px, px), Image.Resampling.LANCZOS), LAUNCH / name)


def home_icon() -> None:
    art = source()
    art = art.crop(art.getchannel("A").getbbox())
    box = (294, 197)
    scale = min(box[0] / art.width, box[1] / art.height)
    glyph = art.resize((round(art.width * scale), round(art.height * scale)), Image.Resampling.LANCZOS)
    out = Image.new("RGBA", box, (0, 0, 0, 0))
    out.alpha_composite(glyph, ((box[0] - glyph.width) // 2, (box[1] - glyph.height) // 2))
    save(out, IMAGES / "buzz-icon.png")


def render(svg: str, width: int) -> Image.Image:
    png = resvg_py.svg_to_bytes(svg_string=svg, width=width)
    return Image.open(io.BytesIO(bytes(png))).convert("RGBA")


def wordmark() -> None:
    svg = WORDMARK_SVG.read_text()
    svg = re.sub(r'<rect width="777" height="326" fill="white"\s*/>', "", svg)
    svg = svg.replace('fill="#241F1F"', f'fill="{INK}"')
    probe = render(svg, 7770)  # 10x, for a tight crop
    bbox = probe.getchannel("A").getbbox()
    assert bbox, "wordmark renders empty"
    x0, y0, x1, y1 = (v / 10 for v in bbox)
    w, h = x1 - x0, y1 - y0
    inner = (WORDMARK_BOX[0] - 2 * WORDMARK_MARGIN[0], WORDMARK_BOX[1] - 2 * WORDMARK_MARGIN[1])
    scale = min(inner[0] / w, inner[1] / h)
    vw, vh = WORDMARK_BOX[0] / scale, WORDMARK_BOX[1] / scale
    vx, vy = x0 - (vw - w) / 2, y0 - (vh - h) / 2
    vb = f"{vx:.2f} {vy:.2f} {vw:.2f} {vh:.2f}"
    svg = re.sub(r'width="777" height="326" viewBox="0 0 777 326"', f'viewBox="{vb}"', svg)
    assert f'viewBox="{vb}"' in svg, "viewBox not rewritten"
    out = render(svg, WORDMARK_BOX[0])
    assert out.size == WORDMARK_BOX, out.size
    save(out, IMAGES / "buzz-wordmark.png")


if __name__ == "__main__":
    app_icons()
    launch_images()
    home_icon()
    wordmark()
