import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/utils.dart';

/// Mihon 在线来源的偏好编辑弹窗。
///
/// 文本偏好会保留为草稿，直到用户按下明确的“保存”按钮；开关、下拉和多选仍沿用
/// Mihon 的即时保存契约。此 widget 公开是为了用真实 manager/runtime 做交互回归测试。
class MihonPreferencesDialog extends StatefulWidget {
  const MihonPreferencesDialog({
    super.key,
    required this.manager,
    required this.source,
  });

  final MihonManager manager;
  final MangaOnlineSourceRow source;

  @override
  State<MihonPreferencesDialog> createState() => _MihonPreferencesDialogState();
}

class _MihonPreferencesDialogState extends State<MihonPreferencesDialog> {
  List<MihonPreference>? _preferences;
  Object? _error;
  String? _savingKey;
  bool _savingAll = false;
  final Map<String, String> _textDrafts = <String, String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final List<MihonPreference> preferences = await widget.manager
          .getPreferences(widget.source);
      if (mounted) setState(() => _preferences = preferences);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _save(MihonPreference original, Object? value) async {
    setState(() => _savingKey = original.key);
    try {
      final List<MihonPreference> preferences = await _persistPreference(
        original,
        value,
      );
      if (mounted) {
        setState(() {
          _preferences = preferences;
          if (_textDrafts[original.key] == value) {
            _textDrafts.remove(original.key);
          }
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _savingKey = null);
    }
  }

  Future<List<MihonPreference>> _persistPreference(
    MihonPreference original,
    Object? value,
  ) {
    final MihonPreference changed = MihonPreference(
      key: original.key,
      kind: original.kind,
      title: original.title,
      summary: original.summary,
      value: value,
      entries: original.entries,
      entryValues: original.entryValues,
    );
    return widget.manager.setPreference(widget.source, changed);
  }

  Future<void> _saveAllAndClose() async {
    final List<MihonPreference>? preferences = _preferences;
    if (preferences == null || _savingKey != null || _savingAll) return;
    setState(() => _savingAll = true);
    try {
      List<MihonPreference> updated = preferences;
      for (final MihonPreference preference in preferences) {
        if (preference.kind != MihonPreferenceKind.text) continue;
        final String? draft = _textDrafts[preference.key];
        if (draft == null || draft == (preference.value?.toString() ?? '')) {
          continue;
        }
        updated = await _persistPreference(preference, draft);
      }
      if (!mounted) return;
      setState(() {
        _preferences = updated;
        _textDrafts.clear();
      });
      Navigator.pop(context);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _savingAll = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<MihonPreference>? preferences = _preferences;
    return AlertDialog(
      title: Text('${widget.source.name} · ${t.mihon_source_preferences}'),
      content: SizedBox(
        width: 480,
        child: _error != null
            ? Text('$_error')
            : preferences == null
            ? Center(child: adaptiveIndicator(context: context))
            : preferences.isEmpty
            ? Text(t.mihon_source_no_results)
            : ListView(
                shrinkWrap: true,
                children: <Widget>[
                  for (final MihonPreference preference in preferences)
                    _buildPreference(preference),
                ],
              ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _savingAll ? null : () => Navigator.pop(context),
          child: Text(t.dialog_close),
        ),
        FilledButton(
          onPressed:
              preferences == null ||
                  _error != null ||
                  _savingKey != null ||
                  _savingAll
              ? null
              : () => unawaited(_saveAllAndClose()),
          child: Text(t.dialog_save),
        ),
      ],
    );
  }

  Widget _buildPreference(MihonPreference preference) {
    final bool busy = _savingAll || _savingKey == preference.key;
    return switch (preference.kind) {
      MihonPreferenceKind.checkBox ||
      MihonPreferenceKind.switchControl => SwitchListTile.adaptive(
        title: Text(preference.title),
        subtitle: preference.summary.isEmpty ? null : Text(preference.summary),
        value: preference.value == true,
        onChanged: busy
            ? null
            : (bool value) => unawaited(_save(preference, value)),
      ),
      MihonPreferenceKind.text => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: TextFormField(
          key: ValueKey<String>('${preference.key}:${preference.value}'),
          initialValue: preference.value?.toString() ?? '',
          enabled: !busy,
          decoration: InputDecoration(
            labelText: preference.title,
            helperText: preference.summary.isEmpty ? null : preference.summary,
          ),
          onChanged: (String value) => _textDrafts[preference.key] = value,
          onFieldSubmitted: (String value) =>
              unawaited(_save(preference, value)),
        ),
      ),
      MihonPreferenceKind.list => DropdownButtonFormField<int>(
        value: (preference.value as int? ?? 0).clamp(
          0,
          preference.entries.length - 1,
        ),
        decoration: InputDecoration(
          labelText: preference.title,
          helperText: preference.summary.isEmpty ? null : preference.summary,
        ),
        items: <DropdownMenuItem<int>>[
          for (int index = 0; index < preference.entries.length; index++)
            DropdownMenuItem<int>(
              value: index,
              child: Text(preference.entries[index]),
            ),
        ],
        onChanged: busy
            ? null
            : (int? value) => unawaited(_save(preference, value ?? 0)),
      ),
      MihonPreferenceKind.multiSelect => ExpansionTile(
        title: Text(preference.title),
        subtitle: preference.summary.isEmpty ? null : Text(preference.summary),
        children: <Widget>[
          for (int index = 0; index < preference.entries.length; index++)
            _MihonMultiSelectRow(
              label: preference.entries[index],
              selected:
                  (preference.value as List<Object?>? ?? const <Object?>[])
                      .map((Object? value) => value.toString())
                      .contains(preference.entryValues[index]),
              onChanged: busy
                  ? null
                  : (bool? selected) {
                      final Set<String> values =
                          (preference.value as List<Object?>? ??
                                  const <Object?>[])
                              .map((Object? value) => value.toString())
                              .toSet();
                      if (selected == true) {
                        values.add(preference.entryValues[index]);
                      } else {
                        values.remove(preference.entryValues[index]);
                      }
                      unawaited(_save(preference, values.toList()));
                    },
            ),
        ],
      ),
      MihonPreferenceKind.unsupported => FushiListItem(
        leading: const Icon(Icons.warning_amber_outlined),
        title: Text(preference.title),
        subtitle: Text(t.mihon_extension_incompatible),
      ),
    };
  }
}

/// 多选偏好的一行。
///
/// 框架的 `CheckboxListTile` 是被 MD3 守卫禁用的本地 chrome；共享的
/// [FushiListItem] 没有内建复选语义，所以这里把「点整行 = 切换」的行为显式接上，
/// 与 `CheckboxListTile` 的交互等价（整行可点，禁用态整行不可点）。
class _MihonMultiSelectRow extends StatelessWidget {
  const _MihonMultiSelectRow({
    required this.label,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final ValueChanged<bool?>? changed = onChanged;
    return FushiListItem(
      title: Text(label),
      leading: Checkbox(value: selected, onChanged: changed),
      onTap: changed == null ? null : () => changed(!selected),
    );
  }
}
