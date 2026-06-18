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

  test('dictionary drag-drop can enter from lookup home with initial paths',
      () {
    final String dialog =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();
    final String home =
        File('lib/src/pages/implementations/home_dictionary_page.dart')
            .readAsStringSync();
    final String model =
        File('lib/src/models/app_model.dart').readAsStringSync();

    expect(dialog, contains('this.initialImportPaths = const <String>[]'));
    expect(dialog, contains('unawaited(_importDictionaryPaths(paths))'),
        reason: 'DictionaryDialogPage should consume initial import paths');
    expect(dialog, contains('t.drag_drop_unsupported_on_dictionary'),
        reason: 'bad dictionary drops must be visible to the user');

    expect(home, contains('HibikiFileDropTarget('));
    expect(home, contains('onDrop: _handleDictionaryHomeDrop'));
    expect(home, contains('classifyDroppedFilesForDictionary(paths)'));
    expect(
        home, contains('showDictionaryMenu(initialImportPaths: importPaths)'));

    expect(model, contains('List<String> initialImportPaths'));
    expect(model, contains('DictionaryDialogPage('));
    expect(model, contains('initialImportPaths: initialImportPaths'));
  });

  // TODO-091/TODO-381：每本词典的「折叠/展开」状态必须在列表行内可一览 + 一键
  // 切换，且按用户诉求放到行**最左**（leading），从拥挤的右侧控件串里拿出来。
  // 守卫：
  //  ① 折叠/展开按钮放在 HibikiListItem 的 leading（最左），不在 trailing；
  //  ② 该按钮单击即 toggleDictionaryCollapsed（一键，非先开菜单）；
  //  ③ 图标随 isCollapsed 状态切换（unfold_more/unfold_less = 状态一览）；
  //  ④ trailing 串里不再有三点菜单（TODO-422 已移除），自然也没有折叠项入口。
  test(
      'dictionary row puts the one-tap collapse toggle in leading (leftmost), '
      'not trailing (TODO-091/TODO-381)', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();

    expect(source, contains('Widget _buildDictionaryCollapseButton('));

    // ① 折叠/展开按钮挂在 leading（最左），不在 trailing 串里。
    expect(
      source,
      contains('leading: _buildDictionaryCollapseButton(dictionary)'),
      reason: 'collapse toggle must be the row leading (leftmost)',
    );
    // 定位 _buildDictionaryTile 的 trailing Row，断言它不再含折叠按钮。
    final int tileStart = source.indexOf('Widget _buildDictionaryTile({');
    final int tileEnd =
        source.indexOf('Widget _buildDictionaryVisibilityButton(');
    expect(tileStart, isNonNegative);
    expect(tileEnd, greaterThan(tileStart));
    final String tileSource = source.substring(tileStart, tileEnd);
    final int trailingStart = tileSource.indexOf('trailing: Row(');
    expect(trailingStart, isNonNegative);
    final String trailingSource = tileSource.substring(trailingStart);
    expect(
      trailingSource,
      isNot(contains('_buildDictionaryCollapseButton(dictionary)')),
      reason: 'collapse toggle moved out of trailing into leading',
    );

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

    // ④ 行尾的三点菜单已被 TODO-422 移除（trailing 串里没有 more_vert，也没有
    //    buildDictionaryTileTrailing/getMenuItems 入口），自然不存在折叠项的
    //    「第二个慢入口」。折叠仍由 leading 一键切换（前面已断言）。
    expect(trailingSource, isNot(contains('Icons.more_vert')));
    expect(trailingSource, isNot(contains('buildDictionaryTileTrailing(')));
    expect(source, isNot(contains('getMenuItems(')));
  });

  // TODO-422：词典行尾的三点菜单（旧 buildDictionaryTileTrailing / getMenuItems）
  // 已被一个独立删除按钮取代。守卫：① 整个文件不再有三点菜单方法；② trailing Row
  // 末尾是一个删除 HibikiIconButton（图标 delete_outline、tooltip 用现有 options_delete
  // key），onTap 仍调原删除确认对话框 showDictionaryDeleteDialog（删单本词典流程不变）。
  test(
      'row trailing replaces the three-dot menu with an inline delete button '
      '(TODO-422)', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();

    // ① 旧三点菜单的两个方法整文件不再存在。
    expect(source, isNot(contains('Widget buildDictionaryTileTrailing(')));
    expect(
      source,
      isNot(contains('List<HibikiPopupMenuItem<VoidCallback>> getMenuItems(')),
    );

    // ② 定位 _buildDictionaryTile 的 trailing Row。
    final int tileStart = source.indexOf('Widget _buildDictionaryTile({');
    final int tileEnd =
        source.indexOf('Widget _buildDictionaryVisibilityButton(');
    expect(tileStart, isNonNegative);
    expect(tileEnd, greaterThan(tileStart));
    final String tileSource = source.substring(tileStart, tileEnd);
    final int trailingStart = tileSource.indexOf('trailing: Row(');
    expect(trailingStart, isNonNegative);
    final String trailingSource = tileSource.substring(trailingStart);

    // trailing 里没有三点菜单，改成独立删除按钮（仍走删除确认对话框）。
    expect(trailingSource, isNot(contains('Icons.more_vert')));
    expect(trailingSource, isNot(contains('buildDictionaryTileTrailing(')));
    expect(trailingSource, contains('HibikiIconButton('));
    expect(trailingSource, contains('Icons.delete_outline'));
    expect(trailingSource, contains('tooltip: t.options_delete'));
    expect(
      trailingSource,
      contains('showDictionaryDeleteDialog(dictionary)'),
    );
  });
}
