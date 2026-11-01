#!/bin/sh
# Build one engine module with the aowl stack: probe_module.sh <module> [more modules...]
# Persistent cache so already-built dependencies are reused. Env: AOWL_SEM, PROBE_NC.
E=C:/Users/timbuktu/dev/aoughwl-engine/src
T=C:/Users/timbuktu/dev/toolchain
S=/c/Users/timbuktu/AppData/Local/Temp/claude/C--Users-timbuktu/5106267e-329c-4b4e-972a-00170796f25f/scratchpad
NC=${PROBE_NC:-$S/nc_probe_$(echo "$*" | tr " ," "__")}
W=$S/probe_main; mkdir -p "$W" "$NC"
export PATH="/c/msys64/ucrt64/bin:$PATH"
cd "$(dirname "$0")" || exit 2
imports=""; for m in "$@"; do imports="$imports, $m"; done
printf 'import std/syncio\nimport %s\necho "probe ok"\n' "${imports#, }" > "$W/probe.nim"
PATHS="$E/interp,$E/nif/lib,$E/nif/models,$E/nif/typed,$E/nif/gear2,$T/aowlabi/src,$T/aowlc/src"
node driver.js "$W/probe.nim" --cwd C:/Users/timbuktu/dev/toolchain/aowlmony --lib C:/Users/timbuktu/dev/toolchain/nimony/lib --path "$PATHS" --nc "$NC" 2>&1 | grep -v '^exit:'
