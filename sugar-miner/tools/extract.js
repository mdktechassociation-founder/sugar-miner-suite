/**
 * tools/extract.js — pull the self-contained miner apart.
 *
 * The shipped page inlines everything: the JS mining core, two webassembly builds
 * (base64) and a pure-JavaScript fallback build. CI needs them as separate files,
 * so this writes them into a scratch directory.
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const PAGE = process.env.SUGAR_PAGE || path.join(ROOT, 'site', 'index.html');
const OUT = process.env.SUGAR_OUT || path.join(ROOT, '.build', 'extracted');

function between(src, startRe, endRe, label, back = 0) {
  const lines = src.split('\n');
  let start = lines.findIndex(l => startRe.test(l));
  start -= back;                       // the comment's opening /* lives on the line above
  if (start < 0) throw new Error(`could not find start of ${label}`);
  let end = -1;
  for (let i = start + 1; i < lines.length; i++) if (endRe.test(lines[i])) { end = i; break; }
  if (end < 0) throw new Error(`could not find end of ${label}`);
  return lines.slice(start, end).join('\n');
}

function extract() {
  const src = fs.readFileSync(PAGE, 'utf8');
  fs.mkdirSync(OUT, { recursive: true });

  const grab = name => {
    const m = new RegExp(`var ${name}\\s*=\\s*"([^"]+)"`).exec(src);
    if (!m) throw new Error(`missing embedded constant ${name}`);
    return m[1];
  };
  const writeB64 = (name, file) => {
    const buf = Buffer.from(grab(name), 'base64');
    if (buf.slice(0, 4).toString('hex') !== '0061736d' && !file.endsWith('mem.bin')) {
      throw new Error(`${name} is not a wasm module (bad magic)`);
    }
    fs.writeFileSync(path.join(OUT, file), buf);
    return buf.length;
  };

  // the transport-agnostic mining core
  const core = between(src, /^\s*\*\s*core\.js - transport-agnostic/, /^<\/script>/, 'core.js', 1);
  fs.writeFileSync(path.join(OUT, 'core.js'), core);

  // the emscripten loader used by the wasm builds
  const loader = between(src, /^var createYespower=\(\(\)=>/, /^<\/script>$/, 'createYespower loader');
  fs.writeFileSync(path.join(OUT, 'createYespower.js'), loader);

  // the pure-JavaScript engine + its inlined static memory (handed over as base64)
  const jsOnly = between(src, /^var JS_ONLY_MEM_B64/, /^<\/script>/, 'js-only engine');
  fs.writeFileSync(path.join(OUT, 'jsonly.js'), jsOnly);
  const mem = Buffer.from(grab('JS_ONLY_MEM_B64'), 'base64');
  fs.writeFileSync(path.join(OUT, 'yespower.jsonly.js.mem'), mem);   // emscripten node path wants this file

  const sizes = {
    wasm_simd: writeB64('WASM_SIMD_B64', 'wasm_simd.bin'),
    wasm_portable: writeB64('WASM_PORTABLE_B64', 'wasm_portable.bin'),
    js_only_mem: mem.length,
  };
  return { page: PAGE, out: OUT, sizes };
}

module.exports = { extract, OUT, PAGE };

if (require.main === module) {
  const r = extract();
  console.log('extracted from', r.page);
  console.log('  ->', r.out);
  for (const [k, v] of Object.entries(r.sizes)) console.log(`     ${k.padEnd(14)} ${v} bytes`);
}
