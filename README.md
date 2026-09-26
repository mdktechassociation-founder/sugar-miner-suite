# SUGAR mining suite

Every phase of this project in one repository: the browser miner it started as, the
Android engine that replaced it, the two apps built on that engine, and the platform
that attaches the engine to other people's apps.

Five components. Each one keeps its own folder, its own README, its own tests and its
own CI job — so nothing here is a pile of merged files. `git log` on this repository
still contains the full history of every component, imported intact.

| folder | phase | what it is | who uses it |
|---|---|---|---|
| [`sugar-miner/`](sugar-miner/) | 0 — origin | one self-contained HTML page that mines in a browser, plus the Cloudflare WebSocket→TCP bridge it needs to reach Stratum | anyone, no install |
| [`sugar-miner-sdk/`](sugar-miner-sdk/) | 1 — the engine | the mining engine: native yespower core, Android foreground service, notification, consent, policy. A library, not an app | developers |
| [`sugar-miner-app/`](sugar-miner-app/) | 2 — the owner's app | a plain miner: enter your address, press start, this device mines to it | the owner / a developer |
| [`sugar-wallet-miner/`](sugar-wallet-miner/) | 3 — the user's app | creates a wallet on the phone, then mines into it. The beneficiary is the phone's own user | end users |
| [`minehub/`](minehub/) | 4 — the platform | wallet creation in a browser, the project-wrap service, the earnings/fleet console, deployment files | developers, operators |

## Which platforms, and what each one can actually do

Flutter runs in more places than this engine can hash, and the difference is worth
stating plainly rather than discovering after an install.

| platform | wallet app | miner app | SDK | what is different |
|---|---|---|---|---|
| **Android** | ✅ | ✅ | ✅ | the full engine: foreground service, notification that stays visible, battery/thermal pausing, boot resume |
| **Linux** | ✅ | ✅ | ✅ | mining runs while the window is open. The native core is built by the same CMake that builds the app, so the library is always beside it. Needs `libsecret-1-dev` and `libjsoncpp-dev` for the wallet's keystore |
| **Windows** | ✅ | ✅ | ✅ | same as Linux, with `yespower.dll` next to the executable |
| **macOS** | ✅ | ✅ | ✅ | same as Linux; sandbox entitlements apply to a distributed build |
| **iOS** | ✅ wallet | ⚠️ foreground only | ✅ | iOS **suspends background apps** and has no foreground service. Mining happens only while the app is on screen, the UI says so, and no notification changes that |
| **Web** | ✅ wallet | ❌ not offered | ✅ compiles | a browser cannot open a TCP socket to a pool and cannot load the native core. The web build runs the wallet and refuses to mine, in one plain sentence. The browser miner in `sugar-miner/` is the web answer, and it uses a WebSocket bridge for exactly this reason |

Three things the engine does on every platform, unchanged: the consented CPU share is
never exceeded, the daily minute cap still applies, and stopping is final.

On desktop there is **no notification** — desktop Flutter has no equivalent this app
ships — so the app window is the indicator, and closing it stops mining. That is a real
difference from Android, where mining survives the app being closed, and it is written
on the screen rather than left to be discovered.

CI builds all of these on their own machines (`.github/workflows/platforms.yml`), so
"supported" means "it built", not "it should".

## The wallet makes its own wallets, with no server anywhere

`sugar-wallet-miner` creates wallets on the device and keeps the key in the platform
keystore. Two kinds, both offline:

- **Twelve words (the default).** A BIP-39 phrase generated from the phone's secure
  random source. The key is derived at `m/44'/408'/0'/0/0` — 408 is Sugarchain's
  registered coin type in SLIP-0044 — and the app shows the words numbered, for
  paper. It also keeps an xprv, which is what a BIP-32-capable wallet wants.
- **A raw key**, for someone importing by hand.

What restores where — this is the compatibility that matters, and it is checked by
tests rather than asserted:

| you keep | restores in |
|---|---|
| the twelve words | any BIP-39 wallet that follows BIP-44 with coin type **408** — and, at the *other* path below, the official Android wallet |
| the WIF | Sugarchain Core (`importprivkey`) and the Sugarchain web wallet |
| the xprv | any wallet with a BIP-32 tab, including that web wallet |
| the backup file (JSON) | this app, via the import field, or by hand anywhere |

### Which Sugarchain wallets understand words — checked, not assumed

Three answers, all verified against the wallet itself:

| wallet | words? | how it was checked |
|---|---|---|
| **Core** (`sugarchain-project/sugarchain`) | **No** | `bip39` and `mnemonic` appear **nowhere** in its source or docs. Its HD wallet is a raw key derived at `m/0'/0'/k'`, and the only single-key import is `importprivkey` (a WIF). Whole-wallet backup is `wallet.dat` or `dumpwallet`, both Core-only formats. |
| **web wallet** (coinbin-based) | **No** | Its `index.html` has no mnemonic or BIP-39 string; it takes WIF and BIP-32 extended keys. |
| **official Android wallet** | **Yes** | It publishes no source, so the released APK was unpacked: its JS bundle calls `bip39.mnemonicToSeed(…)`. |

**And it derives at a different path.** The official Android wallet's bundle reads
`function _(t, n = "m/44'/0'/0'/0", …) { bip39.mnemonicToSeed(t) … derivePath(n + '/' + i) }`
— BIP-39 words at **coin type 0**, Bitcoin's, not Sugarchain's registered 408.

That is silent and expensive: the same twelve words make
`sugar1q3828kzacg6yp9f5tply4yrtgtu20kqt3wu52j6` at 408 and
`sugar1qmxrw6qdh5g3ztfcwm0et5l8mvws4eva2trdxdy` at 0. A restore at the wrong path
shows an empty wallet and no error. So the app's import field asks which wallet the
words came from when the input is a phrase, and both paths are pinned by vectors
against `bip-utils`.

A one-page version of all of this, with the commands and the evidence, is in
[`sugar-wallet-miner/WALLET-KEYS.md`](sugar-wallet-miner/WALLET-KEYS.md).

One more thing found while checking it: `importprivkey` in Core calls
`LearnAllRelatedScripts`, which registers the P2PKH, the P2SH-wrapped segwit **and**
the native bech32 destination for that one key. So a WIF is not merely mandatory for
Core — it is sufficient: it covers the `sugar1q…` address this app mines to.

So: "Sugarchain has no seed phrase" is **true of Core** — the original wallet, where
WIF is mandatory — and **false of the official Android wallet**, which has one and
uses a path of its own.

The import field accepts all four, so a restore is one paste whichever form the
backup is in. Core's own wallet derives at its own `m/0'/0'/k'` scheme and has no
phrase support — the WIF is the bridge to it, and that is why the app still prints
one.

The crypto is in `sugar-wallet-miner/packages/sugar_wallet`, still with no package
dependencies: SHA-512, HMAC-SHA512, PBKDF2, BIP-39 and BIP-32 are written out and
pinned by published vectors — NIST digests, RFC 4231, the BIP-39 reference set, and
BIP-32 test vector 1 six chains deep. The composed claim (these words make this
address) is cross-checked against `bip-utils`, a second implementation.

The same package now **spends**: secp256k1 ECDSA with RFC 6979 deterministic
nonces, low-S normalisation, DER encoding, and BIP-143 P2WPKH signing. That is
verified the same way and against the hardest vector there is — BIP-143's own
published transaction, rebuilt from scratch and required to produce its published
sighash and its published signature byte for byte — plus a whole Sugarchain spend
compared against Python's `embit`: same sighash, same signature, same raw bytes,
same txid. Sending is done on the device: the app asks the chain what the address
holds and what it charges per virtual byte, builds the transaction, shows the
amount, fee, change and total on one card, and signs only when the user presses
send. The one write the wallet app performs is `POST /esplora/tx`, carrying a
signed transaction and nothing about the person who signed it.

## Checking it, and releasing it

Two commands cover the whole suite:

```bash
tools/check_all.sh            # every check in the repository, one command
tools/check_all.sh --strict   # and fail if anything had to be skipped (CI does this)
tools/push.sh                 # push it: token used once, never stored
```

Releases publish themselves. `.github/workflows/release.yml` runs `check_all.sh
--strict`, builds both APKs, checks the merged manifest inside the wallet APK, and
uploads them to one permanent page — `releases/tag/latest` — on every push to `main`
and again every week, so the download link never goes stale and nobody has to
remember an expiry date.

## How the phases fit together

```
   phase 0            phase 2                   phase 3
 browser miner   →   owner's miner app   →   user's wallet app
   (a page)          (mines to YOUR            (mines to THE USER'S
                      address)                   own address)

                            ▲                          ▲
                            │                          │
                     phase 1: sugar-miner-sdk ─────────┘
                     the engine both apps run, and the thing
                     other people's apps embed

                            ▲
                            │
                     phase 4: minehub
                     creates the wallet, attaches the engine to
                     someone else's Flutter project, shows what
                     devices earn, generates the deployment
```

**Two things to be clear about, because they are the whole design:**

1. **Phase 2 and phase 3 are the same engine with different beneficiaries.** In phase 2
   the developer mines to themselves and the user gets the app free. In phase 3 the user
   mines to their own wallet and nobody else earns from it. The SDK is what makes both
   honest: consent is recorded by the engine, the notification cannot be hidden, and
   stopping is final.
2. **Phase 0 is kept, not deleted.** It is the origin of the project and it still works
   if you deploy the bridge. It is also the cheapest way to test a pool or a wallet
   before touching any Android build.

## Installing the engine from a project that is *not* in this suite

The engine is a subfolder here, so an external Flutter project points at the folder:

```yaml
dependencies:
  sugar_miner_sdk:
    git:
      url: https://github.com/mdktechassociation-founder/sugar-miner-suite.git
      ref: sdk-v2.2.0        # a tag, never `main`
      path: sugar-miner-sdk
```

Inside the suite, `sugar-wallet-miner` uses a `path:` dependency instead, so the app and
the engine it ships are always built from the same tree. Tags are prefixed per component
(`sdk-v2.2.0`, `app-v…`, `wallet-v…`) so five components' release history stays readable
in one list.

## The rule this whole suite is built around

> Mining inside someone else's app is acceptable only when the person who owns the phone
> knows, agreed, and can stop it.

Every component enforces that in its own tests, and the numbers are checked in CI on
every push:

| component | what CI proves |
|---|---|
| `sugar-miner-sdk/` | 55 guardrails: consent gates the start path, no stealth keyword exists, the notification is ongoing with a Stop action, auto-config never exceeds the ceiling · 11,200 core-plan combinations where the budget stays a ceiling · the C core reproduces the SugarChain genesis PoW hash · the example APK really contains `libyespower.so` |
| `sugar-wallet-miner/` | 36 wallet vectors (BIP-173 + a second implementation) · 61 phrase vectors · 19 spend vectors against BIP-143 and `embit` · 22 app tests · 20 QR checks against a second encoder **and** a real scanner · 33 guardrails · the release APK contains the miner service, the boot receiver and the notification permission |
| `minehub/` | 71 end-to-end tests · 19 wallet vectors · clean mode adds exactly one import line and hashes every other file · compiled APKs are refused with the reason in code · no stealth, no key custody, no repackaging |
| `sugar-miner/` | the page still produces a consensus-correct genesis hash, and no payout address is hard-coded in it |
| `sugar-miner-app/` | the native core self-test, then release APKs (per-ABI and universal) |

## What this suite will never contain

No stealth or hidden mining. No key custody — no server anywhere holds a private key.
No repackaging of compiled APKs. No income promises: a phone does 100–400 H/s, which at
a 25% duty cycle is pennies a day, and saying otherwise is selling something else.

## CI layout

One workflow per component, each triggered only by its own files:

```
.github/workflows/
  sdk.yml                   engine: guardrails, unit tests, native core, cross-compile, example APK
  wallet-app.yml            user's app: wallet vectors, QR symbol, guardrails, APK
  miner-app.yml             owner's app: native self-test, per-ABI + universal APKs
  platform.yml              minehub: wallet vectors, wrap engine, clean mode, refusals
  browser-miner.yml         page consensus checks
  browser-miner-pages.yml   publish the page to GitHub Pages
  browser-miner-worker.yml  deploy the Stratum bridge to Cloudflare
```

A change to the engine runs the engine job **and** the wallet-app job, because that app
compiles the engine from this same tree — which is the point of putting them together.
