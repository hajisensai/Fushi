import 'package:fushi/src/reader/page_turn_animation.dart';

/// 小说阅读器**分页模式**的翻页动画 + 拖动跟手（JS 片段）。
///
/// 片段是 `window.fushiReader = { ... }` 对象字面量里的一串方法属性（每个以 `,`
/// 结尾），只插进分页 shell（[ReaderPaginationScripts.paginatedShellSource]）——
/// 连续滚动与视觉小说两个 shell 不含它，那两种模式的翻页路径逐字不变。
///
/// ## 快照翻页（View Transitions）
///
/// 翻页仍然是「把 scrollLeft / scrollTop 赋到相邻整页」，只是相邻翻页时这次赋值包进
/// `document.startViewTransition(update)`：浏览器先截旧页快照、再跑 update 换到新页、
/// 然后按 `::view-transition-old/new(root)` 的关键帧把两张快照动起来。竖排分栏
/// 沿 y 轴排列，相邻页在屏外的纵向位置，平滑滚动做不出「左右翻」——快照式动画与分栏
/// 轴无关，方向只看**阅读方向**（[pageTurnMoveDirection]）。
///
/// - 快照对象是**根（视口）**，规则只在动画期间生效（`html[data-fushi-pt]` 门控）。
///   不给滚动容器 `body` 单独命名：WebKit 对竖排 `scrollTop` 滚过的 body 截出的新页
///   快照是空白（Mac WKWebView 实测，Chromium 正常），根快照与滚动轴无关。控制栏在
///   Flutter 层，不在 WebView 里，不会被截进去。
/// - 位置**在动画开始时就落定**：update 回调里写死新位置并广播滚动，进度按新页算；
///   回调跑之前若有人读几何（[getScrollContext]），先同步落位并跳过这次动画
///   （[_flushPendingPageTurn]），读方绝不会看到旧位置。Dart 侧刷新进度的
///   `stableProgressInvocation` 在这短短一帧里返 null，等滚动事件补刷。
/// - 连按：上一个动画立刻 `skipTransition()`，下一次照常起。
/// - 不支持 `startViewTransition`（旧 WebView、iOS < 18）或墨水屏
///   （`--fushi-reader-eink-mode: 1`）时退化为原来的瞬时赋值。
/// - 只有相邻翻页走这里：恢复 / 跳转 / 重锚 / 搜索全部经 `setPagePosition`（瞬时，
///   且会先结束正在播的动画）。
///
/// ## 拖动跟手
///
/// 效果为平移 / 覆盖且开关打开时，触摸横向拖动进入跟手（[followDragUpdate]）：
/// - 横排从左往右读、左滑 = 前进：相邻页就在 x 轴上，直接滚正文（`scroll` 模式），
///   手指下就是真实的下一页；
/// - 其余（竖排 / 从右往左读 / 反转了滑动方向）：只让**当前页**随手指位移
///   （`shift` 模式，body `translateX`，露出底色）。
/// - 松手（[followDragEnd]）：位移超过视口宽 [kPageTurnFollowCommitFraction] 或速度超过
///   [kPageTurnFollowFlingVelocity] px/ms 即提交——返回滑动方向，调用方照常走 `onSwipe`
///   → Dart `_paginate`（跨章 / 节流 / 统计全部一致）；随后到达的 `paginate` 从当前
///   偏移接着播，剩余时长按比例缩短。否则回弹。章首 / 章末阻尼 0.3×、回弹后仍返回方向，
///   跨章照旧。
const String kReaderPageTurnJs =
    '''
  _pageTurn: null,
  _followDrag: null,
  _followDragRelease: null,
  _followDragReleaseTimer: null,
  _followRebound: null,
  _followSavedStyle: null,
  // 读当前配置的效果（Dart 已按墨水屏 / 系统减弱动态效果降级过；JS 再兜一道墨水屏）。
  // 时长只认 Dart 下发的 C.pageTurnDurationMs（FushiMotion token），JS 不另立兜底时长：
  // 没有有效时长 = 不播动画。
  pageTurnEffect: function() {
    var effect = (typeof C !== 'undefined' && C) ? C.pageTurnAnimation : null;
    if (effect !== 'slide' && effect !== 'cover' && effect !== 'fade') return 'none';
    if (this.isEinkMode()) return 'none';
    if (!(this.pageTurnDurationMs() > 0)) return 'none';
    return effect;
  },
  pageTurnDurationMs: function() {
    var ms = (typeof C !== 'undefined' && C) ? Number(C.pageTurnDurationMs) : NaN;
    return ms > 0 ? ms : 0;
  },
  isEinkMode: function() {
    try {
      return getComputedStyle(document.documentElement)
        .getPropertyValue('--fushi-reader-eink-mode').trim() === '1';
    } catch (e) {
      return false;
    }
  },
  pageTurnAnimationSupported: function() {
    return typeof document.startViewTransition === 'function';
  },
  // 是否「从右往左读」：竖排 vertical-rl 与 RTL 横排。前进时内容向右移、新页从左侧进入；
  // 横排从左往右读则相反。判据是阅读方向，不是分栏轴（竖排分栏沿 y 轴）。
  pageTurnRtlProgression: function() {
    try {
      var cs = getComputedStyle(document.body);
      var wm = String(cs.writingMode || '');
      if (wm.indexOf('vertical-rl') === 0 || wm.indexOf('sideways-rl') === 0) return true;
      if (wm.indexOf('vertical-lr') === 0 || wm.indexOf('sideways-lr') === 0) return false;
      return cs.direction === 'rtl';
    } catch (e) {
      return this.isVertical();
    }
  },
  // 翻页时内容整体移动的方向（'left' / 'right'）。
  pageTurnMoveDirection: function(forward) {
    var rtl = this.pageTurnRtlProgression();
    return (forward !== rtl) ? 'left' : 'right';
  },
  // 页面翻页动画是否占着几何（动画回调还没落位 / 拖动跟手中 / 松手待翻 / 回弹中）。
  // Dart 的进度采样在这期间返 null，等落定后的滚动事件补刷。
  pageTurnBusy: function() {
    var pt = this._pageTurn;
    return !!(pt && !pt.applied) || !!this._followDrag ||
      !!this._followDragRelease || !!this._followRebound;
  },
  // 待落定的目标位置（没有在途翻页时 undefined）。
  pendingPageTurnTarget: function() {
    var pt = this._pageTurn;
    return (pt && !pt.applied) ? pt.target : undefined;
  },
  // fn 在新页落位之后执行（没有在途翻页时立即执行）。光标重锚等「要读新页」的动作用。
  whenPageTurnApplied: function(fn) {
    var pt = this._pageTurn;
    if (pt && !pt.applied) {
      pt.queue.push(fn);
      return;
    }
    fn();
  },
  _applyPageTurn: function(pt) {
    if (!pt || pt.applied) return;
    pt.applied = true;
    this._resetFollowDragVisual();
    this._setPagePositionNow(pt.context, pt.target);
    // 动画开始即广播新位置：进度按新页算，打断也不丢进度。
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      try { window.flutter_inappwebview.callHandler('onReaderScroll'); } catch (e) {}
    }
    var queue = pt.queue;
    pt.queue = [];
    for (var i = 0; i < queue.length; i++) {
      try { queue[i](); } catch (e) {}
    }
  },
  _skipPageTurn: function(pt) {
    if (pt && pt.transition && typeof pt.transition.skipTransition === 'function') {
      try { pt.transition.skipTransition(); } catch (e) {}
    }
  },
  // 动画还没开始（旧页快照未截）就有人要读几何：先同步落位，这一次退化成瞬时。
  _flushPendingPageTurn: function() {
    var pt = this._pageTurn;
    if (!pt || pt.applied) return;
    this._applyPageTurn(pt);
    this._skipPageTurn(pt);
  },
  // 立刻结束当前翻页动画（落位 + skipTransition）。连按、触摸按下、任何瞬时定位都走它。
  finishPageTurnAnimation: function() {
    var pt = this._pageTurn;
    if (!pt) return;
    this._applyPageTurn(pt);
    this._skipPageTurn(pt);
  },
  _pageTurnViewportWidth: function() {
    var w = 0;
    try { w = document.body.getBoundingClientRect().width; } catch (e) {}
    return w > 0 ? w : (window.innerWidth || 0);
  },
  _pageTurnBackground: function() {
    function solid(c) {
      if (!c) return false;
      var t = String(c).split(' ').join('');
      return t !== 'transparent' && t.slice(-3) !== ',0)';
    }
    try {
      var b = getComputedStyle(document.body).backgroundColor;
      if (solid(b)) return b;
      var h = getComputedStyle(document.documentElement).backgroundColor;
      if (solid(h)) return h;
    } catch (e) {}
    return 'Canvas';
  },
  _ensurePageTurnStyle: function() {
    var id = 'fushi-page-turn-style';
    if (document.getElementById(id)) return;
    var pair = 'html[data-fushi-pt]::view-transition-old(root),' +
      'html[data-fushi-pt]::view-transition-new(root)';
    var css = [
      'html[data-fushi-pt]::view-transition-group(root){animation:none;}',
      pair + '{animation-duration:var(--fushi-pt-duration,0ms);' +
        'animation-timing-function:cubic-bezier(.2,.7,.2,1);animation-fill-mode:both;' +
        'mix-blend-mode:normal;background-color:var(--fushi-pt-bg,Canvas);}',
      'html[data-fushi-pt-old="move"]::view-transition-old(root){animation-name:fushi-pt-old-move;}',
      'html[data-fushi-pt-old="still"]::view-transition-old(root){animation:none;}',
      'html[data-fushi-pt-new="move"]::view-transition-new(root){animation-name:fushi-pt-new-move;}',
      'html[data-fushi-pt-new="fade"]::view-transition-new(root){animation-name:fushi-pt-fade-in;}',
      'html[data-fushi-pt-new="still"]::view-transition-new(root){animation:none;}',
      'html[data-fushi-pt-top="old"]::view-transition-old(root),' +
        'html[data-fushi-pt-top="new"]::view-transition-new(root)' +
        '{z-index:1;box-shadow:0 0 28px rgba(0,0,0,0.35);}',
      '@keyframes fushi-pt-old-move{from{transform:translateX(var(--fushi-pt-old-from,0px));}' +
        'to{transform:translateX(var(--fushi-pt-old-to,0px));}}',
      '@keyframes fushi-pt-new-move{from{transform:translateX(var(--fushi-pt-new-from,0px));}' +
        'to{transform:translateX(0px);}}',
      '@keyframes fushi-pt-fade-in{from{opacity:0;}to{opacity:1;}}'
    ].join('\\n');
    var style = document.createElement('style');
    style.id = id;
    style.textContent = css;
    (document.head || document.documentElement).appendChild(style);
  },
  // 纯计算：一次翻页动画里旧 / 新快照各自怎么动。sign = 内容移动方向（左 -1 / 右 +1），
  // W = 视口宽，captured = 已经滚进旧快照的位移（横排跟手），shifted = body 已平移的距离
  // （竖排跟手），fromDrag = 由拖动松手接力。
  pageTurnPlan: function(effect, sign, W, captured, shifted, forward, fromDrag) {
    if (effect === 'fade') {
      return { old: 'still', next: 'fade', top: '', oldFrom: 0, oldTo: 0, newFrom: 0 };
    }
    if (effect === 'slide' || (fromDrag && captured > 0)) {
      return {
        old: 'move', next: 'move', top: '',
        oldFrom: sign * shifted,
        oldTo: sign * (W - captured),
        newFrom: -sign * Math.max(0, W - captured - shifted)
      };
    }
    // 覆盖：前进时旧页带阴影移走、新页在下静止；后退时新页带阴影盖回、旧页在下。
    // 拖动接力一律是「旧页从当前偏移继续移出」。
    if (forward || fromDrag) {
      return {
        old: 'move', next: 'still', top: 'old',
        oldFrom: sign * shifted, oldTo: sign * W, newFrom: 0
      };
    }
    return { old: 'still', next: 'move', top: 'new', oldFrom: 0, oldTo: 0, newFrom: -sign * W };
  },
  _setPageTurnAttributes: function(effect, move, plan, durationMs) {
    var root = document.documentElement;
    root.setAttribute('data-fushi-pt', effect);
    root.setAttribute('data-fushi-pt-move', move);
    root.setAttribute('data-fushi-pt-old', plan.old);
    root.setAttribute('data-fushi-pt-new', plan.next);
    if (plan.top) {
      root.setAttribute('data-fushi-pt-top', plan.top);
    } else {
      root.removeAttribute('data-fushi-pt-top');
    }
    var style = root.style;
    style.setProperty('--fushi-pt-duration', Math.round(durationMs) + 'ms');
    style.setProperty('--fushi-pt-old-from', plan.oldFrom + 'px');
    style.setProperty('--fushi-pt-old-to', plan.oldTo + 'px');
    style.setProperty('--fushi-pt-new-from', plan.newFrom + 'px');
    style.setProperty('--fushi-pt-bg', this._pageTurnBackground());
  },
  _clearPageTurnAttributes: function() {
    var root = document.documentElement;
    var names = ['data-fushi-pt', 'data-fushi-pt-move', 'data-fushi-pt-old',
      'data-fushi-pt-new', 'data-fushi-pt-top'];
    for (var i = 0; i < names.length; i++) root.removeAttribute(names[i]);
    var props = ['--fushi-pt-duration', '--fushi-pt-old-from', '--fushi-pt-old-to',
      '--fushi-pt-new-from', '--fushi-pt-bg'];
    for (var j = 0; j < props.length; j++) root.style.removeProperty(props[j]);
  },
  // 相邻翻页的唯一动画入口。forward = 阅读方向上的前进；effect 缺省读配置。
  // 返回落点（与 setPagePosition 相同口径）。
  turnPageAnimated: function(context, target, forward, effect) {
    if (effect === undefined) effect = this.pageTurnEffect();
    var from = this.getPagePosition(context);
    var release = this._takeFollowDragRelease(forward);
    var distance = context.pageSize > 0
      ? Math.round(Math.abs(target - from) / context.pageSize) : 0;
    if (effect === 'none' || !this.pageTurnAnimationSupported() ||
        distance > $kPageTurnAnimationMaxAnimatedDistance) {
      this._resetFollowDragVisual();
      return this.setPagePosition(context, target);
    }
    // 连按：上一个动画立刻结束（它的落点早已写死），再起下一次。
    this.finishPageTurnAnimation();
    var W = this._pageTurnViewportWidth();
    var move = this.pageTurnMoveDirection(forward);
    var sign = move === 'left' ? -1 : 1;
    var duration = this.pageTurnDurationMs();
    var captured = 0;
    var shifted = 0;
    // 拖动方向与这次翻页的内容移动方向相反（反转了滑动方向）：从偏移接力会倒着跳，
    // 先复位再从头播。
    if (release && release.fd && release.fd.shiftPx && (release.fd.shiftPx < 0) !== (sign < 0)) {
      this._restoreFollowBase(release.fd);
      release = null;
    }
    if (release && W > 0) {
      captured = Math.min(W, release.captured || 0);
      shifted = Math.min(W, release.shifted || 0);
      var done = Math.min(1, (captured + shifted) / W);
      duration = Math.max(60, Math.round(duration * (1 - done)));
    }
    var plan = this.pageTurnPlan(effect, sign, W, captured, shifted, forward, !!release);
    this._ensurePageTurnStyle();
    this._setPageTurnAttributes(effect, move, plan, duration);
    var pt = { context: context, target: target, applied: false, transition: null, queue: [] };
    this._pageTurn = pt;
    var self = this;
    var transition = null;
    try {
      transition = document.startViewTransition(function() { self._applyPageTurn(pt); });
    } catch (e) {
      transition = null;
    }
    if (!transition) {
      this._pageTurn = null;
      this._clearPageTurnAttributes();
      this._applyPageTurn(pt);
      return Math.min(Math.max(0, target), context.physicalMaxScroll);
    }
    pt.transition = transition;
    var cleanup = function() {
      if (self._pageTurn !== pt) return;
      self._pageTurn = null;
      self._clearPageTurnAttributes();
    };
    if (transition.ready && transition.ready.catch) transition.ready.catch(function() {});
    if (transition.updateCallbackDone && transition.updateCallbackDone.catch) {
      transition.updateCallbackDone.catch(function() {});
    }
    if (transition.finished && transition.finished.then) {
      transition.finished.then(cleanup, cleanup);
    }
    return Math.min(Math.max(0, target), context.physicalMaxScroll);
  },
  // ── 拖动跟手 ──
  followDragEnabled: function() {
    if (!(typeof C !== 'undefined' && C && C.pageTurnFollowDrag === true)) return false;
    if (!this.pageTurnAnimationSupported()) return false;
    var effect = this.pageTurnEffect();
    return effect === 'slide' || effect === 'cover';
  },
  // 左滑是否前进（与 Dart onSwipe 的 swipeLeftIsForward 同一判据，由 Dart 下发）。
  _followLeftIsForward: function() {
    if (typeof C !== 'undefined' && C && typeof C.swipeLeftIsForward === 'boolean') {
      return C.swipeLeftIsForward;
    }
    return !this.pageTurnRtlProgression();
  },
  followDragActive: function() {
    return !!this._followDrag;
  },
  // dx = 手指自按下起的横向位移（CSS px）。首次调用建立跟手状态。返回是否在跟手。
  followDragUpdate: function(dx) {
    var fd = this._followDrag;
    if (!fd) {
      this.finishPageTurnAnimation();
      this._endFollowRebound();
      // 上一次松手还在等翻页（正文停在半页）：先复位，新的一拖从整页起算。
      var pendingRelease = this._followDragRelease;
      this._clearFollowDragRelease();
      if (pendingRelease) this._restoreFollowBase(pendingRelease.fd);
      var context = this.getScrollContext();
      if (context.pageSize <= 0) return false;
      var metrics = this.paginationMetrics || this.buildPaginationMetrics();
      var leftIsForward = this._followLeftIsForward();
      var rtl = this.pageTurnRtlProgression();
      fd = {
        context: context,
        base: this.getPagePosition(context),
        min: metrics.minScroll,
        max: metrics.maxScroll,
        width: this._pageTurnViewportWidth() || context.pageSize,
        leftIsForward: leftIsForward,
        mode: (!context.vertical && !rtl && leftIsForward) ? 'scroll' : 'shift',
        dx: 0, captured: 0, shifted: 0, shiftPx: 0, forward: true, atLimit: false
      };
      this._followDrag = fd;
    }
    var forward = (dx < 0) === fd.leftIsForward;
    var atLimit = forward ? fd.base >= fd.max - 1 : fd.base <= fd.min + 1;
    var W = fd.width;
    var captured = 0;
    var shiftPx = 0;
    if (atLimit) {
      shiftPx = Math.max(-W, Math.min(W, dx * 0.3));
      if (fd.mode === 'scroll') this.assignPagePosition(fd.context, fd.base);
    } else if (fd.mode === 'scroll') {
      captured = Math.min(Math.abs(dx), fd.context.pageSize);
      this.assignPagePosition(fd.context, fd.base + (dx < 0 ? captured : -captured));
    } else {
      shiftPx = Math.max(-W, Math.min(W, dx));
    }
    this._applyFollowShift(shiftPx);
    fd.dx = dx;
    fd.captured = captured;
    fd.shiftPx = shiftPx;
    fd.shifted = Math.abs(shiftPx);
    fd.forward = forward;
    fd.atLimit = atLimit;
    return true;
  },
  // 松手。velocity = 末段横向速度（px/ms，带符号）。返回要回传的滑动方向
  // （'left' / 'right'），null = 回弹不翻页。
  followDragEnd: function(dx, velocity) {
    var fd = this._followDrag;
    if (!fd) return null;
    this.followDragUpdate(dx);
    var W = fd.width || 1;
    var v = Number(velocity) || 0;
    var commit = dx !== 0 && (Math.abs(dx) > $kPageTurnFollowCommitFraction * W ||
      (Math.abs(v) > $kPageTurnFollowFlingVelocity && (v < 0) === (dx < 0)));
    var dir = dx < 0 ? 'left' : 'right';
    if (!commit || fd.atLimit) {
      // 章首 / 章末：回弹后照常回传方向，跨章逻辑不变。
      this._reboundFollowDrag();
      return commit ? dir : null;
    }
    this._followDrag = null;
    var self = this;
    var release = {
      fd: fd, forward: fd.forward, captured: fd.captured, shifted: fd.shifted
    };
    this._followDragRelease = release;
    // 回传的翻页若没有到达（换章在飞排队 / 被丢弃），别把正文卡在半页上。
    this._followDragReleaseTimer = setTimeout(function() {
      if (self._followDragRelease === release) self._reboundFollowDrag();
    }, 600);
    return dir;
  },
  followDragCancel: function() {
    if (this._followDrag) this._reboundFollowDrag();
  },
  _clearFollowDragRelease: function() {
    if (this._followDragReleaseTimer) {
      clearTimeout(this._followDragReleaseTimer);
      this._followDragReleaseTimer = null;
    }
    this._followDragRelease = null;
  },
  // 翻页接力：取走松手状态。方向对不上（反转了滑动方向等）就丢掉偏移、从头播。
  _takeFollowDragRelease: function(forward) {
    var release = this._followDragRelease;
    this._clearFollowDragRelease();
    if (!release) return null;
    if (release.forward !== forward) {
      this._restoreFollowBase(release.fd);
      return null;
    }
    return release;
  },
  _restoreFollowBase: function(fd) {
    if (fd && fd.mode === 'scroll') this.assignPagePosition(fd.context, fd.base);
    this._applyFollowShift(0);
  },
  _applyFollowShift: function(px) {
    var body = document.body;
    if (!body) return;
    if (!this._followSavedStyle) {
      if (!px) return;
      this._followSavedStyle = {
        transform: body.style.transform || '',
        boxShadow: body.style.boxShadow || ''
      };
    }
    if (px) {
      body.style.transform = 'translateX(' + px + 'px)';
      body.style.boxShadow = '0 0 28px rgba(0,0,0,0.35)';
    } else {
      body.style.transform = this._followSavedStyle.transform;
      body.style.boxShadow = this._followSavedStyle.boxShadow;
      this._followSavedStyle = null;
    }
  },
  // 清掉跟手留下的一切视觉（平移 / 阴影 / 回弹），不碰滚动位置（调用方马上要写新位置）。
  _resetFollowDragVisual: function() {
    this._followRebound = null;
    this._followDrag = null;
    this._clearFollowDragRelease();
    this._applyFollowShift(0);
  },
  _reboundFollowDrag: function() {
    var fd = this._followDrag || (this._followDragRelease && this._followDragRelease.fd);
    this._followDrag = null;
    this._clearFollowDragRelease();
    if (!fd) return;
    var self = this;
    var startScroll = fd.mode === 'scroll' ? this.getPagePosition(fd.context) : fd.base;
    var startShift = fd.shiftPx || 0;
    var distance = Math.max(Math.abs(startScroll - fd.base), Math.abs(startShift));
    var duration = Math.round(this.pageTurnDurationMs() * Math.min(1, distance / (fd.width || 1)));
    var token = { fd: fd };
    this._followRebound = token;
    if (duration < 16 || typeof requestAnimationFrame !== 'function') {
      this._endFollowRebound();
      return;
    }
    var clock = function() {
      return (window.performance && performance.now) ? performance.now() : Date.now();
    };
    var t0 = clock();
    var frame = function() {
      if (self._followRebound !== token) return;
      var p = Math.min(1, (clock() - t0) / duration);
      var eased = 1 - Math.pow(1 - p, 3);
      if (fd.mode === 'scroll') {
        self.assignPagePosition(fd.context, startScroll + (fd.base - startScroll) * eased);
      }
      self._applyFollowShift(startShift * (1 - eased));
      if (p < 1) {
        requestAnimationFrame(frame);
      } else {
        self._endFollowRebound();
      }
    };
    requestAnimationFrame(frame);
  },
  _endFollowRebound: function() {
    var token = this._followRebound;
    this._followRebound = null;
    if (!token) return;
    this._restoreFollowBase(token.fd);
  },
''';
