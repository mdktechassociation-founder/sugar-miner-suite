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

## 2. The wrap — two modes

Upload a **Flutter project** as a `.zip` (the folder with `pubspec.yaml` and
`lib/`). You get it back with the SDK compiled in.

### clean (default) — your app code is untouched

| file | change |
|---|---|
| `pubspec.yaml` | the SDK added as a git dependency |
| `lib/main.dart` | **one import line** — `import 'package:sugar_miner_sdk/native_boot.dart';` |
| `AndroidManifest.xml` | `<meta-data>`: your address, the notice, terms, privacy, policy |
| `MainActivity.kt` | **one line**: `SugarMinerNative.install(this)` in `onCreate` |
| `.github/workflows/sugar-apk.yml` | builds the release APK with your address baked in |

No widgets, no init order, no screens, nothing else. The SDK's own headless Dart
entrypoint reads the manifest and does the work; the consent dialog, the
notification, the service and the reboot receiver are all the SDK's.

The import line is not laziness: Flutter compiles an app into a single AOT
snapshot, and a Dart library the app never imports is not in that snapshot at all,
so a named entrypoint could not be called. One import is the smallest true thing.

### full — the config lives in Dart

Additionally generates `lib/sugar_miner_setup.dart` and calls
`await sugarMinerAttach();` at the top of `main()`. More control: the notification
wording and the disclosure sit in one readable file you own.

### Both modes are idempotent, and both are provable

`sugar-wrap-report.json` travels inside the zip with a SHA-256 of **every** file
and the line counts of each change, so "nothing else of yours was touched" is
checkable rather than a claim. The tests assert it too: removing the one import
line must restore `main.dart` byte-for-byte, and every added line in
`MainActivity.kt` must be one of the few lines named above.

### A compiled APK cannot be wrapped — and not because of policy

For a **Flutter** APK it is physically impossible. The app is compiled into one AOT
snapshot (`libapp.so`); the miner is Dart code with FFI into a native library, and
Dart cannot be added to a snapshot that has already been compiled. The source is not
in the APK, and no dex or smali patch reaches Dart. There is no version of this
operation that a more determined implementer could pull off.

For **any other** APK, the operation exists but means decompiling, rebuilding and
**re-signing with a different key**. That breaks the app's own update path (the
store signature no longer matches), gets it flagged as repackaged, and against
someone else's app it is precisely the malware technique — with no way for a server
to verify that an anonymous upload is the uploader's own work. MineHub refuses it,
in code, and CI fails if that refusal is ever removed.

If you can build your app, wrap the project: it compiles in and keeps your signing
key. If you cannot build at all, the honest alternative is a **host app** — a fresh
Flutter project that ships the miner with your branding, which you distribute
yourself rather than repackage someone else's.

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
