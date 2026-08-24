import 'package:flutter/material.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

/// MD3 tab 的左右内边距（逻辑像素，单侧）。
///
/// 与 framework 的 `_kTabLabelPadding`（`EdgeInsets.symmetric(horizontal: 16)`）
/// 同值：自然宽估算必须与真实布局同口径，否则页头的「摆不摆得下」会判错。
const double _kSectionTabHorizontalPadding = 16.0;

/// [LibrarySectionTabs] 的一段：值 + 用户可读标签。
class LibrarySectionTab<T> {
  const LibrarySectionTab({required this.value, required this.label});

  final T value;
  final String label;
}

/// 库页（书架 / 漫画 / 视频 / 游戏）顶栏共用的分区导航，形态是 MD3 primary tabs。
///
/// 为什么是 tabs 而不是分段按钮（2026-08-24 改）：这排控件切的是**六个互相独立的
/// 目的地**（发现 / 来源 / 设置各自是独立页面、独立 State），是页面级导航。MD3 对
/// 分段按钮的规定是「affects section-level views and should not be considered a
/// replacement for navigational tabs」——用错控件带来两个可见后果，用户都报过：
/// * 分段按钮是**等宽**控件，六段按最长文案取宽后远超页头标题槽，手机上必然溢出，
///   尾段被切成半个胶囊（看着像渲染 bug，而不是「右边还有」）；
/// * 为了让它当导航用，此前堆了统一最小段宽、自然宽估算、两侧渐隐、选中段自动滚入、
///   桌面鼠标拖滚一整套补丁（TODO-2937 / BUG-1719 / BUG-1184）——全是 tabs 自带的。
///
/// 换成 [TabBar] 后：滚动是它的正常形态而非降级；tab 按各自文案取宽（中文顶栏文案
/// 下比等宽分段窄约三分之一，多数窗口直接不再需要滚）；四个模块共用同一实现、同一
/// 指示器与内边距，观感一致由「同一个控件」保证，不再依赖估算出来的等宽下限。
///
/// 保持不变的两件事：
/// * 焦点契约——外层仍是 [FushiAdjustableSegmented]，整排是**单个**焦点停靠点
///   （focusId 恒为 `<focusIdPrefix>-sections`），左右方向键 / D-pad 原地切段，
///   内部 tab 由该外壳的 [ExcludeFocus] 移出遍历，鼠标点击不受影响；
/// * 页头协作——经 [FushiHeaderCrampScope] 上报自然宽，页头据此决定窄屏是否把动作
///   收进 ⋯ 菜单。
class LibrarySectionTabs<T extends Object> extends StatelessWidget {
  const LibrarySectionTabs({
    required this.tabs,
    required this.selected,
    required this.onChanged,
    required this.focusIdPrefix,
    super.key,
  });

  final List<LibrarySectionTab<T>> tabs;
  final T selected;
  final ValueChanged<T> onChanged;

  /// focusId 前缀（如 `game-library-tab`），焦点停靠点 id 为 `<prefix>-sections`。
  final String focusIdPrefix;

  @override
  Widget build(BuildContext context) {
    return FushiAdjustableSegmented<T>(
      values: <T>[for (final LibrarySectionTab<T> tab in tabs) tab.value],
      selected: selected,
      onChanged: onChanged,
      focusIdPrefix: focusIdPrefix,
      focusId: FushiFocusId('$focusIdPrefix-sections'),
      child: FushiSectionTabBar<T>(
        tabs: tabs,
        selected: selected,
        onChanged: onChanged,
      ),
    );
  }
}

/// [LibrarySectionTabs] 的呈现层：受控的 MD3 [TabBar]。
///
/// 「受控」指 [TabController] 只是 [selected] 的投影，不是第二份真相：每帧结束都把
/// controller 拉回 [selected] 对应的下标。这条不变式覆盖了宿主**拒绝**本次切换的
/// 情形——游戏页的「设置」段可由宿主改成打开别的页面而不改分区值，此时 [TabBar] 自己
/// 已经把指示器移过去了，若不校正，指示器会停在一个并未生效的分区上。
class FushiSectionTabBar<T extends Object> extends StatefulWidget {
  const FushiSectionTabBar({
    required this.tabs,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final List<LibrarySectionTab<T>> tabs;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  State<FushiSectionTabBar<T>> createState() => _FushiSectionTabBarState<T>();
}

class _FushiSectionTabBarState<T extends Object>
    extends State<FushiSectionTabBar<T>> with TickerProviderStateMixin {
  late TabController _controller = _createController();

  int get _selectedIndex {
    final int index = widget.tabs
        .indexWhere((LibrarySectionTab<T> tab) => tab.value == widget.selected);
    return index < 0 ? 0 : index;
  }

  TabController _createController() => TabController(
        length: widget.tabs.length,
        initialIndex: _selectedIndex,
        vsync: this,
      );

  @override
  void didUpdateWidget(covariant FushiSectionTabBar<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 段数变了（模块按能力增删分区）才需要换 controller；选中值的变化由每帧末尾的
    // 投影校正统一承接，不在这里分叉。
    if (widget.tabs.length != oldWidget.tabs.length) {
      _controller.dispose();
      _controller = _createController();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _projectionScheduled = false;

  /// 把 controller 拉回 [widget.selected] 的投影。
  ///
  /// 判据只看 `_controller.index`——切换动画进行中它已经是**目标**下标，此时无需干预，
  /// 让动画自己走完；若还去 `animateTo` 同一个下标，只会把动画反复推倒重来。
  ///
  /// build 与 onTap 各调一次，缺一不可：宿主接受本次切换时走 build（父 rebuild），
  /// 宿主**拒绝**时父可能根本不 rebuild（游戏页「设置」段可由宿主改成打开别的页面），
  /// 那一路只剩 onTap 这次校正把指示器拉回真正生效的分区。一帧内去重。
  void _scheduleProjection() {
    if (_projectionScheduled) return;
    _projectionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _projectionScheduled = false;
      if (!mounted) return;
      final int index = _selectedIndex;
      if (_controller.index == index) return;
      _controller.animateTo(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double fontSize = tokens.type.controlLabel.fontSize ?? 14.0;
    final double textScale = MediaQuery.textScalerOf(context).scale(1);
    // 自然宽是纯 build 期可算量（只依赖文案 / 字号 / 缩放）：页头用它判定「左边摆得
    // 下吗」，据此决定是否把动作收进 ⋯ 菜单。tab 各自取宽，故是逐段求和而不是
    // 「段数 × 最宽段」——后者是等宽分段条的算法，用在这里会高估近一倍。
    double naturalWidth = 0.0;
    for (final LibrarySectionTab<T> tab in widget.tabs) {
      naturalWidth += estimateLabelAdvanceWidth(
            label: tab.label,
            fontSize: fontSize,
            textScaleFactor: textScale,
          ) +
          _kSectionTabHorizontalPadding * 2;
    }
    FushiHeaderCrampScope.maybeOf(context)?.reportTitleNaturalWidth(
      naturalWidth,
    );

    _scheduleProjection();

    return TabBar(
      controller: _controller,
      isScrollable: true,
      // 可滚动 TabBar 默认留 52px 起始缩进（[TabAlignment.startOffset]）；顶栏里
      // 首段必须与页头标题左缘对齐，故贴左。
      tabAlignment: TabAlignment.start,
      // MD3 的 tab 分隔线会横贯整条 TabBar，而这里 TabBar 只占页头标题槽、右边还有
      // 动作区——画出来是条半截线，故去掉；页头自身的留白已经分隔了内容。
      dividerHeight: 0,
      onTap: (int index) {
        widget.onChanged(widget.tabs[index].value);
        // TabBar 已把指示器移过去了；宿主若不接受这次切换（不改 selected、也不
        // rebuild），得靠这次校正把它拉回来。
        _scheduleProjection();
      },
      tabs: <Widget>[
        for (final LibrarySectionTab<T> tab in widget.tabs)
          Tab(text: tab.label),
      ],
    );
  }
}
