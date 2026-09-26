#!/usr/bin/env bash
#
# Every check in this repository, in one command.
#
#     tools/check_all.sh            # run everything the machine can run
#     tools/check_all.sh --strict   # and fail if anything had to be skipped
#
# CI runs this with --strict; a person runs it without, and is told what was
# skipped rather than being left to remember eight separate commands. Adding a
# check means adding it here once, and both audiences get it.
#
# Nothing in here needs the network.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()
SKIPPED_NAMES=()

# ── output ──────────────────────────────────────────────────────────────────
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
amber() { printf '\033[33m%s\033[0m\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# run <name> <working dir> <command...>
run() {
  local name="$1" dir="$2"; shift 2
  printf '\n'
  bold "── $name"
  local out
  if out="$( cd "$dir" && "$@" 2>&1 )"; then
    PASS=$((PASS + 1))
    # Keep the last few lines — that is where the counts are.
    printf '%s\n' "$out" | tail -n 3 | sed 's/^/   /'
    green "   ✓ $name"
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
    printf '%s\n' "$out" | tail -n 25 | sed 's/^/   /'
    red "   ✗ $name"
  fi
}

# skip <name> <why>
skip() {
  local name="$1" why="$2"
  SKIP=$((SKIP + 1))
  SKIPPED_NAMES+=("$name — $why")
  printf '\n'
  bold "── $name"
  amber "   · skipped: $why"
}

# needs <tool> <name> <why> — skip when a tool is absent, otherwise run
# A bare Dart script needs `dart run`; `flutter run` would try to launch an app.
# Flutter ships a dart binary beside itself, so this is simply "is dart callable".
DART=""
if have dart; then DART="dart"; fi

bold "checking everything this repository claims"
printf '   repository: %s\n' "$ROOT"
printf '   dart:       %s\n' "${DART:-not installed}"
printf '   python:     %s\n' "$(have python3 && python3 -V 2>&1 || echo 'not installed')"
printf '   node:       %s\n' "$(have node && node -v 2>&1 || echo 'not installed')"

# ── 1. the wallet package: published vectors, no framework, no network ──────
if [[ -n "$DART" ]]; then
  # `dart run` works for a bare Dart package; the Flutter-bundled dart does too.
  run "wallet vectors (SHA/RIPEMD, bech32, base58)" sugar-wallet-miner \
      dart run packages/sugar_wallet/test/wallet_vectors.dart
  run "phrase vectors (BIP-39, BIP-32, 408 and the official path)" sugar-wallet-miner \
      dart run packages/sugar_wallet/test/hd_vectors.dart
  run "spend vectors (BIP-143's own transaction, and embit)" sugar-wallet-miner \
      dart run packages/sugar_wallet/test/spend_vectors.dart
else
  skip "wallet vectors" "dart is not installed"
  skip "phrase vectors" "dart is not installed"
  skip "spend vectors" "dart is not installed"
fi

# ── 2. the wallet app ───────────────────────────────────────────────────────
if have flutter; then
  run "wallet app — static analysis" sugar-wallet-miner \
      flutter analyze --no-fatal-infos
  run "wallet app — its own tests" sugar-wallet-miner flutter test
else
  skip "wallet app — static analysis" "flutter is not installed"
  skip "wallet app — its own tests" "flutter is not installed"
fi

if have python3; then
  run "wallet app — the promises it makes on its own screens" sugar-wallet-miner \
      python3 tools/guardrails.py
  # The QR check compares against a second encoder and a real decoder; without
  # them it skips itself rather than pretending.
  if python3 -c 'import qrcode' 2>/dev/null; then
    run "wallet app — the QR code, against a second encoder and a scanner" sugar-wallet-miner \
        python3 tools/check_qr.py
  else
    skip "wallet app — QR code" "pip install qrcode"
  fi
else
  skip "wallet app — guardrails" "python3 is not installed"
  skip "wallet app — QR code" "python3 is not installed"
fi

# ── 3. the SDK ──────────────────────────────────────────────────────────────
if have python3; then
  run "sdk — the promises that make mining consented and visible" sugar-miner-sdk \
      python3 tools/guardrails.py
  run "sdk — the native core is consensus-correct" sugar-miner-sdk \
      python3 tools/selftest.py
else
  skip "sdk — guardrails" "python3 is not installed"
  skip "sdk — native core self-test" "python3 is not installed"
fi

if have flutter; then
  run "sdk — static analysis" sugar-miner-sdk \
      flutter analyze --no-fatal-infos
  run "sdk — its own tests" sugar-miner-sdk flutter test
else
  skip "sdk — static analysis" "flutter is not installed"
  skip "sdk — its own tests" "flutter is not installed"
fi

# ── 4. the miner app ────────────────────────────────────────────────────────
if have flutter; then
  run "miner app — static analysis" sugar-miner-app \
      flutter analyze --no-fatal-infos
else
  skip "miner app — static analysis" "flutter is not installed"
fi

# ── 5. the browser page ─────────────────────────────────────────────────────
if have node; then
  run "browser miner — the page and the bridge behave" sugar-miner node tools/verify.js
else
  skip "browser miner" "node is not installed"
fi

# ── 5b. the same page, in a real browser ────────────────────────────────────
# The check above runs the page's code in Node, which proves the JavaScript and the
# WebAssembly are correct. It cannot prove the page *runs in a browser*: no DOM, no
# rendering, no Content-Security-Policy, and no browser deciding whether a SIMD module
# compiles. This one loads the published file in headless Chrome and asks it the
# questions only a browser can answer. It needs a browser, so on a machine without one
# it reports a skip rather than pretending.
if have node; then
  CHROME_BIN="${CHROME:-}"
  if [[ -z "$CHROME_BIN" ]]; then
    for candidate in google-chrome-stable google-chrome chromium chromium-browser; do
      if have "$candidate"; then CHROME_BIN="$(command -v "$candidate")"; break; fi
    done
  fi
  # The check finds every Chromium-family browser itself — Chrome, Edge, Chromium, or
  # a downloaded headless shell — and runs the page in each. BROWSERS=… overrides, and
  # dropping a new browser on the machine is enough to have it tested; nobody edits
  # this list to add one.
  if [[ -n "$CHROME_BIN" ]] || have google-chrome || have google-chrome-stable \
     || have chromium || have chromium-browser || have microsoft-edge || have microsoft-edge-stable \
     || [[ -n "$(ls -d "${HOME}"/.cache/chrome/*/ "${HOME}"/.cache/puppeteer/*/ 2>/dev/null)" ]]; then
    BROWSERS="${BROWSERS:-${CHROME_BIN:+$CHROME_BIN}}" \
      run "browser miner — the published page in real browsers" sugar-miner node tools/verify_browser.js
  else
    skip "browser miner in real browsers" "no Chrome, Edge or Chromium here — set BROWSERS=/path/to/browser"
  fi
else
  skip "browser miner in a real browser" "node is not installed"
fi

# ── 6. the platform ─────────────────────────────────────────────────────────
if have python3; then
  run "minehub — build the console" minehub python3 build.py
  run "minehub — the server and the wrapper" minehub python3 test_server.py
else
  skip "minehub" "python3 is not installed"
fi

# ── 7. the pins ─────────────────────────────────────────────────────────────
# The SDK is consumed by tag, so every mention of `sdk-vX.Y.Z` in the tree is a claim
# about which engine a developer gets. This is the check that stops those claims
# drifting apart — silently, and in six different files.
if have python3; then
  run "the SDK pins all point at the SDK's own version" . python3 tools/sdk_pin.py
else
  skip "the SDK pins" "python3 is not installed"
fi

# ── summary ─────────────────────────────────────────────────────────────────
printf '\n'
bold "────────────────────────────────────────────────────────────"
printf '  %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"

if (( SKIP > 0 )); then
  amber "  skipped:"
  for s in "${SKIPPED_NAMES[@]}"; do printf '    · %s\n' "$s"; done
fi

if (( FAIL > 0 )); then
  printf '\n'
  red "  failed:"
  for f in "${FAILED_NAMES[@]}"; do printf '    ✗ %s\n' "$f"; done
  exit 1
fi

if (( SKIP > 0 && STRICT == 1 )); then
  printf '\n'
  red "  --strict: nothing may be skipped, and ${SKIP} were."
  exit 1
fi

printf '\n'
green "  everything that could run, passed."
