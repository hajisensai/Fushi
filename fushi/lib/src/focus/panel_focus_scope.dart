import 'package:flutter/widgets.dart';

/// 浮层面板的焦点圈地（手柄重设计 P3）。
///
/// 解决的问题：视频页的剧集轨 / 字幕列表 / 侧栏面板打开后，焦点仍停在页面级
/// `_videoFocusNode` 上——手柄 D-pad 的通用移焦兜底从那里出发找不到面板内的行，
/// 面板对手柄用户等于不存在。本组件把面板包成一个 [FocusScope] +
/// [FocusTraversalGroup]，在 [visible] 变真（或以可见状态挂载）时把焦点领进面板
/// 的第一个可遍历节点；面板关闭（变假或卸载）时调 [restoreFocus] 让**宿主自己**
/// 把焦点收回去，播放快捷键随之恢复。
///
/// [restoreFocus] 是回调而不是裸 [FocusNode]，是有意的：焦点该不该回到宿主是宿主
/// 的判据（视频页集中在 `_canOwnVideoFocus`：播放器是否就绪、上面压没压查词浮层 /
/// 对话框、路由是不是当前）。在这里裸调 `node.requestFocus()` 会绕过那套判据，也
/// 会绕过只扫 video_fushi* / reader_fushi* 目录的焦点所有权守卫测试——「把节点递
/// 出去让别人代调」正是那条守卫防不住的形状。顺带解掉 dispose 期的
/// use-after-dispose：宿主的判据第一行就是 `mounted`，退页时直接返回 false，不会
/// 对正在 dispose 的节点发请求。
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

  /// 面板关闭后请宿主收回焦点（视频页传 `_focusOwnership.reclaim(...)`）。
  /// null = 不归还。
  final VoidCallback? restoreFocus;

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

  void _restoreHostFocus() => widget.restoreFocus?.call();

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      node: _scope,
      child: FocusTraversalGroup(child: widget.child),
    );
  }
}
