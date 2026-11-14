// BUG-4499：查词弹窗里点开的放大图（`.dict-image-lightbox`）跨查词残留。
//
// 灯箱挂在 __fushiOverlayParent()（document.body / shadow root），不是 #entries-container
// 的后代：换词重渲染清容器摘不掉它，新查词会话的复位也不碰它，于是上一个词的放大图一直
// 盖在下一次（哪怕是另一个词的）查词结果上，只能再点一下关。
//
// 用 Node 真执行 popup.js（vm + 极简假 DOM，见 _popup_dom_host.js）：
//   1. openImageLightbox 把灯箱挂到 body 上（前提成立）。
//   2. 新查词会话 `__fushiResetPopupScroll`（in-app 热槽全量推送 / app 外根 iframe
//      beginLookup 都走它，含同词重查不重渲染的路径）关掉灯箱。
//   3. 换词重渲染 `renderPopup` 关掉灯箱。
//
// Run: node fushi/test/pages/popup_image_lightbox_session_test.js
// (also driven from popup_image_lightbox_session_test.dart inside `flutter test`).

const assert = require('assert');
const vm = require('vm');
const { loadPopup } = require('./_popup_dom_host.js');

// 让假 DOM 的 querySelector 能按类名找到挂在 body 上的灯箱，并让 remove() 真摘除。
function loadWithLightboxDom() {
  const sandbox = loadPopup();
  const body = sandbox.document.body;
  const origAppend = body.appendChild.bind(body);
  body.appendChild = (child) => {
    child.remove = () => {
      body.children = body.children.filter((c) => c !== child);
      body.childNodes = body.childNodes.filter((c) => c !== child);
    };
    return origAppend(child);
  };
  sandbox.document.querySelector = (sel) => {
    const cls = sel.replace(/^\./, '');
    return body.children.find((c) => c.className === cls) || null;
  };
  sandbox.window.scrollTo = () => {};
  sandbox.document.scrollingElement = { scrollTop: 0, scrollHeight: 0, clientHeight: 0 };
  return sandbox;
}

function lightboxes(sandbox) {
  return sandbox.document.body.children.filter((c) => c.className === 'dict-image-lightbox');
}

// 1 + 2：新查词会话关灯箱。
{
  const sandbox = loadWithLightboxDom();
  vm.runInContext("openImageLightbox('fushi://img/a.png', 'a')", sandbox);
  assert.strictEqual(lightboxes(sandbox).length, 1, 'openImageLightbox mounts the overlay on body');
  vm.runInContext('window.__fushiResetPopupScroll()', sandbox);
  assert.strictEqual(lightboxes(sandbox).length, 0,
    'a new lookup session must close the previous lookup\'s enlarged image');
}

// 3：换词重渲染关灯箱。
{
  const sandbox = loadWithLightboxDom();
  const container = sandbox.document.createElement('div');
  container.id = 'entries-container';
  sandbox.document.getElementById = (id) => (id === 'entries-container' ? container : null);
  vm.runInContext("openImageLightbox('fushi://img/a.png', 'a')", sandbox);
  assert.strictEqual(lightboxes(sandbox).length, 1);
  sandbox.window.lookupEntries = [];
  sandbox.window.renderPopup();
  assert.strictEqual(lightboxes(sandbox).length, 0,
    'renderPopup replacing the entries must close the stale lightbox');
}

console.log('popup_image_lightbox_session: all assertions passed');
