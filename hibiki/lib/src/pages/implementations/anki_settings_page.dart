import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/profile/profile_selector.dart';

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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return AdaptiveSettingsScaffold(
      title: Text(t.anki_settings_label),
      children: [
        AdaptiveSettingsSection(
          children: [
            AdaptiveSettingsRow(
              title: t.profile_label,
              icon: Icons.person_outline,
              trailing: const ProfileSelector(),
            ),
            _buildFetchTile(uiState, vm),
          ],
        ),
        if (!Platform.isAndroid)
          AdaptiveSettingsSection(
            title: 'AnkiConnect',
            children: [
              _AnkiConnectionField(
                label: t.anki_connect_host,
                value: settings.ankiConnectHost,
                hint: 'localhost',
                onChanged: vm.updateAnkiConnectHost,
              ),
              _AnkiConnectionField(
                label: t.anki_connect_port,
                value: settings.ankiConnectPort.toString(),
                hint: '8765',
                keyboardType: TextInputType.number,
                onChanged: vm.updateAnkiConnectPort,
              ),
              _AnkiConnectionField(
                label: t.anki_connect_api_key,
                value: settings.ankiConnectApiKey,
                hint: t.anki_connect_api_key_hint,
                onChanged: vm.updateAnkiConnectApiKey,
              ),
            ],
          ),
        if (uiState.errorMessage != null)
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.gap + tokens.spacing.gap / 2,
              0,
              tokens.spacing.gap + tokens.spacing.gap / 2,
              tokens.spacing.gap + tokens.spacing.gap / 2,
            ),
            child: Text(
              uiState.errorMessage!,
              style:
                  textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        if (!uiState.isConfigured && uiState.errorMessage == null)
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.gap,
              tokens.spacing.page,
              tokens.spacing.page + tokens.spacing.gap / 2,
            ),
            child: Text(
              t.anki_not_configured,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (uiState.isConfigured) ...[
          AdaptiveSettingsSection(
            children: [
              _buildDeckDropdown(settings, vm),
              _buildNoteTypeDropdown(settings, vm),
            ],
          ),
          AdaptiveSettingsSection(
            title: t.anki_field_mappings,
            children: _buildFieldMappings(settings, vm),
          ),
          AdaptiveSettingsSection(
            children: [
              _buildTagsInput(settings, vm),
              AdaptiveSettingsSwitchRow(
                title: t.anki_allow_duplicates,
                subtitle: t.anki_allow_duplicates_hint,
                value: settings.allowDupes,
                onChanged: vm.updateAllowDupes,
              ),
              AdaptiveSettingsSwitchRow(
                title: t.anki_compact_glossaries,
                subtitle: t.anki_compact_glossaries_hint,
                value: settings.compactGlossaries,
                onChanged: vm.updateCompactGlossaries,
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildFetchTile(AnkiUiState uiState, AnkiViewModel vm) {
    return AdaptiveSettingsRow(
      icon: Icons.sync_outlined,
      title: uiState.isFetching ? t.anki_fetching : t.anki_fetch,
      // Action row, not navigation: tapping triggers a fetch (spinner while
      // running), it does not open a subpage — so no chevron.
      trailing: uiState.isFetching
          ? SizedBox(
              width: 20,
              height: 20,
              child: adaptiveIndicator(context: context, strokeWidth: 2),
            )
          : null,
      onTap: uiState.isFetching ? null : () => vm.fetchConfiguration(),
    );
  }

  Widget _buildDeckDropdown(AnkiSettings settings, AnkiViewModel vm) {
    final decks = settings.availableDecks;
    final selectedId = settings.selectedDeckId;
    final int? validSelectedId =
        decks.any((d) => d.id == selectedId) ? selectedId : null;

    return AdaptiveSettingsPickerRow<int?>(
      title: t.anki_deck,
      controlBelow: true,
      selected: validSelectedId,
      options: decks
          .map((d) => AdaptiveSettingsPickerOption<int?>(
                value: d.id,
                label: d.name,
              ))
          .toList(),
      onChanged: (id) {
        if (id == null) return;
        final deck = decks.firstWhere((d) => d.id == id);
        vm.selectDeck(deck);
      },
    );
  }

  Widget _buildNoteTypeDropdown(AnkiSettings settings, AnkiViewModel vm) {
    final noteTypes = settings.availableNoteTypes;
    final selectedId = settings.selectedNoteTypeId;
    final int? validSelectedId =
        noteTypes.any((n) => n.id == selectedId) ? selectedId : null;

    return AdaptiveSettingsPickerRow<int?>(
      title: t.anki_note_type,
      controlBelow: true,
      selected: validSelectedId,
      options: noteTypes
          .map((n) => AdaptiveSettingsPickerOption<int?>(
                value: n.id,
                label: n.name,
              ))
          .toList(),
      onChanged: (id) {
        if (id == null) return;
        final noteType = noteTypes.firstWhere((n) => n.id == id);
        vm.selectNoteType(noteType);
      },
    );
  }

  List<Widget> _buildFieldMappings(AnkiSettings settings, AnkiViewModel vm) {
    final noteType = settings.selectedNoteType;
    if (noteType == null) return const <Widget>[];

    return noteType.fields.map((field) {
      final value = settings.fieldMappings[field] ?? '';
      return AdaptiveSettingsNavigationRow(
        title: field,
        subtitle: value.isEmpty ? t.anki_field_not_mapped : value,
        icon: Icons.edit_outlined,
        onTap: () => _showHandlebarPicker(field, value, vm),
      );
    }).toList();
  }

  Future<void> _showHandlebarPicker(
    String field,
    String currentValue,
    AnkiViewModel vm,
  ) async {
    final dictionaryNames =
        appModel.termDictionaries.map((d) => d.name).toList();
    final options = AnkiHandlebarOptions.forTermDictionaries(dictionaryNames);

    final result = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AnkiHandlebarPickerDialog(
        title: t.anki_select_handlebar(field: field),
        initialValue: currentValue,
        options: options,
      ),
    );

    if (result != null) {
      vm.updateFieldMapping(field, result);
    }
  }

  Widget _buildTagsInput(AnkiSettings settings, AnkiViewModel vm) {
    return AdaptiveSettingsRow(
      title: t.anki_tags,
      controlBelow: true,
      trailing: AdaptiveSettingsTextField(
        initialValue: settings.tags,
        labelText: t.anki_tags,
        hintText: t.anki_tags_hint,
        onChanged: (v) => vm.updateTags(v),
      ),
    );
  }
}

/// A single AnkiConnect connection setting (host / port / API key).
///
/// Persists on EVERY change via [onChanged] — not only on Enter — so tapping
/// "Fetch" right after typing uses the value the user just entered. It holds
/// its own [TextEditingController] (rather than a keyed `initialValue` field)
/// so it also reflects externally-loaded values (async settings load, profile
/// switch) without resetting the caret while the user is typing.
class _AnkiConnectionField extends StatefulWidget {
  const _AnkiConnectionField({
    required this.label,
    required this.value,
    required this.hint,
    required this.onChanged,
    this.keyboardType = TextInputType.text,
  });

  final String label;
  final String value;
  final String hint;
  final ValueChanged<String> onChanged;
  final TextInputType keyboardType;

  @override
  State<_AnkiConnectionField> createState() => _AnkiConnectionFieldState();
}

class _AnkiConnectionFieldState extends State<_AnkiConnectionField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value);
  final FocusNode _focusNode = FocusNode();

  @override
  void didUpdateWidget(_AnkiConnectionField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reflect external value changes (async load, profile switch) ONLY while the
    // field is not being edited, so a lagging async save can never clobber the
    // user's in-progress typing.
    if (!_focusNode.hasFocus && widget.value != _controller.text) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: widget.label,
      controlBelow: true,
      trailing: AdaptiveSettingsTextField(
        controller: _controller,
        focusNode: _focusNode,
        keyboardType: widget.keyboardType,
        hintText: widget.hint,
        onChanged: widget.onChanged,
      ),
    );
  }
}

@visibleForTesting
class AnkiHandlebarPickerDialog extends StatefulWidget {
  const AnkiHandlebarPickerDialog({
    required this.title,
    required this.initialValue,
    required this.options,
    super.key,
  });

  final String title;
  final String initialValue;
  final List<String> options;

  @override
  State<AnkiHandlebarPickerDialog> createState() =>
      _AnkiHandlebarPickerDialogState();
}

class _AnkiHandlebarPickerDialogState extends State<AnkiHandlebarPickerDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double maxHeight =
        (MediaQuery.of(context).size.height * 0.24).clamp(56.0, 320.0);

    return HibikiDialogFrame(
      maxWidth: 560,
      maxHeightFactor: 0.96,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.gap,
      ),
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: widget.title,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          0,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        body: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: double.maxFinite,
            maxHeight: maxHeight,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AdaptiveSettingsTextField(
                controller: _controller,
                hintText: t.anki_field_not_mapped,
              ),
              SizedBox(height: tokens.spacing.gap),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.options.length,
                  itemBuilder: (_, i) {
                    final opt = widget.options[i];
                    if (opt == '-') return const Divider(height: 1);
                    final isSelected = widget.initialValue == opt;
                    return AdaptiveSettingsRow(
                      title: opt,
                      trailing: isSelected
                          ? Icon(
                              Icons.check,
                              color: Theme.of(context).colorScheme.primary,
                            )
                          : null,
                      onTap: () => Navigator.pop(context, opt),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: [
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context, ''),
              child:
                  Text(MaterialLocalizations.of(context).deleteButtonTooltip),
            ),
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context, _controller.text),
              child: Text(MaterialLocalizations.of(context).okButtonLabel),
            ),
          ],
        ),
      ),
    );
  }
}
