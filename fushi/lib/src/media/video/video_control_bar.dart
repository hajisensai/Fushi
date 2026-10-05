import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// 视频控制条（底栏 / 顶栏按钮组）在**空间不够**时的唯一处置：按钮永远原尺寸，
/// 放不下的按优先级收进末尾的「⋯」菜单（BUG-2832）。
///
/// 旧实现两条栏各有一种「放不下」的补丁，都错在同一处——**把按钮变形**：
/// - 底栏三区给 [FittedBox] scaleDown：中间传输簇只拿左右两簇剩下的缝，整排缩到
///   四成大小，点击区远小于 48dp，同一条栏两种尺寸；
/// - 顶栏按钮组给横向 `ListView`：右组从左边被裁，「剧集列表」只露半个图标。
///
/// 这里的顺序是：① 全部原样放得下就原样；② 放不下先把带文字的按钮换成纯图标
/// （±10s，`compactChild`）；③ 还放不下就从优先级最低的开始收（成对的按钮一起收），
/// 直到「剩下的 + ⋯」放得下为止。返回 / 播放暂停 / 时间这类钉死项永不收。

/// 条目落在控制条的哪一簇。
enum VideoBarCluster {
  /// 从左边缘起排。
  start,

  /// 能居中就钉几何正中，放不下就在左右两簇之间平移（[videoBottomBarCenterStart]）。
  center,

  /// 贴右边缘；「⋯」永远是这一簇的最后一个。
  end,
}

/// 成对按钮：一侧收进菜单另一侧必须一起收，否则 `−10s` 在、`+10s` 没了。
enum VideoBarHideGroup { seek, cue, frame }

/// 居中簇的起点 x：**能居中就居中，放不下就在左右两簇之间的空隙里平移**。
///
/// - 理想位置是几何正中 `(width - centerWidth) / 2`（BUG-257：play 钉在整条底栏
///   正中，与两侧按钮数量无关）。
/// - 中簇不得压进左簇（`>= leftWidth`），也不得压进右簇
///   （`<= width - rightWidth - centerWidth`）。
/// - 空隙比中簇还窄时紧贴左簇右缘（[planVideoControlBar] 保证正常情况下不会发生，
///   只有钉死项本身就塞不下时才会走到，此时整条栏裁切）。
double videoBottomBarCenterStart({
  required double width,
  required double leftWidth,
  required double centerWidth,
  required double rightWidth,
}) {
  final double ideal = (width - centerWidth) / 2;
  final double minStart = leftWidth;
  final double maxStart = width - rightWidth - centerWidth;
  if (maxStart <= minStart) return minStart;
  return ideal.clamp(minStart, maxStart).toDouble();
}

/// 控件在控制条里的收起优先级：数值越小越先收进「⋯」；`null` = 钉死、永不收。
///
/// 排序依据是「失去它代价多大」：返回 / 播放暂停 / 时间是控制条存在的意义；全屏、
/// 设置、字幕列表是离开当前困境的出口（窄窗正是要靠它们换布局）；seek / 上下句是
/// 学习主路径；其余按使用频率递减，逐帧最冷门。
int? videoControlItemBarPriority(VideoControlItem item) {
  switch (item) {
    case VideoControlItem.back:
    case VideoControlItem.playPause:
    case VideoControlItem.positionIndicator:
    case VideoControlItem.title:
      return null;
    case VideoControlItem.fullscreen:
      return 90;
    case VideoControlItem.settings:
      return 88;
    case VideoControlItem.subtitleList:
      return 85;
    case VideoControlItem.seekBackward:
    case VideoControlItem.seekForward:
      return 80;
    case VideoControlItem.previousCue:
    case VideoControlItem.replayCue:
    case VideoControlItem.nextCue:
      return 75;
    case VideoControlItem.volume:
      return 70;
    case VideoControlItem.speed:
      return 65;
    case VideoControlItem.subtitleTrack:
    case VideoControlItem.audioTrack:
      return 60;
    case VideoControlItem.favoriteSentence:
    case VideoControlItem.immersiveLock:
      return 55;
    case VideoControlItem.previousEpisode:
    case VideoControlItem.nextEpisode:
    case VideoControlItem.episodeList:
      return 50;
    case VideoControlItem.screenshot:
      return 45;
    case VideoControlItem.previousChapter:
    case VideoControlItem.nextChapter:
    case VideoControlItem.chapterList:
      return 40;
    case VideoControlItem.clipExport:
      return 30;
    case VideoControlItem.customAction1:
    case VideoControlItem.customAction2:
    case VideoControlItem.customAction3:
    case VideoControlItem.customAction4:
      return 20;
    case VideoControlItem.frameBackward:
    case VideoControlItem.frameForward:
      return 10;
  }
}

/// 控件所属的成对收起组；不成对的返回 null。
VideoBarHideGroup? videoControlItemBarHideGroup(VideoControlItem item) {
  switch (item) {
    case VideoControlItem.seekBackward:
    case VideoControlItem.seekForward:
      return VideoBarHideGroup.seek;
    case VideoControlItem.previousCue:
    case VideoControlItem.replayCue:
    case VideoControlItem.nextCue:
      return VideoBarHideGroup.cue;
    case VideoControlItem.frameBackward:
    case VideoControlItem.frameForward:
      return VideoBarHideGroup.frame;
    default:
      return null;
  }
}

/// [planVideoControlBar] 的输入：一个条目量出来的宽度与收起属性。
@immutable
class VideoBarMeasure {
  const VideoBarMeasure({
    required this.fullWidth,
    double? compactWidth,
    this.priority,
    this.group,
  }) : compactWidth = compactWidth ?? fullWidth;

  /// 原样（带文字）时的宽。
  final double fullWidth;

  /// 紧凑形态（纯图标）时的宽；没有紧凑形态时等于 [fullWidth]。
  final double compactWidth;

  /// 见 [videoControlItemBarPriority]；null = 钉死。
  final int? priority;

  /// 见 [VideoBarHideGroup]。
  final Object? group;
}

/// [planVideoControlBar] 的结论：要不要换紧凑形态、哪些条目收进「⋯」。
@immutable
class VideoBarPlan {
  const VideoBarPlan({this.compact = false, this.hidden = const <int>{}});

  /// 全部原样显示。
  static const VideoBarPlan showAll = VideoBarPlan();

  /// 带紧凑形态的条目是否换成紧凑形态。
  final bool compact;

  /// 收进「⋯」的条目下标。
  final Set<int> hidden;

  /// 有条目被收起 = 要画「⋯」。
  bool get overflowing => hidden.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is VideoBarPlan &&
      other.compact == compact &&
      setEquals(other.hidden, hidden);

  @override
  int get hashCode => Object.hash(compact, Object.hashAllUnordered(hidden));

  @override
  String toString() => 'VideoBarPlan(compact: $compact, hidden: $hidden)';
}

/// 布局浮点误差容差：宽度来自 `dp × 界面缩放`，两次求和顺序不同可能差一个 ulp。
const double _kFitTolerance = 1e-6;

/// 控制条的放置决策（纯函数，见 [VideoControlBar] 类注释的三步顺序）。
///
/// [maxWidth] 非有限（无界约束）时一律原样。钉死项本身就超宽时返回「能收的全收」，
/// 由渲染层裁切——那是窗口小到连返回键都放不下的退化情形，不再缩放。
VideoBarPlan planVideoControlBar({
  required List<VideoBarMeasure> entries,
  required double maxWidth,
  required double overflowButtonWidth,
}) {
  double total({required bool compact, required Set<int> hidden}) {
    double sum = 0;
    for (int i = 0; i < entries.length; i++) {
      if (hidden.contains(i)) continue;
      sum += compact ? entries[i].compactWidth : entries[i].fullWidth;
    }
    return sum;
  }

  bool fits(double width) => width <= maxWidth + _kFitTolerance;

  if (fits(total(compact: false, hidden: const <int>{}))) {
    return VideoBarPlan.showAll;
  }
  if (fits(total(compact: true, hidden: const <int>{}))) {
    return const VideoBarPlan(compact: true);
  }
  final Set<int> hidden = <int>{};
  for (final List<int> unit in _videoBarHideOrder(entries)) {
    hidden.addAll(unit);
    if (fits(total(compact: true, hidden: hidden) + overflowButtonWidth)) {
      break;
    }
  }
  return VideoBarPlan(compact: true, hidden: hidden);
}

/// 收起顺序：优先级升序；同优先级先收靠后的（离钉死的返回 / 播放更远）。成对的条目
/// 合成一个单元，在组内第一个被轮到的位置一起收。
List<List<int>> _videoBarHideOrder(List<VideoBarMeasure> entries) {
  final List<int> order =
      <int>[
        for (int i = 0; i < entries.length; i++)
          if (entries[i].priority != null) i,
      ]..sort((int a, int b) {
        final int byPriority = entries[a].priority!.compareTo(
          entries[b].priority!,
        );
        return byPriority != 0 ? byPriority : b.compareTo(a);
      });
  final Set<Object> emittedGroups = <Object>{};
  final List<List<int>> units = <List<int>>[];
  for (final int i in order) {
    final Object? group = entries[i].group;
    if (group == null) {
      units.add(<int>[i]);
      continue;
    }
    if (!emittedGroups.add(group)) continue;
    units.add(<int>[
      for (final int j in order)
        if (entries[j].group == group) j,
    ]);
  }
  return units;
}

/// 收进「⋯」后菜单里那一行。
@immutable
class VideoBarMenuAction {
  const VideoBarMenuAction({
    required this.icon,
    required this.label,
    required this.onSelected,
  });

  final IconData icon;
  final String label;
  final VoidCallback onSelected;
}

/// 控制条上的一个条目。
@immutable
class VideoBarEntry {
  const VideoBarEntry({
    required this.child,
    this.compactChild,
    this.cluster = VideoBarCluster.start,
    this.priority,
    this.group,
    this.menuAction,
    this.onFolded,
  }) : assert(
         priority == null || menuAction != null,
         'a collapsible entry must say what its overflow-menu row does',
       );

  /// 原样形态。
  final Widget child;

  /// 紧凑形态（如 ±10s 去掉文字）；null = 没有，紧凑时仍画 [child]。
  final Widget? compactChild;

  final VideoBarCluster cluster;

  /// 见 [videoControlItemBarPriority]；null = 钉死、永不收。
  final int? priority;

  /// 见 [VideoBarHideGroup]。
  final Object? group;

  /// 收起后在「⋯」菜单里的那一行；钉死项可不给。
  final VideoBarMenuAction? menuAction;

  /// 这一项刚从栏上收进「⋯」时（帧尾）调用。被收起的按钮不再绘制，挂在它身上的
  /// 东西（如以它为锚点的浮层）要在这里收场，否则会锚在一个看不见的按钮上。
  final VoidCallback? onFolded;
}

/// 簇的外形：每个非空簇画成一枚悬浮胶囊（Material 3 Expressive floating
/// toolbar）——控制条不再是一整条贴边的实体栏，画面在胶囊之间、之外照常露出。
///
/// 胶囊只是同一个 [VideoControlBar] 的绘制层：收起判据（[planVideoControlBar]）、
/// 「⋯」、焦点资格与命中链路全部不变，只是每簇多出左右 [padding]、簇与簇之间留
/// [gap]，这部分宽度在规划前就从可用宽里扣掉，所以「放得下」的结论仍然只有一个。
@immutable
class VideoBarClusterStyle {
  const VideoBarClusterStyle({
    required this.color,
    this.centerColor,
    this.padding = 4,
    this.verticalPadding = 2,
    this.gap = 8,
    this.elevation = 3,
    this.shadowColor = const Color(0x73000000),
    this.border,
    this.verticalAlignment = 0,
  });

  /// 胶囊底色（起始 / 末尾簇）。
  final Color color;

  /// 居中簇（传输键）的底色；null = 同 [color]。M3E 的「vibrant」浮动工具栏。
  final Color? centerColor;

  /// 胶囊左右内边距（按钮到胶囊边缘）。
  final double padding;

  /// 胶囊上下内边距（胶囊高 = 最高按钮 + 2 × 本值）。
  final double verticalPadding;

  /// 相邻胶囊的最小间距。
  final double gap;

  /// 阴影高度（0 = 无阴影，墨水屏）。
  final double elevation;

  final Color shadowColor;

  /// 描边（墨水屏用）；null = 无。
  final BorderSide? border;

  /// 胶囊在条高里的竖直位置：-1 顶、0 居中、1 贴底。
  final double verticalAlignment;

  /// [cluster] 那枚胶囊的底色。
  Color colorFor(VideoBarCluster cluster) =>
      cluster == VideoBarCluster.center ? (centerColor ?? color) : color;

  @override
  bool operator ==(Object other) =>
      other is VideoBarClusterStyle &&
      other.color == color &&
      other.centerColor == centerColor &&
      other.padding == padding &&
      other.verticalPadding == verticalPadding &&
      other.gap == gap &&
      other.elevation == elevation &&
      other.shadowColor == shadowColor &&
      other.border == border &&
      other.verticalAlignment == verticalAlignment;

  @override
  int get hashCode => Object.hash(
    color,
    centerColor,
    padding,
    verticalPadding,
    gap,
    elevation,
    shadowColor,
    border,
    verticalAlignment,
  );
}

/// 按钮永远原尺寸、放不下就收进「⋯」的控制条（BUG-2832）。
///
/// - [fill] 为 true（底栏）：占满约束宽，start 簇贴左、end 簇贴右、center 簇居中；
/// - [fill] 为 false（顶栏按钮组）：宽度收缩到实际显示的内容，交给外层
///   （`VideoTopBarSlots`）定位。
///
/// 被收起的条目仍挂在树上（保住它们的状态，如浮层锚点），但**不绘制、不参与命中、
/// 不进语义树**，并经 [ExcludeFocus] 退出 Tab / 手柄遍历。焦点资格取决于布局结论，
/// 而 build 先于 layout，所以这一位在布局得出新结论后的帧尾同步（只影响焦点资格，
/// 不影响尺寸，不会形成布局回环）。
class VideoControlBar extends StatefulWidget {
  const VideoControlBar({
    required this.entries,
    required this.moreButtonBuilder,
    this.fill = true,
    this.clusterStyle,
    super.key,
  });

  final List<VideoBarEntry> entries;

  /// 画「⋯」按钮：调用方负责外观（与其它控制条按钮同款），按下时调 `open`。
  final Widget Function(VoidCallback open) moreButtonBuilder;

  final bool fill;

  /// 非 null 时每簇画成一枚悬浮胶囊（[VideoBarClusterStyle]）；null = 旧的透明条。
  final VideoBarClusterStyle? clusterStyle;

  @override
  State<VideoControlBar> createState() => _VideoControlBarState();
}

class _VideoControlBarState extends State<VideoControlBar> {
  /// 驱动 [ExcludeFocus] 的那份结论（帧尾同步，见类注释）。
  final ValueNotifier<VideoBarPlan> _focusPlan = ValueNotifier<VideoBarPlan>(
    VideoBarPlan.showAll,
  );

  /// 最近一次布局得出的结论（同步更新；菜单按它列条目）。
  VideoBarPlan _laidOutPlan = VideoBarPlan.showAll;

  bool _focusSyncScheduled = false;

  final GlobalKey _moreButtonKey = GlobalKey(debugLabel: 'video-bar-more');

  @override
  void dispose() {
    _focusPlan.dispose();
    super.dispose();
  }

  void _onLayoutPlan(VideoBarPlan plan) {
    _laidOutPlan = plan;
    if (plan == _focusPlan.value || _focusSyncScheduled) return;
    _focusSyncScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _focusSyncScheduled = false;
      if (!mounted) return;
      final VideoBarPlan previous = _focusPlan.value;
      final VideoBarPlan next = _laidOutPlan;
      _focusPlan.value = next;
      for (final int i in next.hidden.difference(previous.hidden)) {
        if (i < widget.entries.length) widget.entries[i].onFolded?.call();
      }
    });
  }

  bool _shows(VideoBarPlan plan, _VideoBarChildRole role, int entry) {
    switch (role) {
      case _VideoBarChildRole.more:
        return plan.overflowing;
      case _VideoBarChildRole.full:
      case _VideoBarChildRole.compact:
        if (plan.hidden.contains(entry)) return false;
        final bool useCompact =
            plan.compact && widget.entries[entry].compactChild != null;
        return useCompact == (role == _VideoBarChildRole.compact);
    }
  }

  Widget _slot(_VideoBarChildRole role, int entry, Widget child) {
    return _VideoBarSlot(
      role: role,
      entry: entry,
      child: ValueListenableBuilder<VideoBarPlan>(
        valueListenable: _focusPlan,
        builder: (BuildContext _, VideoBarPlan plan, Widget? slotChild) =>
            ExcludeFocus(
              excluding: !_shows(plan, role, entry),
              child: slotChild!,
            ),
        child: child,
      ),
    );
  }

  Future<void> _openOverflowMenu() async {
    final List<VideoBarMenuAction> actions = <VideoBarMenuAction>[
      for (int i = 0; i < widget.entries.length; i++)
        if (_laidOutPlan.hidden.contains(i))
          if (widget.entries[i].menuAction case final VideoBarMenuAction a) a,
    ];
    final RenderObject? button = _moreButtonKey.currentContext
        ?.findRenderObject();
    final NavigatorState navigator = Navigator.of(context);
    final RenderObject? overlay = navigator.overlay?.context.findRenderObject();
    if (actions.isEmpty || button is! RenderBox || overlay is! RenderBox) {
      return;
    }
    // 相对 overlay 求按钮矩形（与 PopupMenuButton 同法）：沿途的界面缩放中和 transform
    // 都折进 localToGlobal 的 ancestor 换算里，菜单贴着按钮弹出。
    final Rect anchor = Rect.fromPoints(
      button.localToGlobal(Offset.zero, ancestor: overlay),
      button.localToGlobal(
        button.size.bottomRight(Offset.zero),
        ancestor: overlay,
      ),
    );
    final VideoBarMenuAction? chosen = await showFushiMenu<VideoBarMenuAction>(
      context: context,
      position: RelativeRect.fromRect(anchor, Offset.zero & overlay.size),
      items: <PopupMenuEntry<VideoBarMenuAction>>[
        for (final VideoBarMenuAction action in actions)
          PopupMenuItem<VideoBarMenuAction>(
            value: action,
            child: Row(
              children: <Widget>[
                FushiIcon(action.icon, size: 20),
                const SizedBox(width: 12),
                Flexible(child: Text(action.label)),
              ],
            ),
          ),
      ],
    );
    chosen?.onSelected();
  }

  @override
  Widget build(BuildContext context) {
    final Widget layout = _VideoControlBarLayout(
      fill: widget.fill,
      clusterStyle: widget.clusterStyle,
      specs: <_VideoBarSpec>[
        for (final VideoBarEntry entry in widget.entries)
          _VideoBarSpec(
            cluster: entry.cluster,
            priority: entry.priority,
            group: entry.group,
          ),
      ],
      onPlan: _onLayoutPlan,
      children: <Widget>[
        for (int i = 0; i < widget.entries.length; i++) ...<Widget>[
          _slot(_VideoBarChildRole.full, i, widget.entries[i].child),
          if (widget.entries[i].compactChild case final Widget compact)
            _slot(_VideoBarChildRole.compact, i, compact),
        ],
        _slot(
          _VideoBarChildRole.more,
          -1,
          KeyedSubtree(
            key: _moreButtonKey,
            child: widget.moreButtonBuilder(
              () => unawaited(_openOverflowMenu()),
            ),
          ),
        ),
      ],
    );
    if (widget.clusterStyle == null) return layout;
    // 胶囊是实体：点在胶囊的留白上（按钮之间、胶囊边缘）不该穿透到画面——那会
    // 被 media_kit 判成「点画面」去暂停 / 收起控制条。空 onTap 的识别器比祖先的
    // 画面点击更深，竞技场里先胜出；按钮自身更深，照旧先拿到点击。deferToChild：
    // 只有命中胶囊（[_RenderVideoControlBar.hitTestSelf]）或按钮时才参与，胶囊
    // 之间的空隙照常穿透到画面。
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onTap: () {},
      excludeFromSemantics: true,
      child: layout,
    );
  }
}

enum _VideoBarChildRole { full, compact, more }

@immutable
class _VideoBarSpec {
  const _VideoBarSpec({required this.cluster, this.priority, this.group});

  final VideoBarCluster cluster;
  final int? priority;
  final Object? group;

  @override
  bool operator ==(Object other) =>
      other is _VideoBarSpec &&
      other.cluster == cluster &&
      other.priority == priority &&
      other.group == group;

  @override
  int get hashCode => Object.hash(cluster, priority, group);
}

class _VideoBarParentData extends ContainerBoxParentData<RenderBox> {
  _VideoBarChildRole role = _VideoBarChildRole.full;
  int entry = -1;

  /// 本轮布局是否绘制 / 命中 / 进语义树。
  bool shown = false;
}

class _VideoBarSlot extends ParentDataWidget<_VideoBarParentData> {
  const _VideoBarSlot({
    required this.role,
    required this.entry,
    required super.child,
  });

  final _VideoBarChildRole role;
  final int entry;

  @override
  void applyParentData(RenderObject renderObject) {
    final _VideoBarParentData data =
        renderObject.parentData! as _VideoBarParentData;
    if (data.role == role && data.entry == entry) return;
    data
      ..role = role
      ..entry = entry;
    renderObject.parent?.markNeedsLayout();
  }

  @override
  Type get debugTypicalAncestorWidgetClass => _VideoControlBarLayout;
}

class _VideoControlBarLayout extends MultiChildRenderObjectWidget {
  const _VideoControlBarLayout({
    required this.fill,
    required this.clusterStyle,
    required this.specs,
    required this.onPlan,
    required super.children,
  });

  final bool fill;
  final VideoBarClusterStyle? clusterStyle;
  final List<_VideoBarSpec> specs;
  final ValueChanged<VideoBarPlan> onPlan;

  @override
  _RenderVideoControlBar createRenderObject(BuildContext context) =>
      _RenderVideoControlBar(
        fill: fill,
        clusterStyle: clusterStyle,
        specs: specs,
        onPlan: onPlan,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderVideoControlBar renderObject,
  ) {
    renderObject
      ..fill = fill
      ..clusterStyle = clusterStyle
      ..specs = specs
      ..onPlan = onPlan;
  }
}

/// 一次排布的结果；`performLayout` 与 `computeDryLayout` 共用同一套计算。
class _VideoBarArrangement {
  _VideoBarArrangement({
    required this.size,
    required this.plan,
    required this.offsets,
    required this.contentWidth,
    this.pills = const <(VideoBarCluster, Rect)>[],
  });

  final Size size;
  final VideoBarPlan plan;

  /// 每枚悬浮胶囊（簇 + 本地矩形）；没有 [VideoBarClusterStyle] 时为空。
  final List<(VideoBarCluster, Rect)> pills;

  /// 显示中的子节点 → 偏移；不在表里的不显示。
  final Map<RenderBox, Offset> offsets;
  final double contentWidth;
}

class _RenderVideoControlBar extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _VideoBarParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _VideoBarParentData> {
  _RenderVideoControlBar({
    required bool fill,
    required VideoBarClusterStyle? clusterStyle,
    required List<_VideoBarSpec> specs,
    required this.onPlan,
  }) : _fill = fill,
       _clusterStyle = clusterStyle,
       _specs = specs;

  VideoBarClusterStyle? _clusterStyle;
  set clusterStyle(VideoBarClusterStyle? value) {
    if (value == _clusterStyle) return;
    final VideoBarClusterStyle? old = _clusterStyle;
    final bool geometry =
        value == null ||
        old == null ||
        value.padding != old.padding ||
        value.verticalPadding != old.verticalPadding ||
        value.gap != old.gap ||
        value.verticalAlignment != old.verticalAlignment;
    _clusterStyle = value;
    if (geometry) {
      markNeedsLayout();
    } else {
      markNeedsPaint();
    }
  }

  /// 最近一次布局的胶囊（绘制 / 命中用）。
  List<(VideoBarCluster, Rect)> _pills = const <(VideoBarCluster, Rect)>[];

  /// 有条目落在哪些簇（不论本轮显不显示）。胶囊的留白按这份「可能出现的簇」预扣，
  /// 规划结论与是否真的收起无关、不会来回抖。
  Set<VideoBarCluster> get _presentClusters => <VideoBarCluster>{
    for (final _VideoBarSpec spec in _specs) spec.cluster,
  };

  /// 胶囊额外占的宽（内边距 + 簇间距）。
  double _pillReserve(Iterable<VideoBarCluster> clusters) {
    final VideoBarClusterStyle? style = _clusterStyle;
    if (style == null) return 0;
    final int n = clusters.length;
    if (n == 0) return 0;
    return n * 2 * style.padding + (n - 1) * style.gap;
  }

  bool _fill;
  set fill(bool value) {
    if (value == _fill) return;
    _fill = value;
    markNeedsLayout();
  }

  List<_VideoBarSpec> _specs;
  set specs(List<_VideoBarSpec> value) {
    if (listEquals(value, _specs)) return;
    _specs = value;
    markNeedsLayout();
  }

  ValueChanged<VideoBarPlan> onPlan;

  bool _clipsContent = false;
  final LayerHandle<ClipRectLayer> _clipLayer = LayerHandle<ClipRectLayer>();

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _VideoBarParentData) {
      child.parentData = _VideoBarParentData();
    }
  }

  _VideoBarParentData _data(RenderBox child) =>
      child.parentData! as _VideoBarParentData;

  Iterable<RenderBox> get _children sync* {
    RenderBox? child = firstChild;
    while (child != null) {
      yield child;
      child = childAfter(child);
    }
  }

  _VideoBarArrangement _arrange(
    BoxConstraints constraints,
    ChildLayouter layoutChild,
  ) {
    final int count = _specs.length;
    // 子项一律按固有宽量（宽度无界、高度不超过栏高）：按钮的尺寸由它自己决定，
    // 这条栏只决定放不放它，不改它的大小。
    final BoxConstraints childConstraints = BoxConstraints(
      maxHeight: constraints.maxHeight,
    );
    final Map<RenderBox, Size> sizes = <RenderBox, Size>{};
    final List<double> full = List<double>.filled(count, 0);
    final List<double?> compact = List<double?>.filled(count, null);
    RenderBox? more;
    for (final RenderBox child in _children) {
      final Size childSize = layoutChild(child, childConstraints);
      sizes[child] = childSize;
      final _VideoBarParentData data = _data(child);
      switch (data.role) {
        case _VideoBarChildRole.more:
          more = child;
        case _VideoBarChildRole.full:
          if (data.entry < count) full[data.entry] = childSize.width;
        case _VideoBarChildRole.compact:
          if (data.entry < count) compact[data.entry] = childSize.width;
      }
    }
    final double moreWidth = more == null ? 0 : sizes[more]!.width;
    final VideoBarPlan plan = planVideoControlBar(
      entries: <VideoBarMeasure>[
        for (int i = 0; i < count; i++)
          VideoBarMeasure(
            fullWidth: full[i],
            compactWidth: compact[i],
            priority: _specs[i].priority,
            group: _specs[i].group,
          ),
      ],
      maxWidth: constraints.maxWidth - _pillReserve(_presentClusters),
      overflowButtonWidth: moreWidth,
    );

    bool shows(RenderBox child) {
      final _VideoBarParentData data = _data(child);
      if (data.role == _VideoBarChildRole.more) return plan.overflowing;
      if (data.entry >= count || plan.hidden.contains(data.entry)) {
        return false;
      }
      final bool useCompact = plan.compact && compact[data.entry] != null;
      return useCompact == (data.role == _VideoBarChildRole.compact);
    }

    VideoBarCluster clusterOf(RenderBox child) {
      final _VideoBarParentData data = _data(child);
      return data.role == _VideoBarChildRole.more
          ? VideoBarCluster.end
          : _specs[data.entry].cluster;
    }

    // 子节点顺序即条目顺序，「⋯」恒在最后——所以它自然排在 end 簇末尾。
    final List<RenderBox> shown = <RenderBox>[
      for (final RenderBox child in _children)
        if (shows(child)) child,
    ];
    final Map<VideoBarCluster, double> clusterWidth = <VideoBarCluster, double>{
      for (final VideoBarCluster c in VideoBarCluster.values) c: 0,
    };
    double tallest = 0;
    for (final RenderBox child in shown) {
      clusterWidth[clusterOf(child)] =
          clusterWidth[clusterOf(child)]! + sizes[child]!.width;
      tallest = math.max(tallest, sizes[child]!.height);
    }
    final double startWidth = clusterWidth[VideoBarCluster.start]!;
    final double centerWidth = clusterWidth[VideoBarCluster.center]!;
    final double endWidth = clusterWidth[VideoBarCluster.end]!;
    final VideoBarClusterStyle? style = _clusterStyle;
    if (style != null) {
      return _arrangePills(
        constraints: constraints,
        style: style,
        plan: plan,
        shown: shown,
        sizes: sizes,
        clusterOf: clusterOf,
        clusterWidth: clusterWidth,
        tallest: tallest,
      );
    }
    final double contentWidth = startWidth + centerWidth + endWidth;
    final Size size = Size(
      _fill && constraints.hasBoundedWidth
          ? constraints.maxWidth
          : constraints.constrainWidth(contentWidth),
      constraints.hasBoundedHeight
          ? constraints.maxHeight
          : constraints.constrainHeight(tallest),
    );

    final Map<VideoBarCluster, double> cursor = <VideoBarCluster, double>{
      VideoBarCluster.start: 0,
      VideoBarCluster.center: videoBottomBarCenterStart(
        width: size.width,
        leftWidth: startWidth,
        centerWidth: centerWidth,
        rightWidth: endWidth,
      ),
      VideoBarCluster.end: math.max(
        startWidth + centerWidth,
        size.width - endWidth,
      ),
    };
    final Map<RenderBox, Offset> offsets = <RenderBox, Offset>{};
    for (final RenderBox child in shown) {
      final VideoBarCluster cluster = clusterOf(child);
      final Size childSize = sizes[child]!;
      offsets[child] = Offset(
        cursor[cluster]!,
        (size.height - childSize.height) / 2,
      );
      cursor[cluster] = cursor[cluster]! + childSize.width;
    }
    return _VideoBarArrangement(
      size: size,
      plan: plan,
      offsets: offsets,
      contentWidth: contentWidth,
    );
  }

  /// 悬浮胶囊排布：每个**本轮有显示内容**的簇包一枚胶囊（左右
  /// [VideoBarClusterStyle.padding]），胶囊之间至少隔 [VideoBarClusterStyle.gap]。
  /// fill 时 start 胶囊贴左、end 胶囊贴右、center 胶囊能居中就钉正中
  /// （[videoBottomBarCenterStart]，相邻胶囊连同间距当作左右两簇）；非 fill 时依次
  /// 紧排。按钮在胶囊里竖直居中，胶囊在条高里按
  /// [VideoBarClusterStyle.verticalAlignment] 放。
  _VideoBarArrangement _arrangePills({
    required BoxConstraints constraints,
    required VideoBarClusterStyle style,
    required VideoBarPlan plan,
    required List<RenderBox> shown,
    required Map<RenderBox, Size> sizes,
    required VideoBarCluster Function(RenderBox) clusterOf,
    required Map<VideoBarCluster, double> clusterWidth,
    required double tallest,
  }) {
    final List<VideoBarCluster> active = <VideoBarCluster>[
      for (final VideoBarCluster c in VideoBarCluster.values)
        if (clusterWidth[c]! > 0) c,
    ];
    final Map<VideoBarCluster, double> pillWidth = <VideoBarCluster, double>{
      for (final VideoBarCluster c in VideoBarCluster.values)
        c: clusterWidth[c]! > 0 ? clusterWidth[c]! + 2 * style.padding : 0,
    };
    final double pillHeight = tallest + 2 * style.verticalPadding;
    final double contentWidth =
        pillWidth.values.fold<double>(0, (double a, double b) => a + b) +
        math.max(0, active.length - 1) * style.gap;
    final Size size = Size(
      _fill && constraints.hasBoundedWidth
          ? constraints.maxWidth
          : constraints.constrainWidth(contentWidth),
      constraints.hasBoundedHeight
          ? constraints.maxHeight
          : constraints.constrainHeight(pillHeight),
    );
    final double startPill = pillWidth[VideoBarCluster.start]!;
    final double centerPill = pillWidth[VideoBarCluster.center]!;
    final double endPill = pillWidth[VideoBarCluster.end]!;
    final double startSpan = startPill > 0 ? startPill + style.gap : 0;
    final double centerSpan = centerPill > 0 ? centerPill + style.gap : 0;
    final Map<VideoBarCluster, double> pillX = <VideoBarCluster, double>{};
    if (_fill) {
      pillX[VideoBarCluster.start] = 0;
      pillX[VideoBarCluster.center] = videoBottomBarCenterStart(
        width: size.width,
        leftWidth: startSpan,
        centerWidth: centerPill,
        rightWidth: endPill > 0 ? endPill + style.gap : 0,
      );
      pillX[VideoBarCluster.end] = math.max(
        startSpan + centerSpan,
        size.width - endPill,
      );
    } else {
      double x = 0;
      for (final VideoBarCluster c in VideoBarCluster.values) {
        pillX[c] = x;
        if (pillWidth[c]! > 0) x += pillWidth[c]! + style.gap;
      }
    }
    final double pillTop =
        (size.height - pillHeight) * (style.verticalAlignment + 1) / 2;
    final List<(VideoBarCluster, Rect)> pills = <(VideoBarCluster, Rect)>[
      for (final VideoBarCluster c in active)
        (c, Rect.fromLTWH(pillX[c]!, pillTop, pillWidth[c]!, pillHeight)),
    ];
    final Map<VideoBarCluster, double> cursor = <VideoBarCluster, double>{
      for (final VideoBarCluster c in VideoBarCluster.values)
        c: pillX[c]! + style.padding,
    };
    final double centerY = pillTop + pillHeight / 2;
    final Map<RenderBox, Offset> offsets = <RenderBox, Offset>{};
    for (final RenderBox child in shown) {
      final VideoBarCluster cluster = clusterOf(child);
      final Size childSize = sizes[child]!;
      offsets[child] = Offset(cursor[cluster]!, centerY - childSize.height / 2);
      cursor[cluster] = cursor[cluster]! + childSize.width;
    }
    return _VideoBarArrangement(
      size: size,
      plan: plan,
      offsets: offsets,
      contentWidth: contentWidth,
      pills: pills,
    );
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      _arrange(constraints, ChildLayoutHelper.dryLayoutChild).size;

  @override
  void performLayout() {
    final _VideoBarArrangement arrangement = _arrange(
      constraints,
      ChildLayoutHelper.layoutChild,
    );
    size = arrangement.size;
    for (final RenderBox child in _children) {
      final _VideoBarParentData data = _data(child);
      final Offset? offset = arrangement.offsets[child];
      data
        ..shown = offset != null
        ..offset = offset ?? Offset.zero;
    }
    _clipsContent = arrangement.contentWidth > size.width + _kFitTolerance;
    _pills = arrangement.pills;
    onPlan(arrangement.plan);
  }

  /// 不裁切的最窄宽度：钉死项 + 「⋯」（有可收起项时）——即全部收起后的样子。
  /// 外层（`VideoTopBarSlots`）按它给每组保底，组与组之间才不会把对方挤成半个图标。
  @override
  double computeMinIntrinsicWidth(double height) {
    double width = 0;
    for (final RenderBox child in _children) {
      final _VideoBarParentData data = _data(child);
      final bool counts = switch (data.role) {
        _VideoBarChildRole.more => _specs.any(
          (_VideoBarSpec s) => s.priority != null,
        ),
        _VideoBarChildRole.full =>
          data.entry < _specs.length && _specs[data.entry].priority == null,
        _VideoBarChildRole.compact => false,
      };
      if (counts) width += child.getMaxIntrinsicWidth(height);
    }
    return width + _pillReserve(_presentClusters);
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    double width = 0;
    for (final RenderBox child in _children) {
      if (_data(child).role == _VideoBarChildRole.full) {
        width += child.getMaxIntrinsicWidth(height);
      }
    }
    return width + _pillReserve(_presentClusters);
  }

  double _tallestIntrinsic() {
    double height = 0;
    for (final RenderBox child in _children) {
      height = math.max(height, child.getMaxIntrinsicHeight(double.infinity));
    }
    return height + 2 * (_clusterStyle?.verticalPadding ?? 0);
  }

  @override
  double computeMinIntrinsicHeight(double width) => _tallestIntrinsic();

  @override
  double computeMaxIntrinsicHeight(double width) => _tallestIntrinsic();

  void _paintShown(PaintingContext context, Offset offset) {
    final VideoBarClusterStyle? style = _clusterStyle;
    if (style != null && _pills.isNotEmpty) {
      final Canvas canvas = context.canvas;
      for (final (VideoBarCluster cluster, Rect rect) in _pills) {
        final RRect pill = RRect.fromRectAndRadius(
          rect.shift(offset),
          Radius.circular(rect.height / 2),
        );
        if (style.elevation > 0) {
          canvas.drawShadow(
            Path()..addRRect(pill),
            style.shadowColor,
            style.elevation,
            false,
          );
        }
        canvas.drawRRect(pill, Paint()..color = style.colorFor(cluster));
        final BorderSide? border = style.border;
        if (border != null && border.style != BorderStyle.none) {
          canvas.drawRRect(pill.deflate(border.width / 2), border.toPaint());
        }
      }
    }
    for (final RenderBox child in _children) {
      final _VideoBarParentData data = _data(child);
      if (data.shown) context.paintChild(child, offset + data.offset);
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_clipsContent) {
      _clipLayer.layer = null;
      _paintShown(context, offset);
      return;
    }
    _clipLayer.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      _paintShown,
      oldLayer: _clipLayer.layer,
    );
  }

  /// 胶囊本身是实体（见 [VideoControlBar] 的点击吸收层）；胶囊之间的空隙不是。
  @override
  bool hitTestSelf(Offset position) {
    if (_clusterStyle == null) return false;
    for (final (VideoBarCluster _, Rect rect) in _pills) {
      if (rect.contains(position)) return true;
    }
    return false;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    RenderBox? child = lastChild;
    while (child != null) {
      final _VideoBarParentData data = _data(child);
      if (data.shown) {
        final RenderBox target = child;
        final bool hit = result.addWithPaintOffset(
          offset: data.offset,
          position: position,
          hitTest: (BoxHitTestResult result, Offset transformed) =>
              target.hitTest(result, position: transformed),
        );
        if (hit) return true;
      }
      child = data.previousSibling;
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    for (final RenderBox child in _children) {
      if (_data(child).shown) visitor(child);
    }
  }

  @override
  void dispose() {
    _clipLayer.layer = null;
    super.dispose();
  }
}
