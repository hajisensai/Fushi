"""Generate comic-ad regression inputs (images) for the web-core vectors.

Usage: python -I gen_inputs.py <out_dir>
Deterministic: fixed seeds, fixed encoder settings.
"""
import io
import os
import random
import sys

import qrcode
from PIL import Image, ImageDraw

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)


def save(img: Image.Image, name: str, **kw) -> None:
    img.save(os.path.join(OUT, name), **kw)


def poster(w: int, h: int) -> Image.Image:
    """Colorful gradient poster (same formula as the Dart test's _colorfulPoster)."""
    im = Image.new("RGB", (w, h))
    px = im.load()
    for y in range(h):
        for x in range(w):
            px[x, y] = (230, x * 255 // w, 40 + y * 120 // h)
    return im


def fake_qr(im: Image.Image, left: int, top: int, module: int, seed: int = 7,
            drop_bottom_left: bool = False) -> None:
    """25x25 modules + 4 quiet modules; three finder patterns, random data."""
    modules, quiet = 25, 4
    d = ImageDraw.Draw(im)
    side = (modules + quiet * 2) * module
    d.rectangle([left, top, left + side - 1, top + side - 1], fill="white")
    rnd = random.Random(seed)

    def in_finder(r, c):
        return (r < 8 and c < 8) or (r < 8 and c >= modules - 8) or (r >= modules - 8 and c < 8)

    def finder_dark(r, c):
        lr = r - (modules - 7) if r >= 8 else r
        lc = c - (modules - 7) if c >= 8 else c
        if lr > 6 or lc > 6 or lr < 0 or lc < 0:
            return False
        ring = min(min(lr, lc), min(6 - lr, 6 - lc))
        return ring != 1

    for r in range(modules):
        for c in range(modules):
            dark = finder_dark(r, c) if in_finder(r, c) else rnd.random() < 0.5
            if drop_bottom_left and r >= modules - 8 and c < 8:
                dark = False
            if dark:
                x = left + (quiet + c) * module
                y = top + (quiet + r) * module
                d.rectangle([x, y, x + module - 1, y + module - 1], fill="black")


def real_qr(im: Image.Image, left: int, top: int, box: int, text: str) -> None:
    q = qrcode.QRCode(border=4, box_size=box)
    q.add_data(text)
    q.make(fit=True)
    qi = q.make_image(fill_color="black", back_color="white").convert("RGB")
    im.paste(qi, (left, top))


def manga_page(w: int, h: int, seed: int) -> Image.Image:
    """Gray manga-ish page: paper tone, panel borders, screentone dots, ink strokes."""
    rnd = random.Random(seed)
    im = Image.new("L", (w, h), 244)
    d = ImageDraw.Draw(im)
    d.rectangle([20, 20, w - 20, h // 2], outline=0, width=4)
    d.rectangle([20, h // 2 + 12, w // 2 - 6, h - 20], outline=0, width=4)
    d.rectangle([w // 2 + 6, h // 2 + 12, w - 20, h - 20], outline=0, width=4)
    for y in range(h // 2 + 30, h - 30, 6):
        for x in range(30, w // 2 - 20, 6):
            d.point((x, y), fill=60)
    for _ in range(80):
        x0, y0 = rnd.randrange(30, w - 30), rnd.randrange(30, h // 2 - 10)
        d.line([x0, y0, x0 + rnd.randrange(-60, 60), y0 + rnd.randrange(-60, 60)],
               fill=rnd.randrange(0, 90), width=rnd.randrange(1, 4))
    return im


def color_page(w: int, h: int, seed: int) -> Image.Image:
    rnd = random.Random(seed)
    im = Image.new("RGB", (w, h), (250, 236, 220))
    d = ImageDraw.Draw(im)
    for _ in range(40):
        x0, y0 = rnd.randrange(0, w), rnd.randrange(0, h)
        d.ellipse([x0, y0, x0 + rnd.randrange(20, 160), y0 + rnd.randrange(20, 160)],
                  fill=(rnd.randrange(80, 255), rnd.randrange(40, 200), rnd.randrange(40, 220)))
    d.rectangle([20, 20, w - 20, h - 20], outline=(0, 0, 0), width=5)
    return im


# --- colorful ad posters with codes, many formats ---------------------------------
p = poster(600, 900)
fake_qr(p, 180, 520, 7)
save(p, "py_color_qr_600x900.jpg", quality=85)
save(p, "py_color_qr_600x900.webp", quality=80)
save(p, "py_color_qr_600x900_lossless.webp", lossless=True)
save(p.convert("RGBA"), "py_color_qr_600x900_rgba.png")
save(p.quantize(colors=64), "py_color_qr_600x900_palette.png")
save(p.quantize(colors=64), "py_color_qr_600x900.gif")

p = poster(750, 1100)
real_qr(p, 200, 640, 8, "https://example.invalid/download-app?from=comic")
save(p, "py_color_realqr_750x1100.jpg", quality=90)
save(p, "py_color_realqr_750x1100.png")

p = poster(320, 480)
fake_qr(p, 90, 300, 4, seed=21)
save(p, "py_color_qr_320x480.bmp")

# big landscape poster (downscaled to 900 long side before detection)
p = poster(2000, 1400)
fake_qr(p, 1300, 500, 18, seed=11)
save(p, "py_color_qr_2000x1400.jpg", quality=88)

# very large portrait poster
p = poster(2400, 3400)
fake_qr(p, 700, 2200, 30, seed=3)
save(p, "py_color_qr_2400x3400.jpg", quality=80)

# tiny modules: below what survives the 900px downscale
p = poster(1800, 2600)
fake_qr(p, 900, 2000, 3, seed=5)
save(p, "py_color_qr_tiny_modules_1800x2600.jpg", quality=92)

# only two finder patterns
p = poster(600, 900)
fake_qr(p, 180, 520, 7, drop_bottom_left=True)
save(p, "py_color_two_finders_600x900.jpg", quality=90)
save(p, "py_color_two_finders_600x900.png")

# colorful, no code (color pages are not ads)
save(color_page(800, 1200, 1), "py_color_page_800x1200.jpg", quality=85)
save(color_page(800, 1200, 2), "py_color_page_800x1200.webp", quality=80)
save(poster(600, 900), "py_color_poster_noqr_600x900.png")

# --- grayscale with codes -------------------------------------------------------
g = manga_page(600, 900, 4)
gq = g.convert("RGB")
fake_qr(gq, 180, 520, 7)
save(gq.convert("L"), "py_gray_l_qr_600x900.png")          # 8-bit L PNG
save(gq.convert("L"), "py_gray_l_qr_600x900.jpg", quality=90)
save(gq.convert("L"), "py_gray_l_qr_600x900.webp", quality=85)
save(gq, "py_gray_rgb_qr_600x900.jpg", quality=90)          # RGB but neutral
save(gq.convert("LA"), "py_gray_la_qr_600x900.png")

# --- ordinary manga pages -------------------------------------------------------
save(manga_page(800, 1200, 9), "py_manga_page_800x1200.jpg", quality=85)
save(manga_page(800, 1200, 10), "py_manga_page_800x1200.png")
save(manga_page(1100, 1600, 12).convert("RGB"), "py_manga_page_rgb_1100x1600.webp", quality=82)

# --- edge cases -----------------------------------------------------------------
save(poster(31, 40), "py_too_small_31x40.png")
save(poster(32, 32), "py_min_32x32.png")
buf = io.BytesIO()
p = poster(600, 900)
fake_qr(p, 180, 520, 7)
p.save(buf, format="JPEG", quality=85)
with open(os.path.join(OUT, "py_truncated_color_qr.jpg"), "wb") as f:
    f.write(buf.getvalue()[: len(buf.getvalue()) // 3])
with open(os.path.join(OUT, "py_not_an_image.bin"), "wb") as f:
    f.write(b"<!doctype html><html><body>404</body></html>")
with open(os.path.join(OUT, "py_empty.bin"), "wb") as f:
    pass
print("ok")
