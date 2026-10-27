import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/lapis_style_editor_page.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/ops/ctl_settings_body_anki.dart';
import 'package:fushi/src/ops/ctl_settings_body_anki_sync.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/anki_sync/anki_sync_session.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/fake_platform_services.dart';
import '../helpers/test_platform_services.dart';

const AnkiSettings _settings = AnkiSettings(
  selectedNoteTypeId: 1,
  availableNoteTypes: <AnkiNoteType>[
    AnkiNoteType(
      id: 1,
      name: 'Lapis',
      fields: <String>['Expression', 'Sentence'],
    ),
  ],
  fieldMappings: <String, String>{'Expression': '{expression}'},
  lapisCustomCss: '.a { color: red }',
  lapisCustomBlocks: <LapisCustomBlock>[
    LapisCustomBlock(
      id: 'b1',
      anchor: LapisBlockAnchor.top,
      fields: <String>['Sentence'],
    ),
  ],
);

PlatformServices _services(AnkiSyncSession? session) => PlatformServices(
  directory: FakeDirectoryService(),
  lifecycle: FakeLifecycleService(),
  clipboard: FakeClipboardService(),
  permission: FakePermissionService(),
  deviceInfo: FakeDeviceInfoService(),
  createAnkiRepository: AnkiConnectRepository.new,
  ankiSyncSession: () => session,
);

SettingsActionItem _syncAction(String id) => buildCtlBodyPages()
    .expand((CtlBodyPage p) => p.items)
    .whereType<SettingsActionItem>()
    .firstWhere((SettingsActionItem i) => i.id == id);

void main() {
  group('Lapis 可视化编辑器 JSON', () {
    test('读出 = 编辑器保存交回的整份（CSS + 区域 + 字段映射），写读互逆', () {
      final Map<String, Object?> json = ctlLapisVisualEditorJson(_settings);
      expect(json['customCss'], '.a { color: red }');
      expect((json['blocks']! as List).single, containsPair('id', 'b1'));
      expect(json['fieldMappings'], <String, String>{
        'Expression': '{expression}',
        'Sentence': '',
      });
      final LapisVisualEditorResult back = parseCtlLapisVisualEditorJson(
        jsonEncode(json),
        _settings,
      );
      expect(back.customCss, _settings.lapisCustomCss);
      expect(back.blocks.single.id, 'b1');
      expect(back.fieldMappings['Sentence'], '');
    });

    test('缺的键沿用当前值，映射缺省 = 不改', () {
      final LapisVisualEditorResult r = parseCtlLapisVisualEditorJson(
        '{"customCss":".b{}"}',
        _settings,
      );
      expect(r.customCss, '.b{}');
      expect(r.blocks, _settings.lapisCustomBlocks);
      expect(r.fieldMappings, isEmpty);
    });

    test('写入前整体校验：坏 JSON / 未知键 / 类型不对 / 区域不合法 / 字段不存在', () {
      for (final String bad in <String>[
        '{',
        '[]',
        '{"css":""}',
        '{"customCss":1}',
        '{"blocks":{}}',
        '{"blocks":[{"id":"b1","anchor":"nowhere","fields":[]}]}',
        '{"blocks":[{"id":"b1","anchor":"top"},{"id":"b1","anchor":"top"}]}',
        '{"fieldMappings":[]}',
        '{"fieldMappings":{"Expression":1}}',
      ]) {
        expect(
          () => parseCtlLapisVisualEditorJson(bad, _settings),
          throwsFormatException,
          reason: bad,
        );
      }
      expect(
        () => parseCtlLapisVisualEditorJson(
          '{"fieldMappings":{"Nope":"{x}"}}',
          _settings,
        ),
        throwsArgumentError,
      );
    });
  });

  group('内置 Anki 同步客户端', () {
    late Directory root;
    late SettingsContext settings;

    Future<void> capture(WidgetTester tester, AnkiSyncSession? session) async {
      final AppModel app = AppModel(testPlatformServices());
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            platformServicesProvider.overrideWithValue(_services(session)),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (BuildContext context, WidgetRef ref, Widget? _) {
                settings = SettingsContext(
                  context: context,
                  appModel: app,
                  ref: ref,
                  readerSource: ReaderFushiSource.instance,
                  refresh: () {},
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
    }

    setUp(() => root = Directory.systemTemp.createTempSync('anki_sync_cli_'));
    tearDown(() => root.deleteSync(recursive: true));

    test('状态 JSON 只有服务器与用户名，hkey 永不出现', () {
      final Map<String, Object?> json = ankiSyncClientStatusJson(
        const AnkiSyncState(phase: AnkiSyncPhase.idle),
        const AnkiSyncAccount(
          server: null,
          endpoint: null,
          username: 'alice',
          hkey: 'super-secret-hkey',
        ),
        enabled: true,
      );
      expect(json['username'], 'alice');
      expect(json['server'], 'AnkiWeb');
      expect(jsonEncode(json), isNot(contains('super-secret-hkey')));
    });

    testWidgets('本机没有同步客户端：整页不可见，动作报 StateError', (WidgetTester tester) async {
      await capture(tester, null);
      final CtlBodyPage page = buildCtlAnkiSyncBodyPages().single;
      expect(page.visible!(settings), isFalse);
      await expectLater(
        _syncAction('card_creation.anki.sync_client.status').cli!.run!(
          settings,
          const <String, String>{},
        ),
        throwsStateError,
      );
    });

    testWidgets('登录 AnkiWeb 必须显式确认；空用户名 / 密码拒绝；未登录状态', (
      WidgetTester tester,
    ) async {
      final AnkiSyncSession session = AnkiSyncSession(
        root: () async => root,
        startClient: () async => throw StateError('测试里不该启动同步助手'),
      );
      await capture(tester, session);
      final SettingsCliRun signIn = _syncAction(
        'card_creation.anki.sync_client.sign_in',
      ).cli!.run!;
      await expectLater(
        signIn(settings, const <String, String>{
          'username': 'alice',
          'password': 'pw',
        }),
        throwsArgumentError,
      );
      await expectLater(
        signIn(settings, const <String, String>{
          'server': 'https://sync.example',
          'username': ' ',
          'password': 'pw',
        }),
        throwsArgumentError,
      );
      final Map<String, Object?> status =
          await tester.runAsync(
                () async =>
                    await _syncAction(
                          'card_creation.anki.sync_client.status',
                        ).cli!.run!(settings, const <String, String>{})
                        as Map<String, Object?>,
              )
              as Map<String, Object?>;
      expect(status['signedIn'], isFalse);
      final SettingsCliParam password = _syncAction(
        'card_creation.anki.sync_client.sign_in',
      ).cli!.params.firstWhere((SettingsCliParam p) => p.name == 'password');
      expect(password.secret, isTrue, reason: '密码只走 stdin / 环境变量');
      expect(
        _syncAction(
          'card_creation.anki.sync_client.sign_out_discard',
        ).cli!.confirm,
        isTrue,
      );
      await tester.runAsync(session.close);
    });
  });
}
