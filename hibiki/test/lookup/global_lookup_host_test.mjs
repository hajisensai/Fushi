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
      // TODO-1188 — each iframe's popup_bridge_adapter defines its own
      // window.__hibikiBridgeResolve (frame-local _pending realm). The host's
      // top-level router forwards a native reply to the SOURCE frame's resolver;
      // this spy records (id, value) so a test can assert the reply reached
      // EXACTLY that frame with its original frame-local id.
      __hibikiBridgeResolve(id, value) {
        (el.contentWindow._bridgeResolved =
          el.contentWindow._bridgeResolved || []).push({ id, value });
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
  // TODO-1188 — the frame-LOCAL bridge id (5) is rewritten to a host-GLOBAL id on
  // the outbound message, and a route back to the source frame's local id is
  // recorded. The global id is what native sees + echoes back.
  assert.strictEqual(typeof out.__bridgeId, 'number',
    'outbound bridge id is a host-global integer');
  const route = host._bridgeRoutes.get(out.__bridgeId);
  assert.ok(route, 'a route was recorded for the outbound global id');
  assert.strictEqual(route.frameId, 'frame-0', 'route points at the source frame');
  assert.strictEqual(route.localId, 5, 'route remembers the frame-local id');
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
//     (window-local CSS px) + dpr. TODO-1231 P2: measureAndReport NO LONGER
//     shifts the layer synchronously (that raced the window move across vsync ->
//     geometry lurch); the shift is applied by commitLayerShift, which C++
//     RevealStack calls AFTER SetWindowPos. So the layer stays un-shifted until
//     commitLayerShift(box.left, box.top) runs.
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
  // TODO-1231 P2: measureAndReport must NOT have shifted the layer yet (it only
  // reports the bbox; the shift is C++-ordered after SetWindowPos).
  const layer = document.getElementById('global-lookup-host-layer');
  assert.strictEqual(layer.style.left, '0', 'layer NOT shifted by measureAndReport');
  assert.strictEqual(layer.style.top, '0', 'layer NOT shifted by measureAndReport');
  // commitLayerShift (called by C++ RevealStack after the window moved) applies
  // the compensating translation so the bbox origin maps to the window origin.
  host.commitLayerShift(box.left, box.top);
  assert.strictEqual(layer.style.left, '40px', 'commitLayerShift shifts by -minLeft');
  assert.strictEqual(layer.style.top, '0px', 'commitLayerShift shifts by -minTop');
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

// 16. F2 shell chrome: the injected gate <style> carries ONLY the hoshi radius +
//     transparent background (the iframe paints the card fill + the single
//     visible border). It draws NO border (TODO-893 double-border) and NO
//     box-shadow: the overlay HWND is non-layered/opaque, so a CSS shadow paints
//     as an ~11px DARK HALO outside the card that SetWindowRgn cannot clip (the
//     reported "black border outside the rounded corners") instead of a real
//     translucent shadow. The rounded silhouette comes from SetWindowRgn.
{
  const { host, document } = freshHost();
  host.renderStack({ popups: [descriptor('frame-0', -1)] });
  const style = document.getElementById('global-lookup-host-style');
  assert.ok(style, 'gate/shell <style> injected');
  const css = style.textContent;
  assert.ok(/\.global-lookup-frame-shell\{/.test(css), 'shell rule present');
  assert.ok(!/border:1px solid rgba\(120,120,128,0\.36\)/.test(css),
    'TODO-893: shell must NOT draw a border (single border lives on the iframe '
    + 'body) — this was the double-border main cause');
  assert.ok(/border-radius:10px/.test(css), 'hoshi 10px card radius');
  assert.ok(!/box-shadow/.test(css),
    'shell must cast NO box-shadow: on the non-layered opaque WebView2 window a '
    + 'CSS shadow renders as a dark halo outside the card, not a real shadow');
  assert.ok(/background:transparent/.test(css),
    'shell background transparent (iframe paints the fill, no double layer)');
}

// 17. F2 data-theme stamp: the render payload's `theme` is written onto the shell
//     so the dark/light border variant applies (host has no theme of its own).
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, theme: 'dark',
        frame: { left: 0, top: 0, width: 360, height: 480 }, settingsJs: '' },
    ],
  });
  const shell = shellsOf(document)[0];
  assert.strictEqual(shell.getAttribute('data-theme'), 'dark',
    'shell data-theme stamped from the descriptor');
  // re-render light flips it.
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, theme: 'light',
        frame: { left: 0, top: 0, width: 360, height: 480 }, settingsJs: '' },
    ],
  });
  assert.strictEqual(shell.getAttribute('data-theme'), 'light',
    'data-theme re-stamps on re-render');
}

// 18. TODO-890 slide-out CSS: the gate <style> carries a transform+opacity
//     transition AND a .global-lookup-dismissing rule, BOTH scoped to
//     .global-lookup-frame-shell (never a bare body/html — must not leak into the
//     in-app popup which has no host.js). The dismissing rule slides the card off
//     (translateX + opacity 0) so a close animates instead of vanishing.
{
  const { host, document } = freshHost();
  host.renderStack({ popups: [descriptor('frame-0', -1)] });
  const style = document.getElementById('global-lookup-host-style');
  assert.ok(style, 'gate/shell <style> injected');
  const css = style.textContent;
  assert.ok(/transition:transform 200ms ease-out, opacity 200ms ease-out/.test(css),
    'TODO-890: shell carries a transform+opacity transition for the slide-out');
  assert.ok(/\.global-lookup-frame-shell\.global-lookup-dismissing\{/.test(css),
    'TODO-890: a .global-lookup-dismissing rule drives the slide-out');
  assert.ok(/translateX\(120%\)/.test(css),
    'TODO-890: dismissing slides the card off its own width');
  // Isolation: every transition/dismissing rule is scoped to the shell selector,
  // never a bare body/html (would leak the animation into the in-app popup).
  assert.ok(!/(^|[^-])\bbody\s*\{[^}]*transition/.test(css),
    'TODO-890: transition must NOT apply to a bare body');
  assert.ok(!/(^|[^-])\bhtml\s*\{[^}]*transition/.test(css),
    'TODO-890: transition must NOT apply to a bare html');
}

// 19. TODO-890 slide-out dismiss path: dismissRootWithSlide adds the dismissing
//     class to the ROOT shell and posts dismissPopupAt([0]) ONLY after the
//     shell's transitionend fires — NOT instantly. A fake classList + a
//     dispatchable transitionend on the root shell model the real CSS transition.
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  host.renderStack({ popups: [descriptor('frame-0', -1)] });
  const shell = shellsOf(document)[0];
  // Augment the fake shell with a classList + transitionend dispatch (the base
  // fake DOM has neither; host.js falls back to instant-post without them — this
  // test exercises the animated path explicitly).
  const classes = new Set();
  shell.classList = {
    add: (c) => classes.add(c),
    remove: (c) => classes.delete(c),
    contains: (c) => classes.has(c),
  };
  let endHandler = null;
  shell.addEventListener = (type, fn) => {
    if (type === 'transitionend') endHandler = fn;
  };
  shell.removeEventListener = (type, fn) => {
    if (type === 'transitionend' && endHandler === fn) endHandler = null;
  };
  hostPostLog = [];
  host.dismissRootWithSlide();
  assert.ok(classes.has('global-lookup-dismissing'),
    'TODO-890: dismissing class added to the root shell to start the slide');
  assert.ok(!hostPostLog.some((m) => m.handler === 'dismissPopupAt'),
    'TODO-890: dismiss is NOT posted before the slide-out finishes');
  // Fire the transitionend (slide-out done) -> NOW the host posts dismiss.
  assert.ok(endHandler, 'transitionend handler registered');
  endHandler({ propertyName: 'transform' });
  const dismiss = hostPostLog.find((m) => m.handler === 'dismissPopupAt');
  assert.ok(dismiss, 'TODO-890: dismiss posted AFTER transitionend');
  assert.strictEqual(dismiss.args[0], 0, 'dismiss targets the root (index 0)');
}

// 20. TODO-890 slide-out safety: when no transitionend ever fires (reduced-motion
//     / detached), the safety timer still posts dismiss so close never hangs.
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  host.renderStack({ popups: [descriptor('frame-0', -1)] });
  const shell = shellsOf(document)[0];
  const classes = new Set();
  shell.classList = {
    add: (c) => classes.add(c),
    remove: (c) => classes.delete(c),
    contains: (c) => classes.has(c),
  };
  shell.addEventListener = () => {}; // transitionend never fires
  shell.removeEventListener = () => {};
  hostPostLog = [];
  host.dismissRootWithSlide();
  assert.ok(!hostPostLog.some((m) => m.handler === 'dismissPopupAt'),
    'TODO-890: still not posted before the safety timer');
  flushTimers(); // safety timer fires
  const dismiss = hostPostLog.find((m) => m.handler === 'dismissPopupAt');
  assert.ok(dismiss, 'TODO-890: safety timer posts dismiss when transitionend is absent');
}

// 21. TODO-893 v2 (symptom 1): a child iframe's `textSelected` (plain glossary
//     text tap) LOCAL rect is re-anchored to window-local CSS px EXACTLY like
//     onLinkClick (same args[1] shape), so the child card cascades off the real
//     word position instead of iframe-internal coords. The app-external
//     controller used to ignore textSelected entirely, dropping body taps.
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 70, top: 40, width: 360, height: 480 }, settingsJs: '' },
    ],
  });
  const shell = shellsOf(document)[0];
  const iframe = shell.children.find((c) => c.tagName === 'IFRAME');
  iframe.contentWindow.chrome.webview.postMessage({
    handler: 'textSelected',
    args: ['猫', { x: 10, y: 6, width: 24, height: 16 }],
  });
  const out = hostPostLog.find((m) => m.handler === 'textSelected');
  assert.ok(out, 'textSelected reached the top bridge (not dropped)');
  assert.strictEqual(out.__frameId, 'frame-0', 'textSelected stamped with frame id');
  // local (10,6) + shell (70,40) -> window-local (80,46); size preserved.
  assert.strictEqual(out.args[1].x, 80, 'anchor x = shell.left + local.x');
  assert.strictEqual(out.args[1].y, 46, 'anchor y = shell.top + local.y');
  assert.strictEqual(out.args[1].width, 24, 'anchor width preserved');
  assert.strictEqual(out.args[1].height, 16, 'anchor height preserved');
}

// 22. TODO-1079 (C): a NEW lookup (changed ROOT frame id) resets the bbox
//     de-dup so the fresh card's first overlaySize is ALWAYS delivered, even
//     when its union bbox equals the previous lookup's. Without the reset, the
//     reveal-driving overlaySize was suppressed by the stale key and the window
//     stayed hidden -> "popup did not appear".
{
  const { host } = freshHost();
  // Lookup 1: root frame-0 at a fixed geometry -> one overlaySize.
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 200, height: 160 }, settingsJs: '' },
    ],
  });
  const first = hostPostLog.filter((m) => m.handler === 'overlaySize');
  assert.ok(first.length >= 1, 'lookup 1 reported overlaySize');
  hostPostLog = [];
  // Lookup 2: a DIFFERENT root id (fresh lookup) but the SAME bbox geometry.
  host.renderStack({
    popups: [
      { id: 'frame-9', parentIndex: -1, frame: { left: 0, top: 0, width: 200, height: 160 }, settingsJs: '' },
    ],
  });
  const second = hostPostLog.filter((m) => m.handler === 'overlaySize');
  assert.ok(
    second.length >= 1,
    'a new root id re-delivers overlaySize despite an identical bbox (C)',
  );
}

// 23. TODO-1067 (SUB5): a click INSIDE a shell DEFERS to popup.js (per-layer,
//     via __hasChildPopup) — the host must NOT post a competing dismiss (that
//     double-fires + races the stack). Only a click OUTSIDE every shell (true
//     gap) dismisses the root. This kills "click the first popup, everything
//     closes": a card click no longer nukes the root at the host level.
{
  const { host } = freshHost();
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 200, height: 200 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: 120, top: 40, width: 200, height: 200 }, settingsJs: '' },
    ],
  });
  hostPostLog = [];
  const rootHit = host.handleGlobalClick(20, 20);
  assert.strictEqual(rootHit, true, 'click over the root card hits a shell');
  assert.strictEqual(hostPostLog.length, 0,
    'a shell-hit click posts NOTHING from the host (defers to popup.js)');
  const overlapHit = host.handleGlobalClick(160, 60);
  assert.strictEqual(overlapHit, true, 'overlap click hits a shell (deepest)');
  assert.strictEqual(hostPostLog.length, 0,
    'no host post on any card hit (no double-fire with popup.js)');
  assert.strictEqual(host.frameIdAtPoint(160, 60), 'frame-1',
    'the DEEPEST (child) shell wins the hit-test in a cascade overlap');
  hostPostLog = [];
  const gapHit = host.handleGlobalClick(1000, 1000);
  assert.strictEqual(gapHit, false, 'a click outside all shells misses');
  const dismiss = hostPostLog.find((m) => m.handler === 'dismissPopupAt');
  assert.ok(dismiss, 'a click that hits no shell dismisses the root');
  assert.strictEqual(dismiss.args[0], 0, 'root dismiss targets index 0');
}

// 24. TODO-1067 (SUB1): each shell carries a per-shell close-X posting
//     dismissPopupAt[layerIndex] for THAT layer when clicked.
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 200, height: 200 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: 40, top: 40, width: 200, height: 200 }, settingsJs: '' },
    ],
  });
  const shells = shellsOf(document);
  const childShell = shells.find((s) => s.getAttribute('data-frame-id') === 'frame-1');
  const closeBtn = childShell.children.find((c) => c.className === 'global-lookup-close');
  assert.ok(closeBtn, 'each shell has a close-X child');
  assert.strictEqual(closeBtn.getAttribute('data-close-frame-id'), 'frame-1',
    'close-X carries its own frame id');
  const listeners = closeBtn._listeners['pointerdown'] || [];
  assert.ok(listeners.length >= 1, 'close-X has a pointerdown handler');
  hostPostLog = [];
  let stopped = false;
  listeners[0]({ stopPropagation: () => { stopped = true; }, preventDefault: () => {} });
  assert.ok(stopped, 'close-X stops propagation so it does not fall through');
  const msg = hostPostLog.find((m) => m.handler === 'dismissPopupAt');
  assert.ok(msg, 'close-X posts dismissPopupAt');
  assert.strictEqual(msg.args[0], 1, 'child close-X dismisses layer index 1 (this layer)');
}

// 25. TODO-1067 (SUB3): the reveal gate is driven by popup.js popupRendered,
//     NOT the body-height heuristic.
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 360, height: 480 }, settingsJs: '' },
    ],
  });
  const shell = shellsOf(document)[0];
  const iframe = shell.children.find((c) => c.tagName === 'IFRAME');
  iframe.contentDocument.body.scrollHeight = 300;
  iframe.contentDocument.body.offsetHeight = 300;
  assert.strictEqual(host.frameGateState('frame-0').contentReady, false,
    'a non-zero body height with no card node does NOT reveal (SUB3)');
  iframe.contentWindow.chrome.webview.postMessage({
    handler: 'popupRendered',
    args: [300],
  });
  assert.strictEqual(host.frameGateState('frame-0').contentReady, true,
    'popupRendered flips content-ready (authoritative reveal signal)');
  assert.strictEqual(host.frameGateState('frame-0').visible, true,
    'shell reveals once popupRendered + geometry are both in');
}

// 26. TODO-1067 (SUB1): the close-X posts dismissPopupAt for ITS layer. (The
//     per-layer card close itself is owned by popup.js; the host defers on card
//     hits, tested in 23.)
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 200, height: 200 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: 40, top: 40, width: 200, height: 200 }, settingsJs: '' },
    ],
  });
  const rootShell = shellsOf(document).find((s) => s.getAttribute('data-frame-id') === 'frame-0');
  const closeBtn = rootShell.children.find((c) => c.className === 'global-lookup-close');
  assert.ok(closeBtn, 'root shell has a close-X');
  const listeners = closeBtn._listeners['pointerdown'] || [];
  hostPostLog = [];
  listeners[0]({ stopPropagation: () => {}, preventDefault: () => {} });
  const msg = hostPostLog.find((m) => m.handler === 'dismissPopupAt');
  assert.ok(msg, 'root close-X posts dismissPopupAt');
  assert.strictEqual(msg.args[0], 0, 'root close-X dismisses layer index 0 (whole stack)');
}

// 27. TODO-1095: beginLookup clears the bbox de-dup key so a fresh lookup whose
//     union bbox equals the previous lookup's STILL re-delivers overlaySize even
//     when the ROOT FRAME ID IS STABLE (the reuse contract — the id no longer
//     rotates, so the changed-root-id path in test 22 would not fire).
{
  const { host } = freshHost();
  const stableRoot = { id: 'global-lookup-root', parentIndex: -1,
    frame: { left: 0, top: 0, width: 200, height: 160 }, settingsJs: '' };
  host.renderStack({ popups: [stableRoot] });
  const first = hostPostLog.filter((m) => m.handler === 'overlaySize');
  assert.ok(first.length >= 1, 'lookup 1 reported overlaySize');
  hostPostLog = [];
  // Second lookup: SAME root id (reuse), SAME bbox geometry. Without beginLookup
  // the identical bbox key would suppress overlaySize and the window would stay
  // hidden. beginLookup clears lastBBoxKey so it is re-delivered.
  host.beginLookup('global-lookup-root');
  host.renderStack({ popups: [stableRoot] });
  const second = hostPostLog.filter((m) => m.handler === 'overlaySize');
  assert.ok(second.length >= 1,
    'beginLookup re-delivers overlaySize for a reused root with an identical bbox');
}

// 28. TODO-1095: beginLookup RE-GATES the reused root shell so the reveal waits
//     for the NEW card's popupRendered. A stable-id root that was visible after
//     lookup 1 must go content-ready=false again on beginLookup, then re-reveal
//     only once the fresh card signals popupRendered (kills "audio plays but the
//     popup is blank/absent" — reveal firing before the reused iframe re-rendered).
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  const stableRoot = { id: 'global-lookup-root', parentIndex: -1,
    frame: { left: 0, top: 0, width: 360, height: 480 }, settingsJs: '' };
  host.renderStack({ popups: [stableRoot] });
  const shell = shellsOf(document)[0];
  const iframe = shell.children.find((c) => c.tagName === 'IFRAME');
  // Lookup 1 renders -> visible.
  iframe.contentWindow.chrome.webview.postMessage({ handler: 'popupRendered', args: [140] });
  assert.strictEqual(host.frameGateState('global-lookup-root').visible, true,
    'lookup 1: reused root visible after popupRendered');
  // Lookup 2 begins: re-gate. The reused shell must be NOT visible again until
  // the new card renders (content-ready re-armed to false).
  host.beginLookup('global-lookup-root');
  assert.strictEqual(host.frameGateState('global-lookup-root').contentReady, false,
    'beginLookup re-arms content-ready=false on the reused root shell');
  assert.strictEqual(host.frameGateState('global-lookup-root').visible, false,
    'reused root is gated hidden again until the NEW card renders (no stale reveal)');
  host.renderStack({ popups: [stableRoot] });
  // The fresh card renders -> content-ready flips true again -> visible.
  iframe.contentWindow.chrome.webview.postMessage({ handler: 'popupRendered', args: [150] });
  assert.strictEqual(host.frameGateState('global-lookup-root').visible, true,
    'reused root re-reveals once the NEW card signals popupRendered');
}

// 29. TODO-1188 bridge round-trip: a native reply (top-level
//     window.__hibikiBridgeResolve, the ONLY document native ExecuteScript can
//     reach) is FORWARDED to the SOURCE iframe's adapter with its ORIGINAL
//     frame-local id — not to the top-level realm (where the callHandler Promise
//     does NOT live) and not broadcast to siblings. This is the audio ♪ / favorite
//     ☆ "button does nothing" root cause: the reply never reached the iframe.
{
  const { host, document, window } = freshHost();
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 360, height: 480 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: 200, top: 30, width: 360, height: 480 }, settingsJs: '' },
    ],
  });
  const shells = shellsOf(document);
  const if0 = shells.find((s) => s.getAttribute('data-frame-id') === 'frame-0')
    .children.find((c) => c.tagName === 'IFRAME');
  const if1 = shells.find((s) => s.getAttribute('data-frame-id') === 'frame-1')
    .children.find((c) => c.tagName === 'IFRAME');
  // frame-1 issues a favoriteEntry callHandler (frame-local id 1 via its adapter).
  if1.contentWindow.chrome.webview.postMessage({
    handler: 'favoriteEntry',
    args: [{ expression: '猫', reading: 'ねこ' }],
    __bridgeId: 1,
  });
  const out = hostPostLog.find((m) => m.handler === 'favoriteEntry');
  assert.ok(out, 'favoriteEntry reached the top bridge');
  assert.strictEqual(out.__frameId, 'frame-1', 'stamped with the source frame id');
  const globalId = out.__bridgeId;
  assert.strictEqual(typeof globalId, 'number', 'outbound id is a global integer');
  // Native replies on the TOP-LEVEL document with the GLOBAL id.
  window.__hibikiBridgeResolve(globalId, true);
  assert.deepStrictEqual(if1.contentWindow._bridgeResolved, [{ id: 1, value: true }],
    'reply forwarded to the SOURCE frame with its ORIGINAL local id 1');
  assert.ok(!if0.contentWindow._bridgeResolved,
    'the sibling frame was NOT resolved (no broadcast)');
  assert.ok(!host._bridgeRoutes.has(globalId),
    'the route is consumed (pruned) after the reply is delivered');
}

// 30. TODO-1188 cross-frame id collision: two frames each mint the SAME
//     frame-local id (their adapters both start _seq at 1). The host rewrites them
//     to DISTINCT global ids, so resolving one global id resolves ONLY its source
//     frame — a naive broadcast-by-id would wrongly resolve BOTH frames' pending
//     id-1 Promise with the same value.
{
  const { host, document, window } = freshHost();
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 360, height: 480 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: 200, top: 30, width: 360, height: 480 }, settingsJs: '' },
    ],
  });
  const shells = shellsOf(document);
  const if0 = shells.find((s) => s.getAttribute('data-frame-id') === 'frame-0')
    .children.find((c) => c.tagName === 'IFRAME');
  const if1 = shells.find((s) => s.getAttribute('data-frame-id') === 'frame-1')
    .children.find((c) => c.tagName === 'IFRAME');
  // BOTH frames issue a callHandler with the SAME frame-local id 1.
  if0.contentWindow.chrome.webview.postMessage({
    handler: 'favoriteCheck', args: [{ expression: 'A' }], __bridgeId: 1,
  });
  if1.contentWindow.chrome.webview.postMessage({
    handler: 'favoriteCheck', args: [{ expression: 'B' }], __bridgeId: 1,
  });
  const outs = hostPostLog.filter((m) => m.handler === 'favoriteCheck');
  assert.strictEqual(outs.length, 2, 'both favoriteCheck calls reached the bridge');
  const gid0 = outs.find((m) => m.__frameId === 'frame-0').__bridgeId;
  const gid1 = outs.find((m) => m.__frameId === 'frame-1').__bridgeId;
  assert.notStrictEqual(gid0, gid1,
    'the two same-local-id calls got DISTINCT global ids (no collision)');
  // Resolve frame-1's global id: ONLY frame-1 sees it.
  window.__hibikiBridgeResolve(gid1, true);
  assert.deepStrictEqual(if1.contentWindow._bridgeResolved, [{ id: 1, value: true }],
    'frame-1 resolved with its own reply');
  assert.ok(!if0.contentWindow._bridgeResolved,
    'frame-0 (same local id 1) is NOT mis-resolved by frame-1 reply');
  // Now resolve frame-0's global id: frame-0 gets ITS reply.
  window.__hibikiBridgeResolve(gid0, false);
  assert.deepStrictEqual(if0.contentWindow._bridgeResolved, [{ id: 1, value: false }],
    'frame-0 resolved independently with its own reply');
}

// 31. TODO-1188 route pruning: closing a frame drops its pending bridge routes so
//     the route map does not leak entries for torn-down iframes.
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 360, height: 480 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: 200, top: 30, width: 360, height: 480 }, settingsJs: '' },
    ],
  });
  const if1 = shellsOf(document).find((s) => s.getAttribute('data-frame-id') === 'frame-1')
    .children.find((c) => c.tagName === 'IFRAME');
  if1.contentWindow.chrome.webview.postMessage({
    handler: 'resolveWordAudio', args: [{ expression: '猫' }], __bridgeId: 1,
  });
  assert.strictEqual(host._bridgeRoutes.size, 1, 'one pending route for frame-1');
  // Close the child (truncate to root) -> the child's route is pruned.
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 360, height: 480 }, settingsJs: '' },
    ],
  });
  assert.strictEqual(host._bridgeRoutes.size, 0,
    'the removed frame\'s pending route is pruned (no leak)');
}

// 32. TODO-1189 (X passthrough fix): each shell gets a z-index equal to its
//     insertion depth (0 = root), establishing a per-shell stacking context so a
//     deeper child shell fully covers its parent — and the parent's z-index:5
//     close-X no longer escapes to paint OVER the child card. Without this the
//     shells sat at z-index:auto and every close-X leaked above sibling shells.
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [
      descriptor('frame-0', -1),
      descriptor('frame-1', 0),
      descriptor('frame-2', 1),
    ],
  });
  const shells = shellsOf(document);
  const zOf = (id) =>
    shells.find((sx) => sx.getAttribute('data-frame-id') === id).style.zIndex;
  assert.strictEqual(zOf('frame-0'), '0', 'root shell z-index = depth 0');
  assert.strictEqual(zOf('frame-1'), '1', 'child shell z-index = depth 1');
  assert.strictEqual(zOf('frame-2'), '2', 'grandchild shell z-index = depth 2');
  // Strictly increasing with depth: a deeper shell always stacks above shallower.
  assert.ok(
    Number(zOf('frame-2')) > Number(zOf('frame-1')) &&
      Number(zOf('frame-1')) > Number(zOf('frame-0')),
    'shell z-index strictly increases with stack depth (deeper covers parent X)',
  );
}

// 33. TODO-1190 (app-external nested highlight): host.highlightFrame(index,count)
//     evals popup.js's hoshiSelection.highlightSelection(count) INSIDE the target
//     (parent) frame's realm, marking the searched word in the parent card. A bad
//     index / non-positive count is a no-op (returns false, no eval) so a failed
//     highlight never breaks the lookup.
{
  const { host } = freshHost();
  host.renderStack({
    popups: [descriptor('frame-0', -1), descriptor('frame-1', 0)],
  });
  evalLog = [];
  const ok = host.highlightFrame(0, 3);
  assert.strictEqual(ok, true, 'highlightFrame(0,3) targets an existing frame');
  const hl = evalLog.find(
    (e) => e.frameId === 'frame-0' && /highlightSelection\(3\)/.test(e.code),
  );
  assert.ok(hl, 'highlightSelection(3) eval ran in the PARENT frame-0 realm');
  assert.ok(
    /window\.hoshiSelection/.test(hl.code),
    'highlight goes through popup.js window.hoshiSelection',
  );
  // Wrong-realm guard: nothing was injected into the child frame-1.
  assert.ok(
    !evalLog.some((e) => e.frameId === 'frame-1'),
    'highlightFrame(0,...) does NOT touch the child frame',
  );
  // No-op guards.
  evalLog = [];
  assert.strictEqual(host.highlightFrame(0, 0), false, 'count 0 -> no-op');
  assert.strictEqual(host.highlightFrame(9, 3), false, 'bad index -> no-op');
  assert.strictEqual(host.highlightFrame(-1, 3), false, 'negative index -> no-op');
  assert.strictEqual(
    evalLog.length,
    0,
    'a no-op highlight injects nothing',
  );
}

// 34. TODO-1189 (layer-shift hit-test): when a nested sub-popup is pushed
//     UP/LEFT off the cursor (screen-edge second lookup -> minLeft/minTop < 0),
//     measureAndReport shifts the layer by (-minLeft,-minTop) so the union bbox
//     top-left maps to the window origin. frameIdAtPoint receives clicks in
//     WINDOW coords (C++ WH_MOUSE_LL), so it MUST subtract the recorded layer
//     offset to map each shell back to window space. Regression: before the fix
//     it compared window clicks against un-shifted shell coords, so a click ON
//     the parent card (window space) fell in NO raw rect -> misread as an empty
//     gap -> dismissRootWithSlide() closed the WHOLE stack (the reported bug:
//     tap child audio/favorite, parent stack vanishes).
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [
      // Root pinned at (200,200); child pushed to NEGATIVE coords (off the
      // cursor toward the screen edge) so minLeft=minTop=-50 and the layer is
      // shifted by (50,50). Window rects: root (250..350), child (0..100).
      { id: 'frame-0', parentIndex: -1, frame: { left: 200, top: 200, width: 100, height: 100 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: -50, top: -50, width: 100, height: 100 }, settingsJs: '' },
    ],
  });
  // TODO-1231 P2: the layer shift is now applied by commitLayerShift (called by
  // C++ RevealStack after SetWindowPos), NOT synchronously in measureAndReport.
  // Drive it here with the reported bbox origin (minLeft=minTop=-50).
  const box34 = hostPostLog.filter((m) => m.handler === 'overlaySize').pop().args[1];
  host.commitLayerShift(box34.left, box34.top);
  // The layer got shifted (proves minLeft/minTop < 0 translation happened).
  const layer = document.getElementById('global-lookup-host-layer');
  assert.strictEqual(layer.style.left, '50px', 'layer shifted by -minLeft (=50)');
  assert.strictEqual(layer.style.top, '50px', 'layer shifted by -minTop (=50)');
  hostPostLog = [];
  // (a) A click on the ROOT card at its WINDOW position (330,330): inside the
  //     root's window rect (250..350) but OUTSIDE every RAW shell rect
  //     (root raw 200..300, child raw -50..50) — the exact coordinate that the
  //     un-shifted hit-test misread as a gap and dismissed the stack.
  const rootHit = host.handleGlobalClick(330, 330);
  assert.strictEqual(rootHit, true,
    'a click on the parent card (window coords) hits the shell, not a gap');
  assert.strictEqual(host.frameIdAtPoint(330, 330), 'frame-0',
    'window (330,330) maps back to the ROOT shell after offset compensation');
  assert.ok(!hostPostLog.some((m) => m.handler === 'dismissPopupAt'),
    'TODO-1189: a click on the shifted parent card does NOT dismiss the stack');
  // (b) A click on the CHILD card at its WINDOW position (30,30): child window
  //     rect is (0..100) after the shift -> deepest hit is frame-1, no dismiss.
  hostPostLog = [];
  assert.strictEqual(host.handleGlobalClick(30, 30), true,
    'a click on the shifted child card hits its shell');
  assert.strictEqual(host.frameIdAtPoint(30, 30), 'frame-1',
    'window (30,30) maps back to the CHILD shell (deepest)');
  assert.ok(!hostPostLog.some((m) => m.handler === 'dismissPopupAt'),
    'TODO-1189: a click on the shifted child card does NOT dismiss the stack');
  // (c) A TRUE gap (outside every WINDOW rect) still dismisses the root — the
  //     fix compensates the offset, it does not disable gap-dismiss.
  hostPostLog = [];
  assert.strictEqual(host.handleGlobalClick(500, 500), false,
    'a click outside every window rect misses all shells');
  const dismiss = hostPostLog.find((m) => m.handler === 'dismissPopupAt');
  assert.ok(dismiss, 'TODO-1189: a genuine gap click still dismisses the root');
  assert.strictEqual(dismiss.args[0], 0, 'gap dismiss targets the root (index 0)');
}

// 35. TODO-1189 regression (offset=0): a single popup / down-right cascade has
//     minLeft=minTop=0, so the layer is NOT shifted and hit-testing uses shell
//     coords directly (window == layer space). Confirms the offset compensation
//     is a no-op in the common case (no behavior change).
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 100, height: 100 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: 60, top: 40, width: 100, height: 100 }, settingsJs: '' },
    ],
  });
  // TODO-1231 P2: C++ RevealStack -> commitLayerShift runs even for the offset-0
  // case (box origin 0,0), a no-op shift that leaves the layer at the origin.
  const box35 = hostPostLog.filter((m) => m.handler === 'overlaySize').pop().args[1];
  host.commitLayerShift(box35.left, box35.top);
  const layer = document.getElementById('global-lookup-host-layer');
  assert.strictEqual(layer.style.left, '0px', 'no layer shift (minLeft=0)');
  assert.strictEqual(layer.style.top, '0px', 'no layer shift (minTop=0)');
  hostPostLog = [];
  // Click on the child card at its (unshifted) coords -> deepest hit, no dismiss.
  assert.strictEqual(host.frameIdAtPoint(80, 60), 'frame-1',
    'offset=0: hit-test uses shell coords directly (child on top)');
  assert.strictEqual(host.handleGlobalClick(10, 10), true,
    'offset=0: a click on the root card still hits');
  assert.ok(!hostPostLog.some((m) => m.handler === 'dismissPopupAt'),
    'offset=0: card clicks do not dismiss (no regression)');
  const gap = host.handleGlobalClick(400, 400);
  assert.strictEqual(gap, false, 'offset=0: a gap click still misses');
  assert.ok(hostPostLog.some((m) => m.handler === 'dismissPopupAt'),
    'offset=0: a gap click still dismisses the root');
}

// 36. TODO-1231 P1 (no parent re-render): re-rendering an ALREADY-loaded frame
//     with an UNCHANGED settingsJs body must NOT re-eval the body. Baking a
//     changing __hasChildPopup into the body used to force a full renderPopup()
//     rebuild of the parent card on every nested open/close = the "父弹窗闪烁".
{
  const { host } = freshHost();
  host.renderStack({ popups: [descriptor('frame-0', -1, '/* BODY-V1 */')] });
  const bodyEvals = () =>
    evalLog.filter((e) => e.frameId === 'frame-0' && /BODY-V1/.test(e.code)).length;
  assert.strictEqual(bodyEvals(), 1, "parent body eval'd once on first render");
  // Push a child: Dart re-sends the parent's UNCHANGED body + the new child.
  host.renderStack({
    popups: [
      descriptor('frame-0', -1, '/* BODY-V1 */'),
      descriptor('frame-1', 0, '/* CHILD-BODY */'),
    ],
  });
  assert.strictEqual(bodyEvals(), 1,
    'unchanged parent body is NOT re-rendered on nested open (no card rebuild)');
  // Close the child: parent body still unchanged -> still not re-rendered.
  host.renderStack({ popups: [descriptor('frame-0', -1, '/* BODY-V1 */')] });
  assert.strictEqual(bodyEvals(), 1,
    'unchanged parent body is NOT re-rendered on nested close either');
  // A genuinely changed body (new lookup word) DOES re-render.
  host.renderStack({ popups: [descriptor('frame-0', -1, '/* BODY-V2 */')] });
  assert.strictEqual(
    evalLog.filter((e) => e.frameId === 'frame-0' && /BODY-V2/.test(e.code)).length,
    1,
    'a CHANGED body is re-rendered (new lookup still renders)');
}

// 37. TODO-1231 P1 (__hasChildPopup on its OWN channel): the flag is applied by a
//     lone `window.__hasChildPopup = <bool>` eval inside the frame realm, NOT
//     baked into the body, and flips as children open/close WITHOUT re-rendering
//     the parent body (BUG-434 behaviour preserved, flicker removed).
{
  const { host } = freshHost();
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, hasChildPopup: true,
        frame: { left: 0, top: 0, width: 360, height: 480 }, settingsJs: '/* ROOT-BODY */' },
      { id: 'frame-1', parentIndex: 0, hasChildPopup: false,
        frame: { left: 40, top: 60, width: 360, height: 480 }, settingsJs: '/* CHILD-BODY */' },
    ],
  });
  const rootBody = evalLog.find((e) => e.frameId === 'frame-0' && /ROOT-BODY/.test(e.code));
  assert.ok(rootBody, 'root body rendered');
  assert.ok(!/__hasChildPopup/.test(rootBody.code),
    'the body does NOT bake __hasChildPopup (rides its own channel)');
  assert.ok(
    evalLog.some((e) => e.frameId === 'frame-0' && /window\.__hasChildPopup = true/.test(e.code)),
    'root __hasChildPopup=true applied on the dedicated channel');
  const logLen = evalLog.length;
  // Close the child: parent alone, hasChildPopup now false.
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, hasChildPopup: false,
        frame: { left: 0, top: 0, width: 360, height: 480 }, settingsJs: '/* ROOT-BODY */' },
    ],
  });
  const afterClose = evalLog.slice(logLen);
  assert.ok(!afterClose.some((e) => /ROOT-BODY/.test(e.code)),
    'unchanged parent body NOT re-rendered on child close (no flicker)');
  assert.ok(
    afterClose.some((e) => e.frameId === 'frame-0' && /window\.__hasChildPopup = false/.test(e.code)),
    'child close flips __hasChildPopup=false via the dedicated channel');
}

// 38. TODO-1231 (BUG-583): beginLookup must NOT trigger a premature overlaySize
//     off the STALE previous card. The reused root iframe still holds the prior
//     lookup's .glossary-content; before the fix beginLookup re-armed
//     observeContent, which synchronously re-satisfied content-ready from that
//     stale card and fired an overlaySize -> the window revealed the OLD card at
//     the cursor for a frame ("第一个弹窗出现时闪") before the fresh render. Now
//     beginLookup only re-gates content-ready=false (tearing down the stale
//     observer/timer) and the reveal-driving overlaySize comes ONLY from the
//     following renderStack.
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  const stableRoot = { id: 'global-lookup-root', parentIndex: -1,
    frame: { left: 0, top: 0, width: 200, height: 160 }, settingsJs: '/* V1 */' };
  host.renderStack({ popups: [stableRoot] });
  const iframe = shellsOf(document)[0].children.find((c) => c.tagName === 'IFRAME');
  // Lookup 1: the card renders real content -> content-ready + one overlaySize.
  iframe._renderContent(120);
  assert.strictEqual(host.frameGateState('global-lookup-root').contentReady, true,
    'lookup 1: reused root content-ready off its rendered card');
  hostPostLog = [];
  // Lookup 2 begins: re-gate. This must NOT measure/reveal off the stale card.
  host.beginLookup('global-lookup-root');
  assert.strictEqual(host.frameGateState('global-lookup-root').contentReady, false,
    'beginLookup re-gates content-ready=false');
  const premature = hostPostLog.filter((m) => m.handler === 'overlaySize');
  assert.strictEqual(premature.length, 0,
    'beginLookup posts NO overlaySize (no premature reveal off the stale card)');
}

// 39. TODO-1231 (BUG-583): after beginLookup, an UNCHANGED body (same-word
//     re-lookup) must still flip content-ready in renderPayload — otherwise the
//     re-gated frame (beginLookup no longer re-observes the stale card) would
//     wait for a popupRendered that never comes and the card would only reveal
//     via the Dart ready-safety (blank flash). A CHANGED body still waits for the
//     new card's content signal.
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  const rootV1 = { id: 'global-lookup-root', parentIndex: -1,
    frame: { left: 0, top: 0, width: 200, height: 160 }, settingsJs: '/* V1 */' };
  host.renderStack({ popups: [rootV1] });
  const iframe = shellsOf(document)[0].children.find((c) => c.tagName === 'IFRAME');
  iframe._renderContent(120);
  assert.strictEqual(host.frameGateState('global-lookup-root').visible, true,
    'lookup 1 visible after content');
  // Same word again: beginLookup re-gates, renderStack re-sends the IDENTICAL body.
  host.beginLookup('global-lookup-root');
  assert.strictEqual(host.frameGateState('global-lookup-root').contentReady, false,
    'beginLookup re-gated to false');
  host.renderStack({ popups: [rootV1] });
  assert.strictEqual(host.frameGateState('global-lookup-root').contentReady, true,
    'unchanged body re-marks content-ready (no stuck gate on same-word re-lookup)');
  assert.strictEqual(host.frameGateState('global-lookup-root').visible, true,
    'reused root re-reveals on an unchanged-body re-lookup');
}

// 40. TODO-1231 v2 (BUG-583): a freshly-opened, still-gated-hidden child must NOT
//     drag the window-origin (bbox MIN-corner) outward. That origin move races
//     the compensating commitLayerShift across the DWM/WebView2 boundary and
//     lurches the pinned parent card ("父弹窗出现子弹窗时闪一下"). The origin now
//     follows ONLY content-ready (visible) shells; the far edges (window size)
//     still grow to cover the hidden child so it is not clipped when it paints.
//     Once the child renders (content-ready) its up/left corner joins the origin
//     — the single origin move coincides with the child's own appearance.
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  const root = { id: 'global-lookup-root', parentIndex: -1,
    frame: { left: 0, top: 0, width: 200, height: 160 }, settingsJs: '/* R */' };
  host.renderStack({ popups: [root] });
  const rootIframe = shellsOf(document)[0].children
    .find((c) => c.tagName === 'IFRAME');
  rootIframe._renderContent(120); // root visible (content-ready)
  // Open an UP/LEFT child (negative left, below-anchored) — still gated-hidden.
  const child = { id: 'frame-1', parentIndex: 0,
    frame: { left: -40, top: 60, width: 200, height: 160 }, settingsJs: '/* C */' };
  hostPostLog = [];
  host.renderStack({ popups: [root, child] });
  assert.strictEqual(host.frameGateState('frame-1').contentReady, false,
    'the just-opened child is still gated-hidden');
  const openSize = hostPostLog.filter((m) => m.handler === 'overlaySize').pop();
  assert.ok(openSize, 'opening the child re-measures');
  assert.strictEqual(openSize.args[1].left, 0,
    'origin stays at the visible parent (0) — the hidden up/left child does NOT '
    + 'drag it outward');
  assert.strictEqual(openSize.args[1].top, 0, 'origin top stays at the parent');
  // The far edges DID grow to cover the hidden child (no clip when it paints).
  assert.ok(openSize.args[1].width >= 200 && openSize.args[1].height >= 220,
    'the window pre-grows its far edges to cover the hidden child');
  // Child renders -> content-ready -> NOW it joins the origin (single move,
  // coincident with the child appearing).
  const childIframe = shellsOf(document)
    .find((s) => s.getAttribute('data-frame-id') === 'frame-1')
    .children.find((c) => c.tagName === 'IFRAME');
  hostPostLog = [];
  childIframe._renderContent(140);
  const readySize = hostPostLog.filter((m) => m.handler === 'overlaySize').pop();
  assert.ok(readySize, 'the child becoming content-ready re-measures');
  assert.strictEqual(readySize.args[1].left, -40,
    'once the child is visible the origin moves outward to include it (one move)');
}

// 41. TODO-1231 v2 (BUG-583): a DOWN-RIGHT nested open never moves the origin at
//     all — only the far edges grow — so the common cascade has ZERO parent
//     lurch, before AND after the child paints.
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  const root = { id: 'global-lookup-root', parentIndex: -1,
    frame: { left: 0, top: 0, width: 200, height: 160 }, settingsJs: '/* R */' };
  host.renderStack({ popups: [root] });
  const rootIframe = shellsOf(document)[0].children
    .find((c) => c.tagName === 'IFRAME');
  rootIframe._renderContent(120);
  const child = { id: 'frame-1', parentIndex: 0,
    frame: { left: 120, top: 80, width: 200, height: 160 }, settingsJs: '/* C */' };
  hostPostLog = [];
  host.renderStack({ popups: [root, child] });
  const openSize = hostPostLog.filter((m) => m.handler === 'overlaySize').pop();
  assert.ok(openSize, 'opening the down-right child re-measures (far edges grow)');
  assert.strictEqual(openSize.args[1].left, 0,
    'down-right open: origin stays at the parent (0)');
  assert.strictEqual(openSize.args[1].top, 0,
    'down-right open: origin top stays at the parent');
  const childIframe = shellsOf(document)
    .find((s) => s.getAttribute('data-frame-id') === 'frame-1')
    .children.find((c) => c.tagName === 'IFRAME');
  hostPostLog = [];
  childIframe._renderContent(140);
  const readySize = hostPostLog.filter((m) => m.handler === 'overlaySize').pop();
  assert.ok(readySize, 'the down-right child becoming content-ready re-measures');
  assert.strictEqual(readySize.args[1].left, 0,
    'down-right visible: origin still at the parent (never moves)');
  assert.strictEqual(readySize.args[1].top, 0,
    'down-right visible: origin top unchanged (parent perfectly still)');
}

// 42. TODO-1231 v3 (BUG-583): a DOWN-RIGHT child is origin-covered from placement
//     (its top-left >= the window origin 0), so reveal-ready flips IMMEDIATELY —
//     byte-identical to the old unconditional flip (no reveal delay for the common
//     cascade, the case with ZERO parent lurch).
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  host.renderStack({
    popups: [
      { id: 'global-lookup-root', parentIndex: -1, frame: { left: 0, top: 0, width: 200, height: 160 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: 120, top: 80, width: 200, height: 160 }, settingsJs: '' },
    ],
  });
  assert.strictEqual(host.frameGateState('frame-1').revealReady, true,
    'down-right child (top-left >= origin) is covered -> reveal-ready immediately');
  const rootShell = shellsOf(document).find((s) => s.getAttribute('data-frame-id') === 'global-lookup-root');
  assert.strictEqual(rootShell.getAttribute('data-reveal-ready'), 'true',
    'root at the origin is covered -> reveal-ready immediately (unchanged)');
}

// 43. TODO-1231 v3 (BUG-583) — CORE: an UP/LEFT child is HELD reveal-ready=false
//     even once its content renders (would-be visible), because the window origin
//     (0) does not YET cover its negative top-left. Revealing it there paints it
//     CLIPPED at the window edge for the whole Dart round-trip = the residual
//     "子弹窗闪" (child appears cut, then jumps). commitLayerShift moving the origin
//     out to reach the child flips reveal-ready, so the child first paints IN PLACE.
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  host.renderStack({
    popups: [
      { id: 'global-lookup-root', parentIndex: -1, frame: { left: 0, top: 0, width: 200, height: 160 }, settingsJs: '' },
    ],
  });
  const rootIframe = shellsOf(document)[0].children.find((c) => c.tagName === 'IFRAME');
  rootIframe._renderContent(120); // root visible
  // Open an up/left child (negative top-left).
  host.renderStack({
    popups: [
      { id: 'global-lookup-root', parentIndex: -1, frame: { left: 0, top: 0, width: 200, height: 160 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: -40, top: -30, width: 200, height: 160 }, settingsJs: '' },
    ],
  });
  const childIframe = shellsOf(document).find((s) => s.getAttribute('data-frame-id') === 'frame-1')
    .children.find((c) => c.tagName === 'IFRAME');
  assert.strictEqual(host.frameGateState('frame-1').revealReady, false,
    'up/left child NOT reveal-ready at placement (origin 0 does not cover -40,-30)');
  // Child content renders -> content-ready true, but STILL held (no clipped paint).
  childIframe._renderContent(140);
  assert.strictEqual(host.frameGateState('frame-1').contentReady, true,
    'up/left child content-ready off its rendered card');
  assert.strictEqual(host.frameGateState('frame-1').revealReady, false,
    'up/left child STILL held after content (would paint clipped otherwise)');
  assert.strictEqual(host.frameGateState('frame-1').visible, false,
    'up/left child NOT visible until the window origin covers it (no clipped flash)');
  // C++ RevealStack moved the window to the child origin, then commitLayerShift.
  host.commitLayerShift(-40, -30);
  assert.strictEqual(host.frameGateState('frame-1').revealReady, true,
    'commitLayerShift covering the child flips reveal-ready');
  assert.strictEqual(host.frameGateState('frame-1').visible, true,
    'up/left child reveals in-position once the window/layer settle (no clip, no jump)');
}

// 44. TODO-1231 v3 (BUG-583): if the covering commitLayerShift never arrives, the
//     reveal-ready safety timer still flips a held up/left child so it is never
//     stuck invisible (mildly-clipped fallback beats a lost card).
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  host.renderStack({
    popups: [
      { id: 'global-lookup-root', parentIndex: -1, frame: { left: 0, top: 0, width: 200, height: 160 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: -40, top: -30, width: 200, height: 160 }, settingsJs: '' },
    ],
  });
  const childIframe = shellsOf(document).find((s) => s.getAttribute('data-frame-id') === 'frame-1')
    .children.find((c) => c.tagName === 'IFRAME');
  childIframe._renderContent(140);
  assert.strictEqual(host.frameGateState('frame-1').revealReady, false,
    'up/left child held before the safety fires');
  flushTimers(); // reveal-ready safety (+ any content safety) fire
  assert.strictEqual(host.frameGateState('frame-1').revealReady, true,
    'reveal-ready safety flips a held child so it is never stuck hidden');
  assert.strictEqual(host.frameGateState('frame-1').visible, true,
    'held child eventually reveals via the safety path (no lost card)');
}

// 45. TODO-1231 v3 (BUG-583): beginLookup resets the committed origin so a stale
//     NEGATIVE origin from a previous lookup's up/left cascade cannot falsely mark
//     the NEXT lookup's up/left child as already-covered (the bug reappearing on the
//     2nd lookup onward). After the reset the new child is correctly HELD.
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  // Lookup 1: an up/left cascade pushes the committed origin to (-60,-50).
  host.renderStack({
    popups: [
      { id: 'global-lookup-root', parentIndex: -1, frame: { left: 0, top: 0, width: 200, height: 160 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: -60, top: -50, width: 200, height: 160 }, settingsJs: '' },
    ],
  });
  host.commitLayerShift(-60, -50);
  assert.strictEqual(host.frameGateState('frame-1').revealReady, true,
    'lookup 1: committing the (-60,-50) origin covers frame-1');
  // Lookup 2 begins: reset the origin to 0. A MILDER up/left child (-40,-30) must be
  // HELD (fresh window origin 0 does not cover it) — a stale -60 origin would have
  // wrongly said "covered" and revealed it clipped.
  host.beginLookup('global-lookup-root');
  host.renderStack({
    popups: [
      { id: 'global-lookup-root', parentIndex: -1, frame: { left: 0, top: 0, width: 200, height: 160 }, settingsJs: '' },
      { id: 'frame-2', parentIndex: 0, frame: { left: -40, top: -30, width: 200, height: 160 }, settingsJs: '' },
    ],
  });
  assert.strictEqual(host.frameGateState('frame-2').revealReady, false,
    'after beginLookup the origin is reset to 0, so a new up/left child is correctly held');
  // And committing the fresh (-40,-30) origin reveals it in place.
  host.commitLayerShift(-40, -30);
  assert.strictEqual(host.frameGateState('frame-2').revealReady, true,
    'committing the new lookup origin covers frame-2 (reveals in place)');
}

// 46. TODO-1345 (BUG-583 deeper root cause): a per-lookup origin FLOOR (reserved
//     cascade headroom toward the screen interior, pushed by Dart on the renderStack
//     payload) pulls the union bbox MIN-corner (window origin) OUT to the floor from
//     the FIRST reveal — so the window is committed already covering the region an
//     up/left child will occupy, even though the only shell sits at (0,0).
{
  const { host } = freshHost();
  host.renderStack({
    popups: [
      { id: 'global-lookup-root', parentIndex: -1,
        frame: { left: 0, top: 0, width: 200, height: 160 }, settingsJs: '' },
    ],
    originFloor: { left: -140, top: -120 },
  });
  const size = hostPostLog.filter((m) => m.handler === 'overlaySize').pop();
  assert.ok(size, 'overlaySize reported');
  const box = size.args[1];
  assert.strictEqual(box.left, -140,
    'origin floored OUT to the reserved headroom left (single shell at 0)');
  assert.strictEqual(box.top, -120, 'origin floored out to the reserved headroom top');
  // Far edges still reach the root card from the floored origin (no clip).
  assert.strictEqual(box.width, 340, 'width = maxRight(200) - flooredLeft(-140)');
  assert.strictEqual(box.height, 280, 'height = maxBottom(160) - flooredTop(-120)');
  // A floor of 0 (down-right / edge lookup) is a pure no-op: origin stays 0.
  const { host: host2 } = freshHost();
  host2.renderStack({
    popups: [
      { id: 'global-lookup-root', parentIndex: -1,
        frame: { left: 0, top: 0, width: 200, height: 160 }, settingsJs: '' },
    ],
    originFloor: { left: 0, top: 0 },
  });
  const box2 = hostPostLog.filter((m) => m.handler === 'overlaySize').pop().args[1];
  assert.strictEqual(box2.left, 0, 'floor 0 leaves the origin byte-identical (left)');
  assert.strictEqual(box2.top, 0, 'floor 0 leaves the origin byte-identical (top)');
}

// 47. TODO-1345 (BUG-583 deeper) — CORE: with the origin floor reserving up/left
//     headroom, opening an up/left child that lands WITHIN the floor does NOT move
//     the window origin — not at placement, and (critically) NOT when the child
//     becomes content-ready. This is the true root fix for the residual "第二个弹窗
//     出现导致第一个弹窗位置变动": rounds 1-4 let the origin move outward ONCE at the
//     child's content-ready (harness #40 locked that "one move"), which still lurched
//     the pinned parent across the DWM/WebView2 boundary. Reserving the headroom up
//     front freezes the origin so the parent has ZERO displacement — the same
//     guarantee BUG-583 already gave the down-right cascade, now extended to up/left.
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  const root = { id: 'global-lookup-root', parentIndex: -1,
    frame: { left: 0, top: 0, width: 200, height: 160 }, settingsJs: '/* R */' };
  const floor = { left: -140, top: -120 };
  // Root reveal with the reserved floor (Dart computed it from the screen edges).
  host.renderStack({ popups: [root], originFloor: floor });
  const rootIframe = shellsOf(document)[0].children.find((c) => c.tagName === 'IFRAME');
  rootIframe._renderContent(120); // root visible (content-ready)
  const baseline = hostPostLog.filter((m) => m.handler === 'overlaySize').pop().args[1];
  assert.strictEqual(baseline.left, -140, 'root origin sits at the reserved floor left');
  assert.strictEqual(baseline.top, -120, 'root origin sits at the reserved floor top');
  // Simulate C++ RevealStack committing that floored origin (window moved + layer
  // shifted) so the reveal gate's coverage check sees it.
  host.commitLayerShift(baseline.left, baseline.top);
  // Open an up/left child that lands WITHIN the floor (-40,-30 is inside -140,-120).
  const child = { id: 'frame-1', parentIndex: 0,
    frame: { left: -40, top: -30, width: 200, height: 160 }, settingsJs: '/* C */' };
  hostPostLog = [];
  host.renderStack({ popups: [root, child], originFloor: floor });
  const openSize = hostPostLog.filter((m) => m.handler === 'overlaySize').pop();
  if (openSize) {
    assert.strictEqual(openSize.args[1].left, -140,
      'up/left child open does NOT move the origin (it is inside the reserved floor)');
    assert.strictEqual(openSize.args[1].top, -120,
      'up/left child open does NOT move the origin top');
  }
  // The child is covered by the committed floor origin FROM PLACEMENT, so it is
  // reveal-ready without waiting for a window move (no clipped-then-jump either).
  assert.strictEqual(host.frameGateState('frame-1').revealReady, true,
    'child covered by the reserved floor origin -> reveal-ready at placement');
  // Child becomes content-ready: STILL no origin move (rounds 1-4 pulled it to -40
  // here — the residual parent lurch; the floor freezes it at -140).
  const childIframe = shellsOf(document)
    .find((s) => s.getAttribute('data-frame-id') === 'frame-1')
    .children.find((c) => c.tagName === 'IFRAME');
  hostPostLog = [];
  childIframe._renderContent(140);
  const readySize = hostPostLog.filter((m) => m.handler === 'overlaySize').pop();
  if (readySize) {
    assert.strictEqual(readySize.args[1].left, -140,
      'child content-ready does NOT pull the origin (frozen at the floor — zero '
      + 'parent lurch, the deeper BUG-583 fix)');
    assert.strictEqual(readySize.args[1].top, -120,
      'child content-ready does NOT pull the origin top');
  }
}

// ---- spec 2026-07-10 panel mode -------------------------------------------

// P1. panel payload: root shell fills the fixed viewport below the panel bar;
//     the panel bar DOM exists; measureAndReport is short-circuited (no
//     overlaySize reveal-resize loop) and the reveal gate flips directly.
{
  const { host, document } = freshHost();
  hostPostLog = [];
  host.renderStack({
    popups: [descriptor('panel-root', -1)],
    layoutMode: 'panel',
  });
  const bar = document.getElementById('global-lookup-panel-bar');
  assert.ok(bar, 'panel bar created in panel mode');
  const shells = shellsOf(document);
  assert.strictEqual(shells.length, 1, 'one root shell');
  const shell = shells[0];
  assert.strictEqual(shell.style.left, '0px', 'panel root pinned left');
  assert.strictEqual(shell.style.top, '28px', 'panel root below the bar');
  assert.strictEqual(shell.style.width, '100%', 'panel root fills width');
  assert.strictEqual(
    shell.style.height,
    'calc(100% - 28px)',
    'panel root fills height below the bar',
  );
  assert.strictEqual(
    shell.getAttribute('data-panel-root'),
    'true',
    'panel root marked so CSS hides its per-shell close-X (panel bar × is the '
      + 'single close affordance; real-device feedback)',
  );
  assert.ok(
    !hostPostLog.some((m) => m.handler === 'overlaySize'),
    'panel mode never posts overlaySize (fixed window, no reveal-resize loop)',
  );
  assert.strictEqual(
    host.frameGateState('panel-root').revealReady,
    true,
    'panel shell reveal gate flips directly (no overlaySize round-trip)',
  );
}

// P2. cascade payload (no layoutMode key): NO panel bar — the transient
//     overlay's DOM is byte-identical to the pre-panel host.
{
  const { host, document } = freshHost();
  host.renderStack({ popups: [descriptor('frame-0', -1)] });
  assert.strictEqual(
    document.getElementById('global-lookup-panel-bar'),
    null,
    'cascade mode never creates the panel bar',
  );
}

// P3. panel bar chrome: grip mousedown posts beginWindowDrag; pin toggles the
//     visual + posts panelPin; close posts panelClose; setPanelPinnedVisual
//     syncs the visual from the Dart pref.
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [descriptor('panel-root', -1)],
    layoutMode: 'panel',
  });
  const bar = document.getElementById('global-lookup-panel-bar');
  // 面板栏顺序：grip · 🕘history · 📌pin · 🛡block · ×close（history 插在 grip 后）。
  const [grip, historyBtn, pinBtn, blockBtn, closeBtn] = bar.children;
  assert.strictEqual(
    historyBtn.className.indexOf('panel-history') >= 0,
    true,
    'panel bar has the clipboard-history button between grip and pin',
  );
  const fakeEvent = { preventDefault() {}, stopPropagation() {} };

  hostPostLog = [];
  grip._listeners['mousedown'][0](fakeEvent);
  assert.ok(
    hostPostLog.some((m) => m.handler === 'beginWindowDrag'),
    'grip mousedown posts beginWindowDrag (native HTCAPTION loop)',
  );

  hostPostLog = [];
  pinBtn._listeners['pointerdown'][0](fakeEvent);
  const pinMsg = hostPostLog.find((m) => m.handler === 'panelPin');
  assert.ok(pinMsg, 'pin posts panelPin');
  assert.strictEqual(pinMsg.args[0], false, 'default pinned -> first tap unpins');
  assert.ok(
    pinBtn.className.indexOf('panel-pin-off') >= 0,
    'unpinned visual applied',
  );

  host.setPanelPinnedVisual(true);
  assert.ok(
    pinBtn.className.indexOf('panel-pin-off') < 0,
    'setPanelPinnedVisual(true) restores the pinned visual (Dart pref sync)',
  );

  // 防截屏按钮：默认开（盾牌亮）；首点关 -> posts panelBlockCapture(false) + 变暗；
  // setPanelBlockCaptureVisual(true) 从 Dart pref 恢复亮态。
  assert.ok(
    blockBtn.className.indexOf('panel-block') >= 0 &&
      blockBtn.className.indexOf('panel-block-off') < 0,
    'block-capture default on (shield bright)',
  );
  hostPostLog = [];
  blockBtn._listeners['pointerdown'][0](fakeEvent);
  const blockMsg = hostPostLog.find((m) => m.handler === 'panelBlockCapture');
  assert.ok(blockMsg, 'block button posts panelBlockCapture');
  assert.strictEqual(
    blockMsg.args[0], false, 'default on -> first tap turns capture-block off');
  assert.ok(
    blockBtn.className.indexOf('panel-block-off') >= 0,
    'capture-block-off visual applied',
  );
  host.setPanelBlockCaptureVisual(true);
  assert.ok(
    blockBtn.className.indexOf('panel-block-off') < 0,
    'setPanelBlockCaptureVisual(true) restores blocked visual (Dart pref sync)',
  );

  hostPostLog = [];
  closeBtn._listeners['pointerdown'][0](fakeEvent);
  assert.ok(
    hostPostLog.some((m) => m.handler === 'panelClose'),
    'close posts panelClose (Dart hides + pauses)',
  );
}

// ---- 剪贴板复制历史覆盖层（面板栏🕘 / 瞬态 root 卡🕘） --------------------

// 找一个 shell 里的历史覆盖层（null 表示没渲染）。
function historyOverlayIn(shell) {
  return (
    (shell.children || []).find(
      (c) => c.className === 'clipboard-history-overlay',
    ) || null
  );
}

// CH1. 面板栏🕘 pointerdown -> postToHost('clipboardHistory')（Dart 从 DB 重载并回注）。
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [descriptor('panel-root', -1)],
    layoutMode: 'panel',
  });
  const bar = document.getElementById('global-lookup-panel-bar');
  const historyBtn = bar.children.find(
    (c) => c.className.indexOf('panel-history') >= 0,
  );
  assert.ok(historyBtn, 'panel bar has the 🕘 history button');
  hostPostLog = [];
  historyBtn._listeners['pointerdown'][0]({
    preventDefault() {},
    stopPropagation() {},
  });
  assert.ok(
    hostPostLog.some((m) => m.handler === 'clipboardHistory'),
    'panel 🕘 posts clipboardHistory',
  );
}

// CH2. showClipboardHistory 把覆盖层渲染进 ROOT 卡 shell（躲 native 裁剪）：
//      带条目铺行 + 点行 -> lookupClipboardHistoryEntry(text) 并关层；清空按钮 ->
//      clearClipboardHistory；空条目 -> 空态元素、无行。
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [descriptor('panel-root', -1)],
    layoutMode: 'panel',
  });
  const rootShell = shellsOf(document)[0];

  const ok = host.showClipboardHistory({
    entries: [
      { text: 'ねこ', time: '12:00' },
      { text: 'いぬ', time: '11:30' },
    ],
    title: '复制历史',
    clearLabel: '清空',
    emptyLabel: '暂无复制记录',
  });
  assert.strictEqual(ok, true, 'showClipboardHistory returns true (rendered)');

  let overlay = historyOverlayIn(rootShell);
  assert.ok(overlay, 'history overlay rendered inside the ROOT shell');
  const [head, list] = overlay.children;
  assert.ok(
    head.children.some((c) => c.textContent === '复制历史'),
    'header shows localized title',
  );
  assert.strictEqual(list.className, 'clipboard-history-list', 'list present');
  assert.strictEqual(list.children.length, 2, 'two history rows (newest-first)');
  const firstRowText = list.children[0].children[0].textContent;
  assert.strictEqual(firstRowText, 'ねこ', 'first row = first payload entry');

  // 点第一行 -> postToHost('lookupClipboardHistoryEntry', ['ねこ']) 且关层。
  hostPostLog = [];
  list.children[0]._listeners['pointerdown'][0]({
    preventDefault() {},
    stopPropagation() {},
  });
  const pick = hostPostLog.find(
    (m) => m.handler === 'lookupClipboardHistoryEntry',
  );
  assert.ok(pick, 'row click posts lookupClipboardHistoryEntry');
  assert.strictEqual(pick.args[0], 'ねこ', 'entry text forwarded to Dart');
  assert.strictEqual(
    historyOverlayIn(rootShell),
    null,
    'picking an entry closes the history overlay',
  );

  // 清空按钮 -> postToHost('clearClipboardHistory')。
  host.showClipboardHistory({
    entries: [{ text: 'x', time: '10:00' }],
    title: 'T',
    clearLabel: 'C',
    emptyLabel: 'E',
  });
  overlay = historyOverlayIn(rootShell);
  const clearBtn = overlay.children[0].children.find(
    (c) => c.textContent === 'C',
  );
  assert.ok(clearBtn, 'clear button present');
  hostPostLog = [];
  clearBtn._listeners['pointerdown'][0]({
    preventDefault() {},
    stopPropagation() {},
  });
  assert.ok(
    hostPostLog.some((m) => m.handler === 'clearClipboardHistory'),
    'clear posts clearClipboardHistory',
  );

  // 空条目 -> 空态元素、无 list。
  host.showClipboardHistory({
    entries: [],
    title: 'T',
    clearLabel: 'C',
    emptyLabel: '暂无复制记录',
  });
  overlay = historyOverlayIn(rootShell);
  assert.ok(
    overlay.children.some(
      (c) => c.className === 'clipboard-history-empty' &&
        c.textContent === '暂无复制记录',
    ),
    'empty entries render the localized empty state',
  );
  assert.ok(
    !overlay.children.some((c) => c.className === 'clipboard-history-list'),
    'no list element when history is empty',
  );
}

// CH3. 瞬态覆盖窗（cascade）root 卡带 global-lookup-history 按钮，点它 posts
//      clipboardHistory（无面板栏，按钮挂 shell 内躲 native 裁剪）。
{
  const { host, document } = freshHost();
  host.renderStack({ popups: [descriptor('frame-0', -1)] });
  const rootShell = shellsOf(document)[0];
  const histBtn = (rootShell.children || []).find(
    (c) => c.className === 'global-lookup-history',
  );
  assert.ok(histBtn, 'cascade root card carries the 🕘 history button');
  hostPostLog = [];
  histBtn._listeners['pointerdown'][0]({
    preventDefault() {},
    stopPropagation() {},
  });
  assert.ok(
    hostPostLog.some((m) => m.handler === 'clipboardHistory'),
    'transient 🕘 posts clipboardHistory',
  );
}

// ---- BUG-749 shell-union region + immediate gap dismiss --------------------

// R1. measureAndReport posts shellRects (window-relative CSS px = shell − bbox
//     min corner, CSV encoded) BEFORE overlaySize — native applies the region
//     before Dart ever reveals the window — and de-dupes an identical
//     re-measure.
{
  const { host } = freshHost();
  hostPostLog = [];
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 100, height: 80 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: -40, top: 60, width: 100, height: 80 }, settingsJs: '' },
    ],
  });
  // renderStack may run interim measure passes while shells are placed one by
  // one; the LAST posts are the settled pair (same convention as test 11).
  const idxRects = hostPostLog.map((m) => m.handler).lastIndexOf('shellRects');
  const idxSize = hostPostLog.map((m) => m.handler).lastIndexOf('overlaySize');
  assert.ok(idxRects >= 0, 'BUG-749: shellRects posted');
  assert.ok(idxSize >= 0, 'overlaySize posted');
  assert.ok(idxRects < idxSize,
    'BUG-749: shellRects posted BEFORE overlaySize (region correct at reveal)');
  // min corner = (-40, 0): frame-0 -> (40,0,100,80), frame-1 -> (0,60,100,80).
  assert.strictEqual(hostPostLog[idxRects].args[0],
    '40,0,100,80;0,60,100,80',
    'BUG-749: rects are window-relative (shell − bbox min), CSV encoded');
  hostPostLog = [];
  host.measureAndReport();
  assert.ok(!hostPostLog.some((m) => m.handler === 'shellRects'),
    'BUG-749: identical re-measure is de-duped (no shellRects spam)');
}

// R2. beginLookup resets the shellRects de-dup key: native clears its cached
//     rects on Hide(), so the next lookup must re-post even when its cascade
//     geometry is byte-identical to the previous one.
{
  const { host } = freshHost();
  host.renderStack({ popups: [descriptor('frame-0', -1)] });
  hostPostLog = [];
  host.beginLookup('frame-0');
  host.measureAndReport();
  assert.ok(hostPostLog.some((m) => m.handler === 'shellRects'),
    'BUG-749: shellRects re-posted after beginLookup even when unchanged');
}

// R3. BUG-749: a hook-forwarded gap click posts the root dismiss IMMEDIATELY —
//     never deferred behind the TODO-890 slide-out. With the shell-union
//     window region the same physical click also lands in the app below and
//     may start a NEW lookup there (clipboard panel word tap); a dismiss
//     delayed 200ms would post after the fresh card seeded and kill it.
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  host.renderStack({ popups: [descriptor('frame-0', -1)] });
  const shell = shellsOf(document)[0];
  // Give the root shell an animatable classList: a slide-based dismiss would
  // DEFER its post to transitionend/safety-timer — the gap path must post NOW.
  const classes = new Set();
  shell.classList = {
    add: (c) => classes.add(c),
    remove: (c) => classes.delete(c),
    contains: (c) => classes.has(c),
  };
  shell.addEventListener = () => {}; // transitionend never fires
  shell.removeEventListener = () => {};
  hostPostLog = [];
  const hit = host.handleGlobalClick(5000, 5000);
  assert.strictEqual(hit, false, 'gap click misses all shells');
  const dismiss = hostPostLog.find((m) => m.handler === 'dismissPopupAt');
  assert.ok(dismiss,
    'BUG-749: gap dismiss posted synchronously (no slide-out deferral)');
  assert.strictEqual(dismiss.args[0], 0, 'dismiss targets the root (index 0)');
}

// B1. BUG-859: beginLookup resets the layer's DOM transform IN LOCK-STEP with
//     the layerOffset shadow variables. A previous lookup's up/left cascade
//     leaves layer.style shifted (commitLayerShift); resetting only the
//     variables defeated shellCoveredByOrigin (stale-shifted card counted as
//     covered) and any reveal that bypasses commitLayerShift (legacy Reveal /
//     ready-safety fallback) painted the fresh root displaced by the stale
//     shift.
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [
      { id: 'global-lookup-root', parentIndex: -1,
        frame: { left: 0, top: 0, width: 100, height: 80 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0,
        frame: { left: -40, top: -60, width: 100, height: 80 }, settingsJs: '' },
    ],
  });
  // C++ RevealStack applies the compensating shift for the up/left cascade.
  host.commitLayerShift(-40, -60);
  const layer = document.getElementById('global-lookup-host-layer');
  assert.strictEqual(layer.style.left, '40px', 'precondition: layer shifted');
  assert.strictEqual(layer.style.top, '60px', 'precondition: layer shifted');
  // A NEW lookup begins: the DOM transform must reset together with the
  // shadow offsets, not linger from the previous cascade.
  host.beginLookup('global-lookup-root');
  assert.strictEqual(layer.style.left, '0px',
    'BUG-859: beginLookup resets the layer DOM transform (left)');
  assert.strictEqual(layer.style.top, '0px',
    'BUG-859: beginLookup resets the layer DOM transform (top)');
}

// B2. BUG-859: panel mode never dismisses on a hook-forwarded gap click (the
//     persistent panel has no click-outside-dismiss semantics; additionally the
//     panel root's percentage/calc() shell size parses to a 100×0 box in
//     frameIdAtPoint, so EVERY panel click would mis-read as a gap and close
//     the panel).
{
  const { host } = freshHost();
  host.renderStack({
    popups: [descriptor('panel-root', -1)],
    layoutMode: 'panel',
  });
  hostPostLog = [];
  const hit = host.handleGlobalClick(5000, 5000);
  assert.strictEqual(hit, true,
    'BUG-859: panel mode swallows the global click (no gap semantics)');
  assert.ok(!hostPostLog.some((m) => m.handler === 'dismissPopupAt'),
    'BUG-859: panel mode never posts dismissPopupAt from the global hook');
}

// B3. 剪贴板面板：scrollRootToTop 把 ROOT 帧滚动位置复位到顶部（新剪贴板内容从
//     头看，不残留上一句被滚动过的偏移）。root iframe 复用，其 document 滚动位置
//     跨渲染保留，故 Dart 在 update / _showTextOnly 渲染后调此函数复位。
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [descriptor('panel-root', -1), descriptor('frame-1', 0)],
    layoutMode: 'panel',
  });
  const shells = shellsOf(document);
  const rootIframe = shells[0].children.find((c) => c.tagName === 'IFRAME');
  const childIframe = shells[1].children.find((c) => c.tagName === 'IFRAME');
  // 模拟用户把 root 卡与子卡都滚到中途。
  rootIframe.contentDocument.documentElement.scrollTop = 300;
  rootIframe.contentDocument.body.scrollTop = 300;
  childIframe.contentDocument.documentElement.scrollTop = 150;
  childIframe.contentDocument.body.scrollTop = 150;
  assert.strictEqual(typeof host.scrollRootToTop, 'function',
    'scrollRootToTop fn exposed');
  host.scrollRootToTop();
  assert.strictEqual(rootIframe.contentDocument.documentElement.scrollTop, 0,
    '剪贴板更新：ROOT 帧 documentElement 滚回顶部');
  assert.strictEqual(rootIframe.contentDocument.body.scrollTop, 0,
    '剪贴板更新：ROOT 帧 body 滚回顶部');
  // 只复位 root（第一个插入的帧）；子卡保留自身滚动（不是剪贴板内容）。
  assert.strictEqual(childIframe.contentDocument.documentElement.scrollTop, 150,
    '子帧滚动不被 scrollRootToTop 复位');
}

// B4. scrollRootToTop 无 root 帧 / 空栈时安全 no-op（不抛）。
{
  const { host } = freshHost();
  assert.doesNotThrow(() => host.scrollRootToTop(),
    'scrollRootToTop 空栈安全');
}

// R4. BUG-745: the TODO-890 slide-out class must be stripped from the REUSED
//     root shell when a new lookup begins. dismissRootWithSlide adds
//     .global-lookup-dismissing (translateX(120%) + opacity 0) and nothing ever
//     removed it while the root shell survives across lookups (stable root id)
//     — so after the first slide dismissal EVERY later card rendered already
//     slid off-window and fully transparent (native reveal fine, screen empty:
//     「第一次正常，之后的弹窗根本不出现」).
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  host.renderStack({ popups: [descriptor('frame-0', -1)] });
  const shell = shellsOf(document)[0];
  const classes = new Set(['global-lookup-frame-shell']);
  shell.classList = {
    add: (c) => classes.add(c),
    remove: (c) => classes.delete(c),
    contains: (c) => classes.has(c),
  };
  let endHandler = null;
  shell.addEventListener = (type, fn) => {
    if (type === 'transitionend') endHandler = fn;
  };
  shell.removeEventListener = () => {};
  host.dismissRootWithSlide();
  assert.ok(classes.has('global-lookup-dismissing'),
    'slide dismissal poisons the reused root shell (precondition)');
  endHandler({ propertyName: 'transform' });
  assert.ok(classes.has('global-lookup-dismissing'),
    'nothing removes the class at post time (the leak this test pins)');
  // A NEW lookup begins: beginLookup must strip the class so the fresh card
  // does not render slid-out + transparent (invisible).
  host.beginLookup('frame-0');
  assert.ok(!classes.has('global-lookup-dismissing'),
    'BUG-745: beginLookup strips the slide-out class off the reused root shell');
  // And the fresh renderStack must not re-add it.
  host.renderStack({ popups: [descriptor('frame-0', -1)] });
  assert.ok(!classes.has('global-lookup-dismissing'),
    'BUG-745: the fresh render stays un-poisoned');
}

console.log('global_lookup_host_test: PASS');
