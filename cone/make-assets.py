"""Cone Desktop image assets, from cone/icons/source.png (Slice 29 decision 4).

Run from the repository root:  bin/uv run --with Pillow==12.2.0 python cone/make-assets.py
then:                          (cd desktop && pnpm tauri icon ../cone/icons/icon-1024.png -o ../cone/icons)

Writes cone/icons/icon-1024.png — the artwork on a white tile, 824 px with
185 px corners on a 1024 px canvas, the inset upstream's
scripts/generate-macos-icon.py uses — and cone/icons/dmg-background.png at
the size and layout of upstream's (1320x1000, the white panel where Finder
draws the app and Applications icons).
"""
from PIL import Image, ImageDraw, ImageFont

S = 4
ICONS = "cone/icons"
ORANGE, PURPLE, INK = (249, 115, 22), (118, 31, 107), (28, 25, 23)


def tile():
    with Image.open(f"{ICONS}/source.png") as im:
        art = im.convert("RGBA")
    bg = Image.new("RGBA", art.size, (255, 255, 255, 255))
    bg.alpha_composite(art)
    t = bg.resize((824 * S, 824 * S), Image.Resampling.LANCZOS)
    mask = Image.new("L", t.size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, t.width - 1, t.height - 1), radius=185 * S, fill=255)
    canvas = Image.new("RGBA", (1024 * S, 1024 * S))
    canvas.paste(t, (100 * S, 100 * S), mask)
    canvas.resize((1024, 1024), Image.Resampling.LANCZOS).save(f"{ICONS}/icon-1024.png")


def font(size, bold):
    for path in ("/System/Library/Fonts/HelveticaNeue.ttc", "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(path, size, index=1 if bold else 0)
        except OSError:
            continue
    return ImageFont.load_default()


def dmg_background():
    w, h = 1320, 1000
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        f = y / (h - 1)
        top = tuple(int(255 - (255 - c) * 0.22) for c in ORANGE)
        bottom = tuple(int(255 - (255 - c) * 0.16) for c in PURPLE)
        row = tuple(int(top[i] + (bottom[i] - top[i]) * f) for i in range(3))
        for x in range(w):
            px[x, y] = row
    d = ImageDraw.Draw(img)
    with Image.open(f"{ICONS}/source.png") as im:
        mark = im.convert("RGBA").resize((150, 150), Image.Resampling.LANCZOS)
    img.paste(mark, ((w - 150) // 2, 60), mark)
    title, sub = font(92, True), font(40, False)
    for text, f, y in (("Cone", title, 215), ("Drag Cone to Applications", sub, 330)):
        tw = d.textlength(text, font=f)
        d.text(((w - tw) / 2, y), text, font=f, fill=INK)
    d.rounded_rectangle((108, 408, 1212, 935), radius=56, fill=(255, 255, 255))
    img.save(f"{ICONS}/dmg-background.png")


if __name__ == "__main__":
    tile()
    dmg_background()
