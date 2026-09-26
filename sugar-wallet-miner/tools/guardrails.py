#!/usr/bin/env python3
"""
Checks that this app keeps the four promises it makes on its own screens.

The app is not the SDK, but it is the thing the user actually installs, so it is
the thing that can quietly become something else: a wallet that phones home, a
miner whose notification can be dismissed, an "estimate" that was really just a
number someone typed. Each of those is a check below.

    python3 tools/guardrails.py
"""
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.abspath(os.path.join(HERE, '..'))

FAILURES = []
PASSES = []


def check(name, ok, why=''):
    if ok:
        PASSES.append(name)
        print(f'  ✓ {name}')
    else:
        FAILURES.append((name, why))
        print(f'  ✗ {name}')
        if why:
            print(f'      {why}')


def read(path):
    with open(os.path.join(PKG, path), encoding='utf-8') as f:
        return f.read()


def app_sources():
    for root, _dirs, files in os.walk(os.path.join(PKG, 'lib')):
        for f in sorted(files):
            if f.endswith('.dart'):
                p = os.path.join(root, f)
                rel = os.path.relpath(p, PKG)
                yield rel, read(rel)


def strip_comments(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'^\s*//.*$', '', text, flags=re.M)
    return text


def main():
    print('guardrails: the wallet is the user\'s, the mining is visible, nothing phones home\n')

    sources = {path: strip_comments(src) for path, src in app_sources()}
    everything = '\n'.join(sources.values())
    pubspec = read('pubspec.yaml')
    manifest = read('android/app/src/main/AndroidManifest.xml')

    # ── 1. the key is the user's, and stays on the device ───────────────────
    check('the wallet is generated on the device from a secure random source',
          'Random.secure()' in sources.get('lib/services/wallet_store.dart', ''),
          'a wallet from a predictable RNG is not a wallet')
    check('the key is stored in the platform keystore, not in preferences',
          'FlutterSecureStorage' in sources.get('lib/services/wallet_store.dart', ''))
    check('the key never leaves the app in any request',
          'privateKeyHex' not in _http_sections(everything)
          and 'wif' not in _http_sections(everything).lower(),
          'a key in a query string is a key on someone else\'s server')
    check('the app has no analytics, crash reporting or tracking dependency',
          not re.search(r'(firebase|sentry|amplitude|mixpanel|adjust|appsflyer|facebook)',
                        pubspec, re.I),
          'the app talks to its own pool and nothing else')
    # The wallet now has exactly one write in it, because a wallet that cannot
    # spend is not a wallet: a signed transaction, handed to the chain. Everything
    # else it does is a read. This is checked by shape — the POST may only exist in
    # the one helper that performs it, and only the chain service may call it.
    posters = {path for path, src in sources.items()
               if 'postUrl(' in src or "'POST'" in src or 'httpPostText(' in src}
    check('the only write in this app is one signed transaction, to the chain',
          posters <= {'lib/services/net.dart', 'lib/services/net_io.dart',
                      'lib/services/net_web.dart', 'lib/services/chain_api.dart'},
          f'a POST appeared in {sorted(posters - {"lib/services/net.dart", "lib/services/net_io.dart", "lib/services/net_web.dart", "lib/services/chain_api.dart"})}')
    chain = sources.get('lib/services/chain_api.dart', '')
    check('what is posted is a transaction, and it goes to the chain\'s own endpoint',
          "broadcastPath = '/esplora/tx'" in chain
          and "post('$base$broadcastPath'" in chain
          and 'rawHex' in chain,
          'the one POST must carry a signed transaction to /esplora/tx')
    check('the key is not in what is broadcast, and cannot be',
          'privateKey' not in _http_sections(everything)
          and 'phrase' not in _http_sections(everything)
          and 'signAll(' in sources.get('lib/screens/send.dart', ''),
          'signing happens on the device; only the signed bytes are posted')
    # api.coingecko.com is here deliberately, and it is the only third party this
    # app ever added. It is asked one fixed question — what is SUGAR worth — and
    # the request carries no address, no identifier and no key. The three checks
    # around it are the price of letting it in: the URL must stay that exact
    # public one, the app must survive it being down, and the policy must say so.
    hosts = set(re.findall(r'https?://([a-z0-9.\-]+)', everything))
    check('the only hosts contacted are the pool, the chain, and the named price feed',
          hosts <= {'poolab.org', 'github.com', 'api.sugar.wtf', 'api.coingecko.com'},
          str(sorted(hosts)))
    check('the price feed is asked one fixed question and nothing about the user',
          'api.coingecko.com/api/v3/simple/price?ids=sugarchain&vs_currencies=usd'
          in everything,
          'the price URL must be a constant with no address, device id or key in it')
    check('a price feed that is down leaves the app usable rather than blank',
          "'price unknown'" in sources.get('lib/screens/home.dart', '')
          and 'no live price' in sources.get('lib/screens/home.dart', ''),
          'the money side of the screen must degrade to a dash, never to a guess')
    check('the price feed is disclosed in the privacy policy',
          'api.coingecko.com' in read('PRIVACY.md'),
          'a third party the app talks to belongs in the policy, not only in the code')

    # ── 2. mining stays visible and consented ──────────────────────────────
    check('consent goes through the SDK\'s own screen, so the answer is recorded by it',
          'SugarConsentSheet.show(' in sources.get('lib/screens/onboarding.dart', '')
          and 'miner: miner' in sources.get('lib/screens/onboarding.dart', ''),
          'a home-made dialog could grant consent without the SDK knowing')
    check('no stealth/hidden/silent identifier exists in this app',
          not re.search(r'(hideNotification|silentMode|noNotification|hiddenNotification|stealth)',
                        everything, re.I))
    check('the app never asks for overlay permission',
          'SYSTEM_ALERT_WINDOW' not in manifest)
    check('the app does not auto-start mining before the user has agreed',
          'autoStart: false' in sources.get('lib/main.dart', ''),
          'a fresh install must not mine before the disclosure is read')
    check('stopping is a first-class action on the home screen',
          'Stop mining' in sources.get('lib/screens/home.dart', ''))
    check('starting again after a stop is the user\'s own act',
          'clearUserStopped' in sources.get('lib/screens/home.dart', '')
          or 'clearUserStopped' in sources.get('lib/screens/onboarding.dart', ''),
          'the app should have to ask; the SDK should not volunteer')
    check('the mining limit is stated where the user can see it',
          'cpuSharePercent' in sources.get('lib/screens/home.dart', ''))

    # ── 3. the reboot path cannot invent a wallet ─────────────────────────
    headless = sources.get('lib/main.dart', '')
    check('the reboot callback refuses to mine without a wallet',
          'sugarWalletHeadless' in headless
          and 'if (address == null' in headless
          and 'looksLikeSugarAddress' in headless,
          'no wallet means nothing to mine into, so it must return')
    check('the reboot callback carries the tree-shake guard',
          "@pragma('vm:entry-point')" in read('lib/main.dart'),
          'without the pragma, release builds drop the callback')
    check('the boot path reads the public address, not the keystore',
          'WalletStore.address()' in headless
          and 'WalletStore.load()' not in headless.split('sugarWalletHeadless')[1][:600],
          'a keystore read before first unlock is not something to depend on')

    # ── 4. the numbers shown are arithmetic, not a promise ────────────────
    pool = sources.get('lib/services/pool_api.dart', '')
    check('the earnings estimate is computed from live network data',
          'networkHashrate' in pool and 'blockReward' in pool,
          'an estimate must be arithmetic on real numbers')
    check('the estimate says something honest when the data is missing',
          "perDay == null ? '—'" in sources.get('lib/screens/home.dart', '')
          or 'network rate unavailable' in sources.get('lib/screens/home.dart', ''),
          'a missing network rate must not render as a confident number')
    check('a failed pool lookup is shown as unknown, not as zero',
          'did not answer' in sources.get('lib/screens/home.dart', '')
          or 'unknown rather than zero' in sources.get('lib/screens/home.dart', ''))
    check('the honest limits are on the screen, not only in the README',
          'pennies a day' in sources.get('lib/screens/home.dart', '')
          or 'not a mining rig' in sources.get('lib/screens/home.dart', ''))
    check('the Play Store limitation is stated in the app',
          'Play' in sources.get('lib/screens/home.dart', ''))

    # ── 5. the wallet package stays dependency-free and tested ────────────
    wallet_pubspec = read('packages/sugar_wallet/pubspec.yaml')
    check('the wallet package still has no dependencies',
          'dependencies:' not in wallet_pubspec.replace('dev_dependencies: {}', ''),
          'a wallet that resolves to nothing cannot break because a dependency did')
    check('the wallet vectors include the BIP-173 example',
          'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4' in
          read('packages/sugar_wallet/test/wallet_vectors.dart'))
    check('the vectors include a cross-implementation check',
          'JavaScript wallet' in read('packages/sugar_wallet/test/wallet_vectors.dart'),
          'two implementations agreeing is the point')
    check('no test asserts a value it produced itself',
          'sugar1q' in read('packages/sugar_wallet/test/wallet_vectors.dart')
          and 'crossVectors' in read('packages/sugar_wallet/test/wallet_vectors.dart'))

    # ── 6. the app still builds an APK, and CI is where that happens ──────
    #
    # The workflow lives either in this component (a standalone checkout) or in the
    # repository root (the suite, where one workflow per component keeps a change to
    # the engine from silently breaking this app). Both are fine; what is not fine
    # is this app having no CI at all, so the check reads whichever is present.
    def ci_text():
        for rel in ('.github/workflows/ci.yml', '.github/workflows/wallet-app.yml',
                    os.path.join('..', '.github/workflows', 'wallet-app.yml')):
            path = os.path.join(PKG, rel)
            if os.path.exists(path):
                with open(path, encoding='utf-8') as f:
                    return f.read()
        return ''

    check('CI runs the wallet vectors, the analyzer and the APK build',
          all(k in ci_text()
              for k in ['wallet_vectors.dart', 'flutter analyze', 'flutter build apk']))
    check('no XML in this repo is malformed',
          _xml_ok())
    check('the Android identity is this app\'s own',
          'com.mdk.sugarwallet' in read('android/app/build.gradle.kts')
          and 'SUGAR Wallet' in manifest)

    print()
    if FAILURES:
        print(f'{len(FAILURES)} guardrail(s) FAILED:')
        for name, why in FAILURES:
            print(f'  - {name}: {why}' if why else f'  - {name}')
        print('\nThis app gives people their own wallet and mines to it. If a change')
        print('makes the mining invisible, the key exportable, or the numbers flattering,')
        print('it is not that app any more.')
        return 1
    print(f'all {len(PASSES)} guardrails pass — the wallet is the user\'s and the mining is visible')
    return 0


def _http_sections(text):
    """The parts of the app that talk to a network."""
    out = []
    for chunk in text.split('class '):
        if 'HttpClient' in chunk or 'Uri.parse' in chunk:
            out.append(chunk)
    return '\n'.join(out)


def _xml_ok():
    import xml.dom.minidom
    for f in sorted(set(glob.glob(os.path.join(PKG, '**/*.xml'), recursive=True))):
        try:
            xml.dom.minidom.parse(f)
        except Exception as e:  # noqa: BLE001
            print(f'      {os.path.relpath(f, PKG)}: {e}')
            return False
    return True


if __name__ == '__main__':
    sys.exit(main())
