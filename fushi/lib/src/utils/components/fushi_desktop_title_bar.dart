import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:fushi/src/media/video/video_hdr_output.dart'
    show hdrHostActiveGlobal;
import 'package:fushi/src/platform/desktop/macos_traffic_lights.dart';
import 'package:fushi/src/platform/macos_fullscreen_state.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
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

  final Widget title;
  final Widget child;
  final double leadingInset;

  @override
  State<FushiDesktopTitleBar> createState() => _FushiDesktopTitleBarState();
}

class _FushiDesktopTitleBarState extends State<FushiDesktopTitleBar>
    with WindowListener {
  bool _isMaximized = false;

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
      unawaited(setMacOSTrafficLightsHidden(true));
    }
  }

  Future<void> _readInitialWindowState() async {
    try {
      final List<bool> state = await Future.wait<bool>(<Future<bool>>[
        windowManager.isMaximized(),
        windowManager.isFullScreen(),
      ]);
      if (!mounted) return;
      FushiDesktopTitleBar.setWindowManagerFullscreen(state[1]);
      setState(() {
        _isMaximized = state[0];
      });
    } catch (error) {
      debugPrint('[Fushi] failed to read initial window state: $error');
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
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
          child: Column(
            // The frame is always wrapped in DragToResizeArea's Stack, which
            // hands its non-positioned child loose constraints. Stretch makes
            // the cross axis tight regardless, so hiding the caption row cannot
            // change how wide the page below lays out.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (!hideFrame)
                Container(
                  height: FushiDesktopTitleBar.height,
                  // The caption row keeps its own surface fill: only the page
                  // area below may go transparent for HDR passthrough.
                  color: colors.surface,
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: DragToMoveArea(
                          child: Row(
                            children: <Widget>[
                              SizedBox(width: widget.leadingInset),
                              Expanded(
                                child: Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: Padding(
                                    padding: const EdgeInsetsDirectional.only(
                                      start: 16,
                                    ),
                                    child: DefaultTextStyle(
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall!
                                          .copyWith(
                                            color: colors.onSurface,
                                            fontWeight: FontWeight.w600,
                                          ),
                                      child: widget.title,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      _FushiCaptionButton(
                        icon: Icons.remove_rounded,
                        onPressed: _minimize,
                      ),
                      _FushiCaptionButton(
                        icon: _isMaximized
                            ? Icons.filter_none_rounded
                            : Icons.crop_square_rounded,
                        onPressed: _toggleMaximize,
                      ),
                      _FushiCaptionButton(
                        icon: Icons.close_rounded,
                        isClose: true,
                        onPressed: _close,
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
              Expanded(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    // The title bar consumes real layout height. Rebase the
                    // Navigator's MediaQuery to the remaining viewport so
                    // native WebViews paginate against their actual surface,
                    // rather than clipping the last title-bar-height pixels.
                    final MediaQueryData mediaQuery = MediaQuery.of(context);
                    return MediaQuery(
                      data: mediaQuery.copyWith(size: constraints.biggest),
                      child: widget.child,
                    );
                  },
                ),
              ),
            ],
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

class _FushiCaptionButton extends StatelessWidget {
  const _FushiCaptionButton({
    required this.icon,
    required this.onPressed,
    this.isClose = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final bool isClose;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(Size(40, 28)),
          maximumSize: const WidgetStatePropertyAll<Size>(Size(40, 28)),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.zero,
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(borderRadius: tokens.radii.chipRadius),
          ),
          foregroundColor: WidgetStateProperty.resolveWith<Color>((states) {
            if (isClose && states.contains(WidgetState.hovered)) {
              return colors.onError;
            }
            return tokens.surfaces.onVariant;
          }),
          backgroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
            if (isClose && states.contains(WidgetState.hovered)) {
              return colors.error;
            }
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)) {
              return tokens.surfaces.overlay;
            }
            return Colors.transparent;
          }),
          overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        ),
      ),
    );
  }
}
