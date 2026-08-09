import 'package:flutter/widgets.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 视频 controls 的「焦点单一持有者」守门：当 media_kit 全屏路由在栈上时，
/// 卸载**窗口侧**的 controls 子树；全屏路由内的实例不受影响（它能看到
/// [FullscreenInheritedWidget]）。
///
/// 为什么必须卸载（TODO-040/042 视频快捷键失灵的共同根因）：
///
/// media_kit 的窗口与全屏两套 controls 共用同一个 [FocusNode]
/// （`videoViewParametersNotifier.value.focusNode`，即页面持有的
/// `_videoFocusNode`），而全屏是另推的独立路由、窗口侧 controls 仍然挂在树上
/// —— 同一个节点被同时 attach 到两个 [Focus] widget。Flutter 的
/// [FocusAttachment] 语义是：
///
/// * `attach` 直接覆盖节点的 current attachment（先挂者变 stale）；
/// * `detach` 只在「自己仍是 current attachment」时把节点从焦点树摘除；
/// * `reparent` 在 stale attachment 上永远是 no-op。
///
/// 于是退全屏时：全屏侧 [Focus] dispose → `detach`（它是 current）→ 节点被摘出
/// 焦点树；窗口侧只剩 stale attachment，后续 build 的 `reparent` 全是 no-op →
/// **节点永久孤儿**。此后所有 `requestFocus()` 都只会静默置
/// `_requestFocusWhenReparented` 等一个永远不会发生的 reparent —— 空格等全部
/// 播放快捷键死亡，且每个对话框/菜单关闭后的「归还焦点」补丁也一并失效。
///
/// 卸载窗口侧实例保证任意时刻只有一个 [Focus] 持有该节点：
///
/// * 进全屏：全屏侧 attach 接管（窗口侧实例 finalize 期 detach 已 stale，
///   no-op）；
/// * 退全屏：窗口侧 controls 同帧重挂、其 [Focus] 在 initState 重新 attach，
///   而全屏侧的 detach 发生在 finalize 期、彼时已 stale —— 干净交接，节点始终
///   在焦点树上，`requestFocus` / `autofocus` 都能正常找回键盘。
class VideoControlsFocusGate extends StatelessWidget {
  const VideoControlsFocusGate({
    super.key,
    required this.fullscreenRouteActive,
    required this.child,
  });

  /// 页面级「全屏路由当前在栈上」标记（进全屏置位、全屏路由 future 完成复位）。
  final bool fullscreenRouteActive;

  /// 真正的 controls 子树（含持有共享 [FocusNode] 的 [Focus]）。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool inFullscreenRoute =
        FullscreenInheritedWidget.maybeOf(context) != null;
    if (fullscreenRouteActive && !inFullscreenRoute) {
      return const SizedBox.shrink();
    }
    return child;
  }
}
