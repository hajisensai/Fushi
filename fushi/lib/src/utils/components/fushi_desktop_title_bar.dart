import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:fushi/src/media/video/video_hdr_output.dart'
    show hdrHostActiveGlobal;
import 'package:fushi/src/platform/desktop/macos_traffic_lights.dart';
import 'package:fushi/src/platform/macos_fullscreen_state.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show isEinkTheme;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/fushi_color_roles.dart';
import 'package:fushi/src/utils/window_caption_channel.dart';
import 'package:window_manager/window_manager.dart';

/// App-themed desktop frame used after the native caption is hidden.
///
/// Windows and macOS both run it: `main()` hides the platform caption
/// ([TitleBarStyle.hidden]; on macOS that also hides the three traffic-light
/// buttons) and this widget draws the MD3 replacement — one title bar, one look,
/// on both hosts.
///
/// The frame keeps dragging, maximize/restore and the existing intercepted
/// close lifecycle, while avoiding Win32 caption chrome / AppKit titlebar
/// chrome. Resize is where the two hosts differ: Windows needs the app to
/// forward edge drags (`DragToResizeArea` → `startResizing`, which
/// `window_manager` only implements on Windows/Linux), while AppKit keeps
/// owning the window's own resize border under a full-size content view — so
/// macOS mounts no resize edges at all (see [_resizeEdges]).
class FushiDesktopTitleBar extends StatefulWidget {
  const FushiDesktopTitleBar({
    required this.title,
    required this.child,
    this.leadingInset = 0,
    super.key,
  });

  /// Keep the app frame as compact as the native caption it replaces.
  /// This is intentionally outside [FushiAppUiScale], so the window controls do
  /// not grow with content zoom.
  static const double height = 32;

  /// 关闭按钮的 key（测试按它判断顶栏是否挂着窗口按钮）。
  @visibleForTesting
  static const Key closeButtonKey = ValueKey<String>('fushi_title_bar_close');

  static bool _isEnabled = false;

  /// True once the app shell has installed its own desktop frame
  /// ([TitleBarStyle.hidden] + this widget). Widgets below the app frame read
  /// it to avoid rendering a second, redundant page header, and `HomePage`
  /// reads it to decide whether the settings tab still needs its own
  /// full-screen shell with a back arrow.
  ///
  /// Deliberately a startup latch and **not** a
  /// `Platform.isWindows || Platform.isMacOS` expression: widget tests never run
  /// `main()`, so a platform-derived value would make the Windows/macOS dev host
  /// and the Linux CI host take different layout branches for the very same
  /// test.
  static bool get isEnabled => _isEnabled;

  /// Latched exactly once from `main()` after the hidden title bar is applied.
  /// One-way on purpose — nothing turns the app frame back off at runtime.
  static void markEnabled() => _isEnabled = true;

  /// Lets tests exercise both shells; production code must use [markEnabled].
  @visibleForTesting
  static set debugIsEnabled(bool value) => _isEnabled = value;

  /// Fullscreen surfaces that do not flow through `window_manager` (notably
  /// media_kit on Windows) acquire an owner here while they directly manipulate
  /// the HWND. Owner semantics prevent one surface from restoring the frame
  /// while another fullscreen surface is still active.
  static final Set<Object> _contentFullscreenOwners = <Object>{};
  static final Object _windowManagerFullscreenOwner = Object();
  static final ValueNotifier<bool> _contentFullscreen = ValueNotifier<bool>(
    false,
  );

  static void setContentFullscreen({
    required Object owner,
    required bool enabled,
  }) {
    final bool changed = enabled
        ? _contentFullscreenOwners.add(owner)
        : _contentFullscreenOwners.remove(owner);
    if (!changed) return;
    _contentFullscreen.value = _contentFullscreenOwners.isNotEmpty;
    reassertMacTrafficLights();
  }

  /// macOS 原生红绿灯的显隐真值：顶栏在时显示（任何设计系统都用系统红绿灯，
  /// 用户 2026-10-04），内容全屏收起顶栏时隐藏（否则三个圆点浮在视频 / 阅读
  /// 内容左上角，BUG-973）。AppKit 进出原生全屏会重建标题栏视图、复位
  /// `isHidden`，所以退出全屏后调用方要再断言一次。非 macOS no-op。
  static void reassertMacTrafficLights() {
    unawaited(setMacOSTrafficLightsHidden(_contentFullscreen.value));
  }

  /// Keep the app frame in sync with the fullscreen state owned by
  /// `window_manager`.
  ///
  /// On Windows, window_manager only emits `leave-full-screen` when WM_SIZE is
  /// `SIZE_RESTORED`. Exiting fullscreen back to a previously maximized window
  /// remains `SIZE_MAXIMIZED`, so that event never arrives. Callers which set or
  /// read native fullscreen therefore update this stable owner directly.
  static void setWindowManagerFullscreen(bool enabled) {
    setContentFullscreen(
      owner: _windowManagerFullscreenOwner,
      enabled: enabled,
    );
  }

  static bool get isWindowManagerFullscreen =>
      _contentFullscreenOwners.contains(_windowManagerFullscreenOwner);

  /// 页面自带底色时（阅读器预设纸色等），顶栏跟它走而不是根主题的
  /// `colorScheme.surface`——顶栏挂在 Navigator 外，`Theme.of` 只读得到根主题，
  /// 页面不上报就会在页面顶上切出一条异色带。
  ///
  /// 与全屏同一套 owner 语义：多个 owner 同时在场时取最近一次**首次**上报的
  /// 那个（插入序最后一个，同一 owner 改色不改位次）；全部撤回即回落到根主题。
  /// 页面一般不直接调，而是用 [FushiTitleBarColorScope]（它负责「被别的整页
  /// 盖住时撤回」与 dispose）。
  static final Map<Object, FushiTitleBarColors> _pageColorOwners =
      <Object, FushiTitleBarColors>{};
  static final ValueNotifier<FushiTitleBarColors?> _pageColors =
      ValueNotifier<FushiTitleBarColors?>(null);

  /// 当前生效的页面配色；null = 用根主题。
  static ValueListenable<FushiTitleBarColors?> get pageColors => _pageColors;

  /// 页面上报的「延伸到顶栏底下」的背景（歌词模式的封面取色背景）。设置后顶栏
  /// 不再是一条独立色带：标题行先铺上报色兜底，再把这张背景画布的最上面一截
  /// 画进标题行（[FushiTitleBarBackdropView]），页面从同一画布的下半截画——
  /// 两边像素连续。页面一般不直接调，用 [FushiTitleBarColorScope.backdrop]
  /// （与配色同一套「被整页盖住时撤回」语义）。
  static final Map<Object, FushiTitleBarBackdrop> _pageBackdropOwners =
      <Object, FushiTitleBarBackdrop>{};
  static final ValueNotifier<FushiTitleBarBackdrop?> _pageBackdrop =
      ValueNotifier<FushiTitleBarBackdrop?>(null);

  /// 当前生效的页面背景；null = 标题行只铺底色。
  static ValueListenable<FushiTitleBarBackdrop?> get pageBackdrop =>
      _pageBackdrop;

  static void setPageBackdrop({
    required Object owner,
    required FushiTitleBarBackdrop? backdrop,
  }) {
    if (backdrop == null) {
      if (_pageBackdropOwners.remove(owner) == null) return;
    } else {
      // 记录按值比较：画布尺寸、构建函数（tear-off）与修订号都没变就不重发。
      if (_pageBackdropOwners[owner] == backdrop) return;
      _pageBackdropOwners[owner] = backdrop;
    }
    void publish() => _pageBackdrop.value = _pageBackdropOwners.isEmpty
        ? null
        : _pageBackdropOwners.values.last;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => publish());
    } else {
      publish();
    }
  }

  /// 自绘顶栏此刻占的高度（未装自绘顶栏 / 内容全屏收起时为 0）。页面要把背景
  /// 延伸到顶栏底下时，用它算画布；随 [visibleHeightListenable] 变化。
  static double get visibleHeight =>
      _isEnabled && !_contentFullscreen.value ? height : 0;

  /// [visibleHeight] 的变化信号（顶栏只在内容全屏时收起）。
  static ValueListenable<bool> get visibleHeightListenable =>
      _contentFullscreen;

  static void setPageColors({
    required Object owner,
    required FushiTitleBarColors? colors,
  }) {
    if (colors == null) {
      if (_pageColorOwners.remove(owner) == null) return;
    } else {
      if (_pageColorOwners[owner] == colors) return;
      _pageColorOwners[owner] = colors;
    }
    // 上报方通常在自己的 build 里调用，而顶栏是它的祖先：build 阶段直接改
    // notifier 会在构建中把祖先标脏（断言失败）。挪到本帧收尾再发布，下一帧
    // 顶栏重画。其余阶段（dispose、动画状态回调）立即发布。
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback(
        (_) => _publishPageColors(),
      );
    } else {
      _publishPageColors();
    }
  }

  static void _publishPageColors() {
    _pageColors.value = _pageColorOwners.isEmpty
        ? null
        : _pageColorOwners.values.last;
  }

  final Widget title;
  final Widget child;
  final double leadingInset;

  @override
  State<FushiDesktopTitleBar> createState() => _FushiDesktopTitleBarState();
}

class _FushiDesktopTitleBarState extends State<FushiDesktopTitleBar>
    with WindowListener {
  bool _isMaximized = false;

  /// 窗口是否在前台。失焦时窗口按钮组整体降低强调（与系统标题栏失焦变灰
  /// 同一语义），颜色仍全部取主题。
  bool _isFocused = true;

  /// macOS 原生全屏的 chrome 所有者（与 window_manager 那个所有者并列，互不覆盖）。
  final Object _macosNativeFullscreenOwner = Object();

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    if (Platform.isMacOS) {
      // macOS 上 window_manager 的 [WindowListener] 收不到全屏通知：
      // macos_window_utils 持有 NSWindow.delegate 并把它的 delegate 覆盖掉。
      // [MacosFullscreenState] 挂的是 NSWindowDelegate，AppKit 在**所有**入口
      // （快捷键 / 「显示」菜单 / 系统全屏手势）上都发，是唯一能覆盖全部路径的信号。
      MacosFullscreenState.instance.isFullscreen.addListener(
        _onMacosFullscreenChanged,
      );
      unawaited(MacosFullscreenState.instance.ensureRegistered());
      _onMacosFullscreenChanged();
    }
    // Windows 11 贴靠布局：最大化按钮的点击可能由原生命中区回传
    // （caption_snap_button.h），与 Flutter 侧点击走同一个处理。
    WindowCaptionChannel.onCaptionMaxButtonClick = _toggleMaximize;
    unawaited(_readInitialWindowState());
  }

  /// macOS 原生全屏时收起自绘顶栏（全屏下窗口既不能拖也不能缩放，留着就是一条
  /// 纯浪费的横带），退出全屏再把它挂回来。
  ///
  /// 顺带重申交通灯隐藏：`toggleFullScreen` 会重建标题栏视图，可能把
  /// `standardWindowButton.isHidden` 复位——复位后三个圆点会浮在 Flutter 内容
  /// 左上角，正好压住自绘顶栏的标题（BUG-973 同一根因）。
  void _onMacosFullscreenChanged() {
    final bool fullscreen = MacosFullscreenState.instance.isFullscreen.value;
    FushiDesktopTitleBar.setContentFullscreen(
      owner: _macosNativeFullscreenOwner,
      enabled: fullscreen,
    );
    if (!fullscreen) {
      FushiDesktopTitleBar.reassertMacTrafficLights();
    }
  }

  Future<void> _readInitialWindowState() async {
    try {
      final List<bool> state = await Future.wait<bool>(<Future<bool>>[
        windowManager.isMaximized(),
        windowManager.isFullScreen(),
        windowManager.isFocused(),
      ]);
      if (!mounted) return;
      FushiDesktopTitleBar.setWindowManagerFullscreen(state[1]);
      setState(() {
        _isMaximized = state[0];
        _isFocused = state[2];
      });
    } catch (error) {
      debugPrint('[Fushi] failed to read initial window state: $error');
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    if (WindowCaptionChannel.onCaptionMaxButtonClick == _toggleMaximize) {
      WindowCaptionChannel.onCaptionMaxButtonClick = null;
    }
    if (Platform.isMacOS) {
      MacosFullscreenState.instance.isFullscreen.removeListener(
        _onMacosFullscreenChanged,
      );
      FushiDesktopTitleBar.setContentFullscreen(
        owner: _macosNativeFullscreenOwner,
        enabled: false,
      );
    }
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    setState(() => _isMaximized = false);
  }

  @override
  void onWindowFocus() {
    if (!_isFocused) setState(() => _isFocused = true);
  }

  @override
  void onWindowBlur() {
    if (_isFocused) setState(() => _isFocused = false);
  }

  @override
  void onWindowEnterFullScreen() {
    FushiDesktopTitleBar.setWindowManagerFullscreen(true);
  }

  @override
  void onWindowLeaveFullScreen() {
    FushiDesktopTitleBar.setWindowManagerFullscreen(false);
  }

  void _minimize() {
    unawaited(windowManager.minimize());
  }

  void _toggleMaximize() {
    unawaited(_toggleMaximizeAndSync());
  }

  Future<void> _toggleMaximizeAndSync() async {
    try {
      final bool maximized = await windowManager.isMaximized();
      if (maximized) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
      final bool applied = await windowManager.isMaximized();
      if (!mounted || _isMaximized == applied) return;
      setState(() => _isMaximized = applied);
    } catch (error) {
      debugPrint('[Fushi] failed to toggle window maximize state: $error');
    }
  }

  void _close() {
    // main.dart installs setPreventClose(true), so this still runs the existing
    // bounded data flush and fast-exit path instead of destroying the engine.
    unawaited(windowManager.close());
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ValueListenableBuilder<bool>(
      valueListenable: FushiDesktopTitleBar._contentFullscreen,
      builder: (BuildContext context, bool contentFullscreen, Widget? child) {
        final bool hideFrame = contentFullscreen;
        // HDR 直通（video_hdr_output.dart）：这层 surface 底色盖着整个 Navigator，宿主
        // 窗激活时必须让开，否则视频洞透不到主窗后方的 libmpv 宿主窗。
        final Widget frame = ValueListenableBuilder<bool>(
          valueListenable: hdrHostActiveGlobal,
          builder: (BuildContext context, bool hdrHost, Widget? column) {
            return ColoredBox(
              color: hdrHost ? Colors.transparent : colors.surface,
              child: column,
            );
          },
          // 叠放而不是竖排（2026-10-06「app 顶栏和主要界面没有融为一体」）：
          // 曾经是 Column[标题行, Expanded(页面)]——页面从 y = 32 才开始画，
          // 标题行是一条独立的带子，详情页的 fanart / 模糊背景在它下沿被一刀
          // 切开，左栏封面顶端也被这条线截掉。
          //
          // 现在页面占满整个窗口（从 y = 0 画起），标题行浮在它上面；页面经
          // MediaQuery 顶部 padding 拿到标题行的让位高度（与状态栏 / 刘海同一
          // 约定：Scaffold 顶栏、SafeArea、[MediaDetailLayout] 自动让开），
          // 背景与可滚动内容照常铺到标题行底下，标题行本身透明。
          //
          // 上报了页面配色的沉浸页（阅读器纸色、视频 / 串流黑底、漫画底色、
          // 歌词背景，见 [FushiTitleBarColorScope]）仍按「标题行实色 + 页面从
          // 标题行下沿开始」排：它们的 WebView 分页 / 画面几何按可见视口算，
          // 不能被标题行压住一截。两种排法只差页面的 top 偏移与 padding，
          // 子树结构恒定，不会重挂 Navigator。
          child: ValueListenableBuilder<FushiTitleBarColors?>(
            valueListenable: FushiDesktopTitleBar._pageColors,
            builder: (
              BuildContext context,
              FushiTitleBarColors? page,
              Widget? _,
            ) {
              final double caption =
                  hideFrame ? 0 : FushiDesktopTitleBar.height;
              final bool overlay = page == null;
              final double offset = overlay ? 0 : caption;
              final double inset = overlay ? caption : 0;
              return LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  // The caption no longer consumes layout height in overlay
                  // mode; the page gets the whole window plus a top inset. In
                  // offset mode, rebase the Navigator's MediaQuery to the
                  // remaining viewport so native WebViews paginate against
                  // their actual surface rather than clipping the last
                  // title-bar-height pixels.
                  final MediaQueryData mediaQuery = MediaQuery.of(context);
                  final Size size = Size(
                    constraints.maxWidth,
                    math.max(0, constraints.maxHeight - offset),
                  );
                  return Stack(
                    children: <Widget>[
                      Positioned(
                        top: offset,
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: MediaQuery(
                          data: mediaQuery.copyWith(
                            size: size,
                            padding: mediaQuery.padding.copyWith(
                              top: mediaQuery.padding.top + inset,
                            ),
                            viewPadding: mediaQuery.viewPadding.copyWith(
                              top: mediaQuery.viewPadding.top + inset,
                            ),
                          ),
                          child: widget.child,
                        ),
                      ),
                      if (!hideFrame)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: FushiDesktopTitleBar.height,
                          child: _buildCaptionRow(context, page, null),
                        ),
                    ],
                  );
                },
              );
            },
          ),
        );
        // Keep resize ownership in the same state machine as the caption.
        // VirtualWindowFrame maintains its own event-only maximized/fullscreen
        // cache, which is vulnerable to the same missing Windows leave event.
        // Fullscreen omits resize hit targets entirely; maximized windows keep
        // them disabled until the native state is explicitly re-read above.
        //
        // The wrapper widget type is invariant on purpose: swapping between
        // `frame` and `DragToResizeArea(child: frame)` makes
        // `Widget.canUpdate` false at this slot on every fullscreen flip, which
        // deactivates and re-inflates the whole subtree below — including the
        // keyless global-shortcut Focus node and the FushiFocusRoot controller,
        // so focus is lost on each F11 / media fullscreen toggle. State is
        // expressed through `enableResizeEdges` instead; an empty list makes
        // every edge a bare `Container()` with no gesture target, which is
        // exactly the zero-hit-area semantics the removed branch had.
        return DragToResizeArea(
          enableResizeEdges: _resizeEdges(hideFrame: hideFrame),
          child: frame,
        );
      },
    );
  }

  /// 顶栏本体。底色 / 前景优先取页面上报的 [FushiTitleBarColors]（阅读器纸色），
  /// 没有上报时用根主题——顶栏自己的 surface 填充不随 HDR 让开，只有下方页面区
  /// 才会透明。
  Widget _buildCaptionRow(
    BuildContext context,
    FushiTitleBarColors? page,
    Widget? _,
  ) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    // 标题行自带不透明底色、不听 hdrHostActiveGlobal：HDR 直通时下方页面区整层
    // 透明，标题行若跟着透就能看见后面的窗口。页面上报色可能带透明度，先叠到
    // surface 上再用——结果恒不透明，不靠上报方自觉。
    // 没有页面上报色 = 标题行浮在页面上、完全透明：页面背景（含详情页
    // fanart）从窗口顶端铺起，与下面的主界面是同一张，没有接缝。
    final Color captionFill = page == null
        ? Colors.transparent
        : Color.alphaBlend(page.background, colors.surface);
    // 窗口按钮按平台而不是按设计系统（用户 2026-10-04）：macOS 一律用系统原生
    // 红绿灯（左上角，顶栏只给它们留位），Windows / Linux 一律是 MD3 那组按钮。
    final bool trafficLights = Platform.isMacOS;
    return Container(
      height: FushiDesktopTitleBar.height,
      color: captionFill,
      // 页面上报了延伸背景（歌词模式）：在底色之上画同一张背景的顶部一截。
      child: Stack(
        fit: StackFit.expand,
        // 窗口按钮背后的柔光可以画出标题行（向下渐隐到 0），不裁。
        clipBehavior: Clip.none,
        children: <Widget>[
          // 透明标题行浮在页面背景（如详情页 fanart）上时，窗口按钮背后垫一团
          // 无硬边的柔光保证可读：右上角起的径向渐变，压扁成椭圆，边缘处
          // 不透明度已降到 0。只给 Windows 那组按钮（macOS 红绿灯是系统画的）。
          //
          // M3E 按钮组自己有一枚半透明 tonal 胶囊，柔光只负责让胶囊四周的
          // 背景过渡柔和、不出硬边：峰值比旧版低、渐隐半径更大，胶囊整枚落在
          // 最浓的那一段里。墨水屏不画（降级为胶囊描边，无填色）。
          if (page == null && !trafficLights && !isEinkTheme(context))
            Positioned(
              top: 0,
              right: 0,
              width: _kCaptionHaloExtent,
              height: _kCaptionHaloExtent,
              child: IgnorePointer(
                child: Transform(
                  alignment: Alignment.topRight,
                  transform: Matrix4.diagonal3Values(1, 0.26, 1),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.topRight,
                        radius: 1,
                        colors: <Color>[
                          colors.surface.withValues(alpha: 0.5),
                          colors.surface.withValues(alpha: 0.36),
                          colors.surface.withValues(alpha: 0.12),
                          colors.surface.withValues(alpha: 0),
                        ],
                        stops: const <double>[0, 0.42, 0.74, 1],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ValueListenableBuilder<FushiTitleBarBackdrop?>(
            valueListenable: FushiDesktopTitleBar._pageBackdrop,
            builder: (
              BuildContext context,
              FushiTitleBarBackdrop? backdrop,
              Widget? _,
            ) =>
                backdrop == null
                    ? const SizedBox.shrink()
                    : FushiTitleBarBackdropView(backdrop: backdrop),
          ),
          _buildCaptionControls(trafficLights, page),
        ],
      ),
    );
  }

  Widget _buildCaptionControls(bool trafficLights, FushiTitleBarColors? page) {
    return Row(
        children: <Widget>[
          // 系统红绿灯画在原生标题栏视图里，浮在这块留位之上。
          if (trafficLights) const SizedBox(width: _kTrafficLightsReserve),
          Expanded(
            child: DragToMoveArea(
              // 拖动区必须撑满整条标题栏高度：去掉标题文字后 Row 里只剩无高度的
              // 占位（SizedBox 宽 / Spacer），Row 会塌成 0 高，命中测试永远落不进
              // DragToMoveArea，顶栏就拖不动了（2026-10-04 用户报）。
              child: SizedBox.expand(
                child: Row(
                children: <Widget>[
                  SizedBox(
                    width: trafficLights
                        ? math.max(
                            0,
                            widget.leadingInset - _kTrafficLightsReserve,
                          )
                        : widget.leadingInset,
                  ),
                  // 顶部控制条只做拖动区 + 窗口按钮，不显示页面标题（用户
                  // 2026-10-04）；页面自己的大标题 / 顶栏负责标题。[title] 仍
                  // 保留在参数里，供无障碍窗口名等后续用途。
                  const Spacer(),
                ],
              ),
              ),
            ),
          ),
          if (!trafficLights) ...<Widget>[
          // M3E 窗口按钮组：三枚小号 standard 图标按钮收进一枚 tonal 胶囊；
          // 右缘与页面浮动页头的动作组同一条页边（[FushiSpacingTokens.page]），
          // 竖直方向在 32 高的标题行里居中。
          _FushiCaptionButtonGroup(
            page: page,
            active: _isFocused,
            children: <Widget>[
              _FushiCaptionButton(
                glyph: _CaptionGlyph.minimize,
                page: page,
                active: _isFocused,
                onPressed: _minimize,
              ),
              _FushiCaptionButton(
                glyph: _CaptionGlyph.maximize,
                maximized: _isMaximized,
                // 只有 Windows runner 认 HTMAXBUTTON 命中区（贴靠布局）。
                snapLayouts: Platform.isWindows,
                page: page,
                active: _isFocused,
                onPressed: _toggleMaximize,
              ),
              _FushiCaptionButton(
                key: FushiDesktopTitleBar.closeButtonKey,
                glyph: _CaptionGlyph.close,
                page: page,
                active: _isFocused,
                onPressed: _close,
              ),
            ],
          ),
          // 组右侧的页边留白仍是拖动区（右上角另有顶边 resize 把手）。
          DragToMoveArea(
            child: SizedBox(
              width: FushiDesignTokens.of(context).spacing.page,
              height: FushiDesktopTitleBar.height,
            ),
          ),
          ],
        ],
    );
  }

  /// 哪些边由 app 自己转发拖拽给原生「开始改变窗口大小」。
  ///
  /// macOS 恒为空表：`window_manager` 的 macOS 插件根本没有 `startResizing`
  /// （只有 Windows/Linux 实现），挂上去点一下就是 `MissingPluginException`；
  /// 而 AppKit 在 full-size content view 下仍然自己拥有窗口四边的 resize 边框，
  /// 本来就不需要 app 代劳。Windows 侧维持原状：全屏无命中区、最大化时禁用，
  /// 其余只接管顶边三段（左右下三边由 runner 的非客户区命中测试处理）。
  List<ResizeEdge> _resizeEdges({required bool hideFrame}) {
    if (Platform.isMacOS) return const <ResizeEdge>[];
    if (hideFrame || _isMaximized) return const <ResizeEdge>[];
    return const <ResizeEdge>[
      ResizeEdge.topLeft,
      ResizeEdge.top,
      ResizeEdge.topRight,
    ];
  }
}

/// 窗口按钮的字形（自绘，笔画粗细与圆角统一；最大化 / 还原之间做形变）。
enum _CaptionGlyph { minimize, maximize, close }

/// 按钮组几何（逻辑像素，与 [FushiDesktopTitleBar.height] 一样不随
/// [FushiAppUiScale] 缩放）：28 高的胶囊、24 高的按钮可视区，命中区撑满
/// 标题行的 32 高与按钮间距（桌面精确指针，小于 48 但没有命中死角）。
const double _kCaptionCapsuleHeight = 28;
const double _kCaptionButtonWidth = 36;
const double _kCaptionButtonHeight = 24;
const double _kCaptionButtonGap = 2;
const double _kCaptionGroupPadding = 2;
const double _kCaptionGlyphSize = 10;

/// M3E 窗口按钮组：一枚半透明 tonal 胶囊（与页面浮动页头的动作组同一种
/// 「胶囊里一排 standard 图标按钮」形态，只是压成标题行的高度）。
///
/// - 无页面上报色：共享 search 面色（MD3 = surfaceContainerHigh）半透明，浮在页面背景 + 柔光上；
/// - 页面上报色（阅读器纸色等）：从页面前景色派生一层极淡的色块，不引入
///   根主题的 surface（纸色与根主题明暗可能相反）；
/// - 窗口失焦：胶囊变淡（按钮前景同步降低不透明度，见 [_FushiCaptionButton]）；
/// - 墨水屏：无填色，一圈 outline 描边。
class _FushiCaptionButtonGroup extends StatelessWidget {
  const _FushiCaptionButtonGroup({
    required this.page,
    required this.active,
    required this.children,
  });

  final FushiTitleBarColors? page;
  final bool active;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final FushiSpringSpec effects = context.fushiMotion.effectsDefault;
    final Color? pageForeground = page?.foreground;
    final Color fill;
    if (eink) {
      fill = Colors.transparent;
    } else if (pageForeground != null) {
      fill = pageForeground.withValues(
        alpha: pageForeground.a * (active ? 0.08 : 0.04),
      );
    } else {
      fill = FushiDesignTokens.of(
        context,
      ).surfaces.search.withValues(alpha: active ? 0.72 : 0.48);
    }
    final BorderSide side = eink
        ? BorderSide(color: pageForeground ?? cs.outline)
        : BorderSide.none;
    const double inset =
        (FushiDesktopTitleBar.height - _kCaptionCapsuleHeight) / 2;
    return FocusTraversalGroup(
      child: SizedBox(
        height: FushiDesktopTitleBar.height,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Positioned.fill(
              top: inset,
              bottom: inset,
              child: IgnorePointer(
                child: AnimatedContainer(
                  duration: effects.duration,
                  curve: effects.curve,
                  decoration: ShapeDecoration(
                    color: fill,
                    shape: StadiumBorder(side: side),
                  ),
                ),
              ),
            ),
            Padding(
              // 按钮命中区各自带半个间距，组内边距补齐到 [_kCaptionGroupPadding]。
              padding: const EdgeInsets.symmetric(
                horizontal: _kCaptionGroupPadding - _kCaptionButtonGap / 2,
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: children),
            ),
          ],
        ),
      ),
    );
  }
}

/// 组内的一枚 M3E 小号 standard 图标按钮。
///
/// 自绘而不是 [FushiIconButtonControl]：最大化按钮在 Windows 上把命中交给
/// 原生 HTMAXBUTTON（贴靠布局），那时 Flutter 收不到指针，悬停 / 按下态要由
/// 原生回传（[WindowCaptionChannel.captionMaxButtonHovered] / `Pressed`）
/// 注入——按钮组件不开放这一层状态。
///
/// 状态：悬停 / 键盘焦点 = 前景色状态层（[FushiStateLayer]）；按下 = 形状
/// 从全圆收到小圆角并轻微缩小（M3E 按压形变，spatial 弹簧回弹）；关闭按钮
/// 悬停 / 按下 = errorContainer / onErrorContainer（不用刺眼的纯红）。墨水屏
/// 不填色，悬停只描边；减弱动态效果 / 墨水屏下全部瞬间到位。
class _FushiCaptionButton extends StatefulWidget {
  const _FushiCaptionButton({
    required this.glyph,
    required this.page,
    required this.active,
    required this.onPressed,
    this.maximized = false,
    this.snapLayouts = false,
    super.key,
  });

  final _CaptionGlyph glyph;

  /// 页面上报色；null = 根主题 token。前景与状态层都从它派生。
  final FushiTitleBarColors? page;

  /// 窗口在前台。失焦时前景降不透明度。
  final bool active;
  final VoidCallback onPressed;

  /// 仅 [_CaptionGlyph.maximize]：窗口当前已最大化（字形形变为「还原」）。
  final bool maximized;

  /// 把本按钮的命中区报给 Windows runner 做 HTMAXBUTTON（贴靠布局）。
  final bool snapLayouts;

  @override
  State<_FushiCaptionButton> createState() => _FushiCaptionButtonState();
}

class _FushiCaptionButtonState extends State<_FushiCaptionButton> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focusHighlight = false;

  @override
  void initState() {
    super.initState();
    if (widget.snapLayouts) _listenNative();
  }

  @override
  void didUpdateWidget(_FushiCaptionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapLayouts == widget.snapLayouts) return;
    if (widget.snapLayouts) {
      _listenNative();
    } else {
      _unlistenNative();
    }
  }

  @override
  void dispose() {
    if (widget.snapLayouts) _unlistenNative();
    super.dispose();
  }

  void _listenNative() {
    WindowCaptionChannel.captionMaxButtonHovered.addListener(_onNativeState);
    WindowCaptionChannel.captionMaxButtonPressed.addListener(_onNativeState);
  }

  void _unlistenNative() {
    WindowCaptionChannel.captionMaxButtonHovered.removeListener(
      _onNativeState,
    );
    WindowCaptionChannel.captionMaxButtonPressed.removeListener(
      _onNativeState,
    );
  }

  void _onNativeState() {
    if (mounted) setState(() {});
  }

  bool get _isHovered =>
      _hovered ||
      (widget.snapLayouts &&
          WindowCaptionChannel.captionMaxButtonHovered.value);

  bool get _isPressed =>
      _pressed ||
      (widget.snapLayouts &&
          WindowCaptionChannel.captionMaxButtonPressed.value);

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  String? _semanticLabel(BuildContext context) {
    if (widget.glyph != _CaptionGlyph.close) return null;
    return Localizations.of<MaterialLocalizations>(
      context,
      MaterialLocalizations,
    )?.closeButtonTooltip;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final FushiMotionScheme motion = context.fushiMotion;
    final bool hovered = _isHovered;
    final bool pressed = _isPressed;
    final bool isClose = widget.glyph == _CaptionGlyph.close;
    final Color? pageForeground = widget.page?.foreground;
    final Color rest = pageForeground ?? cs.onSurfaceVariant;
    final Color emphasis = pageForeground ?? cs.onSurface;

    Color foreground = widget.active
        ? rest
        : rest.withValues(alpha: rest.a * 0.55);
    Color background = Colors.transparent;
    BorderSide side = BorderSide.none;
    if (isClose && (hovered || pressed)) {
      if (eink) {
        foreground = cs.error;
        side = BorderSide(color: cs.error, width: 1.5);
      } else {
        foreground = cs.onErrorContainer;
        background = pressed
            ? Color.alphaBlend(
                cs.onErrorContainer.withValues(alpha: FushiStateLayer.pressed),
                cs.errorContainer,
              )
            : cs.errorContainer;
      }
    } else if (hovered || pressed || _focusHighlight) {
      foreground = emphasis;
      if (eink) {
        side = BorderSide(color: pageForeground ?? cs.outline);
      } else {
        final double layer = pressed
            ? FushiStateLayer.hover + FushiStateLayer.pressed
            : hovered
            ? FushiStateLayer.hover
            : FushiStateLayer.focus;
        background = emphasis.withValues(alpha: emphasis.a * layer);
      }
    }
    if (_focusHighlight && !eink) {
      side = BorderSide(color: cs.secondary, width: 2);
    }

    final Widget glyph = TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: foreground),
      duration: motion.effectsFast.duration,
      curve: motion.effectsFast.curve,
      builder: (BuildContext context, Color? color, Widget? _) =>
          TweenAnimationBuilder<double>(
            tween: Tween<double>(end: widget.maximized ? 1 : 0),
            duration: motion.spatialDefault.duration,
            curve: motion.spatialDefault.curve,
            builder: (BuildContext context, double restore, Widget? _) =>
                CustomPaint(
                  size: const Size.square(_kCaptionGlyphSize),
                  painter: _CaptionGlyphPainter(
                    glyph: widget.glyph,
                    restore: restore,
                    color: color ?? foreground,
                  ),
                ),
          ),
    );

    final Widget visual = AnimatedScale(
      scale: pressed ? 0.9 : 1,
      duration: motion.spatialFast.duration,
      curve: motion.spatialFast.curve,
      child: AnimatedContainer(
        width: _kCaptionButtonWidth,
        height: _kCaptionButtonHeight,
        duration: motion.effectsFast.duration,
        curve: motion.effectsFast.curve,
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: background,
          shape: RoundedRectangleBorder(
            // 静止全圆（24 高 → 半径 12），按下收到 6：M3E 按压形状形变。
            borderRadius: BorderRadius.circular(
              pressed ? 6 : _kCaptionButtonHeight / 2,
            ),
            side: side,
          ),
        ),
        child: glyph,
      ),
    );

    Widget target = SizedBox(
      width: _kCaptionButtonWidth + _kCaptionButtonGap,
      height: FushiDesktopTitleBar.height,
      child: Center(child: visual),
    );
    if (widget.snapLayouts) {
      target = _CaptionSnapTarget(
        devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
        child: target,
      );
    }

    return Semantics(
      button: true,
      label: _semanticLabel(context),
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.basic,
        onShowFocusHighlight: (bool value) {
          if (_focusHighlight != value) {
            setState(() => _focusHighlight = value);
          }
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (ActivateIntent _) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() {
            _hovered = false;
            _pressed = false;
          }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => _setPressed(true),
            onTapUp: (_) => _setPressed(false),
            onTapCancel: () => _setPressed(false),
            onTap: widget.onPressed,
            child: target,
          ),
        ),
      ),
    );
  }
}

/// 窗口按钮字形：10×10 逻辑像素、统一笔画与圆角端点。
///
/// 最大化 ↔ 还原是一次形变而不是换图标：[restore] 从 0 到 1 时，前方方块
/// 缩小并沉到左下，后方方块从同一位置滑向右上、淡入，被前方方块挡住的那段
/// 不画（与系统「还原」字形同构）。[restore] 可能因 spatial 弹簧略超出
/// 0..1，几何照用（回弹），透明度夹回 0..1。
class _CaptionGlyphPainter extends CustomPainter {
  const _CaptionGlyphPainter({
    required this.glyph,
    required this.restore,
    required this.color,
  });

  final _CaptionGlyph glyph;
  final double restore;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide;
    const double strokeWidth = 1.25;
    const double i = strokeWidth / 2;
    Paint stroke(Color c) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = c;
    switch (glyph) {
      case _CaptionGlyph.minimize:
        canvas.drawLine(Offset(i, s / 2), Offset(s - i, s / 2), stroke(color));
      case _CaptionGlyph.close:
        // X 的对角线视觉上比横线 / 方块大，向内收 0.5。
        _paintClose(canvas, s, i + 0.5, stroke(color));
      case _CaptionGlyph.maximize:
        _paintMaximize(canvas, s, i, strokeWidth, stroke);
    }
  }

  void _paintClose(Canvas canvas, double s, double x, Paint paint) {
    canvas.drawLine(Offset(x, x), Offset(s - x, s - x), paint);
    canvas.drawLine(Offset(s - x, x), Offset(x, s - x), paint);
  }

  void _paintMaximize(
    Canvas canvas,
    double s,
    double i,
    double strokeWidth,
    Paint Function(Color) stroke,
  ) {
    final double t = restore;
    final double offset = s * 0.22 * t;
    final Radius radius = Radius.circular(
      2.6 - 0.6 * t.clamp(0.0, 1.0).toDouble(),
    );
    final Rect front = Rect.fromLTRB(i, i + offset, s - i - offset, s - i);
    final double backAlpha = t.clamp(0.0, 1.0).toDouble();
    if (backAlpha > 0) {
      final Rect back = front.shift(Offset(offset, -offset));
      canvas.save();
      canvas.clipPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(Rect.fromLTWH(-s, -s, s * 3, s * 3))
          ..addRRect(
            RRect.fromRectAndRadius(
              front.inflate(strokeWidth),
              radius + Radius.circular(strokeWidth),
            ),
          ),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(back, radius),
        stroke(color.withValues(alpha: color.a * backAlpha)),
      );
      canvas.restore();
    }
    canvas.drawRRect(RRect.fromRectAndRadius(front, radius), stroke(color));
  }

  @override
  bool shouldRepaint(_CaptionGlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph ||
      oldDelegate.restore != restore ||
      oldDelegate.color != color;
}

/// 把子树在 Flutter 视图里的矩形（物理像素）报给 Windows runner，作为
/// HTMAXBUTTON 命中区（Windows 11 贴靠布局，见 `caption_snap_button.h`）。
///
/// 每次绘制后（布局 / 窗口尺寸 / 缩放变化都会触发重绘）在帧尾取一次全局
/// 矩形，同值由 [WindowCaptionChannel.setCaptionMaxButtonRect] 去重；卸载
/// （顶栏收起、内容全屏）时撤销命中区。
class _CaptionSnapTarget extends SingleChildRenderObjectWidget {
  const _CaptionSnapTarget({
    required this.devicePixelRatio,
    required super.child,
  });

  final double devicePixelRatio;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCaptionSnapTarget(devicePixelRatio: devicePixelRatio);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCaptionSnapTarget renderObject,
  ) {
    renderObject.devicePixelRatio = devicePixelRatio;
  }
}

class _RenderCaptionSnapTarget extends RenderProxyBox {
  _RenderCaptionSnapTarget({required double devicePixelRatio})
    : _devicePixelRatio = devicePixelRatio;

  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  bool _reportScheduled = false;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (_reportScheduled) return;
    _reportScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _reportScheduled = false;
      if (!attached || !hasSize) return;
      final Rect logical = MatrixUtils.transformRect(
        getTransformTo(null),
        Offset.zero & size,
      );
      final double dpr = _devicePixelRatio;
      unawaited(
        WindowCaptionChannel.setCaptionMaxButtonRect(
          Rect.fromLTRB(
            logical.left * dpr,
            logical.top * dpr,
            logical.right * dpr,
            logical.bottom * dpr,
          ),
        ),
      );
    });
  }

  @override
  void detach() {
    super.detach();
    // 撤销放到帧尾：detach 发生在构建期，此刻改原生悬停态的 notifier 会在
    // 构建中标脏别的按钮；同一帧里若又挂回来（换父节点），绘制那次的上报
    // 也在帧尾，以那次为准。
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (attached) return;
      unawaited(WindowCaptionChannel.setCaptionMaxButtonRect(null));
    });
  }
}

/// 页面上报给桌面顶栏的配色：底色 + 标题 / 窗口按钮的前景色。
typedef FushiTitleBarColors = ({Color background, Color foreground});

/// 延伸到顶栏底下的页面背景。[canvas] 是页面画背景用的整张画布（页面尺寸 +
/// 顶栏高度，顶栏占它最上面一截）；[builder] 画这张画布（顶栏与页面各画同一张
/// 画布的一截，像素才连续）；[revision] 在背景外观变化（换主题 / 换封面）时换值，
/// 让顶栏重画——构建函数通常是同一个 tear-off，不变。
typedef FushiTitleBarBackdrop = ({
  Size canvas,
  WidgetBuilder builder,
  Object? revision,
});

/// 在顶栏里画页面背景的顶部一截：画布顶对齐、超出部分裁掉；不吃指针、不进
/// 语义树。公开给测试与页面侧对照。
class FushiTitleBarBackdropView extends StatelessWidget {
  const FushiTitleBarBackdropView({required this.backdrop, super.key});

  final FushiTitleBarBackdrop backdrop;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minWidth: backdrop.canvas.width,
            maxWidth: backdrop.canvas.width,
            minHeight: backdrop.canvas.height,
            maxHeight: backdrop.canvas.height,
            child: RepaintBoundary(child: Builder(builder: backdrop.builder)),
          ),
        ),
      ),
    );
  }
}

/// 只有底色、没有配套前景色的页面（视频黑底、串流黑底、漫画固定底色）用它
/// 上报：窗口按钮按底色明暗取半透明白 / 黑，与 MD3 onSurfaceVariant 同一观感。
FushiTitleBarColors fushiTitleBarColorsOn(Color background) => (
  background: background,
  foreground:
      ThemeData.estimateBrightnessForColor(background) == Brightness.dark
      ? Colors.white70
      : Colors.black54,
);

/// 让桌面顶栏跟随本页底色（[FushiDesktopTitleBar.setPageColors] 的唯一推荐入口）。
///
/// 只在本页是「最上面那一整页」时生效：本页路由被另一个整页（PageRoute）盖住
/// 时，它的 `secondaryAnimation` 离开 dismissed——此刻撤回，顶栏回落到根主题，
/// 盖上来的页面自己决定颜色；弹窗 / 底部面板不是 PageRoute，不推动这条动画，
/// 所以打开它们顶栏不会闪色。离开树时撤回。
///
/// 没有挂自绘顶栏（移动端、Linux）时上报无人消费，零副作用。
///
/// [colors] 为 null = 本页此刻不表态（撤回，顶栏回落到根主题或其它上报方）：
/// 页面顶部颜色随状态变化（MD3 顶栏滚动后换色、视频加载完才变黑）时，用它
/// 表达「这一刻页面顶部就是根主题 surface」，而不必按状态增删这一层包装。
class FushiTitleBarColorScope extends StatefulWidget {
  const FushiTitleBarColorScope({
    required this.colors,
    required this.child,
    this.backdrop,
    super.key,
  });

  final FushiTitleBarColors? colors;

  /// 延伸到顶栏底下的页面背景（歌词模式）；null = 顶栏只铺 [colors] 底色。
  /// 撤回时机与 [colors] 相同（被整页盖住 / dispose）。
  final FushiTitleBarBackdrop? backdrop;
  final Widget child;

  @override
  State<FushiTitleBarColorScope> createState() =>
      _FushiTitleBarColorScopeState();
}

class _FushiTitleBarColorScopeState extends State<FushiTitleBarColorScope> {
  Animation<double>? _coverAnimation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Animation<double>? next = ModalRoute.of(context)?.secondaryAnimation;
    if (identical(next, _coverAnimation)) return;
    _coverAnimation?.removeStatusListener(_onCoverStatus);
    _coverAnimation = next;
    _coverAnimation?.addStatusListener(_onCoverStatus);
  }

  void _onCoverStatus(AnimationStatus _) => _publish();

  bool get _covered =>
      (_coverAnimation?.status ?? AnimationStatus.dismissed) !=
      AnimationStatus.dismissed;

  void _publish() {
    final bool covered = _covered;
    FushiDesktopTitleBar.setPageColors(
      owner: this,
      colors: covered ? null : widget.colors,
    );
    FushiDesktopTitleBar.setPageBackdrop(
      owner: this,
      backdrop: covered ? null : widget.backdrop,
    );
  }

  @override
  void dispose() {
    _coverAnimation?.removeStatusListener(_onCoverStatus);
    FushiDesktopTitleBar.setPageColors(owner: this, colors: null);
    FushiDesktopTitleBar.setPageBackdrop(owner: this, backdrop: null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _publish();
    return widget.child;
  }
}

/// 透明标题行上窗口按钮背后柔光的半径（压扁前；见 [_buildCaptionRow]）。
const double _kCaptionHaloExtent = 280;

/// macOS 系统红绿灯占位宽度（三枚按钮 + 左右边距，与 AppKit 标准标题栏一致）。
const double _kTrafficLightsReserve = 78;
