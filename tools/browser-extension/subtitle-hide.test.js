const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// 「隐藏字幕」（用户诉求：浏览器侧对齐 app 内视频页的 videoToggleSubtitleHide）。
// 扩展此前只有作用于自绘覆盖层、悬停即恢复的防剧透模糊，站点原生字幕从不被遮。
//
// 本测试在受控 vm 里真加载 content.js，钉住三条最容易做错、且做错了会静默毁掉别的功能的性质：
//   ① 隐藏必须用 visibility/opacity，**绝不能**用 display:none 或删节点——扩展的取词、
//      逐句制卡、caret 兜底命中全靠读那些字幕节点的 textContent / 几何。display:none 会把
//      它们摘出布局，"隐藏字幕"就等于顺手废掉制卡。
//   ② 站点原生字幕（Netflix/YouTube）和扩展自绘覆盖层都要被藏——只藏一半等于没藏。
//   ③ 翻回「显示」时样式必须真的被移除（不是留着空规则），否则第二次开关就失效。
const CONTENT = path.join(__dirname, 'content.js');
const PANEL = path.join(__dirname, 'subtitle-panel.js');
const SHORTCUTS = path.join(__dirname, 'video-shortcuts.js');

// BUG-1718：真实运行时（manifest content_scripts / side-panel.html）里 vendor/dict-media.js
// 恒在 content.js / side-panel.js 之前加载，后者依赖它导出的 applyFushiPopupCss 与
// installDictMediaPlaceholderResolver。测试沙箱必须照同样顺序装，否则跑的是一个真实
// 世界里不存在的、缺半个脚本集的环境。
const FUSHI_DICT_MEDIA = require('node:path').join(__dirname, 'vendor', 'dict-media.js');
function loadFushiDictMedia(ctx) {
  require('node:vm').runInContext(
    require('node:fs').readFileSync(FUSHI_DICT_MEDIA, 'utf8'), ctx,
    { filename: 'vendor/dict-media.js' });
}


function makeEl(tag) {
  const el = {
    tagName: (tag || 'div').toUpperCase(),
    _id: '',
    className: '',
    textContent: '',
    style: { cssText: '', setProperty() {}, getPropertyValue: () => '' },
    dataset: {},
    children: [],
    parentNode: null,
    setAttribute(k, v) { if (k === 'id') el._id = v; },
    getAttribute() { return null; },
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener() {},
    appendChild(child) { child.parentNode = el; el.children.push(child); return child; },
    removeChild(child) {
      const i = el.children.indexOf(child);
      if (i >= 0) el.children.splice(i, 1);
      child.parentNode = null;
      return child;
    },
    remove() { if (el.parentNode) el.parentNode.removeChild(el); },
    contains(x) { return x === el || el.children.some((c) => c.contains && c.contains(x)); },
    getBoundingClientRect() {
      return { x: 0, y: 0, left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 };
    },
  };
  Object.defineProperty(el, 'id', { get: () => el._id, set: (v) => { el._id = v; } });
  return el;
}

function findById(el, id) {
  if (el._id === id) return el;
  for (const c of el.children) {
    const hit = findById(c, id);
    if (hit) return hit;
  }
  return null;
}

// storedHidden = 加载时 chrome.storage.local 里 subtitleHidden 的值（模拟「上次关了字幕」）。
function loadContent(storedHidden) {
  const src = fs.readFileSync(CONTENT, 'utf8');
  const head = makeEl('head');
  const body = makeEl('body');
  const html = makeEl('html');
  html.appendChild(head);
  const stored = { subtitleHidden: storedHidden };
  const changeListeners = [];
  const windowListeners = Object.create(null);
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0,
    clearTimeout() {},
    requestAnimationFrame: () => 0,
    getComputedStyle: () => ({ getPropertyValue: () => '' }),
    URL,
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    location: { hostname: 'www.netflix.com', href: 'https://www.netflix.com/watch/1', pathname: '/watch/1' },
  };
  sandbox.document = {
    documentElement: html,
    head,
    body,
    fullscreenElement: null,
    addEventListener() {},
    // 只在 head 里找（注入的 <style> 就挂在这），与 content.js 的 appendChild 目标一致。
    getElementById: (id) => findById(head, id),
    querySelector: () => null,
    querySelectorAll: () => [],
    createElement: (tag) => makeEl(tag),
    createTreeWalker: () => ({ nextNode: () => null }),
  };
  sandbox.chrome = {
    runtime: {
      id: 'test-ext-id',
      getURL: (rel) => `chrome-extension://test-ext-id/${rel}`,
      lastError: null,
      onMessage: { addListener() {} },
      sendMessage() {},
    },
    storage: {
      local: {
        // content.js 用回调式 get；这里同步回调，让加载即完成初始应用。
        get: (keys, cb) => {
          const out = {};
          for (const k of [].concat(keys)) if (k in stored) out[k] = stored[k];
          if (cb) cb(out);
          return Promise.resolve(out);
        },
        set: (patch, cb) => { Object.assign(stored, patch); if (cb) cb(); return Promise.resolve(); },
      },
      onChanged: { addListener: (fn) => changeListeners.push(fn) },
    },
  };
  sandbox.window = {
    addEventListener(type, listener) {
      (windowListeners[type] = windowListeners[type] || []).push(listener);
    },
    innerWidth: 1200,
    innerHeight: 800,
    matchMedia: () => ({ matches: false }),
    fushiSelection: {
      getCharacterAtPoint: () => null,
      selectFromPosition: () => '',
      clearSelection() {},
    },
    flutter_inappwebview: { callHandler() {} },
  };
  sandbox.window.window = sandbox.window;

  vm.createContext(sandbox);
  loadFushiDictMedia(sandbox);
  vm.runInContext(src, sandbox, { filename: 'content.js' });
  return { sandbox, head, stored, changeListeners, windowListeners };
}

const STYLE_ID = 'fushi-hide-subs';

test('隐藏字幕：注入的样式用 visibility 而非 display:none（否则制卡取词会一起废掉）', () => {
  const { sandbox, head } = loadContent(false);
  assert.strictEqual(findById(head, STYLE_ID), null, '默认不隐藏，不该有样式');

  assert.strictEqual(sandbox.window.fushiToggleSubtitleHiding(), true);
  const style = findById(head, STYLE_ID);
  assert.ok(style, '翻开后应注入 <style>');
  const css = style.textContent;
  assert.match(css, /visibility:\s*hidden/);
  assert.doesNotMatch(css, /display:\s*none/,
    'display:none 会把字幕节点摘出布局 → 取词/制卡/caret 命中一起失效');
});

test('隐藏字幕：站点原生字幕与扩展覆盖层都要被藏（只藏一半等于没藏）', () => {
  const { sandbox, head } = loadContent(false);
  sandbox.window.fushiToggleSubtitleHiding();
  const css = findById(head, STYLE_ID).textContent;
  assert.ok(css.includes('.player-timedtext'), 'Netflix 原生字幕');
  assert.ok(css.includes('.ytp-caption-window-container'), 'YouTube 原生字幕');
  assert.ok(css.includes('#fushi-subtitle-overlay'), '扩展自绘覆盖层');
  // 原生 <track> 字幕：::cue 只接受受限属性，必须单独成一条规则，否则整条规则可能失效。
  assert.match(css, /video::cue\s*\{/);
});

test('隐藏字幕：再按一次真的移除样式，且状态落 storage', () => {
  const { sandbox, head, stored } = loadContent(false);
  sandbox.window.fushiToggleSubtitleHiding();
  assert.ok(findById(head, STYLE_ID));
  assert.strictEqual(stored.subtitleHidden, true);

  sandbox.window.fushiToggleSubtitleHiding();
  assert.strictEqual(findById(head, STYLE_ID), null, '关掉后样式必须真被移除');
  assert.strictEqual(stored.subtitleHidden, false);
});

test('隐藏字幕：加载时读 storage 即生效（上次关了字幕，刷新页面仍是关的）', () => {
  const { head } = loadContent(true);
  assert.ok(findById(head, STYLE_ID), '存量为 true 时加载即应注入样式');
});

test('隐藏字幕：options 页改开关经 storage.onChanged 实时生效', () => {
  const { head, changeListeners } = loadContent(false);
  assert.ok(changeListeners.length > 0, 'content.js 应注册 storage.onChanged');
  for (const fn of changeListeners) {
    fn({ subtitleHidden: { newValue: true } }, 'local');
  }
  assert.ok(findById(head, STYLE_ID), 'onChanged 之后应注入样式');
  for (const fn of changeListeners) {
    fn({ subtitleHidden: { newValue: false } }, 'local');
  }
  assert.strictEqual(findById(head, STYLE_ID), null);
});

test('Shift+H 真链：keydown 经 subtitle-panel 转发到 content 并持久化隐藏状态', () => {
  const h = loadContent(false);
  const video = { currentTime: 0, paused: false, playbackRate: 1 };
  h.sandbox.document.querySelector = (selector) => selector === 'video' ? video : null;
  h.sandbox.setInterval = () => 0;
  h.sandbox.clearInterval = () => {};
  h.sandbox.navigator = {
    clipboard: { writeText: () => Promise.resolve() },
  };
  h.sandbox.self = h.sandbox.window;
  h.sandbox.window.fushiEpisodeCues = {};
  h.sandbox.window.fushiVideoKey = () => 'episode';

  vm.runInContext(
    fs.readFileSync(PANEL, 'utf8'),
    h.sandbox,
    { filename: 'subtitle-panel.js' },
  );
  vm.runInContext(
    fs.readFileSync(SHORTCUTS, 'utf8'),
    h.sandbox,
    { filename: 'video-shortcuts.js' },
  );

  const keydown = (h.windowListeners.keydown || []).at(-1);
  assert.strictEqual(typeof keydown, 'function', 'video-shortcuts 应注册 keydown');
  let prevented = false;
  let stopped = false;
  keydown({
    key: 'H',
    code: 'KeyH',
    shiftKey: true,
    ctrlKey: false,
    metaKey: false,
    altKey: false,
    target: null,
    preventDefault() { prevented = true; },
    stopPropagation() { stopped = true; },
  });

  assert.strictEqual(prevented, true, '真链执行成功后应接管 Shift+H');
  assert.strictEqual(stopped, true, '真链执行成功后应阻止站点重复处理');
  assert.strictEqual(h.stored.subtitleHidden, true,
    'subtitle-panel 必须调用 content 的持有者并写回 subtitleHidden');
  assert.ok(findById(h.head, STYLE_ID),
    'keydown → panel → content 真链必须立即注入隐藏字幕样式');
});
