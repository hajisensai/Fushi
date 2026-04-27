import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

class AnkiSettingsPage extends BasePage {
  const AnkiSettingsPage({super.key});

  @override
  BasePageState createState() => _AnkiSettingsPageState();
}

class _AnkiSettingsPageState extends BasePageState {
  List<String>? _decks;
  List<String>? _models;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadAnkiData();
  }

  Future<void> _loadAnkiData() async {
    try {
      final decks = await appModel.getDecks();
      final models = await appModel.getModelList();
      if (mounted) {
        setState(() {
          _decks = decks;
          _models = models;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.anki_settings_label),
      ),
      body: _loadError != null
          ? _buildError()
          : _decks == null
              ? const Center(child: CircularProgressIndicator())
              : _buildContent(),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text(t.error_ankidroid_api, style: textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(t.error_ankidroid_api_content,
                textAlign: TextAlign.center, style: textTheme.bodySmall),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                setState(() => _loadError = null);
                _loadAnkiData();
              },
              child: Text(t.anki_retry),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    final decks = _decks ?? [];
    final mappings = appModel.mappings;
    final currentDeck = appModel.lastSelectedDeckName;
    final currentProfile = appModel.lastSelectedMappingName;

    return ListView(
      children: [
        // ── Default Deck ──
        _SectionHeader(t.anki_default_deck),
        RadioGroup<String>(
          groupValue: currentDeck,
          onChanged: (v) {
            if (v == null) return;
            appModel.setLastSelectedDeck(v);
            setState(() {});
          },
          child: Column(
            children: decks
                .map((deck) => RadioListTile<String>(
                      title: Text(deck),
                      value: deck,
                    ))
                .toList(),
          ),
        ),
        const Divider(),

        // ── Default Export Profile ──
        _SectionHeader(t.anki_default_profile),
        RadioGroup<String>(
          groupValue: currentProfile,
          onChanged: (v) {
            if (v == null) return;
            final m = appModel.getMappingFromLabel(v);
            if (m != null) appModel.setLastSelectedMapping(m);
            setState(() {});
          },
          child: Column(
            children: mappings
                .map((mapping) => RadioListTile<String>(
                      title: Text(mapping.label),
                      subtitle: Text(mapping.model,
                          style: textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                      value: mapping.label,
                    ))
                .toList(),
          ),
        ),
        const Divider(),

        // ── Settings ──
        _SectionHeader(t.show_options),
        SwitchListTile(
          title: Text(t.silent_export),
          subtitle: Text(t.anki_silent_export_hint,
              style: textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          value: appModel.silentExport,
          onChanged: (_) {
            appModel.toggleSilentExport();
            setState(() {});
            Fluttertoast.showToast(
              msg: appModel.silentExport
                  ? t.silent_export_on
                  : t.silent_export_off,
            );
          },
        ),
        SwitchListTile(
          title: Text(t.auto_add_book_name_to_tags),
          subtitle: Text(t.anki_auto_tag_hint,
              style: textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          value: appModel.autoAddBookNameToTags,
          onChanged: (_) {
            appModel.toggleAutoAddBookNameToTags();
            setState(() {});
          },
        ),
        const Divider(),

        // ── Manage Export Profiles ──
        ListTile(
          leading: const Icon(Icons.tune),
          title: Text(t.anki_manage_profiles),
          subtitle: Text(t.anki_manage_profiles_hint,
              style: textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            final models = _models ?? [];
            if (models.isEmpty) return;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ProfilesManagementPage(
                  models: models,
                  initialModel: appModel.lastSelectedMapping.model,
                ),
              ),
            ).then((_) {
              if (mounted) setState(() {});
            });
          },
        ),

        // ── Manage Duplicate Checks ──
        ListTile(
          leading: const Icon(Icons.checklist),
          title: Text(t.manage_duplicate_checks),
          subtitle: Text(t.anki_duplicate_check_hint,
              style: textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          trailing: const Icon(Icons.chevron_right),
          onTap: _showDuplicateChecksPage,
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  void _showDuplicateChecksPage() async {
    List<String> duplicateCheckModels = appModel.duplicateCheckModels;
    List<String> models = _models ?? [];
    Map<String, bool> items = Map<String, bool>.fromEntries(
        models.map((e) => MapEntry(e, duplicateCheckModels.contains(e))));
    if (context.mounted) {
      showAppDialog(
        context: context,
        builder: (context) => SwitchSettingsPage<String>(
          items: items,
          generateLabel: (item) => item,
          onSave: (selection) {
            List<String> newModels = selection.entries
                .where((e) => e.value)
                .map((e) => e.key)
                .toList();
            appModel.setDuplicateCheckModels(newModels);
            if (!duplicateCheckModels.equals(newModels)) {
              appModel.refresh();
            }
          },
        ),
      );
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}
