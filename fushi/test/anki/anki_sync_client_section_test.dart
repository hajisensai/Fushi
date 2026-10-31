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
import 'package:fushi_engine/anki_sync/fushi_anki_sync_client.dart';
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

/// 同步时被服务器限流（HTTP 429）的 helper，错误是 rslib 的 Debug 原文。
class _RateLimitedHelper implements FushiAnkiSyncClient {
  @override
  bool get isDead => false;

  @override
  Future<bool> open(String path) async => true;

  @override
  Future<void> fullDownload({required String hkey, String? endpoint}) async {}

  @override
  Future<Set<int>> existingNotes(List<(int, String)> notes) async => <int>{};

  @override
  Future<AnkiSyncResult> sync({required String hkey, String? endpoint}) async =>
      throw const FushiAnkiSyncException(
        'NetworkError { source: NetworkError { info: "HTTP status client '
        'error (429 Too Many Requests) for url ()", kind: Other } }',
      );

  @override
  Future<void> close() async {}

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

  // 反馈 PT6NCk7Pbo：限流时状态行给人话与自动重试时刻，不给 Rust 调试原文。
  testWidgets('同步被限流（429）：状态行说明限流与自动重试，不显示 helper 原文', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      await session.close();
      File('${root.path}/account.json').writeAsStringSync(
        '{"server":null,"endpoint":null,"username":"u","hkey":"k"}',
      );
      session = AnkiSyncSession(
        root: () async => root,
        startClient: () async => _RateLimitedHelper(),
        syncDelay: const Duration(days: 1),
      );
      await expectLater(session.syncNow(), throwsA(anything));
    });
    expect(session.state.rateLimitedUntil, isNotNull);

    await pumpSection(tester, enabled: true);
    // 账号读盘与状态刷新是真文件 IO，每一跳都要让出真实事件循环再泵一帧。
    for (int i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    final String texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((Text w) => w.data ?? w.textSpan?.toPlainText() ?? '')
        .join(' | ');
    expect(
      find.textContaining('The sync server is limiting requests'),
      findsOneWidget,
      reason: texts,
    );
    expect(find.textContaining('NetworkError'), findsNothing);
    await closeSession(tester);
  });

  /// 「重启」：只有账号与落盘的限流冷却（`rate_limit.json`），会话还没同步过。
  Future<void> pumpRestartedWithCooldown(
    WidgetTester tester, {
    required int until,
  }) async {
    File('${root.path}/account.json').writeAsStringSync(
      '{"server":null,"endpoint":null,"username":"u","hkey":"k"}',
    );
    File(
      '${root.path}/rate_limit.json',
    ).writeAsStringSync('{"until":$until,"strikes":1}');
    await pumpSection(tester, enabled: true);
    // 账号 / 冷却 / 日志读盘都是真文件 IO，续体排在测试的假时钟 zone 里：每一跳都
    // 让出真实事件循环再泵一帧，直到状态行带出限流说明；之后再多排几轮，让状态事件
    // 触发的那次账号读盘也走完（否则文件句柄还开着，tearDown 删临时目录会失败）。
    bool shown() =>
        find.textContaining('rate-limit').evaluate().isNotEmpty ||
        find.textContaining('limiting requests').evaluate().isNotEmpty;
    for (int i = 0; i < 50 && !shown(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    for (int i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  String renderedText(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((Text w) => w.data ?? w.textSpan?.toPlainText() ?? '')
      .join(' | ');

  testWidgets('重启后：落盘的限流冷却一打开设置页就显示（不等下一次同步）', (WidgetTester tester) async {
    final int until = DateTime.now()
        .add(const Duration(minutes: 10))
        .millisecondsSinceEpoch;
    await pumpRestartedWithCooldown(tester, until: until);
    expect(session.state.phase, AnkiSyncPhase.idle);
    expect(session.state.rateLimitedUntil, until);
    expect(
      find.textContaining('The sync server is limiting requests'),
      findsOneWidget,
      reason: renderedText(tester),
    );
    await closeSession(tester);
  });

  testWidgets('冷却已过期：不再说「将在某时之后重试」，改说上次被限流、冷却已结束', (WidgetTester tester) async {
    final int until = DateTime.now()
        .subtract(const Duration(minutes: 5))
        .millisecondsSinceEpoch;
    await pumpRestartedWithCooldown(tester, until: until);
    expect(session.state.rateLimitedUntil, until);
    expect(
      find.textContaining('The sync server is limiting requests'),
      findsNothing,
      reason: renderedText(tester),
    );
    expect(
      find.textContaining('rate-limited the last sync'),
      findsOneWidget,
      reason: renderedText(tester),
    );
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
