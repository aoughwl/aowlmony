# Differentiation — what we can ship that Nim can't

Status: strategy proposal, 2026-07-29.

The premise: we are a from-scratch reimplementation, not a fork. Araq is one person
with twenty years of accumulated compatibility obligations and no time. Our advantage
is not that we are smarter — it is that we own every layer and carry no legacy. This
document is about spending that advantage on things people actually feel.

## 0. The strategic frame

**Nobody switches languages for an IR architecture.** They switch for the first
thirty minutes: install, first program, first error message, first debug session,
first `--release` build, first library. The tower design matters because it makes
those thirty minutes *cheap for us to make excellent* — not because anyone will read
about it.

So the ranking below is by **(felt impact) × (moat) ÷ (remaining effort)**, and the
top items are deliberately ones where we are already 70–90% done and don't seem to
know it.

---

## 1. Tier S — ship these, lead with these

### S1. One engine: compile-time = runtime = debug-time

Nim has a bytecode VM for CTFE that is a *different implementation* with different
semantics from the runtime. Everyone who writes serious Nim macros hits this: works
at compile time, breaks at runtime, or vice versa. It's a permanent, structural
papercut Araq cannot remove without rewriting the VM.

We interpret the typed IR directly with aowli. That means CTFE, macros/plugins,
the REPL, the playground, and the debugger can be **literally the same evaluator**.

The claim: **"there is no compile-time/runtime semantic split, because there is no
second implementation."** Zig can nearly say this; nobody in the Nim-adjacent space
can. It is a one-line pitch that a working macro author will immediately understand.

*Status: mostly built. Needs the CTFE path and the runtime path proven identical on
a corpus — which the tower's oracle property gives us for free.*

### S2. Time-travel debugging, in the browser, from day one

We have fork-based snapshot/restore, step-backwards, watch/diff, a DAP adapter, and
a browser playground with a replay-based debugger. That combination does not exist
for any systems language. `rr` exists but is Linux/x86-only, separate from the
toolchain, and nobody uses it casually.

**This is the demo that sells the language.** A visitor to the homepage should be
able to hit a bug, step *backwards* into it, and see the value change — in a browser,
with no install. That video does more than a year of blog posts.

*Status: ~80% built. The remaining work is packaging and presentation, not research.*

### S3. Show me my program at any level, live, in the editor

Every rung is an artifact and we already have a lens/LSP layer. So: put the cursor on
a line and see it *desugared*, or *with the ARC ops the compiler inserted*, or *as
the target sees it* — inline, as a code lens, updating as you type.

Rust developers actively beg for this (MIR exists; it is not integrated). Nobody
ships it. For us it is a small amount of glue over things that already exist, and it
turns the tower from an internal detail into a **user-facing feature**: the
architecture becomes visible as a superpower rather than a claim.

Second-order effect: it makes the language *teachable*. "Where did that copy come
from" stops being folklore.

### S4. One binary, zero config

`go`, `zig`, `deno`, `bun` all won adoption partly on this. Nim's story is
famously fragmented: `nim`, `nimble`, `nimsuggest`, `nimpretty`, plus config files
with subtle precedence. We already have the pieces — compiler, LSP, formatter,
linter with autofix, debugger, version manager — but as separate tools.

Ship **one executable** that is compiler + LSP + formatter + linter + debugger +
package manager + REPL, with no configuration required to build a hello world, and
no per-project config file needed until you have a real dependency.

This is not a research problem. It is packaging discipline, and it is worth more
adoption than any two language features.

---

## 2. Tier A — strong differentiators, real work remaining

### A1. Async without function coloring, actually shipped

The `passive`/continuation design targets the single most-complained-about problem
in Rust, JS, and Python: "what color is your function". A unified event loop with
`spawn` on top of it is the Go pitch plus type safety.

The differentiator is not the design (Araq has the design) — it is **shipping it
working, with a debugger that steps through suspended frames correctly**. We have the
debugger. That second half is what makes it believable rather than a roadmap item.

### A2. Proofs instead of runtime checks — pushed much further

Nimony already proves `range[lo..hi]` obligations at compile time and emits *no
runtime check*. That is a genuinely striking feature that is currently buried in a
`differences.md` bullet.

Extend the same engine to: array/seq bounds, nil dereference, division by zero,
integer overflow, and case-object field access. Each one that gets proved is a check
we don't emit — so this is simultaneously a **safety** story and a **performance**
story, which is exactly the pitch Rust cannot make (Rust panics; we prove or refuse).

Ergonomics is the whole game here. The failure mode is Ada/SPARK: correct and
unusable. Mitigation: the prover must explain itself in the IDE ("I couldn't prove
`i < len(a)`; here's what I knew"), and there must be a one-keyword escape hatch.

### A3. Refactors and fixes that carry a proof

aowlfmt already gates formatting on IR equivalence: `normalize(IR(orig)) ==
normalize(IR(formatted))` ⇒ safe. That mechanism generalizes to every automated
change — the 21 autofixes, renames, signature changes, macro expansions, migrations.

**"Automated changes to your code come with a proof they didn't change its
meaning."** No other language toolchain makes that claim. It is also the thing that
makes large-scale automated migration (including AI-driven migration) trustworthy,
which is where the world is heading.

### A4. Compiler-computed semantic versioning

Everything is typed and content-addressed, so we can *compute* whether a change is
breaking rather than asking a human to guess. Elm does this and its users love it; no
systems language does. It falls out nearly free from the content-addressing work and
it is a memorable, quotable feature.

### A5. Debuggable metaprogramming

Nim macros are notoriously hard to debug (`echo repr` and hope). If plugins run on
aowli, you can **set a breakpoint inside a macro**, step it, inspect the IR it is
building, and diff before/after expansion. Combined with S1 (same engine), this makes
metaprogramming a normal engineering activity instead of a dark art.

### A6. Dependency-free cross-compilation

`zig cc` converted a lot of C/C++ users on this alone. We own the codegen, the
runtime (aowllib), and increasingly the assembly/link path — so "build a static
binary for any supported target from any host, with nothing installed" is reachable
for us and *structurally* unreachable for a compiler that shells out to the system
toolchain.

Practical, unglamorous, and one of the highest-conversion features on this list.

---

## 3. Tier B — worth doing, not worth leading with

- **Effects/capabilities as surfaced attributes.** "This function allocates / can
  suspend / does IO", inferred and visible in the IDE, enforced only when you opt in.
  The Nim 2 lesson is that mandatory effect checking (`gcsafe`) is hated; inference +
  opt-in enforcement is the version people want.
- **The compiler as a queryable server.** We already emit structured JSON
  diagnostics and have a lens layer and an MCP surface. Formalize it: a persistent
  process that answers "what calls this", "what is the type here", "why did this
  fail", "what changed since last build" — for editors, for CI, and for agents. We
  are further ahead here than we realize, and this is where tooling is going.
- **Derivation-showing error messages.** Because sem is demand-driven, overload
  resolution failure can print the actual search tree rather than a flat list of
  candidates. Rust approximates this ad hoc; we can do it structurally.
- **A real REPL** — falls out of S1 nearly free, and its absence is a persistent
  complaint about compiled languages.

---

## 4. What to deliberately NOT do

- **Do not chase Nim 2 source compatibility.** It doubles the semantic work, forfeits
  the byte-exact differential oracle that makes our correctness story affordable, and
  the users it wins will still complain about the remaining 5% of incompatibility.
  Ship a porting tool and a shim instead — and note our parser *already* handles Nim 2
  syntax, so the door is open where it is cheap.
- **Do not ship eight backends at 1.0.** Two excellent ones (native, and JS/WASM for
  the browser story) beat eight partial ones. Every extra backend is a permanent tax
  on every language feature.
- **Do not build a package *registry* early.** Build the content-addressed dependency
  model — that is the moat. A registry is a commodity and a liability.
- **Do not make the effect system or the prover mandatory.** Both are features when
  opt-in and adoption-killers when required.
- **Do not position as a Nim fork or a Nim successor.** Positioning against Nim wins
  Nim's users, which is a tiny prize. Position against *the languages people are
  actually frustrated with* — and the frustration we answer is "compiled languages
  have terrible feedback loops".

---

## 5. The positioning sentence

Everything above points at one claim, and it is not a language claim:

> **A compiled systems language with the feedback loop of a scripting language** —
> same engine at compile time, run time, and debug time; step backwards through any
> bug, in your editor or in a browser; see exactly what the compiler did to your code
> at every level; and every automated change comes with a proof it changed nothing.

Nim cannot say any clause of that. Neither can Rust, Go, or Zig. That is the wedge.
