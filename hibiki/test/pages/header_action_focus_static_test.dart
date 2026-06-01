import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop dictionary page actions use HibikiIconButton', () {
    final String source = File(
      'lib/src/pages/implementations/dictionary_dialog_page.dart',
    ).readAsStringSync();
    final String desktopActions = source.substring(
      source.indexOf('List<Widget> _buildDesktopPageActions()'),
      source.indexOf('List<Widget> _buildMobilePageActions()'),
    );

    expect(desktopActions, contains('HibikiIconButton('));
    expect(desktopActions, isNot(contains('\n      IconButton(')));
    expect(desktopActions, isNot(contains('\n        IconButton(')));
  });

  test('custom theme page header actions use HibikiIconButton', () {
    final String source = File(
      'lib/src/pages/implementations/custom_theme_page.dart',
    ).readAsStringSync();
    final int actionsStart = source.indexOf('actions: [');
    final int childrenStart = source.indexOf('children: [', actionsStart);
    final String headerActions = source.substring(actionsStart, childrenStart);

    expect(headerActions, contains('HibikiIconButton('));
    expect(headerActions, isNot(contains('\n        IconButton(')));
  });
}
