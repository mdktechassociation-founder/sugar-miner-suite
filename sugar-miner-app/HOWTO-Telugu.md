# SUGAR Miner app — ela install cheyyali, ela run cheyyali

**Idi enti?** Idi oka Flutter Android app. Start cheste phone lock chesina, app
close chesina mining **background lo continue avutundi** — notification tho saha.
Browser page kaadu, idi real native app.

---

## Step 1 — APK download (Flutter install avasaram ledu)

1. Repo open cheyyu: `https://github.com/mdktechassociation-founder/sugar-miner-app`
2. **Actions** tab → **build apk** workflow → latest green run open cheyyu
3. Page bottom lo **Artifacts** section → download cheyyu:
   - `sugar-miner-apk-universal` — andari phones ki pani chestundi (safe choice)
   - `sugar-miner-apk` — per-ABI (small size; modern phones ki `arm64-v8a`)
4. APK phone ki copy chesi install cheyyu. "Install unknown apps" allow cheyyali ane prompt vastundi → allow cheyyu.

## Step 2 — App open chesi settings

| field | emi pettali |
| --- | --- |
| Payout address | **Nee sugar1q… address** (idi lekunda start avvadu — app lo default address ledu, evari address ki credit avvali ante adi nuvve ista) |
| Worker | `phone` (leda nuvvu istam vachina peru) |
| Pool host | `stratum.poolab.org` (already set) |
| Port | `8451` (already set) |

**Start mining** press cheyyu → notification permission adigite **Allow** cheyyu.
Aa notification ne mining ni bathikistundi.

## Step 3 — Background lo vadudu (idi main feature)

- Home button / screen lock chesina **hashrate penchutune untundi**.
- Notification lo `SUGAR miner — 2xx H/s` ani kanipistundi. Adi unte mining jarugutundi.
- **Battery settings** lo app ki "no restrictions / allow background activity" ivvu
  (Xiaomi, Oppo, Vivo, Samsung aggressive ga kill chestai).
- Charger lo pettina better — CPU full ga pani chestundi, phone veditam avutundi.

## Step 4 — Nee shares check cheyyu

- App lo **Log** box lo `share ACCEPTED by the pool ✓` kanipistundi.
- Pool lo nee worker stats: `https://poolab.org/api/worker_stats?address=<nee address>`

---

## Ela pani chestundi (technical, short ga)

| part | enduku ila |
| --- | --- |
| Hashing | SugarChain **yespower C library** (`native/yespower/` → `libyespower.so`), Dart FFI dwara pilustunnam. Dart lo rasthe 2–5 H/s ne vastadi — unusable, andukane C. |
| Pool | **Direct TCP Stratum** — madhyalo proxy ledu, evaru nee shares chudaleru/maralaleru |
| Background | Android **foreground service** — screen off ayina hash aagadu |
| Self test | App open ayyagane native library tho Sugarchain **genesis PoW hash** ni verify chestundi. `engine ✓` kanipisthe library correct, `✗ WRONG HASH` ithe mine cheyyaku — naku cheppu |

## Nijaalu (over-promise cheyyadam ledu)

- Phone ~**100–400 H/s** istundi.
- Pool difficulty batti, okka share ki **thousands of hashes** — ante share okati ki konni nimushalu.
- Earnings **weeks/months** scale lo — hours lo kaadu. Idi hobby, income kaadu.
- Kaani idi **real mining**: nijamaina yespowerSUGAR shares, pool accept chestundi, nee address ki credit avutundi.

## Problem vasthe

| symptom | fix |
| --- | --- |
| `share rejected: [23, "low difficulty share"]` | Pool diff ki takkuva — 0.99 margin valla kabatti ala antundi; okka sari ayithe parvaledu |
| `job not found` | Job maripoindi (network slow) → tharuvata job tho automatic ga continue avutundi |
| Mining aagipoindi, notification poindi | Battery optimization restrictions → app ki "Unrestricted" ivvu |
| `engine unavailable` | APK lo native library load avvaledu → issue cheyyi, nenu chustanu |
| Hashrate 0 kanipistundi kaani notification undi | Pool nunchi job ravali — konni seconds agu |

## Repo nunchi nee inta build cheyyali anukunte

```bash
git clone https://github.com/mdktechassociation-founder/sugar-miner-app
cd sugar-miner-app
python3 tools/selftest.py        # C core correct aa leda check (genesis PoW hash)
flutter pub get
flutter build apk --release --split-per-abi
```
