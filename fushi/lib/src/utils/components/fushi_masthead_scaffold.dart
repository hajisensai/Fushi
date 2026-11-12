/// 二级页的「页头大字」外壳（重设计外壳，`shellRedesignActive` 为 true 时才由
/// 调用点挂上；墨水屏照旧走各页原来的页头）。
///
/// - [FushiMastheadHeader]：页头那一行——返回键 + 页名大字（随滚动在绘制层
///   缩小）+ 右侧平铺的裸图标动作（放不下才收进「⋯」，[FushiShellHeaderActions]
///   的页头大字口径），可带页名后的徽标、页名下的小字与下方一行（页签）。
///   `titleInBody` 时是一排裸图标、页名只在滚过正文大标题后淡入。
/// - [FushiMastheadFrame]：不带 Scaffold 的内核——正文铺满，页头浮在上面，正文的
///   MediaQuery 顶部 padding = 页头下沿；滚到页头下面时垫 [FushiMastheadPanel]
///   底板（90% 页面底色 + 高斯模糊）。
/// - [FushiMastheadScaffold]：内核 + Scaffold + 主滚动控制器，二级页直接用。
///
/// 页头高度与正文让位在**同一次布局**里定（[_MastheadFrameDelegate] 先排页头、
/// 量出高度，再把让位经约束交给正文的 [LayoutBuilder]），首帧正文就在页头下沿，
/// 不是先只让出状态栏、等页头测高回报后再下移一帧。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/page_scroll_registry.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_backdrop.dart'
    show fushiPageBackgroundColor;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart'
    show FushiDesktopTitleBar, FushiTitleBarPassthroughScope;
import 'package:fushi/src/utils/components/fushi_floating_page_chrome.dart'
    show FushiScrollOwnerDepth;
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiShellHeaderActions, fushiHeaderTitleFloor;
import 'package:fushi/src/utils/components/fushi_page_masthead.dart'
    show
        FushiMastheadActionGroup,
        FushiMastheadPanel,
        FushiMastheadRole,
        FushiMastheadScope,
        FushiMastheadTitle,
        fushiMastheadCompact,
        fushiMastheadProgressOf,
        fushiMastheadTextWidth,
        fushiMastheadTitleStyle,
        kFushiMastheadActionExtent,
        kFushiMastheadTrackedOffset;
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart'
    show fushiExpressiveMotionEnabled;
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show fushiRouteImpliesBack;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiIconButtonControl;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:window_manager/window_manager.dart' show DragToMoveArea;

/// 页头在「展开态」（内容在顶）的判据：只在这时记正文让位高度，滚动中页名收缩
/// 不改让位（正文不跳）。设置二级页同一阈值。
const double kFushiMastheadRestOffset = 12;

/// `titleInBody` 页头（一排裸图标）的行高：一个图标按钮的命中区。
const double kFushiMastheadBareRowExtent = kMinInteractiveDimension;

/// `titleRevealOffset` 给定时，页名从该偏移起在这段距离内淡入。
const double _kTitleRevealDistance = kFushiMastheadBareRowExtent;

/// 页名后的徽标（设置的分类形状图标）：[compact] 窄窗，[progress] 收缩进度。
typedef FushiMastheadBadgeBuilder =
    Widget Function(BuildContext context, bool compact, double progress);

/// 页头底下、正文之上的一层（底板之外的额外垫层，如海报详情页压在背景图上的
/// 渐隐薄雾）。[height] 是状态栏 + 页头的实时高度，[progress] 是底板进度。
typedef FushiMastheadBackdropBuilder =
    Widget Function(BuildContext context, double height, double progress);

// =============================================================================
// 页头一行
// =============================================================================

/// 页头大字的一行（见文件头）。
class FushiMastheadHeader extends StatelessWidget {
  const FushiMastheadHeader({
    required this.title,
    required this.progress,
    this.titleReveal,
    this.titleInBody = false,
    this.inCaption = false,
    this.onBack,
    this.leading,
    this.backKey,
    this.dragKey,
    this.actions = const <Widget>[],
    this.badge,
    this.subtitle,
    this.bottom,
    super.key,
  });

  final String title;

  /// 收缩进度（0 = 展开）：非 [titleInBody] 时页名按它在绘制层缩小。
  final double progress;

  /// [titleInBody] 时页名的不透明度（0..1）；null = 跟 [progress]。
  final double? titleReveal;

  /// 正文顶部已有同名大标题：页头只是一排裸图标，页名恒为收缩字号、按
  /// [titleReveal] 淡入。
  final bool titleInBody;

  /// 这一行画在桌面自绘窗口标题行里（两侧让开窗口按钮，空白处垫拖窗区）。
  final bool inCaption;

  /// 返回；null 且没有 [leading] 时不画返回键。
  final VoidCallback? onBack;

  /// 替换返回键的前导（关闭键等）。
  final Widget? leading;
  final Key? backKey;
  final Key? dragKey;

  /// 右侧动作（图标按钮原样；平铺，放不下按优先级收进「⋯」）。
  final List<Widget> actions;
  final FushiMastheadBadgeBuilder? badge;

  /// 页名下一行（设置的当前分组名）。
  final Widget? subtitle;

  /// 页名行下方整行（页签 / 搜索框 / 筛选条）。挂在
  /// `FushiMastheadScope(role: secondary)` 下：放进来的 `LibrarySectionTabs`
  /// 自动画成与库页二级页签同一组件（`FushiMastheadSegmentedTabs` 连体按钮组），
  /// 二级页不必各写一份页签画法。
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool compact = fushiMastheadCompact(context);
    final TextStyle titleStyle = fushiMastheadTitleStyle(
      context,
      compact: compact,
    );
    final double fullSize = titleStyle.fontSize ?? (compact ? 46 : 84);
    final double collapsed = (compact ? 28 : 36) / fullSize;
    final double p = progress.clamp(0.0, 1.0);
    final double scale = titleInBody ? collapsed : lerpDouble(1, collapsed, p)!;
    final double lineHeight =
        MediaQuery.textScalerOf(context).scale(fullSize) *
        (titleStyle.height ?? 1);
    final Widget titleBox = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 只占页名实际（缩放后）的宽：徽标紧跟在页名后面；放不下时省略。
        final double natural =
            fushiMastheadTextWidth(context, title, titleStyle) + 1;
        final double width = math.min(constraints.maxWidth, natural * scale);
        return SizedBox(
          width: width,
          height: lineHeight * scale,
          child: OverflowBox(
            alignment: AlignmentDirectional.bottomStart,
            minWidth: 0,
            maxWidth: width / scale,
            minHeight: 0,
            maxHeight: lineHeight,
            child: Transform.scale(
              scale: scale,
              alignment: AlignmentDirectional.bottomStart.resolve(
                Directionality.of(context),
              ),
              child: Align(
                alignment: AlignmentDirectional.bottomStart,
                child: FushiMastheadTitle(title: title, compact: compact),
              ),
            ),
          ),
        );
      },
    );
    final Widget? lead =
        leading ??
        (onBack == null
            ? null
            : FushiIconButtonControl(
                key: backKey,
                icon: const FushiIcon(FushiIcons.back),
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: onBack,
              ));
    if (titleInBody) return _buildBare(context, tokens, titleBox, lead);
    final FushiMastheadBadgeBuilder? badge = this.badge;
    final Widget? subtitle = this.subtitle;
    final Widget? bottom = this.bottom;
    final Widget titleColumn = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Flexible(child: titleBox),
            if (badge != null) ...<Widget>[
              const SizedBox(width: 12),
              Padding(
                padding: EdgeInsets.only(bottom: compact ? 2 : 6),
                child: badge(context, compact, p),
              ),
            ],
          ],
        ),
        if (subtitle != null) subtitle,
      ],
    );
    final Widget row = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double leadWidth = lead == null
            ? 0
            : kFushiMastheadActionExtent + 14;
        final double budget = math.max(
          0,
          constraints.maxWidth -
              leadWidth -
              14 -
              fushiHeaderTitleFloor(context, constraints.maxWidth),
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            if (lead != null) ...<Widget>[
              FushiMastheadActionGroup(items: <Widget>[lead]),
              const SizedBox(width: 14),
            ],
            Expanded(child: titleColumn),
            if (actions.isNotEmpty) ...<Widget>[
              const SizedBox(width: 14),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: budget),
                child: _MastheadActions(actions: actions),
              ),
            ],
          ],
        );
      },
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: bottom == null
          ? row
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                row,
                SizedBox(height: tokens.spacing.gap),
                // 宽松约束、贴起始边：与库页二级行同一口径（页签按内容宽排，
                // 焦点框只框按钮组，不铺满整行）；搜索框等自会撑满可用宽。
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FushiMastheadScope(
                    role: FushiMastheadRole.secondary,
                    child: bottom,
                  ),
                ),
              ],
            ),
    );
  }

  /// [titleInBody] 的一排裸图标（行高 [kFushiMastheadBareRowExtent]）。
  Widget _buildBare(
    BuildContext context,
    FushiDesignTokens tokens,
    Widget titleBox,
    Widget? lead,
  ) {
    // 裸图标的命中区自带留白：行边距减掉图标按钮自己的内边距，箭头的可见位置
    // 仍对齐页边。
    final EdgeInsets reserved = inCaption
        ? FushiDesktopTitleBar.captionReservedInsets(context)
        : EdgeInsets.zero;
    final double edge = math.max(0, tokens.spacing.page - 12);
    final double opacity = (titleReveal ?? progress).clamp(0.0, 1.0);
    final Widget row = Padding(
      padding: EdgeInsets.only(
        left: reserved.left > 0 ? reserved.left : edge,
        right: reserved.right > 0 ? reserved.right + 8 : edge,
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double leadWidth = lead == null
              ? 0
              : kFushiMastheadActionExtent + 6;
          return Row(
            children: <Widget>[
              if (lead != null) ...<Widget>[lead, const SizedBox(width: 6)],
              Expanded(
                // 页名只是滚过正文大标题后的定位提示，不吃指针（空白处要落到
                // 拖窗区）。
                child: IgnorePointer(
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Opacity(opacity: opacity, child: titleBox),
                  ),
                ),
              ),
              if (actions.isNotEmpty)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.max(0, constraints.maxWidth - leadWidth),
                  ),
                  child: _MastheadActions(actions: actions),
                ),
            ],
          );
        },
      ),
    );
    final Widget sized = SizedBox(
      height: kFushiMastheadBareRowExtent,
      child: row,
    );
    if (!inCaption) return sized;
    return SizedBox(
      height: kFushiMastheadBareRowExtent,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: DragToMoveArea(key: dragKey, child: const SizedBox.expand()),
          ),
          row,
        ],
      ),
    );
  }
}

/// 页头动作：页头大字口径的平铺动作（放不下按优先级收进「⋯」）。
class _MastheadActions extends StatelessWidget {
  const _MastheadActions({required this.actions});

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => FushiMastheadScope(
    role: FushiMastheadRole.primary,
    child: FushiShellHeaderActions(actions: actions),
  );
}

// =============================================================================
// 内核
// =============================================================================

/// 页头大字内核（见文件头）：不带 Scaffold，可直接作为 Scaffold.body 或叠在
/// 别的页面结构里。
class FushiMastheadFrame extends StatefulWidget {
  const FushiMastheadFrame({
    required this.title,
    required this.body,
    this.actions = const <Widget>[],
    this.titleInBody = false,
    this.titleRevealOffset,
    this.leading,
    this.badge,
    this.subtitle,
    this.bottom,
    this.extendBodyBehindHeader = true,
    this.ownPrimaryScroll = false,
    this.backdrop,
    this.backKey,
    this.dragKey,
    this.implyBack = true,
    super.key,
  });

  final String title;
  final Widget body;
  final List<Widget> actions;

  /// 路由能返回时画返回键（[leading] 非 null 时由它替换）。
  final bool implyBack;

  /// 正文顶部已有同名大标题（见 [FushiMastheadHeader.titleInBody]）。桌面装了
  /// 自绘顶栏时这一排裸图标画进窗口标题行。
  final bool titleInBody;

  /// [titleInBody] 时页名开始淡入的主滚动偏移（通常 = 正文大标题区高度 − 页头
  /// 下沿）；null = 跟底板进度一起淡入。
  final ValueListenable<double>? titleRevealOffset;
  final Widget? leading;
  final FushiMastheadBadgeBuilder? badge;
  final Widget? subtitle;
  final Widget? bottom;

  /// 正文铺到页头底下（经 MediaQuery 顶部 padding 让位）；false = 正文排在页头
  /// 下沿以下（WebView、定高版面等无法消费顶部 padding 的正文）。
  final bool extendBodyBehindHeader;

  /// 自持一个全平台继承的 [PrimaryScrollController] 并登记 [PageScrollRegistry]
  /// （手柄 LB / RB 翻屏兜底够得到正文，与 `FushiPageScaffold` 同一约定）。
  final bool ownPrimaryScroll;
  final FushiMastheadBackdropBuilder? backdrop;
  final Key? backKey;
  final Key? dragKey;

  @override
  State<FushiMastheadFrame> createState() => _FushiMastheadFrameState();
}

class _FushiMastheadFrameState extends State<FushiMastheadFrame> {
  ScrollController? _primary;
  final FushiScrollOwnerDepth _owner = FushiScrollOwnerDepth();

  /// 主滚动区的竖向偏移（封顶 [kFushiMastheadTrackedOffset]）。
  final ValueNotifier<double> _offset = ValueNotifier<double>(0);

  /// [FushiMastheadFrame.titleRevealOffset] 下页名的不透明度。
  final ValueNotifier<double> _reveal = ValueNotifier<double>(0);

  /// 主滚动区未封顶的偏移（只给页名淡入用）。
  double _rawOffset = 0;

  /// 展开态页头高度（跨布局记住，见 [_MastheadFrameDelegate]）。
  final _MastheadRestMemo _memo = _MastheadRestMemo();

  @override
  void initState() {
    super.initState();
    if (widget.ownPrimaryScroll) {
      final ScrollController primary = ScrollController();
      _primary = primary;
      PageScrollRegistry.push(primary);
    }
    widget.titleRevealOffset?.addListener(_syncReveal);
  }

  @override
  void didUpdateWidget(FushiMastheadFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.titleRevealOffset != widget.titleRevealOffset) {
      oldWidget.titleRevealOffset?.removeListener(_syncReveal);
      widget.titleRevealOffset?.addListener(_syncReveal);
      _syncReveal();
    }
  }

  @override
  void dispose() {
    widget.titleRevealOffset?.removeListener(_syncReveal);
    final ScrollController? primary = _primary;
    if (primary != null) {
      PageScrollRegistry.pop(primary);
      primary.dispose();
    }
    _offset.dispose();
    _reveal.dispose();
    super.dispose();
  }

  void _syncReveal() {
    final ValueListenable<double>? start = widget.titleRevealOffset;
    if (start == null) return;
    final double next = ((_rawOffset - start.value) / _kTitleRevealDistance)
        .clamp(0.0, 1.0);
    if (next != _reveal.value) _reveal.value = next;
  }

  /// 主滚动区的竖向位置：用户 / 动画滚动（[ScrollUpdateNotification]）与版面修正
  /// （[ScrollMetricsNotification]，只认主滚动区深度，嵌套小列表首次布局不算）。
  bool _onNotification(Notification notification) {
    if (notification is ScrollUpdateNotification) _owner.claim(notification);
    final ScrollMetrics? metrics = switch (notification) {
      ScrollUpdateNotification(:final ScrollMetrics metrics) => metrics,
      final ScrollMetricsNotification n when _owner.owns(n) => n.metrics,
      _ => null,
    };
    if (metrics == null || metrics.axis != Axis.vertical) return false;
    _rawOffset = metrics.extentBefore;
    final double tracked = _rawOffset.clamp(0.0, kFushiMastheadTrackedOffset);
    if (tracked != _offset.value) _offset.value = tracked;
    _syncReveal();
    return false;
  }

  double _progress(BuildContext context, double offset) =>
      fushiMastheadProgressOf(
        compact: fushiMastheadCompact(context),
        motionEnabled: fushiExpressiveMotionEnabled(context),
        offset: offset,
      );

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    final double statusTop = media.padding.top;
    final VoidCallback? onBack =
        widget.implyBack && fushiRouteImpliesBack(context)
        ? () => unawaited(Navigator.of(context).maybePop())
        : null;
    // 正文自带大标题的页：页头上移进窗口标题行（见类注释）。标题行高度已经折在
    // 顶部 padding 里，上移量不超过它；内容全屏 / 未装自绘顶栏时为 0。
    final double captionLift = widget.titleInBody
        ? math.min(FushiDesktopTitleBar.immersiveCaptionInset, statusTop)
        : 0;
    final bool inCaption = captionLift > 0;
    final double headerTop = statusTop - captionLift;
    final Widget body = NotificationListener<Notification>(
      onNotification: _onNotification,
      child: widget.body,
    );
    final bool extend = widget.extendBodyBehindHeader;
    final FushiMastheadBackdropBuilder? extra = widget.backdrop;
    final Widget page = FushiTitleBarPassthroughScope(
      enabled: inCaption,
      child: CustomMultiChildLayout(
        delegate: _MastheadFrameDelegate(
          headerTop: headerTop,
          extendBody: extend,
          memo: _memo,
          offset: _offset,
        ),
        children: <Widget>[
          LayoutId(
            id: _MastheadSlot.body,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final double inset = constraints is _MastheadBodyConstraints
                    ? constraints.topInset
                    : headerTop;
                return SizedBox.fromSize(
                  size: constraints.biggest,
                  child: MediaQuery(
                    data: media.copyWith(
                      padding: media.padding.copyWith(top: inset),
                      viewPadding: media.viewPadding.copyWith(top: inset),
                    ),
                    child: body,
                  ),
                );
              },
            ),
          ),
          LayoutId(
            id: _MastheadSlot.backdrop,
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) =>
                    ValueListenableBuilder<double>(
                      valueListenable: _offset,
                      builder:
                          (BuildContext context, double offset, Widget? _) {
                            final double p = extend
                                ? _progress(context, offset)
                                : 0;
                            final double height = constraints.maxHeight;
                            return Stack(
                              fit: StackFit.expand,
                              children: <Widget>[
                                if (extra != null) extra(context, height, p),
                                // 底板高度由版面给（紧约束），这里不另给数。
                                FushiMastheadPanel(
                                  height: double.infinity,
                                  progress: p,
                                ),
                              ],
                            );
                          },
                    ),
              ),
            ),
          ),
          LayoutId(
            id: _MastheadSlot.header,
            child: ListenableBuilder(
              listenable: Listenable.merge(<Listenable>[_offset, _reveal]),
              builder: (BuildContext context, Widget? _) => FushiMastheadHeader(
                title: widget.title,
                progress: _progress(context, _offset.value),
                titleReveal: widget.titleRevealOffset == null
                    ? null
                    : _reveal.value,
                titleInBody: widget.titleInBody,
                inCaption: inCaption,
                onBack: onBack,
                leading: widget.leading,
                backKey: widget.backKey,
                dragKey: widget.dragKey,
                actions: widget.actions,
                badge: widget.badge,
                subtitle: widget.subtitle,
                bottom: widget.bottom,
              ),
            ),
          ),
        ],
      ),
    );
    final ScrollController? primary = _primary;
    if (primary == null) return page;
    return PrimaryScrollController(
      controller: primary,
      automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
      child: page,
    );
  }
}

enum _MastheadSlot { body, backdrop, header }

/// 跨布局记住的展开态页头高度（null = 还没量过）。
class _MastheadRestMemo {
  double? rest;
}

/// 正文拿到的约束：带上页头让位（[LayoutBuilder] 据此给正文的 MediaQuery）。
class _MastheadBodyConstraints extends BoxConstraints {
  _MastheadBodyConstraints.tight(Size size, {required this.topInset})
    : super(
        minWidth: size.width,
        maxWidth: size.width,
        minHeight: size.height,
        maxHeight: size.height,
      );

  final double topInset;

  @override
  bool operator ==(Object other) =>
      other is _MastheadBodyConstraints &&
      other.topInset == topInset &&
      super == other;

  @override
  int get hashCode => Object.hash(super.hashCode, topInset);
}

/// 先排页头、量出高度，再排正文与底板——让位与页头同一帧定下来。
class _MastheadFrameDelegate extends MultiChildLayoutDelegate {
  _MastheadFrameDelegate({
    required this.headerTop,
    required this.extendBody,
    required this.memo,
    required this.offset,
  });

  final double headerTop;
  final bool extendBody;
  final _MastheadRestMemo memo;
  final ValueListenable<double> offset;

  @override
  void performLayout(Size size) {
    final Size header = layoutChild(
      _MastheadSlot.header,
      BoxConstraints(
        minWidth: size.width,
        maxWidth: size.width,
        maxHeight: math.max(0, size.height - headerTop),
      ),
    );
    positionChild(_MastheadSlot.header, Offset(0, headerTop));
    // 只在展开态（内容在顶）记让位：滚动中页名收缩不改让位（正文不跳）。
    final double? remembered = memo.rest;
    final double rest =
        remembered == null || offset.value <= kFushiMastheadRestOffset
        ? header.height
        : remembered;
    memo.rest = rest;
    final double inset = headerTop + rest;
    if (extendBody) {
      layoutChild(
        _MastheadSlot.body,
        _MastheadBodyConstraints.tight(size, topInset: inset),
      );
      positionChild(_MastheadSlot.body, Offset.zero);
    } else {
      layoutChild(
        _MastheadSlot.body,
        _MastheadBodyConstraints.tight(
          Size(size.width, math.max(0, size.height - inset)),
          topInset: 0,
        ),
      );
      positionChild(_MastheadSlot.body, Offset(0, inset));
    }
    layoutChild(
      _MastheadSlot.backdrop,
      BoxConstraints.tight(
        Size(size.width, math.min(size.height, headerTop + header.height)),
      ),
    );
    positionChild(_MastheadSlot.backdrop, Offset.zero);
  }

  @override
  bool shouldRelayout(_MastheadFrameDelegate oldDelegate) =>
      headerTop != oldDelegate.headerTop ||
      extendBody != oldDelegate.extendBody ||
      memo != oldDelegate.memo ||
      offset != oldDelegate.offset;
}

// =============================================================================
// Scaffold
// =============================================================================

/// 二级页的页头大字外壳：[FushiMastheadFrame] + Scaffold（页面底色、悬浮按钮、
/// 底栏、SnackBar / 键盘避让）+ 主滚动控制器。
class FushiMastheadScaffold extends StatelessWidget {
  const FushiMastheadScaffold({
    required this.title,
    required this.body,
    this.actions = const <Widget>[],
    this.titleInBody = false,
    this.leading,
    this.bottom,
    this.extendBodyBehindHeader = true,
    this.backgroundColor,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.bottomNavigationBar,
    this.dragKey = const ValueKey<String>('fushi-masthead-caption-drag'),
    this.implyBack = true,
    this.ownPrimaryScroll = true,
    super.key,
  });

  /// 见 [FushiMastheadFrame.implyBack]。
  final bool implyBack;

  /// 见 [FushiMastheadFrame.ownPrimaryScroll]；外层已挂主滚动控制器的（
  /// `FushiPageScaffold`）传 false。
  final bool ownPrimaryScroll;

  final String title;
  final Widget body;
  final List<Widget> actions;
  final bool titleInBody;

  /// [titleInBody] 页头画进窗口标题行时，垫底拖窗区的 key。
  final Key? dragKey;
  final Widget? leading;
  final Widget? bottom;
  final bool extendBodyBehindHeader;

  /// null = 页面底色（[fushiPageBackgroundColor]）。
  final Color? backgroundColor;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final Widget? bottomNavigationBar;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: backgroundColor ?? fushiPageBackgroundColor(context),
    floatingActionButton: floatingActionButton,
    floatingActionButtonLocation: floatingActionButtonLocation,
    bottomNavigationBar: bottomNavigationBar,
    body: SafeArea(
      top: false,
      bottom: false,
      child: FushiMastheadFrame(
        title: title,
        actions: actions,
        titleInBody: titleInBody,
        leading: leading,
        bottom: bottom,
        extendBodyBehindHeader: extendBodyBehindHeader,
        ownPrimaryScroll: ownPrimaryScroll,
        dragKey: dragKey,
        implyBack: implyBack,
        body: body,
      ),
    ),
  );
}
