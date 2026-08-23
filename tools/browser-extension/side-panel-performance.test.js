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
  // 行内文字 click=查词已恢复（详见下方专项守卫）；seek 只属于时间戳与行空白区域。
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

test('subtitle text click looks up the word (restored after native side-panel migration)', () => {
  // 行内文字单击=查词曾在 4ade5cae5f（迁原生 Side Panel）时随旧 UI 层一起丢失，用户复诉
  // 「点击查词不见了，只能 Shift 查」。钉三件事：text 有 click 监听、带选区守卫（保住双击
  // 选择文本）、stopPropagation（不冒泡成 row 的 seek），且走显式手势分支（announceMissing=true）。
  assert.match(
    SIDE_PANEL,
    /text\.addEventListener\('click'[\s\S]*?isCollapsed[\s\S]*?stopPropagation\(\)[\s\S]*?lookupAtPointer\(\{[\s\S]*?\}, true\)/,
  );
});

test('lookup pane closes on manual play dismiss / panel blur / list scroll', () => {
  assert.match(SIDE_PANEL, /msg\.type === 'fushiLookupDismiss'[\s\S]*?closeLookup\(\)/);
  assert.match(SIDE_PANEL, /window\.addEventListener\('blur', function \(\) \{ closeLookup\(\); \}\)/);
  assert.match(SIDE_PANEL, /listEl\.addEventListener\('wheel', function \(\) \{ closeLookup\(\); \}, \{ passive: true \}\)/);
  // 面板真关掉时通知 content 恢复由查词暂停的视频。
  assert.match(SIDE_PANEL, /wasOpen[\s\S]*?fushiSubtitleSidePanelLookupClosed/);
});

test('lookup pane is user-resizable and persists via the popupSize channel', () => {
  const css = fs.readFileSync(path.join(__dirname, 'side-panel.css'), 'utf8');
  assert.match(css, /\.lookup-pane \{[^}]*resize: both/);
  assert.match(SIDE_PANEL, /lookupUserResized = true;[\s\S]*?type: 'popupSize'/);
  // 用户拖过后主题下发不得再覆盖宽高。
  assert.match(SIDE_PANEL, /if \(!lookupUserResized\) \{[\s\S]*?--fushi-popup-max-width/);
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
  // 真实实现叫 renderNextDictionaryBlock（vendor/popup.js），语义是「每个宏任务最多建
  // 一个词典块」：首词条首块渲染完就先 _firePopupRendered，余块/余词条全部排进宏任务队列。
  assert.match(POPUP, /const renderNextDictionaryBlock = \(\) => \{/);
  // 还有未建的块或词条时必须 setTimeout(..., 0) 让出宏任务，而不是同步 while/for 一次建完。
  assert.match(
    POPUP,
    /if \(activeEntryElement \|\| nextEntryIndex < entries\.length\) \{\s*\n\s*setTimeout\(renderNextDictionaryBlock, 0\);/,
  );
  // 两处调度：首批渲染后启动队列 + 每建一块后续跑。少一处就说明某条路径退回同步渲染。
  const yieldSites = POPUP.match(/setTimeout\(renderNextDictionaryBlock, 0\)/g) || [];
  assert.strictEqual(yieldSites.length, 2, '渐进渲染的宏任务让出点必须有且仅有 2 处');
  // 让出点之外不得再有同步续跑的直呼（renderNextDictionaryBlock() 裸调用）。
  assert.doesNotMatch(POPUP, /(?<!function )renderNextDictionaryBlock\(\)\s*;/);
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
