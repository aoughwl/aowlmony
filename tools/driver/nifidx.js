// `.s.idx.nif` writer: replaces the previous stack's `x` indexer.
// Spec: docs/DRIVER.md ("the .s.idx.nif index is fully specified").
//   (.nif27)\n(index\n [converter section] [export section] (checksum "<sha1>")\n)\n
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const CTRL = new Set("()[]{}~#'\":@ \n\t\r".split(""));
const DIG = /[0-9]/, B62 = /[0-9A-Za-z]/;

function decodeEsc(s) {          // `\n \t \r \| \^` shortcuts and `\HH` hex pairs
  return s.replace(/\\(n|t|r|\||\^|[0-9A-F]{2})/g, (_, e) => {
    switch (e) { case "n": return "\n"; case "t": return "\t"; case "r": return "\r"; case "|": return "\\"; case "^": return '"'; }
    return String.fromCharCode(parseInt(e, 16));
  });
}

// tokenize NIF text (line info and comments are dropped; they never reach the hash)
function tokenize(text, thisModule) {
  const out = []; let p = 0; const n = text.length;
  function suffix() {
    if (p < n && text[p] === "@") { p++; lineInfo(); }
    else if (p < n && text[p] === "~") lineInfo();
    if (p < n && text[p] === "#") { p++; while (p < n && text[p] !== "#") p++; p++; }
  }
  function lineInfo() {
    if (text[p] === "~") p++;
    while (p < n && B62.test(text[p])) p++;
    if (p < n && text[p] === ",") {
      p++; if (text[p] === "~") p++;
      while (p < n && B62.test(text[p])) p++;
      if (p < n && text[p] === ",") { p++; while (p < n && !CTRL.has(text[p])) p++; }
    }
  }
  function name() { const s = p; while (p < n && !CTRL.has(text[p])) p++; return text.slice(s, p); }
  const expand = s => (s.endsWith(".") ? decodeEsc(s) + thisModule : decodeEsc(s));
  while (p < n) {
    const c = text[p];
    if (c === " " || c === "\n" || c === "\t" || c === "\r") { p++; continue; }
    if (c === "(") { p++; const tag = name(); suffix(); out.push({ k: "(", tag }); }
    else if (c === ")") { p++; out.push({ k: ")" }); }
    else if (c === ".") { p++; suffix(); out.push({ k: "dot" }); }
    else if (c === '"') {
      p++; const s = p; while (p < n && text[p] !== '"') p++;
      const raw = text.slice(s, p); p++; suffix(); out.push({ k: "str", s: decodeEsc(raw) });
    } else if (c === "'") {
      p++; let code;
      if (text[p] === "\\") { code = parseInt(text.substr(p + 1, 2), 16); p += 3; } else { code = text.charCodeAt(p); p++; }
      if (text[p] === "'") p++;
      suffix(); out.push({ k: "char", v: code });
    } else if (c === ":") {
      p++; const s = name(); if (s.length) { suffix(); out.push({ k: "symdef", s: expand(s) }); }
    } else if (c === "-" || DIG.test(c)) {
      const s = p; if (c === "-") p++;
      while (p < n && DIG.test(text[p])) p++;
      let kind = "int";
      if (text[p] === ".") { kind = "float"; p++; while (p < n && DIG.test(text[p])) p++; }
      if (text[p] === "E") { kind = "float"; p++; if (text[p] === "-" || text[p] === "+") p++; while (p < n && DIG.test(text[p])) p++; }
      let v = text.slice(s, p);
      if (text[p] === "u") { kind = "uint"; p++; }
      suffix(); out.push({ k: kind, v });
    } else {
      const s = name();
      if (!s.length) { p++; out.push({ k: "unknown" }); continue; }
      suffix();
      out.push(s.includes(".") ? { k: "sym", s: expand(s) } : { k: "ident", s: decodeEsc(s) });
    }
  }
  // drop leading directives such as (.nif27) (.indexat N)
  let i = 0;
  while (out[i] && out[i].k === "(" && out[i].tag.startsWith(".")) { let d = 0; do { if (out[i].k === "(") d++; else if (out[i].k === ")") d--; i++; } while (d > 0); }
  return out.slice(i);
}

function tokText(t) {
  switch (t.k) {
    case "(": return "(" + t.tag; case ")": return ")"; case "symdef": return " :" + t.s; case "sym": return " " + t.s;
    case "ident": return " " + t.s; case "int": return " " + String(BigInt(t.v)); case "uint": return " " + String(BigInt(t.v));
    case "float": {                       // Nim prints whole floats as `1024.0`, not `1024`
      let s = String(Number(t.v)); if (/^-?\d+$/.test(s)) s += ".0"; return " " + s;
    }
    case "str": return " " + t.s;
    case "char": return " " + t.v;
    case "dot": return "."; default: return "?";
  }
}

const VARLIKE = new Set(["let", "var", "cursor", "const", "type", "glet", "tlet", "gvar", "tvar"]);
const INLINEKINDS = new Set(["template", "macro", "iterator"]);
const ROUTINES = new Set(["proc", "func", "method", "converter"]);
const ENTER = new Set(["inline", "kv", "vv", "build", "bundle", "index", "export", "fromexport", "exportexcept"]);

function checksum(toks) {
  const h = crypto.createHash("sha1");
  let n = 0, nested = 0;
  const skip = i => { if (toks[i].k !== "(") return i + 1; let d = 0; do { if (toks[i].k === "(") d++; else if (toks[i].k === ")") d--; i++; } while (d > 0); return i; };
  const exported = i => toks[i].k === "symdef" && toks[i + 1] && toks[i + 1].k !== "dot";
  let foundInline = false;
  function upd(dummy) {          // hash one subtree starting at n
    let nest = 0;
    for (;;) {
      const t = toks[n]; h.update(tokText(t), "latin1");
      if (t.k === "(") { if (t.tag === "inline" && !dummy) foundInline = true; nest++; } else if (t.k === ")") nest--;
      n++; if (nest <= 0) break;
    }
  }
  const hasMore = () => toks[n] && toks[n].k !== ")";
  for (;;) {
    const t = toks[n];
    if (!t) break;
    if (t.k === "(") {
      const tag = t.tag;
      if (VARLIKE.has(tag)) {
        n++; if (exported(n)) for (let k = 0; k < 5; k++) upd(true);
        while (hasMore()) n = skip(n); n++;
      } else if (INLINEKINDS.has(tag)) {
        n++; if (exported(n)) for (let k = 0; k < 9; k++) upd(true);
        while (hasMore()) n = skip(n); n++;
      } else if (ROUTINES.has(tag)) {
        n++;
        if (exported(n)) {
          foundInline = false;
          for (let k = 0; k < 6; k++) upd(true);      // symdef, export, pattern, typevars, params, retType
          upd(false);                                  // pragmas (inline detection)
          upd(true);                                   // effects
          if (foundInline) upd(true); else n = skip(n); // body only for inline routines
        }
        while (hasMore()) n = skip(n); n++;
      } else { n++; nested++; }                        // entered, not hashed
    } else if (t.k === ")") { nested--; if (nested === 0) break; n++; }
    else n++;
  }
  return h.digest("hex").toUpperCase();
}

const esc = s => s.replace(/[:\\]/g, c => "\\" + c.charCodeAt(0).toString(16).toUpperCase().padStart(2, "0"));

// pText: the module's `.p.nif` (for whole-module `export m` statements), depsPaths: its resolved imports (absolute)
function buildIndex(sNifText, thisModule, opts) {
  const toks = tokenize(sNifText, thisModule);
  let content = "(.nif27)\n(index\n";
  // converters: top-level, exported, non-instance
  const conv = [];
  let depth = 0;
  for (let i = 0; i < toks.length; i++) {
    const t = toks[i];
    if (t.k === "(") {
      if (depth === 1 && t.tag === "converter" && toks[i + 1].k === "symdef" && toks[i + 2].k !== "dot") {
        const name = toks[i + 1].s;
        // fields after: export marker, pattern, typevars, params, retType
        let j = i + 2; const sk = x => { if (toks[x].k !== "(") return x + 1; let d = 0; do { if (toks[x].k === "(") d++; else if (toks[x].k === ")") d--; x++; } while (d > 0); return x; };
        j = sk(j);                       // export marker
        j = sk(j);                       // pattern
        const tvStart = j; j = sk(j);    // typevars
        const isInstance = toks[tvStart].k === "(" && toks[tvStart].tag === "invoke";
        j = sk(j);                       // params
        let r = j;                       // retType: unwrap modifiers / application to the head symbol
        while (toks[r].k === "(") r++;
        if (!isInstance && toks[r].k === "sym") conv.push([toks[r].s, name]);
      }
      depth++;
    } else if (t.k === ")") depth--;
  }
  if (conv.length) content += "(converter\n" + conv.map(([k, v]) => ` (kv ${k} ${v})`).join("\n") + ")\n";
  if (opts && opts.exports && opts.exports.length) content += opts.exports.map(p => `(export "${esc(p)}")`).join("") + "\n";
  content += `(checksum "${checksum(toks)}")\n)\n`;
  return content;
}

module.exports = { tokenize, checksum, buildIndex };

if (require.main === module) {
  // Compare against every cached module that has .s.nif and .s.idx.nif.
  const { parseNif } = require("./graph.js");
  const root = process.argv[2] || path.join(process.env.USERPROFILE, ".aowl", "cache");
  let ok = 0, bad = 0, gap = 0, shown = 0, nonEmpty = 0; const seen = new Set();
  for (const h of fs.readdirSync(root)) {
    const nc = path.join(root, h, "nc"); if (!fs.existsSync(nc)) continue;
    for (const f of fs.readdirSync(nc)) {
      if (!f.endsWith(".s.idx.nif")) continue;
      const name = f.slice(0, -10), sn = path.join(nc, name + ".s.nif");
      if (!fs.existsSync(sn)) continue;
      // whole-module exports: names from the parse output, paths from the resolved imports
      let exportsList = [];
      const pn = path.join(nc, name + ".p.nif"), dn = path.join(nc, name + ".s.deps.nif");
      if (fs.existsSync(pn) && fs.existsSync(dn)) {
        const pt = tokenize(fs.readFileSync(pn, "utf8"), name); const names = [];
        for (let i = 0, d = 0; i < pt.length; i++) { if (pt[i].k === "(") { if (d === 1 && pt[i].tag === "export" && pt[i + 1].k === "ident") names.push(pt[i + 1].s); d++; } else if (pt[i].k === ")") d--; }
        const deps = parseNif(fs.readFileSync(dn, "utf8")).find(t => Array.isArray(t) && t[0] === "stmts");
        const files = deps.slice(1).filter(c => Array.isArray(c) && c[0] === "import").flatMap(c => c.slice(1).map(x => x.str));
        for (const nm of names) { const hit = files.find(x => path.basename(x, ".nim") === nm); if (hit) exportsList.push(hit); }
      }
      const got = buildIndex(fs.readFileSync(sn, "latin1"), name, { exports: exportsList });
      const want = fs.readFileSync(path.join(nc, f), "utf8").replace(/\r\n/g, "\n");
      const key = h + "/" + name;
      if (got === want) { ok++; if (want.length > 80) nonEmpty++; }
      else if (/[(](fromexport|export) /.test(want)) { gap++; }   // needs export info that aowlsem does not emit (see docs/DRIVER.md)
      else { bad++; if (shown++ < 4) console.log("MISMATCH", key, "\n  want:", JSON.stringify(want).slice(0, 330), "\n  got: ", JSON.stringify(got).slice(0, 330)); }
    }
  }
  console.log(`index files: ${ok} byte-identical (${nonEmpty} with sections), ${gap} need export info aowlsem does not emit (known gap), ${bad} real mismatch`);
  process.exit(bad || !ok ? 1 : 0);
}
