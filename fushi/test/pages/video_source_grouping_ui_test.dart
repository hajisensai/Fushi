import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

void main() {
  testWidgets('folder mode saves to source and disables metadata actions', (
    WidgetTester tester,
  ) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Lessons',
        mediaKind: 'video',
        rootPath: '/lessons',
        createdAt: 1,
      ),
    );
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db);
    int libraryChanges = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
        child: MaterialApp(
          home: Scaffold(
            body: MediaSourcesView(
              mediaKind: 'video',
              onScrapeSource: (source) async {},
              onLibraryChanged: () => libraryChanges++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Source scrape settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('By work').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('By folder').last);
    await tester.pumpAndSettle();
    expect(find.text('Enable scraping for this source'), findsNothing);
    await tester.tap(find.text('SAVE'));
    // BUG-4349 起改分组方式即按新方式重扫该来源：重扫是真 IO（扫描根目录），只在
    // runAsync 里推进；扫完通知一次媒体库，保存收尾再通知一次。
    await _pumpRealUntil(tester, () => libraryChanges >= 2);
    await tester.pumpAndSettle();
    expect(
      (await db.getMediaSourceById(sourceId))!.videoGroupingMode,
      'folder',
    );
    expect(find.byTooltip('Scrape this source'), findsNothing);
    expect(libraryChanges, 2, reason: '重扫完成一次 + 保存一次');
    await tester.tap(find.byTooltip('Source scrape settings'));
    await tester.pumpAndSettle();
    expect(find.text('By folder'), findsWidgets);
    // Cancel must not overwrite the persisted mode.
    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();
    expect(
      (await db.getMediaSourceById(sourceId))!.videoGroupingMode,
      'folder',
    );
    expect(libraryChanges, 2, reason: '取消不触发媒体库刷新');
  });
}

/// 交替推进真异步（扫描的文件系统 IO 只在 runAsync 里完成）与 fake 时钟（把 IO 回调
/// 排进来的 microtask 跑掉），直到 [done]；有上限，到了仍未完成按失败报。
Future<void> _pumpRealUntil(WidgetTester tester, bool Function() done) async {
  for (int i = 0; i < 400 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  expect(done(), isTrue, reason: '重扫没有在上限内完成');
}
