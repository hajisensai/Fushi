// BUG-5466：媒体服务器「加入媒体库」的整部剧被 AI 管库变更集 `dissolve` 拆散后，AI 的
// 移出记成与用户移出相同的成员墓碑，用户再点「加入媒体库」也归不回去。
//
// - 用户亲手再加入时清掉本机 AI 整理移出（`evict` / `move`）留下的成员墓碑，集回到
//   合集；用户自己移出的那一集仍照常拦；被动收养（探针 / 目录刷新）不清。
// - 一次加入只读一次整理记录，不按集重复读。
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/library_agent/library_changeset.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/remote_collection_adoption_service.dart';
import 'package:test/test.dart';

/// 数 `library_organize_changes` 上的 SELECT：验证一次加入只读一次整理记录。
class _OrganizeLogReads extends QueryInterceptor {
  int count = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.contains('library_organize_changes')) count++;
    return super.runSelect(executor, statement, args);
  }
}

void main() {
  late FushiDatabase db;
  late _OrganizeLogReads reads;
  late RemoteCollectionAdoptionService adoption;
  setUp(() {
    reads = _OrganizeLogReads();
    db = FushiDatabase.forTesting(NativeDatabase.memory().interceptWith(reads));
    adoption = RemoteCollectionAdoptionService(db);
  });
  tearDown(() => db.close());

  const List<String> episodes = <String>['ep1', 'ep2', 'ep3'];

  RemoteVideoInfo episode(String id) => RemoteVideoInfo(
    id: id,
    title: 'Some Series $id',
    collection: RemoteCollectionMembership(
      collectionName: 'Some Series',
      collectionType: 'playlist',
      sortIndex: 10000 + episodes.indexOf(id) + 1,
    ),
  );

  /// 同 `MediaServerVideoLibrary.addMissing`：逐集写行，整部作品一起收养。
  Future<void> addSeries({bool userIntent = true}) async {
    for (final String id in episodes) {
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: id,
          title: 'Some Series $id',
          videoPath: 'media-server://$id',
        ),
      );
    }
    await adoption.adoptVideos(episodes.map(episode), userIntent: userIntent);
  }

  Future<MediaCollectionRow?> series() =>
      db.getMediaCollectionByNaturalKey('Some Series', 'playlist');

  Future<Set<String>> members() async {
    final MediaCollectionRow? c = await series();
    if (c == null) return <String>{};
    return <String>{
      for (final MediaCollectionItemRow i in await db.getCollectionItems(c.id))
        i.entryKey,
    };
  }

  Future<LibraryChangesetOutcome> dissolve() async {
    final MediaCollectionRow c = (await series())!;
    return applyLibraryChangeset(
      db,
      parseLibraryChangeset(<String, Object?>{
        'changes': <Map<String, Object?>>[
          <String, Object?>{
            'op': 'dissolve',
            'collection': 'C${c.id}',
            'why': 'Multiple episodes of Some Series could lead to confusion.',
          },
        ],
      }),
    );
  }

  test('AI 拆散过的剧：被动收养不放回，用户再「加入媒体库」时集回到合集', () async {
    await addSeries();
    final LibraryChangesetOutcome o = await dissolve();
    expect(o.applied.single['evicted'], episodes.length);
    expect(await members(), isEmpty);

    // 被动收养（探针 / 目录刷新）不推翻 AI 的移出，也不读整理记录。
    reads.count = 0;
    await addSeries(userIntent: false);
    expect(await members(), isEmpty);
    expect(reads.count, 0);

    // 用户亲手再加入：AI 的移出不是用户否决。整部作品只读一次整理记录。
    await addSeries();
    expect(await members(), episodes.toSet());
    expect(reads.count, 1);
  });

  test('用户自己移出的那一集，再加入仍不放回（只清 AI 留下的墓碑）', () async {
    await addSeries();
    final MediaCollectionRow before = (await series())!;
    await db.removeFromCollection(before.id, MediaKind.video, 'ep2');
    await dissolve();
    expect(await members(), isEmpty);

    await addSeries();
    expect(await members(), <String>{'ep1', 'ep3'});
  });

  test('AI 把一集挪去别的合集（move）：来处合集再加入时放回；撤销过的不算', () async {
    await addSeries();
    final MediaCollectionRow c = (await series())!;
    for (final String k in <String>['ep2', 'ep3']) {
      await db.removeFromCollectionAutomatically(
        c.id,
        MediaKind.video.dbValue,
        k,
      );
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int runId = await db
        .into(db.libraryOrganizeRuns)
        .insert(
          LibraryOrganizeRunsCompanion.insert(
            domain: 'video',
            trigger: 'test',
            startedAt: now,
            finishedAt: Value<int?>(now),
            status: 'done',
          ),
        );
    Future<void> logMove(String key, {int? undoneAt}) => db
        .into(db.libraryOrganizeChanges)
        .insert(
          LibraryOrganizeChangesCompanion.insert(
            runId: runId,
            kind: 'move',
            collectionName: 'Elsewhere',
            collectionType: 'collection',
            source: 'ai',
            confidence: 'high',
            payloadJson: jsonEncode(<String, Object?>{
              'from': <String, Object?>{
                'name': 'Some Series',
                'type': 'playlist',
              },
              'members': <Map<String, Object?>>[
                <String, Object?>{'t': MediaKind.video.dbValue, 'k': key},
              ],
              'added': <Object?>[],
            }),
            undoneAt: Value<int?>(undoneAt),
          ),
        );
    await logMove('ep2');
    // ep3 那条记录已被撤销：墓碑不再算 AI 的移出。
    await logMove('ep3', undoneAt: now);

    await addSeries();
    expect(await members(), <String>{'ep1', 'ep2'});
  });

  test('AI 移出后用户加回又亲手移出：再「加入媒体库」不放回（BUG-5016 成员墓碑）', () async {
    await addSeries();
    await dissolve();
    expect(await members(), isEmpty);

    // 用户先把 ep1 加回来（重建合集），再把 ep2 亲手加进去、随后又亲手移出。
    await adoption.adoptVideos(<RemoteVideoInfo>[
      episode('ep1'),
    ], userIntent: true);
    final MediaCollectionRow c = (await series())!;
    await db.addToCollection(c.id, MediaKind.video, 'ep2');
    expect(await members(), <String>{'ep1', 'ep2'});
    // 用户的移出必然晚于 AI 那次运行结束；测试里同一毫秒会混淆上界，让时钟走一格。
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await db.removeFromCollection(c.id, MediaKind.video, 'ep2');

    // 整理记录里 dissolve 的 evict 仍未撤销，但 ep2 现在的墓碑是用户写的：照常拦。
    await addSeries();
    expect(await members(), <String>{'ep1', 'ep3'});
  });
}
