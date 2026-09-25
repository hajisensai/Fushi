import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/updates_center_page.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi/src/updates/update_notifier.dart';
import 'package:fushi/utils.dart' show t;

/// 更新中心：**进页面 = 已读**。用户从首页横幅 / 系统通知点进来这一下就是
/// 「我看到了」，不该进来之后还要再按「全部已读」或逐条点才能把角标消掉。
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

  Widget host() => MaterialApp(home: UpdatesCenterPage(service: service));

  testWidgets('打开页面即全部标已读，并撤掉系统通知', (WidgetTester tester) async {
    await makeService();
    await service.publish(
      const UpdateFeedDraft(
        kind: UpdateFeedKind.appRelease,
        targetKey: '2.6.1',
        title: 'Fushi 2.6.1',
      ),
    );
    await service.publish(
      const UpdateFeedDraft(
        kind: UpdateFeedKind.videoEpisode,
        targetKey: '1|ep1',
        title: '孤独摇滚',
        subtitle: 'S01E01',
      ),
    );
    expect(await service.unseenTotal(), 2, reason: '前置：两条未读');
    expect(notifier.sent, isNotEmpty, reason: '前置：发过系统通知');

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    // 页面本次停留仍列出这两条（用户要看的就是它们）。
    expect(find.text('Fushi 2.6.1'), findsOneWidget);
    expect(find.text('孤独摇滚'), findsOneWidget);
    // 但角标来源已归零、通知栏那条也撤了——没再点任何按钮。
    expect(await service.unseenTotal(), 0);
    expect(
      notifier.cancelled,
      containsAll(<int>[
        updateNotificationId(UpdateFeedKind.appRelease, null),
        updateNotificationId(UpdateFeedKind.videoEpisode, null),
      ]),
    );
  });

  testWidgets('清空按钮：确认后清掉当前筛选域的记录，其它域不动', (WidgetTester tester) async {
    await makeService();
    for (final String v in <String>['2.8.0-debug.15150', '2.8.0-debug.15535']) {
      await service.publish(
        UpdateFeedDraft(
          kind: UpdateFeedKind.appRelease,
          targetKey: v,
          title: v,
        ),
      );
    }
    await service.publish(
      const UpdateFeedDraft(
        kind: UpdateFeedKind.videoEpisode,
        targetKey: '1|ep1',
        title: '孤独摇滚',
      ),
    );

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    // 切到「应用新版」筛选。
    final Finder appChip = find.widgetWithText(
      ChoiceChip,
      updateFeedKindLabel(UpdateFeedKind.appRelease),
    );
    await tester.ensureVisible(appChip);
    await tester.pumpAndSettle();
    await tester.tap(appChip);
    await tester.pumpAndSettle();
    expect(find.text('2.8.0-debug.15535'), findsOneWidget);
    expect(find.text('孤独摇滚'), findsNothing);

    await tester.tap(find.byTooltip(t.updates_history_clear));
    await tester.pumpAndSettle();
    // 取消不删。
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(find.text('2.8.0-debug.15535'), findsOneWidget);

    await tester.tap(find.byTooltip(t.updates_history_clear));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.updates_history_clear_confirm_action));
    await tester.pumpAndSettle();

    expect(find.text('2.8.0-debug.15150'), findsNothing);
    expect(find.text('2.8.0-debug.15535'), findsNothing);
    expect(find.text(t.updates_history_cleared(count: 2)), findsOneWidget);
    final List<UpdateFeedEntryRow> left = await service.entries();
    expect(left.map((UpdateFeedEntryRow e) => e.title), <String>['孤独摇滚']);
  });
}
