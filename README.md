# aowlmony

**The nimony driver over the aoughwl self-owned stack.** Give it a `.nim` file
and it runs parser → sem → lowering → *your choice of* native code, an
interpreter, or idiomatic source (TS/Py/JS) — using aoughwl's own components
wherever they exist, and reusing nimony's for the parts not yet rebuilt.

```
   .nim ──► aowlparser (ours) ──► nimony sem (reused) ──► aowlhexer (ours) ──► .s.aif / .c.aif
                                                                                │        │
                                          aowli (ours) ◄── interpret ──────────┘        └──► aowlc (ours) ──► C ──► gcc ──► native
```

## Quick start

New here? One command takes a `.nim` file all the way to a running program:

```sh
aowlmony run foo.nim        # compile foo.nim → native binary → run it
```

That's the whole happy path. Everything below is optional — it's either a
*different way to run the same file* (an interpreter, or emitting TS/Py/JS) or a
knob for *which* toolchain does the work.

| I want to… | command |
|---|---|
| **just run my program** | `aowlmony run foo.nim` |
| build a binary, don't run it | `aowlmony build foo.nim -o foo` |
| run it in the interpreter (full runtime, debuggable) | `aowlmony interp foo.nim` |
| call one proc and print its result | `aowlmony exec foo.nim --entry fib --arg 20` |
| check the backends agree on it | `aowlmony verify foo.nim` |
| find a pointer that outlives what it points at | `aowlmony verify foo.nim --memory` |
| emit idiomatic TypeScript / Python / JavaScript | `aowlmony ts foo.nim` · `py` · `js` |

**Expert knobs:** add `-v` to see which components ran; put `+aowl` / `+nimony` /
`+hybrid` *before* the command to force a whole-stack profile for one build
(e.g. `aowlmony +nimony run foo.nim`). Everything else lives in `aowlup` (the
toolchain manager) — `aowlmony` only ever *compiles*.

## Two builds in this repo, and which one you run

`aowlmony` is written in the language it compiles. `bin/aowlmony-ng` is that
build and it is the one installed; `bin/aowlmony` is the original Node
implementation, kept as the **differential oracle** — `test/diff.sh` runs both
over the whole command surface and requires byte-identical stdout, stderr and
exit code, so any difference is either a bug or a listed, reasoned improvement.

It is not dead code and it is not a fallback. When the two disagree, that
disagreement is the finding.

## Manager + driver — `aowlup : aowlmony`

The toolchain interface is two tools, modelled on **`rustup` : `cargo`**:

- **[aowlup](https://github.com/aoughwl/aowlup)** *manages the toolchain* —
  installs, versions, and *selects* the components, writing its choice to a
  registry at `~/.aowl`.
- **`aowlmony`** *compiles your code* — it reads that registry and runs the
  selected components. It never installs anything.

Which implementations run is a property of the active **profile** — `aowl` (all
ours), `nimony` (all nimony), or `hybrid` (ours parser + nimony sem + ours hexer,
the default). Switch it with `aowlup profile use <name>`, or override one build
with rustup-style `+profile` syntax:

```sh
aowlmony run foo.nim            # compile with whatever aowlup selected
aowlmony +nimony run foo.nim    # compile once with the all-nimony stack
```

`aowlmony help` prints the active profile and the parser/sem/hexer it resolves to.

## Ours vs reused — the honest map

| stage | tool | owned? |
|---|---|---|
| parse `.nim` → `.p.aif` (user modules) | **[aowlparser](https://github.com/aoughwl/aowlparser)** | ✅ ours |
| parse stdlib → `.p.aif` | `nifler` | reused — aowlparser has `concept`/typed-nil gaps |
| sem `.p.aif` → `.s.aif` | nimony `nimsem` | reused — **[aowlsem](https://github.com/aoughwl/aowlsem) not finished yet** |
| lower `.s.aif` → `.c.aif` (ARC, closures, exceptions, mono) | **[aowlhexer](https://github.com/aoughwl/aowlhexer)** | ✅ ours |
| **native** `.c.aif` → binary | **[aowlc](https://github.com/aoughwl/aowlc)** → gcc | ✅ ours |
| **interpret** `.s.aif` | **[aowli](https://github.com/aoughwl/aowli)** (tree-walk + bytecode VM) | ✅ ours |
| idiomatic `.s.aif` → TS / Py / JS | **[aowlts](https://github.com/aoughwl/aowlts)** / **[aowlpy](https://github.com/aoughwl/aowlpy)** / **[aowljs](https://github.com/aoughwl/aowljs)** | ✅ ours |

Only semantic analysis is still nimony's, until [aowlsem](https://github.com/aoughwl/aowlsem) lands.

## Usage

```sh
aowlmony run    prog.nim                        # native: whole module → binary → run
aowlmony build  prog.nim -o prog                # native: emit a binary
aowlmony exec   prog.nim --entry fib --arg 20   # native: call one proc, print result (→ 6765)
aowlmony interp prog.nim                        # interpret via aowli (full runtime)
aowlmony vm     prog.nim                        # interpret via aowli's bytecode VM
aowlmony verify prog.nim                        # run both; report the first divergent op
aowlmony verify prog.nim --memory               # dangling/use-after-free under --fin
aowlmony ts     prog.nim [--faithful] [--run]   # idiomatic TypeScript
aowlmony py     prog.nim [--run]                # idiomatic Python
aowlmony js     prog.nim [--faithful] [--run]   # idiomatic / native JavaScript
aowlmony parse  prog.nim                        # show OUR aowlparser .p.aif
aowlmony nif    prog.nim -v                     # .p/.s/.c.aif paths + which parser/hexer ran
```

## `verify` — do the backends actually agree?

Every realizer hangs off **one** front end, so if native and interpreted disagree
about the same program, the bug is in a *backend*, not in parsing or sem.
`aowlmony verify` makes that a one-command check: it runs the program natively and
under aowli, and compares stdout, stderr and exit status.

`--native:nimony` (default) uses the binary the compile **already** linked — your
code parsed by aowlparser and lowered by aowlhexer, emitted to C by nimony — so it
costs no extra build. `--native:aowlc` verifies the fully self-owned C backend
instead; when it cannot build a program, that is reported as a leg failure, never
as a divergence.

**A verdict is only as good as the binaries it ran.** The registry can resolve a
tool to an installed copy (`~/.aowl/bin`) that its repo checkout has moved past, and
a week-old engine then looks exactly like a backend defect. Every verdict names the
realizers it ran and their build dates, and if a newer build of the interpreter
exists on disk, verify says so and tells you to re-run with `AOWLMONY_NIFI=` before
reporting anything as an aowli bug.

On a mismatch it does not just say "differs" — it re-runs the interpreted leg
under `aowli --trace`, rebuilds the output stream from the traced
`write(stdout, …)` ops, finds the op that produced the **first divergent byte**,
and prints that op with its source line:

```
  ✗ verify │ native ≢ interpreted

  first divergence  in stdout at line 1, col 1  (byte 0)
    native      → "cdef\nabc\n16\nabcdefghijkl" …
    interpreted → "a\na\n16\nabcdefghijklmnop\n" …

  produced by       write(stdout, a)   op #2 of the interpreted run

error: native and interpreted disagree here
  ┌─ slice.nim:4:1
  │
3 │ let s = "abcdefghijklmnop"
4 │ echo s[2..5]
  │ ^^^^^^^^^^^^ native and interpreted disagree here
```

That report was the command's first real result — and also its first lesson: the
`"a"` was **not** an aowli defect but a stale `~/.aowl/bin/aowli-interp` shadowing a
fixed engine, which is why verify now warns about build dates before you blame a
backend. `7 div 0` was a genuine one: it returned `0` and exit 0 where native traps
`SIGFPE`, now fixed in aowli, which raises `division by zero`. Native still dies on
a signal and loses its buffered stdout, so div-by-zero stays an expected divergence
rather than a match.

Exit codes: **0** the legs agree, **1** they diverge — and *only* that — **2** a leg
could not run, which covers both a failed native build and a front-end compile
error, so a flaky shared-`nimcache` link failure can never masquerade as a
divergence.
`--timeout:N` bounds each leg (default 30s); a leg that times out while the other
finishes *is* a divergence — one realizer doesn't terminate.

One honest limit remains, upstream in aowli's trace format
(`src/aowli/trace.nim`): trace arguments are truncated at 48 chars, so
byte-exact attribution is *checked* (the rebuilt stream is compared against the
real stdout) and the report says so when it can only prefix-match.
`AOWLI_TRACE_ARGCAP=0` lifts the cap. Call sites now carry a **file** as well as
a line, so a frame is user code because its file says so; against an older
interpreter that emits a bare `:line`, verify falls back to "the innermost frame
whose line lands inside your module" and says which rule it used. A top-level
`echo` has *no* user frame at all — it expands to `write(stdout, …)` recorded at
syncio's own line — so the fallback also walks back to the last op run at one of
your lines (for `echo s[2..5]`, the `[]` call).

## `verify --memory` — dangling pointers and use-after-free

`--fin` is what makes destruction observable: it routes the module through the
destroyer, so `=destroy` actually runs at scope exit instead of the program
leaking quietly to the end. `aowlmony verify prog.nim --memory` asks the
question that mode enables — **does any pointer outlive the storage it names?**

```
  ✗ verify --memory │ 1 defect, 1 confirmed under --fin

  use after free   `p` is used after the storage it points at was destroyed
    allocated → uaf.nim:12:9   `b` is declared here
    freed     → uaf.nim:14   end of the scope opened at uaf.nim:11 — =destroy witnessed here
    used      → uaf.nim:15:7   executed on this run

error: `p` is used after the storage it points at was destroyed
   ┌─ uaf.nim:15:7
   │
14 │     use(p)
15 │   use(p)
   │       ^^ `p` is used after the storage it points at was destroyed
   = note: confirmed: the --fin run destroyed `b` and then reached this line
```

Neither half of the toolchain can answer this alone, which is why the check is
built from both. The `--fin` trace knows a destructor ran and where, but renders
every object argument as `(object)` — no identity — so it cannot say *which*
storage died or who still points at it. The sem'd `.s.nif` has the identities
and the scopes but no idea which paths execute. So the dangling pointer is found
structurally in the NIF, and then the `--fin` run is asked to **witness** it: a
`=destroy` at the scope that was blamed, and the use site actually being
reached. Findings are labelled by how much was observed — `confirmed` means both
halves were seen, and a finding that was never on this run's path says so
instead of borrowing the confidence of one that was.

It also traps the address of a local escaping through a `return`. That one is
reported at the `addr`, not at the `ret`: a lowered `ret` usually carries no line
info of its own and inherits the routine's, which would point the diagnostic at
the `proc` header instead of the line that leaks the address.

**A clean verdict states what it examined** — `3 address-taking sites · 2 bound
to a named pointer and tracked across 7 scopes`. Without that, a sound program
and an analysis that never reached your module print the same green tick. The
same counters expose the real limit: the analysis is **intraprocedural**, so an
address handed straight to a call (`bar(addr x)`) is counted but not followed
into the callee, and the report says how many of those it saw.

Exit codes: **0** nothing dangles, **1** at least one defect, **2** the module
did not compile.

## How it finds its tools

`aowlmony` resolves every component through the [aowlup](https://github.com/aoughwl/aowlup)
registry (`aowlup config`), honoring the active profile. Precedence:

```
AOWLMONY_* env  →  aowlmony.config.json  →  aowlup registry  →  dev-fallback probe
```

The per-source build cache is keyed on the active variants, so switching profile
never reuses another profile's artifacts.

**What each slot honors.** The **parser** (`aowlparser` vs `nifler`) and the
**lowering** (`aowlhexer` vs nimony's `hexer`) are swapped in via nimony's
`findTool` shim seam, so the active profile genuinely controls them —
`aowlmony +aowl run f.nim -v` reports *parsed by aowlparser / lowering via
aowlhexer*, `+nimony` reports *nifler / nimony hexer*. Backends
(`native/interp/js/…`) resolve their exes from the registry.

> **`sem=aowlsem`** is the one slot the driver can't honor yet: `aowlsem` can't
> semcheck `std/system` inside the `nimony c` build (it computes different
> include-module hashes and doesn't emit the `.s.idx.nif` index), so selecting it
> falls back to nimony `nimsem` with a note. The driver adopts `aowlsem`
> automatically once it covers `system` — no driver change needed.

## The interpreter is first-class

[aowli](https://github.com/aoughwl/aowli) is not a fallback — it is a primary
execution mode (`aowlmony interp`), and the intended answer to the one feature the
native path is missing: **macros / compile-time execution**. The same evaluator
that runs `aowlmony interp` is meant to run `static:` blocks and constant folding,
replacing nimony's build-a-native-exe-per-macro model. Wiring this into
[aowlsem](https://github.com/aoughwl/aowlsem) is the next milestone.

## Test

```sh
npm test    # runs example programs through the stack; asserts native == interpreter
```

## License

MIT. The old binary name `aifmony` remains as a thin forwarding shim (`bin/aifmony`).
