import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:spaces/spaces.dart';
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
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 48),
                    const SizedBox(height: 12),
                    Text(t.error_ankidroid_api,
                        style: textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(t.error_ankidroid_api_content,
                        textAlign: TextAlign.center,
                        style: textTheme.bodySmall),
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
            )
          : _decks == null
              ? const Center(child: CircularProgressIndicator())
              : _buildContent(),
    );
  }

  Widget _buildContent() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        _buildSectionHeader(t.anki_default_deck),
        const SizedBox(height: 4),
        _buildDeckSelector(),
        const Space.normal(),
        _buildSectionHeader(t.anki_default_profile),
        const SizedBox(height: 4),
        _buildProfileSelector(),
        const Space.normal(),
        const JidoujishoDivider(),
        const Space.small(),
        _buildSwitchRow(
          label: t.close_on_export,
          value: appModel.closeCreatorOnExport,
          onChanged: (_) {
            appModel.toggleCloseCreatorOnExport();
            setState(() {});
            Fluttertoast.showToast(
              msg: appModel.closeCreatorOnExport
                  ? t.close_on_export_on
                  : t.close_on_export_off,
            );
          },
        ),
        _buildSwitchRow(
          label: t.auto_add_book_name_to_tags,
          value: appModel.autoAddBookNameToTags,
          onChanged: (_) {
            appModel.toggleAutoAddBookNameToTags();
            setState(() {});
          },
        ),
        const Space.small(),
        const JidoujishoDivider(),
        const Space.small(),
        _buildManageDuplicateChecks(),
      ],
    );
  }

  Widget _buildSectionHeader(String label) {
    return Text(
      label,
      style: textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }

  Widget _buildDeckSelector() {
    final decks = _decks ?? [];
    final current = appModel.lastSelectedDeckName;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: decks.map((deck) {
        return ChoiceChip(
          label: Text(deck),
          selected: deck == current,
          onSelected: (on) {
            if (!on) return;
            appModel.setLastSelectedDeck(deck);
            setState(() {});
          },
        );
      }).toList(),
    );
  }

  Widget _buildProfileSelector() {
    final mappings = appModel.mappings;
    final current = appModel.lastSelectedMappingName;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: mappings.map((mapping) {
        return ChoiceChip(
          label: Text(mapping.label),
          selected: mapping.label == current,
          onSelected: (on) {
            if (!on) return;
            appModel.setLastSelectedMapping(mapping);
            setState(() {});
          },
        );
      }).toList(),
    );
  }

  Widget _buildSwitchRow({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }

  Widget _buildManageDuplicateChecks() {
    return InkWell(
      onTap: _showDuplicateChecksPage,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        width: double.infinity,
        decoration: BoxDecoration(
          color: Theme.of(context).unselectedWidgetColor.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.checklist_sharp,
              size: textTheme.titleSmall?.fontSize,
            ),
            const Space.small(),
            Text(
              t.manage_duplicate_checks,
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showDuplicateChecksPage() async {
    List<String> duplicateCheckModels = appModel.duplicateCheckModels;
    List<String> models = _models ?? [];
    Map<String, bool> items = Map<String, bool>.fromEntries(
        models.map((e) => MapEntry(e, duplicateCheckModels.contains(e))));
    if (context.mounted) {
      showDialog(
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
