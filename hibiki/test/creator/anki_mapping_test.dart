import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/src/language/implementations/japanese_language.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('default Japanese mapping auto-generates term audio', () {
    final mapping = AnkiMapping.defaultMapping(
      language: JapaneseLanguage.instance,
      order: 0,
    );

    expect(
      mapping.getAutoFieldEnhancementName(field: AudioField.instance),
      LocalAudioEnhancement.key,
    );
  });
}
