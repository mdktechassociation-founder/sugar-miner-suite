# sugar_miner_sdk

**Background SUGAR mining for Flutter apps — consented, visible, and
self-configuring.** The SDK is the worker; your app is the host.

A developer changes **three things**: their own payout address, the disclosure that
matches their app's terms and privacy policy, and one line registering the headless
entrypoint that lets mining resume after a phone restart. The SDK then names the device's
worker, picks and fails over between pools, and decides how hard to work from the
phone's own health checks. The user is asked once, sees a notification the whole
time, and can stop it from the notification itself.

The short version of what this is for: **the app is free, and the user pays with
spare computing power instead of money.** The developer writes that deal down, the
user agrees to it once, and the SDK does the rest quietly in the background.

> Telugu/Tenglish guide: **[HOWTO-Telugu.md](HOWTO-Telugu.md)**
> Permissions and what "24/7" really takes: **[PERMISSIONS.md](PERMISSIONS.md)**

## The one rule this SDK is built around

> Mining inside someone else's app is acceptable only when the person who owns the
> phone knows, agreed, and can stop it. Everything else is cryptojacking — illegal
> in most countries, banned by both app stores, and straight-up malware.

| stealth miners do | this SDK does |
| --- | --- |
| no permission, hidden service | consent gated on the app's own disclosure (notice + terms + privacy policy, versioned) |
| quiet notification or none at all | an **always-visible** notification with a **Stop** button; wording is yours, existence is not |
| hide the battery exemption | asks with the system dialog, and shows the status — see PERMISSIONS.md |
| max out the CPU | **25% of one core by default**, auto-tuned *down* for heat, battery and low-end phones — never up past your ceiling |
| run until the phone dies | hard stops for battery, battery temperature, heat, metered data, and a daily minute budget |
| sneak back after being stopped | the notification's Stop button is final: the SDK will not restart by itself |

All of that is enforced by `tools/guardrails.py` — **46 checks** that run in CI on
every push and fail the build if any of it stops being true. There is no
`stealth: true` flag to find, because one was never written.

## Install

```yaml
dependencies:
  sugar_miner_sdk:
    git:
      url: https://github.com/mdktechassociation-founder/sugar-miner-sdk.git
      ref: main
```

`flutter pub get`. Nothing to add to your Android manifest — the plugin brings its
permissions, its foreground service and its notification icon with it.

## The whole integration

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SugarMinerSdk.install(
    config: const SugarConfig(
      // 1. YOUR address. Set here, in code — the SDK never asks the user for one.
      payoutAddress: 'sugar1q…your address…',
      // workerName is left null: the SDK names the device itself
      // (yourapp-android-1a2b) and remembers it for the pool's worker list.
      disclosure: MiningDisclosure(
        appName: 'My App',
        ownerName: 'My Company',
        // 2. the plain sentence your users read, matching your terms + privacy policy
        miningNotice: 'My App mines a small amount of SUGAR cryptocurrency in the '
            'background for the developer. It uses part of your phone\'s processor, '
            'battery and data, is shown in a notification while it runs, and you can '
            'turn it off at any time.',
        noticeVersion: '1.0.0',
        termsUrl: 'https://yoursite.com/terms',
        termsVersion: '2026-01-15',
        privacyUrl: 'https://yoursite.com/privacy',
      ),
    ),
    policy: const MiningPolicy(
      cpuSharePercent: 25,   // the ceiling the auto-configurator may never exceed
      dailyCapMinutes: 480,
      requireUnmetered: true,
    ),
  );

  runApp(const MyApp());
}
```

**And one more call, for restarts** — the function that Android runs with no
activity on screen:

```dart
/// Android calls this after a reboot or an app update. Three lines.
/// `@pragma('vm:entry-point')` is required: without it, release builds
/// tree-shake the function away and registration returns false.
@pragma('vm:entry-point')
void sugarMinerHeadless() {
  WidgetsFlutterBinding.ensureInitialized();
  SugarMinerSdk.install(config: kConfig);      // same config, no UI
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final ok = await SugarMinerSdk.registerHeadlessEntrypoint(sugarMinerHeadless);
  assert(ok, 'missing @pragma, or the entrypoint was stripped');
  await SugarMinerSdk.install(config: kConfig);
  runApp(const MyApp());
}
```

That is it — mining runs, and it survives the app being closed. If the user has not
agreed yet, nothing mines until they do. Show the SDK's disclosure sheet wherever
fits your flow:

```dart
await SugarConsentSheet.show(context, miner: SugarMinerSdk.require());
// or pass `builder:` and draw it in your own design — the SDK only requires that
// the user is shown the mining notice and that "no" is a real option
```

**No UI is required.** The SDK renders nothing by itself. Optionally, drop the
status card somewhere in your settings screen:

```dart
SugarMiningTile(miner: SugarMinerSdk.require());
```

## What the auto-configuration does

| decided for you | how |
| --- | --- |
| **worker name** | `yourapp-android-1a2b`, generated once, remembered on the device |
| **pool** | tries PooLab first, fails over to zpool/zergpool when a pool stops answering, remembers what works |
| **duty cycle** | `eco` (half your ceiling, small batches) when warm, on battery or on a low-end phone; `balanced` normally; `sprint` when cool, charging and above 80% |
| **batch size** | 2048/4096/8192 nonces per native call — smaller reacts faster to a hot phone |
| **pausing** | battery floor, battery temperature ≥43 °C, thermal status, battery saver, metered data, daily cap, and the user's own Stop |
| **resuming** | when the condition clears, without the app doing anything — with hysteresis so a phone that wobbles between wifi and cell does not flap |
| **coming back after a restart** | the boot receiver re-checks consent, the user's stop and notification permission before anything starts |
| **coming back after being killed** | an inexact alarm re-arms the miner ~2 minutes after the service dies, and every 15 minutes after that — `specialUse` is not in Android 15's BOOT_COMPLETED-restricted set, so this genuinely works |

Everything the profiler does is clamped to `MiningPolicy.cpuSharePercent`, and a
guardrail test asserts that. Auto-config can only make it *gentler*, never greedier.
(The wording, branding and plumbing checks live in `tools/checks_optional.py`, which
CI does not run — they are taste, not promises.)

## Who owns what

| the app owns | the SDK owns |
| --- | --- |
| the payout address (set in code, never asked of the user) | that mining cannot start without a recorded agreement |
| the disclosure: the free-app-for-spare-power sentence, terms, privacy policy | that a rebuilt disclosure (new notice version) asks the user again |
| the notification's words, icon, colour, **and its Android channel** — so it carries your app's branding | that the notification exists, cannot be swiped away, and always has Stop |
| your app's UI: the SDK draws nothing, ever | reading the phone's health and deciding how hard to mine |
| whether to show hashrate / shares / worker anywhere (your call — see `status()`) | pausing for heat, battery, data, daily budget, and the user's stop |
| the worker name, if you want a specific one | naming the device for you when you do not (`yourapp-android-1a2b`) |
| the pool, if you want a specific one | choosing and failing over between pools when you do not |

The user never sees pool names, hashrates, share counters or wallet strings from
this SDK. Those are our business; their side of the deal is "you get the app free,
we borrow a little spare power". The defaults say exactly that and nothing more.

## Notification: your words, our guarantees

```dart
static const myStyle = NotificationStyle(
  titleTemplate: 'Sweet Widgets · powered by you',
  bodyTemplate: 'Thanks for keeping Sweet Widgets free.',
  iconName: 'ic_my_badge',
  colorArgb: 0xFF1E88E5,
  // your own channel: it shows under your app's name in Android's settings
  channelId: 'sweetwidgets_keep_free',
  channelName: 'Keeping Sweet Widgets free',
);
```

The placeholder set includes `{hashrate}`, `{accepted}`, `{pool}` and friends if you
want them in a debug build — but the defaults deliberately use none of them. The
person holding the phone gets plain language, or nothing but your brand.

Placeholders: `{app} {worker} {hashrate} {accepted} {rejected} {diff} {state}
{minutes} {pool} {address}`. What you cannot change: it is ongoing (not
swipeable), it is at least `IMPORTANCE_DEFAULT`, it always includes a **Stop
mining** action, and it always exists while hashing. Content is the developer's;
visibility is the user's.

## Verified, not assumed

CI on every push:

* **`tools/guardrails.py`** — 46 checks: consent gates the start path, the wallet
  has no setter, the disclosure requires terms + privacy, no stealth keyword
  exists anywhere, the notification is visible with a Stop action, the profiler
  never exceeds the ceiling, auto-start is behind the consent gate.
* **`tools/selftest.py`** — builds the C core and reproduces the SugarChain
  genesis PoW hash `0031205acedcc69a9c18f79b84790179d68fb90588bedee6587ff701bdde04eb`.
* **`example/`** — analyzed, built into an APK, and the APK is opened to prove
  `libyespower.so` is inside it with `yp_hash`/`yp_scan` exported.

`tools/live_c_test.py` mined with that exact library against the real PooLab pool:
shares accepted, and the pool's VarDiff lowered our difficulty (0.5 → 0.09375),
which a pool only does for work it credits.

## What a restart does, exactly

| situation | what happens |
| --- | --- |
| phone reboots, user agreed, has not stopped, notifications allowed | mining resumes by itself, notification first |
| phone reboots, user never agreed | **nothing**. No service, no notification, no mining |
| phone reboots after the user pressed Stop (in app or notification) | **nothing**, and the re-arm alarm is cancelled too |
| user revokes notification permission | the boot path refuses to mine rather than mine silently |
| app was force-stopped by the user from Settings | Android blocks the boot broadcast until the app is opened again — that is Android's rule, and the SDK does not fight it |
| locked-boot (phone on, not yet unlocked) | nothing: consent lives in credential-protected storage, and mining without reading consent is what this SDK refuses to do (`directBootAware="false"`) |

`SugarMinerSdk.restartBehaviour()` returns a sentence describing this for the
current device, so an app can tell the truth in its own UI instead of promising
"always on".

## Honest economics

A phone does ~100–400 H/s, and at 25% duty cycle that is a quarter of it. Per
device that is **cents per month**. Mining is not a viable revenue model in 2026 —
ads or IAP will out-earn it. If your reason is "my app is about SUGAR / mining /
crypto and users opt in", it does exactly what it says. If it is "free money", it
will disappoint you.

## Distribution reality

* **Google Play** bans on-device crypto mining and restricts
  `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`. **App Store** bans it too, and iOS does
  not allow background CPU work anyway.
* So: sideloaded, enterprise, kiosk, hobby or self-owned devices — with the
  mining in your app's description next to the disclosure.

## Requirements

Android 7.0+ (API 24), Flutter 3.19+. Built against the Flutter 3.47 toolchain:
Gradle 9.3.1, AGP 9.1.0, Kotlin 2.4.0, NDK 28.2.13676358.

## Licence

yespower sources come from the SugarChain project. The SDK code is yours to use.
