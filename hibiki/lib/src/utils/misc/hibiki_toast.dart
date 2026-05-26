import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';

export 'package:fluttertoast/fluttertoast.dart' show Toast, ToastGravity;

/// Global navigator key used by the desktop toast overlay.
/// Must be assigned to the MaterialApp's navigatorKey.
GlobalKey<NavigatorState>? _toastNavigatorKey;

/// Cross-platform toast that uses native Fluttertoast on mobile
/// and an overlay-based widget on desktop.
abstract final class HibikiToast {
  /// Assign the app's navigator key so desktop toasts can find the overlay.
  static set navigatorKey(GlobalKey<NavigatorState> key) =>
      _toastNavigatorKey = key;

  static void show({
    required String msg,
    Toast toastLength = Toast.LENGTH_SHORT,
    ToastGravity gravity = ToastGravity.BOTTOM,
    Color? backgroundColor,
    Color? textColor,
  }) {
    if (Platform.isAndroid || Platform.isIOS) {
      Fluttertoast.showToast(
        msg: msg,
        toastLength: toastLength,
        gravity: gravity,
        backgroundColor: backgroundColor,
        textColor: textColor,
      );
      return;
    }
    _showDesktopToast(
      msg: msg,
      durationMs: toastLength == Toast.LENGTH_LONG ? 3500 : 2000,
      backgroundColor: backgroundColor,
      textColor: textColor,
    );
  }

  static OverlayEntry? _currentEntry;
  static Timer? _dismissTimer;

  static void _showDesktopToast({
    required String msg,
    required int durationMs,
    Color? backgroundColor,
    Color? textColor,
  }) {
    final overlay = _toastNavigatorKey?.currentState?.overlay;
    if (overlay == null) return;

    _dismissTimer?.cancel();
    _currentEntry?.remove();
    _currentEntry = null;

    final entry = OverlayEntry(
      builder: (context) => _DesktopToastWidget(
        msg: msg,
        backgroundColor: backgroundColor,
        textColor: textColor,
      ),
    );
    _currentEntry = entry;
    overlay.insert(entry);

    _dismissTimer = Timer(Duration(milliseconds: durationMs), () {
      entry.remove();
      if (_currentEntry == entry) _currentEntry = null;
    });
  }
}

class _DesktopToastWidget extends StatefulWidget {
  const _DesktopToastWidget({
    required this.msg,
    this.backgroundColor,
    this.textColor,
  });
  final String msg;
  final Color? backgroundColor;
  final Color? textColor;

  @override
  State<_DesktopToastWidget> createState() => _DesktopToastWidgetState();
}

class _DesktopToastWidgetState extends State<_DesktopToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned(
      bottom: 50,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: FadeTransition(
            opacity: _opacity,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 400),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color:
                    widget.backgroundColor ?? theme.colorScheme.inverseSurface,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Text(
                widget.msg,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: widget.textColor ?? theme.colorScheme.onInverseSurface,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
