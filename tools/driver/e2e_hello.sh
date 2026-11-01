#!/bin/sh
# End-to-end: compile hello-world with ONLY the aowl tools (aowlparser, aowlsem, aowlhexer,
# aowlc, gcc) through driver.js, run it, and require its exact output.
# KNOWN DEPENDENCY: the standard library and allocator sources are still read from the
# previous stack's directory until they are vendored (see docs/DRIVER.md).
# EXPECT overrides the expected output (used to prove this check can fail).
cd "$(dirname "$0")" || exit 2
WANT="${EXPECT:-hello from the aowl stack}"
W=$(mktemp -d)
printf 'import std/syncio\necho "hello from the aowl stack"\n' > "$W/hello.nim"
export PATH="/c/msys64/ucrt64/bin:$PATH"
node driver.js "$W/hello.nim" --cwd C:/Users/timbuktu/dev/toolchain/aowlmony \
  --lib C:/Users/timbuktu/dev/toolchain/nimony/lib --nc "$W/nc" >"$W/build.log" 2>&1 || { echo "build failed:"; tail -5 "$W/build.log"; exit 1; }
exe=$(ls "$W"/nc/*/hello.exe 2>/dev/null | head -1)
[ -x "$exe" ] || { echo "no executable produced"; exit 1; }
got=$("$exe"); st=$?
rm -rf "$W"
if [ "$st" = 0 ] && [ "$got" = "$WANT" ]; then echo "e2e hello: output matches"; exit 0; fi
echo "e2e hello: wrong result (exit $st, output '$got')"; exit 1
