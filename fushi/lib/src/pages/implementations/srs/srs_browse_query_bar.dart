/// 浏览页的搜索积木条：输入框（打字 = 草稿，Enter 把草稿拆成积木）+ 一排积木（点开底部面板编辑，× 删除）
/// + 补全（牌组 / 标签 / 笔记类型 / 状态 / 常用属性 / 「写成语法」）。积木 ↔ 语法的转换在
/// [srs_browse_query.dart]，这里只画界面；查询串仍是唯一真相（页面持有积木 + 草稿，拼成查询交给内核）。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/srs/srs_browse_query.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 积木种类的文字。
String srsBrowseChipKindLabel(SrsBrowseChipKind kind) => switch (kind) {
  SrsBrowseChipKind.deck => t.srs_browse_chip_deck,
  SrsBrowseChipKind.state => t.srs_browse_chip_state,
  SrsBrowseChipKind.tag => t.srs_browse_chip_tag,
  SrsBrowseChipKind.noteType => t.srs_browse_chip_note_type,
  SrsBrowseChipKind.property => t.srs_browse_chip_property,
  SrsBrowseChipKind.source => t.srs_browse_chip_source,
  SrsBrowseChipKind.text => t.srs_browse_chip_text,
  SrsBrowseChipKind.syntax => t.srs_browse_chip_syntax,
};

/// 积木种类的图标。
IconData srsBrowseChipKindIcon(SrsBrowseChipKind kind) => switch (kind) {
  SrsBrowseChipKind.deck => FushiIcons.folder,
  SrsBrowseChipKind.state => FushiIcons.schedule,
  SrsBrowseChipKind.tag => FushiIcons.tag,
  SrsBrowseChipKind.noteType => FushiIcons.ankiCard,
  SrsBrowseChipKind.property => FushiIcons.filterList,
  SrsBrowseChipKind.source => FushiIcons.books,
  SrsBrowseChipKind.text => FushiIcons.search,
  SrsBrowseChipKind.syntax => FushiIcons.code,
};

/// `is:` 取值的人话（不认识的原样）。
String srsBrowseStateLabel(String value) => switch (value) {
  'due' => t.srs_browse_quick_due,
  'new' => t.srs_status_new,
  'learn' => t.srs_status_learning,
  'review' => t.srs_browse_state_review,
  'suspended' => t.srs_status_suspended,
  'buried' => t.srs_browse_status_buried,
  _ => 'is:$value',
};

/// 积木上显示的文字：多值用「、」连，状态换成人话，属性 / 语法原样。
String srsBrowseChipLabel(SrsBrowseChip chip) {
  final String body = switch (chip.kind) {
    SrsBrowseChipKind.state => chip.values.map(srsBrowseStateLabel).join(', '),
    SrsBrowseChipKind.syntax => chip.raw,
    SrsBrowseChipKind.property ||
    SrsBrowseChipKind.text => srsBrowseUnescape(chip.values.first),
    _ => chip.values.map(srsBrowseUnescape).join(', '),
  };
  return chip.negated ? '−$body' : body;
}

/// 编辑面板的一个可勾选项（取值是查询原文，[label] 显示，[trailing] 是右侧的小数字）。
class SrsBrowseChipOption {
  const SrsBrowseChipOption({
    required this.value,
    required this.label,
    this.trailing,
    this.depth = 0,
  });

  final String value;
  final String label;
  final String? trailing;

  /// 缩进层级（子牌组）。
  final int depth;
}

/// 编辑面板的结果：[removed] = 删除这块积木；否则 [chip] 是改好的积木。
typedef SrsBrowseChipEdit = ({SrsBrowseChip? chip, bool removed});

/// 积木条（输入框 + 积木 + 补全 + 错误）。
class SrsBrowseQueryBar extends StatelessWidget {
  const SrsBrowseQueryBar({
    super.key,
    required this.chips,
    required this.draft,
    required this.focusNode,
    required this.fieldScope,
    required this.suggestions,
    required this.error,
    required this.onDraftChanged,
    required this.onDraftSubmitted,
    required this.onChipTap,
    required this.onChipRemove,
    required this.onRemoveLast,
    required this.onSuggestion,
    required this.onPickField,
    required this.onHelp,
    this.onSaveView,
  });

  final List<SrsBrowseChip> chips;
  final TextEditingController draft;
  final FocusNode focusNode;

  /// 「搜索范围」：null = 草稿按语法解析；否则是字段名，草稿是关键字。
  final String? fieldScope;
  final List<SrsBrowseSuggestion> suggestions;
  final String? error;
  final ValueChanged<String> onDraftChanged;
  final ValueChanged<String> onDraftSubmitted;
  final void Function(int index) onChipTap;
  final void Function(int index) onChipRemove;

  /// 草稿为空时按退格：删掉最后一块积木。
  final VoidCallback onRemoveLast;
  final ValueChanged<SrsBrowseSuggestion> onSuggestion;
  final VoidCallback onPickField;
  final VoidCallback onHelp;

  /// 「存为视图」；null = 当前没有条件可存。
  final VoidCallback? onSaveView;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.backspace &&
        draft.text.isEmpty &&
        draft.selection.baseOffset <= 0 &&
        chips.isNotEmpty) {
      onRemoveLast();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String? scope = fieldScope;
    final bool apple = isGlassDesign(context);
    final Color errorColor = apple
        ? appleColorsOf(context).destructive
        : Theme.of(context).colorScheme.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: tokens.spacing.gap,
      children: <Widget>[
        Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _onKey,
          child: FushiSearchField(
            key: const ValueKey<String>('srs-browse-search'),
            controller: draft,
            focusNode: focusNode,
            hintText: scope == null
                ? t.srs_browse_search_syntax_hint
                : t.srs_browse_search_keyword_hint(field: scope),
            onChanged: onDraftChanged,
            onSubmitted: onDraftSubmitted,
            onClear: () => onDraftChanged(''),
            trailing: <Widget>[
              FushiIconButton(
                key: const ValueKey<String>('srs-browse-field'),
                icon: FushiIcons.filterList,
                selected: scope != null,
                tooltip: scope ?? t.srs_browse_search_field_label,
                onTap: onPickField,
              ),
              if (onSaveView != null)
                FushiIconButton(
                  key: const ValueKey<String>('srs-browse-save-view'),
                  icon: FushiIcons.bookmarkAdd,
                  tooltip: t.srs_browse_view_save,
                  onTap: onSaveView,
                ),
              FushiIconButton(
                key: const ValueKey<String>('srs-browse-help'),
                icon: FushiIcons.help,
                tooltip: t.srs_browse_search_help,
                onTap: onHelp,
              ),
            ],
          ),
        ),
        if (chips.isNotEmpty)
          Wrap(
            key: const ValueKey<String>('srs-browse-chips'),
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              for (int i = 0; i < chips.length; i++)
                FushiStaggeredEntrance(
                  index: i,
                  child: FushiPressScale(
                    child: FushiInputChip(
                      key: ValueKey<String>('srs-browse-chip-$i'),
                      avatar: FushiIcon(
                        srsBrowseChipKindIcon(chips[i].kind),
                        size: 18,
                      ),
                      tooltip: chips[i].raw,
                      label: Text(
                        srsBrowseChipLabel(chips[i]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onPressed: () => onChipTap(i),
                      onDeleted: () => onChipRemove(i),
                      deleteButtonTooltipMessage: t.srs_browse_chip_remove,
                    ),
                  ),
                ),
            ],
          ),
        AnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.standard,
          alignment: Alignment.topCenter,
          child: suggestions.isEmpty
              ? const SizedBox(width: double.infinity)
              : _Suggestions(suggestions: suggestions, onPick: onSuggestion),
        ),
        if (error != null)
          Text(
            t.srs_browse_search_error(reason: error!),
            key: const ValueKey<String>('srs-browse-search-error'),
            style: context.fushiType.bodySmall.copyWith(color: errorColor),
          ),
      ],
    );
  }
}

class _Suggestions extends StatelessWidget {
  const _Suggestions({required this.suggestions, required this.onPick});

  final List<SrsBrowseSuggestion> suggestions;
  final ValueChanged<SrsBrowseSuggestion> onPick;

  @override
  Widget build(BuildContext context) {
    return FushiCard(
      key: const ValueKey<String>('srs-browse-suggestions'),
      padding: EdgeInsets.zero,
      pressScale: false,
      child: FushiEntranceScope(
        replayKey: suggestions.length,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < suggestions.length; i++)
              FushiStaggeredEntrance(
                index: i,
                child: FushiListItem(
                  key: ValueKey<String>('srs-browse-suggestion-$i'),
                  density: FushiListDensity.compact,
                  leading: FushiIcon(_icon(suggestions[i].kind), size: 20),
                  title: Text(
                    suggestions[i].label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(_caption(suggestions[i])),
                  onTap: () => onPick(suggestions[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static IconData _icon(SrsBrowseSuggestionKind k) => switch (k) {
    SrsBrowseSuggestionKind.deck => FushiIcons.folder,
    SrsBrowseSuggestionKind.tag => FushiIcons.tag,
    SrsBrowseSuggestionKind.noteType => FushiIcons.ankiCard,
    SrsBrowseSuggestionKind.state => FushiIcons.schedule,
    SrsBrowseSuggestionKind.property => FushiIcons.filterList,
    SrsBrowseSuggestionKind.syntax => FushiIcons.code,
  };

  static String _caption(SrsBrowseSuggestion s) => switch (s.kind) {
    SrsBrowseSuggestionKind.deck => t.srs_browse_chip_deck,
    SrsBrowseSuggestionKind.tag => t.srs_browse_chip_tag,
    SrsBrowseSuggestionKind.noteType => t.srs_browse_chip_note_type,
    SrsBrowseSuggestionKind.state => srsBrowseStateLabel(s.chip.values.first),
    SrsBrowseSuggestionKind.property => t.srs_browse_chip_property,
    SrsBrowseSuggestionKind.syntax => t.srs_browse_suggest_syntax,
  };
}

/// 点积木弹的编辑面板：包含 / 排除 + 勾选项（可多选种类）或原文（属性 / 文本 / 语法），底部「应用 · 将筛出 N 张」
/// 实时计数（[count] 给出把这块积木换成候选后整条查询的命中数；-1 = 语法不对）。返回 null = 取消。
Future<SrsBrowseChipEdit?> showSrsBrowseChipEditor(
  BuildContext context, {
  required SrsBrowseChip chip,
  required List<SrsBrowseChipOption> options,
  required Future<int> Function(SrsBrowseChip candidate) count,
}) => adaptiveModalSheet<SrsBrowseChipEdit>(
  context: context,
  builder: (BuildContext context) =>
      _SrsChipEditor(chip: chip, options: options, count: count),
);

class _SrsChipEditor extends StatefulWidget {
  const _SrsChipEditor({
    required this.chip,
    required this.options,
    required this.count,
  });

  final SrsBrowseChip chip;
  final List<SrsBrowseChipOption> options;
  final Future<int> Function(SrsBrowseChip candidate) count;

  @override
  State<_SrsChipEditor> createState() => _SrsChipEditorState();
}

class _SrsChipEditorState extends State<_SrsChipEditor> {
  late bool _negated = widget.chip.negated;
  late final List<String> _values = <String>[...widget.chip.values];
  late final TextEditingController _raw = TextEditingController(
    text: widget.chip.kind == SrsBrowseChipKind.syntax
        ? widget.chip.raw
        : (widget.chip.values.isEmpty ? '' : widget.chip.values.first),
  );
  int? _count;
  int _seq = 0;
  Timer? _debounce;

  bool get _multi => kSrsBrowseChipKeys.containsKey(widget.chip.kind);

  bool get _negatable => widget.chip.kind != SrsBrowseChipKind.syntax;

  @override
  void initState() {
    super.initState();
    _recount();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _raw.dispose();
    super.dispose();
  }

  SrsBrowseChip get _candidate {
    if (widget.chip.kind == SrsBrowseChipKind.syntax) {
      return SrsBrowseChip.syntax(_raw.text.trim());
    }
    if (_multi) {
      return widget.chip.copyWith(
        values: List<String>.of(_values),
        negated: _negated,
      );
    }
    return widget.chip.copyWith(
      values: <String>[_raw.text.trim()],
      negated: _negated,
    );
  }

  void _recount() {
    final int seq = ++_seq;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () async {
      final int n;
      try {
        n = await widget.count(_candidate);
      } catch (e, stack) {
        ErrorLogService.instance.log('SrsBrowse.chipCount', e, stack);
        return;
      }
      if (mounted && seq == _seq) setState(() => _count = n);
    });
  }

  void _toggle(String value) {
    setState(() {
      if (!_values.remove(value)) _values.add(value);
      _count = null;
    });
    _recount();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<SrsBrowseChipOption> options = <SrsBrowseChipOption>[
      ...widget.options,
      // 积木里有、选项里没有的取值（手写的通配 / 已删的牌组）也列出来，免得一应用就丢。
      for (final String v in widget.chip.values)
        if (_multi &&
            !widget.options.any((SrsBrowseChipOption o) => o.value == v))
          SrsBrowseChipOption(value: v, label: srsBrowseUnescape(v)),
    ];
    final int? n = _count;
    final bool canApply = _multi
        ? _values.isNotEmpty
        : _raw.text.trim().isNotEmpty;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          tokens.spacing.gap,
          tokens.spacing.page,
          tokens.spacing.page + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          key: const ValueKey<String>('srs-browse-chip-editor'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: tokens.spacing.gap,
          children: <Widget>[
            Row(
              spacing: tokens.spacing.gap,
              children: <Widget>[
                FushiIcon(srsBrowseChipKindIcon(widget.chip.kind)),
                Expanded(
                  child: Text(
                    srsBrowseChipKindLabel(widget.chip.kind),
                    style: context.fushiType.titleMediumEmphasized,
                  ),
                ),
                FushiIconButton(
                  key: const ValueKey<String>('srs-browse-chip-remove'),
                  icon: FushiIcons.delete,
                  tooltip: t.srs_browse_chip_remove,
                  onTap: () => Navigator.of(
                    context,
                  ).pop<SrsBrowseChipEdit>((chip: null, removed: true)),
                ),
              ],
            ),
            if (_negatable)
              adaptiveSegmentedButton<bool>(
                context: context,
                segments: <ButtonSegment<bool>>[
                  ButtonSegment<bool>(
                    value: false,
                    label: Text(t.srs_browse_chip_include),
                  ),
                  ButtonSegment<bool>(
                    value: true,
                    label: Text(t.srs_browse_chip_exclude),
                  ),
                ],
                selected: <bool>{_negated},
                onSelectionChanged: (Set<bool> v) {
                  setState(() {
                    _negated = v.first;
                    _count = null;
                  });
                  _recount();
                },
              ),
            if (_multi)
              Flexible(
                child: FushiEntranceScope(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: options.length,
                    itemBuilder: fushiStaggeredItemBuilder((
                      BuildContext context,
                      int i,
                    ) {
                      final SrsBrowseChipOption o = options[i];
                      final bool on = _values.contains(o.value);
                      return FushiListItem(
                        key: ValueKey<String>('srs-browse-chip-option-$i'),
                        density: FushiListDensity.compact,
                        selected: on,
                        padding: EdgeInsetsDirectional.only(
                          start: 12.0 + o.depth * 16,
                          end: 12,
                        ),
                        leading: FushiCheckbox(
                          value: on,
                          onChanged: (_) => _toggle(o.value),
                        ),
                        title: Text(o.label),
                        trailing: o.trailing == null ? null : Text(o.trailing!),
                        onTap: () => _toggle(o.value),
                      );
                    }),
                  ),
                ),
              )
            else
              FushiTextField(
                key: const ValueKey<String>('srs-browse-chip-raw'),
                controller: _raw,
                autofocus: true,
                helperText: t.srs_browse_chip_edit_hint,
                onChanged: (_) {
                  setState(() => _count = null);
                  _recount();
                },
                onSubmitted: (_) {
                  if (canApply) _apply(context);
                },
              ),
            FushiFilledButton.icon(
              key: const ValueKey<String>('srs-browse-chip-apply'),
              onPressed: canApply ? () => _apply(context) : null,
              icon: const FushiIcon(FushiIcons.filter),
              label: Text(
                n == null || n < 0
                    ? t.srs_browse_chip_apply
                    : t.srs_browse_chip_apply_count(n: n),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _apply(BuildContext context) => Navigator.of(
    context,
  ).pop<SrsBrowseChipEdit>((chip: _candidate, removed: false));
}
