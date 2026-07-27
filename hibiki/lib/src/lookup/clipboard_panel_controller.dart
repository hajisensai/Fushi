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
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/lookup/global_lookup_controller.dart'
    show
        GlobalLookupController,
        GlobalLookupMediaRequest,
        resolveGlobalLookupMedia;
import 'package:hibiki/src/lookup/clipboard_history_payload.dart';
import 'package:hibiki/src/lookup/desktop_lookup_router.dart';
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
import 'package:hibiki_core/hibiki_core.dart' show kStatSourceBook;
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

  // spec §6 真机修正：acrylic backdrop 路线废弃（经 windowed WebView2 实测
  // 不透明，且毛玻璃≠透视）。透明=整窗 LWA_ALPHA，Win10/11 通用、无需能力
  // 探测，故原 backdropOk 门控删除、透明度滑杆恒可用。

  // 面板内嵌套栈（与瞬态窗同一纯栈模型 + per-frame result/anchor 侧表）。
  GlobalLookupStack _stack = GlobalLookupStack.empty;
  final Map<String, DictionarySearchResult> _frameResults =
      <String, DictionarySearchResult>{};
  final Map<String, Rect?> _frameAnchors = <String, Rect?>{};
  int _frameSeq = 0;
  String _currentSentence = '';

  /// 「关自动查词」纯文字态：面板只显示句子横幅（逐字可点）、不显示词典结果块。
  /// [_showTextOnly] 置 true；任何真查词（自动查词 / 点句中字 / 嵌套子查词）置
  /// false，使点词后释义正常显示。[_renderPanel] 据此给面板 root 帧传 sentenceOnly。
  bool _sentenceOnly = false;

  /// 真机第 4 轮 — 选词区当前查词起点（整句里的码点下标）。剪贴板更新回 0；
  /// 点句子条某字后为该字下标，配合根结果 bestLength 在横幅整词高亮。
  int _rootHitStart = 0;

  /// 测试注入点：释义点击的外部瞬态弹窗路由。null 走真
  /// [GlobalLookupController.instance.lookupText]。
  @visibleForTesting
  Future<bool> Function(String text, String sentence, Rect? anchorScreenRect)?
      debugExternalLookup;

  /// 当前面板矩形（逻辑像素）。真相源是 pref（windowMoved 落库）；内存值只是
  /// 本次会话的工作拷贝。
  Rect _panelRect = kClipboardPanelDefaultRect;

  /// 审查修正（latest-wins）：VN 台词流下 update 可并发在途（dispatcher
  /// unawaited + searchDictionary 远程词典延迟波动），旧句结果可能后完成并
  /// 覆盖新句。每次 update 领取单调序号，任何 await 之后发现自己已过期就放弃。
  int _updateSeq = 0;

  /// 当前 root 帧是否为**用户显式点词**的结果（`_lookupFromBanner`），而非被动来源自动查词。
  /// 为 true 时，被动连续文本流（剪贴板监听灌进来的 galgame 台词，
  /// `request.passiveStream`）不再抢占/重置 root：
  /// 只把可点句子横幅换成最新台词，保留用户点出的释义（否则每 ~400ms 一条新台词会 `++_updateSeq`
  /// 作废点词的在途 searchDictionary + `_seedRootFrame` 整帧重置冲掉释义，表现为「对话流动时
  /// 点词没反应」）。用户显式动作（点新横幅词 / 真剪贴板复制 / 关面板）重置它。
  bool _userOwnedRoot = false;

  /// 接线 channel 反向 handler；仅「剪贴板查词已开启 且 destination==panel」
  /// 时预热（审查修正的推广：默认去向改 panel 后，开关关着的用户同样不该为
  /// 面板常驻一整棵 WebView2 进程树——预热只给真会用到面板的人）。幂等；仅
  /// Windows。
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
    // 面板任务栏图标 — 在预热（窗口创建）之前把本地化标题递给 native，任务栏
    // 按钮 / Alt-Tab 项从第一帧起就是正确文案；面板被压底时点它即可拉回前台。
    await _channel.setWindowTitle(t.clipboard_panel_window_title);
    if (appModel.desktopClipboardEnabled &&
        appModel.desktopClipboardDestination ==
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
  /// BUG-717（用户 2026-07-11 拍板）：× 关面板只清当前卡，**不**永久暂停路由——
  /// 下一条剪贴板复制（或任何来源）都无条件重开面板。旧的 `paused` 门（× 后丢弃
  /// 非 hotkey 事件、直到 Ctrl+Shift+D 才解除）让用户「关掉后第二个词就出不来」，
  /// 已整条移除：关面板 = 藏窗（`_visible=false`），下一次 update 见 `!_visible`
  /// 直接 `_showPanel` 重开。想彻底静默走设置里的剪贴板查词总开关，不再靠这个门。
  Future<void> update(DesktopLookupRequest request) async {
    final AppModel? model = _appModel;
    if (!_started || model == null) return;
    // 用户已显式点词、正看释义时，被动流只刷新可点句子横幅、不抢占/不重置 root：
    // 换 _currentSentence（新句逐字可点）+ 原地重渲（不 _seedRootFrame、不 resetRootScroll、
    // 不 ++_updateSeq），点词的在途查词与已出释义都不被冲掉。用户点新横幅词即正常换根。
    // BUG-1099：判据抽成纯函数（`keepUserOwnedCardForPassiveStream`），与瞬态覆盖窗
    // 共用同一真相源并可直接单测两个方向（被动流不清帧 / 显式意图仍替换）。
    // 被动流的口径（当前实现，勿按旧注释理解）：`DesktopLookupService` 把**所有**剪贴板
    // 变化（`_handleClipboardChange` + 抓选区括号期回放）都标 `passiveStream:true`——
    // galgame 台词灌进来的和用户自己在别的 app 里 Ctrl+C 的走同一条入口、无法区分。
    // 只有全局热键、悬浮字幕点词、面板横幅点字、卡内点词、台词浮窗点词这些对 Hibiki
    // 的显式动作才是 `passiveStream:false`。面板是持久窗（`_visible` 恒 true，不像瞬态窗
    // 有 dismiss 钩子复位），`_userOwnedRoot` 只在 `hidePanel()` 或本函数下方「建立新 root」
    // 时复位，所以用户点过一次词之后，后续每一次真实 Ctrl+C 也只换横幅、不再自动重查，
    // 直到点横幅里的字或关面板。这是 BUG-1099「已知取舍」条目里记的待拍板行为，不是笔误。
    if (keepUserOwnedCardForPassiveStream(
      passiveStream: request.passiveStream,
      userOwnedCard: _userOwnedRoot,
      visible: _visible,
    )) {
      _currentSentence = request.text;
      _rootHitStart = 0; // 新句与旧词根无对应，撤销高亮基准避免错位高亮
      await _renderPanel(model);
      glog('panel: passive stream banner-only (user-owned root kept)');
      return;
    }
    // 到这里 = 建立新 root（显式复制 / 点词前的被动流）：清除用户拥有标志。
    _userOwnedRoot = false;
    // 「关自动查词」纯文字态：只显示复制到的句子文字（逐字可点），不自动 searchDictionary、
    // 不弹释义、不朗读、不记查词计数。用户点句中字才走 panelSentenceLookup 手动查
    // （那条路径重置 _sentenceOnly=false，释义正常出）。总开关 desktopClipboardEnabled
    // 仍决定「是否监听剪贴板」，本开关只决定「监听到之后自不自动查词」，两者正交。
    if (!model.desktopClipboardAutoLookup) {
      await _showTextOnly(model, request.text);
      return;
    }
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
      _sentenceOnly = false;
      _currentSentence = request.text;
      // 新句：rootQuery=整句，故基准码点下标=0；真正词首由 rootHitRange 再补偿被归一化
      // 剥掉的句首标点长度（BUG-773），不再假设词从句首第 0 字符开始。
      _rootHitStart = 0;
      _seedRootFrame(request.text, result);
      // 真机修复（"只显示一次"）：不能只信 Dart 侧 _visible——窗口可能被系统
      // 藏掉（历史 owned-minimize 联动、显式全屏切换等）而 Dart 不知情，之后
      // 每次更新都渲染进隐形窗。native IsShowing 含 IsWindowVisible 真值，
      // 每次更新复核，不可见就重新上屏。
      if (!_visible || !await _channel.isShowing()) {
        _visible = false;
        await _showPanel(model);
        if (seq != _updateSeq) return;
      } else {
        // 已显示：每次查词把面板抬到 z 序最上，不抢焦点（游戏/浏览器仍持键盘
        // 焦点）。已 pin 直接置顶，否则顶到非置顶带最上——修复「面板被别的窗
        // 压住时，新剪贴板查词只原地更新、看不到」。_showPanel 分支已在 reveal
        // 时置顶，故只在这里补。
        await _channel.raise(topmost: model.clipboardPanelPinned);
        if (seq != _updateSeq) return;
      }
      // 剪贴板内容更新：新句从顶部开始（复用 root iframe 的旧 scrollTop 会残留）。
      await _renderPanel(model, resetRootScroll: true);
      glog('panel: updated "${request.text.length} chars" '
          'entries=${result.entries.length}');
    } catch (e, st) {
      glog('panel: update EXCEPTION $e\n$st');
    }
  }

  /// 「关自动查词」纯文字态：不查词，只把复制到的句子作为 root 帧的横幅显示
  /// （逐字可点，点字走 panelSentenceLookup 手动查）。seed 一个空结果的 root 帧
  /// 让 [_renderPanel] 有 payload 可渲染，并置 [_sentenceOnly] 使渲染脚本摘掉
  /// 「No results」结果块。与自动查词路径共用同一 latest-wins 序号，避免与并发的
  /// 手动查词/后到的剪贴板句乱序。
  Future<void> _showTextOnly(AppModel model, String text) async {
    final int seq = ++_updateSeq;
    _sentenceOnly = true;
    _currentSentence = text;
    _rootHitStart = 0;
    // 空结果（无 entries）：popup.js 渲染句子横幅 + No results 块，后者由渲染脚本
    // 的 sentenceOnly 分支就地摘除，只剩句子文字。
    _seedRootFrame(text, DictionarySearchResult(searchTerm: text));
    if (!_visible || !await _channel.isShowing()) {
      _visible = false;
      await _showPanel(model);
      if (seq != _updateSeq) return;
    } else {
      // 已显示：纯文字态也把面板抬到 z 序最上（每次剪贴板更新即前台，不抢焦点），
      // 与自动查词路径口径一致。
      await _channel.raise(topmost: model.clipboardPanelPinned);
      if (seq != _updateSeq) return;
    }
    // 剪贴板内容更新（纯文字态）：新句从顶部开始，与自动查词路径口径一致。
    await _renderPanel(model, resetRootScroll: true);
    glog('panel: text-only "${text.length} chars" (auto-lookup off)');
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

  /// 透明度滑杆变更即时生效（设置页调用）。spec §6 真机修正：透明机制=整窗
  /// LWA_ALPHA（真透视），不再走卡背景 CSS alpha（acrylic 实测经 windowed
  /// WebView2 呈现为不透明，且毛玻璃本就看不清底下内容）。
  Future<void> refreshOpacity() async {
    final AppModel? model = _appModel;
    if (!_started || model == null) return;
    await _channel.setWindowAlpha((model.clipboardPanelOpacity * 100).round());
  }

  /// 设置页「防截屏」开关即时生效：与面板栏 🛡 按钮同一条 native 通道
  /// （[OverlayWindowChannel.setBlockCapture] → SetWindowDisplayAffinity），切当前
  /// 面板窗的 display affinity；面板已显示时同步面板内 🛡 图标视觉态。pref 落库由
  /// 调用方经 [AppModel.setClipboardPanelBlockCapture] 负责，本方法只管即时重应用
  /// （不新起并行机制，[_onJsMessage] 的 `panelBlockCapture` 分支也走本方法）。
  /// 唯一扇出入口：同一 pref 同时保护瞬态全局查词窗（热键 / 面板内点词都会弹），
  /// 这里一并推给 [GlobalLookupController.applyBlockCapture]——否则录屏/串流会从
  /// 瞬态窗泄露面板承诺保护的内容。
  Future<void> applyBlockCapture(bool block) async {
    if (!isSupported) return;
    await _channel.setBlockCapture(block);
    await GlobalLookupController.instance.applyBlockCapture(block);
    if (_visible) {
      await _channel.render('window.__globalLookupHost && '
          'window.__globalLookupHost.setPanelBlockCaptureVisual($block);');
    }
  }

  /// 面板栏 × / root 卡 ×：藏窗即可。BUG-717：不再暂停路由——下一条剪贴板复制
  /// 会经 [update] 的 `!_visible` 分支重开面板（关掉后第二个词照样弹）。
  Future<void> hidePanel() async {
    _visible = false;
    // 关面板 = 放弃当前用户查词：下一条来源（被动台词流 / 剪贴板）重开时正常自动查、不被
    // 上一轮的用户拥有标志锁成横幅-only。
    _userOwnedRoot = false;
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
    // spec §6 真机修正 — 透明=整窗 LWA_ALPHA（真透视，Win10/11 通用）。
    // acrylic backdrop 链保留在 native（ApplySystemBackdrop）但面板不再调用：
    // 真机实测它经 windowed WebView2 呈现为不透明，且毛玻璃≠「看见底下」。
    await _channel.setWindowAlpha((model.clipboardPanelOpacity * 100).round());
    await _channel.setPinned(model.clipboardPanelPinned);
    // 防截屏：按 pref（默认关）给面板窗设 display affinity。窗口重建后 native
    // 侧 ApplyBlockCapture 自动重加，这里每次显示再确认一次（pref 可能已改）。
    await _channel.setBlockCapture(model.clipboardPanelBlockCapture);
    // pin 视觉态同步折进 _renderPanel 的渲染脚本（审查修正：native
    // pending_json_ 是单槽缓存，独立发送会被随后的栈渲染覆盖丢失）。
    glog('panel: shown rect=$_panelRect '
        'alpha=${(model.clipboardPanelOpacity * 100).round()}%');
  }

  /// 组栈渲染。screen/max 尺寸都以面板视口（CSS px）为边界：嵌套子卡的
  /// computeFrameRect 级联在面板内 clamp（spec §5），不再引用显示器工作区。
  /// [resetRootScroll]：仅「剪贴板内容更新」路径（[update] / [_showTextOnly]，均
  /// seed 全新 root 帧）传 true——面板 root iframe 复用，其滚动容器的 scrollTop 会
  /// 跨渲染保留，一条更长的新内容会停在旧偏移；渲染后调 host 的 scrollRootToTop 把
  /// root 帧滚回顶部。点句中字重查 / 关子卡等原地更新传 false（保留当前滚动位置）。
  Future<void> _renderPanel(AppModel model,
      {bool resetRootScroll = false}) async {
    final BuildContext? ctx = model.navigatorKey.currentContext;
    if (ctx == null) return;
    final double viewportW = _panelRect.width;
    final double viewportH = _panelRect.height - kClipboardPanelBarHeight;
    // 真机第 5 轮 — 用户可把面板拖到 <160 逻辑 px：clamp(160, viewport) 在
    // 下界>上界时抛 ArgumentError，_renderPanel 从此每次更新都炸=面板假死。
    // 语义不变（至少 160、不超视口），只是视口更小时以视口为准。
    final double maxW = viewportW < 160
        ? viewportW
        : (model.popupMaxWidth * model.appUiScale).clamp(160.0, viewportW);
    final double maxH = viewportH < 160
        ? viewportH
        : (model.popupMaxHeight * model.appUiScale).clamp(160.0, viewportH);
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
        // 纯文字态只对面板 root 帧生效：摘掉空结果的「No results」块只剩句子。
        sentenceOnly: _sentenceOnly && frame.id == kGlobalLookupRootFrameId,
      ));
    }
    if (payloads.isEmpty) return;
    // 真机第 4 轮 — 选词区整词高亮：_rootHitStart（点击字/句首）为 rootQuery 在显示
    // 句子里的起始码点下标，长度=根结果的引擎匹配长度（bestLength，即「正常的断词」）。
    // BUG-773 — 归一化查词前剥掉了 rootQuery 的句首标点（『「"( 等），引擎从剥离串 0
    // 位匹配、bestLength 以剥离串为坐标系，而横幅显示**原始**句（含句首标点）。若直接
    // 从 _rootHitStart 铺 bestLength 会左移吞括号、右缺词尾（呪術廻戦→高亮成『呪術廻）。
    // 故把起点再右移「被剥句首标点」长度，再从真正词首量 bestLength（见 rootHitRange）。
    final DictionarySearchResult? rootResult =
        _frameResults[kGlobalLookupRootFrameId];
    final String rootQuery = _stack.isEmpty ? '' : _stack.frames.first.query;
    final ({int start, int length}) hit = rootResult == null
        ? (start: 0, length: 0)
        : rootHitRange(
            query: rootQuery,
            baseStartCp: _rootHitStart,
            leadingUnits: model.lookupLeadingStripUnits(rootQuery),
            bestLength: rootResult.bestLength,
          );
    final String script = buildStackRenderScript(
      context: ctx,
      appModel: model,
      payloads: payloads,
      screenWidth: viewportW,
      screenHeight: viewportH,
      maxWidth: maxW,
      maxHeight: maxH,
      layoutMode: 'panel',
      // 卡背景恒不透明（透明面板路线=composition，真机失败已回退；windowed 下卡
      // 背景透明只会露黑，故恒 1.0）。真透明改走 GDI 悬浮字幕窗（B 路线）另起。
      cardBgAlpha: 1.0,
      sentenceHitStart: hit.length > 0 ? hit.start : -1,
      sentenceHitLength: hit.length,
    );
    // pin 视觉态并进同一渲染脚本：native pending_json_ 是单槽缓存，冷启动时
    // 独立脚本会互相覆盖；同一 ExecuteScript 保证 pin 图标与卡片同帧就位。
    final String pinVisualJs = 'window.__globalLookupHost && '
        'window.__globalLookupHost.setPanelPinnedVisual('
        '${model.clipboardPanelPinned});';
    // 防截屏按钮视觉态同样并进同一渲染脚本（native pending_json_ 单槽缓存，
    // 独立脚本会互相覆盖），保证 🛡 图标与卡片、pin 同帧就位。
    final String blockCaptureVisualJs = 'window.__globalLookupHost && '
        'window.__globalLookupHost.setPanelBlockCaptureVisual('
        '${model.clipboardPanelBlockCapture});';
    // 剪贴板内容更新（新 root）时把 root 帧滚回顶部：root iframe 复用，其滚动位置
    // 会跨渲染保留，否则更长的新内容停在旧偏移而非从头看。并进同一渲染脚本（native
    // pending_json_ 单槽缓存，独立脚本会互相覆盖）。原地更新（点字重查 / 关子卡）
    // 不传，保留当前滚动位置。
    final String scrollResetJs = resetRootScroll
        ? '\nwindow.__globalLookupHost && '
            'window.__globalLookupHost.scrollRootToTop();'
        : '';
    await _channel
        .render('$script\n$pinVisualJs\n$blockCaptureVisualJs$scrollResetJs');
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
      // 剪贴板全文即句子上下文：制卡 `{sentence}` 用它兜底（JS 不发 sentence）。
      // 与句子横幅同一 `_currentSentence`，落实 spec §2 的「兼作制卡 sentence」。
      sentenceContext: _currentSentence,
    )) {
      return;
    }
    // BUG-1139 — Ctrl+滚轮内容缩放：改「词典字号」这一唯一真值后整栈重渲。
    // 实际生效机制是注入 head 里的 `documentElement.style.zoom`
    // （= popupContentZoom(appUiScale, fs)），**不是**按新字号重排——本仓没有任何
    // 一处用 dictionaryFontSize 生成 font-size CSS。面板窗尺寸固定
    // （global_lookup_host.js 在 panel 模式短路 measureAndReport），内容在 iframe 内
    // 滚动，所以这条路径本就不走窗口收缩、没有被裁风险；瞬态覆盖窗那条的测高换算
    // 见 BUG-1139 ③（global_lookup_host.js 的 frameContentZoom）。
    if (maybeHandleOverlayZoomFontStep(
      model: model,
      handler: handler,
      message: message,
      onFontSizeChanged: () => unawaited(_rerender()),
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
      case 'panelBlockCapture':
        // 防截屏按钮：经唯一扇出入口 [applyBlockCapture] 切面板 + 瞬态查词窗的
        // display affinity（同设置页开关路径），再落 pref（默认开）。
        final Object? args = message['args'];
        final bool block =
            args is List && args.isNotEmpty && args.first == true;
        unawaited(applyBlockCapture(block));
        unawaited(model?.setClipboardPanelBlockCapture(block));
      case 'panelClose':
        unawaited(hidePanel());
      case 'clipboardHistory':
        // 面板栏🕘：从 DB 重载复制历史（主进程写入，面板进程读），注入覆盖层。
        if (model == null) return;
        unawaited(_showClipboardHistory(model));
      case 'lookupClipboardHistoryEntry':
        // 历史某条被点：以该文本重查（换根，横幅显示整句），复用剪贴板查词管线。
        final Object? args = message['args'];
        if (args is! List || args.isEmpty) return;
        final String text = args.first?.toString() ?? '';
        if (text.isEmpty) return;
        unawaited(update(DesktopLookupRequest(
          text: text,
          origin: DesktopLookupOrigin.explicit,
        )));
      case 'clearClipboardHistory':
        // 历史面板「清空」：清库 + 内存，再重渲染（空态）。
        if (model == null) return;
        unawaited(_clearClipboardHistoryAndRefresh(model));
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
      case 'panelSentenceLookup':
        // 真机第 4 轮 — 选词区点字：底部原地重查（换根结果），不嵌套压卡。
        // args = [点击字到句尾的后缀, 点击字的码点下标]。
        final Object? args = message['args'];
        if (args is! List || args.isEmpty) return;
        final String suffix = args.first?.toString() ?? '';
        if (suffix.isEmpty) return;
        final int hitStart =
            args.length >= 2 && args[1] is num ? (args[1] as num).toInt() : 0;
        unawaited(_lookupFromBanner(suffix, hitStart));
      case 'onLinkClick':
      case 'textSelected':
        // 真机第 4 轮 — 释义文字点击：弹独立瞬态覆盖窗（OS 光标处，越出面板
        // 边界、点外即关），不再压面板内嵌套卡（固定 380×560 视口装不下级联）。
        final Object? args = message['args'];
        if (args is! List || args.isEmpty) return;
        final String query = args.first?.toString() ?? '';
        if (query.isEmpty) return;
        final Rect? anchor =
            args.length >= 2 ? _anchorRectFromArg(args[1]) : null;
        unawaited(_lookupExternal(query, anchor));
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

  /// 面板栏🕘：从 DB 重载复制历史（主进程采集写入，面板进程只读）后注入覆盖层。
  /// best-effort：任何失败记日志吞掉，绝不打断面板。
  Future<void> _showClipboardHistory(AppModel model) async {
    try {
      await model.clipboardHistoryRepo.loadFromDb();
      await _renderClipboardHistory(model);
    } catch (e, st) {
      glog('panel: clipboard-history EXCEPTION $e\n$st');
    }
  }

  /// 历史面板「清空」：清库 + 内存，再重渲染成空态覆盖层。
  Future<void> _clearClipboardHistoryAndRefresh(AppModel model) async {
    try {
      await model.clearClipboardHistory();
      await _renderClipboardHistory(model);
    } catch (e, st) {
      glog('panel: clipboard-history clear EXCEPTION $e\n$st');
    }
  }

  /// 把当前 [AppModel.clipboardHistory] + 本地化标签转成 host payload 注入渲染。
  /// 单槽 pending_json_ 顾虑不适用：历史开/清是离散用户动作，不与栈渲染并发。
  Future<void> _renderClipboardHistory(AppModel model) async {
    final String payload = buildClipboardHistoryPayloadJson(
      entries: model.clipboardHistory,
      title: t.clipboard_history_title,
      clearLabel: t.clipboard_history_clear,
      emptyLabel: t.clipboard_history_empty,
      now: DateTime.now(),
    );
    await _channel.render('window.__globalLookupHost && '
        'window.__globalLookupHost.showClipboardHistory($payload);');
  }

  /// 真机第 4 轮 — 选词区点字（panelSentenceLookup 桥）：以后缀重查并**换根**
  /// （底部原地更新），横幅继续显示整句（[_currentSentence] 不变），命中词由
  /// [_rootHitStart] + bestLength 高亮。与剪贴板流共用同一 latest-wins 序列：
  /// 点击后若新剪贴板句先到，旧点击结果作废，反之亦然。
  Future<void> _lookupFromBanner(String suffix, int hitStart) async {
    final AppModel? model = _appModel;
    if (!_started || model == null) return;
    // 显式点词：即刻标记 root 为用户拥有（在 await 之前置位，使查词在途时到达的被动台词流
    // 走横幅-only 分支、不 ++_updateSeq 作废本次查词），此后被动流不再冲掉这个结果。
    _userOwnedRoot = true;
    final int seq = ++_updateSeq;
    try {
      _recordLookupCount(model);
      final DictionarySearchResult result = await model.searchDictionary(
        searchTerm: suffix,
        searchWithWildcards: false,
      );
      if (seq != _updateSeq) return;
      // 点句中字=真手动查词：退出纯文字态，释义正常显示。
      _sentenceOnly = false;
      _rootHitStart = hitStart < 0 ? 0 : hitStart;
      _seedRootFrame(suffix, result);
      await _renderPanel(model);
    } catch (e, st) {
      glog('panel: banner lookup EXCEPTION $e\n$st');
    }
  }

  /// 真机第 4 轮 — 释义文字点击走独立瞬态覆盖窗（「查词弹窗应该可以出这个
  /// 框」：子窗 iframe 出不了自己的 HWND，唯一真解是另一个顶层窗）。点外即关。
  /// lookupText 返回 false（未 start / 空词）时回退面板内嵌套卡——点击绝不静默
  /// 丢失。
  ///
  /// 句子横幅（sentence=''）：这条路径是**释义文字/内链的子查词**，被点词并不
  /// 在剪贴板整句里（横幅整句是给面板 root「选词区」用的），故不传 [_currentSentence]
  /// ——否则瞬态窗顶上会重复贴一条与该词无关的剪贴板内容（面板背后本已显示）。
  /// 与面板自身「子卡不带横幅」策略（[_renderPanel] 里 root 才带 [_currentSentence]）
  /// 一致：所有子查词一律无横幅。制卡 sentence 字段不经此横幅（popup.js
  /// buildMinePayload 不读 __globalLookupSentence），故此处清空零影响制卡。
  ///
  /// 真机第 5 轮 — 卡片锚定在**被点文字**下方而非 OS 光标点：[anchorRect] 是
  /// host 重锚定后的面板窗内 CSS px 矩形（含面板栏/shell 偏移），加上
  /// [_panelRect] 原点即屏幕逻辑 px，传给瞬态窗做文字锚点。
  Future<void> _lookupExternal(String query, Rect? anchorRect) async {
    final Rect? screenRect =
        anchorRect?.shift(Offset(_panelRect.left, _panelRect.top));
    try {
      final Future<bool> Function(
              String text, String sentence, Rect? anchorScreenRect) lookup =
          debugExternalLookup ??
              (String text, String sentence, Rect? anchorScreenRect) =>
                  GlobalLookupController.instance.lookupText(text,
                      sentence: sentence, anchorScreenRect: anchorScreenRect);
      if (await lookup(query, '', screenRect)) return;
    } catch (e, st) {
      glog('panel: external lookup EXCEPTION $e\n$st');
    }
    await _lookupNested(query, anchorRect);
  }

  /// bestLength（引擎匹配长度，UTF-16 code units）转码点数——popup.js 的
  /// 逐字 span 数组是 Array.from 的码点数组，两端必须同单位否则代理对
  /// （emoji/罕见汉字）错位。纯函数，直接单测。
  @visibleForTesting
  static int hitLengthCodePoints(int bestLength, String query) {
    if (bestLength <= 0 || query.isEmpty) return 0;
    final int units = bestLength > query.length ? query.length : bestLength;
    return query.substring(0, units).runes.length;
  }

  /// 句子横幅整词高亮区间（**码点**坐标，对应 popup.js `Array.from` 的码点数组）。
  /// BUG-773：归一化查词前用 [AppModel.lookupLeadingStripUnits] 剥掉 [query] 的句首
  /// 标点，引擎才从剥离串 0 位匹配、[bestLength] 以剥离串为坐标系；而横幅显示的是
  /// **原始** query（含句首标点）。若从 [baseStartCp] 直接铺 bestLength 会左移吞进
  /// 句首括号、右缺词尾。故起点右移 [leadingUnits]（句首被剥的 UTF-16 长度）落到真正
  /// 词首，长度从词首起量 bestLength。
  ///
  /// [query]=当前根查询串（整句或点字后缀），[baseStartCp]=query 在显示句子里的起始
  /// 码点下标（整句=0，点字=点击码点下标），[leadingUnits]=query 句首被归一化剥掉的
  /// UTF-16 长度，[bestLength]=引擎匹配长度（UTF-16 code units）。返回 (start,length)
  /// 均为码点。纯函数，直接单测。
  @visibleForTesting
  static ({int start, int length}) rootHitRange({
    required String query,
    required int baseStartCp,
    required int leadingUnits,
    required int bestLength,
  }) {
    if (bestLength <= 0 || query.isEmpty) return (start: 0, length: 0);
    final int lead = leadingUnits < 0
        ? 0
        : (leadingUnits > query.length ? query.length : leadingUnits);
    final int leadCp = query.substring(0, lead).runes.length;
    // 词首之后的子串上再量 bestLength → 码点（复用 hitLengthCodePoints 的钳位）。
    final int lenCp = hitLengthCodePoints(bestLength, query.substring(lead));
    final int base = baseStartCp < 0 ? 0 : baseStartCp;
    return (start: base + leadCp, length: lenCp);
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
