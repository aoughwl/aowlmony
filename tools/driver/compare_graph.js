// Compare generated phase-1 nodes against an oracle build graph, node for node.
// Usage: node compare_graph.js <oracle.build.nif> <main.nim> <cwd> <lib> <nc> [defines,comma]
// Exit 0 only if every node matches (inputs/outputs as sets, args in order).
const fs = require("fs");
const path = require("path");
const { parseNif, generate } = require("./graph.js");

const [oracle, main, cwd, lib, nc, defs, oldLib] = process.argv.slice(2);   // oldLib: prefix to remap to lib (library moved since the oracle run)
if (!nc) { console.error("usage: compare_graph.js oracle main cwd lib nc [defines]"); process.exit(2); }
const norm0 = p => path.resolve(p).split(path.sep).join("/").toLowerCase();
const oldN = oldLib ? norm0(oldLib) : null, libN = norm0(lib);
const norm = p => { const s = norm0(p); return oldN && s.startsWith(oldN) ? libN + s.slice(oldN.length) : s; };

function oracleNodes(file) {
  const tree = parseNif(fs.readFileSync(file, "utf8"));
  const stmts = tree.find(t => Array.isArray(t) && t[0] === "stmts");
  const out = [];
  for (const n of stmts.slice(1)) {
    if (!Array.isArray(n) || n[0] !== "do") continue;
    const node = { tool: n[1], args: [], inputs: [], outputs: [] };
    for (const f of n.slice(2)) {
      if (!Array.isArray(f)) continue;
      const vals = f.slice(1).map(x => (x && x.str !== undefined) ? x.str : String(x));
      if (f[0] === "args") node.args.push(...vals);
      else if (f[0] === "input") node.inputs.push(...vals);
      else if (f[0] === "output") node.outputs.push(...vals);
    }
    out.push(node);
  }
  return out;
}
const key = n => JSON.stringify([n.tool,
  n.args.map(a => a.includes("/") || a.includes("\\") ? norm(a) : a),
  n.inputs.map(norm).sort(), n.outputs.map(norm).sort()]);

const want = oracleNodes(oracle).filter(n => n.tool === "nifler" || n.tool === "nimsem");
const got = generate({ main: path.resolve(main), cwd: path.resolve(cwd), lib: path.resolve(lib), nc: path.resolve(nc),
  defines: new Set((defs || "").split(",").filter(Boolean)) }).nodes;

const wantKeys = new Map(), gotKeys = new Map();
for (const n of want) wantKeys.set(key(n), n);
for (const n of got) gotKeys.set(key(n), n);
let missing = 0, extra = 0;
for (const [k, n] of wantKeys) if (!gotKeys.has(k)) { missing++; if (missing <= 3) console.log("MISSING in generated:", n.tool, n.outputs.join(" ")); }
for (const [k, n] of gotKeys) if (!wantKeys.has(k)) { extra++; if (extra <= 3) console.log("EXTRA in generated:  ", n.tool, n.outputs.join(" ")); }
console.log(`oracle nodes: ${want.length}  generated: ${got.length}  missing: ${missing}  extra: ${extra}`);
console.log(missing === 0 && extra === 0 && want.length === got.length ? "PASS" : "FAIL");
process.exit(missing === 0 && extra === 0 && want.length === got.length ? 0 : 1);
