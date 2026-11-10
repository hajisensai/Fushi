import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_anki/fushi_anki.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiListItem, FushiListDensity;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';

/// 反馈 nWWjBp3Clo：覆写已有卡时「只改哪些字段」的一次勾选结果。
///
/// [selection] 为 `null` = 全部字段（[AnkiSettings.overwriteFieldsFor] 同一口径）；
/// [rejectedEmpty] = 这次操作会让一个字段都不勾，已被拒绝（选择原样不变）。
typedef OverwriteFieldToggle = ({Set<String>? selection, bool rejectedEmpty});

/// 存下来的选择对照这张卡**实际有的**字段：笔记类型改过字段名后，旧名字不再算数
/// （与后端 `fieldsForOverwrite` 只点名卡上有的字段同口径）。`null`（全部字段）原样返回。
Set<String>? effectiveOverwriteSelection({
  required List<String> allFields,
  required Set<String>? stored,
}) {
  if (stored == null) return null;
  return <String>{
    for (final String f in allFields)
      if (stored.contains(f)) f,
  };
}

/// 勾 / 取消勾一个字段后的选择（纯函数）。
///
/// - 从「全部字段」取消勾一个 → 其余字段；
/// - 勾满全部字段 → 收回 `null`（全部字段，不在设置里留一份等价清单）；
/// - 会变成一个都不勾 → 拒绝（覆写按钮本身就是「要写」，空选择没有意义）。
OverwriteFieldToggle toggleOverwriteField({
  required List<String> allFields,
  required Set<String>? selection,
  required String field,
  required bool checked,
}) {
  final Set<String> next = <String>{...(selection ?? allFields.toSet())};
  if (checked) {
    next.add(field);
  } else {
    next.remove(field);
  }
  if (next.isEmpty) return (selection: selection, rejectedEmpty: true);
  if (allFields.every(next.contains)) {
    return (selection: null, rejectedEmpty: false);
  }
  return (selection: next, rejectedEmpty: false);
}

/// 覆写对话框里的「覆写哪些字段」行：收起时一行摘要，展开后逐字段勾选，改动当场写进
/// 设置（按笔记类型记住，[AnkiSettings.withOverwriteFields]）——对话框里的覆写按钮、
/// 查词弹窗里直接点 ✓ 覆写都读同一份选择，由各后端的 `updateMinedNote` 统一执行。
///
/// [noteId] 是用来取字段清单与笔记类型的那张已有卡。后端读不到字段（远端制卡等不
/// 支持覆写的后端）时整行不出。
class AnkiOverwriteFieldsSelector extends StatefulWidget {
  const AnkiOverwriteFieldsSelector({
    super.key,
    required this.repo,
    required this.noteId,
    this.enabled = true,
  });

  final BaseAnkiRepository repo;
  final int noteId;
  final bool enabled;

  @override
  State<AnkiOverwriteFieldsSelector> createState() =>
      _AnkiOverwriteFieldsSelectorState();
}

class _AnkiOverwriteFieldsSelectorState
    extends State<AnkiOverwriteFieldsSelector> {
  bool _loading = true;
  String? _noteTypeName;
  List<String> _fields = const <String>[];
  Set<String>? _selection;
  bool _expanded = false;
  bool _rejectedEmpty = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    Map<String, String>? fields;
    String? noteTypeName;
    AnkiSettings? settings;
    try {
      fields = await widget.repo.noteFields(widget.noteId);
      noteTypeName = await widget.repo.overwriteNoteTypeName(widget.noteId);
      settings = await widget.repo.loadSettings();
    } catch (e, stack) {
      // 读不到字段（主机掉线 / Anki 没开）：这一行不出，覆写照旧按已存的选择执行。
      ErrorLogService.instance.log(
        'AnkiOverwriteFieldsSelector.load',
        e,
        stack,
      );
      fields = null;
    }
    if (!mounted) return;
    final List<String> names = fields?.keys.toList() ?? const <String>[];
    setState(() {
      _loading = false;
      _noteTypeName = noteTypeName;
      _fields = names;
      _selection = effectiveOverwriteSelection(
        allFields: names,
        stored: settings?.overwriteFieldsFor(noteTypeName),
      );
    });
  }

  Future<void> _apply(OverwriteFieldToggle result) async {
    final String? name = _noteTypeName;
    if (name == null) return;
    final Set<String>? selection = result.selection;
    setState(() {
      _rejectedEmpty = result.rejectedEmpty;
      if (!result.rejectedEmpty) _selection = selection;
    });
    if (result.rejectedEmpty) return;
    try {
      await widget.repo.updateSettings(
        (AnkiSettings s) => s.withOverwriteFields(name, selection),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'AnkiOverwriteFieldsSelector.save',
        e,
        stack,
      );
    }
  }

  void _toggle(String field, bool checked) => unawaited(
    _apply(
      toggleOverwriteField(
        allFields: _fields,
        selection: _selection,
        field: field,
        checked: checked,
      ),
    ),
  );

  void _selectAll() =>
      unawaited(_apply((selection: null, rejectedEmpty: false)));

  String _summary() {
    final Set<String>? selection = _selection;
    if (selection == null) return t.anki_overwrite_fields_all;
    if (selection.isEmpty) return t.anki_overwrite_fields_none_selected;
    return _fields.where(selection.contains).join(', ');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _noteTypeName == null || _fields.isEmpty) {
      return const SizedBox.shrink();
    }
    final ThemeData theme = Theme.of(context);
    final bool enabled = widget.enabled;
    final Set<String>? selection = _selection;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FushiListItem(
          key: const ValueKey<String>('anki-overwrite-fields-toggle'),
          leading: const FushiListLeadingIcon(
            FushiIcons.checklist,
            shape: FushiLeadingShape.square,
          ),
          title: Text(t.anki_overwrite_fields),
          subtitle: Text(
            _summary(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: AnimatedRotation(
            turns: _expanded ? 0.5 : 0,
            duration: fushiMotionDuration(context, FushiMotion.short),
            curve: FushiMotion.standard,
            child: const FushiIcon(FushiIcons.expandMore),
          ),
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        FushiAnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          curve: FushiMotion.standard,
          alignment: Alignment.topCenter,
          child: !_expanded
              ? const SizedBox(width: double.infinity)
              : ConstrainedBox(
                  // 对话框高度有界、命中卡列表也要留位置：字段多（Lapis 二十来个）时
                  // 在这块里自己滚。
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: FushiEntranceScope(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                            child: Text(
                              _rejectedEmpty
                                  ? t.anki_overwrite_fields_none_selected
                                  : t.anki_overwrite_fields_hint,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: _rejectedEmpty
                                    ? theme.colorScheme.error
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          FushiStaggeredEntrance(
                            index: 0,
                            child: _FieldRow(
                              key: const ValueKey<String>(
                                'anki-overwrite-fields-all',
                              ),
                              label: t.anki_overwrite_fields_all,
                              checked: selection == null,
                              onChanged: !enabled
                                  ? null
                                  : (bool checked) {
                                      if (checked) _selectAll();
                                    },
                            ),
                          ),
                          for (int i = 0; i < _fields.length; i++)
                            FushiStaggeredEntrance(
                              index: i + 1,
                              child: _FieldRow(
                                key: ValueKey<String>(
                                  'anki-overwrite-field-${_fields[i]}',
                                ),
                                label: _fields[i],
                                checked:
                                    selection == null ||
                                    selection.contains(_fields[i]),
                                onChanged: !enabled
                                    ? null
                                    : (bool checked) =>
                                          _toggle(_fields[i], checked),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    super.key,
    required this.label,
    required this.checked,
    required this.onChanged,
  });

  final String label;
  final bool checked;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final ValueChanged<bool>? onChanged = this.onChanged;
    return FushiListItem(
      density: FushiListDensity.compact,
      leading: FushiCheckbox.adaptive(
        value: checked,
        onChanged: onChanged == null
            ? null
            : (bool? value) => onChanged(value ?? false),
        semanticLabel: label,
      ),
      title: Text(label),
      onTap: onChanged == null ? null : () => onChanged(!checked),
    );
  }
}
