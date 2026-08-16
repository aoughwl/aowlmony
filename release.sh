#!/usr/bin/env bash
# Package aowlmony for a release: a platform-named binary and its checksum.
#
#   ./release.sh            → dist/aowlmony-<os>-<arch> + .sha256 + .glibc
#
# Same shape as aowlup's, deliberately — a stranger installs the manager and the
# driver by the same mechanism, and two mechanisms would mean two ways to be
# wrong. The naming is not cosmetic: `aowlup install` selects an asset by
# `<name>-<os>-<arch>`, so publishing only a bare name means the first
# non-Linux user downloads a binary that cannot run — a failure that arrives
# later and stranger than a missing asset would.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "$os" in darwin) os=macos ;; esac
case "$arch" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac
TRIPLE="$os-$arch"

./build.sh || { echo "release: build failed" >&2; exit 1; }

mkdir -p dist
OUT="dist/aowlmony-$TRIPLE"
cp bin/aowlmony-ng "$OUT"
chmod 755 "$OUT"

# The GLIBC FLOOR. This binary is dynamically linked, so it runs only where
# glibc is at least as new as the one it was built against. A release that does
# not record that hands an older-distro user "GLIBC_2.34 not found" from the
# dynamic loader — a failure with no connection to anything they did.
FLOOR="$(objdump -T "$OUT" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1 | sed 's/GLIBC_//')"
if [ -n "$FLOOR" ]; then
  echo "$FLOOR" > "$OUT.glibc"
  echo "  glibc floor: $FLOOR  (recorded in $(basename "$OUT").glibc)"
else
  echo "  glibc floor: none detected (static?)"
fi

if command -v sha256sum >/dev/null 2>&1; then
  (cd dist && sha256sum "aowlmony-$TRIPLE" > "aowlmony-$TRIPLE.sha256")
elif command -v shasum >/dev/null 2>&1; then
  (cd dist && shasum -a 256 "aowlmony-$TRIPLE" > "aowlmony-$TRIPLE.sha256")
else
  echo "release: no sha256 tool — publishing UNVERIFIABLE assets" >&2
fi

# A release artifact that cannot run is the failure worth catching while it is
# still cheap. `help` is the one command that needs no toolchain at all, so this
# tests the binary rather than the machine it was packaged on.
if ! NO_COLOR=1 "$OUT" help >/dev/null 2>&1; then
  echo "release: the packaged binary does not run — refusing to publish it" >&2
  exit 1
fi

# …and one that runs but cannot compile is worth catching too, when a toolchain
# is present. Skipped rather than failed when there is none: this is a packaging
# script, and "no compiler on the packaging host" is not a defect in the package.
if command -v nimony >/dev/null 2>&1 || [ -x "$HOME/nimony/bin/nimony" ]; then
  SMOKE="$(mktemp -d)"
  printf 'import std/syncio\necho "release-smoke"\n' > "$SMOKE/s.nim"
  if NO_COLOR=1 "$OUT" interp "$SMOKE/s.nim" 2>/dev/null | grep -q release-smoke; then
    echo "  smoke: compiled and ran a program"
  else
    echo "release: the packaged binary could not compile a hello world" >&2
    rm -rf "$SMOKE"
    exit 1
  fi
  rm -rf "$SMOKE"
else
  echo "  smoke: skipped (no nimony on this host)"
fi

echo "RELEASE-OK: $OUT"
ls -la "$OUT"* | sed 's/^/  /'
echo ""
echo "  upload all three files as release assets on aoughwl/aowlmony"
echo "  (aowlup install aowlmony reads the .glibc floor and refuses rather than"
echo "   installing a binary this machine cannot run)"
