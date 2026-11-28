import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_detail_layout.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/media/video/cover_ui/video_poster_detail_hero.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi/src/pages/implementations/media_collection_grid_detail_page.dart';
import 'package:fushi/src/pages/implementations/video_work_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/media_image_user_store.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

/// 「横幅…」入口：视频剧集合集详情页的管理动作、散装电影详情页的次按钮、书 / 游戏
/// 合集详情页的页头动作。宿主注入回调才出入口；换了横幅就通知宿主刷新并重读。
void main() {
  late FushiDatabase db;
  late Directory dir;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('banner_entry_');
  });

  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  void wideSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget app(Widget home) =>
      TranslationProvider(child: MaterialApp(home: home));

  testWidgets('剧集合集详情页：管理动作里有「横幅…」，换了就通知库页', (WidgetTester tester) async {
    wideSurface(tester);
    final int id = await db.createMediaCollection('Show');
    final MediaCollectionRow collection = (await db.getMediaCollectionById(
      id,
    ))!;
    final List<int> picked = <int>[];
    int changed = 0;
    await tester.pumpWidget(
      app(
        MediaCollectionDetailPage(
          database: db,
          collection: collection,
          loadEpisodes: () async => const <CollectionEpisodeSlot>[],
          onOpenEpisode: (VideoBookRow _) {},
          onChanged: () => changed++,
          onPickBanner: (MediaCollectionRow c) async {
            picked.add(c.id);
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(t.media_banner_action));
    await tester.pumpAndSettle();
    expect(picked, <int>[id]);
    expect(changed, 1);
  });

  testWidgets('剧集合集详情页：没注入回调就没有入口', (WidgetTester tester) async {
    wideSurface(tester);
    final int id = await db.createMediaCollection('Show');
    await tester.pumpWidget(
      app(
        MediaCollectionDetailPage(
          database: db,
          collection: (await db.getMediaCollectionById(id))!,
          loadEpisodes: () async => const <CollectionEpisodeSlot>[],
          onOpenEpisode: (VideoBookRow _) {},
          onChanged: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip(t.media_banner_action), findsNothing);
  });

  testWidgets('散装电影详情页：次按钮「横幅…」带视频归属；hero 背景用用户选的那张', (
    WidgetTester tester,
  ) async {
    wideSurface(tester);
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>('movie'),
        title: Value<String>('Movie'),
        videoPath: Value<String>('/v/movie.mkv'),
      ),
    );
    final File pick = File(p.join(dir.path, 'pick.gif'))
      ..writeAsBytesSync(<int>[
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0, 0, 0, 0x3B, //
      ]);
    await db.setUserMediaImage(
      bookUid: 'movie',
      kind: MediaImageKind.backdrop,
      path: pick.path,
    );
    final List<MediaImageOwner> owners = <MediaImageOwner>[];
    await tester.runAsync(() async {
      await tester.pumpWidget(
        app(
          VideoWorkDetailPage(
            database: db,
            repository: VideoBookRepository(db),
            workRef: const VideoWorkRef.book('movie'),
            onChanged: () {},
            onPickBanner: (MediaImageOwner owner) async {
              owners.add(owner);
              return false;
            },
          ),
        ),
      );
      for (int i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find
            .byKey(const ValueKey<String>('video-work-banner'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
    });
    await tester.pump();
    final Finder banner = find.byKey(
      const ValueKey<String>('video-work-banner'),
    );
    expect(banner, findsOneWidget);
    ImageProvider? heroBackdrop;
    for (final Widget w in tester.allWidgets) {
      if (w is CollectionDetailHero) heroBackdrop = w.backdrop;
      if (w is VideoPosterDetailHero) heroBackdrop = w.backdrop;
    }
    expect(heroBackdrop, isA<ResizeImage>());
    expect(
      ((heroBackdrop! as ResizeImage).imageProvider as FileImage).file.path,
      pick.path,
      reason: '用户选的横幅压过作品图组（这里没有刮削图）',
    );
    await tester.tap(banner);
    await tester.pump();
    expect(owners, const <MediaImageOwner>[MediaImageOwner.book('movie')]);
  });

  testWidgets('书 / 游戏合集详情页：页头动作「横幅…」，换了就通知宿主并重读', (WidgetTester tester) async {
    wideSurface(tester);
    final int id = await db.createMediaCollection('Series');
    await db.addToCollection(id, MediaKind.epub, 'b1');
    int picks = 0;
    int changed = 0;
    await tester.pumpWidget(
      app(
        MediaCollectionGridDetailPage(
          database: db,
          collection: (await db.getMediaCollectionById(id))!,
          memberCardBuilder:
              (
                String mediaType,
                String entryKey, {
                VoidCallback? onRemoveFromCollection,
              }) => const SizedBox(width: 10, height: 10),
          onChanged: () => changed++,
          onPickBanner: () async {
            picks++;
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(t.media_banner_action));
    await tester.pumpAndSettle();
    expect(picks, 1);
    expect(changed, 1);
  });
}
