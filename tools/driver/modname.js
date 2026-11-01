// Port of the module-name function (uhash + base36, reversed, 3-char prefix).
const B36 = "0123456789abcdefghijklmnopqrstuvwxyz";
function uhash(s) {
  let h = 0 >>> 0;
  for (const b of Buffer.from(s, "utf8")) {
    h = (h + b) >>> 0;
    h = (h + ((h << 10) >>> 0)) >>> 0;
    h = (h ^ (h >>> 6)) >>> 0;
  }
  h = (h + ((h << 3) >>> 0)) >>> 0;
  h = (h ^ (h >>> 11)) >>> 0;
  h = (h + ((h << 15) >>> 0)) >>> 0;
  return h >>> 0;
}
function suffix(rel) {            // rel: path already relative, '/' separated
  const base = rel.split("/").pop().replace(/\.[^.]*$/, "");
  let id = uhash(rel), out = base.slice(0, 3);
  while (id > 0) { out += B36[id % 36]; id = Math.floor(id / 36); }
  return out;
}
module.exports = { uhash, suffix };
if (require.main === module) {
  const want = {
    "std/system.nim": "sysvq0asl", "std/syncio.nim": "syn1lfpjv", "std/formatfloat.nim": "for2ybv4p1",
    "std/system/basic_types.nim": "bas9lfyiv", "std/system/arithmetics.nim": "ariytns4j",
    "std/system/comparisons.nim": "comzxlm93", "std/system/iterators.nim": "ite00c3rg1",
    "std/system/defaults.nim": "defozvr1x1", "std/system/seqimpl.nim": "seqvroezo",
    "std/system/panics.nim": "panxbb66p", "std/errorcodes/errorcodes.nim": "errefqfp4",
    "../../../AppData/Local/Temp/claude/C--Users-timbuktu/5106267e-329c-4b4e-972a-00170796f25f/scratchpad/hello/hello2.nim": "helszagi51",  // main file: relative to the driver cwd
  };
  let ok = 0, bad = 0;
  for (const [p, w] of Object.entries(want)) {
    const g = suffix(p);
    if (g === w) ok++; else { bad++; console.log("MISMATCH", p, "got", g, "want", w); }
  }
  console.log(`names: ${ok} match, ${bad} mismatch`);
  process.exit(bad ? 1 : 0);
}
