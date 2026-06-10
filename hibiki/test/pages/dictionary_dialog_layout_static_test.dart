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

  test('per-category empty state matches the all-empty placeholder (BUG-058)',
      () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();
    final int rowStart = source.indexOf('  Widget _buildEmptyCategoryRow() {');
    final int rowEnd = source.indexOf('  Widget _buildDictionaryTile(');

    expect(rowStart, isNonNegative);
    expect(rowEnd, greaterThan(rowStart));

    final String rowSource = source.substring(rowStart, rowEnd);

    // The empty-category state (e.g. the Kanji tab with no kanji dictionary)
    // must use the same centred icon + message placeholder as buildEmptyMessage,
    // not a cramped left-aligned grey card.
    expect(rowSource, contains('HibikiPlaceholderMessage'));
    expect(rowSource, contains('DictionaryMediaType.instance.outlinedIcon'));
    expect(rowSource, isNot(contains('HibikiCard')));
    expect(rowSource, isNot(contains('child: Text(')));
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

  // TODO-059：词典管理页支持桌面拖放导入。整页包一层 HibikiFileDropTarget，拖入的
  // 词典包经与「导入词典」按钮同源的 _importDictionaryPaths 导入。守卫这套接线，
  // 防止后续重构悄悄把拖放摘掉或让它走偏离手动导入的旁路。
  test('dictionary manager wires desktop drag-drop import (TODO-059)', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();

    // 整页被 HibikiFileDropTarget 包裹，drop 回调指向 _handleDictionaryDrop。
    expect(source, contains('HibikiFileDropTarget('));
    expect(source, contains('onDrop: _handleDictionaryDrop'));

    // drop 处理走纯分类函数挑词典包，再交给与手动导入同一条 _importDictionaryPaths。
    expect(source, contains('void _handleDictionaryDrop('));
    expect(source, contains('classifyDroppedFilesForDictionary(paths)'));
    expect(source, contains('_importDictionaryPaths(importPaths)'));

    // 文件选择器与拖放共用 _importDictionaryPaths（不另起一条导入旁路）。
    expect(source, contains('Future<void> _importDictionaryPaths('));
    expect(source, contains('await _importDictionaryPaths(paths)'));
    expect(source, contains('appModel.importDictionary('));
  });

  // TODO-091：每本词典的「折叠/展开」状态必须在列表行内可一览 + 一键切换，
  // 不再藏进三点(⋮)菜单的二级项（那是「点两下」且看不见折叠状态）。守卫：
  //  ① 列表行 trailing 直接渲染 _buildDictionaryCollapseButton；
  //  ② 该按钮单击即 toggleDictionaryCollapsed（一键，非先开菜单）；
  //  ③ 图标随 isCollapsed 状态切换（unfold_more/unfold_less = 状态一览）；
  //  ④ 三点菜单 getMenuItems 不再含折叠项（消除第二个慢入口）。
  test('dictionary row surfaces an inline one-tap collapse toggle (TODO-091)',
      () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();

    // ① 行内按钮在 trailing 里、紧邻可见性开关。
    expect(source, contains('_buildDictionaryCollapseButton(dictionary)'));
    expect(source, contains('Widget _buildDictionaryCollapseButton('));

    // ② 单击直接切换折叠状态（不经二级菜单）。
    final int btnStart =
        source.indexOf('Widget _buildDictionaryCollapseButton(');
    final int btnEnd = source.indexOf('// 用自实现的 HibikiReorderableColumn');
    expect(btnStart, isNonNegative);
    expect(btnEnd, greaterThan(btnStart));
    final String btnSource = source.substring(btnStart, btnEnd);
    expect(
        btnSource, contains('appModel.toggleDictionaryCollapsed(dictionary)'));
    expect(btnSource, contains('setState(() {})'));

    // ③ 图标随状态切换，状态可一览。
    expect(
        btnSource, contains('dictionary.isCollapsed(appModel.targetLanguage)'));
    expect(btnSource, contains('Icons.unfold_more'));
    expect(btnSource, contains('Icons.unfold_less'));
    expect(btnSource, contains('t.options_expand'));
    expect(btnSource, contains('t.options_collapse'));

    // ④ 三点菜单不再含折叠项（避免「点两下」的第二入口）。
    final int menuStart =
        source.indexOf('List<HibikiPopupMenuItem<VoidCallback>> getMenuItems(');
    expect(menuStart, isNonNegative);
    final String menuSource = source.substring(menuStart);
    expect(menuSource, isNot(contains('toggleDictionaryCollapsed')));
    expect(menuSource, isNot(contains('t.options_collapse')));
    expect(menuSource, isNot(contains('t.options_expand')));
  });
}
