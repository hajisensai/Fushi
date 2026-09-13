const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function world() {
  const windowListeners = {}, documentListeners = {}, sent = [];
  function element() {
    return {
      children: [], attrs: {}, style: { values: {}, setProperty(k, v) { this.values[k] = v; } },
      appendChild(child) { this.children.push(child); },
      setAttribute(k, v) { this.attrs[k] = v; },
      listeners: {}, addEventListener(name, handler) { this.listeners[name] = handler; },
    };
  }
  const root = element(), host = element();
  const closeButton = element();
  host.attachShadow = () => root;
  const document = {
    documentElement: element(),
    getElementById: id => id === 'fushi-nested-root' ? host : id === 'fushi-nested-close' ? closeButton : null,
    createElement: element,
    addEventListener(name, handler) { documentListeners[name] = handler; },
  };
  const parent = { postMessage(data, origin) { sent.push({ data, origin }); } };
  const port = { postMessage(data) { sent.push({ data, channel: 'port' }); }, start() {} };
  let renders = 0, cssData = null, mediaRoot = null, autoReadOptions = null, minedIndex = null, highlighted = null;
  const window = {
    parent,
    addEventListener(name, handler) { windowListeners[name] = handler; },
    renderPopup() { renders++; },
    fushiAutoReadFirstEntry(_entries, options) { autoReadOptions = options; },
    fushiPopupMineEntryByIndex(index) { minedIndex = index; },
    fushiSelection: { highlightSelection(length) { highlighted = length; } },
  };
  const context = vm.createContext({ window, document, console,
    applyFushiPopupCss(data) { cssData = data; },
    installDictMediaPlaceholderResolver(value) { mediaRoot = value; },
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'nested-popup.js'), 'utf8'), context);
  function windowReceive(data, source = parent, ports = []) {
    windowListeners.message({ data: { __fushiPopupFrame: true, ...data }, source, ports });
  }
  function connect() { windowReceive({ type: 'connect' }, parent, [port]); }
  function receive(data, source) {
    if (source) { windowReceive(data, source); return; }
    if (!port.onmessage) connect();
    port.onmessage({ data: { __fushiPopupFrame: true, ...data } });
  }
  return { window, document, root, host, sent, parent, port, connect, windowReceive, receive, documentListeners, closeButton,
    get renders() { return renders; }, get cssData() { return cssData; },
    get mediaRoot() { return mediaRoot; }, get autoReadOptions() { return autoReadOptions; },
    get minedIndex() { return minedIndex; }, get highlighted() { return highlighted; } };
}

test('frame bootstraps its private root and bridge before shared popup scripts', () => {
  const html = fs.readFileSync(path.join(__dirname, 'nested-popup.html'), 'utf8');
  const scripts = [...html.matchAll(/<script src="([^"]+)"/g)].map(match => match[1]);
  assert.deepEqual(scripts, ['nested-popup.js', 'vendor/dict-media.js',
    'vendor/selection.js', 'vendor/popup.js', 'auto-read.js', 'ruby-render.js']);
  const w = world();
  assert.equal(w.window.__fushiRoot, w.root);
  assert.equal(w.root.children[2].id, 'entries-container');
  assert.equal(w.sent.length, 0);
  w.documentListeners.DOMContentLoaded();
  assert.equal(w.sent[0].data.type, 'ready');
});

test('window messages cannot render, mine or resolve calls; only the first transferred port owns the bridge', async () => {
  const w = world();
  const data = { popupJson: '[{"expression":"親"}]' };
  w.windowReceive({ type: 'render', data });
  assert.equal(w.renders, 0);
  w.windowReceive({ type: 'connect' }, {}, [w.port]);
  assert.equal(w.port.onmessage, undefined);
  w.windowReceive({ type: 'connect' });
  assert.equal(w.port.onmessage, undefined);
  w.connect();
  const attackerPort = { postMessage() {}, start() {} };
  w.windowReceive({ type: 'connect' }, w.parent, [attackerPort]);
  assert.equal(attackerPort.onmessage, undefined);
  w.receive({ type: 'render', data });
  w.windowReceive({ type: 'render', data });
  w.windowReceive({ type: 'mine', entryIndex: 0 });
  assert.equal(w.minedIndex, null);
  assert.equal(w.renders, 1);
  const call = w.window.flutter_inappwebview.callHandler('duplicateCheck', { expression: '親' });
  const message = w.sent.at(-1);
  assert.equal(message.channel, 'port');
  w.windowReceive({ type: 'reply', id: message.data.id, result: true });
  w.receive({ type: 'reply', id: message.data.id, result: false });
  assert.equal(await call, false);
});

test('render forwards shared CSS, audio, theme and queue state without changing another realm', () => {
  const w = world(), other = world();
  const data = { popupJson: '[{"expression":"子"}]', queuedExpressions: ['子'],
    theme: { '--dict-columns': '3', '--fushi-color-scheme': 'light', '--fushi-wheel-speed': '2' },
    audioSources: ['source'], autoReadOnLookup: true, sentenceContextPreviewEnabled: true, popupZoom: 1.25,
    dictionaryStyles: { dictionary: 'css' }, i18nCtx: { title: '上下文' } };
  w.receive({ type: 'render', data });
  assert.equal(w.window.lookupEntries[0].expression, '子');
  assert.equal(w.cssData, data);
  assert.equal(w.mediaRoot, w.root);
  assert.equal(w.window.fushiIsEntryQueued({ expression: '子' }), true);
  assert.equal(other.window.fushiIsEntryQueued({ expression: '子' }), false);
  assert.equal(w.document.documentElement.style.values['--dict-columns'], '3');
  assert.equal(w.root.children[2].attrs['data-theme'], 'light');
  assert.equal(w.window.sentenceContextPreviewEnabled, true);
  assert.equal(w.autoReadOptions.enabled, true);
  assert.equal(w.host.style.zoom, '1.25');
  assert.equal(w.host.style.width, '80%');
  assert.equal(w.host.style.height, '80%');
  w.receive({ type: 'hasChild', value: true });
  assert.equal(w.window.__hasChildPopup, true);
  assert.equal(w.renders, 1);
  w.receive({ type: 'hasChild', value: false });
  assert.equal(w.window.__hasChildPopup, false);
  assert.equal(w.renders, 1);
});

test('bridge keeps structured nested-selection arguments and updates queued membership on success', async () => {
  const w = world();
  w.connect();
  const rect = { left: 10, top: 20, width: 30, height: 40 };
  const lookup = w.window.flutter_inappwebview.callHandler('textSelected', '孫', rect);
  let message = w.sent.at(-1).data;
  assert.equal(message.name, 'textSelected');
  assert.equal(message.args[1], rect);
  w.receive({ type: 'reply', id: message.id, result: null });
  await lookup;
  const mine = w.window.flutter_inappwebview.callHandler('mineEntry', { expression: '孫' });
  message = w.sent.at(-1).data;
  assert.equal(w.window.fushiIsEntryQueued({ expression: '孫' }), false);
  w.receive({ type: 'reply', id: message.id, result: { queued: true } });
  assert.equal((await mine).queued, true);
  assert.equal(w.window.fushiIsEntryQueued({ expression: '孫' }), true);
  const failed = w.window.flutter_inappwebview.callHandler('openSentenceContextModal', { entryIndex: 2 });
  message = w.sent.at(-1).data;
  w.receive({ type: 'reply', id: message.id, error: '失败' });
  await assert.rejects(failed, /失败/);
});

test('frame activation, Escape and modal mine dispatch do not rerender the dictionary', () => {
  const w = world();
  w.connect();
  w.documentListeners.pointerdown();
  assert.equal(w.sent.at(-1).data.type, 'activate');
  let prevented = false, stopped = false;
  w.documentListeners.keydown({ key: 'Escape', preventDefault() { prevented = true; },
    stopPropagation() { stopped = true; } });
  assert.equal(prevented && stopped, true);
  assert.equal(w.sent.at(-1).data.type, 'close');
  w.receive({ type: 'mine', entryIndex: 2 });
  assert.equal(w.minedIndex, 2);
  w.receive({ type: 'mine', entryIndex: -1 });
  assert.equal(w.minedIndex, 2);
  assert.equal(w.renders, 0);
});

test('close button only closes its layer and parent highlight uses shared selection state', () => {
  const w = world();
  w.connect();
  w.closeButton.listeners.click();
  assert.equal(w.sent.at(-1).data.type, 'close');
  w.receive({ type: 'highlight', length: 2 });
  assert.equal(w.highlighted, 2);
  w.receive({ type: 'highlight', length: -1 });
  assert.equal(w.highlighted, 2);
  w.receive({ type: 'highlight', length: 5 }, {});
  assert.equal(w.highlighted, 2);
  assert.equal(w.renders, 0);
});
