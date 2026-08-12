// KiriKiri 游戏内查词 — Dart 编排层（仅 Windows）。
//
// 见 docs/specs/2026-08-10-kirikiri-ingame-lookup-plan.md。三段职责里 Dart 只占中间
// 一小段，而且**位图永远不经过这里**：
//
//   注入进游戏的 hook（几何传感 / 命中测试 / 输入转发）
//        │ onGalLookupHit(整行台词, 字符下标, 字形矩形, 视口尺寸)
//        ▼
//   本控制器 ── 走 app 既有查词链（GlobalLookupController.lookupText →
//        │       AppModel.searchDictionary → 离屏 WebView2 popup.html）
//        │ galLookupPresent(seq, anchor, highlight)
//        ▼
//   runner（取帧）→ 共享内存 → hook memcpy 进游戏 Layer
//
// 本文件里**一行查词逻辑都没有**：不分词、不筛词典、不定 maximumTerms、不排版。
// 词条从哪来、去屈折怎么做、卡片长什么样，全部与阅读器 / 视频 / 剪贴板查词同一份
// 实现；这里只回答三个问题——查哪个串、卡片放哪、高亮哪一段。
//
// 坐标域纪律：hook 报上来的 glyph/view 尺寸在**游戏 primaryLayer 像素**域，卡片位图
// 是逐像素 memcpy 进 Layer 的，所以「卡片在游戏里的尺寸」== 位图的**物理像素**尺寸
// （GlobalLookupController.onRoutedRevealed 回报的就是它）。两者同域可直接比较，全程不乘
// dpr——dpr 只属于 Windows 窗口那一侧。

import 'dart:async';
import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi/src/lookup/global_lookup_channel.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/lookup/global_lookup_layout.dart';
import 'package:fushi/src/lookup/global_lookup_log.dart';
import 'package:fushi/src/lookup/overlay_bridge_handlers.dart';
import 'package:fushi/src/lookup/sentence_extraction.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';

/// 偏好读取口。与 `GalHookPreferenceReader` 同形——独立声明只为不让台词浮窗控制器与
/// 本控制器互相 import 成环，语义完全一致（key + 默认值，测试可注入替身）。
typedef GalIngameLookupPreferenceReader = Object? Function(
  String key, {
  required Object? defaultValue,
});

/// 按台词文本回溯本局会话里的行，给出该行的 gal 制卡 handler（截图 + 语音 + 标签）。
///
/// 制卡链本身在 [GalHookTextOverlayController] 里（`_mineFromLookup`）——它持有
/// mining coordinator、Anki repo 与全部制卡偏好。这里只要一个「这句话对应哪一行」
/// 的解析口，绝不复制那条链。找不到对应行返回 null（卡照样能建，只是没有 gal 媒体）。
typedef GalIngameMiningResolver = OverlayMiningHandler? Function(String line);

/// 游戏内查词编排器（进程级单例）。
class GalIngameLookupController {
  GalIngameLookupController._({
    GalIngameLookupPreferenceReader? preferenceReader,
  }) : _preferenceReader = preferenceReader;

  static final GalIngameLookupController instance =
      GalIngameLookupController._();

  @visibleForTesting
  GalIngameLookupController.test({
    GalIngameLookupPreferenceReader? preferenceReader,
  }) : this._(preferenceReader: preferenceReader);

  /// 「游戏内查词」开关的持久化 key（与其余 gal hook 偏好同一命名族）。
  static const String enabledPreferenceKey = 'gal_hook_ingame_lookup_enabled';

  GalIngameLookupPreferenceReader? _preferenceReader;

  AppModel? _appModel;
  GalIngameMiningResolver? _miningResolver;
  bool _started = false;

  /// galgame 会话是否在跑（由台词浮窗控制器的会话同步喂进来，不另起第二个监听）。
  bool _sessionActive = false;

  /// 最近一次被 runner **确认成功**的开关值，仅供诊断使用。
  /// 它不是跨 shared mapping 的真值：mapping 换代后
  /// runner 中的实际状态可能已丢失，所以 [_syncEnabled] 绝不用它跳过 native 调用。
  bool _pushedEnabled = false;

  /// enable/disable 串行 drain。channel 调用在 await 期间可能又收到会话或
  /// 偏好变更；新意图只置 pending，不再并发第二个 native 调用。当前回执
  /// 返回后重读 [_enabledNow]，直到 native 最后收到的值与最新意图一致。
  bool _enableSyncPending = false;
  Completer<void>? _enableSyncCompleter;

  /// 当前屏上这张卡对应的命中。null = 游戏里没有卡（此时 onRoutedRevealed
  /// 的回调属于普通桌面查词，不该投进游戏）。
  GalLookupHit? _activeHit;

  /// [_activeHit] 所属查词代数。新 submit 一到就使旧 reveal 回调过期，
  /// 防止慢卡在较新点击后闪回。
  int _activeLookupGeneration = 0;

  /// 一个 galgame 会话一个 route epoch；同一会话内每次 submit 再分配唯一 lookup
  /// epoch。两者共同构成不可复用的 [GlobalLookupRoute]，使旧 Future / Timer / JS
  /// bridge 即便迟到也只能落回自己的离屏卡片代数，不能串到下一次点击或桌面浮窗。
  int _sessionRouteEpoch = 0;
  int _lookupRouteEpoch = 0;
  GlobalLookupRoute? _activeRoute;

  /// 最近一次真正提交查词的命中。hover 也有自己的 seq，但它只在 TJS 内即时移动高亮，
  /// 不能作废正在查词的 submit，也不能拿来给卡片 present / dismiss 做身份。
  GalLookupHit? _latestSubmitHit;

  /// latest-wins 待处理命中：查词在途时又点了新字，只留最后一个（连点不排队）。
  ({
    GalLookupHit hit,
    int generation,
    GlobalLookupRoute route,
  })? _pendingLookup;
  bool _draining = false;
  Completer<void>? _drainCompleter;

  /// 每次查词意图/消场都递增。异步词典结果与 channel 回执只有代数仍相等才可落屏，
  /// 因此慢查询永远不能在较新的点击之后闪回旧卡。
  int _lookupGeneration = 0;

  /// enable/disable 路由收尾代数。串行 drain 每次决定一个 native 意图
  /// 就递增；迟到的 disable routing 收尾只能在代数仍匹配时生效。
  int _enableSyncGeneration = 0;

  /// 平台门：galgame hook 只做 Windows，且必须有覆盖窗（卡片像素的唯一来源）。
  static bool get isSupported =>
      GalHookTextOverlayChannel.supportsCurrentPlatform &&
      GlobalLookupController.isSupported;

  @visibleForTesting
  bool get debugSessionActive => _sessionActive;

  @visibleForTesting
  bool get debugPushedEnabled => _pushedEnabled;

  @visibleForTesting
  GalLookupHit? get debugActiveHit => _activeHit;

  /// 接线。幂等；非 Windows 上直接空转（不是崩）。
  ///
  /// [miningResolver] 由台词浮窗控制器提供，见 [GalIngameMiningResolver]。
  /// [preferenceReader] 同样由它透传（测试替身；生产为 null 时读 [AppModel]）。
  ///
  /// 重复调用只刷新依赖、不重复挂回调链——覆盖窗的两个回调是单消费者字段，挂两遍
  /// 会让同一次 reveal 投两帧。
  Future<void> start({
    required AppModel appModel,
    GalIngameMiningResolver? miningResolver,
    GalIngameLookupPreferenceReader? preferenceReader,
  }) async {
    if (!isSupported) return;
    _appModel = appModel;
    _miningResolver = miningResolver;
    _preferenceReader = preferenceReader ?? _preferenceReader;
    if (_started) return;
    _started = true;
    final GlobalLookupController overlay = GlobalLookupController.instance;
    overlay.onRoutedRevealed = (GlobalLookupRoute route, int w, int h) {
      if (!_acceptsRoute(route)) return;
      _onOverlayRevealed(route, w, h);
    };
    overlay.onRoutedHidden = (GlobalLookupRoute route) {
      if (!_acceptsRoute(route)) return;
      unawaited(_onOverlayHidden(route));
    };
  }

  @visibleForTesting
  Future<void> stopForTesting() async {
    _sessionActive = false;
    await _terminateCurrentLookup();
    final Future<void>? lookupDrain = _drainCompleter?.future;
    if (lookupDrain != null) await lookupDrain;
    _started = false;
    // 若此刻正有 enable 在 channel 里，不能直接作废 drain：它可能
    // 在 stop 后才成功把 native 打开。留一个 pending，让同一串行 drain
    // 再下发 false 后才完成清理。
    _enableSyncPending = _enableSyncCompleter != null;
    final Future<void>? enabling = _enableSyncCompleter?.future;
    if (enabling != null) await enabling;
    _enableSyncPending = false;
    _enableSyncGeneration++;
    _pushedEnabled = false;
    _activeHit = null;
    _latestSubmitHit = null;
    _pendingLookup = null;
    _draining = false;
    _drainCompleter = null;
    _lookupGeneration++;
    _activeLookupGeneration = 0;
  }

  /// galgame 会话开始 / 结束。会话不在跑时游戏内查词必须彻底关掉——hook 侧
  /// `lookup_enabled=0` 即零写入，不留半开状态。
  Future<void> setSessionActive(bool active) async {
    if (_sessionActive == active) {
      // active phase 重复通知也是 reader/mapping 换代后重放意图的机会。
      // 不能因为上一个 mapping 曾成功 enable 就用 _pushedEnabled 早退。
      if (active) await _syncEnabled();
      return;
    }
    if (active) {
      _sessionRouteEpoch++;
      _lookupRouteEpoch = 0;
    }
    _sessionActive = active;
    await _syncEnabled();
  }

  /// 设置页改完开关后调用，与 `applyHoverAutoLookupFromPreferences` 同款纪律：
  /// 漏掉这一步，开关只落了盘，本局游戏里不生效。
  Future<void> applyEnabledFromPreferences() async {
    if (!_started) return;
    await _syncEnabled();
  }

  /// 换行 / 换页：屏上那句话已经不在了，卡片必须跟着消场，否则卡片还挂在旧句子的
  /// 字形位置上。由台词浮窗控制器在「显示行变了」那一刻调。
  Future<void> onLineChanged() async {
    await _terminateCurrentLookup();
  }

  /// hook 报上来一次命中。
  ///
  /// [GalLookupHit.submit] 分流：
  ///  - false（悬停）：**不查词**，只把高亮挪到光标那个字。悬停事件是鼠标移动的
  ///    频率，每次都查词会把词典引擎打爆。
  ///  - true（点击 / hook 侧判定的悬停即查词）：走完整查词链。
  ///
  /// 「悬停要不要自动查词」由 hook 侧决定并体现在 submit 上，Dart 不再解释一遍——
  /// 两处各判一次必然漂。
  Future<void> handleHit(GalLookupHit hit) async {
    if (!_started || !_enabledNow) return;
    if (!hit.submit) {
      // hover 高亮已在游戏线程的 fushiLookupReport 中同步绘制；再投一张 host→hook
      // highlight 帧不仅重复，还会和查词卡争双缓冲的最新发布序。
      return;
    }
    _latestSubmitHit = hit;
    // latest-wins：在途查词不打断，但只保留最后一次意图。代数也在入队时递增，
    // 所以当前 await 返回时就能判断自己是否已过期。
    final int generation = ++_lookupGeneration;
    final GlobalLookupRoute route = GlobalLookupRoute.galCard(
      routeEpoch: _sessionRouteEpoch,
      lookupEpoch: ++_lookupRouteEpoch,
    );
    // 新 submit 到达即废止旧 token，而不是等旧词典 Future 返回。旧 reveal / Timer
    // 从这一行起就无法投帧；同一个 galCard surface 会由新 route 的 lookupText 首步
    // hide(notify:false) 清场。
    final GlobalLookupRoute? previousRoute = _activeRoute;
    _activeRoute = route;
    if (previousRoute != null) {
      GlobalLookupChannel.invalidateRoute(previousRoute);
    }
    _pendingLookup = (hit: hit, generation: generation, route: route);
    if (_draining) return;
    _draining = true;
    final Completer<void> drainCompleter = Completer<void>();
    _drainCompleter = drainCompleter;
    try {
      while (_pendingLookup != null) {
        final ({
          GalLookupHit hit,
          int generation,
          GlobalLookupRoute route,
        }) next = _pendingLookup!;
        _pendingLookup = null;
        await _runLookup(next.hit, next.generation, next.route);
      }
    } finally {
      _draining = false;
      if (!drainCompleter.isCompleted) drainCompleter.complete();
      if (identical(_drainCompleter, drainCompleter)) {
        _drainCompleter = null;
      }
    }
  }

  /// hook 转发的卡片内输入：原样丢回 runner 的既有 popup 输入注入口。
  Future<void> handleInput(GalLookupInput input) async {
    if (!_started || !_enabledNow || _activeHit == null) return;
    final GalLookupCallResult result =
        await GalHookTextOverlayChannel.galLookupInput(input);
    if (!result.ok) {
      glog('gal-ingame: input kind=${input.kind} FAILED ${result.error}');
    }
  }

  // ── 内部 ──────────────────────────────────────────────────────────────────

  bool get _enabledNow => _sessionActive && _readEnabledPreference();

  bool _readEnabledPreference() {
    final GalIngameLookupPreferenceReader? reader = _preferenceReader;
    if (reader != null) {
      return reader(
            enabledPreferenceKey,
            defaultValue: PreferencesRepository.galIngameLookupEnabledDefault,
          ) ==
          true;
    }
    final AppModel? model = _appModel;
    if (model == null) return false;
    // best-effort：App 尚未初始化完时 prefsRepo 是 late 字段，读它会抛
    // 读不到就按默认「关」处理——绝不因为读偏好失败把 galgame 会话本身带崩。
    try {
      return model.galIngameLookupEnabled;
    } catch (_) {
      return PreferencesRepository.galIngameLookupEnabledDefault;
    }
  }

  Future<void> _syncEnabled() async {
    _enableSyncPending = true;
    final Completer<void>? activeDrain = _enableSyncCompleter;
    if (activeDrain != null) {
      await activeDrain.future;
      // 解决 drain 已看到 pending=false、但尚未清掉 completer 时的
      // lost-wakeup 窗口：新调用者在这个窗口置 pending 后，醒来必须
      // 自己再开一轮，不能把最后一个意图留在队列里。
      if (_enableSyncPending) await _syncEnabled();
      return;
    }

    final Completer<void> drain = Completer<void>();
    _enableSyncCompleter = drain;
    try {
      while (_enableSyncPending) {
        _enableSyncPending = false;
        final bool desired = _enabledNow;
        final int generation = ++_enableSyncGeneration;
        if (!desired) {
          await _terminateCurrentLookup();
        }
        if (generation != _enableSyncGeneration) continue;
        if (desired != _enabledNow) {
          _enableSyncPending = true;
          continue;
        }

        // 每轮都真正下发，不用 _pushedEnabled 早退。这使同一 active
        // phase 在 shared mapping 换代后仍能重放 enable 意图。
        final GalLookupCallResult result =
            await GalHookTextOverlayChannel.galLookupSetEnabled(desired);
        if (generation != _enableSyncGeneration) continue;

        final bool latestDesired = _enabledNow;
        if (result.ok && desired == latestDesired) {
          _pushedEnabled = desired;
        } else if (!result.ok) {
          // enable 失败必须保持 false，让后续同 active phase 通知可重试。
          // disable 失败也不伪称仍已 enable；runner 会自行保留关闭意图。
          _pushedEnabled = false;
        }
        glog('gal-ingame: setEnabled=$desired session=$_sessionActive '
            '-> ${result.error ?? "ok"}');

        if (desired != latestDesired) {
          _enableSyncPending = true;
          continue;
        }
        if (!desired) await _finishDisableRouting(generation);
      }
    } catch (error) {
      // owner 依旧把异常抛给调用者；Completer 只是唤醒同期进来的
      // waiters，不再单独 completeError，避免没有 waiter 时制造未处理的异步错误。
      if (!drain.isCompleted) drain.complete();
      rethrow;
    } finally {
      if (identical(_enableSyncCompleter, drain)) {
        _enableSyncCompleter = null;
      }
      if (!drain.isCompleted) drain.complete();
    }
  }

  Future<void> _finishDisableRouting(int enableGeneration) async {
    final Future<void>? draining = _drainCompleter?.future;
    if (draining != null) await draining;
    if (enableGeneration != _enableSyncGeneration || _enabledNow) return;
    // 严格顺序：旧 route 仍有效时先 hide；native 回执后再 invalidate。全局没有
    // 可变 target，因此 disable 不可能把迟到 render/reveal 改道成桌面第二弹窗。
    await _hideThenInvalidateActiveRoute();
  }

  /// 真查词：把「从命中字起的一段」交给 app 既有查词链。
  ///
  /// 查询串用共享的 [lookupQueryFromIndex]（与 texthooker 逐字查词同一份）：引擎按
  /// 查询串做最长匹配并回报 `bestLength`，所以点「永」命中「永遠」、点「遠」能单独
  /// 查到「遠」。整行原样当作 `sentence`给制卡上下文；内嵌卡不显示顶部整句横幅。
  static const int _kCardBitmapBytes = 8 * 1024 * 1024;
  static const double _kCardViewportFraction = 0.6;

  void _applyCardSizeCap(GalLookupHit hit) {
    if (hit.viewW <= 0 || hit.viewH <= 0) {
      GlobalLookupController.instance.setPhysicalCap();
      return;
    }
    double w = hit.viewW * _kCardViewportFraction;
    double h = hit.viewH * _kCardViewportFraction;
    const int budgetPixels = _kCardBitmapBytes ~/ 4;
    final double area = w * h;
    if (area > budgetPixels) {
      final double shrink = math.sqrt(budgetPixels / area);
      w *= shrink;
      h *= shrink;
    }
    GlobalLookupController.instance
        .setPhysicalCap(width: w.floor(), height: h.floor());
  }

  Future<void> _runLookup(
    GalLookupHit hit,
    int generation,
    GlobalLookupRoute route,
  ) async {
    if (!_isCurrentLookup(generation, route)) return;
    final String query = lookupQueryFromIndex(hit.line, hit.charIndex);
    if (query.isEmpty) {
      if (_isCurrentLookup(generation, route)) {
        await _terminateCurrentLookup();
      }
      return;
    }
    if (!hit.hasConsistentCharCount) {
      // 不丢弃（下标本身已经过范围校验），但必须留痕：这是「两侧字符计数单位漂了」
      // 的唯一早期信号，静默下去只会表现成「高亮总是偏几个字」。
      glog('gal-ingame: charCount mismatch seq=${hit.seq} '
          'reported=${hit.charCount} actual=${hit.line.length}');
    }
    // 必须在进入 lookupText 前挂上 active token：host 的 overlaySize/reveal 可以在
    // lookupText Future 返回前已经到达。generation 门会拒绝后来新 submit 已作废的旧回调。
    _activeHit = hit;
    _activeLookupGeneration = generation;
    _applyCardSizeCap(hit);
    glog('gal-ingame: lookup seq=${hit.seq} idx=${hit.charIndex} '
        'query="$query"');
    final bool taken = await GlobalLookupChannel.runWithRoute(
      route,
      () => GlobalLookupController.instance.lookupText(
        query,
        sentence: hit.line,
        showSentenceBanner: false,
        miningHandler: _miningResolver?.call(hit.line),
      ),
    );
    if (!_isCurrentLookup(generation, route)) {
      return;
    }
    if (!taken) {
      glog('gal-ingame: overlay refused lookup seq=${hit.seq}');
      await _terminateCurrentLookup();
      return;
    }
  }

  /// 覆盖窗回报「卡片已渲染、尺寸已定」（物理 px）→ 投帧。
  ///
  /// 只接受当前 lookup generation 的 reveal；新 submit 已经到达时，旧 WebView 的迟到尺寸
  /// 绝不能投进游戏。
  void _onOverlayRevealed(
    GlobalLookupRoute route,
    int physicalWidth,
    int physicalHeight,
  ) {
    final GalLookupHit? hit = _activeHit;
    if (hit == null || !_enabledNow) return;
    if (!_isCurrentLookup(_activeLookupGeneration, route)) return;
    if (physicalWidth <= 0 || physicalHeight <= 0) return;
    final int start = hit.charIndex;
    final int len = _highlightLength(hit);
    final ({int x, int y}) anchor =
        _resolveAnchor(hit, physicalWidth, physicalHeight);
    glog('gal-ingame: present seq=${hit.seq} anchor=(${anchor.x},${anchor.y}) '
        'card=${physicalWidth}x$physicalHeight hl=$start+$len');
    unawaited(
      _present(hit, anchor, start, len, _activeLookupGeneration, route),
    );
  }

  Future<void> _present(
    GalLookupHit hit,
    ({int x, int y}) anchor,
    int highlightStart,
    int highlightLen,
    int generation,
    GlobalLookupRoute route,
  ) async {
    if (!_isCurrentLookup(generation, route)) return;
    final GalLookupCallResult result =
        await GalHookTextOverlayChannel.galLookupPresent(
      seq: hit.seq,
      anchorX: anchor.x,
      anchorY: anchor.y,
      highlightStart: highlightStart,
      highlightLen: highlightLen,
    );
    if (!_isCurrentLookup(generation, route)) return;
    if (!result.ok) {
      glog('gal-ingame: present seq=${hit.seq} FAILED ${result.error}');
      return;
    }
    if (result.clamped) {
      glog('gal-ingame: present seq=${hit.seq} CLAMPED to '
          '${result.width}x${result.height}');
    }
  }

  Future<void> _onOverlayHidden(GlobalLookupRoute route) async {
    if (!_acceptsRoute(route)) return;
    await _terminateCurrentLookup();
  }

  /// Ends the current gal lookup on both surfaces.
  ///
  /// The game Layer is dismissed first; the off-screen Fushi popup is then
  /// hidden while its immutable route is still valid, and only after native has
  /// accepted that hide do we retire the token. Invalidating first would make
  /// the channel boundary drop the hide and leave a stale WebView frame capable
  /// of reappearing. This is used for line changes, empty/refused lookups,
  /// genuine popup dismissal, session disable and test shutdown alike.
  Future<void> _terminateCurrentLookup() async {
    final GlobalLookupRoute? route = _activeRoute;
    final GalLookupHit? hit = _latestSubmitHit ?? _activeHit;
    _lookupGeneration++;
    _activeHit = null;
    _activeLookupGeneration = 0;
    _latestSubmitHit = null;
    _pendingLookup = null;
    try {
      if (hit != null) {
        final GalLookupCallResult result =
            await GalHookTextOverlayChannel.galLookupDismiss(hit.seq);
        glog('gal-ingame: dismiss seq=${hit.seq} -> ${result.error ?? "ok"}');
      }
    } finally {
      await _hideThenInvalidateRoute(route);
    }
  }

  /// 命中高亮跨度（UTF-16）= 引擎匹配长度 `bestLength`，钳进行尾。
  ///
  /// 与弹窗内高亮、剪贴板面板横幅高亮同一真值口径；引擎没给（无结果）时退回光标那
  /// 一个字素簇，绝不给 0 —— 0 会让游戏里「点了没反应」。
  int _highlightLength(GalLookupHit hit) {
    final int bestLength = GlobalLookupController.instance.rootBestLength;
    final int remaining = hit.line.length - hit.charIndex;
    if (bestLength <= 0) return _graphemeLengthAt(hit.line, hit.charIndex);
    return bestLength > remaining ? remaining : bestLength;
  }

  bool _acceptsRoute(GlobalLookupRoute route) =>
      route == _activeRoute && GlobalLookupChannel.isRouteValid(route);

  bool _isCurrentLookup(int generation, GlobalLookupRoute route) =>
      _started &&
      _enabledNow &&
      generation == _lookupGeneration &&
      _acceptsRoute(route);

  Future<void> _hideThenInvalidateActiveRoute() async {
    await _hideThenInvalidateRoute(_activeRoute);
  }

  Future<void> _hideThenInvalidateRoute(GlobalLookupRoute? route) async {
    if (route == null) {
      if (_activeRoute == null) {
        GlobalLookupController.instance.setPhysicalCap();
      }
      return;
    }
    await GlobalLookupChannel.runWithRoute(
      route,
      () => GlobalLookupChannel.hide(notify: false),
    );
    if (_activeRoute == route) {
      GlobalLookupChannel.invalidateRoute(route);
      _activeRoute = null;
      GlobalLookupController.instance.setPhysicalCap();
    }
  }

  /// 卡片左上角（primaryLayer px）。
  ///
  /// 复用公共级联定位纯函数 [computeFrameRect]：卡片放在被点字形的下方，
  /// 下方空间不够就翻到上方（这就是「避让字幕」——字形矩形本身即台词所在的那一行），
  /// 中心 X 取字形中心并 clamp 进视口。**不另写一套定位**。
  ///
  /// 之后再夹一次 `[0, view - card]`：[computeFrameRect] 在空间不足时会把**它算出来
  /// 的**宽高收缩，而我们交给游戏 Layer 的卡片尺寸是固定的，所以卡片比视口还大的
  /// 退化情形要显式贴边，否则右/下会溢出到视口外被裁掉。
  /// 测试入口：定位算法必须被**直接**测到，不许在测试里转写一份。
  ///
  /// 这条不是洁癖。本次改造里 replay 的判据就是「参照实现」，生产代码的收卡判据改完
  /// 之后它照样绿——那种绿只证明参照实现自洽。定位算法同理：转写一份就等于把 bug
  /// 复制两遍，然后互相验证说没问题。
  @visibleForTesting
  ({int x, int y}) debugResolveAnchor(GalLookupHit hit, int cardW, int cardH) =>
      _resolveAnchor(hit, cardW, cardH);

  ({int x, int y}) _resolveAnchor(GalLookupHit hit, int cardW, int cardH) {
    if (hit.viewW <= 0 || hit.viewH <= 0) {
      // hook 没报视口（老 hook / 取不到 primaryLayer 尺寸）：退化成「字形正下方」，
      // 不猜屏幕边界。
      return (x: hit.glyphX, y: hit.glyphY + hit.glyphH + _kCardGap);
    }
    final GlobalLookupFrameRect frame = computeFrameRect(
      selectionRect: hit.glyphRect,
      screenW: hit.viewW.toDouble(),
      screenH: hit.viewH.toDouble(),
      maxWidth: cardW.toDouble(),
      maxHeight: cardH.toDouble(),
      // 本样本（KiriKiri + textrender.dll）是横排；竖排排期在 P1 之后，届时由
      // profile 给出真值再传进来，不在这里猜。
      isVertical: false,
    );
    return (
      x: _clampInt(frame.left.round(), 0, hit.viewW - cardW),
      y: _clampInt(frame.top.round(), 0, hit.viewH - cardH),
    );
  }

  /// [index] 处**字素簇**的 UTF-16 长度（绝不劈开代理对 / 浊点 / 组合字，与
  /// texthooker 逐字命中同一粒度）。越界返回 0。
  static int _graphemeLengthAt(String text, int index) {
    if (index < 0 || index >= text.length) return 0;
    int offset = 0;
    for (final String grapheme in text.characters) {
      if (offset == index) return grapheme.length;
      if (offset > index) break;
      offset += grapheme.length;
    }
    // 下标落在某个字素簇中间（脏数据）：按一个 code unit 处理，不抛。
    return 1;
  }

  static int _clampInt(int value, int min, int max) {
    if (max < min) return min;
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }
}

/// 卡片与被点字形之间的间距（primaryLayer px）。与覆盖窗 `computeFrameRect` 的
/// `popupPadding` 同量级，仅用于「hook 没报视口」的退化分支。
const int _kCardGap = 4;
