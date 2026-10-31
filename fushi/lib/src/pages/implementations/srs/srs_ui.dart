/// 复习（Fushi 内置 SRS）各页共用的小件：三色计数、牌组选择、值格式化。
library;

import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 新卡 / 学习 / 到期三种计数的颜色。
///
/// MD3 取主题色（primary / error / tertiary，跟随用户主题与动态取色）；Apple 取系统
/// 语义色（强调蓝 / 系统红 / 系统绿），与 Anki 的蓝 / 红 / 绿同一组认知。
({Color fresh, Color learn, Color review}) srsCountColors(
  BuildContext context,
) {
  if (isGlassDesign(context)) {
    final FushiAppleColors apple = appleColorsOf(context);
    return (
      fresh: apple.accent,
      learn: apple.destructive,
      review: apple.success,
    );
  }
  final ColorScheme scheme = Theme.of(context).colorScheme;
  return (fresh: scheme.primary, learn: scheme.error, review: scheme.tertiary);
}

/// 元信息行（「12 条笔记 · 4 个字段 · 1 种卡片」）：每一段是不可拆的整体，只在
/// 段与段之间折行。整串交给一个 [Text] 时，窄屏会在「1」和「种卡片」之间断开
/// （段内的空格是普通断行点），数字与单位分居两行。
///
/// 每段单行、放不下时自身省略号收尾（不会溢出）；样式继承上层 [DefaultTextStyle]
/// （列表行副标题的字号 / 颜色）。
class SrsMetaLine extends StatelessWidget {
  const SrsMetaLine(this.segments, {super.key});

  /// 段间分隔符，与各页 `join(' · ')` 同形。
  static const String separator = ' · ';

  /// 把已用 [separator] 拼好的本地化串（如 i18n 摘要）拆回各段。
  static List<String> split(String joined) => joined.split(separator);

  final List<String> segments;

  @override
  Widget build(BuildContext context) {
    final List<String> parts = <String>[
      for (final String s in segments)
        if (s.isNotEmpty) s,
    ];
    return Wrap(
      children: <Widget>[
        for (int i = 0; i < parts.length; i++)
          Text(
            i == parts.length - 1 ? parts[i] : '${parts[i]}$separator',
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }
}

/// 三个计数并排（等宽数字，0 显示成弱化色）。
class SrsCountTriple extends StatelessWidget {
  const SrsCountTriple({
    super.key,
    required this.newCount,
    required this.learnCount,
    required this.reviewCount,
    this.reviewPending = false,
    this.dense = false,
    this.tight = false,
  });

  final int newCount;
  final int learnCount;
  final int reviewCount;

  /// RWKV 还没准备好，RWKV 牌组的复习卡没算进 [reviewCount]（[SrsDeckSummary.rwkvPending]）：到期一格显示
  /// 「准备中」（沙漏），不把 0 显示成「今天没有到期」；有别的（FSRS）牌组的到期时数字照旧、后面跟沙漏。
  final bool reviewPending;
  final bool dense;

  /// 手机竖屏牌组列表：数字列收窄（最小 20）、列间距减半，三个数合成一小块，
  /// 把宽度让给牌组名。
  final bool tight;

  @override
  Widget build(BuildContext context) {
    final ({Color fresh, Color learn, Color review}) colors = srsCountColors(
      context,
    );
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextStyle base =
        (dense ? context.fushiType.labelLarge : context.fushiType.titleMedium)
            .copyWith(
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            );
    final Color muted = Theme.of(context).disabledColor;
    Widget cell(int value, Color color, String label) => FushiTooltip(
      message: label,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: tight
              ? 20
              : dense
              ? 24
              : 32,
        ),
        child: Text(
          '$value',
          textAlign: TextAlign.end,
          style: base.copyWith(
            color: value == 0 ? muted : color,
            fontWeight: value == 0 ? FontWeight.w400 : FontWeight.w600,
          ),
        ),
      ),
    );
    Widget pendingReviewCell() => FushiTooltip(
      message: t.srs_review_rwkv_pending,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: tight
              ? 20
              : dense
              ? 24
              : 32,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            if (reviewCount > 0)
              Text(
                '$reviewCount',
                style: base.copyWith(
                  color: colors.review,
                  fontWeight: FontWeight.w600,
                ),
              ),
            FushiIcon(
              FushiIcons.pending,
              key: const ValueKey<String>('srs-count-review-pending'),
              size: (base.fontSize ?? 14) * 1.05,
              color: colors.review,
            ),
          ],
        ),
      ),
    );
    final String reviewLabel = reviewPending
        ? '${t.srs_count_review} '
              '${reviewCount > 0 ? '$reviewCount, ' : ''}'
              '${t.srs_settings_rwkv_preparing_start}'
        : '${t.srs_count_review} $reviewCount';
    return Semantics(
      label:
          '${t.srs_count_new} $newCount, ${t.srs_count_learn} $learnCount, '
          '$reviewLabel',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: tight ? tokens.spacing.gap / 2 : tokens.spacing.gap,
          children: <Widget>[
            cell(newCount, colors.fresh, t.srs_count_new),
            cell(learnCount, colors.learn, t.srs_count_learn),
            if (reviewPending)
              pendingReviewCell()
            else
              cell(reviewCount, colors.review, t.srs_count_review),
          ],
        ),
      ),
    );
  }
}

/// 页面分区在宽窗下落在哪一栏。
enum SrsPane { primary, secondary }

/// [SrsAdaptiveSections] 的一块分区：窄窗按 [SrsAdaptiveSections.sections] 的
/// 顺序单列排；宽窗按 [pane] 分进左（primary）/ 右（secondary）两栏。
class SrsSection {
  const SrsSection(this.child, {this.pane = SrsPane.primary});

  final Widget child;
  final SrsPane pane;
}

/// SRS 表单类页面是否分成两栏：走全仓唯一的 MD3 window size class 断点
/// （[windowSizeClassOf]，expanded ≥ 840），与浏览页的列表 + 预览分栏同一阈值。
/// 手机横屏（~840–930 宽）与桌面窗口都落在这里。
bool srsUsesTwoPane(BoxConstraints constraints) =>
    windowSizeClassOf(constraints) == WindowSizeClass.expanded;

/// MD3 window height class 的 compact 上限（矮于此为 compact height）。
const double kSrsCompactHeight = 480;

/// 又宽又矮的区域（手机横屏、横屏下的分栏预览）：卡面下方再压一排按钮会把
/// 卡面挤成一条，按钮应改到卡面右侧竖排。
bool srsIsShortLandscape(BoxConstraints constraints) =>
    constraints.maxHeight < kSrsCompactHeight &&
    constraints.maxWidth > constraints.maxHeight;

/// SRS 列表页（牌组 / 浏览 / 笔记类型）的行密度：整窗又宽又矮（手机横屏）时用
/// 紧凑行，一屏多放一两行；其余照旧。
FushiListDensity srsListDensityOf(BuildContext context) =>
    srsIsShortLandscape(BoxConstraints.tight(MediaQuery.sizeOf(context)))
    ? FushiListDensity.compact
    : FushiListDensity.standard;

/// SRS 各表单页（牌组选项、笔记编辑、更改笔记类型、笔记类型编辑……）共用的正文：
/// 窄窗一列卡片纵向滚动；宽窗左右两栏各自滚动——手机横屏只有 ~400 高，两栏并排
/// 把滚动距离减半，桌面宽窗也不再是一条两侧大片留白的长卡片。
///
/// 两栏各是一个焦点遍历组（Tab 先走完左栏再进右栏），都接错峰进场。某一栏没有
/// 分区时退回单列。
class SrsAdaptiveSections extends StatelessWidget {
  const SrsAdaptiveSections({
    super.key,
    required this.sections,
    this.primaryFlex = 1,
    this.secondaryFlex = 1,
  });

  final List<SrsSection> sections;
  final int primaryFlex;
  final int secondaryFlex;

  /// 宽窗两栏的 key（测试按它量两栏位置）。
  static const ValueKey<String> primaryPaneKey = ValueKey<String>(
    'srs-pane-primary',
  );
  static const ValueKey<String> secondaryPaneKey = ValueKey<String>(
    'srs-pane-secondary',
  );

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double top = tokens.spacing.gap + MediaQuery.paddingOf(context).top;
    EdgeInsets padding(double left, double right) => withBottomSafeInset(
      context,
      EdgeInsets.fromLTRB(left, top, right, tokens.spacing.section),
    );
    Widget column(List<Widget> items, EdgeInsets insets, {Key? key}) =>
        ListView.separated(
          key: key,
          padding: insets,
          itemCount: items.length,
          separatorBuilder: (BuildContext context, int index) =>
              SizedBox(height: tokens.spacing.gap * 1.5),
          itemBuilder: fushiStaggeredItemBuilder(
            (BuildContext context, int index) => items[index],
          ),
        );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final List<Widget> primary = <Widget>[
          for (final SrsSection s in sections)
            if (s.pane == SrsPane.primary) s.child,
        ];
        final List<Widget> secondary = <Widget>[
          for (final SrsSection s in sections)
            if (s.pane == SrsPane.secondary) s.child,
        ];
        if (!srsUsesTwoPane(constraints) ||
            primary.isEmpty ||
            secondary.isEmpty) {
          return FushiEntranceScope(
            child: column(<Widget>[
              for (final SrsSection s in sections) s.child,
            ], padding(tokens.spacing.page, tokens.spacing.page)),
          );
        }
        final double half = tokens.spacing.gap * 0.75;
        // 两栏各自滚动：页头（返回键）不跟任何一栏收起，见 [FushiPinnedPageChromeScope]。
        return FushiEntranceScope(
          child: FushiPinnedPageChromeScope(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  flex: primaryFlex,
                  child: FocusTraversalGroup(
                    child: column(
                      primary,
                      padding(tokens.spacing.page, half),
                      key: primaryPaneKey,
                    ),
                  ),
                ),
                Expanded(
                  flex: secondaryFlex,
                  child: FocusTraversalGroup(
                    child: column(
                      secondary,
                      padding(half, tokens.spacing.page),
                      key: secondaryPaneKey,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 新卡被自动调整时的一行说明；没调整返回 null。
String? srsNewBudgetNote(SrsNewCardBudget budget) => switch (budget.reason) {
  SrsNewCardBudgetReason.reduced => t.srs_deck_new_reduced(n: budget.allowed),
  SrsNewCardBudgetReason.paused => t.srs_deck_new_paused,
  SrsNewCardBudgetReason.increased => t.srs_deck_new_increased(
    n: budget.allowed,
  ),
  null => null,
};

/// 修改记录的写入者 ID 去掉化身号（`设备ID#3` → `设备ID`）。
String srsWriterDevice(String writerId) {
  final int hash = writerId.lastIndexOf('#');
  return hash < 0 ? writerId : writerId.substring(0, hash);
}

/// 设备 ID 一般是长随机串，界面只给前 8 位。
String srsShortDevice(String writerId) {
  final String device = srsWriterDevice(writerId);
  return device.length <= 8 ? device : device.substring(0, 8);
}

/// 冲突值的人读形式（布尔 / 空 / 结构化值）。
String srsFormatValue(Object? value) => switch (value) {
  null => '—',
  true => t.srs_value_yes,
  false => t.srs_value_no,
  final String s when s.isEmpty => '—',
  final String s => s,
  final num n => '$n',
  _ => jsonEncode(value),
};

/// 本地化的「日期 时刻」（跟随系统 24 小时制设置）。
String srsTimeLabel(BuildContext context, DateTime t) {
  final MaterialLocalizations l = MaterialLocalizations.of(context);
  final bool h24 = MediaQuery.maybeAlwaysUse24HourFormatOf(context) ?? false;
  return '${l.formatMediumDate(t)} '
      '${l.formatTimeOfDay(TimeOfDay.fromDateTime(t), alwaysUse24HourFormat: h24)}';
}

/// 毫秒时刻 → 本地「日期 时:分」。
String srsFormatMoment(int ms) =>
    FushiTimeFormat.dateHourMinute(DateTime.fromMillisecondsSinceEpoch(ms));

/// 从牌组里选一个（移动卡片 / 新建笔记用）。返回 null = 取消。
Future<String?> pickSrsDeck(
  BuildContext context, {
  required List<SrsDeckSummary> decks,
  String? selected,
  required String title,
}) {
  return showFushiChoiceDialog<String>(
    context: context,
    title: title,
    icon: FushiIcons.folder,
    selected: selected,
    options: <FushiChoiceOption<String>>[
      for (final SrsDeckSummary d in decks)
        FushiChoiceOption<String>(value: d.deck.id, label: d.fullName),
    ],
  );
}

/// 牌组选择器的一项（只要 id 与全名，不带计数）。
typedef SrsDeckChoice = ({String id, String fullName});

/// 牌组选择器用的牌组清单：先序（父在前、子紧跟父），同级按手动位置再按名字——与
/// [SrsDbStore.deckSummaries] 的顺序同一口径，但**只读牌组树**。
///
/// 编辑页 / 移动卡片只要名字：`deckSummaries()` 会给每个牌组数新卡 / 学习 / 到期，
/// RWKV 牌组还要对全部复习卡跑一遍即时可提取度推理（`_instantReviews`，缓存最多 30 秒）——
/// 查词弹窗跳到卡片打开编辑页时那一下就慢在这里。
Future<List<SrsDeckChoice>> srsDeckChoices(SrsDbStore store) async {
  final SrsDeckTree tree = await store.deckTree();
  final Map<String?, List<SrsDeckView>> children =
      <String?, List<SrsDeckView>>{};
  for (final SrsDeckView d in tree.decks) {
    (children[tree.parentOf(d.id)] ??= <SrsDeckView>[]).add(d);
  }
  final List<SrsDeckChoice> out = <SrsDeckChoice>[];
  void visit(String? parent) {
    final List<SrsDeckView> level = (children[parent] ?? <SrsDeckView>[])
      ..sort(SrsDeckView.compareSiblings);
    for (final SrsDeckView d in level) {
      out.add((id: d.id, fullName: tree.fullName(d.id)));
      visit(d.id);
    }
  }

  visit(null);
  return out;
}

/// [pickSrsDeck] 的轻量版：吃 [srsDeckChoices] 的结果（不需要计数的地方用它）。
Future<String?> pickSrsDeckChoice(
  BuildContext context, {
  required List<SrsDeckChoice> decks,
  String? selected,
  required String title,
}) {
  return showFushiChoiceDialog<String>(
    context: context,
    title: title,
    icon: FushiIcons.folder,
    selected: selected,
    options: <FushiChoiceOption<String>>[
      for (final SrsDeckChoice d in decks)
        FushiChoiceOption<String>(value: d.id, label: d.fullName),
    ],
  );
}

/// 删除一条笔记（连同全部卡片）前的确认框；确认返回 true。文案与浏览页批量删除同一套。
/// 编辑页顶栏「删除笔记」用：确认后调 `SrsDbStore.deleteNote`（墓碑，可在浏览 / 冲突页恢复）。
Future<bool> confirmSrsNoteDelete(BuildContext context) =>
    showFushiConfirmDialog(
      context: context,
      title: t.srs_note_delete,
      message: t.srs_browse_delete_confirm(n: 1),
      confirmLabel: t.srs_note_delete,
      cancelLabel: t.cancel,
      icon: FushiIcons.delete,
      destructive: true,
    );

/// Lapis 里最常用、放在编辑页最前面的字段（其余折进「更多字段」）。
const List<String> kSrsLapisPrimaryFields = <String>[
  'Expression',
  'ExpressionReading',
  'MainDefinition',
  'Sentence',
];

/// Fushi 卡片编辑页默认展开的字段（按卡面区块分组显示，其余折进「更多字段」）：
/// 词条、读音与单词音频、图片、例句（含翻译 / 音频）、主释义。
const Set<String> kSrsFushiCardPrimaryFields = <String>{
  'Term',
  'TermFurigana',
  'TermReading',
  'TermAudio',
  'Media',
  'Sentence',
  'SentenceTranslation',
  'SentenceAudio',
  'MainDefinition',
};

/// 旗标值 → 标签（0 = 无旗标；1–7 与 Anki 同序）。
String srsFlagLabel(int flag) => switch (flag) {
  1 => t.srs_flag_red,
  2 => t.srs_flag_orange,
  3 => t.srs_flag_green,
  4 => t.srs_flag_blue,
  5 => t.srs_flag_pink,
  6 => t.srs_flag_turquoise,
  7 => t.srs_flag_purple,
  _ => t.srs_flag_none,
};

/// 牌组设置键 → 人读名（冲突页 / 设置页标记用）。
String srsFieldKeyLabel(SrsEntityKind kind, String key) => switch (key) {
  SrsFieldKeys.name => t.srs_key_name,
  SrsFieldKeys.deckLimits => t.srs_key_limits,
  SrsFieldKeys.deckSteps => t.srs_key_steps,
  SrsFieldKeys.deckRetention => t.srs_settings_retention,
  SrsFieldKeys.deckAlgorithm => t.srs_settings_algorithm,
  SrsFieldKeys.deckRwkvQueue => t.srs_settings_rwkv_queue,
  SrsFieldKeys.deckNewPlan => t.srs_settings_new_plan,
  SrsFieldKeys.deckFsrs6Params ||
  SrsFieldKeys.deckFsrs7Params => t.srs_key_params,
  SrsFieldKeys.deckAutoOptimize => t.srs_settings_auto_optimize,
  SrsFieldKeys.deckMaxInterval => t.srs_settings_max_interval,
  SrsFieldKeys.deckParamsMode => t.srs_settings_params_mode,
  SrsFieldKeys.deckParent => t.srs_key_parent,
  SrsFieldKeys.suspended => t.srs_card_suspend,
  SrsFieldKeys.buriedUntilDay => t.srs_card_bury,
  SrsFieldKeys.flag => t.srs_card_flag,
  // 卡片与笔记的牌组键同名（'deck'）。
  SrsFieldKeys.cardDeck => t.srs_key_deck,
  SrsFieldKeys.dayRolloverHour => t.srs_key_rollover,
  SrsFieldKeys.deleted => t.srs_key_deleted,
  SrsFieldKeys.noteType => t.srs_note_type,
  SrsFieldKeys.css => t.srs_note_types_styling,
  SrsFieldKeys.termField => t.srs_note_types_term_field,
  _ => key,
};
