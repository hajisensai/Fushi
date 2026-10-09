import 'dart:async' show FutureOr;
import 'dart:io' show Platform;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter/widgets.dart';

import 'package:fushi/src/media/drag_drop/drop_surface_scope.dart';
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

/// drop 落地那一刻的唯一门：[context] 所在的这个 drop target 现在是不是用户真正
/// 看得着的表面。
///
/// 两层判据，缺一不可：
/// - `ModalRoute.isCurrent`：挡住被新路由（对话框 / 播放页）盖住的页面；
/// - [DropSurfaceScope.activeFor]：挡住同一条路由里被 Offstage / IndexedStack
///   保活的隐藏子树（`isCurrent` 对同级 tab 恒为 true，挡不住它们）。
///
/// 抽成具名函数、而不是在 [DropTarget] 的四个匿名回调里各抄一遍：抄写版本谁都测
/// 不到（测试够不到闭包内部），删掉其中一处的作用域判据不会有任何测试变红。
@visibleForTesting
bool dropSurfaceActive(BuildContext context) {
  final ModalRoute<dynamic>? route = ModalRoute.of(context);
  final bool routeVisible = route == null || route.isCurrent;
  final bool surfaceActive = DropSurfaceScope.activeFor(context);
  if (!routeVisible || !surfaceActive) {
    debugPrint(
      '[fushi-drop] gate closed route=$routeVisible surface=$surfaceActive',
    );
  }
  return routeVisible && surfaceActive;
}

/// Enables desktop_drop only on desktop platforms; all other platforms pass the
/// child through with zero runtime cost.
///
/// 「正拖着文件悬停」状态两条出口（都向后兼容，不用的调用点零改动）：
/// - [onHoverChanged]：落点自己的页面 / 状态拿到变化（例如游戏导入视图）；
/// - [FushiFileDropTarget.dragHoveringOf]：子树里任何卡片按需订阅最近一层落点的
///   悬停位（例如快速导入区、导入对话框顶部的拖放卡），不用一层层往下传参。
class FushiFileDropTarget extends StatefulWidget {
  const FushiFileDropTarget({
    required this.onDrop,
    required this.child,
    this.enabled = true,
    this.debugLabel,
    this.onDropFailure,
    this.onHoverChanged,
    super.key,
  });

  final FileDropCallback onDrop;
  final Widget child;
  final bool enabled;
  final String? debugLabel;

  /// 见 [DropFailureReporter]。`null` = 生产默认（error toast）。
  final DropFailureReporter? onDropFailure;

  /// 「正拖着文件悬停在本落点上」的状态变化（可不传）。
  ///
  /// 拖入且本表面可见可用时报 `true`；拖离、落下（无论是否被门挡掉）报 `false`。
  /// 只在桌面端触发——移动端没有桌面拖放，本组件直接透传 child。只在状态真的
  /// 变化时回调（同一状态不重复报）。
  final ValueChanged<bool>? onHoverChanged;

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// 最近一层 [FushiFileDropTarget] 当前是否正有文件拖着悬停（没有祖先 / 非
  /// 桌面端恒为 false）。会注册依赖：悬停位变化时调用方重建。
  static bool dragHoveringOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_FushiFileDragHoverScope>()
          ?.hovering ??
      false;

  @override
  State<FushiFileDropTarget> createState() => _FushiFileDropTargetState();

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

  void _log(String message) {
    final String label = debugLabel == null ? '' : '[$debugLabel] ';
    debugPrint('[fushi-drop] $label$message');
  }
}

class _FushiFileDropTargetState extends State<FushiFileDropTarget> {
  bool _hovering = false;

  void _setHovering(bool value) {
    if (_hovering == value) return;
    if (mounted) setState(() => _hovering = value);
    widget.onHoverChanged?.call(value);
  }

  @override
  void didUpdateWidget(covariant FushiFileDropTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 关掉落点时一并熄灭悬停位：desktop_drop 在 enable=false 后不再报 exit。
    if (!widget.enabled && _hovering) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _setHovering(false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.enabled;
    if (!FushiFileDropTarget._isDesktop) return widget.child;
    return DropTarget(
      enable: enabled,
      onDragDone: (DropDoneDetails detail) {
        _setHovering(false);
        final bool active = widget.enabled && dropSurfaceActive(context);
        final List<String> paths = detail.files
            .map((DropItem f) => f.path)
            .where((String s) => s.isNotEmpty)
            .toList();
        widget._log(
          'done active=$active files=${paths.length} '
          'local=${detail.localPosition} global=${detail.globalPosition}',
        );
        if (!active) {
          widget._log('ignored inactive drop');
          return;
        }
        if (paths.isEmpty) {
          widget._log('ignored empty drop');
          return;
        }
        widget.runDrop(paths, detail.globalPosition);
      },
      onDragEntered: (DropEventDetails detail) {
        final bool active = widget.enabled && dropSurfaceActive(context);
        widget._log(
          'enter active=$active '
          'local=${detail.localPosition} global=${detail.globalPosition}',
        );
        _setHovering(active);
      },
      onDragUpdated: (DropEventDetails detail) {
        widget._log(
          'update active=${widget.enabled && dropSurfaceActive(context)} '
          'local=${detail.localPosition} global=${detail.globalPosition}',
        );
      },
      onDragExited: (DropEventDetails detail) {
        widget._log(
          'exit active=${widget.enabled && dropSurfaceActive(context)} '
          'local=${detail.localPosition} global=${detail.globalPosition}',
        );
        _setHovering(false);
      },
      child: _FushiFileDragHoverScope(
        hovering: _hovering,
        child: widget.child,
      ),
    );
  }
}

/// [FushiFileDropTarget.dragHoveringOf] 的载体。
class _FushiFileDragHoverScope extends InheritedWidget {
  const _FushiFileDragHoverScope({
    required this.hovering,
    required super.child,
  });

  final bool hovering;

  @override
  bool updateShouldNotify(_FushiFileDragHoverScope oldWidget) =>
      oldWidget.hovering != hovering;
}
