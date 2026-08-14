## aowlmony — the driver over the self-owned aowl stack.
##
## Give it a `.nim` file and it runs parser → sem → lowering → your choice of
## native code, an interpreter, or idiomatic source, using aoughwl's own
## components wherever they exist and reusing nimony's for the parts not yet
## rebuilt.
##
## Two tools, modelled on `rustup` : `cargo` — **aowlup** manages the toolchain
## and writes the registry; **aowlmony** compiles code and only ever reads it.

import std/[syncio, strutils, envvars, cmdline, os, monotimes]
import aowlkit/[subprocess, tty]
import aowlmony/[tools, stage, build]

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

  if cmd.len == 0 or cmd == "-h" or cmd == "--help" or cmd == "help":
    cmdHelp(t)
    return

  if t.semVariant == "aowlsem" and not tools.fileExists(t.aowlsem):
    stderr.writeLine "  " & amber("!") & " " & gray("profile selects ") &
      cyan("sem=aowlsem") & gray(", but the aowlsem binary was not found " &
      "(build ~/aowlsem/bin/aowlsem or set AOWLMONY_AOWLSEM) — using nimony sem")

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

  let b = build.build(file, t, o.verbose)
  if not b.ok:
    if b.output.len > 0: stderr.write b.output
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
  of "ts", "js", "py", "verify":
    # Known commands the nimony build does not implement yet. The JS driver is
    # still the one that answers for them, and saying so beats a wrong answer.
    fail("'" & cmd & "' is not in the nimony build yet — use the JS driver for it", 3)
  else:
    fail("unknown command '" & cmd & "'. Try `" & Prog & " help`.")

main()
