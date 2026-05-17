import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';

class AnkiSettingsPage extends BasePage {
  const AnkiSettingsPage({super.key});

  @override
  BasePageState<AnkiSettingsPage> createState() => _AnkiSettingsPageState();
}

class _AnkiSettingsPageState extends BasePageState<AnkiSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final uiState = ref.watch(ankiViewModelProvider);
    final vm = ref.read(ankiViewModelProvider.notifier);
    final settings = uiState.settings;

    return Scaffold(
      appBar: AppBar(title: Text(t.anki_settings_label)),
      body: ListView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).padding.bottom + 16,
        ),
        children: [
          _buildFetchTile(uiState, vm),
          if (uiState.errorMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                uiState.errorMessage!,
                style: textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          if (!uiState.isConfigured && uiState.errorMessage == null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                t.anki_not_configured,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (uiState.isConfigured) ...[
            const Divider(),
            _buildDeckDropdown(settings, vm),
            const Divider(),
            _buildNoteTypeDropdown(settings, vm),
            const Divider(),
            _SectionHeader(t.anki_field_mappings),
            _buildFieldMappings(settings, vm),
            const Divider(),
            _buildTagsInput(settings, vm),
            const Divider(),
            SwitchListTile(
              title: Text(t.anki_allow_duplicates),
              subtitle: Text(
                t.anki_allow_duplicates_hint,
                style: textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              value: settings.allowDupes,
              onChanged: vm.updateAllowDupes,
            ),
            SwitchListTile(
              title: Text(t.anki_compact_glossaries),
              subtitle: Text(
                t.anki_compact_glossaries_hint,
                style: textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              value: settings.compactGlossaries,
              onChanged: vm.updateCompactGlossaries,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFetchTile(AnkiUiState uiState, AnkiViewModel vm) {
    return ListTile(
      leading: const Icon(Icons.sync),
      title: Text(
        uiState.isFetching ? t.anki_fetching : t.anki_fetch,
      ),
      trailing: uiState.isFetching
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.chevron_right),
      onTap: uiState.isFetching ? null : () => vm.fetchConfiguration(),
    );
  }

  Widget _buildDeckDropdown(AnkiSettings settings, AnkiViewModel vm) {
    final decks = settings.availableDecks;
    final selectedId = settings.selectedDeckId;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: DropdownButtonFormField<int>(
        decoration: InputDecoration(
          labelText: t.anki_deck,
          border: const OutlineInputBorder(),
        ),
        initialValue: decks.any((d) => d.id == selectedId) ? selectedId : null,
        items: decks
            .map((d) => DropdownMenuItem(value: d.id, child: Text(d.name)))
            .toList(),
        onChanged: (id) {
          if (id == null) return;
          final deck = decks.firstWhere((d) => d.id == id);
          vm.selectDeck(deck);
        },
      ),
    );
  }

  Widget _buildNoteTypeDropdown(AnkiSettings settings, AnkiViewModel vm) {
    final noteTypes = settings.availableNoteTypes;
    final selectedId = settings.selectedNoteTypeId;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: DropdownButtonFormField<int>(
        decoration: InputDecoration(
          labelText: t.anki_note_type,
          border: const OutlineInputBorder(),
        ),
        initialValue:
            noteTypes.any((n) => n.id == selectedId) ? selectedId : null,
        items: noteTypes
            .map((n) => DropdownMenuItem(value: n.id, child: Text(n.name)))
            .toList(),
        onChanged: (id) {
          if (id == null) return;
          final noteType = noteTypes.firstWhere((n) => n.id == id);
          vm.selectNoteType(noteType);
        },
      ),
    );
  }

  Widget _buildFieldMappings(AnkiSettings settings, AnkiViewModel vm) {
    final noteType = settings.selectedNoteType;
    if (noteType == null) return const SizedBox.shrink();

    return Column(
      children: noteType.fields.map((field) {
        final value = settings.fieldMappings[field] ?? '';
        return ListTile(
          title: Text(field),
          subtitle: Text(
            value.isEmpty ? t.anki_field_not_mapped : value,
            style: textTheme.bodySmall?.copyWith(
              color: value.isEmpty
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.onSurface,
            ),
          ),
          trailing: const Icon(Icons.edit, size: 18),
          onTap: () => _showHandlebarPicker(field, value, vm),
        );
      }).toList(),
    );
  }

  Future<void> _showHandlebarPicker(
    String field,
    String currentValue,
    AnkiViewModel vm,
  ) async {
    final dictionaryNames =
        appModel.termDictionaries.map((d) => d.name).toList();
    final options = AnkiHandlebarOptions.forTermDictionaries(dictionaryNames);
    final controller = TextEditingController(text: currentValue);

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.anki_select_handlebar(field: field)),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  hintText: t.anki_field_not_mapped,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: options.length,
                  itemBuilder: (_, i) {
                    final opt = options[i];
                    if (opt == '-') return const Divider(height: 1);
                    final isSelected = currentValue == opt;
                    return ListTile(
                      dense: true,
                      title: Text(opt),
                      selected: isSelected,
                      onTap: () => Navigator.pop(ctx, opt),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: Text(MaterialLocalizations.of(ctx).deleteButtonTooltip),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
          ),
        ],
      ),
    );

    if (result != null) {
      vm.updateFieldMapping(field, result);
    }
  }

  Widget _buildTagsInput(AnkiSettings settings, AnkiViewModel vm) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: TextFormField(
        initialValue: settings.tags,
        decoration: InputDecoration(
          labelText: t.anki_tags,
          hintText: t.anki_tags_hint,
          border: const OutlineInputBorder(),
        ),
        onChanged: (v) => vm.updateTags(v),
      ),
    );
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
