// Shared pieces of the Node behavior runners that execute the production paged
// reader shell: reading the payload the Dart driver sends, cutting the shell
// object out of the generated script, compiling it against explicit fakes, and
// a fake DOM range whose client rects follow the fake scroll position.

const assert = require('node:assert');
const fs = require('node:fs');
const vm = require('node:vm');

/// The Dart driver pipes the payload (production script sources as JSON) on
/// stdin; no file path crosses the process boundary.
function readPayload() {
  return JSON.parse(fs.readFileSync(0, 'utf8'));
}

function mustFind(source, needle, from, what) {
  const at = source.indexOf(needle, from);
  assert.ok(at >= 0, what + ' missing');
  return at;
}

/// The `{ ... }` literal assigned to `window.fushiReader` in a shell script.
function shellObjectLiteral(shellSource) {
  const opening = 'window.fushiReader = {';
  const open = mustFind(shellSource, opening, 0, 'fushiReader object') + opening.length - 1;
  const close = mustFind(shellSource, '\n};', open, 'fushiReader object terminator');
  return shellSource.slice(open, close + 2);
}

/// Compiles production script text into a function of the named parameters, so
/// every global the script touches is a fake the runner passes in. `filename`
/// is what stack traces of the compiled script show.
function compileScript(parameters, body, filename) {
  return vm.compileFunction(body, parameters, { filename });
}

/// Client rect of a box at document coordinate `geom.doc` (extent `geom.size`
/// along the page axis) as seen from the live `state.scroll`.
function scrolledRect(state, geom) {
  const left = geom.doc - state.scroll;
  return { left, right: left + geom.size, top: 100, bottom: 120, width: geom.size, height: 20 };
}

/// A fake DOM Range over that box; its rects are re-derived on every read.
function scrolledRange(state, geom) {
  const rect = () => scrolledRect(state, geom);
  return {
    getClientRects: () => [rect()],
    getBoundingClientRect: rect,
    cloneRange: () => scrolledRange(state, geom),
  };
}

module.exports = { readPayload, shellObjectLiteral, compileScript, scrolledRect, scrolledRange };
