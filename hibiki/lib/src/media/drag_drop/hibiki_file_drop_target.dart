import 'dart:io' show Platform;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

/// 拖入文件落地后回调：paths = 拖入文件绝对路径，localPosition = 落点（相对本 widget 左上角）。
typedef FileDropCallback = void Function(
    List<String> paths, Offset localPosition);

/// 仅桌面三端启用 desktop_drop；其余平台直接透传 child（零开销）。
class HibikiFileDropTarget extends StatelessWidget {
  const HibikiFileDropTarget(
      {required this.onDrop, required this.child, super.key});

  final FileDropCallback onDrop;
  final Widget child;

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  Widget build(BuildContext context) {
    if (!_isDesktop) return child;
    return DropTarget(
      onDragDone: (DropDoneDetails detail) {
        final List<String> paths = detail.files
            .map((DropItem f) => f.path)
            .where((String s) => s.isNotEmpty)
            .toList();
        if (paths.isEmpty) return;
        onDrop(paths, detail.localPosition);
      },
      child: child,
    );
  }
}
