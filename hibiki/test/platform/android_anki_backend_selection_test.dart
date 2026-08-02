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
    expect(source, contains('obscureText: true'));
  });

  test('Android can switch to authenticated AnkiConnect immediately', () {
    final services = fakePlatformServices(
      isAndroid: true,
      createAnkiRepository: AnkiRepository.new,
      createAndroidAnkiConnectRepository: AnkiConnectRepository.new,
    );

    services.setUseAnkiConnectOnAndroid(true, apiKey: 'secret');

    expect(services.useAnkiConnectOnAndroid, isTrue);
    expect(services.createAnkiRepository(), isA<AnkiConnectRepository>());
  });

  test('Android restores the persisted AnkiConnect choice on init', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'hoshi_anki_settings': jsonEncode(
        const AnkiSettings(
          useAnkiConnectOnAndroid: true,
          ankiConnectApiKey: 'secret',
        ).toJson(),
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

  test('Android fails closed when persisted remote backend has no API key',
      () async {
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

    expect(services.useAnkiConnectOnAndroid, isFalse);
    expect(services.createAnkiRepository(), isA<AnkiRepository>());
    expect(
      (await AnkiRepository().loadSettings()).useAnkiConnectOnAndroid,
      isFalse,
    );
  });

  test('backend switch can clear configuration from the previous backend', () {
    const AnkiSettings configured = AnkiSettings(
      selectedDeckId: 42,
      selectedDeckName: 'Old deck',
      selectedNoteTypeId: 7,
      selectedNoteTypeName: 'Old model',
      availableDecks: <AnkiDeck>[AnkiDeck(id: 42, name: 'Old deck')],
      availableNoteTypes: <AnkiNoteType>[
        AnkiNoteType(id: 7, name: 'Old model', fields: <String>['Front']),
      ],
      fieldMappings: <String, String>{'Front': 'term'},
    );

    final AnkiSettings cleared = configured.copyWith(
      clearSelectedDeck: true,
      clearSelectedNoteType: true,
      availableDecks: const <AnkiDeck>[],
      availableNoteTypes: const <AnkiNoteType>[],
      fieldMappings: const <String, String>{},
    );

    expect(cleared.selectedDeckId, isNull);
    expect(cleared.selectedNoteTypeId, isNull);
    expect(cleared.availableDecks, isEmpty);
    expect(cleared.availableNoteTypes, isEmpty);
    expect(cleared.fieldMappings, isEmpty);
    expect(cleared.isConfigured, isFalse);
  });
}
