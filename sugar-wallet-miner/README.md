# SUGAR Wallet

An Android app where **every user gets their own Sugarchain wallet**, created on
their own device, and their phone mines SUGAR **into that wallet**. Not into the
developer's. The user keeps the coins; the app keeps none.

It is a Flutter app built on [`sugar-miner-sdk`](https://github.com/mdktechassociation-founder/sugar-miner-suite/tree/main/sugar-miner-sdk),
which supplies the mining engine, the foreground service, the always-visible
notification and the reboot receiver.

```
lib/
  main.dart                    entrypoint + the headless reboot callback
  app_config.dart              this app's disclosure, policy and pool endpoints
  theme.dart                   one dark theme, no surprises
  screens/onboarding.dart      create wallet → save backup → consent
  screens/home.dart            earnings, live status, start/stop
  screens/wallet_screen.dart   show, back up, import, erase
  screens/send.dart            spend: destination, amount, fee, sign, broadcast
  screens/receive.dart         one QR code and the address as text
  services/wallet_store.dart   keystore for the key, preferences for the address
  services/pool_api.dart       reads the pool's public API — nothing is reported
  services/chain_api.dart      the chain: unspent, fee estimate, broadcast
packages/sugar_wallet/         pure-Dart wallet generation and spending
tools/guardrails.py            33 checks on the promises this app makes
```

## What makes this app different from a developer-hosted miner

| | developer-hosted app | this app |
|---|---|---|
| who owns the payout address | the developer, set in code | **the user**, generated on their device |
| where the key lives | nowhere — the user never has one | the phone's keystore, and the user's backup |
| what the consent screen says | "mining keeps this app free" | "this mines for **you**; you can stop it" |
| who can spend the SUGAR | the developer | **only the user** |

## How the wallet works

`packages/sugar_wallet` generates the wallet, and spends from it, in pure Dart:
SHA-256, RIPEMD-160, secp256k1 (including ECDSA and RFC 6979 deterministic nonces),
bech32 (BIP-173), base58check and BIP-143 transaction signing, with no package
dependencies at all.
The parameters are Sugarchain's own, read from its `src/chainparams.cpp`:

| | |
|---|---|
| bech32 HRP | `sugar` (testnet `tugar`) |
| WIF prefix | `0x80` (testnet `0xEF`) |
| address | P2WPKH → `sugar1q…`, exactly what the miner SDK accepts |
| also derived | compressed public key, hash160, and the legacy `S…` address |

The key is generated with `Random.secure()`, written to the platform keystore
(AES-GCM values, RSA-OAEP wrapping key in the hardware-backed Keystore), and only
read back when the user asks to see or export it.

**The reboot path is why there are two stores.** Android calls the headless
callback before any UI exists, and after a reboot the keystore may not be readable
yet, so the app writes the *public address* to ordinary preferences as well. An
address is public information; a private key is not. Mining refers to the former
only — the SDK is handed an address and nothing else, ever.

### Sending — both kinds of coin

A Sugarchain address comes in two forms and a wallet has to handle both:

| | `sugar1q…` (P2WPKH, native segwit) | `S…` (P2PKH, legacy) |
|---|---|---|
| where it comes from | this app, the mining SDK, the official Android wallet | Core's `importprivkey`, the web wallet, anybody who pays the old address |
| how big a coin is to spend | 68 vB | 148 vB — more than twice |
| how it is signed | BIP-143 (commits to the amount) | the pre-segwit rule, in the scriptSig |

Both are supported end to end: the wallet derives both addresses from the same key,
receives at either, and spends from either. The coin's script decides how it is
signed, not a preference — signing a legacy coin with BIP-143 produces a signature
no node will accept, and signing a segwit coin the old way is worse. So the app asks
the chain what each unspent output's script actually is and signs accordingly, and
an output that belongs to neither of this wallet's scripts is refused rather than
signed.

The other half of "usable anywhere" is the key itself. The WIF this app shows is a
standard compressed-key Sugarchain WIF (prefix `0x80`): paste it into Core's
`importprivkey` or into the web wallet and it is the same wallet, at the same
addresses, with the same coins — and those two tools can spend them, which is why
the legacy half above exists.

Sending is done on the device and nowhere else. The screen asks the chain two
questions — what this address can spend, and what the chain charges per virtual
byte today — builds the transaction, shows the amount, the fee, the change and the
total on one card, and only then signs. The signature is BIP-143 P2WPKH, made with
deterministic RFC 6979 nonces so the same transaction signs to the same bytes every
time. What leaves the phone is the signed transaction and nothing else: no key, no
phrase, no account. The only write this app performs is `POST /esplora/tx` on the
chain's own API.

Dust is handled explicitly: below 546 satoshis an output costs more to spend than
it is worth, so the remainder goes into the fee instead of being left as an
unspendable coin.

### Verified, not assumed

```
dart run packages/sugar_wallet/test/wallet_vectors.dart   →  36 passed, 0 failed
dart run packages/sugar_wallet/test/hd_vectors.dart       →  61 passed, 0 failed
dart run packages/sugar_wallet/test/spend_vectors.dart    →  19 passed, 0 failed
```

The vectors are published ones, not this code's own output: the SHA-256 and
RIPEMD-160 standard test vectors (including the million-byte cases), the
**BIP-173 bech32 example**, and — because two implementations agreeing is a
stronger statement than one implementation being self-consistent — the same
private keys run through the JavaScript wallet in the MineHub console, asserting
byte-identical addresses and WIFs.

The spend vectors are the same idea applied to signing: **BIP-143's own published
native-P2WPKH transaction** is rebuilt from scratch and must produce its published
sighash and its published signature, byte for byte — which is only possible if the
ECDSA nonce is derived the way RFC 6979 says, because the published signature used
a deterministic one. Then a Sugarchain spend is compared against an independent
implementation (Python's `embit`): same sighash, same signature bytes, same raw
transaction, same txid.

## What it costs the user

Roughly 100–400 H/s on a phone. SUGAR trades at a fraction of a cent, so this is
pennies a day at best: a curiosity, a hobby, or a way to use a device you already
own. The app says so on its own home screen, in the "Worth knowing" section,
because an app that quietly overstates this is lying to the person who installed it.

Mining pauses automatically on heat, low battery, mobile data, or the daily cap,
and **the notification is visible the whole time it runs**, with a Stop button.
There is no API to hide it, in the app or in the SDK, and CI enforces that.

## Build it

```bash
flutter pub get
flutter build apk --release
# the APK lands in build/app/outputs/flutter-apk/app-release.apk
```

CI does exactly that on every push, and additionally checks the merged manifest
inside the built APK for `SugarMiningService`, `SugarBootReceiver`,
`RECEIVE_BOOT_NOTIFICATIONS`… (`POST_NOTIFICATIONS`), and the special-use
foreground-service reason — so "the miner really shipped" is a test result rather
than a hope.

```bash
python3 tools/guardrails.py    # 33 checks: the wallet is the user's, the mining is visible
flutter analyze                # clean
```

## Install it

**Not on Google Play.** Google prohibits on-device cryptocurrency mining. This app
is distributed by sideloading, enterprise/kiosk deployment, or an app store that
permits it. iOS is not a target: it does not allow background CPU work at all.

**On the user's phone**, three things need doing once:

1. Grant **notifications** — required before mining may start (the SDK refuses to
   mine silently).
2. Allow **unrestricted battery** — without it Android freezes the process when the
   screen goes off, and mining stops until the app is opened again.
3. On Xiaomi, Oppo/Realme, Vivo, Samsung and Huawei, allow **Autostart** in the
   OEM's own settings list; otherwise the service is killed on screen-off.

## Limits, stated plainly

- Play Store: prohibited. iOS: impossible. Sideload/enterprise only.
- A phone is not a rig. Expect cents, not income.
- The wallet is self-custody, which means **losing the backup loses the coins**.
  There is no account, no reset, and no support desk that can help — which is also
  why nobody, including whoever wrote this app, can take them from the user.
