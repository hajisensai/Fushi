// TODO-867 P3b — global_lookup_host.js renderStack DOM-diff harness (node).
// Run: node fushi/test/lookup/global_lookup_host_test.mjs
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
//  11. BUG-1804: one static revision materialises imported font bytes once as a
//      same-origin Blob URL; nested/reloaded frames never eval the base64 source.

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
let fontBlobCreateLog = [];
let fontBlobRevokeLog = [];

function markMovedIframeRealm(node) {
  if (!node) return;
  if (node.tagName === 'IFRAME') {
    node._ancestorMoveCount = (node._ancestorMoveCount || 0) + 1;
  }
  for (const child of node.children || []) markMovedIframeRealm(child);
}

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
      // Match DOM appendChild semantics: appending an existing child moves it;
      // it does not duplicate the same node in the child list. Chromium also
      // reloads an iframe when a mounted ancestor is moved; record that hazard
      // so the warm-pool test fails if host code re-appends a parked shell.
      if (child.parentNode) {
        markMovedIframeRealm(child);
        const oldIndex = child.parentNode.children.indexOf(child);
        if (oldIndex >= 0) child.parentNode.children.splice(oldIndex, 1);
      }
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
      // window.__fushiBridgeResolve (frame-local _pending realm). The host's
      // top-level router forwards a native reply to the SOURCE frame's resolver;
      // this spy records (id, value) so a test can assert the reply reached
      // EXACTLY that frame with its original frame-local id.
      __fushiBridgeResolve(id, value) {
        (el.contentWindow._bridgeResolved =
          el.contentWindow._bridgeResolved || []).push({ id, value });
      },
      __fushiBridgeCancelPending() {
        el.contentWindow._bridgeCancelCount =
          (el.contentWindow._bridgeCancelCount || 0) + 1;
      },
      __fushiPrepareRealmForReuse() {
        el.contentWindow._prepareReuseCount =
          (el.contentWindow._prepareReuseCount || 0) + 1;
      },
      fushiSelection: {
        clearSelection() {
          el.contentWindow._clearSelectionCount =
            (el.contentWindow._clearSelectionCount || 0) + 1;
        },
      },
    };
    // contentDocument for D1/D2: a mutable body height + a .glossary-content
    // flag + querySelector. _observers holds MutationObserver callbacks bound to
    // body so a test can simulate popup.js rendering content (fire the observer).
    const body = { scrollHeight: 0, offsetHeight: 0, _observers: [] };
    el.contentDocument = {
      body,
      // BUG-1139 ③: documentElement carries the injected CSS `zoom`
      // (popup_settings_injection head). measureContentHeight reads it to convert
      // layout px -> host CSS px, so the stub must expose a real style bag.
      documentElement: { scrollHeight: 0, style: { zoom: '' } },
      _hasGlossary: false,
      // BUG-1166 W1 — 记录 host 派发进本帧的合成 WheelEvent，好断言修饰键真的抵达。
      _dispatched: [],
      dispatchEvent(evt) {
        el.contentDocument._dispatched.push(evt);
        return true;
      },
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
let pendingAnimationFrames = [];
function freshHost(opts) {
  opts = opts || {};
  evalLog = [];
  framePostLog = [];
  hostPostLog = [];
  fontBlobCreateLog = [];
  fontBlobRevokeLog = [];
  pendingTimers = [];
  pendingAnimationFrames = [];
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
  if (opts.withSuspendedRaf) {
    sandbox.window.requestAnimationFrame = function (fn) {
      pendingAnimationFrames.push(fn);
      return pendingAnimationFrames.length;
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
  // WebView2 exposes the standard same-origin Blob URL APIs. Model them here so
  // the host's imported-font resource reuse path can be verified without jsdom
  // or a real browser. The fake records resource count/type/bytes; iframe evals
  // still only record JS and do not need to fetch the object URL.
  let nextFontBlobId = 1;
  sandbox.window.atob = function (base64) {
    return Buffer.from(base64, 'base64').toString('binary');
  };
  sandbox.window.Blob = class FakeBlob {
    constructor(parts, options) {
      this.parts = parts;
      this.type = options && options.type;
      this.size = parts.reduce((sum, part) => sum + (part.byteLength || 0), 0);
    }
  };
  sandbox.window.URL = {
    createObjectURL(blob) {
      const url = `blob:https://hibiki.popup/font-${nextFontBlobId++}`;
      fontBlobCreateLog.push({ url, type: blob.type, size: blob.size });
      return url;
    },
    revokeObjectURL(url) {
      fontBlobRevokeLog.push(url);
    },
  };
  sandbox.window.top = sandbox.window;
  sandbox.window.self = sandbox.window;
  runInNewContext(hostSrc, sandbox);
  return { host: sandbox.window.__globalLookupHost, document, window: sandbox.window };
}

// Count frame shells currently attached under the host layer.
function shellsOf(document) {
  const layer = document.getElementById('global-lookup-host-layer');
  if (!layer) return [];
  return layer.children
    .filter((c) => c.className === 'global-lookup-frame-shell')
    .sort((a, b) => Number(a.style.zIndex || 0) - Number(b.style.zIndex || 0));
}

function standbyShellsOf(document) {
  const layer = document.getElementById('global-lookup-host-layer');
  if (!layer) return [];
  return layer.children.filter(
    (c) => c.className === 'global-lookup-frame-standby',
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

function revisionDescriptor(
  id,
  parentIndex,
  revision,
  entriesJs,
  renderJs,
  staticHeadJs,
  staticTailJs,
) {
  const value = {
    id,
    parentIndex,
    frame: { left: 0, top: 0, width: 360, height: 480 },
    staticRevision: revision,
    entriesJs,
    renderJs,
  };
  if (staticHeadJs !== undefined && staticTailJs !== undefined) {
    value.staticHeadJs = staticHeadJs;
    value.staticTailJs = staticTailJs;
  }
  return value;
}

function latestGeometryBox() {
  const message = hostPostLog.filter((m) => m.handler === 'overlaySize').pop();
  assert.ok(message, 'expected a pending overlaySize geometry transaction');
  const box = message.args[1];
  assert.ok(Number.isInteger(box.geometryEpoch) && box.geometryEpoch > 0,
    'overlaySize carries a positive geometryEpoch');
  return box;
}

function commitLatestGeometry(host) {
  const box = latestGeometryBox();
  assert.strictEqual(
    host.commitLayerShift(box.left, box.top, box.geometryEpoch),
    true,
    'latest geometry transaction commits',
  );
  return box;
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
    assert.strictEqual(
      iframe.contentDocument.documentElement.style.background,
      'linear-gradient(rgba(0, 0, 0, 0), rgba(0, 0, 0, 0))',
      'fresh host enforces the transparent canvas guard even with cached popup.css',
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

// 4b. Opening a child must not restore an unchanged parent's planned max
// height and then measure it short again. That two-step iframe viewport resize
// was the visible root-card shake on every first nested lookup.
{
  const { host, document } = freshHost();
  const root = revisionDescriptor(
    'stable-height-root', -1, 401,
    '/* STABLE-ROOT-ENTRIES */', '/* STABLE-ROOT-RENDER */',
    '/* STABLE-HEAD */', '/* STABLE-TAIL */',
  );
  root.frame = { left: 0, top: 0, width: 360, height: 480 };
  host.renderStack({ popups: [root] });
  const rootShell = shellsOf(document)[0];
  const rootIframe = rootShell.children.find((c) => c.tagName === 'IFRAME');
  rootIframe._listeners.load[0]();
  rootIframe.contentDocument.body.scrollHeight = 132;
  rootIframe.contentDocument.body.offsetHeight = 132;
  rootIframe.contentDocument.documentElement.scrollHeight = 132;
  host.measureAndReport();
  assert.strictEqual(rootShell.style.height, '132px',
    'precondition: root was refined from planned max to measured content');

  let rootHeightReads = 0;
  for (const [target, field] of [
    [rootIframe.contentDocument.body, 'scrollHeight'],
    [rootIframe.contentDocument.body, 'offsetHeight'],
    [rootIframe.contentDocument.documentElement, 'scrollHeight'],
  ]) {
    Object.defineProperty(target, field, {
      configurable: true,
      get() {
        rootHeightReads++;
        return 132;
      },
    });
  }

  root.hasChildPopup = true;
  const child = revisionDescriptor(
    'stable-height-child', 0, 401,
    '/* STABLE-CHILD-ENTRIES */', '/* STABLE-CHILD-RENDER */',
  );
  child.frame = { left: 380, top: 0, width: 360, height: 480 };
  host.renderStack({ popups: [root, child] });

  assert.strictEqual(rootShell.style.height, '132px',
    'unchanged root height stays stable while the child is added');
  assert.strictEqual(rootHeightReads, 0,
    'child open reuses the clean root measurement instead of forcing layout');
}

// BUG-1804 close hot path — retainStack sends only the stable id prefix. A
// deep 5 -> 1 collapse must not re-inject the root dictionary body, must retire
// bridge/realm state exactly once for the single parked candidate, and must
// still publish one causally ordered region+bbox geometry transaction.
{
  const { host, document } = freshHost();
  const popups = [
    revisionDescriptor(
      'global-lookup-root', -1, 80,
      '/* ROOT-ENTRIES-80 */', '/* ROOT-RENDER-80 */',
      '/* STATIC-HEAD-80 */', '/* STATIC-TAIL-80 */',
    ),
  ];
  for (let i = 1; i <= 4; i++) {
    popups.push(revisionDescriptor(
      `frame-${i}`, i - 1, 80,
      `/* CHILD-ENTRIES-${i} */`, `/* CHILD-RENDER-${i} */`,
    ));
  }
  for (let i = 0; i < popups.length; i++) {
    popups[i].hasChildPopup = i < popups.length - 1;
  }
  host.renderStack({ popups });
  const activeBefore = shellsOf(document);
  const rootBefore = activeBefore[0];
  const rootIframe = rootBefore.children.find((c) => c.tagName === 'IFRAME');
  const deepestIframe = activeBefore[4].children.find(
    (c) => c.tagName === 'IFRAME',
  );
  const allIframes = activeBefore.map((shell) =>
    shell.children.find((c) => c.tagName === 'IFRAME'))
    .concat(standbyShellsOf(document).map((shell) =>
      shell.children.find((c) => c.tagName === 'IFRAME')));
  const prepareBefore = allIframes.reduce(
    (sum, frame) => sum + (frame.contentWindow._prepareReuseCount || 0), 0);
  const cancelBefore = allIframes.reduce(
    (sum, frame) => sum + (frame.contentWindow._bridgeCancelCount || 0), 0);
  evalLog = [];
  hostPostLog = [];

  assert.strictEqual(host.retainStack(['global-lookup-root']), true,
    'BUG-1804: a validated live prefix is retained');
  assert.strictEqual(shellsOf(document).length, 1,
    'BUG-1804: all descendants are removed in one truncate');
  assert.strictEqual(shellsOf(document)[0], rootBefore,
    'BUG-1804: root shell/iframe identity is unchanged');
  assert.ok(!evalLog.some((entry) =>
    /ROOT-ENTRIES-80|ROOT-RENDER-80/.test(entry.code)),
  'BUG-1804: retainStack never re-injects the surviving root dictionary body');
  assert.strictEqual(rootIframe.contentWindow.__hasChildPopup, false,
    'BUG-1804: the new top receives the direct cheap hasChild=false update');
  assert.strictEqual(rootIframe.contentWindow._clearSelectionCount, 1,
    'BUG-1804: the new leaf clears the selection that opened the removed child');

  const prepareAfter = allIframes.reduce(
    (sum, frame) => sum + (frame.contentWindow._prepareReuseCount || 0), 0);
  const cancelAfter = allIframes.reduce(
    (sum, frame) => sum + (frame.contentWindow._bridgeCancelCount || 0), 0);
  assert.strictEqual(prepareAfter - prepareBefore, 1,
    'BUG-1804: a deep collapse prepares exactly one realm for reuse');
  assert.strictEqual(cancelAfter - cancelBefore, 1,
    'BUG-1804: only the parked realm runs the explicit bridge cancel');
  const parkedIframe = standbyShellsOf(document)[0].children.find(
    (c) => c.tagName === 'IFRAME',
  );
  assert.strictEqual(parkedIframe, deepestIframe,
    'BUG-1804: the deepest/hottest removed realm is the sole standby');

  const geometryMessages = hostPostLog.filter((message) =>
    message.handler === 'shellRects' || message.handler === 'overlaySize');
  assert.deepStrictEqual(
    geometryMessages.map((message) => message.handler),
    ['shellRects', 'overlaySize'],
    'BUG-1804: truncate still commits exactly one ordered geometry transaction',
  );
  assert.ok(geometryMessages[1].args[1].geometryEpoch > 0,
    'BUG-1804: retained stack geometry stays epoch-versioned');
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

// BUG-1804 — the first nested card must consume an already-loaded standby
// popup realm, and closing/reopening that depth must park/rebind the SAME realm
// instead of navigating a fresh iframe. Frame ids still rotate so a late message
// from the retired logical layer cannot attach to its replacement.
{
  const { host, document } = freshHost();
  assert.strictEqual(standbyShellsOf(document).length, 1,
    'BUG-1804: host preloads exactly one bounded child iframe');
  const initiallyWarmIframe = standbyShellsOf(document)[0].children.find(
    (c) => c.tagName === 'IFRAME',
  );
  assert.ok(initiallyWarmIframe && initiallyWarmIframe._loaded,
    'BUG-1804: standby popup.html realm is loaded before the first child lookup');
  hostPostLog = [];
  initiallyWarmIframe.contentWindow.chrome.webview.postMessage({
    handler: 'popupRendered', args: [0], __bridgeId: 17,
  });
  assert.deepStrictEqual(
    initiallyWarmIframe.contentWindow._bridgeResolved,
    [{ id: 17, value: null }],
    'BUG-1804: inactive standby calls settle locally instead of leaking Promises',
  );
  assert.strictEqual(hostPostLog.length, 0,
    'BUG-1804: inactive standby never publishes a native host message');
  assert.strictEqual(host._bridgeRoutes.size, 0,
    'BUG-1804: inactive standby never owns a host bridge route');

  host.renderStack({
    popups: [revisionDescriptor(
      'global-lookup-root', -1, 70,
      '/* ROOT-ENTRIES-70 */', '/* ROOT-RENDER-70 */',
      '/* STATIC-HEAD-70 */', '/* STATIC-TAIL-70 */',
    )],
  });
  const warmStatic = evalLog.find((e) =>
    e.frameId.startsWith('__global-lookup-standby-') &&
      /STATIC-HEAD-70/.test(e.code));
  assert.ok(warmStatic && !/ROOT-RENDER-70/.test(warmStatic.code),
    'BUG-1804: standby installs static/font settings without rendering stale root content');

  evalLog = [];
  host.renderStack({
    popups: [
      revisionDescriptor(
        'global-lookup-root', -1, 70,
        '/* ROOT-ENTRIES-70 */', '/* ROOT-RENDER-70 */',
      ),
      revisionDescriptor(
        'frame-100', 0, 70,
        '/* CHILD-ENTRIES-100 */', '/* CHILD-RENDER-100 */',
      ),
    ],
  });
  const firstChildShell = shellsOf(document).find(
    (s) => s.getAttribute('data-frame-id') === 'frame-100',
  );
  const firstChildIframe = firstChildShell.children.find(
    (c) => c.tagName === 'IFRAME',
  );
  assert.strictEqual(firstChildIframe, initiallyWarmIframe,
    'BUG-1804: first child reuses the preloaded iframe object');
  assert.strictEqual(firstChildIframe._ancestorMoveCount || 0, 0,
    'BUG-1804: acquisition never reparents the mounted shell/reloads its iframe realm');
  const firstChildEval = evalLog.find((e) =>
    e.frameId === 'frame-100' && /CHILD-ENTRIES-100/.test(e.code));
  assert.ok(firstChildEval && !/STATIC-HEAD-70|STATIC-TAIL-70/.test(firstChildEval.code),
    'BUG-1804: a primed child injects only dynamic entries/render JS');

  firstChildIframe.contentWindow.chrome.webview.postMessage({
    handler: 'favoriteEntry', args: [], __bridgeId: 41,
  });
  assert.strictEqual(host._bridgeRoutes.size, 1,
    'BUG-1804: setup creates one pending route owned by the first logical child');
  const cancelCountBeforePark = firstChildIframe.contentWindow._bridgeCancelCount || 0;
  const prepareCountBeforePark = firstChildIframe.contentWindow._prepareReuseCount || 0;

  host.renderStack({
    popups: [revisionDescriptor(
      'global-lookup-root', -1, 70,
      '/* ROOT-ENTRIES-70 */', '/* ROOT-RENDER-70 */',
    )],
  });
  assert.strictEqual(host._bridgeRoutes.size, 0,
    'BUG-1804: parking a child retires every pending bridge route for its old id');
  assert.strictEqual(firstChildIframe.contentWindow._bridgeCancelCount,
    cancelCountBeforePark + 1,
    'BUG-1804: parking settles frame-local pending Promises before realm reuse');
  assert.strictEqual(firstChildIframe.contentWindow._prepareReuseCount,
    prepareCountBeforePark + 1,
    'BUG-1804: parking invalidates popup.js callbacks before realm reuse');
  assert.strictEqual(standbyShellsOf(document).length, 1,
    'BUG-1804: the child pool stays bounded at one parked realm');
  const parkedIframe = standbyShellsOf(document)[0].children.find(
    (c) => c.tagName === 'IFRAME',
  );
  assert.strictEqual(parkedIframe, firstChildIframe,
    'BUG-1804: closing the child parks its live iframe instead of destroying it');

  host.renderStack({
    popups: [
      revisionDescriptor(
        'global-lookup-root', -1, 70,
        '/* ROOT-ENTRIES-70 */', '/* ROOT-RENDER-70 */',
      ),
      revisionDescriptor(
        'frame-101', 0, 70,
        '/* CHILD-ENTRIES-101 */', '/* CHILD-RENDER-101 */',
      ),
    ],
  });
  const reboundShell = shellsOf(document).find(
    (s) => s.getAttribute('data-frame-id') === 'frame-101',
  );
  const reboundIframe = reboundShell.children.find((c) => c.tagName === 'IFRAME');
  assert.strictEqual(reboundIframe, firstChildIframe,
    'BUG-1804: replacement frame id rebinds the same warm iframe realm');
  assert.strictEqual(reboundShell.getAttribute('data-content-ready'), 'false',
    'BUG-1804: rebound content gate cannot inherit readiness from the retired card');
  assert.strictEqual(reboundShell.getAttribute('data-reveal-ready'), 'false',
    'BUG-1804: rebound child waits for its native geometry transaction');
  commitLatestGeometry(host);
  assert.strictEqual(reboundShell.getAttribute('data-reveal-ready'), 'true',
    'BUG-1804: matching native geometry ack releases the rebound child');

  host.renderStack({ popups: [] });
  assert.strictEqual(standbyShellsOf(document).length, 0,
    'BUG-1804: an empty stack releases the warm realm and its retained settings');
}

// BUG-1804 — replenishing the one look-ahead realm must not start a second
// popup.html navigation in the same turn as the acquired child presentation.
{
  const { host, document } = freshHost({
    withTimers: true,
    withSuspendedRaf: true,
  });
  host.renderStack({
    popups: [
      revisionDescriptor(
        'global-lookup-root', -1, 71,
        '/* ROOT-ENTRIES-71 */', '/* ROOT-RENDER-71 */',
        '/* STATIC-HEAD-71 */', '/* STATIC-TAIL-71 */',
      ),
      revisionDescriptor(
        'frame-200', 0, 71,
        '/* CHILD-ENTRIES-200 */', '/* CHILD-RENDER-200 */',
      ),
    ],
  });
  assert.strictEqual(standbyShellsOf(document).length, 0,
    'BUG-1804: child presentation turn does not synchronously create its replacement');
  assert.ok(pendingAnimationFrames.length >= 1,
    'BUG-1804: normal replacement waits for the compositor path');
  const refill = pendingTimers.find((timer) => timer.ms === 50);
  assert.ok(refill,
    'BUG-1804: a watchdog covers rAF suspension in the off-screen game WebView');
  refill.fn();
  assert.strictEqual(standbyShellsOf(document).length, 1,
    'BUG-1804: deferred turn restores the bounded look-ahead realm');
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
  host.commitLayerShift(box.left, box.top, box.geometryEpoch);
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

// 15b. Every measurement starts from descriptor.frame.height (the immutable
//      layout ceiling), computes min(planned, measured), and writes that one
//      height back to the shell. A short first render therefore does not become
//      a permanent ceiling when async dictionary content grows later.
{
  const { host, document } = freshHost();
  host.renderStack({ popups: [descriptor('frame-0', -1)] });
  const shell = shellsOf(document)[0];
  const iframe = shell.children.find((c) => c.tagName === 'IFRAME');
  const lastHeight = () =>
    hostPostLog.filter((m) => m.handler === 'overlaySize').pop().args[1].height;

  iframe.contentDocument.body.scrollHeight = 140;
  iframe.contentDocument.body.offsetHeight = 140;
  host.measureAndReport();
  assert.strictEqual(lastHeight(), 140,
    'measured content shorter than planned height shrinks the reported bbox');
  assert.strictEqual(shell.style.height, '140px',
    'the same min(planned, measured) height is written back to the shell');

  iframe.contentDocument.body.scrollHeight = 320;
  iframe.contentDocument.body.offsetHeight = 320;
  host.measureAndReport();
  assert.strictEqual(lastHeight(), 320,
    'later content growth re-expands from the descriptor planned height');
  assert.strictEqual(shell.style.height, '320px',
    'the shell re-expands with later content instead of staying at 140px');

  iframe.contentDocument.body.scrollHeight = 900;
  iframe.contentDocument.body.offsetHeight = 900;
  host.measureAndReport();
  assert.strictEqual(lastHeight(), 480,
    'content growth remains capped by descriptor.frame.height');
  assert.strictEqual(shell.style.height, '480px',
    'the shell and reported bbox share the planned-height ceiling');
}

// 16. F2 shell chrome: the base shell is transparent until the iframe theme is
//     available. Runtime transfers the card fill to the fixed shell and its one
//     border to a non-layout ::after layer; the iframe body keeps a transparent
//     border allocation so width/height/zoom measurement does not move. It draws
//     NO hard-coded second border and NO box-shadow: on this non-layered HWND a
//     CSS shadow becomes a dark halo rather than a desktop-composited shadow.
{
  const { host, document } = freshHost();
  host.renderStack({ popups: [descriptor('frame-0', -1)] });
  const style = document.getElementById('global-lookup-host-style');
  assert.ok(style, 'gate/shell <style> injected');
  const css = style.textContent;
  assert.ok(/\.global-lookup-frame-shell\{/.test(css), 'shell rule present');
  assert.ok(!/border:1px solid rgba\(120,120,128,0\.36\)/.test(css),
    'host must not hard-code a second theme border');
  assert.ok(/\.global-lookup-frame-shell::after\{[^}]*position:absolute;[^}]*inset:0;[^}]*--global-lookup-shell-border-width/.test(css),
    'the one visible border is a viewport-stable, non-layout shell layer');
  assert.ok(/pointer-events:none;z-index:4/.test(css),
    'shell border cannot intercept lookup or resize input');
  assert.ok(/border-radius:10px/.test(css), 'hoshi 10px card radius');
  assert.ok(!/box-shadow/.test(css),
    'shell must cast NO box-shadow: on the non-layered opaque WebView2 window a '
    + 'CSS shadow renders as a dark halo outside the card, not a real shadow');
  assert.ok(/background:transparent/.test(css),
    'pre-load shell does not flash a hard-coded fill');
  const shell = shellsOf(document)[0];
  const iframe = shell.children.find((c) => c.tagName === 'IFRAME');
  assert.strictEqual(iframe.parentNode, shell,
    'popup iframe remains a direct shell child so the dedicated clip selector matches');
  assert.ok(
    /\.global-lookup-frame-shell>iframe\{[^}]*border-radius:inherit;[^}]*clip-path:inset\(0 round 10px\);[^}]*\}/.test(css),
    'the promoted iframe surface owns an independent 10px rounded clip',
  );
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
//     window.__fushiBridgeResolve, the ONLY document native ExecuteScript can
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
  window.__fushiBridgeResolve(globalId, true);
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
  window.__fushiBridgeResolve(gid1, true);
  assert.deepStrictEqual(if1.contentWindow._bridgeResolved, [{ id: 1, value: true }],
    'frame-1 resolved with its own reply');
  assert.ok(!if0.contentWindow._bridgeResolved,
    'frame-0 (same local id 1) is NOT mis-resolved by frame-1 reply');
  // Now resolve frame-0's global id: frame-0 gets ITS reply.
  window.__fushiBridgeResolve(gid0, false);
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

// BUG-1804 ancestor replacement — logical depth comes from the incoming
// payload, not from the physical Map. The old suffix deliberately remains in
// that Map while its replacement is rendered; deriving C's z-index from it
// would transiently assign depth 3 to the logical depth-1 child.
{
  const { host, document } = freshHost();
  const zOf = (id) => shellsOf(document)
    .find((shell) => shell.getAttribute('data-frame-id') === id)
    ?.style.zIndex;

  host.renderStack({
    popups: [descriptor('root', -1), descriptor('a', 0), descriptor('b', 1)],
  });
  host.renderStack({
    popups: [descriptor('root', -1), descriptor('c', 0)],
  });
  assert.strictEqual(zOf('root'), '0',
    'ancestor replacement keeps root at logical depth 0');
  assert.strictEqual(zOf('c'), '1',
    'replacement child ignores the retiring physical suffix and uses depth 1');

  host.renderStack({
    popups: [
      descriptor('root', -1),
      descriptor('c', 0),
      descriptor('d', 1),
    ],
  });
  assert.strictEqual(zOf('root'), '0');
  assert.strictEqual(zOf('c'), '1');
  assert.strictEqual(zOf('d'), '2');
  assert.ok(Number(zOf('d')) > Number(zOf('c')),
    'grandchild remains stacked above its replacement parent');
}

// BUG-1804 ancestor replacement atomicity — R,A,B -> R,C must keep the visible
// outgoing suffix until C has both rendered and joined the matching native
// geometry transaction. Removing A/B at renderStack return leaves one or more
// compositor opportunities where only R paints because C is still reveal-gated.
// The transition geometry deliberately covers old + new; a following pass
// shrinks to R,C only after the same-task reveal/teardown swap.
{
  const { host, document } = freshHost({
    withObserver: true,
    withTimers: true,
    withSuspendedRaf: true,
  });
  const popup = (id, parentIndex, frame, body) => ({
    id,
    parentIndex,
    frame,
    settingsJs: `/* ${body} */`,
  });
  const root = popup(
    'atomic-root', -1,
    { left: 0, top: 0, width: 200, height: 160 }, 'ROOT',
  );
  const a = popup(
    'atomic-a', 0,
    { left: 120, top: 20, width: 200, height: 160 }, 'A',
  );
  const b = popup(
    'atomic-b', 1,
    { left: 240, top: 40, width: 200, height: 160 }, 'B',
  );
  host.renderStack({ popups: [root, a, b] });
  for (const id of ['atomic-root', 'atomic-a', 'atomic-b']) {
    const iframe = shellsOf(document)
      .find((shell) => shell.getAttribute('data-frame-id') === id)
      .children.find((child) => child.tagName === 'IFRAME');
    iframe._renderContent(120);
  }
  let initialFlushGuard = 0;
  while (pendingAnimationFrames.length) {
    assert.ok(initialFlushGuard++ < 20, 'initial rAF queue converges');
    pendingAnimationFrames.shift()();
  }
  commitLatestGeometry(host);
  assert.strictEqual(host.frameGateState('atomic-b').visible, true,
    'outgoing suffix starts fully visible');

  const c = popup(
    'atomic-c', 0,
    { left: -40, top: 80, width: 200, height: 160 }, 'C',
  );
  hostPostLog = [];
  host.renderStack({ popups: [root, c] });
  const attachedIds = () => shellsOf(document)
    .map((shell) => shell.getAttribute('data-frame-id'));
  assert.deepStrictEqual(
    new Set(attachedIds()),
    new Set(['atomic-root', 'atomic-a', 'atomic-b', 'atomic-c']),
    'replacement render keeps A/B attached while gated C is prepared',
  );
  assert.strictEqual(host.frameGateState('atomic-c').visible, false,
    'C is not exposed before content + matching geometry');
  assert.strictEqual(standbyShellsOf(document).length, 0,
    'pending replacement does not refill the standby pool');

  const cIframe = shellsOf(document)
    .find((shell) => shell.getAttribute('data-frame-id') === 'atomic-c')
    .children.find((child) => child.tagName === 'IFRAME');
  cIframe._renderContent(130);
  assert.ok(attachedIds().includes('atomic-a') && attachedIds().includes('atomic-b'),
    'contentReady alone does not retire the visible old suffix');

  assert.ok(pendingAnimationFrames.length >= 1,
    'replacement schedules its union geometry measurement');
  pendingAnimationFrames.shift()();
  assert.strictEqual(pendingAnimationFrames.length, 0,
    'pending swap schedules no competing standby refill');
  const transitionBox = latestGeometryBox();
  assert.ok(transitionBox.left <= -40 &&
      transitionBox.left + transitionBox.width >= 440,
  'transition geometry covers both outgoing B and incoming C');
  assert.ok(attachedIds().includes('atomic-a') && attachedIds().includes('atomic-b'),
    'old suffix remains through geometry announcement');

  assert.strictEqual(
    host.commitLayerShift(
      transitionBox.left, transitionBox.top, transitionBox.geometryEpoch,
    ),
    true,
    'matching transition geometry commits',
  );
  assert.deepStrictEqual(
    new Set(attachedIds()),
    new Set(['atomic-root', 'atomic-c']),
    'matching commit atomically reveals C and retires A/B',
  );
  assert.strictEqual(host.frameGateState('atomic-c').visible, true,
    'C is visible at the same synchronous boundary that removes A/B');

  hostPostLog = [];
  assert.ok(pendingAnimationFrames.length >= 1,
    'atomic swap schedules a post-reveal shrink measurement');
  pendingAnimationFrames.shift()();
  const settledBox = latestGeometryBox();
  assert.ok(settledBox.left + settledBox.width <= 200,
    'post-swap geometry drops the retiring suffix extent');

  const d = popup(
    'atomic-d', 1,
    { left: 80, top: 100, width: 200, height: 160 }, 'D',
  );
  host.renderStack({ popups: [root, c, d] });
  assert.ok(attachedIds().includes('atomic-d'),
    'pure append still attaches the new child immediately');
  host.renderStack({ popups: [root, c] });
  assert.ok(!attachedIds().includes('atomic-d'),
    'pure truncate still removes the child immediately');
}

// 33. TODO-1190 (app-external nested highlight): host.highlightFrame(index,count)
//     evals popup.js's fushiSelection.highlightSelection(count) INSIDE the target
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
    /window\.fushiSelection/.test(hl.code),
    'highlight goes through popup.js window.fushiSelection',
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
  host.commitLayerShift(box34.left, box34.top, box34.geometryEpoch);
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
  host.commitLayerShift(box35.left, box35.top, box35.geometryEpoch);
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
//     direct `window.__hasChildPopup = <bool>` on the same-origin frame, NOT
//     baked into the body, and flips as children open/close WITHOUT re-rendering
//     the parent body (BUG-434 behaviour preserved, flicker removed).
{
  const { host, document } = freshHost();
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
  const rootIframe = shellsOf(document)[0].children.find(
    (c) => c.tagName === 'IFRAME',
  );
  assert.strictEqual(rootIframe.contentWindow.__hasChildPopup, true,
    'root __hasChildPopup=true applied on the direct dedicated channel');
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
  assert.strictEqual(rootIframe.contentWindow.__hasChildPopup, false,
    'child close flips __hasChildPopup=false via the direct dedicated channel');
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

// 42. A DOWN-RIGHT child also waits for its far edge + native HRGN transaction.
//     Origin-only gating was the SGRE bug: top-left was covered while right/bottom
//     were still clipped by the old visible HWND.
{
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  host.renderStack({
    popups: [
      { id: 'global-lookup-root', parentIndex: -1, frame: { left: 0, top: 0, width: 200, height: 160 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: 120, top: 80, width: 200, height: 160 }, settingsJs: '' },
    ],
  });
  assert.strictEqual(host.frameGateState('frame-1').revealReady, false,
    'down-right child remains gated before native expands its far edges');
  const rootShell = shellsOf(document).find((s) => s.getAttribute('data-frame-id') === 'global-lookup-root');
  assert.strictEqual(rootShell.getAttribute('data-reveal-ready'), 'true',
    'root at the origin is covered -> reveal-ready immediately (unchanged)');
  commitLatestGeometry(host);
  assert.strictEqual(host.frameGateState('frame-1').revealReady, true,
    'matching full-geometry ack releases the down-right child');
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
  commitLatestGeometry(host);
  assert.strictEqual(host.frameGateState('frame-1').revealReady, true,
    'commitLayerShift covering the child flips reveal-ready');
  assert.strictEqual(host.frameGateState('frame-1').visible, true,
    'up/left child reveals in-position once the window/layer settle (no clip, no jump)');
}

// 44. A recovery timer must NEVER bypass an uncommitted native geometry. It may
//     re-measure, but the child remains hidden instead of exposing a clipped
//     intermediate frame.
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
  flushTimers(); // recovery measurement (+ any content safety) fires
  assert.strictEqual(host.frameGateState('frame-1').revealReady, false,
    'recovery timer cannot bypass the missing geometry ack');
  assert.strictEqual(host.frameGateState('frame-1').visible, false,
    'uncommitted child never paints clipped');
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
  commitLatestGeometry(host);
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
  commitLatestGeometry(host);
  assert.strictEqual(host.frameGateState('frame-2').revealReady, true,
    'committing the new lookup origin covers frame-2 (reveals in place)');
}

// BUG-1804 geometry transaction: replacing child A with B before A's native
// resize returns must reject A's stale epoch. Only B's matching epoch may move
// the layer, reveal B, and publish captureReady; epoch stays monotonic across a
// normal beginLookup even though per-lookup transaction state is retired.
{
  const route = { source: 'galCard', routeEpoch: 9, lookupEpoch: 4 };
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  host.beginLookup('global-lookup-root', route);
  const root = { id: 'global-lookup-root', parentIndex: -1,
    frame: { left: 0, top: 0, width: 200, height: 160 }, settingsJs: '' };
  host.renderStack({ popups: [root] });
  const rootIframe = shellsOf(document)[0].children
    .find((c) => c.tagName === 'IFRAME');
  rootIframe._renderContent(120);
  commitLatestGeometry(host);

  const childA = { id: 'frame-a', parentIndex: 0,
    frame: { left: -20, top: -10, width: 200, height: 160 }, settingsJs: 'A' };
  host.renderStack({ popups: [root, childA] });
  const iframeA = shellsOf(document)
    .find((s) => s.getAttribute('data-frame-id') === 'frame-a')
    .children.find((c) => c.tagName === 'IFRAME');
  iframeA._renderContent(140);
  const boxA = latestGeometryBox();

  const childB = { id: 'frame-b', parentIndex: 0,
    frame: { left: -60, top: -40, width: 200, height: 160 }, settingsJs: 'B' };
  host.renderStack({ popups: [root, childB] });
  const iframeB = shellsOf(document)
    .find((s) => s.getAttribute('data-frame-id') === 'frame-b')
    .children.find((c) => c.tagName === 'IFRAME');
  iframeB._renderContent(140);
  const boxB = latestGeometryBox();
  assert.ok(boxB.geometryEpoch > boxA.geometryEpoch,
    'replacement child receives a newer process-wide geometry epoch');

  const layer = document.getElementById('global-lookup-host-layer');
  hostPostLog = [];
  assert.strictEqual(
    host.commitLayerShiftAndArmCapture(
      boxA.left, boxA.top, route, 500, 400, boxA.geometryEpoch,
    ),
    false,
    'stale A epoch is rejected',
  );
  assert.strictEqual(layer.style.left, '0px',
    'stale A epoch does not move the current layer');
  assert.strictEqual(host.frameGateState('frame-b').revealReady, false,
    'stale A epoch cannot reveal replacement B');
  assert.ok(!hostPostLog.some((m) => m.handler === 'captureReady'),
    'stale A epoch cannot arm captureReady');

  assert.strictEqual(
    host.commitLayerShiftAndArmCapture(
      boxB.left, boxB.top, route, 500, 400, boxB.geometryEpoch,
    ),
    true,
    'matching B epoch commits',
  );
  assert.strictEqual(host.frameGateState('frame-b').revealReady, true,
    'matching B epoch reveals B for the first time');
  const ready = hostPostLog.find((m) => m.handler === 'captureReady');
  assert.ok(ready, 'matching B epoch publishes captureReady');
  assert.deepStrictEqual(
    Array.from(ready.args), [500, 400, boxB.geometryEpoch],
    'captureReady carries the exact committed epoch',
  );

  host.beginLookup('global-lookup-root', {
    source: 'galCard', routeEpoch: 9, lookupEpoch: 5,
  });
  host.renderStack({ popups: [root] });
  const nextLookupBox = latestGeometryBox();
  assert.ok(nextLookupBox.geometryEpoch > boxB.geometryEpoch,
    'beginLookup retires state without reusing the geometry epoch counter');
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
  host.commitLayerShift(
    baseline.left, baseline.top, baseline.geometryEpoch,
  );
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
  // The bbox origin is unchanged, but shellRects/HRGN gained a child. That is a
  // new geometry transaction and must be acknowledged before the child paints.
  assert.strictEqual(host.frameGateState('frame-1').revealReady, false,
    'same bbox with new shellRects still gates the child');
  commitLatestGeometry(host);
  assert.strictEqual(host.frameGateState('frame-1').revealReady, true,
    'matching shellRects transaction releases the child without moving origin');
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

// CH4. BUG-1793：galCard 是游戏内查词表面，不显示进程级复制历史入口，也拒绝
//      迟到的历史 payload；同一个稳定 root shell 切回 desktop 后必须恢复入口。
{
  const { host, document } = freshHost();
  host.beginLookup('frame-0', {
    source: 'galCard',
    routeEpoch: 7,
    lookupEpoch: 1,
  });
  host.renderStack({ popups: [descriptor('frame-0', -1)] });
  const rootShell = shellsOf(document)[0];
  assert.ok(
    !(rootShell.children || []).some(
      (c) => c.className === 'global-lookup-history',
    ),
    'galCard root has no clipboard-history button',
  );
  assert.strictEqual(
    host.showClipboardHistory({ entries: [{ text: 'desktop secret' }] }),
    false,
    'galCard rejects a delayed clipboard-history overlay payload',
  );
  assert.strictEqual(
    historyOverlayIn(rootShell),
    null,
    'galCard never mounts clipboard history into the game card',
  );

  host.beginLookup('frame-0', {
    source: 'desktop',
    routeEpoch: 8,
    lookupEpoch: 1,
  });
  host.renderStack({ popups: [descriptor('frame-0', -1)] });
  assert.ok(
    (rootShell.children || []).some(
      (c) => c.className === 'global-lookup-history',
    ),
    'the reused root restores clipboard history after returning to desktop',
  );

  // Native physical-window identity is the final authority. Model a galCard
  // RenderJson postlude arriving while the JS route still says desktop.
  host.setClipboardHistoryAvailable(false);
  assert.ok(
    !(rootShell.children || []).some(
      (c) => c.className === 'global-lookup-history',
    ),
    'native galCard identity removes history even under a stale desktop route',
  );
  assert.strictEqual(
    host.showClipboardHistory({ entries: [{ text: 'still hidden' }] }),
    false,
    'native galCard identity also blocks delayed history payloads',
  );
  host.setClipboardHistoryAvailable(true);
  assert.ok(
    (rootShell.children || []).some(
      (c) => c.className === 'global-lookup-history',
    ),
    'native desktop identity restores history on the reused root',
  );

  // The galgame TEXT overlay uses the desktop HWND, so its explicit render
  // capability bit (not route/source) must suppress the button too.
  host.renderStack({
    popups: [descriptor('frame-0', -1)],
    clipboardHistoryAvailable: false,
  });
  assert.ok(
    !(rootShell.children || []).some(
      (c) => c.className === 'global-lookup-history',
    ),
    'galgame text-overlay payload hides history on the desktop route',
  );
  host.renderStack({
    popups: [descriptor('frame-0', -1)],
    clipboardHistoryAvailable: true,
  });
  assert.ok(
    (rootShell.children || []).some(
      (c) => c.className === 'global-lookup-history',
    ),
    'a later ordinary desktop payload restores history',
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
  commitLatestGeometry(host);
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

// Z1 (BUG-1139 ③). 卡片 iframe 的 documentElement 上挂着注入的 CSS `zoom`
// （= appUiScale × dictionaryFontSize/16）。标准化 CSS zoom 下 scrollHeight 是**未乘 z
// 的 layout px**，而卡片实际画出 layout × z；shell 几何 / union bbox / shellRects
// （→ window region）全是未缩放的 host CSS px。不换算的话 z>1 时窗口与 region 比内容
// 矮 1/z，卡片底部被窗口边缘裁掉、裁口外露出底下的应用 —— 本 bug 的原始症状。
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 360, height: 480 }, settingsJs: '' },
    ],
  });
  const shell = shellsOf(document)[0];
  const iframe = shell.children.find((c) => c.tagName === 'IFRAME');
  const lastBox = () =>
    hostPostLog.filter((m) => m.handler === 'overlaySize').pop().args[1];

  // z=1（默认 16px 字号 + 100% 界面大小）：恒等变换，与改前逐字节一致。
  iframe.contentDocument.body.scrollHeight = 200;
  iframe.contentDocument.body.offsetHeight = 200;
  host.measureAndReport();
  assert.strictEqual(lastBox().height, 200,
    'BUG-1139 ③: z=1 时测高不变（回归护栏：换算必须是恒等的）');

  // z=2：内容视觉高度 400，窗口/region 必须按 400 报，而不是 layout 的 200。
  iframe.contentDocument.documentElement.style.zoom = '2';
  host.measureAndReport();
  assert.strictEqual(lastBox().height, 400,
    'BUG-1139 ③: 放大后窗口按视觉高度报，卡片底部不再被裁');

  // 卡上限仍然是上限：视觉高度超过 planned frame 时收敛到 480，内容在 iframe 内滚动。
  // （守住 measureAndReport「只收小、不撑大」的既有语义没被这次换算改坏。）
  iframe.contentDocument.body.scrollHeight = 300;
  iframe.contentDocument.body.offsetHeight = 300;
  host.measureAndReport();
  assert.strictEqual(lastBox().height, 480,
    'BUG-1139 ③: 换算后仍不得撑破 planned frame 高度（只收小语义不变）');

  // 非法 / 缺失 zoom 一律回落 1，不得把高度算成 0 或 NaN。
  iframe.contentDocument.body.scrollHeight = 200;
  iframe.contentDocument.body.offsetHeight = 200;
  iframe.contentDocument.documentElement.style.zoom = 'not-a-number';
  host.measureAndReport();
  assert.strictEqual(lastBox().height, 200,
    'BUG-1139 ③: 非法 zoom 回落 1（绝不产生 0/NaN 几何）');
}

// W1 (BUG-1166) — handleGlobalWheel 把 Ctrl/Alt 作为**显式 flag** 派发进命中的那张
// 卡片；落在卡片外不派发。这是本修复的行为级证据：修饰键过不了「合成 WM_MOUSEWHEEL」
// 那道边界（Chromium 读 GetKeyState），所以必须以数据形式抵达 JS 层。
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [
      { id: 'frame-0', parentIndex: -1, frame: { left: 0, top: 0, width: 100, height: 100 }, settingsJs: '' },
      { id: 'frame-1', parentIndex: 0, frame: { left: 300, top: 0, width: 100, height: 100 }, settingsJs: '' },
    ],
  });
  const iframeOf = (idx) => shellsOf(document)[idx].children.find((c) => c.tagName === 'IFRAME');

  // Ctrl+滚轮上滚落在 frame-0 上。
  const hit = host.handleGlobalWheel(50, 50, -120, true, false, false);
  assert.strictEqual(hit, true, 'BUG-1166: 落在卡片上的滚轮被派发');
  const got = iframeOf(0).contentDocument._dispatched;
  assert.strictEqual(got.length, 1, 'BUG-1166: 命中帧收到恰好一条 wheel');
  assert.strictEqual(got[0].type, 'wheel', 'BUG-1166: 事件类型是 wheel');
  assert.strictEqual(got[0].ctrlKey, true,
    'BUG-1166: ctrlKey 必须显式带到 JS —— 丢了它 PR#462 的 Ctrl+滚轮缩放就静默失效');
  assert.strictEqual(got[0].altKey, false, 'BUG-1166: 未按 Alt 时 altKey 为 false');
  assert.strictEqual(got[0].deltaY, -120,
    'BUG-1166: deltaY 用 DOM 约定（上滚为负），与真滚轮同构');
  assert.strictEqual(got[0].bubbles, true,
    'BUG-1166: 必须冒泡 —— 缩放监听挂在 window 上，不冒泡就收不到');
  assert.strictEqual(got[0].cancelable, true,
    'BUG-1166: 必须可取消 —— 下游要 preventDefault');
  assert.strictEqual(iframeOf(1).contentDocument._dispatched.length, 0,
    'BUG-1166: 没被命中的帧不该收到');

  // Alt+滚轮下滚落在 frame-1 上。
  const hit2 = host.handleGlobalWheel(350, 50, 120, false, true, false);
  assert.strictEqual(hit2, true, 'BUG-1166: 第二张卡也能命中');
  const got2 = iframeOf(1).contentDocument._dispatched;
  assert.strictEqual(got2.length, 1, 'BUG-1166: 只派发给命中的那一帧');
  assert.strictEqual(got2[0].altKey, true,
    'BUG-1166: altKey 必须显式带到 JS —— WM_MOUSEWHEEL 结构上没有 ALT 位，'
    + '不显式带就永远丢，Alt+滚轮换词条会静默退化成普通滚动');
  assert.strictEqual(got2[0].deltaY, 120, 'BUG-1166: 下滚为正');

  // 卡片之间的缝隙：不派发（那儿用户看到的是底下的应用/游戏）。
  const miss = host.handleGlobalWheel(200, 50, -120, true, false, false);
  assert.strictEqual(miss, false, 'BUG-1166: 卡片外不派发');
  assert.strictEqual(iframeOf(0).contentDocument._dispatched.length, 1,
    'BUG-1166: 缝隙滚轮不该误投给任何一帧');
}

// P1 (BUG-1804) — a stable host revision carries the multi-megabyte custom-font
// static payload once. Later lookups only eval entries + the render body, while
// a prewarmed iframe hydrates from the host-level revision cache before it is
// rebound, so acquisition only evaluates the child-specific dynamic body.
{
  const { host, document } = freshHost();
  host.renderStack({
    popups: [revisionDescriptor(
      'frame-0', -1, 7, '/* ENTRIES-1 */', '/* RENDER-1 */',
      '/* STATIC-HEAD-7 */', '/* STATIC-TAIL-7 */',
    )],
  });
  const first = evalLog.find((e) => /ENTRIES-1/.test(e.code));
  assert.ok(first, 'BUG-1804: first revision renders the root');
  assert.ok(
    first.code.indexOf('STATIC-HEAD-7') < first.code.indexOf('ENTRIES-1') &&
      first.code.indexOf('ENTRIES-1') < first.code.indexOf('STATIC-TAIL-7') &&
      first.code.indexOf('STATIC-TAIL-7') < first.code.indexOf('RENDER-1'),
    'BUG-1804: cold injection preserves head -> entries -> tail -> render order',
  );

  evalLog = [];
  host.renderStack({
    popups: [revisionDescriptor(
      'frame-0', -1, 7, '/* ENTRIES-2 */', '/* RENDER-2 */',
    )],
  });
  const hot = evalLog.find((e) => /ENTRIES-2/.test(e.code));
  assert.ok(hot, 'BUG-1804: changed entries still render on the stable root');
  assert.ok(!/STATIC-HEAD-7|STATIC-TAIL-7/.test(hot.code),
    'BUG-1804: hot lookup does not re-eval the font/static payload');

  evalLog = [];
  host.renderStack({
    popups: [
      revisionDescriptor('frame-0', -1, 7, '/* ENTRIES-2 */', '/* RENDER-2 */'),
      revisionDescriptor('frame-1', 0, 7, '/* CHILD-ENTRIES */', '/* CHILD-RENDER */'),
    ],
  });
  const child = evalLog.find((e) => e.frameId === 'frame-1' && /CHILD-ENTRIES/.test(e.code));
  assert.ok(child && !/STATIC-HEAD-7|STATIC-TAIL-7/.test(child.code),
    'BUG-1804: the prewarmed iframe keeps static state and acquires dynamic-only content');

  // A navigation replaces the iframe realm but not the host record/cache.
  evalLog = [];
  const rootIframe = shellsOf(document)[0].children.find((c) => c.tagName === 'IFRAME');
  const navigatedNativePost = function () {};
  rootIframe.contentWindow.chrome.webview.postMessage = navigatedNativePost;
  rootIframe._listeners.load[0]();
  assert.notStrictEqual(
    rootIframe.contentWindow.chrome.webview.postMessage,
    navigatedNativePost,
    'BUG-1804: navigation replaces and then re-wraps the frame bridge',
  );
  hostPostLog = [];
  rootIframe.contentWindow.chrome.webview.postMessage({
    handler: 'popupRendered', args: [120],
  });
  const routedAfterReload = hostPostLog.find(
    (message) => message.handler === 'popupRendered',
  );
  assert.ok(routedAfterReload && routedAfterReload.__frameId === 'frame-0',
    'BUG-1804: reloaded realm messages are stamped with the live logical id');
  const reloaded = evalLog.find((e) => e.frameId === 'frame-0' && /ENTRIES-2/.test(e.code));
  assert.ok(reloaded && /STATIC-HEAD-7/.test(reloaded.code),
    'BUG-1804: iframe reload re-applies cached static before pending dynamic');

  evalLog = [];
  host.renderStack({
    popups: [revisionDescriptor(
      'frame-0', -1, 8, '/* ENTRIES-3 */', '/* RENDER-3 */',
      '/* STATIC-HEAD-8 */', '/* STATIC-TAIL-8 */',
    )],
  });
  const changed = evalLog.find((e) => /ENTRIES-3/.test(e.code));
  assert.ok(changed && /STATIC-HEAD-8/.test(changed.code) && /STATIC-TAIL-8/.test(changed.code),
    'BUG-1804: a changed revision installs its new static payload');
}

// P1b (BUG-1804) — imported font bytes are materialised once as a same-origin
// Blob resource. Root, nested, and reloaded iframe realms eval only the compact
// blob: URL while every @font-face semantic besides src stays unchanged.
{
  const { host, document } = freshHost();
  const rawDataUrl = 'data:font/ttf;base64,AAECAw==';
  const fontHead =
    '/* FONT-HEAD */\n' +
    '(function(){var css=\'@font-face { font-family: "Noto Sans JP"; ' +
    'src: url("' + rawDataUrl + '") format("truetype"); ' +
    'font-style: italic; font-weight: 500; font-display: swap; }\';})();';
  const rootDescriptor = revisionDescriptor(
    'font-root', -1, 30, '/* FONT-ROOT-ENTRIES */', '/* FONT-ROOT-RENDER */',
    fontHead, '/* FONT-TAIL */',
  );
  host.renderStack({ popups: [rootDescriptor] });

  assert.strictEqual(fontBlobCreateLog.length, 1,
    'BUG-1804: one revision creates one Blob for one imported font');
  assert.deepStrictEqual(
    { type: fontBlobCreateLog[0].type, size: fontBlobCreateLog[0].size },
    { type: 'font/ttf', size: 4 },
    'BUG-1804: Blob preserves MIME and decoded font bytes',
  );
  assert.ok(!Object.prototype.hasOwnProperty.call(rootDescriptor, 'staticHeadJs') &&
      !Object.prototype.hasOwnProperty.call(rootDescriptor, 'staticTailJs'),
    'BUG-1804: the live frame descriptor releases the base64 source');
  const root = evalLog.find((e) =>
    e.frameId === 'font-root' && /FONT-ROOT-ENTRIES/.test(e.code));
  assert.ok(root, 'BUG-1804: root rendered with the shared font resource');
  assert.ok(!root.code.includes(rawDataUrl),
    'BUG-1804: root iframe does not eval the base64 source');
  assert.ok(root.code.includes(fontBlobCreateLog[0].url),
    'BUG-1804: root iframe receives the host Blob URL');
  assert.ok(root.code.includes('font-family: "Noto Sans JP"') &&
      root.code.includes('format("truetype")') &&
      root.code.includes('font-style: italic') &&
      root.code.includes('font-weight: 500') &&
      root.code.includes('font-display: swap'),
    'BUG-1804: family/format/style/weight/display CSS remains unchanged');
  const warmChildRealm = evalLog.find((e) =>
    e.frameId.startsWith('__global-lookup-standby-') &&
      e.code.includes(fontBlobCreateLog[0].url));
  assert.ok(warmChildRealm && !warmChildRealm.code.includes(rawDataUrl),
    'BUG-1804: standby child realm installs the shared Blob URL before acquire');

  evalLog = [];
  host.renderStack({
    popups: [
      revisionDescriptor(
        'font-root', -1, 30,
        '/* FONT-ROOT-ENTRIES */', '/* FONT-ROOT-RENDER */',
      ),
      revisionDescriptor(
        'font-child', 0, 30,
        '/* FONT-CHILD-ENTRIES */', '/* FONT-CHILD-RENDER */',
      ),
    ],
  });
  const child = evalLog.find((e) =>
    e.frameId === 'font-child' && /FONT-CHILD-ENTRIES/.test(e.code));
  assert.ok(child && !child.code.includes(fontBlobCreateLog[0].url),
    'BUG-1804: acquired child skips already-installed static font settings');
  assert.ok(!child.code.includes(rawDataUrl),
    'BUG-1804: nested iframe never evals base64 font data');
  assert.strictEqual(fontBlobCreateLog.length, 1,
    'BUG-1804: nested hydration does not duplicate the font resource');

  evalLog = [];
  const rootIframe = shellsOf(document)
    .find((s) => s.getAttribute('data-frame-id') === 'font-root')
    .children.find((c) => c.tagName === 'IFRAME');
  rootIframe._listeners.load[0]();
  const reloaded = evalLog.find((e) =>
    e.frameId === 'font-root' && /FONT-ROOT-ENTRIES/.test(e.code));
  assert.ok(reloaded && reloaded.code.includes(fontBlobCreateLog[0].url) &&
      !reloaded.code.includes(rawDataUrl),
    'BUG-1804: iframe reload still reuses the one host resource');
  assert.strictEqual(fontBlobCreateLog.length, 1);

  const oldObjectUrl = fontBlobCreateLog[0].url;
  host.renderStack({
    popups: [revisionDescriptor(
      'font-root', -1, 31, '/* FONT-NEW-ENTRIES */', '/* FONT-NEW-RENDER */',
      fontHead, '/* FONT-NEW-TAIL */',
    )],
  });
  assert.strictEqual(fontBlobCreateLog.length, 2,
    'BUG-1804: a new static revision owns its own resource');
  assert.ok(fontBlobRevokeLog.includes(oldObjectUrl),
    'BUG-1804: pruning the old revision revokes its Blob URL');
}

// P1b — gal direct geometry starts compact, but after a real up/left child grows
// the visible HWND, closing that child must retain the same outward origin in
// BOTH bbox and shellRects. Dart already ratchets the HWND origin; resetting only
// the host rect origin to zero clips the retained root against a translated HRGN
// / capture mask.
{
  const route = { source: 'galCard', routeEpoch: 41, lookupEpoch: 7 };
  const { host, document } = freshHost({ withObserver: true, withTimers: true });
  const root = {
    id: 'global-lookup-root', parentIndex: -1,
    frame: { left: 0, top: 0, width: 200, height: 160 }, settingsJs: '/* ROOT */',
  };
  const child = {
    id: 'frame-up', parentIndex: 0,
    frame: { left: 20, top: -80, width: 200, height: 160 }, settingsJs: '/* CHILD */',
  };

  host.beginLookup(root.id, route);
  host.renderStack({ popups: [root] });
  shellsOf(document)[0].children.find((c) => c.tagName === 'IFRAME')
    ._renderContent(120);
  commitLatestGeometry(host);

  hostPostLog = [];
  host.renderStack({ popups: [root, child] });
  shellsOf(document)
    .find((s) => s.getAttribute('data-frame-id') === child.id)
    .children.find((c) => c.tagName === 'IFRAME')._renderContent(120);
  const openBox = latestGeometryBox();
  assert.strictEqual(openBox.top, -80,
    'gal child grows the compact root surface only when it really lands above');
  commitLatestGeometry(host);

  hostPostLog = [];
  assert.strictEqual(host.retainStack([root.id]), true);
  const closeGeometry = hostPostLog.filter(
    (m) => m.handler === 'shellRects' || m.handler === 'overlaySize',
  );
  assert.deepStrictEqual(closeGeometry.map((m) => m.handler),
    ['shellRects', 'overlaySize']);
  const closeBox = closeGeometry[1].args[1];
  assert.strictEqual(closeBox.top, -80,
    'N→1 keeps the host bbox on the same outward gal origin as the HWND ratchet');
  const rootRect = closeGeometry[0].args[0].split(';')[0].split(',').map(Number);
  assert.strictEqual(rootRect[1], 80,
    'retained root shell rect is translated into the held -80 window origin');
}

// P2 (BUG-1804) — a whole-WebView recovery loses the host cache. A dynamic-only
// descriptor must stay content-gated and request exactly one routed static
// resend; once supplied, the pending dynamic body renders normally.
{
  const { host, document } = freshHost();
  const missing = revisionDescriptor(
    'frame-0', -1, 11, '/* RECOVERY-ENTRIES */', '/* RECOVERY-RENDER */',
  );
  host.renderStack({ popups: [missing] });
  const requests = () => hostPostLog.filter(
    (m) => m.handler === 'staticSettingsRequired' && m.args[0] === 11,
  );
  assert.strictEqual(requests().length, 1,
    'BUG-1804: cache miss requests one static resend');
  assert.ok(!evalLog.some((e) => /RECOVERY-ENTRIES/.test(e.code)),
    'BUG-1804: dynamic content is not rendered without its static revision');
  assert.strictEqual(
    shellsOf(document)[0].getAttribute('data-content-ready'),
    'false',
    'BUG-1804: missing static keeps the shell content-gated',
  );
  assert.strictEqual(
    hostPostLog.filter((m) => m.handler === 'overlaySize').length,
    0,
    'BUG-1804: missing static cannot publish bootstrap geometry for a blank iframe',
  );
  host.renderStack({ popups: [missing] });
  assert.strictEqual(requests().length, 1,
    'BUG-1804: repeated missing descriptors coalesce the resend request');

  host.renderStack({
    popups: [revisionDescriptor(
      'frame-0', -1, 11, '/* RECOVERY-ENTRIES */', '/* RECOVERY-RENDER */',
      '/* RECOVERY-HEAD */', '/* RECOVERY-TAIL */',
    )],
  });
  const recovered = evalLog.find((e) => /RECOVERY-ENTRIES/.test(e.code));
  assert.ok(recovered && /RECOVERY-HEAD/.test(recovered.code),
    'BUG-1804: routed static resend replays pending dynamic content');
  assert.ok(hostPostLog.some((m) => m.handler === 'overlaySize'),
    'BUG-1804: successful recovery resumes geometry reporting');
}

// P3 (BUG-1804) — resend coalescing is route-scoped. If route A's request is
// rejected after a newer lookup takes ownership, route B must issue its own
// request for the same revision instead of remaining gated forever.
{
  const { host } = freshHost();
  const missing = revisionDescriptor(
    'global-lookup-root', -1, 12, '/* ROUTED-ENTRIES */', '/* ROUTED-RENDER */',
  );
  host.beginLookup('global-lookup-root', {
    source: 'galCard', routeEpoch: 3, lookupEpoch: 1,
  });
  host.renderStack({ popups: [missing] });
  host.beginLookup('global-lookup-root', {
    source: 'galCard', routeEpoch: 3, lookupEpoch: 2,
  });
  host.renderStack({ popups: [missing] });
  const routedRequests = hostPostLog.filter(
    (m) => m.handler === 'staticSettingsRequired' && m.args[0] === 12,
  );
  assert.strictEqual(routedRequests.length, 2,
    'BUG-1804: route B retries the revision even when route A already requested it');
  assert.strictEqual(routedRequests[0].__lookupEpoch, 1);
  assert.strictEqual(routedRequests[1].__lookupEpoch, 2);
}

// P4 (BUG-1804) — static payloads can contain a 9.6 MB font. Revisions no
// longer used by any live descriptor are evicted instead of accumulating for
// the process lifetime.
{
  const { host } = freshHost();
  host.renderStack({
    popups: [revisionDescriptor(
      'global-lookup-root', -1, 20, '/* E20 */', '/* R20 */',
      '/* H20 */', '/* T20 */',
    )],
  });
  host.renderStack({
    popups: [revisionDescriptor(
      'global-lookup-root', -1, 21, '/* E21 */', '/* R21 */',
      '/* H21 */', '/* T21 */',
    )],
  });
  hostPostLog = [];
  host.renderStack({
    popups: [
      revisionDescriptor('global-lookup-root', -1, 21, '/* E21 */', '/* R21 */'),
      revisionDescriptor('old-revision-child', 0, 20, '/* E20B */', '/* R20B */'),
    ],
  });
  assert.ok(hostPostLog.some(
    (m) => m.handler === 'staticSettingsRequired' && m.args[0] === 20,
  ), 'BUG-1804: a no-longer-live revision was evicted from the host cache');
}

console.log('global_lookup_host_test: PASS');
