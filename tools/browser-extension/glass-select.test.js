const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// 统一玻璃下拉（glass-select.js，用户 2026-10-04：原生 <select> 太丑，全部换成一套液态玻璃
// 下拉）。本测试钉住：
//  ① 渐进增强：原生 select 留在原处（外壳里、视觉隐藏）且仍是唯一真相源——用户选中写回
//     select.value 并派发 input + change；页面代码直接赋 value / selectedIndex 不发事件也能同步
//     触发器文字；hidden / disabled 随 select；
//  ② ARIA：触发器 role=combobox + aria-haspopup=listbox + aria-expanded + aria-controls，菜单
//     role=listbox，项 role=option + aria-selected，当前项经 aria-activedescendant；
//  ③ 键盘：↓ 打开、↑↓ 移动、Enter 提交、Esc 收起不提交、输入首字定位、吃掉的键不外溢；
//  ④ 菜单挂到 <body>（逃出页眉 backdrop-filter 的包含块），选中行带 ✓；
//  ⑤ 页面接线：设置页 / 侧边栏都加载 glass-select.js，侧栏嵌入资源清单带它；material.css 有
//     胶囊触发器 / 玻璃菜单 / 选中行样式，侧边栏按钮统一玻璃胶囊、选中态主色染色；
//     侧边栏页面 CSS 不再按 #track 画原生框。

const SRC = fs.readFileSync(path.join(__dirname, 'glass-select.js'), 'utf8');

// ── 手搓 DOM（无 jsdom，与仓库其余测试同一路数） ──
function makeDom() {
  const doc = { listeners: {}, activeElement: null, readyState: 'complete' };
  class El {
    constructor(tag) {
      this.tagName = tag.toUpperCase();
      this.children = [];
      this.parentNode = null;
      this.attrs = {};
      this.listeners = {};
      this.style = {};
      this.hidden = false;
      this.disabled = false;
      this.tabIndex = 0;
      this._text = '';
      const self = this;
      this.classList = {
        set: new Set(),
        add(...n) { n.forEach((x) => this.set.add(x)); self._syncClass(); },
        remove(...n) { n.forEach((x) => this.set.delete(x)); self._syncClass(); },
        toggle(n, on) { if (on === undefined ? !this.set.has(n) : on) this.set.add(n); else this.set.delete(n); self._syncClass(); },
        contains(n) { return this.set.has(n); },
      };
      this._className = '';
    }
    get className() { return this._className; }
    set className(v) { this._className = String(v); this.classList.set = new Set(this._className.split(/\s+/).filter(Boolean)); }
    _syncClass() { this._className = [...this.classList.set].join(' '); }
    get id() { return this.attrs.id || ''; }
    set id(v) { this.attrs.id = String(v); }
    setAttribute(k, v) { if (k === 'class') this.className = v; else this.attrs[k] = String(v); }
    getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
    removeAttribute(k) { delete this.attrs[k]; }
    appendChild(c) { if (c.parentNode) c.parentNode.removeChild(c); c.parentNode = this; this.children.push(c); return c; }
    insertBefore(c, ref) {
      if (c.parentNode) c.parentNode.removeChild(c);
      c.parentNode = this;
      const i = this.children.indexOf(ref);
      this.children.splice(i < 0 ? this.children.length : i, 0, c);
      return c;
    }
    removeChild(c) { this.children = this.children.filter((x) => x !== c); c.parentNode = null; return c; }
    contains(n) { for (let x = n; x; x = x.parentNode) if (x === this) return true; return false; }
    get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); }
    set textContent(v) { this.children.forEach((c) => { c.parentNode = null; }); this.children = []; this._text = String(v); }
    set innerHTML(v) { this._html = v; }
    get innerHTML() { return this._html || ''; }
    addEventListener(t, fn) { (this.listeners[t] = this.listeners[t] || []).push(fn); }
    dispatchEvent(ev) {
      if (!ev.target) Object.defineProperty(ev, 'target', { value: this, configurable: true });
      for (let x = this; x; x = x.parentNode) {
        (x.listeners[ev.type] || []).forEach((fn) => fn(ev));
        if (!ev.bubbles) break;
      }
      return true;
    }
    focus() { doc.activeElement = this; }
    getBoundingClientRect() { return { left: 20, top: 40, right: 220, bottom: 76, width: 200, height: 36 }; }
    get scrollHeight() { return this.children.length * 34 + 10; }
    scrollIntoView() {}
    querySelector() { return null; }
  }
  class Option extends El {
    constructor(value, text) { super('option'); this.value = value; this._text = text; this.label = ''; }
  }
  class Select extends El {
    constructor() { super('select'); this._sel = -1; this.labels = []; this.multiple = false; }
    get options() { return this.children.filter((c) => c instanceof Option); }
    appendChild(c) { super.appendChild(c); if (this._sel < 0 && c instanceof Option) this._sel = 0; return c; }
    set textContent(v) { super.textContent = v; this._sel = -1; }
    get textContent() { return super.textContent; }
  }
  Object.defineProperty(Select.prototype, 'selectedIndex', {
    configurable: true,
    get() { return this._sel < this.options.length ? this._sel : -1; },
    set(i) { this._sel = i; },
  });
  Object.defineProperty(Select.prototype, 'value', {
    configurable: true,
    get() { const o = this.options[this.selectedIndex]; return o ? o.value : ''; },
    set(v) { this._sel = this.options.findIndex((o) => o.value === v); },
  });
  doc.body = new El('body');
  doc.documentElement = new El('html');
  doc.createElement = (t) => new El(t);
  doc.addEventListener = (t, fn) => { (doc.listeners[t] = doc.listeners[t] || []).push(fn); };
  doc.querySelectorAll = (sel) => {
    const out = [];
    const walk = (n) => { if (sel === 'select' && n instanceof Select) out.push(n); n.children.forEach(walk); };
    walk(doc.body);
    return out;
  };
  return { doc, El, Option, Select };
}

function load(build) {
  const dom = makeDom();
  build(dom);
  const win = { innerWidth: 400, innerHeight: 800, listeners: {}, addEventListener(t, fn) { (this.listeners[t] = this.listeners[t] || []).push(fn); } };
  const sandbox = {
    window: win, document: dom.doc, Event,
    setTimeout: () => 0, clearTimeout: () => {},
    console,
  };
  vm.createContext(sandbox);
  vm.runInContext(SRC, sandbox, { filename: 'glass-select.js' });
  return { dom, win, api: win.fushiGlassSelect };
}

function key(el, k, extra) {
  const ev = Object.assign({ type: 'keydown', key: k, altKey: false, ctrlKey: false, metaKey: false, defaultPrevented: false, propagationStopped: false,
    preventDefault() { this.defaultPrevented = true; }, stopPropagation() { this.propagationStopped = true; } }, extra);
  (el.listeners.keydown || []).forEach((fn) => fn(ev));
  return ev;
}

function trackPanel() {
  let select;
  const r = load(({ doc, Option, Select }) => {
    const header = doc.createElement('header');
    doc.body.appendChild(header);
    select = new Select();
    select.id = 'track';
    select.className = 'track-select';
    select.setAttribute('aria-label', '字幕轨');
    header.appendChild(select);
    select.appendChild(new Option('ja', '日语 (自动生成)（95）'));
    select.appendChild(new Option('live', '实时采集（1）'));
    select.appendChild(new Option('en', 'English（40）'));
  });
  const ui = select.__fushiGlassSelect;
  return Object.assign(r, { select, ui });
}

test('渐进增强：原生 select 留在外壳里作真相源，外壳带上布局类，触发器显示当前项', () => {
  const { select, ui } = trackPanel();
  assert.ok(ui, '页面里的 select 自动增强');
  assert.strictEqual(select.parentNode, ui.wrap);
  assert.ok(ui.wrap.classList.contains('fgs') && ui.wrap.classList.contains('track-select'));
  assert.ok(select.classList.contains('fgs-native'));
  assert.strictEqual(select.tabIndex, -1);
  assert.strictEqual(select.id, 'track', '页面逻辑仍按原 id 找 select');
  assert.strictEqual(ui.trigger.textContent, '日语 (自动生成)（95）');
});

test('ARIA：combobox + listbox + option + aria-activedescendant', () => {
  const { ui } = trackPanel();
  const t = ui.trigger;
  assert.strictEqual(t.getAttribute('role'), 'combobox');
  assert.strictEqual(t.getAttribute('aria-haspopup'), 'listbox');
  assert.strictEqual(t.getAttribute('aria-expanded'), 'false');
  assert.strictEqual(t.getAttribute('aria-controls'), ui.menu.id);
  assert.strictEqual(t.getAttribute('aria-label'), '字幕轨');
  assert.strictEqual(ui.menu.getAttribute('role'), 'listbox');
  ui.open();
  assert.strictEqual(t.getAttribute('aria-expanded'), 'true');
  const rows = ui.menu.children;
  assert.strictEqual(rows.length, 3);
  assert.ok(rows.every((r) => r.getAttribute('role') === 'option'));
  assert.strictEqual(rows[0].getAttribute('aria-selected'), 'true');
  assert.ok(rows[0].classList.contains('is-selected'), '选中行带 ✓ 样式钩子');
  assert.strictEqual(t.getAttribute('aria-activedescendant'), rows[0].id);
});

test('菜单挂到 <body>，fixed 定位贴在触发器下方', () => {
  const { dom, ui } = trackPanel();
  ui.open();
  assert.strictEqual(ui.menu.parentNode, dom.doc.body);
  assert.strictEqual(ui.menu.style.top, (76 + 6) + 'px');
  assert.strictEqual(ui.menu.style.width, '200px');
});

test('键盘：↓ 打开、↓ 移动、Enter 提交并派发 input + change；吃掉的键不外溢', () => {
  const { select, ui } = trackPanel();
  const events = [];
  select.addEventListener('input', () => events.push('input:' + select.value));
  select.addEventListener('change', () => events.push('change:' + select.value));
  let ev = key(ui.trigger, 'ArrowDown');
  assert.ok(!ui.menu.hidden, '↓ 打开菜单');
  assert.ok(ev.defaultPrevented && ev.propagationStopped);
  key(ui.trigger, 'ArrowDown');
  assert.strictEqual(ui.trigger.getAttribute('aria-activedescendant'), ui.menu.children[1].id);
  assert.deepStrictEqual(events, [], '移动高亮不改值');
  ev = key(ui.trigger, 'Enter');
  assert.ok(ui.menu.hidden);
  assert.strictEqual(select.value, 'live');
  assert.deepStrictEqual(events, ['input:live', 'change:live']);
  assert.strictEqual(ui.trigger.textContent, '实时采集（1）');
});

test('键盘：Esc 收起不提交且不外溢（侧边栏 Esc 关查词不被误触）；输入首字定位', () => {
  const { select, ui } = trackPanel();
  key(ui.trigger, 'ArrowDown');
  key(ui.trigger, 'ArrowDown');
  const esc = key(ui.trigger, 'Escape');
  assert.ok(ui.menu.hidden);
  assert.ok(esc.propagationStopped);
  assert.strictEqual(select.value, 'ja');
  key(ui.trigger, 'e');
  assert.ok(!ui.menu.hidden, '输入字符打开菜单');
  assert.strictEqual(ui.trigger.getAttribute('aria-activedescendant'), ui.menu.children[2].id, '定位到 English');
  key(ui.trigger, 'Enter');
  assert.strictEqual(select.value, 'en');
});

test('鼠标：点触发器开合、点选项提交；选同一项不派发 change', () => {
  const { select, ui } = trackPanel();
  let changes = 0;
  select.addEventListener('change', () => changes++);
  ui.trigger.dispatchEvent({ type: 'click' });
  assert.ok(!ui.menu.hidden);
  ui.menu.children[0].dispatchEvent({ type: 'click' });
  assert.ok(ui.menu.hidden);
  assert.strictEqual(changes, 0);
  ui.trigger.dispatchEvent({ type: 'click' });
  ui.menu.children[2].dispatchEvent({ type: 'click' });
  assert.strictEqual(select.value, 'en');
  assert.strictEqual(changes, 1);
});

test('页面代码直接赋 value / selectedIndex（不发事件）也同步触发器；hidden / disabled 随 select', () => {
  const { select, ui, dom } = trackPanel();
  select.value = 'en';
  assert.strictEqual(ui.trigger.textContent, 'English（40）');
  select.selectedIndex = 1;
  assert.strictEqual(ui.trigger.textContent, '实时采集（1）');
  // 侧边栏换轨：清空重建选项后赋值。
  select.textContent = '';
  select.appendChild(new dom.Option('fr', 'Français（3）'));
  select.hidden = true;
  select.value = 'fr';
  assert.strictEqual(ui.trigger.textContent, 'Français（3）');
  assert.strictEqual(ui.wrap.hidden, true);
  select.hidden = false;
  select.disabled = true;
  ui.sync();
  assert.strictEqual(ui.wrap.hidden, false);
  assert.strictEqual(ui.trigger.disabled, true);
  key(ui.trigger, 'ArrowDown');
  assert.ok(ui.menu.hidden, '禁用时不打开');
});

test('页面接线：设置页 / 侧边栏加载组件，侧栏嵌入资源带它，所有 select 都在这两页', () => {
  for (const page of ['options.html', 'side-panel.html']) {
    const html = fs.readFileSync(path.join(__dirname, page), 'utf8');
    assert.match(html, /<script src="glass-select\.js"><\/script>/, page);
    assert.match(html, /href="material\.css"/, page);
  }
  const popup = fs.readFileSync(path.join(__dirname, 'vendor', 'action-popup.html'), 'utf8');
  assert.doesNotMatch(popup, /<select/, '工具栏菜单出现 select 时要同样加载 glass-select.js');
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, 'manifest.json'), 'utf8'));
  assert.ok(manifest.web_accessible_resources.some((r) => r.resources.includes('glass-select.js')));
  const sp = fs.readFileSync(path.join(__dirname, 'side-panel.html'), 'utf8');
  assert.match(sp, /<select id="track" class="track-select"/);
  const spCss = fs.readFileSync(path.join(__dirname, 'side-panel.css'), 'utf8');
  assert.doesNotMatch(spCss, /#track\b/, '选轨版式挂在 .track-select 上（外壳与原生 select 同类）');
});

test('material.css：胶囊触发器 + 材质菜单 + 选中行 ✓；侧边栏按钮统一玻璃胶囊、AS 选中态主色染色', () => {
  const css = fs.readFileSync(path.join(__dirname, 'material.css'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
  const rule = (sel) => {
    const at = css.indexOf(sel + ' {');
    assert.ok(at >= 0, '缺规则 ' + sel);
    return css.slice(at, css.indexOf('}', at));
  };
  const trig = rule(':root .fgs-trigger');
  // 形状 / 材质取 theme.css 的风格 token（玻璃 = 999px 胶囊 + 模糊；M3E = 圆角方 + 实色）。
  assert.match(trig, /border-radius:\s*var\(--fushi-shape-field\)/);
  assert.match(trig, /backdrop-filter:\s*var\(--fushi-mat-filter\)/);
  const menu = rule(':root .fgs-menu');
  assert.match(menu, /position:\s*fixed/);
  assert.match(menu, /border-radius:\s*var\(--fushi-shape-menu\)/);
  assert.match(menu, /backdrop-filter:\s*var\(--fushi-mat-filter\)/);
  const opt = rule(':root .fgs-option');
  const h = Number(/min-height:\s*(\d+)px/.exec(opt)[1]);
  assert.ok(h >= 32 && h <= 36, '行高 32–36');
  assert.match(rule(':root .fgs-option.is-selected'), /--fushi-primary-soft/);
  assert.match(css, /:root \.fgs-option\.is-selected \.fgs-check \{\s*visibility:\s*visible/);
  assert.match(css, /:root \.fgs \.fgs-native \{[^}]*opacity:\s*0/);
  const btn = rule(':root :is(.toolbar, .offset-row, .subs-row) button,\n:root .hdr-fold,\n:root .timestamp');
  assert.match(btn, /border-radius:\s*var\(--fushi-shape-control\)/);
  assert.match(btn, /border:\s*1px solid var\(--fushi-mat-edge\)/);
  assert.match(rule(':root .toolbar button.is-on,\n:root .toolbar button.is-on:hover'), /--fushi-primary-soft/);
});
