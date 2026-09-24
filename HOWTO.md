# SUGAR Miner SDK v2 — what it is, how to use it, what it needs

**What it is.** A Flutter **library (SDK)**. Add it to your app and the app mines
SUGAR in the **background**, as a **self-configuring worker**. The developer does two
things: **set a wallet address**, and **provide a disclosure** (terms + privacy policy
+ one honest sentence). Everything else is handled for you.

> ⚠️ **No stealth, and none is coming.** "Mine without the user knowing" is not a
> feature of this SDK — it is cryptojacking, it is a crime in most countries, and it
> is a Play Store ban. There is no flag anywhere in the code to hide or silence the
> notification, and `tools/guardrails.py` enforces that in CI (**46 checks**). Add
> stealth and **CI fails**.

---

## 1. What the developer does (two things)

### (a) The wallet address — in code, never asked of the user

```dart
const kPayoutAddress = 'sugar1q…YOUR ADDRESS…';   // all credit goes here

await SugarMinerSdk.install(
  config: const SugarConfig(
    payoutAddress: kPayoutAddress,   // there is no field for this in the user's UI
    disclosure: MiningDisclosure(    // see (b)
      appName: 'Your App',
      ownerName: 'Your Company',
      miningNotice: 'Your App mines a little SUGAR in the background — it uses a '
          'small amount of your phone\'s CPU, battery and data, it shows a '
          'notification the whole time, and you can switch it off whenever you like.',
      noticeVersion: '1.0.0',
      termsUrl: 'https://…/terms',      termsVersion: '2026-01-15',
      privacyUrl: 'https://…/privacy',
    ),
  ),
  policy: const MiningPolicy(cpuSharePercent: 25, dailyCapMinutes: 480, requireUnmetered: true),
);
```

### (b) The disclosure — told to the user where they actually look

`miningNotice` (a real sentence), `termsUrl`, `termsVersion`, `privacyUrl` are all
**mandatory**. Put the mining section in your app's own terms and privacy policy as
well, and show this too. If you change the wording (by bumping `noticeVersion`), the
user is **asked again** — an old "yes" does not carry over to new words.

Use `SugarConsentSheet.show(...)`, **or** pass your own `builder:` and draw it your
way. The SDK never degrades your app's UI: zero UI is the default.

---

## 1b. Business model: "the app is free, you pay with spare computing power"

This is the common case, so there is a **ready-made wording** for it:

```dart
disclosure: MiningDisclosure.donation(
  appName: 'Sweet Widgets',
  ownerName: 'Sweet Widgets Ltd',
  termsUrl: 'https://…/terms',      termsVersion: '2026-01-15',
  privacyUrl: 'https://…/privacy',
  extraLine: 'Widgets, themes and sync stay exactly as they are — mining is what keeps it free.',
),
```

What the user reads: *"You use this app for free. In exchange, while it is charging
and you are not using it, it borrows a little of your phone's spare processing power
to mine SUGAR for the developer. That is what keeps the app free."* — it says
**"mine"**, because the user deserves the real word, and it carries **no hashrate,
pool or share arithmetic**, because none of that means anything to them.

## 1c. Who owns what

| the app / developer owns | the SDK owns |
| --- | --- |
| The payout address (in code) | That mining cannot start without a recorded agreement |
| The disclosure (free-app sentence + terms + privacy) | That a new notice version asks the user again |
| **Notification words, icon, colour and Android channel** (your brand) | That the notification **exists**, cannot be swiped away, and carries Stop |
| Your app's UI — the SDK draws nothing | Reading the phone's health and deciding how hard to work |
| Whether you surface hashrate/shares anywhere (your call) | Pausing for heat, battery, data, daily cap and the user's stop |
| Worker name / pool, if you want specific ones | Choosing them for you when you do not |

**The user never sees pool names, hashrate, share counters or wallet strings from this
SDK.** That is our business; their side of the deal is "the app is free, you lend a
little spare power".

## 2. What the user sees

1. **The consent screen** — in your words, once.
2. **The notification** — always visible, **cannot be swiped away**, and always carries
   a **Stop mining** button. **The words, icon, colour and channel are all yours**, so
   it appears under your app's brand in Android settings:
   ```dart
   NotificationStyle(
     titleTemplate: 'Sweet Widgets · powered by you',
     bodyTemplate: 'Thanks for keeping Sweet Widgets free.',        // no H/s, no shares
     channelId: 'sweetwidgets_keep_free', channelName: 'Keeping Sweet Widgets free',
   )
   // Placeholders exist if you want them: {hashrate} {accepted} {pool} …
   // but the SDK's defaults use none of them — they mean nothing to the user.
   ```
   **The SDK does not expose importance, priority or silence.** DEFAULT is fixed,
   ongoing is fixed, Stop is fixed. Without the notification Android kills the process
   (so mining would stop anyway), and mining where the user cannot see it is the crime
   this whole design avoids. That notification is their receipt.
3. **Stop** — once tapped, that decision is **final**. The SDK never restarts mining by
   itself after it.

---

## 3. Auto-configuration (the phone's own health checks)

There is nothing for a developer to tune — the SDK reads the device and decides:

| what | how |
| --- | --- |
| **Worker name** | `yourapp-android-1a2b` — generated once, remembered on the device, so your pool worker list stays readable |
| **Pool** | PooLab first; if it goes quiet, automatic failover to **zpool → zergpool**, remembering what worked |
| **Duty cycle** | `eco` (warm / on battery / low-end phone — half the ceiling), `balanced`, `sprint` (charging + cool + over 80%) |
| **Batch size** | 2048 / 4096 / 8192 nonces per C call — smaller batches when warm, so it reacts sooner |
| **Pause** | battery floor, battery temperature ≥43 °C, thermal status, battery saver, metered data, daily cap, user stop |
| **Resume** | as soon as the condition clears, without the app doing anything — with hysteresis, so flickering wifi does not flap it |

⚠️ **Auto-config can never exceed `cpuSharePercent`.** It can only be gentler, never
greedier. A CI check asserts that.

---

## 4. Permissions — what "24/7" needs (told to developers, plainly)

| permission | why | who is asked |
| --- | --- | --- |
| `INTERNET`, `ACCESS_NETWORK_STATE` | connect to the pool, know wifi vs metered | nobody |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_SPECIAL_USE` | run in the background (Android 15 caps `dataSync` at 6 h/day, which is why this uses `specialUse`) | nobody |
| **`POST_NOTIFICATIONS`** | the mining notification (Android 13+) | **the user** — system dialog |
| `WAKE_LOCK` | keep the CPU alive with the screen off | nobody |
| **`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`** | stop Android from freezing the process — **this is the "24/7" secret** | **the user** — system dialog |

**With those two user permissions (notification + battery unrestricted), mining
continues with the app closed and the screen off.**

### What it does not ask for (and never will)

- **`SYSTEM_ALERT_WINDOW`** (draw over other apps) — mining does not need it. Asking
  for it makes an app look like adware, and Play restricts it. Want an on-screen
  indicator? Put it in your own UI.
- Location, contacts, phone state — why would mining need those? It would look like
  spyware, and it would be treated like spyware.
- Nothing extra for boot-start: `RECEIVE_BOOT_COMPLETED` is declared by the SDK and is
  pointless without a registered entrypoint (see §5b), so register one or leave it —
  the receiver does nothing either way.

### OEM extras (the user does this part)

Xiaomi (MIUI), Oppo/Realme, Vivo, Samsung and Huawei keep their own **Autostart** and
**Battery saver** lists. Unless the app is allowed there, the service is killed when
the screen goes off. `ServiceBridge.openBatterySettings()` can take the user to that
screen, but it takes a tap — there is no API for it.

---

## 5. How "24/7" actually behaves

| situation | behaviour |
| --- | --- |
| App open / screen on | one core at the agreed share (25% by default, automatically less when warm or on battery) |
| Background + screen off, battery exemption **not** granted | Android may freeze the process after a while; the SDK resumes when it is allowed to run again |
| Background + screen off, exemption **granted** | keeps going; the notification stays visible |
| The user taps **Stop** (in the app or the notification) | it stops, and **the SDK will never start it again by itself** |
| **Phone restart** | **it resumes by itself** — after checking three things: consent is still granted, the user has not stopped it, and notification permission is held. All three → mining starts again with its notification; any one missing → **nothing happens** |
| Battery / heat / data / daily cap | pauses by itself, resumes when the condition clears |
| The user withdraws consent | stops, and `start()` refuses from then on |

---

## 5b. Mining after a restart (boot-start) — shipped

Three lines in the app are all it takes:

```dart
/// Android calls this after a reboot or an app update, with nothing on screen.
@pragma('vm:entry-point')                 // ← without this, release builds tree-shake it away!
void sugarMinerHeadless() {
  WidgetsFlutterBinding.ensureInitialized();
  SugarMinerSdk.install(config: kConfig);  // the same config your main() uses
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SugarMinerSdk.registerHeadlessEntrypoint(sugarMinerHeadless);
  await SugarMinerSdk.install(config: kConfig);
  runApp(const MyApp());
}
```

The order on the boot path (verified by CI):

1. consent (`sugar_sdk_consent_granted`) — missing → **nothing starts**
2. the user's own stop (`sugar_sdk_user_stopped`) — set → **nothing starts**
3. `POST_NOTIFICATIONS` — missing → it does not mine (it never mines silently; it waits)
4. only then: the service and a headless Flutter engine → your entrypoint

**The re-arm alarm.** Android — and OEM task killers — do kill background services, so
when the service dies the SDK tries again ~2 minutes later, and then every 15 minutes,
re-checking those three facts each time. If the user taps Stop, that alarm is cancelled
too.

**Two Android truths worth knowing:**

- On Android 15, `BOOT_COMPLETED` may not start a `dataSync / camera / mediaPlayback /
  phoneCall / mediaProjection / microphone` foreground service. This SDK uses
  **`specialUse`**, which is not on that list — that is why the reboot path works.
- If the user **force-stops** the app from Settings, Android blocks the boot broadcast
  until the app is opened again. That is Android's rule. No SDK can bypass it, and this
  one does not try.

**Tell your users the truth.** Do not write "continues after a restart" and hope.
`SugarMinerSdk.restartBehaviour()` returns a sentence describing exactly what happens on
that device — show it in your UI.

## 6. What CI enforces on every push (46 checks)

Consent gates the start path **before** anything else (including the boot receiver) ·
the SDK can never undo the user's "stop" · after a reboot, consent, stop and
notification permission are all re-checked · there is **no API** to silence, hide or
delay the notification (importance is fixed at DEFAULT, ongoing is fixed, Stop is
fixed) · the consented UI shows who benefits, never a wallet string · the payout address
has no setter · terms and privacy are mandatory · auto-config can never exceed the
agreed CPU ceiling · no stealth/hidden/silent wording exists anywhere in the code.

Two files exist now: **`tools/guardrails.py`** (46 checks, runs in CI — this is the only
thing that can fail the build) and **`tools/checks_optional.py`** (15 checks — wording,
branding, XML hygiene; not in CI; run it if you like it, delete the file if you do not).

There is a counter-proof too: the native core reproduces Sugarchain's **genesis
proof-of-work hash** (in CI and in the app), and with that core **7 shares were accepted
by PooLab** — its VarDiff fell from 0.5 to 0.09375, which a pool only does when it is
crediting the work as real.

---

## 7. The honest limits

- One phone does roughly 100–400 H/s; at a 25% duty cycle that is a quarter of it —
  **cents per month**. Mining is not an app revenue model in 2026 (ads or IAP are).
- **Play Store bans on-device mining**, and it restricts
  `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`. **iOS** does not allow background CPU work at
  all.
- So the real homes for this are: sideloading, enterprise/kiosk deployments, your own
  device fleet, and hobby projects — with mining stated in the app description.
