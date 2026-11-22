import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/notice_dwell.dart';
import 'package:fushi/src/utils/misc/toast_severity.dart';

/// 制卡结果卡片上的一颗动作按钮（撤销 / 重试 / 仍要添加 / 查看队列…）。
@immutable
class MineNoticeAction {
  const MineNoticeAction({required this.label, required this.onPressed});

  final String label;

  /// 点下后调用；宿主（toast / 视频 OSD）同时立即收起这张卡。
  final VoidCallback onPressed;
}

/// 带动作按钮的结果卡至少停留多久（与 [FushiNoticeDwell.mineAction] 同值，保留旧名
/// 给既有调用点）。
const Duration kMineNoticeActionVisibleFor = FushiNoticeDwell.mineAction;

/// 制卡结果卡片：底部制卡 toast、歌词模式角落小卡、视频页左上角 OSD 共用的唯一
/// 长相（用户 2026-11-22 重设计，设计稿「制卡提示重设计」）。
///
/// 一张卡回答三件事：
/// 1. **哪个词**——第一行是 [term] + [reading]（最显眼）。此前卡上只有一句「卡片已
///    导出到『牌组』」，后台连续制卡时分不出是哪张卡；
/// 2. **结果如何**——状态标题（[mineNoticeTitle]）显示出来，粗体，放在第二行开头。
///    此前它只进读屏 label，看的人只能靠颜色猜；
/// 3. **去了哪儿 / 为什么**——第二行标题后接 [detail]（牌组名 / 失败原因），没有就用
///    [message]。
///
/// 没有 [term] 的调用点（远端制卡、整批结果）第一行改放状态标题、第二行放消息，
/// 标题同样看得见。
///
/// 失败与「有缺失」的原因放不下两行时出「详情」：展开成整段原文 + 「复制错误」，
/// 展开期间宿主不再自动收起（[expanded] / [onExpandedChanged]）。
///
/// 动效：图标块从 -90° / 0.4 倍弹入（M3E spatial 弹簧）；同一张卡换状态（制卡中 →
/// 结果，原地变形）时图标块重新弹入、底色与强调色过渡，倒计时条从这一刻重新走。
/// 墨水屏与系统「减弱动态效果」下不播（[fushiMotionEnabled]），倒计时条不画。
/// 墨水屏把三色收成白底黑字黑描边（失败卡描边加粗），靠图标形状区分结果。
class FushiMineNoticeCard extends StatefulWidget {
  const FushiMineNoticeCard({
    required this.status,
    required this.message,
    required this.visibleFor,
    this.term,
    this.reading,
    this.detail,
    this.maxWidth = 440,
    this.action,
    this.compact = false,
    this.paused = false,
    this.expanded = false,
    this.onExpandedChanged,
    this.onDismiss,
    super.key,
  });

  final MineToastStatus status;

  /// 完整消息（调用方算好的整句，如「卡片已导出到『Fushi』。」）：读屏 label、
  /// 没有 [detail] 时的第二行、「详情」展开后的原文都用它。
  final String message;

  /// 这次制卡的词（第一行）。null = 调用点拿不到词，第一行放状态标题。
  final String? term;

  /// [term] 的读音；与 [term] 相同或为空时不画。
  final String? reading;

  /// 第二行标题后面的短说明（牌组名 / 失败原因）；null 时用 [message]。
  final String? detail;

  /// 卡片右侧的动作按钮（撤销 / 重试…）；为 null 时不画。按钮视觉 36 高（小号
  /// 30）；触控平台命中区撑到 48dp，桌面精确指针命中区即视觉尺寸
  /// （[FushiTouchTargetPadding] 的约定）。
  final MineNoticeAction? action;

  /// 角落小号：图标块 28、字号小一档，给歌词模式 / 视频 OSD 这类「正文铺满全屏」
  /// 的页面用——默认卡会压住正文。
  final bool compact;

  /// 倒计时条按它耗尽，与宿主的自动收起同长。
  final Duration visibleFor;

  /// 宿主暂停了自动收起（悬停 / 键盘聚焦 / 展开详情）：倒计时条停住。
  final bool paused;

  /// 「详情」是否展开（只对失败 / 有缺失生效）。
  final bool expanded;

  /// 非 null 时，原因放不下两行的失败 / 有缺失卡出「详情」按钮。
  final ValueChanged<bool>? onExpandedChanged;

  /// 展开后右上角的关闭按钮（展开期间不自动收起，要给手动关的出口）。
  final VoidCallback? onDismiss;

  final double maxWidth;

  @override
  State<FushiMineNoticeCard> createState() => _FushiMineNoticeCardState();
}

class _FushiMineNoticeCardState extends State<FushiMineNoticeCard>
    with TickerProviderStateMixin {
  late final AnimationController _iconIn = AnimationController(
    vsync: this,
    duration: FushiMotion.long,
  );
  late final Animation<double> _iconSpring = CurvedAnimation(
    parent: _iconIn,
    curve: FushiMotion.release,
  );
  late final AnimationController _countdown = AnimationController(
    vsync: this,
    duration: widget.visibleFor,
    value: 1,
  );
  bool _started = false;
  bool _copied = false;

  bool get _motion => fushiMotionEnabled(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (_motion) {
      _iconIn.forward();
      if (!widget.paused) _countdown.reverse();
    } else {
      _iconIn.value = 1;
    }
  }

  @override
  void didUpdateWidget(FushiMineNoticeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool morphed =
        oldWidget.status != widget.status ||
        oldWidget.visibleFor != widget.visibleFor ||
        oldWidget.message != widget.message;
    if (morphed) {
      // 原地变形（制卡中 → 结果）：图标块重新弹入，倒计时从这一刻按新时长重走。
      _countdown.duration = widget.visibleFor;
      _countdown.value = 1;
      _copied = false;
      if (!_motion) return;
      if (oldWidget.status != widget.status) _iconIn.forward(from: 0);
      if (!widget.paused) _countdown.reverse();
      return;
    }
    if (oldWidget.paused != widget.paused && _motion) {
      if (widget.paused) {
        _countdown.stop();
      } else {
        _countdown.reverse();
      }
    }
  }

  @override
  void dispose() {
    _iconIn.dispose();
    _countdown.dispose();
    super.dispose();
  }

  Future<void> _copyMessage() async {
    await Clipboard.setData(ClipboardData(text: widget.message));
    if (!mounted) return;
    setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final MineNoticeTone tone = mineNoticeTone(widget.status, dark: dark);
    // Apple：白 / 深灰玻璃底，结果颜色只落在圆形图标上，按钮统一系统强调色。
    final FushiAppleColors? glass = apple && !eink
        ? appleColorsOf(context)
        : null;
    final _CardColors colors = _CardColors(
      container: eink
          ? Colors.white
          : glass != null
          ? (dark ? const Color(0xFF2C2C2E) : Colors.white)
          : tone.container,
      onContainer: eink ? Colors.black : glass?.label ?? tone.onContainer,
      accent: eink ? Colors.black : tone.accent,
      onAccent: eink || glass != null ? Colors.white : tone.onAccent,
      action: eink ? Colors.black : glass?.accent ?? tone.actionColor,
    );
    final Duration morph = _motion ? FushiMotion.medium : Duration.zero;
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: colors.container),
      duration: morph,
      curve: FushiMotion.standard,
      builder: (BuildContext context, Color? container, Widget? _) =>
          TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: colors.accent),
            duration: morph,
            curve: FushiMotion.standard,
            builder: (BuildContext context, Color? accent, Widget? _) =>
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) =>
                      _buildCard(
                        context,
                        colors: colors.copyWith(
                          container: container,
                          accent: accent,
                        ),
                        icon: tone.icon,
                        eink: eink,
                        apple: apple,
                        glass: glass != null,
                        width: math.min(widget.maxWidth, constraints.maxWidth),
                      ),
                ),
          ),
    );
  }

  Widget _buildCard(
    BuildContext context, {
    required _CardColors colors,
    required IconData icon,
    required bool eink,
    required bool apple,
    required bool glass,
    required double width,
  }) {
    final FushiTypography type = context.fushiType;
    final bool compact = widget.compact;
    final String title = mineNoticeTitle(widget.status);
    final String? term = _nonEmpty(widget.term);
    final String? reading = _nonEmpty(widget.reading) == term
        ? null
        : _nonEmpty(widget.reading);
    // 第一行：词，没有词时放状态标题。第二行：有词时「标题 · 说明」，没词时只放说明。
    final String headline = term ?? title;
    final String? supportingTitle = term != null ? title : null;
    final String? supportingDetail = _supportingDetail();

    final double iconBox = compact ? 28 : 40;
    final double iconGap = compact ? 8 : 12;
    final double startPad = compact ? 8 : 10;
    final double cardMinHeight = compact ? 44 : 64;
    final double radius = compact ? 18 : 22;
    final bool canExpand =
        widget.onExpandedChanged != null &&
        (widget.status == MineToastStatus.failed ||
            widget.status == MineToastStatus.addedWithWarning);
    final bool expanded = canExpand && widget.expanded;
    final MineNoticeAction? action = widget.action;
    final bool trailingButtons = action != null || canExpand;
    final double endPad = trailingButtons
        ? (compact ? 4 : 6)
        : (compact ? 14 : 20);

    final TextStyle headlineStyle =
        (compact ? type.titleSmall : type.titleMedium).copyWith(
          color: colors.onContainer,
          fontWeight: FontWeight.w700,
          height: 1.25,
        );
    final TextStyle readingStyle = (compact ? type.labelSmall : type.labelLarge)
        .copyWith(color: colors.onContainer.withValues(alpha: 0.74));
    final TextStyle supportingStyle =
        (compact ? type.labelMedium : type.bodyMedium).copyWith(
          color: colors.onContainer,
          height: 1.3,
        );
    final TextStyle buttonStyle = (compact ? type.labelMedium : type.labelLarge)
        .copyWith(fontWeight: FontWeight.w700);
    final TextSpan supportingSpan = TextSpan(
      children: <InlineSpan>[
        if (supportingTitle != null)
          TextSpan(
            text: supportingTitle,
            style: supportingStyle.copyWith(fontWeight: FontWeight.w700),
          ),
        if (supportingTitle != null && supportingDetail != null)
          TextSpan(text: ' · ', style: supportingStyle),
        if (supportingDetail != null)
          TextSpan(text: supportingDetail, style: supportingStyle),
      ],
    );
    const int supportingLines = 2;

    final TextDirection direction = Directionality.of(context);
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    double labelWidth(String label) {
      final TextPainter p = TextPainter(
        text: TextSpan(text: label, style: buttonStyle),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final double w = p.width;
      p.dispose();
      return w + 2 * (compact ? 10 : 12);
    }

    // 「详情」只在放不下时出：按文字区最大可用宽（卡宽扣掉图标块、留白与右侧
    // 按钮）量一次第二行。按钮宽按「详情 + 动作」预留，量的就是出按钮后的真实宽。
    bool overflow = false;
    if (canExpand && !expanded && width.isFinite) {
      final double reserved =
          labelWidth(t.card_notice_details) +
          (action == null ? 0 : labelWidth(action.label));
      final double textWidth =
          width - startPad - iconBox - iconGap - endPad - reserved;
      final TextPainter painter = TextPainter(
        text: supportingSpan,
        maxLines: supportingLines,
        textDirection: direction,
        textScaler: scaler,
      )..layout(maxWidth: math.max(1, textWidth));
      overflow = painter.didExceedMaxLines;
      painter.dispose();
    }

    final Widget iconBlock = AnimatedBuilder(
      animation: _iconSpring,
      builder: (BuildContext context, Widget? child) {
        final double v = _iconSpring.value;
        return Transform.rotate(
          angle: (v - 1) * 1.5708,
          child: Transform.scale(scale: 0.4 + 0.6 * v, child: child),
        );
      },
      child: Container(
        width: iconBox,
        height: iconBox,
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: colors.accent,
          shape: apple
              ? const CircleBorder()
              : MaterialShapeBorder(shape: MaterialShapes.cookie9Sided),
        ),
        child: FushiIcon(icon, color: colors.onAccent, size: compact ? 16 : 22),
      ),
    );

    Widget textButton(
      String label,
      VoidCallback onPressed, {
      required Key key,
      bool filled = false,
    }) => FushiTouchTargetPadding(
      child: FushiTextButton(
        key: key,
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: filled ? colors.onAccent : colors.action,
          backgroundColor: filled ? colors.accent : null,
          textStyle: buttonStyle,
          // 视觉 32 高（大小卡一致），命中区由 [FushiTouchTargetPadding] 补到 48dp。
          minimumSize: const Size(0, 32),
          padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: const StadiumBorder(),
        ),
        child: Text(label),
      ),
    );

    final ValueChanged<bool>? onExpandedChanged = widget.onExpandedChanged;
    final Widget row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: cardMinHeight),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          iconBlock,
          SizedBox(width: iconGap),
          Flexible(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: compact ? 6 : 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text.rich(
                    TextSpan(
                      children: <InlineSpan>[
                        TextSpan(text: headline, style: headlineStyle),
                        if (term != null && reading != null)
                          TextSpan(text: '  $reading', style: readingStyle),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (supportingTitle != null || supportingDetail != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text.rich(
                        supportingSpan,
                        maxLines: supportingLines,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (canExpand && overflow && !expanded)
            textButton(
              t.card_notice_details,
              () => onExpandedChanged?.call(true),
              key: const ValueKey<String>('mine-notice-details'),
            ),
          if (expanded && widget.onDismiss != null)
            FushiTouchTargetPadding(
              child: FushiIconButton(
                key: const ValueKey<String>('mine-notice-dismiss'),
                icon: FushiIcons.close,
                tooltip: t.card_notice_dismiss,
                onTap: widget.onDismiss,
                enabledColor: colors.onContainer,
                size: 20,
              ),
            )
          else if (action != null && !expanded)
            textButton(
              action.label,
              action.onPressed,
              key: const ValueKey<String>('mine-notice-action'),
            ),
        ],
      ),
    );

    final Widget details = Padding(
      padding: EdgeInsetsDirectional.only(
        start: iconBox + iconGap,
        bottom: 12,
        end: 4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: eink || glass
                  ? null
                  : Colors.white.withValues(alpha: 0.55),
              border: eink || glass
                  ? Border.all(color: colors.onContainer.withValues(alpha: 0.3))
                  : null,
              borderRadius: const BorderRadius.all(Radius.circular(14)),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                child: SelectableText(widget.message, style: supportingStyle),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              if (action != null)
                textButton(
                  action.label,
                  action.onPressed,
                  key: const ValueKey<String>('mine-notice-action'),
                  filled: !eink,
                ),
              textButton(
                _copied ? t.card_notice_copied : t.card_notice_copy_error,
                () => _copyMessage(),
                key: const ValueKey<String>('mine-notice-copy'),
              ),
              textButton(
                t.card_notice_hide,
                () => onExpandedChanged?.call(false),
                key: const ValueKey<String>('mine-notice-collapse'),
              ),
            ],
          ),
        ],
      ),
    );

    final BorderRadius borderRadius = BorderRadius.all(
      Radius.circular(expanded ? 24 : radius),
    );
    final Widget body = Stack(
      children: <Widget>[
        Padding(
          padding: EdgeInsetsDirectional.only(start: startPad, end: endPad),
          child: expanded
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[row, details],
                )
              : row,
        ),
        if (_motion && !apple && !expanded)
          // 倒计时条纯装饰、叠在按钮行上方：不接命中，否则它的实色底会吞掉卡片
          // 底边 2–3px 里本属于按钮 48dp 命中带的触点。
          Positioned.fill(
            child: IgnorePointer(
              child: Align(
                alignment: AlignmentDirectional.bottomStart,
                child: AnimatedBuilder(
                  animation: _countdown,
                  builder: (BuildContext context, Widget? _) =>
                      FractionallySizedBox(
                        widthFactor: _countdown.value,
                        child: Container(
                          height: compact ? 2 : 3,
                          color: colors.accent.withValues(alpha: 0.6),
                        ),
                      ),
                ),
              ),
            ),
          ),
      ],
    );

    final List<BoxShadow>? shadow = eink
        ? null
        : compact
        ? const <BoxShadow>[
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ]
        : const <BoxShadow>[
            BoxShadow(
              color: Color(0x47000000),
              blurRadius: 18,
              offset: Offset(0, 6),
            ),
            BoxShadow(
              color: Color(0x40000000),
              blurRadius: 3,
              offset: Offset(0, 1),
            ),
          ];

    final String semantics = <String>[
      ?term,
      title,
      if (supportingDetail != null && supportingDetail != widget.message)
        supportingDetail,
      if (widget.message != title) widget.message,
    ].join('. ');

    return Semantics(
      liveRegion: true,
      container: true,
      label: semantics,
      // 有按钮时不能吞掉子树语义，否则读屏 / 键盘用户够不到按钮。
      excludeSemantics: !trailingButtons,
      child: AnimatedSize(
        duration: _motion ? FushiMotion.medium : Duration.zero,
        curve: FushiMotion.standard,
        alignment: Alignment.topCenter,
        child: Container(
          constraints: BoxConstraints(
            minHeight: cardMinHeight,
            maxWidth: widget.maxWidth,
          ),
          decoration: BoxDecoration(
            color: glass ? null : colors.container,
            borderRadius: borderRadius,
            border: eink
                ? Border.all(
                    color: Colors.black,
                    width: widget.status == MineToastStatus.failed ? 3 : 1.5,
                  )
                : glass
                ? Border.all(color: colors.onContainer.withValues(alpha: 0.08))
                : null,
            boxShadow: shadow,
          ),
          child: ClipRRect(
            borderRadius: borderRadius,
            child: glass
                ? BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: ColoredBox(
                      color: colors.container.withValues(alpha: 0.86),
                      child: body,
                    ),
                  )
                : body,
          ),
        ),
      ),
    );
  }

  /// 第二行标题后面的说明：[FushiMineNoticeCard.detail] 优先，否则整句消息。
  /// 处理中的消息就是「制卡中…」本身，与标题重复，不画。
  String? _supportingDetail() {
    final String? detail = _nonEmpty(widget.detail);
    if (detail != null) return detail;
    if (widget.status == MineToastStatus.pending) return null;
    return _nonEmpty(widget.message);
  }
}

String? _nonEmpty(String? s) {
  final String? v = s?.trim();
  return v == null || v.isEmpty ? null : v;
}

/// 结果卡此刻的五个颜色（底 / 字 / 强调块 / 强调块上的图标 / 文字按钮）。
@immutable
class _CardColors {
  const _CardColors({
    required this.container,
    required this.onContainer,
    required this.accent,
    required this.onAccent,
    required this.action,
  });

  final Color container;
  final Color onContainer;
  final Color accent;
  final Color onAccent;
  final Color action;

  _CardColors copyWith({Color? container, Color? accent}) => _CardColors(
    container: container ?? this.container,
    onContainer: onContainer,
    accent: accent ?? this.accent,
    onAccent: onAccent,
    action: action,
  );
}
