#!/usr/bin/env python3
"""Inlines the wallet crypto and the dashboard logic into a single index.html.

One file, no CDN, no external requests — so the console works offline, inside a
sandboxed preview, or from a USB stick, and there is exactly one place to read the
code that touches a private key.

    python3 minehub/build.py
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    template = open(os.path.join(HERE, 'src', 'index.template.html'), encoding='utf-8').read()
    wallet = open(os.path.join(HERE, 'src', 'sugar_wallet.js'), encoding='utf-8').read()
    app = open(os.path.join(HERE, 'src', 'console_app.js'), encoding='utf-8').read()

    for marker in ('/*__WALLET_JS__*/', '/*__APP_JS__*/'):
        if marker not in template:
            raise SystemExit(f'template is missing {marker}')

    out = template.replace('/*__WALLET_JS__*/', wallet).replace('/*__APP_JS__*/', app)
    # a </script> inside a JSON string would end the block early
    assert out.count('<script>') == out.count('</script>') == 2, 'script blocks do not balance'

    dest = os.path.join(HERE, 'index.html')
    open(dest, 'w', encoding='utf-8').write(out)
    print(f'wrote {dest} ({len(out) / 1024:.1f} KB, self-contained)')


if __name__ == '__main__':
    main()
