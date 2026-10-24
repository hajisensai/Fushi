import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_detail_layout.dart'
    show CollectionEpisodeCard;
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_library.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_detail_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/video/media_server_video_path.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:path/path.dart' as p;

import 'fake_media_server_browser.dart';

/// 媒体服务器详情页（2026-10-23）：选集用与本地系列详情同一张宽集卡；「加入 /
/// 移出媒体库」落真库并翻转按钮。
void main() {
  late Directory root;
  late EnginePaths previousPaths;
  late FushiDatabase database;
  late FakeMediaServerBrowser browser;

  const MediaServerItem series = MediaServerItem(
    id: 's1',
    name: 'Series s1',
    type: MediaServerItemType.series,
  );

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    root = await Directory.systemTemp.createTemp('fushi-ms-detail-lib-');
    previousPaths = enginePaths;
    enginePaths = FixedEnginePaths(
      documents: Directory(p.join(root.path, 'documents')),
      support: Directory(p.join(root.path, 'support')),
      temp: Directory(p.join(root.path, 'temp')),
    );
    VideoCoverMutationGate.debugResetForTesting();
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    browser = FakeMediaServerBrowser();
    browser.details['s1'] = series;
    final List<MediaServerItem> episodes = <MediaServerItem>[
      for (int i = 1; i <= 2; i++)
        MediaServerItem(
          id: 'ep$i',
          name: 'Episode $i',
          type: MediaServerItemType.episode,
          seriesId: 's1',
          seriesName: 'Series s1',
          episodeNumber: i,
        ),
    ];
    browser.episodes['s1|'] = episodes;
  });

  tearDown(() async {
    await database.close();
    enginePaths = previousPaths;
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
    for (int i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (i >= 4 && done()) return;
    }
  }

  Finder addButton() =>
      find.byKey(const ValueKey<String>('media-server-detail-library-add'));
  Finder removeButton() =>
      find.byKey(const ValueKey<String>('media-server-detail-library-remove'));

  testWidgets('episodes use the series card; add to library writes rows and '
      'flips to remove; remove deletes them', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: MediaServerDetailView(
              session: MediaServerSession(
                browser: browser,
                play: (BuildContext _, MediaServerPlayRequest _) {},
                library: MediaServerVideoLibrary(database: database),
              ),
              item: series,
            ),
          ),
        ),
      ),
    );
    await settleUntil(tester, () => addButton().evaluate().isNotEmpty);

    expect(find.byType(CollectionEpisodeCard), findsNWidgets(2));
    expect(
      find.byKey(const ValueKey<String>('media-server-episode-ep1')),
      findsOneWidget,
    );
    expect(addButton(), findsOneWidget);
    expect(removeButton(), findsNothing);

    await tester.tap(addButton());
    await settleUntil(tester, () => removeButton().evaluate().isNotEmpty);
    final List<VideoBookRow> rows = (await tester.runAsync(
      database.allVideoBooks,
    ))!;
    expect(rows.map((VideoBookRow r) => r.bookUid).toSet(), <String>{
      'ep1',
      'ep2',
    });
    expect(
      rows.every((VideoBookRow r) => isMediaServerVideoPath(r.videoPath)),
      isTrue,
    );
    expect(addButton(), findsNothing);
    expect(find.text(t.video_discovery_in_library), findsOneWidget);

    await tester.tap(removeButton());
    await settleUntil(tester, () => addButton().evaluate().isNotEmpty);
    expect((await tester.runAsync(database.allVideoBooks))!, isEmpty);
    expect(removeButton(), findsNothing);
  });
}
