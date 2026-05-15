import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spaces/spaces.dart';
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
    return AlertDialog(
      contentPadding: MediaQuery.of(context).orientation == Orientation.portrait
          ? Spacing.of(context).insets.exceptBottom.big
          : Spacing.of(context).insets.exceptBottom.normal,
      content: buildContent(),
      actions: actions,
    );
  }

  List<Widget> get actions => [
        buildCloseButton(),
      ];

  Widget buildCloseButton() {
    return TextButton(
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
        child: SingleChildScrollView(
          controller: _contentScrollController,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDictionaryManageRow(),
              _buildCustomCssRow(),
              const Space.small(),
              const JidoujishoDivider(),
              const Space.small(),
              buildAutoSearchSwitch(),
              const Space.small(),
              buildAutoAddBookNameToTagsSwitch(),
              const Space.small(),
              buildCollapseDictionariesSwitch(),
              const Space.small(),
              buildDeduplicatePitchAccentsSwitch(),
              const Space.small(),
              buildHarmonicFrequencySwitch(),
              const Space.small(),
              const JidoujishoDivider(),
              buildDebounceDelayField(),
              buildDictionaryFontSizeField(),
              buildMaximumTermsField(),
              const Space.normal(),
              buildManageAudioSources(),
              const Space.normal(),
              buildLocalAudioSwitch(),
              buildLocalAudioDbList(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDictionaryManageRow() {
    return InkWell(
      onTap: () {
        showAppDialog(
          context: context,
          builder: (_) => const DictionaryDialogPage(),
        ).then((_) {
          if (mounted) setState(() {});
        });
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(Icons.auto_stories, size: textTheme.bodyMedium?.fontSize),
            const SizedBox(width: 8),
            Text(t.dictionaries),
            const Spacer(),
            Icon(Icons.chevron_right,
                size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomCssRow() {
    return InkWell(
      onTap: () {
        showAppDialog(
          context: context,
          builder: (_) => const _DictCssEditorDialog(),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(Icons.code, size: textTheme.bodyMedium?.fontSize),
            const SizedBox(width: 8),
            Text(t.custom_dict_css),
            const Spacer(),
            Icon(Icons.chevron_right,
                size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget buildAutoSearchSwitch() {
    ValueNotifier<bool> notifier =
        ValueNotifier<bool>(appModel.autoSearchEnabled);

    return Row(
      children: [
        Expanded(
          child: Text(t.auto_search),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: notifier,
          builder: (_, value, __) {
            return Switch(
              value: value,
              onChanged: (value) {
                appModel.toggleAutoSearchEnabled();
                notifier.value = appModel.autoSearchEnabled;
              },
            );
          },
        )
      ],
    );
  }

  Widget buildAutoAddBookNameToTagsSwitch() {
    ValueNotifier<bool> notifier =
        ValueNotifier<bool>(appModel.autoAddBookNameToTags);

    return Row(
      children: [
        Expanded(
          child: Text(t.auto_add_book_name_to_tags),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: notifier,
          builder: (_, value, __) {
            return Switch(
              value: value,
              onChanged: (value) {
                appModel.toggleAutoAddBookNameToTags();
                notifier.value = appModel.autoAddBookNameToTags;
              },
            );
          },
        )
      ],
    );
  }

  Widget buildCollapseDictionariesSwitch() {
    ValueNotifier<bool> notifier =
        ValueNotifier<bool>(appModel.collapseDictionaries);

    return Row(
      children: [
        Expanded(
          child: Text(t.collapse_dictionaries),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: notifier,
          builder: (_, value, __) {
            return Switch(
              value: value,
              onChanged: (value) {
                appModel.toggleCollapseDictionaries();
                notifier.value = appModel.collapseDictionaries;
              },
            );
          },
        )
      ],
    );
  }

  Widget buildDeduplicatePitchAccentsSwitch() {
    ValueNotifier<bool> notifier =
        ValueNotifier<bool>(appModel.deduplicatePitchAccents);

    return Row(
      children: [
        Expanded(
          child: Text(t.deduplicate_pitch_accents),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: notifier,
          builder: (_, value, __) {
            return Switch(
              value: value,
              onChanged: (value) {
                appModel.toggleDeduplicatePitchAccents();
                notifier.value = appModel.deduplicatePitchAccents;
              },
            );
          },
        )
      ],
    );
  }

  Widget buildHarmonicFrequencySwitch() {
    ValueNotifier<bool> notifier =
        ValueNotifier<bool>(appModel.harmonicFrequency);

    return Row(
      children: [
        Expanded(
          child: Text(t.harmonic_frequency),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: notifier,
          builder: (_, value, __) {
            return Switch(
              value: value,
              onChanged: (value) {
                appModel.toggleHarmonicFrequency();
                notifier.value = appModel.harmonicFrequency;
              },
            );
          },
        )
      ],
    );
  }

  Widget buildDebounceDelayField() {
    return TextField(
      onChanged: (value) {
        int newDelay =
            int.tryParse(value) ?? appModel.defaultSearchDebounceDelay;
        if (newDelay.isNegative) {
          newDelay = appModel.defaultSearchDebounceDelay;
          _debounceDelayController.text = newDelay.toString();
        }

        appModel.setSearchDebounceDelay(newDelay);
      },
      controller: _debounceDelayController,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        floatingLabelBehavior: FloatingLabelBehavior.always,
        suffixText: t.unit_milliseconds,
        suffixIcon: JidoujishoIconButton(
          tooltip: t.reset,
          size: 18,
          onTap: () async {
            _debounceDelayController.text =
                appModel.defaultSearchDebounceDelay.toString();
            appModel
                .setSearchDebounceDelay(appModel.defaultSearchDebounceDelay);
            FocusScope.of(context).unfocus();
          },
          icon: Icons.undo,
        ),
        labelText: t.auto_search_debounce_delay,
      ),
    );
  }

  Widget buildDictionaryFontSizeField() {
    return TextField(
      onChanged: (value) {
        double newSize =
            double.tryParse(value) ?? appModel.defaultDictionaryFontSize;
        if (newSize.isNegative) {
          newSize = appModel.defaultDictionaryFontSize;
          _dictionaryFontSizeController.text = newSize.toString();
        }

        appModel.setDictionaryFontSize(newSize);
      },
      controller: _dictionaryFontSizeController,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        floatingLabelBehavior: FloatingLabelBehavior.always,
        suffixText: t.unit_pixels,
        suffixIcon: JidoujishoIconButton(
          tooltip: t.reset,
          size: 18,
          onTap: () async {
            _dictionaryFontSizeController.text =
                appModel.defaultDictionaryFontSize.toString();
            appModel.setDictionaryFontSize(appModel.defaultDictionaryFontSize);
            FocusScope.of(context).unfocus();
          },
          icon: Icons.undo,
        ),
        labelText: t.dictionary_font_size,
      ),
    );
  }

  Widget buildMaximumTermsField() {
    return TextField(
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
      controller: _maximumTermsController,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        floatingLabelBehavior: FloatingLabelBehavior.always,
        suffixIcon: JidoujishoIconButton(
          tooltip: t.reset,
          size: 18,
          onTap: () async {
            _maximumTermsController.text =
                appModel.defaultMaximumDictionaryTermsInResult.toString();
            appModel.setMaximumTerms(
                appModel.defaultMaximumDictionaryTermsInResult);
            FocusScope.of(context).unfocus();
          },
          icon: Icons.undo,
        ),
        labelText: t.maximum_terms,
      ),
    );
  }

  Color get activeButtonColor =>
      Theme.of(context).unselectedWidgetColor.withOpacity(0.1);
  Color get inactiveButtonColor =>
      Theme.of(context).unselectedWidgetColor.withOpacity(0.05);
  Color get activeTextColor => Theme.of(context).colorScheme.onSurface;
  Color get inactiveTextColor => Theme.of(context).unselectedWidgetColor;

  Widget buildLocalAudioSwitch() {
    ValueNotifier<bool> notifier =
        ValueNotifier<bool>(appModel.localAudioEnabled);

    return Row(
      children: [
        Expanded(
          child: Text(t.local_audio),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: notifier,
          builder: (_, value, __) {
            return Switch(
              value: value,
              onChanged: (value) {
                appModel.toggleLocalAudio();
                notifier.value = appModel.localAudioEnabled;
              },
            );
          },
        )
      ],
    );
  }

  Widget buildLocalAudioDbList() {
    final List<LocalAudioDbEntry> dbs = appModel.localAudioDbs;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (dbs.isEmpty)
          Padding(
            padding: Spacing.of(context).insets.vertical.small,
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
    );
  }

  Widget _buildDbTile(List<LocalAudioDbEntry> dbs, int index) {
    final LocalAudioDbEntry entry = dbs[index];
    final String label = entry.displayName.isNotEmpty
        ? entry.displayName
        : entry.path.split('/').last;
    final bool enabled = entry.enabled;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Text(
              '${index + 1}',
              style: textTheme.bodyMedium?.copyWith(color: inactiveTextColor),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 6),
          Icon(
            enabled ? Icons.storage : Icons.block,
            size: textTheme.bodyMedium?.fontSize,
            color: enabled ? activeTextColor : inactiveTextColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: textTheme.bodyMedium?.copyWith(
                color: enabled ? null : inactiveTextColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          JidoujishoIconButton(
            tooltip: enabled ? t.options_hide : t.options_show,
            size: 18,
            icon: enabled ? Icons.check_circle_outline : Icons.block,
            onTap: () async {
              await appModelNoUpdate.toggleLocalAudioDbEnabled(index);
              setState(() {});
            },
          ),
          if (index > 0)
            JidoujishoIconButton(
              tooltip: '↑',
              size: 18,
              icon: Icons.arrow_upward,
              onTap: () async {
                await appModelNoUpdate.reorderLocalAudioDbs(index, index - 1);
                setState(() {});
              },
            ),
          if (index < dbs.length - 1)
            JidoujishoIconButton(
              tooltip: '↓',
              size: 18,
              icon: Icons.arrow_downward,
              onTap: () async {
                await appModelNoUpdate.reorderLocalAudioDbs(index, index + 2);
                setState(() {});
              },
            ),
          JidoujishoIconButton(
            tooltip: t.dialog_delete,
            size: 18,
            icon: Icons.delete_outline,
            onTap: () async {
              final bool? confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(t.dialog_delete),
                  content: Text(label),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(t.dialog_cancel),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: FilledButton.styleFrom(
                        backgroundColor:
                            Theme.of(context).colorScheme.errorContainer,
                        foregroundColor:
                            Theme.of(context).colorScheme.onErrorContainer,
                      ),
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
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 16),
                Text(t.dialog_importing),
              ],
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
    return InkWell(
      onTap: showAudioSourcesPage,
      child: Container(
        padding: Spacing.of(context).insets.vertical.normal,
        alignment: Alignment.center,
        width: double.infinity,
        color: activeButtonColor,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.volume_up,
              size: textTheme.titleSmall?.fontSize,
              color: activeTextColor,
            ),
            const Space.small(),
            Text(
              t.manage_audio_sources,
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: activeTextColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void showAudioSourcesPage() {
    showAppDialog(
      context: context,
      builder: (context) => _AudioSourcesDialog(
        sources: List<String>.from(appModel.audioSources),
        onSave: (sources) {
          appModel.setAudioSources(sources);
        },
      ),
    );
  }
}

class _AudioSourcesDialog extends StatefulWidget {
  const _AudioSourcesDialog({
    required this.sources,
    required this.onSave,
  });

  final List<String> sources;
  final void Function(List<String>) onSave;

  @override
  State<_AudioSourcesDialog> createState() => _AudioSourcesDialogState();
}

class _AudioSourcesDialogState extends State<_AudioSourcesDialog> {
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
    return AlertDialog(
      title: Text(t.manage_audio_sources),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _sources.length,
                itemBuilder: (context, index) {
                  return ListTile(
                    dense: true,
                    title: Text(
                      _sources[index],
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete, size: 18),
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
            const Space.normal(),
            TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: 'https://...{term}...{reading}',
                hintStyle: Theme.of(context).textTheme.bodySmall,
                suffixIcon: IconButton(
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
        TextButton(
          onPressed: () {
            setState(() {
              _sources = List<String>.from(AppModel.defaultAudioSources);
            });
          },
          child: Text(t.reset),
        ),
        TextButton(
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

class _DictCssEditorDialog extends StatefulWidget {
  const _DictCssEditorDialog();

  @override
  State<_DictCssEditorDialog> createState() => _DictCssEditorDialogState();
}

class _DictCssEditorDialogState extends State<_DictCssEditorDialog> {
  late int _selectedIndex;
  late TextEditingController _cssController;
  late List<String> _dictNames;
  late AppModel _appModel;

  bool get _isGlobal => _selectedIndex == 0;
  String get _currentDictName => _dictNames[_selectedIndex - 1];

  @override
  void initState() {
    super.initState();
    _appModel = ProviderScope.containerOf(context).read(appProvider);
    _dictNames = _appModel.dictionaries.map((d) => d.name).toList();
    _selectedIndex = 0;
    _cssController = TextEditingController(text: _appModel.globalDictCSS);
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
    _cssController.text = _isGlobal
        ? _appModel.globalDictCSS
        : _appModel.getCustomCSSForDict(_currentDictName);
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

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.55;

    return AlertDialog(
      title: Text(t.custom_dict_css),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: double.maxFinite,
          maxHeight: maxHeight,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButton<int>(
              value: _selectedIndex,
              isExpanded: true,
              onChanged: _onScopeChanged,
              items: [
                DropdownMenuItem<int>(
                  value: 0,
                  child: Text(t.custom_dict_css_global),
                ),
                for (int i = 0; i < _dictNames.length; i++)
                  DropdownMenuItem<int>(
                    value: i + 1,
                    child: Text(
                      _dictNames[i],
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
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
        TextButton(
          child: Text(t.dialog_close),
          onPressed: () async {
            await _saveCurrentScope();
            if (context.mounted) Navigator.pop(context);
          },
        ),
      ],
    );
  }
}
