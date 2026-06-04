import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_dialog_page.dart';

void main() {
  test('dictionary manager page library compiles', () {
    expect(const DictionaryDialogPage(), isA<DictionaryDialogPage>());
  });

  test('dictionary manager is a settings page, not a settings dialog', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();
    final int buildStart =
        source.indexOf('  Widget build(BuildContext context) {');
    final int clearDialogStart =
        source.indexOf('  Future<void> showDictionaryClearDialog()');

    expect(buildStart, isNonNegative);
    expect(clearDialogStart, greaterThan(buildStart));

    final String buildSource = source.substring(buildStart, clearDialogStart);

    expect(buildSource, contains('AdaptiveSettingsScaffold'));
    expect(buildSource, isNot(contains('adaptiveAlertDialog(')));
    expect(buildSource, isNot(contains('DictionaryManagerDialogFrame')));
  });

  test('dictionary manager groups all dictionary categories', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();

    for (final String token in <String>[
      'DictionaryType.term',
      'DictionaryType.kanji',
      'DictionaryType.frequency',
      'DictionaryType.pitch',
      't.dictionary_section_term',
      't.dictionary_section_kanji',
      't.dictionary_section_frequency',
      't.dictionary_section_pitch',
    ]) {
      expect(source, contains(token), reason: 'missing $token');
    }
  });

  test('dictionary manager uses MD3 spacing tokens for page states', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();

    expect(source, contains('HibikiDesignTokens.of(context)'));
    expect(
        source, isNot(contains('padding: const EdgeInsets.only(bottom: 12)')));
    expect(
      source,
      isNot(contains('padding: const EdgeInsets.symmetric(vertical: 24)')),
    );
    expect(
      source,
      isNot(
        contains(
            'padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18)'),
      ),
    );
  });

  test('dictionary manager settings entry pushes a page route', () {
    final String schemaSource =
        File('lib/src/settings/settings_schema.dart').readAsStringSync();
    final int lookupDictionaries =
        schemaSource.indexOf("id: 'lookup.dictionaries'");
    final int lookupCustomCss = schemaSource.indexOf("id: 'lookup.custom_css'");

    expect(lookupDictionaries, isNonNegative);
    expect(lookupCustomCss, greaterThan(lookupDictionaries));

    final String itemSource =
        schemaSource.substring(lookupDictionaries, lookupCustomCss);
    expect(itemSource, contains('pushSettingsPage'));
    expect(itemSource, contains('DictionaryDialogPage'));
    expect(itemSource, isNot(contains('showAppDialog')));
  });

  test('dictionary manager page no longer keeps a dialog frame class', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();

    expect(source, isNot(contains('class DictionaryManagerDialogFrame')));
    expect(source, isNot(contains('CupertinoAlertDialog')));
    expect(source, isNot(contains('return Dialog(')));
  });

  test('dictionary manager uses compact mobile-safe chrome', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();

    expect(source, contains('_buildMobilePageActions'));
    expect(source, contains('_buildDesktopPageActions'));
    expect(source, contains('MediaQuery.sizeOf(context).width < 480'));
    expect(source, contains('AdaptiveSettingsPickerRow<DictionaryType>'));
    expect(source, contains('_buildDictionaryTypePicker'));
    expect(source, contains('_buildDictionaryVisibilityButton'));
  });

  test('dictionary folder import is not Android-only', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();
    final int pickerStart = source
        .indexOf('  Future<({Directory directory, Directory? cleanupDir})?>');
    final int folderImportStart =
        source.indexOf('  Future<void> _importDictionaryFolder()');
    final int buildContentStart = source.indexOf('  Widget buildContent()');

    expect(pickerStart, isNonNegative);
    expect(folderImportStart, isNonNegative);
    expect(buildContentStart, greaterThan(folderImportStart));

    final String pickerSource =
        source.substring(pickerStart, folderImportStart);
    final String folderImportSource =
        source.substring(folderImportStart, buildContentStart);

    expect(
        folderImportSource, isNot(contains('if (!Platform.isAndroid) return')));
    expect(pickerSource, contains('FilePicker.platform.getDirectoryPath'));
    expect(
        folderImportSource, contains('appModel.importDictionaryFromDirectory'));
    expect(
        folderImportSource, contains('directory: pickedDirectory.directory'));
    expect(folderImportSource, contains('pickedDirectory.cleanupDir'));
  });

  // BUG-044：界面缩放（HibikiAppUiScale != 1.0）下，SDK ReorderableListView 的
  // Overlay 拖拽代理不认祖先 Transform.scale，长按拖拽反馈会按 (1−s)×距离 向右下漂移、
  // 飞离原位（用户截图症状）。修复=改用自实现的 HibikiReorderableColumn（局部坐标长按
  // 拖拽，globalToLocal 消掉祖先缩放），缩放下精确跟手、零偏移、视觉一致。
  test(
      'dictionary list uses HibikiReorderableColumn (UI-scale safe), not SDK '
      'ReorderableListView (BUG-044)', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();

    expect(source, contains('HibikiReorderableColumn('));
    // 禁的是 SDK 拖拽控件的**构造调用**（说明性注释可提及其名字）。
    expect(source, isNot(contains('ReorderableListView.builder(')));
    expect(source, isNot(contains('ReorderableListView(')));
    expect(source, isNot(contains('ReorderableDelayedDragStartListener(')));
    expect(source, isNot(contains('ReorderableDragStartListener(')));
    // 上下箭头按钮仍是无障碍/手柄重排路径（手柄抓不到拖拽时）。
    expect(source, contains('Icons.keyboard_arrow_up'));
    expect(source, contains('Icons.keyboard_arrow_down'));
  });

  test('dictionary manager surfaces a labeled Material action bar', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();

    // Material path empties the app bar and renders an in-page action bar.
    expect(source, contains('_buildActionBar'));
    expect(source, contains('if (!cupertino) _buildActionBar()'));
    expect(source, contains('actions: cupertino'));

    // The four actions are labeled buttons reusing the existing i18n keys.
    for (final String label in <String>[
      't.dict_download_browse',
      't.dialog_import_folder',
      't.dialog_import_dictionary',
      't.dialog_clear_all_dictionaries',
    ]) {
      expect(source, contains(label), reason: 'missing label $label');
    }
    expect(source, contains('FilledButton.tonalIcon'));

    // Buttons stay reachable by gamepad/keyboard (single focus stop each).
    expect(source, contains('HibikiActivatableFocusTarget'));
  });
}
