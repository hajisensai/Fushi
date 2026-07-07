import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

export 'package:fluttertoast/fluttertoast.dart' show Toast, ToastGravity;

/// TODO-1325 #6: 制卡结果 toast 的语义状态。决定 MD3 toast 的着色与 Material 图标，
/// 让「加入了 / 已存在 / 失败 / 制卡中」一眼可辨，而不再只靠弹窗里 mine 按钮的图标变化。
enum MineToastStatus { added, duplicate, failed, pending }

/// 把 [MineToastStatus] 映射成 toast 的 (背景色, 前景色, 图标)。用固定 Material 色阶
/// （绿/橙/红/蓝）而非主题取色，保证四态在任意主题下都语义清晰、对比达标；也让无
/// BuildContext 的降级路径（独立弹窗 Activity）能直接复用同一配色。
({Color background, Color foreground, IconData icon}) mineToastPalette(
  MineToastStatus status,
) {
  switch (status) {
    case MineToastStatus.added:
      return (
        background: const Color(0xFF2E7D32), // green 800
        foreground: Colors.white,
        icon: Icons.check_circle_rounded,
      );
    case MineToastStatus.duplicate:
      return (
        background: const Color(0xFFEF6C00), // orange 800
        foreground: Colors.white,
        icon: Icons.library_add_check_rounded,
      );
    case MineToastStatus.failed:
      return (
        background: const Color(0xFFC62828), // red 800
        foreground: Colors.white,
        icon: Icons.error_rounded,
      );
    case MineToastStatus.pending:
      return (
        background: const Color(0xFF1565C0), // blue 800
        foreground: Colors.white,
        icon: Icons.sync_rounded,
      );
  }
}

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

  /// TODO-1325 #6: 制卡结果的 MD3 着色 + 图标 toast。挂在 dictionary_page_mixin 的
  /// onMine 回调之后：按 [status] 着色（added 绿 / duplicate 橙 / failed 红 /
  /// pending 蓝）并配 Material 图标。有 navigator overlay（主 app，桌面与移动）时走
  /// 自绘 overlay（图标 + 颜色齐全，且会顶替上一条，让 pending → 结果自然过渡）；
  /// 无 overlay 的独立弹窗 Activity 降级为原生着色 toast（无图标但仍着色，绝不静默）。
  static void showMine({
    required String msg,
    required MineToastStatus status,
  }) {
    final overlay = _toastNavigatorKey?.currentState?.overlay;
    if (overlay != null) {
      _showMineOverlay(overlay: overlay, msg: msg, status: status);
      return;
    }
    // pending 是过渡态（只有能被结果 toast 顶替时才有意义）。无 overlay 的降级路径
    // 用的是会排队的原生 toast，若也弹 pending 会把「制卡中…」卡在结果之前，故跳过。
    if (status == MineToastStatus.pending) return;
    final palette = mineToastPalette(status);
    show(
      msg: msg,
      backgroundColor: palette.background,
      textColor: palette.foreground,
    );
  }

  static void _showMineOverlay({
    required OverlayState overlay,
    required String msg,
    required MineToastStatus status,
  }) {
    _dismissTimer?.cancel();
    _currentEntry?.remove();
    _currentEntry = null;

    final entry = OverlayEntry(
      builder: (context) => _MineToastWidget(msg: msg, status: status),
    );
    _currentEntry = entry;
    overlay.insert(entry);

    // pending 停留更久（等制卡结果覆盖它），结果 toast 用短时长。
    final int durationMs = status == MineToastStatus.pending ? 4000 : 2400;
    _dismissTimer = Timer(Duration(milliseconds: durationMs), () {
      entry.remove();
      if (_currentEntry == entry) _currentEntry = null;
    });
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
    final tokens = HibikiDesignTokens.of(context);
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
                borderRadius: tokens.radii.controlRadius,
              ),
              child: Text(
                widget.msg,
                textAlign: TextAlign.center,
                style: tokens.type.controlLabel.copyWith(
                  color: widget.textColor ?? theme.colorScheme.onInverseSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// TODO-1325 #6: 制卡结果 toast 的自绘 MD3 组件——一张圆角卡片，左侧状态图标 + 文案，
/// 整体用状态色填充、白色前景，淡入呈现。与 [_DesktopToastWidget] 同一定位/动画骨架，
/// 但多了图标与语义色（added/duplicate/failed/pending）。
class _MineToastWidget extends StatefulWidget {
  const _MineToastWidget({required this.msg, required this.status});

  final String msg;
  final MineToastStatus status;

  @override
  State<_MineToastWidget> createState() => _MineToastWidgetState();
}

class _MineToastWidgetState extends State<_MineToastWidget>
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
    final tokens = HibikiDesignTokens.of(context);
    final ({Color background, Color foreground, IconData icon}) palette =
        mineToastPalette(widget.status);
    return Positioned(
      bottom: 50,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: FadeTransition(
            opacity: _opacity,
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 420),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: palette.background,
                  borderRadius: tokens.radii.controlRadius,
                  boxShadow: const <BoxShadow>[
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(palette.icon, color: palette.foreground, size: 20),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        widget.msg,
                        style: tokens.type.controlLabel.copyWith(
                          color: palette.foreground,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
