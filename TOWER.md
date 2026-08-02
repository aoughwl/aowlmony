# The Tower — a universal lowering design for the aowl stack

Status: design proposal, 2026-07-29. Not a description of existing code.

## 0. The problem being solved

Nimony/hexer has two language levels (typed-Nim NIF, and Leng) and one flat
sequence of ~13 rewrites between them. Consequences:

- **Invariants are not structural.** `xelim` (lower expressions-with-control-flow
  to statements) runs four times, because later passes re-introduce the construct
  into a grammar that still permits it. There is no point at which "no statement
  expressions" becomes true *and stays true*.
- **The low-level IR is C.** Leng bakes in C's translation-unit shape (toplevel
  hoisting), C's header/linkage model (`(incl "file.h")`, `importc` → `.c` variants),
  C's type lattice, raw addr/deref memory. Exceptions are already burned to an
  error-code protocol, closures to env-struct + fn-pointer, dispatch to vtable
  arrays — *before* any backend gets a say.
- **Backends are retrofits.** C, LLVM, JS and the C-free native path all consume
  the same C-shaped rung. JS inherits a memory model it does not want; the native
  path inherits a linkage model it does not need.

The fix is not more passes. It is **levels**, and **policy**.

---

## 1. Five principles

### P1. A level is a language, not a phase.
Each rung has its own grammar file and a validator that runs in CI. A pass
declares its input rung and output rung. It may not emit a node outside its
output rung's grammar. Invariants hold *by construction*, not by convention.

### P2. Lowering is monotone descent.
Each rung strictly removes expressive power. Once a construct is eliminated it
cannot reappear at any lower rung. This is what kills the four-xelims problem:
`xelim` becomes the *definition* of the L2→L3 boundary and runs exactly once.

Corollary: passes come in exactly two flavours.
- **Lowering** (`in: Ln`, `out: Ln+1`) — runs once, is not idempotent, is not re-runnable.
- **Optimization** (`in: Ln`, `out: Ln`) — must be idempotent, may run any number of times.

Anything that wants to be both is a design smell.

### P3. Target decisions are policy data, not passes.
"How are exceptions represented", "how is dispatch done", "what is the memory
model", "how wide is an int" are **values in a target profile record**, consumed
by generic lowering passes. Adding a target is writing a profile, not writing a
backend.

### P4. Every rung is executable.
`aowli` can interpret any rung. This is the load-bearing property: it turns the
tower into a **differential correctness lattice**, so every lowering pass is
testable *in isolation* rather than only end-to-end. (It generalizes the trick
that made aowlsem work — byte-exact differential against an oracle — from one
boundary to all of them.)

### P5. Every rung is content-addressed.
A pass is a memoized pure function `(pass_id, input_hash, policy_hash) → output_hash`.
Recompilation is a cache lookup. This is the `aowlcas` keystone from the aowlmony
roadmap, applied uniformly instead of only at module granularity.

---

## 2. The rungs

```
L0  surface        .p.aif    untyped, source-faithful, layout+comments preserved
L1  resolved       .r.aif    names bound, modules resolved, generics NOT instantiated
L2  typed / HIR    .s.aif    generics instantiated, overloads resolved, magics tagged
L3  core / MIR     .k.aif    statements only, ARC explicit — but target-neutral
L4  machine / LIR  .m.aif    parameterized by a target profile
L5  emission       .c .js .ll .s .ts .py
```

### L0 — Surface
aowlparser output. Already exists and is done (310/310 structural parity on full
upstream Nim/lib). Round-trippable to source; this is the rung aowlfmt operates on.

### L1 — Resolved  *(new rung)*
Names bound to symbols, imports resolved, sigmatch *not* yet run, generics *not*
instantiated. Nimony folds this into sem; splitting it out is worth it because:

- It is the rung an IDE wants. aowllens/aowllsp currently reconstruct this
  information; here it is an artifact.
- It is the rung a **macro/plugin** should see and rewrite. Plugins that operate
  on L1 are analysable (names already mean something) without being trapped by
  instantiation.
- It is stable under generic instantiation, so it caches well.

### L2 — Typed / HIR
aowlsem's output, and **the rung the substrate owns**. Everything still means what
the programmer wrote:

- closures are closures, iterators are iterators
- `try` / `raise` are structured
- methods are methods; dispatch is `(dyncall ...)`
- types are language types: `seq`, `string`, `ref`, object-with-inheritance,
  distinct, range
- expressions may still contain control flow
- no ARC hooks yet
- every call node carries a **resolved effect row** (raises / tags / side-effect /
  allocation), computed once, preserved by all lowerings

This is where semantic meaning lives, so this is what the aoughwl substrate should
ingest and what claims should be about. High-level optimization (whole-program
inlining decisions, specialization, algebraic rewrites) belongs here.

### L3 — Core / MIR  *(the missing rung)*
The single most important addition. L3 is what you get after the **target-neutral**
half of lowering:

Removed at L2→L3:
- statement-expressions (xelim, once and forever)
- implicit control flow: `defer`, `break`-out-of-expression, and-or shortcut forms
- implicit copies: ARC hooks are explicit (`=copy` / `=sink` / `=destroy` / `=dup`),
  moves resolved, destructor placement fixed
- for-loops over inline iterators (inlined here)
- named argument order, default arguments, varargs packing

Deliberately **retained** at L3:
- `(closure fn env)` as a first-class node
- structured `(try ... except ... finally ...)` with typed exception values
- `(dyncall method obj args)` — dispatch strategy undecided
- language-level types: `seq`, `string`, `ref T`, object inheritance
- `passive`/coroutine constructs as constructs (not yet CPS-transformed)

L3 is the **optimizer rung**. Inlining, DCE, const-fold, loop transforms, escape
analysis: written once, every target benefits, and none of them have to reason
about a C shape.

### L4 — Machine model / LIR, *parameterized*
One grammar, many instantiations. The L3→L4 lowering is **driven by the target
profile** (§3). A given `.m.aif` is only meaningful together with the profile that
produced it, and it records that profile's hash in its header.

### L5 — Emission
Dumb printers. An emitter for target T is a total function over
`L4 under profile(T)`. If an emitter needs a `case` on something the profile
already decided, the profile is under-specified — fix the profile, not the emitter.

---

## 3. The target profile

```
(profile js
  (exceptions   native-throw)      ; c: errorcode | sjlj | unwind
  (closures     native-lambda)     ; c: envstruct-fnptr
  (dispatch     prototype)         ; c: vtable | dict
  (memory       gc-refs)           ; c: flat-ptr    | handles (aowli, substrate)
  (strings      native-utf16)      ; c: len-ptr
  (int64        bigint)            ; c: native      | emulated-pair
  (finalization none)              ; c: arc-destroy | gc-hooks
  (aggregates   native-object)     ; c: struct-by-value
  (tu-shape     module)            ; c: flat-toplevel
  (linkage      esm))              ; c: header-decl
```

Each axis has:
- a small closed set of values,
- one generic lowering pass per axis, dispatching on the value,
- a conformance test set that every value must pass.

**Adding a target = writing a profile + filling any missing (axis, value) cell.**
Not writing a backend.

This is also where the `fast` / `faithful` / `machine` export tiering that already
exists in aowlts/aowlpy/aowlweb belongs: `faithful` is not a backend flag, it is
`(int64 bigint)` + `(aggregates boxed)`. Same knob, expressed once, applying to all
targets that share the constraint.

### The tower is a lattice, not a line

Backends choose **where to branch off**:

```
                 L2 ──► L3 ──┬──► L4(profile:c)      ──► C, LLVM, asm
                             ├──► L4(profile:js)     ──► JS
                             ├──► L4(profile:wasmgc) ──► WASM-GC
                             └──► (none)             ──► aowli direct-interpret L3
```

A target whose runtime already provides closures, exceptions and GC (JS, WASM-GC,
the JVM, Python) branches at L3 with a **thin** L4 that lowers almost nothing.
A target that provides nothing (C, bare native) takes the full descent. Today's
architecture forces every target through the maximal descent — that is the entire
bug, stated structurally.

---

## 4. Mechanisms

### 4.1 Grammar-enforced rungs
Each rung ships `Ln.aifgram`. CI runs `aowlvalidate f.k.aif --rung:L3` after every
pass. Cost: writing four or five grammars. Payoff: rung leakage — a pass quietly
emitting a lower-rung node because it was convenient — becomes a build failure
instead of a mystery three passes later. Rung leakage is the *only* way this design
rots; make it loud.

### 4.2 Pass manifests
A pass declares, in data:

```
(pass duplifier (in L2) (out L2) (kind optimization) (requires arc-hooks-absent)
                (provides dup-points) (policy-axes))
(pass lower-exceptions (in L3) (out L4) (kind lowering) (policy-axes exceptions))
```

The driver builds the schedule from the manifests and the requested profile. It can
then *prove* things the current pipeline can only assert in a comment: that a
lowering runs once, that an optimization's preconditions hold, that no pass reads a
policy axis it did not declare.

### 4.3 Effects as attributes, not a subsystem
Do not build an effect *system* as a separate analysis bolted on later. Compute the
effect row (raises / tags / side-effect / allocates / suspends) once at L2, store it
on the call node, and require every lowering to preserve or refine it. Backends read
it: a `raises: []` region needs no try setup under `(exceptions native-throw)`, and
a `suspends: no` proc needs no coroutine frame. It costs almost nothing when it is
an attribute; it costs a whole-program fixpoint when it is a retrofit.

### 4.4 The oracle at every rung
Because aowli executes every rung (P4), the correctness property is:

```
run(L2) ≡ run(L3) ≡ run(L4 under P) ≡ run(emit_P(L4))   for all profiles P
```

Every lowering pass gets a differential test for free, on any corpus, without a
reference compiler. This is the single highest-leverage piece of the design and it
is the thing the current architecture cannot do at all — there is exactly one
executable rung (the last one) and one oracle (nimsem's output bytes).

It also means a new profile is validated before an emitter exists for it.

### 4.5 Content addressing
`(pass_id, input_hash, policy_hash) → output_hash`, stored in aowlcas. Two profiles
share every artifact down to their branch point: `L2` and `L3` are computed once for
both the C and JS builds. Incremental compilation stops being a special mechanism
and becomes a property.

---

## 5. Where the existing pieces land

| Piece | Role in the tower |
|---|---|
| aowlparser | L0 producer (done) |
| aowlfmt / aowlsuggest | L0 tools, rung-declared |
| aowllens / aowllsp | **L1 consumers** — stop reconstructing, start reading |
| aowlsem | L0→L1→L2, plus the L2 optimizer |
| aowlhl | generalize from "shared HL-IR reader" to the **rung-generic reader** — one library, `rung` as a parameter |
| *(new)* aowlcore | L2→L3 lowering + the L3 optimizer — the missing middle end |
| aowli | the universal executor across rungs; the oracle engine (this is its real identity, cf. the runtime-layer note) |
| aowlc | `L4(profile:c)` → C emitter |
| aowljs | **rebase to branch at L3 with `profile:js`** — should get materially simpler |
| aowlts / aowlpy / aowlweb | profiles, not backends |
| aowllib | the `profile:c` runtime |
| obfuscate | an L2 or L3 same-rung transform, declared as such |

---

## 6. Migration order

Do not big-bang this. Each step is independently valuable and independently
abandonable.

**Step 1 — Write grammars for the rungs you already have.**
L0, L2, and whatever aowlc consumes today. Get the validator green in CI. Zero
behaviour change. Payoff: you can now *prove* a rung invariant, and you find out
immediately how much leakage already exists.

**Step 2 — Mint L3 by splitting the middle end.**
Everything through ARC injection is L2→L3; everything after is L3→L4. Run xelim
exactly once, at the boundary, and make the L3 grammar forbid statement-expressions
so it cannot come back. This alone deletes a class of bug and probably some compile
time.

**Step 3 — Teach aowli to execute L3.**
Now you have the oracle at the new boundary and can refactor the rest safely.

**Step 4 — Extract the profile record with exactly two axes.**
`exceptions` and `closures`. Two profiles: `c`, `js`. These are the two that hurt
most and the two where JS is most obviously being punished by a C-shaped rung.

**Step 5 — Rebase aowljs onto L3 + profile:js.**
Success criterion: aowljs gets *smaller*, and the faithful-mode int64 handling
becomes `(int64 bigint)` in a profile rather than a code path.

**Step 6 — The remaining axes**, one at a time, each gated on its conformance set.

---

## 7. Costs, honestly

- **More artifacts.** Six rungs of `.aif` per module instead of three. Mitigated by
  content addressing (shared prefixes across profiles) but the disk and the mental
  surface both grow.
- **Grammar maintenance.** Every language feature now touches N grammars. This is
  real recurring cost and it is the price of P1.
- **The discipline problem.** The design dies if passes are allowed to "just peek"
  one rung down because it is convenient this once. The validator in CI is the only
  thing standing between this design and the flat pipeline it replaces. Treat a
  grammar violation as a build break, never as a warning.
- **L1 may not earn its keep.** If aowllens/aowllsp turn out not to want it, collapse
  L1 into L2 and lose nothing else. It is the one rung here that is a bet rather
  than a necessity.

## 8. The one-sentence version

Make each level a real language with a real grammar, put the target's decisions in a
data record instead of in the pass list, and make every level executable so every
lowering has an oracle — then a new backend is a profile, and "universal" stops
being an aspiration of the file format and becomes a property of the pipeline.

---

# Part II — Beyond the tower

§1–8 describe a *good pipeline*. They do not describe the best thing available to
us, because they leave three structural weaknesses in place. This part names them
and describes what replaces them. Part I is still the right thing to build first —
it is the scaffolding Part II needs — but it should be built knowing where it goes.

## 9. What is still wrong with Part I

**9.1 Phase ordering still exists.** Every lowering pass *destroys* information. So
"inline before or after ARC injection?" remains a real, unanswerable question, and
whatever we choose is wrong for some program. Grammar-typed rungs make the pipeline
safe; they do not make it optimal.

**9.2 The rung set is hand-authored.** Part I hardcodes six levels and, implicitly,
one hand-written lowering per adjacent pair. That is a *tower*, not a *theory of
towers*. Adding a rung means writing N passes; adding a target axis means editing
every pass that could observe it.

**9.3 It ignores the substrate.** aoughwl already has atoms, claims, lenses, and
`idea = e-class-not-a-name`. That is an **e-graph**. We are simultaneously building
a hand-written compiler pipeline and a machine for reasoning about program
equivalence, and treating them as unrelated projects. They are the same project.

## 10. The unification: lowering *is* deduction

### 10.1 One representation, many lenses

Replace "six rung artifacts" with **one graph**:

- **Nodes** are program fragments (a regionalized dependence graph: control flow as
  nested regions, effects threaded as explicit state edges, everything else pure).
- **E-classes** are ideas — the set of all fragments known to be equivalent.
- **Claims** are rewrite rules: `pattern_a ≡ pattern_b under conditions C`, each one
  a first-class, inspectable, attributable object in the substrate.
- **Rungs are lenses**, not files: "L3" is the *grammar predicate* "this node is
  legal at L3". A rung artifact is a materialized view, produced on demand for
  debugging, caching, or interchange.

### 10.2 Optimization and lowering become one operation

- **Lowering rules** and **optimization rules** are both just claims. Inlining is a
  claim. `xelim` is a claim. Closure→env-struct is a claim. ARC injection is a claim
  (with a state-edge side condition).
- **Compiling** = saturate with the applicable claim set, then **extract** the
  cheapest member of the root e-class *whose every node satisfies the target
  profile's legality grammar*.

That single sentence subsumes: pass ordering (gone — nothing is destroyed), the
profile mechanism (a legality predicate + a cost model), and the optimizer (the cost
model). "Compile for JS" becomes *"extract the cheapest JS-legal form"*, and the
reason JS no longer inherits C's memory model is not that we wrote a better pass —
it is that C's lowering was never forced on it, merely *offered*.

### 10.3 Why this is defensible and not just fashionable

The closest production prior art is Cranelift's acyclic-e-graph mid-end (a genuine
e-graph, but scoped narrowly and used only for mid-level optimization, with lowering
still a separate ISLE pass). LLVM/GCC do none of this. No shipping systems language
uses equality saturation as its *entire* middle end. There is real room to be first.

The representation choice matters: a plain term e-graph handles pure expressions
well and effectful control flow badly. A regionalized dependence graph (RVSDG-style:
nested `gamma`/`theta` regions, state edges for effects) is the known fix — it makes
control flow structural and effects explicit, so equality reasoning stays sound
across loops and side effects. It also matches how aowlsem is already built
(demand-driven), which is not a coincidence.

### 10.4 The honest risks

- **Blowup.** Saturation is unbounded in principle; production use requires node
  limits, staged rule sets, and per-region scoping. Cranelift scopes tightly for
  exactly this reason.
- **Extraction is NP-hard** with realistic (non-additive, sharing-aware) cost models.
  Needs ILP or good heuristics, and needs to be *fast enough for a compiler*.
- **Effects and recursion** are where e-graph designs break. This is the part to
  prototype first, not last.
- **Debuggability.** "Why is my code slow" becomes "why did extraction pick that",
  which needs new tooling. But note: it also becomes *answerable*, which it is not
  in a pass pipeline.

Mitigation is staging, not faith: **the pipeline of Part I is the fallback and the
reference**. Every rule set must be able to run as an ordered pipeline, and the
Part I rungs remain the materialized checkpoints. If saturation is too slow for a
given rule set, that rule set runs as a pass. Nothing is lost.

## 11. Two more things Part I left on the table

### 11.1 Translation validation, not just differential testing

§4.4 gives an oracle by *running* both rungs on a corpus. Strictly stronger and
still tractable: for each compilation, emit a **proof that this lowering preserved
semantics for this input** — per-instance validation rather than proving the pass
correct in general. (This is the Alive2-for-LLVM model, and it is what makes
CompCert-grade confidence affordable without a CompCert-grade budget.)

We have already invented the mechanism, at small scale: aowlfmt's equivalence gate
proves a formatting is safe by showing IR equivalence. Generalize the gate from the
formatter to **every automated transformation** — lint autofixes, refactors, macro
expansions, migrations, and eventually lowering itself. The product claim that falls
out is unusually strong and nobody else can make it: *automated changes to your code
carry a proof they didn't change its meaning.*

### 11.2 Incrementality at definition granularity, not module granularity

§4.5 memoizes passes over modules. The real prize is content addressing at the
**definition** level (the Unison model): a definition's identity *is* the hash of its
elaborated form, names are metadata, and "rebuild" stops being a concept. Combined
with §10, the unit of caching becomes an e-class, so two programs that share a
subexpression share its optimization work — across modules, across projects, across
machines.

This is the `aowlcas` keystone taken to its actual conclusion, and it is what turns
"we cache builds" into "there are no builds".

## 12. Revised build order

1. **Part I steps 1–3** unchanged (grammars, mint L3, aowli executes L3). This is
   scaffolding for everything below and is worth it regardless.
2. **Express one existing pass as claims** rather than code — pick a pure,
   self-contained one (const folding, or the algebraic identities). Run it by
   saturation over a single region. Measure against the hand-written pass.
3. **Prototype the effectful/recursive case** on the regionalized representation.
   This is the make-or-break experiment; do it early and be willing to hear no.
4. **Make the profile a legality predicate** rather than a pass parameter, and
   reproduce the C and JS profiles as extraction constraints.
5. **Translation validation** on the smallest lowering, then widen.
6. **Definition-level content addressing** last — it is the biggest change to the
   user-visible model and should follow, not lead, the compiler work.
