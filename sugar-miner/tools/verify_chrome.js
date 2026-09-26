/**
 * tools/verify_chrome.js — the published page, in a real browser.
 *
 * tools/verify.js runs the page's code in Node, which proves the JavaScript and the
 * WebAssembly are correct. It does not prove the page *runs in a browser*: Node has
 * no rendering, no DOM, no Content-Security-Policy, no worker throttling rules and
 * no real WebAssembly engine deciding whether a SIMD module compiles.
 *
 * That gap matters because "Chrome" is the platform this project's web answer is
 * aimed at, and the failure modes are browser failures: a SIMD module that a given
 * Chrome refuses to compile, a page that dies on a DOM query, a script that throws
 * before it ever connects. Those are all invisible to a Node harness that imports the
 * extracted modules directly.
 *
 * So this loads the *published file*, served over HTTP exactly as Pages serves it,
 * in headless Chrome, and asks it the questions that only a browser can answer:
 *
 *   1. does the page load and run without throwing, under a strict console watch?
 *   2. does it still ship an empty payout field and only this project's bridge?
 *   3. does the engine Chrome actually uses — strictly, on this version, after the
 *      page's own SIMD-then-scalar fallback — reproduce the Sugarchain genesis PoW
 *      hash, the same vector the Node harness checks?
 *
 * If no browser is installed it says so and exits 77 (skip), so a developer without
 * Chrome gets an honest "not checked" rather than a green tick nobody earned.
 */

'use strict';

const fs = require('fs');
const http = require('http');
const path = require('path');
const { spawn, execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const PAGE = path.join(ROOT, 'site', 'index.html');
const SKIP = 77;

/* ----------------------------------------------------------------- browser ---- */

function findBrowser() {
  if (process.env.CHROME) return process.env.CHROME;
  const names = [
    'google-chrome-stable', 'google-chrome', 'chromium', 'chromium-browser',
    'chrome-headless-shell',
  ];
  for (const n of names) {
    try {
      const p = execFileSync('bash', ['-lc', `command -v ${n}`], { encoding: 'utf8' }).trim();
      if (p) return p;
    } catch { /* not on PATH */ }
  }
  // puppeteer's cache, where a downloaded headless shell lives
  const caches = [
    path.join(process.env.HOME || '', '.cache', 'chrome'),
    path.join(process.env.HOME || '', '.cache', 'puppeteer'),
  ];
  for (const c of caches) {
    if (!fs.existsSync(c)) continue;
    const hit = execFileSync('bash', ['-lc',
      `find ${JSON.stringify(c)} -type f -name 'chrome-headless-shell' -o -type f -name 'chrome' | head -1`,
    ], { encoding: 'utf8' }).trim();
    if (hit) return hit;
  }
  return null;
}

/* ----------------------------------------------------------------- harness ---- */

// The page's own globals are what we drive: `WASM_BUILDS` (the inlined SIMD and
// scalar builds), `createYespower` (the emscripten loader) and `b64bytes`. This
// mirrors tools/verify.js's Node harness on purpose — same vectors, different engine.
const HARNESS = fs.readFileSync(path.join(__dirname, 'chrome_harness.js'), 'utf8');

/* -------------------------------------------------------------------- main ---- */

async function main() {
  const chrome = findBrowser();
  if (!chrome) {
    console.log('  no Chrome or Chromium on this machine — the browser check did not run');
    console.log('  set CHROME=/path/to/chrome to run it, or install one');
    process.exit(SKIP);
  }

  const page = fs.readFileSync(PAGE, 'utf8');
  const harnessed = page.replace('</body>', '<script>\n' + HARNESS + '\n</script>\n</body>');
  if (harnessed === page) {
    console.log('FAIL the page has no </body> to inject the harness into');
    process.exit(1);
  }

  // Serve it over HTTP, because that is how Pages serves it. file:// changes what a
  // browser allows, and a check that passes under rules the real thing never sees is
  // not a check.
  // Faithful to Pages: the right MIME types, so a browser's wasm streaming compile
  // takes the same path it would in production.
  const mime = (p) => p.endsWith('.wasm') ? 'application/wasm'
    : p.endsWith('.js') ? 'text/javascript; charset=utf-8'
    : 'text/html; charset=utf-8';
  const server = http.createServer((req, res) => {
    if (req.url.includes('stratum')) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': mime(req.url) });
    res.end(harnessed);
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const url = `http://127.0.0.1:${server.address().port}/`;

  const args = [
    '--headless=new',
    '--no-sandbox',
    '--disable-gpu',
    '--disable-dev-shm-usage',
    '--virtual-time-budget=45000',
    '--dump-dom',
    url,
  ];

  let dom = '';
  try {
    dom = await new Promise((resolve, reject) => {
      const c = spawn(chrome, args, { stdio: ['ignore', 'pipe', 'pipe'] });
      let out = '', err = '';
      const timer = setTimeout(() => { c.kill('SIGKILL'); reject(new Error('chrome timed out')); }, 90000);
      c.stdout.on('data', (d) => { out += d; });
      c.stderr.on('data', (d) => { err += d; });
      c.on('error', reject);
      c.on('close', (code) => {
        clearTimeout(timer);
        if (!/===CHROME[\n]*-?CHECK-START===/.test(out.replace(/\n(?=[^<])/g, ''))) {
          // Marker check on the DOM as a whole; the split marker above means only a
          // real result can contain it.
          reject(new Error(`no result in the DOM (chrome exit ${code})\n${err.split('\n').slice(-6).join('\n')}`));
        } else resolve(out);
      });
    });
  } catch (e) {
    console.log('FAIL the page did not finish loading in Chrome — ' + e.message);
    server.close();
    process.exit(1);
  }
  server.close();

  const block = /===CHROME-CHECK-START===\n([\s\S]*?)\n===CHROME-CHECK-END===/.exec(dom);
  if (!block) {
    console.log('FAIL could not read the result block out of the DOM');
    process.exit(1);
  }

  const version = execFileSync(chrome, ['--version'], { encoding: 'utf8' }).trim();
  console.log(`  ${version}`);
  let failed = 0;
  for (const line of block[1].split('\n')) {
    const pass = line.startsWith('PASS');
    console.log('  ' + (pass ? '✓' : '✗') + ' ' + line.replace(/^(PASS|FAIL) /, ''));
    if (!pass) failed++;
  }
  console.log('');
  if (failed) {
    console.log(`  ${failed} check(s) failed in the browser`);
    process.exit(1);
  }
  console.log('  the published page runs in a real browser, and its engines are correct there');
}

main().catch((e) => { console.log('FAIL ' + (e && e.stack || e)); process.exit(1); });
