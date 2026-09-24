# SUGAR Miner SDK — emiti, ela vaadali

**Idi emiti?** Oka Flutter **library (SDK)**. Nee app lo add chesukunte, nee app
**background lo** SUGAR mine chestundi — kani **user ki telisi, user permission
tho** matrame.

> ⚠️ **Stealth version ledu, undadu.** Nenu "user ki teliyakunda mine cheyyadam"
> build cheyyanu — adi cryptojacking, chala countries lo neram, Play Store ki
> ban. Ee SDK lo "notification hide cheyyu" ane flag **lekke ledu**. Adi
> `tools/guardrails.py` ane CI test tho **enforce** chestanu: evaru aina stealth
> try cheste CI **fail** avutundi.

---

## Emiti ivvachu (nijamga pani chestundi)

* **Native hashing** — SugarChain yespower C library (`libyespower.so`), dart FFI
  dwara. Dart lo rasthe 2–5 H/s ne vastadi, anduke C.
* **Direct Stratum** — proxy ledu, pool ki nerugaa TCP.
* **Background lo** — Android foreground service tho screen off ayina continues.
* **Consent** — user oka sari "Allow" cheyyali; aa choice device lo store
  avutundi, eppudaina withdraw cheyyochu.
* **Limits (default ga)** — 25% of one core, battery 30% kindaki pothe stop,
  phone veditam ayithe stop, metered data lo stop, rojuki 8 hours cap.
* **Notification** — enni limits unna, notification **eppudu kanipistundi**,
  swipe chesi theeyalevadu. Adi nee proof, adi user proof.

## Ela add cheyyali (3 steps)

**1. Dependency add cheyyu** (`pubspec.yaml`):

```yaml
dependencies:
  sugar_miner_sdk:
    git:
      url: https://github.com/mdktechassociation-founder/sugar-miner-sdk.git
      ref: main
```

`flutter pub get`. AndroidManifest lo **em cheyyalsina avasaram ledu** —
permissions, service, notification anni SDK ne thisukostundi.

**2. Code raayi:**

```dart
final miner = SugarMiner(
  config: const SugarConfig(
    payoutAddress: 'sugar1q…NEE ADDRESS…',   // nee address (user ni adagaku)
    worker: 'myapp',
  ),
  policy: const MiningPolicy(
    cpuSharePercent: 25,
    dailyCapMinutes: 480,
    requireUnmetered: true,   // user mobile data vaadukokunda
  ),
);

// oka sari permission adugu (first run lo)
await SugarConsentSheet.show(context, miner: miner, appName: 'Naa App');

// start / stop
await miner.start();
```

**3. UI lo status chupinchu:**

```dart
SugarMiningTile(miner: miner)   // hashrate, shares, Stop switch, withdraw button
```

Anthe. Migatha antha SDK chusukuntundi — policy check, pause/resume, reconnect,
notification update.

## Output ela chudali

* Notification: `Mining SUGAR — 213 H/s` / `accepted 4 · rejected 0` — eppudu kanipistundi.
* App lo tile: hashrate, accepted shares, "today X/Y minutes", **Stop**,
  **Withdraw permission**.
* Pool stats: `https://poolab.org/api/worker_stats?address=<nee address>`

## Nijaalu — modatane cheptha

| vishayam | nijam |
| --- | --- |
| Earning | Oka device ki **month ki cents** range. 25% CPU tho inka takkuva. Mining = revenue model kaadu, 2018 lone poyindi. |
| Play Store | On-device mining **banned**. Sideload / enterprise / kiosk / hobby ki matrame. |
| iOS | Background CPU pani cheyyadu — Apple allow cheyyadu. Android matrame. |
| iPhone/browser | Ledu. Android native app matrame. |
| CI | Prati push ki: guardrails 20 checks + genesis hash self-test + example APK build. |

## Ee SDK cheyyani panulu (by design)

❌ Stealth / hidden / silent mode — **ledu**
❌ Notification hide cheyyadam — **ledu**
❌ Permission lekunda start avvadam — **ledu** (code lo gate undi, CI test chestundi)
❌ Limits ni bypass cheyyadam — **ledu** (guardrails CI lo check avutundi)
❌ Play Store ki "clean" ga kanipinchadam — try cheyyaledu, cheyyanu

## Test cheyyadam (example app)

```bash
git clone https://github.com/mdktechassociation-founder/sugar-miner-sdk
cd sugar-miner-sdk/tools && python3 selftest.py     # C core correct aa
curl -L -o apk.zip https://github.com/mdktechassociation-founder/sugar-miner-sdk/actions   # Actions → ci → artifacts
```

Example app APK ni phone lo install chesi, nee address petti, permission ichi,
screen lock chesi notification chudu — hashrate perugutundi.

## Evariki pani chestundi

* Nee **sonta app** lo background mining monetization (user opt-in tho).
* Nee **own devices** (kiosk, farm, office phones) lo mining.
* SUGAR/mining gurinchi oka app ki "mining mode" feature.

Evariki pani cheyyadu: user permission adagakunda, evari phone lo ina mining
cheyyali anukune vaallaki. Adi nenu cheyyanu.
