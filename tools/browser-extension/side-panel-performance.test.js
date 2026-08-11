const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const SIDE_PANEL = fs.readFileSync(path.join(__dirname, 'side-panel.js'), 'utf8');
const SIDE_PANEL_HTML = fs.readFileSync(path.join(__dirname, 'side-panel.html'), 'utf8');
const CONTENT = fs.readFileSync(path.join(__dirname, 'content.js'), 'utf8');
const POPUP = fs.readFileSync(path.join(__dirname, 'vendor', 'popup.js'), 'utf8');
const BACKGROUND = fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8');
const OPTIONS = fs.readFileSync(path.join(__dirname, 'options.js'), 'utf8');
const OPTIONS_HTML = fs.readFileSync(path.join(__dirname, 'options.html'), 'utf8');

test('subtitle row click seeks unless this row owns a native text selection', () => {
  assert.match(
    SIDE_PANEL,
    /row\.addEventListener\('click'[\s\S]*?!selection\.isCollapsed[\s\S]*?row\.contains\(anchorElement\)[\s\S]*?fushiSubtitleSidePanelSeek/,
  );
  assert.match(SIDE_PANEL, /timestamp\.addEventListener\('click'[\s\S]*?event\.stopPropagation\(\)/);
  assert.doesNotMatch(SIDE_PANEL, /text\.addEventListener\('click'/);
});

test('Shift scans immediately at the last pointer without changing native selection', () => {
  assert.doesNotMatch(SIDE_PANEL, /lookupTimer/);
  assert.match(SIDE_PANEL, /text\.addEventListener\('pointermove', rememberPointer/);
  assert.match(
    SIDE_PANEL,
    /event\.key === 'Shift'[\s\S]*?!event\.repeat[\s\S]*?lookupAtPointer\(lastPointer, true\)/,
  );
  assert.doesNotMatch(SIDE_PANEL, /removeAllRanges|preventDefault\(\)/);
});

test('side-panel lookup reuses the Shift popup host model and parsed results', () => {
  assert.match(SIDE_PANEL_HTML, /<section id="lookup-pane" class="lookup-pane" aria-label="查词结果" hidden><\/section>/);
  assert.doesNotMatch(SIDE_PANEL_HTML, /lookup-header|lookup-close|lookup-scroll/);
  assert.match(SIDE_PANEL, /lookupPaneEl\.attachShadow\(\{ mode: 'open' \}\)/);
  assert.match(SIDE_PANEL, /var lookupInFlight = new Map\(\);/);
  assert.match(SIDE_PANEL, /prepared\.entries = JSON\.parse\(data\.popupJson\)/);
  assert.match(SIDE_PANEL, /lookupPaneEl\.addEventListener\('wheel', window\.__fushiPopupWheelListener/);
});

test('Shift popup no longer adds a forced 200ms fade to lookup latency', () => {
  assert.doesNotMatch(CONTENT, /transition:opacity 200ms/);
  assert.doesNotMatch(CONTENT, /fushiHost\.offsetWidth/);
});

test('lookup connection config is cached and invalidated only when settings change', () => {
  assert.match(BACKGROUND, /let connectionConfigPromise = null;/);
  assert.match(BACKGROUND, /if \(!connectionConfigPromise\)[\s\S]*?chrome\.storage\.local\.get/);
  assert.match(BACKGROUND, /changes\.host \|\| changes\.port \|\| changes\.token[\s\S]*?connectionConfigPromise = null/);
});

test('shared popup mouse listeners ignore events outside the dictionary shadow root', () => {
  assert.match(POPUP, /function __fushiEventInsidePopup\(e\)/);
  assert.match(POPUP, /document\.addEventListener\('click',[\s\S]*?if \(!__fushiEventInsidePopup\(e\)\) return;/);
});

test('shared popup yields between remaining dictionary entries', () => {
  assert.match(POPUP, /const renderNextEntry = \(\) =>/);
  assert.match(POPUP, /if \(nextEntryIndex < entries\.length\)[\s\S]*?setTimeout\(renderNextEntry, 0\)/);
});

test('lookup latency is logged by stage and exposed from extension settings', () => {
  assert.match(BACKGROUND, /LOOKUP_PERF_STORAGE_KEY = 'fushiLookupPerfLogs'/);
  assert.match(BACKGROUND, /stage: 'request-start'/);
  assert.match(BACKGROUND, /stage: 'still-pending'/);
  assert.match(BACKGROUND, /fetchHeadersMs:/);
  assert.match(BACKGROUND, /responseBodyMs:/);
  assert.match(BACKGROUND, /outerJsonParseMs:/);
  assert.match(BACKGROUND, /parseLookupServerTiming/);
  assert.match(BACKGROUND, /lookupTraceId: lookupId/);
  assert.match(BACKGROUND, /delete item\.term/);
  assert.match(SIDE_PANEL, /stage: 'client-response'/);
  assert.match(SIDE_PANEL, /innerJsonParseMs:/);
  assert.match(POPUP, /_emitPopupRenderPerf\('first-entry-dom'/);
  assert.match(POPUP, /_emitPopupRenderPerf\('cancelled'/);
  assert.match(SIDE_PANEL, /stage: 'visible-after-paint'/);
  assert.match(OPTIONS_HTML, /id="lookupPerfOutput"/);
  assert.match(OPTIONS, /type: 'lookupPerfGet'/);
  assert.match(OPTIONS, /type: 'lookupPerfClear'/);
});
