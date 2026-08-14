#!/usr/bin/env bash
# The port's acceptance gate: the JS driver and the Nimony driver over the same
# commands, requiring byte-identical output and exit code.
#
# The JS build is the ORACLE. A command counts as ported only when it matches
# here, or the difference is listed in EXPECTED_DIFF with a reason.
#
# NORMALISATION. Two things legitimately differ and would otherwise mask every
# real difference, so both are rewritten to placeholders before comparing:
#   * the stage directory. The JS driver keys it on the SOURCE PATH under
#     $TMPDIR; the Nimony driver keys it on the TOOLCHAIN under ~/.aowl/cache so
#     two projects share one warm stdlib. Different path, same role.
#   * the module hash, which is a hash of the source path relative to the
#     compiler's cwd — and the cwd is the stage dir.
# Everything else must match exactly.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="$ROOT/bin/aowlmony"
NG_BIN="${NG_BIN:-$ROOT/bin/aowlmony-ng}"
FILTER="${1:-}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -x "$NG_BIN" ] || { echo "no $NG_BIN — run ./build.sh first" >&2; exit 2; }

FIX="$TMP/fixtures"
mkdir -p "$FIX"
cat > "$FIX/hello.nim" <<'NIM'
import std/syncio

proc fib(n: int): int =
  if n < 2: n else: fib(n - 1) + fib(n - 2)

echo fib(20)
NIM
cat > "$FIX/broken.nim" <<'NIM'
import std/syncio
echo undefinedThing
NIM

norm() {
  sed -E \
    -e 's#/tmp/aowlmony-cache/[0-9a-f]+#<STAGE>#g' \
    -e "s#$HOME/\.aowl/cache/[0-9a-f]+#<STAGE>#g" \
    -e 's#<STAGE>/nc/[a-z0-9]+#<STAGE>/nc/<HASH>#g' \
    -e 's#<HASH>/[a-z][a-z0-9]+\.c\.nif#<HASH>/<HASH>.c.nif#g' \
    -e 's#main module [a-z][a-z0-9]+#main module <HASH>#g' \
    -e 's#compiled [0-9.]+m?s#compiled <T>#g' \
    -e 's#ran [0-9.]+m?s#ran <T>#g' \
    "$1"
}

# Deliberate differences, with reasons.
#   why           : a new command; the JS driver has no answer for "what changed"
#   <unported>    : ts/js/py/verify still belong to the JS driver, and the Nimony
#                   build says so with exit 3 rather than guessing
#   help          : lists the new `why` command
EXPECTED_DIFF=("help" "why FIX/hello.nim")

CASES=(
  "help"
  "nif FIX/hello.nim"
  "nif FIX/hello.nim -v"
  "interp FIX/hello.nim"
  "run FIX/hello.nim"
  "parse FIX/hello.nim"
  "nif FIX/missing.nim"
  "nif"
  "nosuchcommand FIX/hello.nim"
  "exec FIX/hello.nim"
  "nif FIX/broken.nim"
  "interp FIX/broken.nim"
  "why FIX/hello.nim"
  "ts FIX/hello.nim"
  "verify FIX/hello.nim"
  "verify FIX/hello.nim --native:aowlc"
  "verify FIX/diverge.nim"
  "js FIX/hello.nim"
  "py FIX/hello.nim"
  "ts FIX/hello.nim --run"
)

pass=0; fail=0; expected=0
for c in "${CASES[@]}"; do
  [ -n "$FILTER" ] && [[ "$c" != *"$FILTER"* ]] && continue
  run_args="${c//FIX/$FIX}"

  NO_COLOR=1 node "$NODE_BIN" $run_args > "$TMP/a.out" 2> "$TMP/a.err"; ea=$?
  NO_COLOR=1 "$NG_BIN"        $run_args > "$TMP/b.out" 2> "$TMP/b.err"; eb=$?

  same=1
  diff -q <(norm "$TMP/a.out") <(norm "$TMP/b.out") >/dev/null || same=0
  diff -q <(norm "$TMP/a.err") <(norm "$TMP/b.err") >/dev/null || same=0
  [ "$ea" = "$eb" ] || same=0

  is_expected=0
  for e in "${EXPECTED_DIFF[@]}"; do [ "$c" = "$e" ] && is_expected=1; done

  # A case can AGREE for the wrong reason. `verify … diverge.nim` must reach the
  # divergence path (exit 1); if a leg could not run, both implementations print
  # the same "nothing to compare against" and the case passes while asserting
  # nothing about the thing it exists to test.
  case "$c" in
    *diverge*)
      if [ "$ea" != "1" ]; then
        fail=$((fail+1))
        echo "FAIL '$c' did not reach the divergence path (oracle exit $ea, expected 1)"
        echo "    a leg could not run, so this case proved nothing"
        continue
      fi ;;
  esac

  if [ "$same" = 1 ]; then
    if [ "$is_expected" = 1 ]; then
      echo "?? '$c' is listed as an expected difference but MATCHES — drop it from EXPECTED_DIFF"
      fail=$((fail+1))
    else
      pass=$((pass+1))
    fi
  elif [ "$is_expected" = 1 ]; then
    expected=$((expected+1))
  else
    fail=$((fail+1))
    echo "FAIL aowlmony $c   (node exit $ea, nimony exit $eb)"
    diff -u <(norm "$TMP/a.out") <(norm "$TMP/b.out") | head -20 | sed 's/^/    /'
    diff -u <(norm "$TMP/a.err") <(norm "$TMP/b.err") | head -14 | sed 's/^/    /'
  fi
done

total=$((pass+fail+expected))
echo ""
echo "$pass/$total identical · $expected expected-different · $fail FAILED"
[ "$fail" = 0 ] || exit 1
