#!/usr/bin/env bash
# Build aowlmony with the Nimony compiler (self-hosted).
#
# Output is bin/aowlmony-ng, NOT bin/aowlmony: the JS implementation stays the
# installed driver until test/diff.sh reports parity on every command.
#
# Overrides: NIMONY=/path/to/nimony  AOWLKIT=/path/to/aowlkit/src
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIMONY="${NIMONY:-$HOME/nimony/bin/nimony}"
AOWLKIT="${AOWLKIT:-$HOME/aowlkit/src}"
NIMLOCK="${NIMLOCK:-$HOME/.aowl/bin/nimlock}"
OUT="$ROOT/bin/aowlmony-ng"
cd "$ROOT"

[ -x "$NIMONY" ] || { echo "BUILD-FAIL: no nimony at $NIMONY (set NIMONY=)" >&2; exit 1; }
[ -d "$AOWLKIT" ] || { echo "BUILD-FAIL: no aowlkit at $AOWLKIT" >&2; exit 1; }

# Two ways this build silently did nothing, both guarded against here:
#  1. `bash -c` inherits neither unexported variables nor functions, so the lock
#     wrapper needs an explicit environment.
#  2. `nimony c --base:src src/x.nim` from the repo root resolves nimcache from
#     the CWD but nifmake from --base:, so it builds NOTHING and exits 0. The
#     compiler must run FROM the source directory with a bare relative filename.
export NIMONY AOWLKIT ROOT
build() {
  cd "$ROOT/src" && "$NIMONY" c -p:"$AOWLKIT" aowlmony.nim 2>&1
}
export -f build
if [ -x "$NIMLOCK" ]; then
  log="$("$NIMLOCK" bash -c 'build')"
else
  log="$(build)"
fi
rc=$?

# nimony can exit 0 on a failed build, so the exit status is not evidence. Ask
# for the artifact, and require it to be newer than every source compiled.
BIN="$(ls -t "$ROOT"/src/nimcache/*/aowlmony 2>/dev/null | head -1)"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "$log"
  echo "BUILD-FAIL: no binary produced (rc=$rc)" >&2
  exit 1
fi
newest_src="$(ls -t src/aowlmony.nim src/aowlmony/*.nim | head -1)"
if [ "$newest_src" -nt "$BIN" ]; then
  echo "$log"
  echo "BUILD-FAIL: $newest_src is newer than the artifact — this run did not relink" >&2
  exit 1
fi

mkdir -p "$ROOT/bin"
cp "$BIN" "$OUT"
echo "BUILD-OK: $OUT"
