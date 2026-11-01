# Owning the build sequence (driver spec, draft v0)

Status: spec only. Nothing here is implemented. Written 2026-10-31 from a real
cached run (`~/.aowl/cache/<hash>/nc/*.build.nif`).

## Why

Today both drivers (`bin/aowlmony` and `aowlmony-ng`) call the previous
compiler's driver binary to sequence a build (`build.nim`, the `compile` step).
Parser, semantic stage and lowering are already ours (`aowlup doctor`, profile
`aowl`), but the *sequencing* is not: module-graph discovery, the build graph,
and the executor that runs it. A machine without the previous stack cannot
compile anything until aowlmony owns this.

## What the previous driver does (observed)

1. Parse the main file. The parser's `--deps` sidecar (`<mod>.p.deps.nif`) lists
   the module's imports.
2. Walk imports transitively, resolving each to a source file (search paths,
   std lib, `-p:` paths) and a stable per-module name (hash-suffixed, e.g.
   `bui8a35sj1`).
3. Write a build graph file `<main>.build.nif`:

   ```
   (.nif27)
   (stmts
    (cmd :<tool> "<exe>" "<fixed args>" ... (input)(output) | (args))
    (do <tool> (args ...) (input "<path>")* (output "<path>")*)* )
   ```

   For a hello-world semantic phase: 84 nodes = 54 `parse` + 30 `sem`; paths use
   NIF escapes (`\3A` for `:`, `\5C` for `\`).
4. Run the graph with a make-style executor: a node runs when any input is newer
   than any output; independent nodes run in parallel (`-j`).
5. Repeat for later phases. CAPTURED (see "Later phases" below).

Per-module artifacts: `.p.nif` (parse), `.p.deps.nif` (imports), `.s.nif` and
`.s.idx.nif` (sem + public index), `.x.nif` (lowered), `.dce.nif`.

## What to build

- `graph`: module discovery + node generation for one phase. Pure function from
  (main file, config) to a graph file; no process spawning.
- `exec`: the executor. mtime staleness check, bounded parallelism, stops on the
  first failing node and prints that node's command and output.
- `phases`: ordered list (parse+sem, lower, dce, emit, cc) wiring `graph` and
  `exec`, handing the last step to aowlc and the C compiler.
- Config: search paths, defines, lib dirs, target; today read through the
  previous driver's config module.

## How to verify (no new oracle needed)

Differential, against files already on disk:

1. Pick one fixed small program and the cached `.build.nif` from a run of the
   previous driver.
2. Generate the graph with the new `graph` and compare node-for-node
   (order-insensitive, hashes/paths normalized). Mismatch = FAIL with the first
   differing node.
3. Run the new `exec` over the generated graph and compare produced `.s.nif`
   with the cached ones byte for byte.
4. Final gate: compile and run hello-world on a machine where the previous stack
   is absent. PASS only if the program prints its output; anything not run is
   INCONCLUSIVE.

## Milestones

- M1: `graph` reproduces the semantic-phase graph of one program.
- M2: `exec` runs it; `.s.nif` outputs match the oracle.
- M3: reproduce the later-phase graph (shape captured below; oracle files `*.final.build.nif`).
- M4: wire into both drivers; remove every call to the previous driver binary.
- M5: clean-machine hello-world; then compile the engine's `src/nif` and
  `src/interp`.

## Risks

- Hash-suffixed module names must match exactly or caches and index files
  diverge; get the naming function from a real run, not by guessing.
- aowlsem cannot yet semcheck its own `include`d files, so aowlsem will not
  compile itself through this driver until that is fixed (a separate task).
- The one-lane-per-checkout rule for the aowlsem checkout applies to anything
  run against it.

## Later phases (captured 2026-10-31 from a tiny program: 19 nodes)

File name: `<main>.final.build.nif`, same format as above. Tool definitions:

```
lengc    C emitter                 c --compileOnly --bits:64   (args)(input)
hexer    lowering                  c --bits:64 --cpu:le --flags:br
dce      dead-code pass            d ...
dceLive  merge liveness            dl ... (input many)(output live)
dceEmit  emit with liveness        de ...
cc       C compiler (gcc)          -c -O1 ... (input .c) -o (output .o)
link     linker for NIF objects    (input .linkmanifest + .o files)(output exe)
```

Per module M (main, system and every import), in dependency order:

1. `hexer`: inputs `M.s.nif` + the `.s.idx.nif` of its imports; outputs
   `M.x.nif`, `M.dce.nif` (the main module also takes `--isMain --app:console
   --outdir:<dir>`).
2. one `dceLive`: inputs every `*.dce.nif`; output `<main>/<main>.live.nif`.
3. `dceEmit` per module: inputs `M.x.nif` + live; output `<main>/M.c.nif`.
4. `lengc` per module: `--nimcache:<main dir>` (+ `--isMain` for main);
   `M.c.nif` -> `M.c`. In the aowl stack this is the aowlc step.
5. `cc` per module: `M.c` -> `M.o`; plus one `cc` for the vendored allocator
   (`static.c` -> `static.o`).
6. `link`: `<main>.linkmanifest.nif` + `static.o` + every `M.o` -> `<exe>`.

Only the tool executables differ between stacks; node shapes, inputs and outputs
are what the new graph generator must reproduce. Module names such as
`helszagi51` come from the naming function in the previous stack's `modnames`
(three letters of the file name + hash + digit); the engine's vendored copy is
`src/nif/gear2/modnames.nim` and is the reference to port.

## M1 progress

- Module names (`tools/driver/modname.js`): VERIFIED. The port reproduces all 12
  names tested against a cached run (11 std modules by their search-path-relative
  path, e.g. `std/system.nim` -> `sysvq0asl`; the main file by its path relative
  to the driver's working directory, e.g. `../../../AppData/.../hello2.nim` ->
  `helszagi51`). Consequence: the main module's name depends on the driver's cwd,
  so the generator must take cwd as an explicit input.
- Next: import resolution from `.p.deps.nif` (`(import (infix / std syncio))`,
  including `(when (call defined ...) ...)` conditional imports, so defines must
  be an explicit input), then node generation, then comparison with the oracle.

### M1 result (2026-10-31): PASS on two independent oracles

`tools/driver/run_oracles.sh` runs the generator (`graph.js`) against cached
graphs of the previous driver and compares node for node (tool, args in order,
inputs and outputs as sets, paths normalized):

- hello-world: 30 of 30 nodes match, 0 missing, 0 extra.
- a 84-module tool build: 84 of 84 nodes match, 0 missing, 0 extra.
- Negative control: with the generator deliberately broken the script exits
  non-zero; restored it exits 0. (An earlier draft of the script could not fail
  because its exit status came from `tail`; fixed.)

Rules the generator now encodes (each found by a failing comparison):
- Every module implicitly depends on `system`; load it first.
- `include` ignores `when` (unconditional) and silently skips files that do not
  exist; included files can include more files; an import that resolves to an
  included file depends on the owning module, not a new one.
- `import`/`fromimport` honor `when`: `defined(X)` against defines + OS/CPU
  names, `not`/`and`/`or`/`par`, true/false; anything unevaluable counts as TRUE.
  In `fromimport` only the first item is the module.
- Path forms: `std/[a, b]` expands to one module each; `(prefix ../ x)` is a
  relative parent import; `as` is ignored for resolution.
- The main module's name depends only on its path relative to the driver's cwd.

Not yet covered: running the parser to produce `.p.deps.nif` (M2); the `export`
construct; `when` conditions beyond `defined`; per-module config/passC; the
later-phase graph generator (M3).

New finding: the standard library sources (`lib/std/**`) live under the previous
stack's directory. aowlmony must own a copy of them (vendor into the aowlmony or
engine tree) before that directory can go.

### M3 result (2026-10-31): later-phase generator PASS on two oracles

`tools/driver/graph2.js` (`generateFinal`) reproduces the later-phase graphs
node for node: hello-world 19 of 19, the 84-module tool build 123 of 123, 0
missing and 0 extra. `tools/driver/run_oracles.sh` now runs all four comparisons
(two phase-1, two phase-2); with phase 2 deliberately broken it exits 1.

Rules found by failing comparisons:
- Lowering (`hexer`) inputs are the module's own `.s.nif` plus the `.s.idx.nif`
  of exactly the imports listed in its `.s.deps.nif` (what sem actually resolved,
  re-exports included), not the parser-level sidecar. So phase 2 can only be
  generated after phase 1 has run: it is a second graph, as in the previous driver.
- `system` also lowers against its own index.
- Main module artifacts live in `<nc>/<main>/`; every other module's `.x.nif` and
  `.dce.nif` live in `<nc>/`, and all `.c.nif`, `.c`, `.o` in `<nc>/<main>/`.
- One merged liveness node (`dceLive`) takes every `.dce.nif`, main first.
- The vendored allocator is compiled once (`static.c` -> `static.o`) and linked.

Next: M2 (run the parser to produce `.p.nif`/`.p.deps.nif`, and the executor that
runs a graph with staleness checks), then wire both phases together end to end
on a machine without the previous stack.

### M2 progress (2026-10-31): import sidecar derivation PASS

Our parser emits no `.p.deps` sidecar (the previous parser wrote it). The driver
derives it from the parse output: `tools/driver/deps_extract.js`. Verified on every
cached pair under `~/.aowl/cache`: 84 of 84 reproduced as trees (39 non-trivial,
45 legitimately empty), 0 mismatches; `run_oracles.sh` runs it and has a negative
control. Rules found by failing comparisons:
- Only `import`, `fromimport`, `include`, `export` are kept; nested `when`
  conditions are attached as a `(when cond...)` marker, in order, outermost first.
- A branch keeps only its own condition. An `else` after exactly one branch carries
  that branch's negation; an `else` after several carries nothing.
- Line-info decorations (`@..`, `~..`) are stripped; the sidecar is compared as a
  tree, not byte for byte (nothing but the driver reads it).

Still open for M2: the `.s.idx.nif` index (the previous stack's indexer produces
it from `.s.nif`; the aowlmony README says it is "reused as-is"), the `.s.deps.nif`
(what sem actually resolved), and the executor.

### M2 progress: our parser is a verified drop-in for library modules

`tools/driver/parser_sweep.js` runs `aowlparser p <module> <out>` on every library
module that has a cached parse output of the previous parser and compares the
trees (line info stripped): 54 modules, 164,769 tree nodes, 0 differences, 0
parser failures. Part of `run_oracles.sh` (negative control: a parser that
produces nothing exits 1). Caveat: only modules that were ever compiled and cached
are covered; a module no cache contains is not tested.

### M2: the `.s.idx.nif` index is fully specified (not yet implemented)

Everything the sem shim still takes from the previous stack is one mechanical step,
the index writer (`x`): `aowlsem m` does the semantic work and the old tool only
walks the result. Facts from its source and from cached outputs:

- File: `(.nif27)\n(index\n` + [converter section] + [export section] +
  `(checksum "<SHA1 hex>")\n)\n`. 29 of 38 cached indexes are just the checksum of
  an empty walk (`DA39A3EE5E6B4B0D3255BFEF95601890AFD80709`, SHA-1 of nothing).
- Converter section `(converter (kv <result type sym> <converter sym>)...)`: one
  entry per exported, non-instance converter at module top level.
- Export section: one `(fromexport "<abs path of source module>" name...)` per
  module an `export` statement re-exports from (the cached sample prints
  `(export "<path>")` for a module that re-exports whole modules).
- Checksum: SHA-1 over a token walk of the exported declarations only (let, var,
  const, type, gvar/gtvar..., templates/macros/iterators with bodies, procs/funcs/
  methods/converters with params and effects, bodies only when marked inline).
  Tokens hash as `(tag`, `)`, ` :symdef`, ` sym`, ` ident`, ` int`, ` string`, `.`.
- Needed to implement: a NIF token reader for sem output (the vendored reference is
  `src/nif/lib/nifreader.nim`, 619 lines) and the walk above (about 150 lines).
- Verification oracle: 38 cached index files (9 non-empty), plus the 84 modules'
  `.s.nif` inputs; the check is byte-for-byte equality of the produced `.s.idx.nif`.

### CORRECTION and result: aowlsem already produces the whole semantic phase

The earlier sections that call the `.s.idx.nif` writer and `.s.deps.nif` "still
the previous stack's" were wrong about the cause. `aowlsem m <in.p.nif> <out.s.nif>`
writes `<mod>.s.nif`, `<mod>.s.idx.nif` (converter and export sections, checksum;
`aowlsem.nim` mirrors the reference `createIndex` call) and `<mod>.s.deps.nif`
itself. The shim's extra `x` pass is redundant and the driver does not need it.

`tools/driver/sem_sweep.js` runs aowlsem on cached modules in a scratch copy and
compares with the reference outputs: index byte-identical and resolved-imports file
identical (ignoring the internal `.indexat` offset and `\5C` vs `/` separators) for 3
of 3 non-system modules; no aowlsem failures. Part of `run_oracles.sh`.

Named divergences (not hidden): the `system` module's index checksum differs
(`SEM_KNOWN=sysvq0asl`). Generic-instance names are mangled differently from the
reference (for example `..<.0.Ietcrgq` against `..<.0.Inpqkww1`), so exported
inline bodies hash differently. Harmless once the reference sem is gone, but caches
must not be shared between the two sems. Also: `--base` must be the directory the
parser ran in, because parse output spells file names relative to it.

`tools/driver/nifidx.js` (my own port of the index writer: 32 of 37 cached indexes
byte-identical) is kept as an independent cross-check of the checksum only; it is
no longer part of the build path or of `run_oracles.sh`.

Open: only 4 modules of the cache have both outputs, so this is a thin sample. A
fuller aowlsem check needs a cache of a larger program built with aowlsem.

## First end-to-end build on the aowl tools (2026-10-31)

`tools/driver/driver.js` builds a program with `aowlparser`, `aowlsem`, `aowlhexer`
(lowering `c`, `dl`, `de`), `aowlc-native.exe` (C emit) and gcc, sequenced by
`graph.js` / `graph2.js` / `exec.js`. Hello-world compiled, linked and ran:
`hello from the aowl stack`, exit 0. `tools/driver/e2e_hello.sh` checks that output
(and fails on a wrong expectation); `run_oracles.sh` now runs 8 checks and exits 0.
No call is made to the previous stack's driver, parser, sem, lowering, C emitter,
build tool or linker.

Findings made while getting there:
- `aowlhexer` implements `c`, `d`, `dl`, `de`; `aowlc-native.exe <mod.c.nif>` prints
  C to stdout (the `aowlc` script needs node and is not spawnable on Windows).
- `aowlc` resolves foreign symbols by reading sibling `.c.nif` files, so a module's
  C emit must wait for every module's `.c.nif` (the old emitter did not need this).
  Without it the init-function `extern` declaration of an imported module is silently
  dropped and gcc fails with an implicit declaration. A clearer failure or a
  fallback declaration in `emitc.nim` would be worth adding.
- The link step is plain `gcc -o exe *.o -lws2_32`; `niflink` was not needed.
- `driver.js` writes `cachedconfigfile.txt` and the import sidecars itself.

Still depending on the previous stack's directory: the standard library sources
(`--lib`) and the vendored allocator sources (`static.c`). Also open: the executor
has no test of staleness/skip across runs, only single builds; Windows link flags are
hard-coded; only hello-world has been built, not the engine's `src/nif` or `src/interp`.

### Real code through the driver: what it found (2026-10-31)

Compiling the engine's own vendored NIF library (`src/nif`) with the aowl tools found:
- driver: the module-name rule is "shortest path relative to cwd or any search root"
  (includes in the engine tree were named wrongly); imports spelled inside an included
  file belong to the including module; MSYS-style `/c/..` entries in a comma list must
  be normalized.
- vendoring: `defined(typed)` left over from the rename should have been
  `defined(aowlmony)` (fixed).
- aowlsem (FIXED, source only, private build, see aowlsem `tests/pending/include_imports.diagnosis.md`):
  imports inside an included file were not in the import closure.
- aowlsem (OPEN): `gear2/modnames.nim` fails with `E0200 expected string, found Path`
  at `relativePath(path, getCurrentDir(), '/')` after `from std/os import relativePath,
  getCurrentDir`; the library's `std/os` re-exports string versions via `ospaths2`/
  `oscommons`, `std/paths` has `Path` versions. Resolution picks the wrong one.
Reached so far: `bitabs`, `stringviews`, the NIF core (`nifreader`, `nifstreams`,
`nifcursors`, `symparser`, `lineinfos`, `nifbuilder`) compile and link; the typed model
now gets past the include problem and stops at the `modnames` issue above.

### aowlsem fixes this round (source only, uncommitted, private build; see aowlsem
`tests/pending/include_imports.diagnosis.md`)
1. imports inside an included file join the import closure (`gIncludeDeps`);
2. import guards are decided properly (`guardValue`: `defined` incl. `-d:` defines, `not`,
   `and`, `or`), so `when not defined(aowlmony): from std/paths import Path` no longer leaks
   the `Path` overloads into a module that uses the string API.
Result: the whole typed-model program (`nifprelude`, `typed_model`, `decls`, `programs`,
`xints` and everything under them) now passes the semantic phase. Phase 2 then stops in
`aowlhexer c` on `typed_model.s.nif`: `nifstreams.nim(312) n.kind in {Symbol, SymbolDef}`,
i.e. aowlsem emitted a non-symbol where hexer expects one. Next: bisect that module.

### Real-code progress, later the same day
Three more aowlsem defects fixed (see aowlsem `tests/pending/local_generic_subscript.diagnosis.md`),
all found by compiling the engine's own vendored library:
1. a LOCAL generic `[]` never matched its own generic type (receiver-matching compared an ident
   base with a mangled name);
2. imports spelled in an included file were loaded but not VISIBLE (visibility was seeded from
   the module's own sidecar);
3. (earlier) import guards, include imports.
`typed_model` now passes sem and lowering. The next module in the program, `typed/reporters`, fails
in aowlhexer with `could not find symbol: f.15`: a `{.varargs.}` template using `unpack()`
(std/terminal `styledWrite`) leaves its first parameter unbound. Reproduced standalone
(`styledWrite(stdout, fgRed, "hello")`) - filed, not fixed.
New debug traces (env-gated, silent otherwise): `AOWLSEM_DBG_RECV=1` prints `[AT]`/`[RECV]` for
subscript receiver matching. `AOWL_SEM=<path>` makes driver.js use a private aowlsem build.

### Varargs templates (2026-10-31, later)
Fixed in aowlsem (source only, private build): a `{.varargs.}` template with declared leading
parameters (`std/terminal.styledWrite(f: File)`) left them unbound in both expansion paths.
First attempt also skipped `echo`'s output (implicit `(param :vanon . . (varargs))` was counted
as a fixed parameter); the end-to-end hello check caught it, the second attempt passes.
The engine's `typed/reporters` now lowers. `typed/programs` fails next in `aowlhexer`
(`eraiser.nim(128)`, `fnType.tagEnum == ParamsTagId`).

## MILESTONE (2026-10-31): the engine's typed-model program builds on the aowl stack

`nifprelude, typed_model, decls, programs, xints` - the engine's vendored NIF library with its
whole dependency tree (58 compiled modules, 315 KB executable) - parses, semchecks, lowers,
compiles and RUNS ("typed model imports compile") with only aowlparser, aowlsem, aowlhexer,
aowlc and gcc, sequenced by driver.js. It took five aowlsem fixes (all in
aowlsem.ghfresh, source only, uncommitted; private build; see its `tests/pending/*.diagnosis.md`):
include imports in the closure; import guards decided (`defined`/`not`/`and`/`or`, `-d:`);
included imports VISIBLE; local generic `[]` receiver match; varargs templates with declared
parameters (local and imported); `@[]` against a `sink`ed typevar; alias-instance `typeMatches`.
Still reading the standard library and allocator from the old directory; `src/interp` not yet
attempted; aowlsem's own gate suite never run.

### src/interp, first pass (2026-10-31)
Built with the aowl stack (each as its own probe, fresh cache): values, trace, chunk, modload,
sizeofcalc, redecl, natives, arena, iopolicy, nheap, observe, journal. Not yet: flatmem, natobj
(aowlsem E0262 accessor-through-ref), fieldoffsets (one logical `seq[(string, NifIndexKind,
seq[StrId])]` instantiated under two names in two modules -> C struct mismatch). Bigger modules
(compiler, runtime, vm, interp) untried. Probe harness: tools/driver/probe_module.sh; use a FRESH
cache per probe: sharing one cache between different programs produced bogus dce assertions.
Tool: tools/driver/scan_unresolved.js lists raw (unresolved) constructs in a .s.nif per routine.
Also: driver.js passes -Wno-error=incompatible-pointer-types/-int-conversion to gcc 14.

## Engine interpreter bring-up status (2026-10-31)
`tools/driver/probe_module.sh <mod…>` builds engine modules through the aowl stack with a fresh cache (set `AOWL_SEM` to a private aowlsem build). Building today: flatmem, natobj, fieldoffsets, values, journal, modload, natives, arena, chunk, disasm, floatfmt, hostdyn, hostfd, hostshell, iopolicy, redecl, sizeofcalc, trace, tvmmagics. `compiler` passes sem, fails in hexer (`isTrivial: (untyped)`). The driver's define set must match aowlsem's seed (`windows`, `nimony`, `aowlmony`) or guarded imports go unbuilt.
