// 「本版新内容」：升级后首页出一次卡片，关掉后顶栏留入口，打开看过即消失；内容页
// 调试包按流水线 PR 分组，正式版按区间内的 GitHub release 正文。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/whats_new_home_card.dart';
import 'package:fushi/src/pages/implementations/whats_new_page.dart';
import 'package:fushi/src/updates/debug_pulse_service.dart';
import 'package:fushi/src/updates/whats_new.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  group('whatsNewStatusFor', () {
    WhatsNewStatus status({
      String running = '3.4.0-debug.29190',
      String seen = '3.4.0-debug.29104',
      String dismissed = '',
    }) => whatsNewStatusFor(
      runningVersion: running,
      runningSeq: 29190,
      seenVersion: seen,
      seenSeq: 29104,
      dismissedVersion: dismissed,
    );

    test('升级上来 → 卡片；卡片在当前版本关过 → 顶栏入口', () {
      expect(status().stage, WhatsNewStage.card);
      expect(status().fromVersion, '3.4.0-debug.29104');
      expect(status().toSeq, 29190);
      expect(status(dismissed: '3.4.0-debug.29190').stage, WhatsNewStage.entry);
      // 上一个版本关过的卡片不影响这次。
      expect(status(dismissed: '3.4.0-debug.29104').stage, WhatsNewStage.card);
    });

    test('没有基线 / 版本没变 / 降级 → 不提示', () {
      expect(status(seen: '').stage, WhatsNewStage.none);
      expect(status(seen: '3.4.0-debug.29190').stage, WhatsNewStage.none);
      expect(status(seen: '3.5.0').stage, WhatsNewStage.none);
    });

    test('正式版升级', () {
      expect(status(running: '3.4.0', seen: '3.3.0').stage, WhatsNewStage.card);
    });
  });

  group('WhatsNewController', () {
    late FushiDatabase db;
    late PreferencesRepository prefs;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
    });
    tearDown(() => db.close());

    WhatsNewController controller(String version, int seq) =>
        WhatsNewController(
          prefs: () => prefs,
          runningVersion: version,
          runningSeq: seq,
        );

    test('新装：只定基线，不出卡片；之后升级才出', () async {
      final WhatsNewController first = controller('3.4.0-debug.29104', 29104);
      await first.ensureBaseline();
      expect(first.status.stage, WhatsNewStage.none);
      expect(prefs.whatsNewSeenSeq, 29104);

      final WhatsNewController upgraded = controller(
        '3.4.0-debug.29190',
        29190,
      );
      await upgraded.ensureBaseline();
      expect(upgraded.status.stage, WhatsNewStage.card);
      expect(upgraded.status.fromSeq, 29104);
    });

    test('关卡片 → 顶栏入口；打开看过 → 都消失', () async {
      await controller('3.4.0-debug.29104', 29104).ensureBaseline();
      final WhatsNewController c = controller('3.4.0-debug.29190', 29190);
      int notified = 0;
      c.addListener(() => notified++);

      await c.dismissCard();
      expect(c.status.stage, WhatsNewStage.entry);
      await c.markSeen();
      expect(c.status.stage, WhatsNewStage.none);
      expect(prefs.whatsNewSeenVersion, '3.4.0-debug.29190');
      expect(notified, 2);
    });

    test('降级回旧包：基线拉回当前版本', () async {
      await controller('3.4.0-debug.29190', 29190).ensureBaseline();
      final WhatsNewController older = controller('3.4.0-debug.29104', 29104);
      await older.ensureBaseline();
      expect(prefs.whatsNewSeenVersion, '3.4.0-debug.29104');
      expect(older.status.stage, WhatsNewStage.none);
    });
  });

  group('内容来源', () {
    test('调试包且两端序号已知才走流水线', () {
      expect(
        whatsNewUsesDebugPulse(
          toVersion: '3.4.0-debug.29190',
          fromSeq: 29104,
          toSeq: 29190,
        ),
        isTrue,
      );
      expect(
        whatsNewUsesDebugPulse(
          toVersion: '3.4.0-debug.29190',
          fromSeq: 0,
          toSeq: 29190,
        ),
        isFalse,
      );
      expect(
        whatsNewUsesDebugPulse(toVersion: '3.4.0', fromSeq: 1, toSeq: 2),
        isFalse,
      );
    });

    test('releasesBetween 只留 (from, to] 的应用版本', () {
      final List<Map<String, dynamic>> releases = <Map<String, dynamic>>[
        <String, dynamic>{'tag_name': 'v3.5.0'},
        <String, dynamic>{'tag_name': 'v3.4.0'},
        <String, dynamic>{'tag_name': 'flutter-engine-3.47.6'},
        <String, dynamic>{'tag_name': 'v3.3.1'},
        <String, dynamic>{'tag_name': 'v3.3.0'},
      ];
      expect(
        releasesBetween(
          releases,
          fromVersion: '3.3.0',
          toVersion: '3.4.0',
        ).map((Map<String, dynamic> r) => r['tag_name']),
        <String>['v3.4.0', 'v3.3.1'],
      );
    });
  });

  group('WhatsNewPage', () {
    setUp(() => LocaleSettings.setLocale(AppLocale.en));

    Widget host(Widget home) =>
        TranslationProvider(child: MaterialApp(home: home));

    final String pulse = jsonEncode(<String, Object?>{
      'schema': 1,
      'repo': 'hajisensai/Fushi',
      'builds': <Object?>[
        <String, Object?>{
          'seq': 29190,
          'version': '3.4.0',
          'sha': 'a' * 40,
          'baseSeq': 29116,
          'prs': <int>[3681],
        },
        <String, Object?>{
          'seq': 29116,
          'version': '3.4.0',
          'sha': 'b' * 40,
          'baseSeq': 29104,
          'prs': <int>[3670, 3665],
        },
      ],
      'prs': <String, Object?>{
        '3681': <String, Object?>{
          'number': 3681,
          'title': 'feat(audio): batch synthesis for manga',
        },
        '3670': <String, Object?>{
          'number': 3670,
          'title': 'fix(ocr): signature mismatch',
        },
        '3665': <String, Object?>{'number': 3665, 'title': 'chore: bump deps'},
      },
    });

    testWidgets('调试包：区间内各包的 PR 按类别列出', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          WhatsNewPage(
            fromVersion: '3.4.0-debug.29104',
            fromSeq: 29104,
            toVersion: '3.4.0-debug.29190',
            toSeq: 29190,
            pulseService: DebugPulseService(fetchBody: () async => pulse),
            fetchReleases: () async => fail('调试包不该去拉 release'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('whats-new-header')), findsOne);
      expect(find.textContaining('batch synthesis for manga'), findsOne);
      expect(find.textContaining('signature mismatch'), findsOne);
      expect(find.textContaining('bump deps'), findsOne);
      expect(
        find.byKey(const ValueKey<String>('whats-new-incomplete')),
        findsNothing,
      );
    });

    testWidgets('调试包：区间开头不在流水线里 → 提示看更新日志', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          WhatsNewPage(
            fromVersion: '3.3.0-debug.28000',
            fromSeq: 28000,
            toVersion: '3.4.0-debug.29190',
            toSeq: 29190,
            pulseService: DebugPulseService(fetchBody: () async => pulse),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('whats-new-incomplete')),
        findsOne,
      );
    });

    testWidgets('正式版：列出区间内的发布说明', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          WhatsNewPage(
            fromVersion: '3.3.0',
            fromSeq: 0,
            toVersion: '3.4.0',
            toSeq: null,
            fetchReleases: () async => <Map<String, dynamic>>[
              <String, dynamic>{
                'tag_name': 'v3.4.0',
                'body': 'Brand new reader',
              },
              <String, dynamic>{'tag_name': 'v3.3.0', 'body': 'Old notes'},
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('v3.4.0'), findsOne);
      expect(find.textContaining('Brand new reader'), findsOne);
      expect(find.text('v3.3.0'), findsNothing);
    });

    testWidgets('没有任何说明 → 空态', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          WhatsNewPage(
            fromVersion: '3.3.0',
            fromSeq: 0,
            toVersion: '3.4.0',
            toSeq: null,
            fetchReleases: () async => <Map<String, dynamic>>[],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(t.whats_new_empty), findsOne);
    });
  });

  group('WhatsNewHomeCard', () {
    late FushiDatabase db;
    late PreferencesRepository prefs;

    setUp(() async {
      LocaleSettings.setLocale(AppLocale.en);
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      await prefs.setWhatsNewSeen(version: '3.3.0', seq: 0);
    });
    tearDown(() => db.close());

    testWidgets('关掉卡片 → 收起并转成顶栏入口；点开 → 回调', (WidgetTester tester) async {
      final WhatsNewController c = WhatsNewController(
        prefs: () => prefs,
        runningVersion: '3.4.0',
        runningSeq: null,
      );
      int opened = 0;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: WhatsNewHomeCard(controller: c, onOpen: () => opened++),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(t.whats_new_card_title(version: '3.4.0')), findsOne);

      await tester.tap(
        find.byKey(const ValueKey<String>('whats-new-card-open')),
      );
      expect(opened, 1);

      await tester.tap(
        find.byKey(const ValueKey<String>('whats-new-card-dismiss')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('whats-new-card')),
        findsNothing,
      );
      expect(c.status.stage, WhatsNewStage.entry);
    });
  });
}
