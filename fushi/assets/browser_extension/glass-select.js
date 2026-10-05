// glass-select.js — 扩展自有页面（设置页 / 字幕侧边栏 / 工具栏菜单）的统一下拉组件。
//
// 用户 2026-10-04：原生 <select> 太丑（展开是系统蓝底高亮列表、收起是粗双圈框），换成一套
// 液态玻璃下拉：触发器是玻璃胶囊 + 右侧 chevron，展开面板是玻璃菜单（选中行 = 淡主色底 + ✓、
// 悬停高亮），键盘 ↑↓ / Home / End / PageUp / PageDown / Enter / Space / Esc / Tab / 输入首字
// 定位，ARIA 走 APG「select-only combobox」：焦点始终留在触发器（role=combobox），菜单是
// role=listbox，当前项经 aria-activedescendant 播报。
//
// 渐进增强：原生 <select> 原样留在 DOM 里（只是视觉隐藏），它的 value / selectedIndex / change
// 事件就是唯一真相源——各页面逻辑和测试照旧读写 select，不知道这层存在：
//   - 用户在菜单里选中 → 写 select.value 并派发 input + change（bubbles），与原生一致；
//   - 页面代码改 select.value / selectedIndex → 实例上的访问器拦到后同步触发器文字；
//   - 页面代码重建 <option>（侧边栏换字幕轨）、i18n 改文案、改 hidden / disabled / aria-label →
//     MutationObserver 同步；菜单打开期间选项变了就按新选项重画。
// 选项样式在 material.css（.fgs-*）。脚本缺席时原生 select 照常可用（样式同样在页面 CSS 里）。
//
// 菜单挂在 <body> 上、position: fixed：触发器所在的侧边栏页眉有 backdrop-filter，会把
// fixed 后代的包含块变成页眉自己，菜单留在里面会被裁掉。
(function () {
  'use strict';
  if (typeof window === 'undefined' || typeof document === 'undefined') return;

  var seq = 0;
  var openInstance = null;
  var TYPEAHEAD_MS = 600;
  var CHEVRON = '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false"><path d="M4 6l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  var CHECK = '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false"><path d="M3.5 8.5l3 3 6-7" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';

  function findDescriptor(obj, prop) {
    while (obj) {
      var d = Object.getOwnPropertyDescriptor(obj, prop);
      if (d) return d;
      obj = Object.getPrototypeOf(obj);
    }
    return null;
  }

  function optionText(opt) {
    var t = opt.label != null && opt.label !== '' ? opt.label : opt.textContent;
    return String(t == null ? '' : t).replace(/\s+/g, ' ').trim();
  }

  function enhance(select) {
    if (!select || select.tagName !== 'SELECT' || select.multiple) return null;
    if (select.__fushiGlassSelect) return select.__fushiGlassSelect;
    var uid = 'fgs-' + (++seq);

    var wrap = document.createElement('span');
    wrap.className = 'fgs';
    // 页面给 select 写的布局类（.select-input / .track-select）同样落到外壳上：宽度、外边距、
    // 折叠态隐藏这些版式规则对外壳生效，不必在页面 CSS 里给组件另起一套。
    if (select.className) wrap.className += ' ' + select.className;
    if (select.id) wrap.setAttribute('data-for', select.id);

    var trigger = document.createElement('button');
    trigger.type = 'button';
    trigger.className = 'fgs-trigger';
    trigger.id = uid + '-trigger';
    trigger.setAttribute('role', 'combobox');
    trigger.setAttribute('aria-haspopup', 'listbox');
    trigger.setAttribute('aria-expanded', 'false');
    trigger.setAttribute('aria-controls', uid + '-listbox');
    var valueEl = document.createElement('span');
    valueEl.className = 'fgs-value';
    var chevron = document.createElement('span');
    chevron.className = 'fgs-chevron';
    chevron.innerHTML = CHEVRON;
    trigger.appendChild(valueEl);
    trigger.appendChild(chevron);

    var menu = document.createElement('div');
    menu.className = 'fgs-menu';
    menu.id = uid + '-listbox';
    menu.setAttribute('role', 'listbox');
    menu.tabIndex = -1;
    menu.hidden = true;

    select.parentNode.insertBefore(wrap, select);
    wrap.appendChild(trigger);
    wrap.appendChild(select);
    select.classList.add('fgs-native');
    select.tabIndex = -1;
    select.setAttribute('aria-hidden', 'true');

    var active = -1;
    var typed = '';
    var typedTimer = null;
    var optionEls = [];

    function options() { return Array.prototype.slice.call(select.options || []); }

    function syncLabel() {
      var aria = select.getAttribute('aria-label');
      if (aria) {
        trigger.setAttribute('aria-label', aria);
        trigger.removeAttribute('aria-labelledby');
        menu.setAttribute('aria-label', aria);
        return;
      }
      trigger.removeAttribute('aria-label');
      var label = select.labels && select.labels[0];
      if (!label) return;
      var named = (label.querySelector && label.querySelector('.setting-copy strong')) || label;
      if (!named.id) named.id = uid + '-label';
      trigger.setAttribute('aria-labelledby', named.id + ' ' + valueEl.id);
      menu.setAttribute('aria-labelledby', named.id);
    }
    valueEl.id = uid + '-value';

    function sync() {
      var opts = options();
      var cur = opts[select.selectedIndex];
      valueEl.textContent = cur ? optionText(cur) : '';
      wrap.hidden = !!select.hidden;
      trigger.disabled = !!select.disabled;
      if (select.title) trigger.title = select.title;
      syncLabel();
      if (!menu.hidden) render();
    }

    // 页面代码直接赋值 select.value / selectedIndex 不发事件：在实例上包一层访问器，写完同步。
    ['value', 'selectedIndex'].forEach(function (prop) {
      var d = findDescriptor(select, prop);
      if (!d || typeof d.set !== 'function' || typeof d.get !== 'function') return;
      try {
        Object.defineProperty(select, prop, {
          configurable: true,
          enumerable: d.enumerable,
          get: function () { return d.get.call(this); },
          set: function (v) { d.set.call(this, v); sync(); },
        });
      } catch (_) {}
    });

    function enabledIndex(from, step) {
      var opts = options();
      for (var i = from; i >= 0 && i < opts.length; i += step) {
        if (!opts[i].disabled) return i;
      }
      return -1;
    }

    function setActive(i, scroll) {
      if (i < 0) return;
      active = i;
      for (var k = 0; k < optionEls.length; k++) {
        optionEls[k].classList.toggle('is-active', k === i);
      }
      var el = optionEls[i];
      if (el) {
        trigger.setAttribute('aria-activedescendant', el.id);
        if (scroll && typeof el.scrollIntoView === 'function') el.scrollIntoView({ block: 'nearest' });
      }
    }

    function render() {
      menu.textContent = '';
      optionEls = [];
      options().forEach(function (opt, i) {
        var row = document.createElement('div');
        row.className = 'fgs-option';
        row.id = uid + '-opt-' + i;
        row.setAttribute('role', 'option');
        var selected = i === select.selectedIndex;
        row.setAttribute('aria-selected', selected ? 'true' : 'false');
        if (selected) row.classList.add('is-selected');
        if (opt.disabled) row.setAttribute('aria-disabled', 'true');
        var text = document.createElement('span');
        text.className = 'fgs-option-text';
        text.textContent = optionText(opt);
        var check = document.createElement('span');
        check.className = 'fgs-check';
        check.innerHTML = CHECK;
        row.appendChild(text);
        row.appendChild(check);
        row.addEventListener('pointermove', function () { if (!opt.disabled && active !== i) setActive(i, false); });
        row.addEventListener('click', function () { if (!opt.disabled) commit(i); });
        menu.appendChild(row);
        optionEls.push(row);
      });
      setActive(active >= 0 && active < optionEls.length ? active : select.selectedIndex, false);
    }

    function place() {
      var r = trigger.getBoundingClientRect();
      var vw = window.innerWidth || document.documentElement.clientWidth;
      var vh = window.innerHeight || document.documentElement.clientHeight;
      var gap = 6;
      var width = Math.min(Math.max(r.width, 160), vw - 16);
      var left = Math.min(Math.max(8, r.left), vw - 8 - width);
      menu.style.width = width + 'px';
      menu.style.left = left + 'px';
      menu.style.maxHeight = '';
      var below = vh - r.bottom - gap - 8;
      var above = r.top - gap - 8;
      var natural = Math.min(menu.scrollHeight, 320);
      var up = natural > below && above > below;
      var room = Math.max(96, up ? above : below);
      menu.style.maxHeight = Math.min(320, room) + 'px';
      var h = Math.min(natural, room);
      menu.style.top = (up ? r.top - gap - h : r.bottom + gap) + 'px';
      menu.setAttribute('data-placement', up ? 'top' : 'bottom');
    }

    function open() {
      if (!menu.hidden || trigger.disabled) return;
      if (openInstance && openInstance !== api) openInstance.close();
      openInstance = api;
      active = select.selectedIndex >= 0 ? select.selectedIndex : enabledIndex(0, 1);
      if (!menu.parentNode || menu.parentNode !== document.body) document.body.appendChild(menu);
      render();
      menu.hidden = false;
      wrap.classList.add('is-open');
      trigger.setAttribute('aria-expanded', 'true');
      place();
      setActive(active, true);
    }

    function close() {
      if (menu.hidden) return;
      menu.hidden = true;
      wrap.classList.remove('is-open');
      trigger.setAttribute('aria-expanded', 'false');
      trigger.removeAttribute('aria-activedescendant');
      if (openInstance === api) openInstance = null;
    }

    function commit(i) {
      var opts = options();
      close();
      try { trigger.focus({ preventScroll: true }); } catch (_) { try { trigger.focus(); } catch (_e) {} }
      if (i < 0 || i >= opts.length || opts[i].disabled) return;
      if (i === select.selectedIndex) return;
      select.selectedIndex = i;
      select.dispatchEvent(new Event('input', { bubbles: true }));
      select.dispatchEvent(new Event('change', { bubbles: true }));
    }

    function typeahead(ch) {
      clearTimeout(typedTimer);
      typedTimer = setTimeout(function () { typed = ''; }, TYPEAHEAD_MS);
      var repeat = typed === ch;
      typed = repeat ? ch : typed + ch;
      var needle = typed.toLowerCase();
      var opts = options();
      var n = opts.length;
      // 单字重复按 = 在同首字的项之间轮转（原生 select 同款）；多字 = 从当前项起找前缀。
      var start = (active < 0 ? 0 : active) + (repeat || typed.length === 1 ? 1 : 0);
      for (var k = 0; k < n; k++) {
        var i = (start + k) % n;
        if (!opts[i].disabled && optionText(opts[i]).toLowerCase().indexOf(needle) === 0) {
          setActive(i, true);
          return true;
        }
      }
      return false;
    }

    trigger.addEventListener('click', function () {
      if (menu.hidden) open(); else close();
    });

    trigger.addEventListener('keydown', function (e) {
      var key = e.key;
      var handled = true;
      var isOpen = !menu.hidden;
      var n = options().length;
      if (!isOpen) {
        if (key === 'ArrowDown' || key === 'ArrowUp' || key === 'Enter' || key === ' ' || key === 'F4' || key === 'Home' || key === 'End') {
          open();
          if (key === 'Home') setActive(enabledIndex(0, 1), true);
          else if (key === 'End') setActive(enabledIndex(n - 1, -1), true);
        } else if (key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
          open();
          typeahead(key);
        } else {
          handled = false;
        }
      } else if (key === 'ArrowDown') {
        if (e.altKey) commit(active); else setActive(enabledIndex(active + 1, 1) >= 0 ? enabledIndex(active + 1, 1) : active, true);
      } else if (key === 'ArrowUp') {
        if (e.altKey) commit(active); else setActive(enabledIndex(active - 1, -1) >= 0 ? enabledIndex(active - 1, -1) : active, true);
      } else if (key === 'Home') {
        setActive(enabledIndex(0, 1), true);
      } else if (key === 'End') {
        setActive(enabledIndex(n - 1, -1), true);
      } else if (key === 'PageDown') {
        setActive(enabledIndex(Math.min(n - 1, active + 8), -1), true);
      } else if (key === 'PageUp') {
        setActive(enabledIndex(Math.max(0, active - 8), 1), true);
      } else if (key === 'Enter' || (key === ' ' && !typed)) {
        commit(active);
      } else if (key === 'Escape') {
        close();
      } else if (key === 'Tab') {
        commit(active);
        handled = false; // 焦点照常移走
      } else if (key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
        typeahead(key);
      } else {
        handled = false;
      }
      if (handled) {
        e.preventDefault();
        // 侧边栏 / 设置页在 document 上挂了全局快捷键（Esc 关查词等），这里吃掉的键不再外溢。
        e.stopPropagation();
      }
    });

    trigger.addEventListener('blur', function () {
      // 点菜单项时菜单的 pointerdown 已 preventDefault 留住焦点；真正离开（点别处 / 切窗口）就收起。
      setTimeout(function () { if (document.activeElement !== trigger) close(); }, 0);
    });

    menu.addEventListener('pointerdown', function (e) { e.preventDefault(); });
    menu.addEventListener('mousedown', function (e) { e.preventDefault(); });

    // label[for] / 包住整行的 label：点文字时把焦点给触发器（隐藏的原生 select 接不住焦点）。
    try {
      Array.prototype.forEach.call(select.labels || [], function (label) {
        label.addEventListener('click', function (e) {
          if (wrap.contains(e.target)) return;
          e.preventDefault();
          if (!trigger.disabled) trigger.focus();
        });
      });
    } catch (_) {}

    select.addEventListener('change', sync);

    if (typeof MutationObserver === 'function') {
      new MutationObserver(sync).observe(select, {
        subtree: true,
        childList: true,
        characterData: true,
        attributes: true,
        attributeFilter: ['hidden', 'disabled', 'aria-label', 'label', 'selected', 'title'],
      });
    }

    var api = { select: select, wrap: wrap, trigger: trigger, menu: menu, open: open, close: close, sync: sync, place: place };
    select.__fushiGlassSelect = api;
    sync();
    return api;
  }

  function enhanceAll(root) {
    var list = (root || document).querySelectorAll('select');
    for (var i = 0; i < list.length; i++) enhance(list[i]);
  }

  // 全局：点在菜单与触发器之外收起；窗口尺寸变了（拖宽侧边栏）、滚动（菜单自身除外）时
  // 跟随触发器重定位。
  document.addEventListener('pointerdown', function (e) {
    if (!openInstance) return;
    if (openInstance.menu.contains(e.target) || openInstance.wrap.contains(e.target)) return;
    openInstance.close();
  }, true);
  window.addEventListener('resize', function () { if (openInstance) openInstance.place(); });
  window.addEventListener('scroll', function (e) {
    if (!openInstance || openInstance.menu.contains(e.target)) return;
    openInstance.place();
  }, true);

  window.fushiGlassSelect = { enhance: enhance, enhanceAll: enhanceAll };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { enhanceAll(document); });
  } else {
    enhanceAll(document);
  }
})();
