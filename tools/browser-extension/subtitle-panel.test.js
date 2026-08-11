const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const PANEL = path.join(__dirname, 'subtitle-panel.js');
const MANIFEST = require('./manifest.json');

function makeEl(tag) {
  const el = {
    tagName: String(tag || 'div').toUpperCase(), id: '', children: [], parentNode: null,
    handlers: {}, style: { setProperty() {}, getPropertyValue() { return ''; }, removeProperty() {} },
    setAttribute(name, value) { if (name === 'id') this.id = String(value); },
    getAttribute() { return null; },
    addEventListener(type, fn) { (this.handlers[type] = this.handlers[type] || []).push(fn); },
    appendChild(child) { child.parentNode = this; this.children.push(child); return child; },
    removeChild(child) { this.children = this.children.filter((it) => it !== child); child.parentNode = null; },
    scrollIntoView() {},
  };
  el.classList = { add() {}, remove() {}, toggle() {} };
  return el;
}

function findById(root, id) {
  if (root.id === id) return root;
  for (const child of root.children || []) {
    const match = findById(child, id);
    if (match) return match;
  }
  return null;
}

function loadController(options = {}) {
  const source = fs.readFileSync(PANEL, 'utf8');
  const body = makeEl('body');
  const video = {
    currentTime: 0,
    getBoundingClientRect() { return { left: 0, top: 0, width: 1280, height: 720 }; },
  };
  const runtimeListeners = [];
  const storageListeners = [];
  const sent = [];
  const posted = [];
  const windowObject = {
    fushiEpisodeCues: options.store || {},
    addEventListener() {},
    postMessage(message) { posted.push(message); },
    fushiLookupTermFromSidePanel(term, cue) { sent.push({ lookup: term, cue }); return true; },
  };
  const documentObject = {
    body,
    fullscreenElement: null,
    addEventListener() {},
    getElementById(id) { return findById(body, id); },
    querySelector(selector) { return selector === 'video' ? video : null; },
    querySelectorAll() { return []; },
    createElement: makeEl,
    createDocumentFragment() { return makeEl('fragment'); },
  };
  const sandbox = {
    window: windowObject,
    document: documentObject,
    location: {
      hostname: options.hostname || 'example.com',
      pathname: options.pathname || '/video/1',
      origin: 'https://' + (options.hostname || 'example.com'),
    },
    navigator: { clipboard: { writeText() { return Promise.resolve(); } } },
    setInterval() { return 1; },
    clearInterval() {},
    chrome: {
      storage: {
        local: {
          get(_key, callback) {
            if (callback) { callback(options.stored || { netflixSubtitlePanel: true }); return; }
            return Promise.resolve(options.stored || { netflixSubtitlePanel: true });
          },
          set() {},
        },
        onChanged: { addListener(fn) { storageListeners.push(fn); } },
      },
      runtime: {
        sendMessage(message) { sent.push(message); },
        onMessage: { addListener(fn) { runtimeListeners.push(fn); } },
      },
    },
  };
  vm.runInNewContext(source, sandbox, { filename: 'subtitle-panel.js' });

  function message(payload) {
    let response;
    for (const listener of runtimeListeners) {
      listener(payload, {}, (value) => { response = value; });
      if (response !== undefined) break;
    }
    return response;
  }

  return { body, video, windowObject, sent, posted, message };
}

const TRACKS = {
  '81001|ja': [{ startMs: 1000, endMs: 2000, text: 'こんにちは' }],
  '81001|en': [{ startMs: 1000, endMs: 2000, text: 'Hello' }],
  '81001|live': [{ startMs: 0, endMs: 500, text: 'live' }],
};

test('manifest registers Chrome native side panel', () => {
  assert.ok(MANIFEST.permissions.includes('sidePanel'));
  assert.deepStrictEqual(MANIFEST.side_panel, { default_path: 'side-panel.html' });
});

test('content controller never mounts a subtitle list into the host page DOM', () => {
  const harness = loadController({
    hostname: 'www.netflix.com', pathname: '/watch/81001', store: TRACKS,
  });
  assert.strictEqual(findById(harness.body, 'fushi-subtitle-panel'), null);
  assert.strictEqual(findById(harness.body, 'fushi-subtitle-reopen'), null);
  const state = harness.message({ type: 'fushiSubtitleSidePanelState', includeCues: true });
  assert.strictEqual(state.ok, true);
  assert.strictEqual(findById(harness.body, 'fushi-subtitle-panel'), null);
});

test('side panel state exposes all tracks, keeps live last, and returns active cues on demand', () => {
  const harness = loadController({
    hostname: 'www.netflix.com', pathname: '/watch/81001', store: TRACKS,
  });
  const state = harness.message({ type: 'fushiSubtitleSidePanelState', includeCues: true });
  assert.deepStrictEqual(Array.from(state.tracks, (track) => track.lang), ['en', 'ja', 'live']);
  assert.strictEqual(state.activeLang, 'en');
  assert.strictEqual(state.cues[0].text, 'Hello');
  assert.strictEqual(state.tracks[2].label, '实时采集');
});

test('generic seek changes video time while Netflix seek keeps the DRM bridge', () => {
  const generic = loadController({
    store: { 'example.com/video/1|ja': [{ startMs: 5000, endMs: 6000, text: '五秒' }] },
  });
  generic.message({ type: 'fushiSubtitleSidePanelSeek', ms: 5000 });
  assert.strictEqual(generic.video.currentTime, 5);

  const netflix = loadController({
    hostname: 'www.netflix.com', pathname: '/watch/81001', store: TRACKS,
  });
  netflix.message({ type: 'fushiSubtitleSidePanelSeek', ms: 1000 });
  assert.strictEqual(netflix.video.currentTime, 0);
  assert.strictEqual(netflix.posted[0].__fushiNf, 'seek');
  assert.strictEqual(netflix.posted[0].ms, 1000);
});

test('track selection, offset and lookup are routed through the content controller', () => {
  const harness = loadController({
    hostname: 'www.netflix.com', pathname: '/watch/81001', store: TRACKS,
  });
  let state = harness.message({ type: 'fushiSubtitleSidePanelSelectTrack', lang: 'ja' });
  assert.strictEqual(state.activeLang, 'ja');
  state = harness.message({ type: 'fushiSubtitleSidePanelOffset', deltaMs: 500 });
  assert.strictEqual(state.cues[0].startMs, 1500);
  assert.strictEqual(TRACKS['81001|ja'][0].startMs, 1000, 'raw store remains unchanged');
  const response = harness.message({
    type: 'fushiSubtitleSidePanelLookup', term: '今日', cue: state.cues[0],
  });
  assert.strictEqual(response.ok, true);
  assert.ok(harness.sent.some((entry) => entry.lookup === '今日'));
});
