import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

void main() {
  testWidgets('folder mode saves to source and disables metadata actions',
      (WidgetTester tester) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int sourceId =
        await db.insertMediaSource(MediaSourcesCompanion.insert(
      label: 'Lessons',
      mediaKind: 'video',
      rootPath: '/lessons',
      createdAt: 1,
    ));
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db);
    int libraryChanges = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
      child: MaterialApp(
          home: Scaffold(
              body: MediaSourcesView(
        mediaKind: 'video',
        onScrapeSource: (source) async {},
        onLibraryChanged: () => libraryChanges++,
      ))),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Source scrape settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('By work').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('By folder').last);
    await tester.pumpAndSettle();
    expect(find.text('Enable scraping for this source'), findsNothing);
    await tester.tap(find.text('SAVE'));
    await tester.pumpAndSettle();
    expect(
        (await db.getMediaSourceById(sourceId))!.videoGroupingMode, 'folder');
    expect(find.byTooltip('Scrape this source'), findsNothing);
    expect(libraryChanges, 1);
    await tester.tap(find.byTooltip('Source scrape settings'));
    await tester.pumpAndSettle();
    expect(find.text('By folder'), findsWidgets);
    // Cancel must not overwrite the persisted mode.
    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();
    expect(
        (await db.getMediaSourceById(sourceId))!.videoGroupingMode, 'folder');
    expect(libraryChanges, 1, reason: '取消不触发媒体库刷新');
  });
}
