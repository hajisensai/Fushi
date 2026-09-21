// 播放器内嵌字幕控制（content script 隔离世界，manifest bundle 里排在 subtitle-panel.js 之后）。
//
// 在站点自己的播放器控制栏里挂一颗 Fushi 按钮，点开就是字幕开关 + 字幕外观的就近入口——
// 看片中途想在「Fushi 字幕 ↔ 站点自带字幕」之间切、想把字幕调大一点，此前只有两条路：
// 跑一趟扩展设置页，或者记住快捷键。两条都要求用户离开画面。
//
// 三条不变式：
//  · **不新增任何状态**。每一项都写既有的 chrome.storage.local 键（subtitleOverlayEnabled /
//    subtitleReplaceNative / subtitleOverlayAllTracks / subtitleOverlayBackground / subtitleStyle）
//    或调既有执行端（content.js 的 fushiToggleSubtitleHiding、subtitle-panel.js 的
//    fushiSubtitleShortcut）。options 页、工具栏弹窗、本菜单三处看到的永远是同一个值，
//    因为三处都只经 storage.onChanged 回读。覆盖层总开关的写法与工具栏弹窗逐字同构
//    （overlayToggleWrite，守卫 player-controls.test.js 交叉比对 vendor/action-popup.js）。
//  · **按钮进站点控制栏，菜单不进**。按钮插进 .ytp-right-controls / Netflix 控件行，于是全屏、
//    控件自动隐藏、主题都跟着站点走，零维护；菜单是 fixed 浮层挂 fullscreenElement||body
//    （与查词弹窗 / 字幕覆盖层同一策略），免得被控制栏的 overflow 裁掉。
//  · **事件不漏给站点**。播放器把点画面当播放/暂停、把空格方向键当播放控制，所以按钮与菜单上的
//    指针事件与键盘事件一律 stopPropagation（content.js 的弹窗与模态同款）。
//
// 站点适配只有两条特例（YouTube / Netflix），其余站点退回「悬停视频时浮在右下角」的通用按钮——
// 通用路径不依赖任何站点 DOM，所以不会随站点改版失效。
//
// 判定与菜单模型是纯函数（node 可测）；DOM 装配在下半段。
(function (root, factory) {
  var api = factory();
  try { if (typeof module !== 'undefined' && module.exports) module.exports = api; } catch (_) { /* no-op */ }
  if (root) root.FUSHI_PLAYER_CONTROLS = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // 本模块的总开关（options 页「播放器内字幕按钮」）。默认开；关掉后一个节点都不挂。
  var SETTING_KEY = 'playerControls';
  var PANEL_GATE_KEY = 'netflixSubtitlePanel';
  var BTN_ID = 'fushi-player-btn';
  var MENU_ID = 'fushi-player-controls';
  var MENU_GAP = 8;     // 菜单与按钮之间的间隙（px）
  var VIEWPORT_PAD = 8; // 菜单离视口边缘的最小留白（px）
  var MIN_VIDEO_W = 200; // 通用按钮的视频门（与 study-tracker 同口径：挡掉首页悬停预览/预告片）
  var MIN_VIDEO_H = 120;
  var MIN_VIDEO_SEC = 30;

  function tr(key, params) {
    var g = (typeof window !== 'undefined') ? window : (typeof globalThis !== 'undefined' ? globalThis : null);
    return (g && typeof g.fushiT === 'function') ? g.fushiT(key, params) : key;
  }

  // ────────────────────────────── 纯函数区（node 可测） ──────────────────────────────

  // 站点判定。与 subtitle-providers.js fushiSite() 同口径，但这里只关心「控制栏长什么样」，
  // 所以除 youtube / netflix 外一律 ''（= 通用悬浮按钮），不区分 bilibili 之类。
  function siteOf(hostname) {
    var h = String(hostname || '').toLowerCase();
    if (h === 'youtube.com' || h.endsWith('.youtube.com') || h === 'youtu.be') return 'youtube';
    if (h === 'netflix.com' || h.endsWith('.netflix.com')) return 'netflix';
    return '';
  }

  // 覆盖层总开关的写入内容。**与 vendor/action-popup.js 的 fushiOverlayToggleWrite 必须逐字同义**：
  // 关→开时顺带打开字幕能力总门（覆盖层受它门控，没开过侧边栏的用户单开覆盖层等于什么都不发生），
  // 开→关只翻自己（用户可能还在用侧边栏列表）。守卫在 player-controls.test.js 交叉比对两份实现。
  function overlayToggleWrite(currentlyOn) {
    if (currentlyOn) {
      var off = {};
      off.subtitleOverlayEnabled = false;
      return off;
    }
    var on = {};
    on.subtitleOverlayEnabled = true;
    on[PANEL_GATE_KEY] = true;
    return on;
  }

  // 只有显式 false 才算关——与 subtitle-panel.js applySubtitlePreferences 同型（缺省 = 开）。
  function readBool(stored, key, dflt) {
    var v = stored ? stored[key] : undefined;
    return typeof v === 'boolean' ? v : dflt;
  }

  // 菜单模型（纯数据，渲染与测试共用）。state:
  //   {overlayOn, replaceNative, allTracks, background, hidden, hasTrack, externalTrack}
  // 三个从属开关在总开关关掉时置灰：它们全部只在覆盖层出画时有意义，亮着会让人以为翻了有用。
  //
  // 文案**一律复用设置页 / 工具栏弹窗既有的键**，不另起一套 pc_ 同义键：同一个开关在三个
  // 表面必须是同一个词（CLAUDE.md「同概念一词」），各写各的迟早分岔成「设置页叫 A、
  // 播放器里叫 B」，而且 17 种语言各多一份要维护的译文。只有这里独有的概念才新增键。
  function menuModel(state) {
    var s = state || {};
    var overlayOn = s.overlayOn !== false;
    var items = [];
    items.push({ id: 'overlay', kind: 'switch', on: overlayOn, label: tr('ap_hp_overlay_toggle_label') });
    items.push({ id: 'replaceNative', kind: 'switch', on: !!s.replaceNative, disabled: !overlayOn, label: tr('opt_subtitleReplaceNative_title') });
    items.push({ id: 'allTracks', kind: 'switch', on: !!s.allTracks, disabled: !overlayOn, label: tr('opt_subtitleOverlayAllTracks_title') });
    items.push({ id: 'background', kind: 'switch', on: s.background !== false, disabled: !overlayOn, label: tr('opt_subtitleOverlayBackground_title') });
    items.push({ id: 'hidden', kind: 'switch', on: !!s.hidden, label: tr('opt_subtitleHidden_title') });
    // 「开着却什么都不画」是覆盖层最容易让人误判坏掉的状态：站点自带轨默认不叠覆盖层
    // （subtitle-panel.js updateSubtitleOverlay 的显示门），外挂轨才无条件画。这里如实说出来，
    // 并给一键出路，而不是让用户以为开关坏了。
    if (overlayOn && !s.hidden && s.hasTrack && !s.externalTrack && !s.replaceNative && !s.allTracks) {
      items.push({ id: 'hint', kind: 'hint', label: tr('pc_hint_site_track'), action: 'replaceNative' });
    }
    items.push({ id: 'list', kind: 'action', label: tr('opt_videoShortcutTogglePanel_title') });
    items.push({
      id: 'offset',
      kind: 'group',
      label: tr('pc_offset_title'),
      // 按钮面是数字与符号（与侧边栏 offset-row 同形，不进 i18n）；说明文字走 title。
      buttons: [
        { id: 'offset-minus', label: '−0.1', title: tr('opt_videoShortcutOffsetMinus_title') },
        { id: 'offset-reset', label: '⟲', title: tr('sp_offset_reset_title') },
        { id: 'offset-plus', label: '＋0.1', title: tr('opt_videoShortcutOffsetPlus_title') },
      ],
    });
    items.push({ id: 'style', kind: 'submenu', label: tr('pc_style_title') });
    items.push({ id: 'settings', kind: 'action', label: tr('sp_settings_title') });
    return items;
  }

  // 字幕外观快捷面板的控件表。字段与取值范围全部取自 fushiSubtitleStyle，本文件不重复定义
  // 任何默认值或上下限——否则设置页与这里迟早分岔（两处各调各的，用户看到两套「默认」）。
  function styleControls(S) {
    if (!S) return [];
    var L = S.LIMITS || {};
    function range(field, step, key) {
      var lim = L[field] || [0, 100];
      return { id: field, kind: 'range', min: lim[0], max: lim[1], step: step, label: tr(key) };
    }
    return [
      range('fontScale', 5, 'opt_subtitleStyleFontScale_title'),
      range('lineHeight', 5, 'opt_subtitleStyleLineHeight_title'),
      {
        id: 'textAlign',
        kind: 'segmented',
        label: tr('opt_subtitleStyleTextAlign_title'),
        options: [
          { value: 'left', label: tr('opt_align_left') },
          { value: 'center', label: tr('opt_align_center') },
          { value: 'right', label: tr('opt_align_right') },
        ],
      },
      {
        id: 'shadow',
        kind: 'segmented',
        label: tr('opt_subtitleStyleShadow_title'),
        options: [
          { value: 'none', label: tr('opt_shadow_none') },
          { value: 'soft', label: tr('opt_shadow_soft') },
          { value: 'strong', label: tr('opt_shadow_strong') },
        ],
      },
      { id: 'textColor', kind: 'color', label: tr('opt_subtitleStyleTextColor_title'), fallback: S.DEFAULT_TEXT_COLOR },
      { id: 'backgroundColor', kind: 'color', label: tr('opt_subtitleStyleBackgroundColor_title'), fallback: S.DEFAULT_BACKGROUND_COLOR },
      range('backgroundOpacity', 1, 'opt_subtitleStyleBackgroundOpacity_title'),
    ];
  }

  // 一次外观改动要落盘什么。与 options.js writeSubtitleStyle 同一条纪律：**等于默认就删键**
  // （不是写一份等值对象），否则「恢复默认」之后存储里仍留着一份快照，将来改了默认值不跟随。
  function stylePatchWrite(current, patch, S) {
    var next = S.normalize(Object.assign({}, S.normalize(current), patch || {}));
    return S.isDefault(next) ? { remove: S.KEY, value: next } : { set: S.KEY, value: next };
  }

  // 菜单落点：右缘对齐按钮右缘、底边压在按钮上方，放不下就翻到按钮下方；再夹进视口。
  // 全屏时视口就是全屏元素，同一套算法两态通用（菜单本身是 position:fixed）。
  function placeMenu(btnRect, menuSize, viewport) {
    var b = btnRect || { left: 0, right: 0, top: 0, bottom: 0 };
    var w = Math.max(0, (menuSize && menuSize.width) || 0);
    var h = Math.max(0, (menuSize && menuSize.height) || 0);
    var vw = Math.max(0, (viewport && viewport.width) || 0);
    var vh = Math.max(0, (viewport && viewport.height) || 0);
    var left = b.right - w;
    var top = b.top - MENU_GAP - h;
    if (top < VIEWPORT_PAD) {
      var below = b.bottom + MENU_GAP;
      // 上方放不下才翻到下方，且下方真放得下才翻——两边都不够时留在上方并夹到顶，
      // 至少菜单头部（开关都在那儿）可见，不至于整块滑出画面。
      if (below + h <= vh - VIEWPORT_PAD) top = below;
    }
    var maxLeft = Math.max(VIEWPORT_PAD, vw - w - VIEWPORT_PAD);
    left = Math.min(Math.max(left, VIEWPORT_PAD), maxLeft);
    var maxTop = Math.max(VIEWPORT_PAD, vh - h - VIEWPORT_PAD);
    top = Math.min(Math.max(top, VIEWPORT_PAD), maxTop);
    return { left: Math.round(left), top: Math.round(top) };
  }

  // 视频是否值得挂按钮（只用于通用站点；YouTube / Netflix 命中控制栏即挂）。
  // 门与 study-tracker 一致：太小的是悬停预览、太短的是卡片预告片。
  function videoQualifies(v) {
    if (!v) return false;
    var w = v.clientWidth || 0;
    var h = v.clientHeight || 0;
    if (w < MIN_VIDEO_W || h < MIN_VIDEO_H) return false;
    var d = Number(v.duration);
    if (!isFinite(d) || d <= 0) return true; // 直播 / 尚未知时长：放行
    return d >= MIN_VIDEO_SEC;
  }

  var api = {
    SETTING_KEY: SETTING_KEY,
    BTN_ID: BTN_ID,
    MENU_ID: MENU_ID,
    siteOf: siteOf,
    overlayToggleWrite: overlayToggleWrite,
    menuModel: menuModel,
    styleControls: styleControls,
    stylePatchWrite: stylePatchWrite,
    placeMenu: placeMenu,
    videoQualifies: videoQualifies,
  };

  if (typeof window === 'undefined' || typeof document === 'undefined') return api;
  if (typeof chrome === 'undefined' || !chrome.storage || !chrome.storage.local) return api;

  // ────────────────────────────── DOM 装配 ──────────────────────────────

  var st = {
    enabled: true,
    prefs: {
      subtitleOverlayEnabled: true,
      subtitleReplaceNative: false,
      subtitleOverlayAllTracks: false,
      subtitleOverlayBackground: true,
      subtitleHidden: false,
    },
    style: null,
    open: false,
    page: 'main',
    hoverVideo: false,
  };
  var btnEl = null;
  var menuEl = null;
  var mainPageEl = null;
  var stylePageEl = null;
  var styleWriteTimer = null;
  var site = siteOf(location.hostname);

  function S() { return window.fushiSubtitleStyle || null; }

  function videoEl() {
    // 与全仓库同一条取法（subtitle-panel.js:121 等）：第一条 <video>。站点的画中画/广告位也可能
    // 是 <video>，但控制栏锚点本身就长在正片播放器上，通用路径另有尺寸门，两边都不会挂错地方。
    try { return document.querySelector('video'); } catch (_) { return null; }
  }

  // 站点控制栏锚点。返回 {parent, before} —— before 为 null 表示追加到末尾。
  // 找不到就返回 null，调用方退回通用悬浮按钮，绝不因为站点改版把按钮整个弄丢。
  function controlAnchor() {
    var v = videoEl();
    if (site === 'youtube') {
      var player = (v && v.closest) ? v.closest('.html5-video-player') : null;
      var right = (player || document).querySelector('.ytp-right-controls');
      // 插在右控件组最前（= 字幕/设置按钮左侧），与站点自己的字幕按钮相邻，够得着。
      if (right) return { parent: right, before: right.firstChild || null };
      return null;
    }
    if (site === 'netflix') {
      // Netflix 的控件行是 React 重建的，class 名逐版本变；锚定「全屏按钮」这个稳定的
      // data-uia 契约，插在它前面（右侧按钮组内），比认 class 名耐用。
      var fs = document.querySelector('[data-uia="control-fullscreen-enter"], [data-uia="control-fullscreen-exit"]');
      if (fs && fs.parentNode) return { parent: fs.parentNode, before: fs };
      return null;
    }
    return null;
  }

  function themeOf() {
    try {
      if (window.fushiTheme && typeof window.fushiTheme.resolve === 'function') return window.fushiTheme.resolve('dark');
    } catch (_) { /* no-op */ }
    return 'dark';
  }

  // 站点把「点画面」当播放/暂停、把空格方向键当播放控制，我们的节点上一律不放行。
  // 不 preventDefault——聚焦、滑杆拖动、颜色选择这些默认行为还要留着。
  function sealEvents(el) {
    var pointer = ['pointerdown', 'pointerup', 'mousedown', 'mouseup', 'click', 'dblclick', 'touchstart', 'touchend', 'wheel'];
    for (var i = 0; i < pointer.length; i++) {
      el.addEventListener(pointer[i], function (e) { e.stopPropagation(); }, false);
    }
    var keys = ['keydown', 'keyup', 'keypress'];
    for (var j = 0; j < keys.length; j++) {
      el.addEventListener(keys[j], function (e) { e.stopPropagation(); }, false);
    }
  }

  function makeButton() {
    var b = document.createElement('button');
    b.id = BTN_ID;
    b.type = 'button';
    b.className = 'fushi-pc-btn';
    b.setAttribute('aria-haspopup', 'true');
    b.setAttribute('aria-expanded', 'false');
    var icon = document.createElement('img');
    icon.className = 'fushi-pc-btn-icon';
    icon.alt = '';
    icon.setAttribute('aria-hidden', 'true');
    try { icon.src = chrome.runtime.getURL('icon-32.png'); } catch (_) { /* no-op */ }
    var state = document.createElement('span');
    state.className = 'fushi-pc-btn-state';
    b.appendChild(icon);
    b.appendChild(state);
    sealEvents(b);
    b.addEventListener('click', function () { toggleMenu(); });
    return b;
  }

  function paintButton() {
    if (!btnEl) return;
    var on = st.prefs.subtitleOverlayEnabled !== false && !st.prefs.subtitleHidden;
    btnEl.dataset.on = on ? '1' : '';
    btnEl.title = tr(on ? 'ap_overlay_toggle_title_on' : 'ap_overlay_toggle_title_off');
    btnEl.setAttribute('aria-label', btnEl.title);
    var state = btnEl.querySelector('.fushi-pc-btn-state');
    if (state) state.textContent = tr(on ? 'ap_toggle_on' : 'ap_toggle_off');
  }

  // 站点重建控制栏（YouTube SPA 导航、Netflix 退出全屏）后按钮会被连根端掉，所以这里是
  // 幂等的「确保在位」而不是「装一次」：节点还在正确容器里就什么都不做。
  function ensureButton() {
    if (!st.enabled) return teardown();
    var anchor = controlAnchor();
    var generic = !anchor;
    if (generic && !videoQualifies(videoEl())) return teardown();
    if (!btnEl) btnEl = makeButton();
    btnEl.classList.toggle('is-floating', generic);
    if (generic) {
      var parent = document.fullscreenElement || document.body;
      // 与 openMenu 同一条护栏：全屏目标是 <video> 时不能往里塞（媒体元素的子节点
      // 是 fallback 内容，永远不渲染）。很多站点直接 video.requestFullscreen()，
      // 漏了这条按钮会在全屏下静默消失——而全屏正是最需要它的时候。
      if (parent && parent.tagName === 'VIDEO') parent = document.body;
      if (parent && btnEl.parentNode !== parent) parent.appendChild(btnEl);
      placeFloatingButton();
    } else if (
      btnEl.parentNode !== anchor.parent ||
      (anchor.before && anchor.before !== btnEl && btnEl.nextSibling !== anchor.before)
    ) {
      // `anchor.before !== btnEl` 不能省：YouTube 的锚点是 `right.firstChild`，
      // 按钮插进去之后它自己就是 firstChild，下一拍算出的 before 就是按钮本身。
      // 少了这条判据，每秒都会 insertBefore(btnEl, btnEl)——DOM 对此的语义是
      // 「先把节点摘下来再插回原位」：站点控制栏每秒挨一次 childList 变更、按钮
      // 上的焦点每秒被清一次（Tab 过去就用不了）、hover/transition 每秒重置。
      anchor.parent.insertBefore(btnEl, anchor.before);
    }
    paintButton();
  }

  // 通用站点的悬浮按钮：贴视频画面右下角，鼠标不在视频上就淡出（站点控件也是这个作息）。
  function placeFloatingButton() {
    var v = videoEl();
    if (!btnEl || !v || typeof v.getBoundingClientRect !== 'function') return;
    var r = v.getBoundingClientRect();
    btnEl.style.left = Math.round(r.right - 52) + 'px';
    btnEl.style.top = Math.round(r.bottom - 52) + 'px';
    btnEl.dataset.visible = (st.open || st.hoverVideo) ? '1' : '';
  }

  function teardown() {
    closeMenu();
    if (btnEl && btnEl.parentNode) btnEl.parentNode.removeChild(btnEl);
    btnEl = null;
  }

  function row(item) {
    var el = document.createElement('div');
    el.className = 'fushi-pc-row';
    el.dataset.item = item.id;
    if (item.disabled) el.dataset.disabled = '1';
    var copy = document.createElement('span');
    copy.className = 'fushi-pc-copy';
    var title = document.createElement('strong');
    title.textContent = item.label;
    copy.appendChild(title);
    if (item.detail) {
      var d = document.createElement('small');
      d.textContent = item.detail;
      copy.appendChild(d);
    }
    el.appendChild(copy);
    return el;
  }

  function renderMain() {
    if (!mainPageEl) return;
    mainPageEl.textContent = '';
    var items = menuModel({
      overlayOn: st.prefs.subtitleOverlayEnabled !== false,
      replaceNative: !!st.prefs.subtitleReplaceNative,
      allTracks: !!st.prefs.subtitleOverlayAllTracks,
      background: st.prefs.subtitleOverlayBackground !== false,
      hidden: !!st.prefs.subtitleHidden,
      hasTrack: hasTrack(),
      externalTrack: hasExternalTrack(),
    });
    for (var i = 0; i < items.length; i++) mainPageEl.appendChild(renderItem(items[i]));
  }

  function renderItem(item) {
    if (item.kind === 'hint') {
      var hint = document.createElement('button');
      hint.type = 'button';
      hint.className = 'fushi-pc-hint';
      hint.dataset.item = item.id;
      hint.textContent = item.label;
      hint.addEventListener('click', function () { writePrefs({ subtitleReplaceNative: true }); });
      return hint;
    }
    if (item.kind === 'group') {
      var g = row(item);
      g.classList.add('is-group');
      var box = document.createElement('span');
      box.className = 'fushi-pc-seg';
      for (var i = 0; i < item.buttons.length; i++) {
        (function (spec) {
          var b = document.createElement('button');
          b.type = 'button';
          b.dataset.action = spec.id;
          b.textContent = spec.label;
          if (spec.title) {
            b.title = spec.title;
            b.setAttribute('aria-label', spec.title);
          }
          b.addEventListener('click', function () { runShortcut(spec.id); });
          box.appendChild(b);
        })(item.buttons[i]);
      }
      g.appendChild(box);
      return g;
    }
    if (item.kind === 'switch') {
      var s = row(item);
      s.classList.add('is-switch');
      s.setAttribute('role', 'switch');
      s.setAttribute('tabindex', '0');
      s.setAttribute('aria-checked', item.on ? 'true' : 'false');
      var sw = document.createElement('span');
      sw.className = 'fushi-pc-switch';
      sw.dataset.on = item.on ? '1' : '';
      s.appendChild(sw);
      if (!item.disabled) {
        s.addEventListener('click', function () { flip(item.id); });
        s.addEventListener('keydown', function (e) {
          if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); flip(item.id); }
        });
      }
      return s;
    }
    var a = row(item);
    a.classList.add(item.kind === 'submenu' ? 'is-submenu' : 'is-action');
    a.setAttribute('role', 'button');
    a.setAttribute('tabindex', '0');
    function go() {
      if (item.id === 'style') showPage('style');
      else if (item.id === 'list') runShortcut('toggle-panel');
      else if (item.id === 'settings') openOptions();
    }
    a.addEventListener('click', go);
    a.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); go(); }
    });
    return a;
  }

  function renderStylePage() {
    if (!stylePageEl) return;
    var mod = S();
    stylePageEl.textContent = '';
    var back = document.createElement('button');
    back.type = 'button';
    back.className = 'fushi-pc-back';
    back.textContent = tr('pc_style_back');
    back.addEventListener('click', function () { showPage('main'); });
    stylePageEl.appendChild(back);
    if (!mod) return;
    var cur = mod.normalize(st.style);
    var controls = styleControls(mod);
    for (var i = 0; i < controls.length; i++) stylePageEl.appendChild(renderStyleControl(controls[i], cur));
    var foot = document.createElement('div');
    foot.className = 'fushi-pc-foot';
    var reset = document.createElement('button');
    reset.type = 'button';
    reset.textContent = tr('pc_style_reset');
    reset.addEventListener('click', function () { writeStyle(mod.DEFAULTS, true); });
    var more = document.createElement('button');
    more.type = 'button';
    more.textContent = tr('pc_style_more');
    more.addEventListener('click', openOptions);
    foot.appendChild(reset);
    foot.appendChild(more);
    stylePageEl.appendChild(foot);
  }

  function renderStyleControl(spec, cur) {
    var el = document.createElement('div');
    el.className = 'fushi-pc-style-row';
    el.dataset.field = spec.id;
    var label = document.createElement('span');
    label.className = 'fushi-pc-style-label';
    label.textContent = spec.label;
    el.appendChild(label);
    if (spec.kind === 'range') {
      var wrap = document.createElement('span');
      wrap.className = 'fushi-pc-range';
      var input = document.createElement('input');
      input.type = 'range';
      input.min = String(spec.min);
      input.max = String(spec.max);
      input.step = String(spec.step);
      input.value = String(cur[spec.id]);
      var out = document.createElement('output');
      out.textContent = String(cur[spec.id]);
      input.addEventListener('input', function () {
        out.textContent = input.value;
        var patch = {};
        patch[spec.id] = Number(input.value);
        writeStyle(patch, false);
      });
      wrap.appendChild(input);
      wrap.appendChild(out);
      el.appendChild(wrap);
      return el;
    }
    if (spec.kind === 'segmented') {
      var seg = document.createElement('span');
      seg.className = 'fushi-pc-seg';
      for (var i = 0; i < spec.options.length; i++) {
        (function (opt) {
          var b = document.createElement('button');
          b.type = 'button';
          b.dataset.value = opt.value;
          b.dataset.on = cur[spec.id] === opt.value ? '1' : '';
          b.textContent = opt.label;
          b.addEventListener('click', function () {
            var patch = {};
            patch[spec.id] = opt.value;
            writeStyle(patch, true);
          });
          seg.appendChild(b);
        })(spec.options[i]);
      }
      el.appendChild(seg);
      return el;
    }
    // color：存的空串 = 跟随主题；<input type="color"> 没有「空」态，所以用默认色回显，
    // 并单给一颗「跟随主题」把值清回空串，不把「没设过」偷偷变成一个具体颜色。
    var colorWrap = document.createElement('span');
    colorWrap.className = 'fushi-pc-color';
    var color = document.createElement('input');
    color.type = 'color';
    color.value = cur[spec.id] || spec.fallback || '#ffffff';
    color.addEventListener('input', function () {
      var patch = {};
      patch[spec.id] = color.value;
      writeStyle(patch, false);
    });
    var auto = document.createElement('button');
    auto.type = 'button';
    auto.className = 'fushi-pc-color-auto';
    auto.dataset.on = cur[spec.id] ? '' : '1';
    auto.textContent = tr('opt_subtitleStyle_follow_theme');
    auto.addEventListener('click', function () {
      var patch = {};
      patch[spec.id] = '';
      writeStyle(patch, true);
    });
    colorWrap.appendChild(color);
    colorWrap.appendChild(auto);
    el.appendChild(colorWrap);
    return el;
  }

  function showPage(page) {
    st.page = page;
    if (page === 'style') renderStylePage();
    if (mainPageEl) mainPageEl.hidden = page !== 'main';
    if (stylePageEl) stylePageEl.hidden = page !== 'style';
    position();
  }

  function ensureMenu() {
    if (menuEl) return menuEl;
    menuEl = document.createElement('div');
    menuEl.id = MENU_ID;
    menuEl.setAttribute('role', 'menu');
    mainPageEl = document.createElement('div');
    mainPageEl.className = 'fushi-pc-page';
    stylePageEl = document.createElement('div');
    stylePageEl.className = 'fushi-pc-page';
    stylePageEl.hidden = true;
    menuEl.appendChild(mainPageEl);
    menuEl.appendChild(stylePageEl);
    sealEvents(menuEl);
    return menuEl;
  }

  function applyMenuTheme() {
    if (!menuEl) return;
    var t = themeOf();
    if (t === 'light' || t === 'dark') menuEl.setAttribute('data-theme', t);
    else menuEl.removeAttribute('data-theme');
  }

  function openMenu() {
    ensureMenu();
    var parent = document.fullscreenElement || document.body;
    // 全屏目标是 <video> 时不能往里塞：媒体元素的子节点是 fallback 内容，永远不渲染
    // （mobile-drawer.js 同一条护栏）。那种页面退回 body——不全屏时本来就对。
    if (parent && parent.tagName === 'VIDEO') parent = document.body;
    if (parent && menuEl.parentNode !== parent) parent.appendChild(menuEl);
    applyMenuTheme();
    st.open = true;
    st.page = 'main';
    renderMain();
    if (mainPageEl) mainPageEl.hidden = false;
    if (stylePageEl) stylePageEl.hidden = true;
    menuEl.dataset.open = '1';
    if (btnEl) btnEl.setAttribute('aria-expanded', 'true');
    position();
    placeFloatingButton();
  }

  function closeMenu() {
    st.open = false;
    if (menuEl) menuEl.dataset.open = '';
    if (btnEl) btnEl.setAttribute('aria-expanded', 'false');
    placeFloatingButton();
  }

  function toggleMenu() { if (st.open) closeMenu(); else openMenu(); }

  function position() {
    if (!menuEl || !btnEl || !st.open) return;
    var r = btnEl.getBoundingClientRect();
    var size = { width: menuEl.offsetWidth, height: menuEl.offsetHeight };
    var view = { width: window.innerWidth || 0, height: window.innerHeight || 0 };
    var p = placeMenu(r, size, view);
    menuEl.style.left = p.left + 'px';
    menuEl.style.top = p.top + 'px';
  }

  // ────────────────────────────── 动作 ──────────────────────────────

  function hasTrack() {
    try {
      var store = window.fushiEpisodeCues;
      if (!store || typeof window.fushiVideoKey !== 'function') return false;
      var prefix = window.fushiVideoKey() + '|';
      for (var k in store) {
        if (k.indexOf(prefix) === 0 && store[k] && store[k].length) return true;
      }
    } catch (_) { /* no-op */ }
    return false;
  }

  // 外挂轨的 lang 前缀由 subtitle-panel.js 定义，是轨身份的一部分（README「不翻译的东西」）。
  // 这里只做判据，不产生新身份。
  function hasExternalTrack() {
    try {
      var store = window.fushiEpisodeCues;
      if (!store || typeof window.fushiVideoKey !== 'function') return false;
      var prefix = window.fushiVideoKey() + '|';
      for (var k in store) {
        if (k.indexOf(prefix) !== 0 || !store[k] || !store[k].length) continue;
        var lang = k.slice(prefix.length);
        if (lang.indexOf('外挂:') === 0) return true;
      }
    } catch (_) { /* no-op */ }
    return false;
  }

  function writePrefs(obj) {
    Object.assign(st.prefs, obj);
    renderMain();
    paintButton();
    try { chrome.storage.local.set(obj); } catch (_) { /* no-op */ }
  }

  function flip(id) {
    if (id === 'overlay') {
      return writePrefs(overlayToggleWrite(st.prefs.subtitleOverlayEnabled !== false));
    }
    if (id === 'hidden') {
      // 隐藏字幕的状态与 style 注入归 content.js 独占（见那里的所有权注释），这里只转发。
      // 它自己写 subtitleHidden + toast，我们等 storage.onChanged 回读，不抢着写。
      if (typeof window.fushiToggleSubtitleHiding === 'function') window.fushiToggleSubtitleHiding();
      return;
    }
    if (id === 'replaceNative') return writePrefs({ subtitleReplaceNative: !st.prefs.subtitleReplaceNative });
    if (id === 'allTracks') return writePrefs({ subtitleOverlayAllTracks: !st.prefs.subtitleOverlayAllTracks });
    if (id === 'background') return writePrefs({ subtitleOverlayBackground: st.prefs.subtitleOverlayBackground === false });
  }

  function runShortcut(action) {
    if (typeof window.fushiSubtitleShortcut !== 'function') return;
    var ok = window.fushiSubtitleShortcut(action) === true;
    if (action === 'toggle-panel' && ok) closeMenu();
  }

  function openOptions() {
    try { chrome.runtime.sendMessage({ type: 'openOptions' }); } catch (_) { /* no-op */ }
    closeMenu();
  }

  // 滑杆拖动期间每一帧都写盘没有意义（覆盖层读的是同一份 storage，120ms 去抖足够跟手），
  // 与 options.js 同一条去抖纪律；离散控件（对齐/描边/跟随主题/恢复默认）立即落盘。
  function writeStyle(patch, immediate) {
    var mod = S();
    if (!mod) return;
    st.style = mod.normalize(Object.assign({}, mod.normalize(st.style), patch));
    if (styleWriteTimer) clearTimeout(styleWriteTimer);
    var commit = function () {
      styleWriteTimer = null;
      var write = stylePatchWrite(st.style, null, mod);
      try {
        if (write.remove) chrome.storage.local.remove(write.remove);
        else chrome.storage.local.set(defineKey(write.set, write.value));
      } catch (_) { /* no-op */ }
    };
    if (immediate) { commit(); renderStylePage(); } else styleWriteTimer = setTimeout(commit, 120);
  }

  function defineKey(key, value) {
    var o = {};
    o[key] = value;
    return o;
  }

  // ────────────────────────────── 装载与同步 ──────────────────────────────

  var PREF_KEYS = [
    SETTING_KEY, 'subtitleOverlayEnabled', 'subtitleReplaceNative', 'subtitleOverlayAllTracks',
    'subtitleOverlayBackground', 'subtitleHidden', 'subtitleStyle',
  ];

  function adoptStored(stored) {
    var s = stored || {};
    st.enabled = readBool(s, SETTING_KEY, true);
    st.prefs.subtitleOverlayEnabled = readBool(s, 'subtitleOverlayEnabled', true);
    st.prefs.subtitleReplaceNative = readBool(s, 'subtitleReplaceNative', false);
    st.prefs.subtitleOverlayAllTracks = readBool(s, 'subtitleOverlayAllTracks', false);
    st.prefs.subtitleOverlayBackground = readBool(s, 'subtitleOverlayBackground', true);
    st.prefs.subtitleHidden = readBool(s, 'subtitleHidden', false);
    if (Object.prototype.hasOwnProperty.call(s, 'subtitleStyle')) st.style = s.subtitleStyle || null;
  }

  try {
    chrome.storage.local.get(PREF_KEYS, function (r) {
      adoptStored(r || {});
      ensureButton();
      if (st.open) renderMain();
    });
  } catch (_) { /* no-op */ }

  try {
    chrome.storage.onChanged.addListener(function (changes, area) {
      if (area !== 'local' || !changes) return;
      var touched = false;
      for (var i = 0; i < PREF_KEYS.length; i++) {
        if (changes[PREF_KEYS[i]]) {
          var next = {};
          next[PREF_KEYS[i]] = changes[PREF_KEYS[i]].newValue;
          adoptStored(Object.assign({}, snapshot(), next));
          touched = true;
        }
      }
      if (!touched) return;
      ensureButton();
      if (st.open) {
        renderMain();
        if (st.page === 'style') renderStylePage();
      }
    });
  } catch (_) { /* no-op */ }

  function snapshot() {
    var s = {};
    s[SETTING_KEY] = st.enabled;
    s.subtitleOverlayEnabled = st.prefs.subtitleOverlayEnabled;
    s.subtitleReplaceNative = st.prefs.subtitleReplaceNative;
    s.subtitleOverlayAllTracks = st.prefs.subtitleOverlayAllTracks;
    s.subtitleOverlayBackground = st.prefs.subtitleOverlayBackground;
    s.subtitleHidden = st.prefs.subtitleHidden;
    s.subtitleStyle = st.style;
    return s;
  }

  // 点菜单外、按 Esc 都关菜单。Esc 在 capture 阶段吞掉这一次按键，站点自己的 Esc 处理
  // （退全屏/关面板）不再同时发生；菜单没开时一概放行，与 content.js 的弹窗同一分工。
  document.addEventListener('pointerdown', function (e) {
    if (!st.open) return;
    var t = e.target;
    if (menuEl && menuEl.contains(t)) return;
    if (btnEl && btnEl.contains(t)) return;
    closeMenu();
  }, true);

  document.addEventListener('keydown', function (e) {
    if (!st.open || e.key !== 'Escape') return;
    closeMenu();
    e.stopPropagation();
  }, true);

  document.addEventListener('fullscreenchange', function () {
    closeMenu();
    ensureButton();
  });

  window.addEventListener('resize', function () {
    placeFloatingButton();
    position();
  });

  // 通用悬浮按钮的显隐跟鼠标：在视频画面上才出现，与站点控件一个作息。
  document.addEventListener('pointerover', function (e) {
    if (!btnEl || !btnEl.classList.contains('is-floating')) return;
    var v = videoEl();
    var t = e.target;
    var inside = !!(v && t && (t === v || (btnEl.contains && btnEl.contains(t)) ||
      (v.parentNode && v.parentNode.contains && v.parentNode.contains(t))));
    if (inside === st.hoverVideo) return;
    st.hoverVideo = inside;
    placeFloatingButton();
  }, true);

  // 站点 SPA 导航 / 控件重建后补挂。轮询是这里最省心的形态：YouTube 的
  // yt-navigate-finish 只在 YouTube 有，Netflix 的控件行是 React 随时重建的，
  // 与其为每个站点各写一套观察器，不如一秒一次确认「按钮还在正确容器里吗」。
  setInterval(function () {
    ensureButton();
    if (st.open) position();
  }, 1000);

  if (window.fushiTheme && typeof window.fushiTheme.onChange === 'function') {
    try { window.fushiTheme.onChange(applyMenuTheme); } catch (_) { /* no-op */ }
  }
  if (window.fushiI18n && typeof window.fushiI18n.onChange === 'function') {
    try {
      window.fushiI18n.onChange(function () {
        paintButton();
        if (st.open) { renderMain(); if (st.page === 'style') renderStylePage(); }
      });
    } catch (_) { /* no-op */ }
  }

  return api;
});
