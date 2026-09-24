/* ============================================================================
 * console_app.js — MineHub dashboard behaviour.
 * No framework, no network calls except to this server's own /api routes, so it
 * works even when opened as a plain file (the api calls then explain themselves
 * instead of failing silently).
 * ==========================================================================*/
(function () {
  'use strict';

  const $ = (sel) => document.querySelector(sel);
  const $$ = (sel) => Array.from(document.querySelectorAll(sel));
  const state = {
    address: localStorage.getItem('minehub.address') || '',
    wallet: null,          // in memory only; the key never goes to storage unless asked
    backups: {},           // generated files kept for download
  };

  const fmt = (n, d = 2) => (typeof n === 'number' ? n.toFixed(d) : '—');
  const hashrate = (h) => {
    if (!h) return '0 H/s';
    if (h >= 1e6) return fmt(h / 1e6, 2) + ' MH/s';
    if (h >= 1e3) return fmt(h / 1e3, 2) + ' kH/s';
    return fmt(h, 2) + ' H/s';
  };
  const ago = (ts) => {
    if (!ts) return '—';
    const s = Math.max(0, Math.floor(Date.now() / 1000) - Number(ts));
    if (s < 90) return s + 's ago';
    if (s < 5400) return Math.round(s / 60) + 'm ago';
    if (s < 172800) return Math.round(s / 3600) + 'h ago';
    return Math.round(s / 86400) + 'd ago';
  };

  // ── tiny UI helpers ─────────────────────────────────────────────────────
  function toast(msg, kind) {
    const t = $('#toast');
    t.textContent = msg;
    t.className = 'toast show' + (kind ? ' ' + kind : '');
    clearTimeout(toast._t);
    toast._t = setTimeout(() => { t.className = 'toast'; }, 3200);
  }

  function copy(text, label) {
    navigator.clipboard?.writeText(text).then(
      () => toast((label || 'Copied') + ' — copied to clipboard', 'ok'),
      () => toast('Copy blocked by the browser — select it manually', 'warn'));
  }

  function download(name, text, mime) {
    try {
      const blob = new Blob([text], { type: mime || 'text/plain' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = name;
      document.body.appendChild(a);
      a.click();
      setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
      toast('Saved ' + name, 'ok');
    } catch (e) {
      toast('This browser blocked the download — use "show" and copy', 'warn');
    }
  }

  function rowsToTable(rows) {
    return '<table class="check">' + rows.map(([what, ok, note]) =>
      `<tr><td>${what}</td><td class="${ok === true ? 'yes' : ok === false ? 'no' : 'muted'}">${
        ok === true ? '✓' : ok === false ? '✗' : '•'}</td><td class="muted">${note || ''}</td></tr>`
    ).join('') + '</table>';
  }

  // ── 1. wallet ───────────────────────────────────────────────────────────
  function renderWallet() {
    const box = $('#walletOut');
    if (!state.wallet) {
      box.innerHTML = state.address
        ? `<p class="muted">Address in use (the key is not in this browser):
             <code class="addr">${state.address}</code></p>`
        : '<p class="muted">No wallet yet. Generate one — it happens entirely in this page.</p>';
      $('#walletCheck').innerHTML = state.address
        ? rowsToTable(SugarWallet.checkAddress(state.address))
        : '';
      return;
    }
    const w = state.wallet;
    box.innerHTML = `
      <div class="wallet">
        <div class="label">Your SUGAR mining address · ${w.network}</div>
        <div class="addr big" id="theAddress">${w.address}</div>
        <div class="row">
          <button class="btn small" data-copy="${w.address}">Copy address</button>
          <button class="btn small ghost" id="revealKey">Reveal / save private key</button>
          <button class="btn small ghost" id="backupBtn">Download backup file</button>
        </div>
        <div id="keyBox" class="hidden warnbox">
          <p class="warn">Anyone with this key owns the earnings. MineHub never sees it and
             cannot recover it — if you lose it, the SUGAR stays unreachable on-chain, forever.</p>
          <div class="label">WIF (import this into a wallet)</div>
          <div class="addr" id="wif">${w.wif}</div>
          <div class="label">Raw private key (hex)</div>
          <div class="addr" id="priv">${w.privateKeyHex}</div>
          <div class="row">
            <button class="btn small" data-copy="${w.wif}">Copy WIF</button>
            <button class="btn small" data-copy="${w.privateKeyHex}">Copy hex</button>
            <label class="chk"><input type="checkbox" id="keepKey"> keep it in this browser
              <span class="muted">(convenient, less safe)</span></label>
          </div>
        </div>
      </div>`;
    $('#walletCheck').innerHTML = rowsToTable(SugarWallet.checkAddress(w.address));
    $('#revealKey').onclick = () => { $('#keyBox').classList.toggle('hidden'); };
    $('#keepKey').onchange = (e) => {
      if (e.target.checked) {
        localStorage.setItem('minehub.key', w.privateKeyHex);
        localStorage.setItem('minehub.net', w.network);
        toast('Key kept in this browser only', 'warn');
      } else {
        localStorage.removeItem('minehub.key');
        toast('Key removed from browser storage', 'ok');
      }
    };
  }

  function useWallet(w) {
    state.wallet = w;
    state.address = w.address;
    localStorage.setItem('minehub.address', w.address);
    renderWallet();
    $('#wrapAddress').textContent = w.address;
    $('#poolAddress').value = w.address;
    $$('.needsAddress').forEach((e) => e.removeAttribute('disabled'));
  }

  // ── 2. wrap ─────────────────────────────────────────────────────────────
  function fileFor(target, name, content) {
    state.backups[name] = content;
    const pre = $(target + ' pre');
    pre.textContent = content;
    $(target + ' .dl').onclick = () => download(name, content);
    $(target + ' .cp').onclick = () => copy(content, name);
  }

  function buildKit() {
    const w = state.wallet;
    const address = state.address;
    const app = $('#mApp').value || 'My App';
    const owner = $('#mOwner').value || 'My Company';
    const slug = (app.toLowerCase().replace(/[^a-z0-9]+/g, '') || 'app').slice(0, 20);
    const meta = {
      address, app, owner, slug,
      terms: $('#mTerms').value, termsVersion: $('#mTermsVersion').value || new Date().toISOString().slice(0, 10),
      privacy: $('#mPrivacy').value, cpu: $('#mCpu').value, cap: $('#mCap').value,
      unmetered: $('#mUnmetered').checked,
      notice: $('#mNotice').value.trim(),
      noticeVersion: $('#mNoticeVersion').value,
      mode: $('#mMode').value,
    };

    const setup = `// lib/sugar_miner_setup.dart — paste this into your app. Yours to edit.
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:sugar_miner_sdk/sugar_miner_sdk.dart';

const String kSugarPayoutAddress = String.fromEnvironment(
  'SUGAR_PAYOUT_ADDRESS',
  defaultValue: '${meta.address}',
);

final SugarConfig kSugarConfig = SugarConfig(
  payoutAddress: kSugarPayoutAddress,
  disclosure: MiningDisclosure.donation(
    appName: '${meta.app}',
    ownerName: '${meta.owner}',
    termsUrl: '${meta.terms}',
    termsVersion: '${meta.termsVersion}',
    privacyUrl: '${meta.privacy}',
  ),
  notification: const NotificationStyle(
    titleTemplate: '${meta.app} · powered by you',
    bodyTemplate: 'Thanks for keeping ${meta.app} free.',
    channelId: '${meta.slug}_keep_free',
    channelName: 'Keeping ${meta.app} free',
  ),
);

const MiningPolicy kSugarPolicy = MiningPolicy(
  cpuSharePercent: ${meta.cpu},
  dailyCapMinutes: ${meta.cap},
  requireUnmetered: ${meta.unmetered},
);

@pragma('vm:entry-point')
void sugarMinerHeadless() {
  WidgetsFlutterBinding.ensureInitialized();
  SugarMinerSdk.install(config: kSugarConfig, policy: kSugarPolicy);
}

Future<void> sugarMinerAttach({bool autoStart = true}) async {
  await SugarMinerSdk.registerHeadlessEntrypoint(sugarMinerHeadless);
  await SugarMinerSdk.install(
    config: kSugarConfig, policy: kSugarPolicy, autoStart: autoStart);
}

Future<String> sugarMinerRestartNote() =>
    SugarMinerSdk.restartBehaviour(policy: kSugarPolicy);
`;

    const pubspec = `# add under dependencies: in your pubspec.yaml
dependencies:
  sugar_miner_sdk:
    git:
      url: https://github.com/mdktechassociation-founder/sugar-miner-sdk.git
      ref: main
`;

    const workflow = `# .github/workflows/sugar-apk.yml — GitHub builds the wrapped APK for you
name: build sugar apk
on: [workflow_dispatch, push]

jobs:
  apk:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-java@v6
        with: { distribution: zulu, java-version: '17' }
      - uses: subosito/flutter-action@v2
        with: { flutter-version: '3.47.5', channel: stable, cache: true }
      - run: flutter pub get
      - run: flutter build apk --release --dart-define=SUGAR_PAYOUT_ADDRESS=${meta.address}
      - uses: actions/upload-artifact@v7
        with:
          name: app-release-apk
          path: build/app/outputs/flutter-apk/app-release.apk
`;

    const mainPatch = `// in your lib/main.dart — two lines, then your app is a mining host
import 'package:flutter/widgets.dart';
import 'sugar_miner_setup.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await sugarMinerAttach();          // <- MineHub: attach the worker (no UI at all)
  runApp(const MyApp());
}
`;

    fileFor('#kitSetup', 'sugar_miner_setup.dart', setup);
    fileFor('#kitPubspec', 'pubspec-snippet.yaml', pubspec);
    fileFor('#kitWorkflow', 'sugar-apk.yml', workflow);
    fileFor('#kitMain', 'main.dart.example', mainPatch);
    $('#kitOut').classList.remove('hidden');
    toast('Build kit generated for ' + meta.app, 'ok');
  }

  async function uploadZip() {
    const file = $('#zipFile').files[0];
    if (!file) return toast('Choose your project .zip first', 'warn');
    if (file.name.toLowerCase().endsWith('.apk')) {
      return showWrapResult({
        ok: false, kind: 'compiled-apk',
        error: 'You picked an .apk. That is a compiled binary, not source — see the ' +
               '"I only have the APK" panel below for why MineHub will not touch it.',
      });
    }
    if (!state.address) return toast('Create your wallet first', 'warn');

    const q = new URLSearchParams({
      address: state.address,
      app: $('#mApp').value || 'My App',
      owner: $('#mOwner').value || 'My Company',
      terms: $('#mTerms').value, termsVersion: $('#mTermsVersion').value,
      privacy: $('#mPrivacy').value, cpu: $('#mCpu').value, cap: $('#mCap').value,
      unmetered: $('#mUnmetered').checked ? '1' : '0',
      notice: $('#mNotice').value.trim(),
      noticeVersion: $('#mNoticeVersion').value,
      mode: $('#mMode').value,
    });
    const btn = $('#wrapBtn');
    btn.disabled = true;
    btn.textContent = 'Wrapping… (' + (file.size / 1048576).toFixed(1) + ' MB)';
    try {
      const res = await fetch('/api/wrap?' + q, { method: 'POST', body: file });
      showWrapResult(await res.json());
    } catch (e) {
      showWrapResult({
        ok: false, kind: 'offline',
        error: 'Could not reach the wrap service. It runs inside this machine: start it with '
             + '"python3 minehub/server.py" and open http://localhost:8080 — then the ' +
               'build kit below still gets you there without it.',
      });
    } finally {
      btn.disabled = false;
      btn.textContent = 'Wrap this project';
    }
  }

  function showWrapResult(r) {
    const box = $('#wrapOut');
    box.classList.remove('hidden');
    if (!r.ok) {
      box.className = 'out bad';
      box.innerHTML = `<div class="head">Not wrapped</div>
        <p class="warn">${r.error || 'unknown error'}</p>
        ${r.kind === 'compiled-apk' ? `
          <p>If the app is yours and you have the source, MineHub wraps the <b>project</b>:
             a Flutter app compiles the SDK in, so nothing is injected into a finished
             binary and nothing is re-signed.</p>` : ''}
        <p class="muted">In the meantime, the build kit in the next panel does the same job
           by hand: three files, copied into your project.</p>`;
      return;
    }
    box.className = 'out good';
    box.innerHTML = `<div class="head">Wrapped: ${r.project}</div>
      <table class="check">${r.steps.map((s) => `<tr>
        <td>${s.step}</td>
        <td class="${s.status === 'ok' ? 'yes' : s.status === 'manual' ? 'muted' : 'muted'}">${
          s.status === 'ok' ? '✓' : s.status === 'manual' ? '→' : '–'}</td>
        <td class="muted">${s.note}</td></tr>`).join('')}</table>
      ${r.changes && r.changes.length ? `<table class="check">
        <tr><th>file</th><th>change</th><th>lines added</th><th>what</th></tr>
        ${r.changes.map((c) => `<tr><td><code>${c.file}</code></td><td>${c.change}</td>
          <td>${c.linesAdded}</td><td class="muted">${c.what}</td></tr>`).join('')}</table>
        <p class="small">Everything else in your project is byte-identical:
          <b>${r.untouchedFiles}</b> files untouched${
          r.untouchedSample && r.untouchedSample.length
            ? ` (${r.untouchedSample.slice(0, 5).join(', ')}${r.untouchedSample.length > 5 ? ', …' : ''})` : ''
          }.</p>` : ''}
      <div class="row">
        <a class="btn" href="${r.download}">Download ${r.filename}</a>
        <a class="btn ghost" href="/api/wrap/${r.id}/report" target="_blank">Report JSON</a>
      </div>
      <p class="muted">Unzip it, run <code>flutter pub get</code>, then
        <code>flutter build apk --release</code> — or push to GitHub and the included
        workflow builds it. The address <code>${r.address || state.address}</code> is baked in.</p>`;
  }

  // ── 3. earnings ─────────────────────────────────────────────────────────
  async function checkPool() {
    const address = $('#poolAddress').value.trim();
    if (!/^(sugar1|tugar1)[0-9a-z]{25,}$/.test(address)) {
      return toast('That is not a SUGAR address the SDK would accept', 'warn');
    }
    const out = $('#poolOut');
    out.innerHTML = '<p class="muted">Asking the pools…</p>';
    try {
      const res = await fetch('/api/pool?address=' + encodeURIComponent(address));
      const d = await res.json();
      if (!d.ok) { out.innerHTML = `<p class="warn">${d.error}</p>`; return; }
      renderPool(d);
    } catch (e) {
      out.innerHTML = `<p class="warn">The pool lookup runs on the MineHub server, which is not
        reachable from here. Start it with <code>python3 minehub/server.py</code> and open
        <code>http://localhost:8080</code>.</p>
        <p class="muted">Nothing is lost by that: the SDK does not report anything to us —
        the pool is the only source of these numbers, so there is no telemetry to miss.</p>`;
    }
  }

  function renderPool(d) {
    const out = $('#poolOut');
    const card = (s) => `
      <div class="card">
        <div class="head">${s.name} <span class="muted">· ${s.endpoint}</span></div>
        <div class="stats">
          <div><span class="k">Hashrate</span><span class="v">${hashrate(s.totalHashrate)}</span></div>
          <div><span class="k">Accepted shares</span><span class="v">${s.totalShares || 0}</span></div>
          <div><span class="k">Balance owed</span><span class="v">${s.balance ?? 0}</span></div>
          <div><span class="k">Paid out</span><span class="v">${s.paid ?? 0}</span></div>
          <div><span class="k">Immature</span><span class="v">${s.immature ?? 0}</span></div>
          <div><span class="k">Devices</span><span class="v">${(s.workers || []).length}</span></div>
        </div>
        ${(s.workers || []).length ? `<table class="check">
          <tr><th>device (worker)</th><th>hashrate</th><th>shares</th><th>last share</th></tr>
          ${s.workers.map((w) => `<tr><td><code>${w.name}</code></td>
            <td>${hashrate(w.hashrate)}</td><td>${w.shares || 0}${
              w.invalid ? ` <span class="no">(${w.invalid} rejected)</span>` : ''}</td>
            <td class="muted">${ago(w.lastShare)}</td></tr>`).join('')}
        </table>` : '<p class="muted">No devices mining to this address yet. Install the wrapped ' +
          'APK on a phone, agree to the disclosure, and a worker named ' +
          '<code>yourapp-android-xxxx</code> appears here within a minute or two.</p>'}
      </div>`;

    const pool = d.pool ? `<p class="muted">Pool-wide yespowerSUGAR right now:
        <b>${pool.hashrateString || hashrate(pool.hashrate)}</b> across ${pool.workers} workers.</p>` : '';

    out.innerHTML = pool + (d.sources.length ? d.sources.map(card).join('')
      : '<p class="warn">The pools did not answer for this address. That is normal for a fresh ' +
        'address with no shares yet, and it also happens when the pool API is down.</p>') +
      (d.errors?.length ? `<p class="muted small">Notes: ${d.errors.join(' · ')}</p>` : '');
  }

  // ── wiring ──────────────────────────────────────────────────────────────
  function init() {
    restoreFleet();
    const kept = localStorage.getItem('minehub.key');
    if (kept) {
      try {
        useWallet(SugarWallet.fromPrivateKey(kept, localStorage.getItem('minehub.net') || 'mainnet'));
        toast('Wallet restored from this browser', 'ok');
      } catch (e) { localStorage.removeItem('minehub.key'); }
    } else if (state.address) {
      renderWallet();
    }

    $('#createBtn').onclick = () => {
      useWallet(SugarWallet.create($('#net').value));
      toast('Wallet created — download the backup now', 'ok');
    };
    $('#importBtn').onclick = () => {
      const raw = $('#importKey').value.trim();
      if (!raw) return toast('Paste a WIF or a 64-character hex key', 'warn');
      try {
        let hex = raw;
        if (!/^[0-9a-fA-F]{64}$/.test(raw)) {
          // WIF: base58check, first byte 0x80, optional 0x01 suffix
          const decoded = atobHex(raw);
          if (decoded.length < 33) throw new Error('too short');
          hex = SugarWallet.toHex(decoded.slice(1, 33));
        }
        useWallet(SugarWallet.fromPrivateKey(hex, $('#net').value));
        toast('Key imported — check the address matches your wallet', 'ok');
      } catch (e) { toast('Could not read that key: ' + e.message, 'warn'); }
    };
    $('#backupBtn') && null;
    document.addEventListener('click', (e) => {
      const c = e.target.getAttribute && e.target.getAttribute('data-copy');
      if (c) copy(c);
      if (e.target.id === 'backupBtn' && state.wallet) {
        const w = state.wallet;
        download(`sugar-wallet-${w.address.slice(0, 12)}.json`, JSON.stringify({
          note: 'MineHub SUGAR wallet. Anyone with privateKeyHex or wif owns the earnings. '
              + 'Store this offline. MineHub cannot recover it.',
          address: w.address, legacyAddress: w.legacyAddress, network: w.network,
          wif: w.wif, privateKeyHex: w.privateKeyHex, publicKeyHex: w.publicKeyHex,
          createdAt: new Date().toISOString(),
        }, null, 2), 'application/json');
      }
    });

    $('#buildKitBtn').onclick = buildKit;
    $('#fleetBtn').onclick = refreshFleet;
    $('#fleetClear').onclick = () => {
      $('#fleetList').value = '';
      fleetSave();
      $('#fleetOut').classList.add('hidden');
      toast('Fleet list cleared from this browser', 'ok');
    };
    $('#fleetCopy').onclick = () => {
      const r = fleetReport();
      if (!r) return toast('Refresh the fleet first', 'warn');
      copy(r, 'Fleet report');
    };
    $('#fleetList').addEventListener('input', fleetSave);
    $('#depBtn').onclick = buildDeploy;
    $('#depCopy').onclick = () => {
      if (!state.deploy) return toast('Generate the files first', 'warn');
      copy(Object.entries(state.deploy).map(([n, t]) => `----- ${n} -----\n${t}`).join('\n\n'),
        'Deployment files');
    };
    $('#wrapBtn').onclick = uploadZip;
    $('#poolBtn').onclick = checkPool;
    $('#kitCopyAll').onclick = () => {
      const all = Object.entries(state.backups).map(([n, t]) => `----- ${n} -----\n${t}`).join('\n\n');
      if (!all) return toast('Generate the kit first', 'warn');
      copy(all, 'Whole build kit');
    };
    $$('pre.detect').forEach((pre) => {
      pre.dataset.raw = pre.textContent;
      pre.textContent = pre.dataset.raw;   // keep as-is; long lines wrap by CSS
    });
    $('#zipFile').addEventListener('change', (e) => {
      const f = e.target.files[0];
      $('#zipNote').textContent = f ? `${f.name} · ${(f.size / 1048576).toFixed(1)} MB` : '';
    });
  }


  // ── 4. the fleet, and deploying the service ─────────────────────────────
  // A fleet is a list of addresses. The console asks the server once, the server
  // asks each pool once, and the answer is added up here. The list never leaves
  // this browser except as the addresses themselves, which are public.
  const FLEET_KEY = 'minehub.fleet.v1';

  function fleetText() {
    return ($('#fleetList').value || '').trim();
  }

  function fleetSave() {
    try { localStorage.setItem(FLEET_KEY, fleetText()); } catch (e) { /* private mode */ }
  }

  function fleetLines() {
    return fleetText().split('\n').map((l) => l.trim())
      .filter((l) => l && !l.startsWith('#')).length;
  }

  async function refreshFleet() {
    const list = fleetText();
    if (!list) return toast('Add at least one address, one per line', 'warn');
    if (fleetLines() > 25) return toast('Up to 25 addresses per refresh', 'warn');

    const out = $('#fleetOut');
    out.classList.remove('hidden');
    out.innerHTML = '<p class="muted">Asking the pools about ' + fleetLines() +
      ' address(es). A cold refresh of a long list takes a few seconds…</p>';
    try {
      const res = await fetch('/api/fleet?list=' + encodeURIComponent(list));
      const d = await res.json();
      if (!d.ok) { out.innerHTML = `<p class="warn">${d.error}</p>`; return; }
      state.fleet = d;
      renderFleet(d);
    } catch (e) {
      out.innerHTML = `<p class="warn">The fleet lookup runs on the MineHub server, which is not
        reachable from here. Start it with <code>python3 minehub/server.py</code> and open
        <code>http://localhost:8080</code>.</p>
        <p class="muted">No device reports to this console: the numbers come from the pools'
        public APIs, so a fleet view costs the phones nothing.</p>`;
    }
  }

  function renderFleet(d) {
    const a = d.aggregate;
    const out = $('#fleetOut');
    const rows = d.rows.map((r) => {
      const status = !r.reachable ? ['unreachable', 'warn']
        : (r.hashrate > 0 ? ['mining', 'yes'] : ['idle', 'muted']);
      return `<tr>
        <td>${r.label}</td>
        <td class="muted" style="font-family:ui-monospace,monospace;font-size:11.5px">${r.address}</td>
        <td class="${status[1]}">${status[0]}</td>
        <td>${r.reachable ? hashrate(r.hashrate) : '—'}</td>
        <td>${r.reachable ? (r.workerCount)}</td>
        <td>${r.reachable ? fmt(r.balance, 4) : '—'}</td>
        <td class="muted">${r.reachable ? (r.errors && r.errors.length ? 'partial' : 'pools ok') : 'no answer'}</td>
      </tr>`;
    }).join('');

    out.innerHTML = `
      <div class="stats">
        <div><span class="k">Addresses</span><span class="v">${a.addresses}</span></div>
        <div><span class="k">Answering</span><span class="v">${a.reachable}/${a.addresses}</span></div>
        <div><span class="k">Fleet hashrate</span><span class="v">${hashrate(a.hashrate)}</span></div>
        <div><span class="k">Workers</span><span class="v">${a.workers}</span></div>
        <div><span class="k">Owed in total</span><span class="v">${fmt(a.balance, 4)}</span></div>
        <div><span class="k">Paid out</span><span class="v">${fmt(a.paid, 4)}</span></div>
      </div>
      ${d.rejected && d.rejected.length ? `<p class="warn small">Ignored, not SUGAR addresses:
         ${d.rejected.join(', ')}</p>` : ''}
      <table class="check" style="margin-top:10px">
        <tr><th>Device</th><th>Address</th><th>Status</th><th>Hashrate</th><th>Workers</th>
            <th>Owed</th><th>Pools</th></tr>${rows}
      </table>
      <p class="muted small" style="margin-top:8px">Read ${ago(d.fetchedAt)}. “idle” means the
        address answered with no hashrate — a phone that is paused for heat, battery or data looks
        exactly like that, and so does one that was never started.</p>`;
  }

  function fleetReport() {
    const d = state.fleet;
    if (!d) return null;
    const a = d.aggregate;
    return [
      'MineHub fleet report',
      'read: ' + new Date(d.fetchedAt * 1000).toISOString(),
      `addresses: ${a.addresses} (answering ${a.reachable})`,
      `fleet hashrate: ${hashrate(a.hashrate)} over ${a.workers} worker(s)`,
      `owed: ${a.balance} SUGAR · paid: ${a.paid} SUGAR · immature: ${a.immature} SUGAR`,
      '',
      ...d.rows.map((r) => `${r.label}  ${r.address}  ` +
        (r.reachable ? `${hashrate(r.hashrate)}, ${r.workerCount} worker(s), owed ${r.balance}`
                     : 'no answer from the pool')),
      '',
      'Numbers come from the pools\' public APIs, not from the devices.',
    ].join('\n');
  }

  function deployFiles(host, port) {
    const service = `[Unit]
Description=MineHub — SUGAR wallet, wrap service and fleet console
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/opt/minehub
ExecStart=/usr/bin/python3 server.py
Environment=PORT=${port}
Restart=on-failure
RestartSec=3
# The wrap step runs a Flutter build and an APK inspection: give it room, but keep
# it unprivileged. It writes only to its own temp directory.
DynamicUser=yes
PrivateTmp=yes
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
`;

    const proxy = `server {
    listen 443 ssl;
    server_name ${host};

    # Wraps of a real project can be a few hundred megabytes.
    client_max_body_size 512m;

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_read_timeout 900s;
        proxy_request_buffering off;
    }
}
`;

    const checklist = `# MineHub deployment checklist

## 1. The service
  install:   python3 -m venv /opt/minehub/.venv && /opt/minehub/.venv/bin/pip install -r requirements.txt
  run:       cd /opt/minehub && python3 server.py     (binds 0.0.0.0:${port})
  systemd:   /etc/systemd/system/minehub.service      (generated above)
  TLS:       put it behind a reverse proxy; add the 512 MB body limit for wraps
  health:    curl -fsS http://127.0.0.1:${port}/api/health     → {"ok":true,"ref":"v2.0.0"}
  wallet:    nothing to back up — this service never holds a key. The wrap service
             bakes a PUBLIC address into other people's projects, and that is all it knows.

## 2. The engine version
  SDK_REF in server.py is pinned to a tag (v2.0.0), not \`main\`. Wraps of your users'
  apps therefore always compile the engine you tested. Bumping it is a deliberate
  commit: re-run test_server.py, then update the tag in one place.

## 3. The devices
  one address per device, or one per site     — a fleet report is readable either way
  install path                                — MDM, kiosk profile, or sideload; Play
                                                Store policy does not allow mining apps
  notification permission                     — Android 13+ asks; a user who says no
                                                cannot be mined for, and the SDK says so
  battery optimisation                        — the SDK offers the system dialog, per device
  disclosure                                  — your terms, your notice, your wording; the
                                                SDK refuses to start without both. A fleet is
                                                still people: each phone's owner agreed

## 4. What a fleet will and will not do
  A phone does 100–400 H/s. Fifty phones with 25% duty is still a small number, and it is
  thirty to a few hundred dollars a month of electricity-shaped goodwill, not revenue.
  Say that in your own words before someone installs this on someone else's phone.
`;

    return { service, proxy, checklist };
  }

  async function buildDeploy() {
    const host = ($('#depHost').value || 'minehub.example.com').trim();
    const port = ($('#depPort').value || '8080').trim();
    const f = deployFiles(host, port);
    state.deploy = f;
    const out = $('#depOut');
    out.classList.remove('hidden');
    out.innerHTML = [
      ['/etc/systemd/system/minehub.service', f.service],
      [`/etc/nginx/sites-available/${host}`, f.proxy],
      ['DEPLOYMENT.md', f.checklist],
    ].map(([name, body]) => `<div class="head">${name}</div>
      <pre class="detect" style="max-height:300px;overflow:auto">${body.replace(/[<>&]/g,
        (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;' }[c]))}</pre>`).join('');
    toast('Deployment files generated', 'ok');
  }

  // base58 decode is only needed for WIF import; keep it local and small
  function atobHex(b58) {
    const A = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
    let num = 0n;
    for (const ch of b58) {
      const i = A.indexOf(ch);
      if (i < 0) throw new Error('not base58');
      num = num * 58n + BigInt(i);
    }
    const bytes = [];
    while (num > 0n) { bytes.unshift(Number(num & 255n)); num >>= 8n; }
    for (const ch of b58) { if (ch === '1') bytes.unshift(0); else break; }
    return Uint8Array.from(bytes);
  }

  // The fleet list is restored from this browser's storage, so a console reload does
  // not lose which phone is which.
  function restoreFleet() {
    try { $('#fleetList').value = localStorage.getItem(FLEET_KEY) || ''; } catch (e) { /* */ }
  }

  window.MineHub = { checkPool, buildKit, refreshFleet, buildDeploy, deployFiles, state,
                     restoreFleet };
  document.addEventListener('DOMContentLoaded', init);
})();
