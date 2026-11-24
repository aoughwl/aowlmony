#!/usr/bin/env bash
# Assemble a self-contained aowl root (no nimony/nim binaries, libraries or checkouts).
#
#   tools/root/stage-linux-root.sh [ROOT]            # default ROOT=~/.aowl/root
#
# Inputs (override with env): REPOS=<dir holding the tool repos, default ../..>
#   $REPOS/aowlparser $REPOS/aowlsem $REPOS/aowlhexer $REPOS/aowlc   (each with bin/ built,
#   or built here with the previous root via BUILD_WITH=<existing root>)
#   STD=<aoughwl/std flattened tree, default rt/lib/std of this repo>
#   SRCLIB=<compiler-internal library sources the tools import: lib models nimony njvl lengc gear2 hexer v2>
# Result: ROOT/bin/{aowlparser,aowlsem,aowlhexer,aowlc,aowlmony}, ROOT/lib/std, ROOT/vendor/mimalloc,
#         ROOT/src (SRCLIB), ROOT/driver (tools/driver/*.js).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="${1:-$HOME/.aowl/root}"
REPOS="${REPOS:-$(dirname "$HERE")}"
STD="${STD:-$HERE/rt/lib/std}"
SRCLIB="${SRCLIB:?set SRCLIB to the directory holding lib/ models/ nimony/ njvl/ lengc/ gear2/ hexer/ v2/}"
mkdir -p "$ROOT"/{bin,lib,vendor,src,driver}
cp -r "$STD" "$ROOT/lib/"
cp -r "$HERE/rt/vendor/mimalloc" "$ROOT/vendor/"
for d in lib models nimony njvl lengc gear2 hexer v2; do [ -d "$SRCLIB/$d" ] && cp -r "$SRCLIB/$d" "$ROOT/src/"; done
cp "$HERE"/tools/driver/*.js "$ROOT/driver/"
cp "$HERE/tools/root/aowlbuild" "$ROOT/bin/aowlbuild"; cp "$HERE/bin/aowlmony" "$ROOT/bin/aowlmony"; chmod +x "$ROOT/bin/aowlbuild" "$ROOT/bin/aowlmony"
for t in aowlparser aowlsem aowlhexer; do cp "$REPOS/$t/bin/$t" "$ROOT/bin/$t"; done
cp "$REPOS/aowlc/bin/aowlc-native" "$ROOT/bin/aowlc"
echo "staged $ROOT"
