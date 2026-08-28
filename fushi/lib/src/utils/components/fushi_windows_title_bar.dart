import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// App-themed Windows frame used after the native caption is hidden.
///
/// The frame keeps resizing, dragging, double-click maximize/restore and the
/// existing intercepted close lifecycle, while avoiding Win32 caption chrome.
class FushiWindowsTitleBar extends StatefulWidget {
  const FushiWindowsTitleBar({
    required this.title,
    required this.child,
    this.leadingInset = 0,
    super.key,
  });

  /// Keep the app frame as compact as the native Windows caption it replaces.
  /// This is intentionally outside [FushiAppUiScale], so the window controls do
  /// not grow with content zoom.
  static const double height = 32;

  /// Set only after Windows accepts [TitleBarStyle.hidden]. Widgets below the
  /// app frame use this to avoid rendering a second, redundant page header.
  static bool isEnabled = false;

  /// Fullscreen surfaces that do not flow through `window_manager` (notably
  /// media_kit on Windows) acquire an owner here while they directly manipulate
  /// the HWND. Owner semantics prevent one surface from restoring the frame
  /// while another fullscreen surface is still active.
  static final Set<Object> _contentFullscreenOwners = <Object>{};
  static final Object _windowManagerFullscreenOwner = Object();
  static final ValueNotifier<bool> _contentFullscreen =
      ValueNotifier<bool>(false);

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
  State<FushiWindowsTitleBar> createState() => _FushiWindowsTitleBarState();
}

class _FushiWindowsTitleBarState extends State<FushiWindowsTitleBar>
    with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_readInitialWindowState());
  }

  Future<void> _readInitialWindowState() async {
    try {
      final List<bool> state = await Future.wait<bool>(<Future<bool>>[
        windowManager.isMaximized(),
        windowManager.isFullScreen(),
      ]);
      if (!mounted) return;
      FushiWindowsTitleBar.setWindowManagerFullscreen(state[1]);
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
    FushiWindowsTitleBar.setWindowManagerFullscreen(true);
  }

  @override
  void onWindowLeaveFullScreen() {
    FushiWindowsTitleBar.setWindowManagerFullscreen(false);
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
      valueListenable: FushiWindowsTitleBar._contentFullscreen,
      builder: (BuildContext context, bool contentFullscreen, Widget? child) {
        final bool hideFrame = contentFullscreen;
        final Widget frame = ColoredBox(
          color: colors.surface,
          child: Column(
            // The frame is always wrapped in DragToResizeArea's Stack, which
            // hands its non-positioned child loose constraints. Stretch makes
            // the cross axis tight regardless, so hiding the caption row cannot
            // change how wide the page below lays out.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (!hideFrame)
                SizedBox(
                  height: FushiWindowsTitleBar.height,
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
                  builder: (
                    BuildContext context,
                    BoxConstraints constraints,
                  ) {
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
          enableResizeEdges: (hideFrame || _isMaximized)
              ? const <ResizeEdge>[]
              : const <ResizeEdge>[
                  ResizeEdge.topLeft,
                  ResizeEdge.top,
                  ResizeEdge.topRight,
                ],
          child: frame,
        );
      },
    );
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
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          foregroundColor: WidgetStateProperty.resolveWith<Color>((states) {
            if (isClose && states.contains(WidgetState.hovered)) {
              return colors.onError;
            }
            return colors.onSurfaceVariant;
          }),
          backgroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
            if (isClose && states.contains(WidgetState.hovered)) {
              return colors.error;
            }
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)) {
              return colors.surfaceContainerHighest;
            }
            return Colors.transparent;
          }),
          overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        ),
      ),
    );
  }
}
