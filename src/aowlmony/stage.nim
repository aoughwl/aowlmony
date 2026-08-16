## The build cache.
##
## Two jobs, deliberately separated:
##
## 1. WHERE artifacts live. The stage is keyed on the TOOLCHAIN — the active
##    profile, the three pass variants, and a stamp of every resolved binary —
##    and NOT on the source path. So two entry points, or two projects, share
##    one warm nimcache and pay for the stdlib once; and rebuilding aowlsem
##    lands in a different stage instead of silently reusing artifacts produced
##    by the previous one. The old key was sha1(source path ⊗ three variant
##    NAMES), which omitted the toolchain entirely.
##
## 2. WHETHER a source really changed. nifmake's staleness check is mtime-only,
##    and mtime MISSES changes: same-second edits, coarse filesystem
##    granularity, `cp -p`, `rsync --times`, and `git checkout` of an older
##    revision all leave changed bytes with an unchanged mtime. We keep a
##    content manifest over the whole user-module closure and bump the mtime of
##    anything whose hash moved, so the compiler's incremental cache is told the
##    truth. The previous driver did this for the ENTRY FILE ONLY.
##
## The manifest shape is aowltest's, deliberately: sorted lines, a versioned key
## prefix so the schema can be bumped, and a sentinel hash for a file that has
## gone away so its disappearance still moves the key.

import std/[syncio, strutils, envvars, os, sha1]
import aowlkit/subprocess
import tools

const
  KeySchema* = "aowlmony-key 1"
  MissingHash* = "0000000000000000000000000000000000000000"

proc sha1Hex*(data: string): string =
  var st = newSha1State()
  update(st, toOpenArray(data, 0, data.len - 1))
  let d = finalize(st)
  const hex = "0123456789abcdef"
  result = ""
  for b in d:
    result.add hex[int(b shr 4) and 0xF]
    result.add hex[int(b) and 0xF]

proc fileHash*(path: string): string =
  ## A vanished input must still move the key, so an unreadable file hashes to a
  ## sentinel rather than being skipped.
  var content = ""
  try:
    content = readFile(path)
  except:
    return MissingHash
  sha1Hex(content)

proc stampOf(path: string): string =
  ## size+mtime, not a content hash: these are multi-megabyte binaries and every
  ## real rebuild moves both. Cheap enough to do on every invocation, which is
  ## what makes it safe to put in the key.
  if path.len == 0: return "-"
  var size: int64 = -1
  var mtime: int64 = -1
  try:
    size = getFileSize(path)
  except:
    size = -1
  try:
    mtime = getLastModificationTime(path)
  except:
    mtime = -1
  $size & ":" & $mtime

proc toolStamp*(t: Tools): string =
  ## Everything that can change what the compiler emits.
  var lines: seq[string] = @[]
  lines.add "profile " & t.profile
  lines.add "variant parser " & t.parserVariant
  lines.add "variant hexer " & t.hexerVariant
  lines.add "variant sem " & t.semVariant
  lines.add "tool nimony " & t.nimony & " " & stampOf(t.nimony)
  lines.add "tool nifler " & t.niflerReal & " " & stampOf(t.niflerReal)
  lines.add "tool nimsem " & t.nimsemReal & " " & stampOf(t.nimsemReal)
  if t.parserVariant == "aowlparser":
    lines.add "tool parser " & t.nifparser & " " & stampOf(t.nifparser)
  if t.hexerVariant == "aowlhexer":
    lines.add "tool hexer " & t.hexer & " " & stampOf(t.hexer)
  if t.semVariant == "aowlsem":
    lines.add "tool sem " & t.aowlsem & " " & stampOf(t.aowlsem)
  joinLines(lines)

proc joinLines*(xs: seq[string]): string =
  result = ""
  for x in xs:
    result.add x
    result.add "\n"

proc aowlHome*(): string =
  let e = getEnv("AOWL_HOME", "")
  if e.len > 0: e else: homeDir() & "/.aowl"

proc stageKey*(t: Tools): string =
  sha1Hex(KeySchema & "\n" & toolStamp(t))[0 ..< 12]

proc stageDir*(t: Tools): string =
  ## ~/.aowl/cache/<toolchain key>. The manager creates that directory and
  ## nothing has used it until now; $TMPDIR is swept by the system and loses a
  ## warm stdlib on every reboot.
  aowlHome() & "/cache/" & stageKey(t)

# --------------------------------------------------------------------------
# the user-module closure
# --------------------------------------------------------------------------

proc sourceOfPnif*(pnif: string): string =
  ## nimony records each module's source path on line 4 of its .p.nif, as
  ##   (stmts@<col>,<line>,<path>
  ## with the path relative to the compiler's cwd (our stage dir). This is the
  ## COMPILER's own resolved answer, which is why the closure is read from here
  ## rather than re-deriving import resolution from the deps sidecars — those
  ## record module expressions (`std/syncio`), not files.
  var f: File
  if not open(f, pnif, fmRead): return ""
  var line = ""
  var n = 0
  var found = ""
  while n < 6 and readLine(f, line):
    inc n
    let i = find(line, "(stmts")
    if i < 0: continue
    let at = find(line, '@', i)
    if at < 0: break
    # line info is <col>,<line>,<file> — the path is everything after the 2nd comma
    var commas = 0
    var j = at
    while j < line.len:
      if line[j] == ',':
        inc commas
        if commas == 2:
          found = line[j + 1 ..< line.len]
          break
      inc j
    break
  close(f)
  strip(found)

proc absolutise*(base, p: string): string =
  if p.len == 0: return ""
  if p[0] == '/': return p
  # resolve ../.. against the stage dir without touching the filesystem
  var parts: seq[string] = @[]
  for seg in split(base & "/" & p, '/'):
    if seg.len == 0 or seg == ".": continue
    if seg == "..":
      if parts.len > 0: discard parts.pop()
    else:
      parts.add seg
  result = ""
  for seg in parts: result.add "/" & seg

proc endsWithPhase*(name, phase: string): bool =
  ## Does `name` end in this phase suffix, in EITHER spelling?
  ##
  ## `.aif` — aowl intermediate format — is the house name and the one we write;
  ## nimony still emits `.nif`. Both are the same bytes, so every reader here
  ## takes either and no caller has to know which produced the artifact.
  name.endsWith(phase & ".aif") or name.endsWith(phase & ".nif")

proc stripPhase*(name, phase: string): string =
  ## `<hash>.c.aif` / `<hash>.c.nif` -> `<hash>`; "" when it is neither.
  if not endsWithPhase(name, phase): return ""
  name[0 ..< name.len - (phase.len + 4)]

proc phaseFile*(nc, stem, phase: string): string =
  ## The artifact for this module and phase, whichever spelling is on disk.
  ## `.aif` wins when both exist — it is the format we own.
  let a = nc & "/" & stem & phase & ".aif"
  if tools.fileExists(a): return a
  let n = nc & "/" & stem & phase & ".nif"
  if tools.fileExists(n): return n
  ""

proc programClosure*(nc, stage, mainHash, libDir: string): seq[string] =
  ## The modules THIS program is made of, minus the toolchain's own library — a
  ## stdlib file only changes when the toolchain does, and that is already in
  ## the stage key.
  ##
  ## The source is `nc/<mainHash>/`, the subdirectory `nimony c` fills with one
  ## `.c.nif` per module actually linked into this entry point. That is the
  ## compiler's own answer to "what is this program made of", which is why it is
  ## read from here rather than re-derived: the `.p.deps.nif` sidecars record
  ## module EXPRESSIONS (`std/syncio`), not files, so using them would mean
  ## reimplementing import resolution.
  ##
  ## ⚠️ It must NOT be every `.p.nif` in the stage, which is what this proc used
  ## to do. The stage is shared across projects by design, so that set is every
  ## module of every project that ever used this toolchain: measured on this box,
  ## a hello-world's manifest carried 117 deps, nearly all of them other
  ## projects' long-deleted /tmp fixtures. Safe — it over-invalidates, never
  ## under — but it grows without bound and lets one project's edit miss
  ## another project's cache.
  result = @[]
  if mainHash.len == 0: return
  let ls = runCaptured("ls", @[nc & "/" & mainHash], "", false)
  if not ls.ok or ls.exitCode != 0: return
  for line in splitLines(ls.output):
    let name = strip(line)
    let modHash = stripPhase(name, ".c")
    if modHash.len == 0: continue
    let pnif = phaseFile(nc, modHash, ".p")
    if pnif.len == 0: continue
    let src = sourceOfPnif(pnif)
    if src.len == 0: continue
    let abs = absolutise(stage, src)
    if abs.len == 0: continue
    if libDir.len > 0 and abs.startsWith(libDir): continue
    var seen = false
    for x in result:
      if x == abs: seen = true
    if not seen: result.add abs

# --------------------------------------------------------------------------
# the manifest
# --------------------------------------------------------------------------

proc sortLines(xs: var seq[string]) =
  var i = 0
  while i < xs.len:
    var j = i + 1
    while j < xs.len:
      if xs[j] < xs[i]: swap(xs[i], xs[j])
      inc j
    inc i

proc buildManifest*(entry, mainHash: string, closure: seq[string], t: Tools): string =
  ## Sorted, so discovery order cannot change the key and two manifests can be
  ## diffed by a merge walk.
  ##
  ## The `main` line records which module in the stage IS this program, so a
  ## later run can find this entry's own artifacts without re-deriving the
  ## wrapper/prelude logic that produced the compile target.
  var lines: seq[string] = @[]
  lines.add "entry " & entry & " " & fileHash(entry)
  if mainHash.len > 0: lines.add "main " & mainHash
  for f in closure:
    if f == entry: continue
    lines.add "dep " & f & " " & fileHash(f)
  for l in splitLines(toolStamp(t)):
    if l.len > 0: lines.add "tool= " & l
  sortLines(lines)
  joinLines(lines)

proc libDirOf*(nimony: string): string =
  ## `<nimony repo>/lib`, from `<repo>/bin/nimony`. The stdlib is excluded from
  ## every manifest: a stdlib file only changes when the toolchain does, and the
  ## toolchain is already in the stage key.
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

proc mainHashOf*(manifest: string): string =
  ## Which module in the stage this entry's last successful build produced.
  result = ""
  for l in splitLines(manifest):
    if l.startsWith("main "): return strip(l[5 ..< l.len])

proc currentManifest*(t: Tools, entryAbs, mainHash: string): string =
  ## THE manifest for this entry under this toolchain — the one and only place
  ## the closure rule is spelled.
  ##
  ## ⚠️ It is a proc rather than three call sites because it once WAS three call
  ## sites: `build` passed `libDirOf(t.nimony)` while `why` and `watch` passed
  ## `""`, so `why` compared a manifest carrying the whole stdlib against a
  ## recorded one that by construction never could — and could therefore never
  ## report "nothing changed". A rule that decides what a build depends on gets
  ## written once.
  let st = stageDir(t)
  buildManifest(entryAbs, mainHash,
                programClosure(st & "/nc", st, mainHash, libDirOf(t.nimony)), t)

proc inputCount*(manifest: string): int =
  ## How many source inputs a manifest covers — the DENOMINATOR for the hit/miss
  ## readout. A cache that reports only its hits cannot be told from one that
  ## never looked.
  result = 0
  for l in splitLines(manifest):
    if l.startsWith("dep ") or l.startsWith("entry "): inc result

proc manifestPath*(stage, entry: string): string =
  ## One manifest per entry point, inside the shared stage.
  stage & "/manifests/" & sha1Hex(entry)[0 ..< 16] & ".manifest"

proc readManifest*(p: string): string =
  try:
    readFile(p)
  except:
    ""

proc dirOf(p: string): string =
  ## std/strutils has no rfind.
  var cut = -1
  var i = 0
  while i < p.len:
    if p[i] == '/': cut = i
    inc i
  if cut <= 0: "." else: p[0 ..< cut]

proc writeManifest*(p, content: string) =
  let dir = dirOf(p)
  discard execShellCmd("mkdir -p " & quoteShell(dir))
  try:
    writeFile(p, content)
  except:
    discard

proc changedFiles*(oldManifest, newManifest: string): seq[string] =
  ## The files whose hash moved. Both manifests are sorted, so this is a merge
  ## walk rather than an n^2 comparison.
  result = @[]
  var oldLines: seq[string] = @[]
  for l in splitLines(oldManifest):
    if l.startsWith("dep ") or l.startsWith("entry "): oldLines.add l
  for l in splitLines(newManifest):
    if not (l.startsWith("dep ") or l.startsWith("entry ")): continue
    var hit = false
    for o in oldLines:
      if o == l: hit = true
    if hit: continue
    # the line differs: recover the path (2nd field)
    let parts = split(l, ' ')
    if parts.len >= 2: result.add parts[1]

proc bumpMtime*(path: string) =
  ## Tell the compiler's mtime-only staleness check the truth about a file whose
  ## CONTENT moved. Touching is enough: nifmake rebuilds a node when an input is
  ## strictly newer than its outputs.
  discard execShellCmd("touch " & quoteShell(path))

proc explainLines*(oldManifest, newManifest: string): seq[string] =
  ## What `aowlmony why` prints: the manifest lines that differ, in both
  ## directions, so a REMOVED input is as visible as a changed one.
  result = @[]
  for l in splitLines(newManifest):
    if l.len == 0: continue
    var hit = false
    for o in splitLines(oldManifest):
      if o == l: hit = true
    if not hit: result.add "+ " & l
  for o in splitLines(oldManifest):
    if o.len == 0: continue
    var hit = false
    for l in splitLines(newManifest):
      if o == l: hit = true
    if not hit: result.add "- " & o
