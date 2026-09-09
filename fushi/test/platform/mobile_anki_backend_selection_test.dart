import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_card_creation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_platform_services.dart';
import '../helpers/source_guard.dart';

/// 移动端 Anki 后端选择：两个平台的原生后端都改不了已存在的 note type
/// （Android 的 AnkiDroid Content Provider / iOS 的 AnkiMobile URL scheme），
/// 因此两端同样提供「改用 AnkiConnect」。
///
/// BUG-1608：这个选择此前只对 Android 接线，iOS 连工厂都没传，`_isAndroid` 一票
/// 否决 → iOS 上 Lapis 样式区永远隐藏。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('Android keeps AnkiDroid as the default backend', () {
    final services = fakePlatformServices(
      isMobile: true,
      createAnkiRepository: AnkiRepository.new,
      createMobileAnkiConnectRepository: AnkiConnectRepository.new,
    );

    expect(services.createAnkiRepository(), isA<AnkiRepository>());
  });

  test('mobile renders AnkiConnect settings collapsed by default', () {
    final String source = File(
      'lib/src/pages/implementations/anki_settings_page.dart',
    ).readAsStringSync();

    final SettingsDestination destination = buildCardCreationDestination();
    final SettingsSection connection = destination.sections.firstWhere(
      (SettingsSection section) => section.id == 'card_creation.connection',
    );
    expect(
      connection.presentation,
      Platform.isAndroid || Platform.isIOS
          ? SettingsSectionPresentation.collapsed
          : SettingsSectionPresentation.alwaysExpanded,
    );
    // 本机只能执行一个平台分支，另锁两个移动系统共享的 schema 分支，防止 iOS 漏门控。
    final String schema = maskComments(
      File(
        'lib/src/settings/settings_schema_card_creation.dart',
      ).readAsStringSync(),
    );
    expect(
      schema,
      matches(
        RegExp(
          r'presentation:\s*Platform\.isAndroid\s*\|\|\s*Platform\.isIOS\s*'
          r'\?\s*SettingsSectionPresentation\.collapsed\s*'
          r':\s*SettingsSectionPresentation\.alwaysExpanded',
        ),
      ),
    );
    final SettingsNavigationItem entry =
        connection.items.single as SettingsNavigationItem;
    expect(entry.id, 'card_creation.connection.open');
    final SettingsDestination child = entry.child!();
    expect(child.id, SettingsDestinationId.cardCreation);
    expect(child.body, isNotNull);
    expect(
      child.bodySearchEntries.map((SettingsBodySearchEntry item) => item.id),
      containsAll(<String>[
        'card_creation.anki.connect_host',
        'card_creation.anki.connect_port',
        'card_creation.anki.connect_api_key',
      ]),
    );
    final String panel = methodBody(source, 'Widget _buildConnectionPanel(');
    expect(panel, contains('if (_isMobileAnkiPlatform)'));
    expect(panel, contains('label: t.anki_connect_host'));
    expect(panel, contains('label: t.anki_connect_port'));
    expect(panel, contains('label: t.anki_connect_api_key'));
    expect(
      panel,
      isNot(contains('collapsible:')),
      reason: '进入子页后直接显示连接字段，折叠仅由上层入口管理',
    );
    expect(source, contains('t.anki_connect_use_on_mobile'));
    expect(source, contains('obscureText: true'));
    // 清空 API key 必须经页面自己的处置入口，不能直接接 vm（BUG-1608）。
    expect(source, contains('onChanged: _updateAnkiConnectApiKey'));
  });

  test('mobile can switch to authenticated AnkiConnect immediately', () {
    final services = fakePlatformServices(
      isMobile: true,
      createAnkiRepository: AnkiRepository.new,
      createMobileAnkiConnectRepository: AnkiConnectRepository.new,
    );

    services.setUseAnkiConnectOnMobile(true, apiKey: 'secret');

    expect(services.useAnkiConnectOnMobile, isTrue);
    expect(services.createAnkiRepository(), isA<AnkiConnectRepository>());
  });

  test('iOS gets the same AnkiConnect choice as Android (BUG-1608)', () {
    // iOS 的默认后端是 AnkiMobile；这里用 AnkiRepository 占位只为断言「默认 !=
    // AnkiConnect、切换后 == AnkiConnect」这条选择逻辑，与具体默认实现无关。
    final services = fakePlatformServices(
      isMobile: true,
      createAnkiRepository: AnkiRepository.new,
      createMobileAnkiConnectRepository: AnkiConnectRepository.new,
    );

    expect(services.offersMobileAnkiConnectChoice, isTrue);
    services.setUseAnkiConnectOnMobile(true, apiKey: 'secret');
    expect(services.createAnkiRepository(), isA<AnkiConnectRepository>());
  });

  test('desktop offers no mobile backend choice', () {
    final services = fakePlatformServices(
      createAnkiRepository: AnkiConnectRepository.new,
    );

    expect(services.offersMobileAnkiConnectChoice, isFalse);
    services.setUseAnkiConnectOnMobile(true, apiKey: 'secret');
    expect(
      services.useAnkiConnectOnMobile,
      isFalse,
      reason: '桌面本来就走 AnkiConnect，没有这条支路',
    );
  });

  test('mobile restores the persisted AnkiConnect choice on init', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'fushi_anki_settings': jsonEncode(
        const AnkiSettings(
          useAnkiConnectOnMobile: true,
          ankiConnectApiKey: 'secret',
        ).toJson(),
      ),
    });
    final services = fakePlatformServices(
      isMobile: true,
      createAnkiRepository: AnkiRepository.new,
      createMobileAnkiConnectRepository: AnkiConnectRepository.new,
    );

    await services.init();

    expect(services.useAnkiConnectOnMobile, isTrue);
    expect(services.createAnkiRepository(), isA<AnkiConnectRepository>());
  });

  test('持久化键名冻结：仍读写 useAnkiConnectOnAndroid（老装置升级不丢选择）', () async {
    // Dart 侧字段已改名 useAnkiConnectOnMobile，磁盘上必须原样还是老键——改键名
    // 会让所有老装置的选择在升级后静默变回默认后端。
    expect(
      const AnkiSettings(
        useAnkiConnectOnMobile: true,
      ).toJson()['useAnkiConnectOnAndroid'],
      isTrue,
    );
    expect(
      AnkiSettings.fromJson(<String, dynamic>{
        'useAnkiConnectOnAndroid': true,
      }).useAnkiConnectOnMobile,
      isTrue,
    );
  });

  test(
    'mobile fails closed when persisted remote backend has no API key',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'fushi_anki_settings': jsonEncode(
          const AnkiSettings(useAnkiConnectOnMobile: true).toJson(),
        ),
      });
      final services = fakePlatformServices(
        isMobile: true,
        createAnkiRepository: AnkiRepository.new,
        createMobileAnkiConnectRepository: AnkiConnectRepository.new,
      );

      await services.init();

      expect(services.useAnkiConnectOnMobile, isFalse);
      expect(services.createAnkiRepository(), isA<AnkiRepository>());
      expect(
        (await AnkiRepository().loadSettings()).useAnkiConnectOnMobile,
        isFalse,
      );
    },
  );

  group('BUG-1608 ankiConnectUsableOnMobile 是唯一判据', () {
    test('开关开 + key 非空 → 可用', () {
      expect(
        const AnkiSettings(
          useAnkiConnectOnMobile: true,
          ankiConnectApiKey: 'secret',
        ).ankiConnectUsableOnMobile,
        isTrue,
      );
    });

    test('开关开但 key 被清空 → 不可用（移动端强制要求 API key）', () {
      expect(
        const AnkiSettings(
          useAnkiConnectOnMobile: true,
          ankiConnectApiKey: '   ',
        ).ankiConnectUsableOnMobile,
        isFalse,
        reason: '纯空白等同于没填',
      );
    });

    test('开关关 → 不可用（即便填了 key）', () {
      expect(
        const AnkiSettings(
          ankiConnectApiKey: 'secret',
        ).ankiConnectUsableOnMobile,
        isFalse,
      );
    });

    test('运行时选择与判据一致：清空 key 后立即回落原生后端', () {
      final services = fakePlatformServices(
        isMobile: true,
        createAnkiRepository: AnkiRepository.new,
        createMobileAnkiConnectRepository: AnkiConnectRepository.new,
      );
      services.setUseAnkiConnectOnMobile(true, apiKey: 'secret');
      expect(services.createAnkiRepository(), isA<AnkiConnectRepository>());

      // 用户清空了 API key：设置页当场以同一判据重算，运行时必须立刻改回原生
      // 后端，而不是拖到下次启动 init() 才静默纠正。
      services.setUseAnkiConnectOnMobile(true, apiKey: '');
      expect(services.useAnkiConnectOnMobile, isFalse);
      expect(services.createAnkiRepository(), isA<AnkiRepository>());
    });
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
