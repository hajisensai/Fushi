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
//   7. per-frame settingsJs is eval'd inside that frame's contentWindow realm.

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
    // contentWindow.eval records what host.js injects per frame.
    el.contentWindow = {
      eval(code) {
        evalLog.push({ frameId: el.parentNode && el.parentNode.attributes['data-frame-id'], code });
      },
    };
  }
  return el;
}

function makeDocument() {
  const body = makeElement('body');
  const doc = {
    body,
    documentElement: makeElement('html'),
    _byId: {},
    createElement(tag) {
      return makeElement(tag);
    },
    getElementById(id) {
      // host.js only looks up the layer it created; track ids on append.
      return doc._byId[id] || null;
    },
  };
  // Patch body.appendChild to register ids (host.js sets layer.id then appends).
  const origAppend = body.appendChild;
  body.appendChild = function (child) {
    if (child.id) doc._byId[child.id] = child;
    return origAppend.call(body, child);
  };
  return doc;
}

// Build a fresh sandbox + load host.js into it.
function freshHost() {
  evalLog = [];
  const document = makeDocument();
  const sandbox = {
    window: {},
    document,
    Map,
    Set,
    WeakMap,
    console,
  };
  sandbox.window.document = document;
  runInNewContext(hostSrc, sandbox);
  return { host: sandbox.window.__globalLookupHost, document };
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

console.log('global_lookup_host_test: PASS');
