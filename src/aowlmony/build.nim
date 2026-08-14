## Running the front end.
##
## The whole pipeline is achieved by ONE subprocess — `nimony c` — plus PATH
## shims. nimony resolves `nifler`, `hexer` and `nimsem` through a findTool that
## checks the cwd first and then bare names on PATH, so staging executables with
## those names and running the compiler from the stage dir substitutes our
## implementations without the compiler knowing.
##
## The cwd matters for a second reason: a module's cache identity is a hash of
## its path relative to the compiler's CWD, so the stage dir must be stable or
## every build gets a fresh, empty cache.

import std/[syncio, strutils, envvars, os, monotimes]
import aowlkit/[subprocess, tty]
import tools, stage, project

type BuildResult* = object
  stage*: string
  nc*: string
  mainHash*: string
  snif*: string
  cnif*: string
  pnif*: string
  nbin*: string        ## the binary `nimony c` links for free, "" if absent
  byOurParser*: bool
  compileMs*: float
  output*: string      ## stdout+stderr of the compiler
  ok*: bool
  usedHexer*: bool
  usedSem*: bool
  lineShift*: int      ## lines the prelude wrapper added above the user's first
  userFile*: string    ## the file the user actually wrote, when a wrapper was used
  wrapFile*: string    ## the generated wrapper, "" when none was needed

proc shellQuoteJson(s: string): string =
  ## A bash double-quoted literal for embedding a path in a generated shim.
  result = "\""
  for c in s:
    if c == '"' or c == '\\' or c == '$' or c == '`': result.add '\\'
    result.add c
  result.add '"'

proc parserShim(t: Tools): string =
  ## nifler-compatible: OUR parser for the user modules named in $NIFRW_USER,
  ## the real nifler for the stdlib and for the --deps import sidecar (which our
  ## parser does not emit).
  "#!/usr/bin/env bash\n" &
  "REAL_NIFLER=" & shellQuoteJson(t.niflerReal) & "\n" &
  "NIFPARSER=" & shellQuoteJson(t.nifparser) & "\n" &
  """wants_deps=0; pos=(); infile=""; outfile=""
for a in "$@"; do
  case "$a" in
    --deps) wants_deps=1 ;;
    --portablePaths|-f|--forceRebuild|--deps*) ;;
    p|parse) pos+=("p") ;;
    *.nim) pos+=("$a"); infile="$a" ;;
    *.nif|*.aif) pos+=("$a"); outfile="$a" ;;
    *) pos+=("$a") ;;
  esac
done
real_in="$(readlink -f "$infile" 2>/dev/null)"
is_user=0
IFS=':' read -ra USERS <<< "${NIFRW_USER:-}"
for u in "${USERS[@]}"; do [ -n "$u" ] && [ "$(readlink -f "$u" 2>/dev/null)" = "$real_in" ] && is_user=1; done
if [ "$is_user" = 1 ]; then
  # real nifler writes the --deps import sidecar (our parser emits none)
  [ "$wants_deps" = 1 ] && "$REAL_NIFLER" "$@" >/dev/null 2>&1
  # our parser's [out] positional is a no-op, so emit to stdout and redirect;
  # that also overwrites nifler's sidecar .p.nif.
  if [ -n "$outfile" ]; then exec "$NIFPARSER" p "$infile" - > "$outfile"; else exec "$NIFPARSER" "${pos[@]}"; fi
else
  exec "$REAL_NIFLER" "$@"
fi
"""

proc semShim(t: Tools, libDir, srcLibDir, stageDir: string): string =
  ## nimsem-compatible. nimony calls:
  ##   nimsem --base:B --nimcache:NC m [--isSystem|--isMain] <p.nif>…
  ## aowlsem wants:
  ##   m <in.p.nif> <out.s.nif> [--base:] [--nimcache:] -p:LIB… [--noSystem]
  ##
  ## THREE CLI INCOMPATIBILITIES, all of which have to be closed here:
  ##
  ##  * `--base:` MEANS DIFFERENT THINGS. nimony passes the project/config base
  ##    dir; aowlsem uses it as the directory a module's RELATIVE line-info
  ##    source path resolves against — which is the cwd the compile was launched
  ##    from, i.e. our stage. Forwarding nimony's value makes system.nim's
  ##    `include`s resolve to the wrong place and produces a flood of bogus
  ##    `undeclared identifier \`string\`` / \`cint\`, which reads as aowlsem
  ##    being nowhere near ready when the argv is simply wrong.
  ##  * `--path:` is NOT OPTIONAL for aowlsem. nimsem derives the stdlib search
  ##    path from getAppDir() and is never passed one; aowlsem needs it to derive
  ##    the relative path nimony hashed each include fragment under. BOTH
  ##    `<toolroot>/lib` and `<toolroot>/src/lib` are required.
  ##  * argv SHAPE: aowlsem is positional (`m IN OUT`) and reads flags after it.
  ##
  ## Anything that is not a single-module `m` goes to the real nimsem verbatim:
  ## cyclic module GROUPS (>1 file in one call) are not handled by aowlsem yet.
  ## The real nimsem is also reused as the mechanical .s.nif → .s.idx.nif
  ## indexer — that subcommand walks the NIF and does no semantic analysis.
  "#!/usr/bin/env bash\n" &
  "AOWLSEM=" & shellQuoteJson(t.aowlsem) & "\n" &
  "NIMSEM=" & shellQuoteJson(t.nimsemReal) & "\n" &
  "LIB=" & shellQuoteJson(libDir) & "\n" &
  "SRCLIB=" & shellQuoteJson(srcLibDir) & "\n" &
  "STAGE=" & shellQuoteJson(stageDir) & "\n" &
  """mode=""; base=""; nc=""; issystem=0; seen_cmd=0; files=()
for a in "$@"; do
  if [ "$seen_cmd" = 0 ]; then
    case "$a" in
      --base:*) base="$a" ;;
      --nimcache:*) nc="$a" ;;
      m) mode=m; seen_cmd=1 ;;
      x) mode=x; seen_cmd=1 ;;
      e|idetools) mode=other; seen_cmd=1 ;;
    esac
  else
    case "$a" in
      --isSystem) issystem=1 ;;
      --isMain) : ;;
      *) files+=("$a") ;;
    esac
  fi
done
if [ "$mode" != "m" ] || [ "${#files[@]}" -ne 1 ]; then
  exec "$NIMSEM" "$@"
fi
in="${files[0]}"
out="${in%.p.nif}.s.nif"
sargs=(m "$in" "$out")
# nimony's --base is DROPPED on purpose (see the note above); aowlsem's --base
# is the directory relative line-info resolves against, which is our stage.
sargs+=("--base:$STAGE")
[ -n "$nc" ] && sargs+=("$nc")
sargs+=("-p:$LIB" "-p:$SRCLIB")
[ "$issystem" = 1 ] && sargs+=("--noSystem")
"$AOWLSEM" "${sargs[@]}" || exit $?
exec "$NIMSEM" x "$out"
"""

proc writeShim(path, body: string) =
  try:
    writeFile(path, body)
  except:
    return
  discard execShellCmd("chmod 755 " & quoteShell(path))

proc removeIfPresent(path: string) =
  if tools.fileExists(path):
    discard execShellCmd("rm -f " & quoteShell(path))

proc repoRootOf(nimony: string): string =
  ## <nimony repo>, from <repo>/bin/nimony
  var cuts = 0
  var i = nimony.len - 1
  var cut = -1
  while i >= 0:
    if nimony[i] == '/':
      inc cuts
      if cuts == 2:
        cut = i
        break
    dec i
  if cut <= 0: "" else: nimony[0 ..< cut]

proc libDirOf(nimony: string): string =
  ## <nimony repo>/lib, from <repo>/bin/nimony
  var cuts = 0
  var i = nimony.len - 1
  var cut = -1
  while i >= 0:
    if nimony[i] == '/':
      inc cuts
      if cuts == 2:
        cut = i
        break
    dec i
  if cut <= 0: "" else: nimony[0 ..< cut] & "/lib"

proc findMain(nc, stage, absEntry: string): tuple[hash: string, cnif: string] =
  ## The main module is the nc subdirectory holding <hash>.c.nif named after
  ## itself — everything entry-point-specific lives under that subdir, because
  ## DCE outcomes differ per entry point.
  ##
  ## ⚠️ It must be matched to THIS entry point by source path, not simply taken
  ## as the first one found. The stage is shared across projects now, so several
  ## main modules coexist in one nc; picking the first silently runs a different
  ## program, which is a wrong answer that looks like a successful build.
  let ls = runCaptured("ls", @[nc], "", false)
  if not ls.ok or ls.exitCode != 0: return ("", "")
  for line in splitLines(ls.output):
    let d = strip(line)
    if d.len == 0: continue
    let c = nc & "/" & d & "/" & d & ".c.nif"
    if not tools.fileExists(c): continue
    let src = sourceOfPnif(nc & "/" & d & ".p.nif")
    if src.len == 0: continue
    if absolutise(stage, src) == absEntry: return (d, c)
  ("", "")

proc build*(entry: string, t: Tools, verbose = false,
            proj = emptyProject(), depPaths: seq[string] = @[]): BuildResult =
  result = BuildResult(stage: "", nc: "", mainHash: "", snif: "", cnif: "",
                       pnif: "", nbin: "", byOurParser: false, compileMs: 0.0,
                       output: "", ok: false, usedHexer: false, usedSem: false,
                       lineShift: 0, userFile: "", wrapFile: "")
  var abs = entry
  try:
    abs = expandFilename(entry)
  except:
    return

  let st = stageDir(t)
  let nc = st & "/nc"
  discard execShellCmd("mkdir -p " & quoteShell(nc))
  result.stage = st
  result.nc = nc
  result.userFile = abs

  # A PRELUDE is a module implicitly imported into the entry — what makes a
  # `.aoughwl` file substrate source with no boilerplate. It is done by compiling
  # a wrapper whose first line is the import, which shifts every diagnostic by
  # one line; the reporter shifts them back. The wrapper lives in the stage (so
  # its module identity is stable) and the ORIGINAL directory goes on the search
  # path so the user's own relative imports still resolve.
  var compileTarget = abs
  var extraPaths: seq[string] = @[]
  if proj.prelude.len > 0:
    let wrapDir = st & "/wrap/" & sha1Hex(abs)[0 ..< 12]
    discard execShellCmd("mkdir -p " & quoteShell(wrapDir))
    var srcText = ""
    try:
      srcText = readFile(abs)
    except:
      srcText = ""
    var stemName = abs
    var sc = -1
    var si = 0
    while si < stemName.len:
      if stemName[si] == '/': sc = si
      inc si
    if sc >= 0: stemName = stemName[sc + 1 ..< stemName.len]
    var dot = -1
    si = 0
    while si < stemName.len:
      if stemName[si] == '.': dot = si
      inc si
    if dot > 0: stemName = stemName[0 ..< dot]
    let wrapFile = wrapDir & "/" & stemName & ".nim"
    try:
      # no leading newline: user line N is wrapper line N+1, exactly one shift
      writeFile(wrapFile, "import " & proj.prelude & "\n" & srcText)
    except:
      discard
    compileTarget = wrapFile
    result.wrapFile = wrapFile
    result.lineShift = 1
    var origDir = abs
    if sc >= 0: origDir = abs[0 ..< sc]
    extraPaths.add origDir
    let subs = substratePaths()   # bind first: a returned seq is not borrowable
    for sp in subs: extraPaths.add sp

  # Shims are rewritten every invocation, and a shim for a DESELECTED variant is
  # removed — a stale one lingering in a shared stage would silently keep using
  # the implementation the profile just switched away from.
  let useParser = t.parserVariant == "aowlparser" and t.nifparser.len > 0
  if useParser: writeShim(st & "/nifler", parserShim(t))
  else: removeIfPresent(st & "/nifler")

  let useHexer = t.hexerVariant == "aowlhexer" and t.hexer.len > 0 and
                 tools.fileExists(t.hexer) and getEnv("AOWLMONY_NO_AOWLHEXER", "").len == 0
  if useHexer:
    writeShim(st & "/hexer", "#!/usr/bin/env bash\nexec " &
      shellQuoteJson(t.hexer) & " \"$@\"\n")
  else: removeIfPresent(st & "/hexer")
  result.usedHexer = useHexer

  let useSem = t.semVariant == "aowlsem" and t.aowlsem.len > 0 and
               tools.fileExists(t.aowlsem) and getEnv("AOWLMONY_NO_AOWLSEM", "").len == 0
  if useSem:
    let root = repoRootOf(t.nimony)
    writeShim(st & "/nimsem", semShim(t, root & "/lib", root & "/src/lib", st))
  else: removeIfPresent(st & "/nimsem")
  result.usedSem = useSem

  # Content freshness over the whole user closure, not just the entry file.
  let lib = libDirOf(t.nimony)
  let closure = userClosure(nc, st, lib)
  let mpath = manifestPath(st, abs)
  let prev = readManifest(mpath)
  let cur = buildManifest(abs, closure, t)
  if prev.len > 0:
    for f in changedFiles(prev, cur):
      bumpMtime(f)
  elif tools.fileExists(abs):
    # first build for this entry: nothing to compare against, so make sure the
    # entry is not older than a cached artifact from another checkout.
    bumpMtime(abs)

  if verbose:
    var stemName = abs
    var s2 = -1
    var q = 0
    while q < stemName.len:
      if stemName[q] == '/': s2 = q
      inc q
    if s2 >= 0: stemName = stemName[s2 + 1 ..< stemName.len]
    stderr.writeLine "  " & dim(GDot) & " " & gray("nifparser parses " & stemName & "; " &
      (if useSem: "sem via aowlsem (ours)" else: "sem via nimony nimsem;") & " " &
      (if useHexer: "lowering via aowlhexer (ours)" else: "lowering via nimony hexer"))

  # Take the machine-wide lock: `nimony c` regenerates a shared static object
  # regardless of --nimcache:, so two compiles anywhere on the box race and the
  # loser dies with a link error that reads exactly like a real one.
  let nimlock = homeDir() & "/.aowl/bin/nimlock"

  # Every user module goes through OUR parser, not just the entry. The shim has
  # always read a colon-separated list here; the previous driver passed a single
  # path, so in a multi-file program the imported modules were parsed by nifler
  # while the provenance line still claimed our parser had run.
  var userList = compileTarget
  if compileTarget != abs: userList.add ":" & abs
  for f in userSources(proj):
    if f != abs and f != compileTarget: userList.add ":" & f

  var cmd = "cd " & quoteShell(st) & " && NIFRW_USER=" & quoteShell(userList) &
    " PATH=" & quoteShell(st) & ":$PATH "
  if tools.fileExists(nimlock): cmd.add quoteShell(nimlock) & " "
  cmd.add quoteShell(t.nimony) & " c --nimcache:" & quoteShell(nc)
  for sp in searchPaths(proj):
    cmd.add " --path:" & quoteShell(sp)
  for sp in extraPaths:
    cmd.add " --path:" & quoteShell(sp)
  for sp in depPaths:
    cmd.add " --path:" & quoteShell(sp)
  cmd.add " " & quoteShell(compileTarget)

  let t0 = getMonoTime()
  let r = captureShellMerged(cmd)
  result.compileMs = float(ticks(getMonoTime()) - ticks(t0)) / 1e6
  result.output = r.output

  let m = findMain(nc, st, compileTarget)
  result.mainHash = m.hash
  result.cnif = m.cnif

  # A build counts as failed when it emitted a diagnostic — NOT merely when no
  # .c.nif exists. A failed rebuild leaves the PREVIOUS build's .c.nif in the
  # cache, and nimony can exit 0 on failure, so "the artifact is there" is not
  # evidence that this run produced it.
  let hadError = r.exitCode != 0 or contains(r.output, "Error:") or
                 contains(r.output, "error[")
  if m.hash.len == 0 or hadError:
    result.ok = false
    return

  result.snif = nc & "/" & m.hash & ".s.nif"
  result.pnif = nc & "/" & m.hash & ".p.nif"
  var pn = ""
  try:
    pn = readFile(result.pnif)
  except:
    pn = ""
  result.byOurParser = contains(pn, "vendor \"aowlparser\"") or
                       contains(pn, "vendor \"aifparser\"") or
                       contains(pn, "vendor \"nifparser\"")

  # `nimony c` also links a binary next to the module's .c.nif, named after the
  # source stem. We already paid for that compile, and unlike our own native
  # backend today it handles stdout — so `verify` can use it as a native leg.
  var stem = compileTarget
  var slash = -1
  var i = 0
  while i < stem.len:
    if stem[i] == '/': slash = i
    inc i
  if slash >= 0: stem = stem[slash + 1 ..< stem.len]
  let dot = find(stem, '.')
  if dot > 0: stem = stem[0 ..< dot]
  let nbin = nc & "/" & m.hash & "/" & stem
  if tools.fileExists(nbin): result.nbin = nbin

  # Record the manifest only on SUCCESS. A poisoned build must not leave a key
  # claiming its inputs were satisfied.
  writeManifest(mpath, cur)
  result.ok = true
