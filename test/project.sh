#!/usr/bin/env bash
# `mony.toml` and what having one buys you.
#
#   1. `new` scaffolds a project that builds
#   2. inside a project, `run` needs no argument — the manifest names the entry
#   3. a multi-module program builds, and EVERY user module goes through our
#      parser, not only the entry one
#   4. a path dep resolves and its modules are importable
#   5. an unresolvable dep (git / index) is reported, not silently ignored
#
# Case 3 is the one with teeth: the previous driver set a single path in
# NIFRW_USER even though the shim already read a list, so imported modules were
# parsed by nifler while `nif -v` still reported "parsed by nifparser (ours)".
# The provenance is checked here per MODULE, from the artifacts.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NG="${NG_BIN:-$ROOT/bin/aowlmony-ng}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -x "$NG" ] || { echo "no $NG — run ./build.sh first" >&2; exit 2; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }

cd "$TMP"

# --- 1. new ------------------------------------------------------------------
NO_COLOR=1 "$NG" new demo >/dev/null 2>&1
if [ -f "$TMP/demo/mony.toml" ] && [ -f "$TMP/demo/src/demo.nim" ]; then
  ok "new scaffolds mony.toml + src/"
else
  bad "new scaffolds mony.toml + src/" "$(ls -R "$TMP/demo" 2>&1 | head -5)"
fi

# --- 2. run with no argument -------------------------------------------------
cd "$TMP/demo"
out="$(NO_COLOR=1 "$NG" interp 2>/dev/null | tail -1)"
if [ "$out" = "hello from demo" ]; then
  ok "inside a project, the entry comes from the manifest"
else
  bad "inside a project, the entry comes from the manifest" "printed '$out'"
fi

# --- 3. multi-module, and OUR parser on every user module --------------------
cat > src/helper.nim <<'NIM'
proc greet*(who: string): string = "hi " & who
NIM
cat > src/demo.nim <<'NIM'
import std/syncio
import helper

echo greet("project")
NIM
out="$(NO_COLOR=1 "$NG" interp 2>/dev/null | tail -1)"
if [ "$out" = "hi project" ]; then
  ok "a multi-module project builds and runs"
else
  bad "a multi-module project builds and runs" "printed '$out'"
fi

# provenance, per module, read from the artifacts rather than from a summary line
stage="$(NO_COLOR=1 "$NG" why src/demo.nim 2>/dev/null | sed -n 's/^  stage //p' | tail -1)"
# ⚠️ Match THIS project's helper.nim by its own path, not by the bare module
# name. The stage is shared across projects by design, so a scan for "helper.nim"
# finds every helper.nim any fixture ever built — and taking the last match had
# this gate reporting on another test's file (which, being outside a project, is
# legitimately parsed by nifler). Same failure as findMain's "first .c.nif in the
# nc": in a shared cache, a name is not an identity.
# The path inside a .p.nif is written relative to the stage dir, so it ends in
# this project's absolute path with the leading slash gone.
here="$(pwd -P)"; needle="${here#/}/src/helper.nim"
helper_pnif=""
for f in "$stage"/nc/*.p.nif "$stage"/nc/*.p.aif; do
  [ -f "$f" ] || continue
  head -c 400 "$f" 2>/dev/null | tr -d '\n' | grep -qF "$needle" && helper_pnif="$f"
done
if [ -n "$helper_pnif" ]; then
  if head -c 200 "$helper_pnif" | grep -qE 'vendor "(aowl|aif|nif)parser"'; then
    ok "the IMPORTED module was parsed by our parser"
  else
    vendor="$(head -c 200 "$helper_pnif" | sed -n 's/.*vendor "\([^"]*\)".*/\1/p' | head -1)"
    bad "the IMPORTED module was parsed by our parser" "vendor is '$vendor'"
  fi
else
  bad "the imported module's .p.nif was found" "looked in $stage/nc"
fi

# --- 4. a path dep -----------------------------------------------------------
mkdir -p "$TMP/mylib/src"
cat > "$TMP/mylib/mony.toml" <<'TOML'
[package]
name    = "mylib"
version = "0.1.0"
TOML
cat > "$TMP/mylib/src/mylib.nim" <<'NIM'
proc answer*(): int = 42
NIM
cat > mony.toml <<'TOML'
[package]
name    = "demo"
version = "0.1.0"

[build]
entry   = "src/demo.nim"
target  = "native"

[deps]
mylib = { path = "../mylib" }
TOML
cat > src/demo.nim <<'NIM'
import std/syncio
import mylib

echo answer()
NIM
out="$(NO_COLOR=1 "$NG" interp 2>/dev/null | tail -1)"
if [ "$out" = "42" ]; then
  ok "a path dep resolves and is importable"
else
  bad "a path dep resolves and is importable" "printed '$out'"
fi

# --- 5. an unresolvable dep is reported --------------------------------------
cat >> mony.toml <<'TOML'
regex = { git = "https://github.com/x/regex", tag = "v2" }
TOML
msg="$(NO_COLOR=1 "$NG" interp 2>&1 | grep -c "regex" || true)"
if [ "${msg:-0}" -gt 0 ]; then
  ok "a git dep is reported as unresolvable, not silently dropped"
else
  bad "a git dep is reported as unresolvable, not silently dropped" \
      "nothing mentioned it; a manifest entry that does nothing is worse than an error"
fi

# --- 6. watch re-runs the command you ASKED for, and sees a change -----------
# It used to be hardcoded to `interp` whatever you typed, and to discard the
# exit code. Both directions are asserted: the requested action must appear, and
# an edit must produce a SECOND run with the NEW answer — a watcher that only
# ever runs once looks identical to a working one for the first second.
W="$TMP/watchproj"
mkdir -p "$W"
cat > "$W/w.nim" <<'NIM'
import std/syncio
echo "first"
NIM
# 120 s, not 25: every `nimony c` on this machine still queues behind a
# machine-wide lock, so a rebuild here can wait on an unrelated project's
# compile. The gate must fail on "watch did not react", never on "the box was
# busy" — see the nimcache_static work.
( cd "$W" && NO_COLOR=1 timeout 120 "$NG" watch "$W/w.nim" --as interp > "$W/out.log" 2>&1 ) &
watch_pid=$!
for _ in $(seq 1 120); do grep -q "first" "$W/out.log" 2>/dev/null && break; sleep 0.5; done
cat > "$W/w.nim" <<'NIM'
import std/syncio
echo "second"
NIM
for _ in $(seq 1 120); do grep -q "second" "$W/out.log" 2>/dev/null && break; sleep 0.5; done
kill "$watch_pid" 2>/dev/null; wait "$watch_pid" 2>/dev/null
if grep -q "first" "$W/out.log" && grep -q "second" "$W/out.log"; then
  ok "watch re-runs on a change and prints the new answer"
else
  bad "watch re-runs on a change and prints the new answer" \
      "log: $(tr '\n' '|' < "$W/out.log" | tail -c 200)"
fi
if grep -q "· interp" "$W/out.log"; then
  ok "watch honours --as (it used to be hardcoded to interp whatever you asked)"
else
  bad "watch honours --as" "no action banner in the log"
fi

echo ""
echo "$pass passed · $fail failed"
[ "$fail" = 0 ] || exit 1
