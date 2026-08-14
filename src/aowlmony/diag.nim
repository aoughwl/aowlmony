## Compiler diagnostics, rendered the way a user can act on.
##
## Two front ends produce them and they disagree about format:
##   nimony       path(line, col) Error: message        (Warning:/Hint: too)
##   our parser   file:line:col: error[code]: message   (+ trailing help:/hint:)
##
## Everything here writes to STDERR, so a captured stdout stays the program's.

import std/[syncio, strutils]
import aowlkit/tty

type
  Help* = object
    kind*: string
    text*: string

  Diagnostic* = object
    file*: string
    line*: int
    col*: int
    severity*: string   ## error | warning | hint
    code*: string       ## "" when the front end gave none
    message*: string
    helps*: seq[Help]

# --------------------------------------------------------------------------
# a dependency-free Nim highlighter
# --------------------------------------------------------------------------

const
  Keywords = ["addr", "and", "as", "asm", "bind", "block", "break", "case",
    "cast", "concept", "const", "continue", "converter", "defer", "discard",
    "distinct", "div", "do", "elif", "else", "end", "enum", "except", "export",
    "finally", "for", "from", "func", "if", "import", "in", "include",
    "interface", "is", "isnot", "iterator", "let", "macro", "method", "mixin",
    "mod", "nil", "not", "notin", "object", "of", "or", "out", "proc", "ptr",
    "raise", "ref", "return", "shl", "shr", "static", "template", "try",
    "tuple", "type", "using", "var", "when", "while", "xor", "yield"]
  TypeNames = ["int", "float", "string", "bool", "char", "byte", "uint",
    "int8", "int16", "int32", "int64", "uint8", "uint16", "uint32", "uint64",
    "float32", "float64", "seq", "array", "void"]
  Delims = "()[]{},.;:+-*/=<>! \t"

proc isKeyword(w: string): bool =
  for k in Keywords:
    if k == w: return true
  false

proc isTypeName(w: string): bool =
  for k in TypeNames:
    if k == w: return true
  false

proc isDelim(c: char): bool =
  for d in Delims:
    if d == c: return true
  false

proc hlNim*(line: string): string =
  ## Char-by-char, matching the scheme the rest of the toolchain uses: keywords
  ## red, types yellow, strings/chars cyan, `#` comments green. Tolerant of an
  ## unterminated literal, because that is exactly what an error line often is.
  if not colorEnabled(): return line
  result = ""
  var word = ""

  # NB: no nested proc. A closure over `word`/`result` needs an explicit
  # `.closure` annotation in nimony, and the token flush is two lines anyway.
  template flushWord() =
    if word.len > 0:
      if isKeyword(word): result.add col(Red, word)
      elif isTypeName(word): result.add col(Amber, word)
      else: result.add word
      word = ""

  var i = 0
  while i < line.len:
    let ch = line[i]
    if ch == '"' or ch == '\'':
      flushWord()
      let q = ch
      var s = $ch
      inc i
      while i < line.len:
        let c = line[i]
        s.add c
        if c == '\\' and i + 1 < line.len:
          s.add line[i + 1]
          i = i + 2
          continue
        inc i
        if c == q: break
      result.add col(Cyan, s)
      continue
    elif ch == '#':
      flushWord()
      result.add col(Green, line[i ..< line.len])
      return result
    elif isDelim(ch):
      flushWord()
      result.add ch
    else:
      word.add ch
    inc i
  flushWord()

# --------------------------------------------------------------------------
# parsing
# --------------------------------------------------------------------------

proc parseInt0(s: string): int =
  try:
    parseInt(s)
  except:
    0

proc parseNimonyLine(raw: string): (bool, Diagnostic) =
  ## path(line, col) Severity: message
  var d = Diagnostic(file: "", line: 0, col: 0, severity: "", code: "",
                     message: "", helps: @[])
  let s = strip(raw)
  let open = find(s, '(')
  if open <= 0: return (false, d)
  let close = find(s, ')', open)
  if close < 0: return (false, d)
  let inner = s[open + 1 ..< close]
  let comma = find(inner, ',')
  if comma < 0: return (false, d)
  let lineNo = parseInt0(strip(inner[0 ..< comma]))
  let colNo = parseInt0(strip(inner[comma + 1 ..< inner.len]))
  if lineNo == 0: return (false, d)
  var rest = strip(s[close + 1 ..< s.len])
  var sev = ""
  for cand in ["Error", "Warning", "Hint"]:
    if rest.startsWith(cand & ":"):
      sev = toLowerAscii(cand)
      rest = strip(rest[cand.len + 1 ..< rest.len])
  if sev.len == 0: return (false, d)
  d.file = s[0 ..< open]
  d.line = lineNo
  d.col = colNo
  d.severity = sev
  d.message = rest
  (true, d)

proc parseOursLine(raw: string): (bool, Diagnostic) =
  ## file:line:col: severity[code]: message
  var d = Diagnostic(file: "", line: 0, col: 0, severity: "", code: "",
                     message: "", helps: @[])
  let s = strip(raw)
  # walk from the right so a path containing ':' still splits correctly
  var fields: seq[string] = @[]
  var cur = ""
  for c in s:
    if c == ':':
      fields.add cur
      cur = ""
    else:
      cur.add c
  fields.add cur
  if fields.len < 4: return (false, d)
  # fields: [path…, line, col, severity[code], message…]
  var idx = 0
  var lineIdx = -1
  while idx < fields.len - 2:
    let a = strip(fields[idx + 1])
    let b = strip(fields[idx + 2])
    if a.len > 0 and b.len > 0 and parseInt0(a) > 0 and parseInt0(b) > 0:
      lineIdx = idx + 1
      break
    inc idx
  if lineIdx < 0: return (false, d)
  var path = fields[0]
  var k = 1
  while k < lineIdx:
    path.add ":" & fields[k]
    inc k
  d.file = path
  d.line = parseInt0(strip(fields[lineIdx]))
  d.col = parseInt0(strip(fields[lineIdx + 1]))
  if lineIdx + 2 >= fields.len: return (false, d)
  var sev = strip(fields[lineIdx + 2])
  let br = find(sev, '[')
  if br >= 0:
    let close = find(sev, ']', br)
    if close > br:
      d.code = sev[br + 1 ..< close]
    sev = sev[0 ..< br]
  sev = toLowerAscii(strip(sev))
  if sev != "error" and sev != "warning" and sev != "hint": return (false, d)
  d.severity = sev
  var msg = ""
  var m = lineIdx + 3
  while m < fields.len:
    if msg.len > 0: msg.add ":"
    msg.add fields[m]
    inc m
  d.message = strip(msg)
  (true, d)

proc parseDiagnostics*(lines: seq[string]): seq[Diagnostic] =
  result = @[]
  for raw in lines:
    let a = parseNimonyLine(raw)
    if a[0]:
      result.add a[1]
      continue
    let b = parseOursLine(raw)
    if b[0]:
      result.add b[1]
      continue
    # a trailing help:/hint: attaches to the diagnostic above it
    let s = strip(raw)
    if result.len > 0:
      for kind in ["help", "hint"]:
        if s.startsWith(kind & ":"):
          result[result.len - 1].helps.add Help(kind: kind,
            text: strip(s[kind.len + 1 ..< s.len]))
          break

# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------

proc severityColor(sev, s: string): string =
  case sev
  of "warning": amber(s)
  of "hint": cyan(s)
  else: red(s)

proc caretSpan(d: Diagnostic, line: string): int =
  ## The identifier starting at the column, so the underline covers the token
  ## rather than a single character.
  var n = 0
  var i = d.col - 1
  while i >= 0 and i < line.len:
    let c = line[i]
    if (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
       (c >= '0' and c <= '9') or c == '_':
      inc n
      inc i
    else:
      break
  if n < 1: 1 else: n

proc readSourceLines(d: Diagnostic, abs, nimFile: string): seq[string] =
  result = @[]
  var p = ""
  if d.file == nimFile: p = abs
  else:
    var baseA = abs
    var baseD = d.file
    var i = 0
    var cut = -1
    while i < baseA.len:
      if baseA[i] == '/': cut = i
      inc i
    let stemA = if cut >= 0: baseA[cut + 1 ..< baseA.len] else: baseA
    cut = -1
    i = 0
    while i < baseD.len:
      if baseD[i] == '/': cut = i
      inc i
    let stemD = if cut >= 0: baseD[cut + 1 ..< baseD.len] else: baseD
    if stemA == stemD: p = abs
    else: p = d.file
  var content = ""
  try:
    content = readFile(p)
  except:
    return @[]
  for l in splitLines(content): result.add l

proc renderDiag*(d: Diagnostic, abs, nimFile: string) =
  ## rustc style: a severity-coloured header, a dim gutter, one line of context
  ## each side, a caret underline, and any help notes under a `=` marker.
  let header = bold(severityColor(d.severity, d.severity)) &
    (if d.code.len > 0: gray("[" & d.code & "]") else: "") & ": " & d.message
  let src = readSourceLines(d, abs, nimFile)
  let target = d.line - 1
  if src.len == 0 or target < 0 or target >= src.len:
    stderr.writeLine "  " & severityColor(d.severity,
      d.file & ":" & $d.line & ":" & $d.col & ":") & " " & header
    for h in d.helps:
      stderr.writeLine "  " & gray("= " & h.kind & ": " & h.text)
    return

  var lo = target - 1
  if lo < 0: lo = 0
  var hi = target + 1
  if hi > src.len - 1: hi = src.len - 1
  let gw = ($(hi + 1)).len
  let rail = repeat(' ', gw) & " " & gray(GBar)

  stderr.writeLine header
  stderr.writeLine repeat(' ', gw) & " " & gray("┌─ ") &
    gray(d.file & ":" & $d.line & ":" & $d.col)
  stderr.writeLine rail
  var i = lo
  while i <= hi:
    let num = $(i + 1)
    let padded = repeat(' ', gw - num.len) & num
    if i == target:
      stderr.writeLine dim(padded) & " " & gray(GBar) & " " & hlNim(src[i])
      let span = caretSpan(d, src[i])
      var indent = d.col - 1
      if indent < 0: indent = 0
      stderr.writeLine rail & " " & repeat(' ', indent) &
        severityColor(d.severity, repeat('^', span)) & " " &
        severityColor(d.severity, d.message)
    else:
      stderr.writeLine dim(padded & " " & GBar & " " & src[i])
    inc i
  for h in d.helps:
    stderr.writeLine repeat(' ', gw) & " " & gray("= " & h.kind & ": " & h.text)
