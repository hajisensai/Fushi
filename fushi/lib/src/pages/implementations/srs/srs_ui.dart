/// 复习（Fushi 内置 SRS）各页共用的小件：三色计数、牌组选择、值格式化。
library;

import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

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

/// 三个计数并排（等宽数字，0 显示成弱化色）。
class SrsCountTriple extends StatelessWidget {
  const SrsCountTriple({
    super.key,
    required this.newCount,
    required this.learnCount,
    required this.reviewCount,
    this.dense = false,
  });

  final int newCount;
  final int learnCount;
  final int reviewCount;
  final bool dense;

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
        constraints: BoxConstraints(minWidth: dense ? 24 : 32),
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
    return Semantics(
      label:
          '${t.srs_count_new} $newCount, ${t.srs_count_learn} $learnCount, '
          '${t.srs_count_review} $reviewCount',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: tokens.spacing.gap,
          children: <Widget>[
            cell(newCount, colors.fresh, t.srs_count_new),
            cell(learnCount, colors.learn, t.srs_count_learn),
            cell(reviewCount, colors.review, t.srs_count_review),
          ],
        ),
      ),
    );
  }
}

/// 新卡被自动缩减时的一行说明；没缩减返回 null。
String? srsNewBudgetNote(SrsNewCardBudget budget) => switch (budget.reason) {
  SrsNewCardBudgetReason.reduced => t.srs_deck_new_reduced(n: budget.allowed),
  SrsNewCardBudgetReason.paused => t.srs_deck_new_paused,
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

/// Lapis 里最常用、放在编辑页最前面的字段（其余折进「更多字段」）。
const List<String> kSrsLapisPrimaryFields = <String>[
  'Expression',
  'ExpressionReading',
  'MainDefinition',
  'Sentence',
];

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
  _ => key,
};
