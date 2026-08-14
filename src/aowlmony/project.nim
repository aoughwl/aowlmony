## `mony.toml` — what makes a directory a project rather than a loose file.
##
## Shape (from DESIGN.md §6.1; implemented, not redesigned):
##
##   [package]
##   name    = "myapp"
##   version = "0.1.0"
##
##   [build]
##   entry   = "src/main.nim"
##   target  = "native"
##
##   [deps]
##   mylib = { path = "../mylib" }
##
## Only path deps resolve here. Version and git deps need the lockfile and the
## content-addressed store, which are a later stage — and a manifest that
## silently ignored them would be worse than one that says so out loud.

import std/[syncio, strutils]
import aowlkit/subprocess

type
  Dep* = object
    name*: string
    path*: string      ## "" unless this is a path dep
    git*: string
    version*: string
    resolvable*: bool  ## false for git/index deps until the store lands

  Project* = object
    found*: bool
    root*: string      ## the directory holding mony.toml
    name*: string
    version*: string
    entry*: string     ## "" when unset
    target*: string
    deps*: seq[Dep]

proc emptyProject*(): Project =
  Project(found: false, root: "", name: "", version: "", entry: "",
          target: "", deps: @[])

proc fileExists(p: string): bool =
  var f: File
  if open(f, p, fmRead):
    close(f)
    true
  else:
    false

proc unquote(s: string): string =
  let t = strip(s)
  if t.len >= 2 and ((t[0] == '"' and t[t.len - 1] == '"') or
                     (t[0] == '\'' and t[t.len - 1] == '\'')):
    t[1 ..< t.len - 1]
  else:
    t

proc inlineField(body, key: string): string =
  ## One `key = "value"` out of a `{ … }` inline table.
  for part in split(body, ','):
    let eq = find(part, '=')
    if eq < 0: continue
    if strip(part[0 ..< eq]) == key:
      return unquote(part[eq + 1 ..< part.len])
  ""

proc parseManifest*(path: string): Project =
  ## A deliberately small TOML reader: sections, `key = "value"`, and one level
  ## of inline table. Anything richer belongs to a real parser, and we would
  ## rather refuse a construct than guess at it.
  result = emptyProject()
  var content = ""
  try:
    content = readFile(path)
  except:
    return
  var section = ""
  for raw in splitLines(content):
    var line = strip(raw)
    let hash = find(line, '#')
    if hash == 0: continue
    if line.len == 0: continue
    if line[0] == '[':
      let close = find(line, ']')
      if close > 1: section = strip(line[1 ..< close])
      continue
    let eq = find(line, '=')
    if eq < 0: continue
    let key = strip(line[0 ..< eq])
    let valRaw = strip(line[eq + 1 ..< line.len])
    case section
    of "package":
      if key == "name": result.name = unquote(valRaw)
      elif key == "version": result.version = unquote(valRaw)
    of "build":
      if key == "entry": result.entry = unquote(valRaw)
      elif key == "target": result.target = unquote(valRaw)
    of "deps":
      var d = Dep(name: key, path: "", git: "", version: "", resolvable: false)
      if valRaw.len > 0 and valRaw[0] == '{':
        var body = valRaw
        let close = find(body, '}')
        if close > 0: body = body[1 ..< close]
        d.path = inlineField(body, "path")
        d.git = inlineField(body, "git")
        d.version = inlineField(body, "tag")
        if d.version.len == 0: d.version = inlineField(body, "version")
      else:
        d.version = unquote(valRaw)
      d.resolvable = d.path.len > 0
      result.deps.add d
    else: discard
  result.found = true

proc dirOf(p: string): string =
  var cut = -1
  var i = 0
  while i < p.len:
    if p[i] == '/': cut = i
    inc i
  if cut <= 0: "/" else: p[0 ..< cut]

proc findProject*(startDir: string): Project =
  ## Walk up from the starting directory, the way cargo finds Cargo.toml. A
  ## loose file with no manifest above it is still a perfectly good thing to
  ## compile — this returns `found: false` and the driver carries on.
  result = emptyProject()
  var dir = startDir
  var guard = 0
  while dir.len > 1 and guard < 64:
    let m = dir & "/mony.toml"
    if fileExists(m):
      result = parseManifest(m)
      result.root = dir
      return
    dir = dirOf(dir)
    inc guard

proc absDep*(p: Project, d: Dep): string =
  ## A path dep is relative to the manifest, not to the cwd.
  if d.path.len == 0: return ""
  if d.path[0] == '/': return d.path
  let r = runCaptured("readlink", @["-f", p.root & "/" & d.path], "", false)
  if r.ok and r.exitCode == 0: strip(r.output) else: p.root & "/" & d.path

proc searchPaths*(p: Project): seq[string] =
  ## `--path` for the project's own src/ and for each resolvable dep.
  ##
  ## A dep's modules live in its `src/` when it has one — `import mylib` must
  ## find `mylib/src/mylib.nim`, so pointing at the dep's ROOT resolves nothing.
  result = @[]
  if not p.found: return
  if dirExists(p.root & "/src"): result.add p.root & "/src"
  for d in p.deps:
    if not d.resolvable: continue
    let a = absDep(p, d)
    if a.len == 0: continue
    if dirExists(a & "/src"): result.add a & "/src"
    else: result.add a

proc dirExists*(p: string): bool =
  let r = runCaptured("test", @["-d", p], "", false)
  r.ok and r.exitCode == 0

proc userSources*(p: Project): seq[string] =
  ## Every `.nim` inside the project and its path deps. This is what makes the
  ## whole project go through OUR parser instead of only the entry module — the
  ## previous driver set a single path here even though the shim already read a
  ## list, so a multi-file program was mostly parsed by nifler while the
  ## provenance line claimed otherwise.
  result = @[]
  if not p.found: return
  var roots = @[p.root]
  for d in p.deps:
    if not d.resolvable: continue
    let a = absDep(p, d)
    if a.len > 0: roots.add a
  for r in roots:
    let found = runCaptured("find", @[r, "-name", "*.nim", "-type", "f"], "", false)
    if not found.ok or found.exitCode != 0: continue
    for line in splitLines(found.output):
      let f = strip(line)
      if f.len > 0: result.add f

proc unresolvedDeps*(p: Project): seq[string] =
  result = @[]
  for d in p.deps:
    if not d.resolvable: result.add d.name
