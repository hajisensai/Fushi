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
    final int actionsStart = source.indexOf('actions: [');
    final int childrenStart = source.indexOf('children: [', actionsStart);
    final String headerActions = source.substring(actionsStart, childrenStart);

    expect(headerActions, contains('FushiIconButton('));
    expect(headerActions, isNot(contains('\n        IconButton(')));
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
