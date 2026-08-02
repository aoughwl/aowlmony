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

// --- verify: differential native vs interpreted ---------------------------
// `verify` runs both realizers off the one front end and, on a mismatch, names
// the op that produced the first divergent byte. Three things are asserted: the
// agreement path, the "native leg did not build" path (aowlc cannot yet emit any
// program that touches `stdout`, so this is the common case), and — against a
// REAL aowli trace — that a byte offset in the output is attributed to the write
// op that produced it. Exit codes: 0 agree, 1 diverge, 2 a leg could not run.
console.log("verify (native ≡ interpreted):");
{
  const v = aifmony(["verify", path.join(EX, "compute.nim")]);
  check("verify compute.nim agrees", v.status === 0 && /native ≡ interpreted/.test(v.err) ? "agree" : v.err.slice(0, 120), "agree");
  // the default native leg is the binary `nimony c` already linked, so a program
  // that prints really is compared (aowlc cannot build one — asserted below).
  const h = aifmony(["verify", path.join(EX, "hello.nim")]);
  check("verify hello.nim agrees on real stdout",
    h.status === 0 && /stdout 22B \/ 2 lines/.test(h.err) ? "agree-22B" : h.err.slice(0, 140), "agree-22B");
  const hc = aifmony(["verify", path.join(EX, "hello.nim"), "--native:aowlc"]);
  check("verify --native:aowlc reports the unbuildable leg",
    hc.status === 2 && /aowlc native leg did not build/.test(hc.err) ? "native-leg-failed" : `status=${hc.status}`, "native-leg-failed");

  // a REAL stdout divergence, end to end: aowli's `s[2..5]` yields "a" where
  // native yields "cdef". verify must name the write op AND point at the echo.
  const sl = path.join(os.tmpdir(), "aowlmony-test-slice.nim");
  fs.writeFileSync(sl, 'import std/syncio\n\nlet s = "abcdefghijklmnop"\necho s[2..5]\n');
  const sv = aifmony(["verify", sl]);
  check("verify slice diverges", sv.status, 1);
  check("verify slice names the producing op", /produced by\s+write\(stdout, a\)/.test(sv.err) ? "named" : sv.err.slice(0, 200), "named");
  check("verify slice locates the echo", /aowlmony-test-slice\.nim:4/.test(sv.err) ? "line-4" : sv.err.slice(0, 200), "line-4");

  // a divergence with a source location: `7 div 0` traps SIGFPE natively and
  // returns 0 under aowli, so verify must report it AND point at the call site.
  const dz = path.join(os.tmpdir(), "aowlmony-test-divzero.nim");
  fs.writeFileSync(dz, "proc dv(a, b: int): int = a div b\n\nvar z = 0\nlet r = dv(7, z)\ndiscard r\n");
  const d = aifmony(["verify", dz]);
  check("verify div-by-zero diverges", d.status, 1);
  check("verify div-by-zero names the source line",
    /aowlmony-test-divzero\.nim:4/.test(d.err) ? "located" : d.err.slice(0, 160), "located");

  // attribution, against a real trace: which write op produced a given byte?
  const V = require(path.join(ROOT, "bin", "aowlmony"));   // the shim exports nothing
  const tr = cp.spawnSync("node", [AIFMONY, "interp", "--trace", path.join(EX, "hello.nim")], { encoding: "utf8" });
  const p = V.parseTrace(tr.stderr || "");
  const outText = tr.stdout || "";
  const at = V.attribute(p.writes.stdout, outText, outText.indexOf("42"));
  check("attribution rebuilds the traced stdout exactly", at.exact, true);
  check("attribution names the op that printed 42", at.op && at.op.argstr, "stdout, 42");
  check("attribution of byte 0 names the first write", V.attribute(p.writes.stdout, outText, 0).op.argstr,
    "stdout, hello from aifmony");
  // trace-arg escaping round-trips (trace.nim argText collapses \n and \t)
  check("unescapeArg restores a newline", JSON.stringify(V.unescapeArg("a\\nb").text), JSON.stringify("a\nb"));
  check("unescapeArg flags a 48-char truncated arg", V.unescapeArg("x".repeat(45) + "...").truncated, true);
  check("firstDiff on a prefix points past the shorter stream", V.firstDiff("ab", "abc"), 2);
}

// --- provenance: the user module is parsed by OUR nifparser ---------------
console.log("provenance:");
const nif = aifmony(["nif", path.join(EX, "compute.nim"), "-v"]);
check("compute.nim parsed by nifparser", /\(nifparser\)/.test(nif.out) ? "nifparser" : "other", "nifparser");

console.log(`\n${pass}/${pass + fail} passed`);
process.exit(fail ? 1 : 0);
