## Which executable performs each stage of the pipeline.
##
## Precedence, highest first:
##   AOWLMONY_* env  →  aowlmony.config.json in the cwd  →  the aowlup registry
##   →  a dev probe across the rename family
##
## The registry is read through `aowlup config`, never by parsing
## ~/.aowl/registry.json ourselves: **aowlup writes that file, the driver only
## ever reads it**, and going through the manager's own accessor is what keeps
## the two tools from disagreeing about which binary is "the" binary.

import std/[syncio, strutils, envvars, json, os]
import aowlkit/subprocess

type Tools* = object
  nimony*: string
  niflerReal*: string
  nimsemReal*: string     ## reused ONLY as the mechanical .s.nif → .s.idx.nif indexer
  aowlsem*: string        ## our semantic checker, injected via a nimsem shim
  nifparser*: string      ## our parser
  aowlsuggest*: string    ## our quick-fix layer, consulted on a compile failure
  interp*: string
  vm*: string
  native*: string
  hexer*: string          ## our lowering pass
  ts*: string
  js*: string
  py*: string
  profile*: string
  parserVariant*: string
  hexerVariant*: string
  semVariant*: string

proc homeDir*(): string =
  let h = getEnv("HOME", "")
  if h.len > 0: h else: "/root"

proc fileExists*(p: string): bool =
  var f: File
  if open(f, p, fmRead):
    close(f)
    true
  else:
    false

proc allPrefixes*(name: string): seq[string] =
  ## The ecosystem renamed nif* → aif* → aowl*, and a dev box can still carry a
  ## repo whose directory and binary disagree (~/aifparser/bin/aowlparser).
  ## Newest spelling first.
  if name.startsWith("nif"):
    let stem = name[3 ..< name.len]
    @["aowl" & stem, "aif" & stem, name]
  else:
    @[name]

proc firstExisting*(cands: seq[string]): string =
  ## "" when nothing exists — NOT the last candidate. A resolver that invents a
  ## plausible path turns "you have not built this" into a confusing failure
  ## much further downstream.
  for c in cands:
    if c.len > 0 and fileExists(c): return c
  ""

proc repoBin*(base: string, suffix = ""): seq[string] =
  ## ~/<repo>/bin/<bin><suffix> across the rename family, in both positions.
  result = @[]
  let home = homeDir()
  let names = allPrefixes(base)
  for repo in names:
    for b in names:
      result.add home & "/" & repo & "/bin/" & b & suffix

proc parserCandidates*(): seq[string] =
  result = @[]
  let home = homeDir()
  let names = allPrefixes("nifparser")
  for repo in names:
    for b in names:
      result.add home & "/" & repo & "/bin/" & b
  # also accept a not-yet-installed build sitting in the repo's nimcache
  for repo in names:
    let nc = home & "/" & repo & "/nimcache"
    let ls = runCaptured("ls", @[nc], "", false)
    if ls.ok and ls.exitCode == 0:
      for line in splitLines(ls.output):
        let d = strip(line)
        if d.len == 0: continue
        for b in names:
          result.add nc & "/" & d & "/" & b

# --------------------------------------------------------------------------
# the aowlup registry
# --------------------------------------------------------------------------

type Stack* = object
  profile*: string
  ok*: bool
  exes*: seq[(string, string)]      ## slot → exe
  variants*: seq[(string, string)]  ## slot → variant id

proc slotField(st: Stack, table: seq[(string, string)], slot: string): string =
  for kv in table:
    if kv[0] == slot: return kv[1]
  ""

proc exeOf*(st: Stack, slot: string): string = slotField(st, st.exes, slot)
proc variantOf*(st: Stack, slot: string): string = slotField(st, st.variants, slot)

proc loadStack*(): Stack =
  ## Ask the manager. Falls back to an empty stack so the driver still works on a
  ## machine with no ~/.aowl at all, exactly as it did before there was a manager.
  result = Stack(profile: "", ok: false, exes: @[], variants: @[])
  let home = homeDir()
  var manager = ""
  # the native manager first: it is the one that will ship as a release binary.
  for c in [home & "/aowlup/bin/aowlup-ng", home & "/aowlup/bin/aowlup",
            home & "/.aowl/bin/aowl"]:
    if fileExists(c):
      manager = c
      break
  if manager.len == 0: return

  let r = runCaptured(manager, @["config"], "", false)
  if not r.ok or r.exitCode != 0 or r.output.len == 0: return
  var tree: JsonTree
  try:
    tree = parseJson(r.output)
  except:
    return
  if hasError(tree): return
  for k, v in pairs(root(tree)):
    if k == "profile":
      result.profile = getStr(v, "")
    elif k == "slots":
      for slot, entry in pairs(v):
        for ek, ev in pairs(entry):
          if ek == "exe": result.exes.add (slot, getStr(ev, ""))
          elif ek == "variant": result.variants.add (slot, getStr(ev, ""))
  result.ok = true

# --------------------------------------------------------------------------
# project config
# --------------------------------------------------------------------------

proc loadProjectConfig*(): seq[(string, string)] =
  ## aowlmony.config.json (or the deprecated aifmony.config.json) in the cwd.
  result = @[]
  for name in ["aowlmony.config.json", "aifmony.config.json"]:
    if not fileExists(name): continue
    var tree: JsonTree
    try:
      tree = parseFile(name)
    except:
      continue
    if hasError(tree): continue
    for k, v in pairs(root(tree)):
      let s = getStr(v, "")
      if s.len > 0: result.add (k, s)
    break

proc cfgGet(cfg: seq[(string, string)], key: string): string =
  for kv in cfg:
    if kv[0] == key: return kv[1]
  ""

proc pick(envName, key: string, cfg: seq[(string, string)], fallback: string): string =
  ## env (with the deprecated AIFMONY_ alias) → config file → caller's fallback.
  let e = getEnv(envName, "")
  if e.len > 0: return e
  if envName.startsWith("AOWLMONY_"):
    let alias = "AIFMONY_" & envName[9 ..< envName.len]
    let a = getEnv(alias, "")
    if a.len > 0: return a
  let c = cfgGet(cfg, key)
  if c.len > 0: return c
  fallback

proc resolveTools*(): Tools =
  result = Tools(nimony: "", niflerReal: "", nimsemReal: "", aowlsem: "",
                 nifparser: "", aowlsuggest: "", interp: "", vm: "", native: "",
                 hexer: "", ts: "", js: "", py: "", profile: "",
                 parserVariant: "", hexerVariant: "", semVariant: "")
  let cfg = loadProjectConfig()
  let st = loadStack()
  let home = homeDir()

  result.nimony = pick("AOWLMONY_NIMONY", "nimony", cfg,
                       firstExisting(@[home & "/nimony/bin/nimony"]))
  result.niflerReal = pick("AOWLMONY_NIFLER", "nifler", cfg,
                           firstExisting(@[home & "/nimony/bin/nifler"]))
  result.nimsemReal = pick("AOWLMONY_NIMSEM", "nimsem", cfg,
                           firstExisting(@[home & "/nimony/bin/nimsem"]))
  # NB: do NOT seed this from the registry's sem slot — that slot holds the
  # ACTIVE variant's exe, which is nimony's own nimsem until the default flips.
  result.aowlsem = pick("AOWLMONY_AOWLSEM", "aowlsem", cfg,
                        firstExisting(@[home & "/aowlsem/bin/aowlsem"]))
  result.nifparser = pick("AOWLMONY_NIFPARSER", "nifparser", cfg,
                          firstExisting(parserCandidates()))
  result.aowlsuggest = pick("AOWLMONY_AOWLSUGGEST", "aowlsuggest", cfg,
    (if st.exeOf("suggest").len > 0: st.exeOf("suggest")
     else: firstExisting(@[home & "/aowlsuggest/bin/aowlsuggest"])))
  result.interp = pick("AOWLMONY_NIFI", "nifiInterp", cfg,
    (if st.exeOf("interp").len > 0: st.exeOf("interp")
     else: firstExisting(repoBin("nifi", "-interp"))))
  result.vm = pick("AOWLMONY_NIFI_VM", "nifiVm", cfg,
    (if st.exeOf("vm").len > 0: st.exeOf("vm")
     else: firstExisting(repoBin("nifi", "-vm"))))
  result.native = pick("AOWLMONY_NIFC", "nifc", cfg,
    (if st.exeOf("native").len > 0: st.exeOf("native")
     else: firstExisting(repoBin("nifc"))))
  result.hexer = pick("AOWLMONY_HEXER", "aifhexer", cfg,
    firstExisting(@[home & "/aowlhexer/bin/aowlhexer",
                    home & "/aifhexer/bin/aifhexer"]))
  result.ts = pick("AOWLMONY_AOWLTS", "aowlts", cfg,
    (if st.exeOf("ts").len > 0: st.exeOf("ts") else: firstExisting(repoBin("nifts"))))
  result.js = pick("AOWLMONY_AOWLJS", "aowljs", cfg,
    (if st.exeOf("js").len > 0: st.exeOf("js") else: firstExisting(repoBin("nifjs"))))
  result.py = pick("AOWLMONY_AOWLPY", "aowlpy", cfg,
    (if st.exeOf("py").len > 0: st.exeOf("py") else: firstExisting(repoBin("nifpy"))))

  result.profile = if st.profile.len > 0: st.profile else: "hybrid"
  let pv = st.variantOf("parser")
  result.parserVariant = if pv.len > 0: pv else: "aowlparser"
  let hv = st.variantOf("hexer")
  result.hexerVariant = if hv.len > 0: hv else: "aowlhexer"
  # AOWLMONY_SEM forces the sem variant for one run, ahead of the registry —
  # so aowlsem can be exercised before the registry default flips.
  let envSem = getEnv("AOWLMONY_SEM", "")
  let sv = st.variantOf("sem")
  result.semVariant = if envSem.len > 0: envSem
                      elif sv.len > 0: sv
                      else: "nimsem"

  # A registry-resolved exe wins for a slot whose variant is OURS.
  if result.parserVariant == "aowlparser" and st.exeOf("parser").len > 0:
    result.nifparser = pick("AOWLMONY_NIFPARSER", "nifparser", cfg, st.exeOf("parser"))
  if result.hexerVariant == "aowlhexer" and st.exeOf("hexer").len > 0:
    result.hexer = pick("AOWLMONY_HEXER", "aifhexer", cfg, st.exeOf("hexer"))
