# Which platforms, and what is actually verified

Every row below is a claim with something behind it. Where the evidence is "CI builds
it", that is what it says — a build proves the platform's toolchain accepts this code,
it does not prove anybody has run the result. This file exists so the difference is
visible without reading nine workflow files.

The matrix in [README.md](README.md) says what each platform *can do*. This says who
checked, and how.

| platform | builds | verified by | runs? | mines? |
|---|---|---|---|---|
| **Android** | ✅ CI + published APK | `release.yml` builds both APKs on every push, opens the wallet APK and asserts the mining service, the boot receiver and four permissions are inside it | the APK is signed (v2 + v3 + v3.1), carries `arm64-v8a`, `armeabi-v7a` and `x86_64`, and downloads as an anonymous stranger | ✅ full engine — foreground service, notification, battery/thermal pausing, boot resume |
| **iOS** | ✅ CI, unsigned (`flutter build ios --no-codesign`) | `platforms.yml` → `ios` | ❌ nobody has installed it: an unsigned build cannot be installed without a signing identity | ⚠️ foreground only — iOS suspends background apps, so mining stops when the app leaves the screen, and the UI says so |
| **Ubuntu (Linux)** | ✅ CI | `platforms.yml` → `linux` on `ubuntu-latest`: builds both apps and fails unless `lib/libyespower.so` is in the bundle | ❌ not launched in CI | ✅ while the window is open |
| **Debian (Linux)** | ✅ built here, on Debian 13 | the wallet's `flutter build linux --release` succeeded on Debian 13; the `lib/libyespower.so` **inside that bundle** was loaded and called and reproduced Sugarchain's genesis PoW hash (`0031205acedcc69a9c18f79b84790179d68fb90588bedee6587ff701bdde04eb`); the app was then launched under a virtual display and stayed up | ✅ launched, not interacted with | ✅ same engine, same check |
| **Windows** | ✅ CI | `platforms.yml` → `windows`: builds with mingw (MSVC cannot compile the C core) and copies `yespower.dll` beside the executable | ❌ never launched by anybody — the loader looks for the DLL beside the .exe, and CI only checks that it is there | ✅ in principle; unproven in practice |
| **macOS** | ✅ CI | `platforms.yml` → `macos`: clang builds `libyespower.dylib`, and it is copied into `Contents/Frameworks` of both `.app`s | ❌ never launched by anybody | ✅ in principle; unproven in practice |
| **Chrome / Chromium (web)** | ✅ CI, and **run** in a real browser | `tools/verify_browser.js` serves the published page over HTTP and opens it in every Chromium-family browser on the machine. In each one: both of the page's engines (SIMD and scalar) must reproduce the genesis PoW hash, the page's own `sha256d` must reproduce the genesis block hash, the payout field must still ship empty, the bridge field must never name a third party, and nothing may be logged as an error | ✅ the page loads and its engines run — verified on Chrome 154 and on Edge 154, and CI runs the same check on every push with `--strict`, which fails if it had to skip | ❌ a browser cannot open a TCP socket; the wallet build refuses to mine in one plain sentence, and `sugar-miner/` is the web answer through a WebSocket bridge |
| **Edge (Chromium)** | ✅ run here, and in CI wherever it is installed | the same check, in real headless Edge on Debian 13: 13/13, including both hashing engines reproducing the genesis PoW hash | ✅ Edge 154 loads the page and its engines run | ❌ same as Chrome — nothing about a browser changes the TCP problem. Installing a browser is enough for it to be tested: the check finds Chrome, Edge, Chromium and downloaded shells by itself, and `BROWSERS=…` narrows it |

## What has never been done, on any platform

- **Nobody has mined with this on real hardware.** Not once, on any platform. The
  engines are verified against the coin's genesis block, the transaction code against
  BIP-143 and embit, and the encodings against published vectors — but not against a
  running phone.
- **Nobody has sent a real transaction.** The spend path is covered by 28 vectors and a
  live fee lookup; mainnet with real coins is the test that would close it.
- **Windows and macOS binaries have never been executed.** They build, and the native
  library is where the loader will look. That is all that is known.
- **No ARM desktop, no 32-bit x86 desktop.** CI builds x86-64 for Linux, Windows and
  macOS. Android is the only platform shipping ARM, and it ships both ABIs.
- **The desktop builds are unsigned.** macOS Gatekeeper and Windows SmartScreen will
  both object; the apps are for their owners, not for distribution.
- **iOS needs a signing identity and a developer account**, which is why CI stops at
  `--no-codesign`.

## What each check would catch, if it broke

| platform | the check that fails |
|---|---|
| Android, iOS, Linux, Windows, macOS, web | `every platform this suite claims` — a platform that stops building is a platform this repository no longer supports, and nobody has to find out from a user |
| the mining engine anywhere | `sdk — the native core is consensus-correct` — builds the C and checks it against Sugarchain's genesis |
| the published page | `browser miner — the page and the bridge behave` (Node) and `browser miner — the published page in real browsers` (every Chromium installed, each with its own pass/fail; CI writes the list of browsers it tested to the run's summary page, so which ones were covered is visible without downloading a log) |
| the APK people download | `release.yml` opens the built wallet APK and asserts the service, receiver and permissions are inside it before anything is published |

All of it runs behind one command, `tools/check_all.sh`, and every push to `main` runs
it with `--strict`, so nothing can be skipped without being noticed.
