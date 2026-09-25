#!/usr/bin/env python3
"""
The conscience check — consent and visibility, nothing else.

This file is the *only* thing CI enforces about what this SDK is allowed to do,
and it enforces one rule: mining here is consented, and the person whose phone
is doing the work can always see it and can always stop it.

Everything in here is a hard requirement, not a preference:

  * no code path starts mining before a recorded agreement exists
  * the user's "no" and "stop" are final, and survive reboots
  * the notification exists, cannot be silenced, and carries Stop
  * the app owner's wallet is the only wallet, and the user is never asked for one
  * a reboot resumes only what the user already agreed to and has not stopped

Opinionated, cosmetic or capability checks (default wording, channel branding,
example-app taste, health-check plumbing, XML validity) deliberately live in
tools/checks_optional.py and are NOT part of the build. This file stays small
enough to read in one sitting, so nothing here can quietly stop being true.

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
    """Look at code, not at prose about the rules."""
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


def body_after(src, marker, length=4000):
    """The code following a marker — used to inspect one method, not the file."""
    i = src.find(marker)
    return src[i:i + length] if i >= 0 else ''


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
                yield os.path.relpath(p, PKG), strip_comments(open(p, encoding='utf-8').read(), True)


def main():
    print('guardrails: mining must never be silent, hidden or unasked\n')

    consent = code('lib/src/consent.dart')
    sdk = code('lib/sugar_miner_sdk.dart')
    start = body_after(sdk, 'Future<MinerStartResult> start(')
    cfg = code('lib/src/sugar_config.dart')
    disc = code('lib/src/disclosure.dart')
    style = code('lib/src/notification_style.dart')
    policy = code('lib/src/policy.dart')
    bridge = code('lib/src/service_bridge.dart')
    service = code('android/src/main/kotlin/com/mdk/sugarminer/sdk/SugarMiningService.kt')
    manifest = read('android/src/main/AndroidManifest.xml')
    example = code('example/lib/main.dart')

    # ── 1. consent gates every path that can start mining ────────────────────
    check('the consent store only says yes to the notice/terms the user saw',
          'consentVersion' in consent and 'isGranted' in consent)
    check('the start path checks consent and refuses without it',
          'hasConsent()' in start and 'no consent recorded' in start,
          'SugarMiner.start() must refuse when there is no consent')
    check('consent is checked before the hashing isolate is spawned',
          start.find('hasConsent()') >= 0 and start.find('hasConsent()') < start.find('_spinUp('),
          'consent must be checked before _spinUp(), which spawns the miner')
    check('consent is checked before the notification/service is used to mine',
          start.find('hasConsent()') < start.find('ensureNotificationPermission()'),
          'consent must come before any notification or service start')
    check('auto-start on app launch is behind the same gate',
          'hasConsent()' in body_after(sdk, 'static Future<SugarMiner> install(')
          or 'miner.hasConsent()' in body_after(sdk, 'static Future<SugarMiner> install('),
          'SugarMinerSdk.install() must check consent before starting anything')

    # ── 2. the user's "no" and "stop" are final ─────────────────────────────
    check('a refusal is recorded and honoured', 'revoke()' in consent)
    check('a user "stop" cannot be undone by the SDK itself',
          'markStoppedByUser' in consent and 'stoppedByUser' in sdk)
    check('the stop button in the notification writes that same flag',
          'PREF_STOPPED_BY_USER' in service and 'flutter.sugar_sdk_user_stopped' in service)

    # ── 3. the wallet is the app owner's, and nobody else's ────────────────
    check('the payout address is required configuration',
          'required this.payoutAddress' in cfg)
    check('the payout address has no setter',
          'set payoutAddress' not in cfg
          and 'payoutAddress =' not in body_after(cfg, 'class SugarConfig', 900))
    check('the SDK never asks the user for a wallet',
          'labelText' not in example or 'wallet' not in example.lower())
    check('the example sets the owner address in code',
          'kPayoutAddress' in example and 'String.fromEnvironment' in example)

    # ── 4. the disclosure is mandatory ─────────────────────────────────────
    check('the disclosure requires a mining notice, terms and a privacy policy',
          all(k in disc for k in ['miningNotice', 'termsUrl', 'privacyUrl', 'ownerName', 'termsVersion']))
    check('a one-line "we mine" is not enough of a notice',
          'miningNotice.trim().length >= 40' in disc,
          'the notice must be a real sentence, not a word')
    check('changing the notice or terms asks the user again',
          'consentVersion' in disc and 'noticeVersion' in disc)

    # ── 5. no stealth, anywhere ────────────────────────────────────────────
    forbidden = [
        'stealth', 'cloak', 'disguise', 'covert', 'hideNotification', 'hiddenNotification',
        'noNotification', 'silentMode', 'invisible', 'unseen', 'conceal', 'hideApp',
    ]
    hits = []
    for path, src in list(dart_sources()) + list(kotlin_sources()):
        low = src.lower()
        for word in forbidden:
            if word.lower() in low:
                hits.append(f'{path}: {word}')
    check('no stealth/hidden/silent option exists in the code', not hits,
          'found: ' + ', '.join(hits) + ' — this SDK has no quiet mode, by design')
    check('nothing draws over other apps', 'SYSTEM_ALERT_WINDOW' not in manifest)
    check('no package-visibility snooping', 'QUERY_ALL_PACKAGES' not in manifest)

    # ── 6. the notification exists, and cannot be made invisible ───────────
    check('the default notification wording tells the user mining is happening',
          'mining' in style.lower())
    check('no API can hide, delay or silence the notification',
          not any(k in style.lower() for k in ['hidden', 'silent', 'importance', 'dismiss', 'delay'])
          and not any(k in bridge.lower() for k in ["'importance'", "'ongoing'", "'silent'", "'priority'"]),
          'those are the facts that keep this legal, so they are not parameters')
    check('the Android channel importance is fixed at DEFAULT',
          'NotificationManager.IMPORTANCE_DEFAULT' in service
          and 'IMPORTANCE_MIN' not in service
          and 'IMPORTANCE_NONE' not in service
          and 'IMPORTANCE_LOW' not in service,
          'never MIN/NONE/LOW, whatever the host app asks for')
    check('the notification is ongoing — it cannot be swiped away', 'setOngoing(true)' in service)
    check('the notification always carries a Stop action', 'Stop mining' in service)
    check('the notification taps through to the app', 'getLaunchIntentForPackage' in service)
    check('the notification icon exists',
          os.path.exists(os.path.join(PKG, 'android/src/main/res/drawable-xxhdpi/ic_sugar_miner.png')))

    # ── 7. Android is told, in its own manifest, what is happening ─────────
    check('foreground service type declared', 'foregroundServiceType="specialUse"' in manifest)
    check('the special-use reason is spelled out', 'PROPERTY_SPECIAL_USE_FGS_SUBTYPE' in manifest)
    check('the service is not exported', 'android:exported="false"' in manifest)

    # ── 8. the agreed limits are enforced by code, not by hope ─────────────
    check('the profiler can never exceed the agreed ceiling',
          'ceilingProfile.dutyShare' in code('lib/src/auto_config.dart')
          and 'ceiling / 2' in code('lib/src/auto_config.dart'),
          'every auto profile must be at or below MiningPolicy.cpuSharePercent')
    check('the daily time budget is enforced',
          'dailyCapMinutes' in policy and 'minedMinutesToday' in policy)
    check("the user's stop is enforced by the policy engine", 'isStopped' in policy)

    # ── 9. pause/resume happens, and the battery exemption is asked for ────
    check('a pause stops the miner and a resume restarts it',
          'startWhenAllowed' in sdk and '_spinUp(' in sdk and '.stop()' in sdk)
    check('the battery-exemption flow asks the user rather than assuming',
          'requestIgnoreBatteryOptimizations' in bridge)

    # ── 10. restarting the phone must never restart mining behind the user ──
    boot = code('android/src/main/kotlin/com/mdk/sugarminer/sdk/SugarBootReceiver.kt')
    headless = code('android/src/main/kotlin/com/mdk/sugarminer/sdk/HeadlessMinerEngine.kt')
    headless_dart = code('lib/src/headless.dart')

    check('a reboot can resume mining (RECEIVE_BOOT_COMPLETED declared)',
          'RECEIVE_BOOT_COMPLETED' in manifest and 'BOOT_COMPLETED' in manifest)
    check("the boot receiver checks the user's consent first",
          'PREF_CONSENT_GRANTED' in boot
          and boot.find('PREF_CONSENT_GRANTED') < boot.find('startForegroundService'),
          'the boot path must read the consent flag before starting anything')
    check("the boot receiver honours the user's own stop",
          'PREF_STOPPED_BY_USER' in boot
          and boot.find('PREF_STOPPED_BY_USER') < boot.find('startForegroundService'))
    check('the boot receiver refuses to mine without notification permission',
          'canPostNotifications' in boot and 'POST_NOTIFICATIONS' in boot)
    check('no mining happens at locked-boot time (consent would be unreadable)',
          'directBootAware="false"' in manifest and 'LOCKED_BOOT_COMPLETED' not in manifest)
    check('the boot receiver is not exported', 'android:exported="false"' in manifest)
    check('the re-arm alarm is cancelled when the user stops mining',
          'cancelReArm' in service and 'cancelReArm' in boot)
    check("re-arming never outlives the user's stop",
          'armReArm' in service and 'PREF_STOPPED_BY_USER' in service)
    check('a headless run still registers plugins (so the miner really runs)',
          'GeneratedPluginRegistrant' in headless)
    check('the headless engine does nothing without a registered entrypoint',
          'PREF_BOOT_CALLBACK' in headless and 'handle <= 0L' in headless,
          'no entrypoint registered means no resume — never a guess')
    check('registration tells the truth when it fails',
          'return false' in headless_dart and 'vm:entry-point' in read('lib/src/headless.dart'))
    check('the restart promise the app shows the user is computed, not hard-coded',
          'restartBehaviour' in sdk and 'restartBehaviour' in headless_dart)

    # ── 10b. the "no Dart" native path is held to the same rules ───────────
    native = code('android/src/main/kotlin/com/mdk/sugarminer/sdk/SugarMinerNative.kt')
    boot_dart = code('lib/src/native_boot.dart')

    check('the native installer shows its own consent dialog before anything runs',
          'AlertDialog' in native and 'Agree and start' in native and 'No thanks' in native,
          'an app that writes no Dart still has to ask its user, in words')
    check('the native consent writes the same key and version the Dart store reads',
          'PREF_CONSENT_GRANTED' in native
          and 'flutter.sugar_sdk_consent_version' in native
          and '"$noticeVersion|terms:$termsVersion|privacy:$privacyUrl"' in native,
          'two stores with two ideas of "the user agreed" is how consent gets lost')
    native_start = body_after(native, 'private fun startMining', 1200)
    check('the native path cannot start mining without a recorded consent',
          'consentRecorded(context, config.consentVersion)' in native_start
          and 'return' in native_start,
          'startMining() must re-check the prefs, not trust its caller')
    check('the native path refuses to mine without notification permission',
          'POST_NOTIFICATIONS' in native_start and 'PERMISSION_GRANTED' in native_start
          and 'return' in native_start,
          'silent mining is the one thing this SDK never does, native path included')
    check('a native "no thanks" is recorded and not asked again',
          'consent_refused' in native and 'fun refused(' in native)
    check('metadata that is missing or unusable stops the installer dead',
          'return null' in native and 'notice.length < 40' in native,
          'no address and no real notice means no mining, not a guess')
    check('the SDK entrypoint refuses without a valid payout address',
          'sugar1|tugar1' in boot_dart and 'return null' in boot_dart)
    check('the SDK entrypoint carries the tree-shake guard',
          '@pragma(\'vm:entry-point\')' in read('lib/src/native_boot.dart'))
    check('the native installer can stop mining for good, and does',
          'fun stop(' in native and 'cancelReArm' in native and 'ACTION_STOP_BY_USER' in native)

    # ── 11. the example can be trusted as documentation ────────────────────
    check('the example shows no user-facing mining configuration',
          '_address' not in example and 'TextField' not in example,
          'a host app must not expose mining knobs to the end user')

    print()
    if FAILURES:
        print(f'{len(FAILURES)} guardrail(s) FAILED:')
        for name, why in FAILURES:
            print(f'  - {name}: {why}' if why else f'  - {name}')
        print('\nIf you are adding a "quiet" or "hidden" mode: that is the one thing')
        print('this SDK will not ship. Mining without the device owner knowing is')
        print('malware, it is illegal in most countries, and it is not a feature.')
        return 1

    print(f'all {len(PASSES)} guardrails pass — mining here is consented and visible')
    return 0


if __name__ == '__main__':
    sys.exit(main())
