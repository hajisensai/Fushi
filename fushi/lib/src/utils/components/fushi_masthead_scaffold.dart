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
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show isGlassDesign;
import 'package:fushi/src/utils/adaptive/fushi_page_backdrop.dart'
    show fushiPageBackgroundColor;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart'
    show FushiDesktopTitleBar, FushiTitleBarPassthroughScope;
import 'package:fushi/src/utils/components/fushi_icon_button.dart'
    show FushiIconButton;
import 'package:fushi/src/utils/components/fushi_floating_page_chrome.dart'
    show FushiPinnedPageChromeScope, FushiScrollOwnerDepth;
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiShellHeaderActions, fushiHeaderTitleFloor;
import 'package:fushi/src/utils/components/fushi_page_masthead.dart'
    show
        FushiMastheadActionGroup,
        FushiMastheadPanel,
        FushiMastheadRole,
        FushiMastheadScope,
        FushiMastheadTitle,
        FushiMastheadTitleFit,
        fushiMastheadCompact,
        fushiMastheadProgressOf,
        fushiMastheadTitleFit,
        fushiMastheadTitleStyle,
        kFushiMastheadActionExtent,
        kFushiMastheadTrackedOffset;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart'
    show FushiMotion, fushiMotionDuration;
import 'package:fushi/src/utils/components/fushi_page_title_metrics.dart'
    show FushiPageTitleMetrics, FushiPageTitleScale, FushiPageTitleTier;
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart'
    show fushiExpressiveMotionEnabled;
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show
        FushiAppleLargeTitle,
        FushiAppleNavBar,
        FushiAppleSoftScrollEdge,
        FushiRouteBackButton,
        fushiAppleInlineTitleOpacity,
        fushiAppleLargeTitleBand,
        fushiAppleLargeTitleOpacity,
        fushiRouteImpliesBack,
        kFushiAppleScrollEdgeTail;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show fushiAppleCompact, fushiAppleMacScale;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:window_manager/window_manager.dart' show DragToMoveArea;

/// 页头在「展开态」（内容在顶）的判据：只在这时记正文让位高度，滚动中页名收缩
/// 不改让位（正文不跳）。设置二级页同一阈值。
const double kFushiMastheadRestOffset = 12;

/// `titleInBody` 页头（一排裸图标）的行高：一个图标按钮的命中区。
const double kFushiMastheadBareRowExtent = kMinInteractiveDimension;

/// `titleRevealOffset` 给定时，页名从该偏移起在这段距离内淡入。
const double _kTitleRevealDistance = kFushiMastheadBareRowExtent;

/// 页头返回键的图标字号（命中区按它补到 [kMinInteractiveDimension]）。
const double _kBackIconSize = 24;

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

/// 页名排法的缓存键：同一组输入只排一次（[fushiMastheadTitleFit] 要做多次
/// 文字排版，页头在滚动收缩的每一帧都会重建）。
typedef _TitleFitKey = ({
  String text,
  TextStyle style,
  double maxWidth,
  TextScaler textScaler,
  TextDirection direction,
  FushiPageTitleTier tier,
  bool singleLine,
});

/// [FushiMastheadHeader] 的页名盒：静止态按 [fushiMastheadTitleFit] 定下字号与
/// 折行宽（放不下先缩小、再折两行，最后才省略——手机上「Reading」按 46 排只剩
/// 「Read…」，BUG-5062），滚动收缩只在绘制层按 [scale] 等比缩小，折好的两行
/// 不随滚动重排。只占页名实际（缩放后）的宽：徽标紧跟在页名后面。
class _MastheadTitleBox extends StatefulWidget {
  const _MastheadTitleBox({
    required this.title,
    required this.compact,
    required this.scale,
    required this.singleLine,
    required this.tier,
  });

  final String title;
  final bool compact;

  /// 页名字阶档位。
  final FushiPageTitleTier tier;

  /// 绘制层缩放（相对满字号）：滚动收缩进度对应的比例。
  final double scale;

  /// 只排一行（行高固定的裸图标行），放不下省略。
  final bool singleLine;

  @override
  State<_MastheadTitleBox> createState() => _MastheadTitleBoxState();
}

class _MastheadTitleBoxState extends State<_MastheadTitleBox> {
  _TitleFitKey? _fitKey;
  FushiMastheadTitleFit? _fit;

  FushiMastheadTitleFit _fitFor(_TitleFitKey key, FushiPageTitleScale scale) {
    final FushiMastheadTitleFit? cached = _fit;
    if (cached != null && key == _fitKey) return cached;
    final double full = scale.fontSize;
    final FushiMastheadTitleFit fit = fushiMastheadTitleFit(
      text: key.text,
      style: key.style,
      maxWidth: key.maxWidth,
      singleLineMinScale: scale.collapsedFontSize / full,
      twoLineMinScale: scale.twoLineMinFontSize / full,
      twoLineMaxScale: scale.twoLineMaxFontSize / full,
      direction: key.direction,
      textScaler: key.textScaler,
      maxLines: key.singleLine ? 1 : 2,
    );
    _fitKey = key;
    _fit = fit;
    return fit;
  }

  @override
  Widget build(BuildContext context) {
    final FushiPageTitleScale titleScale = FushiPageTitleMetrics.forCompact(
      widget.compact,
    ).titleScale(widget.tier);
    final TextStyle style = fushiMastheadTitleStyle(
      context,
      compact: widget.compact,
      tier: widget.tier,
    );
    final TextScaler textScaler = MediaQuery.textScalerOf(context);
    final TextDirection direction = Directionality.of(context);
    final double lineHeight =
        textScaler.scale(titleScale.fontSize) * titleScale.lineHeight;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final FushiMastheadTitleFit fit = _fitFor((
          text: widget.title,
          style: style,
          maxWidth: constraints.maxWidth,
          textScaler: textScaler,
          direction: direction,
          tier: widget.tier,
          singleLine: widget.singleLine,
        ), titleScale);
        final double fitScale = math.min(widget.scale, fit.scale);
        final double width = math.min(
          constraints.maxWidth,
          fit.lineWidth * fitScale,
        );
        return SizedBox(
          width: width,
          height: lineHeight * fit.lines * fitScale,
          child: OverflowBox(
            alignment: AlignmentDirectional.bottomStart,
            minWidth: 0,
            maxWidth: width / fitScale,
            minHeight: 0,
            maxHeight: lineHeight * fit.lines,
            child: Transform.scale(
              scale: fitScale,
              alignment: AlignmentDirectional.bottomStart.resolve(direction),
              child: Align(
                alignment: AlignmentDirectional.bottomStart,
                child: FushiMastheadTitle(
                  title: widget.title,
                  compact: widget.compact,
                  maxLines: fit.lines,
                  tier: widget.tier,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 页头大字的一行（见文件头）。
///
/// @design m3e（只画 M3E 页头大字；Apple 设计系统下 [FushiMastheadFrame] /
/// [FushiMastheadScaffold] 不经本组件，换成 iOS 27 大标题导航栏
/// [FushiAppleNavBar]。直接挂本组件的调用方须自己在 Apple 下分派）
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
    this.titleTier = FushiPageTitleTier.page,
    super.key,
  });

  final String title;

  /// 页名字阶档位（设置分类页用 [FushiPageTitleTier.section]）。
  final FushiPageTitleTier titleTier;

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
    final FushiPageTitleScale titleScale = FushiPageTitleMetrics.forCompact(
      compact,
    ).titleScale(titleTier);
    final double collapsed = titleScale.collapsedFontSize / titleScale.fontSize;
    final double p = progress.clamp(0.0, 1.0);
    final double scale = titleInBody ? collapsed : lerpDouble(1, collapsed, p)!;
    final Widget titleBox = _MastheadTitleBox(
      title: title,
      compact: compact,
      scale: scale,
      // 裸图标行行高固定 kFushiMastheadBareRowExtent（48），装不下两行：页名
      // 只是滚过正文大标题后的定位提示，按收起态字号一行、放不下省略。
      singleLine: titleInBody,
      tier: titleTier,
    );
    final Widget? lead =
        leading ??
        (onBack == null
            ? null
            // FushiIconButton（不是裸 FushiIconButtonControl）：在 FushiFocusRoot
            // 下登记成焦点目标，返回键手柄 / 键盘焦点够得到，不只靠触屏或系统返回。
            // 命中区保持 48×48（被取代的 AppBar BackButton / IconButton 本就是这么
            // 大）：默认内边距只有 40，返回键是二级页最常点的钮，不能缩。
            : FushiIconButton(
                key: backKey,
                icon: FushiIcons.back,
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                size: _kBackIconSize,
                padding: const EdgeInsets.all(
                  (kMinInteractiveDimension - _kBackIconSize) / 2,
                ),
                onTap: onBack,
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
///
/// @design dual
/// M3E：页头大字（[FushiMastheadHeader] + [FushiMastheadPanel] 底板）。
/// Apple（[isGlassDesign]）：iOS 27 / macOS 27 大标题导航栏，与设置子页、
/// `FushiPageScaffold` 非页头大字路径同一套——最上面一行 [FushiAppleNavBar]
/// （透明栏、玻璃返回圆钮、动作进共享玻璃胶囊、放不下收横向「⋯」；桌面在窗口
/// 标题栏行下面），下面是靠前的 34pt 大标题（[FushiAppleLargeTitle]），再下面是
/// [subtitle] / [bottom]（吸顶）。正文往下滚时大标题随内容上移、淡出，栏里淡入
/// 居中 17pt 小标题；内容压到栏下时下沿是库的 soft scroll edge
/// （[FushiAppleSoftScrollEdge]）。[titleInBody] 时没有大标题，正文铺到透明栏
/// 底下，小标题按 [titleRevealOffset] 淡入。[badge] 在 Apple 下不画（Apple
/// 导航栏没有 M3E 模块多边形徽标）。
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

  /// 并排各自滚动的多栏（[FushiPinnedPageChromeScope] 里、主深度上的竖向滚动区）
  /// 未封顶的偏移，按滚动区（通知的 context）分开记。
  ///
  /// 宽窗表单两栏（`SrsAdaptiveSections`）是同一深度上两个同时可见、各自滚动的
  /// 列表，页头却只有一条：取其中滚得最远的那个——任一栏有内容压在页头下面就
  /// 收起，两栏都回到顶才展开。只记「最后一条通知」时，页头在两栏各自的位置之间
  /// 来回切换，一栏在顶、另一栏已滚动就大字 / 小字反复跳（反馈 ONNjqh7wxs）。
  ///
  /// 只对声明了并排的多栏取最大值：分页 / 换页（TabBarView、IndexedStack、
  /// AnimatedSwitcher）里同一深度的几个列表是换着显示的，离开的那页可能还挂着
  /// （保活 / 过渡中），它的位置不能压住刚换上、停在顶部的那页。来自多栏以外的
  /// 主滚动区通知直接定页头位置并清空这里。
  ///
  /// 每栏连同通知深度一起记：主深度要等第一次竖向滚动才定下来，在那之前栏里
  /// 更深的竖向滚动区（多行输入框的内部滚动等）可能先被当成一栏记进来；主深度
  /// 定到更浅处后这些记录不再算数，否则它们的内部偏移会一直压着页头。
  final Map<BuildContext, ({int depth, double offset})> _panes =
      <BuildContext, ({int depth, double offset})>{};

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
  ///
  /// 并排多栏里页头的偏移取各栏最大值（见 [_panes]）；比主深度更深的嵌套竖向
  /// 列表不算。
  bool _onNotification(Notification notification) {
    if (notification is ScrollUpdateNotification) _owner.claim(notification);
    final (
      BuildContext? source,
      int depth,
      ScrollMetrics? metrics,
    ) = switch (notification) {
      final ScrollUpdateNotification n => (n.context, n.depth, n.metrics),
      final ScrollMetricsNotification n when _owner.owns(n) => (
        n.context,
        n.depth,
        n.metrics,
      ),
      _ => (null, 0, null),
    };
    if (metrics == null || metrics.axis != Axis.vertical) return false;
    // 比主滚动区更深的嵌套竖向列表（正文里自带滚动的小框）不驱动页头。
    if (depth > _owner.depth) return false;
    if (source != null && FushiPinnedPageChromeScope.pins(source)) {
      _panes[source] = (depth: depth, offset: metrics.extentBefore);
      final int ownerDepth = _owner.depth;
      _panes.removeWhere(
        (BuildContext pane, ({int depth, double offset}) entry) =>
            !pane.mounted || entry.depth > ownerDepth,
      );
      _rawOffset = _panes.values.fold(
        0.0,
        (double acc, ({int depth, double offset}) entry) =>
            math.max(acc, entry.offset),
      );
    } else {
      _panes.clear();
      _rawOffset = metrics.extentBefore;
    }
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

  /// Apple 大标题已收起的进度（0 = 大标题完全露出，1 = 收进导航栏）。
  /// 正文排在页头下面（不随内容滚）时只取两档：滚离顶部即收起。
  double _appleProgress(double band) {
    if (!widget.extendBodyBehindHeader) {
      return _offset.value > kFushiMastheadRestOffset ? 1 : 0;
    }
    if (band <= 0) return 1;
    return (_offset.value / band).clamp(0.0, 1.0);
  }

  /// Apple（Cupertino）= iOS 27 / macOS 27 大标题导航栏（见类注释）。
  Widget _buildApple(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    final VoidCallback? onBack =
        widget.implyBack && fushiRouteImpliesBack(context)
        ? () => unawaited(Navigator.of(context).maybePop())
        : null;
    final Widget? leading =
        widget.leading ??
        (onBack == null
            ? null
            : FushiRouteBackButton(key: widget.backKey, onPressed: onBack));
    final bool titleInBody = widget.titleInBody;
    final double band = titleInBody ? 0 : fushiAppleLargeTitleBand(context);
    final ValueListenable<double>? revealStart = widget.titleRevealOffset;
    final Widget inlineTitle = ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[_offset, _reveal]),
      child: Text(widget.title),
      builder: (BuildContext context, Widget? child) {
        final double o = titleInBody
            ? (revealStart == null
                  ? (_offset.value > kFushiMastheadRestOffset ? 1.0 : 0.0)
                  : _reveal.value)
            : fushiAppleInlineTitleOpacity(_appleProgress(band));
        return ExcludeSemantics(
          excluding: o == 0,
          child: Opacity(opacity: o, child: child),
        );
      },
    );
    final FushiAppleNavBar bar = FushiAppleNavBar(
      // 下面自己让位状态栏 / 窗口标题栏（桌面工具栏排在标题栏行下面）。
      primary: false,
      automaticallyImplyLeading: false,
      leading: leading,
      title: inlineTitle,
      actions: widget.actions,
    );
    final Widget body = NotificationListener<Notification>(
      onNotification: _onNotification,
      child: widget.body,
    );
    return titleInBody
        ? _buildAppleTitleInBody(context, media, bar, body)
        : _buildAppleLargeTitle(context, media, bar, body, band);
  }

  /// [FushiMastheadFrame.titleInBody]：正文（自带大标题 / hero）铺到透明栏底下，
  /// 栏浮在上面；滚动后栏区垫 soft scroll edge。
  Widget _buildAppleTitleInBody(
    BuildContext context,
    MediaQueryData media,
    Widget bar,
    Widget body,
  ) {
    final double statusTop = media.padding.top;
    final double barBottom = statusTop + kToolbarHeight;
    final FushiMastheadBackdropBuilder? extra = widget.backdrop;
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: MediaQuery(
            data: media.copyWith(
              padding: media.padding.copyWith(top: barBottom),
              viewPadding: media.viewPadding.copyWith(top: barBottom),
            ),
            child: body,
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: barBottom + kFushiAppleScrollEdgeTail,
          child: IgnorePointer(
            child: ValueListenableBuilder<double>(
              valueListenable: _offset,
              builder: (BuildContext context, double offset, Widget? _) {
                final double p = offset > 0 ? 1 : 0;
                return Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    if (extra != null) extra(context, barBottom, p),
                    Align(
                      alignment: Alignment.topCenter,
                      child: FushiAppleSoftScrollEdge(
                        visible: offset > 0,
                        solidExtent: barBottom,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        Positioned(top: statusTop, left: 0, right: 0, child: bar),
      ],
    );
  }

  /// 大标题形态：栏一行 + 大标题 + 吸顶的 [subtitle] / [bottom]。
  ///
  /// 正文、scroll edge 底、大标题都从**窗口顶**（含状态栏 / 桌面窗口按钮行）起排，
  /// 栏行叠在最上面：iOS 27 导航栏的 scroll edge 是从窗口顶到吸顶行下沿的一整块
  /// 模糊 + 压暗底（[FushiAppleScrollEdgeBackdrop]）。曾经把栏行排在 Column 里、
  /// 正文与底只排在栏下面，状态栏 + 栏行那一段是没有内容、没有底的纯页面底色，
  /// 下面一段才是模糊的内容——两种底在栏下沿接成一条分界线。
  Widget _buildAppleLargeTitle(
    BuildContext context,
    MediaQueryData media,
    FushiAppleNavBar bar,
    Widget body,
    double band,
  ) {
    final double statusTop = media.padding.top;
    final bool extend = widget.extendBodyBehindHeader;
    final double side = fushiAppleCompact(context)
        ? 20 * fushiAppleMacScale(context)
        : 16;
    final Widget? subtitle = widget.subtitle;
    final Widget? bottom = widget.bottom;
    final Widget largeTitle = ListenableBuilder(
      listenable: _offset,
      child: Padding(
        padding: EdgeInsets.fromLTRB(side, 0, side, 8),
        child: Align(
          alignment: AlignmentDirectional.bottomStart,
          child: FushiAppleLargeTitle(title: widget.title),
        ),
      ),
      builder: (BuildContext context, Widget? child) {
        final double o = fushiAppleLargeTitleOpacity(_appleProgress(band));
        return IgnorePointer(
          child: ExcludeSemantics(
            excluding: o == 0,
            child: AnimatedOpacity(
              opacity: o,
              // 随内容滚的大标题逐帧跟手；不随内容滚时两档切换补一段淡变。
              duration: extend
                  ? Duration.zero
                  : fushiMotionDuration(context, FushiMotion.short),
              curve: FushiMotion.standard,
              child: child,
            ),
          ),
        );
      },
    );
    final Widget? below = subtitle == null && bottom == null
        ? null
        : Padding(
            padding: EdgeInsets.fromLTRB(side, 0, side, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (subtitle != null) subtitle,
                if (bottom != null)
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
    final Widget content = CustomMultiChildLayout(
      delegate: _AppleMastheadDelegate(
        top: statusTop + bar.preferredSize.height,
        band: band,
        extendBody: extend,
        offset: _offset,
      ),
      children: <Widget>[
        LayoutId(
          id: _AppleMastheadSlot.body,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double inset = constraints is _MastheadBodyConstraints
                  ? constraints.topInset
                  : 0;
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
          id: _AppleMastheadSlot.edge,
          child: IgnorePointer(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) =>
                  ValueListenableBuilder<double>(
                    valueListenable: _offset,
                    builder: (BuildContext context, double offset, Widget? _) =>
                        FushiAppleSoftScrollEdge(
                          visible: extend ? offset >= band - 0.5 : offset > 0,
                          solidExtent: math.max(
                            0,
                            constraints.maxHeight - kFushiAppleScrollEdgeTail,
                          ),
                        ),
                  ),
            ),
          ),
        ),
        LayoutId(id: _AppleMastheadSlot.largeTitle, child: largeTitle),
        if (below != null)
          LayoutId(id: _AppleMastheadSlot.bottom, child: below),
      ],
    );
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      child: Stack(
        children: <Widget>[
          Positioned.fill(child: content),
          Positioned(top: statusTop, left: 0, right: 0, child: bar),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget page = isGlassDesign(context)
        ? _buildApple(context)
        : _buildM3e(context);
    final ScrollController? primary = _primary;
    if (primary == null) return page;
    return PrimaryScrollController(
      controller: primary,
      automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
      child: page,
    );
  }

  Widget _buildM3e(BuildContext context) {
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
    return page;
  }
}

enum _MastheadSlot { body, backdrop, header }

enum _AppleMastheadSlot { body, edge, largeTitle, bottom }

/// Apple 大标题导航栏的正文区版面（栏下面那一块）：先量吸顶行（subtitle /
/// bottom）的高，正文让位 = 大标题行 + 吸顶行；大标题与吸顶行随主滚动偏移
/// 上移（最多一个大标题行），之后吸顶行停在栏下沿。正文不铺到页头底下时整体
/// 排在让位以下，大标题与吸顶行不动。soft scroll edge 盖住吸顶行背后再往下
/// 渐隐 [kFushiAppleScrollEdgeTail]。
class _AppleMastheadDelegate extends MultiChildLayoutDelegate {
  _AppleMastheadDelegate({
    required this.top,
    required this.band,
    required this.extendBody,
    required this.offset,
  }) : super(relayout: offset);

  /// 栏行下沿（状态栏 / 窗口按钮行 + 栏行）：大标题与吸顶行从这里往下排。
  final double top;
  final double band;
  final bool extendBody;
  final ValueListenable<double> offset;

  @override
  void performLayout(Size size) {
    final double below = hasChild(_AppleMastheadSlot.bottom)
        ? layoutChild(
            _AppleMastheadSlot.bottom,
            BoxConstraints.tightFor(width: size.width),
          ).height
        : 0;
    final double slide = extendBody ? offset.value.clamp(0.0, band) : 0;
    final double inset = top + band + below;
    if (extendBody) {
      layoutChild(
        _AppleMastheadSlot.body,
        _MastheadBodyConstraints.tight(size, topInset: inset),
      );
      positionChild(_AppleMastheadSlot.body, Offset.zero);
    } else {
      layoutChild(
        _AppleMastheadSlot.body,
        _MastheadBodyConstraints.tight(
          Size(size.width, math.max(0, size.height - inset)),
          topInset: 0,
        ),
      );
      positionChild(_AppleMastheadSlot.body, Offset(0, inset));
    }
    // 正文铺到页头底下：实底 = 窗口顶到吸顶行下沿（一整块，含状态栏与栏行）；
    // 正文排在下面：实底 0，渐隐从正文顶边往下画。
    final double solid = extendBody ? top + band - slide + below : 0;
    layoutChild(
      _AppleMastheadSlot.edge,
      BoxConstraints.tight(Size(size.width, solid + kFushiAppleScrollEdgeTail)),
    );
    positionChild(_AppleMastheadSlot.edge, Offset(0, extendBody ? 0 : inset));
    layoutChild(
      _AppleMastheadSlot.largeTitle,
      BoxConstraints.tight(Size(size.width, band)),
    );
    positionChild(_AppleMastheadSlot.largeTitle, Offset(0, top - slide));
    if (hasChild(_AppleMastheadSlot.bottom)) {
      positionChild(_AppleMastheadSlot.bottom, Offset(0, top + band - slide));
    }
  }

  @override
  bool shouldRelayout(_AppleMastheadDelegate oldDelegate) =>
      top != oldDelegate.top ||
      band != oldDelegate.band ||
      extendBody != oldDelegate.extendBody ||
      offset != oldDelegate.offset;
}

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
///
/// @design dual（Apple 下是 iOS 27 大标题导航栏，见 [FushiMastheadFrame]）
class FushiMastheadScaffold extends StatelessWidget {
  const FushiMastheadScaffold({
    required this.title,
    required this.body,
    this.actions = const <Widget>[],
    this.titleInBody = false,
    this.titleRevealOffset,
    this.leading,
    this.subtitle,
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

  /// 见 [FushiMastheadFrame.titleRevealOffset]。
  final ValueListenable<double>? titleRevealOffset;

  /// [titleInBody] 页头画进窗口标题行时，垫底拖窗区的 key。
  final Key? dragKey;
  final Widget? leading;

  /// 页名下一行（见 [FushiMastheadHeader.subtitle]）；[titleInBody] 时不画。
  final Widget? subtitle;
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
        titleRevealOffset: titleRevealOffset,
        leading: leading,
        subtitle: subtitle,
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
