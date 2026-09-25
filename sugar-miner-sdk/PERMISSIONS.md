# Permissions, and what "24/7" actually takes

For the app developer integrating this SDK. Short version: **two** things are
asked of the user — their agreement, and notification permission — plus **one**
setting that decides whether Android keeps the miner alive. Everything else is
declared in the manifest and needs no user interaction.

## What the SDK adds to your app's manifest

You do not edit anything. These arrive merged from the plugin:

| permission | why | who asks |
| --- | --- | --- |
| `INTERNET` | talk to the mining pool | nobody, normal permission |
| `ACCESS_NETWORK_STATE` | know whether you are on wifi or mobile data, so the miner can stop on metered connections | nobody |
| `FOREGROUND_SERVICE` | run while the app is backgrounded | nobody |
| `FOREGROUND_SERVICE_SPECIAL_USE` | Android 14+ requires a declared type; `specialUse` is used instead of `dataSync` because Android 15 caps `dataSync` at 6 hours per day | nobody |
| `POST_NOTIFICATIONS` | the mining notification (Android 13+) | **the user**, via a system dialog |
| `WAKE_LOCK` | keep the CPU on with the screen off | nobody |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | lets you ask for the exemption below | **the user**, via a system dialog |
| `RECEIVE_BOOT_COMPLETED` | resume mining after a reboot or app update, for a user who agreed and has not stopped | nobody |

The `specialUse` declaration includes a `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` string
that says, in the app's own manifest, that it mines on the user's behalf with
their permission. Store reviewers and curious users can both read it.

## The three asks, in the order the user meets them

### 1. The agreement (your screen, your words)

Not an Android permission — an actual decision, and the SDK's hard gate. It is
built from `SugarConfig.disclosure`:

* `miningNotice` — one or two plain sentences: **the app mines, for the
  developer, using CPU/battery/data, visible in a notification, stoppable.**
* `termsUrl` + `termsVersion` — your Terms & Conditions.
* `privacyUrl` — your Privacy Policy.
* `noticeVersion` — bump it when the words change; users are then asked again.

Show it with the SDK's sheet (`SugarConsentSheet.show`) or pass `builder` and
draw it yourself in your own design. Both paths record the same consent, and
`SugarMiner.start()` does nothing without it.

> Put the mining in the terms and privacy policy as well — that is where it
> belongs — but not *only* there. Consent that exists only inside a document is
> the thing this SDK is built to avoid.

### 2. Notifications (`POST_NOTIFICATIONS`)

The notification is *your* app's — your words, your icon, your colour, and your own
Android channel, so it sits under your app's name in the user's settings. The SDK's
defaults are plain language with no mining arithmetic in them. What you cannot
configure is whether it exists, how loud it is, or whether the user can dismiss it:
those three are what keep this on the right side of the line, and there is no API
for them anywhere in the SDK.

Requested by the SDK the first time mining starts. Consequences of "no": the
miner does not start at all. That is deliberate — mining without a visible
notification is the thing that makes phone mining malware, so there is no
fallback that mines quietly.

### 3. Battery unrestricted (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`)

This is the one that decides whether "24/7" is true. By default Android puts apps
into Doze/App Standby and freezes background work; a miner that gets frozen stops
submitting shares, and the notification eventually goes away with the service.

* Ask with `ServiceBridge.requestIgnoreBatteryOptimizations()` — it opens the
  system dialog ("Allow app to run in the background?").
* Check with `ServiceBridge.isIgnoringBatteryOptimizations()`; the SDK shows the
  status in `SugarMiningTile` and in `status()`.
* If the user declines, mining still runs — just with the normal Android
  lifecycle, which means it can be frozen after a while in the background.

**OEM extra step.** Xiaomi (MIUI), Oppo/Realme (ColorOS), Vivo (Funtouch),
Samsung, Huawei and others add their own "Autostart" / "Battery saver" lists on
top of Android's. On those phones the user must also allow your app there, or the
service is killed when the screen goes off. Point them at it with
`ServiceBridge.openBatterySettings()` and mention it in your FAQ. There is no API
that grants this for you — it must be the user's tap.

## What "24/7" means precisely

| situation | behaviour |
| --- | --- |
| App open, screen on | mining at the agreed share of one core (default 25%, auto-tuned down when warm or on battery) |
| App backgrounded, screen off, battery exemption granted | continues; the notification stays up |
| App backgrounded, no exemption | may be frozen by Android after a while; the re-arm alarm brings it back when Android lets it run |
| User presses Stop (app **or notification**) | stops and will **not** restart by itself, ever |
| Phone restarts | resumes by itself, notification first — **if** the user agreed, has not stopped, and notifications are allowed. Otherwise nothing happens at all |
| Battery below the floor, too warm, metered data, daily cap reached | pauses on its own; resumes when the condition clears |
| User withdraws consent | stops, and `start()` refuses from then on |

### Boot-start: implemented, not a snippet

Mining survives a reboot. Your app provides one entrypoint and registers it:

```dart
@pragma('vm:entry-point')
void sugarMinerHeadless() {
  WidgetsFlutterBinding.ensureInitialized();
  SugarMinerSdk.install(config: kConfig);       // same config you use in main()
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final ok = await SugarMinerSdk.registerHeadlessEntrypoint(sugarMinerHeadless);
  assert(ok);
  await SugarMinerSdk.install(config: kConfig);
  runApp(const MyApp());
}
```

What the boot path does, in order, before it starts anything:

1. reads the stored consent (`sugar_sdk_consent_granted`) — no consent, no mining;
2. reads the user's stop flag (`sugar_sdk_user_stopped`) — a stopped miner stays stopped;
3. checks `POST_NOTIFICATIONS` — no notification permission, no mining (it will not
   mine silently, so it waits instead);
4. starts the foreground service, then spins up a headless `FlutterEngine`
   (registering plugins the same way your activity does) and calls your entrypoint.

Two Android details worth knowing:

* Android 15 forbids `BOOT_COMPLETED` receivers from starting `dataSync`, `camera`,
  `mediaPlayback`, `phoneCall`, `mediaProjection` and `microphone` foreground
  services. This SDK uses **`specialUse`**, which is not on that list — that is why
  the reboot path works at all.
* If the user force-stops the app from Settings, Android blocks the boot broadcast
  until the app is opened again. No SDK can bypass that, and this one does not try.

The re-arm alarm is the companion piece: Android (and OEM task killers) end
background services, so the service schedules an inexact wake-up ~2 minutes after it
dies, then every 15 minutes, and the same receiver re-checks the three facts above
each time. Stopping mining cancels it.

Tell users what this means in *your* words. `SugarMinerSdk.restartBehaviour()` gives
you the sentence for the current device — surface it instead of promising "always on".

## What NOT to request

* **`SYSTEM_ALERT_WINDOW` (draw over other apps / "floating app" permission)** —
  not needed by this SDK and deliberately not requested. Nothing in mining needs
  to draw over the screen, and asking for it makes the app look like adware (Play
  restricts it for the same reason). If you want an on-screen mining indicator,
  say so in your own app's UI instead.
* Nothing extra for boot-start: `RECEIVE_BOOT_COMPLETED` is declared by the SDK and
  is pointless without a registered entrypoint, so register one (above) or leave it —
  the receiver does nothing either way.
* **`ACCESS_FINE_LOCATION`, contacts, phone state, etc.** — no. A miner that asks
  for these is not mining, it is spying.
* **`QUERY_ALL_PACKAGES`** — no reason.

## Store reality

Google Play prohibits apps whose primary purpose is on-device cryptocurrency
mining, and restricts `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` to apps whose core
function needs it. Apple bans background CPU mining outright. So this SDK is for
sideloaded, enterprise, kiosk, self-owned or hobby distribution — put the mining
in your app's own description there, next to the disclosure.
