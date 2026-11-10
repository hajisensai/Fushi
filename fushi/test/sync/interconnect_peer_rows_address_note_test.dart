import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/sync/interconnect_dictionary_lookup_section.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// BUG-4274：「配对与设备 → 已添加的设备」逐地址成行（排序 = 组内选路优先级，开关 /
/// 测试结果 / 重新配对都按地址）。配对一台服务器后 host 公布的第二条地址被学进来，
/// 两行标题都是同一个设备名「TestServer」，看起来像重复配对。每行加注记：第几条、
/// 什么网络、是否自动学到；只有一条地址的设备不加。
const String _paired = 'https://192.0.2.10:38865';
const String _learned = 'https://192.0.2.11:38865';
const String _other = 'http://192.168.1.50:38765';

const List<FushiClientUrl> _seed = <FushiClientUrl>[
  FushiClientUrl(
    url: _paired,
    hostId: 'wwy-host',
    deviceName: 'TestServer',
    token: 'tok',
    fingerprintSha256: 'aa:bb',
  ),
  FushiClientUrl(
    url: _learned,
    hostId: 'wwy-host',
    deviceName: 'TestServer',
    token: 'tok',
    fingerprintSha256: 'aa:bb',
    learned: true,
    addressKind: 'lan',
  ),
  // 手输、没有 hostId 的老条目：单独一台，不加注记。
  FushiClientUrl(url: _other, deviceName: 'Laptop'),
];

FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

SettingsDestination _devicesPage() {
  for (final SettingsSection section
      in buildInterconnectDestination().sections) {
    for (final SettingsItem item in section.items) {
      if (item is SettingsNavigationItem && item.id == 'interconnect.devices') {
        return item.child!();
      }
    }
  }
  throw StateError('interconnect.devices navigation item not found');
}

Future<SyncRepository> _pumpDevicesPage(WidgetTester tester) async {
  FocusManager.instance.highlightStrategy =
      FocusHighlightStrategy.alwaysTraditional;
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final FushiDatabase db = _testDb();
  final PreferencesRepository prefs = PreferencesRepository(db);
  await prefs.loadFromDb();
  final Directory storeDir = Directory.systemTemp.createTempSync(
    'fushi_peer_rows',
  );
  final SyncRepository repo = SyncRepository(db);
  await repo.setInterconnectEnabled(true);
  await repo.setFushiClientUrls(_seed);

  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('material'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('light'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  final AppModel appModel = AppModel(testPlatformServices())
    ..themeNotifier = themeNotifier
    ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir)
    ..wireDatabaseForTesting(db);
  addTearDown(() async {
    themeNotifier.dispose();
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            platform: TargetPlatform.android,
            extensions: <ThemeExtension<dynamic>>[
              FushiDesignSystemTheme(themeNotifier.designSystemTheme),
            ],
          ),
          home: Scaffold(
            body: FushiFocusRoot(
              child: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) =>
                    Consumer(
                      builder: (BuildContext context, WidgetRef ref, _) {
                        final SettingsContext sc = SettingsContext(
                          context: context,
                          appModel: ref.read(appProvider),
                          ref: ref,
                          readerSource: ReaderFushiSource.instance,
                          refresh: () => setState(() {}),
                        );
                        return const MaterialSettingsRenderer()
                            .buildDetailContent(
                              settingsContext: sc,
                              destination: _devicesPage(),
                              scrollController: ScrollController(),
                            );
                      },
                    ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _pumpFrames(tester);
  return repo;
}

/// 页面有常驻动画（LAN 发现进度），不能 pumpAndSettle；有界推帧让异步 load 落地。
Future<void> _pumpFrames(WidgetTester tester) async {
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  // 测试字体 Ahem 偏宽，行尾按钮的 RenderFlex 溢出是字体伪影（同 golden 测试）。
  while (tester.takeException() != null) {}
}

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey<String>(key))).data!;

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
  late Directory ppDir;
  setUpAll(() {
    ppDir = Directory.systemTemp.createTempSync('fushi_pp');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => ppDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (ppDir.existsSync()) ppDir.deleteSync(recursive: true);
  });
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    resetSyncSettingsStateForTest();
  });
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  group('interconnectPeerAddressSlotOf / interconnectPeerAddressNote', () {
    test('multi-address host: index follows list order, learned flagged', () {
      expect(interconnectPeerAddressSlotOf(_seed, _seed[0]), (
        index: 1,
        count: 2,
        rank: 0,
        learned: false,
      ));
      expect(interconnectPeerAddressSlotOf(_seed, _seed[1]), (
        index: 2,
        count: 2,
        rank: 0,
        learned: true,
      ));
      expect(
        interconnectPeerAddressNote(_seed, _seed[0]),
        'Address 1 of 2 for this device · Local network',
      );
      expect(
        interconnectPeerAddressNote(_seed, _seed[1]),
        'Address 2 of 2 for this device · Local network · Found automatically',
      );
    });

    test('single-address host and entries without hostId get no note', () {
      expect(interconnectPeerAddressSlotOf(_seed, _seed[2]), isNull);
      expect(interconnectPeerAddressNote(_seed, _seed[2]), isNull);
      // 两条手输、都没有 hostId → 各自一台，不互相注记。
      const List<FushiClientUrl> legacy = <FushiClientUrl>[
        FushiClientUrl(url: 'http://192.168.1.2:38765', deviceName: 'X'),
        FushiClientUrl(url: 'http://192.168.1.3:38765', deviceName: 'X'),
      ];
      expect(interconnectPeerAddressNote(legacy, legacy[0]), isNull);
      expect(interconnectPeerAddressNote(legacy, legacy[1]), isNull);
    });

    test('network kind comes from the host label, else from the URL', () {
      const List<FushiClientUrl> kinds = <FushiClientUrl>[
        FushiClientUrl(url: 'https://100.70.0.1:1', hostId: 'h'),
        FushiClientUrl(url: 'https://[2001:db8::1]:1', hostId: 'h'),
        FushiClientUrl(url: 'https://box.example.com:1', hostId: 'h'),
        FushiClientUrl(
          url: 'p2p://node',
          hostId: 'h',
          learned: true,
          addressKind: 'p2p',
        ),
      ];
      expect(
        <String?>[
          for (final FushiClientUrl u in kinds)
            interconnectPeerAddressNote(kinds, u),
        ],
        <String>[
          'Address 1 of 4 for this device · Virtual network',
          'Address 2 of 4 for this device · IPv6',
          'Address 3 of 4 for this device · Internet',
          'Address 4 of 4 for this device · P2P tunnel · Found automatically',
        ],
      );
    });
  });

  testWidgets('added peers: two addresses of one server are annotated, not '
      'duplicates; keyboard reorder keeps the notes in priority order', (
    WidgetTester tester,
  ) async {
    final SyncRepository repo = await _pumpDevicesPage(tester);

    // 同一台 host 的两行：标题都是设备名，各带地址与注记。
    for (final String url in <String>[_paired, _learned]) {
      expect(_textOf(tester, 'interconnect-peer-title-$url'), 'TestServer');
      expect(_textOf(tester, 'interconnect-peer-url-$url'), url);
    }
    expect(
      _textOf(tester, 'interconnect-peer-address-note-$_paired'),
      'Address 1 of 2 for this device · Local network',
    );
    expect(
      _textOf(tester, 'interconnect-peer-address-note-$_learned'),
      'Address 2 of 2 for this device · Local network · Found automatically',
    );
    // 单地址设备不加注记。
    expect(
      find.byKey(
        const ValueKey<String>('interconnect-peer-address-note-$_other'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('interconnect-peer-title-$_other')),
      findsOneWidget,
    );

    // 焦点驱动：聚焦学到那一行的「上移」按钮、回车 → 它成为这台 host 的首选地址，
    // 注记跟着列表顺序（= 选路优先级）更新。
    final Finder learnedRow = find.ancestor(
      of: find.byKey(
        const ValueKey<String>('interconnect-peer-title-$_learned'),
      ),
      matching: find.byType(FushiListItem),
    );
    final Finder moveUp = find.descendant(
      of: learnedRow,
      matching: find.byTooltip(t.move_up),
    );
    expect(moveUp, findsOneWidget);
    final Element leaf = tester.element(
      find
          .descendant(of: moveUp, matching: find.byWidgetPredicate((_) => true))
          .last,
    );
    Focus.of(leaf).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _pumpFrames(tester);

    expect(
      (await repo.getFushiClientUrls()).map((FushiClientUrl u) => u.url),
      <String>[_learned, _paired, _other],
    );
    expect(
      _textOf(tester, 'interconnect-peer-address-note-$_learned'),
      'Address 1 of 2 for this device · Local network · Found automatically',
    );
    expect(
      _textOf(tester, 'interconnect-peer-address-note-$_paired'),
      'Address 2 of 2 for this device · Local network',
    );
  });
}
