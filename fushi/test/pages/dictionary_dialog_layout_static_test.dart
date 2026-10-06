import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_dialog_page.dart';

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

    expect(source, contains('FushiDesignTokens.of(context)'));
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

  // TODO-1343：用户报「自动更新和词典粘一块了」——AdaptiveSettingsScaffold 的
  // children 之间不插任何间隔（见 settings_shared.dart 的 ListView/SliverList），
  // 全靠每个子块自带分隔。词典列表 buildContent() 没有底部间距、自动更新设置卡
  // 原来又只有底部间距，于是列表最后一张词典卡与自动更新卡直接贴在一起。守卫：
  // _buildAutoUpdateCard() 必须给外层 Padding 补一段顶部间距，把两个分区分开。
  test('dictionary auto-update card separates from the list above (TODO-1343)',
      () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();

    final int cardStart = source.indexOf('  Widget _buildAutoUpdateCard() {');
    final int cardEnd = source.indexOf('  Widget _buildActionBar({');
    expect(cardStart, isNonNegative);
    expect(cardEnd, greaterThan(cardStart));

    final String cardSource = source.substring(cardStart, cardEnd);

    // 外层 Padding 必须带顶部间距（top:），且用 MD3 spacing token 表达，不硬编码。
    expect(
      cardSource,
      contains('top: tokens.spacing.gap + tokens.spacing.gap / 2'),
      reason: '自动更新卡必须与上方词典列表隔开顶部间距，避免粘连',
    );
    // 保底：不得退回「只有底部间距」的旧写法（粘连的根因）。
    expect(
      cardSource,
      isNot(contains('padding: EdgeInsets.only(bottom: tokens.spacing.gap),')),
      reason: '只有底部间距会让自动更新卡与词典列表粘一块（TODO-1343 回归）',
    );
  });

  test('dictionary manager settings entry pushes a page route', () {
    final String schemaSource =
        File('lib/src/settings/settings_schema_lookup.dart').readAsStringSync();
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

  // 2026-10 词典管理 M3 Expressive 重做：宽屏（≥ 840）列表 + 详情侧板两栏，
  // 窄屏单列卡片列表 + 底部 sheet；类型筛选在所有宽度都是同一个带本数的分段
  // 控件（手机上不再退化成要点开才看得到选项的下拉框）。
  test('dictionary manager uses compact mobile-safe chrome', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();

    expect(source, contains('_buildMobilePageActions'));
    expect(source, contains('_buildDesktopPageActions'));
    expect(source, contains('MediaQuery.sizeOf(context).width < 480'));
    expect(source, contains('dictionaryManagerUsesSplitLayout(width)'));
    expect(source, contains('_buildSplitBody('));
    expect(source, contains('_showDictionaryDetailSheet('));
    expect(source, contains('adaptiveModalSheet<void>('));
    expect(
        source, isNot(contains('AdaptiveSettingsPickerRow<DictionaryType>')));
    expect(source, isNot(contains('_buildDictionaryTypePicker')));
    expect(source, contains('_buildDictionaryVisibilityButton'));
  });

  // 批量操作：共享 BatchActionBar（全选 / 反选 / 启用 / 停用 / 删除），批量删除与
  // 单本删除走同一确认 + 删除漏斗，不另起删除旁路。
  test('dictionary manager batch actions reuse shared primitives', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();

    expect(source, contains('BatchActionBar('));
    expect(source, contains('void _batchSetEnabled(bool enabled)'));
    expect(source, contains('appModel.toggleDictionaryHidden(dictionary)'));
    final int start = source.indexOf('  Future<void> _batchDelete() {');
    expect(start, isNonNegative);
    final String batchDelete =
        source.substring(start, source.indexOf('\n  }\n', start));
    expect(batchDelete, contains('_showDictionaryActionConfirmDialog('));
    expect(batchDelete, contains('appModel.deleteDictionary(dictionary)'));
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

  // BUG-044：界面缩放（FushiAppUiScale != 1.0）下，SDK ReorderableListView 的
  // Overlay 拖拽代理不认祖先 Transform.scale，长按拖拽反馈会按 (1−s)×距离 向右下漂移、
  // 飞离原位（用户截图症状）。修复=改用自实现的 FushiReorderableColumn（局部坐标长按
  // 拖拽，globalToLocal 消掉祖先缩放），缩放下精确跟手、零偏移、视觉一致。
  test(
      'dictionary list uses FushiReorderableColumn (UI-scale safe), not SDK '
      'ReorderableListView (BUG-044)', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();

    expect(source, contains('FushiReorderableColumn('));
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
    expect(rowSource, contains('FushiPlaceholderMessage'));
    expect(rowSource, contains('DictionaryMediaType.instance.outlinedIcon'));
    expect(rowSource, isNot(contains('FushiCard')));
    expect(rowSource, isNot(contains('child: Text(')));
  });

  test('dictionary manager surfaces a labeled Material action bar', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();

    // Material path empties the app bar and renders an in-page action bar.
    expect(source, contains('_buildActionBar'));
    expect(
        source, contains('if (!cupertino) _buildActionBar(compact: compact)'));
    expect(source, contains('final List<Widget> actions = cupertino'));

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
    expect(source, contains('FushiActivatableFocusTarget'));
  });

  // TODO-059：词典管理页支持桌面拖放导入。整页包一层 FushiFileDropTarget，拖入的
  // 词典包经与「导入词典」按钮同源的 _importDictionaryPaths 导入。守卫这套接线，
  // 防止后续重构悄悄把拖放摘掉或让它走偏离手动导入的旁路。
  test('dictionary manager wires desktop drag-drop import (TODO-059)', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();

    // 整页被 FushiFileDropTarget 包裹，drop 回调指向 _handleDictionaryDrop。
    expect(source, contains('FushiFileDropTarget('));
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

    expect(home, contains('FushiFileDropTarget('));
    expect(home, contains('onDrop: _handleDictionaryHomeDrop'));
    expect(home, contains('classifyDroppedFilesForDictionary(paths)'));
    expect(
        home, contains('showDictionaryMenu(initialImportPaths: importPaths)'));

    expect(model, contains('List<String> initialImportPaths'));
    expect(model, contains('DictionaryDialogPage('));
    expect(model, contains('initialImportPaths: initialImportPaths'));
  });

  // TODO-091/TODO-381：每本词典的「折叠/展开」状态必须在列表行内可一览 + 一键
  // 切换。2026-10 词典管理重做后它从行首挪到行尾开关旁（行首让给优先级序号 /
  // 多选复选框），详情里另有同一状态的三段分段控件。守卫：
  //  ① 行（_buildDictionaryTile）里直接挂折叠按钮，单击即切换，不进二级菜单；
  //  ② 行首是优先级序号徽标（多选态是复选框）；
  //  ③ 图标随折叠**三态**切换（BUG-2158：横杠=继承 / unfold_more=显式展开 /
  //     unfold_less=显式折叠，三个图标 = 状态一览）；
  //  ④ 行里没有三点菜单（TODO-422 已移除）。
  test(
      'dictionary row keeps the one-tap collapse toggle in the row '
      '(TODO-091/TODO-381, BUG-2158)', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();

    expect(source, contains('Widget _buildDictionaryCollapseButton('));

    final int tileStart = source.indexOf('Widget _buildDictionaryTile({');
    final int tileEnd = source.indexOf('Widget _buildDictionaryGroupCard({');
    expect(tileStart, isNonNegative);
    expect(tileEnd, greaterThan(tileStart));
    final String tileSource = source.substring(tileStart, tileEnd);
    // ① 折叠按钮就在行里。
    expect(tileSource, contains('_buildDictionaryCollapseButton(dictionary)'));
    // ② 行首：优先级序号 / 多选复选框。
    expect(tileSource, contains('DictionaryOrderBadge('));
    expect(tileSource, contains('FushiCheckbox('));
    expect(tileSource, contains('leading: leading'));
    // ④ 行里没有三点菜单。
    expect(tileSource, isNot(contains('Icons.more_vert')));
    expect(source, isNot(contains('getMenuItems(')));

    // ① 单击直接切换折叠状态（不经二级菜单）。
    final int btnStart =
        source.indexOf('Widget _buildDictionaryCollapseButton(');
    final int btnEnd = source.indexOf('// 用自实现的 FushiReorderableColumn');
    expect(btnStart, isNonNegative);
    expect(btnEnd, greaterThan(btnStart));
    final String btnSource = source.substring(btnStart, btnEnd);
    expect(btnSource,
        contains('appModel.cycleDictionaryCollapseState(dictionary)'));
    expect(btnSource, contains('setState(() {})'));

    // ③ 图标随**三态**切换，状态可一览（BUG-2158）。少一个分支就意味着两个态
    // 共用一个图标 —— 那正是修复前「显式展开」和「继承」长得一模一样的老毛病。
    expect(btnSource,
        contains('dictionary.collapseStateFor(JapaneseLanguage.instance)'));
    expect(btnSource, contains('DictionaryCollapseState.inherit'));
    expect(btnSource, contains('DictionaryCollapseState.expanded'));
    expect(btnSource, contains('DictionaryCollapseState.collapsed'));
    expect(btnSource, contains('Icons.horizontal_rule'));
    expect(btnSource, contains('Icons.unfold_more'));
    expect(btnSource, contains('Icons.unfold_less'));
    expect(btnSource, contains('t.options_expand'));
    expect(btnSource, contains('t.options_collapse'));
  });

  // TODO-422：词典行尾的三点菜单（旧 buildDictionaryTileTrailing / getMenuItems）
  // 已移除。2026-10 重做后改名 / 内容语言 / 更新 / 排序 / 删除都住在词典详情
  // （DictionaryManagerDetail：宽屏右侧侧板、窄屏底部 sheet）。守卫：① 整个文件
  // 不再有三点菜单方法；② 详情里有带文字的删除按钮（delete_outline +
  // options_delete），页面把它接到原删除确认对话框 showDictionaryDeleteDialog
  // （删单本流程不变）。
  test('per-dictionary delete lives in the detail panel (TODO-422)', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();
    final String panels =
        File('lib/src/pages/implementations/dictionary_manager_panels.dart')
            .readAsStringSync();

    expect(source, isNot(contains('Widget buildDictionaryTileTrailing(')));
    expect(
      source,
      isNot(contains('List<FushiPopupMenuItem<VoidCallback>> getMenuItems(')),
    );

    final int start = panels.indexOf('class DictionaryManagerDetail ');
    final int end = panels.indexOf('class _QuickActionTile ');
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    final String detail = panels.substring(start, end);
    expect(detail, contains('Icons.delete_outline'));
    expect(detail, contains('t.options_delete'));
    expect(detail, contains('onPressed: onDelete'));
    // 排序按钮（无障碍 / 手柄路径）也在详情里。
    expect(detail, contains('Icons.keyboard_arrow_up'));
    expect(detail, contains('Icons.keyboard_arrow_down'));

    expect(source, contains('showDictionaryDeleteDialog(dictionary)'));
    expect(source, contains('unawaited(showDictionaryDeleteDialog(current))'));
  });
}
