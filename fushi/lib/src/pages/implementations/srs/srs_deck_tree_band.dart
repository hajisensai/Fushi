part of 'srs_deck_list_page.dart';

// =============================================================================
// 牌组树的拼贴版式（所有者 2026-11-15「树状组件跟拼贴很不搭」）
//
// 每个顶层牌组（手机详情页的子牌组清单里是每个直接子牌组）连同它的子孙画成一块
// 按牌组取色的圆角色块（[_DeckBandGroup]），配色与首页拼贴的牌组海报同一套
// （[fushiPosterColors] + 色相键 `srs-deck:<牌组全名>`，所以树里的色块和上方选中牌组的
// 海报同色；按名字而不是 id 取色，已配对设备上的同名牌组与本机同色，设计稿 11-20 #17）。块里每个牌组是一张透明的内层行（[_DeckRow] 的色块分支）：顶层行
// 带 M3E 多边形首字徽章 + 粗圆角进度条，子牌组是缩进 + 细分隔线的内层行；行尾
// 三个计数是带颜色语义的 chip（[SrsDeckCountChips]，0 弱化），播放按钮是块内
// 右侧的圆形 tonal 按钮（[_SrsDeckBandPlayButton]）。展开 / 收起沿用
// [FushiTreeReveal] 的弹簧高度动画与 [FushiTreeChevron] 的箭头旋转；色块底在
// reveal 外面，子行收起时块高跟着弹簧收，块面不会被缩放 / 淡出切出缺口。
//
// 本机牌组树与「已配对设备」分区共用这一套（[_srsDeckBandGroups]）；墨水屏
// （[shellRedesignActive] 为 false）两处都走分段卡行。
// =============================================================================

/// 色块的圆角（与拼贴半高块同档，见 `fushiCoverBlockRadius`）。
const double _kDeckBandRadius = 26;

/// 色块内边距：0——行直接贴满色块（用户 2026-11-16「还是有点怪，像是套两层」：
/// 留边距时行是块里另起的一张卡，悬停 / 选中把它染成块中块）。
const double _kDeckBandInset = 0;

/// 内层行的圆角：与色块同圆角（单行块时行面与块面完全重合）。
const double _kDeckBandTileRadius = _kDeckBandRadius;

/// 行悬停放大倍数的上限：行几乎占满块宽，按封面卡的 1.05 放大会顶出色块。
/// 实际倍数再按行宽封顶（[_deckBandHoverScaleFor]），宽屏长行每侧外扩也落在块内边距里。
const double _kDeckBandHoverScale = 1.015;

/// 宽 [width] 的内层行悬停放大倍数：每侧外扩不超过块内边距减 1px（不压到块边），
/// 且不超过 [_kDeckBandHoverScale]。宽度无界（拖动反馈等）时不放大。
double _deckBandHoverScaleFor(double width) {
  if (!width.isFinite || width <= 0 || _kDeckBandInset <= 1) return 1;
  final double cap = 1 + 2 * (_kDeckBandInset - 1) / width;
  return cap < _kDeckBandHoverScale ? cap : _kDeckBandHoverScale;
}

/// 牌组 [deck] 的色块配色：与首页拼贴的牌组海报（`_SrsDeckPoster`）同一个色相键。
/// 键是牌组全名：本机与已配对设备上的同名牌组同色（两边的牌组 id 不相干）。
FushiCoverBlockColors _srsDeckBandColors(
  BuildContext context,
  SrsDeckSummary deck,
) => fushiPosterColors(context, fushiPosterHue('srs-deck:${deck.fullName}'));

/// 先序牌组列表 [decks] 切成色块：一个组 = 一个（相对 [baseDepth]）顶层牌组 + 紧跟其后的
/// 子孙，块按组头牌组取色（[_srsDeckBandColors]）。行由调用方的 [rowAt] 建（本机树与已配对
/// 设备分区各自接自己的数据源与动作，行组件都是 [_DeckRow]）；[index] 是行在块里的位置。
List<Widget> _srsDeckBandGroups(
  BuildContext context, {
  required List<SrsDeckSummary> decks,
  required int baseDepth,
  required String keyPrefix,
  required Widget Function(int i, {required int index, required _DeckBand band})
  rowAt,
}) {
  final List<Widget> groups = <Widget>[];
  int i = 0;
  while (i < decks.length) {
    final SrsDeckSummary head = decks[i];
    final FushiCoverBlockColors colors = _srsDeckBandColors(context, head);
    final List<Widget> rows = <Widget>[
      rowAt(i, index: 0, band: _DeckBand(colors: colors, inner: false)),
    ];
    int j = i + 1;
    while (j < decks.length && decks[j].depth - baseDepth > 0) {
      rows.add(
        rowAt(
          j,
          index: j - i,
          band: _DeckBand(colors: colors, inner: true),
        ),
      );
      j++;
    }
    groups.add(
      _DeckBandGroup(
        key: ValueKey<String>('$keyPrefix${head.deck.id}'),
        colors: colors,
        children: rows,
      ),
    );
    i = j;
  }
  return groups;
}

/// 行所在的色块：配色 + 是不是块里的内层（子牌组）行。
@immutable
class _DeckBand {
  const _DeckBand({required this.colors, required this.inner});

  final FushiCoverBlockColors colors;

  /// 子牌组行（块里的内层行：缩进 + 顶部细分隔线，不画徽章）。
  final bool inner;
}

/// 一块牌组色块：圆角底 + 半高块投影，里面纵向排这一组的各行。
class _DeckBandGroup extends StatelessWidget {
  const _DeckBandGroup({
    super.key,
    required this.colors,
    required this.children,
  });

  final FushiCoverBlockColors colors;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: colors.container,
        shape: shellShape(
          context,
          const BorderRadius.all(Radius.circular(_kDeckBandRadius)),
        ),
        shadows: fushiCoverBlockShadows(FushiCoverBlockSize.half),
      ),
      child: Padding(
        padding: const EdgeInsets.all(_kDeckBandInset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

/// 色块里的内层行外壳：透明行面（选中时一层 onContainer 薄染 + 强调色描边），
/// 悬停 [FushiHoverLift] 轻抬、按下下沉（[FushiHoverLift] 内层自带 [FushiPressScale]，
/// 这里不再另包一层，否则按下会叠乘两次）；点按 / 长按 / 右键与焦点目标都由
/// [FushiCard] 挂（与原分段卡行同一套）。
class _DeckBandTile extends StatelessWidget {
  const _DeckBandTile({
    required this.colors,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onSecondaryTap,
    required this.child,
  });

  final FushiCoverBlockColors colors;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onSecondaryTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) =>
          FushiHoverLift(
            scale: _deckBandHoverScaleFor(constraints.maxWidth),
            builder: (BuildContext context, bool hovering) => FushiCard(
              padding: EdgeInsets.zero,
              // 选中 / 悬停只在色块原底色上加一层同色系淡染，不描边、不用通用灰色
              // 状态层：行贴满色块，染色读作「这块被点亮」而不是块里又浮起一张卡
              // （用户 2026-11-16 两张截图）。键盘焦点环仍由 FushiCard 自己画。
              color: colors.onContainer.withValues(
                alpha: (selected ? 0.07 : 0) + (hovering ? 0.05 : 0),
              ),
              stateLayer: false,
              borderRadius: const BorderRadius.all(
                Radius.circular(_kDeckBandTileRadius),
              ),
              selected: selected,
              // 按压下沉由 FushiHoverLift 内层的 FushiPressScale 统一给（两套设计系统一致）。
              pressScale: false,
              morph: false,
              onTap: onTap,
              onLongPress: onLongPress,
              onSecondaryTap: onSecondaryTap,
              child: child,
            ),
          ),
    );
  }
}

/// 子牌组行顶上的细分隔线（色块里的内层行之间）。
class _DeckBandDivider extends StatelessWidget {
  const _DeckBandDivider({required this.colors, required this.indent});

  final FushiCoverBlockColors colors;

  /// 起点距行左缘（跟着层级缩进，线从箭头位开始）。
  final double indent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsetsDirectional.only(start: indent, end: 14),
      child: SizedBox(
        height: 1,
        child: ColoredBox(color: colors.onContainer.withValues(alpha: 0.10)),
      ),
    );
  }
}

/// 色块行名下的粗圆角进度条（今天的完成度，口径见 [srsTodayProgress]）。
class _SrsDeckBandProgress extends StatelessWidget {
  const _SrsDeckBandProgress({
    super.key,
    required this.value,
    required this.colors,
  });

  static const double height = 6;

  /// 定长短条：按行宽拉长时 0% 只剩一长条空轨，也和行尾 chip 对不齐。
  static const double maxWidth = 200;

  final double value;
  final FushiCoverBlockColors colors;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.onContainer.withValues(alpha: 0.14),
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: value.clamp(0, 1)),
              duration: fushiMotionDuration(context, FushiMotion.long),
              curve: FushiMotion.enter,
              builder: (BuildContext context, double f, Widget? _) =>
                  FractionallySizedBox(
                    widthFactor: f,
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.accent,
                        borderRadius: BorderRadius.circular(height / 2),
                      ),
                    ),
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 色块内右侧的圆形 tonal 播放按钮：直接复习这个牌组。
class _SrsDeckBandPlayButton extends StatelessWidget {
  const _SrsDeckBandPlayButton({
    super.key,
    required this.colors,
    required this.onTap,
  });

  final FushiCoverBlockColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FushiPressScale(
      child: FushiIconButton(
        icon: FushiIcons.play,
        tooltip: t.srs_home_review_deck,
        backgroundColor: colors.accent.withValues(alpha: 0.18),
        enabledColor: colors.accent,
        size: 20,
        onTap: onTap,
      ),
    );
  }
}

/// 色块牌组行的三个计数：新卡 / 学习中 / 待复习各一枚带颜色语义的 chip
/// （色相取 [srsCountColors]，与今日计划条的图例同色），0 弱化成淡底淡字。
///
/// 宽行 chip 里带一个色点；窄屏（[compact]）去掉色点、收窄，把宽度让给牌组名。
/// 各 chip 最小宽度固定，各行的计数列上下对齐。RWKV 准备中时待复习一枚换成沙漏
/// （有 FSRS 到期时数字后面跟沙漏），口径同 [SrsCountTriple]。
class SrsDeckCountChips extends StatelessWidget {
  const SrsDeckCountChips({
    super.key,
    required this.newCount,
    required this.learnCount,
    required this.reviewCount,
    required this.colors,
    this.reviewPending = false,
    this.compact = false,
  });

  final int newCount;
  final int learnCount;
  final int reviewCount;

  /// 所在色块的配色（chip 底 / 字按它调和）。
  final FushiCoverBlockColors colors;

  /// 见 [SrsCountTriple.reviewPending]。
  final bool reviewPending;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ({Color fresh, Color learn, Color review}) hues = srsCountColors(
      context,
    );
    final SrsReviewCell review = SrsReviewCell(
      due: reviewCount,
      pending: reviewPending,
    );
    return Semantics(
      label:
          '${t.srs_count_new} $newCount, ${t.srs_count_learn} $learnCount, '
          '${review.label()}',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: compact ? 3 : 6,
          children: <Widget>[
            _chip(
              context,
              value: newCount,
              hue: hues.fresh,
              tip: t.srs_count_new,
            ),
            _chip(
              context,
              value: learnCount,
              hue: hues.learn,
              tip: t.srs_count_learn,
            ),
            _chip(
              context,
              value: reviewCount,
              hue: hues.review,
              tip: reviewPending
                  ? t.srs_review_rwkv_pending
                  : t.srs_count_review,
              pending: reviewPending,
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(
    BuildContext context, {
    required int value,
    required Color hue,
    required String tip,
    bool pending = false,
  }) {
    final bool zero = value == 0 && !pending;
    final Color ink = zero
        ? colors.onContainer.withValues(alpha: 0.42)
        : Color.lerp(hue, colors.onContainer, 0.3)!;
    final Color fill = zero
        ? colors.onContainer.withValues(alpha: 0.06)
        : hue.withValues(alpha: 0.20);
    final TextStyle style =
        (compact ? context.fushiType.labelMedium : context.fushiType.labelLarge)
            .copyWith(
              color: ink,
              fontWeight: zero ? FontWeight.w500 : FontWeight.w700,
              height: 1,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            );
    final double height = compact ? 22 : 28;
    return FushiTooltip(
      message: tip,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: compact ? 28 : 46,
          minHeight: height,
          maxHeight: height,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(height / 2),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: compact ? 2 : 5,
              children: <Widget>[
                if (!compact)
                  SizedBox.square(
                    dimension: 6,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: zero ? hue.withValues(alpha: 0.35) : hue,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                if (!pending || value > 0) Text('$value', style: style),
                if (pending)
                  FushiIcon(
                    FushiIcons.pending,
                    key: const ValueKey<String>('srs-count-review-pending'),
                    size: (style.fontSize ?? 14) * 1.05,
                    color: ink,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
