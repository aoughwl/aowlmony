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
| emit idiomatic TypeScript / Python / JavaScript | `aowlmony ts foo.nim` · `py` · `js` |

**Expert knobs:** add `-v` to see which components ran; put `+aowl` / `+nimony` /
`+hybrid` *before* the command to force a whole-stack profile for one build
(e.g. `aowlmony +nimony run foo.nim`). Everything else lives in `aowlup` (the
toolchain manager) — `aowlmony` only ever *compiles*.

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
aowlmony ts     prog.nim [--faithful] [--run]   # idiomatic TypeScript
aowlmony py     prog.nim [--run]                # idiomatic Python
aowlmony js     prog.nim [--faithful] [--run]   # idiomatic / native JavaScript
aowlmony parse  prog.nim                        # show OUR aowlparser .p.aif
aowlmony nif    prog.nim -v                     # .p/.s/.c.aif paths + which parser/hexer ran
```

## `verify` — do the backends actually agree?

Every realizer hangs off **one** front end, so if native and interpreted disagree
about the same program, the bug is in a *backend*, not in parsing or sem.
`aowlmony verify` makes that a one-command check: it builds `.c.aif` → binary with
aowlc, runs `.s.aif` under aowli, and compares stdout, stderr and exit status.

On a mismatch it does not just say "differs" — it re-runs the interpreted leg
under `aowli --trace`, rebuilds the output stream from the traced
`write(stdout, …)` ops, finds the op that produced the **first divergent byte**,
and prints that op with its source line:

```
  ✗ verify │ output agrees, exit status does not
    native      → exit 128 (SIGFPE)
    interpreted → exit 0
    last interpreted op dv(7, 0)

error: execution ended here
  ┌─ divzero.nim:4:1
  │
3 │ var z = 0
4 │ let r = dv(7, z)
  │ ^^^^^^^^^^^^^^^^ execution ended here
```

That example is a real finding: `7 div 0` traps `SIGFPE` natively and quietly
yields `0` under aowli.

Exit codes: **0** the legs agree, **1** they diverge, **2** a leg could not run
(e.g. the native build failed — reported as such, never as a divergence).
`--timeout:N` bounds each leg (default 30s); a leg that times out while the other
finishes *is* a divergence — one realizer doesn't terminate.

Two honest limits, both upstream in aowli's trace format
(`src/aowli/trace.nim`): trace arguments are truncated at 48 chars, so
byte-exact attribution is *checked* (the rebuilt stream is compared against the
real stdout) and the report says so when it can only prefix-match; and the trace
carries a **line but no file**, so an op inside the stdlib is attributed by
walking up its call chain to the innermost frame that lands inside your module.

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
