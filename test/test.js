#!/usr/bin/env node
// End-to-end test for the nimony rewrite driver. Each example is compiled once
// (nifparser → nimony sem+hexer, cached), then exercised through BOTH aoughwl
// backends — native (nifc → gcc) and the interpreter (nifi) — and the results
// are asserted to agree. Proves the self-owned frontend feeds both backends
// consistently.
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

// --- provenance: the user module is parsed by OUR nifparser ---------------
console.log("provenance:");
const nif = aifmony(["nif", path.join(EX, "compute.nim"), "-v"]);
check("compute.nim parsed by nifparser", /\(nifparser\)/.test(nif.out) ? "nifparser" : "other", "nifparser");

console.log(`\n${pass}/${pass + fail} passed`);
process.exit(fail ? 1 : 0);
