// 移动端字幕列表抽屉（content script 隔离世界，manifest bundle 里排在 touch-lookup.js 之后）。
// 安卓系浏览器没有 chrome.sidePanel——那是桌面独有 API，字幕列表（side-panel.html 整套 UI）
// 在手机上原本没有任何显示面。本脚本在「触屏设备 + 页面里有视频」时挂一条贴边拉条：
//   · 轻点拉条 → 抽屉滑入：横屏从右缘抽出、竖屏从底部升起；内容是一份 iframe，指向
//     side-panel.html?fushiEmbed=1&fushiTabId=N —— 选轨/点句跳转/时轴偏移/外挂字幕/Jimaku
//     搜字幕/制卡/面板查词全部原样复用，零复制逻辑；
//   · 按住拉条直接左右/上下拖 → 抽屉跟手；松手按露出比例吸附开/关，开态拖过当前尺寸
//     即顺手加宽/加高并存进 mobileSubtitleDrawerGeom（下次记住）——「可收可拉」；
//   · iframe 挂 chrome-extension:// 页必须走 web_accessible_resources（manifest 已加），
//     iframe 上下文里 tabs.query({currentWindow}) 不可靠，标签 id 由 background 的
//     drawerSelfTab 如实回报 sender.tab.id；
//   · 收起不销毁 iframe（列表滚动位置、在途请求都保命），postMessage 通知面板暂停 300ms
//     轮询，拉开即恢复；
//   · 进全屏跟着进：节点迁 fullscreenElement 子树（与字幕覆盖层/查词弹窗同一策略）。
// 开关 mobileSubtitleDrawer 默认开；桌面（pointer: fine）永远不出现这套节点，行为零变化。
(function () {
  'use strict';
  if (typeof window === 'undefined' || typeof document === 'undefined') return;

  var STRIP = 12;      // 收起时露出的贴边细条厚度（px）；样式见 content.css .fushi-drawer-strip
  var DRAG_AMP = 1.5;  // 拖拽放大：手指 1px 抽屉走 1.5px——细条浅 grab 轻拂即出（灵敏度要求）
  var MIN_OPEN = 260;  // 抽屉最小宽/高。与 side-panel.css 折叠头一行严丝合缝：七颗
                       // 静态小钮 7×30+6×3 缝，加 12 拉手槽与 20 header 内边距 = 260，
                       // 任何合法宽度都一行装下（收缩机制已撤，用户裁决：直接调小）。
  var MAX_RATIO = 0.6; // 抽屉尺寸上限：最多占 60% 视口（横屏算宽、竖屏算高），视频永远留 4 成
  var LAND_GAP = 24;   // 横屏对侧留白：不整屏盖死画面
  var PORT_MIN = 160;  // 竖屏收起后给视频至少留这么多 px

  var st = {
    enabled: true,
    geom: { landW: 0, portH: 0 },
    open: false,
  };
  var rootEl = null;
  var stripEl = null;
  var iframeEl = null;
  var frameTabId; // undefined=未知，null=问过拿不到（回落 queryActiveTab）

  function coarsePointer() {
    try { return !!(window.matchMedia && window.matchMedia('(pointer: coarse)').matches); } catch (_) { return false; }
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }
  function vw() { return window.innerWidth || 360; }
  function vh() { return window.innerHeight || 640; }
  function isLand() { return vw() >= vh(); }

  // 尺寸上限单一来源：60% 视口与「对侧留白/最少视频」双重夹逼，恒 ≥ MIN_OPEN。
  function maxFull(land) {
    var span = land ? vw() : vh();
    return Math.max(MIN_OPEN, Math.min(span * MAX_RATIO, span - (land ? LAND_GAP : PORT_MIN)));
  }
  function fullSize() {
    if (isLand()) {
      var w = st.geom.landW || Math.round(clamp(vw() * 0.42, 300, 430));
      return clamp(w, MIN_OPEN, maxFull(true));
    }
    var h = st.geom.portH || Math.round(vh() * 0.48);
    return clamp(h, MIN_OPEN, maxFull(false));
  }

  // ── 开抽屉时视频让位（用户要的原生侧边栏手感）──
  // 只在元素全屏态让位（手机主形态，见 drawerAllowed：横屏非全屏已整体禁用）：目标是
  // fullscreenElement，横屏压宽（右挂）、竖屏压高（底挂）；裸媒体全屏与非全屏竖屏页面态
  // 都不让位。宽度全走 JS 像素换算，站点重排由 adopt 跟随（见下）。
  // 一道（同步）：inline !important 压主轴尺寸——站点后到的样式表/内联 width 都压得住；
  //   连目标内部的 <video> 一起压（播放器常给 video 写死像素内联尺寸，只缩容器照样满屏）。
  // 二道（下一帧实测）：量真实矩形治「没跟着缩的全屏层」——video 盒被居中玩法留在原地时
  //   （absolute+translate、margin auto、100vw 中间层）硬钉左（position:fixed; left:0，顶边
  //   取实测值不跳位）并收宽进区域；进度条/播放键所在的**横贯全屏控件层**同样处理：横屏
  //   右缘探出就压宽，竖屏钉在屏幕底的整条上提到区域底缘（不然藏在抽屉底下）。小块控件
  //   不直接动——父层收进区域后自然跟。所有判定基于实测，跟了容器的层零扰动。
  // 宽度全走 JS 像素换算（innerWidth - 抽屉实占），不用 100vw/100vh CSS 常量——它们含
  //   滚动条/视觉视口误差，就是用户报「设置的宽度不够准确」的来源。
  // 所有改写前快照原内联值，关抽屉/换目标/卸除时精确还原，不伤站点自有样式。
  var squeezeRecs = []; // [{el, saved:{prop:{value,prio}}}] —— 每元素每属性只留第一份快照
  function squeezeClear() {
    squeezeRecs.forEach(function (rec) {
      for (var p in rec.saved) {
        var s = rec.saved[p];
        try {
          // 完整往返：值和 !important 优先级都按站点原样写回，hyphen 属性（object-fit）
          // 也只有 setProperty 认得。
          if (s.value) rec.el.style.setProperty(p, s.value, s.prio || '');
          else rec.el.style.removeProperty(p);
        } catch (_) {}
      }
    });
    squeezeRecs = [];
  }
  function squeezeApply(el, decls) {
    var rec = null;
    for (var i = 0; i < squeezeRecs.length; i++) if (squeezeRecs[i].el === el) { rec = squeezeRecs[i]; break; }
    if (!rec) { rec = { el: el, saved: {}, written: {} }; squeezeRecs.push(rec); }
    for (var s = 0; s < decls.length; s++) {
      var p = decls[s][0];
      if (!(p in rec.saved)) {
        var v = '', pr = '';
        try {
          v = el.style.getPropertyValue ? el.style.getPropertyValue(p) : (el.style[p] || '');
          pr = el.style.getPropertyPriority ? el.style.getPropertyPriority(p) : '';
        } catch (_) { v = ''; }
        rec.saved[p] = { value: v, prio: pr };
      }
    }
    for (var k = 0; k < decls.length; k++) {
      try {
        el.style.setProperty(decls[k][0], decls[k][1], 'important');
        rec.written[decls[k][0]] = decls[k][1]; // 我们写进去的哨兵值，adopt 拿它比对
      } catch (_) {}
    }
  }
  // ── 跟随式快照（adopt）──
  // 快照不能是死照片：播放器对同一内联槽位的改写会先后于/后于我们的还原发生
  // （fullscreenchange 里它同步重排 vs 下一帧才重排），赌时机就是用户报的「切换全屏
  // 有时候错位」。改成比对「我们写的值」和「属性现在的值」：不相等说明播放器改写过了,
  // 把它现值（连同优先级）吸成新的还原基准。开态下低频轮询 + 全屏切换事件与重排帧
  // 两头即时执行，怎么排都接得住。
  function adoptExternalWrites() {
    var dirty = false;
    squeezeRecs.forEach(function (rec) {
      for (var p in rec.written) {
        var cur = null;
        try { cur = rec.el.style.getPropertyValue(p); } catch (_) { continue; }
        if (cur === rec.written[p]) continue;
        var prio = '';
        try { prio = rec.el.style.getPropertyPriority(p); } catch (_) {}
        rec.saved[p] = { value: cur || '', prio: prio };
        dirty = true;
      }
    });
    return dirty;
  }
  function isMediaEl(el) {
    return !!(el && /^(VIDEO|AUDIO|IMG|CANVAS)$/.test(el.tagName || ''));
  }
  // 用户终局裁决：**横屏只在全屏时开字幕列表**。页面态横屏的播放器让位形态太杂（整页
  // 容器/fixed 控件/播放器自重排互相踩），修不稳，干脆整体砍掉——非全屏横屏不挂载抽屉。
  // 竖屏两种态都开（底挂浮层，不让位）。全屏不看元素类型：Android 站常常 requestFullscreen
  // 打在 <video> 本身（原生视频全屏），排除媒体会把这条主路整个禁掉（用户报「全屏不能
  // 拖拉」）——媒体全屏时抽屉挂 body，压 video 本体就是那里唯一有效的让位。
  function drawerAllowed() {
    return !isLand() || !!document.fullscreenElement;
  }
  var gapRaf = 0;
  var adoptTimer = 0; // 开态低频 adopt 轮询（见 adoptExternalWrites）
  var gapWant = null; // {land, occupy}：拖拽中间态只留最后一份
  function scheduleGapFix(land, occupy) {
    gapWant = { land: land, occupy: occupy };
    if (gapRaf || typeof requestAnimationFrame !== 'function') return;
    gapRaf = requestAnimationFrame(function () {
      gapRaf = 0;
      runGapFix(gapWant);
    });
  }
  function runGapFix(want) {
    if (!st.open || !want) return;
    var fs = document.fullscreenElement;
    // 让位只存在于全屏态（横屏页面态已被 drawerAllowed 禁掉）；裸媒体全屏钉不得。
    var root = fs;
    if (!root || isMediaEl(root) || !root.querySelectorAll) return;
    var land = want.land;
    var regionSpan = Math.max(0, Math.round((land ? vw() : vh()) - want.occupy));
    var regionRight = Math.round(vw() - want.occupy);
    var list = [];
    try {
      // video 本体 + 常见控件层名（chrome=YouTube 控件条、control/progress/seek/slider 泛用）。
      // 小控件（按钮/进度条本体）不直接动：它们所在的容器层被收进区域后自己会跟。
      list = Array.prototype.slice.call(root.querySelectorAll(
        'video, [class*="ontrol"], [class*="hrome"], [class*="rogress"], [class*="eek"], [role="slider"]'));
    } catch (_) { return; }
    list.forEach(function (el) {
      var r = null;
      try { r = el.getBoundingClientRect(); } catch (_) {}
      if (!r || !r.width) return;
      var video = el.tagName === 'VIDEO';
      // 非 video 只处理「横贯整屏」的层（左右缘基本贴屏）——其余小块留给父层带动。
      if (!video && r.width < vw() - 8) return;
      var decls = [];
      if (land) {
        if (video && fs && r.left > 1) {
          // 钉左（仅全屏）：顶边取实测值保持原视觉高度。页面态绝不 fixed——
          // fixed 跟着视口不跟页面，一滚动字幕/进度条全体漂移脱节。
          decls.push(['position', 'fixed'], ['left', '0px'], ['top', Math.round(r.top) + 'px']);
        }
        var baseLeft = (video && fs && r.left > 1) ? 0 : Math.round(r.left);
        if (r.right > regionRight + 1) {
          decls.push(['width', Math.max(0, regionRight - baseLeft) + 'px']);
        }
      } else {
        if (video) {
          if (r.bottom > regionSpan + 1) decls.push(['height', Math.max(0, regionSpan - Math.round(r.top)) + 'px']);
        } else if (r.bottom > regionSpan + 1) {
          // 控件条钉在屏幕底部（fixed bottom:0，容器收缩不吃它）→ 整层上提到区域底缘，
          // 不然它藏在抽屉底下摸不到。实测判定，绝对定位跟了容器的（r.bottom 已在区域内）不动。
          decls.push(['bottom', Math.round(r.bottom - regionSpan) + 'px']);
        }
      }
      if (decls.length) squeezeApply(el, decls);
    });
  }
  function updateSqueeze(land, occupy) {
    squeezeClear();
    if (!st.open) return;
    // 让位只在全屏态发生（横屏非全屏已被 drawerAllowed 禁掉）。全屏层不设媒体例外：
    // fs 就是 <video> 时压它本体正是原生视频全屏唯一有效的让位；非全屏竖屏不让位。
    var target = document.fullscreenElement || null;
    if (!target) { return; }
    var region = Math.max(0, Math.round((land ? vw() : vh()) - occupy));
    var value = region + 'px';
    var prop = land ? 'width' : 'height';
    var els = [];
    try { els = Array.prototype.slice.call(target.querySelectorAll('video')); } catch (_) {}
    if (els.indexOf(target) < 0) els.push(target);
    els.forEach(function (el) {
      var decls = [[prop, value], [land ? 'min-width' : 'min-height', '0px']];
      // 压盒必须同时保比例：object-fit 的初始值是 **fill**，大量站点靠 100% 拉伸 video——
      // 只压宽不锁 contain，拖宽窄时画面整个被捏扁（用户报的「拖拉让视频比例变化」）。
      // contain 只改信箱边位置，像素永不拉伸；还原时连站点原来的 object-fit（含 !important）照抄回去。
      if (el.tagName === 'VIDEO') decls.push(['object-fit', 'contain']);
      squeezeApply(el, decls);
    });
    scheduleGapFix(land, occupy);
  }

  // 几何只走两条属性：横屏定 width + translateX，竖屏定 height + translateY。
  function setMetrics(land, full, expose) {
    if (!rootEl) return;
    rootEl.classList.toggle('is-land', land);
    rootEl.classList.toggle('is-port', !land);
    rootEl.classList.toggle('is-open', expose > STRIP + 1);
    if (land) {
      rootEl.style.width = Math.round(full) + 'px';
      rootEl.style.height = '';
      rootEl.style.transform = 'translateX(' + Math.round(full - expose) + 'px)';
    } else {
      rootEl.style.height = Math.round(full) + 'px';
      rootEl.style.width = '';
      rootEl.style.transform = 'translateY(' + Math.round(full - expose) + 'px)';
    }
    updateSqueeze(land, Math.min(full, expose));
  }

  function layout() {
    var full = fullSize();
    setMetrics(isLand(), full, st.open ? full : STRIP);
  }

  function postToFrame(type) {
    try {
      if (iframeEl && iframeEl.contentWindow) {
        // S5691：targetOrigin 传扩展页自己的 URL（浏览器按其中的 chrome-extension
        // origin 投递），绝不用 '*'——只有本抽屉的 iframe 收得到这条消息。
        iframeEl.contentWindow.postMessage(
          { source: 'fushi-drawer', type: type },
          chrome.runtime.getURL('side-panel.html'));
      }
    } catch (_) {}
  }

  function ensureIframe() {
    if (iframeEl || !rootEl) return;
    iframeEl = document.createElement('iframe');
    iframeEl.id = 'fushi-drawer-frame';
    iframeEl.setAttribute('aria-label', '字幕列表');
    var start = function (tid) {
      var url = chrome.runtime.getURL('side-panel.html') + '?fushiEmbed=1';
      if (tid != null) url += '&fushiTabId=' + tid;
      // 与 postToFrame 的接收端配对（S5691）：面板只认这个 origin 发来的宿主消息。
      // content script 里 location.origin 就是宿主页 origin，也正是 postMessage 的投递源。
      url += '&fushiHostOrigin=' + encodeURIComponent(location.origin);
      iframeEl.src = url;
    };
    if (frameTabId !== undefined) start(frameTabId);
    else {
      try {
        chrome.runtime.sendMessage({ type: 'drawerSelfTab' }, function (resp) {
          var tid = null;
          try { if (!chrome.runtime.lastError && resp && Number.isInteger(resp.tabId)) tid = resp.tabId; } catch (_) {}
          frameTabId = tid;
          start(tid);
        });
      } catch (_) { frameTabId = null; start(null); }
    }
    rootEl.appendChild(iframeEl);
  }

  function setOpen(on) {
    if (!rootEl) return;
    st.open = !!on;
    if (st.open) ensureIframe();
    layout();
    postToFrame(st.open ? 'resume' : 'pause');
  }

  // 供 subtitle-panel.js 的 Shift+S 契约：触屏上没有原生侧边栏，键位改拉本页抽屉。
  window.fushiMobileDrawerOpen = function () {
    if (!rootEl) return false;
    if (!st.open) setOpen(true);
    return true;
  };

  // ── 拉条手势：轻点开关；拖拽自由停位（松手处即宽度，实时调宽）──
  // 开态拖拽有 MIN_OPEN 实时地板：压不成细条（用户要求「不能拉到无限短」），收起走轻点。
  var drag = null;
  function stripDown(e) {
    var land = isLand();
    var full = fullSize();
    drag = {
      id: e.pointerId,
      land: land,
      x0: e.clientX,
      y0: e.clientY,
      full: full,
      expose: st.open ? full : STRIP,
      curFull: full,
      curExpose: st.open ? full : STRIP,
      openStart: st.open,
      moved: false,
    };
    rootEl.classList.add('is-dragging'); // 拖拽期关 transition，跟手
    beginWindowDrag();
    // 手势监听走 window 而不靠 setPointerCapture：手指右滑压窄时会离开 34px 拉条滑到
    // iframe 上（尤其顶到 MIN_OPEN 地板后拉条停住、手指继续走）——触摸手势整个生命周期
    // 都派发到 parent 文档，window 监听全程收得到；而老内核（Kiwi/Edge Android）上
    // setPointerCapture 静默失败过一次，move/up 断在 iframe 里，用户端表现就是
    // 「往左能停、往右松手弹回」。capture 仍尝试一下，多一层保险。
    try { stripEl.setPointerCapture(e.pointerId); } catch (_) {}
    e.preventDefault();
  }
  function beginWindowDrag() {
    window.addEventListener('pointermove', stripMove);
    window.addEventListener('pointerup', stripUp);
    window.addEventListener('pointercancel', stripCancel);
  }
  function endWindowDrag() {
    window.removeEventListener('pointermove', stripMove);
    window.removeEventListener('pointerup', stripUp);
    window.removeEventListener('pointercancel', stripCancel);
  }
  function stripMove(e) {
    if (!drag || e.pointerId !== drag.id) return;
    var d = (drag.land ? (drag.x0 - e.clientX) : (drag.y0 - e.clientY)) * DRAG_AMP; // 向左/向上为正 = 拉出
    var start = drag.expose;
    var maxExpose = maxFull(drag.land); // 拖也拖不过上限：视频永远保有四成可视
    // 开态地板 MIN_OPEN（永远拖不成残条）；收起态起步是 STRIP，允许小幅误拖弹回。
    var floor = drag.openStart ? MIN_OPEN : STRIP;
    var expose = clamp(start + d, floor, maxExpose);
    if (Math.abs(expose - start) > 4) drag.moved = true; // 已含放大：手指 ~3px 即判拖，轻拂就走
    drag.curFull = Math.max(drag.full, expose); // 拉过头顺手扩尺寸
    drag.curExpose = expose;
    setMetrics(drag.land, drag.curFull, expose);
  }
  function stripUp(e) {
    if (!drag || e.pointerId !== drag.id) return;
    var g = drag;
    drag = null;
    endWindowDrag();
    if (rootEl) rootEl.classList.remove('is-dragging');
    if (!g.moved) { setOpen(!st.open); return; } // 轻点：toggle（开=回到记住的宽度）
    // 自由停位：松手即停在拖到处——那个位置就是抽屉宽度（实时调宽）。
    // 收起态拉出但没到 MIN_OPEN 就松手 → 视为误拖，弹回边条；开态有地板，压不到这条线。
    var w = Math.round(g.curExpose);
    if (w < MIN_OPEN) {
      st.open = false;
      setMetrics(g.land, g.full, STRIP);
      postToFrame('pause');
      return;
    }
    var cap = maxFull(g.land);
    var finalFull = clamp(w, MIN_OPEN, cap);
    if (g.land) st.geom.landW = finalFull; else st.geom.portH = finalFull;
    saveGeom();
    st.open = true;
    ensureIframe();
    setMetrics(g.land, finalFull, finalFull);
    postToFrame('resume');
  }
  function stripCancel(e) {
    if (!drag || e.pointerId !== drag.id) return;
    endWindowDrag();
    if (drag.moved) { stripUp(e); return; } // 已被系统手势打断但拖出位移了：按松手结算，别弹跳
    drag = null;
    if (rootEl) rootEl.classList.remove('is-dragging');
    layout(); // 没位移：弹回原位
  }

  function saveGeom() {
    try { chrome.storage.local.set({ mobileSubtitleDrawerGeom: { landW: st.geom.landW, portH: st.geom.portH } }); } catch (_) {}
  }

  function attachToHost() {
    if (!rootEl) return;
    // fullscreenElement 是 <video>/<audio>（浏览器原生视频全屏）时不能挂进去：媒体元素
    // 的子节点属 fallback content，播放中根本不渲染——抽屉会凭空消失。这种模式交给 body。
    var fs = document.fullscreenElement;
    var hostFs = fs && !isMediaEl(fs); // 媒体全屏挂不进 host 但也是全屏——is-fs 按 fs 判
    var parent = hostFs ? fs : document.body;
    if (parent && rootEl.parentNode !== parent) parent.appendChild(rootEl);
    // 全屏态标记：开合按钮在 CSS 里从边缘中点挪去右上角（用户指定）。
    rootEl.classList.toggle('is-fs', !!fs);
  }

  function onFullscreenChange() {
    // 全屏↔横屏页面态切换即 drawerAllowed 翻转点：先让 syncUi 决定挂载/卸除/host 迁移。
    // 卸除路径自带 squeezeClear，横屏页面绝不留让位残骸；挂载则继续走下面的重基。
    syncUi();
    if (!rootEl) return; // 已按新规则卸除
    // 进出全屏播放器都要重排自己的内联尺寸，和让位快照正面撞车：同步还原写回的是
    // **全屏时代**的快照值（比如 height:1080px），播放器重排稍慢一步就被盖住，退出全屏
    // 后视频带着巨大尺寸留在页面里——字幕浮量的是这个坏盒，用户看到的「退出全屏字幕
    // 错位」就是这么来的。改成：立即撤销全部让位改写（交还布局权）→ 下一帧播放器写稳
    // 新值后，以它为快照重新起基再压。一帧的让位空缺没人看得见，永久错位看得见。
    adoptExternalWrites(); // 事件时刻播放器多半已同步重排：先把真值吸进快照
    if (typeof requestAnimationFrame === 'function') {
      requestAnimationFrame(function () {
        if (!rootEl) return;
        adoptExternalWrites(); // 晚到的重排在这一帧写稳：再吸一遍，然后以真值重新起基重压
        layout();
      });
    } else {
      layout(); // 老 WebView 没有 rAF：同步重压（快照已吸过一轮真值）
    }
  }
  function onResize() {
    if (drag) return;
    // 旋转/进分屏即 drawerAllowed 与朝向的翻转点：先 syncUi 定夺挂载/卸除，卸除即已还原。
    syncUi();
    if (!rootEl) return;
    // 旋转 = resize 连发 + 播放器同步重排写新尺寸：老写法每拍 layout() 里的
    // squeezeClear 会把**旋转前**的快照盖回去——播放器改对了又被我们压回旧值，
    // 用户看到的就是「横竖屏调转字幕错位」（和退出全屏那次同病）。改法与
    // fullscreenchange 一致：事件先 adopt 吸真值，rAF 再吸一遍才重新起基重压；
    // 连发的每一拍都走这套，最后一拍落在稳定尺寸上，中间拍无盖写伤害。
    adoptExternalWrites();
    if (typeof requestAnimationFrame === 'function') {
      requestAnimationFrame(function () {
        if (!rootEl) return;
        adoptExternalWrites();
        layout();
      });
    } else {
      layout();
    }
  }

  function mount() {
    if (rootEl) return;
    rootEl = document.createElement('div');
    rootEl.id = 'fushi-drawer';
    stripEl = document.createElement('div');
    stripEl.className = 'fushi-drawer-strip'; // 隐形边缘手势区：任何贴边按下即进入拖拽/开合判定
    stripEl.setAttribute('aria-label', '字幕列表边缘手势区');
    var btn = document.createElement('div');
    btn.className = 'fushi-drawer-btn';
    btn.setAttribute('role', 'button');
    btn.setAttribute('aria-label', '展开或收起字幕列表');
    btn.textContent = '☰'; // 可见开合钮；pointerdown 冒泡进 stripEl，点=开关、按住同样能拖
    stripEl.appendChild(btn);
    rootEl.appendChild(stripEl);
    stripEl.addEventListener('pointerdown', stripDown);
    stripEl.addEventListener('contextmenu', function (e) { e.preventDefault(); }); // move/up/cancel 挂 window，见 stripDown 注释
    document.addEventListener('fullscreenchange', onFullscreenChange);
    window.addEventListener('resize', onResize);
    adoptTimer = setInterval(function () {
      // 播放器任何时候改写内联尺寸都被吸成还原基准，随后重压回让位尺寸。拖拽中不抢手。
      if (rootEl && !drag && st.open && squeezeRecs.length && adoptExternalWrites()) layout();
    }, 150);
    attachToHost();
    layout();
    if (st.open) { ensureIframe(); } // 页面重建（SPA）后恢复开态
  }

  function unmount() {
    if (!rootEl) return;
    endWindowDrag(); // 拖到一半被停用也不能留监听
    if (adoptTimer) { clearInterval(adoptTimer); adoptTimer = 0; }
    document.removeEventListener('fullscreenchange', onFullscreenChange);
    window.removeEventListener('resize', onResize);
    squeezeClear(); // 让位类挂在页面元素上，抽屉本体卸了绝不能把 calc 宽度留给站点
    try { if (rootEl.parentNode) rootEl.parentNode.removeChild(rootEl); } catch (_) {}
    rootEl = null;
    stripEl = null;
    iframeEl = null;
  }

  function syncUi() {
    var want = st.enabled === true && coarsePointer() && !!document.querySelector('video') && drawerAllowed();
    if (want && !rootEl) mount();
    else if (!want && rootEl) unmount();
    else if (want) attachToHost();
  }

  function applySettings(saved) {
    saved = saved || {};
    if (typeof saved.mobileSubtitleDrawer === 'boolean') st.enabled = saved.mobileSubtitleDrawer;
    var g = saved.mobileSubtitleDrawerGeom;
    if (g && typeof g === 'object') {
      if (typeof g.landW === 'number' && isFinite(g.landW)) st.geom.landW = g.landW;
      if (typeof g.portH === 'number' && isFinite(g.portH)) st.geom.portH = g.portH;
    }
    if (!st.enabled && rootEl) { unmount(); return; }
    if (rootEl) layout();
  }
  try {
    chrome.storage.local.get(['mobileSubtitleDrawer', 'mobileSubtitleDrawerGeom'], applySettings);
  } catch (_) {}
  try {
    chrome.storage.onChanged.addListener(function (changes, area) {
      if (area !== 'local' || !changes) return;
      var patch = {};
      var changed = false;
      if (changes.mobileSubtitleDrawer) { patch.mobileSubtitleDrawer = changes.mobileSubtitleDrawer.newValue; changed = true; }
      if (changes.mobileSubtitleDrawerGeom) { patch.mobileSubtitleDrawerGeom = changes.mobileSubtitleDrawerGeom.newValue; changed = true; }
      if (changed) applySettings(patch);
    });
  } catch (_) {}

  setInterval(syncUi, 900);
  syncUi();
})();
