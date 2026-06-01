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
    final bool compact = MediaQuery.sizeOf(context).width < 480;
    return AdaptiveSettingsScaffold(
      title: Text(t.dictionaries),
      actions: compact ? _buildMobilePageActions() : _buildDesktopPageActions(),
      children: [
        compact ? _buildDictionaryTypePicker() : _buildCategorySelector(),
        buildContent(),
      ],
    );
  }

  List<Widget> _buildDesktopPageActions() {
    return [
      IconButton(
        tooltip: t.dict_download_browse,
        icon: const Icon(Icons.cloud_download_outlined),
        onPressed: _showDownloadSelectionDialog,
      ),
      if (!Platform.isIOS)
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

  List<Widget> _buildMobilePageActions() {
    return [
      HibikiOverflowMenu<VoidCallback>(
        tooltip: t.show_options,
        icon: Icons.more_vert,
        onSelected: (VoidCallback action) => action(),
        items: [
          buildPopupItem(
            label: t.dict_download_browse,
            icon: Icons.cloud_download_outlined,
            action: _showDownloadSelectionDialog,
          ),
          if (!Platform.isIOS)
            buildPopupItem(
              label: t.dialog_import_folder,
              icon: Icons.drive_folder_upload_outlined,
              action: _importDictionaryFolder,
            ),
          buildPopupItem(
            label: t.dialog_import_dictionary,
            icon: Icons.upload_file_outlined,
            action: _importDictionaryFiles,
          ),
          buildPopupItem(
            label: t.dialog_clear_all_dictionaries,
            icon: Icons.delete_sweep_outlined,
            color: theme.colorScheme.error,
            action: showDictionaryClearDialog,
          ),
        ],
      ),
    ];
  }

  Future<void> showDictionaryClearDialog() async {
    final Widget dialog = DictionaryConfirmationDialog(
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
      builder: (context) => dialog,
    );
  }

  Future<void> showDictionaryDeleteDialog(Dictionary dictionary) async {
    final Widget dialog = DictionaryConfirmationDialog(
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
      builder: (context) => dialog,
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
        builder: (context) => const DictionaryLowMemoryDialog(),
      );
    }
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

  // HBK-AUDIT-110: build a rec->index map once per catalog so checkbox tiles do
  // an O(1) lookup instead of List.indexOf (O(n)) per checkbox per rebuild.
  Map<RecommendedDictionary, int> _computeRecIndices(
      List<RecommendedDictionary> cat) {
    final Map<RecommendedDictionary, int> indices =
        <RecommendedDictionary, int>{};
    for (int i = 0; i < cat.length; i++) {
      indices[cat[i]] = i;
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
    // HBK-AUDIT-110: byCategory and the rec->index map depend only on
    // workingCatalog, not on checkbox toggles. Compute them here (and again
    // only when the language changes) so per-toggle setDialogState rebuilds
    // don't re-derive the grouping or run O(n) catalog.indexOf per checkbox.
    var byCategory = DictionaryDownloader.byCategoryFrom(workingCatalog);
    var recIndex = _computeRecIndices(workingCatalog);
    final Set<DictionaryCategory> expandedCategories = <DictionaryCategory>{
      DictionaryCategory.jaEn,
      DictionaryCategory.jaJa,
    };

    final selected = await showAppDialog<Set<int>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final int downloadCount = checked.length;
            final HibikiDesignTokens tokens = HibikiDesignTokens.of(ctx);
            return DictionaryDownloadSelectionDialogFrame(
              content: SizedBox(
                width: double.maxFinite,
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
                          // HBK-AUDIT-110: recompute the catalog-derived
                          // structures only when the language (hence catalog)
                          // actually changes.
                          byCategory = DictionaryDownloader.byCategoryFrom(
                              workingCatalog);
                          recIndex = _computeRecIndices(workingCatalog);
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
                    SizedBox(height: tokens.spacing.gap),
                    for (final cat in DictionaryCategory.values)
                      if (byCategory.containsKey(cat))
                        _buildCategoryTile(
                          cat: cat,
                          items: byCategory[cat]!,
                          recIndex: recIndex,
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Row(
      children: [
        Text(t.dict_download_language, style: tokens.type.controlLabel),
        SizedBox(width: tokens.spacing.gap),
        Expanded(
          child: GamepadMenuDropdown<String>(
            selected: selectedLang,
            onChanged: onChanged,
            entries: <GamepadDropdownEntry<String>>[
              for (final MapEntry<String, String> e in langs.entries)
                (value: e.key, label: e.value),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryTile({
    required DictionaryCategory cat,
    required List<RecommendedDictionary> items,
    required Map<RecommendedDictionary, int> recIndex,
    required Set<int> checked,
    required Set<int> installedIndices,
    required bool expanded,
    required ValueChanged<bool> onExpansionChanged,
    required void Function(int idx, bool val) onChanged,
  }) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
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
                  recIndex: recIndex,
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
    required Map<RecommendedDictionary, int> recIndex,
    required Set<int> checked,
    required Set<int> installedIndices,
    required void Function(int idx, bool val) onChanged,
  }) {
    // HBK-AUDIT-110: O(1) lookup from a precomputed map instead of the former
    // per-checkbox catalog.indexOf(rec) linear scan on every rebuild.
    final int idx = recIndex[rec] ?? -1;
    final bool installed = installedIndices.contains(idx);
    final bool selected = checked.contains(idx);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiListItem(
      minHeight: 68,
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.rowHorizontal - tokens.spacing.gap / 2,
        vertical: tokens.spacing.gap,
      ),
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
        builder: (ctx, String msg, __) => DictionaryDownloadProgressDialog(
          message: msg,
          progressListenable: downloadProgress,
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

  Future<({Directory directory, Directory? cleanupDir})?>
      _pickDictionaryImportDirectory() async {
    if (Platform.isAndroid) {
      final Directory tempDir = Directory(
        '${appModel.dictionaryResourceDirectory.path}/saf_import_temp',
      );
      final String? result = await _safChannel.invokeMethod<String>(
        'pickAndCopyDirectory',
        {'destPath': tempDir.path},
      );
      if (result == null) return null;
      return (directory: tempDir, cleanupDir: tempDir);
    }

    final String? selectedPath = await FilePicker.platform.getDirectoryPath();
    if (selectedPath == null) return null;
    return (directory: Directory(selectedPath), cleanupDir: null);
  }

  Future<void> _importDictionaryFolder() async {
    ValueNotifier<String> progressNotifier =
        ValueNotifier<String>(t.import_start);
    ValueNotifier<int?> countNotifier = ValueNotifier<int?>(null);
    ValueNotifier<int?> totalNotifier = ValueNotifier<int?>(null);
    progressNotifier.addListener(() {
      debugPrint('[Dictionary Import] ${progressNotifier.value}');
    });

    final ({Directory? cleanupDir, Directory directory})? pickedDirectory =
        await _pickDictionaryImportDirectory();
    if (pickedDirectory == null) return;

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
        directory: pickedDirectory.directory,
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
      final Directory? cleanupDir = pickedDirectory.cleanupDir;
      if (cleanupDir != null && cleanupDir.existsSync()) {
        cleanupDir.deleteSync(recursive: true);
      }
    }

    if (mounted) {
      Navigator.pop(context);
    }

    if (hadMemoryError && mounted) {
      showAppDialog(
        context: context,
        builder: (context) => const DictionaryLowMemoryDialog(),
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(
        bottom: tokens.spacing.gap + tokens.spacing.gap / 2,
      ),
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

  Widget _buildDictionaryTypePicker() {
    return AdaptiveSettingsSection(
      children: [
        AdaptiveSettingsPickerRow<DictionaryType>(
          title: t.dictionaries,
          icon: Icons.menu_book_outlined,
          controlBelow: true,
          materialWidth: double.infinity,
          selected: _selectedType,
          options: [
            AdaptiveSettingsPickerOption<DictionaryType>(
              value: DictionaryType.term,
              label: t.dictionary_type_term,
            ),
            AdaptiveSettingsPickerOption<DictionaryType>(
              value: DictionaryType.kanji,
              label: t.dictionary_section_kanji,
            ),
            AdaptiveSettingsPickerOption<DictionaryType>(
              value: DictionaryType.frequency,
              label: t.dictionary_type_frequency,
            ),
            AdaptiveSettingsPickerOption<DictionaryType>(
              value: DictionaryType.pitch,
              label: t.dictionary_type_pitch,
            ),
          ],
          onChanged: (DictionaryType value) {
            setState(() => _selectedType = value);
          },
        ),
      ],
    );
  }

  Widget buildEmptyMessage() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return AdaptiveSettingsSection(
      children: [
        Padding(
          padding: EdgeInsets.symmetric(
            vertical: tokens.spacing.card + tokens.spacing.gap,
          ),
          child: HibikiPlaceholderMessage(
            icon: DictionaryMediaType.instance.outlinedIcon,
            message: t.dictionaries_menu_empty,
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyCategoryRow() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiCard(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.gap + tokens.spacing.gap / 2,
        vertical: tokens.spacing.card + tokens.spacing.gap / 4,
      ),
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
    required VoidCallback onMoveUp,
    required VoidCallback onMoveDown,
  }) {
    DictionaryFormat dictionaryFormat =
        appModel.dictionaryFormats[dictionary.formatKey]!;
    final bool enabled = !dictionary.isHidden(appModel.targetLanguage);
    final ColorScheme scheme = theme.colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color titleColor =
        enabled ? scheme.onSurface : scheme.onSurfaceVariant;
    final Color subtitleColor = scheme.onSurfaceVariant;
    return Padding(
      key: key,
      padding: EdgeInsets.only(bottom: isLast ? 0 : tokens.spacing.rowVertical),
      child: HibikiCard(
        padding: EdgeInsets.zero,
        child: HibikiListItem(
          minHeight: 70,
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.rowHorizontal - tokens.spacing.gap / 2,
            vertical: tokens.spacing.rowVertical,
          ),
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
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall?.copyWith(
              color: subtitleColor,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Gamepad/keyboard reorder equivalent for the drag handle.
              HibikiIconButton(
                icon: Icons.keyboard_arrow_up,
                size: 18,
                tooltip: t.move_up,
                enabled: index > 0,
                onTap: onMoveUp,
              ),
              HibikiIconButton(
                icon: Icons.keyboard_arrow_down,
                size: 18,
                tooltip: t.move_down,
                enabled: !isLast,
                onTap: onMoveDown,
              ),
              _buildDictionaryVisibilityButton(dictionary, enabled),
              SizedBox(width: tokens.spacing.gap / 2),
              buildDictionaryTileTrailing(dictionary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDictionaryVisibilityButton(
    Dictionary dictionary,
    bool enabled,
  ) {
    final ColorScheme scheme = theme.colorScheme;
    final String tooltip = enabled ? t.options_hide : t.options_show;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        toggled: enabled,
        label: tooltip,
        child: Switch(
          value: enabled,
          onChanged: (_) => _toggleDictionaryHidden(dictionary),
          activeThumbColor: scheme.onPrimaryContainer,
          activeTrackColor: scheme.primaryContainer,
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
          onMoveUp: () => _reorderDictionaries(index, index - 1, dictionaries),
          onMoveDown: () =>
              _reorderDictionaries(index, index + 2, dictionaries),
        );
      },
      onReorder: (oldIndex, newIndex) =>
          _reorderDictionaries(oldIndex, newIndex, dictionaries),
    );
  }

  void _reorderDictionaries(
    int oldIndex,
    int newIndex,
    List<Dictionary> dictionaries,
  ) {
    if (newIndex > oldIndex) newIndex--;
    final List<Dictionary> cloneDictionaries = List.from(dictionaries);

    final Dictionary item = cloneDictionaries.removeAt(oldIndex);
    cloneDictionaries.insert(newIndex, item);

    for (int i = 0; i < cloneDictionaries.length; i++) {
      cloneDictionaries[i].order = i;
    }

    appModel.updateDictionaryOrder(cloneDictionaries);
    setState(() {});
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
    return HibikiOverflowMenu<VoidCallback>(
      splashRadius: 20,
      padding: EdgeInsets.zero,
      tooltip: t.show_options,
      onSelected: (value) => value(),
      items: getMenuItems(dictionary),
      iconSize: 24,
    );
  }

  HibikiPopupMenuItem<VoidCallback> buildPopupItem({
    required String label,
    required VoidCallback action,
    IconData? icon,
    Color? color,
  }) {
    return HibikiPopupMenuItem<VoidCallback>(
      label: label,
      value: action,
      icon: icon,
      color: color,
    );
  }

  // HBK-AUDIT-111: removed the dead openDictionaryOptionsMenu (an unused
  // showMenu-based duplicate of the live overflow-menu path). The dictionary
  // tile opens this same getMenuItems list via buildDictionaryTileTrailing()
  // / HibikiOverflowMenu; the showMenu variant was never wired to any gesture.

  List<HibikiPopupMenuItem<VoidCallback>> getMenuItems(Dictionary dictionary) {
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

@visibleForTesting
class DictionaryConfirmationDialog extends StatelessWidget {
  const DictionaryConfirmationDialog({
    required this.title,
    required this.content,
    required this.actions,
    super.key,
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 440,
      maxHeightFactor: 0.78,
      child: HibikiModalSheetFrame(
        leadingIcon: Icons.warning_amber_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.card,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            DefaultTextStyle.merge(
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tokens.type.listTitle.copyWith(
                fontWeight: FontWeight.w600,
              ),
              child: title,
            ),
            SizedBox(height: tokens.spacing.gap),
            DefaultTextStyle.merge(
              style: tokens.type.listSubtitle,
              child: content,
            ),
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: actions,
        ),
      ),
    );
  }
}

@visibleForTesting
class DictionaryDownloadSelectionDialogFrame extends StatelessWidget {
  const DictionaryDownloadSelectionDialogFrame({
    required this.content,
    required this.actions,
    super.key,
  });

  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 560,
      maxHeightFactor: 0.86,
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.dict_download_select_title,
        leadingIcon: Icons.cloud_download_outlined,
        scrollable: true,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: content,
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: actions,
        ),
      ),
    );
  }
}

@visibleForTesting
class DictionaryDownloadProgressDialog extends StatelessWidget {
  const DictionaryDownloadProgressDialog({
    required this.message,
    required this.progressListenable,
    super.key,
  });

  final String message;
  final ValueNotifier<double> progressListenable;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.72,
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: message,
        leadingIcon: Icons.cloud_download_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: ValueListenableBuilder<double>(
          valueListenable: progressListenable,
          builder: (_, double progress, __) => LinearProgressIndicator(
            value: progress > 0 ? progress : null,
          ),
        ),
      ),
    );
  }
}

@visibleForTesting
class DictionaryLowMemoryDialog extends StatelessWidget {
  const DictionaryLowMemoryDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.72,
      child: HibikiModalSheetFrame(
        title: t.low_memory_mode,
        leadingIcon: Icons.memory_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Text(
          t.low_memory_mode_suggestion,
          style: tokens.type.listSubtitle,
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_close),
            ),
          ],
        ),
      ),
    );
  }
}
