/// 浏览页的对话框与小件：搜索帮助、排序选择、批量菜单、行状态文字、旗标选择。
library;

import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_engine/srs/srs_note_batch_edit.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 批量菜单项。
enum SrsBrowseBatchAction {
  toggleSuspend,
  toggleBury,
  flag,
  move,
  addTags,
  removeTags,
  setCardType,
  setField,
  findReplace,
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
  SrsBrowseBatchAction.setCardType => t.srs_browse_card_type_set,
  SrsBrowseBatchAction.setField => t.srs_browse_field_set,
  SrsBrowseBatchAction.findReplace => t.srs_browse_find_replace,
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
  SrsBrowseSortColumn.retention => t.srs_browse_sort_retention,
  SrsBrowseSortColumn.reps => t.srs_browse_sort_reps,
  SrsBrowseSortColumn.lapses => t.srs_browse_sort_lapses,
  SrsBrowseSortColumn.deck => t.srs_key_deck,
  SrsBrowseSortColumn.noteType => t.srs_note_type,
  SrsBrowseSortColumn.source => t.srs_browse_view_sources,
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
  String? allLabel,
}) => showFushiChoiceDialog<String>(
  context: context,
  title: title,
  icon: FushiIcons.filterList,
  selected: selected ?? (allowAll ? kSrsBrowseAllFields : null),
  options: <FushiChoiceOption<String>>[
    if (allowAll)
      FushiChoiceOption<String>(
        value: kSrsBrowseAllFields,
        label: allLabel ?? t.srs_browse_search_field_all,
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
  ('prop:r<0.7   prop:r>=0.9', t.srs_browse_help_retention),
  ('added:7   edited:7', t.srs_browse_help_days),
  ('rated:1   rated:7:1', t.srs_browse_help_rated),
  ('has:audio   -has:image', t.srs_browse_help_has),
  ('is:emptyfield', t.srs_browse_help_emptyfield),
  ('is:dupe', t.srs_browse_help_dupe),
  ('src:none   src:book   src:video', t.srs_browse_help_src),
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

/// 卡型的文字。
String srsCardTypeLabel(SrsCardType type) => switch (type) {
  SrsCardType.word => t.srs_browse_card_type_word,
  SrsCardType.sentence => t.srs_browse_card_type_sentence,
  SrsCardType.wordAndSentence => t.srs_browse_card_type_word_and_sentence,
  SrsCardType.click => t.srs_browse_card_type_click,
  SrsCardType.audio => t.srs_browse_card_type_audio,
};

/// 批量设卡型：选一个卡型。返回 null = 取消。
Future<SrsCardType?> pickSrsCardType(BuildContext context) =>
    showFushiChoiceDialog<SrsCardType>(
      context: context,
      title: t.srs_browse_card_type_set,
      icon: FushiIcons.viewAgenda,
      options: <FushiChoiceOption<SrsCardType>>[
        for (final SrsCardType type in SrsCardType.values)
          FushiChoiceOption<SrsCardType>(
            value: type,
            label: srsCardTypeLabel(type),
          ),
      ],
    );

/// 空计划（没有要写的字段）给用户的提示：有笔记因类型没有所需字段被跳过就报跳过条数（不然用户
/// 会以为数据已经是目标值），只有确实都已是目标值时才是「没有改动」。
({String message, bool warning}) srsNoteFieldPlanEmptyNotice(
  SrsNoteFieldPlan plan,
) => plan.skipped.isNotEmpty
    ? (
        message: t.srs_browse_field_edit_skipped(n: plan.skipped.length),
        warning: true,
      )
    : (message: t.srs_browse_nothing_changed, warning: false);

/// 批量改字段前的确认：「将修改 N 条笔记」，有跳过的再说明一句。
Future<bool> confirmSrsNoteFieldPlan(
  BuildContext context, {
  required String title,
  required SrsNoteFieldPlan plan,
}) => showFushiConfirmDialog(
  context: context,
  title: title,
  message: <String>[
    t.srs_browse_field_edit_confirm(n: plan.noteCount),
    if (plan.skipped.isNotEmpty)
      t.srs_browse_field_edit_skipped(n: plan.skipped.length),
  ].join('\n'),
  confirmLabel: t.srs_browse_field_edit_apply,
  cancelLabel: t.cancel,
  icon: FushiIcons.edit,
);

/// 查找替换的参数（[fieldName] 为 null = 全部字段）。
class SrsFindReplaceRequest {
  const SrsFindReplaceRequest({
    required this.fieldName,
    required this.find,
    required this.replace,
    required this.regex,
    required this.caseSensitive,
  });

  final String? fieldName;
  final String find;
  final String replace;
  final bool regex;
  final bool caseSensitive;
}

/// 查找替换对话框：查找 / 替换为 / 字段 / 正则 / 区分大小写。确认时调 [onSubmit]
/// （算计划）；它抛 [FormatException]（非法正则）就在查找框下就地报错、对话框不关。
/// 返回 [onSubmit] 的结果，null = 取消。
Future<T?> showSrsFindReplaceDialog<T extends Object>(
  BuildContext context, {
  required List<String> fieldNames,
  required Future<T> Function(SrsFindReplaceRequest request) onSubmit,
}) => showAppDialog<T>(
  context: context,
  builder: (_) =>
      SrsFindReplaceDialog<T>(fieldNames: fieldNames, onSubmit: onSubmit),
);

/// [showSrsFindReplaceDialog] 的对话框本体。
class SrsFindReplaceDialog<T extends Object> extends StatefulWidget {
  const SrsFindReplaceDialog({
    super.key,
    required this.fieldNames,
    required this.onSubmit,
  });

  final List<String> fieldNames;
  final Future<T> Function(SrsFindReplaceRequest request) onSubmit;

  @override
  State<SrsFindReplaceDialog<T>> createState() =>
      _SrsFindReplaceDialogState<T>();
}

class _SrsFindReplaceDialogState<T extends Object>
    extends State<SrsFindReplaceDialog<T>> {
  final TextEditingController _find = TextEditingController();
  final TextEditingController _replace = TextEditingController();
  String? _field;
  bool _regex = false;
  bool _caseSensitive = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _find.addListener(_onFindChanged);
  }

  void _onFindChanged() => setState(() => _error = null);

  @override
  void dispose() {
    _find.removeListener(_onFindChanged);
    _find.dispose();
    _replace.dispose();
    super.dispose();
  }

  bool get _canSubmit => !_busy && _find.text.isNotEmpty;

  Future<void> _pickField() async {
    final String? picked = await pickSrsBrowseField(
      context,
      fieldNames: widget.fieldNames,
      selected: _field,
      title: t.srs_browse_find_replace_field_label,
      allLabel: t.srs_browse_find_replace_field_all,
    );
    if (picked == null || !mounted) return;
    setState(() => _field = picked == kSrsBrowseAllFields ? null : picked);
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final T result = await widget.onSubmit(
        SrsFindReplaceRequest(
          fieldName: _field,
          find: _find.text,
          replace: _replace.text,
          regex: _regex,
          caseSensitive: _caseSensitive,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = t.srs_browse_find_replace_regex_invalid(reason: e.message);
      });
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsBrowse.findReplace.plan', e, stack);
      FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiAlertDialog(
      icon: const FushiDialogHeroIcon(icon: FushiIcons.search),
      title: Text(t.srs_browse_find_replace),
      scrollable: true,
      content: FushiAnimatedSize(
        duration: fushiMotionDuration(context, FushiMotion.short),
        curve: FushiMotion.standard,
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: tokens.spacing.gap,
          children: <Widget>[
            FushiTextField(
              key: const ValueKey<String>('srs-browse-find-replace-find'),
              controller: _find,
              autofocus: true,
              labelText: t.srs_browse_find_replace_find,
              errorText: _error,
              onSubmitted: (_) => _submit(),
            ),
            FushiTextField(
              key: const ValueKey<String>(
                'srs-browse-find-replace-replacement',
              ),
              controller: _replace,
              labelText: t.srs_browse_find_replace_replacement,
              helperText: _regex
                  ? t.srs_browse_find_replace_regex_hint(syntax: r'$1, ${name}')
                  : null,
              onSubmitted: (_) => _submit(),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FushiActionChip(
                key: const ValueKey<String>('srs-browse-find-replace-field'),
                icon: FushiIcons.filterList,
                label: _field ?? t.srs_browse_find_replace_field_all,
                onPressed: () => _pickField(),
              ),
            ),
            FushiSwitchListTile(
              key: const ValueKey<String>('srs-browse-find-replace-regex'),
              contentPadding: EdgeInsets.zero,
              title: Text(t.srs_browse_find_replace_regex),
              value: _regex,
              onChanged: (bool v) => setState(() {
                _regex = v;
                _error = null;
              }),
            ),
            FushiSwitchListTile(
              key: const ValueKey<String>('srs-browse-find-replace-case'),
              contentPadding: EdgeInsets.zero,
              title: Text(t.srs_browse_find_replace_case_sensitive),
              value: _caseSensitive,
              onChanged: (bool v) => setState(() => _caseSensitive = v),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('srs-browse-find-replace-ok'),
          label: t.srs_browse_find_replace,
          kind: FushiDialogActionKind.primary,
          onPressed: _canSubmit ? () => _submit() : null,
        ),
      ],
    );
  }
}
