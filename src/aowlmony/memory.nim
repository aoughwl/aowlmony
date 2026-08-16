## `verify --memory` — dangling pointers and use-after-free.
##
## A pointer goes dangling when the storage it names is destroyed while the
## pointer itself is still live. `--fin` is what makes that observable: it routes
## the module through the destroyer, so `=destroy` really runs at scope exit
## instead of the program leaking quietly to the end.
##
## Neither half of the toolchain can answer this alone, which is the whole design
## of the check. The `--fin --trace` run knows a destructor ran and where, but
## renders every object argument as `(object)` — NO IDENTITY — so it cannot say
## which storage died or who still points at it. The `.s.aif` has the identities
## and the scopes but no idea which paths execute. So: find the dangling pointer
## STRUCTURALLY in the artifact, then ask the `--fin` run to WITNESS it, and
## label each finding by how much of it was actually observed.
##
## This module is the structural half plus the witness test. The rendering lives
## with the other reporting in `aowlmony.nim`.

{.feature: "lenientnils".}
## ⚠️ A `ref` is NON-NILABLE in nimony by default, and this module is a tree
## walker: "this node has no 4th child", "we are not inside a routine" and "the
## artifact ended" are all genuinely absent values, not defaults. Spelling them
## as an absent ref is the honest shape; the alternative is a parallel `has…`
## bool beside every node field, which is the same nil with more places to
## forget it.

import std/[syncio, strutils, tables]
import tools, stage, verify

type
  Pos* = object
    file*: string
    line*, col*: int

  NodeKind = enum
    nkAtom, nkNode

  NifNode* = ref object
    kind*: NodeKind
    text*: string        ## the atom's text, or the node's tag
    pos*: Pos
    kids*: seq[NifNode]

  Finding* = object
    isEscape*: bool
    ptrName*: string
    target*: string
    alloc*: Pos
    freeAt*: Pos
    opened*: Pos
    hasOpened*: bool
    use*: Pos
    routine*: string
    ## witness, filled in by `witnessFinding`
    destroyed*: bool
    reachedUse*: bool
    confirmed*: bool

  MemStats* = object
    sites*: int          ## address-taking expressions in the entry module
    tracked*: int        ## …of those, bound to a named pointer we follow
    scopes*: int

  MemResult* = object
    findings*: seq[Finding]
    stats*: MemStats

# --------------------------------------------------------------------------
# a minimal NIF reader (tokens -> tree with absolute source positions)
#
# The driver has always consumed NIF artifacts, but only ever regexed them.
# This check needs real structure — which scope a variable belongs to, which
# expression took its address — so this is an actual reader.
#
# ⭐ Line info is the part worth stating: every token may carry an
# `@col,line,file` suffix whose numbers are base62 deltas RELATIVE TO THE
# ENCLOSING PARENT NODE — not to the previous sibling — a leading `~` negates,
# and a filename makes the position absolute rather than a delta. Columns are
# 0-based in the stream. Mirrors nifreader's handleLineInfo.
# --------------------------------------------------------------------------

proc b62(c: char): int =
  ## -1 when the character is not a base62 digit.
  let k = ord(c)
  if k >= 48 and k <= 57: k - 48        # 0-9 -> 0..9
  elif k >= 65 and k <= 90: k - 55      # A-Z -> 10..35
  elif k >= 97 and k <= 122: k - 61     # a-z -> 36..61
  else: -1

type Suffix = object
  has: bool
  col, line: int
  file: string

proc splitAtom(tok: string): (string, Suffix) =
  ## One raw token -> its text and its decoded line-info suffix. The search for
  ## the `@`/`~` starts AFTER any quoted literal, so an `@` inside a string is
  ## never mistaken for line info.
  var start = 0
  if tok.len > 0 and (tok[0] == '"' or tok[0] == '\''):
    let q = tok[0]
    var j = 1
    while j < tok.len and tok[j] != q:
      if tok[j] == '\\': inc j
      inc j
    start = j + 1
    if start > tok.len: start = tok.len

  var at = -1
  var k = start
  while k < tok.len:
    if tok[k] == '@' or tok[k] == '~':
      at = k
      break
    inc k
  if at < 0: return (tok, Suffix(has: false, col: 0, line: 0, file: ""))

  var s = tok[at ..< tok.len]
  if s.len > 0 and s[0] == '@': s = s[1 ..< s.len]
  var i = 0

  # one base62 integer, `~` negating
  var neg = false
  if i < s.len and s[i] == '~':
    neg = true
    inc i
  var col = 0
  while i < s.len and b62(s[i]) >= 0:
    col = col * 62 + b62(s[i])
    inc i
  if neg: col = -col

  var line = 0
  var file = ""
  if i < s.len and s[i] == ',':
    inc i
    neg = false
    if i < s.len and s[i] == '~':
      neg = true
      inc i
    while i < s.len and b62(s[i]) >= 0:
      line = line * 62 + b62(s[i])
      inc i
    if neg: line = -line
  if i < s.len and s[i] == ',':
    file = s[i + 1 ..< s.len]

  (tok[0 ..< at], Suffix(has: true, col: col, line: line, file: file))

proc posFrom(parent: Pos, suf: Suffix): Pos =
  ## A suffix carrying a filename is ABSOLUTE; otherwise it is a delta on the
  ## enclosing node's position.
  if not suf.has: parent
  elif suf.file.len > 0: Pos(file: suf.file, line: suf.line, col: suf.col)
  else: Pos(file: parent.file, line: parent.line + suf.line,
            col: parent.col + suf.col)

proc isSpace(c: char): bool =
  c == ' ' or c == '\n' or c == '\r' or c == '\t'

proc nifParse*(text: string): seq[NifNode] =
  ## The whole artifact as top-level forms. `.` (the omitted slot) stays an
  ## ordinary atom, so declarations keep their fixed child-slot layout by index.
  result = @[]
  var stack: seq[NifNode] = @[]
  let root = Pos(file: "", line: 0, col: 0)
  var i = 0
  let n = text.len
  while i < n:
    let c = text[i]
    if isSpace(c):
      inc i
      continue
    if c == ')':
      if stack.len > 0: discard stack.pop()
      inc i
      continue
    let open = c == '('
    if open: inc i
    var j = i
    if not open and j < n and (text[j] == '"' or text[j] == '\''):
      let q = text[j]
      inc j
      while j < n and text[j] != q:
        if text[j] == '\\': inc j
        inc j
      inc j                                  # past the closing quote…
    while j < n and not isSpace(text[j]) and text[j] != '(' and text[j] != ')':
      inc j                                  # …then any line-info suffix
    if j > n: j = n
    let parts = splitAtom(text[i ..< j])
    var parentPos = root
    if stack.len > 0: parentPos = stack[stack.len - 1].pos
    let p = posFrom(parentPos, parts[1])
    let nd = NifNode(kind: (if open: nkNode else: nkAtom), text: parts[0],
                     pos: p, kids: @[])
    if stack.len > 0: stack[stack.len - 1].kids.add nd
    else: result.add nd
    if open: stack.add nd
    i = j

# --------------------------------------------------------------------------
# the analysis
# --------------------------------------------------------------------------

const
  NifVars = ["var", "let", "cursor", "gvar", "glet", "tvar", "tlet", "const"]
  NifAddr = ["addr", "haddr"]
  ## projections: expressions naming storage INSIDE some root variable, so the
  ## address of any of them dangles exactly when the root variable does.
  NifProj = ["dot", "ddot", "at", "arrat", "tupat", "pat", "deref", "hderef",
             "conv", "hconv", "cast", "baseobj"]
  NifRoutine = ["proc", "func", "method", "converter", "iterator", "macro",
                "template"]
  ## nodes owning a nested scope: a `stmts` directly under one of these belongs
  ## to that construct, and is reported as "the block opened at <its line>".
  NifOwner = ["block", "while", "for", "if", "elif", "else", "of", "case",
              "try", "except", "fin", "finally", "scope"]

proc oneOf(s: string, xs: openArray[string]): bool =
  result = false
  for x in xs:
    if x == s: return true

type
  Scope = object
    parent: int          ## index into MemCtx.scopes; -1 for the root
    vars: seq[string]
    exitAt: Pos
    hasExit: bool
    opened: Pos
    hasOpened: bool
    inRoutine: bool

  Borrow = object
    target: string
    at: Pos
    hasAt: bool

  DeadPtr = object
    target: string
    alloc: Pos
    freeAt: Pos
    opened: Pos
    hasOpened: bool

  MemCtx = object
    scopes: seq[Scope]
    declScope: Table[string, int]
    declPos: Table[string, Pos]
    borrow: Table[string, Borrow]
    dead: Table[string, DeadPtr]
    live: Table[string, bool]
    reported: Table[string, bool]
    findings: seq[Finding]
    stats: MemStats
    absSrc: string
    stageDir: string

proc inEntry(c: MemCtx, p: Pos): bool =
  ## Is this position in the module the user asked about? Positions in an
  ## artifact are written relative to the stage, so they are resolved the same
  ## way the cache resolves a module's own source path.
  if p.file.len == 0: return false
  absolutise(c.stageDir, p.file) == c.absSrc

proc isIdent(s: string): bool =
  if s.len == 0: return false
  let c0 = s[0]
  if not ((c0 >= 'A' and c0 <= 'Z') or (c0 >= 'a' and c0 <= 'z') or c0 == '_'):
    return false
  for ch in s:
    let okCh = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
               (ch >= '0' and ch <= '9') or ch == '_' or ch == '.'
    if not okCh: return false
  true

proc rootSym(x: NifNode): string =
  ## The variable whose storage this expression names, "" when it names none.
  if x == nil: return ""
  if x.kind == nkAtom:
    return (if isIdent(x.text): x.text else: "")
  if oneOf(x.text, NifProj) and x.kids.len > 0: return rootSym(x.kids[0])
  ""

proc symName*(s: string): string =
  ## The source-level name: everything before the mangling dot.
  let d = find(s, '.')
  if d < 0: s else: s[0 ..< d]

proc borrowOf(c: MemCtx, x: NifNode): Borrow =
  ## Does `x` yield the address of some variable's storage? Either directly
  ## (`addr v`, `addr v.field`) or by copying a pointer that already holds one.
  ##
  ## `at` is where the address was TAKEN, and carrying it matters: a lowered
  ## `ret` often has no line info of its own and inherits the ROUTINE's, so
  ## anchoring an escaping-address report on the `ret` would point at
  ## `proc mk(…)` instead of the line that actually leaks the address.
  result = Borrow(target: "", at: Pos(file: "", line: 0, col: 0), hasAt: false)
  if x == nil: return
  if x.kind == nkAtom:
    if hasKey(c.borrow, x.text):
      let b = getOrDefault(c.borrow, x.text)
      return Borrow(target: b.target, at: b.at, hasAt: b.hasAt)
    return
  if oneOf(x.text, NifAddr):
    if x.kids.len > 0:
      let t = rootSym(x.kids[0])
      if t.len > 0:
        return Borrow(target: t, at: x.kids[0].pos, hasAt: true)
    return
  if oneOf(x.text, NifProj) and x.kids.len > 0:
    return borrowOf(c, x.kids[0])

proc useSym(c: var MemCtx, sym: string, p: Pos) =
  if not hasKey(c.dead, sym): return
  if not inEntry(c, p): return
  let key = sym & "@" & $p.line & ":" & $p.col
  if hasKey(c.reported, key): return
  c.reported[key] = true
  let d = getOrDefault(c.dead, sym)
  c.findings.add Finding(isEscape: false, ptrName: symName(sym),
    target: symName(d.target), alloc: d.alloc, freeAt: d.freeAt,
    opened: d.opened, hasOpened: d.hasOpened, use: p, routine: "",
    destroyed: false, reachedUse: false, confirmed: false)

proc mark(c: var MemCtx, scope: int, p: Pos) =
  ## The furthest point reached inside a scope — where "the end of this scope"
  ## is, for reporting.
  if scope < 0: return
  if not inEntry(c, p): return
  if (not c.scopes[scope].hasExit) or p.line > c.scopes[scope].exitAt.line:
    c.scopes[scope].exitAt = p
    c.scopes[scope].hasExit = true

proc closeScope(c: var MemCtx, scope: int) =
  ## Leaving a scope destroys everything declared in it. Any pointer that
  ## OUTLIVES the scope and holds one of those addresses is dangling from here.
  let vars = c.scopes[scope].vars
  for v in vars:
    if hasKey(c.live, v): c.live[v] = false
    if not hasKey(c.declPos, v): continue
    if not inEntry(c, getOrDefault(c.declPos, v)): continue
    for p, b in pairs(c.borrow):
      if b.target != v: continue
      if not getOrDefault(c.live, p, false): continue   # a pointer that dies too is fine
      if hasKey(c.declScope, p) and getOrDefault(c.declScope, p, -1) == scope: continue
                                                           # …including one from this very scope
      var freeAt = c.scopes[scope].opened
      if c.scopes[scope].hasExit: freeAt = c.scopes[scope].exitAt
      c.dead[p] = DeadPtr(target: v, alloc: getOrDefault(c.declPos, v), freeAt: freeAt,
                          opened: c.scopes[scope].opened,
                          hasOpened: c.scopes[scope].hasOpened)
  if c.scopes[scope].parent >= 0 and c.scopes[scope].hasExit:
    mark(c, c.scopes[scope].parent, c.scopes[scope].exitAt)

proc walk(c: var MemCtx, x: NifNode, scope: int, routine: NifNode,
          owner: Pos, hasOwner: bool) =
  if x == nil: return
  if x.kind == nkAtom:
    mark(c, scope, x.pos)
    useSym(c, x.text, x.pos)
    return
  mark(c, scope, x.pos)
  let tag = x.text
  if oneOf(tag, NifAddr) and inEntry(c, x.pos): inc c.stats.sites

  if tag == "stmts" or tag == "scope":
    if inEntry(c, x.pos): inc c.stats.scopes
    var opened = x.pos
    var hasOpened = true
    if hasOwner: opened = owner
    c.scopes.add Scope(parent: scope, vars: @[],
                       exitAt: Pos(file: "", line: 0, col: 0), hasExit: false,
                       opened: opened, hasOpened: hasOpened,
                       inRoutine: routine != nil)
    let inner = c.scopes.len - 1
    let kids = x.kids
    for k in kids:
      walk(c, k, inner, routine, x.pos, oneOf(tag, NifOwner))
    closeScope(c, inner)
    return

  if oneOf(tag, NifRoutine):
    let kids = x.kids
    for k in kids:
      walk(c, k, scope, x, x.pos, true)
    return

  if oneOf(tag, NifVars):
    # (var :sym export pragmas Type value) — the value is slot 4.
    var name: NifNode = nil
    var init: NifNode = nil
    if x.kids.len > 0: name = x.kids[0]
    if x.kids.len > 4: init = x.kids[4]
    if init != nil: walk(c, init, scope, routine, x.pos, true)
    if name != nil and name.kind == nkAtom and name.text.len > 1 and
       name.text[0] == ':':
      let sym = name.text[1 ..< name.text.len]
      c.declScope[sym] = scope
      c.declPos[sym] = name.pos
      c.scopes[scope].vars.add sym
      c.live[sym] = true
      if hasKey(c.dead, sym): del(c.dead, sym)
      if hasKey(c.borrow, sym): del(c.borrow, sym)
      let b = borrowOf(c, init)
      if b.target.len > 0:
        c.borrow[sym] = b
        if inEntry(c, name.pos): inc c.stats.tracked
    return

  if tag == "asgn":
    var lhs: NifNode = nil
    var rhs: NifNode = nil
    if x.kids.len > 0: lhs = x.kids[0]
    if x.kids.len > 1: rhs = x.kids[1]
    if rhs != nil: walk(c, rhs, scope, routine, x.pos, true)
    var sym = ""
    if lhs != nil and lhs.kind == nkAtom: sym = rootSym(lhs)
    if sym.len > 0:
      # a whole-variable assignment REBINDS: it clears any dangling state and
      # installs whatever the right-hand side borrows.
      if hasKey(c.dead, sym): del(c.dead, sym)
      if hasKey(c.borrow, sym): del(c.borrow, sym)
      mark(c, scope, lhs.pos)
      let b = borrowOf(c, rhs)
      if b.target.len > 0:
        c.borrow[sym] = b
        if inEntry(c, lhs.pos): inc c.stats.tracked
    elif lhs != nil:
      walk(c, lhs, scope, routine, x.pos, true)
    return

  if tag == "ret" and routine != nil:
    # Returning the address of something this routine owns: it dies as the
    # routine returns, so the caller receives a pointer that is already
    # dangling. Reported at the site of the `addr`, not the `ret` — see
    # borrowOf.
    var arg: NifNode = nil
    if x.kids.len > 0: arg = x.kids[0]
    let b = borrowOf(c, arg)
    let t = b.target
    if t.len > 0 and getOrDefault(c.live, t, false) and
       hasKey(c.declScope, t) and c.scopes[getOrDefault(c.declScope, t, 0)].inRoutine and
       hasKey(c.declPos, t) and inEntry(c, getOrDefault(c.declPos, t)) and
       b.hasAt and inEntry(c, b.at):
      let key = "ret:" & t & "@" & $b.at.line
      if not hasKey(c.reported, key):
        c.reported[key] = true
        var rname = ""
        if routine.kids.len > 0 and routine.kids[0].kind == nkAtom and
           routine.kids[0].text.len > 1 and routine.kids[0].text[0] == ':':
          rname = symName(routine.kids[0].text[1 ..< routine.kids[0].text.len])
        c.findings.add Finding(isEscape: true, ptrName: symName(t),
          target: symName(t), alloc: getOrDefault(c.declPos, t), freeAt: b.at,
          opened: routine.pos, hasOpened: true, use: b.at, routine: rname,
          destroyed: false, reachedUse: false, confirmed: false)

  let kids = x.kids
  for k in kids:
    walk(c, k, scope, routine, x.pos, oneOf(tag, NifOwner))

proc sortFindings(xs: var seq[Finding]) =
  var i = 0
  while i < xs.len:
    var j = i + 1
    while j < xs.len:
      let earlier = xs[j].use.line < xs[i].use.line or
                    (xs[j].use.line == xs[i].use.line and
                     xs[j].use.col < xs[i].use.col)
      if earlier:
        let tmp = xs[i]
        xs[i] = xs[j]
        xs[j] = tmp
      inc j
    inc i

proc memoryFindings*(nifText, absSrc, stageDir: string): MemResult =
  ## Findings, each with an allocation site, the point the storage was
  ## destroyed, and the site that used the pointer afterwards.
  ##
  ## ⚠️ The stats are part of the RESULT, not decoration. A checker whose walk
  ## never reached the entry module reports "clean" for exactly the same reason
  ## a sound program does — so `sites == 0` has to be said out loud rather than
  ## dressed up as a verdict that was never computed.
  var c = MemCtx(scopes: @[], declScope: initTable[string, int](),
                 declPos: initTable[string, Pos](),
                 borrow: initTable[string, Borrow](),
                 dead: initTable[string, DeadPtr](),
                 live: initTable[string, bool](),
                 reported: initTable[string, bool](),
                 findings: @[],
                 stats: MemStats(sites: 0, tracked: 0, scopes: 0),
                 absSrc: absSrc, stageDir: stageDir)
  c.scopes.add Scope(parent: -1, vars: @[],
                     exitAt: Pos(file: "", line: 0, col: 0), hasExit: false,
                     opened: Pos(file: "", line: 0, col: 0), hasOpened: false,
                     inRoutine: false)
  let forms = nifParse(nifText)
  for f in forms:
    if f.kind == nkNode and f.text == "stmts":
      walk(c, f, 0, nil, Pos(file: "", line: 0, col: 0), false)
  closeScope(c, 0)
  sortFindings(c.findings)
  MemResult(findings: c.findings, stats: c.stats)

# --------------------------------------------------------------------------
# the witness
# --------------------------------------------------------------------------

proc witnessFinding*(f: var Finding, ops: seq[Op], base: string) =
  ## Did the `--fin` run actually observe this? Two independent halves: a
  ## destructor that ran at the scope whose exit we blamed, and the use site
  ## being reached at all. A finding with neither is still a defect — it just
  ## was not on this run's path, and the report must not pretend otherwise.
  if f.isEscape:
    # The leak is the return itself, so the witness is simply "the routine ran"
    # — the `addr` line is usually an assignment, which is a step and not a
    # call, and would never appear in a call trace however often it executed.
    var ran = false
    if f.routine.len > 0:
      for op in ops:
        if op.file == base and op.callee == f.routine:
          ran = true
          break
    var reached = ran
    if not reached:
      for op in ops:
        if op.file == base and op.line == f.use.line:
          reached = true
          break
        for ch in op.chain:
          if ch.file == base and ch.line == f.use.line:
            reached = true
            break
        if reached: break
    f.destroyed = ran
    f.reachedUse = reached
    f.confirmed = ran
    return

  var lo = f.freeAt.line
  if f.hasOpened and f.opened.line < lo: lo = f.opened.line
  var destroyed = false
  for op in ops:
    if op.file == base and op.callee.startsWith("=destroy") and
       op.line >= lo and op.line <= f.freeAt.line:
      destroyed = true
      break
  var reached = false
  for op in ops:
    if op.file == base and op.line == f.use.line:
      reached = true
      break
    for ch in op.chain:
      if ch.file == base and ch.line == f.use.line:
        reached = true
        break
    if reached: break
  f.destroyed = destroyed
  f.reachedUse = reached
  f.confirmed = destroyed and reached
