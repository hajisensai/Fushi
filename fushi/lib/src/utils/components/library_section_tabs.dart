import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingToolbarSurface;
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';

/// MD3 tab 的左右内边距（逻辑像素，单侧）。
///
/// 与 framework 的 `_kTabLabelPadding`（`EdgeInsets.symmetric(horizontal: 16)`）
/// 同值：自然宽估算必须与真实布局同口径，否则页头的「摆不摆得下」会判错。
const double _kSectionTabHorizontalPadding = 16.0;

/// Apple 页签的默认单侧内边距（与 `_FushiGlassTabBar` 的 labelPadding 默认值同值）。
const double _kSectionTabAppleLabelPadding = 12.0;

/// 收紧档的单侧内边距下限：再小相邻两段的文字就贴在一起、点按区也太窄。
const double _kSectionTabMinLabelPadding = 8.0;

/// 溢出档末尾「更多」按钮的宽（也是它的高与点按区）。
const double _kSectionTabMoreWidth = 40.0;

/// 横向 tab 还有离屏内容时，边缘渐隐占用的宽度（逻辑像素）。
///
/// 它只覆盖内容、不参与布局，也不拦截点击；比在 primary tabs 下方再画一根滚动条
/// 更轻，并避免与选中指示器形成两条含义不同的横线。
const double _kSectionTabOverflowFadeWidth = 24.0;

const ValueKey<String> _kSectionTabLeadingOverflowCueKey = ValueKey<String>(
  'library-section-tabs-leading-overflow-cue',
);
const ValueKey<String> _kSectionTabTrailingOverflowCueKey = ValueKey<String>(
  'library-section-tabs-trailing-overflow-cue',
);

/// 向子树广播「模块此刻真正显示的是哪个分区」，让同一模块里**同时常驻**的多份
/// [LibrarySectionTabs] 跟着它走。
///
/// 动因：游戏模块的七个子区在 IndexedStack 里一起常驻，每个子页各自挂一份页签、
/// 各自的 `selected` 是常量——切到别的子区时，那一页的页签早就停在自己的位置上，
/// 指示条没有起点可滑，看起来就是「导航栏没动画」。挂了本作用域后，**隐藏**页的
/// 页签把指示器投影到 [current]（跟着用户真正所在的分区走），被切出来的那一刻才
/// 从来源分区滑到自己。
///
/// [current] 的值不在某份页签的段里（如游戏「诊断」不设页签）时，该页签回落到
/// 自己的 `selected`。只对自持形态生效；[LibrarySectionTabs.controlled] 的真相在
/// 宿主 controller，不受影响。
///
/// 同一时刻只挂**一份**页签、切分区时整份换位置的壳（视频 / 书架 / 漫画）不用它，
/// 而是给页签一个壳持有的 [GlobalKey]，让同一个 State 随分区移动——见
/// `VideoLibraryShell` / `MediaLibraryShell`。
class LibrarySectionFollowScope extends InheritedWidget {
  const LibrarySectionFollowScope({
    required this.current,
    required super.child,
    super.key,
  });

  /// 模块当前真正显示的分区值（与页签的 `LibrarySectionTab.value` 同值域）。
  final ValueListenable<Object?> current;

  static ValueListenable<Object?>? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<LibrarySectionFollowScope>()
      ?.current;

  @override
  bool updateShouldNotify(LibrarySectionFollowScope oldWidget) =>
      current != oldWidget.current;
}

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
    this.secondary = false,
    this.fill = true,
    this.floating = false,
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
    this.secondary = false,
    this.fill = true,
    this.floating = false,
    super.key,
  }) : selected = null,
       onChanged = null;

  final List<LibrarySectionTab<T>> tabs;

  /// M3 Expressive 浮动页签胶囊（2026-10-05 视频库浮动工具栏）：整排收进一枚
  /// 悬浮的 floating toolbar 胶囊（[FushiFloatingToolbarSurface]），按自然宽贴左、
  /// 摆不下时在胶囊里横滑；选中段是 secondaryContainer 全胶囊，切换时弹性
  /// 拉伸滑过去（[TabIndicatorAnimation.elastic]）。Apple 设计系统是一枚
  /// 液态玻璃胶囊。焦点 / 投影 / 跟随契约与常规形态完全相同。
  final bool floating;

  /// MD3 secondary tabs：页面内、primary tabs 之下的二级分区（如「浏览」页签里
  /// 再分小说 / 漫画 / 视频）。与 primary 同一套焦点、滚动与投影契约，只换
  /// 呈现（指示条横贯整个 tab、选中文案不着主色），层级一眼可辨。
  final bool secondary;

  /// 摆得下时铺满整行（各段等分可用宽度、不滚动）；摆不下（窄窗 / 界面缩放 /
  /// 长译文）自动退回贴左可滚动的常规形态，不会把段挤到截字。用于页面内的
  /// 二级分区（如「浏览」各页签里的小说 / 漫画 / 视频），顶栏页签不用。
  final bool fill;

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
          secondary: secondary,
          fill: fill,
          floating: floating,
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
            final int target = tabs.indexWhere(
              (LibrarySectionTab<T> tab) => tab.value == value,
            );
            if (target >= 0 && target != host.index) host.animateTo(target);
          },
          child: FushiSectionTabBar<T>.controlled(
            tabs: tabs,
            controller: host,
            secondary: secondary,
            fill: fill,
            floating: floating,
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
    this.secondary = false,
    this.fill = true,
    this.floating = false,
    super.key,
  }) : controller = null;

  /// 宿主持有形态：直接用宿主的 controller（页内 [TabBarView] 也由它驱动），不投影、
  /// 不接管点击、不负责它的生命周期。
  const FushiSectionTabBar.controlled({
    required this.tabs,
    required TabController this.controller,
    this.secondary = false,
    this.fill = true,
    this.floating = false,
    super.key,
  }) : selected = null,
       onChanged = null;

  final List<LibrarySectionTab<T>> tabs;
  final T? selected;
  final ValueChanged<T>? onChanged;
  final TabController? controller;

  /// 见 [LibrarySectionTabs.secondary]。
  final bool secondary;

  /// 见 [LibrarySectionTabs.fill]。
  final bool fill;

  /// 见 [LibrarySectionTabs.floating]。
  final bool floating;

  @override
  State<FushiSectionTabBar<T>> createState() => _FushiSectionTabBarState<T>();
}

class _FushiSectionTabBarState<T extends Object>
    extends State<FushiSectionTabBar<T>>
    with TickerProviderStateMixin {
  /// 自持形态下由本 State 创建并负责 dispose；宿主持有形态下恒为 null。
  TabController? _owned;

  TabController get _controller => widget.controller ?? _owned!;

  /// 溢出档（前 N 段 + 「更多」）的显示用 controller，见 [_syncDisplayController]；
  /// 其余档位不用它（保留着，窗口再变窄时不必重建）。
  TabController? _display;

  /// 宿主持有 controller 时它本身就是真相，没有第二份要对齐的东西：既不投影，
  /// 也不接管点击。
  bool get _hostControlled => widget.controller != null;

  int get _selectedIndex {
    final int index = widget.tabs.indexWhere(
      (LibrarySectionTab<T> tab) => tab.value == widget.selected,
    );
    return index < 0 ? 0 : index;
  }

  /// [LibrarySectionFollowScope] 广播的「模块当前分区」；没挂作用域时为 null。
  ValueListenable<Object?>? _follow;

  /// 指示器该停在哪：挂了跟随作用域且当前分区在本页签的段里时跟它走（隐藏页的
  /// 页签就这样一直停在用户真正所在的分区上），否则是自己的 [widget.selected]。
  /// 可见那一份两者恒等。
  int get _targetIndex {
    final Object? followed = _follow?.value;
    if (followed != null) {
      final int index = widget.tabs.indexWhere(
        (LibrarySectionTab<T> tab) => tab.value == followed,
      );
      if (index >= 0) return index;
    }
    return _selectedIndex;
  }

  void _onFollowChanged() {
    if (!mounted) return;
    // 重建即经 build 里的投影校正滑过去；listener 触发时不在 build 阶段，可以 setState。
    setState(() {});
  }

  /// 自持 controller 的指示条滑动时长：eink 下归零（滑动 = 一串局部刷新的残影），
  /// 首帧 initState 里读不到 Theme，先按默认建，didChangeDependencies 再对齐。
  Duration _animationDuration = kTabScrollDuration;

  TabController _createController() => TabController(
    length: widget.tabs.length,
    initialIndex: _targetIndex,
    animationDuration: _animationDuration,
    vsync: this,
  );

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) _owned = _createController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ValueListenable<Object?>? follow = widget.controller == null
        ? LibrarySectionFollowScope.maybeOf(context)
        : null;
    if (!identical(follow, _follow)) {
      _follow?.removeListener(_onFollowChanged);
      _follow = follow?..addListener(_onFollowChanged);
    }
    final Duration duration = einkSafeDuration(context, kTabScrollDuration);
    if (duration == _animationDuration) return;
    _animationDuration = duration;
    if (_owned == null) return;
    _owned!.dispose();
    _owned = _createController();
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
    _follow?.removeListener(_onFollowChanged);
    _owned?.dispose();
    _display?.dispose();
    super.dispose();
  }

  bool _projectionScheduled = false;

  bool _showLeadingOverflowCue = false;
  bool _showTrailingOverflowCue = false;
  bool _overflowCueUpdateScheduled = false;
  bool _pendingLeadingOverflowCue = false;
  bool _pendingTrailingOverflowCue = false;

  /// [TabBar] 把自己的横向 [ScrollController] 封在内部，外层拿不到；但内部
  /// Scrollable 的 metrics notification 会正常向上冒泡。用它判断两端是否还有
  /// 离屏内容，既不复制一套 tab 布局，也不接管 TabBar 自带的选中项滚入逻辑。
  void _updateOverflowCues(ScrollMetrics metrics) {
    if (metrics.axis != Axis.horizontal) return;
    _pendingLeadingOverflowCue = metrics.extentBefore > 0.5;
    _pendingTrailingOverflowCue = metrics.extentAfter > 0.5;
    if (_overflowCueUpdateScheduled) return;
    _overflowCueUpdateScheduled = true;
    // ScrollMetricsNotification 在 layout 后发出；延到帧末更新，避免在布局阶段
    // setState。若同一帧收到多条通知，pending 值始终保留最后一条。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _overflowCueUpdateScheduled = false;
      if (!mounted) return;
      final bool leading = _pendingLeadingOverflowCue;
      final bool trailing = _pendingTrailingOverflowCue;
      if (_showLeadingOverflowCue == leading &&
          _showTrailingOverflowCue == trailing) {
        return;
      }
      setState(() {
        _showLeadingOverflowCue = leading;
        _showTrailingOverflowCue = trailing;
      });
    });
  }

  bool _handleScrollMetrics(ScrollMetricsNotification notification) {
    _updateOverflowCues(notification.metrics);
    return false;
  }

  bool _handleScroll(ScrollNotification notification) {
    _updateOverflowCues(notification.metrics);
    return false;
  }

  /// 把 controller 拉回 [_targetIndex] 的投影（没挂跟随作用域时即 [widget.selected]）。
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
      final int index = _targetIndex;
      if (_controller.index == index) return;
      _controller.animateTo(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 自然宽是纯 build 期可算量（只依赖文案 / 字号 / 缩放）：页头用它判定「左边摆得
    // 下吗」，据此决定是否把动作收进 ⋯ 菜单。
    FushiHeaderCrampScope.maybeOf(context)?.reportTitleNaturalWidth(
      estimateSectionTabBarWidth(context, <String>[
        for (final LibrarySectionTab<T> tab in widget.tabs) tab.label,
      ], horizontalPaddingPerTab: _kSectionTabHorizontalPadding),
    );

    if (!_hostControlled) _scheduleProjection();

    // 2026-10-04 用户：「顶部标签栏做成全宽的，移动端摆不下你想想办法」。
    // 铺满 → 逐级收紧 → 「更多」下拉三档（见 [_resolveLayout]），外加 fill=false
    // 的旧可滚动形态，**共用同一棵子树**：Stack › 滚动通知 › 拖滚 › Row
    // [Expanded(TabBar), 更多槽]。档位之间只换参数（isScrollable / labelPadding /
    // 字号 / 段列表 / controller），TabBar 的 State 不重挂、宿主 controller 不重建。
    //
    // TabBar 自带「选中段自动滚入」，但**不带**桌面鼠标拖滚：Flutter 桌面默认
    // dragDevices 不含 mouse，故恒包 [HorizontalDragScrollable]（不可滚动档里它
    // 只是一层 ScrollConfiguration，无副作用）。两侧渐隐只在可滚动档出现
    // （BUG-1971），由冒泡的 scroll metrics 驱动，不需要拿 TabBar 的内部 controller。
    final Widget bar = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final _SectionTabLayout layout = _resolveLayout(
          context,
          constraints.maxWidth,
        );
        final bool scrollFit = layout.fit == _SectionTabFit.scroll;
        if (!scrollFit) {
          // 非滚动档没有 Scrollable，也就没有滚动通知来收回渐隐：窗口先窄（出了
          // 尾部渐隐）再拉宽时旧 cue 会一直盖在最后一段上。这里只改字段不
          // setState：它们只被可滚动档读取，而那一档下次 build 时新 Scrollable
          // 的首条 metrics 通知随即给出真值。
          _showLeadingOverflowCue = false;
          _showTrailingOverflowCue = false;
          _pendingLeadingOverflowCue = false;
          _pendingTrailingOverflowCue = false;
        }
        final TabController controller = layout.fit == _SectionTabFit.overflow
            ? _syncDisplayController(layout.visible)
            : _controller;
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: <Widget>[
            NotificationListener<ScrollMetricsNotification>(
              onNotification: _handleScrollMetrics,
              child: NotificationListener<ScrollNotification>(
                onNotification: _handleScroll,
                child: HorizontalDragScrollable(
                  child: Row(
                    children: <Widget>[
                      Expanded(child: _buildTabBar(layout, controller)),
                      _buildMoreSlot(layout),
                    ],
                  ),
                ),
              ),
            ),
            if (scrollFit && _showLeadingOverflowCue)
              PositionedDirectional(
                start: 0,
                top: 0,
                bottom: 0,
                child: _SectionTabOverflowFade(
                  key: _kSectionTabLeadingOverflowCueKey,
                  leading: true,
                  floating: widget.floating,
                ),
              ),
            if (scrollFit && _showTrailingOverflowCue)
              PositionedDirectional(
                end: 0,
                top: 0,
                bottom: 0,
                child: _SectionTabOverflowFade(
                  key: _kSectionTabTrailingOverflowCueKey,
                  leading: false,
                  floating: widget.floating,
                ),
              ),
          ],
        );
      },
    );
    if (!widget.floating) return bar;
    return _FloatingSectionTabsFrame(
      naturalWidth: _floatingNaturalWidth(context),
      child: bar,
    );
  }

  /// 浮动胶囊里整排页签的自然宽：与 [_resolveLayout] 同一把量尺（真实字体
  /// 量文字进距），加上各段内边距（Apple 还有文字内衬与页签条两端外边距）。
  double _floatingNaturalWidth(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final List<double> widths = _measureLabels(
      context,
      _labelStyleBase(
        context,
      ).copyWith(fontSize: _baseFontSize(context, apple)),
    );
    final double perTab = apple
        ? _kSectionTabAppleLabelPadding * 2 + kFushiAppleTabContentInset * 2
        : _kSectionTabHorizontalPadding * 2;
    double total = apple ? 16.0 : 0.0;
    for (final double width in widths) {
      total += width + perTab;
    }
    return total;
  }

  /// 真正选中的段下标（全量段序）：宿主持有形态是宿主 controller 的下标，自持
  /// 形态是投影目标 [_targetIndex]。
  int get _realIndex => _hostControlled
      ? widget.controller!.index.clamp(0, widget.tabs.length - 1)
      : _targetIndex;

  /// 量各段文字的真实进距（与 Tab 同一字体、同一文字缩放；按选中态的 w600 量，
  /// 是未选中 w500 的上界，算出来的总宽只会略宽于真实布局、不会撑出滚动）。
  List<double> _measureLabels(BuildContext context, TextStyle style) {
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final List<double> widths = <double>[];
    for (final LibrarySectionTab<T> tab in widget.tabs) {
      final TextPainter painter = TextPainter(
        text: TextSpan(text: tab.label, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      widths.add(painter.width.ceilToDouble() + 1);
      painter.dispose();
    }
    return widths;
  }

  /// 本行宽度下用哪一档（2026-10-04「顶部标签栏全宽、移动端摆不下想办法」）：
  ///
  /// ① **等分铺满**：最宽段 + 默认内边距在 `maxWidth / 段数` 的等分格里放得下
  ///    （TabBar fill 给每段包 Expanded，判据必须是「段数 × 最宽段」而非总和，
  ///    否则一段长其余短时长段会被截）。
  /// ② **逐级收紧后铺满**：按各段自然宽排，内边距从默认（MD3 16 / Apple 12）
  ///    往下收、最低 8；还不够就字号降一级（14 → 13 → 12，不低于 12）。选定
  ///    字号后把剩余宽度均摊回每段两侧，整行恰好铺满、不出滚动。
  /// ③ **前 N 段 + 末尾「更多」下拉**：12 号字 + 8 内边距仍摆不下时，只排得下的
  ///    前 N 段，其余收进 ⌄ 菜单；选中段在溢出区时替换到可见末位，用户永远看得到
  ///    自己在哪。不再横滑截断。
  ///
  /// `fill: false` 的调用方维持旧的贴左可滚动形态。
  _SectionTabLayout _resolveLayout(BuildContext context, double maxWidth) {
    final int n = widget.tabs.length;
    // 浮动胶囊按自然宽贴左、摆不下在胶囊里横滑（M3E floating toolbar 的
    // 内容就是可横滑的一排），不走铺满 / 收紧 / 「更多」三档。
    if (!widget.fill || widget.floating || !maxWidth.isFinite || n == 0) {
      return const _SectionTabLayout(fit: _SectionTabFit.scroll);
    }
    final bool apple = isGlassDesign(context);
    // Apple 页签条自带左右各 8 的外边距（_FushiGlassTabBar 的 padding 默认值）。
    final double available = maxWidth - (apple ? 16.0 : 0.0);
    final double basePadding = apple
        ? _kSectionTabAppleLabelPadding
        : _kSectionTabHorizontalPadding;
    // Apple 文字页签在 label 内边距里还给文字两侧各留一圈内衬（悬停 / 焦点底的
    // 呼吸位），每段实际多占这一截。漏算它时窄屏 4 段（浏览页「发现 / 在线源 /
    // 扩展 / 下载」）被判成「等分放得下」，实际「在线源」被 Tab 的渐隐截断
    // （2026-10-05 用户截图）。
    final double inset = apple ? kFushiAppleTabContentInset * 2 : 0.0;
    final TextStyle style = _labelStyleBase(context);
    final double baseFont = _baseFontSize(context, apple);
    final List<double> fonts = <double>[
      baseFont,
      for (final double size in const <double>[13.0, 12.0])
        if (size < baseFont) size,
    ];

    List<double> widths = _measureLabels(
      context,
      style.copyWith(fontSize: baseFont),
    );
    final double widest = widths.reduce(math.max);
    if ((widest + inset + basePadding * 2) * n <= available) {
      return const _SectionTabLayout(fit: _SectionTabFit.fill);
    }

    for (final double font in fonts) {
      if (font != baseFont) {
        widths = _measureLabels(context, style.copyWith(fontSize: font));
      }
      final double sum = widths.fold<double>(0, (double a, double b) => a + b);
      final double padding = _floorPadding(
        (available - sum - inset * n) / (2 * n),
      );
      if (padding >= _kSectionTabMinLabelPadding) {
        return _SectionTabLayout(
          fit: _SectionTabFit.natural,
          fontSize: font == baseFont ? null : font,
          labelPadding: padding,
        );
      }
    }

    // ③ 溢出：最小字号、最小内边距下能排几段（末位要容得下溢出区里最宽的那段，
    // 因为选中段可能被替换上来）。
    final double room = available - _kSectionTabMoreWidth;
    final List<double> cells = <double>[
      for (final double w in widths)
        w + inset + _kSectionTabMinLabelPadding * 2,
    ];
    int count = 1;
    for (int k = n - 1; k >= 1; k--) {
      double used = 0;
      for (int i = 0; i < k - 1; i++) {
        used += cells[i];
      }
      double tail = 0;
      for (int i = k - 1; i < n; i++) {
        tail = math.max(tail, cells[i]);
      }
      if (used + tail <= room) {
        count = k;
        break;
      }
    }
    final int selected = _realIndex;
    final List<int> visible = <int>[
      for (int i = 0; i < count - 1; i++) i,
      selected >= count - 1 ? selected : count - 1,
    ];
    double visibleText = 0;
    for (final int i in visible) {
      visibleText += widths[i] + inset;
    }
    final double padding = math.max(
      4.0,
      _floorPadding((room - visibleText) / (2 * visible.length)),
    );
    return _SectionTabLayout(
      fit: _SectionTabFit.overflow,
      fontSize: fonts.last == baseFont ? null : fonts.last,
      labelPadding: padding,
      visible: visible,
    );
  }

  /// 往下取到 0.01：均摊出来的内边距若因浮点误差略大，可滚动 TabBar 会多出一丝
  /// 滚动范围并亮起尾部渐隐。
  static double _floorPadding(double value) => (value * 100).floor() / 100;

  /// 页签文字的基准样式（量宽 + 收紧时显式下发字号都从它派生）。
  TextStyle _labelStyleBase(BuildContext context) =>
      (Theme.of(context).textTheme.titleSmall ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.w600,
      );

  /// 默认档字号：MD3 是 titleSmall；Apple 页签把它钳在 12–15（与
  /// `_FushiGlassTabBar` 同口径）。
  double _baseFontSize(BuildContext context, bool apple) {
    final double size =
        Theme.of(context).textTheme.titleSmall?.fontSize ?? 14.0;
    return apple ? size.clamp(12.0, 15.0) : size;
  }

  /// 溢出档的显示用 controller：长度 = 可见段数，下标 = 选中段在可见段里的位置。
  ///
  /// 它只是 [_realIndex] 的投影，不是第二份真相——点击经 [_selectRealIndex] 回到
  /// 宿主 / 自持 controller，再由下一次 build 投回来。可见段数变了（窗口宽度
  /// 变了）才换一个；旧的那个此刻仍挂在 TabBar 上，帧末再释放。
  TabController _syncDisplayController(List<int> visible) {
    final int target = math.max(0, visible.indexOf(_realIndex));
    final TabController? current = _display;
    if (current == null || current.length != visible.length) {
      if (current != null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (Duration _) => current.dispose(),
        );
      }
      return _display = TabController(
        length: visible.length,
        initialIndex: target,
        animationDuration: _animationDuration,
        vsync: this,
      );
    }
    if (current.index != target) {
      // build 期不能 animateTo（会同步通知 TabBar setState）；帧末再滑过去。
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (!mounted || !identical(_display, current)) return;
        if (current.index != target) current.animateTo(target);
      });
    }
    return current;
  }

  /// 按全量段序选中第 [index] 段（溢出档的点击与「更多」菜单共用）。
  void _selectRealIndex(int index) {
    final TabController? host = widget.controller;
    if (host != null) {
      if (host.index != index) host.animateTo(index);
      return;
    }
    widget.onChanged!(widget.tabs[index].value);
    // 宿主拒绝这次切换时可能根本不 rebuild：自持 controller 由投影拉回，显示用
    // controller 靠这次重建重新投影。
    _scheduleProjection();
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) setState(() {});
    });
  }

  /// 「更多」槽：只有溢出档才有按钮，其余档位是零宽占位（Row 的子项结构不变）。
  Widget _buildMoreSlot(_SectionTabLayout layout) {
    if (layout.fit != _SectionTabFit.overflow) return const SizedBox.shrink();
    return Builder(
      builder: (BuildContext anchorContext) => _SectionTabMoreButton(
        onTap: () => _showOverflowSections(anchorContext, layout.visible),
      ),
    );
  }

  Future<void> _showOverflowSections(
    BuildContext anchorContext,
    List<int> visible,
  ) async {
    final RenderBox button = anchorContext.findRenderObject()! as RenderBox;
    final RenderBox overlay =
        Navigator.of(anchorContext).overlay!.context.findRenderObject()!
            as RenderBox;
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );
    final int? picked = await showFushiMenu<int>(
      context: anchorContext,
      position: position,
      items: <PopupMenuEntry<int>>[
        for (int i = 0; i < widget.tabs.length; i++)
          if (!visible.contains(i))
            PopupMenuItem<int>(value: i, child: Text(widget.tabs[i].label)),
      ],
    );
    if (picked == null || !mounted) return;
    _selectRealIndex(picked);
  }

  Widget _buildTabBar(_SectionTabLayout layout, TabController controller) {
    final bool overflow = layout.fit == _SectionTabFit.overflow;
    // 宿主持有形态（非溢出档）不接管点击：TabBar 自己 animateTo 那一个
    // controller，页内的 TabBarView 跟着走，中间不该再插一手。溢出档的 TabBar
    // 挂的是显示用 controller，点击必须映射回全量段序。
    final ValueChanged<int>? onTap = overflow
        ? (int index) => _selectRealIndex(layout.visible[index])
        : _hostControlled
        ? null
        : (int index) {
            widget.onChanged!(widget.tabs[index].value);
            // TabBar 已把指示器移过去了；宿主若不接受这次切换（不改 selected、
            // 也不 rebuild），得靠这次校正把它拉回来。
            _scheduleProjection();
          };
    final List<Widget> tabs = <Widget>[
      if (overflow)
        for (final int i in layout.visible) Tab(text: widget.tabs[i].label)
      else
        for (final LibrarySectionTab<T> tab in widget.tabs)
          Tab(text: tab.label),
    ];
    final double? font = layout.fontSize;
    final TextStyle? labelStyle = font == null
        ? null
        : _labelStyleBase(context).copyWith(fontSize: font);
    final TextStyle? unselectedLabelStyle = labelStyle?.copyWith(
      fontWeight: FontWeight.w500,
    );
    final double? padding = layout.labelPadding;
    final EdgeInsetsGeometry? labelPadding = padding == null
        ? null
        : EdgeInsets.symmetric(horizontal: padding);
    final bool scrollable = layout.fit != _SectionTabFit.fill;
    // 可滚动 TabBar 默认留 52px 起始缩进（[TabAlignment.startOffset]）；首段必须
    // 与页头标题 / 页面内容左缘对齐，故贴左。分隔线去掉：标签行旁边可能还有
    // 页头动作（不在首页外壳里时），画出来是条半截线。
    final TabAlignment alignment = scrollable
        ? TabAlignment.start
        : TabAlignment.fill;
    if (widget.floating && !widget.secondary) {
      final ColorScheme cs = Theme.of(context).colorScheme;
      return FushiTabBar(
        controller: controller,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        dividerHeight: 0,
        labelStyle: labelStyle,
        unselectedLabelStyle: unselectedLabelStyle,
        labelPadding: labelPadding,
        onTap: onTap,
        // M3E：选中段是一枚 secondaryContainer 全胶囊，切换时弹性拉伸着滑过去
        // （elastic = 先伸长够到目标段、再收回，形状随位移变形）。
        indicator: ShapeDecoration(
          shape: const StadiumBorder(),
          color: cs.secondaryContainer,
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        indicatorPadding: const EdgeInsets.symmetric(vertical: 4),
        indicatorAnimation: TabIndicatorAnimation.elastic,
        labelColor: cs.onSecondaryContainer,
        unselectedLabelColor: cs.onSurfaceVariant,
        splashBorderRadius: const BorderRadius.all(Radius.circular(999)),
        tabs: tabs,
      );
    }
    if (widget.secondary) {
      return FushiTabBar.secondary(
        controller: controller,
        isScrollable: scrollable,
        tabAlignment: alignment,
        dividerHeight: 0,
        labelStyle: labelStyle,
        unselectedLabelStyle: unselectedLabelStyle,
        labelPadding: labelPadding,
        onTap: onTap,
        tabs: tabs,
      );
    }
    return FushiTabBar(
      controller: controller,
      isScrollable: scrollable,
      tabAlignment: alignment,
      dividerHeight: 0,
      labelStyle: labelStyle,
      unselectedLabelStyle: unselectedLabelStyle,
      labelPadding: labelPadding,
      onTap: onTap,
      tabs: tabs,
    );
  }
}

/// [FushiSectionTabBar] 的排布档位，见 `_resolveLayout`。
enum _SectionTabFit { fill, natural, overflow, scroll }

class _SectionTabLayout {
  const _SectionTabLayout({
    required this.fit,
    this.fontSize,
    this.labelPadding,
    this.visible = const <int>[],
  });

  final _SectionTabFit fit;

  /// 显式字号；null = 主题默认（不下发 labelStyle，观感与旧实现逐像素相同）。
  final double? fontSize;

  /// 单侧 label 内边距；null = 控件默认。
  final double? labelPadding;

  /// 溢出档里实际显示的段（全量段序下标，按显示顺序）。
  final List<int> visible;
}

/// 溢出档末尾的「更多」：与页签同高的 ⌄，点开列出未显示的分区。
///
/// 它在 [FushiAdjustableSegmented] 的 ExcludeFocus 里，不是单独的焦点停靠点——
/// 键盘 / 手柄在整排这一个停靠点上用左右方向键就能走遍**全部**分区（含溢出区，
/// 走到时它被替换到可见末位），菜单只服务指针。两套设计系统同一结构：Apple
/// 去水波、次要标签色 + SF chevron；MD3 圆形水波 + onSurfaceVariant。
class _SectionTabMoreButton extends StatelessWidget {
  const _SectionTabMoreButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final Color color = apple
        ? appleColorsOf(context).secondaryLabel
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Tooltip(
      message: t.common_more_actions,
      child: Semantics(
        button: true,
        label: t.common_more_actions,
        child: InkResponse(
          onTap: onTap,
          radius: _kSectionTabMoreWidth / 2,
          splashFactory: apple ? NoSplash.splashFactory : null,
          highlightColor: apple ? Colors.transparent : null,
          child: SizedBox(
            width: _kSectionTabMoreWidth,
            height: _kSectionTabMoreWidth,
            child: Icon(
              apple ? CupertinoIcons.chevron_down : Icons.expand_more,
              size: apple ? 17 : 24,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

/// 不可交互的边缘渐隐：用当前 scaffold 背景盖住离屏方向的 tab 尾端，形成“内容仍在
/// 延伸”的视觉线索。方向走 [PositionedDirectional]，RTL 下同样按逻辑首尾工作。
class _SectionTabOverflowFade extends StatelessWidget {
  const _SectionTabOverflowFade({
    required this.leading,
    this.floating = false,
    super.key,
  });

  final bool leading;

  /// 在浮动胶囊里：渐隐要用胶囊底色才盖得住。
  final bool floating;

  @override
  Widget build(BuildContext context) {
    // eink：渐隐是一条灰阶过渡带 = 抖动噪点；去掉，尾端 tab 直接截断（横向拖滚照常）。
    if (isEinkTheme(context)) return const SizedBox.shrink();
    final Color background = floating
        ? FushiFloatingToolbarSurface.colorOf(context)
        : Theme.of(context).scaffoldBackgroundColor;
    return IgnorePointer(
      child: SizedBox(
        width: _kSectionTabOverflowFadeWidth,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: leading ? Alignment.centerLeft : Alignment.centerRight,
              end: leading ? Alignment.centerRight : Alignment.centerLeft,
              colors: <Color>[background, background.withValues(alpha: 0)],
            ),
          ),
        ),
      ),
    );
  }
}

/// 浮动页签胶囊的外框：按页签自然宽（加胶囊内边距）贴左，最宽不超过可用宽；
/// 超出时胶囊吃满可用宽、页签在里面横滑。
class _FloatingSectionTabsFrame extends StatelessWidget {
  const _FloatingSectionTabsFrame({
    required this.naturalWidth,
    required this.child,
  });

  /// 整排页签的自然宽（不含胶囊内边距）。
  final double naturalWidth;
  final Widget child;

  static const double _horizontalPadding = 6;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // +2：量尺取整的余量，免得刚好摆得下时多出一丝滚动范围亮起渐隐。
        final double wanted = naturalWidth + _horizontalPadding * 2 + 2;
        final double width = constraints.maxWidth.isFinite
            ? math.min(wanted, constraints.maxWidth)
            : wanted;
        return Align(
          alignment: AlignmentDirectional.centerStart,
          widthFactor: constraints.maxWidth.isFinite ? null : 1,
          child: SizedBox(
            width: width,
            child: FushiFloatingToolbarSurface(
              padding: const EdgeInsets.symmetric(
                horizontal: _horizontalPadding,
                vertical: 4,
              ),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
