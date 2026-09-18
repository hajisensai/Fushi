// BUG-2575 / BUG-2576：VN 量尺盒尺寸优先级 + restore 进度落屏的行为级跑手（由
// vn_measure_box_restore_progress_behavior_test.dart 用 node 执行，argv[2] = payload.json）。
//
// 断言依赖的生产字面量（供变异实测对照）：
// - root.style.setProperty('width', screenBox.width + 'px', 'important');   （量尺宽 important）
// - root.style.setProperty('height', screenBox.height + 'px', 'important'); （量尺高 important）
// - if (target >= 0.99) return this.screens.length - 1;                    （restore 章末）
// - index = this.screenIndexForRestoreProgress(this.initialProgress);       （fragment 失效回退）
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
function assert(value, message) {
  if (!value) throw new Error(message);
}

// 抠出 `window.fushiReader = { ... };` 对象字面量（VN 主对象；shim IIFE 在它之后）。
const shell = data.shell;
const startMarker = '\nwindow.fushiReader = {\n';
const endMarker = '\n};\n';
const start = shell.indexOf(startMarker);
assert(start >= 0, 'window.fushiReader object literal not found in the generated VN shell');
const end = shell.indexOf(endMarker, start);
assert(end > start, 'window.fushiReader object literal has no terminator');
const literal = shell.slice(start + startMarker.length - 2, end + 2); // "{ ... }"

// 对象字面量只在求值时建对象，不执行任何方法；C 只需要它读到的字段存在。
const C = {
  vnRevealSpeed: 0, vnScreenMode: 'block', vnSentencesPerScreen: 1, vnPreserveDialogue: true,
  vnMergeCrossScreenSentenceAudioCues: false, sentenceAudioCues: null,
  initialProgress: 0, initialFragment: null
};
const window = {};
// document 替身：方法体里的裸 `document` 通过 Function 形参解析到它。
const document = {
  createRange() { return {}; },
  createElement() { return elementDouble(); }
};
const proto = new Function('C', 'window', 'document', 'return (' + literal + ');')(C, window, document);

// ── CSSStyleDeclaration 替身：记录 setProperty 的优先级 ─────────────────────
function styleDouble() {
  const props = {};
  const style = {
    setProperty(name, value, priority) { props[name] = {value: value, priority: priority || ''}; },
    getPropertyValue(name) { return props[name] ? props[name].value : ''; },
    getPropertyPriority(name) { return props[name] ? props[name].priority : ''; },
    _props: props
  };
  // 裸赋值（root.style.left = ...）走普通优先级。
  return new Proxy(style, {
    set(target, key, value) {
      if (typeof key === 'string' && !(key in target)) { props[key] = {value: value, priority: ''}; return true; }
      target[key] = value; return true;
    }
  });
}
function elementDouble() {
  const el = {
    className: '', attrs: {}, children: [], style: styleDouble(),
    setAttribute(k, v) { this.attrs[k] = v; },
    appendChild(child) { this.children.push(child); child.parentNode = this; return child; }
  };
  return el;
}

// ── ① createScreenMeasurement：宽高必须以 important 写入，否则被 `.fushi-vn-screen`
//      样式表里的 `100% !important` 压掉、量尺恒为整视口 ─────────────────────
{
  const vn = Object.assign(Object.create(proto), {
    stage: elementDouble(),
    screen: Object.assign(elementDouble(), {
      getBoundingClientRect() { return {left: 0, top: 60, width: 393, height: 702}; }
    })
  });
  const m = vn.createScreenMeasurement();
  assert(m && m.root && m.content, 'createScreenMeasurement must return {root, content}');
  assert(m.root.style.getPropertyValue('width') === '393px',
    'mirror width must copy the real screen box, got ' + m.root.style.getPropertyValue('width'));
  assert(m.root.style.getPropertyValue('height') === '702px',
    'mirror height must copy the real screen box, got ' + m.root.style.getPropertyValue('height'));
  assert(m.root.style.getPropertyPriority('width') === 'important',
    'mirror width must be written with !important (stylesheet has width:100% !important)');
  assert(m.root.style.getPropertyPriority('height') === 'important',
    'mirror height must be written with !important (stylesheet has height:100% !important)');
  assert(m.root.style.getPropertyValue('left') === '0px' && m.root.style.getPropertyValue('top') === '60px',
    'mirror must sit at the real screen box origin');
  assert(vn.stage.children.indexOf(m.root) >= 0, 'mirror must be mounted under the stage');
}

// ── ② 无真实盒时的兜底同样要 important ──────────────────────────────────────
{
  const vn = Object.assign(Object.create(proto), {
    stage: elementDouble(),
    screen: Object.assign(elementDouble(), { getBoundingClientRect() { return {left: 0, top: 0, width: 0, height: 0}; } })
  });
  const m = vn.createScreenMeasurement();
  assert(m.root.style.getPropertyPriority('width') === 'important' &&
    m.root.style.getPropertyPriority('height') === 'important',
    'fallback mirror size must also be written with !important');
}

// ── ③ restore 口径：>= 0.99 落末屏；其余走进度锚 ────────────────────────────
function screensOf(anchors) {
  return anchors.map((a, i) => ({progressAnchor: a, startCharCount: i * 10, endCharCount: i * 10 + 10}));
}
{
  // 200 屏的长章：尾锚线性分布，0.99 按锚只能落到第 198 屏（还差一屏才是章末）。
  const anchors = [];
  for (let i = 1; i <= 200; i++) anchors.push(i / 200);
  const vn = Object.assign(Object.create(proto), {screens: screensOf(anchors), totalChapterChars: 2000});
  assert(vn.screenIndexForProgress(0.99) === 197,
    'sanity: linear anchor lookup for 0.99 lands before the last screen, got ' + vn.screenIndexForProgress(0.99));
  assert(vn.screenIndexForRestoreProgress(0.99) === 199,
    'restore progress >= 0.99 must land on the LAST screen (chapter end), got ' + vn.screenIndexForRestoreProgress(0.99));
  assert(vn.screenIndexForRestoreProgress(1) === 199, 'restore progress 1.0 must land on the last screen');
  assert(vn.screenIndexForRestoreProgress(0.5) === 99,
    'restore progress below the chapter-end threshold must still use the anchors, got ' + vn.screenIndexForRestoreProgress(0.5));
  assert(vn.screenIndexForRestoreProgress(0) === 0, 'restore progress 0 must land on the first screen');
  const empty = Object.assign(Object.create(proto), {screens: [], totalChapterChars: 0});
  assert(empty.screenIndexForRestoreProgress(0.99) === 0, 'empty screen table must degrade to 0');
}

// ── ④ restoreProgress 入口走 restore 口径；renderInitialScreen 的 fragment 失效回退进度 ──
{
  const anchors = [];
  for (let i = 1; i <= 50; i++) anchors.push(i / 50);
  function makeVn(extra) {
    const log = {render: []};
    const vn = Object.assign(Object.create(proto), {
      log: log, screens: screensOf(anchors), totalChapterChars: 500, revealSpeed: 45,
      readyPromise: Promise.resolve(),
      renderScreen(i, full) { log.render.push([i, !!full]); this.currentScreenIndex = i; },
      notifyRestoreComplete() { log.notified = true; },
      screenIndexForFragment(f) { return f === 'known' ? 7 : -1; }
    }, extra || {});
    return vn;
  }
  const a = makeVn();
  return Promise.resolve()
    .then(() => a.restoreProgress(0.99))
    .then(() => {
      assert(a.log.render.length === 1 && a.log.render[0][0] === 49 && a.log.render[0][1] === true,
        'restoreProgress(0.99) must render the last screen fully revealed, got ' + JSON.stringify(a.log.render));
      assert(a.log.notified === true, 'restoreProgress must notify restore complete');

      const b = makeVn({initialFragment: 'known', initialProgress: 0.5});
      b.renderInitialScreen();
      assert(b.log.render[0][0] === 7, 'known fragment wins over progress, got ' + JSON.stringify(b.log.render));

      const c = makeVn({initialFragment: 'missing', initialProgress: 0.5});
      c.renderInitialScreen();
      assert(c.log.render[0][0] === 24,
        'unresolvable fragment must fall back to the progress anchor (screen 24), got ' + JSON.stringify(c.log.render));
      assert(c.log.render[0][1] === true, 'fallback landing must be fully revealed');

      const d = makeVn({initialFragment: 'missing', initialProgress: 0});
      d.renderInitialScreen();
      assert(d.log.render[0][0] === 0, 'no fragment + no progress must land on screen 0');

      const e = makeVn({initialFragment: null, initialProgress: 0.99});
      e.renderInitialScreen();
      assert(e.log.render[0][0] === 49,
        'initial progress 0.99 (previous-chapter landing) must open on the last screen, got ' + JSON.stringify(e.log.render));
      console.log('OK');
    });
}
