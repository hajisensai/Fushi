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

  static const double height = 52;

  /// Set only after Windows accepts [TitleBarStyle.hidden]. Widgets below the
  /// app frame use this to avoid rendering a second, redundant page header.
  static bool isEnabled = false;

  final Widget title;
  final Widget child;
  final double leadingInset;

  @override
  State<FushiWindowsTitleBar> createState() => _FushiWindowsTitleBarState();
}

class _FushiWindowsTitleBarState extends State<FushiWindowsTitleBar>
    with WindowListener {
  bool _isMaximized = false;
  bool _isFullScreen = false;

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
      setState(() {
        _isMaximized = state[0];
        _isFullScreen = state[1];
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
    setState(() => _isFullScreen = true);
  }

  @override
  void onWindowLeaveFullScreen() {
    setState(() => _isFullScreen = false);
  }

  void _minimize() {
    unawaited(windowManager.minimize());
  }

  void _toggleMaximize() {
    if (_isMaximized) {
      unawaited(windowManager.unmaximize());
    } else {
      unawaited(windowManager.maximize());
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
    return VirtualWindowFrame(
      child: ColoredBox(
        color: colors.surface,
        child: Column(
          children: <Widget>[
            if (!_isFullScreen)
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
                                    start: 24,
                                  ),
                                  child: DefaultTextStyle(
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge!
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
                    const SizedBox(width: 6),
                  ],
                ),
              ),
            Expanded(child: widget.child),
          ],
        ),
      ),
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
        icon: Icon(icon, size: 20),
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(Size(40, 40)),
          maximumSize: const WidgetStatePropertyAll<Size>(Size(40, 40)),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.zero,
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
