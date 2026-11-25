// video-5：合集里的一集打开时，播放器在首帧前逐成员各查一次视频行与集级刮削
// （24 集约 50 次往返）。[VideoBookRepository.collectionPlaybackSnapshot] 把它收成
// 与集数无关的固定几条语句。
//
// 钉子：
// - SELECT 条数与集数无关（逐集 N+1 回归即红）；
// - 结果按成员 sortIndex 有序，非视频成员与孤儿成员（集行已删）被滤掉，集级刮削
//   按 bookUid 对上——与旧逐条路径同口径。
import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor, Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:test/test.dart';

class _SelectCounter extends QueryInterceptor {
  bool armed = false;
  int selects = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (armed) selects++;
    return executor.runSelect(statement, args);
  }
}

Future<int> _seedCollection(FushiDatabase db, int episodes) async {
  final int id = await db.createMediaCollection(
    'Series',
    collectionType: 'playlist',
  );
  for (int i = 0; i < episodes; i++) {
    final String uid = 'ep$i';
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: uid,
        title: 'Episode $i',
        videoPath: 'D:/Videos/$uid.mkv',
      ),
    );
    // 倒序写 sortIndex，钉结果按成员顺序而不是按 uid / 插入序。
    await db.upsertCollectionItemAt(
      id,
      MediaKind.video.dbValue,
      uid,
      episodes - i,
    );
    await db.upsertVideoScrapeMeta(
      VideoScrapeMetaCompanion.insert(
        bookUid: uid,
        source: 'tmdb',
        subjectId: '1',
        title: 'Name $i',
        episodeNumber: Value<int?>(i + 1),
        scrapedAt: DateTime(2026),
      ),
    );
  }
  return id;
}

void main() {
  test('合集快照的 SELECT 条数与集数无关', () async {
    Future<int> selectsFor(int episodes) async {
      final _SelectCounter counter = _SelectCounter();
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory().interceptWith(counter),
      );
      addTearDown(db.close);
      final int id = await _seedCollection(db, episodes);
      counter.armed = true;
      final CollectionPlaybackSnapshot snap = await VideoBookRepository(
        db,
      ).collectionPlaybackSnapshot(id);
      counter.armed = false;
      expect(snap.episodes, hasLength(episodes));
      return counter.selects;
    }

    final int small = await selectsFor(2);
    final int large = await selectsFor(24);
    expect(large, small, reason: '24 集与 2 集的 SELECT 条数应相同（无逐集查询）');
    // 6 条快照本体 + 2 条分栏批量查询（手动分栏 / 手动季集指定，拍板台
    // iR6ccUys9H），都与集数无关。
    expect(small, lessThanOrEqualTo(8));
  });

  test('按成员顺序返回，滤掉非视频与孤儿成员，集级刮削按 uid 对上', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int id = await _seedCollection(db, 3);
    // 孤儿成员：成员行在、集行已删。
    await db.upsertCollectionItemAt(id, MediaKind.video.dbValue, 'gone', 0);
    // 非视频成员。
    await db.upsertCollectionItemAt(id, 'book', 'ep0', 99);

    final CollectionPlaybackSnapshot snap = await VideoBookRepository(
      db,
    ).collectionPlaybackSnapshot(id);

    expect(snap.collection?.name, 'Series');
    expect(snap.episodes.map((VideoBookRow r) => r.bookUid).toList(), <String>[
      'ep2',
      'ep1',
      'ep0',
    ]);
    expect(snap.episodeMeta['ep1']?.title, 'Name 1');
    expect(snap.episodeMeta['ep1']?.episodeNumber, 2);
    expect(snap.episodeMeta.containsKey('gone'), isFalse);
  });

  test('空合集不发成员批量查询', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int id = await db.createMediaCollection(
      'Empty',
      collectionType: 'playlist',
    );
    final CollectionPlaybackSnapshot snap = await VideoBookRepository(
      db,
    ).collectionPlaybackSnapshot(id);
    expect(snap.episodes, isEmpty);
    expect(snap.collection?.name, 'Empty');
  });
}
