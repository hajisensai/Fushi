import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/models/dictionary_repository.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/utils.dart';

/// Page used for managing installed dictionaries.
class DictionaryDialogPage extends BasePage {
  /// Create an instance of this page.
  const DictionaryDialogPage({super.key});

  @override
  BasePageState createState() => _DictionaryDialogPageState();
}

class _DictionaryDialogPageState extends BasePageState {
  DictionaryType _selectedType = DictionaryType.term;
  bool _isDownloading = false;

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsScaffold(
      title: Text(t.dictionaries),
      actions: _buildPageActions(),
      children: [
        _buildCategorySelector(),
        buildContent(),
      ],
    );
  }

  List<Widget> _buildPageActions() {
    return [
      IconButton(
        tooltip: t.dict_download_browse,
        icon: const Icon(Icons.cloud_download_outlined),
        onPressed: _showDownloadSelectionDialog,
      ),
      if (Platform.isAndroid)
        IconButton(
          tooltip: t.dialog_import_folder,
          icon: const Icon(Icons.drive_folder_upload_outlined),
          onPressed: _importDictionaryFolder,
        ),
      IconButton(
        tooltip: t.dialog_import_dictionary,
        icon: const Icon(Icons.upload_file_outlined),
        onPressed: _importDictionaryFiles,
      ),
      IconButton(
        tooltip: t.dialog_clear_all_dictionaries,
        icon: Icon(
          Icons.delete_sweep_outlined,
          color: theme.colorScheme.error,
        ),
        onPressed: showDictionaryClearDialog,
      ),
    ];
  }

  Future<void> showDictionaryClearDialog() async {
    Widget alertDialog = adaptiveAlertDialog(
      context: context,
      title: Text(t.dialog_title_dictionary_clear),
      content: Text(
        t.dialog_content_dictionary_clear,
        textAlign: TextAlign.justify,
      ),
      actions: <Widget>[
        adaptiveDialogAction(
          context: context,
          child: Text(
            t.dialog_clear,
          ),
          onPressed: () async {
            showAppDialog(
              barrierDismissible: false,
              context: context,
              builder: (context) => const DictionaryDialogDeletePage(),
            );

            await appModel.deleteDictionaries();

            if (mounted) {
              Navigator.pop(context);
            }

            if (mounted) {
              Navigator.pop(context);
              setState(() {});
            }
          },
        ),
        adaptiveDialogAction(
          context: context,
          child: Text(t.dialog_cancel),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );

    showAppDialog(
      context: context,
      builder: (context) => alertDialog,
    );
  }

  Future<void> showDictionaryDeleteDialog(Dictionary dictionary) async {
    Widget alertDialog = adaptiveAlertDialog(
      context: context,
      title: Text(t.dialog_title_dictionary_delete(name: dictionary.name)),
      content: Text(
        t.dialog_content_dictionary_delete,
        textAlign: TextAlign.justify,
      ),
      actions: <Widget>[
        adaptiveDialogAction(
          context: context,
          child: Text(
            t.dialog_delete,
          ),
          onPressed: () async {
            showAppDialog(
              barrierDismissible: false,
              context: context,
              builder: (context) =>
                  DictionaryDialogDeletePage(name: dictionary.name),
            );

            await appModel.deleteDictionary(dictionary);

            if (mounted) {
              Navigator.pop(context);
            }

            if (mounted) {
              Navigator.pop(context);
              setState(() {});
            }
          },
        ),
        adaptiveDialogAction(
          context: context,
          child: Text(t.dialog_cancel),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );

    showAppDialog(
      context: context,
      builder: (context) => alertDialog,
    );
  }

  Future<void> _importDictionaryFiles() async {
    ValueNotifier<String> progressNotifier =
        ValueNotifier<String>(t.import_start);
    ValueNotifier<int?> countNotifier = ValueNotifier<int?>(null);
    ValueNotifier<int?> totalNotifier = ValueNotifier<int?>(null);
    progressNotifier.addListener(() {
      debugPrint('[Dictionary Import] ${progressNotifier.value}');
    });

    if (Platform.isAndroid || Platform.isIOS) {
      await FilePicker.platform.clearTemporaryFiles();
    }

    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip', 'dsl', 'mdx', 'ifo', 'css'],
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) {
      return;
    }

    if (!mounted) return;
    showAppDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => DictionaryDialogImportPage(
        progressNotifier: progressNotifier,
        countNotifier: countNotifier,
        totalNotifier: totalNotifier,
      ),
    );

    final dictFiles = result.files
        .where((f) => !f.path!.toLowerCase().endsWith('.css'))
        .toList();
    final cssFiles = result.files
        .where((f) => f.path!.toLowerCase().endsWith('.css'))
        .map((f) => File(f.path!))
        .toList();

    bool hadMemoryError = false;

    totalNotifier.value = dictFiles.length;
    for (int i = 0; i < dictFiles.length; i++) {
      countNotifier.value = i + 1;

      PlatformFile platformFile = dictFiles[i];
      File file = File(platformFile.path!);

      await appModel.importDictionary(
        progressNotifier: progressNotifier,
        file: file,
        cssFiles: cssFiles,
        onImportSuccess: () {
          if (!mounted) return;
          _selectedType = appModel.dictionaries.last.type;
          setState(() {});
        },
        onMemoryError: () {
          hadMemoryError = true;
        },
      );
    }

    if (Platform.isAndroid || Platform.isIOS) {
      await FilePicker.platform.clearTemporaryFiles();
    }

    if (mounted) {
      Navigator.pop(context);
    }

    if (hadMemoryError && mounted) {
      showAppDialog(
        context: context,
        builder: (context) => adaptiveAlertDialog(
          context: context,
          title: Text(t.low_memory_mode),
          content: Text(t.low_memory_mode_suggestion),
          actions: [
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_close),
            ),
          ],
        ),
      );
    }
  }

  Widget _buildDownloadRecommendedButton() {
    return TextButton(
      onPressed: _showDownloadSelectionDialog,
      child: Text(t.dict_download_browse),
    );
  }

  String _categoryLabel(DictionaryCategory cat) {
    switch (cat) {
      case DictionaryCategory.jaEn:
        return t.dict_category_ja_en;
      case DictionaryCategory.jaJa:
        return t.dict_category_ja_ja;
      case DictionaryCategory.jaOther:
        return t.dict_category_ja_other;
      case DictionaryCategory.grammar:
        return t.dict_category_grammar;
      case DictionaryCategory.kanji:
        return t.dict_category_kanji;
      case DictionaryCategory.frequency:
        return t.dict_category_frequency;
      case DictionaryCategory.names:
        return t.dict_category_names;
      case DictionaryCategory.supplementary:
        return t.dict_category_supplementary;
    }
  }

  bool _isDictInstalled(RecommendedDictionary rec) {
    return appModel.dictionaries.any((d) {
      final String base = DictionaryRepository.baseName(d.name);
      if (base == rec.matchPrefix) return true;
      if (d.name == rec.matchPrefix) return true;
      if (d.name.startsWith(rec.matchPrefix) &&
          d.name.substring(rec.matchPrefix.length).trimLeft().startsWith('[')) {
        return true;
      }
      return false;
    });
  }

  Set<int> _computeInstalledIndices(List<RecommendedDictionary> cat) {
    final Set<int> indices = {};
    for (int i = 0; i < cat.length; i++) {
      if (_isDictInstalled(cat[i])) indices.add(i);
    }
    return indices;
  }

  Future<void> _showDownloadSelectionDialog() async {
    if (_isDownloading) return;

    var selectedLang = appModel.appLocale.languageCode;
    if (!DictionaryDownloader.availableLanguages.containsKey(selectedLang)) {
      selectedLang = 'en';
    }
    var workingCatalog = DictionaryDownloader.catalogForLang(selectedLang);
    var installedIndices = _computeInstalledIndices(workingCatalog);
    var defaults = DictionaryDownloader.defaultSelectionForLang(
        selectedLang, workingCatalog);
    var checked = Set<int>.from(defaults.difference(installedIndices));
    final Set<DictionaryCategory> expandedCategories = <DictionaryCategory>{
      DictionaryCategory.jaEn,
      DictionaryCategory.jaJa,
    };

    final selected = await showAppDialog<Set<int>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final byCategory =
                DictionaryDownloader.byCategoryFrom(workingCatalog);
            final int downloadCount = checked.length;
            return adaptiveAlertDialog(
              context: ctx,
              title: Text(t.dict_download_select_title),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildLanguageSelector(
                        selectedLang: selectedLang,
                        onChanged: (String lang) {
                          setDialogState(() {
                            selectedLang = lang;
                            workingCatalog =
                                DictionaryDownloader.catalogForLang(lang);
                            installedIndices =
                                _computeInstalledIndices(workingCatalog);
                            defaults =
                                DictionaryDownloader.defaultSelectionForLang(
                                    lang, workingCatalog);
                            checked = Set<int>.from(
                                defaults.difference(installedIndices));
                          });
                        },
                      ),
                      const SizedBox(height: 8),
                      for (final cat in DictionaryCategory.values)
                        if (byCategory.containsKey(cat))
                          _buildCategoryTile(
                            cat: cat,
                            items: byCategory[cat]!,
                            catalog: workingCatalog,
                            checked: checked,
                            installedIndices: installedIndices,
                            expanded: expandedCategories.contains(cat),
                            onExpansionChanged: (bool expanded) {
                              setDialogState(() {
                                if (expanded) {
                                  expandedCategories.add(cat);
                                } else {
                                  expandedCategories.remove(cat);
                                }
                              });
                            },
                            onChanged: (int idx, bool val) {
                              setDialogState(() {
                                if (val) {
                                  checked.add(idx);
                                } else {
                                  checked.remove(idx);
                                }
                              });
                            },
                          ),
                    ],
                  ),
                ),
              ),
              actions: [
                adaptiveDialogAction(
                  context: ctx,
                  onPressed: () => Navigator.pop(ctx, null),
                  child: Text(t.dialog_cancel),
                ),
                adaptiveDialogAction(
                  context: ctx,
                  onPressed: downloadCount > 0
                      ? () => Navigator.pop(ctx, checked)
                      : null,
                  child: Text(
                      t.dict_download_button(count: downloadCount.toString())),
                ),
              ],
            );
          },
        );
      },
    );

    if (selected == null || selected.isEmpty || !mounted) return;

    final toDownload = selected.map((i) => workingCatalog[i]).toList();

    if (toDownload.isEmpty) return;
    await _downloadSelectedDictionaries(toDownload);
  }

  Widget _buildLanguageSelector({
    required String selectedLang,
    required ValueChanged<String> onChanged,
  }) {
    const Map<String, String> langs = DictionaryDownloader.availableLanguages;
    return Row(
      children: [
        Text(t.dict_download_language,
            style: TextStyle(fontSize: textTheme.bodyMedium?.fontSize)),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownMenu<String>(
            expandedInsets: EdgeInsets.zero,
            initialSelection: selectedLang,
            dropdownMenuEntries: langs.entries.map((e) {
              return DropdownMenuEntry(value: e.key, label: e.value);
            }).toList(),
            onSelected: (String? val) {
              if (val != null) onChanged(val);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryTile({
    required DictionaryCategory cat,
    required List<RecommendedDictionary> items,
    required List<RecommendedDictionary> catalog,
    required Set<int> checked,
    required Set<int> installedIndices,
    required bool expanded,
    required ValueChanged<bool> onExpansionChanged,
    required void Function(int idx, bool val) onChanged,
  }) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: HibikiCard(
        padding: EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HibikiListItem(
              minHeight: 52,
              title: Text(
                _categoryLabel(cat),
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              trailing: Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                color: tokens.surfaces.onVariant,
              ),
              onTap: () => onExpansionChanged(!expanded),
            ),
            if (expanded)
              for (final rec in items)
                _buildDictCheckbox(
                  rec: rec,
                  catalog: catalog,
                  checked: checked,
                  installedIndices: installedIndices,
                  onChanged: onChanged,
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildDictCheckbox({
    required RecommendedDictionary rec,
    required List<RecommendedDictionary> catalog,
    required Set<int> checked,
    required Set<int> installedIndices,
    required void Function(int idx, bool val) onChanged,
  }) {
    final int idx = catalog.indexOf(rec);
    final bool installed = installedIndices.contains(idx);
    final bool selected = checked.contains(idx);
    return HibikiListItem(
      minHeight: 68,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      selected: selected,
      onTap: () => onChanged(idx, !selected),
      leading: Checkbox(
        value: selected,
        onChanged: (bool? value) => onChanged(idx, value ?? false),
      ),
      title: Text(
        rec.name,
        style: textTheme.bodyMedium?.copyWith(
          color: installed ? theme.colorScheme.onSurfaceVariant : null,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
      subtitle: Text(
        installed
            ? '${t.dict_download_installed}  ${rec.sizeEstimate}'
            : '${rec.description}  ${rec.sizeEstimate}',
        style: textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Future<void> _downloadSelectedDictionaries(
    List<RecommendedDictionary> toDownload,
  ) async {
    _isDownloading = true;
    final ValueNotifier<String> progressNotifier =
        ValueNotifier<String>(t.import_start);
    final ValueNotifier<double> downloadProgress = ValueNotifier<double>(0);

    showAppDialog(
      barrierDismissible: false,
      context: context,
      builder: (ctx) => ValueListenableBuilder<String>(
        valueListenable: progressNotifier,
        builder: (ctx, String msg, __) => adaptiveAlertDialog(
          context: ctx,
          title: Text(msg),
          content: ValueListenableBuilder<double>(
            valueListenable: downloadProgress,
            builder: (_, double progress, __) =>
                LinearProgressIndicator(value: progress > 0 ? progress : null),
          ),
        ),
      ),
    );

    final Directory tempDir = Directory(
      path.join(appModel.dictionaryResourceDirectory.path, 'download_temp'),
    );

    int successCount = 0;
    String? lastError;

    try {
      for (final RecommendedDictionary rec in toDownload) {
        progressNotifier.value = t.dict_downloading(name: rec.name);
        downloadProgress.value = 0;

        try {
          final File zipFile = await DictionaryDownloader.download(
            url: rec.url,
            tempDir: tempDir,
            progressNotifier: downloadProgress,
          );

          progressNotifier.value = t.import_extract;
          await appModel.importDictionary(
            file: zipFile,
            progressNotifier: progressNotifier,
            onImportSuccess: () {},
          );
          successCount++;
        } catch (e) {
          lastError = '${rec.name}: $e';
        }
      }

      if (successCount == toDownload.length) {
        progressNotifier.value = t.dict_download_complete;
      } else if (successCount > 0) {
        progressNotifier.value =
            '$successCount/${toDownload.length} OK. Failed: $lastError';
      } else {
        progressNotifier.value = t.dict_download_failed(error: lastError ?? '');
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    } finally {
      progressNotifier.dispose();
      downloadProgress.dispose();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
      _isDownloading = false;
      if (mounted) {
        Navigator.pop(context);
        setState(() {});
      }
    }
  }

  static const _safChannel = HibikiChannels.saf;

  Future<void> _importDictionaryFolder() async {
    ValueNotifier<String> progressNotifier =
        ValueNotifier<String>(t.import_start);
    ValueNotifier<int?> countNotifier = ValueNotifier<int?>(null);
    ValueNotifier<int?> totalNotifier = ValueNotifier<int?>(null);
    progressNotifier.addListener(() {
      debugPrint('[Dictionary Import] ${progressNotifier.value}');
    });

    final tempDir = Directory(
      '${appModel.dictionaryResourceDirectory.path}/saf_import_temp',
    );

    if (!Platform.isAndroid) return;
    final result = await _safChannel.invokeMethod<String>(
      'pickAndCopyDirectory',
      {'destPath': tempDir.path},
    );
    if (result == null) return;

    if (mounted) {
      showAppDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => DictionaryDialogImportPage(
          progressNotifier: progressNotifier,
          countNotifier: countNotifier,
          totalNotifier: totalNotifier,
        ),
      );
    }

    bool hadMemoryError = false;

    try {
      await appModel.importDictionaryFromDirectory(
        directory: tempDir,
        progressNotifier: progressNotifier,
        countNotifier: countNotifier,
        totalNotifier: totalNotifier,
        onImportSuccess: () {
          if (!mounted) return;
          _selectedType = appModel.dictionaries.last.type;
          setState(() {});
        },
        onMemoryError: () {
          hadMemoryError = true;
        },
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('DictionaryDialog.folderImport', e, stack);
      debugPrint('[Dictionary Import] folder import error: $e');
      progressNotifier.value = '$e';
      await Future.delayed(const Duration(seconds: 3));
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }

    if (mounted) {
      Navigator.pop(context);
    }

    if (hadMemoryError && mounted) {
      showAppDialog(
        context: context,
        builder: (context) => adaptiveAlertDialog(
          context: context,
          title: Text(t.low_memory_mode),
          content: Text(t.low_memory_mode_suggestion),
          actions: [
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_close),
            ),
          ],
        ),
      );
    }
  }

  Widget buildContent() {
    final List<Dictionary> selectedDictionaries =
        _dictionariesForType(_selectedType);
    if (appModel.dictionaries.isEmpty) return buildEmptyMessage();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(
          _labelForType(_selectedType),
          padding: const EdgeInsets.only(bottom: 6),
        ),
        if (selectedDictionaries.isEmpty)
          _buildEmptyCategoryRow()
        else
          _buildDictionaryList(selectedDictionaries),
      ],
    );
  }

  Widget _buildCategorySelector() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: adaptiveSegmentedButton<DictionaryType>(
                context: context,
                segments: [
                  ButtonSegment<DictionaryType>(
                    value: DictionaryType.term,
                    label: Text(t.dictionary_type_term),
                    tooltip: t.dictionary_type_term,
                  ),
                  ButtonSegment<DictionaryType>(
                    value: DictionaryType.kanji,
                    label: Text(t.dictionary_section_kanji),
                    tooltip: t.dictionary_section_kanji,
                  ),
                  ButtonSegment<DictionaryType>(
                    value: DictionaryType.frequency,
                    label: Text(t.dictionary_type_frequency),
                    tooltip: t.dictionary_type_frequency,
                  ),
                  ButtonSegment<DictionaryType>(
                    value: DictionaryType.pitch,
                    label: Text(t.dictionary_type_pitch),
                    tooltip: t.dictionary_type_pitch,
                  ),
                ],
                selected: {_selectedType},
                onSelectionChanged: (Set<DictionaryType> selection) {
                  if (selection.isEmpty) return;
                  setState(() => _selectedType = selection.first);
                },
                style: kSettingsSegmentedStyle,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget buildEmptyMessage() {
    return AdaptiveSettingsSection(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: HibikiPlaceholderMessage(
            icon: DictionaryMediaType.instance.outlinedIcon,
            message: t.dictionaries_menu_empty,
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyCategoryRow() {
    return HibikiCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
      child: Text(
        t.dictionaries_menu_empty,
        style: textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildDictionaryTile({
    required Dictionary dictionary,
    required int index,
    required Key key,
    required bool isLast,
  }) {
    DictionaryFormat dictionaryFormat =
        appModel.dictionaryFormats[dictionary.formatKey]!;
    final bool enabled = !dictionary.isHidden(appModel.targetLanguage);
    final ColorScheme scheme = theme.colorScheme;
    final Color titleColor =
        enabled ? scheme.onSurface : scheme.onSurfaceVariant;
    final Color subtitleColor = scheme.onSurfaceVariant;
    return Padding(
      key: key,
      padding: EdgeInsets.only(bottom: isLast ? 0 : 10),
      child: HibikiCard(
        padding: EdgeInsets.zero,
        child: HibikiListItem(
          minHeight: 70,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          leading: ReorderableDragStartListener(
            index: index,
            child: Icon(
              Icons.drag_handle,
              color: scheme.onSurfaceVariant,
            ),
          ),
          title: Text(
            dictionary.name,
            style: textTheme.bodyLarge?.copyWith(
              color: titleColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            _subtitleForDictionary(dictionary, dictionaryFormat),
            style: textTheme.bodySmall?.copyWith(
              color: subtitleColor,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              buildDictionaryTileTrailing(dictionary),
              const SizedBox(width: 4),
              adaptiveSwitch(
                context: context,
                value: enabled,
                onChanged: (_) => _toggleDictionaryHidden(dictionary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDictionaryList(List<Dictionary> dictionaries) {
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: dictionaries.length,
      itemBuilder: (context, index) {
        Dictionary dictionary = dictionaries[index];
        return _buildDictionaryTile(
          dictionary: dictionary,
          index: index,
          key: ValueKey(dictionary.name),
          isLast: index == dictionaries.length - 1,
        );
      },
      onReorder: (oldIndex, newIndex) {
        if (newIndex > oldIndex) newIndex--;
        List<Dictionary> cloneDictionaries = List.from(dictionaries);

        Dictionary item = cloneDictionaries.removeAt(oldIndex);
        cloneDictionaries.insert(newIndex, item);

        for (int index = 0; index < cloneDictionaries.length; index++) {
          final Dictionary dictionary = cloneDictionaries[index];
          dictionary.order = index;
        }

        appModel.updateDictionaryOrder(cloneDictionaries);
        setState(() {});
      },
    );
  }

  String _subtitleForDictionary(
    Dictionary dictionary,
    DictionaryFormat dictionaryFormat,
  ) {
    final String revision = dictionary.metadata['revision'] ??
        dictionary.metadata['version'] ??
        dictionary.metadata['formatVersion'] ??
        '';
    if (revision.isNotEmpty) return revision;
    return dictionaryFormat.name;
  }

  List<Dictionary> _dictionariesForType(DictionaryType type) {
    return switch (type) {
      DictionaryType.term => appModel.termDictionaries,
      DictionaryType.kanji => appModel.kanjiDictionaries,
      DictionaryType.frequency => appModel.freqDictionaries,
      DictionaryType.pitch => appModel.pitchDictionaries,
    };
  }

  String _labelForType(DictionaryType type) {
    return switch (type) {
      DictionaryType.term => t.dictionary_section_term,
      DictionaryType.kanji => t.dictionary_section_kanji,
      DictionaryType.frequency => t.dictionary_section_frequency,
      DictionaryType.pitch => t.dictionary_section_pitch,
    };
  }

  void _toggleDictionaryHidden(Dictionary dictionary) {
    appModel.toggleDictionaryHidden(dictionary);
    setState(() {});
  }

  Widget buildDictionaryTileTrailing(Dictionary dictionary) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Material(
        color: Colors.transparent,
        child: HibikiOverflowMenu<VoidCallback>(
          splashRadius: 20,
          padding: EdgeInsets.zero,
          tooltip: t.show_options,
          onSelected: (value) => value(),
          items: getMenuItems(dictionary),
          iconSize: 24,
        ),
      ),
    );
  }

  PopupMenuItem<VoidCallback> buildPopupItem({
    required String label,
    required Function() action,
    IconData? icon,
    Color? color,
  }) {
    return PopupMenuItem<VoidCallback>(
      value: action,
      child: Row(
        children: [
          if (icon != null)
            Icon(
              icon,
              size: textTheme.bodyMedium?.fontSize,
              color: color,
            ),
          if (icon != null) const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(color: color),
          ),
        ],
      ),
    );
  }

  void openDictionaryOptionsMenu(
      {required TapDownDetails details, required Dictionary dictionary}) async {
    RelativeRect position = RelativeRect.fromLTRB(
        details.globalPosition.dx, details.globalPosition.dy, 0, 0);
    Function()? selectedAction = await showMenu(
      context: context,
      position: position,
      items: getMenuItems(dictionary),
    );

    selectedAction?.call();
  }

  List<PopupMenuItem<VoidCallback>> getMenuItems(Dictionary dictionary) {
    return [
      buildPopupItem(
        label: dictionary.isHidden(appModel.targetLanguage)
            ? t.options_show
            : t.options_hide,
        icon: dictionary.isHidden(appModel.targetLanguage)
            ? Icons.check_circle_outline
            : Icons.block,
        action: () {
          _toggleDictionaryHidden(dictionary);
        },
      ),
      buildPopupItem(
        label: dictionary.isCollapsed(appModel.targetLanguage)
            ? t.options_expand
            : t.options_collapse,
        icon: dictionary.isCollapsed(appModel.targetLanguage)
            ? Icons.unfold_more
            : Icons.unfold_less,
        action: () {
          appModel.toggleDictionaryCollapsed(dictionary);
          setState(() {});
        },
      ),
      buildPopupItem(
        label: t.custom_dict_css,
        icon: Icons.code_outlined,
        action: () {
          showAppDialog(
            context: context,
            builder: (_) => DictCssEditorDialog(
              initialDictionaryName: dictionary.name,
            ),
          );
        },
      ),
      buildPopupItem(
        label: t.options_delete,
        icon: Icons.delete_outline,
        action: () {
          showDictionaryDeleteDialog(dictionary);
        },
        color: theme.colorScheme.primary,
      ),
    ];
  }
}
