// 取词扫描 + 弹窗注入。修饰键默认 Shift。普通 DOM（popup.js 依赖顶层 #entries-container）。
// 样式经 content.css 注入，全部作用域到 #entries-container，不污染宿主页（TODO-1090）。
const HIBIKI_MOD = 'shiftKey';
const HIBIKI_MAX_LEN = 12;
let hibikiContainer = null;

/**
 * 跟随宿主页配色返回弹窗主题名。
 * @returns {'dark'|'light'}
 */
function hibikiResolveTheme() {
  return (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches)
    ? 'dark'
    : 'light';
}

function hibikiEnsureContainer() {
  if (hibikiContainer && document.body.contains(hibikiContainer)) return hibikiContainer;
  let c = document.getElementById('entries-container');
  if (!c) {
    c = document.createElement('div');
    c.id = 'entries-container';
    c.style.cssText = 'position:absolute;z-index:2147483647;max-width:400px;';
    // content.css 把主题变量作用域到 #entries-container[data-theme]，
    // 主题属性必须落在弹窗根上（不再改宿主 <html>），否则文字/背景色回退到空值。
    c.setAttribute('data-theme', hibikiResolveTheme());
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
