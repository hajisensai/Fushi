import 'dart:io' show Platform;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/widgets.dart';

/// File drop callback. [globalPosition] uses Flutter global/view coordinates,
/// matching rectangles produced by RenderBox.localToGlobal.
typedef FileDropCallback = void Function(
    List<String> paths, Offset globalPosition);

/// Enables desktop_drop only on desktop platforms; all other platforms pass the
/// child through with zero runtime cost.
class HibikiFileDropTarget extends StatelessWidget {
  const HibikiFileDropTarget({
    required this.onDrop,
    required this.child,
    this.enabled = true,
    this.debugLabel,
    super.key,
  });

  final FileDropCallback onDrop;
  final Widget child;
  final bool enabled;
  final String? debugLabel;

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  Widget build(BuildContext context) {
    if (!_isDesktop) return child;
    return DropTarget(
      enable: enabled,
      onDragDone: (DropDoneDetails detail) {
        final bool routeVisible = _routeVisible(context);
        final bool active = enabled && routeVisible;
        final List<String> paths = detail.files
            .map((DropItem f) => f.path)
            .where((String s) => s.isNotEmpty)
            .toList();
        _log(
          'done active=$active routeVisible=$routeVisible '
          'files=${paths.length} local=${detail.localPosition} '
          'global=${detail.globalPosition}',
        );
        if (!active) {
          _log('ignored inactive drop');
          return;
        }
        if (paths.isEmpty) {
          _log('ignored empty drop');
          return;
        }
        onDrop(paths, detail.globalPosition);
      },
      onDragEntered: (DropEventDetails detail) {
        final bool routeVisible = _routeVisible(context);
        final bool active = enabled && routeVisible;
        _log(
          'enter active=$active routeVisible=$routeVisible '
          'local=${detail.localPosition} global=${detail.globalPosition}',
        );
      },
      onDragUpdated: (DropEventDetails detail) {
        final bool routeVisible = _routeVisible(context);
        final bool active = enabled && routeVisible;
        _log(
          'update active=$active routeVisible=$routeVisible '
          'local=${detail.localPosition} global=${detail.globalPosition}',
        );
      },
      onDragExited: (DropEventDetails detail) {
        final bool routeVisible = _routeVisible(context);
        final bool active = enabled && routeVisible;
        _log(
          'exit active=$active routeVisible=$routeVisible '
          'local=${detail.localPosition} global=${detail.globalPosition}',
        );
      },
      child: child,
    );
  }

  bool _routeVisible(BuildContext context) {
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    return route == null || route.isCurrent;
  }

  void _log(String message) {
    final String label = debugLabel == null ? '' : '[$debugLabel] ';
    debugPrint('[hibiki-drop] $label$message');
  }
}
