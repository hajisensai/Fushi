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
    /event\.key === 'Shift'[\s\S]*?!event\.repeat[\s\S]*?lookupAtPointer\(lastPointer, \{ explicit: true, announceMissing: true \}\)/,
  );
  assert.doesNotMatch(SIDE_PANEL, /removeAllRanges|preventDefault\(\)/);
});

test('subtitle text click looks up the word (restored after native side-panel migration)', () => {
  // 行内文字单击=查词曾在 4ade5cae5f（迁原生 Side Panel）时随旧 UI 层一起丢失，用户复诉
  // 「点击查词不见了，只能 Shift 查」。钉三件事：text 有 click 监听、带选区守卫（保住双击
  // 选择文本）、走显式手势分支（explicit），且**取到词才** stopPropagation。
  assert.match(
    SIDE_PANEL,
    /text\.addEventListener\('click'[\s\S]*?isCollapsed[\s\S]*?lookupAtPointer\(\{[\s\S]*?\}, \{ explicit: true \}\)/,
  );
  // 文字块占满整行宽度：点文字右侧空白同样落在它身上，取不到词时这一击必须继续冒泡到 row
  // 的 seek（用户报「点击空白位置不会跳转到这句」，那时只剩一条「未识别到可查词文字」）。
  assert.match(SIDE_PANEL, /var started = lookupAtPointer\([\s\S]*?if \(started\) event\.stopPropagation\(\);/);
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
  // 用户拖过后主题下发不得再覆盖**宽高**——但只锁这两项。
  assert.match(
    SIDE_PANEL,
    /if \(!lookupUserResized\) \{\s*lookupPaneEl\.style\.width = box\.width \+ 'px';[\s\S]*?lookupPaneEl\.style\.maxHeight = lookupBaseMaxHeight;\s*\}/,
  );
  // zoom 由 app 的「词典字号」下发，拖把手改不到它，因此必须留在门外无条件跟随。
  // 早退整个函数会让用户拖过一次后再改字号永远不生效（本会话内不可恢复）。
  assert.doesNotMatch(SIDE_PANEL, /if \(lookupUserResized\) return;/);
  assert.match(
    SIDE_PANEL,
    /\}\s*lookupPaneEl\.style\.maxWidth = 'calc\(100vw - 16px\)';\s*lookupPaneEl\.style\.zoom = String\(box\.zoom\);/,
  );
  // 尺寸盒必须经 popup-size.js 的决策器并带上**本文档视口**：直接写 theme px 的老写法
  // 在 CSS zoom 之下必然溢出窄侧边栏（右半边被 overflow-x 切掉）。
  assert.match(
    SIDE_PANEL,
    /fushiResolvePopupBox\(\s*lookupThemeForBox, \{ width: window\.innerWidth, height: window\.innerHeight \}\)/,
  );
  assert.doesNotMatch(SIDE_PANEL, /style\.width = theme\[/);
  // 侧边栏宽度可拖：视口一变就重算尺寸盒，否则变窄后仍按旧宽渲染 = 又被切。
  assert.match(SIDE_PANEL, /addEventListener\('resize', function \(\) \{\s*applyLookupBox\(\)/);
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
  // 一个时间片的词典块」：首词条首块渲染完就先 _firePopupRendered，余块/余词条全部排进
  // 宏任务队列。BUG-2039 把让出点从裸 setTimeout 换成 scheduleRenderTail（MessageChannel
  // 优先、setTimeout 兜底），**让出这件事本身没变**，所以判据跟着换调度器名字即可。
  assert.match(POPUP, /const renderNextDictionaryBlock = \(\) => \{/);
  // 还有未建的块或词条时必须让出宏任务，而不是同步 while/for 一次建完。
  assert.match(
    POPUP,
    /if \(activeEntryElement \|\| nextEntryIndex < entries\.length\) \{\s*\n\s*scheduleRenderTail\(renderNextDictionaryBlock\);/,
  );
  // 两处调度：首批渲染后启动队列 + 每建一片后续跑。少一处就说明某条路径退回同步渲染。
  const yieldSites = POPUP.match(/scheduleRenderTail\(renderNextDictionaryBlock\)/g) || [];
  assert.strictEqual(yieldSites.length, 2, '渐进渲染的宏任务让出点必须有且仅有 2 处');
  // 让出点之外不得再有同步续跑的直呼（renderNextDictionaryBlock() 裸调用）。
  assert.doesNotMatch(POPUP, /(?<!function )renderNextDictionaryBlock\(\)\s*;/);
});

// BUG-2039 之后补的一环：上面那条只证明「调用了调度器」，证明不了「调度器真的让出」。
// 把 scheduleRenderTail 的函数体换成 `task()` 同步直呼，上面四条断言**全部照绿**——而渐进
// 渲染已经退化成一次同步建完。所以调度器自己也必须被钉住。
test('scheduleRenderTail 真的让出宏任务，不得同步执行 task', () => {
  const head = 'function scheduleRenderTail(task) {';
  const start = POPUP.indexOf(head);
  assert.notStrictEqual(start, -1, '找不到 scheduleRenderTail —— 判据锚点已失效');
  const end = POPUP.indexOf('\n}', start);
  assert.notStrictEqual(end, -1, '取不到 scheduleRenderTail 函数体');
  // 剥注释再判：实测过一次——把函数体换成 `task();` 但在注释里留下
  // `postMessage` / `setTimeout(task, 0)` 字面量，下面两条**要求型**断言会被注释满足。
  // （本函数很短、体内无正则字面量也无含 `//` 的字符串，这个朴素剥法足够。）
  const body = POPUP.slice(start + head.length, end)
      .replace(/\/\*[\s\S]*?\*\//g, ' ')
      .replace(/\/\/[^\n]*/g, ' ');
  // 自校验：窗口没塌成空壳（下面的否定断言在空串上恒真）。
  assert.ok(body.length > 40, 'scheduleRenderTail 函数体窗口异常小，判据已失效');
  assert.match(body, /setTimeout\(task, 0\)/, '必须保留 setTimeout 兜底路径');
  assert.match(body, /postMessage\(/, '快路径必须经消息队列让出，而不是直接跑');
  // 核心不变式：函数体里不得出现同步直呼。
  assert.doesNotMatch(body, /(?<![.\w])task\(\)/,
      'scheduleRenderTail 不得同步执行 task —— 那等于取消了渐进渲染');
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
