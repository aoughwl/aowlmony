// Phase-2 (lower, dce, emit, C compile, link) build-graph generator. Pure function.
// Takes the module structure from graph.js `generate()`. Spec: docs/DRIVER.md.
const path = require("path");
const fs = require("fs");
const { parseNif } = require("./graph.js");

// opts: { nc, exeName, staticC, staticInclude, staticObj }
//   staticC is emitted exactly as given (the oracle keeps it relative to the driver cwd).
function generateFinal(p1, opts) {
  const { nc, exeName, staticC, staticInclude, staticObj, remap } = opts;   // remap {from,to}: a directory moved since the deps were written
  const { modules, mainMod, sys, includedBy } = p1;
  const dir = path.join(nc, mainMod.name);               // <nc>/<main>/
  const at = (m, ext) => (m === mainMod ? path.join(dir, m.name + ext) : path.join(nc, m.name + ext));
  const inDir = (m, ext) => path.join(dir, m.name + ext);
  const idx = m => path.join(nc, m.name + ".s.idx.nif");
  const byFile = new Map(modules.map(m => [m.file, m]));
  const nodes = [];

  for (const m of modules) {                                 // lowering
    const isMain = m === mainMod;
    const inputs = [path.join(nc, m.name + ".s.nif")];
    // The semantic stage records the imports it actually resolved (re-exports included)
    // in `<mod>.s.deps.nif`; lowering needs exactly those interfaces.
    const sd = path.join(nc, m.name + ".s.deps.nif");
    const seen = new Set();
    const add = mm => { if (mm && !seen.has(mm)) { seen.add(mm); inputs.push(idx(mm)); } };
    if (m === sys) add(sys);                                   // the system module also lowers against its own interface
    if (fs.existsSync(sd)) {
      const st = parseNif(fs.readFileSync(sd, "utf8")).find(t => Array.isArray(t) && t[0] === "stmts");
      for (const c of st.slice(1)) if (Array.isArray(c) && c[0] === "import")
        for (const f of c.slice(1)) { let file = path.normalize(f.str);
          if (remap && file.toLowerCase().startsWith(path.normalize(remap.from).toLowerCase())) file = path.normalize(remap.to) + file.slice(path.normalize(remap.from).length); add(byFile.get(file) || includedBy.get(file)); }
    } else {
      for (const f of m.imports) add(byFile.get(f));
      if (sys) add(sys);
    }
    nodes.push({ tool: "hexer",
      args: isMain ? ["--isMain", "--app:console", "--outdir:" + dir] : [],
      inputs, outputs: [at(m, ".x.nif"), at(m, ".dce.nif")] });
  }
  nodes.push({ tool: "dceLive", args: [],                    // one merged liveness
    inputs: [mainMod, ...modules.filter(m => m !== mainMod)].map(m => at(m, ".dce.nif")),
    outputs: [inDir(mainMod, ".live.nif")] });
  for (const m of modules) {
    nodes.push({ tool: "dceEmit", args: ["--outdir:" + dir],
      inputs: [at(m, ".x.nif"), inDir(mainMod, ".live.nif")], outputs: [inDir(m, ".c.nif")] });
    nodes.push({ tool: "lengc", args: ["--nimcache:" + dir].concat(m === mainMod ? ["--isMain"] : []),
      inputs: [inDir(m, ".c.nif")], outputs: [inDir(m, ".c")] });
    nodes.push({ tool: "cc", args: [], inputs: [inDir(m, ".c")], outputs: [inDir(m, ".o")] });
  }
  // `{.compile: "x.c".}` in a module: its sidecar carries `(build (tup "C" file flags))`, file relative to the
  // module's own directory. The system module's entry is the allocator (staticC), handled below.
  const extraObjs = [];
  for (const m of modules) {
    if (m === sys) continue;
    const sd = path.join(nc, m.name + ".s.deps.nif");
    if (!fs.existsSync(sd)) continue;
    const st = parseNif(fs.readFileSync(sd, "utf8")).find(t => Array.isArray(t) && t[0] === "stmts");
    for (const c of st.slice(1)) if (Array.isArray(c) && c[0] === "build")
      for (const t of c.slice(1)) if (Array.isArray(t) && t[0] === "tup" && t[1] && t[1].str === "C" && t[2] && t[2].str) {
        let cf = t[2].str; if (!path.isAbsolute(cf)) cf = path.join(path.dirname(m.file), cf);
        const flags = (t[3] && t[3].str ? t[3].str : "").split(/s+/).filter(Boolean);
        const obj = path.join(nc, m.name + "_" + path.basename(cf).replace(/.c$/, "") + ".o");
        nodes.push({ tool: "cc", args: flags, inputs: [path.normalize(cf)], outputs: [obj] });
        extraObjs.push(obj);
      }
  }
  nodes.push({ tool: "cc", args: ["-DMI_STATS=1", "-I" + staticInclude], inputs: [staticC], outputs: [staticObj] });
  nodes.push({ tool: "link", args: [],
    inputs: [inDir(mainMod, ".linkmanifest.nif"), staticObj, ...extraObjs, ...[mainMod, ...modules.filter(m => m !== mainMod)].map(m => inDir(m, ".o"))],
    outputs: [path.join(dir, exeName)] });
  return { nodes };
}
module.exports = { generateFinal };
