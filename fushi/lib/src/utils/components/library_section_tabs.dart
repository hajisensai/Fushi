import 'package:flutter/material.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

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
///   桌面鼠标拖滚一整套补丁（TODO-2937 / BUG-1719 / BUG-1184）——其中滚动形态与
///   选中段自动滚入是 tabs 自带的，等宽下限和自然宽估算随控件一起作废。**桌面鼠标
///   拖滚不是自带的**（Flutter 桌面默认 dragDevices 不含 mouse），仍要显式包
///   [HorizontalDragScrollable]；两侧渐隐是有意舍弃。
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
  /// 组件自持选中态：宿主只给「当前是哪个」和「点了哪个」，内部 [TabController]
  /// 是 [selected] 的投影。四个库页壳（书架 / 漫画 / 视频 / 游戏）用这个形态——
  /// 它们的子视图是 [Offstage] 保活的独立页面，页内没有 [TabBarView]。
  const LibrarySectionTabs({
    required this.tabs,
    required T this.selected,
    required ValueChanged<T> this.onChanged,
    required this.focusIdPrefix,
    super.key,
  }) : controller = null;

  /// 宿主已持有 [TabController]（页内还有 [TabBarView] 由它驱动）：直接共用那一个，
  /// **不**再镜像出第二份选中态。
  ///
  /// 差别不只是少一个对象：镜像形态下横滑 [TabBarView] 时，宿主 index 只在越过一半
  /// 时跳变，镜像出的指示器只能跟着 `animateTo` 一跳；共用同一个 controller 时指示器
  /// 跟手连续滑动，那才是 MD3 tabs 与 [TabBarView] 配对时的正常行为。
  ///
  /// 值域即下标：`tabs[i].value` 必须与 controller 的第 i 个 tab 对应。
  const LibrarySectionTabs.controlled({
    required this.tabs,
    required TabController this.controller,
    required this.focusIdPrefix,
    super.key,
  })  : selected = null,
        onChanged = null;

  final List<LibrarySectionTab<T>> tabs;

  /// 仅自持形态；[LibrarySectionTabs.controlled] 下为 null（真相在 [controller]）。
  final T? selected;
  final ValueChanged<T>? onChanged;

  /// 仅 [LibrarySectionTabs.controlled] 形态；自持形态下为 null。
  final TabController? controller;

  /// focusId 前缀（如 `game-library-tab`），焦点停靠点 id 为 `<prefix>-sections`。
  final String focusIdPrefix;

  Widget _focusShell({
    required T selectedValue,
    required ValueChanged<T> onSelect,
    required Widget child,
  }) {
    return FushiAdjustableSegmented<T>(
      values: <T>[for (final LibrarySectionTab<T> tab in tabs) tab.value],
      selected: selectedValue,
      onChanged: onSelect,
      focusIdPrefix: focusIdPrefix,
      focusId: FushiFocusId('$focusIdPrefix-sections'),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final TabController? host = controller;
    if (host == null) {
      final T selectedValue = selected as T;
      final ValueChanged<T> onSelect = onChanged!;
      return _focusShell(
        selectedValue: selectedValue,
        onSelect: onSelect,
        child: FushiSectionTabBar<T>(
          tabs: tabs,
          selected: selectedValue,
          onChanged: onSelect,
        ),
      );
    }
    // 焦点外壳要的是「当前值 + 怎么切」，从宿主 controller 就地派生；监听它才能让
    // 横滑 / 外部 animateTo 之后方向键的起点跟着走。
    return AnimatedBuilder(
      animation: host,
      builder: (BuildContext context, Widget? child) {
        final int index = host.index.clamp(0, tabs.length - 1);
        return _focusShell(
          selectedValue: tabs[index].value,
          onSelect: (T value) {
            final int target =
                tabs.indexWhere((LibrarySectionTab<T> tab) => tab.value == value);
            if (target >= 0 && target != host.index) host.animateTo(target);
          },
          child: FushiSectionTabBar<T>.controlled(
            tabs: tabs,
            controller: host,
          ),
        );
      },
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
  /// 自持形态：内部 controller 是 [selected] 的投影。
  const FushiSectionTabBar({
    required this.tabs,
    required T this.selected,
    required ValueChanged<T> this.onChanged,
    super.key,
  }) : controller = null;

  /// 宿主持有形态：直接用宿主的 controller（页内 [TabBarView] 也由它驱动），不投影、
  /// 不接管点击、不负责它的生命周期。
  const FushiSectionTabBar.controlled({
    required this.tabs,
    required TabController this.controller,
    super.key,
  })  : selected = null,
        onChanged = null;

  final List<LibrarySectionTab<T>> tabs;
  final T? selected;
  final ValueChanged<T>? onChanged;
  final TabController? controller;

  @override
  State<FushiSectionTabBar<T>> createState() => _FushiSectionTabBarState<T>();
}

class _FushiSectionTabBarState<T extends Object>
    extends State<FushiSectionTabBar<T>> with TickerProviderStateMixin {
  /// 自持形态下由本 State 创建并负责 dispose；宿主持有形态下恒为 null。
  TabController? _owned;

  TabController get _controller => widget.controller ?? _owned!;

  /// 宿主持有 controller 时它本身就是真相，没有第二份要对齐的东西：既不投影，
  /// 也不接管点击。
  bool get _hostControlled => widget.controller != null;

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
  void initState() {
    super.initState();
    if (widget.controller == null) _owned = _createController();
  }

  @override
  void didUpdateWidget(covariant FushiSectionTabBar<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != null) {
      // 换成宿主持有：自持时期的 controller 不再是任何东西的真相，就地释放。
      _owned?.dispose();
      _owned = null;
      return;
    }
    if (_owned == null) {
      _owned = _createController();
      return;
    }
    // 段数变了（模块按能力增删分区）才需要换 controller；选中值的变化由每帧末尾的
    // 投影校正统一承接，不在这里分叉。
    if (widget.tabs.length != oldWidget.tabs.length) {
      _owned!.dispose();
      _owned = _createController();
    }
  }

  @override
  void dispose() {
    _owned?.dispose();
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
    // 自然宽是纯 build 期可算量（只依赖文案 / 字号 / 缩放）：页头用它判定「左边摆得
    // 下吗」，据此决定是否把动作收进 ⋯ 菜单。
    FushiHeaderCrampScope.maybeOf(context)?.reportTitleNaturalWidth(
      estimateSectionTabBarWidth(
        context,
        <String>[for (final LibrarySectionTab<T> tab in widget.tabs) tab.label],
        horizontalPaddingPerTab: _kSectionTabHorizontalPadding,
      ),
    );

    if (!_hostControlled) _scheduleProjection();

    // TabBar 自带「选中段自动滚入」，但**不带**桌面鼠标拖滚：Flutter 桌面默认
    // dragDevices 不含 mouse。旧的等宽段条外面本来就包着 [HorizontalDragScrollable]，
    // 换控件时一起丢了——一旦溢出（窄窗 / 界面缩放 / 德俄长文案），桌面用户拖不动，
    // 只剩键盘、手柄或点那半截 tab。
    //
    // 两样没跟过来，都是有意的：两侧渐隐（tabs 比等宽段窄约三分之一，溢出概率显著
    // 下降），以及横向滚轮——[WheelToHorizontalScroll] 需要目标滚动区的
    // ScrollController，而 TabBar 的内部 controller 取不到，接不上。
    return HorizontalDragScrollable(child: _buildTabBar());
  }

  Widget _buildTabBar() {
    return TabBar(
      controller: _controller,
      isScrollable: true,
      // 可滚动 TabBar 默认留 52px 起始缩进（[TabAlignment.startOffset]）；顶栏里
      // 首段必须与页头标题左缘对齐，故贴左。
      tabAlignment: TabAlignment.start,
      // MD3 的 tab 分隔线会横贯整条 TabBar，而这里 TabBar 只占页头标题槽、右边还有
      // 动作区——画出来是条半截线，故去掉；页头自身的留白已经分隔了内容。
      dividerHeight: 0,
      // 宿主持有形态不接管点击：TabBar 自己 animateTo 那一个 controller，页内的
      // TabBarView 跟着走，中间不该再插一手。
      onTap: _hostControlled
          ? null
          : (int index) {
              widget.onChanged!(widget.tabs[index].value);
              // TabBar 已把指示器移过去了；宿主若不接受这次切换（不改 selected、
              // 也不 rebuild），得靠这次校正把它拉回来。
              _scheduleProjection();
            },
      tabs: <Widget>[
        for (final LibrarySectionTab<T> tab in widget.tabs)
          Tab(text: tab.label),
      ],
    );
  }
}
