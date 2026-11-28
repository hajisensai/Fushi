import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/banner/banner_picker_sheet.dart';
import 'package:fushi/src/media/banner/collection_banner_sources.dart';
import 'package:fushi/src/media/banner/game_banner_sources.dart';
import 'package:fushi/src/mining/metadata/adapters/vndb_adapter.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/item_scrape/item_scrape_store.dart';
import 'package:fushi_engine/media/video/media_image_user_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

/// 游戏与合集的「横幅…」来源：游戏在线 = VNDB 截图（只留安全分级）+ 各源 draft 的
/// `backdropUrl`；合集内 = 各成员已有的横幅；合集写入走 `media_images` 用户口径。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late Directory dir;

  Uint8List pngHeader(int width, int height) {
    final ByteData data = ByteData(33);
    const List<int> sig = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    for (int i = 0; i < sig.length; i++) {
      data.setUint8(i, sig[i]);
    }
    data.setUint32(8, 13);
    const List<int> ihdr = <int>[0x49, 0x48, 0x44, 0x52];
    for (int i = 0; i < 4; i++) {
      data.setUint8(12 + i, ihdr[i]);
    }
    data.setUint32(16, width);
    data.setUint32(20, height);
    return data.buffer.asUint8List();
  }

  String png(String name, int w, int h) =>
      (File(p.join(dir.path, name))..writeAsBytesSync(pngHeader(w, h))).path;

  File gif(String name) => File(p.join(dir.path, name))
    ..writeAsBytesSync(<int>[
      0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0, 0, 0, 0x3B, //
    ]);

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('game_banner_');
  });

  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> addSource(
    String gameId,
    String source, {
    String? externalId,
    Map<String, Object?> data = const <String, Object?>{},
  }) => db
      .into(db.galgameSources)
      .insert(
        GalgameSourcesCompanion.insert(
          gameId: gameId,
          source: source,
          externalId: Value<String?>(externalId),
          dataJson: jsonEncode(data),
          fetchedAt: 1,
        ),
      );

  VndbMetadataAdapter fakeVndb(List<Map<String, Object?>> screenshots) =>
      VndbMetadataAdapter(
        client: MockClient((http.Request request) async {
          final Map<String, Object?> body =
              jsonDecode(request.body) as Map<String, Object?>;
          expect(body['fields'], kVndbScreenshotFields);
          expect(body['filters'], <Object?>['id', '=', 'v17']);
          return http.Response(
            jsonEncode(<String, Object?>{
              'results': <Object?>[
                <String, Object?>{'id': 'v17', 'screenshots': screenshots},
              ],
            }),
            200,
          );
        }),
      );

  test('VNDB 截图：只留成人 / 暴力分级都不高于 0.5 的，缺分级当不安全', () {
    final List<VndbScreenshot> out = parseVndbScreenshots(<Object?>[
      <String, Object?>{
        'url': 'https://t.vndb.test/sf/1.jpg',
        'thumbnail': 'https://t.vndb.test/st/1.jpg',
        'dims': <int>[1280, 720],
        'sexual': 0,
        'violence': 0,
      },
      <String, Object?>{
        'url': 'https://t.vndb.test/sf/2.jpg',
        'sexual': 1.6,
        'violence': 0,
      },
      <String, Object?>{
        'url': 'https://t.vndb.test/sf/3.jpg',
        'sexual': 0,
        'violence': 1,
      },
      <String, Object?>{'url': 'https://t.vndb.test/sf/4.jpg'},
      <String, Object?>{'sexual': 0, 'violence': 0},
    ]);
    expect(out.single.url, 'https://t.vndb.test/sf/1.jpg');
    expect(out.single.thumbnail, 'https://t.vndb.test/st/1.jpg');
    expect(out.single.width, 1280);
    expect(out.single.height, 720);
  });

  test('游戏在线候选：draft 的 backdropUrl + 已绑 VNDB 的截图，去重', () async {
    await addSource(
      'g1',
      'bgm',
      externalId: '4885',
      data: <String, Object?>{'backdropUrl': 'https://img.test/bgm-wide.jpg'},
    );
    await addSource('g1', 'vndb', externalId: 'v17');
    final List<BannerCandidate> out = await loadGameBannerOnlineCandidates(
      db: db,
      gameId: 'g1',
      vndbFactory: () => fakeVndb(<Map<String, Object?>>[
        <String, Object?>{
          'url': 'https://t.vndb.test/sf/1.jpg',
          'thumbnail': 'https://t.vndb.test/st/1.jpg',
          'dims': <int>[1280, 720],
          'sexual': 0,
          'violence': 0,
        },
        <String, Object?>{
          'url': 'https://img.test/bgm-wide.jpg',
          'sexual': 0,
          'violence': 0,
        },
      ]),
    );
    expect(
      <String?>[for (final BannerCandidate c in out) c.sourceUrl],
      <String?>[
        'https://img.test/bgm-wide.jpg',
        'https://t.vndb.test/sf/1.jpg',
      ],
    );
    expect(out.last.label, 'VNDB');
    expect(out.last.width, 1280);
  });

  test('游戏面板：没有「游戏中」分段；在线关着只剩文件或链接；选的图上锁', () async {
    final ItemScrapeStore store = ItemScrapeStore(
      db,
      imagesDirectory: Directory(p.join(dir.path, 'items')),
    );
    BannerPickerTarget target = await loadGameBannerPickerTarget(
      db: db,
      gameId: 'g1',
      onlineEnabled: false,
      store: store,
    );
    expect(target.sources, <BannerPickerSource>[BannerPickerSource.fileOrLink]);
    expect(target.current, isNull);
    await target.apply(gif('pick.gif'));
    final ItemImageRow row = (await db.getItemImages(
      MediaKind.game,
      'g1',
    )).single;
    expect(row.userChosen, isTrue);
    // 之后的游戏刮削写入让路。
    expect(
      await store.writeScrapedImageFromFile(
        ItemScrapeKey(MediaKind.game, 'g1'),
        MediaImageKind.backdrop,
        gif('scraped.gif'),
      ),
      isNull,
    );
    target = await loadGameBannerPickerTarget(
      db: db,
      gameId: 'g1',
      onlineEnabled: true,
      store: store,
    );
    expect(target.currentUserChosen, isTrue);
    expect(target.sources, <BannerPickerSource>[
      BannerPickerSource.online,
      BannerPickerSource.fileOrLink,
    ]);
    expect(target.onlineEmptyMessage, t.media_banner_game_online_empty);
  });

  group('合集', () {
    late int collectionId;
    late MediaImageUserStore store;

    setUp(() async {
      collectionId = await db.createMediaCollection('Series');
      store = MediaImageUserStore(
        db,
        collectionsDirectory: Directory(p.join(dir.path, 'collections')),
        videosDirectory: Directory(p.join(dir.path, 'videos')),
      );
    });

    test('合集内：按成员顺序收各成员的横幅，只留横版的', () async {
      await db.addToCollection(collectionId, MediaKind.epub, 'b1');
      await db.addToCollection(collectionId, MediaKind.game, 'g1');
      await db.addToCollection(collectionId, MediaKind.epub, 'b2');
      final String wide1 = png('b1.png', 1920, 1080);
      final String narrow = png('b2.png', 800, 1200);
      final String wide2 = png('g1.png', 1600, 900);
      await db.replaceItemImagesOfKind(
        mediaType: MediaKind.epub,
        entryKey: 'b1',
        kind: MediaImageKind.backdrop,
        images: <({String path, String? sourceUrl})>[
          (path: wide1, sourceUrl: null),
        ],
      );
      await db.replaceItemImagesOfKind(
        mediaType: MediaKind.epub,
        entryKey: 'b2',
        kind: MediaImageKind.backdrop,
        images: <({String path, String? sourceUrl})>[
          (path: narrow, sourceUrl: null),
        ],
      );
      await db.replaceItemImagesOfKind(
        mediaType: MediaKind.game,
        entryKey: 'g1',
        kind: MediaImageKind.backdrop,
        images: <({String path, String? sourceUrl})>[
          (path: wide2, sourceUrl: null),
        ],
      );
      final List<BannerCandidate> out = await loadCollectionBannerFromMembers(
        db: db,
        collectionId: collectionId,
      );
      final List<String> paths = <String>[
        for (final BannerCandidate c in out) (await c.resolve()).path,
      ];
      expect(paths, <String>[wide1, wide2]);
    });

    test('面板：游戏合集的在线来源用领头游戏；选的图进合集附加图组并上锁，可移除', () async {
      await db.addToCollection(collectionId, MediaKind.game, 'g1');
      final MediaCollectionRow collection = (await db.getMediaCollectionById(
        collectionId,
      ))!;
      BannerPickerTarget target = await loadCollectionBannerPickerTarget(
        db: db,
        collection: collection,
        onlineEnabled: true,
        thumbnailsDirectory: dir,
        store: store,
      );
      expect(target.sources, <BannerPickerSource>[
        BannerPickerSource.online,
        BannerPickerSource.fromWork,
        BannerPickerSource.fileOrLink,
      ]);
      expect(target.fromWorkLabel, t.media_banner_source_from_collection);
      expect(target.clear, isNull);
      await target.apply(gif('pick.gif'));
      final MediaImageRow row = (await db.getMediaImagesForCollection(
        collectionId,
      )).single;
      expect(row.userChosen, isTrue);

      target = await loadCollectionBannerPickerTarget(
        db: db,
        collection: collection,
        onlineEnabled: false,
        thumbnailsDirectory: dir,
        store: store,
      );
      expect(target.loadOnline, isNull);
      expect(target.currentUserChosen, isTrue);
      await target.clear!();
      expect(await db.getMediaImagesForCollection(collectionId), isEmpty);
    });
  });
}
