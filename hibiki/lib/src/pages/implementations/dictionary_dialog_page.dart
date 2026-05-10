import 'dart:io';

import 'package:change_notifier_builder/change_notifier_builder.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki/dictionary.dart';
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
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
                buildImportFolderButton(),
                const SizedBox(width: 8),
                buildImportButton(),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                buildClearButton(),
                const SizedBox(width: 8),
                buildCloseButton(),
              ],
            ),
          ],
        ),
      ];

  Future<void> showDictionaryClearDialog() async {
    Widget alertDialog = AlertDialog(
      title: Text(t.dialog_title_dictionary_clear),
      content: Text(
        t.dialog_content_dictionary_clear,
        textAlign: TextAlign.justify,
      ),
      actions: <Widget>[
        TextButton(
          child: Text(
            t.dialog_clear,
            style: TextStyle(color: theme.colorScheme.primary),
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
            }

            _selectedOrder = -1;
            setState(() {});
          },
        ),
        TextButton(
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
    Widget alertDialog = AlertDialog(
      title: Text(t.dialog_title_dictionary_delete(name: dictionary.name)),
      content: Text(
        t.dialog_content_dictionary_delete,
        textAlign: TextAlign.justify,
      ),
      actions: <Widget>[
        TextButton(
          child: Text(
            t.dialog_delete,
            style: TextStyle(color: theme.colorScheme.primary),
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
            }

            _selectedOrder = -1;
            setState(() {});
          },
        ),
        TextButton(
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
      allowedExtensions: const ['zip', 'dsl', 'mdx', 'css'],
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
          _selectedOrder = appModel.dictionaries.last.order;
          setState(() {});
        },
      );
    }

    await FilePicker.platform.clearTemporaryFiles();

    if (mounted) {
      Navigator.pop(context);
    }
  }

  Widget buildImportButton() {
    return TextButton(
      child: Text(t.dialog_import_dictionary),
      onPressed: _importDictionaryFiles,
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

        try {
          await appModel.importDictionaryFromDirectory(
            directory: tempDir,
            progressNotifier: progressNotifier,
            countNotifier: countNotifier,
            totalNotifier: totalNotifier,
            onImportSuccess: () {
              _selectedOrder = appModel.dictionaries.last.order;
              setState(() {});
            },
          );
        } catch (e) {
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
    ScrollController contentController = ScrollController();

    return SizedBox(
      width: double.maxFinite,
      child: RawScrollbar(
        thickness: 3,
        thumbVisibility: true,
        controller: contentController,
        child: Padding(
          padding: contentController.hasClients
              ? Spacing.of(context).insets.onlyRight.normal
              : EdgeInsets.zero,
          child: SingleChildScrollView(
            controller: contentController,
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
                const JidoujishoDivider(),
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
        Flexible(child: buildDictionaryList(dictionaries)),
      ],
    );
  }

  Widget buildEmptyMessage() {
    return Padding(
      padding: EdgeInsets.only(
        bottom: Spacing.of(context).spaces.normal,
      ),
      child: JidoujishoPlaceholderMessage(
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
      buildDefaultDragHandles: true,
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
        Icons.visibility_off,
        size: textTheme.titleLarge?.fontSize,
        color: theme.unselectedWidgetColor,
      );
    } else if (dictionary.isCollapsed(appModel.targetLanguage)) {
      return Icon(
        Icons.close_fullscreen,
        size: textTheme.titleLarge?.fontSize,
        color: theme.unselectedWidgetColor,
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
                      JidoujishoMarquee(
                        text: dictionary.name,
                        style: TextStyle(
                          fontSize: textTheme.bodyMedium?.fontSize,
                          color: dictionary.isHidden(appModel.targetLanguage)
                              ? theme.unselectedWidgetColor
                              : null,
                        ),
                      ),
                      JidoujishoMarquee(
                        text: dictionaryFormat.name,
                        style: TextStyle(
                          fontSize: textTheme.bodySmall?.fontSize,
                          color: dictionary.isHidden(appModel.targetLanguage)
                              ? theme.unselectedWidgetColor
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
        label: dictionary.isCollapsed(appModel.targetLanguage)
            ? t.options_expand
            : t.options_collapse,
        icon: dictionary.isCollapsed(appModel.targetLanguage)
            ? Icons.open_in_full
            : Icons.close_fullscreen,
        action: () {
          appModel.toggleDictionaryCollapsed(dictionary);
          final notifier = _notifiersByDictionary[dictionary];
          if (notifier != null) {
            notifier.value = !notifier.value;
            notifier.value = !notifier.value;
          }
        },
      ),
      buildPopupItem(
        label: dictionary.isHidden(appModel.targetLanguage)
            ? t.options_show
            : t.options_hide,
        icon: dictionary.isCollapsed(appModel.targetLanguage)
            ? Icons.visibility
            : Icons.visibility_off,
        action: () {
          appModel.toggleDictionaryHidden(dictionary);
          final notifier = _notifiersByDictionary[dictionary];
          if (notifier != null) {
            notifier.value = !notifier.value;
            notifier.value = !notifier.value;
          }
        },
      ),
      buildPopupItem(
        label: t.options_delete,
        icon: Icons.delete,
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
              color: theme.unselectedWidgetColor,
            ),
          ),
        ),
        Stack(
          alignment: Alignment.bottomCenter,
          children: [
            ChangeNotifierBuilder(
              notifier: _formatNotifier,
              builder: (_, __, ___) => JidoujishoDropdown<DictionaryFormat>(
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
                    color: Theme.of(context).unselectedWidgetColor,
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
