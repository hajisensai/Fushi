const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, 'nested-popup-host.js'), 'utf8');
const origin = 'chrome-extension://test-extension';
const flush = () => new Promise(resolve => setImmediate(resolve));

function harness(handler = () => null) {
  const frames = [], lookups = [], listeners = {}, calls = [];
  class MockMessageChannel {
    constructor() {
      const makePort = () => ({
        closed: false, onmessage: null, start() {},
        close() { this.closed = true; },
        postMessage(data) {
          if (!this.closed && !this.peer.closed) this.peer.onmessage?.({ data });
        },
      });
      this.port1 = makePort(); this.port2 = makePort();
      this.port1.peer = this.port2; this.port2.peer = this.port1;
    }
  }
  let focusCount = 0, renderCount = 0, resumeCount = 0;
  const root = {
    scrollTop: 312, innerHTML: 'unchanged parent dictionary',
    getBoundingClientRect: () => ({ left: 40, top: 60 }),
    focus: () => focusCount++,
  };
  const window = {
    innerWidth: 1280, innerHeight: 900,
    addEventListener: (name, callback) => { listeners[name] = callback; },
    fushiIsEntryQueued: () => false,
    renderPopup: () => renderCount++,
    flutter_inappwebview: {
      callHandler: (name, ...args) => { calls.push({ name, args }); return handler(name, ...args); },
    },
  };
  const context = vm.createContext({
    window, URL, Promise, console, MessageChannel: MockMessageChannel,
    chrome: { runtime: {
      id: 'test-extension',
      getURL: file => origin + '/' + file,
      sendMessage: (message, callback) => lookups.push({ message, callback }),
    } },
    document: {
      createElement: tag => {
        assert.equal(tag, 'iframe');
        const frame = {
          style: {}, messages: [], windowMessages: [], removed: false,
          setAttribute() {},
          remove() { this.removed = true; },
          focus() { focusCount++; },
          getBoundingClientRect: () => ({ left: 100, top: 120 }),
        };
        frame.contentWindow = { postMessage: (message, targetOrigin, ports) => {
          assert.equal(targetOrigin, origin, 'use the actual extension origin');
          frame.windowMessages.push(message);
          assert.equal(message.type, 'connect', 'public channel transfers only the port');
          assert.equal(ports.length, 1);
          frame.port = ports[0];
          frame.port.onmessage = event => frame.messages.push(event.data);
        } };
        return frame;
      },
      body: { appendChild: frame => frames.push(frame) },
    },
    fushiHost: root,
    fushiPendingCueWindow: { cue: 'root sentence' },
    fushiSentenceCtx: { prev: 2, next: 1 },
    FUSHI_CTX_I18N: {},
    fushiResolvePopupBox: () => ({ width: 500, maxHeight: 500, zoom: 1 }),
    fushiComputePlacement: () => ({ left: 100, top: 120, maxHeight: 500 }),
    fushiCurrentCueLocation: () => ({ index: 0 }),
    fushiShowConnectionFailure() {},
    fushiResumeVideo: () => resumeCount++,
  });
  vm.runInContext(source, context, { filename: 'nested-popup-host.js' });
  const replyLookup = (index, expression = '子', ready = true) => {
    const before = frames.length;
    lookups[index].callback({
      ok: true, data: { popupJson: JSON.stringify([{ expression }]), theme: {} },
    });
    if (ready && frames.length > before) event(frames.at(-1), { type: 'ready' });
  };
  const event = (frame, message, overrides = {}) => listeners.message({
    data: { __fushiPopupFrame: true, ...message },
    source: frame.contentWindow, origin, ...overrides,
  });
  const portEvent = (frame, message) => frame.port.postMessage({ __fushiPopupFrame: true, ...message });
  const call = (frame, name, args = [], id = 1) => portEvent(frame, { type: 'call', name, args, id });
  const live = () => frames.filter(frame => !frame.removed);
  return { context, root, window, frames, lookups, calls, live, event, portEvent, call, replyLookup,
    api: window.fushiNestedPopups,
    counts: () => ({ focusCount, renderCount, resumeCount }) };
}

test('nested lookup preserves parent DOM, scroll and pause, revealing child only when rendered', () => {
  const h = harness();
  h.api.open('子', { x: 80, y: 100 });
  assert.equal(h.live().length, 0);
  h.replyLookup(0);
  const child = h.frames[0];
  assert.equal(h.root.innerHTML, 'unchanged parent dictionary');
  assert.equal(h.root.scrollTop, 312);
  assert.equal(h.counts().renderCount, 0);
  assert.match(child.style.cssText, /visibility:hidden/);
  h.event(child, { type: 'ready' });
  assert.equal(child.messages.filter(message => message.type === 'render').length, 1);
  h.call(child, 'popupRendered', [240]);
  assert.equal(child.style.visibility, 'visible');
  assert.equal(h.counts().resumeCount, 0);
});

test('two children keep ancestry; parent tapOutside removes only descendants', () => {
  const h = harness();
  h.api.open('子'); h.replyLookup(0);
  const child = h.frames[0];
  h.call(child, 'textSelected', ['孫', { x: 10, y: 20 }]); h.replyLookup(1);
  assert.equal(h.live().length, 2);
  assert.equal(h.window.__hasChildPopup, true);
  assert.equal(child.messages.filter(message => message.type === 'hasChild').at(-1).value, true);
  h.call(child, 'tapOutside');
  assert.deepEqual(h.live(), [child]);
  assert.equal(child.messages.filter(message => message.type === 'hasChild').at(-1).value, false);
  h.call(child, 'tapOutside');
  assert.deepEqual(h.live(), [child]);
  assert.equal(h.counts().resumeCount, 0);
});

test('Escape pop and explicit child close return one level without resuming the video', () => {
  const h = harness();
  h.api.open('子'); h.replyLookup(0);
  h.call(h.frames[0], 'onLinkClick', ['孫']); h.replyLookup(1);
  assert.equal(h.api.pop(), true);
  assert.deepEqual(h.live(), [h.frames[0]]);
  h.portEvent(h.frames[0], { type: 'close' });
  assert.equal(h.live().length, 0);
  assert.equal(h.window.__hasChildPopup, false);
  assert.equal(h.api.pop(), false);
  assert.equal(h.counts().focusCount, 2);
  assert.equal(h.counts().resumeCount, 0);
});

test('root dismissal cancels pending lookup and cannot recreate a closed popup', () => {
  const h = harness();
  h.api.open('子');
  h.api.clear();
  h.context.fushiHost = null;
  h.replyLookup(0);
  assert.equal(h.frames.length, 0);
});

test('latest concurrent lookup wins, including new lookup from an ancestor', () => {
  const h = harness();
  h.api.open('古い'); h.api.open('新しい');
  h.replyLookup(1, '新しい'); h.replyLookup(0, '古い');
  assert.equal(h.frames.length, 1);
  assert.match(h.frames[0].title, /新しい/);
  h.call(h.frames[0], 'textSelected', ['子']);
  h.api.open('別の親の子');
  h.replyLookup(2); h.replyLookup(3);
  assert.equal(h.live().length, 1);
  assert.match(h.live()[0].title, /別の親の子/);
});

test('frame bridge checks both origin and exact live frame source', () => {
  const h = harness();
  h.api.open('子'); h.replyLookup(0, '子', false);
  const child = h.frames[0], before = child.messages.length;
  h.event(child, { type: 'ready' }, { origin: 'https://hostile.example' });
  h.event(child, { type: 'ready' }, { source: {} });
  assert.equal(child.messages.length, before);
  assert.equal(child.port, undefined);
  h.event(child, { type: 'ready' });
  h.event(child, { type: 'call', name: 'mineEntry', args: [{ expression: 'forged' }], id: 99 });
  h.event(child, { type: 'close' });
  assert.equal(h.live().length, 1, 'public close must not dismiss a layer');
  assert.equal(h.calls.length, 0, 'public calls cannot execute mining');
  h.call(child, 'unregisteredBridge', ['ignored']);
  assert.equal(h.calls.length, 0);
  const connectedCount = child.messages.length;
  h.api.clear();
  assert.equal(child.port.peer.closed, true, 'retired host port is closed');
  h.event(child, { type: 'ready' });
  h.call(child, 'mineEntry', [{ expression: 'retired' }]);
  assert.equal(h.calls.length, 0);
  assert.equal(child.messages.length, connectedCount);
});

test('asynchronous bridge replies are not delivered to a closed frame or its replacement', async () => {
  let resolve;
  const h = harness(() => new Promise(done => { resolve = done; }));
  h.api.open('子'); h.replyLookup(0);
  const child = h.frames[0];
  h.call(child, 'mineEntry', [{ expression: '子' }], 42);
  assert.equal(h.calls.length, 1);
  h.api.clear();
  h.api.open('次'); h.replyLookup(1);
  resolve({ queued: true });
  await flush();
  for (const frame of h.frames) {
    assert.equal(frame.messages.some(message => message.type === 'reply' && message.id === 42), false);
  }
  assert.equal(h.counts().resumeCount, 0);
});
