#!/usr/bin/env python3
"""
Draws the app icon set — no binary assets in the repo, the icons are generated.

    python3 tools/make_icons.py

Produces android/app/src/main/res/mipmap-*/ic_launcher.png plus the white
silhouette the foreground-service notification needs (ic_bg_service_small).
"""
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, '..', 'android', 'app', 'src', 'main', 'res')

DENSITIES = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
S = 1024  # master size


def cube_polygons(cx, cy, r):
    """Isometric cube: top face, left face, right face — as polygon point lists."""
    h = r * 0.866  # cos(30°)
    top = [(cx, cy - r), (cx + r, cy - r / 2), (cx, cy), (cx - r, cy - r / 2)]
    left = [(cx - r, cy - r / 2), (cx, cy), (cx, cy + r), (cx - r, cy + r / 2)]
    right = [(cx + r, cy - r / 2), (cx, cy), (cx, cy + r), (cx + r, cy + r / 2)]
    return top, left, right


def draw_icon(size=S, bg=True):
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    if bg:
        # deep navy, slightly graded top-to-bottom
        for y in range(size):
            t = y / (size - 1)
            c = (int(9 + 12 * t), int(26 + 32 * t), int(56 + 46 * t), 255)
            d.line([(0, y), (size, y)], fill=c)

    cx = cy = size / 2
    r = size * 0.29
    top, left, right = cube_polygons(cx, cy, r)
    d.polygon(top, fill=(246, 250, 255, 255))
    d.polygon(left, fill=(176, 197, 224, 255))
    d.polygon(right, fill=(208, 224, 244, 255))
    d.line(top + [top[0]], fill=(255, 255, 255, 255), width=max(1, size // 160))

    # grain: little notches so it reads as sugar, not a plain cube
    ink = (150, 175, 205, 180) if bg else (255, 255, 255, 255)
    for (fx, fy) in [(0.42, 0.36), (0.55, 0.33), (0.48, 0.46), (0.60, 0.44), (0.36, 0.44)]:
        x, y = cx - r + 2 * r * fx, cy - r + 2 * r * fy
        s = size * 0.008
        d.ellipse([x - s, y - s, x + s, y + s], fill=ink)

    return img


def silhouette(size=96):
    """Notification icons must be a flat white shape on transparent."""
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx = cy = size / 2
    r = size * 0.34
    top, left, right = cube_polygons(cx, cy, r)
    for poly in (top, left, right):
        d.polygon(poly, fill=(255, 255, 255, 255))
    return img


def main():
    master = draw_icon()
    for name, px in DENSITIES.items():
        out = os.path.join(RES, f'mipmap-{name}', 'ic_launcher.png')
        os.makedirs(os.path.dirname(out), exist_ok=True)
        master.resize((px, px), Image.LANCZOS).save(out, 'PNG')
        print('wrote', out)

    # Android 8+ round mask
    circ = Image.new('L', (S, S), 0)
    ImageDraw.Draw(circ).ellipse([0, 0, S - 1, S - 1], fill=255)
    rounded = master.copy()
    rounded.putalpha(circ)
    for name, px in DENSITIES.items():
        out = os.path.join(RES, f'mipmap-{name}', 'ic_launcher_round.png')
        rounded.resize((px, px), Image.LANCZOS).save(out, 'PNG')
        print('wrote', out)

    notif = os.path.join(RES, 'drawable', 'ic_bg_service_small.png')
    os.makedirs(os.path.dirname(notif), exist_ok=True)
    silhouette().save(notif, 'PNG')
    print('wrote', notif)


if __name__ == '__main__':
    main()
