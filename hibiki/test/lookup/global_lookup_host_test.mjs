// TODO-867 P3b — global_lookup_host.js renderStack DOM-diff harness (node).
// Run: node hibiki/test/lookup/global_lookup_host_test.mjs
//
// global_lookup_host.js is the app-OUTSIDE nested-stack host: it diffs a
// { popups: [...] } payload into a live frames Map of iframe shells. jsdom is
// NOT a dependency here (the existing test/lookup/*.mjs harnesses hand-roll a
// minimal DOM in a node:vm sandbox), so this test ships a tiny fake DOM that
// supports exactly the APIs host.js touches (createElement/appendChild/
// removeChild/setAttribute/style/addEventListener/getElementById) and asserts:
//   1. renderStack with N popups builds N frame shells (each a div>iframe);
//   2. iframe src is popup.html and carries NO `sandbox` attribute (the bridge
//      contract — sandbox without allow-same-origin would kill contentWindow
//      injection);
//   3. truncating the payload (closing children) removes the gone frames;
//   4. growing the payload (push child) adds a frame, keeps the survivors;
//   5. an empty payload clears the whole stack;
//   6. topPopupId() returns the deepest (last) frame id;
//   7. per-frame settingsJs is eval'd inside that frame's contentWindow realm;
//   8. D1 reveal gate: a shell starts gated-hidden (content-ready=false,
//      reveal-ready=false), flips reveal-ready once geometry is placed and
//      content-ready once the iframe DOM has a .glossary-content / non-zero body
//      height, and is only "visible" when BOTH flags are true;
//   9. D1 safety: a frame whose content never arrives is forced content-ready by
//      the host safety timer (no card stuck invisible);
//  10. D2 convergence: a content-ready burst across layers coalesces into a
//      single union-bbox overlaySize per frame (no thrash), de-duped on the box.

import assert from 'node:assert';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { runInNewContext } from 'node:vm';

const __dirname = dirname(fileURLToPath(import.meta.url));
const hostSrc = readFileSync(
  join(__dirname, '..', '..', 'assets', 'popup', 'global_lookup_host.js'),
  'utf8',
);

// ---- minimal fake DOM ----------------------------------------------------
// Just enough for host.js: element tree + style bag + attributes + listeners.
// Each iframe gets a fake contentWindow whose `eval` records the injected JS so
// we can assert per-frame settings injection without a real browser.
let evalLog = [];
let framePostLog = [];

function makeElement(tag) {
  const el = {
    tagName: tag.toUpperCase(),
    children: [],
    parentNode: null,
    style: {},
    attributes: {},
    _listeners: {},
    className: '',
    id: '',
    appendChild(child) {
      child.parentNode = el;
      el.children.push(child);
      return child;
    },
    removeChild(child) {
      const i = el.children.indexOf(child);
      if (i >= 0) el.children.splice(i, 1);
      child.parentNode = null;
      return child;
    },
    setAttribute(name, value) {
      el.attributes[name] = String(value);
    },
    getAttribute(name) {
      return Object.prototype.hasOwnProperty.call(el.attributes, name)
        ? el.attributes[name]
        : null;
    },
    hasAttribute(name) {
      return Object.prototype.hasOwnProperty.call(el.attributes, name);
    },
    addEventListener(type, fn) {
      (el._listeners[type] = el._listeners[type] || []).push(fn);
      // host.js attaches the iframe `load` handler right after appending the
      // iframe; a real browser then fires `load` once navigation completes.
      // Model that by firing synchronously when the load handler is attached
      // to an already-attached iframe (so injectContent runs in the test).
      if (type === 'load' && el.tagName === 'IFRAME' && el.parentNode) {
        el._loaded = true;
        fn();
      }
    },
  };
  if (tag === 'iframe') {
    // contentWindow.eval records what host.js injects per frame; chrome.webview
    // is the IN-FRAME bridge the host wraps (C1) so we can post a message AS the
    // child and capture the host-transformed envelope that reaches "C++".
    el.contentWindow = {
      eval(code) {
        evalLog.push({ frameId: el.parentNode && el.parentNode.attributes['data-frame-id'], code });
      },
      chrome: {
        webview: {
          postMessage(msg) {
            framePostLog.push(msg);
          },
        },
      },
    };
    // contentDocument for D1/D2: a mutable body height + a .glossary-content
    // flag + querySelector. _observers holds MutationObserver callbacks bound to
    // body so a test can simulate popup.js rendering content (fire the observer).
    const body = { scrollHeight: 0, offsetHeight: 0, _observers: [] };
    el.contentDocument = {
      body,
      documentElement: { scrollHeight: 0 },
      _hasGlossary: false,
      querySelector(sel) {
        if (sel === '.glossary-content') {
          return el.contentDocument._hasGlossary ? { tagName: 'DIV' } : null;
        }
        return null;
      },
    };
    // Test helper: simulate popup.js finishing render inside this iframe.
    el._renderContent = function (height) {
      el.contentDocument._hasGlossary = true;
      body.scrollHeight = height || 120;
      body.offsetHeight = height || 120;
      for (const cb of body._observers.slice()) {
        cb([{ type: 'childList' }]);
      }
    };
  }
  return el;
}

function makeDocument() {
  const body = makeElement('body');
  const head = makeElement('head');
  const doc = {
    body,
    head,
    documentElement: makeElement('html'),
    _byId: {},
    createElement(tag) {
      return makeElement(tag);
    },
    getElementById(id) {
      // host.js only looks up the layer + the gate <style> it created; track
      // ids on append (both body and head register).
      return doc._byId[id] || null;
    },
  };
  // Patch body+head appendChild to register ids (host.js sets layer.id /
  // style.id then appends). The gate <style> goes to head, the layer to body.
  const origBodyAppend = body.appendChild;
  body.appendChild = function (child) {
    if (child.id) doc._byId[child.id] = child;
    return origBodyAppend.call(body, child);
  };
  const origHeadAppend = head.appendChild;
  head.appendChild = function (child) {
    if (child.id) doc._byId[child.id] = child;
    return origHeadAppend.call(head, child);
  };
  return doc;
}

// Build a fresh sandbox + load host.js into it.
let hostPostLog = [];
let pendingTimers = [];
function freshHost(opts) {
  opts = opts || {};
  evalLog = [];
  framePostLog = [];
  hostPostLog = [];
  pendingTimers = [];
  const document = makeDocument();
  // MutationObserver stub: records observed body so a test can fire it via
  // el._renderContent (which walks body._observers). Disconnect detaches.
  function FakeMutationObserver(cb) {
    this._cb = cb;
    this._body = null;
  }
  FakeMutationObserver.prototype.observe = function (body) {
    this._body = body;
    body._observers.push(this._cb);
  };
  FakeMutationObserver.prototype.disconnect = function () {
    if (this._body) {
      const i = this._body._observers.indexOf(this._cb);
      if (i >= 0) this._body._observers.splice(i, 1);
      this._body = null;
    }
  };
  const sandbox = {
    window: {},
    document,
    Map,
    Set,
    WeakMap,
    WeakSet,
    Math,
    Array,
    parseFloat,
    isFinite,
    console,
  };
  // The observer path is opt-in per test (default OFF so the legacy tests keep
  // exercising the synchronous content check + safety-timer fallback).
  if (opts.withObserver) {
    sandbox.window.MutationObserver = FakeMutationObserver;
  }
  // Deferred timers are captured (not auto-run) so a test flushes them
  // explicitly. Default OFF so the synchronous scheduleMeasure fallback (node
  // harness reality) is what the existing tests see.
  if (opts.withTimers) {
    let nextId = 1;
    sandbox.window.setTimeout = function (fn, ms) {
      const id = nextId++;
      pendingTimers.push({ id, fn, ms });
      return id;
    };
    sandbox.window.clearTimeout = function (id) {
      const i = pendingTimers.findIndex((t) => t.id === id);
      if (i >= 0) pendingTimers.splice(i, 1);
    };
  }
  sandbox.window.document = document;
  // The TOP-LEVEL bridge: host.js posts overlaySize / dismissPopupAt here, and
  // wrapFrameBridge routes the re-anchored child messages through it too.
  sandbox.window.chrome = {
    webview: {
      postMessage(msg) {
        hostPostLog.push(msg);
      },
    },
  };
  sandbox.window.devicePixelRatio = 1;
  sandbox.window.top = sandbox.window;
  sandbox.window.self = sandbox.window;
  runInNewContext(hostSrc, sandbox);
  return { host: sandbox.window.__globalLookupHost, document, window: sandbox.window };
}

// Count frame shells currently attached under the host layer.
function shellsOf(document) {
  const layer = document.getElementById('global-lookup-host-layer');
  if (!layer) return [];
  return layer.children.filter(
    (c) => c.className === 'global-lookup-frame-shell',
  );
}

function descriptor(id, parentIndex, settingsJs) {
  return {
    id,
    parentIndex,
    frame: { left: 0, top: 0, width: 360, height: 480 },
    settingsJs: settingsJs || ('/* settings ' + id + ' */'),
  };
}

// ---- tests ---------------------------------------------------------------

// 1. host installed + exposes the entry points.
{
  const { host } = freshHost();
  assert.ok(host, '__globalLookupHost installed');
  assert.strictEqual(typeof host.renderStack, 'function', 'renderStack fn');
  assert.strictEqual(typeof host.topPopupId, 'function', 'topPopupId fn');
}

// 2. renderStack builds one shell>iframe per popup; iframe = popup.html, NO sandbox.
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [descriptor('frame-0', -1), descriptor('frame-1', 0)],
  });
  const shells = shellsOf(document);
  assert.strictEqual(shells.length, 2, 'two frame shells');
  for (const shell of shells) {
    const iframe = shell.children.find((c) => c.tagName === 'IFRAME');
    assert.ok(iframe, 'shell has an iframe');
    assert.strictEqual(
      iframe.getAttribute('src'),
      'https://hibiki.popup/popup.html',
      'iframe loads popup.html',
    );
    assert.ok(
      !iframe.hasAttribute('sandbox'),
      'iframe must NOT carry a sandbox attribute (bridge contract)',
    );
  }
  assert.strictEqual(host.topPopupId(), 'frame-1', 'top = deepest frame');
}

// 3. truncating (closing children) removes the gone frames, keeps survivors.
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [descriptor('frame-0', -1), descriptor('frame-1', 0), descriptor('frame-2', 1)],
  });
  assert.strictEqual(shellsOf(document).length, 3, 'three before truncate');
  // Close children of frame-0 -> only the root survives.
  host.renderStack({ popups: [descriptor('frame-0', -1)] });
  const shells = shellsOf(document);
  assert.strictEqual(shells.length, 1, 'one after truncate');
  assert.strictEqual(
    shells[0].getAttribute('data-frame-id'),
    'frame-0',
    'survivor is the root',
  );
  assert.strictEqual(host.topPopupId(), 'frame-0', 'top is root after truncate');
}

// 4. growing (push child) adds a frame and keeps the survivors (no rebuild).
{
  const { host, document } = freshHost();
  host.renderStack({ popups: [descriptor('frame-0', -1)] });
  const rootBefore = shellsOf(document)[0];
  host.renderStack({
    popups: [descriptor('frame-0', -1), descriptor('frame-1', 0)],
  });
  const shells = shellsOf(document);
  assert.strictEqual(shells.length, 2, 'two after push');
  // The root shell object is the SAME (surviving frame reused, not recreated).
  assert.strictEqual(
    shells.find((s) => s.getAttribute('data-frame-id') === 'frame-0'),
    rootBefore,
    'surviving root shell is reused, not rebuilt',
  );
}

// 5. empty payload clears the whole stack.
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [descriptor('frame-0', -1), descriptor('frame-1', 0)],
  });
  host.renderStack({ popups: [] });
  assert.strictEqual(shellsOf(document).length, 0, 'cleared');
  assert.strictEqual(host.topPopupId(), null, 'topPopupId null when empty');
}

// 6. per-frame settingsJs is eval'd inside that frame's contentWindow realm.
{
  const { host } = freshHost();
  host.renderStack({
    popups: [
      descriptor('frame-0', -1, '/* ROOT-SETTINGS */'),
      descriptor('frame-1', 0, '/* CHILD-SETTINGS */'),
    ],
  });
  const root = evalLog.find((e) => e.frameId === 'frame-0');
  const child = evalLog.find((e) => e.frameId === 'frame-1');
  assert.ok(root && /ROOT-SETTINGS/.test(root.code), 'root settings injected');
  assert.ok(child && /CHILD-SETTINGS/.test(child.code), 'child settings injected');
}


// 7. C1: a child iframe's onLinkClick LOCAL rect is re-anchored to window-local
//    CSS px (shell.left/top + FRAME_CONTENT_TOP=0) and the message is stamped
//    with the source frame id before it reaches "C++".
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 100, top: 50, width: 360, height: 480 }, settingsJs: '' },
    ],
  });
  const shell = shellsOf(document)[0];
  const iframe = shell.children.find((c) => c.tagName === 'IFRAME');
  // Post AS the child: the host shim wrapped iframe.contentWindow.chrome.webview.
  iframe.contentWindow.chrome.webview.postMessage({
    handler: 'onLinkClick',
    args: ['cat', { x: 12, y: 8, width: 30, height: 18 }],
    __bridgeId: 5,
  });
  const out = hostPostLog.find((m) => m.handler === 'onLinkClick');
  assert.ok(out, 'onLinkClick reached the top bridge');
  assert.strictEqual(out.__frameId, 'frame-0', 'message stamped with frame id');
  // local (12,8) + shell (100,50) -> screen-local (112,58); size preserved.
  assert.strictEqual(out.args[1].x, 112, 'anchor x = shell.left + local.x');
  assert.strictEqual(out.args[1].y, 58, 'anchor y = shell.top + local.y');
  assert.strictEqual(out.args[1].width, 30, 'anchor width preserved');
  assert.strictEqual(out.args[1].height, 18, 'anchor height preserved');
  assert.strictEqual(out.__bridgeId, 5, 'bridge id preserved for resolution');
}

// 8. C1: a non-onLinkClick message (e.g. tapOutside) is passed through with only
//    the frame id stamped (no rect mangling).
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 360, height: 480 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: 200, top: 30, width: 360, height: 480 }, settingsJs: '' },
    ],
  });
  const childShell = shellsOf(document).find((s) => s.getAttribute('data-frame-id') === 'frame-1');
  const childIframe = childShell.children.find((c) => c.tagName === 'IFRAME');
  childIframe.contentWindow.chrome.webview.postMessage({ handler: 'tapOutside', args: [] });
  const out = hostPostLog.find((m) => m.handler === 'tapOutside');
  assert.ok(out, 'tapOutside reached the top bridge');
  assert.strictEqual(out.__frameId, 'frame-1', 'tapOutside stamped with child frame id');
}

// 9. layerIndexOf: insertion order is stack depth (0 = root).
{
  const { host } = freshHost();
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 1, height: 1 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: 0, top: 0, width: 1, height: 1 }, settingsJs: '' },
    ],
  });
  assert.strictEqual(host.layerIndexOf('frame-0'), 0, 'root index 0');
  assert.strictEqual(host.layerIndexOf('frame-1'), 1, 'child index 1');
  assert.strictEqual(host.layerIndexOf('frame-x'), -1, 'unknown -> -1');
}

// 10. E2 handleGlobalClick: a click inside a shell keeps (no dismiss); a click in
//     the gap between shells dismisses the root (whole stack).
{
  const { host } = freshHost();
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 100, height: 100 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: 300, top: 0, width: 100, height: 100 }, settingsJs: '' },
    ],
  });
  hostPostLog = [];
  const insideHit = host.handleGlobalClick(50, 50); // inside frame-0
  assert.strictEqual(insideHit, true, 'click inside a shell hits');
  assert.ok(!hostPostLog.some((m) => m.handler === 'dismissPopupAt'),
    'a click inside a shell does NOT dismiss');
  const gapHit = host.handleGlobalClick(200, 50); // gap between the two shells
  assert.strictEqual(gapHit, false, 'click in the gap misses all shells');
  const dismiss = hostPostLog.find((m) => m.handler === 'dismissPopupAt');
  assert.ok(dismiss, 'a click in the gap dismisses the root');
  assert.strictEqual(dismiss.args[0], 0, 'dismiss targets the root (index 0)');
}

// 11. D2 overlaySize: the host reports the UNION bounding box of all shells
//     (window-local CSS px) + dpr; the layer is shifted by (-minLeft,-minTop).
{
  const { host, document, window } = freshHost();
  window.devicePixelRatio = 1.5;
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 100, height: 80 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: -40, top: 60, width: 100, height: 80 }, settingsJs: '' },
    ],
  });
  const size = hostPostLog.filter((m) => m.handler === 'overlaySize').pop();
  assert.ok(size, 'overlaySize reported');
  assert.strictEqual(size.args[0], 1.5, 'dpr forwarded');
  const box = size.args[1];
  // union: minLeft=-40, minTop=0, maxRight=100, maxBottom=140.
  assert.strictEqual(box.left, -40, 'bbox left = min shell left');
  assert.strictEqual(box.top, 0, 'bbox top = min shell top');
  assert.strictEqual(box.width, 140, 'bbox width = maxRight - minLeft');
  assert.strictEqual(box.height, 140, 'bbox height = maxBottom - minTop');
  // layer shifted so the bbox origin maps to the window origin.
  const layer = document.getElementById('global-lookup-host-layer');
  assert.strictEqual(layer.style.left, '40px', 'layer shifted by -minLeft');
  assert.strictEqual(layer.style.top, '0px', 'layer shifted by -minTop');
}

// Flush all captured safety timers (simulate the timeout firing).
function flushTimers() {
  const due = pendingTimers.slice();
  pendingTimers = [];
  for (const t of due) {
    t.fn();
  }
}

// 12. D1 reveal gate: a freshly-rendered shell is gated-hidden — reveal-ready
//     flips once geometry is placed, but content-ready stays false until the
//     iframe DOM actually renders, so the shell is NOT visible yet.
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 360, height: 480 }, settingsJs: '' },
    ],
  });
  // The gate <style> is injected (on first ensureLayer) with both selectors so
  // visibility has a single declarative source.
  const style = document.getElementById('global-lookup-host-style');
  assert.ok(style, 'reveal-gate <style> injected');
  assert.ok(
    /visibility:hidden/.test(style.textContent),
    'gate CSS hides shells by default',
  );
  assert.ok(
    style.textContent.indexOf(
      '[data-content-ready="true"][data-reveal-ready="true"]') >= 0,
    'gate CSS reveals only when BOTH flags are true',
  );
  const shell = shellsOf(document)[0];
  // Geometry placed -> reveal-ready true; content not rendered -> content-ready
  // still false; therefore NOT visible.
  assert.strictEqual(shell.getAttribute('data-reveal-ready'), 'true',
    'reveal-ready flips once geometry is placed');
  assert.strictEqual(shell.getAttribute('data-content-ready'), 'false',
    'content-ready stays false until the iframe DOM renders');
  const gate = host.frameGateState('frame-0');
  assert.strictEqual(gate.revealReady, true, 'gate revealReady');
  assert.strictEqual(gate.contentReady, false, 'gate contentReady false');
  assert.strictEqual(gate.visible, false, 'shell NOT visible (one flag missing)');
}

// 13. D1: once the iframe renders .glossary-content the MutationObserver flips
//     content-ready -> BOTH flags set -> the shell becomes visible.
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 360, height: 480 }, settingsJs: '' },
    ],
  });
  const shell = shellsOf(document)[0];
  const iframe = shell.children.find((c) => c.tagName === 'IFRAME');
  assert.strictEqual(host.frameGateState('frame-0').visible, false,
    'invisible before content arrives');
  // Simulate popup.js finishing render: fires the host MutationObserver.
  iframe._renderContent(140);
  assert.strictEqual(shell.getAttribute('data-content-ready'), 'true',
    'observer flips content-ready when .glossary-content appears');
  assert.strictEqual(host.frameGateState('frame-0').visible, true,
    'shell visible once BOTH content-ready and reveal-ready are set');
}

// 14. D1 safety: a frame whose content never arrives is forced content-ready by
//     the host safety timer so the card is never stuck invisible.
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 360, height: 480 }, settingsJs: '' },
    ],
  });
  assert.strictEqual(host.frameGateState('frame-0').visible, false,
    'still invisible while waiting for content');
  flushTimers(); // the CONTENT_READY_SAFETY_MS timeout fires
  assert.strictEqual(host.frameGateState('frame-0').contentReady, true,
    'safety timer forces content-ready on render failure');
  assert.strictEqual(host.frameGateState('frame-0').visible, true,
    'shell revealed by the safety path (no stuck-invisible card)');
}

// 15. D2 convergence: a content-ready burst across MULTIPLE layers converges to
//     a STABLE bbox without thrash. Each layer's content refines its height
//     (measureContentHeight caps to the planned shell height), so the union bbox
//     settles after the burst; a redundant re-measure of the SAME state emits
//     zero overlaySize (de-dup on the bbox key), proving no oscillation loop.
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 100, height: 200 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: 120, top: 40, width: 100, height: 200 }, settingsJs: '' },
    ],
  });
  const shells = shellsOf(document);
  const if0 = shells.find((s) => s.getAttribute('data-frame-id') === 'frame-0')
    .children.find((c) => c.tagName === 'IFRAME');
  const if1 = shells.find((s) => s.getAttribute('data-frame-id') === 'frame-1')
    .children.find((c) => c.tagName === 'IFRAME');
  hostPostLog = [];
  // Both layers render content shorter than planned (200): the bbox refines once
  // per real change, then stops. Drive the whole burst, then re-measure twice.
  if0._renderContent(150);
  if1._renderContent(150);
  const afterBurst = hostPostLog.filter((m) => m.handler === 'overlaySize').length;
  // The burst converges to a bounded number of reports (<= one per layer that
  // actually changed the bbox), NOT an unbounded loop.
  assert.ok(afterBurst >= 1 && afterBurst <= 2,
    'a content burst converges to a bounded number of bbox reports, not a loop');
  hostPostLog = [];
  // The state is now STABLE: re-measuring the identical bbox emits nothing.
  host.measureAndReport();
  host.measureAndReport();
  const repeat = hostPostLog.filter((m) => m.handler === 'overlaySize');
  assert.strictEqual(repeat.length, 0,
    'a re-measure with an unchanged bbox is de-duped (no thrash / no loop)');
}

console.log('global_lookup_host_test: PASS');
