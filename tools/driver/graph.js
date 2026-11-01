// Phase-1 (parse + sem) build-graph generator. Pure function: no processes are
// spawned. Reads each module's `.p.deps.nif` (the parser's import sidecar) from
// the cache dir; M2 will produce those by running the parser.
// Spec: docs/DRIVER.md.
const fs = require("fs");
const path = require("path");
const { suffix } = require("./modname.js");

// ---- tiny NIF reader (enough for deps sidecars and build graphs) ----------
function unesc(s) { return s.replace(/\\([0-9A-Fa-f]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16))); }
function esc(s) {   // inverse for the characters the build files escape
  return s.replace(/[:\\]/g, c => "\\" + c.charCodeAt(0).toString(16).toUpperCase().padStart(2, "0"));
}
function parseNif(text) {
  let i = 0;
  function skipWs() { while (i < text.length && /\s/.test(text[i])) i++; }
  function node() {
    skipWs();
    if (text[i] === "(") {
      i++; const kids = [];
      for (;;) {
        skipWs();
        if (i >= text.length) throw new Error("unterminated list");
        if (text[i] === ")") { i++; return kids; }
        kids.push(node());
      }
    }
    if (text[i] === '"') {
      let j = i + 1;
      while (text[j] !== '"') j++;
      const s = text.slice(i + 1, j); i = j + 1;
      while (i < text.length && (text[i] === "@" || text[i] === "~")) {   // trailing line-info annotation
        i++; while (i < text.length && !/[\s()"]/.test(text[i])) i++;
      }
      return { str: unesc(s) };
    }
    let j = i;
    while (j < text.length && !/[\s()"]/.test(text[j])) j++;
    const s = text.slice(i, j); i = j; return s;
  }
  const out = [];
  for (;;) { skipWs(); if (i >= text.length) break; out.push(node()); }
  return out;
}

// ---- deps -----------------------------------------------------------------
function flatPath(n) {            // (infix / std syncio) -> "std/syncio"
  if (typeof n === "string") return n;
  if (n.str !== undefined) return n.str;
  if (Array.isArray(n) && n[0] === "infix" && n[1] === "/") return n.slice(2).map(flatPath).join("/");
  throw new Error("unsupported path expression: " + JSON.stringify(n));
}
function expandPaths(n) {          // -> array of "a/b" strings; std/[a, b] expands to two
  if (typeof n === "string") return [unesc(n)];
  if (n.str !== undefined) return [n.str];
  if (Array.isArray(n) && n[0] === "prefix") return expandPaths(n[2]).map(e => unesc(String(n[1].str !== undefined ? n[1].str : n[1])) + e);   // `../x`
  if (Array.isArray(n) && n[0] === "bracket") return n.slice(1).flatMap(expandPaths);
  if (Array.isArray(n) && n[0] === "infix" && n[1] === "/") {
    let acc = [""];
    n.slice(2).forEach((part, i) => {
      const ex = expandPaths(part);
      acc = acc.flatMap(a => ex.map(e => (i === 0 ? e : a + "/" + e)));
      if (i === 0) acc = ex;
    });
    return acc;
  }
  if (Array.isArray(n) && n[0] === "infix" && n[1] === "as") return expandPaths(n[2]);
  throw new Error("unsupported path expression: " + JSON.stringify(n));
}
function condTrue(c, defines) {
  // Mirrors the previous scanner: defined(X), not, and, or, par, true/false literals;
  // anything it cannot evaluate counts as TRUE (the conservative direction).
  if (typeof c === "string") return c === "false" ? false : true;
  if (!Array.isArray(c)) return true;
  const h = c[0];
  if (h === "call" || h === "cmd" || h === "callstrlit") {
    if (c[1] === "defined") return defines.has(flatPath(c[2]));
    return true;
  }
  if (h === "prefix" && c[1] === "not") return !condTrue(c[2], defines);
  if (h === "infix" && c[1] === "and") return condTrue(c[2], defines) && condTrue(c[3], defines);
  if (h === "infix" && c[1] === "or") return condTrue(c[2], defines) || condTrue(c[3], defines);
  if (h === "par") return condTrue(c[1], defines);
  return true;
}
function readDeps(depsFile, defines) {
  const imports = [], includes = [];
  const tree = parseNif(fs.readFileSync(depsFile, "utf8"));
  const stmts = tree.find(t => Array.isArray(t) && t[0] === "stmts");
  function visit(n, active) {
    if (!Array.isArray(n)) return;
    const h = n[0];
    if (h === "import" || h === "fromimport" || h === "include") {
      // optional leading (when c1 c2 ...) means "all conditions must hold"
      let k = 1, on = active;
      if (Array.isArray(n[k]) && n[k][0] === "when") {
        // includes are unconditional in the previous scanner; only imports honor `when`
        if (h !== "include") for (const c of n[k].slice(1)) on = on && condTrue(c, defines);
        k++;
      }
      if (!on) return;
      const target = h === "include" ? includes : imports;
      for (const p of n.slice(k)) {
        target.push(...expandPaths(p));
        if (h === "fromimport") break;                       // first item is the module; the rest are symbol names
      }
    } else if (h === "stmts") for (const c of n.slice(1)) visit(c, active);
  }
  visit(stmts, true);
  return { imports, includes };
}

// ---- generator ------------------------------------------------------------
// opts: { main, cwd, lib, nc, defines:Set, tools:{parse,sem}, configName }
function generate(opts) {
  const { main, cwd, lib, nc, defines } = opts;
  const rel = (p, base) => path.relative(base, p).split(path.sep).join("/");
  // the shortest path relative to the working directory or any search path (the reference rule)
  const roots = [lib, ...(opts.paths || [])];
  const nameOf = file => { let f = rel(file, cwd); for (const s of roots) { const c = rel(file, s); if (c.length < f.length) f = c; } return suffix(f); };
  const includedBy = new Map();        // included file -> owning module
  const mods = new Map();           // file -> {file, name, imports:[file], includes:[file]}
  const order = [];
  function resolveImport(p, from) {
    const cands = [path.join(lib, p + ".nim"), path.join(path.dirname(from), p + ".nim"), ...(opts.paths || []).map(d => path.join(d, p + ".nim"))];
    const hit = cands.find(c => fs.existsSync(c));
    if (!hit) throw new Error(`cannot resolve import '${p}' from ${from}; tried:\n  ` + cands.join("\n  "));
    return hit;
  }
  function load(file) {
    if (mods.has(file)) return mods.get(file);
    if (includedBy.has(file)) return includedBy.get(file);   // an included file is part of its owner module
    const m = { file, name: nameOf(file), imports: [], includes: [] };
    mods.set(file, m); order.push(m);
    if (opts.ensure) opts.ensure(file, m.name);          // let the caller parse the module on discovery
    const depsFile = path.join(nc, m.name + ".p.deps.nif");
    const d = readDeps(depsFile, defines);
    for (const p of d.imports) m.imports.push(load(resolveImport(p, file)).file);
    const addIncludes = (fromFile, list) => {
      for (const p of list) {
        const inc = path.join(path.dirname(fromFile), p + ".nim");
        if (!fs.existsSync(inc)) continue;                    // missing include files are ignored
        const im = { file: inc, name: nameOf(inc), isInclude: true };
        m.includes.push(im); includedBy.set(inc, m);
        if (opts.ensure) opts.ensure(inc, im.name);
        const sub = path.join(nc, im.name + ".p.deps.nif");     // included files can include more
        if (fs.existsSync(sub)) {
          const sd = readDeps(sub, defines);
          // an included file's imports belong to the including module (the reference scanner
          // traverses an include as part of the current node)
          for (const q of sd.imports) { const f = load(resolveImport(q, inc)).file; if (!m.imports.includes(f)) m.imports.push(f); }
          addIncludes(inc, sd.includes);
        }
      }
    };
    addIncludes(file, d.includes);
    return m;
  }
  const sysFile = path.join(lib, "std", "system.nim");
  if (fs.existsSync(sysFile)) load(sysFile);           // every module implicitly depends on system; load first so its includes are known
  const mainMod = load(main);
  const sys = mods.get(sysFile);
  const cfg = path.join(nc, opts.configName || "cachedconfigfile.txt");
  const P = (name, ext) => path.join(nc, name + ext);
  const nodes = [];
  // parse nodes: every module and every included file
  for (const m of order) {
    nodes.push({ tool: "nifler", args: [], inputs: [m.file], outputs: [P(m.name, ".p.nif")] });
    for (const inc of m.includes) nodes.push({ tool: "nifler", args: [], inputs: [inc.file], outputs: [P(inc.name, ".p.nif")] });
  }
  // sem nodes
  for (const m of order) {
    const isMain = m === mainMod, isSys = m === sys;
    const args = isMain ? ["--isMain", P(m.name, ".p.nif")] : isSys ? ["--isSystem", P(m.name, ".p.nif")] : [P(m.name, ".p.nif")];
    const inputs = [P(m.name, ".p.nif"), ...m.includes.map(i => P(i.name, ".p.nif"))];
    for (const imp of m.imports) inputs.push(P(mods.get(imp).name, ".s.idx.nif"));
    if (!isSys && sys && !m.imports.includes(sys.file)) inputs.push(P(sys.name, ".s.idx.nif"));
    inputs.push(cfg);
    nodes.push({ tool: "nimsem", args, inputs, outputs: [P(m.name, ".s.nif"), P(m.name, ".s.idx.nif")] });
  }
  return { nodes, mainName: mainMod.name, modules: order, mainMod, sys, includedBy };
}

module.exports = { parseNif, esc, unesc, generate, readDeps };
