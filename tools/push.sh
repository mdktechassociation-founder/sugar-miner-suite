#!/usr/bin/env bash
#
# One command to push this repository, with the token never stored anywhere.
#
#     tools/push.sh
#
# It asks for the token, uses it for this one push, and forgets it. The token is
# not written to .git/config, not written to the remote, not exported into your
# shell and not put on the command line — so it is not in `git remote -v`, not in
# your shell history, and not in `ps`. Read with `read -s`, so it is not echoed
# either.
#
# Use a fine-grained token with `Contents: Read and write` on this one repository,
# and revoke it when you are done: https://github.com/settings/tokens

set -euo pipefail

REPO_SLUG="mdktechassociation-founder/sugar-miner-suite"
BRANCH="${1:-main}"

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "this is not a git checkout" >&2
  exit 2
fi

# A commit needs a name on it, and `.git/config` is not always carried around (it is
# excluded from snapshots, and some checkouts are restored without it). Rather than
# failing with git's "empty ident name" after somebody has already typed a message,
# fill in the identity this repository's history uses.
if [[ -z "$(git config user.name 2>/dev/null)" || -z "$(git config user.email 2>/dev/null)" ]]; then
  git config user.name "MineHub"
  git config user.email "minehub@users.noreply.github.com"
  echo "  (set the commit identity to MineHub — .git/config did not have one)"
fi

echo
echo "  repository: $REPO_SLUG"
echo "  branch:     $BRANCH"
echo "  commits to send:"
git log --oneline "@{u}..HEAD" 2>/dev/null | sed 's/^/    /' || git log --oneline -5 | sed 's/^/    /'
echo

if [[ "${SKIP_CHECKS:-0}" != "1" ]]; then
  # Pushing is the one moment it is worth knowing the tree is good. Skip with
  # SKIP_CHECKS=1 when you are pushing a docs change and know it.
  printf '  run the checks first? [Y/n] '
  read -r answer
  if [[ ! "$answer" =~ ^[Nn]$ ]]; then
    "$(dirname "${BASH_SOURCE[0]}")/check_all.sh" || {
      echo
      echo "  the checks failed — fix that, or SKIP_CHECKS=1 tools/push.sh to push anyway" >&2
      exit 1
    }
  fi
fi

printf '\n  GitHub token (input hidden, used once, never stored): '
read -rs TOKEN
echo
[[ -n "$TOKEN" ]] || { echo "  no token given" >&2; exit 2; }

# The token goes in as the username of a one-shot URL. Nothing is configured, so
# nothing is left behind afterwards.
REMOTE="https://x-access-token:${TOKEN}@github.com/${REPO_SLUG}.git"

# The SDK is consumed by tag — a developer's pubspec and MineHub's wrapper both pin
# `sdk-vX.Y.Z`. That tag has to exist for the version we are pushing, or the pin
# points at nothing, so it is created and pushed here rather than by somebody who
# remembers. CI does the same thing as a net (see .github/workflows/sdk-tag.yml), so
# a push made any other way is covered too.
SDK_VERSION="$(sed -n 's/^version:[[:space:]]*//p' sugar-miner-sdk/pubspec.yaml \
  | head -1 | tr -d '[:space:]')"
SDK_TAG="sdk-v${SDK_VERSION%%+*}"
if git rev-parse -q --verify "refs/tags/$SDK_TAG" >/dev/null; then
  echo "  the SDK tag $SDK_TAG is already here"
else
  git tag "$SDK_TAG"
  echo "  tagging $SDK_TAG"
fi

echo
if git push "$REMOTE" "HEAD:${BRANCH}"; then
  # The tag goes afterwards, on its own. Pushed together with the branch it could
  # fail the whole push for being already present — which fails the push that carried
  # the actual work over a tag that was already correct. The branch is what matters.
  git push "$REMOTE" "refs/tags/${SDK_TAG}" >/dev/null 2>&1 \
    && echo "  the SDK tag $SDK_TAG is on the remote" \
    || echo "  ($SDK_TAG is already on the remote, or could not be pushed — the branch is fine)"
  TOKEN=""
  echo
  echo "  pushed."
  echo "  CI:      https://github.com/${REPO_SLUG}/actions"
  echo "  release: https://github.com/${REPO_SLUG}/releases/tag/latest"
  echo
  echo "  Revoke the token now if you made it for this: https://github.com/settings/tokens"
else
  TOKEN=""
  echo "  the push failed — the token may lack Contents: write on this repository" >&2
  exit 1
fi
