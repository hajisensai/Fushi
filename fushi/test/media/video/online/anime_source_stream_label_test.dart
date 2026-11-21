import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/media/video/online/anime_source_stream_label.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/anime_source_video_path.dart';
import 'package:material_ui/material_ui.dart';

/// 拍板台 646L8W6DK2（应用内反馈 646L8W6DK2）：合集详情里只能在线播放（在线视频源
/// 入库、还没下载）的集与已下载的集长得一样。状态行要写「Streams · 源名」，已下载
/// 的集照旧是规格摘要；源查不到时只写「Streams」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String pkg = 'eu.kanade.tachiyomi.animeextension.en.anikoto';
  const String goneP = 'eu.kanade.tachiyomi.animeextension.en.gone';

  VideoBookRow row(String uid, String videoPath) => VideoBookRow(
    bookUid: uid,
    title: uid,
    videoPath: videoPath,
    lastPositionMs: 0,
    currentEpisode: 0,
    delayMs: 0,
  );

  MangaOnlineSourceRow source(String package, String id, String name) =>
      MangaOnlineSourceRow(
        extensionPackage: package,
        sourceId: id,
        name: name,
        language: 'en',
        baseUrl: '',
        enabled: true,
        pinned: false,
        sortOrder: 0,
        mediaKind: 'anime',
      );

  group('parseAnimeSourceVideoPath', () {
    test('取回扩展包与源 id（animeSourceVideoPath 的逆）', () {
      final String path = animeSourceVideoPath(
        extensionPackage: pkg,
        sourceId: '42',
        label: 'Show - E06',
      );
      expect(parseAnimeSourceVideoPath(path), (
        extensionPackage: pkg,
        sourceId: '42',
      ));
      expect(parseAnimeSourceVideoPath('  ANIME-SOURCE://p/7/x'), (
        extensionPackage: 'p',
        sourceId: '7',
      ));
    });

    test('非本 scheme / 缺段 → null', () {
      expect(parseAnimeSourceVideoPath(null), isNull);
      expect(parseAnimeSourceVideoPath(r'D:\v\ep.mkv'), isNull);
      expect(parseAnimeSourceVideoPath('https://x/y/z'), isNull);
      expect(parseAnimeSourceVideoPath('anime-source://'), isNull);
      expect(parseAnimeSourceVideoPath('anime-source://pkg'), isNull);
      expect(parseAnimeSourceVideoPath('anime-source://pkg//x'), isNull);
    });
  });

  group('animeSourceStreamingNames', () {
    test('只收在线集；源名按 (扩展包, 源 id) 查，查不到为 null', () {
      final Map<String, String?> names = animeSourceStreamingNames(
        <VideoBookRow>[
          row('local', '/v/Show - 02.mkv'),
          row('online', 'anime-source://$pkg/42/Show - E06'),
          row('other-source', 'anime-source://$pkg/43/Show - E07'),
          row('gone', 'anime-source://$goneP/1/Show - E08'),
        ],
        <MangaOnlineSourceRow>[
          source(pkg, '42', 'Anikoto'),
          source(pkg, '43', '  '),
        ],
      );
      expect(names, <String, String?>{
        'online': 'Anikoto',
        'other-source': null,
        'gone': null,
      });
    });

    test('标签：有源名写「Streams · 源名」，否则只写「Streams」', () {
      LocaleSettings.setLocale(AppLocale.en);
      expect(animeSourceStreamingLabel('Anikoto'), 'Streams · Anikoto');
      expect(animeSourceStreamingLabel(null), 'Streams');
      expect(animeSourceStreamingLabel(''), 'Streams');
    });
  });

  group('合集详情页集卡状态行', () {
    late FushiDatabase db;
    late int collectionId;

    setUp(() async {
      LocaleSettings.setLocale(AppLocale.en);
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      for (final (String uid, String path) in const <(String, String)>[
        ('video/e02', '/v/[Grp] Show - 02.mkv'),
        ('anime/e06', 'anime-source://$pkg/42/Show - E06'),
        ('anime/e07', 'anime-source://$goneP/1/Show - E07'),
      ]) {
        await db.upsertVideoBook(
          VideoBooksCompanion(
            bookUid: Value<String>(uid),
            title: Value<String>(uid),
            videoPath: Value<String>(path),
          ),
        );
      }
      await db
          .into(db.mangaOnlineSources)
          .insert(
            MangaOnlineSourcesCompanion.insert(
              extensionPackage: pkg,
              sourceId: '42',
              name: 'Anikoto',
              language: 'en',
              mediaKind: const Value<String>('anime'),
            ),
          );
      collectionId = await db.createMediaCollection(
        'Show',
        collectionType: 'playlist',
      );
      for (final String uid in <String>[
        'video/e02',
        'anime/e06',
        'anime/e07',
      ]) {
        await db.addToCollection(collectionId, MediaKind.video, uid);
      }
    });

    tearDown(() => db.close());

    Future<List<CollectionEpisodeSlot>> loadSlots() async {
      final List<MediaCollectionItemRow> items = await db.getCollectionItems(
        collectionId,
      );
      return <CollectionEpisodeSlot>[
        for (final MediaCollectionItemRow item in items)
          if (await db.getVideoBookByBookUid(item.entryKey)
              case final VideoBookRow r)
            CollectionEpisodeSlot.local(r),
      ];
    }

    testWidgets('在线集写「Streams · 源名」，本地集不写', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: MediaCollectionDetailPage(
              database: db,
              collection: MediaCollectionRow(
                origin: 'user',
                organizeAliases: '',
                id: collectionId,
                name: 'Show',
                collectionType: 'playlist',
                coverSource: null,
                sortOrder: 0,
                createdAt: 0,
                orderUpdatedAt: 0,
              ),
              loadEpisodes: loadSlots,
              onOpenEpisode: (VideoBookRow _) async {},
              onChanged: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 源在表里的那集带源名；扩展已卸载的那集只写「Streams」；本地集两者都不写。
      expect(find.text('Streams · Anikoto'), findsOneWidget);
      expect(find.text('Streams'), findsOneWidget);
    });
  });
}
