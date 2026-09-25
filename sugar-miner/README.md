# SUGAR miner + bridge

A self-contained Sugarchain (SUGAR) browser miner, and the WebSocket → TCP bridge it
needs to reach a raw Stratum pool from a web page.

```
browser (site/index.html)
   │  wss://…workers.dev
   ▼
Cloudflare Worker (worker/worker.js)  ──connect()──►  stratum.poolab.org:8451
```

## What's here

| Path | What it is |
|---|---|
| `site/index.html` | the miner page — everything (JS core, two wasm builds, a JS-only fallback) inlined, no CDN |
| `worker/worker.js` | hardened WS⇄TCP bridge for Cloudflare Workers |
| `vendor/SUGAR_MINER_SINGLE_FILE.html` | the upstream file, **unmodified**, kept for provenance |
| `tools/extract.js` | pulls the page apart into separate files for testing |
| `tools/verify.js` | the test suite: consensus correctness + safety regressions |
| `.github/workflows/` | `verify` (every push) · `deploy-worker` · `pages` |

## Only two things differ from the upstream page

`site/index.html` is byte-identical to `vendor/…` except:

1. the **payout address** field ships **empty** (upstream had a stranger's wallet
   hard-coded, which would have mined into their account for anyone who just
   pressed the button), and
2. the **proxy URL** field ships **empty**, with a notice explaining what to fill in.

You can confirm this yourself: `git diff --no-index vendor/ site/` after a `sed`
swallows the base64 blobs — or just trust CI, which **fails the build if any
`sugar1…` address ever appears in the shipped page again**.

## Use it

```bash
# 1. deploy the bridge
npm install -g wrangler && wrangler login
cd worker && wrangler deploy          # updates this project's bridge

# 2. open the miner
open site/index.html
```

Give the page your bridge and your wallet, either in the two form fields or in the URL:

```
https://mdktechassociation-founder.github.io/sugar-miner-suite/?ws=wss://stratum-proxy.mdktechassociation.workers.dev
```

**Use your own `sugar1q…` address.** That is the only thing the pool pays out to.

## Tests

```bash
node tools/verify.js                # 21 checks, offline
SUGAR_LIVE=1 node tools/verify.js   # + one live check against the real pool
```

What CI actually proves on every push:

* **consensus** — all three engines (wasm SIMD, wasm scalar, JS-only) reproduce the
  real SugarChain genesis PoW hash `0031205a…e04eb`, i.e. hashing is correct, not
  merely plausible;
* **difficulty maths** — the pool's `2^16` scale factor (`POOL_DIFF1 = bitcoin-diff1 × 65536`),
  hashes-per-share at difficulty 1 / 0.5, and inverse consistency;
* **wire format** — prevhash word-swap, `ntime` passthrough, 80-byte header, little-endian nonce;
* **safety** — no wallet address or third-party proxy is baked into the published page.

## Facts about the coin/pool, measured, not guessed

* PoW = yespower 1.0.1, `N=2048`, **`r=32`**, 74-byte personalisation
  `"Satoshi Nakamoto 31/Oct/2008 Proof-of-work is essentially one-CPU-one-vote"`.
* Pool share difficulty is in **bitcoin-diff1 ÷ 65536** units; the pool accepts when
  `shareDiff / difficulty ≥ 0.99`. The official `sugarmaker` does the same
  (`diff_to_target(target, job.diff / 65536.0)`).
* A browser tab does ~160–250 H/s. That is roughly 0.6 % of the network — this is a
  learning project, not an income stream.

## Licensing / provenance

The mining core and wasm builds come from the upstream single-file page; the
Sugarchain parameters and the yespower sources are the project's own (GPL-2.0 /
BSD-2-Clause for yespower). Keep the upstream notices if you redistribute.
