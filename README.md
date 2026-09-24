# SUGAR Miner — Flutter app

A real Android app that mines Sugarchain (yespowerSUGAR) in the background: press
start, lock the screen, the phone keeps submitting shares to the pool.

This replaces the earlier browser miner. A web page can only mine while its tab
is open and it must route the pool connection through a WebSocket proxy. A native
app connects straight to the pool over TCP and keeps running as a foreground
service — that is the whole reason this version exists.

## What is inside

| piece | why it is like that |
| --- | --- |
| `native/yespower/` | SugarChain's own yespower 1.0.1 C sources + `yp_bridge.c`. Hashing runs here, not in Dart: pure Dart yespower manages only a few H/s, the C core does hundreds per second per core. |
| `lib/miner/yespower.dart` | FFI bindings (`yp_hash`, `yp_scan`, `yp_version`, `yp_free_local`). |
| `lib/miner/stratum.dart` | Stratum client over raw TCP — subscribe, authorize, jobs, submit. |
| `lib/miner/engine.dart` | The mining loop: builds the 80-byte header, scans nonces in C, submits hits, reports stats. |
| `lib/background_service.dart` | Android foreground service hosting the mining isolate, so it survives the app being backgrounded. |
| `lib/main.dart` | The screen: payout address, pool, start/stop, live hashrate and log. |
| `tools/selftest.py` | Proves the C core reproduces the SugarChain genesis PoW hash. Runs in CI. |
| `.github/workflows/build-apk.yml` | Builds the APK on GitHub's machines — you do not need Flutter installed. |

## Getting an APK (no Flutter needed locally)

1. Push this folder to a GitHub repo.
2. Open the repo → **Actions** → the **build apk** workflow.
3. Wait for it to go green (first run takes ~10 minutes), open the run and
   download **sugar-miner-apk** (per-ABI) or **sugar-miner-apk-universal**.
4. Copy the APK to the phone and install it (allow "install unknown apps").

`arm64-v8a` covers every modern phone. If unsure, use the universal APK.

## Using it

1. Open the app, paste **your own** SUGAR payout address (`sugar1q…`). There is no
   default address anywhere in this app — a miner that silently pays someone else
   is the classic trap, and this one cannot.
2. Pool is preset to `stratum.poolab.org:8451`; change host/port if you use another.
3. Press **Start mining**. Android asks for notification permission — say yes, the
   notification is what keeps the mining alive. A notification appears showing the
   current hashrate.
4. Press home / lock the screen. The hashrate keeps climbing.
5. Check your shares on the pool's worker page for your address:
   `https://poolab.org/api/worker_stats?address=<your address>`

## Expected performance

Phones are slow at yespower and pool difficulty rises as more people mine. A
typical phone gives roughly 100–400 H/s. At the pool's usual difficulty a share
takes thousands of hashes, so expect a share every few minutes and earnings best
measured in "over weeks", not hours: phone mining is a hobby, not income. The
value here is that it is *real* mining — genuine yespowerSUGAR shares, accepted
by the pool, credited to your address.

## Building it yourself (if you do have Flutter)

```bash
flutter pub get
flutter build apk --release --split-per-abi
# output: build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Test the native core alone, on any machine with a C compiler:

```bash
python3 tools/selftest.py     # must print PASS with the genesis PoW hash
```

## Honest limitations

- **iOS**: background CPU work is not allowed, so on iPhone it mines only while
  the app is on screen.
- **Battery/heat**: this is a full-CPU workload. Keep the phone charging, expect
  it to get warm, and stop it if the phone throttles hard.
- **Aggressive battery savers** (Xiaomi, Oppo, Samsung) may kill the service
  anyway — allow the app to run in the background in settings, or the mining dies
  with the screen.
- Solo block-finding on a phone is not realistic; pool mining only.

## Licence

yespower sources come from the SugarChain project (MIT). This app code is yours.
