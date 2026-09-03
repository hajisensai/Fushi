import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final java = File(
    'android/app/src/main/java/app/fushi/reader/AnkiChannelHandler.java',
  ).readAsStringSync();
  final repo = File(
    '../packages/fushi_anki/lib/src/ankidroid/anki_repository.dart',
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
    // BUG-1902：这一行的实现搬进了共享组件 `anki/anki_config_controls.dart`，
    // 好让新手引导用**同一份**实现（此前它是本页的私有方法，跨文件不可见，引导页
    // 只能显示三行只读文本）。守卫跟着实现走：页面负责挂载，组件负责调用与文案。
    final controls = File(
      'lib/src/anki/anki_config_controls.dart',
    ).readAsStringSync();

    test('page mounts the shared row and the row calls createLapisSetup', () {
      expect(page, contains('AnkiCreateLapisRow('));
      expect(controls, contains('createLapisSetup()'));
      expect(controls, contains('t.anki_create_lapis'));
    });
  });
}
