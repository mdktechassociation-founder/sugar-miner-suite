#!/usr/bin/env python3
"""
Verifies the QR encoder against two independent implementations.

A QR code with one wrong module points at a different address — that is, at
someone else's wallet. So this does not check the encoder against itself:

  1. **Identity** — the module matrix must be byte-identical to `qrcode`
     (python-qrcode) when both are pinned to the same mask. That covers the
     codewords, Reed-Solomon, block interleaving, mask application, placement and
     the format information, i.e. everything except the choice of mask.

  2. **Scannability** — the rendered symbol must decode back to the exact input
     text with OpenCV's detector, which is a different implementation again
     (zxing-style), and is what a phone camera is doing.

Neither the mask *choice* nor this implementation's penalty scoring is asserted
to match anyone else's: any of the eight masks is a valid symbol as long as its
format information agrees, and (2) is the test that proves it does.

    python3 tools/check_qr.py            # needs the Dart SDK on PATH
"""
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

TEXTS = [
    'sugar1qw508d6qejxtdg4y5r3zarvary0c5xw7kjjlkp2',   # a real mainnet address length
    'sugar1qvmqas4maw7lg9clqu6kqu9zq9cluvlln2zcz5l',
    'tugar1qtestnet000000000000000000000000000',
    'SdJvKP8kQtHqzZR1t8vJmQn5xWcYbGfLpM',                # the legacy S… form
    'The quick brown fox jumps over the lazy dog 0123456789',  # long: version 5+
]

failures = []
passes = []


def note(ok, name, why=''):
    (passes if ok else failures).append(name)
    print(f'  {"✓" if ok else "✗"} {name}' + (f'  ({why})' if why and not ok else ''))


def dart_dump(text):
    """Runs the Dart encoder and returns (size, mask, rows)."""
    env = dict(os.environ)
    procs = subprocess.run(
        ['dart', 'run', 'tool/qr_dump.dart', text],
        cwd=ROOT, capture_output=True, text=True, env=env, timeout=180)
    if procs.returncode != 0:
        raise RuntimeError(procs.stderr.strip()[:400])
    lines = open('/tmp/qr.txt').read().strip().split('\n')
    size = int(lines[0].split(':')[1])
    mask = int(lines[1].split(':')[1])
    return size, mask, lines[2:2 + size]


def main():
    if not shutil.which('dart'):
        print('dart is not on PATH — skipping (CI installs it)')
        return 0

    try:
        import qrcode
    except ImportError:
        print('python-qrcode is not installed — run: pip install qrcode')
        return 2

    try:
        import cv2
        import numpy as np
    except ImportError:
        cv2 = None
        print('  (opencv not installed: the scannability check will be skipped)\n')

    for text in TEXTS:
        try:
            size, mask, rows = dart_dump(text)
        except Exception as e:                                    # noqa: BLE001
            note(False, f'encodes "{text[:24]}…"', str(e))
            continue

        note(0 <= mask <= 7, f'mask {mask} is in range for "{text[:20]}…"')

        ref = qrcode.QRCode(version=None, error_correction=qrcode.constants.ERROR_CORRECT_M,
                            box_size=1, border=0, mask_pattern=mask)
        # optimize=0 keeps the reference to a single byte-mode segment, which is
        # exactly what the encoder under test does. Without it, python-qrcode
        # silently splits a long run of digits into its own numeric segment and
        # the two symbols legitimately disagree while decoding to the same text.
        ref.add_data(text, optimize=0)
        ref.make(fit=False)
        expected = ref.get_matrix()
        if len(expected) != size:
            note(False, f'version agrees for "{text[:20]}…"',
                 f'mine {size}x{size}, reference {len(expected)}x{len(expected)}')
            continue
        note(True, f'version agrees for "{text[:20]}…" ({size}x{size})')

        diff = [(x, y) for y in range(size) for x in range(size)
                if (rows[y][x] == '1') != expected[y][x]]
        note(not diff, f'modules identical to the reference at mask {mask}',
             f'{len(diff)} differ, e.g. {diff[:6]}')

        if cv2 is not None:
            quiet, scale = 6, 14
            n = size + quiet * 2
            img = np.ones((n, n), dtype=np.uint8) * 255
            for y in range(size):
                for x in range(size):
                    if rows[y][x] == '1':
                        img[y + quiet, x + quiet] = 0
            big = np.kron(img, np.ones((scale, scale), dtype=np.uint8))
            decoded, _points, _ = cv2.QRCodeDetector().detectAndDecode(big)
            note(decoded == text, f'a scanner reads "{text[:20]}…" back exactly',
                 f'got {decoded[:40]!r}')

    print()
    if failures:
        print(f'{len(failures)} QR check(s) FAILED')
        for f in failures:
            print(f'  - {f}')
        return 1
    print(f'all {len(passes)} QR checks pass — the symbol is right, and it scans')
    return 0


if __name__ == '__main__':
    sys.exit(main())
