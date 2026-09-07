import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'reader_history_source_corpus.dart';

void main() {
  test('desktop dictionary page actions use FushiIconButton', () {
    final String source = File(
      'lib/src/pages/implementations/dictionary_dialog_page.dart',
    ).readAsStringSync();
    final String desktopActions = source.substring(
      source.indexOf('List<Widget> _buildDesktopPageActions()'),
      source.indexOf('List<Widget> _buildMobilePageActions()'),
    );

    expect(desktopActions, contains('FushiIconButton('));
    expect(desktopActions, isNot(contains('\n      IconButton(')));
    expect(desktopActions, isNot(contains('\n        IconButton(')));
  });

  test('custom theme page header actions use FushiIconButton', () {
    final String source = File(
      'lib/src/pages/implementations/custom_theme_page.dart',
    ).readAsStringSync();
    // BUG-2187 重设计后两个 action 提成了局部变量，在窄屏/宽屏两个 scaffold 里
    // 复用（`actions: actions,`），文件里已无 `actions: [` 字面量——旧锚点
    // indexOf 返 -1、substring 直接 RangeError。改钉这个列表本身。
    final int actionsStart =
        source.indexOf('final List<Widget> actions = <Widget>[');
    expect(actionsStart, isNonNegative,
        reason: '锚点失效：custom_theme_page 的 header actions 列表被重命名/挪走');
    final int actionsEnd = source.indexOf('\n    ];', actionsStart);
    expect(actionsEnd, greaterThan(actionsStart), reason: '找不到 actions 列表结束');
    final String headerActions = source.substring(actionsStart, actionsEnd);

    expect(headerActions, contains('FushiIconButton('));
    // 缩进无关（旧断言写死 8 空格，新代码是 6 空格，照抄会恒真）；
    // FushiIconButton 本身含子串 IconButton(，用负向 lookbehind 排掉。
    expect(headerActions, isNot(matches(RegExp(r'(?<![A-Za-z])IconButton\('))));
  });

  test('shortcut action rows use FushiIconButton for edit command', () {
    // _ActionTile lives in the action_tile part of shortcut_settings_page.dart
    // (shortcut settings refactor); the part file only contains the tile + the
    // mouse chip, so the whole file is the tile section.
    final String actionTile = File(
      'lib/src/pages/implementations/shortcut_settings/action_tile.part.dart',
    ).readAsStringSync();

    expect(actionTile, contains('FushiIconButton('));
    expect(actionTile, isNot(contains('trailing: IconButton(')));
  });

  test('reader history batch toolbar uses FushiIconButton actions', () {
    final String source = readReaderHistorySource();
    final int barStart = source.indexOf('Widget _buildBatchActionBar()');
    final int deleteStart =
        source.indexOf('Future<void> _batchDeleteConfirm()');
    final String selectionBar = source.substring(barStart, deleteStart);

    expect(selectionBar, contains('FushiIconButton('));
    expect(selectionBar, isNot(contains('\n              IconButton(')));
  });

  test('home dictionary compact toolbar uses FushiIconButton action', () {
    final String source = File(
      'lib/src/pages/implementations/home_dictionary_page.dart',
    ).readAsStringSync();
    final int toolbarStart = source.indexOf('Widget _buildSearchHeader()');
    final int bodyStart = source.indexOf('Widget _buildBody()');
    final String toolbar = source.substring(toolbarStart, bodyStart);

    expect(toolbar, contains('FushiIconButton('));
    expect(toolbar, isNot(contains('\n              IconButton(')));
  });
}
