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
helper_pnif=""
for f in "$stage"/nc/*.p.nif; do
  head -c 400 "$f" 2>/dev/null | grep -q "helper.nim" && helper_pnif="$f"
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

echo ""
echo "$pass passed · $fail failed"
[ "$fail" = 0 ] || exit 1
