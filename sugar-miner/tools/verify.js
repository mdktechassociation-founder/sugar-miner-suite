/**
 * tools/verify.js — the test suite CI runs on every push.
 *
 * Two kinds of check:
 *
 *  A. SAFETY REGRESSIONS on what we actually publish (site/index.html).
 *     The upstream file shipped with a stranger's payout address hard-coded in the
 *     form, which silently mined into their wallet. That must never come back.
 *
 *  B. CONSENSUS CORRECTNESS of every hashing engine inside the page, against the
 *     real Sugarchain genesis block. If the wasm ever drifts, this fails loudly
 *     instead of quietly producing garbage hashes.
 *
 * Runs fully offline (no pool contact). Set SUGAR_LIVE=1 to *also* talk to the
 * pool — that check is opt-in because it depends on a third party being up.
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { extract, OUT } = require('./extract.js');

/* ------------------------------------------------------------------ harness */
let failures = 0, checks = 0;
const ok = (name, pass, detail = '') => {
  checks++;
  if (!pass) failures++;
  console.log(`${pass ? '  ✓' : '  ✗'} ${name}${detail ? '  — ' + detail : ''}`);
};
const section = t => console.log(`\n${t}`);

const GENESIS_HEADER =
  '010000000000000000000000000000000000000000000000000000000000000000000000' +
  'b050e156acdac2cada87b39ce5f137f5b872901e6b9e1c1d41b09c572ace7776' +
  '7073555dffff3f1ff7000000';
const GENESIS_BLOCK  = '7d5eaec2dbb75f99feadfa524c78b7cabc1d8c8204f79d4f3a83381b811b0adc';
const GENESIS_POW    = '0031205acedcc69a9c18f79b84790179d68fb90588bedee6587ff701bdde04eb';

// the miner's own hasher wrapper (same buffer-reuse logic as the page's onModule)
function makeHasher(yp) {
  const h = {
    key: null, cap: null, out: 0,
    hash(bytes, params) {
      const key = `${params.N}/${params.r}/${params.version}/${params.pers ? params.pers.length : 0}`;
      if (h.key !== key) { h.key = key; h.cap = { src: 0, pers: 0 }; }
      if (!h.out) h.out = yp._yp_alloc(32);
      if (h.cap.src < bytes.length) { h.cap.src = bytes.length; h.srcPtr = yp._yp_alloc(bytes.length); }
      yp.HEAPU8.set(bytes, h.srcPtr);
      let persPtr = 0, persLen = 0;
      if (params.pers) {
        const pb = new TextEncoder().encode(params.pers);
        if (h.cap.pers < pb.length) { h.cap.pers = pb.length; h.persPtr = yp._yp_alloc(pb.length); }
        yp.HEAPU8.set(pb, h.persPtr); persPtr = h.persPtr; persLen = pb.length;
      }
      const rc = yp._yp_hash(h.srcPtr, bytes.length, persPtr, persLen, params.version, params.N, params.r, h.out);
      if (rc !== 0) throw new Error('yespower returned ' + rc);
      return yp.HEAPU8.slice(h.out, h.out + 32);
    },
  };
  return h;
}

async function loadWasmBuild(createYespower, file) {
  const bin = fs.readFileSync(path.join(OUT, file));
  const mod = await createYespower({
    instantiateWasm: (imports, cb) => {
      WebAssembly.instantiate(bin, imports).then(r => cb(r.instance));
      return {};
    },
  });
  return mod;
}

function loadJsOnlyEngine() {
  const ctx = {
    module: { exports: {} }, exports: {}, require, console, process,
    TextDecoder, TextEncoder, Uint8Array, Int8Array, Uint16Array, Uint32Array, Int16Array, Int32Array,
    Float32Array, Float64Array, ArrayBuffer, Math, Date, Object, Array, String, Number, JSON,
    Error, TypeError, RangeError, Promise, RegExp, setTimeout, clearTimeout, performance,
    WebAssembly: undefined, document: undefined, window: undefined, self: null,
    globalThis: null, URL, decodeURIComponent, encodeURIComponent,
    __dirname: OUT, __filename: path.join(OUT, 'jsonly.js'),
  };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(
    fs.readFileSync(path.join(OUT, 'jsonly.js'), 'utf8') +
    '\n;module.exports={createYespowerJSOnly:typeof createYespowerJSOnly!=="undefined"?createYespowerJSOnly:null,mem:typeof JS_ONLY_MEM_B64!=="undefined"?JS_ONLY_MEM_B64:null};',
    ctx);
  return ctx.module.exports;
}

/* -------------------------------------------------------------------- main */
(async () => {
  const info = extract();
  const S = require(path.join(OUT, 'core.js'));

  /* ---- A. the published page must not ship a stranger's wallet ------------ */
  section('A. Published page safety (site/index.html)');
  const page = fs.readFileSync(info.page, 'utf8');
  const addrBox = /<input id="addr"[^>]*>/.exec(page);
  const urlBox  = /<input id="url"[^>]*>/.exec(page);

  ok('payout address field exists', !!addrBox);
  ok('payout address ships EMPTY', !!addrBox && /value=""/.test(addrBox[0]),
     addrBox ? addrBox[0].trim() : '');
  const wallets = (page.match(/sugar1[0-9a-z]{30,}/gi) || []);
  ok('no wallet address hard-coded anywhere in the page', wallets.length === 0,
     wallets.length ? wallets.join(', ') : '');
  // The bridge is this project's own worker, and it may be pre-filled: the page
  // this repository publishes is the one that worker exists for, and making every
  // visitor paste it was friction with no safety value. What must NOT happen is a
  // *third party's* relay being baked in — someone's mining would then flow through
  // a server this project does not control. So the rule is: the field ships empty,
  // or it names this project's own bridge.
  const OUR_BRIDGE = 'wss://stratum-proxy.mdktechassociation.workers.dev';
  const urlValue = urlBox ? (/value="([^"]*)"/.exec(urlBox[0]) || [null, ''])[1] : null;
  ok('bridge field is empty, or this project\'s own bridge',
     !!urlBox && (urlValue === '' || urlValue === OUR_BRIDGE),
     urlBox ? urlBox[0].trim() : '');
  ok('the bridge can still be overridden with ?ws=',
     page.includes('ws=([^&]+)'),
     'a page that only connects to one relay is a page you cannot move');
  ok('all three engines are still inlined',
     ['WASM_SIMD_B64', 'WASM_PORTABLE_B64', 'JS_ONLY_MEM_B64', 'createYespowerJSOnly'].every(k => page.includes(k)));

  /* ---- B1. header serialization ------------------------------------------ */
  section('B. Consensus correctness');
  const hdr = S.hexToBytes(GENESIS_HEADER);
  ok('genesis header is 80 bytes', hdr.length === 80, hdr.length + ' bytes');
  const blockHash = S.bytesToHex(S.reverseBytes(S.sha256d(hdr)));
  ok('sha256d(genesis header) == chainparams block hash', blockHash === GENESIS_BLOCK, blockHash);
  ok('pool difficulty scale is Bitcoin-diff1 x 2^16',
     S.POOL_DIFF1 === S.DIFF1 * 65536n && S.DIFF1 === BigInt('0x00000000FFFF0000000000000000000000000000000000000000000000000000'));

  /* ---- B2. every engine must reproduce the real genesis PoW hash ---------- */
  const ctx = {
    module: { exports: {} }, exports: {}, require, console, process,
    TextDecoder, TextEncoder, Uint8Array, WebAssembly, __dirname: OUT,
    __filename: path.join(OUT, 'createYespower.js'), globalThis: null, URL, setTimeout,
  };
  ctx.globalThis = ctx; ctx.self = ctx;
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(OUT, 'createYespower.js'), 'utf8') + '\n;module.exports=createYespower;', ctx);
  const createYespower = ctx.module.exports;

  for (const build of ['wasm_simd.bin', 'wasm_portable.bin']) {
    const mod = await loadWasmBuild(createYespower, build);
    const pow = S.bytesToHex(S.reverseBytes(makeHasher(mod).hash(hdr, S.SUGAR_PARAMS)));
    ok(`${build.padEnd(18)} reproduces Sugarchain genesis PoW hash`, pow === GENESIS_POW, pow);
  }

  const { createYespowerJSOnly, mem } = loadJsOnlyEngine();
  if (!createYespowerJSOnly) {
    ok('pure-JavaScript engine present', false);
  } else {
    const bin = Buffer.from(mem, 'base64');
    const ab = new ArrayBuffer(bin.length); new Uint8Array(ab).set(bin);
    const mod = await createYespowerJSOnly({ memoryInitializerRequest: { status: 200, response: ab } });
    const pow = S.bytesToHex(S.reverseBytes(makeHasher(mod).hash(hdr, S.SUGAR_PARAMS)));
    ok('js-only engine     reproduces Sugarchain genesis PoW hash', pow === GENESIS_POW, pow);
  }

  /* ---- B3. difficulty / target maths ------------------------------------- */
  section('C. Difficulty maths');
  const perShare = d => Math.pow(2, 256) / Number(S.shareTargetFor(d));
  // exact values: 2^256 / shareTargetFor(d) = 65536 * 0.99 * d * 65536/65535
  ok('difficulty 1   -> 64881.6 hashes/share', Math.abs(perShare(1) - 64881.63) < 0.5, perShare(1).toFixed(1));
  ok('difficulty 0.5 -> 32440.8 hashes/share', Math.abs(perShare(0.5) - 32440.82) < 0.5, perShare(0.5).toFixed(1));
  ok('scales linearly with difficulty', Math.abs(perShare(2) - 2 * perShare(1)) / perShare(1) < 1e-9);
  ok('poolShareDiffFor(__) inverts shareTargetFor(__)', (() => {
    const t = S.shareTargetFor(0.5);
    // a hash exactly at the share target must read back as ~0.99 x difficulty
    const d = S.poolShareDiffFor(t);
    return Math.abs(d - 0.5 * 0.99) / (0.5 * 0.99) < 1e-6;
  })());
  ok('swapWords4Hex is its own inverse (prevhash convention)', (() => {
    const x = 'd95730d1f729e992a2e28bc7ba9fc7097e5f558c4bb5236d7d04a41414815a85';
    return S.swapWords4Hex(S.swapWords4Hex(x)) === x && S.swapWords4Hex(x) !== x;
  })());
  ok('nbitsToTarget(0x1f3fffff) == powlimit', S.nbitsToTarget('1f3fffff') === (BigInt(0x3fffff) << BigInt(8 * (0x1f - 3))));

  /* ---- B4. stratum wire format (offline) --------------------------------- */
  section('D. Stratum wire format');
  const job = S.parseJob(['deadbeef', 'd95730d1f729e992a2e28bc7ba9fc7097e5f558c4bb5236d7d04a41414815a85',
    'aa', 'bb', [], '20000000', '1f008a29', '6ab4edb0', true]);
  ok('parseJob un-swaps prevhash from notify order',
     job.prevhash === S.swapWords4Hex(job.prevhashNotify) && job.prevhash !== job.prevhashNotify);
  ok('parseJob keeps ntime as delivered', job.ntime === '6ab4edb0');
  const header = S.buildHeader(job, S.hexToBytes('00'.repeat(32)), 0x12345678);
  ok('header built from a job is 80 bytes', header.length === 80);
  ok('nonce is little-endian at offset 76',
     S.bytesToHex(header.subarray(76, 80)) === '78563412');

  /* ---- optional live check ----------------------------------------------- */
  if (process.env.SUGAR_LIVE === '1') {
    section('E. Live pool check (opt-in)');
    try {
      const net = require('net');
      const result = await new Promise((resolve, reject) => {
        const sock = net.connect(8451, 'stratum.poolab.org');
        let buf = '', got = false;
        const failsafe = setTimeout(() => reject(new Error('timeout')), 20000);
        sock.on('connect', () => sock.write(JSON.stringify({ id: 1, method: 'mining.subscribe', params: ['ci/1.0'] }) + '\n'));
        sock.on('data', d => {
          buf += d.toString();
          if (got) return;
          const m = /"result":\[\[.*?\],"(?:[0-9a-f]+)",(\d+)\]/.exec(buf);
          if (m) { got = true; clearTimeout(failsafe); sock.destroy(); resolve(m[1]); }
        });
        sock.on('error', e => { clearTimeout(failsafe); reject(e); });
      });
      ok('pool answers subscribe with an extranonce2 size', Number(result) === 4, 'size=' + result);
    } catch (e) {
      ok('pool reachable', false, e.message + ' (third-party pool; not a build failure)');
    }
  } else {
    section('E. Live pool check skipped (set SUGAR_LIVE=1 to enable)');
  }

  /* ---- summary ------------------------------------------------------------ */
  console.log(`\n${failures ? '✗ FAILED' : '✓ PASSED'} — ${checks - failures}/${checks} checks`);
  process.exit(failures ? 1 : 0);
})().catch(e => { console.error('\nharness error:', e); process.exit(2); });
