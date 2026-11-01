// Our parser vs the previous parser on every library module that has a cached
// parse output. Trees are compared after stripping line info.
// Usage: node parser_sweep.js <aowlparser.exe> <lib dir> [cache root]
const fs = require("fs"), path = require("path"), cp = require("child_process"), os = require("os");
const { parseNif } = require("./graph.js");
const { strip } = require("./deps_extract.js");
const { suffix } = require("./modname.js");

const [parser, lib, cacheRoot] = process.argv.slice(2);
if (!lib) { console.error("usage: parser_sweep.js <aowlparser.exe> <lib dir> [cache root]"); process.exit(2); }
const cache = cacheRoot || path.join(process.env.USERPROFILE || process.env.HOME, ".aowl", "cache");
const oracleFor = new Map();   // module name -> cached .p.nif (first found)
for (const h of fs.readdirSync(cache)) {
  const nc = path.join(cache, h, "nc");
  if (!fs.existsSync(nc)) continue;
  for (const f of fs.readdirSync(nc)) if (f.endsWith(".p.nif")) { const n = f.slice(0, -6); if (!oracleFor.has(n)) oracleFor.set(n, path.join(nc, f)); }
}
const rootOf = file => strip(parseNif(fs.readFileSync(file, "utf8")).find(x => Array.isArray(x) && typeof x[0] === "string" && x[0].startsWith("stmts")));
const count = n => Array.isArray(n) ? 1 + n.reduce((s, k) => s + count(k), 0) : 1;

function walk(d, out) { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p, out); else if (e.name.endsWith(".nim")) out.push(p); } return out; }
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "sweep-"));
let equal = 0, differ = 0, failed = 0, nodes = 0; const bad = [];
for (const file of walk(path.join(lib, "std"), [])) {
  const rel = path.relative(lib, file).split(path.sep).join("/");
  const name = suffix(rel);
  const oracle = oracleFor.get(name);
  if (!oracle) continue;
  const out = path.join(tmp, name + ".p.nif");
  const r = cp.spawnSync(parser, ["p", file, out], { encoding: "utf8" });
  if (r.status !== 0 || !fs.existsSync(out)) { failed++; bad.push(rel + " (parser failed)"); continue; }
  const a = JSON.stringify(rootOf(out)), b = JSON.stringify(rootOf(oracle));
  if (a === b) { equal++; nodes += count(rootOf(out)); } else { differ++; bad.push(rel); }
}
console.log(`modules compared: ${equal + differ + failed}  equal: ${equal} (${nodes} tree nodes)  differ: ${differ}  parser failed: ${failed}`);
if (bad.length) console.log("not equal:", bad.slice(0, 12).join(", "));
process.exit(differ || failed || !equal ? 1 : 0);
