#!/usr/bin/env bash
# Bring back work that was committed here but never pushed.
#
# This sandbox keeps the files but forgets git's objects between sessions, so a
# commit that has not been pushed can vanish while its changes stay on disk. The
# bundle next to the suite is a copy of everything, so recovering is one command
# instead of an archaeology exercise.
#
#   tools/restore.sh            # restore if git has lost commits
#   tools/restore.sh --force    # restore even if git looks healthy
set -euo pipefail

BUNDLE="${BUNDLE:-/home/user/sugar-wallet-updates.bundle}"
cd "$(dirname "$0")/.."
repo_root="$(pwd)"

if [[ ! -f "$BUNDLE" ]]; then
  echo "No bundle at $BUNDLE — nothing to restore from." >&2
  echo "If the work is still on disk, commit it and re-run tools/push.sh." >&2
  exit 1
fi

head_ref="$(git symbolic-ref --short -q HEAD || echo '')"
[[ "$head_ref" == "main" ]] || { echo "On '${head_ref:-detached HEAD}', not main. Stopping." >&2; exit 1; }

if git bundle verify "$BUNDLE" >/dev/null 2>&1; then
  echo "Bundle is readable."
else
  echo "Bundle at $BUNDLE is damaged; cannot restore from it." >&2
  exit 1
fi

if [[ "${1:-}" != "--force" ]] && git log --oneline -1 >/dev/null 2>&1; then
  # A healthy HEAD that already matches the bundle means there is nothing to do.
  if git rev-parse --verify -q refs/heads/main >/dev/null &&
     git merge-base --is-ancestor "$(git rev-parse refs/heads/main)" HEAD 2>/dev/null; then
    echo "git looks healthy (HEAD $(git rev-parse --short HEAD)). Use --force to overwrite anyway."
    exit 0
  fi
fi

git fetch -q "$BUNDLE" 'HEAD:refs/heads/recovered'
before="$(git rev-parse --short HEAD)"
git reset -q --hard recovered
git branch -q -D recovered
git clean -qfd -e '.dart_tool' -e 'build' -e 'node_modules' 2>/dev/null || true
echo "Restored: ${before} -> $(git rev-parse --short HEAD)"
echo
git log --oneline b0e8043..HEAD 2>/dev/null || git log --oneline -3
echo
echo "Next: tools/check_all.sh   then   tools/push.sh"
