#!/usr/bin/env bash
#
# Everything the checks need, installed by one command.
#
#     tools/dev_setup.sh                 # the whole toolchain
#     tools/dev_setup.sh --no-browsers   # skip Chrome/Edge
#
# A fresh clone has the code and nothing to run it with: no Flutter, no packages,
# no browser for the page check. Working that list out by hand, in the right order,
# is the kind of manual step this repository keeps removing, so it lives here
# instead. Run it as often as you like — everything is skipped when it is already
# there, so a second run costs seconds.
#
# What it installs, and where:
#   Flutter 3.47.5   $HOME/.cache/fl/flutter           (~1 GB, the bulk of the time)
#   Dart packages    $HOME/.cache/pub                  (per project: pub get)
#   python packages  the system interpreter            qrcode, embit, opencv, numpy
#   browsers         wherever the platform puts them   Chrome, Edge (headless-capable)
#
# Nothing here needs root. The two steps that can use it — apt and pip on a managed
# Python — say so and are skipped without it.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

FLUTTER_VERSION="${FLUTTER_VERSION:-3.47.5}"
FLUTTER_DIR="${FLUTTER_DIR:-$HOME/.cache/fl/flutter}"
export PUB_CACHE="${PUB_CACHE:-$HOME/.cache/pub}"

WANT_BROWSERS=1
[[ "${1:-}" == "--no-browsers" ]] && WANT_BROWSERS=0

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
amber() { printf '\033[33m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }
has_sudo() { [[ "$(id -u)" == "0" ]] || sudo -n true 2>/dev/null; }
as_root() { if [[ "$(id -u)" == "0" ]]; then "$@"; else sudo "$@"; fi; }

SKIPPED=()
FAILED=()

bold "setting up the toolchain for $ROOT"

# ── 1. Flutter ───────────────────────────────────────────────────────────────
# Downloaded into the home cache rather than a system location, so this never needs
# root and never collides with a Flutter somebody already installed.
if [[ -x "$FLUTTER_DIR/bin/flutter" ]]; then
  green "  flutter: already at $FLUTTER_DIR ($("$FLUTTER_DIR/bin/flutter" --version 2>/dev/null | head -1))"
else
  case "$(uname -s)" in
    Linux)  ARCHIVE="flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" ;;
    Darwin) ARCHIVE="flutter_macos_${FLUTTER_VERSION}-stable.zip" ;;
    *)      ARCHIVE="" ;;
  esac
  if [[ -z "$ARCHIVE" ]]; then
    amber "  flutter: no archive for $(uname -s) — install it yourself and re-run"
    SKIPPED+=("flutter (unsupported platform $(uname -s))")
  else
    URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/$(uname -s | tr '[:upper:]' '[:lower:]')/$ARCHIVE"
    bold "  flutter: downloading $FLUTTER_VERSION (this is the slow part, ~1 GB)"
    DEST="$(dirname "$FLUTTER_DIR")"
    mkdir -p "$DEST"
    # Downloaded beside its destination, never into /tmp: on many systems /tmp is a
    # small tmpfs, and an 800 MB archive fills it and fails halfway. Cleaned up on
    # any exit, including a Ctrl-C, so a failed run leaves no rubble.
    PART="$DEST/.flutter-download-$$"
    trap 'rm -f "$PART"' EXIT INT TERM
    if [[ "$ARCHIVE" == *.zip ]]; then
      curl -fsSL -o "$PART" "$URL" && unzip -q -o "$PART" -d "$DEST"
    else
      curl -fsSL -o "$PART" "$URL" && tar xf "$PART" -C "$DEST"
    fi
    rm -f "$PART"
    if [[ -x "$FLUTTER_DIR/bin/flutter" ]]; then
      green "  flutter: $("$FLUTTER_DIR/bin/flutter" --version 2>/dev/null | head -1)"
    else
      red "  flutter: download failed"
      FAILED+=("flutter")
    fi
  fi
fi

DART=""
[[ -x "$FLUTTER_DIR/bin/dart" ]] && DART="$FLUTTER_DIR/bin/dart"
[[ -z "$DART" ]] && have dart && DART="dart"

# ── 2. Dart packages ─────────────────────────────────────────────────────────
if [[ -n "$DART" ]]; then
  for project in sugar-wallet-miner sugar-miner-sdk sugar-miner-app; do
    if [[ -f "$project/pubspec.yaml" ]]; then
      # `pub get` is fast when the lock file is satisfied, so this is not guarded.
      if (cd "$project" && "$FLUTTER_DIR/bin/flutter" pub get >/dev/null 2>&1); then
        green "  packages: $project"
      else
        red "  packages: $project failed"
        FAILED+=("pub get $project")
      fi
    fi
  done
else
  amber "  packages: no dart, so pub get was skipped"
  SKIPPED+=("dart packages (no flutter/dart)")
fi

# ── 3. Python packages the checks compare against ────────────────────────────
if have python3; then
  # qrcode and embit are reference implementations, not conveniences: the QR check
  # encodes with a second encoder, and the spend vectors come from embit. cv2 and
  # numpy decode the QR symbol back.
  PY_PKGS=(qrcode embit numpy opencv-python-headless)
  MISSING=()
  for pkg in qrcode embit numpy cv2; do
    python3 -c "import $pkg" >/dev/null 2>&1 || MISSING+=("$pkg")
  done
  if (( ${#MISSING[@]} == 0 )); then
    green "  python: qrcode, embit, numpy, opencv all present"
  else
    if python3 -m pip install -q "${PY_PKGS[@]}" 2>/dev/null \
       || python3 -m pip install -q --break-system-packages "${PY_PKGS[@]}" 2>/dev/null; then
      green "  python: installed ${PY_PKGS[*]}"
    else
      red "  python: could not install ${PY_PKGS[*]}"
      FAILED+=("python packages")
    fi
  fi
else
  amber "  python: not installed, and several checks need it"
  SKIPPED+=("python packages (no python3)")
fi

# ── 4. Browsers, for the page check ──────────────────────────────────────────
# Which browsers exist decides which browsers the page gets tested in, so this
# installs a Chromium-family browser (and gets Edge too, when the platform has a
# package for it) rather than taking whatever is there.
if (( WANT_BROWSERS == 0 )); then
  amber "  browsers: skipped (--no-browsers)"
elif have google-chrome || have google-chrome-stable || have chromium \
     || have chromium-browser || have microsoft-edge || have microsoft-edge-stable; then
  FOUND=""
  for b in google-chrome-stable google-chrome microsoft-edge-stable microsoft-edge chromium chromium-browser; do
    have "$b" || continue
    V="$("$b" --version 2>/dev/null | head -1)"
    # microsoft-edge is usually a symlink to microsoft-edge-stable: one browser, one line
    case "$FOUND" in *"$V"*) continue ;; esac
    FOUND="$FOUND${FOUND:+, }$V"
  done
  green "  browsers: $FOUND"
else
  bold "  browsers: none found; installing one the checks can drive"
  INSTALLED=0
  if [[ "$(uname -s)" == "Linux" ]] && have apt-get && has_sudo; then
    # Edge first where the vendor package is available, then Chromium from the
    # distribution — either is enough for the page check, and both is better.
    if curl -fsSL https://packages.microsoft.com/keys/microsoft.asc 2>/dev/null \
       | as_root gpg --dearmor --yes -o /usr/share/keyrings/microsoft.gpg 2>/dev/null; then
      echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/edge stable main" \
        | as_root tee /etc/apt/sources.list.d/microsoft-edge.list >/dev/null
      as_root apt-get update -qq 2>/dev/null
      as_root apt-get install -y -qq microsoft-edge-stable >/dev/null 2>&1 && INSTALLED=1
    fi
    if (( INSTALLED == 0 )); then
      as_root apt-get update -qq 2>/dev/null
      as_root apt-get install -y -qq chromium >/dev/null 2>&1 && INSTALLED=1
    fi
  fi
  if (( INSTALLED == 0 )) && have npx; then
    # Works without root anywhere node does: a headless Chrome in the home cache.
    bold "  chrome: downloading a headless shell with npx"
    mkdir -p "$HOME/.cache/chrome"
    npx --yes @puppeteer/browsers install chrome-headless-shell@stable \
      --path "$HOME/.cache/chrome" >/dev/null 2>&1 && INSTALLED=1
  fi
  if (( INSTALLED == 1 )); then
    green "  browsers: installed (the page check finds it by itself)"
  else
    amber "  browsers: could not install one — the page check will report a skip"
    SKIPPED+=("browsers (install Chrome, Edge or Chromium to run the page check)")
  fi
fi

# ── 5. file modes ────────────────────────────────────────────────────────────
# Some environments (containers, restored snapshots, zip round-trips) lose the
# executable bit, and then the very commands this project tells people to run answer
# "Permission denied". Cheap to check, so it is part of setup rather than a surprise.
for script in tools/*.sh; do
  [[ -f "$script" ]] || continue
  if [[ ! -x "$script" ]]; then
    chmod +x "$script"
    green "  modes: made $script executable again"
  fi
done

# ── what to do next ──────────────────────────────────────────────────────────
printf '\n'
bold "────────────────────────────────────────────────────────────"
if (( ${#FAILED[@]} > 0 )); then
  red "  could not set up:"
  for f in "${FAILED[@]}"; do printf '    ✗ %s\n' "$f"; done
  printf '\n'
fi
if (( ${#SKIPPED[@]} > 0 )); then
  amber "  skipped:"
  for s in "${SKIPPED[@]}"; do printf '    · %s\n' "$s"; done
  printf '\n'
fi

printf '  for this shell:\n'
printf '    export PATH="%s/bin:$PATH"\n' "$FLUTTER_DIR"
printf '    export PUB_CACHE="%s"\n' "$PUB_CACHE"
printf '\n'
printf '  then:\n'
printf '    tools/check_all.sh --strict\n'

(( ${#FAILED[@]} == 0 ))
