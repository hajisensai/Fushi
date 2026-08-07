import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:fushi/src/utils/components/hibiki_design_tokens.dart';
import 'package:fushi/src/utils/misc/toast_severity.dart';

export 'package:fluttertoast/fluttertoast.dart' show Toast, ToastGravity;
// 语义与调色板住在 toast_severity.dart（视频页 OSD 也用，见该文件头注释），
// 这里再导出一次，让既有 `import hibiki_toast.dart` 的调用点无需改 import。
export 'package:fushi/src/utils/misc/toast_severity.dart';

/// Global navigator key used by the desktop toast overlay.
/// Must be assigned to the MaterialApp's navigatorKey.
GlobalKey<NavigatorState>? _toastNavigatorKey;

/// Cross-platform toast that uses native Fluttertoast on mobile
/// and an overlay-based widget on desktop.
abstract final class FushiToast {
  /// Assign the app's navigator key so desktop toasts can find the overlay.
  static set navigatorKey(GlobalKey<NavigatorState> key) =>
      _toastNavigatorKey = key;

  /// [severity] 决定配色与图标（见 [ToastSeverity]）。显式传 [backgroundColor] /
  /// [textColor] 仍然优先——少数调用点（如 tag chip 透传自身颜色）不是语义着色。
  static void show({
    required String msg,
    Toast toastLength = Toast.LENGTH_SHORT,
    ToastGravity gravity = ToastGravity.BOTTOM,
    Color? backgroundColor,
    Color? textColor,
    ToastSeverity severity = ToastSeverity.neutral,
  }) {
    final ({Color background, Color foreground, IconData icon})? palette =
        toastSeverityPalette(severity);
    final Color? bg = backgroundColor ?? palette?.background;
    final Color? fg = textColor ?? palette?.foreground;
    if (Platform.isAndroid || Platform.isIOS) {
      // 原生 toast 画不了图标，只能着色；桌面自绘 overlay 图标齐全。
      Fluttertoast.showToast(
        msg: msg,
        toastLength: toastLength,
        gravity: gravity,
        backgroundColor: bg,
        textColor: fg,
      );
      return;
    }
    final int durationMs = toastLength == Toast.LENGTH_LONG ? 3500 : 2000;
    // 有语义调色板且调用点没自带颜色时，走带图标的着色渲染器（与制卡 toast 同一个）。
    if (palette != null && backgroundColor == null && textColor == null) {
      _showPaletteToast(msg: msg, palette: palette, durationMs: durationMs);
      return;
    }
    _showDesktopToast(
      msg: msg,
      durationMs: durationMs,
      backgroundColor: bg,
      textColor: fg,
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
    // pending 停留更久（等制卡结果覆盖它），结果 toast 用短时长。
    _insertToastEntry(
      overlay: overlay,
      durationMs: status == MineToastStatus.pending ? 4000 : 2400,
      builder: (BuildContext context) => _SeverityToastWidget(
        msg: msg,
        palette: mineToastPalette(status),
      ),
    );
  }

  /// 语义着色 toast（桌面自绘路径）。与制卡 toast 共用同一个渲染器，避免出现
  /// 「制卡的有图标有颜色、别的没有」这种同类通知两副长相。
  static void _showPaletteToast({
    required String msg,
    required ({Color background, Color foreground, IconData icon}) palette,
    required int durationMs,
  }) {
    final overlay = _toastNavigatorKey?.currentState?.overlay;
    if (overlay == null) return;
    _insertToastEntry(
      overlay: overlay,
      durationMs: durationMs,
      builder: (BuildContext context) =>
          _SeverityToastWidget(msg: msg, palette: palette),
    );
  }

  static void _insertToastEntry({
    required OverlayState overlay,
    required int durationMs,
    required WidgetBuilder builder,
  }) {
    _dismissTimer?.cancel();
    _currentEntry?.remove();
    _currentEntry = null;

    final entry = OverlayEntry(builder: builder);
    _currentEntry = entry;
    overlay.insert(entry);

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
    final tokens = FushiDesignTokens.of(context);
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

/// 语义 toast 的自绘 MD3 组件——一张圆角卡片，左侧状态图标 + 文案，整体用状态色
/// 填充、白色前景，淡入呈现。与 [_DesktopToastWidget] 同一定位/动画骨架，但多了图标
/// 与语义色。
///
/// 制卡结果（[mineToastPalette]）与通用语义（[toastSeverityPalette]）共用本组件：
/// 两者都只是一组 (背景, 前景, 图标)，没有理由各写一个渲染器。
class _SeverityToastWidget extends StatefulWidget {
  const _SeverityToastWidget({required this.msg, required this.palette});

  final String msg;
  final ({Color background, Color foreground, IconData icon}) palette;

  @override
  State<_SeverityToastWidget> createState() => _SeverityToastWidgetState();
}

class _SeverityToastWidgetState extends State<_SeverityToastWidget>
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
    final tokens = FushiDesignTokens.of(context);
    final ({Color background, Color foreground, IconData icon}) palette =
        widget.palette;
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
