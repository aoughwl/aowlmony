#!/usr/bin/env bash
# `[build] prelude` — the substrate front end, folded in as a project setting.
#
# A prelude is a module implicitly imported into the entry, which is what lets a
# `.aoughwl` file be substrate source with no boilerplate. It is implemented by
# compiling a generated wrapper, and the two things that go wrong with wrappers
# are exactly what is asserted here:
#
#   1. the program runs, with the prelude's vocabulary in scope
#   2. a diagnostic names the USER's file and the USER's line number — not the
#      generated wrapper, and not a line shifted by the injected import
#
# The standalone substrate driver got (2) wrong on its `run` path (only `check`
# shifted), so an error under `run` pointed at a temp file with every line off by
# one. Folding the prelude in means there is one implementation to get right.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NG="${NG_BIN:-$ROOT/bin/aowlmony-ng}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -x "$NG" ] || { echo "no $NG — run ./build.sh first" >&2; exit 2; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }

mkdir -p "$TMP/p/src"
cd "$TMP/p"
cat > mony.toml <<'TOML'
[package]
name    = "sub"
version = "0.1.0"

[build]
entry   = "src/sub.aoughwl"
prelude = "std/syncio"
TOML

# 1 ---------------------------------------------------------------- it runs
cat > src/sub.aoughwl <<'SRC'
echo "prelude gave us echo"
SRC
out="$(NO_COLOR=1 "$NG" interp 2>/dev/null | tail -1)"
if [ "$out" = "prelude gave us echo" ]; then
  ok "a prelude file runs with the injected import in scope"
else
  bad "a prelude file runs with the injected import in scope" "printed '$out'"
fi

# 2 ------------------------------------------------- the user's file and line
cat > src/sub.aoughwl <<'SRC'
echo "fine"
let x: int = "not an int"
SRC
err="$(NO_COLOR=1 "$NG" nif 2>&1)"
if echo "$err" | grep -q "src/sub.aoughwl:2:"; then
  ok "a diagnostic names the user's file at the user's line (2, not the wrapper's 3)"
else
  bad "a diagnostic names the user's file at the user's line" \
      "$(echo "$err" | grep -E '┌─|error' | head -2)"
fi
if echo "$err" | grep -q "wrap/"; then
  bad "the generated wrapper path never reaches the user" \
      "$(echo "$err" | grep 'wrap/' | head -1)"
else
  ok "the generated wrapper path never reaches the user"
fi

echo ""
echo "$pass passed · $fail failed"
[ "$fail" = 0 ] || exit 1
