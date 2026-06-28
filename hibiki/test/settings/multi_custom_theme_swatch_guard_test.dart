import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// TODO-930 M1/M2 source-scan guards. A full widget test of the theme swatch row
// or the editor would need the whole AppModel/InAppWebView stack; the structure
// that matters (multi-swatch loop, +new swatch, per-id routing, name field,
// delete button, list-model apply path) is pinned by a source scan so reverting
// the work turns these red. Behaviour of the underlying data API is covered by
// test/models/multi_custom_theme_ui_test.dart.

void main() {
  final String actions =
      File('lib/src/settings/settings_actions.dart').readAsStringSync();
  final String page =
      File('lib/src/pages/implementations/custom_theme_page.dart')
          .readAsStringSync();

  group('M1 swatch row renders one swatch per custom theme', () {
    test('iterates appModel.customThemes into swatches', () {
      expect(actions.contains('appModel.customThemes.map('), isTrue,
          reason: 'swatch row no longer loops over the custom theme list');
    });

    test('tapping a swatch pins the theme by id (custom-theme:<id>)', () {
      expect(actions.contains(r'custom-theme:${e.id}'), isTrue,
          reason: 'swatch tap must write app_theme_key=custom-theme:<id>');
    });

    test('long-press a swatch edits that specific theme', () {
      expect(actions.contains('CustomThemePage(themeId: e.id)'), isTrue,
          reason: 'long-press must open the editor for that entry');
    });

    test('has a +new swatch that creates a blank theme then edits it', () {
      expect(actions.contains('createBlankCustomTheme(appModel)'), isTrue,
          reason: 'missing the +new swatch create path');
      expect(actions.contains('Icons.add'), isTrue,
          reason: 'the +new swatch needs an add overlay icon');
    });

    test('keeps a focus-reachable edit button', () {
      expect(actions.contains('t.edit_custom_theme'), isTrue,
          reason: 'the focus/gamepad edit button was removed');
    });

    test('default display name falls back to Custom N', () {
      expect(actions.contains('t.custom_theme_default_name(n:'), isTrue,
          reason: 'default-name helper must use the localized Custom N key');
    });
  });

  group('M2 editor edits a specific entry with name + delete', () {
    test('CustomThemePage accepts an optional themeId', () {
      expect(page.contains('this.themeId'), isTrue,
          reason: 'editor must accept a themeId to edit a specific entry');
      expect(page.contains('final String? themeId;'), isTrue);
    });

    test('renders a name field bound to the name controller', () {
      expect(page.contains('_buildNameField()'), isTrue,
          reason: 'name field builder missing');
      expect(page.contains('controller: _nameController'), isTrue);
      expect(page.contains('t.custom_theme_name'), isTrue);
    });

    test('apply routes through the list model (upsert + select + key)', () {
      expect(page.contains('appModel.upsertCustomTheme(entry)'), isTrue,
          reason: 'apply must persist into the list model');
      expect(page.contains('appModel.selectCustomTheme(entry.id)'), isTrue);
      expect(
          page.contains(r"appModel.setAppThemeKey('custom-theme:${entry.id}')"),
          isTrue);
    });

    test('has a delete button + confirm + post-delete fallback', () {
      expect(page.contains('t.delete_custom_theme'), isTrue,
          reason: 'delete button label missing');
      expect(page.contains('appModel.deleteCustomTheme(_entryId)'), isTrue);
      expect(page.contains('t.delete_custom_theme_confirm'), isTrue,
          reason: 'delete must show a confirm dialog');
      expect(page.contains('_resolveThemeKeyAfterDelete('), isTrue,
          reason: 'post-delete fallback (decision 1) missing');
      expect(page.contains("'system-theme'"), isTrue,
          reason: 'empty-list delete must fall back to system-theme');
    });

    test('share-code wire is unchanged (id/name not in the code)', () {
      // The share code is still hibiki-theme:<seed>:<mode>[:fc..]; no id/name
      // field was added (M3), so the encoder still starts with that prefix.
      expect(page.contains("var code = 'hibiki-theme:"), isTrue,
          reason: 'share-code wire format changed unexpectedly');
    });
  });
}
