// End-to-end build with the aowl tools only: parse -> sem -> lower -> dce -> C -> cc -> link.
// Usage: node driver.js <main.nim> --cwd DIR --lib DIR --nc DIR [--exe NAME] [--define X,Y]
//        [--tools-dir DIR]  (DIR holding aowlparser/aowlsem/aowlhexer/aowlc; default: sibling checkouts)
// No call is made to the previous stack's driver or tools.
const fs = require("fs"), path = require("path"), cp = require("child_process");
const { generate, parseNif } = require("./graph.js");
const { generateFinal } = require("./graph2.js");
const { extract } = require("./deps_extract.js");
const { runGraph } = require("./exec.js");

function arg(name, dflt) { const i = process.argv.indexOf("--" + name); return i > 0 ? process.argv[i + 1] : dflt; }
const main = path.resolve(process.argv[2] || "");
const cwd = path.resolve(arg("cwd", process.cwd()));
const lib = path.resolve(arg("lib", ""));
const nc = path.resolve(arg("nc", ""));
const exeName = arg("exe", path.basename(main, ".nim") + ".exe");
const winPath = p => /^\/[a-zA-Z]\//.test(p) ? p[1].toUpperCase() + ":" + p.slice(2) : p;   // MSYS-style /c/x -> C:/x
const extraPaths = (arg("path", "") || "").split(",").filter(Boolean).map(p => path.resolve(winPath(p)));   // more import roots
const userDefines = ["aowlmony", ...(arg("define", "") || "").split(",").filter(Boolean)];   // -d: symbols for every module
// `nimony` stays defined: aowlsem seeds it (library sources gate imports on it), and the graph must agree with the checker or a guarded import is never built.
const defines = new Set(["windows", "nimony", ...userDefines]);
const T = path.resolve(arg("tools-dir", path.join(__dirname, "..", "..", "..")));
const tools = {
  parser: process.env.AOWL_PARSER || path.join(T, "aifparser", "bin", "aowlparser.exe"),
  sem: process.env.AOWL_SEM || path.join(T, "aowlsem.ghfresh", "bin", "aowlsem.exe"),   // AOWL_SEM: try a private build
  hexer: path.join(T, "aowlhexer", "bin", "aowlhexer.exe"),
  c: process.env.AOWL_C || path.join(T, "aowlc", "bin", "aowlc-native.exe"),
  cc: "gcc",
};
const verbose = process.argv.includes("-v");
const say = m => verbose && console.log(m);
fs.mkdirSync(nc, { recursive: true });

// --- serialize a deps tree back to NIF text (the graph generator reads this form)
function ser(n) {
  if (typeof n === "string") return n;
  if (n.str !== undefined) return '"' + n.str.replace(/[\\"]/g, c => "\\" + c.charCodeAt(0).toString(16).toUpperCase().padStart(2, "0")) + '"';
  return "(" + n.map(ser).join(" ") + ")";
}

// --- parse a module (and derive its import sidecar) the first time it is discovered
const parsed = new Set();
function ensure(file, name) {
  if (parsed.has(name)) return;
  const pnif = path.join(nc, name + ".p.nif");
  const r = cp.spawnSync(tools.parser, ["p", file, pnif], { cwd, encoding: "utf8" });
  if (r.status !== 0 || !fs.existsSync(pnif)) throw new Error(`parse failed for ${file}\n${r.stdout}${r.stderr}`);
  const deps = extract(fs.readFileSync(pnif, "latin1"));
  fs.writeFileSync(path.join(nc, name + ".p.deps.nif"), "(.nif27)\n(.vendor \"aowl\")\n(.dialect \"nim-deps\")\n" + ser(deps) + "\n");
  parsed.add(name);
}

(async () => {
  fs.writeFileSync(path.join(nc, "cachedconfigfile.txt"), `--base:${cwd} -d:aowlmony --bits:64 --cpu:amd64 --os:Windows ${main}\n`);
  // ---- phase 1: parse + sem
  const p1 = generate({ main, cwd, lib, nc, defines, ensure, paths: extraPaths });
  const nodes1 = p1.nodes.filter(n => n.tool === "nimsem").map(n => {
    const pnif = n.args[n.args.length - 1];
    const argv = [tools.sem, "m", pnif, n.outputs[0], "--base:" + cwd, "--nimcache:" + nc, "-p:" + lib, ...extraPaths.map(p => "-p:" + p), ...userDefines.map(x => "-d:" + x)];
    if (n.args.includes("--isSystem")) argv.push("--noSystem");
    return { ...n, argv, cwd };
  });
  say(`phase 1: ${nodes1.length} sem nodes`);
  let res = await runGraph(nodes1, { jobs: 4, log: say });
  if (!res.ok) return fail("sem", res);

  // ---- phase 2: lower, dce, emit, C, cc, link
  const mainDir = path.join(nc, p1.mainName);
  fs.mkdirSync(mainDir, { recursive: true });
  const staticC = path.join(lib, "..", "vendor", "mimalloc", "src", "static.c");
  const staticInc = path.join(lib, "..", "vendor", "mimalloc", "include");
  const staticObj = path.join(nc, "static.o");
  const p2 = generateFinal(p1, { nc, exeName, staticC, staticInclude: staticInc, staticObj });
  const H = ["--bits:64", "--cpu:le"];
  // aowlc resolves foreign symbols (module inits, imported procs and types) by reading the
  // sibling .c.nif files, so a module's C emit must wait for every module's .c.nif.
  const allCnif = p2.nodes.filter(n => n.tool === "dceEmit").map(n => n.outputs[0]);
  const nodes2 = p2.nodes.map(n => {
    if (n.tool === "lengc") n = { ...n, inputs: [n.inputs[0], ...allCnif.filter(x => x !== n.inputs[0])] };
    let argv;
    switch (n.tool) {
      case "hexer": argv = [tools.hexer, "c", ...H, "--flags:br", ...n.args, n.inputs[0]]; break;
      case "dceLive": argv = [tools.hexer, "dl", ...H, ...n.inputs, n.outputs[0]]; break;
      case "dceEmit": argv = [tools.hexer, "de", ...H, ...n.args, n.inputs[0], n.inputs[1]]; break;
      case "lengc": argv = [tools.c, n.inputs[0]]; n = { ...n, stdoutTo: n.outputs[0] }; break;
      case "cc": argv = [tools.cc, "-c", "-Wno-attributes", "-Wno-error=incompatible-pointer-types", "-Wno-error=int-conversion", "-O1", "-I" + path.dirname(main), ...extraPaths.map(p => "-I" + p), ...n.args, n.inputs[0], "-o", n.outputs[0]]; break;
      case "link": argv = [tools.cc, ...(process.argv.includes("--shared") ? ["-shared"] : []), "-o", n.outputs[0], ...n.inputs.filter(i => i.endsWith(".o")), "-lws2_32"]; break;
      default: throw new Error("no command for tool " + n.tool);
    }
    return { ...n, argv, cwd };
  });
  say(`phase 2: ${nodes2.length} nodes`);
  res = await runGraph(nodes2, { jobs: 4, log: say });
  if (!res.ok) return fail("phase 2", res);
  console.log("built", path.join(mainDir, exeName));

  function fail(where, r) {
    console.error(`FAILED in ${where}`);
    if (r.failed.node) console.error("command:", r.failed.node.argv.join(" ")), console.error("exit:", r.failed.code, " missing outputs:", r.failed.missing.join(", "));
    console.error(r.failed.output);
    process.exit(1);
  }
})().catch(e => { console.error(e.stack || String(e)); process.exit(1); });
