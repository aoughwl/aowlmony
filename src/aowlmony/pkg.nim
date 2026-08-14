## The package store and the lockfile.
##
## THE CONSTRAINT that shapes this, from DESIGN.md §6: a module's cache identity
## is a hash of its shortest relative path. Spell a dependency's directory
## differently between two builds and its identity — and its whole incremental
## cache — silently changes. So a dep must live at a STABLE, canonical path, and
## the only stable name available is one derived from its content.
##
##   ~/.aowl/pkg/<key>/          key = sha1(url \n rev)
##
## Two projects on the same revision therefore share one checkout and one warm
## cache, and a project that pins a revision gets the same path on every machine.
##
## `mony.lock` records what was resolved, so a later build reproduces it without
## asking the network what "the tag" means today.

import std/[syncio, strutils, envvars, os]
import aowlkit/subprocess
import stage, project

type Resolved* = object
  name*: string
  source*: string   ## "path" | "git"
  url*: string
  rev*: string      ## the exact commit, never a moving tag
  dir*: string      ## where it landed on disk
  ok*: bool
  err*: string

proc storeDir*(): string =
  let e = getEnv("AOWL_HOME", "")
  let home = if e.len > 0: e else: getEnv("HOME", "") & "/.aowl"
  home & "/pkg"

proc dirExists(p: string): bool =
  let r = runCaptured("test", @["-d", p], "", false)
  r.ok and r.exitCode == 0

proc lockPath*(p: Project): string = p.root & "/mony.lock"

proc readLock*(p: Project): seq[Resolved] =
  ## `name source url rev` per line. Deliberately a flat text format: it is read
  ## by humans in review far more often than by anything else.
  result = @[]
  var content = ""
  try:
    content = readFile(lockPath(p))
  except:
    return
  for raw in splitLines(content):
    let line = strip(raw)
    if line.len == 0 or line[0] == '#': continue
    var fields: seq[string] = @[]
    for f in split(line, ' '):
      if f.len > 0: fields.add f
    if fields.len < 4: continue
    result.add Resolved(name: fields[0], source: fields[1], url: fields[2],
                        rev: fields[3], dir: "", ok: true, err: "")

proc writeLock*(p: Project, rs: seq[Resolved]) =
  var s = "# mony.lock — resolved dependencies. Generated; edit mony.toml instead.\n" &
          "# name source url rev\n"
  for r in rs:
    if not r.ok: continue
    s.add r.name & " " & r.source & " " & (if r.url.len > 0: r.url else: "-") &
      " " & (if r.rev.len > 0: r.rev else: "-") & "\n"
  try:
    writeFile(lockPath(p), s)
  except:
    discard

proc lockedRev(locked: seq[Resolved], name, url: string): string =
  for l in locked:
    if l.name == name and (l.url == url or url.len == 0): return l.rev
  ""

proc remoteRev(url, want: string): string =
  ## Ask the remote what a tag or branch points at, ONCE, and record it. A build
  ## that re-resolves a moving tag every time is not reproducible, and the day it
  ## moves is the day the failure looks like a compiler bug.
  var args = @["ls-remote", url]
  if want.len > 0: args.add want
  let r = runCaptured("git", args, "", false)
  if not r.ok or r.exitCode != 0: return ""
  for line in splitLines(r.output):
    let t = strip(line)
    if t.len == 0: continue
    let sp = find(t, '\t')
    if sp > 0: return t[0 ..< sp]
    let sp2 = find(t, ' ')
    if sp2 > 0: return t[0 ..< sp2]
  ""

proc fetchGit(name, url, rev: string): Resolved =
  result = Resolved(name: name, source: "git", url: url, rev: rev, dir: "",
                    ok: false, err: "")
  if rev.len == 0:
    result.err = "could not resolve a revision"
    return
  let key = sha1Hex(url & "\n" & rev)[0 ..< 16]
  let dir = storeDir() & "/" & key
  result.dir = dir
  if dirExists(dir & "/.git"):
    result.ok = true
    return
  discard execShellCmd("mkdir -p " & quoteShell(storeDir()))
  # clone then checkout the exact rev: --branch takes a name, and a name is what
  # we are deliberately not trusting twice.
  let c = runCaptured("git", @["clone", "--quiet", url, dir], "", true)
  if not c.ok or c.exitCode != 0:
    result.err = "clone failed"
    discard execShellCmd("rm -rf " & quoteShell(dir))
    return
  let co = runCaptured("git", @["-C", dir, "checkout", "--quiet", rev], "", true)
  if not co.ok or co.exitCode != 0:
    result.err = "no such revision " & rev[0 ..< 8]
    discard execShellCmd("rm -rf " & quoteShell(dir))
    return
  result.ok = true

proc resolveDeps*(p: Project, offline = false): seq[Resolved] =
  ## Path deps resolve locally; git deps resolve through the store. A version
  ## dep needs the index, which does not exist yet — it is reported, not guessed.
  result = @[]
  if not p.found: return
  let locked = readLock(p)
  for d in p.deps:
    if d.path.len > 0:
      result.add Resolved(name: d.name, source: "path", url: d.path, rev: "",
                          dir: absDep(p, d), ok: true, err: "")
    elif d.git.len > 0:
      var rev = lockedRev(locked, d.name, d.git)
      if rev.len == 0 and not offline:
        rev = remoteRev(d.git, d.version)
      if rev.len == 0:
        result.add Resolved(name: d.name, source: "git", url: d.git, rev: "",
                            dir: "", ok: false,
                            err: (if offline: "not in mony.lock and offline"
                                  else: "could not resolve " &
                                        (if d.version.len > 0: d.version else: "HEAD")))
      else:
        result.add fetchGit(d.name, d.git, rev)
    else:
      result.add Resolved(name: d.name, source: "index", url: "", rev: "",
                          dir: "", ok: false,
                          err: "version deps need the package index, which does not exist yet")

proc depSearchPaths*(rs: seq[Resolved]): seq[string] =
  ## A dep's modules live in its src/ when it has one.
  result = @[]
  for r in rs:
    if not r.ok or r.dir.len == 0: continue
    if dirExists(r.dir & "/src"): result.add r.dir & "/src"
    else: result.add r.dir
