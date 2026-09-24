#!/usr/bin/env python3
"""
Draws the PNG assets the SDK and the example app need — nothing binary is
committed by hand.

    python3 tools/make_icons.py

* android/src/main/res/drawable-*/ic_sugar_miner.png  … the notification icon.
  Android wants a flat white silhouette on transparent, sized per density.
* example/android/app/src/main/res/mipmap-*/ic_launcher*.png … the example app's
  launcher icon (a sugar cube, because it is a SUGAR miner).
"""
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.join(HERE, '..')

# notification icon: 24dp
NOTIF = {'mdpi': 24, 'hdpi': 36, 'xhdpi': 48, 'xxhdpi': 72, 'xxxhdpi': 96}
# launcher icon: 48dp
LAUNCH = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
S = 1024


def cube(cx, cy, r):
    h = r * 0.866
    top = [(cx, cy - r), (cx + r, cy - r / 2), (cx, cy), (cx - r, cy - r / 2)]
    left = [(cx - r, cy - r / 2), (cx, cy), (cx, cy + r), (cx - r, cy + r / 2)]
    right = [(cx + r, cy - r / 2), (cx, cy), (cx, cy + r), (cx + r, cy + r / 2)]
    return top, left, right


def silhouette(size):
    """Flat white shape — what Android requires for a notification icon."""
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for poly in cube(size / 2, size / 2, size * 0.34):
        d.polygon(poly, fill=(255, 255, 255, 255))
    return img


def launcher():
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for y in range(S):
        t = y / (S - 1)
        d.line([(0, y), (S, y)], fill=(int(9 + 12 * t), int(26 + 32 * t), int(56 + 46 * t), 255))
    top, left, right = cube(S / 2, S / 2, S * 0.29)
    d.polygon(top, fill=(246, 250, 255, 255))
    d.polygon(left, fill=(176, 197, 224, 255))
    d.polygon(right, fill=(208, 224, 244, 255))
    for fx, fy in [(0.42, 0.36), (0.55, 0.33), (0.48, 0.46), (0.60, 0.44), (0.36, 0.44)]:
        x, y = S / 2 - S * 0.29 + 2 * S * 0.29 * fx, S / 2 - S * 0.29 + 2 * S * 0.29 * fy
        s = S * 0.008
        d.ellipse([x - s, y - s, x + s, y + s], fill=(150, 175, 205, 180))
    return img


def main():
    notif = silhouette(96)
    for name, px in NOTIF.items():
        out = os.path.join(PKG, 'android/src/main/res', f'drawable-{name}', 'ic_sugar_miner.png')
        os.makedirs(os.path.dirname(out), exist_ok=True)
        notif.resize((px, px), Image.LANCZOS).save(out, 'PNG')
        print('wrote', os.path.relpath(out, PKG))

    master = launcher()
    circle = Image.new('L', (S, S), 0)
    ImageDraw.Draw(circle).ellipse([0, 0, S - 1, S - 1], fill=255)
    rounded = master.copy()
    rounded.putalpha(circle)
    for name, px in LAUNCH.items():
        d1 = os.path.join(PKG, 'example/android/app/src/main/res', f'mipmap-{name}')
        os.makedirs(d1, exist_ok=True)
        master.resize((px, px), Image.LANCZOS).save(os.path.join(d1, 'ic_launcher.png'), 'PNG')
        rounded.resize((px, px), Image.LANCZOS).save(os.path.join(d1, 'ic_launcher_round.png'), 'PNG')
        print('wrote example icons:', name, px)


if __name__ == '__main__':
    main()
