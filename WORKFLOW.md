# What this suite is, what it does, and how it is used

Five pieces in one repository, each with one job. Everything here runs on the user's
device; there is no server of ours in the middle, and no account anywhere.

```
   sugar-miner-sdk        the engine: yespower mining, consent, the foreground service
        │
        ├── sugar-wallet-miner    the user's app — their own wallet, their phone mines into it
        ├── sugar-miner-app       the owner's app — their phone mines into THEIR address
        │
   minehub                the platform — creates wallets, attaches the engine to
        │                 somebody else's Flutter project, shows the fleet's earnings
        │
   sugar-miner            the web page — a browser cannot mine, so this is the bridge
                          and the landing page, not a miner
```

---

## 1. The four uses, and who uses each

| # | Use | Who | What they do | Where it lives |
|---|---|---|---|---|
| **0** | **Mine without installing anything** | a visitor | opens the page, accepts, mines in the browser through the WebSocket bridge | `sugar-miner/` (page + worker) |
| **1** | **Mine to your own address** | a pool operator, a project owner, anyone with a wallet | installs one APK, pastes or generates an address, presses start | `sugar-miner-app/` |
| **2** | **Mine to the user's own wallet** | an end user — this is the point of the project | installs one APK, gets a wallet made on the phone, mines into it, can spend it | `sugar-wallet-miner/` |
| **3** | **Put mining inside somebody else's app** | a developer with a Flutter app | three lines and a manifest entry, then their app mines and pays whoever they say | `sugar-miner-sdk/` + `minehub/` |

Said differently: **0** is the demo, **1** is a tool, **2** is a wallet, **3** is a
product other people build on. All four run the same engine, and all four obey the
same rules — consent before any hashing, a notification that cannot be dismissed
while mining, and a Stop that actually stops.

---

## 2. The end-to-end workflow, as a user lives it

### Step 1 — get the app
There is no Play Store listing: Google prohibits on-device cryptocurrency mining, so
this is a sideloaded APK. CI builds it on every push and attaches it to the run.

### Step 2 — first run: a wallet is made on the phone
Nothing is downloaded, nothing is registered, and there is no browser step.
`Random.secure()` makes a key, and the app writes it to the platform keystore.

```
     twelve words  ──►  m/44'/408'/0'/0/0  ──►  key ──►  the wallet
                                                          │
                    ┌─────────────────────────────────────┤
                    ▼                     ▼               ▼
              sugar1q… address       S… address         WIF
              (mining pays here)   (old wallets)   (the login)
```

The user is shown all of it once, on the "save this now" screen, and told plainly
that losing the key loses the coins.

### Step 3 — mining, visibly
The app hands the SDK the **address** and nothing else. The engine starts a
foreground service, shows a notification that cannot be swiped away, respects the
daily cap and the duty cycle, and stops the moment the user presses Stop. Earnings
come from the pool's own public API; the dollar figure from a named price feed; a
number the app cannot vouch for is shown as a dash, never as a guess.

### Step 4 — receiving
The receive screen draws a QR code. There is a switch above it, because this one key
has two addresses and only the receiver knows which the sender can handle:

* **`sugar1q…`** — native segwit. Modern wallets want this, and a coin that arrives
  here is cheap to spend later. This is what mining pays to.
* **`S…`** — legacy P2PKH. For an exchange or an old tool that refuses the new
  format. Same wallet, same coins, just more expensive to move later.

Both work. SUGAR sent to either address arrives, and the app can spend from both.

### Step 5 — sending
Destination, amount, then a card showing **amount, fee, change and total** — and
nothing is signed until the user presses send. Signing happens on the phone
(BIP-143 for segwit coins, the pre-segwit rule for legacy ones, both with
deterministic RFC 6979 nonces). What leaves the phone is the signed transaction and
nothing else; the one write the app ever performs is `POST /esplora/tx` on the
chain's own API.

### Step 6 — the wallet is portable, which is the whole idea
The WIF is a standard Sugarchain WIF. Paste it anywhere:

| paste into | result |
|---|---|
| Sugarchain Core — `importprivkey <wif>` | the same wallet, all of its addresses, spendable |
| the web wallet (coinbin-derived) | the same wallet, from the WIF or the xprv |
| this app again | the same wallet, both addresses, both balances |

The twelve words are the other half: any BIP-39 wallet that follows BIP-44 with coin
type **408** restores the same wallet from them.

---

## 3. The developer workflow — putting mining in somebody else's app

```
   their Flutter project                    what they add
   ─────────────────────                    ─────────────
   pubspec.yaml            ──►   3 lines: the git dependency, pinned to sdk-v2.2.0
   main.dart               ──►   1 import + 1 line in onCreate
   AndroidManifest.xml     ──►   1 <meta-data> for the disclosure text
```

That is the whole wrap. The SDK must not damage the host app: it never touches the
host's UI, it uses its own notification, and the guardrails check that.

`minehub/` automates it: the wrapper attaches the SDK to a project, the server
serves the wallet creator and the wrap service, and the console shows the fleet —
which devices are mining, at what hashrate, to which address — and generates the
deployment files.

---

## 4. What nobody has to do by hand

The rule for this section: if a human has to remember it, it is a bug.

| was manual | is now |
|---|---|
| remember eight commands to check the repository | `tools/check_all.sh` — one command, every check, and it says what it skipped rather than pretending |
| hunt through the Actions tab for the right run, download an artifact, hope it has not expired | **one permanent link**: `/releases/tag/latest` always holds the newest APKs |
| remember to rebuild before the artifact expires | a **weekly scheduled run** rebuilds and replaces them; the link never goes stale |
| notice when a Flutter or SDK update breaks the build | the same weekly run fails, and that is the notification |
| publish a broken build | the release job runs `check_all.sh --strict` first and does not publish unless every check passed |
| keep six copies of the SDK version pin in agreement, by hand | one source of truth (`the SDK's pubspec`) and `tools/sdk_pin.py` — the check fails the moment a pin drifts, and `--fix` rewrites them all |
| remember to tag the SDK so `ref: sdk-vX.Y.Z` resolves | `tools/push.sh` pushes the tag with the branch; CI creates it too, for pushes made any other way |
| watch an APK's signing certificate expire | it is minted at build time and valid to 2056, and the file is replaced weekly |
| push by hand, with the token going into git config or the shell history | `tools/push.sh` — asks for the token, uses it for one push, forgets it; nothing stored, nothing echoed, nothing in `ps` |
| paste an address into the send screen by long-press and a system menu | one tap on the paste button; the address is checked the moment it lands and the app says whether it looks right |

The two commands a person ever needs:

```bash
tools/check_all.sh              # is everything still true?
tools/push.sh                   # send it, and its tag with it
python3 tools/sdk_pin.py --fix  # only if the check says a pin drifted
```

## 5. The release workflow

```
   push to main
        │
        ├── wallet app workflow ──► analyze · 47 app tests · 36+61+28 vectors ·
        │                           33 guardrails · QR checks · release APK
        ├── sdk workflow ─────────► analyze · 55 guardrails · native core selftest
        ├── miner app workflow ───► analyze · APK · merged manifest assertions
        ├── platform workflow ────► minehub build + 71 server tests
        └── every-platform workflow ► linux · windows · macOS · web · iOS compile
```

Every release is a test result, not a promise: the APK is opened afterwards and the
merged manifest is checked for the mining service, the boot receiver and the
notification permission.

---

## 6. What we can do from here

**Blocked on you (one thing):** the commits from this round are in the local
repository and cannot be pushed from here — this sandbox has no write access to
GitHub. `tools/push.sh` does the whole push in one command with no token stored
anywhere, so it is now a four-second job instead of a manual one.

**Next, in the order I would do it:**

1. **Push, and watch CI go green** on the sending work. Every other step is easier
   once the code is on GitHub.
2. **Put it on a real phone.** Nothing in this suite has ever mined on real hardware.
   Install the wallet APK, let it mine for an hour, confirm the balance moves.
3. **Send a real amount to yourself.** The smallest meaningful payment — receive at
   the `S…` address, spend it back to `sugar1q…` — is the one test that proves the
   whole chain of custody end to end. It exercises exactly the path the vectors
   cover, on mainnet, with real coins.
4. **Then the two small open items**, neither of which blocks anybody: the worker's
   origin allowlist, and the `{message}` placeholder in the notification.

   Two things that used to be on this list are gone rather than deferred. The
   leftover `mining_tile.dart` is deleted — the SDK ships no UI at all now. And the
   APK expiry dates were a red herring: the certificate inside the published APK is
   minted by CI at build time and is valid to **2056**, and the file is replaced
   every week regardless, so there is no date for anybody to watch.

**What this suite will not do, stated plainly:** a browser cannot open a TCP socket
to a pool, so the web build runs the wallet and refuses to mine — the bridge page is
the web answer, not a native one. iOS suspends background apps, so mining there is
foreground only and says so. Nothing here goes on Google Play. The desktop builds are
unsigned.
