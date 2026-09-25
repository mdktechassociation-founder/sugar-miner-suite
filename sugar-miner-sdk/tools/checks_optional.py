#!/usr/bin/env python3
"""
The taste checks — NOT part of the build.

These were mixed in with the consent/visibility guardrails and did not belong
there: they are opinions about wording, branding, plumbing and build hygiene,
not promises about whether mining is consented and visible. They live here so
you can run them when you want them and delete the file when you do not.

Nothing in CI runs this.

    python3 tools/checks_optional.py
"""
import glob
import os
import re
import sys
import xml.dom.minidom

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
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'^\s*//.*$', '', text, flags=re.M)
    text = re.sub(r'///.*$', '', text, flags=re.M)
    if is_kotlin:
        text = re.sub(r'^\s*\*.*$', '', text, flags=re.M)
    return text


def read(path):
    with open(os.path.join(PKG, path), encoding='utf-8') as f:
        return f.read()


def code(path):
    return strip_comments(read(path), is_kotlin=path.endswith('.kt'))


def main():
    print('optional checks: taste, wording, plumbing, build hygiene\n')

    disc = code('lib/src/disclosure.dart')
    style = code('lib/src/notification_style.dart')
    auto = code('lib/src/auto_config.dart')
    engine = code('lib/src/miner/engine.dart')
    bridge = code('lib/src/service_bridge.dart')
    manifest = read('android/src/main/AndroidManifest.xml')

    # ── wording and branding ───────────────────────────────────────────────
    check('there is a ready-made "free app, in exchange for spare power" wording',
          'MiningDisclosure.donation' in disc,
          'the common case deserves plain words, not a constructor to fill in')
    defaults = style[style.index('const NotificationStyle({'):]
    defaults = defaults[:defaults.index('});')]
    check('the default wording carries no mining arithmetic',
          not any(j in defaults
                  for j in ['{hashrate}', 'H/s', '{diff}', '{accepted}', '{worker}', 'pool']),
          'no hashrate / pool / share counters in front of the user by default')
    check('notification text is configurable by the developer',
          'titleTemplate' in style and 'bodyTemplate' in style)
    check("the notification channel is the app's own branding",
          all(k in style for k in ['channelId', 'channelName', 'channelDescription']),
          'the user should see the app in notification settings, not this library')
    check('the UI the SDK renders shows who benefits, not a wallet string',
          'payoutAddress' not in code('lib/src/widgets/consent_sheet.dart')
          and 'Mining to' not in read('lib/src/widgets/consent_sheet.dart'))

    # ── resource discipline ────────────────────────────────────────────────
    check('no wake-lock abuse beyond the mining service', manifest.count('WAKE_LOCK') == 1)
    check('CPU duty-cycling exists', 'dutyShare' in engine)
    check('a running miner can be retuned mid-flight', 'applyProfile' in engine)
    for rule, needle in [
        ('battery floor', 'minBatteryPercent'),
        ('thermal stop', 'maxThermalStatus'),
        ('charger rule', 'requireCharging'),
        ('metered-data stop', 'requireUnmetered'),
        ('battery temperature stop', 'batteryTempC'),
    ]:
        check(f'the profiler enforces the {rule}', needle in auto)
    check('the profiler reads health from Android, not from guesses',
          all(k in bridge for k in ['deviceState', 'isIgnoringBatteryOptimizations']))

    # ── build hygiene (this one saved a 3-minute CI failure once) ──────────
    broken = []
    for f in sorted(set(glob.glob(os.path.join(PKG, '**/*.xml'), recursive=True))):
        try:
            xml.dom.minidom.parse(f)
        except Exception as e:  # noqa: BLE001
            broken.append(f'{os.path.relpath(f, PKG)}: {e}')
    check('every XML file parses', not broken, '; '.join(broken))

    print()
    if FAILURES:
        print(f'{len(FAILURES)} optional check(s) failed (does not break the build):')
        for name, why in FAILURES:
            print(f'  - {name}: {why}' if why else f'  - {name}')
        return 1
    print(f'all {len(PASSES)} optional checks pass')
    return 0


if __name__ == '__main__':
    sys.exit(main())
