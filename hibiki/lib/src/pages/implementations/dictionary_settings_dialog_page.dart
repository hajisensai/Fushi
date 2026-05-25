import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

/// The content of the dialog used for managing dictionary settings.
class DictionarySettingsDialogPage extends BasePage {
  /// Create an instance of this page.
  const DictionarySettingsDialogPage({super.key});

  @override
  BasePageState createState() => _DictionaryDialogPageState();
}

class _DictionaryDialogPageState extends BasePageState {
  late TextEditingController _debounceDelayController;
  late TextEditingController _dictionaryFontSizeController;
  late TextEditingController _maximumTermsController;
  final ScrollController _contentScrollController = ScrollController();

  @override
  void initState() {
    super.initState();

    _debounceDelayController = TextEditingController(
        text: appModelNoUpdate.searchDebounceDelay.toString());
    _dictionaryFontSizeController = TextEditingController(
        text: appModelNoUpdate.dictionaryFontSize.toString());

    _maximumTermsController =
        TextEditingController(text: appModelNoUpdate.maximumTerms.toString());
  }

  @override
  void dispose() {
    _contentScrollController.dispose();
    _debounceDelayController.dispose();
    _dictionaryFontSizeController.dispose();
    _maximumTermsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return adaptiveAlertDialog(
      context: context,
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      content: buildContent(),
      actions: actions,
    );
  }

  List<Widget> get actions => [
        buildCloseButton(),
      ];

  Widget buildCloseButton() {
    return adaptiveDialogAction(
      context: context,
      child: Text(t.dialog_close),
      onPressed: () => Navigator.pop(context),
    );
  }

  Widget buildContent() {
    return SizedBox(
      width: double.maxFinite,
      child: RawScrollbar(
        thickness: 3,
        thumbVisibility: true,
        controller: _contentScrollController,
        child: ListView(
          controller: _contentScrollController,
          shrinkWrap: true,
          children: [
            AdaptiveSettingsSection(
              children: [
                _buildDictionaryManageRow(),
                _buildCustomCssRow(),
              ],
            ),
            AdaptiveSettingsSection(
              children: [
                buildAutoSearchSwitch(),
                buildAutoAddBookNameToTagsSwitch(),
                buildCollapseDictionariesSwitch(),
                buildDeduplicatePitchAccentsSwitch(),
                buildHarmonicFrequencySwitch(),
                buildShowExpressionTagsSwitch(),
              ],
            ),
            AdaptiveSettingsSection(
              children: [
                buildDebounceDelayField(),
                buildDictionaryFontSizeField(),
                buildMaximumTermsField(),
              ],
            ),
            AdaptiveSettingsSection(
              children: [
                buildManageAudioSources(),
                buildLocalAudioSwitch(),
                buildLocalAudioDbList(),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDictionaryManageRow() {
    return AdaptiveSettingsNavigationRow(
      title: t.dictionaries,
      icon: Icons.auto_stories_outlined,
      onTap: () {
        showAppDialog(
          context: context,
          builder: (_) => const DictionaryDialogPage(),
        ).then((_) {
          if (mounted) setState(() {});
        });
      },
    );
  }

  Widget _buildCustomCssRow() {
    return AdaptiveSettingsNavigationRow(
      title: t.custom_dict_css,
      icon: Icons.code_outlined,
      onTap: () {
        showAppDialog(
          context: context,
          builder: (_) => const DictCssEditorDialog(),
        );
      },
    );
  }

  Widget buildAutoSearchSwitch() {
    return _buildSwitchRow(
      title: t.auto_search,
      value: appModel.autoSearchEnabled,
      onChanged: appModel.toggleAutoSearchEnabled,
    );
  }

  Widget buildAutoAddBookNameToTagsSwitch() {
    return _buildSwitchRow(
      title: t.auto_add_book_name_to_tags,
      value: appModel.autoAddBookNameToTags,
      onChanged: appModel.toggleAutoAddBookNameToTags,
    );
  }

  Widget buildCollapseDictionariesSwitch() {
    return _buildSwitchRow(
      title: t.collapse_dictionaries,
      value: appModel.collapseDictionaries,
      onChanged: appModel.toggleCollapseDictionaries,
    );
  }

  Widget buildDeduplicatePitchAccentsSwitch() {
    return _buildSwitchRow(
      title: t.deduplicate_pitch_accents,
      value: appModel.deduplicatePitchAccents,
      onChanged: appModel.toggleDeduplicatePitchAccents,
    );
  }

  Widget buildHarmonicFrequencySwitch() {
    return _buildSwitchRow(
      title: t.harmonic_frequency,
      value: appModel.harmonicFrequency,
      onChanged: appModel.toggleHarmonicFrequency,
    );
  }

  Widget buildShowExpressionTagsSwitch() {
    return _buildSwitchRow(
      title: t.show_expression_tags,
      value: appModel.showExpressionTags,
      onChanged: appModel.toggleShowExpressionTags,
    );
  }

  Widget _buildSwitchRow({
    required String title,
    required bool value,
    required VoidCallback onChanged,
  }) {
    return AdaptiveSettingsSwitchRow(
      title: title,
      value: value,
      onChanged: (_) {
        onChanged();
        setState(() {});
      },
    );
  }

  Widget buildDebounceDelayField() {
    return _buildNumberTextField(
      title: t.auto_search_debounce_delay,
      controller: _debounceDelayController,
      suffixText: t.unit_milliseconds,
      onChanged: (value) {
        int newDelay =
            int.tryParse(value) ?? appModel.defaultSearchDebounceDelay;
        if (newDelay.isNegative) {
          newDelay = appModel.defaultSearchDebounceDelay;
          _debounceDelayController.text = newDelay.toString();
        }
        appModel.setSearchDebounceDelay(newDelay);
      },
      onReset: () {
        _debounceDelayController.text =
            appModel.defaultSearchDebounceDelay.toString();
        appModel.setSearchDebounceDelay(appModel.defaultSearchDebounceDelay);
      },
    );
  }

  Widget buildDictionaryFontSizeField() {
    return _buildNumberTextField(
      title: t.dictionary_font_size,
      controller: _dictionaryFontSizeController,
      suffixText: t.unit_pixels,
      onChanged: (value) {
        double newSize =
            double.tryParse(value) ?? appModel.defaultDictionaryFontSize;
        if (newSize.isNegative) {
          newSize = appModel.defaultDictionaryFontSize;
          _dictionaryFontSizeController.text = newSize.toString();
        }
        appModel.setDictionaryFontSize(newSize);
      },
      onReset: () {
        _dictionaryFontSizeController.text =
            appModel.defaultDictionaryFontSize.toString();
        appModel.setDictionaryFontSize(appModel.defaultDictionaryFontSize);
      },
    );
  }

  Widget buildMaximumTermsField() {
    return _buildNumberTextField(
      title: t.maximum_terms,
      controller: _maximumTermsController,
      onChanged: (value) {
        int newAmount = int.tryParse(value) ??
            appModel.defaultMaximumDictionaryTermsInResult;
        if (newAmount.isNegative) {
          newAmount = appModel.defaultMaximumDictionaryTermsInResult;
          _maximumTermsController.text = newAmount.toString();
        }
        appModel.setMaximumTerms(newAmount);
        appModel.clearDictionaryResultsCache();
      },
      onReset: () {
        _maximumTermsController.text =
            appModel.defaultMaximumDictionaryTermsInResult.toString();
        appModel
            .setMaximumTerms(appModel.defaultMaximumDictionaryTermsInResult);
      },
    );
  }

  Widget _buildNumberTextField({
    required String title,
    required TextEditingController controller,
    required ValueChanged<String> onChanged,
    required VoidCallback onReset,
    String? suffixText,
  }) {
    return AdaptiveSettingsRow(
      title: title,
      controlBelow: true,
      trailing: TextField(
        onChanged: onChanged,
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          floatingLabelBehavior: FloatingLabelBehavior.always,
          suffixText: suffixText,
          suffixIcon: HibikiIconButton(
            tooltip: t.reset,
            size: 18,
            onTap: () {
              onReset();
              FocusScope.of(context).unfocus();
            },
            icon: Icons.undo_outlined,
          ),
          labelText: title,
        ),
      ),
    );
  }

  Color get activeTextColor => Theme.of(context).colorScheme.onSurface;
  Color get inactiveTextColor => Theme.of(context).colorScheme.onSurfaceVariant;

  Widget buildLocalAudioSwitch() {
    return _buildSwitchRow(
      title: t.local_audio,
      value: appModel.localAudioEnabled,
      onChanged: appModel.toggleLocalAudio,
    );
  }

  Widget buildLocalAudioDbList() {
    final List<LocalAudioDbEntry> dbs = appModel.localAudioDbs;

    return AdaptiveSettingsRow(
      title: t.local_audio_add_db,
      controlBelow: true,
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (dbs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                t.local_audio_not_set,
                style: textTheme.bodySmall?.copyWith(color: inactiveTextColor),
              ),
            ),
          for (int index = 0; index < dbs.length; index++)
            _buildDbTile(dbs, index),
          const SizedBox(height: 4),
          TextButton.icon(
            icon: Icon(Icons.add, size: textTheme.bodyMedium?.fontSize),
            label: Text(t.local_audio_add_db, style: textTheme.bodyMedium),
            onPressed: _pickAndAddAudioDb,
          ),
        ],
      ),
    );
  }

  Widget _buildDbTile(List<LocalAudioDbEntry> dbs, int index) {
    final LocalAudioDbEntry entry = dbs[index];
    final String label = entry.displayName.isNotEmpty
        ? entry.displayName
        : entry.path.split('/').last;
    final bool enabled = entry.enabled;

    return AdaptiveSettingsRow(
      title: label,
      icon: enabled ? Icons.storage_outlined : Icons.block,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${index + 1}',
            style: textTheme.bodySmall?.copyWith(color: inactiveTextColor),
          ),
          HibikiIconButton(
            tooltip: enabled ? t.options_hide : t.options_show,
            size: 18,
            icon: enabled ? Icons.check_circle_outline : Icons.block,
            onTap: () async {
              await appModelNoUpdate.toggleLocalAudioDbEnabled(index);
              setState(() {});
            },
          ),
          if (index > 0)
            HibikiIconButton(
              tooltip: '↑',
              size: 18,
              icon: Icons.arrow_upward_outlined,
              onTap: () async {
                await appModelNoUpdate.reorderLocalAudioDbs(index, index - 1);
                setState(() {});
              },
            ),
          if (index < dbs.length - 1)
            HibikiIconButton(
              tooltip: '↓',
              size: 18,
              icon: Icons.arrow_downward_outlined,
              onTap: () async {
                await appModelNoUpdate.reorderLocalAudioDbs(index, index + 2);
                setState(() {});
              },
            ),
          HibikiIconButton(
            tooltip: t.dialog_delete,
            size: 18,
            icon: Icons.delete_outline,
            onTap: () async {
              final bool? confirmed = await showAppDialog<bool>(
                context: context,
                builder: (ctx) => adaptiveAlertDialog(
                  context: ctx,
                  title: Text(t.dialog_delete),
                  content: Text(label),
                  actions: [
                    adaptiveDialogAction(
                      context: ctx,
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(t.dialog_cancel),
                    ),
                    adaptiveDialogAction(
                      context: ctx,
                      isDefaultAction: true,
                      isDestructiveAction: true,
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(t.dialog_delete),
                    ),
                  ],
                ),
              );
              if (confirmed == true && mounted) {
                await appModelNoUpdate.removeLocalAudioDb(index);
                setState(() {});
              }
            },
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndAddAudioDb() async {
    bool importDialogShown = false;

    void showImportDialog() {
      if (importDialogShown || !mounted) return;
      importDialogShown = true;
      showAppDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: Builder(
            builder: (ctx) => adaptiveAlertDialog(
              context: ctx,
              content: Row(
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: adaptiveIndicator(context: ctx, strokeWidth: 2),
                  ),
                  const SizedBox(width: 16),
                  Text(t.dialog_importing),
                ],
              ),
            ),
          ),
        ),
      );
    }

    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        onFileLoading: (status) {
          if (status == FilePickerStatus.picking) showImportDialog();
        },
      );
      if (result != null && result.files.single.path != null && mounted) {
        final PlatformFile file = result.files.single;
        showImportDialog();
        await appModelNoUpdate.addLocalAudioDb(
          file.path!,
          displayName: file.name,
        );
        if (mounted) setState(() {});
      }
    } finally {
      if (importDialogShown && mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  Widget buildManageAudioSources() {
    return AdaptiveSettingsNavigationRow(
      title: t.manage_audio_sources,
      icon: Icons.volume_up_outlined,
      onTap: showAudioSourcesPage,
    );
  }

  void showAudioSourcesPage() {
    showAppDialog(
      context: context,
      builder: (context) => AudioSourcesDialog(
        sources: List<String>.from(appModel.audioSources),
        onSave: (sources) {
          appModel.setAudioSources(sources);
        },
      ),
    );
  }
}

@visibleForTesting
class AudioSourcesDialog extends StatefulWidget {
  const AudioSourcesDialog({
    required this.sources,
    required this.onSave,
    super.key,
  });

  final List<String> sources;
  final void Function(List<String>) onSave;

  @override
  State<AudioSourcesDialog> createState() => _AudioSourcesDialogState();
}

class _AudioSourcesDialogState extends State<AudioSourcesDialog> {
  late List<String> _sources;
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _sources = List<String>.from(widget.sources);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double maxHeight = MediaQuery.of(context).size.height * 0.42;

    return adaptiveAlertDialog(
      context: context,
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      actionsPadding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      buttonPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Text(
        t.manage_audio_sources,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: double.maxFinite,
          maxHeight: maxHeight,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: ReorderableListView.builder(
                shrinkWrap: true,
                itemCount: _sources.length,
                onReorder: (int oldIndex, int newIndex) {
                  setState(() {
                    if (newIndex > oldIndex) newIndex--;
                    final item = _sources.removeAt(oldIndex);
                    _sources.insert(newIndex, item);
                  });
                },
                itemBuilder: (context, index) {
                  return AdaptiveSettingsRow(
                    key: ValueKey('audio_src_$index'),
                    title: _sources[index],
                    icon: Icons.drag_handle,
                    trailing: IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: () {
                        setState(() {
                          _sources.removeAt(index);
                        });
                      },
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: 'https://...{term}...{reading}',
                hintStyle: Theme.of(context).textTheme.bodySmall,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                suffixIcon: IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.add),
                  onPressed: _addSource,
                ),
              ),
              style: Theme.of(context).textTheme.bodySmall,
              onSubmitted: (_) => _addSource(),
            ),
          ],
        ),
      ),
      actions: [
        adaptiveDialogAction(
          context: context,
          onPressed: () {
            setState(() {
              _sources = List<String>.from(AppModel.defaultAudioSources);
            });
          },
          child: Text(t.reset),
        ),
        adaptiveDialogAction(
          context: context,
          onPressed: () {
            widget.onSave(_sources);
            Navigator.pop(context);
          },
          child: Text(t.dialog_close),
        ),
      ],
    );
  }

  void _addSource() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) {
      setState(() {
        _sources.add(text);
        _controller.clear();
      });
    }
  }
}

class DictCssEditorDialog extends StatefulWidget {
  const DictCssEditorDialog({
    super.key,
    this.initialDictionaryName,
  });

  final String? initialDictionaryName;

  @override
  State<DictCssEditorDialog> createState() => _DictCssEditorDialogState();
}

class _DictCssEditorDialogState extends State<DictCssEditorDialog> {
  late int _selectedIndex;
  late TextEditingController _cssController;
  late List<String> _dictNames;
  late AppModel _appModel;

  bool get _isGlobal => _selectedIndex == 0;
  String get _currentDictName => _dictNames[_selectedIndex - 1];

  @override
  void initState() {
    super.initState();
    _appModel =
        ProviderScope.containerOf(context, listen: false).read(appProvider);
    _dictNames = _appModel.dictionaries.map((d) => d.name).toList();
    _selectedIndex = _initialSelectedIndex();
    _cssController = TextEditingController(text: _currentCss);
  }

  @override
  void dispose() {
    _cssController.dispose();
    super.dispose();
  }

  Future<void> _onScopeChanged(int? index) async {
    if (index == null || index == _selectedIndex) return;
    await _saveCurrentScope();
    _selectedIndex = index;
    _cssController.text = _currentCss;
    setState(() {});
  }

  Future<void> _saveCurrentScope() async {
    final css = _cssController.text;
    if (_isGlobal) {
      await _appModel.setGlobalDictCSS(css);
    } else {
      await _appModel.setCustomCSSForDict(_currentDictName, css);
    }
  }

  int _initialSelectedIndex() {
    final String? initialDictionaryName = widget.initialDictionaryName;
    if (initialDictionaryName == null) return 0;
    final int dictIndex = _dictNames.indexOf(initialDictionaryName);
    return dictIndex < 0 ? 0 : dictIndex + 1;
  }

  String get _currentCss {
    return _isGlobal
        ? _appModel.globalDictCSS
        : _appModel.getCustomCSSForDict(_currentDictName);
  }

  @override
  Widget build(BuildContext context) {
    final Size mediaSize = MediaQuery.of(context).size;
    final double contentHeight = (mediaSize.height * 0.55).clamp(280.0, 480.0);
    final double contentWidth = desktopDialogContentWidth(mediaSize.width);

    return adaptiveAlertDialog(
      context: context,
      title: Text(t.custom_dict_css),
      content: SizedBox(
        width: contentWidth,
        height: contentHeight,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildScopeDropdown(context),
            const SizedBox(height: 8),
            Expanded(
              child: TextField(
                controller: _cssController,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
                decoration: const InputDecoration(
                  hintText: '.glossary-content { font-size: 18px; }',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.all(8),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        adaptiveDialogAction(
          context: context,
          child: Text(t.dialog_close),
          onPressed: () async {
            await _saveCurrentScope();
            if (context.mounted) Navigator.pop(context);
          },
        ),
      ],
    );
  }

  Widget _buildScopeDropdown(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: DropdownMenu<int>(
        label: Text(t.custom_dict_css),
        expandedInsets: EdgeInsets.zero,
        initialSelection: _selectedIndex,
        dropdownMenuEntries: [
          DropdownMenuEntry<int>(
            value: 0,
            label: t.custom_dict_css_global,
          ),
          for (int i = 0; i < _dictNames.length; i++)
            DropdownMenuEntry<int>(
              value: i + 1,
              label: _dictNames[i],
            ),
        ],
        onSelected: _onScopeChanged,
      ),
    );
  }
}
