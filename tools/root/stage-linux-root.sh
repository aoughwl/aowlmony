#!/usr/bin/env bash
# Assemble a self-contained aowl root (no nimony/nim binaries, libraries or checkouts).
#
#   tools/root/stage-linux-root.sh [ROOT]            # default ROOT=~/.aowl/root
#
# Inputs (override with env): REPOS=<dir holding the tool repos, default ../..>
#   $REPOS/aowlparser $REPOS/aowlsem $REPOS/aowlhexer $REPOS/aowlc   (each with bin/ built,
#   or built here with the previous root via BUILD_WITH=<existing root>)
#   AOWL_STD=<aoughwl/std checkout, default $REPOS/std-work/std>: ROOT/lib/std is a tree of SYMLINKS into it (no copy).
#   NIF=<aowlnif checkout> MODEL=<aowlmodel checkout>   (default $REPOS/aowlnif, $REPOS/aowlmodel)
# Result: ROOT/bin/{aowlparser,aowlsem,aowlhexer,aowlc,aowlmony}, ROOT/lib/std, ROOT/vendor/mimalloc,
#         ROOT/src (SRCLIB), ROOT/driver (tools/driver/*.js).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="${1:-$HOME/.aowl/root}"
REPOS="${REPOS:-$(dirname "$HERE")}"
AOWL_STD="${AOWL_STD:-}"
if [ -z "$AOWL_STD" ]; then for c in "$REPOS/std-work/std" "$REPOS/std" "$HOME/Desktop/dev/std-work/std"; do [ -f "$c/core-layout.txt" ] && { AOWL_STD="$(cd "$c" && pwd)"; break; }; done; fi
[ -n "$AOWL_STD" ] || { echo "stage: set AOWL_STD to an aoughwl/std checkout" >&2; exit 2; }
mkdir -p "$ROOT"/{bin,lib,vendor,src,driver}
# lib/std = symlinks into the aoughwl/std checkout (no copy; edits there are live). Layout from core-layout.txt.
rm -rf "$ROOT/lib/std"; mkdir -p "$ROOT/lib/std"
grep -v '^#' "$AOWL_STD/core-layout.txt" | while read kind name; do
  [ -d "$AOWL_STD/$name" ] || { echo "stage: missing std folder $name" >&2; exit 3; }
  if [ "$kind" = tree ]; then
    (cd "$AOWL_STD/$name" && find . -type f | while read f; do
      if [ "$name/$f" = "system/./system.nim" ]; then ln -s "$AOWL_STD/$name/$f" "$ROOT/lib/std/system.nim"
      else mkdir -p "$ROOT/lib/std/$name/$(dirname "$f")"; ln -s "$AOWL_STD/$name/$f" "$ROOT/lib/std/$name/$f"; fi
    done)
  else for f in "$AOWL_STD/$name"/*; do [ -f "$f" ] && ln -s "$f" "$ROOT/lib/std/$(basename "$f")"; done; fi
done
if find -L "$ROOT/lib/std" -type f \( -name '*.nim' -o -name '*.aowl' -o -name '*.c' -o -name '*.h' \) -print0 | xargs -0 grep -lq $'\r' 2>/dev/null; then
  echo "stage: CRLF files in $AOWL_STD (checkout is CRLF-dirty). Run: git -C $AOWL_STD checkout -- .   (the dirt is CR-only)" >&2; exit 2; fi

MIM="$HERE/rt/vendor/mimalloc"; [ -d "$MIM" ] || MIM="${MIMALLOC:-$HOME/.aowl/root/vendor/mimalloc}"
[ -d "$ROOT/vendor/mimalloc" ] && [ "$MIM" = "$ROOT/vendor/mimalloc" ] || cp -r "$MIM" "$ROOT/vendor/"
for d in lib models; do cp -r "$NIF/$d" "$ROOT/src/"; done
for d in model njvl lengc gear2; do cp -r "$MODEL/$d" "$ROOT/src/"; done
cp "$HERE"/tools/driver/*.js "$ROOT/driver/"
cp "$HERE/tools/root/aowlbuild" "$ROOT/bin/aowlbuild"; cp "$HERE/bin/aowlmony" "$ROOT/bin/aowlmony"; chmod +x "$ROOT/bin/aowlbuild" "$ROOT/bin/aowlmony"
for t in aowlparser aowlsem aowlhexer; do cp "$REPOS/$t/bin/$t" "$ROOT/bin/$t"; done
cp "$REPOS/aowlc/bin/aowlc-native" "$ROOT/bin/aowlc"
echo "staged $ROOT"
