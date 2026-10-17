import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/updates_center_page.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi/src/updates/update_notifier.dart';
import 'package:fushi/utils.dart' show t;

/// 更新中心：**进页面 = 已读**。用户从首页横幅 / 系统通知点进来这一下就是
/// 「我看到了」，不该进来之后还要再按「全部已读」或逐条点才能把角标消掉。
///
/// 2026-10-09 页头精简：只剩 `[返回] [域筛选 …]` 一行，没有「全部」页签，
/// 页面动作（刷新 / 全部标为已读 / 清空记录）恒在「⋯」里。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late RecordingUpdateNotifier notifier;
  late UpdateFeedService service;

  Future<void> makeService() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    notifier = RecordingUpdateNotifier();
    service = UpdateFeedService(database: db, prefs: prefs, notifier: notifier);
  }

  Future<void> publish(UpdateFeedKind kind, String key, String title) => service
      .publish(UpdateFeedDraft(kind: kind, targetKey: key, title: title));

  /// 页面压在一条可返回的路由上（真实入口都是 push 进来的），返回键才会出现。
  Widget host() => MaterialApp(
    // '/updates' 被拆成 ['/', '/updates'] 两层：页面压在可返回的路由上。
    initialRoute: '/updates',
    routes: <String, WidgetBuilder>{
      '/': (_) => const SizedBox(),
      '/updates': (_) => UpdatesCenterPage(service: service),
    },
  );

  Finder filter(UpdateFeedKind kind) =>
      find.byKey(ValueKey<String>('updates_filter_${kind.dbValue}'));
  final Finder more = find.byKey(
    const ValueKey<String>('fushi_floating_toolbar_overflow'),
  );

  /// 条目是否按「本次停留里的新条目」高亮（标题加粗）。
  bool isFresh(WidgetTester tester, String title) {
    final Finder text = find.text(title);
    return tester.widget<Text>(text).style ==
        tester.element(text).fushiType.bodyLargeEmphasized;
  }

  group('pickDefaultUpdateFeedFilter', () {
    test('有未读时取枚举序第一个有未读的域（内容域优先于更新提示）', () {
      expect(
        pickDefaultUpdateFeedFilter(
          unseen: <UpdateFeedKind>{
            UpdateFeedKind.appRelease,
            UpdateFeedKind.mangaChapter,
          },
          present: UpdateFeedKind.values.toSet(),
        ),
        UpdateFeedKind.mangaChapter,
      );
    });

    test('只有应用新版是新的：直接落在应用新版', () {
      expect(
        pickDefaultUpdateFeedFilter(
          unseen: <UpdateFeedKind>{UpdateFeedKind.appRelease},
          present: UpdateFeedKind.values.toSet(),
        ),
        UpdateFeedKind.appRelease,
      );
    });

    test('都已读：第一个有记录的域；空库：番剧新集', () {
      expect(
        pickDefaultUpdateFeedFilter(
          unseen: const <UpdateFeedKind>{},
          present: <UpdateFeedKind>{
            UpdateFeedKind.mangaExtension,
            UpdateFeedKind.appRelease,
          },
        ),
        UpdateFeedKind.mangaExtension,
      );
      expect(
        pickDefaultUpdateFeedFilter(
          unseen: const <UpdateFeedKind>{},
          present: const <UpdateFeedKind>{},
        ),
        UpdateFeedKind.videoEpisode,
      );
    });
  });

  testWidgets('打开页面即全部标已读、撤系统通知；默认落在有新内容的番剧域', (WidgetTester tester) async {
    await makeService();
    await publish(UpdateFeedKind.appRelease, '2.6.1', 'Fushi 2.6.1');
    await publish(UpdateFeedKind.videoEpisode, '1|ep1', '孤独摇滚');
    expect(await service.unseenTotal(), 2, reason: '前置：两条未读');
    expect(notifier.sent, isNotEmpty, reason: '前置：发过系统通知');

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    // 番剧新集被应用新版淹没是这次改版的起因：默认就落在番剧域。
    expect(find.text('孤独摇滚'), findsOneWidget);
    expect(find.text('Fushi 2.6.1'), findsNothing);
    // 角标来源已归零、通知栏那条也撤了——没再点任何按钮。
    expect(await service.unseenTotal(), 0);
    expect(
      notifier.cancelled,
      containsAll(<int>[
        updateNotificationId(UpdateFeedKind.appRelease, null),
        updateNotificationId(UpdateFeedKind.videoEpisode, null),
      ]),
    );

    // 切到应用新版：库里已标已读，但这条在本次停留里仍算「新」（进页面快照）。
    await tester.tap(filter(UpdateFeedKind.appRelease));
    await tester.pumpAndSettle();
    expect(find.text('Fushi 2.6.1'), findsOneWidget);
    expect(find.text('孤独摇滚'), findsNothing);
    expect(isFresh(tester, 'Fushi 2.6.1'), isTrue);
  });

  testWidgets('只有应用新版是新的：一进来就落在应用新版', (WidgetTester tester) async {
    await makeService();
    await publish(UpdateFeedKind.videoEpisode, '1|ep1', '孤独摇滚');
    await service.markAllSeen();
    await publish(UpdateFeedKind.appRelease, '2.6.1', 'Fushi 2.6.1');

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('Fushi 2.6.1'), findsOneWidget);
    expect(find.text('孤独摇滚'), findsNothing);
  });

  testWidgets('页头只有返回 + 四个域筛选：没有「全部」，页面动作都在 ⋯ 里', (WidgetTester tester) async {
    await makeService();
    await publish(UpdateFeedKind.videoEpisode, '1|ep1', '孤独摇滚');

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('updates_back')), findsOneWidget);
    for (final UpdateFeedKind kind in UpdateFeedKind.values) {
      expect(filter(kind), findsOneWidget, reason: '宽窗下 ${kind.name} 平铺');
    }
    expect(find.byType(ChoiceChip), findsNothing, reason: '旧的第二行筛选条已删');
    // 页面动作不平铺在页头里。
    expect(find.byTooltip(t.updates_history_clear), findsNothing);
    expect(find.byTooltip(t.updates_mark_all_seen), findsNothing);
    expect(find.byTooltip(t.refresh), findsNothing);

    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text(t.refresh), findsOneWidget);
    expect(find.text(t.updates_mark_all_seen), findsOneWidget);
    expect(find.text(t.updates_history_clear), findsOneWidget);

    // 全部标为已读：收掉本次停留的「新」高亮。
    expect(isFresh(tester, '孤独摇滚'), isTrue);
    await tester.tap(find.text(t.updates_mark_all_seen));
    await tester.pumpAndSettle();
    expect(isFresh(tester, '孤独摇滚'), isFalse);
  });

  testWidgets('手机窄屏：放不下的筛选按优先级收进 ⋯，不溢出，从 ⋯ 里仍能切过去', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(360 * 3, 780 * 3);
    addTearDown(tester.view.reset);
    await makeService();
    await publish(UpdateFeedKind.videoEpisode, '1|ep1', '孤独摇滚');
    await publish(UpdateFeedKind.appRelease, '2.6.1', 'Fushi 2.6.1');

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 最高优先级的番剧新集恒平铺；最低优先级的应用新版先收。
    expect(filter(UpdateFeedKind.videoEpisode), findsOneWidget);
    expect(filter(UpdateFeedKind.appRelease), findsNothing);

    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(updateFeedKindLabel(UpdateFeedKind.appRelease)).last,
    );
    await tester.pumpAndSettle();
    expect(find.text('Fushi 2.6.1'), findsOneWidget);
    expect(find.text('孤独摇滚'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('清空：⋯ 里的「清空记录」确认后只清当前域，其它域不动', (WidgetTester tester) async {
    await makeService();
    for (final String v in <String>['2.8.0-debug.15150', '2.8.0-debug.15535']) {
      await publish(UpdateFeedKind.appRelease, v, v);
    }
    await publish(UpdateFeedKind.videoEpisode, '1|ep1', '孤独摇滚');

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await tester.tap(filter(UpdateFeedKind.appRelease));
    await tester.pumpAndSettle();
    expect(find.text('2.8.0-debug.15535'), findsOneWidget);
    expect(find.text('孤独摇滚'), findsNothing);

    Future<void> openClear() async {
      await tester.tap(more);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.updates_history_clear));
      await tester.pumpAndSettle();
    }

    await openClear();
    // 取消不删。
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(find.text('2.8.0-debug.15535'), findsOneWidget);

    await openClear();
    await tester.tap(find.text(t.updates_history_clear_confirm_action));
    await tester.pumpAndSettle();

    expect(find.text('2.8.0-debug.15150'), findsNothing);
    expect(find.text('2.8.0-debug.15535'), findsNothing);
    expect(find.text(t.updates_history_cleared(count: 2)), findsOneWidget);
    final List<UpdateFeedEntryRow> left = await service.entries();
    expect(left.map((UpdateFeedEntryRow e) => e.title), <String>['孤独摇滚']);
  });
}
