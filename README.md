# sugar_miner_sdk

**Consented background SUGAR mining for Flutter apps.** Add it to your app, ask the
device owner once, and your app mines yespowerSUGAR for *your* address while it is
backgrounded — politely, visibly, and with hard limits it cannot exceed.

Yes, it really mines: the same native yespower core, the same direct Stratum
connection. What it does *not* have is a way to run quietly.

> Telugu/Tenglish guide: **[HOWTO-Telugu.md](HOWTO-Telugu.md)**

---

## The rule this SDK is built around

> Mining inside someone else's app is acceptable only when the person who owns the
> phone knows, agreed, and can stop it. Everything else is cryptojacking — illegal
> in most countries, banned by both app stores, and straight-up malware.

So this SDK is designed the other way round from a stealth miner:

| stealth miners do | this SDK does |
| --- | --- |
| no permission, hidden service | a consent screen the user must accept; stored versioned, revocable |
| quiet notification or none at all | an **always-visible, non-dismissible** notification with the hashrate |
| hide from the battery settings | asks Android for a `specialUse` foreground service and says why, in the manifest |
| max out the CPU | **25% of one core by default**, duty-cycled, and it sleeps the rest |
| run until the phone dies | stops on low battery, on heat, on metered data, and after a daily time budget |
| sneak back after being stopped | if the user withdraws permission, mining cannot restart |

Those aren't promises in the docs — `tools/guardrails.py` checks them in CI on
every push and fails the build if any of it stops being true. There is no
`stealth: true` flag to find, because one was never written.

## Install

```yaml
dependencies:
  sugar_miner_sdk:
    git:
      url: https://github.com/mdktechassociation-founder/sugar-miner-sdk.git
      ref: main
```

Then a normal `flutter pub get`. Nothing to add to your Android manifest — the
plugin brings its permissions and its foreground service with it.

## Use it

```dart
import 'package:sugar_miner_sdk/sugar_miner_sdk.dart';

final miner = SugarMiner(
  // your own address: this is what earns
  config: const SugarConfig(payoutAddress: 'sugar1q…your address…', worker: 'app'),
  // the defaults are already polite; tune them if you like
  policy: const MiningPolicy(
    cpuSharePercent: 25,        // a quarter of one core, duty-cycled
    minBatteryPercent: 30,      // on battery, never below this
    maxThermalStatus: 2,        // stop when the phone gets hot
    dailyCapMinutes: 480,       // eight hours a day, then it stops itself
    requireUnmetered: true,     // never on someone's mobile data
  ),
);

// 1. Ask once — puts up the disclosure sheet and remembers the answer
await SugarConsentSheet.show(context, miner: miner, appName: 'My App');

// 2. Start it (refuses politely if there is no consent, or the phone is unhappy)
final result = await miner.start();
debugPrint('$result');

// 3. Show the user what is happening, with a switch to stop it
SugarMiningTile(miner: miner);

miner.stats.listen((s) => debugPrint('${s.hashrate.toStringAsFixed(0)} H/s'));
```

That is the whole integration: one dependency, one dialog, one widget. The
`SugarMiningTile` is the piece that keeps you honest — hashrate, accepted shares,
today's minutes used, a battery-settings shortcut, and a **Withdraw permission**
button.

## What the user sees

1. A disclosure sheet in plain language: what runs, what it does to the phone,
   what it stops for, and that the notification can never be hidden.
2. A persistent notification — `Mining SUGAR — 213 H/s` / `accepted 4 · rejected 0` —
   for as long as any hashing happens. It cannot be swiped away.
3. A switch in your UI that stops everything, and a withdraw-consent button that
   makes the SDK refuse to start again.

## What actually happens on the phone

* Hashing runs in a background isolate in the host app's process, inside a native
  foreground service, so it continues with the screen off.
* The C core (`libyespower.so`, built from SugarChain's yespower 1.0.1) is
  compiled into the plugin and packed into every APK that depends on it.
* Mining talks straight to the pool over TCP (`stratum.poolab.org:8451` by
  default) — no relay, no middleman.
* The isolate is duty-cycled: hash a batch, sleep three times as long, so a
  "25%" policy really is a quarter of a core.
* A Dart-side watchdog re-checks the policy every 30 seconds and pauses or
  resumes without the host app doing anything.

## Verified, not assumed

CI runs three things on every push:

* `tools/guardrails.py` — 20 checks that the consent gate, the visible
  notification, the limits and the absence of stealth options are still true.
* `tools/selftest.py` — builds the C core and reproduces the SugarChain genesis
  PoW hash `0031205acedcc69a9c18f79b84790179d68fb90588bedee6587ff701bdde04eb`.
* Builds `example/` and then inspects the APK to prove `libyespower.so` is inside
  it with `yp_hash`/`yp_scan` exported.

`tools/live_c_test.py` mined with that exact library against the real PooLab pool:
shares accepted, and the pool's VarDiff lowered our difficulty (0.5 → 0.09375),
which a pool only does for work it credits.

## Honest economics

A phone does ~100–400 H/s, and at 25% duty cycle that is a quarter of it. Overage
earnings per device are **cents per month**. Mining is not a viable revenue
model for an app in 2026 — ads, IAP or just not monetising will out-earn it. If
your reason for mining is "free money", this will disappoint you. If your reason
is "the app is about SUGAR / mining / crypto, and users opt in", it does exactly
what it says.

## Distribution reality

* **Google Play** bans on-device crypto mining, period.
* **App Store** the same, and iOS does not allow background CPU work anyway.
* So this is for sideloaded, enterprise/internal, kiosk, hobby or self-owned
  devices — and it belongs in the app's own description wherever you distribute
  it, next to the disclosure.

## Requirements

Android 7.0+ (API 24). Flutter 3.19+. Built and tested against the Flutter 3.47
Android toolchain: Gradle 9.3.1, AGP 9.1.0, Kotlin 2.4.0, NDK 28.2.13676358.

## Licence

yespower sources come from the SugarChain project. The SDK code is yours to use.
