/* ============================================================================
 * sugar_wallet.js — SUGAR wallet generation, in the browser, with no library.
 *
 * Pure JS: SHA-256, RIPEMD-160, secp256k1, bech32, base58check.
 * The private key is generated with crypto.getRandomValues and NEVER leaves the
 * page. The server only ever sees the public address.
 *
 * Address format follows sugarchain-project/sugarchain (src/chainparams.cpp):
 *   mainnet  bech32_hrp = "sugar"   WIF prefix 0x80   P2PKH 0x3F
 *   testnet  bech32_hrp = "tugar"   WIF prefix 0xEF
 * so a mainnet address is sugar1q... — which is exactly what the mining SDK's
 * address check accepts.
 * ==========================================================================*/
(function (root) {
  'use strict';

  // ────────────────────────────────────────────────────────────── SHA-256 ──
  const SHA_K = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  function sha256(bytes) {
    const msg = toBytes(bytes);
    const bitLen = msg.length * 8;
    const withPad = new Uint8Array((((msg.length + 9) >> 6) + 1) << 6);
    withPad.set(msg);
    withPad[msg.length] = 0x80;
    const dv = new DataView(withPad.buffer);
    dv.setUint32(withPad.length - 4, bitLen >>> 0, false);
    dv.setUint32(withPad.length - 8, Math.floor(bitLen / 4294967296), false);

    let [h0, h1, h2, h3, h4, h5, h6, h7] = [
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];
    const w = new Uint32Array(64);
    const rr = (x, n) => ((x >>> n) | (x << (32 - n))) >>> 0;

    for (let i = 0; i < withPad.length; i += 64) {
      for (let t = 0; t < 16; t++) w[t] = dv.getUint32(i + t * 4, false);
      for (let t = 16; t < 64; t++) {
        const s0 = rr(w[t - 15], 7) ^ rr(w[t - 15], 18) ^ (w[t - 15] >>> 3);
        const s1 = rr(w[t - 2], 17) ^ rr(w[t - 2], 19) ^ (w[t - 2] >>> 10);
        w[t] = (w[t - 16] + s0 + w[t - 7] + s1) >>> 0;
      }
      let [a, b, c, d, e, f, g, h] = [h0, h1, h2, h3, h4, h5, h6, h7];
      for (let t = 0; t < 64; t++) {
        const S1 = rr(e, 6) ^ rr(e, 11) ^ rr(e, 25);
        const ch = (e & f) ^ (~e & g);
        const t1 = (h + S1 + ch + SHA_K[t] + w[t]) >>> 0;
        const S0 = rr(a, 2) ^ rr(a, 13) ^ rr(a, 22);
        const maj = (a & b) ^ (a & c) ^ (b & c);
        const t2 = (S0 + maj) >>> 0;
        h = g; g = f; f = e; e = (d + t1) >>> 0;
        d = c; c = b; b = a; a = (t1 + t2) >>> 0;
      }
      h0 = (h0 + a) >>> 0; h1 = (h1 + b) >>> 0; h2 = (h2 + c) >>> 0; h3 = (h3 + d) >>> 0;
      h4 = (h4 + e) >>> 0; h5 = (h5 + f) >>> 0; h6 = (h6 + g) >>> 0; h7 = (h7 + h) >>> 0;
    }
    const out = new Uint8Array(32);
    const odv = new DataView(out.buffer);
    [h0, h1, h2, h3, h4, h5, h6, h7].forEach((x, idx) => odv.setUint32(idx * 4, x, false));
    return out;
  }

  // ──────────────────────────────────────────────────────────── RIPEMD-160 ──
  const RL = [
    [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15],
    [7,4,13,1,10,6,15,3,12,0,9,5,2,14,11,8],
    [3,10,14,4,9,15,8,1,2,7,0,6,13,11,5,12],
    [1,9,11,10,0,8,12,4,13,3,7,15,14,5,6,2],
    [4,0,5,9,7,12,2,10,14,1,3,8,11,6,15,13],
  ];
  const RR = [
    [5,14,7,0,9,2,11,4,13,6,15,8,1,10,3,12],
    [6,11,3,7,0,13,5,10,14,15,8,12,4,9,1,2],
    [15,5,1,3,7,14,6,9,11,8,12,2,10,0,4,13],
    [8,6,4,1,3,11,15,0,5,12,2,13,9,7,10,14],
    [12,15,10,4,1,5,8,7,6,2,13,14,0,3,9,11],
  ];
  const SL = [
    [11,14,15,12,5,8,7,9,11,13,14,15,6,7,9,8],
    [7,6,8,13,11,9,7,15,7,12,15,9,11,7,13,12],
    [11,13,6,7,14,9,13,15,14,8,13,6,5,12,7,5],
    [11,12,14,15,14,15,9,8,9,14,5,6,8,6,5,12],
    [9,15,5,11,6,8,13,12,5,12,13,14,11,8,5,6],
  ];
  const SR = [
    [8,9,9,11,13,15,15,5,7,7,8,11,14,14,12,6],
    [9,13,15,7,12,8,9,11,7,7,12,7,6,15,13,11],
    [9,7,15,11,8,6,6,14,12,13,5,14,13,13,7,5],
    [15,5,8,11,14,14,6,14,6,9,12,9,12,5,15,8],
    [8,5,12,9,12,5,14,6,8,13,6,5,15,13,11,11],
  ];
  const KL = [0x00000000, 0x5a827999, 0x6ed9eba1, 0x8f1bbcdc, 0xa953fd4e];
  const KR = [0x50a28be6, 0x5c4dd124, 0x6d703ef3, 0x7a6d76e9, 0x00000000];
  const rol = (x, n) => ((x << n) | (x >>> (32 - n))) >>> 0;
  const f1 = (x, y, z) => (x ^ y ^ z) >>> 0;
  const f2 = (x, y, z) => ((x & y) | (~x & z)) >>> 0;
  const f3 = (x, y, z) => ((x | ~y) ^ z) >>> 0;
  const f4 = (x, y, z) => ((x & z) | (y & ~z)) >>> 0;
  const f5 = (x, y, z) => (x ^ (y | ~z)) >>> 0;

  function ripemd160(bytes) {
    const msg = toBytes(bytes);
    const bitLen = msg.length * 8;
    const padded = new Uint8Array((((msg.length + 9) >> 6) + 1) << 6);
    padded.set(msg);
    padded[msg.length] = 0x80;
    const dv = new DataView(padded.buffer);
    dv.setUint32(padded.length - 8, bitLen >>> 0, true);
    dv.setUint32(padded.length - 4, Math.floor(bitLen / 4294967296), true);

    let [h0, h1, h2, h3, h4] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0];
    const x = new Uint32Array(16);
    const FL = [f1, f2, f3, f4, f5];
    const FR = [f5, f4, f3, f2, f1];

    for (let i = 0; i < padded.length; i += 64) {
      for (let t = 0; t < 16; t++) x[t] = dv.getUint32(i + t * 4, true);
      let [al, bl, cl, dl, el] = [h0, h1, h2, h3, h4];
      let [ar, br, cr, dr, er] = [h0, h1, h2, h3, h4];
      for (let r = 0; r < 5; r++) {
        for (let j = 0; j < 16; j++) {
          let t = (al + FL[r](bl, cl, dl) + x[RL[r][j]] + KL[r]) >>> 0;
          t = (rol(t, SL[r][j]) + el) >>> 0;
          al = el; el = dl; dl = rol(cl, 10); cl = bl; bl = t;

          t = (ar + FR[r](br, cr, dr) + x[RR[r][j]] + KR[r]) >>> 0;
          t = (rol(t, SR[r][j]) + er) >>> 0;
          ar = er; er = dr; dr = rol(cr, 10); cr = br; br = t;
        }
      }
      const t = (h1 + cl + dr) >>> 0;
      h1 = (h2 + dl + er) >>> 0;
      h2 = (h3 + el + ar) >>> 0;
      h3 = (h4 + al + br) >>> 0;
      h4 = (h0 + bl + cr) >>> 0;
      h0 = t;
    }
    const out = new Uint8Array(20);
    const odv = new DataView(out.buffer);
    [h0, h1, h2, h3, h4].forEach((v, i) => odv.setUint32(i * 4, v, true));
    return out;
  }

  const hash160 = (bytes) => ripemd160(sha256(bytes));

  // ───────────────────────────────────────────────────────────── secp256k1 ──
  const P = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2fn;
  const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
  const GX = 0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798n;
  const GY = 0x483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8n;

  const mod = (a, m = P) => ((a % m) + m) % m;
  const inv = (a, m = P) => {           // Fermat inverse — m is prime
    let r = 1n, b = mod(a, m), e = m - 2n;
    while (e > 0n) { if (e & 1n) r = mod(r * b, m); b = mod(b * b, m); e >>= 1n; }
    return r;
  };

  function pointAdd(p1, p2) {
    if (!p1) return p2;
    if (!p2) return p1;
    const [x1, y1] = p1, [x2, y2] = p2;
    if (x1 === x2 && mod(y1 + y2) === 0n) return null;      // P + (-P) = O
    let lam;
    if (x1 === x2 && y1 === y2) lam = mod(3n * x1 * x1 * inv(2n * y1));
    else lam = mod((y2 - y1) * inv(x2 - x1));
    const x3 = mod(lam * lam - x1 - x2);
    const y3 = mod(lam * (x1 - x3) - y1);
    return [x3, y3];
  }

  function pointMul(k, point) {
    let result = null, addend = point;
    while (k > 0n) {
      if (k & 1n) result = pointAdd(result, addend);
      addend = pointAdd(addend, addend);
      k >>= 1n;
    }
    return result;
  }

  const toHex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
  const fromHex = (hex) => {
    const clean = String(hex).trim().replace(/^0x/i, '').replace(/\s/g, '');
    if (!/^[0-9a-fA-F]*$/.test(clean) || clean.length % 2) throw new Error('not hex');
    const out = new Uint8Array(clean.length / 2);
    for (let i = 0; i < out.length; i++) out[i] = parseInt(clean.substr(i * 2, 2), 16);
    return out;
  };
  const bigToBytes = (v, len = 32) => {
    const h = v.toString(16).padStart(len * 2, '0');
    if (h.length > len * 2) throw new Error('number too large');
    return fromHex(h);
  };
  const bytesToBig = (b) => BigInt('0x' + (toHex(b) || '0'));

  function toBytes(input) {
    if (input instanceof Uint8Array) return input;
    if (typeof input === 'string') return new TextEncoder().encode(input);
    throw new Error('expected string or Uint8Array');
  }

  // ───────────────────────────────────────────────── bech32 (BIP-173/350) ──
  const CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

  function bech32Polymod(values) {
    const GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
    let chk = 1;
    for (const v of values) {
      const top = chk >> 25;
      chk = ((chk & 0x1ffffff) << 5) ^ v;
      for (let i = 0; i < 5; i++) if ((top >> i) & 1) chk ^= GEN[i];
    }
    return chk;
  }
  const hrpExpand = (hrp) =>
    [...hrp].map((c) => c.charCodeAt(0) >> 5).concat([0], [...hrp].map((c) => c.charCodeAt(0) & 31));

  function convertBits(data, fromBits, toBits, pad) {
    let acc = 0, bits = 0;
    const out = [];
    const maxv = (1 << toBits) - 1;
    for (const value of data) {
      acc = (acc << fromBits) | value;
      bits += fromBits;
      while (bits >= toBits) { bits -= toBits; out.push((acc >> bits) & maxv); }
    }
    if (pad && bits) out.push((acc << (toBits - bits)) & maxv);
    return out;
  }

  function bech32Encode(hrp, witver, witprog) {
    const data = [witver].concat(convertBits(Array.from(witprog), 8, 5, true));
    const polymod = bech32Polymod(hrpExpand(hrp).concat(data).concat([0, 0, 0, 0, 0, 0])) ^ 1;
    const checksum = [0, 1, 2, 3, 4, 5].map((i) => (polymod >> (5 * (5 - i))) & 31);
    return hrp + '1' + data.concat(checksum).map((d) => CHARSET[d]).join('');
  }

  function bech32Decode(addr) {
    if (typeof addr !== 'string' || addr.length < 8 || addr.length > 90) return null;
    if (addr !== addr.toLowerCase() && addr !== addr.toUpperCase()) return null;
    const lower = addr.toLowerCase();
    const pos = lower.lastIndexOf('1');
    if (pos < 1 || pos + 7 > lower.length) return null;
    const hrp = lower.slice(0, pos);
    const data = [];
    for (const c of lower.slice(pos + 1)) {
      const v = CHARSET.indexOf(c);
      if (v < 0) return null;
      data.push(v);
    }
    if (bech32Polymod(hrpExpand(hrp).concat(data)) !== 1) return null;
    const witver = data[0];
    const prog = convertBits(data.slice(1, -6), 5, 8, false);
    return { hrp, witver, program: new Uint8Array(prog), words: data.length - 7 };
  }

  // ───────────────────────────────────────────────────────── base58check ──
  const B58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  function base58Encode(bytes) {
    let num = bytesToBig(bytes), out = '';
    while (num > 0n) { out = B58[Number(num % 58n)] + out; num /= 58n; }
    for (const b of bytes) { if (b === 0) out = '1' + out; else break; }
    return out;
  }
  function base58Check(payload) {
    const checksum = sha256(sha256(payload)).slice(0, 4);
    const both = new Uint8Array(payload.length + 4);
    both.set(payload); both.set(checksum, payload.length);
    return base58Encode(both);
  }

  // ─────────────────────────────────────────────────────────────── wallet ──
  const NETWORKS = {
    mainnet: { hrp: 'sugar', wif: 0x80, label: 'SUGAR mainnet' },
    testnet: { hrp: 'tugar', wif: 0xef, label: 'SUGAR testnet' },
  };

  function randomPrivateKey() {
    const bytes = new Uint8Array(32);
    const g = root.crypto || root.msCrypto;
    if (!g || !g.getRandomValues) throw new Error('no secure random source in this browser');
    for (let tries = 0; tries < 64; tries++) {
      g.getRandomValues(bytes);
      const k = bytesToBig(bytes);
      if (k > 0n && k < N) return bytes;      // the 1-in-2^127 rejection case
    }
    throw new Error('could not generate a key');
  }

  function publicKey(privateKeyBytes) {
    const k = bytesToBig(privateKeyBytes);
    if (k <= 0n || k >= N) throw new Error('private key out of range');
    const [x, y] = pointMul(k, [GX, GY]);
    const out = new Uint8Array(33);           // compressed: 02/03 || X
    out[0] = (y & 1n) === 0n ? 0x02 : 0x03;
    out.set(bigToBytes(x, 32), 1);
    return out;
  }

  function fromPrivateKey(privateKeyHex, network = 'mainnet') {
    const net = NETWORKS[network] || NETWORKS.mainnet;
    const priv = fromHex(privateKeyHex);
    if (priv.length !== 32) throw new Error('private key must be 32 bytes');
    const pub = publicKey(priv);
    const h160 = hash160(pub);
    const address = bech32Encode(net.hrp, 0, h160);                  // P2WPKH
    const wifBytes = new Uint8Array(34);
    wifBytes[0] = net.wif;
    wifBytes.set(priv, 1);
    wifBytes[33] = 0x01;                                            // compressed
    return {
      network,
      privateKeyHex: toHex(priv),
      wif: base58Check(wifBytes),
      publicKeyHex: toHex(pub),
      hash160Hex: toHex(h160),
      address,
      legacyAddress: base58Check(
        new Uint8Array([0x3f, ...h160])                                // P2PKH, "S…"
      ),
    };
  }

  const create = (network = 'mainnet') => fromPrivateKey(toHex(randomPrivateKey()), network);

  /** Acceptance check for a mining payout address, mirroring the SDK's own test. */
  function checkAddress(address) {
    const rows = [];
    const s = String(address || '').trim();
    const decoded = bech32Decode(s);
    rows.push(['bech32 checksum', !!decoded, decoded ? 'valid' : 'not a valid bech32 string']);
    if (!decoded) return rows;
    rows.push(['network prefix', decoded.hrp === 'sugar' || decoded.hrp === 'tugar',
      decoded.hrp === 'sugar' ? 'mainnet (sugar)' : decoded.hrp === 'tugar' ? 'testnet (tugar)' : `unknown (${decoded.hrp})`]);
    rows.push(['witness version', decoded.witver === 0, decoded.witver === 0 ? 'v0 (P2WPKH)' : `v${decoded.witver}`]);
    rows.push(['program length', decoded.program.length === 20, `${decoded.program.length} bytes (20 = single key)`]);
    rows.push(['SDK pattern', /^(sugar1|tugar1)[0-9a-z]{25,}$/.test(s), 'matches what the SDK accepts']);
    rows.push(['can you spend from it', null, 'only if you hold the key — see the backup step']);
    return rows;
  }

  const api = {
    sha256, ripemd160, hash160, toHex, fromHex,
    bech32Encode, bech32Decode, base58Check,
    create, fromPrivateKey, publicKey, checkAddress, NETWORKS,
  };
  root.SugarWallet = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
