// Run `aowlsem m` on cached modules (in a scratch copy of the cache dir) and check
// that its own outputs match the reference: `.s.idx.nif` byte for byte, and
// `.s.deps.nif` with the internal `.indexat` offset ignored.
// Usage: node sem_sweep.js <aowlsem.exe> <nc dir> <lib dir> <base dir> [max]
const fs = require("fs"), path = require("path"), cp = require("child_process"), os = require("os");
const [sem, ncSrc, lib, base, maxArg] = process.argv.slice(2);
if (!base) { console.error("usage: sem_sweep.js <aowlsem.exe> <nc dir> <lib dir> <base dir> [max]"); process.exit(2); }
const max = Number(maxArg || 1e9);
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "semsweep-"));
const nc = path.join(tmp, "nc");
fs.cpSync(ncSrc, nc, { recursive: true });
// ignore the internal byte offset and the path-separator style (`\5C` vs `/`)
const norm = s => s.replace(/\r\n/g, "\n").replace(/\(\.indexat \d+\s*\)/, "(.indexat N)").split("\\5C").join("/");
const known = new Set((process.env.SEM_KNOWN || "").split(",").filter(Boolean));   // named, documented divergences
let knownHit = 0, idxOk = 0, idxBad = 0, depsOk = 0, depsBad = 0, failed = 0, tried = 0; const bad = [];
const names = fs.readdirSync(ncSrc).filter(f => f.endsWith(".p.nif")).map(f => f.slice(0, -6))
  .filter(n => fs.existsSync(path.join(ncSrc, n + ".s.nif")) && fs.existsSync(path.join(ncSrc, n + ".s.idx.nif")));
for (const name of names.slice(0, max)) {
  tried++;
  for (const ext of [".s.nif", ".s.idx.nif", ".s.deps.nif"]) fs.rmSync(path.join(nc, name + ext), { force: true });
  const args = ["m", path.join(nc, name + ".p.nif"), path.join(nc, name + ".s.nif"), "--base:" + base, "--nimcache:" + nc, "-p:" + lib];
  if (name.startsWith("sys") && fs.statSync(path.join(ncSrc, name + ".p.nif")).size > 5000) args.push("--noSystem");   // the system module itself
  const r = cp.spawnSync(sem, args, { encoding: "utf8", timeout: 120000 });
  const gi = path.join(nc, name + ".s.idx.nif"), wi = path.join(ncSrc, name + ".s.idx.nif");
  if (r.status !== 0 || !fs.existsSync(gi)) { failed++; bad.push(name + " (aowlsem failed)"); continue; }
  if (norm(fs.readFileSync(gi, "latin1")) === norm(fs.readFileSync(wi, "latin1"))) idxOk++; else if (known.has(name)) knownHit++; else { idxBad++; bad.push(name + " (idx)"); }
  const gd = path.join(nc, name + ".s.deps.nif"), wd = path.join(ncSrc, name + ".s.deps.nif");
  if (fs.existsSync(gd) && fs.existsSync(wd)) { if (norm(fs.readFileSync(gd, "latin1")) === norm(fs.readFileSync(wd, "latin1"))) depsOk++; else if (known.has(name)) knownHit++; else { depsBad++; bad.push(name + " (deps)"); } }
}
fs.rmSync(tmp, { recursive: true, force: true });
console.log(`aowlsem modules run: ${tried}  failed: ${failed}  known divergences: ${knownHit} (${[...known].join(",")})  index identical: ${idxOk}/${idxOk + idxBad}  deps identical: ${depsOk}/${depsOk + depsBad}`);
if (bad.length) console.log("differ:", bad.slice(0, 10).join(", "));
process.exit(failed || idxBad || depsBad || !idxOk ? 1 : 0);
