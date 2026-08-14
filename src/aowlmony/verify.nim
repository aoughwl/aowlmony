## `verify` — run the same program natively and interpreted, and report the first
## place they disagree.
##
## Both realizers hang off ONE front end, so a native-vs-interpreted disagreement
## is a BACKEND defect by construction: the parser, the semantic checker and the
## lowering that produced the artifact are shared, and only the realizer differs.
##
## Exit codes carry the verdict: 0 they agree, 1 they disagree, 2 a leg could not
## run. A compile failure must therefore NOT land on 1 — the driver reclassifies
## it as 2 before calling in here.
##
## `--memory` is a different question (a static dangling-pointer analysis over
## the NIF, witnessed against a `--fin` run) and is not implemented here; the JS
## driver still answers it.

import std/[syncio, strutils, os, monotimes]
import aowlkit/[subprocess, tty]
import tools, diag

type Cap* = object
  outText*: string
  errText*: string
  code*: int
  timedOut*: bool
  ranAtAll*: bool

proc runCap*(cmd: string, args: seq[string], timeoutS: int): Cap =
  ## Separate streams, a real timeout, and an exit code. `timeout` reports 124.
  result = Cap(outText: "", errText: "", code: 0, timedOut: false, ranAtAll: false)
  let stamp = $ticks(getMonoTime())
  let base = "/tmp/aowlmony-verify-" & stamp
  # The redirects belong to the CHILD, not to `timeout`. Redirecting the whole
  # pipeline puts timeout's own "the monitored command dumped core" into the
  # file we then read back as the program's stderr — and a divergence report
  # would blame the program for a message the wrapper wrote.
  let script = "exec \"$0\" \"$@\" > " & quoteShell(base & ".out") &
               " 2> " & quoteShell(base & ".err")
  var line = "timeout " & $timeoutS & " /bin/sh -c " & quoteShell(script) & " " &
             quoteShell(cmd)
  for a in args: line.add " " & quoteShell(a)
  # and the WRAPPER's own stderr is discarded: `timeout` announces a core dump
  # and the shell announces "Floating point exception", neither of which the
  # program wrote. Left alone they surface as the driver's own output.
  line.add " 2>/dev/null"
  result.code = execShellCmd(line)
  result.timedOut = result.code == 124
  try:
    result.outText = readFile(base & ".out")
    result.ranAtAll = true
  except:
    result.outText = ""
  try:
    result.errText = readFile(base & ".err")
  except:
    result.errText = ""
  discard execShellCmd("rm -f " & quoteShell(base & ".out") & " " & quoteShell(base & ".err"))

proc firstDiff*(a, b: string): int =
  ## Index of the first differing byte, or -1. When one is a strict prefix of the
  ## other the divergence is AT the end of the shorter stream.
  var n = a.len
  if b.len < n: n = b.len
  var i = 0
  while i < n:
    if a[i] != b[i]: return i
    inc i
  if a.len == b.len: -1 else: n

proc offsetToLineCol*(s: string, i: int): (int, int) =
  var line = 1
  var col = 1
  var k = 0
  while k < i and k < s.len:
    if s[k] == '\n':
      inc line
      col = 1
    else:
      inc col
    inc k
  (line, col)

proc printable(s: string): string =
  result = "\""
  for c in s:
    case c
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    else:
      if c < ' ': result.add "\\x" & $int(c)
      else: result.add c
  result.add "\""

proc around*(s: string, i: int, n = 24): string =
  if i >= s.len: return dim("<end of output>")
  var stop = i + n
  if stop > s.len: stop = s.len
  result = printable(s[i ..< stop])
  if s.len > i + n: result.add dim(" …")

# --------------------------------------------------------------------------
# the trace
# --------------------------------------------------------------------------

type
  Frame* = object
    callee*: string
    line*: int
    file*: string

  Op* = object
    idx*: int
    depth*: int
    line*: int
    file*: string
    callee*: string
    argstr*: string
    chain*: seq[Frame]
    stream*: string     ## "stdout"/"stderr" for a write op, else ""
    chunk*: string
    chunkTruncated*: bool

  Trace* = object
    ops*: seq[Op]
    stdoutWrites*: seq[int]   ## indices into ops
    stderrWrites*: seq[int]
    truncated*: bool

proc unescapeArg*(s: string): (string, bool) =
  ## Undo aowli trace.nim's argText() escaping. It renders an argument longer
  ## than 48 chars as `s[0..44] & "..."`, so a 48-char chunk ending in "..." is
  ## almost certainly truncated — and byte-exact reconstruction is off from there.
  let truncated = s.len == 48 and s.endsWith("...")
  let body = if truncated: s[0 ..< s.len - 3] else: s
  var res = ""
  var i = 0
  while i < body.len:
    if body[i] == '\\' and i + 1 < body.len and body[i + 1] == 'n':
      res.add '\n'
      i = i + 2
    elif body[i] == '\\' and i + 1 < body.len and body[i + 1] == 't':
      res.add '\t'
      i = i + 2
    else:
      res.add body[i]
      inc i
  (res, truncated)

proc splitTail(rest: string): (string, string, int) =
  ## `…  <file>:<line>` at the end of a trace line. aowli renders the file since
  ## the attribution change; older builds render `  :<line>` with no file. Accept
  ## both — an unrecognised suffix would leave every op at line 0 and silently
  ## kill attribution rather than failing loudly.
  var i = rest.len - 1
  var digits = 0
  while i >= 0 and rest[i] >= '0' and rest[i] <= '9':
    dec i
    inc digits
  if digits == 0 or i < 0 or rest[i] != ':': return (rest, "", 0)
  let lineNo = rest[i + 1 ..< rest.len]
  var j = i - 1
  while j >= 0 and rest[j] != ' ' and rest[j] != '(' and rest[j] != ')' and rest[j] != ':':
    dec j
  if j < 1 or rest[j] != ' ' or rest[j - 1] != ' ': return (rest, "", 0)
  let fileName = rest[j + 1 ..< i]
  var n = 0
  try:
    n = parseInt(lineNo)
  except:
    return (rest, "", 0)
  (rest[0 ..< j - 1], fileName, n)

proc parseTrace*(text: string): Trace =
  ## Indentation is two spaces per depth, `→` opens a frame, `←` closes one.
  ## Each op keeps the live frame chain above it, so a stdlib op can be walked
  ## back up to user code.
  result = Trace(ops: @[], stdoutWrites: @[], stderrWrites: @[], truncated: false)
  var stack: seq[Frame] = @[]
  for raw in splitLines(text):
    if strip(raw).len == 0: continue
    if contains(raw, "(trace truncated at"):
      result.truncated = true
      continue
    if raw.startsWith("-- trace:"): continue
    var lead = 0
    while lead < raw.len and raw[lead] == ' ': inc lead
    let depth = lead shr 1
    let body = raw[lead ..< raw.len]
    if body.startsWith("←"):
      if stack.len > depth: stack.setLen depth
      continue
    if not body.startsWith("→"): continue
    var rest = body[len("→") + 1 ..< body.len]
    let tail = splitTail(rest)
    rest = tail[0]
    let openParen = find(rest, '(')
    if openParen < 0 or not rest.endsWith(")"): continue
    if stack.len > depth: stack.setLen depth

    var op = Op(idx: result.ops.len, depth: depth, line: tail[2], file: tail[1],
                callee: rest[0 ..< openParen],
                argstr: rest[openParen + 1 ..< rest.len - 1],
                chain: stack, stream: "", chunk: "", chunkTruncated: false)

    # `echo` lowers to `write(stdout, …)`; that argument IS the emitted text.
    if op.callee == "write":
      for s in ["stdout", "stderr"]:
        if op.argstr.startsWith(s & ", "):
          let u = unescapeArg(op.argstr[s.len + 2 ..< op.argstr.len])
          op.stream = s
          op.chunk = u[0]
          op.chunkTruncated = u[1]
    stack.add Frame(callee: op.callee, line: op.line, file: op.file)
    result.ops.add op
    if op.stream == "stdout": result.stdoutWrites.add op.idx
    elif op.stream == "stderr": result.stderrWrites.add op.idx

proc attribute*(tr: Trace, writeIdx: seq[int], actual: string,
                off: int): (int, bool) =
  ## Which traced write produced byte `off`? The stream is rebuilt from the write
  ## ops and checked against what the program really printed: `exact` is false
  ## when the rebuild disagrees, so the named op is a best prefix match and NOT a
  ## proof. Saying which it is matters more than naming an op.
  var pos = 0
  var hit = -1
  var exact = true
  for i in writeIdx:
    let op = tr.ops[i]
    if op.chunkTruncated: exact = false
    let stop = pos + op.chunk.len
    if hit < 0 and off < stop: hit = i
    var seg = ""
    if pos < actual.len:
      var e = stop
      if e > actual.len: e = actual.len
      seg = actual[pos ..< e]
    if seg != op.chunk: exact = false
    pos = stop
  if pos != actual.len: exact = false
  if hit < 0 and writeIdx.len > 0: hit = writeIdx[writeIdx.len - 1]
  (hit, exact)

type Located* = object
  line*: int
  col*: int
  endCol*: int
  callee*: string
  how*: string    ## "self" | "caller" | "preceding"
  ok*: bool

proc atLine(lines: seq[string], lineNo: int, how, callee: string): Located =
  ## Module level rather than nested: capturing `lines` from an inner proc needs
  ## an explicit `.closure` in nimony, and passing it says the same thing.
  let text = if lineNo - 1 >= 0 and lineNo - 1 < lines.len: lines[lineNo - 1] else: ""
  var indent = 0
  while indent < text.len and (text[indent] == ' ' or text[indent] == '\t'): inc indent
  var col = indent + 1
  if col < 1: col = 1
  var endCol = len(strip(text, leading = false))
  if endCol < col: endCol = col
  Located(line: lineNo, col: col, endCol: endCol, callee: callee, how: how, ok: true)

proc locateOp*(tr: Trace, opIdx: int, absSrc: string): Located =
  ## When aowli's trace carries a FILE, a frame is user code iff that file is the
  ## entry module — exact, no heuristic. Older builds record a line only, so we
  ## fall back to "the innermost frame whose line falls inside the entry module",
  ## which can misfire on a stdlib line that happens to be in range. That is
  ## exactly why the file is preferred when present.
  result = Located(line: 0, col: 0, endCol: 0, callee: "", how: "", ok: false)
  var lines: seq[string] = @[]
  var content = ""
  try:
    content = readFile(absSrc)
  except:
    return
  for l in splitLines(content): lines.add l

  var base = absSrc
  var cut = -1
  var i = 0
  while i < base.len:
    if base[i] == '/': cut = i
    inc i
  if cut >= 0: base = base[cut + 1 ..< base.len]

  let op = tr.ops[opIdx]
  var frames = op.chain
  frames.add Frame(callee: op.callee, line: op.line, file: op.file)

  var anyFile = false
  for f in frames:
    if f.file.len > 0: anyFile = true


  var k = frames.len - 1
  while k >= 0:
    let f = frames[k]
    let inSrc = f.line > 0 and f.line <= lines.len and
                (if anyFile: f.file == base else: true)
    if inSrc:
      return atLine(lines, f.line, (if k == frames.len - 1: "self" else: "caller"), f.callee)
    dec k

  # Nothing on the chain is user code — the normal shape for a top-level `echo`,
  # which expands to write(stdout,…) recorded at system's line with no user frame
  # above it. The last op run AT a user line is then the statement in progress:
  # a preceding SIBLING, not an ancestor, hence the separate walk.
  var j = opIdx - 1
  while j >= 0:
    let o = tr.ops[j]
    let inSrc = o.line > 0 and o.line <= lines.len and
                (if anyFile: o.file == base else: true)
    if inSrc: return atLine(lines, o.line, "preceding", o.callee)
    dec j

# --------------------------------------------------------------------------
# staleness
# --------------------------------------------------------------------------

type Newer* = object
  found*: bool
  path*: string
  mtime*: int64
  resolvedMtime*: int64

proc mtimeOf(p: string): int64 =
  try:
    getLastModificationTime(p)
  except:
    -1

proc newerBuildThan*(resolved: string, candidates: seq[string]): Newer =
  ## A verdict is only as good as the binaries it ran. The registry can resolve a
  ## tool to an INSTALLED copy that a checkout has since moved past, and a
  ## week-old engine then reads as a backend divergence — exactly the wrong
  ## conclusion. Find any newer copy so verify can say so instead of blaming a
  ## backend.
  result = Newer(found: false, path: "", mtime: 0, resolvedMtime: 0)
  let mine = mtimeOf(resolved)
  if mine < 0: return
  result.resolvedMtime = mine
  for c in candidates:
    if c.len == 0 or c == resolved: continue
    let m = mtimeOf(c)
    if m > mine and (not result.found or m > result.mtime):
      result.found = true
      result.path = c
      result.mtime = m

proc dayOf*(p: string): string =
  let r = runCaptured("date", @["-r", p, "+%Y-%m-%d"], "", false)
  if r.ok and r.exitCode == 0: strip(r.output) else: "?"
