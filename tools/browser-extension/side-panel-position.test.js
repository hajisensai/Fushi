const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, 'side-panel.js'), 'utf8');
const flush = async () => { for (let i = 0; i < 8; i++) await new Promise(setImmediate); };
const cues = [
  { startMs: 10000, endMs: 12000, text: 'first' },
  { startMs: 20000, endMs: 22000, text: 'second' },
  { startMs: 30000, endMs: 32000, text: 'third' },
];

function loadPanel(initialState) {
  const elements = new Map();
  const scrolls = [];
  let state = initialState;
  let poll;
  function element() {
    const classes = new Set();
    const el = {
      children: [], handlers: {}, dataset: {}, style: { setProperty() {}, removeProperty() {} },
      hidden: true, value: '', innerHTML: '',
      classList: {
        add(name) { classes.add(name); }, remove(name) { classes.delete(name); },
        toggle(name, on) { if (on) classes.add(name); else classes.delete(name); },
        contains(name) { return classes.has(name); },
      },
      addEventListener(name, fn) { (this.handlers[name] ||= []).push(fn); },
      appendChild(child) { this.children.push(child); return child; },
      attachShadow() { return element(); }, querySelector() { return null; },
      querySelectorAll() { return []; }, contains() { return false; },
      setAttribute() {}, getAttribute() { return null; }, removeAttribute() {},
      scrollIntoView(options) { scrolls.push({ index: Number(this.dataset.index), options }); },
    };
    Object.defineProperty(el, 'textContent', { set() { this.children = []; }, get() { return ''; } });
    return el;
  }
  const document = {
    getElementById(id) { if (!elements.has(id)) elements.set(id, element()); return elements.get(id); },
    createElement: element, createDocumentFragment: element, addEventListener() {},
    querySelector() { return null; }, querySelectorAll() { return []; },
    body: element(), documentElement: element(),
  };
  const listeners = { addListener() {} };
  const context = {
    document, window: { addEventListener() {}, innerWidth: 400, innerHeight: 800 },
    chrome: {
      runtime: { getURL: (url) => url, onMessage: listeners, sendMessage(_msg, cb) { if (cb) cb({}); } },
      storage: { local: { get(_key, cb) { cb({}); } }, onChanged: listeners },
      tabs: {
        query(_query, cb) { cb([{ id: 1 }]); },
        sendMessage(_id, msg, cb) { cb({ ...state, cues: msg.includeCues ? state.cues : undefined }); },
        onActivated: listeners, onUpdated: listeners,
      },
    },
    installDictMediaPlaceholderResolver() {}, applyFushiPopupCss() {},
    setInterval(fn) { poll = fn; }, setTimeout() {}, clearTimeout() {},
    requestAnimationFrame() {}, performance: { now: () => 0 },
    navigator: { language: 'zh-CN' }, URL, console,
  };
  vm.runInNewContext(source, context, { filename: 'side-panel.js' });
  return {
    scrolls,
    async update(next) { state = next; poll(); await flush(); },
    fire(id, name) { for (const fn of elements.get(id).handlers[name] || []) fn({}); },
    rows() { return elements.get('list').children[0].children; },
  };
}

function state(time, items = cues, signature = 'loaded') {
  return { ok: true, hasVideo: true, videoKey: 'video', activeLang: 'ja', currentTimeMs: time,
    tracks: [{ lang: 'ja', label: 'Japanese', signature, length: items.length }], cues: items };
}

test('opening in a subtitle gap centers the closest cue without highlighting it', async () => {
  const h = loadPanel(state(28000));
  await flush();
  assert.equal(h.scrolls.length, 1);
  assert.equal(h.scrolls[0].index, 2);
  assert.equal(h.scrolls[0].options.behavior, 'instant');
  assert.ok(h.rows().every((row) => !row.classList.contains('is-current')));
  await h.update(state(28100));
  assert.equal(h.scrolls.length, 1, 'same nearest cue does not restart scrolling each poll');
});

test('opening during a cue centers and highlights the current cue', async () => {
  const h = loadPanel(state(21000));
  await flush();
  assert.equal(h.scrolls[0].index, 1);
  assert.equal(h.rows()[1].classList.contains('is-current'), true);
});

test('opening before/after subtitles uses first/last cue', async () => {
  for (const [time, index] of [[0, 0], [50000, 2], [14000, 0]]) {
    const h = loadPanel(state(time));
    await flush();
    assert.equal(h.scrolls[0].index, index);
  }
});

test('late playback time still performs initial placement', async () => {
  const h = loadPanel(state(undefined));
  await flush();
  assert.equal(h.scrolls.length, 0);
  await h.update(state(28000));
  assert.equal(h.scrolls[0].index, 2);
  assert.equal(h.scrolls[0].options.behavior, 'instant');
});

test('late subtitle track uses the latest playback time', async () => {
  const h = loadPanel(state(21000, [], 'pending'));
  await flush();
  assert.equal(h.scrolls.length, 0);
  await h.update(state(28000));
  assert.equal(h.scrolls[0].index, 2);
});

test('manual scrolling keeps the viewport until follow is explicitly reenabled', async () => {
  const h = loadPanel(state(11000));
  await flush();
  h.fire('list', 'wheel');
  await h.update(state(21000));
  assert.equal(h.scrolls.length, 1);
  assert.equal(h.rows()[1].classList.contains('is-current'), true);
  h.fire('auto-scroll', 'click');
  assert.equal(h.scrolls.length, 2);
  assert.equal(h.scrolls[1].index, 1);
});
