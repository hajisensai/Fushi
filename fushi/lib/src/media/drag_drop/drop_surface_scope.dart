import 'package:flutter/widgets.dart';

/// 声明「这棵子树属于哪个可见表面」，让 [FushiFileDropTarget] 在 drop 落地那一刻
/// 判断自己是不是用户当前真正看着的那个页面。
///
/// 为什么需要它：`desktop_drop` 是**全局广播**——每个 `DropTarget` 把自己加进一个
/// 进程级监听器列表，一次 OS drop 事件所有监听者都会被调用，唯一的过滤是各自
/// `RenderBox.paintBounds.contains(位置)`（见 vendored `desktop_drop` 的
/// `_onDropEvent`，其文档也明说「把新页面推到 drop target 前面时你必须自己禁用它」）。
/// 而 home-shell 的四个库页是 `Offstage` 保活的，`RenderOffstage.performLayout` 在
/// offstage 时仍以完整约束给子树布局（只关掉 Flutter 自己的 `hitTest`），于是**每个
/// 访问过的 tab 的 drop target 都仍然是全屏大小、全部命中**。
///
/// 原有的唯一门控 `ModalRoute.isCurrent` 挡不住这个：四个 tab 同在 HomePage 这一条
/// 路由上，`isCurrent` 对它们同时为 true。实测后果是「在视频页拖入一个视频文件夹 →
/// 隐藏的书架页把它当漫画弹出『导入漫画』对话框，隐藏的游戏页同时弹『拖入的文件里
/// 没有新的游戏 .exe』，而真正可见的视频页一动不动」。
///
/// 这里修的是**结构**而不是逐个调用点补判断：作用域由 shell 在「构建 tab 内容」的
/// 那一处统一提供，11 个 drop 注册点一行都不用改，以后新增的入口天生带上。
class DropSurfaceScope extends InheritedWidget {
  const DropSurfaceScope({
    required this.isActive,
    required super.child,
    super.key,
  });

  /// 在 drop 落地那一刻求值：本子树当前是否是用户看得见的表面。
  ///
  /// 用回调而不是 bool 字段，是因为拖放判定只发生在事件到达的瞬间，不需要让
  /// widget 树为了「当前哪个 tab」而重建。
  final bool Function() isActive;

  /// [context] 所在子树当前是否可以接收拖放。
  ///
  /// **所有**祖先作用域都必须活跃（逐层 AND），所以嵌套是可组合的：外层声明
  /// 「视频 tab 可见吗」，内层再声明「视频 tab 内部当前是不是本地库那一屏」。
  /// 没有任何作用域时返回 true——对话框、播放页这类自己独占一条路由的表面
  /// 不受影响，行为与改动前一致。
  static bool activeFor(BuildContext context) {
    bool active = true;
    context.visitAncestorElements((Element element) {
      final Widget widget = element.widget;
      if (widget is DropSurfaceScope && !widget.isActive()) {
        active = false;
        return false;
      }
      return true;
    });
    return active;
  }

  /// 恒 false：本作用域只在事件到达时被**主动**读取（[activeFor] 不建立依赖），
  /// 不驱动任何重建。
  @override
  bool updateShouldNotify(DropSurfaceScope oldWidget) => false;
}
