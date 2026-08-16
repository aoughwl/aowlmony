#!/usr/bin/env bash
# `verify --memory` — the dangling-pointer check, ported to the Nimony driver.
#
# Every case is run through BOTH drivers and must agree, because the JS build is
# the oracle for this command as for every other; the assertions below then pin
# what the answer actually has to be, so "they agree" cannot be satisfied by two
# builds that are wrong in the same way.
#
# THE NEGATIVE CASES CARRY THE WEIGHT. A checker that flags the real defect and
# also flags `let p = addr b; use(p)` in one scope is a noise generator, so the
# clean programs are asserted as hard as the broken ones — and the clean verdict
# must state its COVERAGE, because "no defect" and "the walk never reached your
# module" otherwise print the same line.
#
# The line numbers are load-bearing in a second way: they come out of the NIF
# reader's base62, parent-relative line-info decoding. Get the delta base wrong
# and every position shifts, so these are also the reader's test.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NG="${NG_BIN:-$ROOT/bin/aowlmony-ng}"
NODE_BIN="$ROOT/bin/aowlmony"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -x "$NG" ] || { echo "no $NG — run ./build.sh first" >&2; exit 2; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }

PRELUDE='import std/syncio

type Buf = object
  data: string

proc use(p: ptr Buf) =
  echo "use: ", p.data

'

write_fixture() {   # <stem> <body>  -> path
  local f="$TMP/$1.nim"
  printf '%s%s' "$PRELUDE" "$2" > "$f"
  echo "$f"
}

# --- 1. the defect: p outlives the block that owns b, and is read after -------
uaf="$(write_fixture uaf 'proc main() =
  var p: ptr Buf
  block:
    var b = Buf(data: "hello")
    p = addr b
    use(p)
  use(p)

main()
')"
NO_COLOR=1 "$NG" verify "$uaf" --memory > "$TMP/uaf.out" 2> "$TMP/uaf.err"; ng_rc=$?
NO_COLOR=1 node "$NODE_BIN" verify "$uaf" --memory > "$TMP/uafj.out" 2> "$TMP/uafj.err"; js_rc=$?

[ "$ng_rc" = 1 ] && ok "a use after free exits 1" \
                 || bad "a use after free exits 1" "exit $ng_rc"
[ "$ng_rc" = "$js_rc" ] && ok "both drivers agree on the exit code ($ng_rc)" \
                        || bad "both drivers agree on the exit code" "nimony $ng_rc, js $js_rc"
grep -q ':12:9' "$TMP/uaf.err" && ok "the allocation site is named (12:9)" \
                               || bad "the allocation site is named (12:9)" "$(grep -m1 allocated "$TMP/uaf.err")"
grep -q ':15:7' "$TMP/uaf.err" && ok "the use site is named (15:7)" \
                               || bad "the use site is named (15:7)" "$(grep -m1 used "$TMP/uaf.err")"
grep -qE 'end of the scope opened at .*:11' "$TMP/uaf.err" \
  && ok "the freeing scope is named (opened at 11)" \
  || bad "the freeing scope is named" "$(grep -m1 freed "$TMP/uaf.err")"
grep -q '1 confirmed under --fin' "$TMP/uaf.err" \
  && ok "the finding is confirmed against the --fin run" \
  || bad "the finding is confirmed against the --fin run" "$(head -3 "$TMP/uaf.err" | tr '\n' '|')"
grep -q '=destroy witnessed here' "$TMP/uaf.err" \
  && ok "the destructor is witnessed at the blamed scope" \
  || bad "the destructor is witnessed at the blamed scope"

# --- 2. same scope: b and p die together, so nothing dangles ------------------
same="$(write_fixture memok1 'proc main() =
  var b = Buf(data: "hi")
  let p = addr b
  use(p)

main()
')"
NO_COLOR=1 "$NG" verify "$same" --memory > /dev/null 2> "$TMP/same.err"; rc=$?
[ "$rc" = 0 ] && ok "a pointer that dies with its target is not a defect" \
              || bad "a pointer that dies with its target is not a defect" "exit $rc"

# --- 3. rebound after the block: the dangling value never reaches the use -----
reb="$(write_fixture memok2 'proc main() =
  var p: ptr Buf
  var keep = Buf(data: "kept")
  block:
    var b = Buf(data: "hi")
    p = addr b
    use(p)
  p = addr keep
  use(p)

main()
')"
NO_COLOR=1 "$NG" verify "$reb" --memory > /dev/null 2> "$TMP/reb.err"; rc=$?
[ "$rc" = 0 ] && ok "reassigning the pointer clears the dangling state" \
              || bad "reassigning the pointer clears the dangling state" "exit $rc"

# --- 4. an escaping address, reported at the `addr` --------------------------
# NOT at the `ret`: a lowered `ret` carries no line info of its own and inherits
# the ROUTINE's, so anchoring there points at the `proc` header.
esc="$(write_fixture memesc 'proc mk(): ptr Buf =
  var b = Buf(data: "gone")
  result = addr b

proc main() =
  let p = mk()
  echo p.data

main()
')"
NO_COLOR=1 "$NG" verify "$esc" --memory > /dev/null 2> "$TMP/esc.err"; rc=$?
[ "$rc" = 1 ] && ok "an escaping address exits 1" || bad "an escaping address exits 1" "exit $rc"
grep -qE 'escapes.*:11:' "$TMP/esc.err" \
  && ok "the escape is reported at the addr, not at the proc header" \
  || bad "the escape is reported at the addr" "$(grep -m1 escapes "$TMP/esc.err")"

# --- 5. a clean verdict must state what it EXAMINED --------------------------
# NB: no prelude here. The shared prelude's `use(p: ptr Buf)` dereferences a
# pointer, which is itself an address-taking site — so a fixture built on it
# cannot test the "this file takes no addresses at all" verdict.
none="$TMP/memnone.nim"
printf 'import std/syncio\n\nproc main() =\n  echo "nothing to see"\n\nmain()\n' > "$none"
NO_COLOR=1 "$NG" verify "$none" --memory > /dev/null 2> "$TMP/none.err"; rc=$?
[ "$rc" = 0 ] && ok "a program that takes no addresses exits 0" \
              || bad "a program that takes no addresses exits 0" "exit $rc"
grep -q '0 address-taking sites' "$TMP/none.err" \
  && ok "a clean verdict reports its coverage, so it cannot be confused with an unreached walk" \
  || bad "a clean verdict reports its coverage" "$(grep -m1 'address-taking' "$TMP/none.err")"

echo ""
echo "$pass passed · $fail failed"
[ "$fail" = 0 ] || exit 1
