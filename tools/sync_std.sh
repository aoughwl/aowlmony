#!/bin/sh
# sync_std.sh - keep rt/lib/std (the vendored standard library) in step with the
# source of truth, github.com/aoughwl/std (one folder per module; tools/flatten_core.sh there rebuilds the std/ tree).
#
#   tools/sync_std.sh [--check] [<std-checkout>]
#
# default: flatten <std> and copy the result over rt/lib/std/ (files only in rt/lib/std are
#          removed so the result equals the source tree).
# --check: change nothing; list files that differ (CR/LF differences ignored)
#          and exit 1 if there are any, 0 if the trees match.
# <std-checkout>: path of the aoughwl/std checkout; default $AOWL_STD, then
#          ../std next to this repo.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
CHECK=0
STD=""
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) STD=$a ;;
  esac
done
[ -n "$STD" ] || STD=${AOWL_STD:-$HERE/../std}
DST=$HERE/rt/lib/std
[ -f "$STD/tools/flatten_core.sh" ] || { echo "sync_std: $STD/tools/flatten_core.sh not found (set AOWL_STD or pass the std checkout)" >&2; exit 2; }
[ -d "$DST" ] || { echo "sync_std: $DST not found" >&2; exit 2; }

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
sh "$STD/tools/flatten_core.sh" "$TMP/flat" >&2 || { echo "sync_std: flatten failed" >&2; exit 2; }
SRC=$TMP/flat/std
(cd "$SRC" && find . -type f | sort) >"$TMP/a"
(cd "$DST" && find . -type f | sort) >"$TMP/b"

# differing / missing files, relative paths
: >"$TMP/diff"
while IFS= read -r f; do
  if [ ! -f "$DST/$f" ]; then echo "only in std: $f" >>"$TMP/diff"
  elif ! diff -q --strip-trailing-cr "$SRC/$f" "$DST/$f" >/dev/null 2>&1; then echo "differs: $f" >>"$TMP/diff"
  fi
done <"$TMP/a"
while IFS= read -r f; do
  [ -f "$SRC/$f" ] || echo "only in rt/lib/std: $f" >>"$TMP/diff"
done <"$TMP/b"

n=$(wc -l <"$TMP/diff" | tr -d ' ')
if [ "$CHECK" = 1 ]; then
  if [ "$n" -eq 0 ]; then echo "sync_std: rt/lib/std matches $SRC (0 differences)"; exit 0; fi
  cat "$TMP/diff"; echo "sync_std: $n file(s) differ"; exit 1
fi

if [ "$n" -eq 0 ]; then echo "sync_std: already in sync"; exit 0; fi
while IFS= read -r l; do
  case "$l" in
    "only in rt/lib/std: "*) rm -f "$DST/${l#only in rt/lib/std: }" ;;
    *) f=${l#*: }; mkdir -p "$DST/$(dirname "$f")"; cp "$SRC/$f" "$DST/$f" ;;
  esac
done <"$TMP/diff"
echo "sync_std: updated $n file(s) from $SRC"
