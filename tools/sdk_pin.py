#!/usr/bin/env python3
"""
The SDK is consumed by tag, not by branch. That is the right choice — a wrapper
pinned at `main` is a wrapper that changes under a developer's feet — but it means
every mention of `sdk-vX.Y.Z` is a claim about which engine a developer will get.
Written by hand in six files, those claims drift, and a drifted pin looks exactly
like a working one.

So the truth lives in one place: the version in `sugar-miner-sdk/pubspec.yaml`, which
is also what CI turns into the tag. This checks every other mention against it, and
fixes them all in one command.

    tools/sdk_pin.py          # check: does every pin point at the current version?
    tools/sdk_pin.py --fix    # make them all point at it
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PUBSPEC = ROOT / "sugar-miner-sdk" / "pubspec.yaml"

# Text that can hold a pin. Anything else is binary or generated.
SUFFIXES = {".md", ".dart", ".py", ".sh", ".yaml", ".yml", ".json", ".txt"}

# Generated or vendored trees, and the one file that talks about old versions on
# purpose: the changelog records history, so an old tag in there is correct.
SKIP_DIRS = {".git", "build", ".dart_tool", "node_modules", ".cache", ".github"}
SKIP_FILES = {"sugar-miner-sdk/CHANGELOG.md", "tools/sdk_pin.py"}

PIN = re.compile(r"sdk-v\d+\.\d+\.\d+")


def sdk_version() -> str:
    """The version the SDK declares — the one thing a pin is allowed to follow."""
    for line in PUBSPEC.read_text().splitlines():
        if line.startswith("version:"):
            return line.split(":", 1)[1].strip().split("+")[0]
    sys.exit(f"  no version: line in {PUBSPEC.relative_to(ROOT)}")


def text_files():
    """Everything git tracks, so untracked scratch files cannot cause a false alarm."""
    try:
        listing = subprocess.run(
            ["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True
        ).stdout.splitlines()
    except (subprocess.CalledProcessError, FileNotFoundError):
        listing = [
            str(p.relative_to(ROOT)) for p in ROOT.rglob("*") if p.is_file()
        ]
    for rel in listing:
        path = pathlib.Path(rel)
        if path.suffix not in SUFFIXES or rel in SKIP_FILES:
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        yield rel


def main() -> int:
    want = f"sdk-v{sdk_version()}"
    fix = "--fix" in sys.argv[1:]

    stale: list[tuple[str, list[str]]] = []
    mentions = 0

    for rel in text_files():
        path = ROOT / rel
        try:
            text = path.read_text()
        except (OSError, UnicodeDecodeError):
            continue
        found = sorted(set(PIN.findall(text)))
        if not found:
            continue
        mentions += len(PIN.findall(text))
        wrong = [tag for tag in found if tag != want]
        if not wrong:
            continue
        stale.append((rel, wrong))
        if fix:
            for tag in wrong:
                text = text.replace(tag, want)
            path.write_text(text)

    if not stale:
        print(f"  the SDK is {want.split('sdk-v')[1]}, and every pin says so")
        print(f"  {mentions} mentions across {len(list(text_files()))} tracked text files")
        return 0

    verb = "fixed" if fix else "wrong"
    print(f"  the SDK is {sdk_version()}, so its tag is {want} — these are {verb}:")
    for rel, tags in stale:
        print(f"    {rel:44} {', '.join(tags)}")
    if fix:
        print()
        print("  re-run without --fix to confirm.")
        return 0
    print()
    print("  fix: python3 tools/sdk_pin.py --fix")
    return 1


if __name__ == "__main__":
    sys.exit(main())
