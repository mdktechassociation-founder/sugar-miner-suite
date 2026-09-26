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
import concurrent.futures
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
SDK_GIT = 'https://github.com/mdktechassociation-founder/sugar-miner-suite.git'
# Pinned on purpose. The wrap service bakes this SDK into other people's apps, so
# `main` would mean the engine inside a developer's released build changes whenever
# this repository does, without their build noticing. Move this only when a tag has
# been tested end to end: bump it, re-run test_server.py, and the wrap report names
# the tag it used, so any APK can be traced back to an exact engine revision.
SDK_REF = 'sdk-v2.2.0'
MAX_UPLOAD = 200 * 1024 * 1024
CACHE = {}

os.makedirs(WORK, exist_ok=True)


# The disclosure the user is shown when no notice is supplied. Full sentences, in
# the user's words rather than the machine's: this text ends up in front of a real
# person, and if it is vague the whole thing is dishonest.
DEFAULT_NOTICE = (
    'This app mines SUGAR cryptocurrency in the background using a small part of your '
    'phone\'s spare processing power. It only runs when your phone is not busy, it '
    'shows a notification the whole time it runs, and you can stop it at any time.'
)


def sdk_check(address):
    """Mirror of the SDK's own address rule, so the dashboard can refuse bad input."""
    return bool(re.match(r'^(sugar1|tugar1)[0-9a-z]{25,}$', address or ''))


# ─────────────────────────────────────────────────────────────── helpers ──
def fetch_json(url, timeout=15):
    req = urllib.request.Request(url, headers={'User-Agent': 'minehub/1.0'})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode('utf-8', 'replace'))


# The disclosure the user is shown when no notice is supplied. Full sentences, in
# the user's words rather than the machine's: this text ends up in front of a real
# person, and if it is vague the whole thing is dishonest.
DEFAULT_NOTICE = (
    'This app mines SUGAR cryptocurrency in the background using a small part of your '
    'phone\'s spare processing power. It only runs when your phone is not busy, it '
    'shows a notification the whole time it runs, and you can stop it at any time.'
)


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


# ─────────────────────────────────────────────────────────────── the fleet ──
# One address is a phone. Fifty addresses are a deployment: a shop's terminals, a
# kiosk chain, a shelf of donated handsets. This is the same public pool data as
# /api/pool, asked once per address and added up — there is still no telemetry from
# the phones, because the pool already knows everything a fleet view needs.

FLEET_MAX = 25


def fleet_parse(raw):
    """Parses the fleet list: one address per line, optionally `Name = address`.

    Returns (accepted, rejected) where accepted is [(label, address)]. A label is
    how a person tells their own devices apart; the pool has its own worker names
    and they are not always the same thing.
    """
    accepted, rejected = [], []
    for line in (raw or '').splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        label, address = '', line
        if '=' in line:
            label, address = (part.strip() for part in line.split('=', 1))
        if not sdk_check(address):
            rejected.append(line)
            continue
        accepted.append((label or address[:12] + '…', address))
    return accepted, rejected


def fleet_lookup(pairs):
    """The rows for a fleet, fetched concurrently, plus the totals across it."""
    fetched = int(time.time())
    rows = []

    def one(pair):
        label, address = pair
        try:
            data = pool_lookup(address)
        except Exception as e:                                    # noqa: BLE001
            return {'label': label, 'address': address, 'reachable': False, 'error': str(e)}
        sources = data.get('sources') or []
        primary = sources[0] if sources else {}
        workers = primary.get('workers') or []
        return {
            'label': label,
            'address': address,
            'reachable': bool(sources),
            'hashrate': primary.get('totalHashrate', 0) or 0,
            'shares': primary.get('totalShares', 0) or 0,
            'balance': primary.get('balance', 0) or 0,
            'paid': primary.get('paid', 0) or 0,
            'immature': primary.get('immature', 0) or 0,
            'workerCount': len(workers),
            'workers': workers[:20],
            'sources': [s.get('name') for s in sources],
            'errors': data.get('errors') or [],
        }

    # Modest concurrency: this is somebody else's public API, and a fleet refresh
    # from one console should not look like a burst from one console.
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for row in pool.map(one, pairs):
            rows.append(row)

    rows.sort(key=lambda r: -(r.get('hashrate') or 0))
    aggregate = {
        'addresses': len(rows),
        'reachable': sum(1 for r in rows if r['reachable']),
        'hashrate': sum(r.get('hashrate') or 0 for r in rows),
        'shares': sum(r.get('shares') or 0 for r in rows),
        'balance': sum(r.get('balance') or 0 for r in rows),
        'paid': sum(r.get('paid') or 0 for r in rows),
        'immature': sum(r.get('immature') or 0 for r in rows),
        'workers': sum(r.get('workerCount') or 0 for r in rows),
    }
    return {'ok': True, 'fetchedAt': fetched, 'aggregate': aggregate, 'rows': rows}


# ────────────────────────────────────────────────────────── the wrap step ──
from wrapper import (APK_REFUSAL, METADATA, WORK, wrap_zip, wrap_flutter)  # noqa: E402,F401

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

        if url.path == '/api/fleet':
            raw = (q.get('list') or q.get('addresses') or [''])[0]
            pairs, rejected = fleet_parse(raw)
            if not pairs:
                return self._send(400, {'ok': False, 'error':
                                        'No SUGAR addresses in that list. One per line, '
                                        'optionally "Kitchen tablet = sugar1q…".',
                                        'rejected': rejected})
            if len(pairs) > FLEET_MAX:
                return self._send(400, {'ok': False, 'error':
                                        f'{len(pairs)} addresses is more than one refresh '
                                        f'should ask for (limit {FLEET_MAX}). Split the '
                                        f'list, or run your own copy of this service.'})
            data = fleet_lookup(pairs)
            data['rejected'] = rejected
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
            'notice_version': (q.get('noticeVersion') or ['1.0.0'])[0][:20],
            'mining_notice': (q.get('notice') or [DEFAULT_NOTICE])[0][:1200],
        }
        mode = (q.get('mode') or ['clean'])[0]
        if mode not in ('clean', 'full'):
            mode = 'clean'

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
            result = wrap_zip(tmp, meta, mode)
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
