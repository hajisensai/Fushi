import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/sync_client/anki_sync_client_section.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/anki_sync/anki_sync_session.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/fake_platform_services.dart';

/// 「Anki 同步客户端」设置节的折叠语义（PR #2678 审查）：
/// - 只对**未启用**的用户默认折叠；已启用的用户必须直接看到状态 / 未同步告警；
/// - 设置搜索跳到本节开关时，折叠着也要先展开，落点才会构建并消费挂点。
class _SettingsRepository extends FakeAnkiRepository {
  _SettingsRepository(this._initial);

  final AnkiSettings _initial;

  @override
  Future<AnkiSettings> loadSettings() async => _initial;
}

PlatformServices _services(AnkiSyncSession session) => PlatformServices(
  directory: FakeDirectoryService(),
  lifecycle: FakeLifecycleService(),
  clipboard: FakeClipboardService(),
  permission: FakePermissionService(),
  deviceInfo: FakeDeviceInfoService(),
  createAnkiRepository: AnkiConnectRepository.new,
  ankiSyncSession: () => session,
);

void main() {
  late Directory root;
  late AnkiSyncSession session;

  setUp(() {
    root = Directory.systemTemp.createTempSync('anki_sync_section_');
    session = AnkiSyncSession(
      root: () async => root,
      startClient: () async => throw StateError('测试里不该启动同步助手'),
    );
    SettingsSearchReveal.pendingItemId = null;
  });

  tearDown(() {
    SettingsSearchReveal.pendingItemId = null;
    root.deleteSync(recursive: true);
  });

  Future<void> pumpSection(WidgetTester tester, {required bool enabled}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(_services(session)),
          ankiRepositoryProvider.overrideWith(
            (Ref ref) =>
                _SettingsRepository(AnkiSettings(useAnkiSyncClient: enabled)),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: AnkiSyncClientSection()),
          ),
        ),
      ),
    );
    // 让 AnkiViewModel 装载完设置（假仓库同步完成，只需排空微任务）。
    await tester.pump();
    await tester.pump();
  }

  Future<void> closeSession(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(session.close);
  }

  testWidgets('未启用：默认折叠，只露出展开行', (WidgetTester tester) async {
    await pumpSection(tester, enabled: false);
    expect(find.text(t.anki_sync_client_advanced_title), findsOneWidget);
    expect(find.text(t.anki_sync_client_use_title), findsNothing);
    expect(find.text(t.anki_sync_client_status_signed_out), findsNothing);

    await tester.tap(find.text(t.anki_sync_client_advanced_title));
    await tester.pump();
    expect(find.text(t.anki_sync_client_use_title), findsOneWidget);
    await closeSession(tester);
  });

  testWidgets('已启用：默认展开，状态行直接可见（不把未同步告警藏起来）', (WidgetTester tester) async {
    await pumpSection(tester, enabled: true);
    expect(find.text(t.anki_sync_client_use_title), findsOneWidget);
    expect(find.text(t.anki_sync_client_status_signed_out), findsOneWidget);

    // 用户亲手折起来就尊重用户。
    await tester.tap(find.text(t.anki_sync_client_advanced_title));
    await tester.pump();
    expect(find.text(t.anki_sync_client_status_signed_out), findsNothing);
    await closeSession(tester);
  });

  testWidgets('搜索跳到本节开关：折叠着也先展开，落点消费挂点并定位高亮', (WidgetTester tester) async {
    SettingsSearchReveal.pendingItemId = kAnkiSyncClientSearchTargetId;
    await pumpSection(tester, enabled: false);
    expect(find.text(t.anki_sync_client_use_title), findsOneWidget);
    expect(SettingsSearchReveal.pendingItemId, isNull, reason: '挂点不得悬挂');
    expect(find.byType(SettingsRevealTarget), findsOneWidget);
    await tester.pumpAndSettle();
    await closeSession(tester);
  });
}
