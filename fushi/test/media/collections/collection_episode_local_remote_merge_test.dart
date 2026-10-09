import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteCollectionMembership, RemoteVideoInfo;

/// BUG-2978 · 作品详情页同一集出两张卡（本地完整卡 + 远端只有标题的卡）。
///
/// 合集清单是跨端 union：媒体服务器按剧名把单集收养进同名本地合集（entryKey =
/// 服务器 item id），本机同一集的成员行 entryKey 是本地 bookUid——同一集两行。
/// 成员解析必须把这两行归并成一槽（本地优先、远端挂成 [remoteMirror]），
/// 集数 / 看完计数才与真实集数一致；库页走同一判据不再出远端占位卡。
void main() {
  late FushiDatabase db;
  late VideoBookRepository repo;
  late int collectionId;

  RemoteVideoInfo jellyfinEpisode(
    String id,
    int episode, {
    int? completedAt,
  }) =>
      RemoteVideoInfo(
        id: id,
        title: 'Frieren S01E${episode.toString().padLeft(2, '0')} Ep $episode',
        completedAt: completedAt,
        collection: RemoteCollectionMembership(
          collectionName: 'Frieren',
          collectionType: 'playlist',
          sortIndex: 10000 + episode,
        ),
      );

  VideoBookRow localRow(String uid, String path) => VideoBookRow(
        bookUid: uid,
        title: path,
        videoPath: path,
        lastPositionMs: 0,
        currentEpisode: 0,
        delayMs: 0,
      );

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = VideoBookRepository(db);
    collectionId =
        await db.createMediaCollection('Frieren', collectionType: 'playlist');
  });

  tearDown(() => db.close());

  test('本地 1-2 集 + 媒体服务器 1-3 集 → 三槽，1/2 集本地优先且保留远端副本', () async {
    for (final int ep in <int>[1, 2]) {
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value('video/local$ep'),
        title: Value('[Sub] Frieren - 0$ep [1080p]'),
        videoPath: Value('/anime/Frieren/[Sub] Frieren - 0$ep [1080p].mkv'),
      ));
    }
    for (final String key in <String>[
      'video/local1',
      'video/local2',
      'jf-1',
      'jf-2',
      'jf-3',
    ]) {
      await db.addToCollection(collectionId, MediaKind.video, key);
    }

    final List<CollectionEpisodeSlot> slots = await loadCollectionEpisodeSlots(
      repository: repo,
      collectionId: collectionId,
      loadRemoteVideos: () async => <RemoteVideoInfo>[
        jellyfinEpisode('jf-1', 1, completedAt: 123),
        jellyfinEpisode('jf-2', 2),
        jellyfinEpisode('jf-3', 3),
      ],
    );

    expect(
      slots.map((CollectionEpisodeSlot s) => s.entryKey).toList(),
      <String>['video/local1', 'video/local2', 'jf-3'],
    );
    expect(slots[0].isRemote, isFalse);
    expect(slots[0].remoteMirror?.id, 'jf-1');
    expect(slots[1].remoteMirror?.id, 'jf-2');
    expect(slots[2].isRemote, isTrue);
    // 在媒体服务器上看完的那一集，归并后仍算看完。
    expect(slots[0].completed, isTrue);
    expect(slots[1].completed, isFalse);
  });

  test('不同季同集号不归并；身份撞号时宁可不并', () {
    final Map<String, String> pairs = pairRemoteEpisodesWithLocal(
      local: <VideoBookRow>[
        localRow('a', '/anime/Show/Season 2/Show - 01.mkv'),
        localRow('b', '/anime/Show/Show S01E05 v1.mkv'),
        localRow('c', '/anime/Show/Show S01E05 v2.mkv'),
      ],
      remote: <RemoteVideoInfo>[
        const RemoteVideoInfo(id: 'r1', title: 'Show S01E01 Pilot'),
        const RemoteVideoInfo(id: 'r5', title: 'Show S01E05 Name'),
      ],
    );
    expect(pairs, isEmpty);
  });

  test('库页口径：按合集分桶判重，不在合集里的远端条目不判', () {
    final Map<String, int> collectionOf = <String, int>{
      'l1': 7,
      'r1': 7,
      'r2': 7,
      // r9 与 l1 同集号但不在同一合集。
      'r9': 8,
    };
    final Set<String> mirrored = remoteEpisodesMirroredLocally(
      local: <VideoBookRow>[localRow('l1', '/anime/Show/Show - 01.mkv')],
      remote: <RemoteVideoInfo>[
        const RemoteVideoInfo(id: 'r1', title: 'Show S01E01 A'),
        const RemoteVideoInfo(id: 'r2', title: 'Show S01E02 B'),
        const RemoteVideoInfo(id: 'r9', title: 'Show S01E01 A'),
        const RemoteVideoInfo(id: 'loose', title: 'Show S01E01 A'),
      ],
      collectionOfEntry: (String key) => collectionOf[key],
    );
    expect(mirrored, <String>{'r1'});
  });
}
