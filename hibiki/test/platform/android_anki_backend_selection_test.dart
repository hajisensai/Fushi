import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_platform_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('Android keeps AnkiDroid as the default backend', () {
    final services = fakePlatformServices(
      isAndroid: true,
      createAnkiRepository: AnkiRepository.new,
      createAndroidAnkiConnectRepository: AnkiConnectRepository.new,
    );

    expect(services.createAnkiRepository(), isA<AnkiRepository>());
  });

  test('Android renders AnkiConnect settings collapsed by default', () {
    final String source = File(
      'lib/src/pages/implementations/anki_settings_page.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('if (!Platform.isAndroid)')));
    expect(source, contains('collapsible: Platform.isAndroid'));
    expect(source, contains('initiallyExpanded: !Platform.isAndroid'));
    expect(source, contains('t.anki_connect_use_on_android'));
  });

  test('Android can switch to AnkiConnect immediately', () {
    final services = fakePlatformServices(
      isAndroid: true,
      createAnkiRepository: AnkiRepository.new,
      createAndroidAnkiConnectRepository: AnkiConnectRepository.new,
    );

    services.setUseAnkiConnectOnAndroid(true);

    expect(services.useAnkiConnectOnAndroid, isTrue);
    expect(services.createAnkiRepository(), isA<AnkiConnectRepository>());
  });

  test('Android restores the persisted AnkiConnect choice on init', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'hoshi_anki_settings': jsonEncode(
        const AnkiSettings(useAnkiConnectOnAndroid: true).toJson(),
      ),
    });
    final services = fakePlatformServices(
      isAndroid: true,
      createAnkiRepository: AnkiRepository.new,
      createAndroidAnkiConnectRepository: AnkiConnectRepository.new,
    );

    await services.init();

    expect(services.useAnkiConnectOnAndroid, isTrue);
    expect(services.createAnkiRepository(), isA<AnkiConnectRepository>());
  });
}
