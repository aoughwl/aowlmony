// Debug helper: show, per differing node of one tool, which inputs/args differ.
// Usage: node diff_nodes.js <tool> (uses the big oracle configuration below)
const fs = require("fs");
const g = require("./graph.js"), g2 = require("./graph2.js");
const tool = process.argv[2] || "hexer";
const B = "C:/Users/timbuktu/.aowl/cache/6a681fbe71ed/nc", T = "C:/Users/timbuktu/dev/toolchain";
const p1 = g.generate({ main: "C:/Users/timbuktu/dev/jester/tools/build_native_host.nim",
  cwd: "C:/Users/timbuktu/dev/aoughwl-engine/src/interp", lib: T + "/_uninstalled-nimony/nimony-aowl/lib", nc: B, defines: new Set(["windows"]) });
const got = g2.generateFinal(p1, { nc: B, exeName: "build_native_host.exe", staticC: "x", staticInclude: "x", staticObj: "x", remap: { from: T + "/nimony-aowl", to: T + "/_uninstalled-nimony/nimony-aowl" } }).nodes;
const st = g.parseNif(fs.readFileSync(B + "/bui8a35sj1.final.build.nif", "utf8")).find(t => Array.isArray(t) && t[0] === "stmts");
const bn = p => p.split("\\").join("/").split("/").slice(-2).join("/");
let shown = 0;
for (const n of st.slice(1)) {
  if (!Array.isArray(n) || n[0] !== "do" || n[1] !== tool) continue;
  const f = k => n.filter(x => Array.isArray(x) && x[0] === k).flatMap(x => x.slice(1).map(y => y.str));
  const outs = f("output").map(bn);
  const gn = got.find(x => x.tool === tool && x.outputs.map(bn).join() === outs.join());
  if (!gn) { console.log("no generated node for", outs.join(" ")); continue; }
  const wi = new Set(f("input").map(bn)), gi = new Set(gn.inputs.map(bn));
  const a = [...gi].filter(x => !wi.has(x)), b = [...wi].filter(x => !gi.has(x));
  const wa = f("args").map(bn).join(" "), ga = gn.args.map(bn).join(" ");
  if (a.length || b.length || wa !== ga) {
    if (shown++ < 8) console.log(outs[0], "\n   gen-only:", a.join(", "), "\n   oracle-only:", b.join(", "), "\n   args oracle:", wa, " gen:", ga);
  }
}
console.log("differing", tool, "nodes shown:", shown);
