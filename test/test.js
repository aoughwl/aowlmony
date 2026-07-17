#!/usr/bin/env node
// End-to-end test for the nimony rewrite driver. Each example is compiled once
// (nifparser → nimony sem+hexer, cached), then exercised through the aoughwl
// backends — native (nifc → gcc), the interpreter (nifi), and the idiomatic
// source backends (aowlts/aowlpy/aowljs) — and the results are asserted to
// agree with the nimony reference. Proves the self-owned frontend feeds every
// backend consistently.
"use strict";
const cp = require("child_process");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const AIFMONY = path.join(ROOT, "bin", "aifmony");
const EX = path.join(ROOT, "examples");

function aifmony(args) {
  const r = cp.spawnSync("node", [AIFMONY, ...args], { encoding: "utf8" });
  return { out: (r.stdout || "").trim(), err: (r.stderr || "").trim(), status: r.status };
}

let pass = 0, fail = 0;
function check(label, got, want) {
  if (got === want) { console.log(`  ok   ${label} = ${JSON.stringify(got)}`); pass++; }
  else { console.log(`  FAIL ${label} => ${JSON.stringify(got)}  (want ${JSON.stringify(want)})`); fail++; }
}

// --- native (nifc) exec: call a proc, assert printed result ---------------
const NATIVE = [
  ["compute.nim", "fib", [0], "0"],
  ["compute.nim", "fib", [10], "55"],
  ["compute.nim", "fib", [12], "144"],
  ["compute.nim", "fib", [20], "6765"],
  ["compute.nim", "ack", [2, 3], "9"],
  ["compute.nim", "ack", [3, 4], "125"],
  ["demo.nim",    "fib", [20], "6765"],
  ["demo.nim",    "fact", [0], "1"],
  ["demo.nim",    "fact", [5], "120"],
  ["demo.nim",    "fact", [10], "3628800"],
  ["demo.nim",    "isPrime", [2], "1"],
  ["demo.nim",    "isPrime", [91], "0"],
  ["demo.nim",    "isPrime", [97], "1"],
  ["demo.nim",    "isPrime", [100], "0"],
];
console.log("native  (nifparser → sem+hexer → nifc → gcc):");
for (const [file, entry, args, want] of NATIVE) {
  const a = ["exec", path.join(EX, file), "--entry", entry];
  for (const v of args) a.push("--arg", String(v));
  check(`${entry}(${args.join(",")})`, aifmony(a).out, want);
}

// --- interpreter (nifi): run whole program, assert echoed output ----------
console.log("interpret (nifparser → sem → nifi):");
check("interp demo.nim output", aifmony(["interp", path.join(EX, "demo.nim")]).out, "6765\n3628800\ntrue");

// --- idiomatic backends (aowlts/aowljs/aowlpy): emit source + run ----------
// Each backend's `--run` output must equal the nimony reference for the same
// program, proving the sem'd .s.nif feeds all three idiomatic backends.
const os = require("os");
const fs = require("fs");
const NIMONY = process.env.AIFMONY_NIMONY || path.join(os.homedir(), "nimony", "bin", "nimony");
function nimonyRef(file) {
  const nc = path.join(os.tmpdir(), "aifmony-test-ref", path.basename(file, ".nim"));
  fs.mkdirSync(nc, { recursive: true });
  const r = cp.spawnSync(NIMONY, ["c", "-r", "--nimcache:" + nc, path.join(EX, file)], { encoding: "utf8" });
  return (r.stdout || "").trim();
}
console.log("idiomatic backends (aowlts / aowlpy / aowljs), --run == nimony:");
for (const file of ["hello.nim", "demo.nim"]) {
  const ref = nimonyRef(file);
  check(`ts  ${file}`, aifmony(["ts", path.join(EX, file), "--run"]).out, ref);
  check(`py  ${file}`, aifmony(["py", path.join(EX, file), "--run"]).out, ref);
  check(`js  ${file}`, aifmony(["js", path.join(EX, file), "--run"]).out, ref);
}
// faithful mode: int64 overflow must match native exactly (fast mode does not).
console.log("faithful mode (int64-exact) on bignum.nim:");
{
  const ref = nimonyRef("bignum.nim");
  check("ts --faithful bignum.nim", aifmony(["ts", path.join(EX, "bignum.nim"), "--faithful", "--run"]).out, ref);
  check("js --faithful bignum.nim", aifmony(["js", path.join(EX, "bignum.nim"), "--faithful", "--run"]).out, ref);
  const fast = aifmony(["ts", path.join(EX, "bignum.nim"), "--run"]).out;
  check("ts fast bignum.nim differs (proves faithful matters)", fast !== ref ? "differs" : "same", "differs");
}

// --- provenance: the user module is parsed by OUR nifparser ---------------
console.log("provenance:");
const nif = aifmony(["nif", path.join(EX, "compute.nim"), "-v"]);
check("compute.nim parsed by nifparser", /\(nifparser\)/.test(nif.out) ? "nifparser" : "other", "nifparser");

console.log(`\n${pass}/${pass + fail} passed`);
process.exit(fail ? 1 : 0);
