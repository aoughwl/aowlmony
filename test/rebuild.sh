#!/usr/bin/env bash
# What the cache must actually guarantee. Every case here is written so it CAN
# go red: each asserts a rebuild happens, or that an answer changed — never
# merely that a command exited 0.
#
#   1. the toolchain is part of the cache identity
#   2. a content change with a PRESERVED mtime still produces the new answer,
#      for an IMPORTED module and not only the entry file
#   3. switching profile does not share artifacts
#   4. a failed build records nothing
#   5. a second project reuses the first one's warm stdlib
#
# Case 2 is the one that matters most: mtime does not merely over-detect, it
# MISSES changes — `git checkout` of an older revision, `cp -p`, `rsync --times`
# and same-second edits all leave changed bytes with an unchanged mtime. It is
# run against BOTH drivers, because the JS driver guards the entry file only and
# this is the difference the rewrite is for.
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

stage_of() { NO_COLOR=1 "$NG" why "$1" 2>/dev/null | sed -n 's/^  stage //p' | tail -1; }

# --- 1. the toolchain is part of the cache identity -------------------------
mkdir -p "$TMP/p1"
cat > "$TMP/p1/main.nim" <<'NIM'
import std/syncio
import lib
echo value()
NIM
cat > "$TMP/p1/lib.nim" <<'NIM'
proc value*(): int = 1
NIM

NO_COLOR=1 "$NG" nif "$TMP/p1/main.nim" >/dev/null 2>&1
base_stage="$(stage_of "$TMP/p1/main.nim")"
cp "$HOME/nimony/bin/nimony" "$TMP/nimony-copy" 2>/dev/null || true
alt_stage="$(AOWLMONY_NIMONY=$TMP/nimony-copy stage_of_x=1 NO_COLOR=1 "$NG" why "$TMP/p1/main.nim" 2>/dev/null | sed -n 's/^  stage //p' | tail -1)"
if [ -n "$base_stage" ] && [ -n "$alt_stage" ] && [ "$base_stage" != "$alt_stage" ]; then
  ok "a different compiler binary is a different cache"
else
  bad "a different compiler binary is a different cache" "both resolved to $base_stage"
fi

# --- 2. a content change with a preserved mtime ------------------------------
check_preserved_mtime() {
  # NB: separate `local` statements. In `local a="$1" b="$a"`, bash declares both
  # names as unset locals FIRST, so the second reads the empty local, not "$1".
  local drv="$1"
  local label="$2"
  local proj="$TMP/mt-$2"
  mkdir -p "$proj"
  cat > "$proj/lib.nim" <<'NIM'
proc value*(): int = 1
NIM
  cat > "$proj/main.nim" <<'NIM'
import std/syncio
import lib
echo value()
NIM
  local first
  first="$(NO_COLOR=1 $drv interp "$proj/main.nim" 2>/dev/null | tail -1)"
  [ "$first" = "1" ] || { bad "[$label] baseline build prints 1" "got '$first'"; return; }

  # change the CONTENT of the imported module, then restore its old timestamp —
  # exactly what a `git checkout` of an older revision looks like on disk.
  local stamp
  stamp="$(date -r "$proj/lib.nim" '+%Y%m%d%H%M.%S')"
  cat > "$proj/lib.nim" <<'NIM'
proc value*(): int = 42
NIM
  touch -t "$stamp" "$proj/lib.nim"

  local second
  second="$(NO_COLOR=1 $drv interp "$proj/main.nim" 2>/dev/null | tail -1)"
  if [ "$label" = "js-oracle" ]; then
    # The JS driver hashes the ENTRY FILE ONLY, so an imported module that keeps
    # its mtime is not noticed and the previous build is served. Asserted here as
    # a KNOWN baseline rather than skipped: this is the defect the rewrite fixes,
    # and if it ever starts passing this note has gone stale and should be cut.
    if [ "$second" = "1" ]; then
      ok "[$label] known gap reproduced: stale artifact served (printed 1, not 42)"
    else
      bad "[$label] known gap NO LONGER reproduces — printed '$second'" \
          "the JS driver appears fixed; update this test and the rewrite's rationale"
    fi
    return
  fi
  if [ "$second" = "42" ]; then
    ok "[$label] an mtime-preserving edit of an IMPORTED module still gives the new answer"
  else
    bad "[$label] an mtime-preserving edit of an IMPORTED module still gives the new answer" \
        "printed '$second', expected 42 — a stale artifact was served"
  fi
}
check_preserved_mtime "$NG" "nimony"
check_preserved_mtime "node $NODE_BIN" "js-oracle"

# --- 3. profiles do not share artifacts -------------------------------------
a_stage="$(NO_COLOR=1 "$NG" why "$TMP/p1/main.nim" 2>/dev/null | sed -n 's/^  stage //p' | tail -1)"
n_stage="$(NO_COLOR=1 "$NG" +nimony why "$TMP/p1/main.nim" 2>/dev/null | sed -n 's/^  stage //p' | tail -1)"
if [ -n "$a_stage" ] && [ -n "$n_stage" ] && [ "$a_stage" != "$n_stage" ]; then
  ok "+nimony and the default profile use disjoint stages"
else
  bad "+nimony and the default profile use disjoint stages" "both '$a_stage'"
fi

# --- 4. a failed build records nothing --------------------------------------
mkdir -p "$TMP/bad"
cat > "$TMP/bad/main.nim" <<'NIM'
import std/syncio
echo thisIdentifierDoesNotExist
NIM
NO_COLOR=1 "$NG" nif "$TMP/bad/main.nim" >/dev/null 2>&1
rc=$?
if [ "$rc" != "0" ]; then
  why_out="$(NO_COLOR=1 "$NG" why "$TMP/bad/main.nim" 2>/dev/null)"
  if echo "$why_out" | grep -q "no previous build"; then
    ok "a failed build leaves no cache entry"
  else
    bad "a failed build leaves no cache entry" "why says: $(echo "$why_out" | head -1)"
  fi
else
  bad "a failed build exits non-zero" "exited 0"
fi

# --- 5. a second project reuses the warm stdlib -----------------------------
mkdir -p "$TMP/p2"
cat > "$TMP/p2/other.nim" <<'NIM'
import std/syncio
echo "second project"
NIM
p2_stage="$(NO_COLOR=1 "$NG" nif "$TMP/p2/other.nim" >/dev/null 2>&1; stage_of "$TMP/p2/other.nim")"
if [ -n "$p2_stage" ] && [ "$p2_stage" = "$base_stage" ]; then
  ok "a second project shares the first one's stage (warm stdlib)"
else
  bad "a second project shares the first one's stage" "p1=$base_stage p2=$p2_stage"
fi

# --- 6. `why` tells the truth in BOTH directions -----------------------------
# It could not, and nothing caught it: `why` computed its closure with an empty
# libDir while the build passed the real one, so it compared a manifest carrying
# the whole stdlib against a recorded one that by construction never could. It
# reported every stdlib module as newly added, on every unchanged program, for
# ever. A one-directional check would have passed — hence both directions here.
mkdir -p "$TMP/wy"
cat > "$TMP/wy/main.nim" <<'NIM'
import std/syncio
import helper
echo greet()
NIM
cat > "$TMP/wy/helper.nim" <<'NIM'
proc greet*(): string = "one"
NIM
NO_COLOR=1 "$NG" nif "$TMP/wy/main.nim" >/dev/null 2>&1
why_clean="$(NO_COLOR=1 "$NG" why "$TMP/wy/main.nim" 2>/dev/null)"
if echo "$why_clean" | grep -q "nothing changed"; then
  ok "after a build, why reports nothing changed"
else
  bad "after a build, why reports nothing changed" "said: $(echo "$why_clean" | head -2 | tr '\n' ' ')"
fi

# and the other direction: an edit must be NAMED, and named by path
mtime_before="$(stat -c %Y "$TMP/wy/helper.nim")"
cat > "$TMP/wy/helper.nim" <<'NIM'
proc greet*(): string = "two"
NIM
touch -d "@$mtime_before" "$TMP/wy/helper.nim"
why_dirty="$(NO_COLOR=1 "$NG" why "$TMP/wy/main.nim" 2>/dev/null)"
if echo "$why_dirty" | grep -q "helper.nim"; then
  ok "why names the module whose CONTENT moved under a preserved mtime"
else
  bad "why names the module whose content moved" "said: $(echo "$why_dirty" | head -2 | tr '\n' ' ')"
fi

# --- 7. a hit skips the compiler, and a miss does not ------------------------
# The readout is the point: without it a 100% miss rate looks exactly like a fast
# machine. Asserted on the reported compile time, which is the user-visible claim.
NO_COLOR=1 "$NG" nif "$TMP/wy/main.nim" >/dev/null 2>&1   # take the edit
hit_line="$(NO_COLOR=1 "$NG" nif "$TMP/wy/main.nim" -v 2>&1 | grep -c 'cache hit')"
if [ "$hit_line" = "1" ]; then
  ok "an unchanged rebuild reports a cache hit"
else
  bad "an unchanged rebuild reports a cache hit" "grep found $hit_line"
fi

cat > "$TMP/wy/helper.nim" <<'NIM'
proc greet*(): string = "three"
NIM
miss_out="$(NO_COLOR=1 "$NG" nif "$TMP/wy/main.nim" -v 2>&1)"
if echo "$miss_out" | grep -q 'cache miss · 1 of'; then
  ok "a changed input reports a miss, with the denominator"
else
  bad "a changed input reports a miss with the denominator" \
      "said: $(echo "$miss_out" | grep cache | head -1)"
fi

# --- 8. the closure is THIS program's, not the whole shared stage -------------
# The stage is shared by design, so "every .p.nif in the nc" is every module of
# every project that ever used this toolchain: measured, a hello-world's manifest
# carried 117 deps, nearly all of them other projects' deleted /tmp fixtures.
# Over-invalidation, unbounded growth, and one project's edit missing another's
# cache. p2/other.nim imports nothing of its own, so its manifest must be small —
# and must not mention p1, which shares its stage.
NO_COLOR=1 "$NG" nif "$TMP/p2/other.nim" >/dev/null 2>&1
p2_inputs="$(NO_COLOR=1 "$NG" nif "$TMP/p2/other.nim" -v 2>&1 | sed -n 's/.*of \([0-9]*\) inputs moved.*/\1/p' | tail -1)"
p1_named="$(NO_COLOR=1 "$NG" why "$TMP/p2/other.nim" 2>/dev/null | grep -c 'p1/' || true)"
if [ -n "$p2_inputs" ] && [ "$p2_inputs" -le 2 ] && [ "$p1_named" = "0" ]; then
  ok "a program's manifest covers its own modules only ($p2_inputs), not the shared stage"
else
  bad "a program's manifest covers its own modules only" \
      "inputs=$p2_inputs, lines naming the other project=$p1_named"
fi

echo ""
echo "$pass passed · $fail failed"
[ "$fail" = 0 ] || exit 1
