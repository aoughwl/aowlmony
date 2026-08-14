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
import aowlmony/[tools, stage, build, diag, project]

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
  keep: bool
  memory: bool
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
                run: false, keep: false, memory: false, showTime: true,
                verbose: false)
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
    elif a == "--faithful": result.faithful = true
    elif a == "--run": result.run = true
    elif a == "--keep": result.keep = true
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
    @["test [ARGS]", "run the project's tests via aowltest"],
    @["watch FILE", "rebuild whenever an input changes"],
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
    dim("-o  --entry  --arg  --engine  --faithful  --run  --keep  --no-time  --timeout:N  -v")
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
    lines.add replaceAll(s, abs, nimFile)

  let diags = parseDiagnostics(lines)
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

  # A manifest entry that does nothing is worse than an error: say plainly which
  # deps this driver cannot resolve yet, every build, rather than letting the
  # program fail later with an import error that names no cause.
  if proj.found:
    let missing = unresolvedDeps(proj)
    if missing.len > 0:
      stderr.writeLine "  " & amber(GWarn) & " " & gray("mony.toml declares ") &
        cyan(joinStr(missing, ", ")) &
        gray(" as git/version deps — only path deps resolve today, so ") &
        gray("these are NOT on the search path")

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
    let lib = if t.nimony.len > 0: t.nimony else: ""
    discard lib
    let closure = userClosure(st & "/nc", st, "")
    let cur = buildManifest(absSrc, closure, t)
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
    let st = stageDir(t)
    stdout.writeLine "  " & gray("watching ") & cyan(tildeAbbrev(absSrc)) &
      dim("   (ctrl-c to stop)")
    var last = ""
    while true:
      let closure = userClosure(st & "/nc", st, "")
      let now = buildManifest(absSrc, closure, t)
      if now != last:
        last = now
        let wb = build.build(file, t, false, proj)
        if wb.ok:
          let rc = runInherit(t.interp, aowliArgs(wb.snif, absSrc, o, false))
          discard rc
          timingLine("watch", wb.compileMs, -1.0, o.showTime)
        else:
          reportFailure(wb, file, absSrc, t, false)
      discard execShellCmd("sleep 0.5")

  let b = build.build(file, t, o.verbose, proj)
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
    # The differential harness is the largest single piece of the JS driver and
    # is not ported yet; it still answers for this command.
    fail("'" & cmd & "' is not in the nimony build yet — use the JS driver for it", 3)
  else:
    fail("unknown command '" & cmd & "'. Try `" & Prog & " help`.")

main()
