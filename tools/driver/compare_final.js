// Compare the generated phase-2 graph against an oracle `*.final.build.nif`.
// Usage: node compare_final.js <oracle.final.build.nif> <main.nim> <cwd> <lib> <nc> <defines> <exeName> <staticC> <staticInclude> <staticObj>
const fs = require("fs");
const path = require("path");
const { parseNif, generate } = require("./graph.js");
const { generateFinal } = require("./graph2.js");
const [oracle, main, cwd, lib, nc, defs, exeName, staticC, staticInclude, staticObj, oldRoot, newRoot] = process.argv.slice(2);   // oldRoot->newRoot: directory moved since the oracle run
if (!staticObj) { console.error("usage: see header"); process.exit(2); }
const norm0 = p => path.resolve(p).split(path.sep).join("/").toLowerCase();
const norm = p => { const s = norm0(p); const o = oldRoot ? norm0(oldRoot) : null; return o && s.startsWith(o) ? norm0(newRoot) + s.slice(o.length) : s; };
const nrm = a => (a.includes("/") || a.includes("\\") || a.includes(":")) ? norm(a.replace(/^(-[A-Za-z]+:?)/, "")) + "|" + a.match(/^(-[A-Za-z]+:?)?/)[0] : a;

function oracleNodes(file) {
  const st = parseNif(fs.readFileSync(file, "utf8")).find(t => Array.isArray(t) && t[0] === "stmts");
  const out = [];
  for (const n of st.slice(1)) {
    if (!Array.isArray(n) || n[0] !== "do") continue;
    const node = { tool: n[1], args: [], inputs: [], outputs: [] };
    for (const f of n.slice(2)) {
      if (!Array.isArray(f)) continue;
      const vals = f.slice(1).map(x => (x && x.str !== undefined) ? x.str : String(x));
      (f[0] === "args" ? node.args : f[0] === "input" ? node.inputs : node.outputs).push(...vals);
    }
    out.push(node);
  }
  return out;
}
const key = n => JSON.stringify([n.tool, n.args.map(nrm), n.inputs.map(norm).sort(), n.outputs.map(norm).sort()]);

const p1 = generate({ main: path.resolve(main), cwd: path.resolve(cwd), lib: path.resolve(lib), nc: path.resolve(nc),
  defines: new Set(defs.split(",").filter(Boolean)) });
const got = generateFinal(p1, { nc: path.resolve(nc), exeName, staticC, staticInclude, staticObj, remap: oldRoot ? { from: oldRoot, to: newRoot } : null }).nodes;
const want = oracleNodes(oracle);
const wk = new Map(want.map(n => [key(n), n])), gk = new Map(got.map(n => [key(n), n]));
let missing = 0, extra = 0;
for (const [k, n] of wk) if (!gk.has(k)) { if (++missing <= 4) console.log("MISSING in generated:", n.tool, n.outputs.join(" ")); }
for (const [k, n] of gk) if (!wk.has(k)) { if (++extra <= 4) console.log("EXTRA in generated:  ", n.tool, n.outputs.join(" ")); }
console.log(`oracle nodes: ${want.length}  generated: ${got.length}  missing: ${missing}  extra: ${extra}`);
const ok = missing === 0 && extra === 0 && want.length === got.length;
console.log(ok ? "PASS" : "FAIL");
process.exit(ok ? 0 : 1);
