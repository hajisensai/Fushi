import 'dart:async' show FutureOr;
import 'dart:io' show Platform;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter/widgets.dart';

import 'package:fushi/utils.dart';

/// File drop callback. [globalPosition] uses Flutter global/view coordinates,
/// matching rectangles produced by RenderBox.localToGlobal.
///
/// 返回 [FutureOr] 而不是 `void`：处理器可能要做真实 IO（书架落点要真读包才分得出
/// 图片型 zip 与词典包）。声明成 `void` 时 `async` 处理器抛出的异常无人可接——
/// 见 [FushiFileDropTarget.runDrop]。
typedef FileDropCallback = FutureOr<void> Function(
    List<String> paths, Offset globalPosition);

/// 拖放处理失败时的上报通道。默认弹 error toast；测试注入自己的收集器，用来断言
/// 「失败**一定**被上报」——只断「没抛出来」是不够的，静默吞掉同样满足那条。
typedef DropFailureReporter = void Function(
    Object error, StackTrace stackTrace);

/// Enables desktop_drop only on desktop platforms; all other platforms pass the
/// child through with zero runtime cost.
class FushiFileDropTarget extends StatelessWidget {
  const FushiFileDropTarget({
    required this.onDrop,
    required this.child,
    this.enabled = true,
    this.debugLabel,
    this.onDropFailure,
    super.key,
  });

  final FileDropCallback onDrop;
  final Widget child;
  final bool enabled;
  final String? debugLabel;

  /// 见 [DropFailureReporter]。`null` = 生产默认（error toast）。
  final DropFailureReporter? onDropFailure;

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
        runDrop(paths, detail.globalPosition);
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

  /// 把 [onDrop] 的**全部**失败收在这一处，并且一定给用户一个可见结果。
  ///
  /// 这是所有文件拖入入口（书架 / 视频库 / 词典页 / 游戏库 / 播放页 + 四个导入
  /// 对话框）共用的唯一咽喉。各页的路由函数挂在 desktop_drop 的 `void` 回调上，
  /// 抛出时异常直接漂进 zone：用户看到的只有「拖了没反应」，他会以为文件类型没被
  /// 识别，而真相是识别到一半炸了——这正是「让用户基于错误信息做决定」被剥夺的
  /// 情形。逐个入口补 try/catch 等于把同一份补丁抄十一遍，还会漏掉以后新增的入口；
  /// 收在这里，新入口天生带上。
  ///
  /// 必须 `await`：[FileDropCallback] 返回 [FutureOr]，只包同步栈的话，`async`
  /// 处理器抛出的异常照样从 catch 底下漏走。
  @visibleForTesting
  Future<void> runDrop(List<String> paths, Offset globalPosition) async {
    try {
      await onDrop(paths, globalPosition);
    } catch (error, stackTrace) {
      _log('drop handler threw: $error\n$stackTrace');
      (onDropFailure ?? _showDropFailureToast)(error, stackTrace);
    }
  }

  void _showDropFailureToast(Object error, StackTrace stackTrace) {
    FushiToast.show(msg: t.drag_drop_failed, severity: ToastSeverity.error);
  }

  bool _routeVisible(BuildContext context) {
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    return route == null || route.isCurrent;
  }

  void _log(String message) {
    final String label = debugLabel == null ? '' : '[$debugLabel] ';
    debugPrint('[fushi-drop] $label$message');
  }
}
