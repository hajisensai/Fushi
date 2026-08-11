const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const SIDE_PANEL = fs.readFileSync(path.join(__dirname, 'side-panel.js'), 'utf8');
const POPUP = fs.readFileSync(path.join(__dirname, 'vendor', 'popup.js'), 'utf8');

test('side panel click lookup has no fixed scan delay and starts immediately', () => {
  assert.doesNotMatch(SIDE_PANEL, /lookupTimer/);
  assert.doesNotMatch(SIDE_PANEL, /setTimeout\([^)]*lookupAt/s);
  assert.match(
    SIDE_PANEL,
    /text\.addEventListener\('click'[\s\S]*?if \(event\.detail > 1\) return;[\s\S]*?lookupAt\(event\.clientX, event\.clientY\)/,
  );
});

test('side panel prepares the cue in parallel and reuses lookup results', () => {
  assert.match(
    SIDE_PANEL,
    /sendToTab\(\{ type: 'fushiSubtitleSidePanelPrepareLookup'[\s\S]*?var cached = lookupCache\.get\(value\);[\s\S]*?await sendRuntime\(\{ type: 'lookup'/,
  );
  assert.match(SIDE_PANEL, /var lookupRequestId = 0;/);
  assert.match(SIDE_PANEL, /var lookupCache = new Map\(\);/);
});

test('shared popup mouse listeners ignore events outside the dictionary shadow root', () => {
  assert.match(POPUP, /function __fushiEventInsidePopup\(e\)/);
  assert.match(POPUP, /document\.addEventListener\('click',[\s\S]*?if \(!__fushiEventInsidePopup\(e\)\) return;/);
});
