import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeBar, FushiFloatingChromeSoloTitle;
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiShellHeaderActions;
import 'package:fushi/src/utils/components/fushi_page_masthead.dart'
    show FushiMastheadRole, FushiMastheadScope;
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show FushiShellActionsSlot, FushiShellTitleScope;

// =============================================================================
// 不叠在库页浮动工具区里的「页头大字」（重设计外壳，`fushi_page_masthead.dart`）。
//
// 库页把 [FushiFloatingChromeBar] 放进 `FushiFloatingChromeOverlay(masthead: true)`：
// 随滚动收缩、画页头底板。设置这类自己管版面（主从两栏、折叠大标题列表）的页面
// 只要一行固定的页头大字：页名 + 模块徽标 + 右侧动作组 + 主按钮位。这里把「页名
// 交给大字行」「动作登记进自己的动作槽」两件事收在一处，调用点只给数据。
//
// 有返回键（[leading]）时大字行不画外壳页名（返回键与页名不同排），页名改放在
// 一级切换位（[FushiFloatingChromeSoloTitle]，与页名同字号），徽标随之不画。
// 只在重设计外壳生效时（`shellRedesignActive`）由调用点挂。
// =============================================================================

class FushiStaticMasthead extends StatefulWidget {
  const FushiStaticMasthead({
    required this.title,
    this.actions = const <Widget>[],
    this.leading,
    this.trailing,
    this.padding,
    super.key,
  });

  /// 页名（大字）。
  final String title;

  /// 右侧动作（图标按钮，放不下按优先级收进「⋯」）；空 = 不画动作组。
  final List<Widget> actions;

  /// 返回键等前导；非 null 时页名改画在一级切换位（见文件头）。
  final Widget? leading;

  /// 动作组右边的主按钮位（[FushiFloatingChromeBar.trailing]）。
  final Widget? trailing;

  /// 整行内边距；null = 左右页边。
  final EdgeInsetsGeometry? padding;

  @override
  State<FushiStaticMasthead> createState() => _FushiStaticMastheadState();
}

class _FushiStaticMastheadState extends State<FushiStaticMasthead> {
  final FushiShellActionsSlot _slot = FushiShellActionsSlot();

  @override
  void dispose() {
    _slot.dispose();
    super.dispose();
  }

  void _syncActions() {
    if (widget.actions.isEmpty) {
      _slot.release(this);
    } else {
      _slot.claim(
        this,
        visible: true,
        actions: FushiShellHeaderActions(actions: widget.actions),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    _syncActions();
    final bool hasLeading = widget.leading != null;
    return FushiShellTitleScope(
      // 有返回键时大字行不画外壳页名，页名由一级切换位的单独页名补上。
      title: hasLeading ? null : widget.title,
      actionsSlot: _slot,
      child: FushiMastheadScope(
        role: FushiMastheadRole.primary,
        child: FushiFloatingChromeBar(
          tabs: hasLeading
              ? FushiFloatingChromeSoloTitle(title: widget.title)
              : const SizedBox.shrink(),
          slot: _slot,
          leading: widget.leading,
          trailing: widget.trailing,
          padding: widget.padding,
        ),
      ),
    );
  }
}
