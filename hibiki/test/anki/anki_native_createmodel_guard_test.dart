import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final java = File(
    'android/app/src/main/java/app/hibiki/reader/AnkiChannelHandler.java',
  ).readAsStringSync();
  final repo = File(
    '../packages/hibiki_anki/lib/src/ankidroid/anki_repository.dart',
  ).readAsStringSync();

  group('AnkiDroid native create path is schema-driven', () {
    test('native handler has createNoteType + createDeck cases', () {
      expect(java, contains('case "createNoteType"'));
      expect(java, contains('case "createDeck"'));
      expect(java, contains('addNewCustomModel'));
      expect(java, contains('addNewDeck'));
    });

    test('legacy hardcoded Lapis model is gone', () {
      expect(java.contains('case "addDefaultModel"'), isFalse);
      expect(java.contains('"Cloze Before"'), isFalse,
          reason: 'old Term/Meaning hardcoded schema must be removed');
      expect(java.contains('"Expanded Meaning"'), isFalse);
    });

    test('Dart repo invokes the schema-driven channel methods', () {
      expect(repo, contains("invokeMethod('createNoteType'"));
      expect(repo, contains("invokeMethod('createDeck'"));
      expect(repo, contains('noteTypeFields'));
    });
  });

  group('settings page wires the Create Lapis action', () {
    final page = File(
      'lib/src/pages/implementations/anki_settings_page.dart',
    ).readAsStringSync();

    test('calls createLapisSetup and uses the i18n label', () {
      expect(page, contains('createLapisSetup()'));
      expect(page, contains('t.anki_create_lapis'));
    });
  });
}
