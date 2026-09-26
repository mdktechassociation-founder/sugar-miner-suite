/**
 * tools/verify_browser.js — the published page, in every real browser on this machine.
 *
 * tools/verify.js runs the page's code in Node, which proves the JavaScript and the
 * WebAssembly are correct. It does not prove the page *runs in a browser*: Node has no
 * DOM, no rendering, no Content-Security-Policy, and no browser deciding whether a SIMD
 * module compiles. Those are exactly the things that break a web page.
 *
 * So the published file is served over HTTP — the way Pages serves it — and opened in
 * each Chromium-family browser found: Chrome, Edge, Chromium, or a headless shell. Every
 * one of them has to answer the same questions through tools/chrome_harness.js:
 *
 *   1. do the page's own engines reproduce Sugarchain's genesis PoW hash here?
 *   2. does the page's own sha256d reproduce the genesis block hash here?
 *   3. does the DOM still ship an empty payout field, and a bridge field that
 *      never names a third party's relay?
 *   4. did anything throw, or get logged as an error, while that happened?
 *
 * A browser that is not installed is simply not tested, and that is reported rather
 * than hidden. If none is installed at all the check exits 77 (skip), so a machine
 * without a browser says "not checked" instead of showing a tick nobody earned.
 *
 *   node tools/verify_browser.js              # every browser it can find
 *   BROWSERS=/usr/bin/microsoft-edge node tools/verify_browser.js   # just one
 */

'use strict';

const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const { spawn, execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const PAGE = path.join(ROOT, 'site', 'index.html');
const HARNESS = fs.readFileSync(path.join(__dirname, 'chrome_harness.js'), 'utf8');
const SKIP = 77;

/* ----------------------------------------------------------------- browsers ---- */

// Names to look for on PATH. Order is preference, not precedence — every browser that
// is present gets tested, because "works in one Chromium" is not "works in Chromium".
const KNOWN = [
  ['google-chrome-stable', 'Chrome'],
  ['google-chrome', 'Chrome'],
  ['microsoft-edge-stable', 'Edge'],
  ['microsoft-edge', 'Edge'],
  ['chromium', 'Chromium'],
  ['chromium-browser', 'Chromium'],
  ['chrome-headless-shell', 'headless shell'],
];

function onPath(name) {
  try {
    const p = execFileSync('bash', ['-lc', `command -v ${name}`], { encoding: 'utf8' }).trim();
    return p || null;
  } catch {
    return null;
  }
}

function findBrowsers() {
  if (process.env.BROWSERS) {
    return process.env.BROWSERS.split(',').map((s) => s.trim()).filter(Boolean)
      .map((p) => ({ path: p, label: path.basename(p) }));
  }

  const found = [];
  const seen = new Set();
  const add = (binary, label) => {
    if (!binary || seen.has(binary)) return;
    let real = binary;
    try { real = fs.realpathSync(binary); } catch { /* keep as given */ }
    if (seen.has(real)) return;
    seen.add(real);
    found.push({ path: binary, label });
  };

  for (const [name, label] of KNOWN) add(onPath(name), label);

  // A headless shell downloaded by the puppeteer tooling, which is how a machine with
  // no system browser still gets checked.
  const caches = [
    path.join(os.homedir(), '.cache', 'chrome'),
    path.join(os.homedir(), '.cache', 'puppeteer'),
  ];
  for (const cache of caches) {
    if (!fs.existsSync(cache)) continue;
    try {
      const hit = execFileSync('bash', ['-lc',
        `find ${JSON.stringify(cache)} -type f \\( -name chrome-headless-shell -o -name chrome \\) | head -1`,
      ], { encoding: 'utf8' }).trim();
      if (hit) add(hit, 'headless shell');
    } catch { /* nothing there */ }
  }
  return found;
}

/* ------------------------------------------------------------------ harness ---- */

async function runInBrowser(browser) {
  const page = fs.readFileSync(PAGE, 'utf8');
  const harnessed = page.replace('</body>', '<script>\n' + HARNESS + '\n</script>\n</body>');
  if (harnessed === page) return { failure: 'the page has no </body> to inject the harness into' };

  // Faithful to Pages: correct MIME types, so wasm streaming compilation takes the
  // same path it would in production. /stratum is not a real bridge — the check never
  // connects — so it answers 404 rather than hanging.
  const server = http.createServer((req, res) => {
    if (req.url.includes('stratum')) { res.writeHead(404); res.end(); return; }
    const type = req.url.endsWith('.wasm') ? 'application/wasm'
      : req.url.endsWith('.js') ? 'text/javascript; charset=utf-8'
      : 'text/html; charset=utf-8';
    res.writeHead(200, { 'Content-Type': type });
    res.end(harnessed);
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const url = `http://127.0.0.1:${server.address().port}/`;

  // A throwaway profile: never touch a real browser profile, its history or its logins.
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'sugar-browser-'));

  let dom = '';
  try {
    dom = await new Promise((resolve, reject) => {
      const child = spawn(browser.path, [
        '--headless=new', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage',
        `--user-data-dir=${profile}`,
        '--no-first-run', '--no-default-browser-check',
        '--virtual-time-budget=45000', '--dump-dom', url,
      ], { stdio: ['ignore', 'pipe', 'pipe'] });

      let out = '', err = '';
      const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('timed out')); }, 90000);
      child.stdout.on('data', (d) => { out += d; });
      child.stderr.on('data', (d) => { err += d; });
      child.on('error', reject);
      child.on('close', (code) => {
        clearTimeout(timer);
        if (!out.includes(['===CHROME', 'CHECK-START==='].join('-'))) {
          reject(new Error(`the page did not finish loading (exit ${code})\n` +
            err.split('\n').filter((l) => /ERROR|error/.test(l)).slice(-3).join('\n')));
        } else resolve(out);
      });
    });
  } catch (e) {
    return { failure: e.message };
  } finally {
    server.close();
    fs.rmSync(profile, { recursive: true, force: true });
  }

  const block = /===CHROME-CHECK-START===\n([\s\S]*?)\n===CHROME-CHECK-END===/.exec(dom);
  if (!block) return { failure: 'could not read the result out of the DOM' };

  let version = '';
  try { version = execFileSync(browser.path, ['--version'], { encoding: 'utf8' }).trim(); } catch { /* fine */ }

  const lines = block[1].split('\n');
  return { version, lines, failed: lines.filter((l) => !l.startsWith('PASS')).length };
}

/* --------------------------------------------------------------------- main ---- */

async function main() {
  const browsers = findBrowsers();
  if (browsers.length === 0) {
    console.log('  no Chrome, Edge or Chromium on this machine — the browser check did not run');
    console.log('  install one, or set BROWSERS=/path/to/edge,/path/to/chrome');
    process.exit(SKIP);
  }

  let failed = 0;
  let checked = 0;

  for (const browser of browsers) {
    const result = await runInBrowser(browser);
    console.log(`\n  ${browser.label} — ${browser.path}`);
    if (result.failure) {
      console.log(`    ✗ ${result.failure}`);
      failed++;
      continue;
    }
    browser.version = result.version;      // for the CI summary below
    console.log(`    ${result.version || '(version unknown)'}`);
    for (const line of result.lines) {
      const pass = line.startsWith('PASS');
      console.log('    ' + (pass ? '✓' : '✗') + ' ' + line.replace(/^(PASS|FAIL) /, ''));
      if (!pass) failed++;
    }
    checked++;
  }

  console.log('');
  const summary = `${checked} browser(s): ` +
    browsers.map((b) => `${b.label} (${(b.version || '').replace(/^[^0-9]*/, '')})`).join(', ');

  // On CI, write it where it can be read without admin rights or a log download: the
  // run's own summary page. Which browsers were tested is part of the result, not a
  // detail — "it passed in Chrome" and "it passed in Chrome and Edge" are different
  // claims, and the person reading the run should not have to guess which one it is.
  if (process.env.GITHUB_STEP_SUMMARY) {
    try {
      fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY,
        `### The published page, in real browsers\n\n` +
        `${failed ? '❌' : '✅'} ${summary}\n\n` +
        browsers.map((b) => `- ${b.label}: ${b.version || 'version unknown'} at \`${b.path}\``).join('\n') + '\n');
    } catch { /* a summary that cannot be written must never fail the check */ }
  }

  if (failed) {
    console.log(`  ${failed} check(s) failed across ${browsers.length} browser(s)`);
    process.exit(1);
  }
  console.log(`  the published page runs in ${checked} real browser(s), and its engines are correct there`);
}

main().catch((e) => { console.log('FAIL ' + ((e && e.stack) || e)); process.exit(1); });
