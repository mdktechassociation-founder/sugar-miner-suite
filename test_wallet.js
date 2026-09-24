/* Wallet math tests. Run: node minehub/test_wallet.js
 * Every expectation here is a published test vector, not a value this code
 * produced — that is the whole point. BIP-173 (bech32), the SHA/RIPEMD
 * standard vectors, and Bitcoin's well-known privkey-1 WIF. */
const W = require('./src/sugar_wallet.js');

let pass = 0, fail = 0;
function eq(name, got, want) {
  const ok = String(got).toLowerCase() === String(want).toLowerCase();
  console.log(`${ok ? '  ✓' : '  ✗'} ${name}`);
  if (!ok) { console.log(`      got  ${got}\n      want ${want}`); fail++; } else pass++;
}

console.log('hashing');
eq('sha256("")', W.toHex(W.sha256('')), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
eq('sha256("abc")', W.toHex(W.sha256('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
eq('ripemd160("")', W.toHex(W.ripemd160('')), '9c1185a5c5e9fc54612808977ee8f548b2258d31');
eq('ripemd160("abc")', W.toHex(W.ripemd160('abc')), '8eb208f7e05d987a9b044a8e98c6b087f15a0bfc');
eq('ripemd160("message digest")', W.toHex(W.ripemd160('message digest')), '5d0689ef49d2fae572b881b123a85ffa21595f36');
eq('ripemd160("a".repeat(1000000))',
   W.toHex(W.ripemd160('a'.repeat(1000000))), '52783243c1697bdbe16d37f97f68f08325dc1528');

console.log('\nsecp256k1 + BIP-173 test vector (privkey 1)');
const k1 = W.fromPrivateKey('0'.repeat(63) + '1', 'mainnet');
eq('public key is G', k1.publicKeyHex,
   '0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798');
eq('hash160(redeem key)', k1.hash160Hex, '751e76e8199196d454941c45d1b3a323f1433bd6');
// BIP-173's canonical example: same key, hrp "bc"
eq('BIP-173 example (hrp bc)', W.bech32Encode('bc', 0, W.fromHex('751e76e8199196d454941c45d1b3a323f1433bd6')),
   'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4');
eq('WIF (compressed, mainnet)', k1.wif, 'KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73sVHnoWn');
eq('our P2WPKH, hrp sugar', k1.address,
   W.bech32Encode('sugar', 0, W.fromHex('751e76e8199196d454941c45d1b3a323f1433bd6')));

console.log('\nround-trip: address decodes back to the same key hash');
const dec = W.bech32Decode(k1.address);
eq('decoded hrp', dec.hrp, 'sugar');
eq('decoded program', W.toHex(dec.program), k1.hash160Hex);

console.log('\n20 random wallets');
let rate = 0;
for (let i = 0; i < 20; i++) {
  const w = W.create('mainnet');
  const ok = /^sugar1q[0-9a-z]{25,}$/.test(w.address) && W.checkAddress(w.address).every((r) => r[1] !== false);
  if (ok) rate++;
  else console.log('      bad:', w.address);
}
eq('20/20 valid sugar1q addresses', rate, 20);
const t = W.create('testnet');
eq('testnet address starts tugar1q', t.address.startsWith('tugar1q'), true);

console.log('\naddress check rejects nonsense');
eq('empty', W.checkAddress('')[0][1], false);
eq('bitcoin address', W.checkAddress('bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4')[0][1], true);
eq('...but flagged as unknown network',
   W.checkAddress('bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4')[1][1], false);
eq('one char changed fails checksum',
   W.checkAddress('sugar1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5')[0][1], false);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
