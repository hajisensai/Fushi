const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const dart = fs.readFileSync(path.join(__dirname, '../../lib/src/reader/reader_selection_scripts.dart'), 'utf8');
const source = dart.split('static String source() => r"""')[1].split('""";')[0];
const window = { CSS: {}, getSelection: () => null };
const document = { elementFromPoint: () => null, createRange: () => ({
  setStart() {}, setEnd() {}, getClientRects: () => [],
}) };
vm.runInNewContext(source, { window, document, CSS: { highlights: { set() {}, delete() {} } }, Highlight: function() {} });
const s = window.fushiSelection;
const text = (textContent) => ({ textContent, parentElement: { closest: () => null } });
let hit, lookups = 0;
s.getCharacterAtPoint = () => hit;
s.hideSelectionHandles = () => {};
s.clearSelectionRubyHighlights = () => {};
s.rubyForNode = () => null;
s.selectFromPosition = function(node, offset) {
  lookups++;
  while (offset > 0 && !this.isCodePointJapanese(node.textContent.codePointAt(offset)) && !this.isScanBoundary(node.textContent[offset - 1])) offset--;
  this.selection = {startNode: node, startOffset: offset, ranges: [{node, start: offset, end: node.textContent.length}]};
};
window.__fushiCssHighlightsSupported = true;
const latin = text('hello world');
hit = {node: latin, offset: 2};
s.selectText(0, 0, 400, true);
for (const offset of [2, 3, 4, 0, 1]) { hit.offset = offset; s.selectText(0, 0, 400, true); }
assert.equal(lookups, 1, 'pending Latin lookup deduplicates normalized word');
hit.offset = 6; s.selectText(0, 0, 400, true);
assert.equal(lookups, 2, 'next Latin word remains queryable');
s.clearSelection();
const ja = text('日本語学校');
hit = {node: ja, offset: 0}; s.selectText(0, 0, 400, true);
s.highlightSelection(3);
for (const offset of [0, 1, 2, 1]) { hit.offset = offset; s.selectText(0, 0, 400, true); }
assert.equal(lookups, 3, 'matched Japanese word deduplicates every character');
hit.offset = 3; s.selectText(0, 0, 400, true);
assert.equal(lookups, 4, 'scan tail must not count as matched word');
const inline = text('語学校');
s.selection = {startNode: ja, startOffset: 0, ranges: [{node: ja, start: 0, end: 2}, {node: inline, start: 0, end: 3}]};
s.highlightSelection(3);
hit = {node: inline, offset: 0}; s.selectText(0, 0, 400, true);
assert.equal(lookups, 4, 'same match spans inline nodes');
hit.offset = 1; s.selectText(0, 0, 400, true);
assert.equal(lookups, 5, 'end offset is exclusive');
s.clearSelection();
hit = {node: ja, offset: 0}; s.selectText(0, 0, 400, true);
assert.equal(lookups, 6, 'dismiss permits looking up again');
s.selectText(0, 0, 400, false);
assert.equal(s.selection, null, 'real click retains toggle behavior');
s.selectText(0, 0, 400, true);
const wrapper = {};
s.highlightWrappers = [wrapper];
hit = {node: {textContent: '日本語', parentElement: {closest: () => wrapper}}, offset: 1};
s.selectText(0, 0, 400, true);
assert.equal(lookups, 7, 'DOM wrapper fallback preserves word identity');
console.log('all assertions passed (8 hover scenarios)');
