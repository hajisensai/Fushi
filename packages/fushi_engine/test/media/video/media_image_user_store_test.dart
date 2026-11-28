import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/cover_file_writer.dart';
import 'package:fushi_engine/media/video/media_image_user_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// v184 `media_images.user_chosen`：视频作品 / 合集附加图的来源锁。判锁在
/// [FushiDatabase.replaceMediaImagesForCollection] / `...ForBook`（刮削整组重写的
/// 唯一 DB 入口）与全量清理的事务里；用户写入经 [MediaImageUserStore]。
void main() {
  late FushiDatabase db;
  late Directory collections;
  late Directory videos;
  late Directory scratch;
  late MediaImageUserStore store;
  late int collectionId;

  // 最小 GIF：写侧判据只查 "GIF8" 头。
  final List<int> gif = <int>[
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0, 0, 0, 0x3B, //
  ];

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    collections = Directory.systemTemp.createTempSync('media_images_c_');
    videos = Directory.systemTemp.createTempSync('media_images_v_');
    scratch = Directory.systemTemp.createTempSync('media_images_src_');
    store = MediaImageUserStore(
      db,
      collectionsDirectory: collections,
      videosDirectory: videos,
      downloadImage: (String url) async {
        final File f = File(p.join(scratch.path, 'dl_${url.hashCode}.gif'));
        await f.writeAsBytes(gif);
        return f;
      },
    );
    collectionId = await db.createMediaCollection('剧');
  });

  tearDown(() async {
    await db.close();
    for (final Directory d in <Directory>[collections, videos, scratch]) {
      d.deleteSync(recursive: true);
    }
  });

  File source(String name) =>
      File(p.join(scratch.path, name))..writeAsBytesSync(gif);

  MediaImagesCompanion scraped(
    MediaImageKind kind,
    String path, {
    int position = 0,
  }) => MediaImagesCompanion.insert(
    collectionId: Value<int?>(collectionId),
    kind: kind.dbValue,
    position: Value<int>(position),
    path: path,
    sourceUrl: Value<String?>('https://image.tmdb.test$path'),
  );

  Future<List<MediaImageRow>> rowsOf(MediaImageKind kind) async =>
      (await db.getMediaImagesForCollection(
        collectionId,
      )).where((MediaImageRow r) => r.kind == kind.dbValue).toList();

  MediaImageOwner collection() => MediaImageOwner.collection(collectionId);

  test('用户选图：替换这一种的全部刮削行、落在合集目录、上锁', () async {
    await db
        .replaceMediaImagesForCollection(collectionId, <MediaImagesCompanion>[
          scraped(MediaImageKind.backdrop, '/s0.jpg'),
          scraped(MediaImageKind.backdrop, '/s1.jpg', position: 1),
        ]);
    final String dest = await store.setUserImageFromFile(
      collection(),
      MediaImageKind.backdrop,
      source('pick.gif'),
      sourceUrl: 'https://image.tmdb.test/pick.jpg',
    );
    expect(p.isWithin(collections.path, dest), isTrue);
    expect(p.basename(dest), 'collection_${collectionId}_backdrop_user.gif');
    final MediaImageRow row = (await rowsOf(MediaImageKind.backdrop)).single;
    expect(row.path, dest);
    expect(row.userChosen, isTrue);
    expect(row.sourceUrl, 'https://image.tmdb.test/pick.jpg');
    expect(
      (await store.firstImage(collection(), MediaImageKind.backdrop))?.path,
      dest,
    );
  });

  test('刮削整组重写：用户选的那一种整组让路，其余种类照常替换', () async {
    final String dest = await store.setUserImageFromFile(
      collection(),
      MediaImageKind.backdrop,
      source('pick.gif'),
    );
    await db
        .replaceMediaImagesForCollection(collectionId, <MediaImagesCompanion>[
          scraped(MediaImageKind.backdrop, '/new0.jpg'),
          scraped(MediaImageKind.backdrop, '/new1.jpg', position: 1),
          scraped(MediaImageKind.logo, '/logo.png'),
        ]);
    final MediaImageRow backdrop = (await rowsOf(
      MediaImageKind.backdrop,
    )).single;
    expect(backdrop.path, dest);
    expect(backdrop.userChosen, isTrue);
    expect((await rowsOf(MediaImageKind.logo)).single.path, '/logo.png');
    expect(File(dest).existsSync(), isTrue);

    // 再刮一次（空图组 = 清空）：用户的仍在，刮削的 logo 清掉。
    await db.replaceMediaImagesForCollection(
      collectionId,
      const <MediaImagesCompanion>[],
    );
    expect((await rowsOf(MediaImageKind.backdrop)).single.path, dest);
    expect(await rowsOf(MediaImageKind.logo), isEmpty);
  });

  test('刮削行写入时一律记为刮削来源（调用方给 userChosen 也不认）', () async {
    await db
        .replaceMediaImagesForCollection(collectionId, <MediaImagesCompanion>[
          scraped(
            MediaImageKind.backdrop,
            '/s.jpg',
          ).copyWith(userChosen: const Value<bool>(true)),
        ]);
    expect((await rowsOf(MediaImageKind.backdrop)).single.userChosen, isFalse);
  });

  test('移除：只删用户那张、回收文件并解锁，下一次刮削重新写入', () async {
    final String dest = await store.setUserImageFromFile(
      collection(),
      MediaImageKind.backdrop,
      source('pick.gif'),
    );
    await store.clearUserImage(collection(), MediaImageKind.backdrop);
    expect(await rowsOf(MediaImageKind.backdrop), isEmpty);
    expect(File(dest).existsSync(), isFalse);
    await db.replaceMediaImagesForCollection(
      collectionId,
      <MediaImagesCompanion>[scraped(MediaImageKind.backdrop, '/again.jpg')],
    );
    final MediaImageRow row = (await rowsOf(MediaImageKind.backdrop)).single;
    expect(row.path, '/again.jpg');
    expect(row.userChosen, isFalse);
  });

  test('移除不碰刮削的图（它们归刮削管）', () async {
    await db.replaceMediaImagesForCollection(
      collectionId,
      <MediaImagesCompanion>[scraped(MediaImageKind.backdrop, '/s0.jpg')],
    );
    await store.clearUserImage(collection(), MediaImageKind.backdrop);
    expect((await rowsOf(MediaImageKind.backdrop)).single.path, '/s0.jpg');
  });

  test('单视频归属：换一张不同扩展名的图回收旧文件；目录外的旧文件不碰', () async {
    final VideoBookRow book = await _insertVideo(db, 'movie-1');
    final MediaImageOwner movie = MediaImageOwner.book(book.bookUid);
    final File outside = source('outside.gif');
    await db.replaceMediaImagesForBook(book.bookUid, <MediaImagesCompanion>[
      MediaImagesCompanion.insert(
        bookUid: Value<String?>(book.bookUid),
        kind: MediaImageKind.backdrop.dbValue,
        path: outside.path,
        sourceUrl: const Value<String?>('https://x/sidecar.jpg'),
      ),
    ]);
    final String first = await store.setUserImageFromFile(
      movie,
      MediaImageKind.backdrop,
      source('a.gif'),
    );
    expect(p.isWithin(videos.path, first), isTrue);
    expect(p.basename(first), startsWith('video_'));
    expect(p.basename(first), endsWith('_backdrop_user.gif'));
    expect(outside.existsSync(), isTrue, reason: '刮削 sidecar 在目录外，不回收');

    final File png = File(p.join(scratch.path, 'b.png'))
      ..writeAsBytesSync(<int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
        0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, //
      ]);
    final String second = await store.setUserImageFromFile(
      movie,
      MediaImageKind.backdrop,
      png,
    );
    expect(second, endsWith('_backdrop_user.png'));
    expect(File(first).existsSync(), isFalse);
    final List<MediaImageRow> rows = await db.getMediaImagesForBook(
      book.bookUid,
    );
    expect(rows.single.path, second);
    expect(rows.single.userChosen, isTrue);

    // 散装电影 / 分集的刮削写回同样让路。
    await db.replaceMediaImagesForBook(book.bookUid, <MediaImagesCompanion>[
      MediaImagesCompanion.insert(
        bookUid: Value<String?>(book.bookUid),
        kind: MediaImageKind.backdrop.dbValue,
        path: '/rescrape.jpg',
        sourceUrl: const Value<String?>('https://x/rescrape.jpg'),
      ),
    ]);
    expect((await db.getMediaImagesForBook(book.bookUid)).single.path, second);
  });

  test('源不是可解码图片：抛错，旧图与锁不动', () async {
    final String dest = await store.setUserImageFromFile(
      collection(),
      MediaImageKind.backdrop,
      source('pick.gif'),
    );
    final File broken = File(p.join(scratch.path, 'broken.jpg'))
      ..writeAsBytesSync(<int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]);
    await expectLater(
      store.setUserImageFromFile(collection(), MediaImageKind.backdrop, broken),
      throwsA(isA<CoverImageInvalidException>()),
    );
    final MediaImageRow row = (await rowsOf(MediaImageKind.backdrop)).single;
    expect(row.path, dest);
    expect(row.userChosen, isTrue);
  });

  test('链接：下载后写入、记原地址', () async {
    await store.setUserImageFromUrl(
      collection(),
      MediaImageKind.backdrop,
      'https://example.test/wide.gif',
    );
    final MediaImageRow row = (await rowsOf(MediaImageKind.backdrop)).single;
    expect(row.sourceUrl, 'https://example.test/wide.gif');
    expect(row.userChosen, isTrue);
  });

  test('全量清理刮削记录：用户选的图（带在线原地址）保留，刮削投影清掉', () async {
    await db.replaceMediaImagesForCollection(
      collectionId,
      <MediaImagesCompanion>[scraped(MediaImageKind.logo, '/logo.png')],
    );
    final String dest = await store.setUserImageFromFile(
      collection(),
      MediaImageKind.backdrop,
      source('pick.gif'),
      sourceUrl: 'https://image.tmdb.test/pick.jpg',
    );
    await db.clearAllVideoScrapeRecords(
      clearLegacyScrapedMediaImagePaths: <int, String>{collectionId: dest},
    );
    final List<MediaImageRow> rows = await db.getMediaImagesForCollection(
      collectionId,
    );
    expect(rows.single.path, dest);
    expect(rows.single.userChosen, isTrue);
  });

  test('文件名：合集按 id、视频按 uid 摘要，带 _user；不认得的扩展名按 jpg', () {
    expect(
      mediaImageUserFileName(
        const MediaImageOwner.collection(7),
        MediaImageKind.backdrop,
        File('x.webp'),
      ),
      'collection_7_backdrop_user.webp',
    );
    expect(
      mediaImageUserFileName(
        const MediaImageOwner.book('uid'),
        MediaImageKind.backdrop,
        File('x.bin'),
      ),
      matches(RegExp(r'^video_[0-9a-f]{16}_backdrop_user\.jpg$')),
    );
  });
}

Future<VideoBookRow> _insertVideo(FushiDatabase db, String bookUid) async {
  await db
      .into(db.videoBooks)
      .insert(
        VideoBooksCompanion.insert(
          bookUid: bookUid,
          title: 'Movie',
          videoPath: '/videos/$bookUid.mkv',
        ),
      );
  return (await db.getVideoBookByBookUid(bookUid))!;
}
