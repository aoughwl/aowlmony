// Graph executor: runs nodes in dependency order (a node waits for the nodes that
// produce its inputs), skips a node whose outputs are all newer than all inputs,
// runs up to `jobs` nodes at once, and stops on the first failure printing the
// failing command and its output. Spec: docs/DRIVER.md.
const fs = require("fs");
const cp = require("child_process");

const mtime = p => { try { return fs.statSync(p).mtimeMs; } catch { return -1; } };

// nodes: [{ tool, inputs, outputs, argv: [exe, ...args], cwd?, after? }]
//   `argv` is already the full command (the caller maps tool -> command).
// opts: { jobs, log, force }
async function runGraph(nodes, opts = {}) {
  const jobs = opts.jobs || 4, log = opts.log || (() => {});
  const producer = new Map();                       // output path -> node index
  nodes.forEach((n, i) => n.outputs.forEach(o => producer.set(o, i)));
  const deps = nodes.map(n => new Set(n.inputs.map(i => producer.get(i)).filter(j => j !== undefined)));
  const state = nodes.map(() => "pending");         // pending | running | done | skipped
  let failed = null, running = 0, finished = 0;

  const stale = n => {
    if (opts.force) return true;
    const ins = Math.max(-1, ...n.inputs.map(mtime)), outs = n.outputs.map(mtime);
    return outs.some(t => t < 0) || Math.min(...outs) < ins;
  };

  return new Promise(resolve => {
    const pump = () => {
      if (failed) { if (running === 0) resolve({ ok: false, failed }); return; }
      if (finished === nodes.length) { resolve({ ok: true }); return; }
      for (let i = 0; i < nodes.length && running < jobs; i++) {
        if (state[i] !== "pending") continue;
        if ([...deps[i]].some(d => state[d] !== "done" && state[d] !== "skipped")) continue;
        const n = nodes[i];
        if (!stale(n)) { state[i] = "skipped"; finished++; log(`skip   ${n.tool}`); continue; }
        state[i] = "running"; running++;
        log(`run    ${n.tool} ${n.outputs[0] || ""}`);
        const [exe, ...args] = n.argv;
        const child = cp.spawn(exe, args, { cwd: n.cwd, windowsHide: true });
        let out = ""; const bufs = [];
        child.stdout.on("data", d => { if (n.stdoutTo) bufs.push(d); else out += d; }); child.stderr.on("data", d => out += d);
        child.on("error", e => { out += String(e); done(1); });
        child.on("close", code => done(code));
        let called = false;
        const done = code => {
          if (called) return; called = true;
          running--;
          if (code === 0 && n.stdoutTo) fs.writeFileSync(n.stdoutTo, Buffer.concat(bufs));   // tools that print their result
          const missing = n.outputs.filter(o => mtime(o) < 0);
          if (code === 0 && missing.length === 0) { state[i] = "done"; finished++; }
          else if (!failed) failed = { node: n, code, output: out.slice(-4000), missing };
          pump();
        };
      }
      if (running === 0 && !failed && finished < nodes.length) {
        // nothing runnable but work remains: a cycle or an input nobody produces yet
        failed = { node: null, code: -1, output: "deadlock: unsatisfied dependencies", missing: [] };
        resolve({ ok: false, failed });
      }
    };
    pump();
  });
}
module.exports = { runGraph };
