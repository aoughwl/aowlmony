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

# 6 --------------------------------- the lock records CONTENT, not only a name
# A commit id says which content was ASKED for. The tree hash says which content
# was USED. They come apart exactly when it matters: an interrupted clone, a
# hand-edit in the shared store, a half-deleted entry.
sed -i '/^ghost /d' mony.toml 2>/dev/null || true
grep -v '^ghost ' mony.toml > "$TMP/mt" && mv "$TMP/mt" mony.toml
NO_COLOR=1 "$NG" fetch >/dev/null 2>&1
if grep -qE '^dep8? .* [0-9a-f]{7,}$' mony.lock || \
   awk '$2=="git" && $5 != "-" && length($5) > 6 {found=1} END{exit !found}' mony.lock; then
  ok "mony.lock records the content a git dep resolved to, not just its commit"
else
  bad "mony.lock records the content a git dep resolved to" "$(grep -v '^#' mony.lock | head -2)"
fi

# a PATH dep used to be written as `-`: the one dependency that can change under
# you between two builds was the one the lockfile said nothing about.
mkdir -p "$TMP/sibling/src"
cat > "$TMP/sibling/mony.toml" <<'TOML'
[package]
name = "sibling"
TOML
cat > "$TMP/sibling/src/sibling.nim" <<'NIM'
proc sib*(): int = 1
NIM
cat >> mony.toml <<TOML
sibling = { path = "$TMP/sibling" }
TOML
NO_COLOR=1 "$NG" fetch >/dev/null 2>&1
before="$(awk '$1=="sibling"{print $5}' mony.lock)"
cat > "$TMP/sibling/src/sibling.nim" <<'NIM'
proc sib*(): int = 2
NIM
NO_COLOR=1 "$NG" fetch >/dev/null 2>&1
after="$(awk '$1=="sibling"{print $5}' mony.lock)"
if [ -n "$before" ] && [ "$before" != "-" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
  ok "a path dep is fingerprinted, and editing it moves the fingerprint"
else
  bad "a path dep is fingerprinted and the fingerprint moves" "before='$before' after='$after'"
fi

# 7 ------------------------------------------------- --offline is a real flag
# It was a parameter nothing ever passed: the "not in mony.lock and offline"
# branch was unreachable code.
cat >> mony.toml <<'TOML'
unlocked = { git = "https://example.invalid/nope", tag = "v1" }
TOML
off="$(NO_COLOR=1 "$NG" fetch --offline 2>&1)"; rc=$?
if [ "$rc" != "0" ] && echo "$off" | grep -q "offline"; then
  ok "--offline refuses to ask a remote, and says that is why"
else
  bad "--offline refuses to ask a remote" "rc=$rc out=$(echo "$off" | tail -2 | tr '\n' '|')"
fi

# 8 ------------------------- a git dep's modules go through OUR parser as well
# `userSources` walks the project and its PATH deps; a git dep lives in the
# content store, so it was invisible there and its modules went to nifler while
# the provenance line said our parser had run. Exactly the defect that had
# already been fixed once for the project's own modules — a dependency is user
# code, only the stdlib is not.
NO_COLOR=1 "$NG" nif >/dev/null 2>&1
stage="$(NO_COLOR=1 "$NG" why 2>/dev/null | sed -n 's/^  stage //p' | tail -1)"
dep_pnif=""
for f in "$stage"/nc/*.p.nif "$stage"/nc/*.p.aif; do
  [ -f "$f" ] || continue
  head -c 400 "$f" 2>/dev/null | tr -d '\n' | grep -qF "/pkg/" && dep_pnif="$f"
done
if [ -n "$dep_pnif" ]; then
  if head -c 200 "$dep_pnif" | grep -qE 'vendor "(aowl|aif|nif)parser"'; then
    ok "a git dep's module was parsed by our parser"
  else
    bad "a git dep's module was parsed by our parser" \
        "vendor is '$(head -c 200 "$dep_pnif" | sed -n 's/.*vendor "\([^"]*\)".*/\1/p' | head -1)'"
  fi
else
  bad "the git dep's artifact was found in the stage" "looked in $stage/nc for a path under /pkg/"
fi

echo ""
echo "$pass passed · $fail failed"
[ "$fail" = 0 ] || exit 1
