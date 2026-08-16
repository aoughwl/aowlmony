## aowlmony — the driver over the self-owned aowl stack.
##
## Give it a `.nim` file and it runs parser → sem → lowering → your choice of
## native code, an interpreter, or idiomatic source, using aoughwl's own
## components wherever they exist and reusing nimony's for the parts not yet
## rebuilt.
##
## Two tools, modelled on `rustup` : `cargo` — **aowlup** manages the toolchain
## and writes the registry; **aowlmony** compiles code and only ever reads it.

import std/[syncio, strutils, envvars, cmdline, os, monotimes, json]
import aowlkit/[subprocess, tty]
import aowlmony/[tools, stage, build, diag, project, pkg, verify, memory]

const Prog = "aowlmony"

# `verify` gives exit 1 a specific meaning — the backends disagree — so a
# front-end compile failure must not land on it.
var compileFailCode = 1

proc fail(msg: string, code = 0) =
  ## The glyph does NOT degrade to ASCII here: the driver's errors are read in a
  ## terminal next to the compiler's own diagnostics, and a mixed vocabulary of
  ## markers is worse than a missing font.
  stderr.writeLine "  " & red(GCross) & " " & red(msg)
  quit(if code != 0: code else: 1)

proc note(verbose: bool, msg: string) =
  if verbose: stderr.writeLine "  " & dim(GDot) & " " & gray(msg)

proc fmtDur(ms: float): string =
  if ms < 1000.0:
    $int(ms + 0.5) & "ms"
  else:
    let tenths = int(ms / 100.0 + 0.5)
    $(tenths div 10) & "." & $(tenths mod 10) & "s"

proc timingLine(label: string, compileMs: float, runMs: float, show: bool) =
  ## A concise dim one-liner on STDERR, so it never pollutes captured output.
  if not show: return
  var seg: seq[string] = @[]
  if compileMs >= 0.0: seg.add "compiled " & fmtDur(compileMs)
  if runMs >= 0.0: seg.add "ran " & fmtDur(runMs)
  if seg.len == 0: return
  stderr.writeLine "  " & green(GOk) & " " & dim(label & " · " & joinStr(seg, " · "))

# --------------------------------------------------------------------------
# options
# --------------------------------------------------------------------------

type Opts = object
  rest: seq[string]      ## positional
  args: seq[string]      ## --arg values
  aowli: seq[string]     ## flags forwarded to the interpreter
  progArgs: seq[string]  ## after `--`
  outFile: string
  entry: string
  evalCode: string
  hasEval: bool
  faithful: bool
  run: bool
  watchAs: string        ## `watch --as <command>`; what a change re-runs
  memory: bool
  timeout: int
  native: string
  showTime: bool
  verbose: bool

proc isAowliFlag(a: string): bool =
  ## The tracing family and the hybrid-native family, forwarded verbatim.
  a == "--trace" or a == "--trace-full" or a == "--trace-profile" or
  a.startsWith("--trace-depth:") or a == "--hybrid" or a == "--build-native" or
  a.startsWith("--interpret:") or a.startsWith("--native-src:") or
  a.startsWith("--native-lib:")

proc parseOpts(argv: seq[string]): Opts =
  result = Opts(rest: @[], args: @[], aowli: @[], progArgs: @[], outFile: "",
                entry: "", evalCode: "", hasEval: false, faithful: false,
                run: false, watchAs: "", memory: false, timeout: 0, native: "",
                showTime: true, verbose: false)
  var i = 0
  while i < argv.len:
    let a = argv[i]
    if a == "--":
      var k = i + 1
      while k < argv.len:
        result.progArgs.add argv[k]
        inc k
      break
    elif a == "-o" or a == "--out":
      inc i
      if i < argv.len: result.outFile = argv[i]
    elif a == "--entry":
      inc i
      if i < argv.len: result.entry = argv[i]
    elif a == "-e":
      inc i
      if i < argv.len:
        result.evalCode = argv[i]
        result.hasEval = true
    elif a == "--arg":
      inc i
      if i < argv.len: result.args.add argv[i]
    elif a == "--memory": result.memory = true
    elif a.startsWith("--timeout:"):
      try:
        result.timeout = parseInt(a[10 ..< a.len])
      except:
        result.timeout = 0
    elif a == "--timeout":
      inc i
      if i < argv.len:
        try:
          result.timeout = parseInt(argv[i])
        except:
          result.timeout = 0
    elif a.startsWith("--native:"): result.native = a[9 ..< a.len]
    elif a == "--native":
      inc i
      if i < argv.len: result.native = argv[i]
    elif a == "--faithful": result.faithful = true
    elif a == "--run": result.run = true
    elif a.startsWith("--as:"): result.watchAs = a[5 ..< a.len]
    elif a == "--as":
      inc i
      if i < argv.len: result.watchAs = argv[i]
    elif a == "--no-cache":
      # One mechanism, not two: the build reads the env var, so the flag sets it
      # rather than threading a second switch down to the same decision.
      try:
        putEnv("AOWLMONY_NO_CACHE", "1")
      except:
        discard
    elif a == "--keep":
      # RETIRED, and said out loud rather than ignored. It used to select a
      # `.aowlmony/` stage next to the source; the stage is keyed on the
      # toolchain and shared now, so there is nothing for it to choose. A flag
      # that is silently accepted and does nothing is worse than one that is
      # gone: the user believes it took effect.
      stderr.writeLine "  " & amber(GWarn) & " " &
        gray("--keep is retired: the stage is keyed on the toolchain and shared " &
             "(see `why` for what it holds)")
    elif a == "--time": result.showTime = true
    elif a == "--no-time": result.showTime = false
    elif a == "-v" or a == "--verbose": result.verbose = true
    elif isAowliFlag(a): result.aowli.add a
    else: result.rest.add a
    inc i

# --------------------------------------------------------------------------
# help
# --------------------------------------------------------------------------

proc cmdHelp(t: Tools) =
  stdout.write "\n  " & teal(GDiamond) & " " & bold(teal("aowlmony")) & "  " &
    dim(GBar) & "  " & gray("nimony driver over the self-owned aowl stack") & "\n\n"
  let rows = @[
    @["run FILE", "native: compile → binary → run"],
    @["build FILE [-o BIN]", "native: emit a binary"],
    @["exec FILE --entry N", "native: call one proc, print result"],
    @["interp FILE", "interpret via aowli (tree-walk)"],
    @["eval FILE | -e CODE", "run via aowli; -e runs inline code, - reads stdin"],
    @["vm FILE", "interpret via aowli bytecode VM"],
    @["ts|js FILE [--faithful]", "emit idiomatic TypeScript / JavaScript"],
    @["py FILE", "emit idiomatic Python"],
    @["verify FILE", "run native + interpreted, report the first divergent op"],
    @["verify FILE --memory", "trap dangling pointers under --fin: allocation site + use site"],
    @["parse FILE", "show OUR .p.nif"],
    @["nif FILE", "compile only; print .s/.c.nif paths"],
    @["why FILE", "say which input changed, and what it forced to rebuild"],
    @["new NAME | init", "start a project (mony.toml + src/)"],
    @["fetch", "resolve deps into the store and write mony.lock"],
    @["test [ARGS]", "run the project's tests via aowltest"],
    @["watch FILE [--as CMD]", "re-run CMD (default run) whenever an input changes"],
    @["clean [--all]", "drop build manifests (--all: the artifacts too)"],
    @["fix FILE [--dry-run]", "apply aowlsuggest quick-fixes (cross-language habits)"],
    @["lint FILE", "aowlsuggest diagnostics only (no compile)"],
  ]
  for r in rows:
    var pad = 26 - r[0].len
    if pad < 1: pad = 1
    stdout.writeLine "  " & teal(r[0]) & repeat(' ', pad) & gray(r[1])
  stdout.writeLine ""
  stdout.writeLine "  " & gray("profile ") & GArrow & " " & bold(violet(t.profile)) &
    dim("  parser=") & cyan(t.parserVariant) & dim(" hexer=") & cyan(t.hexerVariant) &
    dim(" sem=") & cyan(t.semVariant) & dim("   one-shot: ") &
    teal("aowlmony +nimony run <file>")
  stdout.writeLine "  " & gray("options ") & GArrow & " " &
    dim("-o  --entry  --arg  --faithful  --run  --no-cache  --no-time  --timeout:N  -v")
  stdout.writeLine "  " & gray("aowli   ") & GArrow & " " &
    dim("interp/vm/eval forward --trace[-full|-profile] --trace-depth:N, the hybrid ") &
    dim("family (--hybrid --build-native --interpret: --native-src: --native-lib:), and ") &
    teal("-- ARG…") & dim(" to the program")
  stdout.writeLine "  " & gray("toolchain ") & GArrow & " " & teal("aowlup") &
    dim("   — aowlup manages the stack (profiles/versions/setup), aowlmony compiles (rustup : cargo)")
  stdout.writeLine ""

# --------------------------------------------------------------------------
# running children
# --------------------------------------------------------------------------

proc runInherit(cmd: string, args: seq[string]): int =
  var line = quoteShell(cmd)
  for a in args: line.add " " & quoteShell(a)
  execShellCmd(line)

proc outPath(nimFile, outOpt, ext: string): string =
  ## -o if given, else beside the .nim source.
  if outOpt.len > 0:
    try:
      return expandFilename(outOpt)
    except:
      return outOpt
  var abs = nimFile
  try:
    abs = expandFilename(nimFile)
  except:
    discard
  var cut = -1
  var i = 0
  while i < abs.len:
    if abs[i] == '/': cut = i
    inc i
  let dir = if cut >= 0: abs[0 ..< cut] else: "."
  var stem = if cut >= 0: abs[cut + 1 ..< abs.len] else: abs
  var dot = -1
  i = 0
  while i < stem.len:
    if stem[i] == '.': dot = i
    inc i
  if dot > 0: stem = stem[0 ..< dot]
  dir & "/" & stem & "." & ext

proc tildeAbbrev(p: string): string =
  let h = homeDir()
  if h.len > 0 and p.startsWith(h): "~" & p[h.len ..< p.len] else: p

proc baseNameOf(p: string): string =
  var cut = -1
  var i = 0
  while i < p.len:
    if p[i] == '/': cut = i
    inc i
  if cut >= 0: p[cut + 1 ..< p.len] else: p

proc aowliArgs(snif, absSrc: string, o: Opts, vmOnly: bool): seq[string] =
  var pass: seq[string] = @[]
  if vmOnly:
    for a in o.aowli:
      if a == "--trace" or a == "--trace-full": pass.add a
  else:
    pass = o.aowli
    var hybrid = false
    var buildNative = false
    var hasSrc = false
    for a in pass:
      if a == "--hybrid": hybrid = true
      elif a == "--build-native": buildNative = true
      elif a.startsWith("--native-src:"): hasSrc = true
    if hybrid and buildNative and not hasSrc:
      pass.add "--native-src:" & absSrc
  result = pass
  result.add snif
  if o.progArgs.len > 0:
    result.add "--"
    for a in o.progArgs: result.add a

# --------------------------------------------------------------------------
# reporting a compile failure
# --------------------------------------------------------------------------

proc isNoise(s, stageDir: string): bool =
  ## nifmake's driver chatter means nothing to someone who wrote a typo.
  if s.startsWith("FAILURE:") or strip(s).startsWith("FAILURE:"): return true
  if contains(s, "nifmake") or contains(s, ".build.nif") or
     contains(s, ".deps.nif"): return true
  if stageDir.len > 0 and contains(s, stageDir): return true
  let t = strip(s)
  if t.startsWith("✗") or t.startsWith("×"): return true
  false

proc splitPath(p: string): seq[string] =
  result = @[]
  for seg in split(p, '/'):
    if seg.len > 0 and seg != ".": result.add seg

proc relativeTo(base, target: string): string =
  ## How the COMPILER spells the source: relative to its cwd, which is the stage
  ## dir. Diagnostics arrive with that spelling, and it must be rewritten back to
  ## the path the user typed or every error points at a directory they have never
  ## heard of.
  let b = splitPath(base)
  let t = splitPath(target)
  var i = 0
  while i < b.len and i < t.len and b[i] == t[i]: inc i
  var parts: seq[string] = @[]
  var k = i
  while k < b.len:
    parts.add ".."
    inc k
  k = i
  while k < t.len:
    parts.add t[k]
    inc k
  joinStr(parts, "/")

proc replaceAll(s, sub, by: string): string =
  if sub.len == 0: return s
  result = ""
  var i = 0
  while i < s.len:
    if i + sub.len <= s.len and s[i ..< i + sub.len] == sub:
      result.add by
      i = i + sub.len
    else:
      result.add s[i]
      inc i

type Sug = object
  line: int
  col: int
  code: string
  message: string
  fix: string

proc absorbSug(node: JsonNode, found: var seq[Sug], anyFixable: var bool) =
  ## Module level, not nested: capturing `found`/`anyFixable` from an inner proc
  ## needs an explicit `.closure` in nimony, and var params say the same thing
  ## more plainly.
  var s = Sug(line: 0, col: 0, code: "", message: "", fix: "")
  for k, v in pairs(node):
    case k
    of "line": s.line = int(getInt(v, 0))
    of "col": s.col = int(getInt(v, 0))
    of "code": s.code = getStr(v, "")
    of "message": s.message = getStr(v, "")
    of "fix": s.fix = getStr(v, "")
    of "autofixable":
      if getBool(v, false): anyFixable = true
    else: discard
  if s.fix.len > 0: anyFixable = true
  found.add s

proc suggestFixHints(nimFile, abs: string, t: Tools, shown: seq[string]) =
  ## Many cryptic sem errors are a habit from another language. Ask aowlsuggest
  ## whether it recognises one, and print the command that applies the fix.
  ## Best effort: silent when the tool is absent or has nothing to say, and it
  ## never displaces the primary error.
  if t.aowlsuggest.len == 0 or not tools.fileExists(t.aowlsuggest): return
  let r = runCaptured(t.aowlsuggest, @["check", abs, "--format:json"], "", false)
  if not r.ok or strip(r.output).len == 0: return
  var tree: JsonTree
  try:
    tree = parseJson(r.output)
  except:
    return
  if hasError(tree): return

  var found: seq[Sug] = @[]
  var anyFixable = false

  let rt = root(tree)
  case kind(rt)
  of JArray:
    for item in items(rt): absorbSug(item, found, anyFixable)
  else:
    for k, v in pairs(rt):
      if k == "files":
        for f in items(v):
          for fk, fv in pairs(f):
            if fk == "diagnostics":
              for d in items(fv): absorbSug(d, found, anyFixable)

  var fresh: seq[Sug] = @[]
  for s in found:
    var dup = false
    for key in shown:
      if key == s.code & "@" & $s.line: dup = true
    if not dup: fresh.add s
  if fresh.len > 0:
    stderr.writeLine ""
    stderr.writeLine "  " & cyan("aowlsuggest") &
      gray(" recognizes this — likely a cross-language habit:")
    var n = 0
    for s in fresh:
      if n >= 6: break
      var at = ""
      if s.line > 0:
        at = ":" & $s.line
        if s.col > 0: at.add ":" & $s.col
      var tip = ""
      if s.fix.len > 0: tip = gray("  → " & s.fix)
      let body = if s.message.len > 0: s.message else: s.code
      stderr.writeLine "    " & amber("•") & " " & gray(nimFile & at) & "  " & body & tip
      inc n
    if fresh.len > 6:
      stderr.writeLine "    " & gray("… " & $(fresh.len - 6) & " more (aowlsuggest lint " &
        nimFile & ")")
  if anyFixable:
    stderr.writeLine "  " & gray("apply the auto-fixes: ") & cyan("aowlmony fix " & nimFile)

proc reportFailure(b: BuildResult, nimFile, abs: string, t: Tools, verbose: bool) =
  ## Show the COMPILER's diagnostics, with the staged `../../…` spelling rewritten
  ## back to the path the user actually typed, and the build-driver noise dropped.
  var lines: seq[string] = @[]
  for raw in splitLines(b.output):
    var s = raw
    while s.len > 0 and (s[s.len - 1] == ' ' or s[s.len - 1] == '\t'):
      s = s[0 ..< s.len - 1]
    if strip(s).len == 0: continue
    if isNoise(s, b.stage): continue
    # the staged spelling first, then the absolute one
    let staged = relativeTo(b.stage, abs)
    if staged.len > 0: s = replaceAll(s, staged, nimFile)
    if b.wrapFile.len > 0:
      # the compiler saw the WRAPPER, which lives in the stage. Rewrite both its
      # absolute and its stage-relative spelling, or every diagnostic points at a
      # generated file the user never wrote.
      s = replaceAll(s, b.wrapFile, nimFile)
      let wrapRel = relativeTo(b.stage, b.wrapFile)
      if wrapRel.len > 0: s = replaceAll(s, wrapRel, nimFile)
    lines.add replaceAll(s, abs, nimFile)

  var diags = parseDiagnostics(lines)
  if b.lineShift != 0:
    # a prelude wrapper added lines above the user's first one; report the
    # numbers they can act on, not the ones the compiler saw
    var i = 0
    while i < diags.len:
      diags[i].line = diags[i].line - b.lineShift
      if diags[i].line < 1: diags[i].line = 1
      inc i
  var shown: seq[string] = @[]
  if diags.len > 0:
    var first = true
    for d in diags:
      if not first: stderr.writeLine ""
      first = false
      renderDiag(d, abs, nimFile)
      shown.add d.code & "@" & $d.line
  else:
    var errs: seq[string] = @[]
    for s in lines:
      if contains(s, "Error:"): errs.add s
    let show = if errs.len > 0: errs else: lines
    for s in show: stderr.writeLine "  " & red(s)
  if verbose and b.output.len > 0:
    stderr.writeLine gray("  [verbose] raw driver output:")
    stderr.write b.output
  suggestFixHints(nimFile, abs, t, shown)


# --------------------------------------------------------------------------
# verify's two footers
# --------------------------------------------------------------------------

proc provenance(which, bin, interpPath: string, byOurParser, usedHexer: bool) =
  ## Which binaries produced this verdict. A verdict without its provenance is
  ## unfalsifiable a week later.
  stderr.writeLine "    " & dim("native " &
    (if which == "aowlc": "aowlc→gcc" else: "nimony's C backend") & " " & dayOf(bin) &
    " · interpreted " & baseNameOf(interpPath) & " " & dayOf(interpPath) &
    " · front end " & (if byOurParser: "aowlparser" else: "nifler") & "→sem→" &
    (if usedHexer: "aowlhexer" else: "hexer"))

proc warnStale(stale: Newer, interpPath: string) =
  ## Before blaming a backend, check the engine we ran is the newest one built.
  if not stale.found: return
  stderr.writeLine ""
  stderr.writeLine "  " & amber("!") & " " &
    bold(amber("this may not be a backend defect — the interpreter is not the newest build"))
  stderr.writeLine "  " & gray("ran    ") & cyan(tildeAbbrev(interpPath))
  stderr.writeLine "  " & gray("newer  ") & cyan(tildeAbbrev(stale.path))
  stderr.writeLine "  " & gray("re-run with ") &
    teal("AOWLMONY_NIFI=" & tildeAbbrev(stale.path)) &
    gray(" before reporting this as an aowli bug")

# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

proc main() =
  let argv = commandLineParams()
  var args: seq[string] = @[]
  var i = 0
  while i < argv.len:
    let a = argv[i]
    if i == 0 and a.len > 1 and a[0] == '+':
      # rustup-style one-shot profile; flows to `aowlup config` via the env.
      try:
        putEnv("AOWL_PROFILE", a[1 ..< a.len])
      except:
        fail("could not set the ephemeral profile from '" & a & "'")
    else:
      args.add a
    inc i

  let cmd = if args.len > 0: args[0] else: ""
  var tail: seq[string] = @[]
  var k = 1
  while k < args.len:
    tail.add args[k]
    inc k
  let o = parseOpts(tail)
  let t = resolveTools()
  let proj = findProject(getEnv("PWD", "."))

  if cmd.len == 0 or cmd == "-h" or cmd == "--help" or cmd == "help":
    cmdHelp(t)
    return

  # Resolve dependencies before anything is compiled, record what was resolved,
  # and say plainly what could not be. A manifest entry that silently does
  # nothing is worse than an error: the build fails later with an import error
  # that names no cause.
  var depPaths: seq[string] = @[]
  if proj.found and proj.deps.len > 0:
    let resolved = resolveDeps(proj)
    for d in resolved:
      if d.ok:
        note(o.verbose, "dep " & d.name & " → " & d.dir)
      else:
        stderr.writeLine "  " & amber(GWarn) & " " & gray("dep ") & cyan(d.name) &
          gray(" unresolved: ") & gray(d.err)
    depPaths = depSearchPaths(resolved)
    writeLock(proj, resolved)

  if t.semVariant == "aowlsem" and not tools.fileExists(t.aowlsem):
    stderr.writeLine "  " & amber("!") & " " & gray("profile selects ") &
      cyan("sem=aowlsem") & gray(", but the aowlsem binary was not found " &
      "(build ~/aowlsem/bin/aowlsem or set AOWLMONY_AOWLSEM) — using nimony sem")

  # ---- project-level commands, none of which need a compile ----------------
  if cmd == "new" or cmd == "init":
    var dir = ""
    var name = ""
    if cmd == "new":
      if o.rest.len == 0: fail("new needs a project name")
      name = o.rest[0]
      dir = name
      if project.dirExists(dir): fail("'" & dir & "' already exists")
      discard execShellCmd("mkdir -p " & quoteShell(dir & "/src"))
    else:
      dir = "."
      name = if o.rest.len > 0: o.rest[0] else: baseNameOf(getEnv("PWD", "app"))
      discard execShellCmd("mkdir -p " & quoteShell(dir & "/src"))
    let manifest = dir & "/mony.toml"
    if tools.fileExists(manifest): fail("mony.toml already exists")
    let entry = "src/" & name & ".nim"
    try:
      writeFile(manifest,
        "[package]\n" &
        "name    = \"" & name & "\"\n" &
        "version = \"0.1.0\"\n\n" &
        "[build]\n" &
        "entry   = \"" & entry & "\"\n" &
        "target  = \"native\"\n\n" &
        "[deps]\n")
      if not tools.fileExists(dir & "/" & entry):
        writeFile(dir & "/" & entry,
          "import std/syncio\n\nproc main() =\n  echo \"hello from " & name &
          "\"\n\nmain()\n")
    except:
      fail("could not write the project files")
    stdout.writeLine "  " & green(GOk) & " " & gray("created ") & cyan(name) &
      dim("  " & manifest & " + " & entry)
    stdout.writeLine "  " & dim("next → ") & teal("aowlmony run") &
      dim("   (the entry comes from mony.toml)")
    return

  if cmd == "clean":
    let st = stageDir(t)
    stdout.writeLine "  " & gray("stage ") & cyan(tildeAbbrev(st))
    if o.rest.len > 0 and o.rest[0] == "--all":
      discard execShellCmd("rm -rf " & quoteShell(st))
      stdout.writeLine "  " & green(GOk) & " removed the whole stage " &
        dim("(the next build is cold)")
    else:
      discard execShellCmd("rm -rf " & quoteShell(st & "/manifests"))
      stdout.writeLine "  " & green(GOk) & " dropped the build manifests " &
        dim("(artifacts kept; --all removes those too)")
    return

  if cmd == "fetch":
    if not proj.found: fail("fetch needs a project — run `" & Prog & " init` first")
    if proj.deps.len == 0:
      note(true, "no dependencies declared in mony.toml")
      return
    stdout.write banner(Prog, "resolving dependencies")
    let resolved = resolveDeps(proj)
    var rows: seq[seq[string]] = @[]
    var bad = 0
    for d in resolved:
      if d.ok:
        rows.add @[bold(white(d.name)), dim(d.source),
                   (if d.rev.len >= 8: cyan(d.rev[0 ..< 8]) else: dim("-")),
                   green(GOk & " " & tildeAbbrev(d.dir))]
      else:
        rows.add @[bold(white(d.name)), dim(d.source), dim("-"), red(GCross & " " & d.err)]
        inc bad
    stdout.writeLine renderTable(@[column("dep"), column("source"),
                                   column("rev"), column("resolved")], rows)
    writeLock(proj, resolved)
    stdout.writeLine ""
    stdout.writeLine "  " & gray("lockfile ") & cyan(tildeAbbrev(lockPath(proj)))
    stdout.writeLine ""
    if bad > 0: quit 1
    return

  if cmd == "test":
    # aowltest owns test running — hash-skipping unchanged cases is its whole
    # design, and reimplementing a worse version here would be the wrong kind of
    # self-reliance. We only locate it and hand over.
    var runner = ""
    for c in [homeDir() & "/aowltest/bin/aowltest", homeDir() & "/.aowl/bin/aowltest"]:
      if tools.fileExists(c): runner = c
    if runner.len == 0:
      let onPath = runCaptured("bash", @["-lc", "command -v aowltest || true"], "", false)
      if onPath.ok: runner = strip(onPath.output)
    if runner.len == 0 or not tools.fileExists(runner):
      fail("aowltest not found — install it, or run your tests directly")
    var targs: seq[string] = @[]
    for a in o.rest: targs.add a
    if targs.len == 0 and proj.found: targs.add proj.root
    quit runInherit(runner, targs)

  if cmd == "parse":
    if o.rest.len == 0: fail("parse needs a .nim file")
    quit runInherit(t.nifparser, @["p", o.rest[0], "-"])

  if cmd == "fix" or cmd == "lint" or cmd == "check":
    if o.rest.len == 0: fail(cmd & " needs a .nim file")
    let f = o.rest[0]
    if not tools.fileExists(f): fail("no such file: " & f)
    if t.aowlsuggest.len == 0 or not tools.fileExists(t.aowlsuggest):
      fail("aowlsuggest not found — build ~/aowlsuggest/bin/aowlsuggest or set AOWLMONY_AOWLSUGGEST")
    var extra: seq[string] = @[]
    if cmd == "fix":
      var dry = false
      for a in argv:
        if a == "--dry-run": dry = true
      extra.add(if dry: "--dry-run" else: "--write")
    for a in argv:
      if a.startsWith("--format:") or a.startsWith("--style:") or
         a == "--pedantic" or a == "--stats" or a == "--quiet" or a == "--color":
        extra.add a
    var callArgs = @[cmd, f]
    for e in extra: callArgs.add e
    quit runInherit(t.aowlsuggest, callArgs)

  # Commands below need a compiled front end.
  var file = if o.rest.len > 0: o.rest[0] else: ""
  if cmd == "eval":
    var code = ""
    var haveCode = false
    if o.hasEval:
      code = o.evalCode
      haveCode = true
    elif file == "-":
      var buf = ""
      var line = ""
      while readLine(stdin, line):
        buf.add line & "\n"
      code = buf
      haveCode = true
    if haveCode:
      let tmp = "/tmp/aowlmony-eval-" & $getMonoTime().ticks & ".nim"
      try:
        writeFile(tmp, (if code.endsWith("\n"): code else: code & "\n"))
      except:
        fail("could not write the temporary eval file")
      file = tmp
    elif file.len == 0:
      fail("eval needs a FILE, -e CODE, or -")

  if file.len == 0 and proj.found and proj.entry.len > 0:
    # `aowlmony run` inside a project needs no argument: the manifest names the
    # entry, which is the whole point of having one.
    file = proj.root & "/" & proj.entry
    note(o.verbose, "entry from mony.toml: " & file)
  if file.len == 0: fail(cmd & " needs a .nim file")
  if not tools.fileExists(file): fail("no such file: " & file)
  if cmd == "verify": compileFailCode = 2

  var absSrc = file
  try:
    absSrc = expandFilename(file)
  except:
    discard

  # `why` answers from the manifest WITHOUT building: the question is what
  # changed since last time, and building first would answer it by erasing it.
  if cmd == "why":
    let st = stageDir(t)
    let mpath = manifestPath(st, absSrc)
    let prev = readManifest(mpath)
    if prev.len == 0:
      stdout.writeLine "  " & gray("no previous build of ") & cyan(absSrc) &
        gray(" in this toolchain's cache")
      stdout.writeLine "  " & dim("stage ") & dim(st)
      return
    let cur = currentManifest(t, absSrc, mainHashOf(prev))
    let diffs = explainLines(prev, cur)
    if diffs.len == 0:
      stdout.writeLine "  " & green(GOk) & " " & gray("nothing changed — a build now would be a cache hit")
    else:
      stdout.writeLine "  " & amber(GWarn) & " " & gray("these inputs moved since the last build:")
      for d in diffs:
        if d.startsWith("+"): stdout.writeLine "    " & green(d)
        else: stdout.writeLine "    " & red(d)
    stdout.writeLine "  " & dim("stage ") & dim(st)
    return

  if cmd == "watch":
    # Poll the manifest rather than the filesystem: the manifest is content, and
    # the whole point of this driver's cache is that a timestamp is not evidence.
    #
    # The action is carried out by re-invoking THIS binary with the command the
    # user asked for (`--as run|interp|vm|nif|test`, default `run`), not by a
    # second copy of the dispatch: `watch` used to be hardcoded to `interp`
    # whatever you typed, and to throw away the exit code — which is what a
    # duplicated decision looks like once it has drifted.
    let action = if o.watchAs.len > 0: o.watchAs else: "run"
    stdout.writeLine "  " & gray("watching ") & cyan(tildeAbbrev(absSrc)) &
      gray(" · " & action) & dim("   (ctrl-c to stop)")
    # A watcher that buffers its own output is a watcher that appears to do
    # nothing: it is killed by ctrl-c, and a buffer that was never flushed dies
    # with the process. Every line this loop prints is flushed as it is written.
    flushFile(stdout)
    let self = getAppFilename()
    var last = ""
    var runs = 0
    while true:
      let now = currentManifest(t, absSrc,
                  mainHashOf(readManifest(manifestPath(stageDir(t), absSrc))))
      if now != last:
        last = now
        inc runs
        stdout.writeLine "  " & dim(GDot) & " " & gray("#" & $runs & "  " & action)
        flushFile(stdout)
        let rc = runInherit(self, @[action, absSrc])
        if rc != 0:
          stdout.writeLine "  " & red(GCross) & " " & gray("exit " & $rc)
        flushFile(stdout)
      discard execShellCmd("sleep 0.5")

  let b = build.build(file, t, o.verbose, proj, depPaths)
  if not b.ok:
    reportFailure(b, file, absSrc, t, o.verbose)
    fail("compile failed", compileFailCode)
  note(o.verbose, "main module " & b.mainHash & " parsed by " &
       (if b.byOurParser: "nifparser (ours)" else: "nifler (fallback)"))

  case cmd
  of "nif":
    stdout.writeLine ".p.nif  " & b.pnif &
      (if b.byOurParser: "  (nifparser)" else: "  (nifler)")
    stdout.writeLine ".s.nif  " & b.snif
    stdout.writeLine ".c.nif  " & b.cnif
  of "interp", "eval":
    let t0 = getMonoTime()
    let rc = runInherit(t.interp, aowliArgs(b.snif, absSrc, o, false))
    let ms = float(ticks(getMonoTime()) - ticks(t0)) / 1e6
    if rc == 0: timingLine(cmd, b.compileMs, ms, o.showTime)
    quit rc
  of "vm":
    let t0 = getMonoTime()
    let rc = runInherit(t.vm, aowliArgs(b.snif, absSrc, o, true))
    let ms = float(ticks(getMonoTime()) - ticks(t0)) / 1e6
    if rc == 0: timingLine(cmd, b.compileMs, ms, o.showTime)
    quit rc
  of "exec":
    if o.entry.len == 0: fail("exec needs --entry NAME")
    var a = @[t.native, "exec", b.cnif, "--entry", o.entry]
    for v in o.args:
      a.add "--arg"
      a.add v
    let t0 = getMonoTime()
    let rc = runInherit("node", a)
    let ms = float(ticks(getMonoTime()) - ticks(t0)) / 1e6
    if rc == 0: timingLine(cmd, b.compileMs, ms, o.showTime)
    quit rc
  of "build":
    var a = @[t.native, "build", b.cnif]
    if o.outFile.len > 0:
      a.add "-o"
      a.add o.outFile
    let t0 = getMonoTime()
    let rc = runInherit("node", a)
    let ms = float(ticks(getMonoTime()) - ticks(t0)) / 1e6
    if rc == 0: timingLine(cmd, b.compileMs, ms, o.showTime)
    quit rc
  of "run":
    let t0 = getMonoTime()
    let rc = runInherit("node", @[t.native, "run", b.cnif])
    let ms = float(ticks(getMonoTime()) - ticks(t0)) / 1e6
    if rc == 0: timingLine(cmd, b.compileMs, ms, o.showTime)
    quit rc
  of "ts", "js", "py":
    let bin = case cmd
              of "ts": t.ts
              of "js": t.js
              else: t.py
    if bin.len == 0 or not tools.fileExists(bin):
      fail(cmd & " backend not found (set AOWLMONY_AOWL" & toUpperAscii(cmd) &
           " or build ~/aowl" & cmd & "/bin/aowl" & cmd & ")")
    let outFile = outPath(file, o.outFile, cmd)
    let faithful = o.faithful and cmd != "py"   # int64-exact emission: ts/js only
    var a: seq[string] = @[]
    if faithful: a.add "--faithful"
    a.add b.snif
    note(o.verbose, cmd & " backend emits " & outFile &
         (if faithful: " (faithful)" else: ""))
    let er = runCaptured(bin, a, "", false)
    if not er.ok or er.exitCode != 0:
      if er.output.len > 0: stderr.write er.output
      fail(cmd & " backend failed")
    try:
      writeFile(outFile, er.output)
    except:
      fail("could not write " & outFile)
    stderr.writeLine "  " & green(GOk) & " " & gray("wrote ") &
      cyan(tildeAbbrev(outFile))
    if o.run:
      let t0 = getMonoTime()
      var rc = 0
      case cmd
      of "ts":
        # --no-warnings: the transform-types flag is experimental and its notice
        # would otherwise land in the program's own output.
        rc = runInherit("node", @["--experimental-transform-types", "--no-warnings", outFile])
      of "py":
        rc = runInherit("python3", @[outFile])
      else:
        # aowljs's flush emits a top-level `return __out;`, so the module is
        # wrapped in an IIFE and its return value printed — the same thing
        # aowljs's own run harness does.
        var src = ""
        try:
          src = readFile(outFile)
        except:
          src = ""
        rc = runInherit("node", @["-e",
          "process.stdout.write((function(){" & src & "})())"])
      let ms = float(ticks(getMonoTime()) - ticks(t0)) / 1e6
      if rc == 0: timingLine(cmd, b.compileMs, ms, o.showTime)
      quit rc
    timingLine(cmd, b.compileMs, -1.0, o.showTime)
  of "verify":
    if o.memory:
      # A DIFFERENT question from the differential above: a dangling-pointer
      # analysis over the artifact, witnessed against a `--fin` run.
      let timeoutM = if o.timeout > 0: o.timeout else: 30
      var art = ""
      try:
        art = readFile(b.snif)
      except:
        fail("cannot read " & b.snif)
      let mr = memoryFindings(art, absSrc, b.stage)
      var findings = mr.findings
      let st = mr.stats

      # The witness run. `--fin` is forced: without it the destroyer never runs
      # and the question this command asks is not even posed.
      var finArgs: seq[string] = @["--fin", "--trace"]
      for a in aowliArgs(b.snif, absSrc, o, false):
        if not a.startsWith("--trace") and a != "--fin": finArgs.add a
      let traced = runCap(t.interp, finArgs, timeoutM)
      let tr = parseTrace(traced.errText)
      let ranFin = tr.ops.len > 0
      if traced.timedOut:
        stderr.writeLine "  " & amber("!") & " " & gray("the --fin run hit the " &
          $timeoutM & "s timeout; findings below are static only")
      if tr.truncated:
        stderr.writeLine "  " & amber("!") & " " & gray("aowli truncated the trace " &
          "at its cap; witnesses past that point are unavailable")

      let base = baseNameOf(absSrc)
      var confirmed = 0
      if ranFin and not traced.timedOut:
        var k = 0
        while k < findings.len:
          witnessFinding(findings[k], tr.ops, base)
          if findings[k].confirmed: inc confirmed
          inc k

      stderr.writeLine ""
      if findings.len == 0:
        # ⚠️ "clean" and "the walk never reached your code" must not print the
        # same line, so the verdict carries what was examined.
        let nothingToCheck = st.sites == 0
        let head = if nothingToCheck: amber(GOk) else: green(GOk)
        let word = if nothingToCheck: amber("verify --memory") else: green("verify --memory")
        stderr.writeLine "  " & head & " " & bold(word) & " " & gray(GBar) & " " &
          gray(if nothingToCheck: "nothing to check — " & file & " takes no addresses"
               else: "no pointer outlives the storage it names")
        stderr.writeLine "    " & dim($st.sites & " address-taking site" &
          (if st.sites == 1: "" else: "s") & " · " & $st.tracked &
          " bound to a named pointer and tracked across " & $st.scopes & " scope" &
          (if st.scopes == 1: "" else: "s"))
        if st.sites > st.tracked:
          let n = st.sites - st.tracked
          stderr.writeLine "    " & gray("note: " & $n &
            (if n == 1: " address flows" else: " addresses flow") &
            " straight into a call rather than into a variable; this analysis is " &
            "intraprocedural and does not follow them into the callee")
        if not ranFin:
          stderr.writeLine "    " & amber("!") & " " & gray("the --fin run produced no " &
            "trace, so this is a static result only — nothing witnessed a destructor running")
        stderr.writeLine "    " & dim("front end " &
          (if b.byOurParser: "aowlparser" else: "nifler") & "→sem→" &
          (if b.usedHexer: "aowlhexer" else: "hexer") & " · witness " &
          baseNameOf(t.interp) & " --fin " & dayOf(t.interp) & " · " & $tr.ops.len & " traced op" &
          (if tr.ops.len == 1: "" else: "s"))
        stderr.writeLine ""
        quit 0

      stderr.writeLine "  " & red(GCross) & " " & bold(red("verify --memory")) & " " &
        gray(GBar) & " " & gray($findings.len &
          (if findings.len == 1: " defect, " else: " defects, ")) &
        (if confirmed > 0: red($confirmed & " confirmed under --fin")
         else: amber("none reached on this run"))
      stderr.writeLine ""

      for f in findings:
        let who = if f.routine.len > 0: "`" & f.routine & "`" else: "the routine"
        let title = if f.isEscape:
                      "the address of the local `" & f.target & "` outlives " & who
                    else:
                      "`" & f.ptrName & "` is used after the storage it points at was destroyed"
        stderr.writeLine "  " & bold(if f.isEscape: "escaping address" else: "use after free") &
          "   " & gray(title)
        stderr.writeLine "    " & cyan("allocated ") & gray(GArrow) & " " & file & ":" &
          $f.alloc.line & ":" & $(f.alloc.col + 1) &
          dim("   `" & f.target & "` is declared here")
        if f.isEscape:
          stderr.writeLine "    " & red("escapes   ") & gray(GArrow) & " " & file & ":" &
            $f.use.line & ":" & $(f.use.col + 1) &
            dim("   its address is returned from " & who) &
            (if f.confirmed: dim(" — " & f.routine & " ran on this run") else: "")
          stderr.writeLine "    " & violet("freed     ") & gray(GArrow) &
            dim(" as " & who & " returns — every caller's copy of the pointer is " &
                "dangling from that moment")
        else:
          let openedLine = if f.hasOpened: f.opened.line else: f.freeAt.line
          stderr.writeLine "    " & violet("freed     ") & gray(GArrow) & " " & file & ":" &
            $f.freeAt.line & dim("   end of the scope opened at " & file & ":" & $openedLine) &
            (if f.destroyed: dim(" — =destroy witnessed here") else: "")
          stderr.writeLine "    " & red("used      ") & gray(GArrow) & " " & file & ":" &
            $f.use.line & ":" & $(f.use.col + 1) &
            (if f.reachedUse: dim("   executed on this run") else: "")
        stderr.writeLine ""

        let note =
          if not ranFin:
            "static only: the --fin witness run produced no trace"
          elif f.isEscape:
            if f.confirmed:
              "confirmed: " & who & " ran under --fin, so a dangling pointer really was handed out"
            else:
              who & " was not called on this run, so nothing witnessed the escape — " &
                "the analysis is structural"
          elif f.confirmed:
            "confirmed: the --fin run destroyed `" & f.target & "` and then reached this line"
          elif f.destroyed:
            "the destructor ran, but this line was not reached on this run — the defect " &
              "is real, the path is not exercised by the program's default input"
          else:
            "this run neither destroyed `" & f.target & "` nor reached this line; the " &
              "analysis is structural and the path was not taken"
        renderDiag(Diagnostic(file: file, line: f.use.line, col: f.use.col + 1,
          endCol: f.use.col + 1 + f.ptrName.len,
          severity: (if f.confirmed: "error" else: "warning"), code: "",
          message: title, helps: @[Help(kind: "note", text: note)]), absSrc, file)
        stderr.writeLine ""

      stderr.writeLine "    " & dim("front end " &
        (if b.byOurParser: "aowlparser" else: "nifler") & "→sem→" &
        (if b.usedHexer: "aowlhexer" else: "hexer") & " · witness " &
        baseNameOf(t.interp) & " --fin " & dayOf(t.interp) & " · " & $tr.ops.len & " traced op" &
        (if tr.ops.len == 1: "" else: "s"))
      stderr.writeLine ""
      quit 1
    let timeoutS = if o.timeout > 0: o.timeout else: 30
    let which = if o.native.len > 0: o.native else: "nimony"
    if which != "nimony" and which != "aowlc":
      fail("--native takes nimony|aowlc, not '" & which & "'")

    var bin = ""
    var temp = false
    if which == "nimony":
      bin = b.nbin
      if bin.len == 0:
        stderr.writeLine ""
        stderr.writeLine "  " & red(GCross) & " " & bold(red("verify")) & " " &
          gray(GBar) & " " & gray("nimony linked no binary for this module — nothing to compare against")
        stderr.writeLine "  " & gray("  try the self-owned backend instead: ") &
          teal("aowlmony verify " & file & " --native:aowlc")
        stderr.writeLine ""
        quit 2
    else:
      # build first, then run — so a BUILD failure is never mistaken for the
      # program writing to stderr (`aowlc run` merges the two).
      bin = "/tmp/aowlmony-verify-bin-" & $ticks(getMonoTime())
      temp = true
      let nb = runCap("node", @[t.native, "build", b.cnif, "-o", bin], timeoutS)
      if nb.code != 0 or not tools.fileExists(bin):
        stderr.writeLine ""
        stderr.writeLine "  " & red(GCross) & " " & bold(red("verify")) & " " &
          gray(GBar) & " " & gray("the aowlc native leg did not build — nothing to compare against")
        var shown = 0
        for l in splitLines(nb.errText & "\n" & nb.outText):
          if shown >= 4: break
          if contains(l, "error") or contains(l, "Error"):
            stderr.writeLine "  " & dim("    " & strip(l))
            inc shown
        stderr.writeLine "  " & gray("  the interpreted leg is unaffected — ") &
          teal("aowlmony interp " & file) & gray(" runs it")
        stderr.writeLine ""
        quit 2

    let nat = runCap(bin, o.progArgs, timeoutS)
    let itp = runCap(t.interp, aowliArgs(b.snif, absSrc, o, false), timeoutS)
    if temp: discard execShellCmd("rm -f " & quoteShell(bin))

    for leg in [("native", nat), ("interpreted", itp)]:
      if leg[1].timedOut:
        stderr.writeLine ""
        stderr.writeLine "  " & red(GCross) & " " & bold(red("verify")) & " " &
          gray(GBar) & " the " & leg[0] & " leg hit the " & $timeoutS &
          "s timeout (raise it with " & teal("--timeout:N") & ")"
        stderr.writeLine "  " & gray("  the other leg finished, so this is itself a divergence: one realizer does not terminate")
        stderr.writeLine ""
        quit 1

    let stale = newerBuildThan(t.interp, repoBin("nifi", "-interp"))

    # stdout first (that is what programs are judged on), then stderr, then exit
    # status. Only re-run under --trace when something actually differs.
    for check in [("stdout", nat.outText, itp.outText),
                  ("stderr", nat.errText, itp.errText)]:
      let off = firstDiff(check[1], check[2])
      if off < 0: continue
      var traceArgs: seq[string] = @["--trace"]
      for a in aowliArgs(b.snif, absSrc, o, false):
        if not a.startsWith("--trace"): traceArgs.add a
      let traced = runCap(t.interp, traceArgs, timeoutS)
      let tr = parseTrace(traced.errText)
      if tr.truncated:
        stderr.writeLine "  " & amber("!") & " " &
          gray("aowli truncated the trace at its cap; attribution past that point is unavailable")
      let writes = if check[0] == "stdout": tr.stdoutWrites else: tr.stderrWrites
      let att = attribute(tr, writes, check[2], off)

      let lc = offsetToLineCol((if check[1].len > off: check[1] else: check[2]), off)
      stderr.writeLine ""
      stderr.writeLine "  " & red(GCross) & " " & bold(red("verify")) & " " &
        gray(GBar) & " " & gray("native ") & red("≢") & gray(" interpreted")
      stderr.writeLine ""
      stderr.writeLine "  " & bold("first divergence") & gray("  in " & check[0] &
        " at line " & $lc[0] & ", col " & $lc[1] & "  (byte " & $off & ")")
      stderr.writeLine "    " & cyan("native      ") & gray(GArrow) & " " & around(check[1], off)
      stderr.writeLine "    " & violet("interpreted ") & gray(GArrow) & " " & around(check[2], off)

      if att[0] < 0:
        stderr.writeLine ""
        stderr.writeLine "  " & amber("!") & " " & gray("no traced write op covers that byte — " &
          "the interpreted leg produced this output outside a recorded call")
        stderr.writeLine ""
      else:
        let op = tr.ops[att[0]]
        stderr.writeLine ""
        stderr.writeLine "  " & bold("produced by") & "       " &
          teal(op.callee & "(" & op.argstr & ")") &
          dim("   op #" & $op.idx & " of the interpreted run")
        if not att[1]:
          stderr.writeLine "  " & amber("!") & " " & gray("attribution is approximate: the " &
            "rebuilt trace stream does not match the run's output byte-for-byte " &
            "(aowli truncates trace args at 48 chars)")
        let loc = locateOp(tr, att[0], absSrc)
        stderr.writeLine ""
        if loc.ok:
          var helps: seq[Help] = @[]
          if loc.how == "caller":
            helps.add Help(kind: "note", text: "innermost enclosing user frame — the " &
              "divergent op itself (" & op.callee & ") is outside " & file)
          elif loc.how == "preceding":
            helps.add Help(kind: "note", text: "the statement in progress: `" & op.callee &
              "` runs with no user frame above it (a top-level echo expands to " &
              "write(stdout,…) inside system), so this is the last op the interpreter " &
              "ran at a line in your module — `" & loc.callee & "`")
          renderDiag(Diagnostic(file: file, line: loc.line, col: loc.col, endCol: loc.endCol,
            severity: "error", code: "",
            message: "native and interpreted disagree here", helps: helps), absSrc, file)
        else:
          stderr.writeLine "  " & amber("!") & " " & gray("no source location: every frame " &
            "on this op's chain is outside " & file & " — the whole stack ran in the standard library")
      provenance(which, bin, t.interp, b.byOurParser, b.usedHexer)
      warnStale(stale, t.interp)
      stderr.writeLine ""
      quit 1

    if nat.code != itp.code:
      stderr.writeLine ""
      stderr.writeLine "  " & red(GCross) & " " & bold(red("verify")) & " " &
        gray(GBar) & " " & gray("output agrees, ") & red("exit status does not")
      stderr.writeLine "  " & cyan("native      ") & gray(GArrow) & " exit " & $nat.code
      stderr.writeLine "  " & violet("interpreted ") & gray(GArrow) & " exit " & $itp.code
      provenance(which, bin, t.interp, b.byOurParser, b.usedHexer)
      warnStale(stale, t.interp)
      stderr.writeLine ""
      quit 1

    # Agreed — say exactly what was compared, so a trivial "both printed nothing"
    # never reads like a strong result.
    var nLines = 0
    if nat.outText.len > 0:
      nLines = splitLines(nat.outText).len
      if nat.outText.endsWith("\n"): dec nLines
    stderr.writeLine ""
    stderr.writeLine "  " & green(GOk) & " " & bold(green("verify")) & " " &
      gray(GBar) & " " & gray("native ") & green("≡") & gray(" interpreted")
    stderr.writeLine "    " & dim("stdout " & $nat.outText.len & "B / " & $nLines &
      " line" & (if nLines == 1: "" else: "s") & " · stderr " & $nat.errText.len &
      "B · exit " & $nat.code)
    if nat.outText.len == 0 and nat.errText.len == 0:
      stderr.writeLine "  " & amber("!") & " " &
        gray("both legs produced no output — agreement here is weak evidence")
    provenance(which, bin, t.interp, b.byOurParser, b.usedHexer)
    if stale.found:
      stderr.writeLine "  " & amber("!") & " " & gray("a newer interpreter exists (") &
        cyan(tildeAbbrev(stale.path)) & gray(") — this agreement is about the older build")
    stderr.writeLine ""
    quit 0
  else:
    fail("unknown command '" & cmd & "'. Try `" & Prog & " help`.")

main()
