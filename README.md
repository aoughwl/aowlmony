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
aowlmony ts     prog.nim [--faithful] [--run]   # idiomatic TypeScript
aowlmony py     prog.nim [--run]                # idiomatic Python
aowlmony js     prog.nim [--faithful] [--run]   # idiomatic / native JavaScript
aowlmony parse  prog.nim                        # show OUR aowlparser .p.aif
aowlmony nif    prog.nim -v                     # .p/.s/.c.aif paths + which parser/hexer ran
```

## How it finds its tools

`aowlmony` resolves every component through the [aowlup](https://github.com/aoughwl/aowlup)
registry (`aowlup config`), honoring the active profile. Precedence:

```
AIFMONY_* env  →  aifmony.config.json  →  aowlup registry  →  dev-fallback probe
```

The per-source build cache is keyed on the active variants, so switching profile
never reuses another profile's artifacts.

> **Note.** `sem=aowlsem` is not yet wired into the driver (sem still runs inside
> `nimony c`); selecting it prints a note and falls back to nimony sem.

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
