#!/usr/bin/env python3
"""End-to-end test: the wrap engine and the HTTP surface.

    python3 minehub/test_server.py
"""
import io
import json
import os
import sys
import tempfile
import threading
import urllib.parse
import urllib.request
import uuid
import zipfile
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import server as S  # noqa: E402

PASS, FAIL = [], []


def ok(name, cond, note=''):
    (PASS if cond else FAIL).append(name)
    print(f'  {"✓" if cond else "✗"} {name}' + (f'  ({note})' if note and not cond else ''))


def make_flutter_zip(path, nested=True):
    root = 'myapp/' if nested else ''
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr(root + 'pubspec.yaml', 'name: myapp\ndescription: test\n'
                   'environment:\n  sdk: ">=3.4.0 <4.0.0"\ndependencies:\n  flutter:\n'
                   '    sdk: flutter\n')
        z.writestr(root + 'lib/main.dart', """import 'package:flutter/material.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp(home: Text('hi'));
}
""")
        z.writestr(root + 'README.md', '# myapp\n')
        z.writestr(root + 'android/app/build.gradle', '// placeholder\n')
        z.writestr(root + 'android/app/src/main/AndroidManifest.xml',
                   '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
                   '    <application android:label="myapp">\n'
                   '    </application>\n</manifest>\n')
        z.writestr(root + 'android/app/src/main/kotlin/com/example/myapp/MainActivity.kt',
                   MAIN_ACTIVITY)


def make_apk_zip(path):
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('AndroidManifest.xml', b'\x03\x00\x08\x00binary xml')
        z.writestr('classes.dex', b'dex\n035\x00fake')
        z.writestr('resources.arsc', b'fake')


META = {
    'address': 'sugar1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4',
    'app_name': 'Sweet Widgets', 'owner_name': 'Sweet Widgets Ltd',
    'terms_url': 'https://example.com/terms', 'terms_version': '2026-01-15',
    'privacy_url': 'https://example.com/privacy',
    'cpu_share': 25, 'daily_cap': 480, 'require_unmetered': True,
    'mining_notice': 'Sweet Widgets mines a little SUGAR in the background to keep the '
                     'app free. It shows a notification the whole time and you can stop it.',
    'notice_version': '1.0.0',
}

MAIN_ACTIVITY = '''package com.example.myapp

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
}
'''


def main():
    tmp = tempfile.mkdtemp(prefix='minehub-test-')

    print('wrap: a Flutter project, full mode (config in Dart, hook in main)')
    fz = os.path.join(tmp, 'project.zip')
    make_flutter_zip(fz)
    res = S.wrap_zip(fz, META, 'full')
    ok('wrap succeeded', res.get('ok'), res.get('error'))
    if res.get('ok'):
        ok('detected project name', res['project'] == 'myapp', res.get('project'))
        ok('all steps ok', all(s['status'] == 'ok' for s in res['steps']),
           str([s for s in res['steps'] if s['status'] != 'ok']))
        wz = os.path.join(S.WORK, res['id'], 'wrapped.zip')
        z = zipfile.ZipFile(wz)
        names = z.namelist()
        ok('setup file inside', 'myapp/lib/sugar_miner_setup.dart' in names)
        ok('workflow inside', 'myapp/.github/workflows/sugar-apk.yml' in names)
        ok('integration notes inside', 'myapp/SUGAR-INTEGRATION.md' in names)
        ok('report inside', 'myapp/sugar-wrap-report.json' in names)
        setup = z.read('myapp/lib/sugar_miner_setup.dart').decode()
        ok('address baked in', META['address'] in setup)
        ok('disclosure used', 'MiningDisclosure.donation' in setup)
        ok('headless entrypoint pragma', "@pragma('vm:entry-point')" in setup)
        main_dart = z.read('myapp/lib/main.dart').decode()
        ok('import added', "import 'sugar_miner_setup.dart';" in main_dart)
        ok('main made async', 'Future<void> main() async {' in main_dart, main_dart[:120])
        ok('attach awaited', 'await sugarMinerAttach();' in main_dart)
        ok('attach is the first statement',
           main_dart.index('await sugarMinerAttach();') < main_dart.index('runApp('))
        ok('rest of the file intact', 'class MyApp extends StatelessWidget' in main_dart)
        pubspec = z.read('myapp/pubspec.yaml').decode()
        ok('dependency added under dependencies:',
           '  sugar_miner_sdk:' in pubspec and 'git:' in pubspec)
        ok('yaml still has the flutter dep', 'flutter:\n    sdk: flutter' in pubspec, pubspec)

    print('\nclean mode: the app code must be untouched except two lines')
    fz_clean = os.path.join(tmp, 'clean.zip')
    make_flutter_zip(fz_clean)
    res_clean = S.wrap_zip(fz_clean, META, 'clean')
    ok('clean wrap succeeded', res_clean.get('ok'), res_clean.get('error'))
    if res_clean.get('ok'):
        import hashlib
        ok('mode reported', res_clean['mode'] == 'clean')
        z = zipfile.ZipFile(os.path.join(S.WORK, res_clean['id'], 'wrapped.zip'))
        main_dart = z.read('myapp/lib/main.dart').decode()
        original_dart = zipfile.ZipFile(fz_clean).read('myapp/lib/main.dart').decode()
        ok('main.dart gained exactly one import line',
           len(main_dart.splitlines()) == len(original_dart.splitlines()) + 1,
           f'{len(original_dart.splitlines())} -> {len(main_dart.splitlines())} lines')
        ok('the import is the SDK native_boot library',
           "import 'package:sugar_miner_sdk/native_boot.dart';" in main_dart)
        ok('removing that line restores the file byte-for-byte',
           main_dart.replace("import 'package:sugar_miner_sdk/native_boot.dart';\n", '') == original_dart)
        ok('no generated setup file in clean mode',
           'myapp/lib/sugar_miner_setup.dart' not in z.namelist())

        activity = z.read('myapp/android/app/src/main/kotlin/com/example/myapp/MainActivity.kt').decode()
        ok('MainActivity calls install(this)', 'SugarMinerNative.install(this)' in activity)
        ok('MainActivity imports the installer',
           'import com.mdk.sugarminer.sdk.SugarMinerNative' in activity)
        import difflib
        added = [l[1:] for l in difflib.unified_diff(
            MAIN_ACTIVITY.splitlines(), activity.splitlines(), lineterm='', n=0)
            if l.startswith('+') and not l.startswith('+++')]
        allowed = {'', 'import com.mdk.sugarminer.sdk.SugarMinerNative',
                   '    override fun onCreate(savedInstanceState: android.os.Bundle?) {',
                   '        super.onCreate(savedInstanceState)',
                   '        SugarMinerNative.install(this)',
                   '    }'}
        ok('every added line in MainActivity is one of the two things we promised',
           set(added) <= allowed, f'unexpected: {sorted(set(added) - allowed)}')
        ok('the class body is otherwise intact', 'class MainActivity : FlutterActivity()' in activity)
        ok('the install call is inside onCreate',
           activity.index('override fun onCreate') < activity.index('SugarMinerNative.install(this)'))

        manifest = z.read('myapp/android/app/src/main/AndroidManifest.xml').decode()
        ok('manifest carries the payout address',
           'com.mdk.sugarminer.PAYOUT_ADDRESS' in manifest and META['address'] in manifest)
        ok('manifest carries the notice the user will be shown',
           'com.mdk.sugarminer.MINING_NOTICE' in manifest)
        ok('manifest carries the policy too',
           'com.mdk.sugarminer.CPU_SHARE_PERCENT' in manifest)

        report = json.loads(z.read('myapp/sugar-wrap-report.json').decode())
        ok('the report says how many files were untouched', report['untouchedFiles'] >= 3,
           str(report['untouchedFiles']))
        ok('the report lists the changed files with line counts',
           all('linesAdded' in c for c in report['changes']) and len(report['changes']) >= 3)
        ok('the report records a hash of every file', len(report['allFiles']) >= 6)

        notes = z.read('myapp/SUGAR-INTEGRATION.md').decode()
        ok('the notes state the mode', 'Mode: **clean**' in notes)
        ok('the notes forbid hiding the notification', 'hide the notification' in notes.lower())

        # wrapping the wrapped project again must not double anything
        again = os.path.join(S.WORK, res_clean['id'], 'wrapped.zip')
        res_again = S.wrap_zip(again, META, 'clean')
        ok('re-wrapping is idempotent', res_again.get('ok'), res_again.get('error'))
        if res_again.get('ok'):
            z2 = zipfile.ZipFile(os.path.join(S.WORK, res_again['id'], 'wrapped.zip'))
            m2 = z2.read('myapp/lib/main.dart').decode()
            a2 = z2.read('myapp/android/app/src/main/kotlin/com/example/myapp/MainActivity.kt').decode()
            ok('no duplicate import', m2.count('native_boot.dart') == 1)
            ok('no duplicate install call', a2.count('SugarMinerNative.install(this)') == 1)

    print('\nwrap: a compiled APK is refused, with the reason')
    apk = os.path.join(tmp, 'app-release.apk')
    make_apk_zip(apk)
    res2 = S.wrap_zip(apk, META)
    ok('refused', not res2.get('ok'))
    ok('classified as a compiled apk', res2.get('kind') == 'compiled-apk', res2.get('kind'))
    ok('explains re-signing', 're-signing' in (res2.get('error') or ''))

    print('\nwrap: a random zip is refused')
    rz = os.path.join(tmp, 'random.zip')
    with zipfile.ZipFile(rz, 'w') as z:
        z.writestr('holiday/photo.jpg', b'not a project')
    res3 = S.wrap_zip(rz, META)
    ok('refused', not res3.get('ok'))
    ok('says it needs pubspec.yaml', 'pubspec.yaml' in (res3.get('error') or ''))

    print('\nwrap: a project whose main() is already async and hooked')
    fz2 = os.path.join(tmp, 'again.zip')
    make_flutter_zip(fz2, nested=False)
    with zipfile.ZipFile(fz2) as zin:                       # wrap it, then wrap the result
        data = {n: zin.read(n) for n in zin.namelist()}
    rz2 = os.path.join(tmp, 'again2.zip')
    with zipfile.ZipFile(rz2, 'w') as z:
        for n, b in data.items():
            z.writestr(n, b)
    r1 = S.wrap_zip(rz2, META, 'full')
    second = os.path.join(S.WORK, r1['id'], 'wrapped.zip')
    r2 = S.wrap_zip(second, META, 'full')
    ok('second wrap still succeeds', r2.get('ok'), r2.get('error'))
    if r2.get('ok'):
        z = zipfile.ZipFile(os.path.join(S.WORK, r2['id'], 'wrapped.zip'))
        m = z.read('lib/main.dart').decode()
        ok('no duplicate attach call', m.count('await sugarMinerAttach();') == 1, m[:200])
        ok('no duplicate import', m.count("import 'sugar_miner_setup.dart';") == 1)

    print('\naddress validation mirrors the SDK')
    ok('accepts sugar1…', S.sdk_check(META['address']))
    ok('rejects empty', not S.sdk_check(''))
    ok('rejects a bitcoin address', not S.sdk_check('bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4'))
    ok('accepts tugar1… testnet', S.sdk_check('tugar1q' + 'x' * 30))

    print('\nHTTP surface')
    port = 8099
    srv = ThreadingHTTPServer(('127.0.0.1', port), S.Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{port}'

    body = urllib.request.urlopen(base + '/', timeout=10).read().decode()
    ok('index.html served and self-contained', 'SugarWallet' in body and 'http://' not in
       body.split('<style>')[0], f'{len(body)} bytes')

    h = json.loads(urllib.request.urlopen(base + '/api/health', timeout=10).read())
    ok('/api/health', h.get('ok') is True)

    bad = urllib.request.Request(base + '/api/pool?address=nonsense')
    try:
        urllib.request.urlopen(bad, timeout=10)
        ok('bad address rejected', False)
    except urllib.error.HTTPError as e:
        ok('bad address rejected', e.code == 400)

    q = urllib.parse.urlencode({
        'address': META['address'], 'app': 'Sweet Widgets', 'owner': 'Sweet Widgets Ltd',
        'terms': 'https://example.com/terms', 'privacy': 'https://example.com/privacy',
        'cpu': '25', 'cap': '480', 'unmetered': '1'})
    fz3 = os.path.join(tmp, 'http.zip')
    make_flutter_zip(fz3)
    req = urllib.request.Request(base + '/api/wrap?' + q, data=open(fz3, 'rb').read(),
                                method='POST')
    r = json.loads(urllib.request.urlopen(req, timeout=60).read())
    ok('upload wrapped over HTTP', r.get('ok'), r.get('error'))
    if r.get('ok'):
        dl = urllib.request.urlopen(base + r['download'], timeout=30).read()
        ok('download is a zip', dl[:2] == b'PK', dl[:4])
        z = zipfile.ZipFile(io.BytesIO(dl))
        ok('downloaded zip has the SDK attached in clean mode',
           "import 'package:sugar_miner_sdk/native_boot.dart';" in z.read('myapp/lib/main.dart').decode()
           and 'SugarMinerNative.install(this)' in
           z.read('myapp/android/app/src/main/kotlin/com/example/myapp/MainActivity.kt').decode())
        ok('and the manifest carries the address',
           META['address'] in z.read('myapp/android/app/src/main/AndroidManifest.xml').decode())

    apkq = urllib.request.Request(base + '/api/wrap?' + q, data=open(apk, 'rb').read(),
                                 method='POST')
    try:
        urllib.request.urlopen(apkq, timeout=30)
        ok('APK upload rejected over HTTP', False)
    except urllib.error.HTTPError as e:
        d = json.loads(e.read())
        ok('APK upload rejected over HTTP', e.code == 400 and d.get('kind') == 'compiled-apk')


    print('\nthe fleet view (one address per device)')
    ok('a fleet list parses labels and addresses',
       S.fleet_parse('Kitchen tablet = ' + META['address'])[0] ==
       [('Kitchen tablet', META['address'])])
    ok('blank lines and comments are ignored',
       S.fleet_parse('\n# a note\n' + META['address'] + '\n')[0][0][1] == META['address'])
    ok('a line that is not an address is rejected, not silently dropped',
       S.fleet_parse('nonsense=' + META['address'] + '\nnot-an-address')[1] == ['not-an-address'])

    # The fleet endpoint, against a stubbed pool so the test does not depend on
    # somebody else's API being up. Two addresses: one mining, one answering with
    # nothing — which is what a paused phone looks like.
    real_lookup = S.pool_lookup
    quiet = 'sugar1q' + 'q' * 38

    def fake_lookup(address):
        if address == META['address']:
            return {'sources': [{'name': 'PooLab', 'endpoint': 'x', 'totalHashrate': 250.0,
                                 'totalShares': 7, 'balance': 0.25, 'paid': 1.5,
                                 'immature': 0.05,
                                 'workers': [{'name': 'w1'}, {'name': 'w2'}]}],
                    'errors': []}
        return {'sources': [], 'errors': ['PooLab: timeout']}

    S.pool_lookup = fake_lookup
    try:
        fl = urllib.parse.quote('# my fleet\nFront desk = ' + META['address'] +
                                '\nBack room = ' + quiet)
        d = json.loads(urllib.request.urlopen(base + '/api/fleet?list=' + fl, timeout=15).read())
        a = d['aggregate']
        ok('fleet aggregates the addresses it could reach', d['ok'] and a['addresses'] == 2
           and a['reachable'] == 1, json.dumps(a))
        ok('fleet adds up hashrate, shares and money',
           a['hashrate'] == 250.0 and a['shares'] == 7 and abs(a['balance'] - 0.25) < 1e-9
           and a['workers'] == 2, json.dumps(a))
        ok('an address the pool does not answer for is a row, not a crash',
           len(d['rows']) == 2 and sum(1 for r in d['rows'] if not r['reachable']) == 1
           and d['rows'][0]['label'] == 'Front desk')
        ok('rows are sorted by hashrate, so the busiest device is first',
           d['rows'][0]['hashrate'] == 250.0)
    finally:
        S.pool_lookup = real_lookup

    try:
        urllib.request.urlopen(base + '/api/fleet?list=', timeout=10)
        ok('an empty fleet is refused', False)
    except urllib.error.HTTPError as e:
        ok('an empty fleet is refused', e.code == 400)

    try:
        many = urllib.parse.quote('\n'.join('sugar1q' + 'z' * 38 for _ in range(30)))
        urllib.request.urlopen(base + '/api/fleet?list=' + many, timeout=10)
        ok('a fleet larger than the limit is refused', False)
    except urllib.error.HTTPError as e:
        ok('a fleet larger than the limit is refused', e.code == 400)

    print('\nthe engine revision the platform bakes into other people\'s apps')
    import wrapper as W
    ok('the wrap service is pinned to a tag, not main',
       S.SDK_REF != 'main' and W.SDK_REF != 'main', S.SDK_REF)
    ok('/api/health reports the pinned tag',
       json.loads(urllib.request.urlopen(base + '/api/health', timeout=10).read())
       .get('ref') == W.SDK_REF)
    ok('server.py and wrapper.py agree on the tag', S.SDK_REF == W.SDK_REF,
       f'{S.SDK_REF} vs {W.SDK_REF}')

    srv.shutdown()
    print(f'\n{len(PASS)} passed, {len(FAIL)} failed')
    if FAIL:
        print('failed: ' + ', '.join(FAIL))
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main())
