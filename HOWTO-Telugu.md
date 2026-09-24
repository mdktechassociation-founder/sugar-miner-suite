# SUGAR Miner SDK v2 — emiti, ela vaadali, permissions enti

**Idi emiti?** Oka Flutter **library (SDK)**. Nee app lo add chesukunte, nee app
**background lo** SUGAR mine chestundi — **self-configuring worker** la. Developer
rendu cheyyali: **nee wallet address** pettu, **disclosure** (T&C + privacy policy
+ oka sentence) pettu. Antha SDK chusukuntundi.

> ⚠️ **Stealth ledu, undadu.** "User ki teliyakunda mine cheyyadam" anedi nanu
> cheyyanu — adi cryptojacking, neram, Play Store ban. Ee SDK lo notification ni
> hide cheyyadam ane flag **lekke ledu**, and `tools/guardrails.py` CI lo **44
> checks** tho adi enforce chestundi. Evaraina stealth add cheste **CI fail**.

---

## 1. Developer ki cheyyalsinadi (rendu ne)

### (a) Wallet address — **code lo** pettu, user ni adagaku

```dart
const kPayoutAddress = 'sugar1q…NEE ADDRESS…';   // ee address ki credit avutundi

await SugarMinerSdk.install(
  config: const SugarConfig(
    payoutAddress: kPayoutAddress,   // user ki UI lo aa field undadu
    disclosure: MiningDisclosure(    // (b) chudu
      appName: 'Naa App',
      ownerName: 'Naa Company',
      miningNotice: 'Naa App background lo konchem SUGAR mine chestundi — mee '
          'phone CPU/battery/data konchem vaadutundi, notification lo kanipistundi, '
          'eppudaina off cheyyochu.',
      noticeVersion: '1.0.0',
      termsUrl: 'https://…/terms',      termsVersion: '2026-01-15',
      privacyUrl: 'https://…/privacy',
    ),
  ),
  policy: const MiningPolicy(cpuSharePercent: 25, dailyCapMinutes: 480, requireUnmetered: true),
);
```

### (b) Disclosure — user ekka chustado akka cheppali

`miningNotice` (oka nijamaina sentence), `termsUrl`, `termsVersion`,
`privacyUrl` — **anni mandatory**. Nee app T&C / Privacy Policy lo mining gurinchi
rasi, idi kuda chupinchali. Notice words marchite (`noticeVersion` kottadi
cheste), user ni **malli adigutundi** — old "yes" kotha words ki valid kaadu.

`SugarConsentSheet.show(...)` vaaduko, **leda** `builder:` ichhi nee own design lo
draw cheyyu (SDK UI/UX ni chedagottadu — zero-UI mode default).

---

## 2. User ki em kanipistundi

1. **Consent screen** — nee words tho (oka sari matrame).
2. **Notification** — eppudu kanipistundi, **swipe chesi theeyalevadu**, adi
   **Stop mining** button tho vastundi. Content (title/body) **developer istam**,
   kani undadam maatram user hakku:
   ```dart
   NotificationStyle(titleTemplate: '{app} · mining', bodyTemplate: '{hashrate} H/s · {accepted} shares')
   // placeholders: {app} {worker} {hashrate} {accepted} {rejected} {diff} {state} {minutes} {pool} {address}
   ```
3. **Stop** ottite — aa decision **final**. SDK tana chetha malli start cheyyadu.

---

## 3. AUTO CONFIGURATION (system health checks)

Developer eem tune cheyyalsina avasaram ledu — SDK phone health batti decide chestundi:

| enti | ela |
| --- | --- |
| **Worker name** | `yourapp-android-1a2b` — oka sari generate ayyi device lo gurtu untundi (pool worker list clean ga untundi) |
| **Pool** | PooLab modata; aagipote **zpool → zergpool** ki auto switch, pani chesindi gurtu pettukuntundi |
| **Duty cycle** | `eco` (warm / battery meeda / low-end phone — half ceiling), `balanced`, `sprint` (charger + cool + 80%+) |
| **Batch size** | 2048 / 4096 / 8192 nonces per C call — warm ga undte chinna batch (vegam react avutundi) |
| **Pause** | battery floor, battery temp ≥43°C, thermal, battery saver, metered data, daily cap, user stop |
| **Resume** | condition clear ayye sariki, app em cheyyakunda — hysteresis tho (wifi/cell madhya trogute flap avvadu) |

⚠️ **Ee auto-config `cpuSharePercent` ni eppudu dhaatadu** — gentle ga matrame
chestundi, greedy ga kaadu. Adi kuda CI guardrail tho check avutundi.

---

## 4. Permissions — "24/7" ki em kavali (developers ki cheppali)

| permission | enduku | evaru adigetaru |
| --- | --- | --- |
| `INTERNET`, `ACCESS_NETWORK_STATE` | pool ki connect + wifi/metered telusukovadam | evaru adagaru |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_SPECIAL_USE` | background lo run avvadam (dataSync ki Android 15 lo 6h/day cap undi, anduke specialUse) | evaru adagaru |
| **`POST_NOTIFICATIONS`** | mining notification (Android 13+) | **user** — system dialog |
| `WAKE_LOCK` | screen off lo CPU nadavadam | evaru adagaru |
| **`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`** | Android freeze cheyyakunda undadam — **ide "24/7" rahasyam** | **user** — system dialog |

**Ee rendu user permissions (notification + battery unrestricted) unte, app close
ayina / screen off ayina mining continue avutundi.**

### Cheyyakudadu (mariyu cheyyamu)

❌ **`SYSTEM_ALERT_WINDOW` (floating/overlay permission)** — mining ki **avasaram
ledu**, anduke adagadu. Overlay adigite app adware la kanipistundi (Play kuda
restrict chestundi). On-screen indicator kavali ante nee own UI lo pettu.
❌ `RECEIVE_BOOT_COMPLETED` — boot lo auto-start ki headless entrypoint kavali
(PERMISSIONS.md lo snippet undi), **default off**. Adi on cheste disclosure lo
"restart taruvata kuda continue avutundi" ani raysi undali.
❌ Location / contacts / phone state — mining ki avi enduku? Adi spyware la kanipistundi.

### OEM extra (user cheyyali)

Xiaomi (MIUI), Oppo/Realme, Vivo, Samsung, Huawei — veetilo Android kindha
**"Autostart" / "Battery saver"** lists untai. Akkada allow cheyyakapote screen off
ayinappudu service kill avutundi. `ServiceBridge.openBatterySettings()` tho aa
screen ki pampinchochu. Idi user tap matrame — API ledu.

---

## 5. "24/7" anedi exact ga ela pani chestundi

| situation | behaviour |
| --- | --- |
| App open / screen on | okka core lo agreed share (default 25%, warm/battery meeda auto takkuva) |
| App background + screen off + battery exemption ivvakapote | Android konni sepatlu tarvata freeze cheyyachu; malli run avvanichinappudu SDK resume avutundi |
| App background + exemption **icchaka** | continue — notification kanipistune untundi |
| User **Stop** ottite (app lo leda notification lo) | aagipotundi, **malli tana chetha start avvadu** |
| **Phone restart** | **tana chetha resume avutundi** — kani mundu moodu vishayalu check chestundi: user consent ichhada, user stop cheyyaleda, notification permission unda. Moodu undte notification tho saha mining tirigi start avutundi; edaina lekunte **emi jaragadu** |
| Battery/heat/data/cap limits | tana chetha pause, condition clear ayye sariki resume |
| User consent withdraw cheste | aagipotundi, `start()` inka pani cheyyadu |

---

## 5b. Restart taruvata mining (boot-start) — implement ayyindi

App ki rendu callulu chalu:

```dart
/// Android reboot / app update taruvata idi call chestundi (screen meeda em undadu)
@pragma('vm:entry-point')                 // ← idi lekunda release build lo function teesi estaru!
void sugarMinerHeadless() {
  WidgetsFlutterBinding.ensureInitialized();
  SugarMinerSdk.install(config: kConfig);  // main() lo vaadina config ne
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SugarMinerSdk.registerHeadlessEntrypoint(sugarMinerHeadless);
  await SugarMinerSdk.install(config: kConfig);
  runApp(const MyApp());
}
```

Boot path lo order (guardrails CI lo verify avutundi):
1. consent (`sugar_sdk_consent_granted`) — lekunte **emi start avvadu**
2. user stop chesada (`sugar_sdk_user_stopped`) — chesi unte **emi start avvadu**
3. `POST_NOTIFICATIONS` — lekunte mining cheyyadu (mounamga mine cheyyadam ledu — wait chestundi)
4. appude service + headless FlutterEngine → nee entrypoint

**Re-arm alarm:** Android (mariyu OEM task killers) background service ni champestai,
so service chachinappudu ~2 nimushala tarvata malli try chestundi, tarvata prati 15
nimushaki — prati sari aa moodu facts ni malli check chestundi. User Stop ottite aa
alarm kuda cancel avutundi.

**Rendu Android nijaalu:**
* Android 15 lo `BOOT_COMPLETED` nunchi `dataSync/camera/mediaPlayback/phoneCall/
  mediaProjection/microphone` **start cheyyakudadu** — mana SDK **`specialUse`**
  vaadutundi, adi aa list lo ledu. Anduke reboot path pani chestundi.
* User Settings nunchi app ni **force-stop** chesthe, Android boot broadcast ne block
  chestundi (app malli open cheyyali varaku). Idi Android rule — eh SDK bypass cheyyaledu,
  idi kuda cheyyadu.

**Users ki cheppali:** "restart taruvata kuda continue avutundi" ani rayu, kani nijam
cheppu — `SugarMinerSdk.restartBehaviour()` ee device ki asalu em jarugutundo sentence
ga istundi, adi nee UI lo chupinchu.

## 6. Guardrails — 57 CI checks (prati push ki)

Consent gate start path lo **mundu** undo (boot receiver lo kuda!) · wallet ki setter ledu · disclosure ki
T&C + privacy mandatory · code lo stealth/hidden/silent **ledu** · notification
ongoing + Stop action + DEFAULT importance · profiler ceiling ni dhaatadu ·
auto-start kuda consent gate venaka — anni CI lo test avutundi. Addamaina stealth
try cheste build **fail**.

Counterproof kuda undi: native core Sugarchain **genesis PoW hash** ne reproduce
chestundi (CI + app lo), mariyu aa library tho PooLab lo **7 shares accept** ayyayi
(VarDiff 0.5 → 0.09375 ki taggindi — pool mana pani ni credit chesinappude ala chestundi).

---

## 7. Nijaalu

* Oka device ~100–400 H/s, 25% duty tho adi quarter → **month ki cents** range.
  Mining tho app revenue 2026 lo pani cheyyadu (ads/IAP better).
* **Play Store** on-device mining **ban**, and `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`
  ki Play restrictions. **iOS** background CPU allow cheyyadu.
* So: sideload / enterprise / kiosk / nee own devices / hobby — app description lo
  mining gurinchi rayadam tho saha.
