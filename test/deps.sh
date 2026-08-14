#!/usr/bin/env bash
# Dependencies: the store, the lockfile, and reproducibility.
#
# The git dep here is a LOCAL repository. git treats a path as a valid remote, so
# the whole gate is hermetic — no network, and it still exercises the real code
# path (ls-remote → clone → checkout an exact rev → content-addressed store).
#
# What is asserted, and why:
#   1. a git dep resolves, lands in ~/.aowl/pkg/<key>, and is importable
#   2. the store path is derived from (url, rev) — the SAME revision resolves to
#      the SAME directory, because a module's cache identity is a hash of its
#      path and a dep that moves loses its incremental cache
#   3. mony.lock records the exact commit, not the tag that pointed at it
#   4. a second resolve reuses the lock and does NOT ask the remote again
#   5. a dep that cannot resolve is reported and fails the command
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NG="${NG_BIN:-$ROOT/bin/aowlmony-ng}"
TMP="$(mktemp -d)"
export AOWL_HOME="$TMP/aowlhome"
trap 'rm -rf "$TMP"' EXIT

[ -x "$NG" ] || { echo "no $NG — run ./build.sh first" >&2; exit 2; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }

# --- a local repo standing in for a remote ----------------------------------
mkdir -p "$TMP/remote/src"
cd "$TMP/remote"
cat > src/tinylib.nim <<'NIM'
proc tiny*(): int = 7
NIM
git init -q . && git add -A
git -c user.email=t@t -c user.name=t commit -qm "tinylib"
git tag v1
REV="$(git rev-parse HEAD)"

# --- a project that depends on it -------------------------------------------
mkdir -p "$TMP/app/src"
cd "$TMP/app"
cat > mony.toml <<TOML
[package]
name    = "app"
version = "0.1.0"

[build]
entry   = "src/app.nim"

[deps]
tinylib = { git = "$TMP/remote", tag = "v1" }
TOML
cat > src/app.nim <<'NIM'
import std/syncio
import tinylib

echo tiny()
NIM

# 1 -------------------------------------------------------------- it resolves
out="$(NO_COLOR=1 "$NG" fetch 2>&1)"
if echo "$out" | grep -q "tinylib"; then
  ok "fetch resolves a git dep"
else
  bad "fetch resolves a git dep" "$(echo "$out" | head -3)"
fi

run_out="$(NO_COLOR=1 "$NG" interp 2>/dev/null | tail -1)"
if [ "$run_out" = "7" ]; then
  ok "a git dep is importable and its code runs"
else
  bad "a git dep is importable and its code runs" "printed '$run_out'"
fi

# 2 -------------------------------------------- the store path is deterministic
store_dirs="$(ls "$AOWL_HOME/pkg" 2>/dev/null | wc -l)"
first="$(ls "$AOWL_HOME/pkg" 2>/dev/null | head -1)"
rm -f mony.lock
NO_COLOR=1 "$NG" fetch >/dev/null 2>&1
again="$(ls "$AOWL_HOME/pkg" 2>/dev/null | head -1)"
count="$(ls "$AOWL_HOME/pkg" 2>/dev/null | wc -l)"
if [ "$store_dirs" = "1" ] && [ "$first" = "$again" ] && [ "$count" = "1" ]; then
  ok "the same revision resolves to the same store directory"
else
  bad "the same revision resolves to the same store directory" \
      "before='$first' after='$again' count=$count"
fi

# 3 ------------------------------------------------ the lock pins a commit
if grep -q "$REV" mony.lock 2>/dev/null; then
  ok "mony.lock records the exact commit, not the tag"
else
  bad "mony.lock records the exact commit, not the tag" "$(cat mony.lock 2>&1 | tail -2)"
fi

# 4 ------------------------------------- a locked build does not need the remote
mv "$TMP/remote" "$TMP/remote-gone"
run_out="$(NO_COLOR=1 "$NG" interp 2>/dev/null | tail -1)"
mv "$TMP/remote-gone" "$TMP/remote"
if [ "$run_out" = "7" ]; then
  ok "a locked, already-fetched dep builds with the remote gone"
else
  bad "a locked, already-fetched dep builds with the remote gone" "printed '$run_out'"
fi

# 5 ------------------------------------------- an unresolvable dep is reported
cat >> mony.toml <<'TOML'
ghost = { git = "/nonexistent/repo", tag = "v9" }
TOML
out="$(NO_COLOR=1 "$NG" fetch 2>&1)"; rc=$?
if [ "$rc" != "0" ] && echo "$out" | grep -q "ghost"; then
  ok "an unresolvable dep is named and fails the command"
else
  bad "an unresolvable dep is named and fails the command" "rc=$rc"
fi

echo ""
echo "$pass passed · $fail failed"
[ "$fail" = 0 ] || exit 1
