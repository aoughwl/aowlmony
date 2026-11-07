// Every import form must reach the dependency sidecar like a plain import, or its module is never built.
// Usage: node test_deps_extract.js   (AOWL_PARSER overrides the parser; default: the sibling checkout's bin)
const fs = require("fs"), os = require("os"), path = require("path"), cp = require("child_process");
const { extract } = require("./deps_extract.js");
const { readDeps } = require("./graph.js");
const parser = process.env.AOWL_PARSER || path.join(__dirname, "..", "..", "..", "aifparser", "bin", "aowlparser.exe");
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "deps_extract_"));
const src = [
  "import plain",
  "import ex1 except Foo",
  "import pkg/ex2 except Foo, Bar",
  "import pkg/[ex3, ex4] except Foo",
  "import asmod as alias",
  "from frm import sym",
  "include inc",
  "when defined(windows):",
  "  import winonly except Foo",
  "when defined(neverdefined):",
  "  import gone except Foo",
].join("\n") + "\n";
fs.writeFileSync(path.join(dir, "m.aowl"), src);
const r = cp.spawnSync(parser, ["p", "m.aowl", "m.p.nif"], { cwd: dir, encoding: "utf8" });
if (r.status !== 0) { console.error("parse failed", r.stdout, r.stderr); process.exit(2); }
const tree = extract(fs.readFileSync(path.join(dir, "m.p.nif"), "latin1"));
const text = (n) => typeof n === "string" ? n : "(" + n.map(text).join(" ") + ")";
fs.writeFileSync(path.join(dir, "m.p.deps.nif"), "(.nif27)\n" + text(tree) + "\n");
const d = readDeps(path.join(dir, "m.p.deps.nif"), new Set(["windows"]));
const want = ["plain", "ex1", "pkg/ex2", "pkg/ex3", "pkg/ex4", "asmod", "frm", "winonly"];
const got = d.imports.slice().sort(), w = want.slice().sort();
let bad = 0;
if (JSON.stringify(got) !== JSON.stringify(w)) { console.log("FAIL imports", got, "want", w); bad++; }
if (JSON.stringify(d.includes) !== JSON.stringify(["inc"])) { console.log("FAIL includes", d.includes); bad++; }
fs.rmSync(dir, { recursive: true, force: true });
console.log(bad ? "deps_extract: FAIL" : "deps_extract: all import forms produce dependencies");
process.exit(bad ? 1 : 0);
