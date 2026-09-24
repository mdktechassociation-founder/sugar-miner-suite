# MineHub — the platform around the miner SDK

Three things a developer needs, in the order they need them:

1. **A SUGAR wallet** whose key they hold, so the mining rewards are theirs and
   nobody else's.
2. **A wrapped app**: their Flutter project compiled together with the SDK, with
   their address baked in, and a CI workflow that produces the APK.
3. **An earnings view**: hashrate, balance and one row per device, read from the
   pools' own public APIs.

```
minehub/
  index.html          ← the whole console, one self-contained file (built)
  src/sugar_wallet.js ← SHA-256, RIPEMD-160, secp256k1, bech32, base58check
  src/console_app.js  ← dashboard behaviour
  src/index.template.html
  build.py            ← inlines the two scripts into index.html
  server.py           ← wrap engine + pool lookup + static hosting
  test_wallet.js      ← wallet math vs published vectors   (node)
  test_server.js      ← wrap engine + HTTP surface          (python)
```

Run it:

```bash
node minehub/test_wallet.js     # 19 checks, BIP-173 vectors included
python3 minehub/test_server.js  # 36 checks, end to end
python3 minehub/build.py        # regenerates index.html
python3 minehub/server.py       # http://localhost:8080
```

## 1. The wallet

Generated **in the browser**, from the browser's own CSPRNG, using Sugarchain's
parameters taken from its `src/chainparams.cpp`:

| | |
|---|---|
| bech32 HRP | `sugar` (testnet `tugar`) |
| WIF prefix | `0x80` (testnet `0xEF`) |
| address type | P2WPKH — `sugar1q…`, which is what the SDK's check accepts |
| also derived | compressed pubkey, `hash160`, and the legacy `S…` address |

The server never receives a private key — only the address, which is all mining
needs. There is no account to lose, no key held for you, and therefore no way for
this platform (or anyone who compromises it) to take the earnings.

**Losing the key loses the SUGAR permanently.** There is no recovery, by design.
Download the backup file and keep it offline.

## 2. The wrap

Upload a **Flutter project** as a `.zip` (the folder with `pubspec.yaml` and
`lib/`). You get it back with:

| change | what it is |
|---|---|
| `lib/sugar_miner_setup.dart` | new file: your address, disclosure, CPU policy, the `@pragma('vm:entry-point')` restart hook, and `sugarMinerAttach()` |
| `pubspec.yaml` | the SDK added as a git dependency |
| `lib/main.dart` | `main()` made async if needed, and `await sugarMinerAttach();` inserted as its first statement |
| `.github/workflows/sugar-apk.yml` | GitHub builds the release APK with `--dart-define=SUGAR_PAYOUT_ADDRESS=…` |
| `SUGAR-INTEGRATION.md`, `sugar-wrap-report.json` | the report, inside the zip, so it travels with the code |

The server tells you exactly what it changed, or what it could not and why. It is
idempotent: wrapping an already-wrapped project adds nothing twice.

Wrapping means **compiling your source**, not patching a finished file.

### A compiled APK is refused, deliberately

To put code into a compiled APK you must decompile it, rebuild it and re-sign it
with a different key. That is the standard malware repackaging technique; it
breaks the app's own update path, because the store signature no longer matches;
and there is no way for a server to verify that an anonymous upload is yours. So
this server answers with that explanation instead of doing it.

If the app is yours and you can build it, wrap the project. If you cannot build
it, the honest alternative is a **host app**: a fresh Flutter project that ships
the miner with your branding — a real app you distribute yourself, not a
repackaged one.

## 3. Earnings

`GET /api/pool?address=sugar1…` proxies the public APIs of PooLab
(`stratum.poolab.org:8451`) and zpool (`mine.zpool.ca:6241`), returning total
hashrate, shares, balance, paid, immature, and a row per worker device.

Nothing is reported by the phones. The SDK has no telemetry and no account, so the
pool is the only source — which is also why the dashboard works with the SDK's
stock build and cannot leak a thing that the pool does not already know.

The API is cached for 60 seconds; a fresh address with no shares returns zeros,
which is correct rather than broken.

## What this platform will not do

- **Hide the notification.** No API exists in the SDK, and this console does not
  pretend otherwise: without the notification Android kills the foreground service
  anyway, and mining the user cannot see is cryptojacking — malware charges, store
  bans, and pools that blacklist the address. A developer who patches it in has
  built malware with our name in the comments.
- **Hold keys.** See above.
- **Repackage binaries.** See above.
- **Promise money.** One phone does 100–400 H/s. At a 25% duty cycle that is cents
  per month per device. Play bans on-device mining; iOS allows no background CPU
  work at all. This covers a small app's hosting at best, and only at fleet scale.

## Running it for real

- **HTTPS is required off localhost** for the clipboard and for a trustworthy
  padlock on a page that generates keys. Any small VPS behind Caddy/nginx is
  enough; the wallet work is all client-side, so the server stays idle.
- **HTTP compression and a body limit** are already handled: uploads are capped at
  200 MB, zips are streamed to a temp dir, and wrapped results live in
  `/tmp/minehub-work/<id>/` until the machine reboots.
- **Add accounts when you need them.** Today a developer keeps a wallet backup
  file and pastes their address; there is nothing to log into and no database to
  leak. If you add accounts, store addresses only — never keys.
- **Each developer's SDK builds can be pinned** to a tag instead of `main` by
  editing `SDK_REF` in `server.py`, which is what you want once real apps ship.
