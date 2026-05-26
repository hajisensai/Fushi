import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
