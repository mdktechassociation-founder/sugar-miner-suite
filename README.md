# SUGAR Miner — Flutter app

A real Android app that mines Sugarchain (yespowerSUGAR) in the background: press
start, lock the screen, the phone keeps submitting shares to the pool.

This replaces the earlier browser miner. A web page can only mine while its tab
is open, and it has to route the pool connection through a WebSocket proxy. A
native app connects straight to the pool over TCP and keeps running as a
foreground service — that is the whole reason this version exists.

> Telugu/Tenglish lo step-by-step guide: **[HOWTO-Telugu.md](HOWTO-Telugu.md)**

## Get the APK (no Flutter install needed)

1. **Actions** → **build apk** → newest green run → download an artifact:
   * `sugar-miner-apk-universal` — one APK, every phone (simplest)
   * `sugar-miner-apk` — per-ABI APKs, smaller (`arm64-v8a` = modern phones)
2. Copy it to the phone, install it (allow "install unknown apps").
3. Open the app, paste **your own** `sugar1q…` address, press **Start mining**,
   allow the notification. Then lock the screen — the hashrate keeps climbing.

The APK is signed with the debug key, which is fine for installing it yourself.

## What is inside

| piece | why it is like that |
| --- | --- |
| `native/yespower/` | SugarChain's own yespower 1.0.1 C sources + `yp_bridge.c`. Hashing runs here, not in Dart: pure Dart yespower manages a few H/s, the C core does hundreds per second per core. |
| `lib/miner/yespower.dart` | FFI bindings (`yp_hash`, `yp_scan`, `yp_version`, `yp_free_local`). |
| `lib/miner/stratum.dart` | Stratum client over raw TCP — subscribe, authorize, jobs, submit. |
| `lib/miner/engine.dart` | The mining loop: builds the 80-byte header, scans nonces in C, submits hits, reports stats. |
| `lib/background_service.dart` | Android foreground service hosting the mining isolate, so it survives the app being backgrounded. |
| `lib/main.dart` | The screen: payout address, pool, start/stop, live hashrate and log. |
| `tools/selftest.py` | Proves the C core reproduces the SugarChain genesis PoW hash. Runs in CI on every push. |
| `tools/live_c_test.py` | Mines against the real pool (PooLab) with the exact library the app ships. |
| `.github/workflows/build-apk.yml` | Builds the APK on GitHub's machines. |
| `.github/workflows/native-core.yml` | Cross-compiles the C core for arm64/armv7 and checks the exported symbols. |

## Verified, not assumed

* `tools/selftest.py` rebuilds the library and reproduces the genesis PoW hash
  `0031205acedcc69a9c18f79b84790179d68fb90588bedee6587ff701bdde04eb` — CI runs it
  on every push, and the app re-runs the same check **on your phone** at startup
  (the `engine ✓` line under the title).
* `tools/live_c_test.py` mined with that exact library against
  `stratum.poolab.org:8451`: shares found and acknowledged, and the pool's VarDiff
  lowered our difficulty (0.5 → 0.09375), which it only does for work it credits.
* The built APK contains `libyespower.so` for `arm64-v8a`, `armeabi-v7a` and
  `x86_64`, each exporting `yp_hash`/`yp_scan`/`yp_version`/`yp_free_local`.

## Building it yourself

```bash
flutter pub get
flutter build apk --release --split-per-abi
# output: build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Toolchain: this project matches Flutter 3.47's Android template — Gradle 9.3.1,
AGP 9.1.0, Kotlin 2.4.0, compileSdk 36, minSdk 24, NDK 28.2.13676358.

Test the native core alone on any machine with a C compiler:

```bash
python3 tools/selftest.py     # must print PASS with the genesis PoW hash
```

## Using it well

* Keep the phone **charging** and expect it to get warm — this is a full-CPU load.
* Give the app **unrestricted battery** (Xiaomi/Oppo/Vivo/Samsung kill services
  aggressively). The notification must stay up; it is what keeps mining alive.
* The manifest declares both `dataSync` and `specialUse` foreground-service
  types, because Android 15 caps `dataSync` services at 6 hours a day.
* Check your shares on the pool: `https://poolab.org/api/worker_stats?address=<your address>`

## Honest expectations

A phone does roughly 100–400 H/s, and a share takes thousands of hashes at the
pool's usual difficulty — so expect a share every few minutes and earnings on a
"weeks" scale, not hours. Phone mining is a hobby, not income. What is real here
is the mining itself: genuine yespowerSUGAR shares, accepted by the pool, credited
to your address.

## Limits

* **iOS**: background CPU work is not allowed, so on iPhone it only mines while
  the app is on screen.
* **Release APK is debug-signed** — fine for personal use, replace the keystore
  before distributing it.
* Shrinking/minifying is off in the release build on purpose: the FFI symbols and
  the background service are reached by name, and a stripped build would only fail
  at runtime.

## Licence

yespower sources come from the SugarChain project (MIT). This app code is yours.
