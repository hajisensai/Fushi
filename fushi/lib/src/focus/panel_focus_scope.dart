import 'package:flutter/widgets.dart';

/// 浮层面板的焦点圈地（手柄重设计 P3）。
///
/// 解决的问题：视频页的剧集轨 / 字幕列表 / 侧栏面板打开后，焦点仍停在页面级
/// `_videoFocusNode` 上——手柄 D-pad 的通用移焦兜底从那里出发找不到面板内的行，
/// 面板对手柄用户等于不存在。本组件把面板包成一个 [FocusScope] +
/// [FocusTraversalGroup]，在 [visible] 变真（或以可见状态挂载）时把焦点领进面板
/// 的第一个可遍历节点；面板关闭（变假或卸载）时把焦点还给 [restoreFocus]（宿主
/// 页面焦点节点），播放快捷键随之恢复。
///
/// 两种宿主形态都覆盖：
///   · 常驻挂载 + FadingChromeGate 显隐（剧集轨）：跟 [didUpdateWidget] 的
///     visible 边沿走；
///   · 只在打开时挂载（字幕列表 / 侧栏）：跟 [initState] / [dispose] 走，
///     visible 恒 true 即可。
///
/// 若面板内有子节点自带 `autofocus`（如选中集卡片），后帧检查发现焦点已在面板内
/// 就不再抢——autofocus 的更精准落点优先。
class PanelFocusScope extends StatefulWidget {
  const PanelFocusScope({
    required this.visible,
    required this.child,
    this.restoreFocus,
    super.key,
  });

  /// 面板当前是否可见。常驻挂载的面板传真实显隐；随开关挂卸的面板传 true。
  final bool visible;

  /// 面板关闭后把焦点还给谁（通常是宿主页面的键盘焦点节点）。null = 不归还。
  final FocusNode? restoreFocus;

  final Widget child;

  @override
  State<PanelFocusScope> createState() => _PanelFocusScopeState();
}

class _PanelFocusScopeState extends State<PanelFocusScope> {
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'PanelFocusScope');

  @override
  void initState() {
    super.initState();
    if (widget.visible) _claimFocusNextFrame();
  }

  @override
  void didUpdateWidget(PanelFocusScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !oldWidget.visible) {
      _claimFocusNextFrame();
    } else if (!widget.visible && oldWidget.visible) {
      _restoreHostFocus();
    }
  }

  @override
  void dispose() {
    // 面板随关闭卸载（字幕列表 / 侧栏）：焦点若还圈在面板里，归还宿主。
    if (widget.visible && _scope.hasFocus) _restoreHostFocus();
    _scope.dispose();
    super.dispose();
  }

  /// 后帧认领：等本帧布局完成（FadingChromeGate 的 ExcludeFocus 已放开）再进。
  void _claimFocusNextFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.visible) return;
      // 子节点 autofocus 已落在面板内 → 尊重更精准的落点，不抢。
      if (_scope.hasFocus) return;
      _scope.requestFocus();
      if (_scope.focusedChild == null) _scope.nextFocus();
    });
  }

  void _restoreHostFocus() {
    final FocusNode? host = widget.restoreFocus;
    if (host == null) return;
    if (host.canRequestFocus) host.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      node: _scope,
      child: FocusTraversalGroup(child: widget.child),
    );
  }
}
