// Report constructs `aowlsem` left UNRESOLVED in a semantic output (`.s.nif`), per enclosing
// routine: raw `infix`/`prefix` nodes, `dot`/`ddot` whose field is a bare identifier, `call`/`cmd`
// whose callee is a bare identifier, `at` whose receiver is a bare identifier. Resolved output has
// none of these inside non-template routines, and hexer asserts on them.
// Usage: node scan_unresolved.js <file.s.nif> [--templates]   (templates are skipped by default:
// their bodies legitimately keep raw nodes until instantiated)
const fs = require("fs");
const { tokenize } = require("./nifidx.js");
const file = process.argv[2];
const withTemplates = process.argv.includes("--templates");
if (!file) { console.error("usage: scan_unresolved.js <file.s.nif> [--templates]"); process.exit(2); }
const toks = tokenize(fs.readFileSync(file, "latin1"), "x");
const sk = i => { if (toks[i].k !== "(") return i + 1; let d = 0; do { if (toks[i].k === "(") d++; else if (toks[i].k === ")") d--; i++; } while (d > 0); return i; };
const render = (i, n = 14) => { const o = []; for (let k = i; k < Math.min(toks.length, i + n); k++) { const t = toks[k]; o.push(t.k === "(" ? "(" + t.tag : t.k === ")" ? ")" : t.s !== undefined ? t.s : t.v !== undefined ? t.v : t.k); } return o.join(" "); };
let depth = 0, cur = "(top)", curKind = "", total = 0;
const found = new Map();
const note = (kind, i) => { if (curKind === "template" && !withTemplates) return; total++; const key = cur + "  [" + kind + "]"; if (!found.has(key)) found.set(key, render(i)); };
for (let i = 0; i < toks.length; i++) {
  const t = toks[i];
  if (t.k === "(") {
    depth++;
    if (depth === 2 && /^(proc|template|func|iterator|converter|macro|method)$/.test(t.tag) && toks[i + 1].k === "symdef") { cur = t.tag + " " + toks[i + 1].s.replace(/\.\d+\.\w*$/, ""); curKind = t.tag; }
    else if (depth === 2) { cur = "(top) " + t.tag; curKind = ""; }
    if (t.tag === "infix" || t.tag === "prefix") { if (toks[i + 1] && toks[i + 1].k === "ident") note(t.tag + "-ident-op", i); }
    else if (t.tag === "dot" || t.tag === "ddot") { const f = sk(i + 1); if (toks[f] && toks[f].k !== "sym") note("dot-field-" + toks[f].k, i); }
    else if (t.tag === "call" || t.tag === "cmd") { const c = toks[i + 1]; if (c && c.k === "ident") note(t.tag + "-ident-callee", i); }
    else if (t.tag === "at") { const r = toks[i + 1]; if (r && r.k === "ident") note("at-ident", i); }
    else if (t.tag === "array") { const r = toks[i + 1]; if (r && r.k === "dot") note("array-unknown-elem", i); }
  } else if (t.k === ")") depth--;
}
for (const [k, v] of found) console.log(k.padEnd(48), v.slice(0, 100));
console.log(`unresolved constructs: ${total} in ${found.size} routine/kind groups`);
process.exit(total ? 1 : 0);
