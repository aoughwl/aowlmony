#!/usr/bin/env bash
# test/claims.sh — do the NUMBERS in this repo's documentation still agree with
# whatever printed them?
#
# The other scripts here compare aowlmony against nimony. This one checks the
# PROSE, which had no gate. Three repos in this toolchain were caught in two days
# publishing a score no gate had ever printed — aowlsem's "498/498" on the docs
# site (an hconv census reworded into a module count; the real figure was 46/55),
# aowlc's "73/73" for a script printing 66/67, and its "77/77" for one printing
# 78/78. None was caught by a test, because no test read prose.
#
#   bash test/claims.sh          # cheap
#   bash test/claims.sh --all    # also the cross-repo gates a claim depends on
#   bash test/claims.sh --sweep  # numbers with no row in CLAIMS.tsv
#
# Worth knowing before you trust a number from this repo: NONE of the seven test
# entry points here has a declared denominator. test/test.js prints
# `${pass}/${pass+fail} passed`; the six shell scripts print
# `$pass passed · $fail failed`. Every total is derived, so a check that stops
# running shrinks the gate quietly rather than failing it — which is why a
# numerator from them cannot be pinned by this file, and why DESIGN.md's
# "Suite 24/25 → 25/25" is filed as the record of one change and not as the
# suite's state. A declared plan is the fix; until then, that is the honest scope.
#
# It reports and never rewrites. Exit 0 clean / 1 disagreement or unattributed /
# 2 could not be checked.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 tools/claimcheck.py --label aowlmony "$@"
