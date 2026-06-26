import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';
import 'package:hibiki/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:hibiki/src/models/dictionary_import_manager.dart';
import 'package:hibiki/src/models/dictionary_repository.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/utils.dart';

/// Page used for managing installed dictionaries.
class DictionaryDialogPage extends BasePage {
  /// Create an instance of this page.
  const DictionaryDialogPage({
    super.key,
    this.initialImportPaths = const <String>[],
  });

  /// Dictionary package paths to import as soon as the page is visible. CSS
  /// attachment paths may be included after at least one dictionary package.
  final List<String> initialImportPaths;

  @override
  BasePageState createState() => _DictionaryDialogPageState();
}

class _DictionaryDialogPageState extends BasePageState {
  DictionaryType _selectedType = DictionaryType.term;
  bool _isDownloading = false;

  @override
  void initState() {
    super.initState();
    if (widget is DictionaryDialogPage) {
      final List<String> paths =
          (widget as DictionaryDialogPage).initialImportPaths;
      if (paths.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          debugPrint(
            '[hibiki-drop] [dictionary-dialog] initialImportPaths=${paths.length}',
          );
          if (mounted) unawaited(_importDictionaryPaths(paths));
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final bool compact = MediaQuery.sizeOf(context).width < 480;
    // 桌面三端：整页包一层文件拖放区，把拖入的词典包接到与「导入词典」按钮同源的
    // 导入路径（TODO-059）。移动端 HibikiFileDropTarget 直接透传 child，零开销。
    return HibikiFileDropTarget(
      debugLabel: 'dictionary-dialog',
      onDrop: _handleDictionaryDrop,
      child: AdaptiveSettingsScaffold(
        title: Text(t.dictionaries),
        // Cupertino (iOS/macOS) keeps its native nav-bar icon actions. Material
        // (Android/Windows/Linux) empties the app bar and surfaces the same
        // actions as labeled buttons in an in-page action bar so they read as
        // normal buttons instead of bare icons.
        actions: cupertino
            ? (compact ? _buildMobilePageActions() : _buildDesktopPageActions())
            : const <Widget>[],
        children: [
          if (!cupertino) _buildActionBar(),
          compact ? _buildDictionaryTypePicker() : _buildCategorySelector(),
          buildContent(),
        ],
      ),
    );
  }

  /// Material in-page action bar: labeled import/clear buttons that wrap on
  /// narrow widths. Replaces the bare app-bar icon buttons on Material.
  Widget _buildActionBar() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: tokens.spacing.gap + tokens.spacing.gap / 2,
      ),
      child: Wrap(
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
        children: <Widget>[
          _buildActionButton(
            focusPrefix: 'dict-action-download',
            icon: Icons.cloud_download_outlined,
            label: t.dict_download_browse,
            onTap: _showDownloadSelectionDialog,
          ),
          // TODO-609：遍历所有可在线更新的词典逐个比对 revision，汇总结果。
          if (appModel.dictionaries.any((Dictionary d) => d.isUpdatable))
            _buildActionButton(
              focusPrefix: 'dict-action-update',
              icon: Icons.system_update_alt,
              label: t.dict_update_check,
              onTap: _checkForUpdates,
            ),
          // Folder import is unavailable on iOS. This bar only renders on
          // Material, so the guard is a no-op on a normal iOS device (Cupertino
          // there); it stays live only for a forced Material design-system
          // override on iOS, mirroring _buildDesktopPageActions.
          if (!Platform.isIOS)
            _buildActionButton(
              focusPrefix: 'dict-action-folder',
              icon: Icons.drive_folder_upload_outlined,
              label: t.dialog_import_folder,
              onTap: _importDictionaryFolder,
            ),
          _buildActionButton(
            focusPrefix: 'dict-action-file',
            icon: Icons.upload_file_outlined,
            label: t.dialog_import_dictionary,
            onTap: _importDictionaryFiles,
          ),
          _buildActionButton(
            focusPrefix: 'dict-action-clear',
            icon: Icons.delete_sweep_outlined,
            label: t.dialog_clear_all_dictionaries,
            onTap: showDictionaryClearDialog,
            style: FilledButton.styleFrom(
              backgroundColor: scheme.errorContainer,
              foregroundColor: scheme.onErrorContainer,
            ),
          ),
        ],
      ),
    );
  }

  /// A labeled action button that is mouse/touch tappable and, under a
  /// [HibikiFocusRoot], a single gamepad/keyboard focus stop (A/Enter fires
  /// [onTap]). Same idiom as the reader quick-settings action strip: the
  /// underlying button is removed from focus traversal so it does not grab a
  /// competing, unregistered focus node.
  Widget _buildActionButton({
    required String focusPrefix,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    ButtonStyle? style,
  }) {
    final Widget button = FilledButton.tonalIcon(
      onPressed: onTap,
      style: style,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
    if (HibikiFocusRoot.maybeControllerOf(context) == null) {
      return button;
    }
    return HibikiActivatableFocusTarget(
      focusIdPrefix: focusPrefix,
      onTap: onTap,
      child: ExcludeFocus(child: button),
    );
  }

  List<Widget> _buildDesktopPageActions() {
    return [
      HibikiIconButton(
        tooltip: t.dict_download_browse,
        icon: Icons.cloud_download_outlined,
        onTap: _showDownloadSelectionDialog,
      ),
      if (!Platform.isIOS)
        HibikiIconButton(
          tooltip: t.dialog_import_folder,
          icon: Icons.drive_folder_upload_outlined,
          onTap: _importDictionaryFolder,
        ),
      HibikiIconButton(
        tooltip: t.dialog_import_dictionary,
        icon: Icons.upload_file_outlined,
        onTap: _importDictionaryFiles,
      ),
      HibikiIconButton(
        tooltip: t.dialog_clear_all_dictionaries,
        icon: Icons.delete_sweep_outlined,
        enabledColor: theme.colorScheme.error,
        onTap: showDictionaryClearDialog,
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

    final List<String> paths = result.files
        .map((PlatformFile f) => f.path)
        .whereType<String>()
        .toList();
    await _importDictionaryPaths(paths);

    if (Platform.isAndroid || Platform.isIOS) {
      await FilePicker.platform.clearTemporaryFiles();
    }
  }

  /// 把一组词典文件路径导入。文件选择器与桌面拖放共用这一条路径（与「导入词典」
  /// 按钮完全同源，不另起炉灶）：把 `.css` 拆成随词典的样式附件，其余按词典包逐个
  /// 经 [AppModel.importDictionary] 导入，复用同一进度对话框 / 失败汇总 / 内存不足
  /// 提示。无任何可导入的词典包时直接返回（不弹空进度框）。
  Future<void> _importDictionaryPaths(List<String> paths) async {
    final List<File> cssFiles = paths
        .where((String pth) => pth.toLowerCase().endsWith('.css'))
        .map((String pth) => File(pth))
        .toList();
    final List<File> dictFiles = paths
        .where((String pth) => !pth.toLowerCase().endsWith('.css'))
        .map((String pth) => File(pth))
        .toList();

    if (dictFiles.isEmpty) return;

    final ValueNotifier<String> progressNotifier =
        ValueNotifier<String>(t.import_start);
    final ValueNotifier<int?> countNotifier = ValueNotifier<int?>(null);
    final ValueNotifier<int?> totalNotifier = ValueNotifier<int?>(null);
    progressNotifier.addListener(() {
      debugPrint('[Dictionary Import] ${progressNotifier.value}');
    });

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
    // TODO-082：导入一开始就给用户一个明确反馈（开始后台导入），不只让用户盯着
    // 模态进度框猜测进度。
    HibikiToast.show(msg: t.dict_import_started);

    bool hadMemoryError = false;
    final List<String> failedNames = [];

    totalNotifier.value = dictFiles.length;
    for (int i = 0; i < dictFiles.length; i++) {
      countNotifier.value = i + 1;

      final File file = dictFiles[i];

      // BUG-082: collect per-file failures (no 3s block each) and show one
      // summary after the loop instead of dwelling on every failed import.
      try {
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
      } catch (e, stack) {
        ErrorLogService.instance.log('DictionaryDialog.fileImport', e, stack);
        failedNames.add(path.basenameWithoutExtension(file.path));
      }
    }

    if (mounted) {
      Navigator.pop(context);
    }

    if (failedNames.isNotEmpty) {
      HibikiToast.show(
        msg: DictionaryImportManager.formatImportFailureSummary(failedNames),
        toastLength: Toast.LENGTH_LONG,
      );
    }

    // TODO-082：成功导入的词典数 = 总数 - 失败数；> 0 就给一条明确的成功提示
    // （失败的另由上面的失败汇总文案告知，两者可同时出现：部分成功部分失败）。
    final int successCount = dictFiles.length - failedNames.length;
    if (successCount > 0) {
      HibikiToast.show(msg: t.dict_import_success_summary(n: successCount));
    }

    if (hadMemoryError && mounted) {
      showAppDialog(
        context: context,
        builder: (context) => const DictionaryLowMemoryDialog(),
      );
    }
  }

  /// 桌面拖放落地处理：把拖入文件按扩展名分类，取出词典包（`.zip`/`.dsl`/`.mdx`）+
  /// 同批拖入的 `.css` 样式附件，交给与「导入词典」按钮同源的 [_importDictionaryPaths]。
  /// 没有词典包时给用户明确反馈；移动端无桌面拖放，[HibikiFileDropTarget] 已直接
  /// 透传 child，本回调在移动端永不触发。纯分类逻辑见 [classifyDroppedFilesForDictionary]。
  void _handleDictionaryDrop(List<String> paths, Offset globalPosition) {
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;

    final List<String> importPaths = classifyDroppedFilesForDictionary(paths);
    debugPrint(
      '[hibiki-drop] [dictionary-dialog] importPaths=${importPaths.length} '
      'paths=${paths.length} global=$globalPosition',
    );
    if (importPaths.isEmpty) {
      debugPrint('[hibiki-drop] [dictionary-dialog] intent=unsupportedSurface');
      HibikiToast.show(msg: t.drag_drop_unsupported_on_dictionary);
      return;
    }
    _importDictionaryPaths(importPaths);
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
          // TODO-609：在线下载即记来源——catalog 的 zip URL 当 downloadUrl 回填。
          // 嵌入 index.json 若声明 isUpdatable/indexUrl/revision（如 yomidevs
          // releases/latest）会在 readSourceMetadataFromIndex 里覆盖优先；这里只兜底
          // 补 downloadUrl，使凡声明可更新的在线词典都能后续检查更新。
          await appModel.importDictionary(
            file: zipFile,
            progressNotifier: progressNotifier,
            onImportSuccess: () {},
            sourceOverride: <String, String>{'downloadUrl': rec.url},
          );
          successCount++;
        } catch (e) {
          lastError = '${rec.name}: $e';
        }
      }

      if (successCount == toDownload.length) {
        progressNotifier.value = t.dict_download_complete;
      } else if (successCount > 0) {
        progressNotifier.value = t.dict_download_partial(
          success: successCount,
          total: toDownload.length,
          error: lastError ?? '',
        );
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
      // TODO-082：目录导入也在开始时给明确反馈（成功/失败提示由
      // DictionaryImportManager.importFromDirectory 在完成时弹出）。
      HibikiToast.show(msg: t.dict_import_started);
    }

    bool hadMemoryError = false;
    String? folderImportError;

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
      // BUG-082: don't block 3s here either — capture and toast after the
      // progress dialog closes, consistent with the multi-file path.
      folderImportError = '$e';
    } finally {
      final Directory? cleanupDir = pickedDirectory.cleanupDir;
      if (cleanupDir != null && cleanupDir.existsSync()) {
        cleanupDir.deleteSync(recursive: true);
      }
    }

    if (mounted) {
      Navigator.pop(context);
    }

    if (folderImportError != null) {
      HibikiToast.show(
        msg: folderImportError,
        toastLength: Toast.LENGTH_LONG,
      );
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
              // Wrap as a single gamepad/keyboard focus stop (D-pad Left/Right
              // cycles the category). A bare segmented button is a cluster of
              // unregistered native buttons that the directional focus
              // controller skips over to the dictionary tiles below.
              child: HibikiAdjustableSegmented<DictionaryType>(
                focusIdPrefix: 'dict-type',
                values: const <DictionaryType>[
                  DictionaryType.term,
                  DictionaryType.kanji,
                  DictionaryType.frequency,
                  DictionaryType.pitch,
                ],
                selected: _selectedType,
                onChanged: (DictionaryType value) {
                  setState(() => _selectedType = value);
                },
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
    // Mirror buildEmptyMessage (the all-empty state) so switching to a
    // dictionary-type tab that happens to have no dictionary of that type reads
    // the same: a centred icon + message, not a cramped left-aligned grey card
    // (BUG-058 — inconsistent empty-state styling).
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: tokens.spacing.card + tokens.spacing.gap,
      ),
      child: HibikiPlaceholderMessage(
        icon: DictionaryMediaType.instance.outlinedIcon,
        message: t.dictionaries_menu_empty,
      ),
    );
  }

  Widget _buildDictionaryTile({
    required Dictionary dictionary,
    required int index,
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
    // 窄屏（手机）= 与本页其它分支同一真值阈值（_buildDictionaryTypePicker /
    // _buildMobilePageActions 都用 width < 480）。窄屏下控件串挤死了词典名：leading
    // 折叠 + 上/下/Switch/(更新)/删除 共 6-7 个固有宽控件占去约 176px，中段 title 只
    // 剩约 80px ≈ 5 个汉字 → 长词典名被省略号截短。修复=窄屏改两行布局：标题独占
    // 整行宽（不再与 trailing 抢宽），控件串挪到标题下方一行；桌面宽屏仍是单行
    // HibikiListItem（向后兼容）。这从结构上消除「窄屏 trailing 抢 title 宽」的特殊
    // 情况，四个 tab（term/kanji/frequency/pitch）共用本 tile 一处修复全覆盖。
    final bool compact = MediaQuery.sizeOf(context).width < 480;
    final Text nameText = Text(
      dictionary.name,
      style: textTheme.bodyLarge?.copyWith(
        color: titleColor,
        fontWeight: FontWeight.w600,
      ),
    );
    final Text subtitleText = Text(
      _subtitleForDictionary(dictionary, dictionaryFormat),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: textTheme.bodySmall?.copyWith(
        color: subtitleColor,
      ),
    );
    final Row controls = _buildDictionaryTileControls(
      dictionary: dictionary,
      index: index,
      isLast: isLast,
      enabled: enabled,
      onMoveUp: onMoveUp,
      onMoveDown: onMoveDown,
    );
    // 行内容本身不含拖拽监听：长按拖拽由外层 HibikiReorderableColumn 统一接管
    // （局部坐标，缩放下零偏移），不再用 SDK 的 ReorderableDelayedDragStartListener。
    // 行间距交给 HibikiReorderableColumn 的 spacing（见 _buildDictionaryList），
    // 此处不再包 bottom padding——否则拖拽浮层会把行间空隙连同卡片一起涂成背景，
    // 表现为「被拖行下方多出一条背景」（BUG-078 第二症状）。
    if (compact) {
      // 窄屏两行布局：第一行 = 折叠按钮（leading 语义，最左）+ 词典名（Expanded
      // 拿满整行剩余宽，不再被右侧控件串抢宽）；第二行 = 副标题；第三行 = 控件串
      // （上/下/Switch/更新/删除）右对齐。彻底消除「窄屏 trailing 抢 title 宽」的
      // 结构（TODO-749/751）。
      return HibikiCard(
        padding: EdgeInsets.zero,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.rowHorizontal - tokens.spacing.gap / 2,
            vertical: tokens.spacing.rowVertical,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  _buildDictionaryCollapseButton(dictionary),
                  SizedBox(width: tokens.spacing.gap),
                  Expanded(child: nameText),
                ],
              ),
              Padding(
                padding: EdgeInsets.only(top: tokens.spacing.gap / 4),
                child: subtitleText,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: controls,
              ),
            ],
          ),
        ),
      );
    }
    return HibikiCard(
      padding: EdgeInsets.zero,
      child: HibikiListItem(
        minHeight: 70,
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.rowHorizontal - tokens.spacing.gap / 2,
          vertical: tokens.spacing.rowVertical,
        ),
        // TODO-381 (user request): collapse/expand is the most-used one-tap
        // toggle for a row, so it is promoted to the row leading (leftmost):
        // visible at a glance, reachable with one finger, no longer buried in
        // the trailing control cluster. The name sits in the middle and uses
        // HibikiListItem own Expanded + ellipsis to take the full middle width,
        // so even on narrow widths it shows as much as fits (graceful ellipsis)
        // and is never squeezed out by the trailing controls.
        leading: _buildDictionaryCollapseButton(dictionary),
        title: nameText,
        subtitle: subtitleText,
        // Trailing keeps only: gamepad/a11y reorder arrows, the show/hide
        // switch, and a single inline delete button. Collapse/expand moved to
        // leading; custom CSS keeps its global fallback entry under settings →
        // dictionary settings (DictCssEditorDialog 可下拉选本词典), so dropping
        // the old three-dot menu does not lose any function (TODO-422).
        trailing: controls,
      ),
    );
  }

  /// 词典行尾的控件串（上/下重排箭头 + 显示/隐藏 Switch + 可选更新按钮 + 独立删除
  /// 按钮）。桌面宽屏放进 HibikiListItem 的 trailing（与标题同一行），窄屏挪到标题
  /// 下方（两行布局，见 _buildDictionaryTile），两处共用这一份避免重复。
  Row _buildDictionaryTileControls({
    required Dictionary dictionary,
    required int index,
    required bool isLast,
    required bool enabled,
    required VoidCallback onMoveUp,
    required VoidCallback onMoveDown,
  }) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    // 行尾控件串（窄屏挪到标题下方，桌面在标题右侧）；末尾是独立删除按钮
    //（TODO-422 取代旧三点菜单），不含旧的三点溢出菜单图标。
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
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
        // TODO-839：每本词典行尾恒显示一个「更新」按钮（消除「这本能更新那本不能」
        // 的视觉断层）。按 isUpdatable 分流：
        //   - 在线来源（isUpdatable 三条件满足）→ 走 _updateSingleDictionary（拉远端
        //     index.json 比 revision，TODO-609 原行为不变；它首行另有 isUpdatable 双保险）。
        //   - 本地导入 / 旧词典（isUpdatable=false）→ 走 _updateDictionaryFromFile（从
        //     文件重选 force 覆盖；异名先弹确认，避免静默改判成新增导入）。
        SizedBox(width: tokens.spacing.gap / 2),
        HibikiIconButton(
          icon: Icons.system_update_alt,
          size: 20,
          tooltip: t.dict_update_tooltip,
          onTap: () => dictionary.isUpdatable
              ? _updateSingleDictionary(dictionary)
              : _updateDictionaryFromFile(dictionary),
        ),
        SizedBox(width: tokens.spacing.gap / 2),
        // 行尾独立删除按钮（取代旧三点菜单），仍走原删除确认对话框流程。
        HibikiIconButton(
          icon: Icons.delete_outline,
          size: 20,
          tooltip: t.options_delete,
          onTap: () => showDictionaryDeleteDialog(dictionary),
        ),
      ],
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

  // TODO-091/TODO-381：把每本词典的「折叠/展开」状态做成行首 leading（最左）的
  // 一键开关，使 20+ 本词典的折叠状态可在列表里一眼一览（图标本身即状态），单击
  // 直接切换、无需先开菜单再选（对齐用户参考的 hsa 体验，并按用户诉求把它放到
  // 行最左）。折叠语义 = 查词弹窗里该词典释义默认折叠（见 dictionary_popup_webview
  // 注入 collapsedDictionaryNames）；持久化仍走既有 Dictionary.collapsedLanguages
  // （按 targetLanguage 区分），不改后端逻辑。
  Widget _buildDictionaryCollapseButton(Dictionary dictionary) {
    final bool collapsed = dictionary.isCollapsed(appModel.targetLanguage);
    final String tooltip = collapsed ? t.options_expand : t.options_collapse;
    return HibikiIconButton(
      // 已折叠 → 展开图标（点了会展开）；已展开 → 折叠图标（点了会折叠）。
      icon: collapsed ? Icons.unfold_more : Icons.unfold_less,
      size: 20,
      tooltip: tooltip,
      onTap: () {
        appModel.toggleDictionaryCollapsed(dictionary);
        setState(() {});
      },
    );
  }

  // 用自实现的 HibikiReorderableColumn（局部坐标长按拖拽），而非 SDK 的
  // ReorderableListView：后者的 Overlay 拖拽代理不认祖先 HibikiAppUiScale 的
  // Transform.scale，缩放界面下长按拖拽反馈会按 (1−s)×距离 向右下漂移、飞离原位
  // （BUG-044）。前者把拖拽反馈渲染在列表自身坐标系、用 globalToLocal 消掉祖先缩放
  // → 任意缩放下都精确跟手、零偏移且视觉一致。上下箭头按钮仍是无障碍/手柄重排路径。
  Widget _buildDictionaryList(List<Dictionary> dictionaries) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiReorderableColumn(
      itemCount: dictionaries.length,
      // 行间距由列表统一插入（见 _buildDictionaryTile 不再自带 bottom padding）；
      // 圆角传卡片半径，让拖拽浮层裁成圆角、不在卡片四角露出底色。
      spacing: tokens.spacing.rowVertical,
      feedbackBorderRadius: tokens.radii.cardRadius,
      keyForIndex: (int index) => ValueKey<String>(dictionaries[index].name),
      // HibikiReorderableColumn 的 to 已是最终下标，直接 removeAt(from)/insert(to)。
      onReorder: (int from, int to) =>
          _reorderDictionaries(from, to, dictionaries),
      itemBuilder: (BuildContext context, int index) => _buildDictionaryTile(
        dictionary: dictionaries[index],
        index: index,
        isLast: index == dictionaries.length - 1,
        onMoveUp: () => _reorderDictionaries(index, index - 1, dictionaries),
        onMoveDown: () => _reorderDictionaries(index, index + 1, dictionaries),
      ),
    );
  }

  /// 把 [dictionaries] 中 `from` 处的词典移动到**最终下标** `newIndex`，重排 order
  /// 并持久化。`newIndex` 是移动完成后该词典应处的位置（非 SDK 的「插入前下标」），
  /// 上下箭头与长按拖拽统一走这套最终下标语义——无需 SDK 的 `if(new>old)new--` 特例。
  void _reorderDictionaries(
    int oldIndex,
    int newIndex,
    List<Dictionary> dictionaries,
  ) {
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

  // ── TODO-609：在线 revision 比对手动更新 ──────────────────────────────

  /// 下载 [downloadUrl] 处的词典包并**强制重导**（force=true）替换同名旧版，保留
  /// order/hidden/collapsed，落上新来源（[sourceOverride] 至少带回 downloadUrl）。
  /// 复用现有下载进度 UI（[DictionaryDownloadProgressDialog]）。成功返 true。
  Future<bool> _redownloadAndReimport({
    required String name,
    required String downloadUrl,
    required ValueNotifier<String> progressNotifier,
    required ValueNotifier<double> downloadProgress,
    required Map<String, String> sourceOverride,
  }) async {
    final Directory tempDir = Directory(
      path.join(appModel.dictionaryResourceDirectory.path, 'update_temp'),
    );
    try {
      progressNotifier.value = t.dict_update_updating(name: name);
      downloadProgress.value = 0;
      final File zipFile = await DictionaryDownloader.download(
        url: downloadUrl,
        tempDir: tempDir,
        progressNotifier: downloadProgress,
      );
      await appModel.importDictionary(
        file: zipFile,
        progressNotifier: progressNotifier,
        onImportSuccess: () {},
        forceReplaceExisting: true,
        sourceOverride: sourceOverride,
      );
      return true;
    } finally {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    }
  }

  /// 单本词典「更新」按钮：拉远端 index.json 比 revision，有新版才下载重导。无新版
  /// 提示「已是最新」。任何失败提示 [t.dict_update_failed]，不崩。
  Future<void> _updateSingleDictionary(Dictionary dictionary) async {
    if (_isDownloading) return;
    if (!dictionary.isUpdatable) return;
    _isDownloading = true;

    final ValueNotifier<String> progressNotifier =
        ValueNotifier<String>(t.dict_update_checking);
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

    String resultMsg = t.dict_update_latest;
    try {
      final String? remoteRevision =
          await DictionaryUpdateService.fetchRemoteIndex(dictionary.indexUrl);
      if (!DictionaryUpdateService.needsUpdate(
          dictionary.revision, remoteRevision)) {
        resultMsg = t.dict_update_latest;
      } else {
        await _redownloadAndReimport(
          name: dictionary.name,
          downloadUrl: dictionary.downloadUrl,
          progressNotifier: progressNotifier,
          downloadProgress: downloadProgress,
          // W-2：更新即知本词典可更新——显式回填 isUpdatable:'true' + 两 URL，使
          // 即便重导包内 index.json 不声明 isUpdatable，更新后仍保持可更新（不丢按钮）。
          sourceOverride: <String, String>{
            'isUpdatable': 'true',
            'downloadUrl': dictionary.downloadUrl,
            'indexUrl': dictionary.indexUrl,
          },
        );
        resultMsg = t.dict_update_done(name: dictionary.name);
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('DictionaryDialog.updateSingle', e, stack);
      resultMsg = t.dict_update_failed(error: '$e');
    } finally {
      progressNotifier.dispose();
      downloadProgress.dispose();
      _isDownloading = false;
      if (mounted) {
        Navigator.pop(context);
        setState(() {});
      }
    }
    HibikiToast.show(msg: resultMsg);
  }

  /// TODO-839：本地导入 / 旧词典（isUpdatable=false，无在线来源）的「从文件重选覆盖
  /// 更新」。让用户重选一个词典包，force 覆盖原词典（保留 order/hidden/collapsed），
  /// 失败不丢原词典（复用 importFromFile 的 import_temp 暂存→成功才删旧）。
  ///
  /// 异名陷阱处理：decideUpdate 按**新包 index.json 的 title** 决策，而非用户点的那本
  /// 词典。新包异名（base 名都不同）时它会 newDictionary 把新包当全新词典追加、原词典
  /// 原封不动留着——用户以为「更新了」实则多出一本、原词典没变。故导入前先廉价探出新
  /// 包 title（仅 yomitan zip 可探），与被更新词典名不同则弹确认（dsl/mdx 探不到 title
  /// → 退化为纯 force，量极低可接受）。
  Future<void> _updateDictionaryFromFile(Dictionary dictionary) async {
    if (_isDownloading) return;

    if (Platform.isAndroid || Platform.isIOS) {
      await FilePicker.platform.clearTemporaryFiles();
    }
    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['zip', 'dsl', 'mdx', 'ifo'],
      allowMultiple: false,
    );
    final String? pickedPath =
        picked?.files.isNotEmpty == true ? picked!.files.single.path : null;
    if (pickedPath == null) {
      if (Platform.isAndroid || Platform.isIOS) {
        await FilePicker.platform.clearTemporaryFiles();
      }
      return;
    }
    final File file = File(pickedPath);

    // 异名确认：仅 yomitan zip 能廉价探出 title；探到且与目标词典异名时先弹确认。
    final String? incomingTitle =
        DictionaryImportManager.peekDictionaryTitle(file);
    if (incomingTitle != null && incomingTitle != dictionary.name) {
      final bool? confirmed = await _confirmNameMismatch(
        incoming: incomingTitle,
        existing: dictionary.name,
      );
      if (confirmed != true) {
        if (Platform.isAndroid || Platform.isIOS) {
          await FilePicker.platform.clearTemporaryFiles();
        }
        return;
      }
    }

    if (!mounted) return;
    _isDownloading = true;

    final ValueNotifier<String> progressNotifier =
        ValueNotifier<String>(t.dict_update_updating(name: dictionary.name));
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

    String resultMsg = t.dict_update_done(name: dictionary.name);
    try {
      await appModel.importDictionary(
        file: file,
        progressNotifier: progressNotifier,
        onImportSuccess: () {},
        forceReplaceExisting: true,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('DictionaryDialog.updateFromFile', e, stack);
      resultMsg = t.dict_update_failed(error: '$e');
    } finally {
      progressNotifier.dispose();
      downloadProgress.dispose();
      _isDownloading = false;
      if (mounted) {
        Navigator.pop(context);
        setState(() {});
      }
      if (Platform.isAndroid || Platform.isIOS) {
        await FilePicker.platform.clearTemporaryFiles();
      }
    }
    HibikiToast.show(msg: resultMsg);
  }

  /// 异名覆盖确认对话框：所选文件包名 [incoming] 与被更新词典 [existing] 不同时弹出，
  /// 用户点「替换」返 true、取消 / 关闭返 null（中止、原词典不动）。
  Future<bool?> _confirmNameMismatch({
    required String incoming,
    required String existing,
  }) {
    return showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => DictionaryConfirmationDialog(
        title: Text(t.dict_update_name_mismatch_title),
        content: Text(
          t.dict_update_name_mismatch_body(
            incoming: incoming,
            existing: existing,
          ),
        ),
        actions: <Widget>[
          adaptiveDialogAction(
            context: ctx,
            child: Text(t.dialog_cancel),
            onPressed: () => Navigator.pop(ctx),
          ),
          adaptiveDialogAction(
            context: ctx,
            isDefaultAction: true,
            child: Text(t.dialog_replace),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
  }

  /// action bar「检查更新」：遍历所有可更新词典逐个比对，有新版的逐个下载重导，
  /// 汇总 N 更新 / M 最新 / K 失败。复用现有下载进度 UI。
  Future<void> _checkForUpdates() async {
    if (_isDownloading) return;
    final List<Dictionary> updatable =
        appModel.dictionaries.where((Dictionary d) => d.isUpdatable).toList();
    if (updatable.isEmpty) {
      HibikiToast.show(msg: t.dict_update_none);
      return;
    }
    _isDownloading = true;

    final ValueNotifier<String> progressNotifier =
        ValueNotifier<String>(t.dict_update_checking);
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

    int updated = 0;
    int current = 0;
    int failed = 0;
    try {
      for (final Dictionary d in updatable) {
        try {
          // W-1：每本检查前归零进度条，避免上一本下载完的满格残留在「检查 revision」
          // 阶段误显 100%。
          downloadProgress.value = 0;
          progressNotifier.value = t.dict_update_checking;
          final String? remoteRevision =
              await DictionaryUpdateService.fetchRemoteIndex(d.indexUrl);
          if (!DictionaryUpdateService.needsUpdate(
              d.revision, remoteRevision)) {
            current++;
            continue;
          }
          await _redownloadAndReimport(
            name: d.name,
            downloadUrl: d.downloadUrl,
            progressNotifier: progressNotifier,
            downloadProgress: downloadProgress,
            sourceOverride: <String, String>{
              'isUpdatable': 'true',
              'downloadUrl': d.downloadUrl,
              'indexUrl': d.indexUrl,
            },
          );
          updated++;
        } catch (e, stack) {
          ErrorLogService.instance
              .log('DictionaryDialog.checkUpdates', e, stack);
          failed++;
        }
      }
    } finally {
      progressNotifier.dispose();
      downloadProgress.dispose();
      _isDownloading = false;
      if (mounted) {
        Navigator.pop(context);
        setState(() {});
      }
    }
    HibikiToast.show(
      msg: t.dict_update_summary(
        updated: updated.toString(),
        current: current.toString(),
        failed: failed.toString(),
      ),
      toastLength: Toast.LENGTH_LONG,
    );
  }

  // TODO-422：每本词典行尾原来的三点菜单（自定义 CSS + 删除）已移除，改为行尾
  // 一个独立删除按钮（见 _buildDictionaryTile 的 trailing Row）。删单本词典仍走
  // showDictionaryDeleteDialog 的确认对话框；自定义 CSS 仍有设置 → 词典设置里的
  // DictCssEditorDialog 全局入口（可下拉选本词典），故不丢功能。
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
