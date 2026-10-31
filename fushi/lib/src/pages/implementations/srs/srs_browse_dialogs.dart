/// 浏览页的对话框与小件：搜索帮助、排序选择、批量菜单、行状态文字。
library;

import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 批量菜单项。
enum SrsBrowseBatchAction {
  toggleSuspend,
  toggleBury,
  flag,
  move,
  addTags,
  removeTags,
  reset,
  setDue,
  changeNoteType,
  migrateToFushiCard,
  delete,
}

/// 批量菜单项的文字。
String srsBrowseBatchLabel(SrsBrowseBatchAction a) => switch (a) {
  SrsBrowseBatchAction.toggleSuspend => t.srs_browse_toggle_suspend,
  SrsBrowseBatchAction.toggleBury => t.srs_browse_bury_toggle,
  SrsBrowseBatchAction.flag => t.srs_card_flag,
  SrsBrowseBatchAction.move => t.srs_card_move,
  SrsBrowseBatchAction.addTags => t.srs_browse_tags_add,
  SrsBrowseBatchAction.removeTags => t.srs_browse_tags_remove,
  SrsBrowseBatchAction.reset => t.srs_card_reset,
  SrsBrowseBatchAction.setDue => t.srs_browse_set_due,
  SrsBrowseBatchAction.changeNoteType => t.srs_browse_change_note_type,
  SrsBrowseBatchAction.migrateToFushiCard => t.srs_migrate_fushi_action,
  SrsBrowseBatchAction.delete => t.srs_browse_delete_notes,
};

/// 排序列的文字。
String srsBrowseSortLabel(SrsBrowseSort sort) => switch (sort.column) {
  SrsBrowseSortColumn.sortField => t.srs_browse_sort_sort_field,
  SrsBrowseSortColumn.field => t.srs_browse_sort_field_named(
    name: sort.fieldName ?? '',
  ),
  SrsBrowseSortColumn.due => t.srs_browse_sort_due,
  SrsBrowseSortColumn.created => t.srs_browse_sort_created,
  SrsBrowseSortColumn.modified => t.srs_browse_sort_modified,
  SrsBrowseSortColumn.interval => t.srs_browse_sort_interval,
  SrsBrowseSortColumn.difficulty => t.srs_browse_sort_difficulty,
  SrsBrowseSortColumn.reps => t.srs_browse_sort_reps,
  SrsBrowseSortColumn.lapses => t.srs_browse_sort_lapses,
  SrsBrowseSortColumn.deck => t.srs_key_deck,
  SrsBrowseSortColumn.noteType => t.srs_note_type,
};

/// 选排序列；选「指定字段」时接着选字段。返回 null = 取消。方向沿用 [current]。
Future<SrsBrowseSort?> pickSrsBrowseSort(
  BuildContext context, {
  required SrsBrowseSort current,
  required List<String> fieldNames,
}) async {
  final SrsBrowseSortColumn? column =
      await showFushiChoiceDialog<SrsBrowseSortColumn>(
        context: context,
        title: t.srs_browse_sort_title,
        icon: FushiIcons.sort,
        selected: current.column,
        options: <FushiChoiceOption<SrsBrowseSortColumn>>[
          for (final SrsBrowseSortColumn c in SrsBrowseSortColumn.values)
            if (c != SrsBrowseSortColumn.field || fieldNames.isNotEmpty)
              FushiChoiceOption<SrsBrowseSortColumn>(
                value: c,
                label: c == SrsBrowseSortColumn.field
                    ? t.srs_browse_sort_field_pick
                    : srsBrowseSortLabel(
                        SrsBrowseSort(column: c, ascending: current.ascending),
                      ),
              ),
        ],
      );
  if (column == null || !context.mounted) return null;
  if (column != SrsBrowseSortColumn.field) {
    return SrsBrowseSort(column: column, ascending: current.ascending);
  }
  final String? field = await pickSrsBrowseField(
    context,
    fieldNames: fieldNames,
    selected: current.fieldName,
    title: t.srs_browse_sort_field_pick,
    allowAll: false,
  );
  if (field == null) return null;
  return SrsBrowseSort(
    column: SrsBrowseSortColumn.field,
    ascending: current.ascending,
    fieldName: field,
  );
}

/// 「全部字段」在选择框里的占位值（字段名不可能为空串）。
const String kSrsBrowseAllFields = '';

/// 选一个字段（[allowAll] 时第一项是「全部字段（搜索语法）」，返回 [kSrsBrowseAllFields]）。
Future<String?> pickSrsBrowseField(
  BuildContext context, {
  required List<String> fieldNames,
  required String? selected,
  required String title,
  bool allowAll = true,
}) => showFushiChoiceDialog<String>(
  context: context,
  title: title,
  icon: FushiIcons.filterList,
  selected: selected ?? (allowAll ? kSrsBrowseAllFields : null),
  options: <FushiChoiceOption<String>>[
    if (allowAll)
      FushiChoiceOption<String>(
        value: kSrsBrowseAllFields,
        label: t.srs_browse_search_field_all,
      ),
    for (final String f in fieldNames)
      FushiChoiceOption<String>(value: f, label: f),
  ],
);

/// 搜索语法帮助的一行：语法示例（不翻译）+ 说明。
List<(String, String)> srsBrowseSearchHelpRows() => <(String, String)>[
  ('食べる', t.srs_browse_help_text),
  ('Expression:食べる   Expression:*食*', t.srs_browse_help_field),
  (r'Expression:re:^食', t.srs_browse_help_field_regex),
  (r're:\d+', t.srs_browse_help_regex),
  ('deck:日本語   deck:"My Deck"', t.srs_browse_help_deck),
  ('note:Lapis', t.srs_browse_help_note),
  ('tag:verb   tag:none', t.srs_browse_help_tag),
  ('card:1   card:Recognition', t.srs_browse_help_card),
  (
    'is:new  is:learn  is:review  is:due  is:suspended  is:buried',
    t.srs_browse_help_is,
  ),
  ('flag:1   -flag:0', t.srs_browse_help_flag),
  (
    'prop:ivl>=10   prop:due<=1   prop:lapses>3   prop:d>0.8',
    t.srs_browse_help_prop,
  ),
  ('added:7   edited:7', t.srs_browse_help_days),
  ('a b   a or b   -a   (a or b) c', t.srs_browse_help_logic),
  ('"a b"', t.srs_browse_help_quote),
];

/// 搜索语法帮助。
Future<void> showSrsBrowseSearchHelp(BuildContext context) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final ColorScheme colors = Theme.of(context).colorScheme;
  return showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      icon: const FushiDialogHeroIcon(
        icon: FushiIcons.help,
        tone: FushiHeroTone.neutral,
      ),
      title: Text(t.srs_browse_search_help),
      actions: <Widget>[
        FushiDialogAction(
          label: t.dialog_ok,
          kind: FushiDialogActionKind.primary,
          autofocus: true,
          onPressed: () => Navigator.of(dialogContext).pop(),
        ),
      ],
      content: _helpBody(context, tokens, colors),
    ),
  );
}

Widget _helpBody(
  BuildContext context,
  FushiDesignTokens tokens,
  ColorScheme colors,
) {
  return SizedBox(
    width: 520,
    child: SingleChildScrollView(
      key: const ValueKey<String>('srs-browse-search-help'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final (String syntax, String meaning)
              in srsBrowseSearchHelpRows())
            Padding(
              padding: EdgeInsets.only(bottom: tokens.spacing.gap),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SelectableText(
                    syntax,
                    style: context.fushiType.bodyMedium.copyWith(
                      fontFamily: 'monospace',
                      color: colors.primary,
                    ),
                  ),
                  Text(
                    meaning,
                    style: context.fushiType.bodySmall.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

/// 一张卡的状态文字（暂停 / 搁置 / 新卡 / 学习中 / 今天到期 / N 天后）。
String srsBrowseCardStatus(SrsBrowseRow c) {
  if (c.isSuspended) return t.srs_status_suspended;
  if (c.isBuried) return t.srs_browse_status_buried;
  if (c.isNew) return t.srs_status_new;
  if (c.queue == SrsQueue.learning || c.queue == SrsQueue.relearning) {
    return t.srs_status_learning;
  }
  final int? days = c.dueInDays;
  if (days == null || days <= 0) return t.srs_status_due;
  return t.srs_status_review_in(n: days);
}

/// 卡片状态的标签色调：浏览页手机行把状态画成行首小标签（不再拼进副标题末尾被省略号吃掉）。
FushiTagTone srsBrowseCardStatusTone(SrsBrowseRow c) {
  if (c.isSuspended || c.isBuried) return FushiTagTone.neutral;
  if (c.isNew) return FushiTagTone.accent;
  if (c.queue == SrsQueue.learning || c.queue == SrsQueue.relearning) {
    return FushiTagTone.warning;
  }
  final int? days = c.dueInDays;
  if (days == null || days <= 0) return FushiTagTone.success;
  return FushiTagTone.neutral;
}

/// 旗标颜色（0 = 无）。与 Anki 的七色同序。
Color? srsFlagColor(int flag) => switch (flag) {
  1 => const Color(0xFFE53935),
  2 => const Color(0xFFFB8C00),
  3 => const Color(0xFF43A047),
  4 => const Color(0xFF1E88E5),
  5 => const Color(0xFFD81B60),
  6 => const Color(0xFF00ACC1),
  7 => const Color(0xFF8E24AA),
  _ => null,
};

/// 批量菜单：把 [actions] 列成一个选择框。
Future<SrsBrowseBatchAction?> pickSrsBrowseBatchAction(
  BuildContext context, {
  required List<SrsBrowseBatchAction> actions,
  required String title,
}) => showFushiChoiceDialog<SrsBrowseBatchAction>(
  context: context,
  title: title,
  icon: FushiIcons.checklist,
  options: <FushiChoiceOption<SrsBrowseBatchAction>>[
    for (final SrsBrowseBatchAction a in actions)
      FushiChoiceOption<SrsBrowseBatchAction>(
        value: a,
        label: srsBrowseBatchLabel(a),
      ),
  ],
);

/// 旗标选择（复用复习页的标签）。
Future<int?> pickSrsFlag(BuildContext context, {int? selected}) =>
    showFushiChoiceDialog<int>(
      context: context,
      title: t.srs_card_flag,
      icon: FushiIcons.flag,
      selected: selected,
      options: <FushiChoiceOption<int>>[
        for (int f = 0; f <= 7; f++)
          FushiChoiceOption<int>(value: f, label: srsFlagLabel(f)),
      ],
    );
