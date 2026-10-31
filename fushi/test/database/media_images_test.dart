import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:fushi_core/fushi_core.dart';

/// v68 守卫：media_images 附加图组表（Jellyfin 图组对齐）。
///
/// 锁四件事：
///  1. 两种归属（合集 / 单视频）的整组替换与读回、组内排序；
///  2. CHECK 单一归属约束在 DB 层真的锁死（不是靠调用方自觉）；
///  3. 删归属（合集 / 视频）FK cascade 清行；
///  4. v67→v68 迁移把遗留 `collection_scrape_meta.backdrop_path` 搬进本表
///     （kind='backdrop', position=0），旧库升级后 hero 背景零丢失。
void main() {
  /// 必须显式开 `foreign_keys`：`NativeDatabase.memory()` 默认关闭外键，cascade
  /// 用例不开就是假绿（与 collection_scrape_meta_test 同一教训）。
  Future<FushiDatabase> openDb() async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (CommonDatabase rawDb) =>
            rawDb.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    addTearDown(db.close);
    return db;
  }

  MediaImagesCompanion collectionImage(
    int collectionId, {
    required MediaImageKind kind,
    int position = 0,
    required String path,
    String? sourceUrl,
  }) => MediaImagesCompanion.insert(
    collectionId: Value<int?>(collectionId),
    kind: kind.dbValue,
    position: Value<int>(position),
    path: path,
    sourceUrl: Value<String?>(sourceUrl),
  );

  test('合集归属：整组替换幂等 + 读回按 kind/position 排序', () async {
    final FushiDatabase db = await openDb();
    final int id = await db.createMediaCollection('c1');

    await db.replaceMediaImagesForCollection(id, <MediaImagesCompanion>[
      collectionImage(
        id,
        kind: MediaImageKind.backdrop,
        position: 1,
        path: '/b1.jpg',
      ),
      collectionImage(
        id,
        kind: MediaImageKind.backdrop,
        position: 0,
        path: '/b0.jpg',
      ),
      collectionImage(id, kind: MediaImageKind.logo, path: '/logo.png'),
    ]);
    // 再替换一次（重刮）：不残留上一轮的行。
    await db.replaceMediaImagesForCollection(id, <MediaImagesCompanion>[
      collectionImage(id, kind: MediaImageKind.backdrop, path: '/b0v2.jpg'),
      collectionImage(
        id,
        kind: MediaImageKind.titleCard,
        path: '/titlecard.jpg',
      ),
    ]);

    final List<MediaImageRow> rows = await db.getMediaImagesForCollection(id);
    expect(rows, hasLength(2), reason: '整组替换必须删干净旧行，不是逐条 upsert');
    expect(rows.first.kind, MediaImageKind.backdrop.dbValue);
    expect(rows.first.path, '/b0v2.jpg');
    expect(rows.last.kind, MediaImageKind.titleCard.dbValue);
  });

  test('视频归属：整组替换 + 与合集归属互不串桶', () async {
    final FushiDatabase db = await openDb();
    final int cid = await db.createMediaCollection('c1');
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>('video/movie1'),
        title: Value<String>('Movie 1'),
        videoPath: Value<String>('/abs/m1.mkv'),
      ),
    );

    await db.replaceMediaImagesForCollection(cid, <MediaImagesCompanion>[
      collectionImage(cid, kind: MediaImageKind.backdrop, path: '/c_b0.jpg'),
    ]);
    await db.replaceMediaImagesForBook('video/movie1', <MediaImagesCompanion>[
      MediaImagesCompanion.insert(
        bookUid: const Value<String?>('video/movie1'),
        kind: MediaImageKind.backdrop.dbValue,
        path: '/v_b0.jpg',
      ),
    ]);

    expect(
      (await db.getMediaImagesForCollection(cid)).single.path,
      '/c_b0.jpg',
    );
    expect(
      (await db.getMediaImagesForBook('video/movie1')).single.path,
      '/v_b0.jpg',
    );
    expect(await db.getAllMediaImages(), hasLength(2));
  });

  test('CHECK 单一归属：双归属与零归属都被 DB 拒绝', () async {
    final FushiDatabase db = await openDb();
    final int cid = await db.createMediaCollection('c1');
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>('video/movie1'),
        title: Value<String>('Movie 1'),
        videoPath: Value<String>('/abs/m1.mkv'),
      ),
    );

    // 零归属。
    await expectLater(
      db
          .into(db.mediaImages)
          .insert(
            MediaImagesCompanion.insert(
              kind: MediaImageKind.logo.dbValue,
              path: '/orphan.png',
            ),
          ),
      throwsA(anything),
      reason: '归属双空的图行谁都回收不了 = 确定性泄漏，必须在 DB 层拒收',
    );
    // 双归属。
    await expectLater(
      db
          .into(db.mediaImages)
          .insert(
            MediaImagesCompanion.insert(
              collectionId: Value<int?>(cid),
              bookUid: const Value<String?>('video/movie1'),
              kind: MediaImageKind.logo.dbValue,
              path: '/both.png',
            ),
          ),
      throwsA(anything),
      reason: '双归属行删除语义不可判定（跟谁 cascade？），必须在 DB 层拒收',
    );
  });

  test('删视频 → 视频归属行 FK cascade 清空', () async {
    final FushiDatabase db = await openDb();
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>('video/movie1'),
        title: Value<String>('Movie 1'),
        videoPath: Value<String>('/abs/m1.mkv'),
      ),
    );
    await db.replaceMediaImagesForBook('video/movie1', <MediaImagesCompanion>[
      MediaImagesCompanion.insert(
        bookUid: const Value<String?>('video/movie1'),
        kind: MediaImageKind.titleCard.dbValue,
        path: '/v_tc.jpg',
      ),
    ]);
    expect(await db.getAllMediaImages(), hasLength(1));

    await db.deleteVideoBook('video/movie1');
    expect(
      await db.getAllMediaImages(),
      isEmpty,
      reason: '删视频必须连带清它的附加图行（FK cascade）',
    );
  });
}
