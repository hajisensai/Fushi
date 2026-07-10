// spec 2026-07-10 — 常驻剪贴板查词面板编排（Windows）。
//
// 核心洞察（spec §2）：面板不是新渲染面——它是「一次带句子上下文的全局查词，
// 渲染进第二个覆盖窗实例」。查词/渲染/嵌套/桥全部复用瞬态覆盖窗的管线：
//   DesktopLookupDispatcher → update(request) → AppModel.searchDictionary
//   → buildStackRenderScript(layoutMode:'panel', sentence:整句)
//   → 面板窗 render（host 面板布局：root 撑满固定视口、内容内滚、原地更新）。
// 与瞬态窗的差异全是数据不是模式：固定 rect（用户拖动/调整后记忆）、不装
// dismiss 钩子（常驻语义）、九根 DEFERRED 桥经共享 overlay_bridge_handlers
// 由本 channel 回传。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hibiki/src/lookup/global_lookup_controller.dart'
    show GlobalLookupMediaRequest, resolveGlobalLookupMedia;
import 'package:hibiki/src/lookup/global_lookup_log.dart';
import 'package:hibiki/src/lookup/global_lookup_render.dart';
import 'package:hibiki/src/lookup/global_lookup_stack.dart';
import 'package:hibiki/src/lookup/overlay_bridge_handlers.dart';
import 'package:hibiki/src/lookup/overlay_window_channel.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:path/path.dart' as p;

/// 面板窗默认矩形（逻辑像素）。首次启用（无记忆位）时用；native
/// Reveal 会把越界矩形 clamp 回工作区，故不需要 Dart 侧预知显示器布局。
const Rect kClipboardPanelDefaultRect = Rect.fromLTWH(120, 120, 380, 560);

/// host 面板栏高度（CSS px），与 global_lookup_host.js 的 PANEL_BAR_HEIGHT
/// 一致（守卫见 clipboard_panel_controller_test）。
const double kClipboardPanelBarHeight = 28;

/// 解析 `x,y,w,h`（逻辑像素）矩形记忆；格式非法返回 null（回退默认位）。
/// 纯函数，直接单测。
Rect? parseClipboardPanelRect(String raw) {
  final List<String> parts = raw.split(',');
  if (parts.length != 4) return null;
  final List<double> nums = <double>[];
  for (final String part in parts) {
    final double? v = double.tryParse(part.trim());
    if (v == null || !v.isFinite) return null;
    nums.add(v);
  }
  if (nums[2] < 120 || nums[3] < 120) return null; // 过小=损坏记忆，弃用。
  return Rect.fromLTWH(nums[0], nums[1], nums[2], nums[3]);
}

/// 编码矩形记忆（逻辑像素，1 位小数足够）。纯函数。
String encodeClipboardPanelRect(Rect r) =>
    '${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)},'
    '${r.width.toStringAsFixed(1)},${r.height.toStringAsFixed(1)}';

/// 常驻剪贴板面板的单例编排器。生命周期：main.dart 桌面块 [start] 一次；
/// 请求入口只有 [update]（由 DesktopLookupDispatcher 按去向分区调用）。
class ClipboardPanelController {
  ClipboardPanelController._();
  static final ClipboardPanelController instance = ClipboardPanelController._();

  static bool get isSupported => Platform.isWindows;

  static const OverlayWindowChannel _channel =
      OverlayWindowChannel(HibikiChannels.clipboardPanel);

  AppModel? _appModel;
  bool _started = false;
  bool _visible = false;

  /// ×（面板栏关闭钮）后为 true：剪贴板事件不再更新面板，直到 Ctrl+Shift+D
  /// （origin=hotkey 的显式意图）或重开设置开关解除。
  bool paused = false;

  bool _backdropApplied = false;

  /// spec §6 gate — Win11 acrylic backdrop 是否被 OS 接受。false（Win10 /
  /// 旧 Win11）时透明度滑杆隐藏、卡背景恒 alpha=1（不透明降级）。
  bool get backdropOk => _backdropApplied;

  // 面板内嵌套栈（与瞬态窗同一纯栈模型 + per-frame result/anchor 侧表）。
  GlobalLookupStack _stack = GlobalLookupStack.empty;
  final Map<String, DictionarySearchResult> _frameResults =
      <String, DictionarySearchResult>{};
  final Map<String, Rect?> _frameAnchors = <String, Rect?>{};
  int _frameSeq = 0;
  String _currentSentence = '';

  /// 当前面板矩形（逻辑像素）。真相源是 pref（windowMoved 落库）；内存值只是
  /// 本次会话的工作拷贝。
  Rect _panelRect = kClipboardPanelDefaultRect;

  /// 审查修正（latest-wins）：VN 台词流下 update 可并发在途（dispatcher
  /// unawaited + searchDictionary 远程词典延迟波动），旧句结果可能后完成并
  /// 覆盖新句。每次 update 领取单调序号，任何 await 之后发现自己已过期就放弃。
  int _updateSeq = 0;

  /// 接线 channel 反向 handler；仅 destination==panel 时预热（审查修正：默认
  /// main 的用户不为面板常驻一整棵 WebView2 进程树——零破坏承诺的一部分）。
  /// 幂等；仅 Windows。
  Future<void> start({required AppModel appModel}) async {
    if (!isSupported || _started) return;
    _started = true;
    _appModel = appModel;
    _panelRect = parseClipboardPanelRect(appModel.clipboardPanelRect) ??
        kClipboardPanelDefaultRect;
    _channel.setHandlers(
      onGetMedia: _resolveMedia,
      onJsMessage: _onJsMessage,
      // 面板不装 dismiss 钩子，genuine overlayHidden 只可能来自 JS 路径；
      // 防御性重置可见态即可。
      onOverlayHidden: () => _visible = false,
    );
    await _channel.prepare(_popupAssetsDir());
    if (appModel.desktopClipboardDestination ==
        DesktopClipboardDestination.panel) {
      unawaited(ensurePrewarmed());
    }
    glog('panel: started rect=$_panelRect');
  }

  /// 预热面板 WebView2（native 幂等，热了就 no-op）。启动时 destination==panel
  /// 才调；用户在设置里切到 panel 时补调（冷路径由 native pending_json_ 缓存
  /// 兜底，只慢首帧不丢帧）。
  Future<void> ensurePrewarmed() async {
    if (!_started) return;
    try {
      final double dpr = _devicePixelRatio();
      await _channel.prewarmWebView(
        width: (_panelRect.width * dpr).round(),
        height: (_panelRect.height * dpr).round(),
      );
    } catch (e) {
      glog('panel: prewarm FAILED (non-fatal): $e');
    }
  }

  /// 剪贴板/热键请求入口（DesktopLookupDispatcher 的 panel 分区）。
  /// 语义：整句查一次（引擎按前缀/去屈折从句首匹配）+ 句子横幅逐字可点；
  /// 面板未显示则按记忆位显示；已显示则原地更新（固定 rect 无窗口运动）。
  /// paused 时只有 origin=hotkey（Ctrl+Shift+D 显式意图）解除暂停并继续。
  Future<void> update(DesktopLookupRequest request) async {
    final AppModel? model = _appModel;
    if (!_started || model == null) return;
    if (paused && request.origin != DesktopLookupOrigin.hotkey) {
      glog('panel: paused — drop ${request.origin}');
      return;
    }
    paused = false;
    // latest-wins：领取序号；每个 await 后核对，过期即弃（VN 流乱序守卫）。
    final int seq = ++_updateSeq;
    try {
      final DictionarySearchResult result = await model.searchDictionary(
        searchTerm: request.text,
        searchWithWildcards: false,
      );
      if (seq != _updateSeq) {
        glog('panel: update superseded (seq=$seq)');
        return;
      }
      _recordLookupCount(model);
      _currentSentence = request.text;
      _seedRootFrame(request.text, result);
      if (!_visible) {
        await _showPanel(model);
        if (seq != _updateSeq) return;
      }
      await _renderPanel(model);
      glog('panel: updated "${request.text.length} chars" '
          'entries=${result.entries.length}');
    } catch (e, st) {
      glog('panel: update EXCEPTION $e\n$st');
    }
  }

  /// TODO-1204 对齐——面板查词与瞬态覆盖窗同口径记一次查词计数（source
  /// [kStatSourceBook]，无书 locator，只进统计页汇总）。best-effort：任何失败
  /// 记日志吞掉，绝不打断查词。
  void _recordLookupCount(AppModel model) {
    try {
      unawaited(model.database
          .addLookupCount(sourceType: kStatSourceBook, dateKey: statTodayKey())
          .catchError((Object e, StackTrace st) {
        glog('panel: lookup-count EXCEPTION $e\n$st');
      }));
    } catch (e, st) {
      glog('panel: lookup-count EXCEPTION (sync) $e\n$st');
    }
  }

  /// 透明度滑杆变更后重渲 root，使新 alpha 生效（设置页调用）。
  Future<void> refreshOpacity() async {
    final AppModel? model = _appModel;
    if (!_started || model == null || _stack.isEmpty) return;
    await _renderPanel(model);
  }

  /// 面板栏 ×：藏窗 + 暂停路由（Ctrl+Shift+D 或设置重开解除）。
  Future<void> hidePanel({bool pause = true}) async {
    paused = pause || paused;
    _visible = false;
    await _channel.hide(notify: false);
  }

  void _seedRootFrame(String query, DictionarySearchResult result) {
    const String id = kGlobalLookupRootFrameId;
    _stack = GlobalLookupStack(<GlobalLookupFrame>[
      GlobalLookupFrame(
        id: id,
        query: query,
        parentIndex: -1,
        resultCount: result.entries.length,
      ),
    ]);
    _frameResults
      ..clear()
      ..[id] = result;
    _frameAnchors
      ..clear()
      ..[id] = null;
  }

  Future<void> _showPanel(AppModel model) async {
    final double dpr = _devicePixelRatio();
    final GlobalLookupShowResult shown = await _channel.showAt(
      x: (_panelRect.left * dpr).round(),
      y: (_panelRect.top * dpr).round(),
      width: (_panelRect.width * dpr).round(),
      height: (_panelRect.height * dpr).round(),
    );
    if (!shown.ok) {
      glog('panel: showAt FAILED');
      return;
    }
    // 固定 rect：跳过瞬态窗的离屏自测循环，直接按记忆尺寸上屏（native
    // Reveal 会 clamp 到工作区，显示器拔掉/缩小也不会丢窗）。
    await _channel.reveal(
      width: (_panelRect.width * dpr).round(),
      height: (_panelRect.height * dpr).round(),
    );
    _visible = true;
    // spec §6 gate — 首次显示时申请 acrylic backdrop 并据结果门控透明度。
    _backdropApplied = await _channel.applyBackdrop();
    await _channel.setPinned(model.clipboardPanelPinned);
    // pin 视觉态同步折进 _renderPanel 的渲染脚本（审查修正：native
    // pending_json_ 是单槽缓存，独立发送会被随后的栈渲染覆盖丢失）。
    glog('panel: shown rect=$_panelRect backdrop=$_backdropApplied');
  }

  /// 组栈渲染。screen/max 尺寸都以面板视口（CSS px）为边界：嵌套子卡的
  /// computeFrameRect 级联在面板内 clamp（spec §5），不再引用显示器工作区。
  Future<void> _renderPanel(AppModel model) async {
    final BuildContext? ctx = model.navigatorKey.currentContext;
    if (ctx == null) return;
    final double viewportW = _panelRect.width;
    final double viewportH = _panelRect.height - kClipboardPanelBarHeight;
    final double maxW =
        (model.popupMaxWidth * model.appUiScale).clamp(160.0, viewportW);
    final double maxH =
        (model.popupMaxHeight * model.appUiScale).clamp(160.0, viewportH);
    final List<GlobalLookupFramePayload> payloads =
        <GlobalLookupFramePayload>[];
    for (int i = 0; i < _stack.length; i++) {
      final GlobalLookupFrame frame = _stack.frames[i];
      final DictionarySearchResult? result = _frameResults[frame.id];
      if (result == null) continue;
      payloads.add(GlobalLookupFramePayload(
        frame: frame,
        result: result,
        anchorRect: _frameAnchors[frame.id],
        // 面板 root 恒带整句横幅（剪贴板文本天然就是句子上下文，兼作制卡
        // sentence 字段）；子卡不带（与瞬态窗一致）。
        sentence: frame.id == kGlobalLookupRootFrameId ? _currentSentence : '',
      ));
    }
    if (payloads.isEmpty) return;
    final String script = buildStackRenderScript(
      context: ctx,
      appModel: model,
      payloads: payloads,
      screenWidth: viewportW,
      screenHeight: viewportH,
      maxWidth: maxW,
      maxHeight: maxH,
      layoutMode: 'panel',
      cardBgAlpha: _backdropApplied ? model.clipboardPanelOpacity : 1.0,
    );
    // pin 视觉态并进同一渲染脚本：native pending_json_ 是单槽缓存，冷启动时
    // 独立脚本会互相覆盖；同一 ExecuteScript 保证 pin 图标与卡片同帧就位。
    final String pinVisualJs = 'window.__globalLookupHost && '
        'window.__globalLookupHost.setPanelPinnedVisual('
        '${model.clipboardPanelPinned});';
    await _channel.render('$script\n$pinVisualJs');
  }

  void _onJsMessage(Map<String, Object?> message) {
    final Object? handler = message['handler'];
    final AppModel? model = _appModel;
    // 九根 DEFERRED 桥走共享权威 handler，经本 channel 的 resolveBridge 回传
    // （与瞬态覆盖窗同一实现，spec 红线：绝不复制）。
    if (maybeHandleOverlayDeferredBridge(
      model: model,
      handler: handler,
      message: message,
      resolveBridge: _channel.resolveBridge,
    )) {
      return;
    }
    switch (handler) {
      case 'windowMoved':
        // 拖动/调整结束（native 模态循环返回后报最终 rect，物理 px）。
        final Object? args = message['args'];
        if (args is List && args.length >= 4) {
          final double dpr = _devicePixelRatio();
          final List<double> v = <double>[
            for (final Object? a in args) (a is num) ? a.toDouble() : 0,
          ];
          if (v[2] > 0 && v[3] > 0 && dpr > 0) {
            _panelRect =
                Rect.fromLTWH(v[0] / dpr, v[1] / dpr, v[2] / dpr, v[3] / dpr);
            unawaited(model
                ?.setClipboardPanelRect(encodeClipboardPanelRect(_panelRect)));
            glog('panel: moved -> $_panelRect');
          }
        }
      case 'panelPin':
        final Object? args = message['args'];
        final bool pinned =
            args is List && args.isNotEmpty && args.first == true;
        unawaited(_channel.setPinned(pinned));
        unawaited(model?.setClipboardPanelPinned(pinned));
      case 'panelClose':
        unawaited(hidePanel());
      case 'dismissPopupAt':
        final int? index = _firstIntArg(message);
        if (index == null) return;
        if (index <= 0) {
          // root 卡的 × 与面板栏 × 同语义：常驻面板没有「关根卡留空窗」态。
          unawaited(hidePanel());
          return;
        }
        _stack = dismissPopupAt(_stack, index);
        _pruneFrameSideTables();
        unawaited(_rerender());
      case 'closeChildPopups':
        final int? parentIndex = _firstIntArg(message);
        if (parentIndex == null) return;
        _stack = closeChildPopupsAndClearSelection(_stack, parentIndex);
        _pruneFrameSideTables();
        unawaited(_rerender());
      case 'tapOutside':
        // 面板内点空白：只收子层（层内语义与瞬态窗一致），绝不藏窗（常驻）。
        final String? frameId = message['__frameId'] as String?;
        final int layerIndex =
            frameId == null ? -1 : _layerIndexForFrameId(frameId);
        if (layerIndex >= 0) {
          _stack = closeChildPopupsAndClearSelection(_stack, layerIndex);
          _pruneFrameSideTables();
          unawaited(_rerender());
        }
      case 'onLinkClick':
      case 'textSelected':
        final Object? args = message['args'];
        if (args is! List || args.isEmpty) return;
        final String query = args.first?.toString() ?? '';
        if (query.isEmpty) return;
        final Rect? anchor =
            args.length >= 2 ? _anchorRectFromArg(args[1]) : null;
        unawaited(_lookupNested(query, anchor));
      // overlaySize：面板 host 已短路，不应到达；popupRendered/contentHeight/
      // topPullReleased（常驻不滑关）/dismiss：一律忽略。
      default:
        return;
    }
  }

  Future<void> _rerender() async {
    final AppModel? model = _appModel;
    if (model == null || _stack.isEmpty) return;
    await _renderPanel(model);
  }

  Future<void> _lookupNested(String query, Rect? anchorRect) async {
    final AppModel? model = _appModel;
    if (model == null) return;
    try {
      _recordLookupCount(model);
      final DictionarySearchResult result = await model.searchDictionary(
        searchTerm: query,
        searchWithWildcards: false,
      );
      final GlobalLookupFrame child = GlobalLookupFrame(
        id: 'panel-frame-${_frameSeq++}',
        query: query,
        parentIndex: _stack.length - 1,
        resultCount: result.entries.length,
      );
      final GlobalLookupStack next = pushLookupFrame(_stack, child);
      if (identical(next, _stack)) {
        return; // 无结果的嵌套查词不压栈（与瞬态窗同语义）。
      }
      _stack = next;
      _frameResults[child.id] = result;
      _frameAnchors[child.id] = anchorRect;
      await _renderPanel(model);
    } catch (e, st) {
      glog('panel: nested EXCEPTION $e\n$st');
    }
  }

  void _pruneFrameSideTables() {
    final Set<String> live = <String>{
      for (final GlobalLookupFrame f in _stack.frames) f.id,
    };
    _frameResults.removeWhere((String id, _) => !live.contains(id));
    _frameAnchors.removeWhere((String id, _) => !live.contains(id));
  }

  int _layerIndexForFrameId(String frameId) {
    for (int i = 0; i < _stack.length; i++) {
      if (_stack.frames[i].id == frameId) return i;
    }
    return -1;
  }

  int? _firstIntArg(Map<String, Object?> message) {
    final Object? args = message['args'];
    if (args is List && args.isNotEmpty && args.first is num) {
      return (args.first as num).toInt();
    }
    return null;
  }

  Rect? _anchorRectFromArg(Object? arg) {
    if (arg is! Map) return null;
    double num2(Object? v) => (v is num) ? v.toDouble() : 0;
    final double w = num2(arg['width']);
    final double h = num2(arg['height']);
    if (w <= 0 && h <= 0) return null;
    return Rect.fromLTWH(num2(arg['x']), num2(arg['y']), w, h);
  }

  Future<Uint8List> _resolveMedia(String url) async {
    try {
      final GlobalLookupMediaRequest? request = resolveGlobalLookupMedia(url);
      if (request == null) return Uint8List(0);
      final Uint8List? bytes =
          HoshiDicts.instance.getMediaFile(request.dictionary, request.path);
      return bytes ?? Uint8List(0);
    } catch (_) {
      return Uint8List(0);
    }
  }

  double _devicePixelRatio() {
    final BuildContext? ctx = _appModel?.navigatorKey.currentContext;
    if (ctx != null) {
      final double dpr = MediaQuery.maybeOf(ctx)?.devicePixelRatio ?? 0;
      if (dpr > 0) return dpr;
    }
    return WidgetsBinding.instance.platformDispatcher.views.isNotEmpty
        ? WidgetsBinding
            .instance.platformDispatcher.views.first.devicePixelRatio
        : 1.0;
  }

  String _popupAssetsDir() => p.join(
        p.dirname(Platform.resolvedExecutable),
        'data',
        'flutter_assets',
        'assets',
        'popup',
      );
}
