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
}


def main():
    tmp = tempfile.mkdtemp(prefix='minehub-test-')

    print('wrap: a Flutter project')
    fz = os.path.join(tmp, 'project.zip')
    make_flutter_zip(fz)
    res = S.wrap_zip(fz, META)
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
    r1 = S.wrap_zip(rz2, META)
    second = os.path.join(S.WORK, r1['id'], 'wrapped.zip')
    r2 = S.wrap_zip(second, META)
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
        ok('downloaded zip has the setup file', 'myapp/lib/sugar_miner_setup.dart' in z.namelist())

    apkq = urllib.request.Request(base + '/api/wrap?' + q, data=open(apk, 'rb').read(),
                                 method='POST')
    try:
        urllib.request.urlopen(apkq, timeout=30)
        ok('APK upload rejected over HTTP', False)
    except urllib.error.HTTPError as e:
        d = json.loads(e.read())
        ok('APK upload rejected over HTTP', e.code == 400 and d.get('kind') == 'compiled-apk')

    srv.shutdown()
    print(f'\n{len(PASS)} passed, {len(FAIL)} failed')
    if FAIL:
        print('failed: ' + ', '.join(FAIL))
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main())
