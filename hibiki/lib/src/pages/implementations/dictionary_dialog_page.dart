import 'dart:io';

import 'package:change_notifier_builder/change_notifier_builder.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/utils.dart';
import 'package:collection/collection.dart';

/// The content of the dialog used for managing dictionaries.
class DictionaryDialogPage extends BasePage {
  /// Create an instance of this page.
  const DictionaryDialogPage({super.key});

  @override
  BasePageState createState() => _DictionaryDialogPageState();
}

class _DictionaryDialogPageState extends BasePageState with ChangeNotifier {
  int? _selectedOrder;
  bool _isDownloading = false;
  final ScrollController _contentScrollController = ScrollController();

  @override
  void dispose() {
    _contentScrollController.dispose();
    for (final notifier in _notifiersByDictionary.values) {
      notifier.dispose();
    }
    _notifiersByDictionary.clear();
    _formatNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return adaptiveAlertDialog(
      context: context,
      contentPadding: MediaQuery.of(context).orientation == Orientation.portrait
          ? Spacing.of(context).insets.exceptBottom.big
          : Spacing.of(context).insets.exceptBottom.normal.copyWith(
                left: Spacing.of(context).spaces.semiBig,
                right: Spacing.of(context).spaces.semiBig,
              ),
      actionsPadding: Spacing.of(context).insets.exceptBottom.normal.copyWith(
            left: Spacing.of(context).spaces.normal,
            right: Spacing.of(context).spaces.normal,
            bottom: Spacing.of(context).spaces.normal,
            top: Spacing.of(context).spaces.extraSmall,
          ),
      content: buildContent(),
      actions: actions,
    );
  }

  List<Widget> get actions => [
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Flexible(child: _buildDownloadRecommendedButton()),
                const SizedBox(width: 8),
                Flexible(child: buildImportFolderButton()),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Flexible(child: buildImportButton()),
                const SizedBox(width: 8),
                Flexible(child: buildClearButton()),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Flexible(child: buildCloseButton()),
              ],
            ),
          ],
        ),
      ];

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
              _selectedOrder = -1;
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
              _selectedOrder = -1;
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

    await FilePicker.platform.clearTemporaryFiles();

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
          _selectedOrder = appModel.dictionaries.last.order;
          setState(() {});
        },
        onMemoryError: () {
          hadMemoryError = true;
        },
      );
    }

    await FilePicker.platform.clearTemporaryFiles();

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
    return appModel.dictionaries.any(
      (d) => d.name.startsWith(rec.matchPrefix),
    );
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

    final selected = await showAppDialog<Set<int>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final byCategory =
                DictionaryDownloader.byCategoryFrom(workingCatalog);
            final int downloadCount =
                checked.where((i) => !installedIndices.contains(i)).length;
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
                            initiallyExpanded: cat == DictionaryCategory.jaEn ||
                                cat == DictionaryCategory.jaJa,
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

    final toDownload = selected
        .where((i) => !installedIndices.contains(i))
        .map((i) => workingCatalog[i])
        .toList();

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
    required bool initiallyExpanded,
    required void Function(int idx, bool val) onChanged,
  }) {
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: Text(_categoryLabel(cat),
            style: TextStyle(fontSize: textTheme.titleSmall?.fontSize)),
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        initiallyExpanded: initiallyExpanded,
        children: [
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
    );
  }

  Widget _buildDictCheckbox({
    required RecommendedDictionary rec,
    required List<RecommendedDictionary> catalog,
    required Set<int> checked,
    required Set<int> installedIndices,
    required void Function(int idx, bool val) onChanged,
  }) {
    final idx = catalog.indexOf(rec);
    final installed = installedIndices.contains(idx);
    return CheckboxListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      value: installed || checked.contains(idx),
      onChanged: installed ? null : (bool? val) => onChanged(idx, val ?? false),
      title: Text(
        rec.name,
        style: TextStyle(
          fontSize: textTheme.bodyMedium?.fontSize,
          color: installed ? theme.colorScheme.onSurfaceVariant : null,
        ),
      ),
      subtitle: Text(
        installed
            ? t.dict_download_installed
            : '${rec.description}  ${rec.sizeEstimate}',
        style: TextStyle(
          fontSize: textTheme.bodySmall?.fontSize,
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

  Widget buildImportButton() {
    return TextButton(
      onPressed: _importDictionaryFiles,
      child: Text(t.dialog_import_dictionary),
    );
  }

  static const _safChannel = HibikiChannels.saf;

  Widget buildImportFolderButton() {
    return TextButton(
      child: Text(t.dialog_import_folder),
      onPressed: () async {
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
              _selectedOrder = appModel.dictionaries.last.order;
              setState(() {});
            },
            onMemoryError: () {
              hadMemoryError = true;
            },
          );
        } catch (e, stack) {
          ErrorLogService.instance
              .log('DictionaryDialog.folderImport', e, stack);
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
      },
    );
  }

  Widget buildClearButton() {
    return TextButton(
      onPressed: showDictionaryClearDialog,
      child: Text(
        t.dialog_clear_all_dictionaries,
        style: TextStyle(
          color: Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }

  Widget buildCloseButton() {
    return TextButton(
      child: Text(t.dialog_close),
      onPressed: () => Navigator.pop(context),
    );
  }

  Widget buildContent() {
    final termDicts = appModel.termDictionaries;
    final freqDicts = appModel.freqDictionaries;
    final pitchDicts = appModel.pitchDictionaries;
    final kanjiDicts = appModel.kanjiDictionaries;
    final allEmpty = termDicts.isEmpty &&
        freqDicts.isEmpty &&
        pitchDicts.isEmpty &&
        kanjiDicts.isEmpty;
    return SizedBox(
      width: double.maxFinite,
      child: RawScrollbar(
        thickness: 3,
        thumbVisibility: true,
        controller: _contentScrollController,
        child: Padding(
          padding: _contentScrollController.hasClients
              ? Spacing.of(context).insets.onlyRight.normal
              : EdgeInsets.zero,
          child: SingleChildScrollView(
            controller: _contentScrollController,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (allEmpty)
                  buildEmptyMessage()
                else ...[
                  _buildSection(
                    title: t.dictionary_section_term,
                    dictionaries: termDicts,
                  ),
                  _buildSection(
                    title: t.dictionary_section_kanji,
                    dictionaries: kanjiDicts,
                  ),
                  _buildSection(
                    title: t.dictionary_section_frequency,
                    dictionaries: freqDicts,
                  ),
                  _buildSection(
                    title: t.dictionary_section_pitch,
                    dictionaries: pitchDicts,
                  ),
                ],
                const HibikiDivider(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required List<Dictionary> dictionaries,
  }) {
    if (dictionaries.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: textTheme.titleSmall?.fontSize,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        buildDictionaryList(dictionaries),
      ],
    );
  }

  Widget buildEmptyMessage() {
    return Padding(
      padding: EdgeInsets.only(
        bottom: Spacing.of(context).spaces.normal,
      ),
      child: HibikiPlaceholderMessage(
        icon: DictionaryMediaType.instance.outlinedIcon,
        message: t.dictionaries_menu_empty,
      ),
    );
  }

  final Map<String, ValueNotifier<bool>> _notifiersByDictionary = {};

  Widget buildDictionaryList(List<Dictionary> dictionaries) {
    _selectedOrder ??= dictionaries.firstOrNull?.order;

    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: dictionaries.length,
      itemBuilder: (context, index) {
        Dictionary dictionary = dictionaries[index];
        _notifiersByDictionary.putIfAbsent(
          dictionary.name,
          () => ValueNotifier<bool>(dictionary.order == _selectedOrder),
        );
        return buildDictionaryTile(
          dictionary,
          _notifiersByDictionary[dictionary.name]!,
        );
      },
      onReorder: (oldIndex, newIndex) {
        if (newIndex > oldIndex) newIndex--;
        List<Dictionary> cloneDictionaries = List.from(dictionaries);

        Dictionary item = cloneDictionaries.removeAt(oldIndex);
        cloneDictionaries.insert(newIndex, item);

        cloneDictionaries.forEachIndexed((index, dictionary) {
          dictionary.order = index;
        });

        _selectedOrder = newIndex;

        appModel.updateDictionaryOrder(cloneDictionaries);
        setState(() {});
      },
    );
  }

  Icon getIcon({
    required Dictionary dictionary,
    required DictionaryFormat dictionaryFormat,
  }) {
    if (dictionary.isHidden(appModel.targetLanguage)) {
      return Icon(
        Icons.block,
        size: textTheme.titleLarge?.fontSize,
        color: theme.colorScheme.onSurfaceVariant,
      );
    } else {
      return Icon(
        dictionaryFormat.icon,
        size: textTheme.titleLarge?.fontSize,
      );
    }
  }

  Widget buildDictionaryTile(
    Dictionary dictionary,
    ValueNotifier<bool> notifier,
  ) {
    DictionaryFormat dictionaryFormat =
        appModel.dictionaryFormats[dictionary.formatKey]!;

    return ValueListenableBuilder<bool>(
      key: ValueKey(dictionary.name),
      valueListenable: notifier,
      builder: (context, value, _) {
        return Material(
          type: MaterialType.transparency,
          child: ListTile(
            selected: _selectedOrder == dictionary.order,
            leading: getIcon(
              dictionary: dictionary,
              dictionaryFormat: dictionaryFormat,
            ),
            title: Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      HibikiMarquee(
                        text: dictionary.name,
                        style: TextStyle(
                          fontSize: textTheme.bodyMedium?.fontSize,
                          color: dictionary.isHidden(appModel.targetLanguage)
                              ? theme.colorScheme.onSurfaceVariant
                              : null,
                        ),
                      ),
                      HibikiMarquee(
                        text: dictionaryFormat.name,
                        style: TextStyle(
                          fontSize: textTheme.bodySmall?.fontSize,
                          color: dictionary.isHidden(appModel.targetLanguage)
                              ? theme.colorScheme.onSurfaceVariant
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
                const Space.normal(),
                buildDictionaryTileTrailing(dictionary)
              ],
            ),
            onTap: () {
              _selectedOrder = dictionary.order;

              for (int i = 0; i < _notifiersByDictionary.length; i++) {
                _notifiersByDictionary.entries.elementAt(i).value.value = false;
              }
              notifier.value = true;
            },
          ),
        );
      },
    );
  }

  Widget buildDictionaryTileTrailing(Dictionary dictionary) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Material(
        color: Colors.transparent,
        child: PopupMenuButton<VoidCallback>(
          splashRadius: 20,
          padding: EdgeInsets.zero,
          tooltip: t.show_options,
          color: Theme.of(context).popupMenuTheme.color,
          onSelected: (value) => value(),
          itemBuilder: (context) => getMenuItems(dictionary),
          child: Container(
            height: 30,
            width: 30,
            alignment: Alignment.center,
            child: Icon(
              Icons.more_vert,
              color: theme.iconTheme.color,
              size: 24,
            ),
          ),
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
          if (icon != null) const Space.normal(),
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
          appModel.toggleDictionaryHidden(dictionary);
          final notifier = _notifiersByDictionary[dictionary.name];
          if (notifier != null) {
            notifier.value = !notifier.value;
            notifier.value = !notifier.value;
          }
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
          final notifier = _notifiersByDictionary[dictionary.name];
          if (notifier != null) {
            notifier.value = !notifier.value;
            notifier.value = !notifier.value;
          }
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

  final _formatNotifier = ChangeNotifier();

  Widget buildImportDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: Spacing.of(context).insets.onlyLeft.small,
          child: Text(
            t.import_format,
            style: TextStyle(
              fontSize: 10,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Stack(
          alignment: Alignment.bottomCenter,
          children: [
            ChangeNotifierBuilder(
              notifier: _formatNotifier,
              builder: (_, __, ___) => HibikiDropdown<DictionaryFormat>(
                options: appModel.dictionaryFormats.values.toList(),
                initialOption: appModel.lastSelectedDictionaryFormat,
                generateLabel: (format) => format.name,
                onChanged: (format) {
                  appModel.setLastSelectedDictionaryFormat(format!);
                  _formatNotifier.notifyListeners();
                },
              ),
            ),
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                border: Border.fromBorderSide(
                  BorderSide(
                    width: 0.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
