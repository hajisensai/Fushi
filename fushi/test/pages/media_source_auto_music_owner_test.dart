// v145（反馈 QAondMh4M5）：视频来源自动登记的音乐来源在来源页上要看得出是谁加的、能
// 转成自己的来源；删视频来源时确认框说清会一并移除几个自动添加的音乐文件夹。
// Material 与 Apple 两套（FushiAlertDialog.adaptive / 菜单）各跑一遍。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

void main() {
  late FushiDatabase db;
  late int video;
  late int auto;

  setUp(() async {
    db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    video = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Anime 库',
        mediaKind: 'video',
        rootPath: 'D:/Anime',
        createdAt: 1,
      ),
    );
    auto = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Drama',
        mediaKind: 'music',
        rootPath: 'D:/Anime/Drama',
        createdAt: 1,
        autoOwnerSourceId: Value<int?>(video),
      ),
    );
    await db.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: <MusicTracksCompanion>[
          for (final String uid in <String>['a', 'b', 'c'])
            MusicTracksCompanion.insert(
              trackUid: uid,
              sourceId: Value<int?>(auto),
              path: 'D:/Anime/Drama/$uid.mp3',
              title: uid,
              fileMtimeAt: 1,
              fileSize: 1,
              addedAt: 1,
            ),
        ],
        albums: const <MusicAlbumsCompanion>[],
        artists: const <MusicArtistsCompanion>[],
        credits: const <MusicTrackCreditsCompanion>[],
      ),
    );
  });

  tearDown(() => db.close());

  Future<void> pumpView(WidgetTester tester, String mediaKind) async {
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(420, 800)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: MediaSourcesView(mediaKind: mediaKind),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  final TargetPlatformVariant platforms = TargetPlatformVariant(
    <TargetPlatform>{TargetPlatform.android, TargetPlatform.iOS},
  );

  testWidgets('music page: auto source names its video source; "keep as my '
      'source" turns it into a manual one', (WidgetTester tester) async {
    await pumpView(tester, 'music');
    final Finder owner = find.byKey(
      ValueKey<String>('media_source_auto_owner_$auto'),
    );
    expect(owner, findsOneWidget);
    expect(
      find.text(t.media_source_auto_added_from(source: 'Anime 库')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(ValueKey<String>('media_source_menu_$auto')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey<String>('media_source_keep_as_own_$auto')),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect((await db.getMediaSourceById(auto))!.autoOwnerSourceId, isNull);
    expect(owner, findsNothing);
  }, variant: platforms);

  testWidgets('video page: the removal dialog says how many auto-added music '
      'folders (and tracks) go with it', (WidgetTester tester) async {
    await pumpView(tester, 'video');
    await tester.tap(find.byKey(ValueKey<String>('media_source_menu_$video')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey<String>('media_source_remove_$video')),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('media-source-remove-auto-music')),
      findsOneWidget,
    );
    expect(
      find.text(t.media_source_remove_auto_music_sources(count: 1, tracks: 3)),
      findsOneWidget,
    );
  }, variant: platforms);
}
