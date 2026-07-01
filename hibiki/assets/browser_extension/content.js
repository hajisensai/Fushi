// 取词扫描 + 弹窗注入。修饰键默认 Shift。普通 DOM（popup.js 依赖顶层 #entries-container）。
const HIBIKI_MOD = 'shiftKey';
const HIBIKI_MAX_LEN = 12;
let hibikiContainer = null;

function hibikiEnsureContainer() {
  if (hibikiContainer && document.body.contains(hibikiContainer)) return hibikiContainer;
  let c = document.getElementById('entries-container');
  if (!c) {
    c = document.createElement('div');
    c.id = 'entries-container';
    c.style.cssText = 'position:absolute;z-index:2147483647;max-width:400px;';
    document.body.appendChild(c);
  }
  hibikiContainer = c;
  return c;
}

function hibikiRemoveContainer() {
  if (hibikiContainer) { hibikiContainer.remove(); hibikiContainer = null; }
}

function hibikiCaretFromPoint(x, y) {
  if (document.caretRangeFromPoint) return document.caretRangeFromPoint(x, y);
  if (document.caretPositionFromPoint) {
    const p = document.caretPositionFromPoint(x, y);
    if (!p) return null;
    const r = document.createRange();
    r.setStart(p.offsetNode, p.offset);
    return r;
  }
  return null;
}

document.addEventListener('mousemove', (e) => {
  if (!e[HIBIKI_MOD]) return;
  const range = hibikiCaretFromPoint(e.clientX, e.clientY);
  if (!range || range.startContainer.nodeType !== Node.TEXT_NODE) return;
  const term = expandWordWindow(range.startContainer, range.startOffset, HIBIKI_MAX_LEN);
  if (!term.trim()) return;
  chrome.runtime.sendMessage({ type: 'lookup', term }, (resp) => {
    if (!resp || !resp.ok || !resp.data || !resp.data.popupJson) return;
    hibikiRender(resp.data.popupJson, e.pageX, e.pageY);
  });
});

function hibikiRender(popupJson, x, y) {
  const c = hibikiEnsureContainer();
  c.style.left = x + 'px';
  c.style.top = y + 'px';
  try { window.lookupEntries = JSON.parse(popupJson); }
  catch (_) { window.lookupEntries = []; }
  window._noResultsMessage = 'No results';
  window.__hibikiOnTapOutside = hibikiRemoveContainer;
  if (typeof window.renderPopup === 'function') window.renderPopup();
}

document.addEventListener('mousedown', (e) => {
  if (hibikiContainer && !hibikiContainer.contains(e.target)) hibikiRemoveContainer();
});
