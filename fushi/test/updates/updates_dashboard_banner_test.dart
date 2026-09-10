import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/updates_dashboard_banner.dart';
import 'package:fushi/src/updates/update_feed_kind.dart';
import 'package:fushi/src/updates/update_feed_service.dart';

/// v101 首页横幅：没有未读时**一个像素都不占**（首页顶部不该多一块常驻空卡），
/// 有未读时显示总数与按域明细。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late UpdateFeedService service;

  Future<void> makeService() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    service = UpdateFeedService(database: db, prefs: prefs);
  }

  Widget host() => MaterialApp(
        home: Scaffold(
          body: UpdatesDashboardBanner(service: service),
        ),
      );

  testWidgets('零未读：整块收成零高度', (WidgetTester tester) async {
    await makeService();
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.byType(UpdatesDashboardBanner), findsOneWidget);
    expect(
      tester.getSize(find.byType(UpdatesDashboardBanner)).height,
      0,
      reason: '没有更新的日子首页顶部不该空出一条',
    );
  });

  testWidgets('有未读：显示总数与按域明细', (WidgetTester tester) async {
    await makeService();
    await service.publishBatch(
      UpdateFeedKind.videoEpisode,
      <UpdateFeedDraft>[
        const UpdateFeedDraft(
          kind: UpdateFeedKind.videoEpisode,
          targetKey: '1|ep1',
          title: '孤独摇滚',
          subtitle: 'S01E01',
        ),
        const UpdateFeedDraft(
          kind: UpdateFeedKind.videoEpisode,
          targetKey: '1|ep2',
          title: '孤独摇滚',
          subtitle: 'S01E02',
        ),
      ],
    );
    await service.publish(
      const UpdateFeedDraft(
        kind: UpdateFeedKind.appRelease,
        targetKey: '2.3.1',
        title: 'Fushi 2.3.1',
      ),
    );

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(UpdatesDashboardBanner)).height,
        greaterThan(0));
    // 总数徽标 = 3（两集 + 一个版本）。
    expect(find.text('3'), findsOneWidget);
    // 明细按域，只列有未读的域。
    expect(find.textContaining('2'), findsWidgets);
  });
}
