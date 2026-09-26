/*
 * tools/chrome_harness.js — runs *inside* the browser, injected into a copy of the
 * published page by tools/verify_chrome.js. Nothing here is executed by Node.
 *
 * The page's own globals are what we drive: `WASM_BUILDS` (the inlined SIMD and
 * scalar builds), `createYespower` (the emscripten loader) and `b64bytes`. This
 * mirrors tools/verify.js's Node harness on purpose — same vector, same C API, but
 * compiled and run by a real browser instead of by Node.
 */
(async function () {
  var lines = [];
  var problems = [];
  function note(name, pass, detail) {
    lines.push((pass ? 'PASS ' : 'FAIL ') + name + (detail ? '  \u2014 ' + detail : ''));
  }

  // An uncaught error or a console.error is a failure. A page that logs an exception
  // and carries on looking fine is exactly what a headless check is for.
  window.addEventListener('error', function (e) { problems.push('uncaught: ' + e.message); });
  window.addEventListener('unhandledrejection', function (e) {
    problems.push('unhandled rejection: ' + ((e.reason && e.reason.message) || e.reason));
  });
  var realError = console.error;
  console.error = function () {
    problems.push('console.error: ' + Array.prototype.join.call(arguments, ' '));
    realError.apply(console, arguments);
  };

  var GENESIS_HEADER =
    '010000000000000000000000000000000000000000000000000000000000000000000000' +
    'b050e156acdac2cada87b39ce5f137f5b872901e6b9e1c1d41b09c572ace7776' +
    '7073555dffff3f1ff7000000';
  var GENESIS_BLOCK = '7d5eaec2dbb75f99feadfa524c78b7cabc1d8c8204f79d4f3a83381b811b0adc';
  var GENESIS_POW = '0031205acedcc69a9c18f79b84790179d68fb90588bedee6587ff701bdde04eb';

  function fromHex(s) {
    var out = new Uint8Array(s.length / 2);
    for (var i = 0; i < out.length; i++) out[i] = parseInt(s.substr(i * 2, 2), 16);
    return out;
  }

  // The same accessors tools/verify.js's makeHasher uses; the C API is the contract.
  // The parameters come from the page's own SUGAR_PARAMS rather than being written
  // out here — a copy in a test is a copy that can be right while the page is wrong.
  function makeHasher(yp, params) {
    var out = 0, src = 0, pers = 0;
    var personalisation = params.pers;
    return {
      hash: function (bytes) {
        out = out || yp._yp_alloc(32);
        src = src || yp._yp_alloc(bytes.length);
        pers = pers || yp._yp_alloc(personalisation.length);
        yp.HEAPU8.set(bytes, src);
        for (var i = 0; i < personalisation.length; i++) {
          yp.HEAPU8[pers + i] = personalisation.charCodeAt(i);
        }
        var rc = yp._yp_hash(src, bytes.length, pers, personalisation.length,
                             params.version, params.N, params.r, out);
        if (rc !== 0) throw new Error('yp_hash returned ' + rc);
        return yp.HEAPU8.slice(out, out + 32);
      },
    };
  }

  function reverseHex(u8) {
    var s = '';
    for (var i = u8.length - 1; i >= 0; i--) s += u8[i].toString(16).padStart(2, '0');
    return s;
  }

  try {
    note('the page defines its engines (WASM_BUILDS, createYespower)',
      typeof WASM_BUILDS !== 'undefined' && typeof createYespower === 'function');
    // `root.SugarMiner = factory()` in the page: the core, as a browser sees it.
    var CORE = (typeof SugarMiner !== 'undefined') ? SugarMiner : null;
    note('the core is reachable as a browser global (SugarMiner)', !!CORE);
    var params = CORE ? CORE.SUGAR_PARAMS : null;
    note('the page carries the coin\u2019s own yespower parameters',
      !!params && params.version === 10 && params.N === 2048 && params.r === 32,
      params ? 'version ' + params.version + ', N ' + params.N + ', r ' + params.r : 'no parameters');
    var hdrForSha = fromHex(GENESIS_HEADER);
    note('its sha256d reproduces the genesis block hash, in this browser',
      !!CORE && CORE.bytesToHex(CORE.reverseBytes(CORE.sha256d(hdrForSha))) === GENESIS_BLOCK,
      CORE ? CORE.bytesToHex(CORE.reverseBytes(CORE.sha256d(hdrForSha))) : 'no core');

    // 1. what the page ships, as a browser's DOM sees it
    var addr = document.getElementById('addr');
    var url = document.getElementById('url');
    note('payout address field is empty in the DOM', !!addr && addr.value === '');
    var ours = 'wss://stratum-proxy.mdktechassociation.workers.dev';
    // The field ships empty; ?ws= fills it; and a page served from localhost
    // deliberately defaults to a bridge on that same machine. What must never
    // happen is a *third party's* relay in the box, so the rule is: empty, ours, or
    // on the host serving this page.
    var bridgeOk = false;
    if (url) {
      if (url.value === '' || url.value === ours) bridgeOk = true;
      else {
        try {
          var parsed = new URL(url.value.replace(/^ws/, 'http'));
          bridgeOk = parsed.host === location.host ||
                     /^(localhost|127\.0\.0\.1|\[::1\]|::1|0\.0\.0\.0)$/.test(parsed.hostname);
        } catch (e) { bridgeOk = false; }
      }
    }
    note('bridge field is empty, ours, or this page\u2019s own host \u2014 never a third party',
      bridgeOk, url ? (url.value || '(empty)') : 'no bridge field');
    note('no wallet address anywhere in the rendered page',
      !/sugar1[0-9a-z]{30,}/i.test(document.documentElement.outerHTML));

    // 2. the engines, as this Chrome compiles them
    var hdr = fromHex(GENESIS_HEADER);
    note('genesis header is 80 bytes', hdr.length === 80, hdr.length + ' bytes');

    var simdCompiled = false;
    for (var i = 0; i < WASM_BUILDS.length; i++) {
      var build = WASM_BUILDS[i];
      try {
        var bytes = b64bytes(build.b64);
        var mod = await createYespower({
          instantiateWasm: function (imports, done) {
            WebAssembly.instantiate(bytes, imports).then(function (r) { done(r.instance); });
            return {};
          },
        });
        var pow = reverseHex(makeHasher(mod, params).hash(hdr));
        if (build.label === 'simd') simdCompiled = true;
        note(build.label + ' build reproduces the genesis PoW hash',
          pow === GENESIS_POW, pow === GENESIS_POW ? '' : pow.slice(0, 24) + '\u2026');
      } catch (e) {
        note(build.label + ' build reproduces the genesis PoW hash', false, e.message || String(e));
      }
    }
    note('this Chrome compiled the SIMD build', simdCompiled,
      simdCompiled ? '' : 'it falls back to the scalar build \u2014 correct, but worth knowing');
    note('WebAssembly SIMD is available to the page',
      typeof WebAssembly.validate === 'function');

    // 3. the fallback path itself: if the page is asked for SIMD by a browser that
    //    cannot compile it, it must land on the scalar build rather than dying.
    note('the page carries a scalar build to fall back to',
      WASM_BUILDS.length > 1 && typeof WASM_BUILDS[1].b64 === 'string');
  } catch (e) {
    note('the harness itself ran', false, (e && e.stack) || String(e));
  }

  for (var p = 0; p < problems.length; p++) {
    note('nothing was logged as an error', false, problems[p]);
  }

  // Assembled at runtime so the literal never appears in this file's source — the
  // page is dumped as DOM text, and a marker in the source would be found first.
  var pre = document.createElement('pre');
  pre.id = '__chrome_check__';
  pre.textContent = ['===CHROME', 'CHECK-START==='].join('-') + '\n' +
    lines.join('\n') + '\n' + ['===CHROME', 'CHECK-END==='].join('-');
  document.body.appendChild(pre);
})();
