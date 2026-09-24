# Privacy policy — SUGAR Wallet

The short version: **the app has no account, no analytics, and no server of ours.
It talks to one public mining pool, and it tells it one thing — your wallet
address.**

## What leaves the device

| what | where it goes | why |
|---|---|---|
| Your wallet **address** | `stratum.poolab.org:8451` (the mining pool) | the pool must know where to credit the mined SUGAR |
| Your wallet **address** | `poolab.org` (its public stats API) | so the app can show your hashrate, balance and device list |
| Share submissions | the same pool, over the same connection | that is what mining is |

The address is public information: it is the same string anyone can look up on a
blockchain explorer to see the balance. It is not linked to any name, email, phone
number or account, because the app never asks for any of those.

## What never leaves the device

- The **private key**, the WIF, and the seed-equivalent material — they are
  generated locally and stored in the platform keystore. No code path in this app
  sends them anywhere.
- **Nothing else.** There is no analytics SDK, no crash reporter, no advertising
  identifier, no device fingerprinting, and no POST request of any kind in this
  app's code. The guardrails check fails the build if a network write appears.

## What is stored on the device

- The private key, in the platform keystore (encrypted; the wrapping key is in the
  hardware-backed Keystore where available).
- The **public** address, network, and creation date in ordinary preferences, so
  that mining can resume after a reboot without the keystore being read first.
- The SDK's own mining state: consent version and time, whether the user stopped
  mining, and minutes mined today.
- Your backup file, **if you copy it** — that is the only copy outside the device
  and you decide where it lives.

Erasing the wallet in the app removes all of it from the device. It cannot remove
anything from the blockchain, and it cannot move coins that are already at an
address whose key you have deleted.

## Third parties

The mining pool sees your address and your share submissions. It has its own
privacy policy; this app does not control it. Blockchain explorers can see the
address and its balance, because that is what a public blockchain is.

There is no other third party. Nothing is sold, shared, or brokered, because
nothing is collected.

Contact: the repository's issue tracker.
