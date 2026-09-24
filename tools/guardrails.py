#!/usr/bin/env python3
"""
The conscience check. Fails the build if this SDK grows a way to mine quietly.

Crypto mining inside someone else's app is only acceptable while it is *their*
choice and *their* knowledge. So these are checked mechanically, in CI, on every
push — a promise in a README is worth nothing; a failing test is worth something.

    python3 tools/guardrails.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.abspath(os.path.join(HERE, '..'))

FAILURES = []
PASSES = []


def check(name, ok, why_failed=''):
    if ok:
        PASSES.append(name)
        print(f'  ✓ {name}')
    else:
        FAILURES.append((name, why_failed))
        print(f'  ✗ {name}')
        if why_failed:
            print(f'      {why_failed}')


def strip_comments(text, is_kotlin=False):
    """Remove comments so the scans look at code, not at prose about the rules."""
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'^\s*//.*$', '', text, flags=re.M)
    text = re.sub(r'///.*$', '', text, flags=re.M)
    if is_kotlin:
        text = re.sub(r'^\s*\*.*$', '', text, flags=re.M)
    return text


def read(path):
    with open(os.path.join(PKG, path), encoding='utf-8') as f:
        return f.read()


def dart_sources():
    for root, _dirs, files in os.walk(os.path.join(PKG, 'lib')):
        for f in files:
            if f.endswith('.dart'):
                p = os.path.join(root, f)
                yield os.path.relpath(p, PKG), strip_comments(open(p, encoding='utf-8').read())


def kotlin_sources():
    base = os.path.join(PKG, 'android/src/main/kotlin')
    for root, _dirs, files in os.walk(base):
        for f in files:
            if f.endswith('.kt'):
                p = os.path.join(root, f)
                yield os.path.relpath(p, PKG), strip_comments(
                    open(p, encoding='utf-8').read(), is_kotlin=True)


def main():
    print('guardrails: mining must never be silent, hidden or unasked\n')

    # 1 — consent is a hard gate in the only entry point that can start mining
    sdk = strip_comments(read('lib/sugar_miner_sdk.dart'))
    start_body = sdk.split('Future<MinerStartResult> start()', 1)
    check(
        'the start path checks consent before it does anything',
        'SugarConsent.isGranted()' in sdk and 'no consent recorded' in sdk,
        'SugarMiner.start() must call SugarConsent.isGranted() and refuse without it',
    )
    check(
        'consent is checked before the foreground service is started',
        ('SugarConsent.isGranted()' in sdk
         and sdk.index('SugarConsent.isGranted()') < sdk.index('ServiceBridge.startForeground')),
        'the consent check must come before ServiceBridge.startForeground()',
    )
    check(
        'consent is checked before the hashing isolate is spawned',
        ('SugarConsent.isGranted()' in sdk and sdk.index('SugarConsent.isGranted()') < sdk.index('MinerIsolate.spawn')),
        'the consent check must come before MinerIsolate.spawn()',
    )

    # 2 — a "no" is remembered, and it stops mining
    consent = strip_comments(read('lib/src/consent.dart'))
    check('a refusal is recorded and honoured', 'revoke()' in consent and 'isGranted' in consent)

    # 3 — no stealth affordances anywhere in the code
    forbidden = [
        'stealth', 'cloak', 'disguise', 'covert',
        'hideNotification', 'hiddenNotification', 'noNotification',
        'silentMode', 'silently', 'invisible', 'unseen', 'conceal',
    ]
    hits = []
    for path, src in list(dart_sources()) + list(kotlin_sources()):
        low = src.lower()
        for word in forbidden:
            if word.lower() in low:
                hits.append(f'{path}: {word}')
    check(
        'no stealth/hidden/silent option exists in the code',
        not hits,
        'found: ' + ', '.join(hits) + ' — this SDK has no quiet mode, by design',
    )

    # 4 — the notification is always visible and non-dismissible
    service = strip_comments(read('android/src/main/kotlin/com/mdk/sugarminer/sdk/SugarMiningService.kt'), True)
    check('the notification is ongoing (the user cannot swipe it away)', 'setOngoing(true)' in service)
    check('the notification channel is IMPORTANCE_DEFAULT or higher',
          'NotificationManager.IMPORTANCE_DEFAULT' in service.replace(' ', ''),
          'IMPORTANCE_MIN/NONE would make mining invisible')
    check('no auto-cancel / dismissible notification', 'setAutoCancel(true)' not in service)
    check('the notification taps through to the app', 'getLaunchIntentForPackage' in service)
    check('the notification icon exists', os.path.exists(
        os.path.join(PKG, 'android/src/main/res/drawable-xxhdpi/ic_sugar_miner.png')))

    # 5 — Android must be told why this service exists
    manifest = read('android/src/main/AndroidManifest.xml')
    check('foreground service type declared', 'foregroundServiceType="specialUse"' in manifest)
    check('the special-use reason is spelled out for the user',
          'PROPERTY_SPECIAL_USE_FGS_SUBTYPE' in manifest)
    check('service is not exported', 'android:exported="false"' in manifest)
    check('no wake-lock abuse beyond the mining service',
          manifest.count('WAKE_LOCK') == 1)

    # 6 — the limits are real code, not just documentation
    engine = strip_comments(read('lib/src/miner/engine.dart'))
    check('CPU duty-cycling exists', 'dutyShare' in engine)
    policy = strip_comments(read('lib/src/policy.dart'))
    for rule, needle in [
        ('battery floor', 'minBatteryPercent'),
        ('thermal stop', 'maxThermalStatus'),
        ('daily time budget', 'dailyCapMinutes'),
        ('metered-data stop', 'requireUnmetered'),
    ]:
        check(f'policy enforces the {rule}', needle in policy)

    # 7 — the pause path actually pauses
    check('policy decisions pause and resume the miner',
          '_isolate?.pause()' in sdk and 'resume()' in sdk)

    print()
    if FAILURES:
        print(f'{len(FAILURES)} guardrail(s) FAILED:')
        for name, why in FAILURES:
            print(f'  - {name}: {why}')
        print('\nIf you are adding a "quiet" or "hidden" mode: that is the one thing')
        print('this SDK will not ship. Mining without the device owner knowing is')
        print('malware, it is illegal in most countries, and it is not a feature.')
        return 1

    print(f'all {len(PASSES)} guardrails pass — mining here is consented and visible')
    return 0


if __name__ == '__main__':
    sys.exit(main())
