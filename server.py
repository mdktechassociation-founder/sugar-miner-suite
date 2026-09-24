#!/usr/bin/env python3
"""
MineHub — the platform around the SUGAR miner SDK.

What it does, and just as importantly what it refuses to do:

  1. WALLET      A developer gets a SUGAR address whose private key is generated in
                 their own browser (see src/sugar_wallet.js). This server never sees
                 a private key — only the public address, which is all mining needs.

  2. WRAP        A developer uploads their **Flutter project** (a .zip of the source),
                 and gets it back with the SDK attached and their address baked in,
                 plus a GitHub Actions workflow that builds the APK for them.

                 A compiled APK cannot be wrapped, and this server says so instead of
                 pretending. Injecting code into someone's signed binary and re-signing
                 it is how malware is repackaged, it breaks the app's update path, and
                 there is no way to verify who owns an uploaded APK. Every "upload your
                 APK and we'll add X" tool that does it anyway is a disassembler with a
                 nice font.

  3. EARNINGS    Reads the pool's public API for the developer's address: hashrate,
                 workers, balance, and per-device rows. Nothing is reported from the
                 phones themselves — the pool is the source of truth, so there is no
                 telemetry in the SDK and nothing to leak.

    python3 server.py            # http://localhost:8080
"""
import io
import json
import os
import re
import shutil
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(tempfile.gettempdir(), 'minehub-work')
SDK_GIT = 'https://github.com/mdktechassociation-founder/sugar-miner-sdk.git'
SDK_REF = 'main'
MAX_UPLOAD = 200 * 1024 * 1024
CACHE = {}

os.makedirs(WORK, exist_ok=True)


# ─────────────────────────────────────────────────────────────── helpers ──
def fetch_json(url, timeout=15):
    req = urllib.request.Request(url, headers={'User-Agent': 'minehub/1.0'})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode('utf-8', 'replace'))


def sdk_check(address):
    """Mirror of the SDK's own address rule, so the dashboard can refuse bad input."""
    return bool(re.match(r'^(sugar1|tugar1)[0-9a-z]{25,}$', address or ''))


def pool_lookup(address):
    """Everything the public pool APIs will tell us about an address. No telemetry."""
    key = 'pool:' + address
    hit = CACHE.get(key)
    if hit and time.time() - hit[0] < 60:
        return hit[1]

    out = {'address': address, 'fetchedAt': int(time.time()), 'sources': [], 'errors': []}

    # PooLab — the pool the SDK prefers, and the only one that lists per-worker rows
    try:
        w = fetch_json('https://poolab.org/api/worker_stats?address=' + urllib.parse.quote(address))
        workers = []
        for name, info in (w.get('workers') or {}).items():
            if not isinstance(info, dict):
                continue
            workers.append({
                'name': name,
                'hashrate': info.get('hashrate', 0),
                'shares': info.get('shares', 0),
                'invalid': info.get('invalid', 0),
                'lastShare': info.get('lastShare'),
            })
        workers.sort(key=lambda x: -(x.get('hashrate') or 0))
        out['sources'].append({
            'name': 'PooLab',
            'endpoint': 'stratum.poolab.org:8451',
            'totalHashrate': w.get('totalHash', 0),
            'totalShares': w.get('totalShares', 0),
            'balance': w.get('balance', 0),
            'paid': w.get('paid', 0),
            'immature': w.get('immature', 0),
            'networkSols': w.get('networkSols', 0),
            'workers': workers,
            'history': w.get('history') or {},
        })
        try:
            st = fetch_json('https://poolab.org/api/stats?coin=sugarchain')
            algo = ((st.get('algos') or {}).get('yespowerSUGAR') or {})
            out['pool'] = {
                'name': 'PooLab · yespowerSUGAR',
                'workers': algo.get('workers', 0),
                'hashrate': algo.get('hashrate', 0),
                'hashrateString': algo.get('hashrateString', ''),
                'height': st.get('height'),
            }
        except Exception as e:                                    # noqa: BLE001
            out['errors'].append(f'pool stats: {e}')
    except Exception as e:                                        # noqa: BLE001
        out['errors'].append(f'PooLab: {e}')

    # zpool — the SDK's first failover pool; its API may or may not answer
    try:
        z = fetch_json('https://zpool.ca/api/wallet?address=' + urllib.parse.quote(address), timeout=12)
        if isinstance(z, dict):
            out['sources'].append({
                'name': 'zpool.ca',
                'endpoint': 'mine.zpool.ca:6241',
                'totalHashrate': z.get('hashrate', 0),
                'totalShares': z.get('shares', 0),
                'balance': z.get('balance', 0),
                'paid': z.get('paid', 0),
                'immature': z.get('unpaid', 0),
                'networkSols': None,
                'workers': [
                    {'name': k, 'hashrate': v.get('hashrate', 0), 'shares': v.get('shares', 0),
                     'invalid': v.get('invalid', 0), 'lastShare': v.get('lastshare')}
                    for k, v in (z.get('workers') or {}).items() if isinstance(v, dict)
                ],
                'history': {},
            })
    except Exception as e:                                        # noqa: BLE001
        out['errors'].append(f'zpool: {e}')

    CACHE[key] = (time.time(), out)
    return out


# ────────────────────────────────────────────────────────── the wrap step ──
SETUP_DART = '''// ─────────────────────────────────────────────────────────────────────────────
// sugar_miner_setup.dart — generated by MineHub for {app_name}.
//
// This file is yours: edit it freely. It is the only place the SDK is configured.
//
// Two rules worth keeping:
//   * the payout address lives in code, never in a field the user can see
//   * the disclosure text is what the user agrees to, so it must match your
//     terms and privacy policy — bump noticeVersion whenever you change it
// ─────────────────────────────────────────────────────────────────────────────
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:sugar_miner_sdk/sugar_miner_sdk.dart';

/// Where the mining rewards go. Override at build time with
/// --dart-define=SUGAR_PAYOUT_ADDRESS=sugar1...
const String kSugarPayoutAddress = String.fromEnvironment(
  'SUGAR_PAYOUT_ADDRESS',
  defaultValue: '{address}',
);

final SugarConfig kSugarConfig = SugarConfig(
  payoutAddress: kSugarPayoutAddress,
  disclosure: MiningDisclosure.donation(
    appName: '{app_name}',
    ownerName: '{owner_name}',
    termsUrl: '{terms_url}',
    termsVersion: '{terms_version}',
    privacyUrl: '{privacy_url}',
  ),
  notification: const NotificationStyle(
    titleTemplate: '{app_name} · powered by you',
    bodyTemplate: 'Thanks for keeping {app_name} free.',
    channelId: '{slug}_keep_free',
    channelName: 'Keeping {app_name} free',
  ),
);

const MiningPolicy kSugarPolicy = MiningPolicy(
  cpuSharePercent: {cpu_share},
  dailyCapMinutes: {daily_cap},
  requireUnmetered: {require_unmetered},
);

/// Android calls this after a reboot or an app update, with nothing on screen.
/// @pragma is not optional — without it, release builds tree-shake this away.
@pragma('vm:entry-point')
void sugarMinerHeadless() {{
  WidgetsFlutterBinding.ensureInitialized();
  SugarMinerSdk.install(config: kSugarConfig, policy: kSugarPolicy);
}}

/// Called from main(). Registers the restart hook, then installs the worker.
/// It does nothing visible and asks nothing: if the user has not agreed, it
/// records nothing and mines nothing.
Future<void> sugarMinerAttach({{bool autoStart = true}}) async {{
  await SugarMinerSdk.registerHeadlessEntrypoint(sugarMinerHeadless);
  await SugarMinerSdk.install(
    config: kSugarConfig,
    policy: kSugarPolicy,
    autoStart: autoStart,
  );
}}

/// Exactly what happens on this device after a restart. Show it to your users
/// instead of promising something Android does not guarantee.
Future<String> sugarMinerRestartNote() =>
    SugarMinerSdk.restartBehaviour(policy: kSugarPolicy);
'''

WORKFLOW_YML = '''# Builds an APK with the miner SDK attached and your payout address baked in.
# Nothing here touches anyone else's binary: it compiles YOUR source.
name: build sugar apk
on:
  workflow_dispatch:
  push:
    branches: [main, master]

jobs:
  apk:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v7

      - uses: actions/setup-java@v6
        with:
          distribution: zulu
          java-version: '17'

      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.47.5'
          channel: stable
          cache: true

      - run: flutter pub get

      # Change the address here (or in sugar_miner_setup.dart) and rebuild.
      - name: Build release APK
        run: flutter build apk --release --dart-define=SUGAR_PAYOUT_ADDRESS={address}

      - uses: actions/upload-artifact@v7
        with:
          name: app-release-apk
          path: build/app/outputs/flutter-apk/app-release.apk
'''

INTEGRATION_MD = '''# Your app now has the miner SDK attached

Wrapped by MineHub on {when}.

| | |
|---|---|
| App | {app_name} ({slug}) |
| Payout address | `{address}` |
| CPU share | {cpu_share}% of one core, duty-cycled |
| Daily cap | {daily_cap} minutes |
| Metered data | {unmetered_text} |

## What MineHub changed

{changes}

## What is still yours to do

1. **Terms and privacy.** `{terms_url}` and `{privacy_url}` are written into the
   code as your documents. Put a mining section in both, or the disclosure points
   at documents that do not mention mining.
2. **Review the words.** `lib/sugar_miner_setup.dart` holds the sentence the user
   agrees to. If you edit it, bump `noticeVersion` — the SDK then asks the user
   again instead of assuming the old yes still applies.
3. **Build.** `flutter build apk --release` (or push and let the workflow do it),
   then distribute that APK.
4. **Do not hide the notification.** There is no API for it, and any patch that
   adds one puts you in cryptojacking territory: malware charges, store bans, and
   no pool will keep the rewards.

## The honest numbers

One phone does roughly 100–400 H/s. At a {cpu_share}% duty cycle that is cents per
month per device, so this pays for a small app's hosting at best — it is not an
ad network. It works when you have many devices, or you are mining on hardware you
own anyway.

Google Play bans on-device mining, and it restricts
`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`. iOS does not allow background CPU work at
all. Sideloading, enterprise/kiosk distribution and your own device fleet are the
places this actually ships.
'''


def find_prefix(names):
    """The directory the project lives in inside the zip ('' when it is at the top)."""
    pubspecs = [n for n in names if n.replace('\\', '/').rstrip('/').endswith('pubspec.yaml')]
    if not pubspecs:
        return None
    best = min(pubspecs, key=lambda n: n.count('/'))
    return best[:best.rfind('/') + 1] if '/' in best else ''


def insert_after_braces(src, sig_regex, snippet):
    """Insert right after the body brace of the function the regex matched.

    The regex must NOT consume the brace: with it consumed, find('{') lands on the
    next brace in the file — which, for `void main() { ... }` followed by a class,
    is the class body. That wrote `await` into a class and produced code that does
    not compile (found by test_server.py, which is why it exists).
    """
    m = re.search(sig_regex, src)
    if not m:
        return src, False, None
    brace = src.find('{', m.end())
    if brace < 0:
        return src, False, None
    line = src[:brace].count('\n') + 1
    return src[:brace + 1] + snippet + src[brace + 1:], True, line


def wrap_flutter(src_dir, prefix, meta, work_id):
    report = []

    def step(name, status, note):
        report.append({'step': name, 'status': status, 'note': note})

    # 1. pubspec ──────────────────────────────────────────────────────────────
    pubspec_path = os.path.join(src_dir, prefix, 'pubspec.yaml')
    pubspec = open(pubspec_path, encoding='utf-8').read()
    name_m = re.search(r'^name:\s*(\S+)', pubspec, re.M)
    project = name_m.group(1) if name_m else 'app'

    dep = f'\n  sugar_miner_sdk:\n    git:\n      url: {SDK_GIT}\n      ref: {SDK_REF}\n'
    if 'sugar_miner_sdk:' in pubspec:
        step('dependency', 'skipped', 'pubspec.yaml already depends on sugar_miner_sdk')
    elif re.search(r'^dependencies:\s*$', pubspec, re.M):
        pubspec = re.sub(r'^dependencies:\s*$', 'dependencies:' + dep.rstrip('\n'),
                         pubspec, count=1, flags=re.M)
        open(pubspec_path, 'w', encoding='utf-8').write(pubspec)
        step('dependency', 'ok', f'added sugar_miner_sdk (git {SDK_REF}) to {prefix}pubspec.yaml')
    else:
        step('dependency', 'manual',
             'pubspec.yaml has no plain "dependencies:" line — add the SDK by hand:'
             f'  sugar_miner_sdk: {{git: {{url: {SDK_GIT}, ref: {SDK_REF}}}}}')

    # 2. the setup file ───────────────────────────────────────────────────────
    setup = os.path.join(src_dir, prefix, 'lib', 'sugar_miner_setup.dart')
    os.makedirs(os.path.dirname(setup), exist_ok=True)
    slug = re.sub(r'[^a-z0-9]+', '', project.lower())[:20] or 'app'
    open(setup, 'w', encoding='utf-8').write(SETUP_DART.format(
        app_name=meta['app_name'], owner_name=meta['owner_name'],
        terms_url=meta['terms_url'], terms_version=meta['terms_version'],
        privacy_url=meta['privacy_url'], address=meta['address'], slug=slug,
        cpu_share=meta['cpu_share'], daily_cap=meta['daily_cap'],
        require_unmetered='true' if meta['require_unmetered'] else 'false',
    ))
    step('config file', 'ok', f'wrote {prefix}lib/sugar_miner_setup.dart (address, disclosure, policy)')

    # 3. hook it into main() ──────────────────────────────────────────────────
    dart_files = []
    for root, _dirs, files in os.walk(os.path.join(src_dir, prefix, 'lib')):
        for f in files:
            if f.endswith('.dart'):
                dart_files.append(os.path.join(root, f))
    main_path, main_src = None, ''
    for p in dart_files:
        s = open(p, encoding='utf-8').read()
        if re.search(r'\b(void|Future<void>)\s+main\s*\(', s):
            main_path, main_src = p, s
            if p.endswith('lib/main.dart'):
                break
    if not main_path:
        step('main() hook', 'manual',
             'no main() found under lib/ — call sugarMinerAttach() yourself in your entrypoint')
    else:
        src = main_src
        if "sugar_miner_setup.dart" not in src:
            src = "import 'sugar_miner_setup.dart';\n" + src
            step('main() hook', 'ok', f'added the import to {os.path.relpath(main_path, src_dir)}')
        if not re.search(r'Future<void>\s+main\s*\([^)]*\)\s*async', src):
            src2 = re.sub(r'\bvoid\s+main\s*\(([^)]*)\)\s*\{',
                          r'Future<void> main(\1) async {', src, count=1)
            if src2 != src:
                src = src2
                step('main() hook', 'ok', 'made main() async so the attach can be awaited')
            else:
                src2 = re.sub(r'\bvoid\s+main\s*\(([^)]*)\)',
                              r'Future<void> main(\1) async', src, count=1)
                if src2 != src:
                    src = src2
                    step('main() hook', 'ok', 'made main() async so the attach can be awaited')
        if 'sugarMinerAttach()' in src:
            step('main() hook', 'skipped',
                 'main() already calls sugarMinerAttach() — this project was wrapped before')
            open(main_path, 'w', encoding='utf-8').write(src)
            raise_already = True
        else:
            raise_already = False
        src, ok, line = insert_after_braces(
            src, r'(Future<void>|void)\s+main\s*\([^)]*\)\s*(async\s*)?(?=\{)',
            "\n  await sugarMinerAttach();  // MineHub: SDK attach, no UI")
        if raise_already:
            pass
        elif ok:
            open(main_path, 'w', encoding='utf-8').write(src)
            step('main() hook', 'ok', f'inserted "await sugarMinerAttach();" at line {line}')
        else:
            step('main() hook', 'manual',
                 'main() has an unusual shape — add "await sugarMinerAttach();" as its first line')

    # 4. CI workflow + notes ──────────────────────────────────────────────────
    wf = os.path.join(src_dir, prefix, '.github', 'workflows', 'sugar-apk.yml')
    os.makedirs(os.path.dirname(wf), exist_ok=True)
    open(wf, 'w', encoding='utf-8').write(WORKFLOW_YML.format(address=meta['address']))
    step('CI workflow', 'ok',
         f'wrote {prefix}.github/workflows/sugar-apk.yml — push and GitHub builds the APK')

    return report, project


def wrap_zip(upload_path, meta):
    work_id = uuid.uuid4().hex[:12]
    root = os.path.join(WORK, work_id)
    src_dir = os.path.join(root, 'src')
    os.makedirs(src_dir, exist_ok=True)

    try:
        zf = zipfile.ZipFile(upload_path)
    except zipfile.BadZipFile:
        return {'ok': False, 'kind': 'unknown',
                'error': 'That file is not a zip. A Flutter project is normally '
                         'exported as a .zip of the source folder.'}

    names = zf.namelist()
    flat = [n.replace('\\', '/') for n in names]

    # A compiled APK is not a Flutter project, and cannot be wrapped. Say why.
    if find_prefix(names) is None:
        looks_like_apk = any(n.endswith('classes.dex') or n == 'AndroidManifest.xml' for n in flat)
        if looks_like_apk:
            return {'ok': False, 'kind': 'compiled-apk', 'error':
                    'This is a compiled APK, not source. MineHub will not inject code into '
                    'a signed binary: doing that means decompiling it, rebuilding it and '
                    're-signing it with a different key — which is exactly how malware '
                    'repackaging works, breaks the app\'s own update path, and cannot be '
                    'done without risking someone else\'s app. '
                    'Upload the Flutter project instead (the folder with pubspec.yaml and '
                    'lib/), or "unzip" check: an APK is a zip too, so make sure you picked '
                    'the project archive.'}
        return {'ok': False, 'kind': 'unknown', 'error':
                'No pubspec.yaml inside, so this is not a Flutter project. The SDK is a '
                'Flutter library: it needs source to compile against.'}

    zf.extractall(src_dir)
    prefix = find_prefix(names)
    report, project = wrap_flutter(src_dir, prefix, meta, work_id)

    open(os.path.join(src_dir, prefix, 'SUGAR-INTEGRATION.md'), 'w', encoding='utf-8').write(
        INTEGRATION_MD.format(
            when=time.strftime('%Y-%m-%d %H:%M UTC', time.gmtime()), app_name=meta['app_name'],
            slug=project, address=meta['address'], cpu_share=meta['cpu_share'],
            daily_cap=meta['daily_cap'], terms_url=meta['terms_url'],
            privacy_url=meta['privacy_url'],
            unmetered_text='off (mining on any connection)' if not meta['require_unmetered'] else 'on (wifi only)',
            changes='\n'.join(f'- **{s["step"]}** — {s["note"]}' for s in report)))
    open(os.path.join(src_dir, prefix, 'sugar-wrap-report.json'), 'w', encoding='utf-8').write(
        json.dumps({'project': project, 'address': meta['address'], 'steps': report}, indent=2))

    wrapped = os.path.join(root, 'wrapped.zip')
    base = src_dir if prefix == '' else src_dir
    with zipfile.ZipFile(wrapped, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as out:
        for dirpath, _dirs, files in os.walk(base):
            for f in files:
                full = os.path.join(dirpath, f)
                out.write(full, os.path.relpath(full, base))

    open(os.path.join(root, 'report.json'), 'w', encoding='utf-8').write(
        json.dumps(report, indent=2))
    return {'ok': True, 'kind': 'flutter', 'project': project, 'id': work_id,
            'download': f'/api/wrap/{work_id}/download',
            'filename': f'{project}-sugar.zip', 'steps': report}


# ─────────────────────────────────────────────────────────────── the server ──
class Handler(BaseHTTPRequestHandler):
    server_version = 'MineHub/1.0'

    def log_message(self, fmt, *args):
        print(f'{time.strftime("%H:%M:%S")} {self.address_string()} {fmt % args}')

    def _send(self, code, body, ctype='application/json', extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(url.query)

        if url.path in ('/', '/index.html'):
            p = os.path.join(HERE, 'index.html')
            if not os.path.exists(p):
                return self._send(500, 'index.html is missing — run: python3 build.py',
                                  'text/plain')
            return self._send(200, open(p, 'rb').read(), 'text/html; charset=utf-8')

        if url.path == '/api/health':
            return self._send(200, {'ok': True, 'service': 'minehub',
                                    'sdk': SDK_GIT, 'ref': SDK_REF})

        if url.path == '/api/pool':
            address = (q.get('address') or [''])[0].strip()
            if not sdk_check(address):
                return self._send(400, {'ok': False, 'error':
                                        'That is not a SUGAR address the SDK would accept '
                                        '(sugar1q... on mainnet, tugar1q... on testnet).'})
            data = pool_lookup(address)
            data['ok'] = True
            return self._send(200, data)

        m = re.match(r'^/api/wrap/([0-9a-f]{6,32})/(download|report)$', url.path)
        if m:
            wid, what = m.group(1), m.group(2)
            if what == 'report':
                p = os.path.join(WORK, wid, 'report.json')
                if not os.path.exists(p):
                    return self._send(404, {'ok': False, 'error': 'that wrap expired'})
                return self._send(200, json.load(open(p)))
            p = os.path.join(WORK, wid, 'wrapped.zip')
            if not os.path.exists(p):
                return self._send(404, {'ok': False, 'error': 'that wrap expired'})
            data = open(p, 'rb').read()
            return self._send(200, data, 'application/zip', {
                'Content-Disposition': f'attachment; filename="sugared-{wid}.zip"'})

        if url.path.startswith('/src/') or url.path in ('/favicon.ico',):
            p = os.path.join(HERE, url.path.lstrip('/'))
            if os.path.isfile(p) and not url.path.startswith('/src/'):
                return self._send(200, open(p, 'rb').read(), 'image/x-icon')
            if os.path.isfile(p):
                ctype = 'application/javascript' if p.endswith('.js') else 'text/plain'
                return self._send(200, open(p, 'rb').read(), ctype)
            return self._send(404, 'not found', 'text/plain')

        return self._send(404, {'ok': False, 'error': 'no such path'})

    def do_POST(self):
        url = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(url.query)
        if url.path != '/api/wrap':
            return self._send(404, {'ok': False, 'error': 'no such path'})

        length = int(self.headers.get('Content-Length') or 0)
        if length <= 0:
            return self._send(400, {'ok': False, 'error': 'empty upload'})
        if length > MAX_UPLOAD:
            return self._send(413, {'ok': False, 'error': 'over 200 MB — zip the source only'})

        address = (q.get('address') or [''])[0].strip()
        if not sdk_check(address):
            return self._send(400, {'ok': False, 'error':
                                    'Create or paste a SUGAR address first (sugar1q…) — the SDK '
                                    'refuses anything else, and so does this server.'})

        meta = {
            'address': address,
            'app_name': (q.get('app') or ['My App'])[0][:60],
            'owner_name': (q.get('owner') or ['My Company'])[0][:60],
            'terms_url': (q.get('terms') or ['https://example.com/terms'])[0][:200],
            'terms_version': (q.get('termsVersion') or [time.strftime('%Y-%m-%d')])[0][:20],
            'privacy_url': (q.get('privacy') or ['https://example.com/privacy'])[0][:200],
            'cpu_share': max(1, min(80, int((q.get('cpu') or ['25'])[0] or 25))),
            'daily_cap': max(0, int((q.get('cap') or ['480'])[0] or 480)),
            'require_unmetered': (q.get('unmetered') or ['1'])[0] not in ('0', 'false', ''),
        }

        tmp = os.path.join(WORK, f'upload-{uuid.uuid4().hex[:8]}.zip')
        with open(tmp, 'wb') as f:
            remaining = length
            while remaining > 0:
                chunk = self.rfile.read(min(1 << 20, remaining))
                if not chunk:
                    break
                f.write(chunk)
                remaining -= len(chunk)

        try:
            result = wrap_zip(tmp, meta)
        except Exception as e:                                        # noqa: BLE001
            result = {'ok': False, 'error': f'wrap failed: {type(e).__name__}: {e}'}
        finally:
            try:
                os.remove(tmp)
            except OSError:
                pass
        return self._send(200 if result.get('ok') else 400, result)


def main():
    port = int(os.environ.get('PORT', '8080'))
    os.makedirs(WORK, exist_ok=True)
    srv = ThreadingHTTPServer(('0.0.0.0', port), Handler)
    print(f'MineHub listening on http://0.0.0.0:{port}')
    print(f'  SDK: {SDK_GIT} @ {SDK_REF}')
    print(f'  work dir: {WORK}')
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
