# Keys and phrases — what is true for each Sugarchain wallet

Checked against the wallets themselves, on 2026-09-25. Nothing here is remembered or
assumed; the evidence is stated under each answer so you can re-check it.

---

## The two questions, answered

### 1. "Is the WIF mandatory for the original wallet?" — **Yes. And it is enough.**

Sugarchain Core's only single-key import is a WIF:

```
importprivkey "privkey" ( "label" ) ( rescan )
  Adds a private key (as returned by dumpprivkey) to your wallet.
```

`src/wallet/rpcdump.cpp` — verified against the tree, branch `master-v0.16.3`.

**And one WIF covers the whole wallet.** `importprivkey` calls `AddKeyPubKey` and then
`LearnAllRelatedScripts`, which registers three destinations for that one key:

```cpp
CTxDestination segwit = WitnessV0KeyHash(keyid);
CTxDestination p2sh   = CScriptID(GetScriptForDestination(segwit));
return std::vector<CTxDestination>{keyid, p2sh, segwit};
```

That means importing a WIF teaches Core all three of your addresses:

| what the key makes | address | covered by `importprivkey`? |
|---|---|---|
| legacy P2PKH | `S…` | ✅ |
| P2SH-wrapped segwit | `s…` | ✅ |
| native bech32 (the one this app mines to) | `sugar1q…` | ✅ |

So a WIF alone is enough for Core to see **and spend** coins mined to this app's
`sugar1q…` address. You do not need to export anything else.

### 2. "Sugarchain has no seed phrase" — **true of Core, false of the Android wallet.**

**Core: no words.** The strings `bip39` and `mnemonic` appear **0 times** in its entire
`src/` tree. Its HD wallet is a raw key derived at `m/0'/0'/k'` (`src/wallet/wallet.cpp`),
it has no `sethdseed` RPC in this version, and its restorable-to-a-person formats are a
WIF, `wallet.dat`, and `dumpwallet` — the last two readable only by Core.

**The official Android wallet: words.** That repository ships **no source**, only APKs — so
the released `Sugar-Wallet-1.0.3.apk` was unpacked and its JavaScript bundle read:

```js
function _(t, n = "m/44'/0'/0'/0", …) { bip39.mnemonicToSeed(t) … derivePath(n + '/' + i) }
```

BIP-39 words, following BIP-32 — confirmed present in the binary.

`bip39` appears in the APK's JS bundle; `bitcoinj`, `xprv`, `xpub` and BIP-32 paths other
than the one above do not. It walks the standard library, so it takes the standard list.

---

## The trap: words alone do not identify a wallet

The official Android wallet derives at **coin type 0** — Bitcoin's — not Sugarchain's
registered coin type **408** (SLIP-0044). The same twelve words, two different wallets:

| derived at | address |
|---|---|
| `m/44'/408'/0'/0/0` — this app, and the SLIP-44 standard | `sugar1q3828kzacg6yp9f5tply4yrtgtu20kqt3wu52j6` |
| `m/44'/0'/0'/0/0` — the official Android wallet | `sugar1qmxrw6qdh5g3ztfcwm0et5l8mvws4eva2trdxdy` |

(From `abandon abandon … about`, computed with `bip-utils`.)

This fails **silently**: restoring at the wrong path shows an empty wallet and no error
anywhere. That is why this app's import field asks which wallet a phrase came from
whenever the input is words, and why both paths are pinned by tests.

---

## What to keep, and where each form restores

| you keep | restores in | notes |
|---|---|---|
| **the WIF** | Core (`importprivkey`), the web wallet, this app | the only form **every** Sugarchain wallet accepts — keep this one |
| **the twelve words** | this app, and BIP-39 wallets following BIP-44 at coin type 408 | also restores in the official Android wallet *if* it is told path 0 — and by default it uses 0, so words from *it* need this app's "official Android wallet" option |
| **the xprv** | any wallet with a BIP-32 tab, including the web wallet | one key for a whole tree of addresses |
| **the backup file (JSON)** | this app's import field | contains all of the above |

**The rules that follow from the evidence:**

- **Words can always produce the WIF.** Any BIP-39 wallet derives it; this app shows it
  next to the phrase.
- **A WIF can never produce words.** There is nothing to recover: words are a way of
  encoding a seed, and a raw key was never made from one. If your wallet was created as
  a raw key, that WIF is everything there is.
- **If you want one backup that works everywhere, make it the WIF** — words are portable
  only between wallets that agree on the path.

---

## What this app does about it

- Creates wallets from **twelve words** (default) or a **raw key**, entirely on the device.
- Shows the words numbered, plus the WIF, the hex key, the xprv and a backup file.
- **Import accepts all four forms**, and asks which wallet a phrase came from.
- The crypto is pinned by **61 vectors**, including both derivation paths against a
  second implementation, and one test asserting the two paths really do produce
  different wallets rather than quietly the same one.

## For the record: Core's import RPCs

| RPC | takes | gives you |
|---|---|---|
| `importprivkey` | a WIF | the key, and all three of its addresses — **this is the one** |
| `importaddress` / `importpubkey` | address / public key | watch only, cannot spend |
| `importwallet` / `importmulti` | a `dumpwallet` file, or scripts+keys | bulk restore inside Core only |

---

## The short version: this wallet works anywhere a WIF works

There is one secret and it has one standard form. `w.wif` is a normal Sugarchain
mainnet WIF — base58check, prefix `0x80`, compressed-key marker — so pasting it into
another wallet produces the same wallet, not a similar one:

| paste the WIF into | what you get |
|---|---|
| **Sugarchain Core** — `importprivkey <wif>` | the key, and **all of its addresses**, because Core scans the chain for every script form a single key can own (`LearnAllRelatedScripts`). Spending from Core then works for whichever of them holds the coins. |
| **the web wallet** (coinbin-derived) | the same wallet from the WIF, or from the xprv if you prefer to give it the extended key |
| **this app**, by pasting the WIF back | the same wallet, the same two addresses, the same coins |
| a BIP-39 wallet | not the WIF — that one wants the **twelve words**, at coin type 408 |

### One key, two addresses

A single key controls two addresses, and both of them are this wallet:

| | `sugar1q…` — P2WPKH (native segwit) | `S…` — P2PKH (legacy) |
|---|---|---|
| where it comes from | this app, the mining SDK, the official Android wallet | Core, the web wallet, any old tool |
| receiving | yes | yes — the receive screen hands out whichever you pick |
| spending | yes, signed with BIP-143 | yes, signed the pre-segwit way |
| cost to spend a coin | 68 vB | 148 vB — more than twice |
| mining pays here | **yes** — the miner takes a `sugar1q…` address | no |

So: give out the `sugar1q…` address unless a sender insists on the old format, and
mine to it always. Coins that arrive at the `S…` address are still spendable here and
in Core; they are only more expensive to move. The receive screen has the switch, and
says which is which.

### Verified for both halves

Both ways of signing are checked against things this repository did not write:

| | vector | result |
|---|---|---|
| segwit (BIP-143) | **BIP-143's own published transaction**, rebuilt from scratch | its published sighash and its published signature, byte for byte |
| segwit, whole spend | Python's `embit`, an independent implementation | same signature, same raw transaction, same txid |
| legacy (P2PKH) | Python's `embit`, legacy sighash and signing | same sighash, same DER signature, same raw bytes, same txid |
| address derivation | `embit` on the same key | `SZrn9Y64wiWg19Tj4cfCqfPK9MKnPFxMYE`, identical |
| the signature in the app | verified in-test with the package's own verifier | a signature that does not verify cannot pass the test |

`dart run packages/sugar_wallet/test/spend_vectors.dart` runs all of it: 28 checks.

### The one WIF this app refuses

An **uncompressed** WIF — no `0x01` marker, which is what Bitcoin-1.x-era wallets
wrote and what Core still holds for keys imported that way. Its address is a
*different* address from the compressed key's, so importing it here would derive the
other one, show an empty wallet, and look exactly like lost coins. The app says so
instead, and says what to do about it. Everything this app generates is compressed,
so nothing made here is affected.
