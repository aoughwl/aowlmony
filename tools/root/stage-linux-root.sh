#!/usr/bin/env bash
# Assemble a self-contained aowl root (no nimony/nim binaries, libraries or checkouts).
#
#   tools/root/stage-linux-root.sh [ROOT]            # default ROOT=~/.aowl/root
#
# Inputs (override with env): REPOS=<dir holding the tool repos, default ../..>
#   $REPOS/aowlparser $REPOS/aowlsem $REPOS/aowlhexer $REPOS/aowlc   (each with bin/ built,
#   or built here with the previous root via BUILD_WITH=<existing root>)
#   AOWL_STD=<aoughwl/std checkout, default $REPOS/std-work/std or ../std>: ROOT/lib/std is flattened from its
#   COMMITTED content (git archive HEAD), never the working tree (CRLF-safe). STD=<flat tree> overrides.
#   NIF=<aowlnif checkout> MODEL=<aowlmodel checkout>   (default $REPOS/aowlnif, $REPOS/aowlmodel)
# Result: ROOT/bin/{aowlparser,aowlsem,aowlhexer,aowlc,aowlmony}, ROOT/lib/std, ROOT/vendor/mimalloc,
#         ROOT/src (SRCLIB), ROOT/driver (tools/driver/*.js).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="${1:-$HOME/.aowl/root}"
REPOS="${REPOS:-$(dirname "$HERE")}"
AOWL_STD="${AOWL_STD:-}"
if [ -z "$AOWL_STD" ]; then for c in "$REPOS/std-work/std" "$REPOS/std" "$HOME/Desktop/dev/std-work/std"; do [ -f "$c/tools/flatten_core.sh" ] && { AOWL_STD="$c"; break; }; done; fi
if [ -z "${STD:-}" ]; then
  [ -n "$AOWL_STD" ] || { echo "stage: set AOWL_STD to an aoughwl/std checkout" >&2; exit 2; }
  TMPSTD="$(mktemp -d)"; trap 'rm -rf "$TMPSTD"' EXIT
  mkdir -p "$TMPSTD/src"; git -C "$AOWL_STD" archive HEAD | tar -x -C "$TMPSTD/src"
  sh "$TMPSTD/src/tools/flatten_core.sh" "$TMPSTD/flat" >&2
  STD="$TMPSTD/flat/std"
  echo "std: $(git -C "$AOWL_STD" rev-parse --short HEAD) flattened from committed content" >&2
fi
if grep -rlq $'\r' "$STD" 2>/dev/null; then echo "stage: CR found in flattened std" >&2; exit 2; fi
NIF="${NIF:-$REPOS/aowlnif}"; MODEL="${MODEL:-$REPOS/aowlmodel}"   # the aowl-owned library repos
mkdir -p "$ROOT"/{bin,lib,vendor,src,driver}
rm -rf "$ROOT/lib/std"; cp -r "$STD" "$ROOT/lib/std"
MIM="$HERE/rt/vendor/mimalloc"; [ -d "$MIM" ] || MIM="${MIMALLOC:-$HOME/.aowl/root/vendor/mimalloc}"
[ -d "$ROOT/vendor/mimalloc" ] && [ "$MIM" = "$ROOT/vendor/mimalloc" ] || cp -r "$MIM" "$ROOT/vendor/"
for d in lib models; do cp -r "$NIF/$d" "$ROOT/src/"; done
for d in model njvl lengc gear2; do cp -r "$MODEL/$d" "$ROOT/src/"; done
cp "$HERE"/tools/driver/*.js "$ROOT/driver/"
cp "$HERE/tools/root/aowlbuild" "$ROOT/bin/aowlbuild"; cp "$HERE/bin/aowlmony" "$ROOT/bin/aowlmony"; chmod +x "$ROOT/bin/aowlbuild" "$ROOT/bin/aowlmony"
for t in aowlparser aowlsem aowlhexer; do cp "$REPOS/$t/bin/$t" "$ROOT/bin/$t"; done
cp "$REPOS/aowlc/bin/aowlc-native" "$ROOT/bin/aowlc"
echo "staged $ROOT"
