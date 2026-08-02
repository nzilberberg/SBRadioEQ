/*
  verify-page.js — run with:  node design/verify-page.js design/eq-screen.html

  The first mockup shipped rendering EMPTY: the static chrome drew, and every
  JS-generated part (wallpaper, curve, parameter cells) was missing. It was sent
  without ever being executed, because the browser pane had timed out and I
  treated "the file exists and the base64 decodes" as verification. It is not:
  a page can be structurally perfect and still paint nothing.

  So this executes the page's script against a DOM stub and asserts the screen
  is actually POPULATED. It checks three separate things, because they fail
  independently:

    1. the script parses and runs without throwing;
    2. it writes real content into the elements the screen is made of;
    3. the no-JS fallback in the markup is populated too, so a viewer that
       blocks inline script still shows a legible default rather than a void.

  Exit code is non-zero on any failure, so it can gate a publish.
*/
"use strict";
const fs = require("fs");

const file = process.argv[2];
if (!file) { console.error("usage: node verify-page.js <file.html>"); process.exit(2); }
const html = fs.readFileSync(file, "utf8");

let pass = 0, fail = 0;
function ok(name, cond, detail) {
  if (cond) { pass++; console.log(`  ok   ${name.padEnd(52)} ${detail || ""}`); }
  else      { fail++; console.log(`  FAIL ${name.padEnd(52)} ${detail || ""}`); }
}

/* ---- 3. the fallback that survives a blocked script ------------------- */
console.log("=== the markup alone renders something (script-blocked case) ===");
{
  const grid = /<div class="grid"[^>]*>([\s\S]*?)<\/div>\s*<\/div>/.exec(html);
  const staticCells = grid ? (grid[1].match(/class="cell/g) || []).length : 0;
  ok("parameter cells exist in the markup", staticCells >= 3,
     `${staticCells} static cells`);

  const poly = (html.match(/<polyline/g) || []).length;
  ok("a curve exists in the markup", poly >= 1, `${poly} polyline(s)`);

  ok("wallpaper is a CSS background, not set by script",
     /background-image:\s*url\(data:image\/png;base64,/.test(html) &&
     !/style\.backgroundImage/.test(html),
     "no JS dependency for the background");
}

/* ---- 1 + 2. the script runs and fills the screen ---------------------- */
console.log("=== the script runs and populates the screen ===");
const m = /<script>([\s\S]*?)<\/script>/.exec(html);
if (!m) { ok("a script block exists", false, "none found"); report(); }
const src = m[1];

/* Element stub: records what the script writes. */
const store = Object.create(null);
function mkEl(id) {
  return {
    id, style: {}, className: "",
    _html: "", _text: "",
    get innerHTML() { return this._html; },
    set innerHTML(v) { this._html = String(v); },
    get textContent() { return this._text; },
    set textContent(v) { this._text = String(v); },
    onclick: null,
    classList: { toggle(){}, add(){}, remove(){}, contains(){ return false; } },
    children: [],
    appendChild(c) { this.children.push(c); this._html += c._html || ""; },
    addEventListener() {}, setAttribute() {}, getAttribute() { return null; },
  };
}
/* Serve any id the page asks for, so a missing stub never masquerades as a
   page bug -- but remember which ids were touched. */
const doc = {
  getElementById(id) { return store[id] || (store[id] = mkEl(id)); },
  createElement() { return mkEl("new"); },
  addEventListener() {},
};
global.document = doc;
global.window = { addEventListener(){} };
global.addEventListener = () => {};

let threw = null;
try { new Function(src)(); } catch (e) { threw = e; }
ok("script runs without throwing", !threw,
   threw ? `${threw.constructor.name}: ${threw.message}` : "");

if (!threw) {
  const grid = store.grid, graph = store.graph, read = store.read;

  ok("the parameter grid was populated",
     grid && grid.children.length >= 3,
     grid ? `${grid.children.length} cells built` : "grid never touched");

  ok("cells carry real values, not empty spans",
     grid && /class="v">[^<]+</.test(grid._html),
     grid ? (grid._html.match(/class="v">([^<]*)</g) || []).slice(0, 3).join(" ") : "");

  ok("the curve was drawn",
     graph && /<polyline points="[\d.,\s-]{40,}"/.test(graph._html),
     graph ? `${graph._html.length} chars of SVG` : "graph never touched");

  /*
    The stub's textContent starts EMPTY, so any non-empty value here was
    written by the script -- that alone is the proof, and it is what the
    original failure lacked.

    An earlier version of this check also demanded the value differ from the
    static default. That was wrong twice over: the fallback is supposed to
    match the computed default (otherwise the screen jumps when script runs),
    and it made the check fail on a page that was working correctly.
  */
  ok("the readout was written by the script",
     read && /^(BYP|NO HEADROOM|−[\d.]+\/\d+)$/.test(read._text),
     read._text ? `"${read._text}"` : "readout never touched");

  const metrics = ["mK1", "mK2", "mAtten", "mHead"].filter(k => store[k] && store[k]._html);
  ok("bench readouts were filled", metrics.length === 4,
     `${metrics.length}/4 populated`);
}

function report() {
  console.log("");
  console.log(`passed=${pass} failed=${fail}`);
  process.exit(fail ? 1 : 0);
}
report();
