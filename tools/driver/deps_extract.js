// Derive a module's import sidecar (`.p.deps`) from its parse output (`.p.nif`).
// The parser in our stack emits no sidecar, so the driver derives it. The result
// is a tree in the same shape graph.js's readDeps consumes:
//   ["stmts", ["import", ["when", cond...]?, path...], ...]
// Spec: docs/DRIVER.md.
const fs = require("fs");
const { parseNif } = require("./graph.js");

// Strip line-info decorations (`name@,1,file`, `x~3`, `y@A`) from a parsed tree.
function strip(n) {
  if (typeof n === "string") return n.replace(/[@~].*$/s, "");
  if (Array.isArray(n)) return n.map(strip);
  return n;
}
const WANT = new Set(["import", "fromimport", "include", "export"]);

function extract(pNifText) {
  const tree = parseNif(pNifText);
  const root = strip(tree.find(t => Array.isArray(t) && typeof t[0] === "string" && t[0].startsWith("stmts")));
  const out = ["stmts"];
  function emit(node, conds) {
    const [h, ...rest] = node;
    out.push(conds.length ? [h, ["when", ...conds], ...rest] : [h, ...rest]);
  }
  function visit(n, conds) {
    if (!Array.isArray(n)) return;
    const h = n[0];
    if (WANT.has(h)) { emit(n, conds); return; }
    if (h === "stmts") { for (const c of n.slice(1)) visit(c, conds); return; }
    if (h === "when") {
      for (const br of n.slice(1)) {
        if (!Array.isArray(br)) continue;
        if (br[0] === "elif") {
          const cond = br[1], body = br[2];
          visit(body, [...conds, cond]);                 // a branch keeps only its own condition
        } else if (br[0] === "else") {
          // An `else` after exactly one branch carries that branch's negation;
          // after several it carries nothing (the previous tool never expresses it).
          const branches = n.slice(1).filter(b => Array.isArray(b) && b[0] === "elif");
          visit(br[1], branches.length === 1 ? [...conds, ["prefix", "not", branches[0][1]]] : conds);
        }
      }
    }
  }
  visit(root, []);
  return out;
}

module.exports = { extract, strip };

if (require.main === module) {
  // Self-test: every cached (.p.nif, .p.deps.nif) pair under ~/.aowl/cache.
  const path = require("path");
  const root = process.argv[2] || path.join(process.env.USERPROFILE || process.env.HOME, ".aowl", "cache");
  let ok = 0, bad = 0, shown = 0, nonEmpty = 0;
  for (const h of fs.readdirSync(root)) {
    const nc = path.join(root, h, "nc");
    if (!fs.existsSync(nc)) continue;
    for (const f of fs.readdirSync(nc)) {
      if (!f.endsWith(".p.deps.nif")) continue;
      const pn = path.join(nc, f.replace(".p.deps.nif", ".p.nif"));
      if (!fs.existsSync(pn)) continue;
      const want = strip(parseNif(fs.readFileSync(path.join(nc, f), "utf8")).find(t => Array.isArray(t) && typeof t[0] === "string" && t[0].startsWith("stmts")));
      const got = extract(fs.readFileSync(pn, "utf8"));
      if (JSON.stringify(want) === JSON.stringify(got)) { ok++; if (want.length > 1) nonEmpty++; }
      else { bad++; if (shown++ < 3) console.log("MISMATCH", f, "\n  want:", JSON.stringify(want).slice(0, 300), "\n  got: ", JSON.stringify(got).slice(0, 300)); }
    }
  }
  console.log(`deps sidecars: ${ok} match (${nonEmpty} with at least one dependency), ${bad} mismatch`);
  process.exit(bad || !nonEmpty ? 1 : 0);
}
