// 反馈 0RgCNJFQmJ / 审查 #3487：活动轨按需取轨失败后，侧栏下拉里再点同一项必须能重试。
// 浏览器对 <select> 只在值变化时发 change；失败的活动轨若仍是选中值，再点它什么都不发生，
// 「重新选择可重试」（sp_track_failed_suffix）就落空。这里在受控 vm 里跑真的 renderTracks，
// 用一个按浏览器语义取值的假 <select> 钉住：失败活动轨不占选中值、闭合态仍显示「加载失败」。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function extract(src, name) {
  const start = src.indexOf('function ' + name + '(');
  assert.ok(start >= 0, name + ' 不见了');
  let depth = 0;
  for (let i = src.indexOf('{', start); i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  throw new Error('unbalanced ' + name);
}

// 假 <select>：value 赋值只会选中值相同的 option（与浏览器一致，禁用项也能被程序选中）；
// 没有匹配项时 selectedIndex = -1。用户在下拉里选某项时只有值变化才发 change。
function fakeSelect() {
  const sel = {
    options: [], selectedIndex: -1, hidden: false, changes: 0,
    set textContent(_v) { this.options = []; this.selectedIndex = -1; },
    appendChild(o) { this.options.push(o); if (this.selectedIndex < 0 && !o.disabled) this.selectedIndex = this.options.length - 1; return o; },
    get value() { return this.selectedIndex >= 0 ? this.options[this.selectedIndex].value : ''; },
    set value(v) { this.selectedIndex = this.options.findIndex((o) => o.value === String(v)); },
    shownText() { return this.selectedIndex >= 0 ? this.options[this.selectedIndex].textContent : ''; },
    userPicks(lang) {
      const idx = this.options.findIndex((o) => o.value === lang && !o.disabled && !o.hidden);
      assert.ok(idx >= 0, '下拉里要能看见并选 ' + lang);
      if (idx !== this.selectedIndex) { this.selectedIndex = idx; this.changes++; }
    },
  };
  return sel;
}

function loadRenderTracks() {
  const src = fs.readFileSync(path.join(__dirname, 'side-panel.js'), 'utf8');
  const trackEl = fakeSelect();
  const ctx = {
    trackEl,
    offsetEl: { hidden: false },
    offsetValueEl: { value: '' },
    trackSig: '~',
    document: { activeElement: null, createElement: () => ({ value: '', textContent: '', disabled: false, hidden: false }) },
    tr: (k) => ({ sp_track_failed_suffix: '（加载失败）', sp_track_pending_suffix: '（选中加载）' })[k] || k,
    formatOffsetSeconds: (ms) => String(ms),
  };
  vm.createContext(ctx);
  vm.runInContext(extract(src, 'renderTracks'), ctx);
  return { trackEl, render: (state) => ctx.renderTracks(state) };
}

const TRACKS = [
  { lang: 'ar', label: 'Arabic', length: 3, signature: 's' },
  { lang: 'ja', label: 'Japanese', length: 0, signature: '0', pending: true, failed: true },
];

test('失败的活动轨：闭合态仍显示「加载失败」，在下拉里再选它会发 change（可重试）', () => {
  const { trackEl, render } = loadRenderTracks();
  render({ activeLang: 'ja', tracks: TRACKS, offsetMs: 0 });
  assert.strictEqual(trackEl.shownText(), 'Japanese（加载失败）');
  assert.notStrictEqual(trackEl.value, 'ja', '失败活动轨不能占着选中值，否则再选同一项没有 change');
  trackEl.userPicks('ja');
  assert.strictEqual(trackEl.changes, 1);
  assert.strictEqual(trackEl.value, 'ja');
});

test('正常活动轨照旧是选中值；重取后（不再 failed）选中值回到这条轨', () => {
  const { trackEl, render } = loadRenderTracks();
  render({ activeLang: 'ar', tracks: TRACKS, offsetMs: 0 });
  assert.strictEqual(trackEl.value, 'ar');
  assert.strictEqual(trackEl.options.length, 2, '没有失败活动轨就不加占位项');
  render({ activeLang: 'ja', tracks: [TRACKS[0], Object.assign({}, TRACKS[1], { failed: false })], offsetMs: 0 });
  assert.strictEqual(trackEl.value, 'ja');
  assert.strictEqual(trackEl.shownText(), 'Japanese（选中加载）');
});

test('change 处理跳过占位项的空值', () => {
  const src = fs.readFileSync(path.join(__dirname, 'side-panel.js'), 'utf8');
  assert.match(src, /trackEl\.addEventListener\('change', async function \(\) \{\s*if \(!trackEl\.value\) return;/);
});
