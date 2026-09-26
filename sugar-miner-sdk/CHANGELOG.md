# Changelog

## 2.2.0

### Removed

- **`SugarMiningTile` is gone.** The SDK ships no UI at all now: no status card, no
  readouts, nothing for a host app's users to stumble onto. If you want a line of
  status in your own settings screen, read `status()` and draw it yourself — the
  numbers are the same ones the tile used to lay out. This is what "ee sodhi antha
  sdk lo pettodhu" asked for, and it is the version of the SDK that can be dropped
  into somebody else's app without leaving a trace of ours in it.

### Fixed

- **The version number told the truth again.** `sdk-v2.1.0` was tagged on GitHub
  while `pubspec.yaml` still said `2.0.0`, so a developer pinning the tag got a
  package claiming to be the previous release. The number below is what the package
  actually is, and the tag for it is created by CI from this file rather than by
  somebody remembering to do it. See `.github/workflows/sdk-tag.yml`.

## 2.1.0

What the `sdk-v2.1.0` tag shipped, recorded here after the fact because the file was
left at 2.0.0 at the time.

- The native core builds on Windows (gcc, not MSVC) and macOS, so the platform work
  is real rather than claimed.
- The pre-filled bridge in the browser miner points at this project's own Worker by
  default, with `?ws=` still available to point it anywhere else.

## 2.0.0 — the rig release

The engine can now spend its budget on more than one core. Nothing about the budget
itself changed: **this release does not let the SDK use more of the phone than the
developer already agreed to.**

### Added

- **Rig mode, off by default.** `MiningPolicy.maxCores` (default `1`) lets the
  consented budget be *split* across several cores instead of spent on one:
  `cpuSharePercent: 50, maxCores: 4` means four cores at 12.5% duty each — the same
  50% of one core in total. It is opt-in, and the total is structurally incapable of
  exceeding `cpuSharePercent`.
- **Phone-side vetoes.** The split only happens while the device is charging, is cool
  (`thermalStatus` below 2) and is above 60% battery. The moment any of those stops
  being true, the plan collapses back to one core — the same code path a single-core
  integration always used.
- **`minPerCoreDuty`** (default `0.02`) — the smallest duty a core is worth running at.
  Eight cores at 3% each spend more time being scheduled than hashing, so the plan
  stops splitting before that.
- **`CorePlan` / `CoreScheduler`** are public, and `SugarMinerSdk.instance.corePlan`
  tells a host app what the engine decided and why, in plain words.
- **`MiningProfile` now carries `charging`, `thermalStatus` and `batteryPercent`**, so
  the watchdog can re-plan without re-reading Android.

### Why it is opt-in

Spreading the same duty over four cores produces roughly the same hashes, with better
scheduling luck on phones that otherwise push background work onto one little core.
On a pocket phone it also warms up faster, and the policy engine answers heat by
pausing — so a rig on a phone in someone's pocket can be *worse* than one core. Rig
mode is for the device that is plugged in and idle: a spare phone, a kiosk, a shelf of
donated handsets.

### Tests

`test/core_plan_test.dart` sweeps 11,200 policy/device combinations and asserts the
one property that matters: the total duty never exceeds the consented share, for any
core count, any charge state, any thermal state and any battery level.

## 1.0.0

First release: consented, visible background mining with a self-configuring worker,
pool failover, a hard daily minute budget, and health-based pausing.
