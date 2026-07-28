import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_manager.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_models.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/media_sources_view.dart';
import 'package:hibiki/utils.dart';

class MihonSourceSettingsPage extends ConsumerStatefulWidget {
  const MihonSourceSettingsPage({
    super.key,
    this.navigation,
  });

  final Widget? navigation;

  @override
  ConsumerState<MihonSourceSettingsPage> createState() =>
      _MihonSourceSettingsPageState();
}

class _MihonSourceSettingsPageState
    extends ConsumerState<MihonSourceSettingsPage> {
  final GlobalKey<MediaSourcesViewState> _localSourcesKey =
      GlobalKey<MediaSourcesViewState>();
  MihonManager? _manager;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final MihonManager manager = ref.read(appProvider).mihonManager;
    if (identical(manager, _manager)) return;
    _manager?.removeListener(_changed);
    _manager = manager..addListener(_changed);
  }

  @override
  void dispose() {
    _manager?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _clearSourceData(MangaOnlineSourceRow source) async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog.adaptive(
        title: Text(t.mihon_source_clear_data),
        content: Text(t.mihon_source_clear_data_hint),
        actions: <Widget>[
          adaptiveDialogAction(
            context: dialogContext,
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(t.dialog_cancel),
          ),
          adaptiveDialogAction(
            context: dialogContext,
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(t.dialog_clear),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _manager!.clearSourceData(source);
    } on Object catch (error) {
      if (mounted) HibikiToast.show(msg: '$error');
    }
  }

  void _openPreferences(MangaOnlineSourceRow source) {
    showAppDialog<void>(
      context: context,
      builder: (BuildContext context) => _MihonPreferencesDialog(
        manager: _manager!,
        source: source,
      ),
    );
  }

  Future<void> _moveSource(
    MangaOnlineSourceRow source,
    int delta,
  ) async {
    final List<MangaOnlineSourceRow> rows =
        List<MangaOnlineSourceRow>.of(_manager!.sources);
    final int index = rows.indexWhere(
      (MangaOnlineSourceRow row) =>
          row.extensionPackage == source.extensionPackage &&
          row.sourceId == source.sourceId,
    );
    final int target = index + delta;
    if (index < 0 || target < 0 || target >= rows.length) return;
    final MangaOnlineSourceRow other = rows[target];
    await _manager!.updateSourceSettings(
      source,
      sortOrder: other.sortOrder,
    );
    await _manager!.updateSourceSettings(
      other,
      sortOrder: source.sortOrder,
    );
  }

  @override
  Widget build(BuildContext context) {
    final MihonManager manager = _manager ?? ref.read(appProvider).mihonManager;
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context))
            HibikiPageHeader(
              title: t.mihon_source_settings_title,
              actions: <Widget>[
                HibikiIconButton(
                  tooltip: t.media_source_add,
                  label: t.media_source_add,
                  icon: Icons.create_new_folder_outlined,
                  onTap: () => _localSourcesKey.currentState?.addSource(),
                ),
              ],
              bottom: widget.navigation,
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                Text(
                  t.media_source_manage_title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                MediaSourcesView(
                  key: _localSourcesKey,
                  mediaKind: 'manga',
                ),
                const SizedBox(height: 28),
                Text(
                  t.mihon_sources_title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                if (manager.sources.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      t.mihon_source_empty,
                      textAlign: TextAlign.center,
                    ),
                  ),
                for (int index = 0; index < manager.sources.length; index++)
                  _buildOnlineSource(
                    manager,
                    manager.sources[index],
                    index,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOnlineSource(
    MihonManager manager,
    MangaOnlineSourceRow source,
    int index,
  ) {
    return Card(
      child: ListTile(
        leading: Switch.adaptive(
          value: source.enabled,
          onChanged: (bool value) => unawaited(
            manager.updateSourceSettings(source, enabled: value),
          ),
        ),
        title: Text(source.name),
        subtitle: Text(
          '${source.language.toUpperCase()} · ${source.extensionPackage}',
        ),
        trailing: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            IconButton(
              tooltip: t.sort_by,
              onPressed:
                  index == 0 ? null : () => unawaited(_moveSource(source, -1)),
              icon: const Icon(Icons.keyboard_arrow_up),
            ),
            IconButton(
              tooltip: t.sort_by,
              onPressed: index == manager.sources.length - 1
                  ? null
                  : () => unawaited(_moveSource(source, 1)),
              icon: const Icon(Icons.keyboard_arrow_down),
            ),
            IconButton(
              tooltip: t.mihon_source_preferences,
              onPressed: () => _openPreferences(source),
              icon: const Icon(Icons.tune),
            ),
            IconButton(
              tooltip: t.mihon_source_clear_data,
              onPressed: () => unawaited(_clearSourceData(source)),
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
            IconButton(
              tooltip: t.sort_by,
              onPressed: () => unawaited(
                manager.updateSourceSettings(
                  source,
                  pinned: !source.pinned,
                ),
              ),
              icon: Icon(
                source.pinned ? Icons.push_pin : Icons.push_pin_outlined,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MihonPreferencesDialog extends StatefulWidget {
  const _MihonPreferencesDialog({
    required this.manager,
    required this.source,
  });

  final MihonManager manager;
  final MangaOnlineSourceRow source;

  @override
  State<_MihonPreferencesDialog> createState() =>
      _MihonPreferencesDialogState();
}

class _MihonPreferencesDialogState extends State<_MihonPreferencesDialog> {
  List<MihonPreference>? _preferences;
  Object? _error;
  String? _savingKey;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final List<MihonPreference> preferences =
          await widget.manager.getPreferences(widget.source);
      if (mounted) setState(() => _preferences = preferences);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _save(
    MihonPreference original,
    Object? value,
  ) async {
    final MihonPreference changed = MihonPreference(
      key: original.key,
      kind: original.kind,
      title: original.title,
      summary: original.summary,
      value: value,
      entries: original.entries,
      entryValues: original.entryValues,
    );
    setState(() => _savingKey = original.key);
    try {
      final List<MihonPreference> preferences =
          await widget.manager.setPreference(widget.source, changed);
      if (mounted) setState(() => _preferences = preferences);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _savingKey = null);
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
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_close),
        ),
      ],
    );
  }

  Widget _buildPreference(MihonPreference preference) {
    final bool busy = _savingKey == preference.key;
    return switch (preference.kind) {
      MihonPreferenceKind.checkBox ||
      MihonPreferenceKind.switchControl =>
        SwitchListTile.adaptive(
          title: Text(preference.title),
          subtitle:
              preference.summary.isEmpty ? null : Text(preference.summary),
          value: preference.value == true,
          onChanged:
              busy ? null : (bool value) => unawaited(_save(preference, value)),
        ),
      MihonPreferenceKind.text => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: TextFormField(
            key: ValueKey<String>(
              '${preference.key}:${preference.value}',
            ),
            initialValue: preference.value?.toString() ?? '',
            enabled: !busy,
            decoration: InputDecoration(
              labelText: preference.title,
              helperText:
                  preference.summary.isEmpty ? null : preference.summary,
            ),
            onFieldSubmitted: (String value) =>
                unawaited(_save(preference, value)),
          ),
        ),
      MihonPreferenceKind.list => DropdownButtonFormField<int>(
          value: (preference.value as int? ?? 0)
              .clamp(0, preference.entries.length - 1),
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
          subtitle:
              preference.summary.isEmpty ? null : Text(preference.summary),
          children: <Widget>[
            for (int index = 0; index < preference.entries.length; index++)
              CheckboxListTile(
                title: Text(preference.entries[index]),
                value: (preference.value as List<Object?>? ?? const <Object?>[])
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
      MihonPreferenceKind.unsupported => ListTile(
          leading: const Icon(Icons.warning_amber_outlined),
          title: Text(preference.title),
          subtitle: Text(t.mihon_extension_incompatible),
        ),
    };
  }
}
