#!/bin/sh
# Build-graph generators (phase 1 and phase 2) vs cached oracle graphs.
# Exit 0 only if EVERY comparison passes. Each comparison's own exit status is
# checked; output is never piped before it.
cd "$(dirname "$0")" || exit 2
C=/c/Users/timbuktu/.aowl/cache
T=C:/Users/timbuktu/dev/toolchain
HELLO=C:/Users/timbuktu/AppData/Local/Temp/claude/C--Users-timbuktu/5106267e-329c-4b4e-972a-00170796f25f/scratchpad/hello/hello2.nim
TOOLM=C:/Users/timbuktu/dev/jester/tools/build_native_host.nim
rc=0

check() {  # name, script, then that script's args
  name="$1"; script="$2"; shift 2
  out=$(node "$script" "$@" 2>&1); st=$?
  echo "[$name] $(echo "$out" | grep -E '^oracle nodes' | head -1)"
  if [ $st -ne 0 ]; then
    echo "[$name] FAIL (exit $st)"; echo "$out" | grep -E 'MISSING|EXTRA|Error' | head -3 | cut -c1-200
    rc=1
  else
    echo "[$name] PASS"
  fi
}

# phase 1 (parse + sem)
check p1-hello-30  compare_graph.js $C/940be4c37b30/nc/helszagi51.build.nif "$HELLO" \
  "$T/aowlmony" "$T/nimony/lib" $C/940be4c37b30/nc windows
check p1-tool-84   compare_graph.js $C/6a681fbe71ed/nc/bui8a35sj1.build.nif "$TOOLM" \
  "C:/Users/timbuktu/dev/aoughwl-engine/src/interp" "$T/_uninstalled-nimony/nimony-aowl/lib" $C/6a681fbe71ed/nc windows \
  "$T/nimony-aowl/lib"

# phase 2 (lower, dce, emit, C compile, link)
check p2-hello-19  compare_final.js $C/940be4c37b30/nc/helszagi51.final.build.nif "$HELLO" \
  "$T/aowlmony" "$T/nimony/lib" $C/940be4c37b30/nc windows hello2.exe \
  "../../../dev/toolchain/nimony/vendor/mimalloc/src/static.c" "$T/nimony/vendor/mimalloc/include" "$T/nimony/nimcache_static/static.o"
check p2-tool-123  compare_final.js $C/6a681fbe71ed/nc/bui8a35sj1.final.build.nif "$TOOLM" \
  "C:/Users/timbuktu/dev/aoughwl-engine/src/interp" "$T/_uninstalled-nimony/nimony-aowl/lib" $C/6a681fbe71ed/nc windows build_native_host.exe \
  "../../../dev/toolchain/nimony-aowl/vendor/mimalloc/src/static.c" "$T/nimony-aowl/vendor/mimalloc/include" "$T/nimony-aowl/nimcache_static/static.o" \
  "$T/nimony-aowl" "$T/_uninstalled-nimony/nimony-aowl"

# parse-output -> import sidecar (our parser emits none, so the driver derives it)
out=$(node deps_extract.js "$C" 2>&1); st=$?
echo "[deps-sidecar] $(echo "$out" | tail -1)"
if [ $st -ne 0 ]; then echo "[deps-sidecar] FAIL (exit $st)"; rc=1; else echo "[deps-sidecar] PASS"; fi

# our parser vs the previous parser on cached library modules (trees, line info stripped)
out=$(node parser_sweep.js C:/Users/timbuktu/dev/toolchain/aifparser/bin/aowlparser.exe "$T/nimony/lib" 2>&1); st=$?
echo "[parser-sweep] $(echo "$out" | head -1)"
if [ $st -ne 0 ]; then echo "[parser-sweep] FAIL (exit $st)"; rc=1; else echo "[parser-sweep] PASS"; fi

# aowlsem's own outputs (.s.idx.nif byte-identical, .s.deps.nif ignoring offset/separators) vs the reference.
# Known divergence: the system module's checksum (generic-instance names are mangled differently).
out=$(SEM_KNOWN=sysvq0asl node sem_sweep.js C:/Users/timbuktu/dev/toolchain/aowlsem.ghfresh/bin/aowlsem.exe $C/940be4c37b30/nc "$T/nimony/lib" "$T/aowlmony" 2>&1); st=$?
echo "[aowlsem-sweep] $(echo "$out" | head -1)"
if [ $st -ne 0 ]; then echo "[aowlsem-sweep] FAIL (exit $st)"; echo "$out" | sed -n 2p; rc=1; else echo "[aowlsem-sweep] PASS"; fi

# first end-to-end program built and run on the aowl tools only
out=$(sh e2e_hello.sh 2>&1); st=$?
echo "[e2e-hello] $(echo "$out" | tail -1)"
if [ $st -ne 0 ]; then echo "[e2e-hello] FAIL (exit $st)"; rc=1; else echo "[e2e-hello] PASS"; fi

exit $rc
