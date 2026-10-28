import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_continue.dart';
import 'package:fushi/src/media/video/media_server/media_server_library.dart'
    show MediaServerBookSpec;
import 'package:fushi/src/media/video/video_watched_marks.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/media_server_video_path.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

/// 手动「标记已看 / 未看」：真写库 + 真跑「下一集」选择器，焊死两件事：
/// 1. 标记会清掉续播位置——否则已打勾但断点停在中途会被判成「重看到一半」，
///    「下一集」不推进；
/// 2. 取消已看把完成标记与片尾位置一起收回，不会还被算成看完。
void main() {
  const int durationMs = 24 * 60 * 1000;

  FushiDatabase openDb() {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    return db;
  }

  Future<void> seed(FushiDatabase db, String uid, {int positionMs = 0}) =>
      db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>(uid),
          title: Value<String>(uid),
          videoPath: Value<String>('/abs/$uid.mkv'),
          lastPositionMs: Value<int>(positionMs),
        ),
      );

  CollectionMemberProgress progressOf(VideoBookRow row) =>
      CollectionMemberProgress(
        positionMs: row.lastPositionMs,
        completed: row.completedAt != null,
        durationMs: durationMs,
      );

  test('标记已看：打勾并清掉中途断点，该集算看完（下一集会推进）', () async {
    final FushiDatabase db = openDb();
    await seed(db, 'ep1', positionMs: 5 * 60 * 1000);
    await seed(db, 'ep2');

    final WatchedMarkResult result = await setVideosWatched(
      db: db,
      watched: true,
      localUids: <String>['ep1'],
    );

    final VideoBookRow ep1 = (await db.getVideoBookByBookUid('ep1'))!;
    expect(result.localChanged, 1);
    expect(ep1.completedAt, isNotNull);
    expect(ep1.lastPositionMs, 0);
    expect(progressOf(ep1).isFinished, isTrue);
    expect(
      continueMemberIndex(<CollectionMemberProgress>[
        progressOf(ep1),
        progressOf((await db.getVideoBookByBookUid('ep2'))!),
      ]),
      1,
      reason: '第 1 集手动标已看后，「继续」应落到第 2 集',
    );
  });

  test('取消已看：完成标记与片尾位置一起收回', () async {
    final FushiDatabase db = openDb();
    await seed(db, 'ep1', positionMs: durationMs - 1000);
    await db.markVideoCompleted('ep1', DateTime.now());

    await setVideosWatched(db: db, watched: false, localUids: <String>['ep1']);

    final VideoBookRow ep1 = (await db.getVideoBookByBookUid('ep1'))!;
    expect(ep1.completedAt, isNull);
    expect(ep1.lastPositionMs, 0);
    expect(progressOf(ep1).countsAsWatched, isFalse);
  });

  test('已看过的再标已看：保留原完成时刻，只收回位置', () async {
    final FushiDatabase db = openDb();
    await seed(db, 'ep1', positionMs: 60 * 1000);
    final DateTime first = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    await db.markVideoCompleted('ep1', first);

    await setVideosWatched(db: db, watched: true, localUids: <String>['ep1']);

    final VideoBookRow ep1 = (await db.getVideoBookByBookUid('ep1'))!;
    expect(ep1.completedAt, first);
    expect(ep1.lastPositionMs, 0);
  });

  test('批量：只动给出的集，其余不变', () async {
    final FushiDatabase db = openDb();
    for (final String uid in <String>['a', 'b', 'c']) {
      await seed(db, uid);
    }
    await setVideosWatched(
      db: db,
      watched: true,
      localUids: <String>['a', 'b'],
    );
    expect((await db.getVideoBookByBookUid('a'))!.completedAt, isNotNull);
    expect((await db.getVideoBookByBookUid('b'))!.completedAt, isNotNull);
    expect((await db.getVideoBookByBookUid('c'))!.completedAt, isNull);
  });

  test('媒体服务器：逐条标记；单条失败不挡其余，计入失败数', () async {
    final FushiDatabase db = openDb();
    final _FakeMarker marker = _FakeMarker(failOn: <String>{'bad'});

    final WatchedMarkResult result = await setVideosWatched(
      db: db,
      watched: true,
      remoteIds: <String>['r1', 'bad', 'r2'],
      remoteMarker: marker,
    );

    expect(marker.calls, <String>['r1:true', 'bad:true', 'r2:true']);
    expect(result.remoteChanged, 2);
    expect(result.remoteFailed, 1);
    expect(result.hasFailures, isTrue);
  });

  test('没有标记能力的来源：远端条目全部算失败，本地照常生效', () async {
    final FushiDatabase db = openDb();
    await seed(db, 'ep1');

    final WatchedMarkResult result = await setVideosWatched(
      db: db,
      watched: true,
      localUids: <String>['ep1'],
      remoteIds: <String>['r1'],
    );

    expect(result.localChanged, 1);
    expect(result.remoteFailed, 1);
  });

  test('标记写库时同一事务盖互联 LWW 戳：位置 0 @ 标记时刻、看完标记 @ 标记时刻', () async {
    final FushiDatabase db = openDb();
    await seed(db, 'ep1', positionMs: 5 * 60 * 1000);
    // 旧断点的戳停在很早以前：标记若不盖新戳，同步会拿 host 的旧断点灌回来。
    await db.setPrefTyped<int>(videoRemotePositionAtPrefKey('ep1'), 1000);
    final DateTime now = DateTime.fromMillisecondsSinceEpoch(1800000000000);

    await setVideosWatched(
      db: db,
      watched: true,
      localUids: <String>['ep1', 'missing'],
      now: now,
    );

    expect(
      await db.getPrefTyped<int>(videoRemotePositionPrefKey('ep1'), -1),
      0,
    );
    expect(
      await db.getPrefTyped<int>(videoRemotePositionAtPrefKey('ep1'), 0),
      now.millisecondsSinceEpoch,
    );
    expect(
      await db.getPrefTyped<int>(videoRemoteCompletedPrefKey('ep1'), 0),
      now.millisecondsSinceEpoch,
    );
    expect(
      await db.getPrefTyped<int>(videoRemoteCompletedAtPrefKey('ep1'), 0),
      now.millisecondsSinceEpoch,
    );
    expect(
      await db.getPrefTyped<int>(videoRemoteCompletedAtPrefKey('missing'), 0),
      0,
      reason: '不存在的行不写镜像键（否则凭空进同步基底）',
    );

    final DateTime later = now.add(const Duration(minutes: 1));
    await setVideosWatched(
      db: db,
      watched: false,
      localUids: <String>['ep1'],
      now: later,
    );
    expect(
      await db.getPrefTyped<int>(videoRemoteCompletedPrefKey('ep1'), -1),
      0,
      reason: '取消已看 = 「未看完」也是一次带戳写，能跨设备收敛',
    );
    expect(
      await db.getPrefTyped<int>(videoRemoteCompletedAtPrefKey('ep1'), 0),
      later.millisecondsSinceEpoch,
    );
  });

  test('restoreWatchState：原样写回看完时刻与断点并盖新戳（撤销用）', () async {
    final FushiDatabase db = openDb();
    await seed(db, 'ep1', positionMs: 90 * 1000);
    await setVideosWatched(db: db, watched: false, localUids: <String>['ep1']);
    final DateTime done = DateTime.fromMillisecondsSinceEpoch(1700000000000);

    await VideoBookRepository(
      db,
    ).restoreWatchState('ep1', completedAt: done, positionMs: 90 * 1000);

    final VideoBookRow ep1 = (await db.getVideoBookByBookUid('ep1'))!;
    expect(ep1.completedAt, done);
    expect(ep1.lastPositionMs, 90 * 1000);
    expect(
      await db.getPrefTyped<int>(videoRemotePositionPrefKey('ep1'), 0),
      90 * 1000,
    );
    expect(
      await db.getPrefTyped<int>(videoRemoteCompletedPrefKey('ep1'), 0),
      done.millisecondsSinceEpoch,
    );
  });

  test('本地入库的媒体服务器条目：本地写库 + 回写那台服务器；同一条目不重发', () async {
    final FushiDatabase db = openDb();
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('item-1'),
        title: const Value<String>('E1'),
        videoPath: Value<String>(
          mediaServerVideoPath(itemId: 'item-1', label: 'E1'),
        ),
        streamSpecJson: Value<String?>(
          const MediaServerBookSpec(
            serverId: 'srv-a',
            info: RemoteVideoInfo(id: 'item-1', title: 'E1'),
            workId: 'series-1',
          ).encode(),
        ),
      ),
    );
    final _FakeMarker server = _FakeMarker();
    final List<String> resolved = <String>[];

    final WatchedMarkResult result = await setVideosWatched(
      db: db,
      watched: true,
      localUids: <String>['item-1'],
      // 当前来源也镜像着同一条目：不该再发一次。
      remoteIds: <String>['item-1'],
      remoteMarker: _FakeMarker(),
      mediaServerMarker: (String serverId) async {
        resolved.add(serverId);
        return server;
      },
    );

    expect(resolved, <String>['srv-a']);
    expect(server.calls, <String>['item-1:true']);
    expect(result.localChanged, 1);
    expect(result.remoteChanged, 1);
    expect((await db.getVideoBookByBookUid('item-1'))!.completedAt, isNotNull);
  });

  test('失败提示区分：有本地行的失败 = 本地已更新；纯远端失败 = 什么都没改', () async {
    final FushiDatabase db = openDb();
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('item-1'),
        title: const Value<String>('E1'),
        videoPath: const Value<String>('media-server://item-1/E1'),
        streamSpecJson: Value<String?>(
          const MediaServerBookSpec(
            serverId: 'gone-server',
            info: RemoteVideoInfo(id: 'item-1', title: 'E1'),
          ).encode(),
        ),
      ),
    );

    final WatchedMarkResult localKept = await setVideosWatched(
      db: db,
      watched: true,
      localUids: <String>['item-1'],
      mediaServerMarker: (String _) async => throw StateError('signed out'),
    );
    expect(localKept.remoteFailed, 1);
    expect(localKept.failuresKeptLocally, isTrue);

    final WatchedMarkResult pureRemote = await setVideosWatched(
      db: db,
      watched: true,
      remoteIds: <String>['r1'],
      remoteMarker: _FakeMarker(failOn: <String>{'r1'}),
    );
    expect(pureRemote.remoteFailed, 1);
    expect(
      pureRemote.failuresKeptLocally,
      isFalse,
      reason: '纯远端条目失败时本机什么都没改，不能提示「本地状态已更新」',
    );
  });

  test('服务器没有「已播放」协议（如 Plex）：只改本地，不算失败', () async {
    final FushiDatabase db = openDb();
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('plex-1'),
        title: const Value<String>('M'),
        videoPath: const Value<String>('media-server://plex-1/M'),
        streamSpecJson: Value<String?>(
          const MediaServerBookSpec(
            serverId: 'plex',
            info: RemoteVideoInfo(id: 'plex-1', title: 'M'),
          ).encode(),
        ),
      ),
    );
    final WatchedMarkResult result = await setVideosWatched(
      db: db,
      watched: true,
      localUids: <String>['plex-1'],
      mediaServerMarker: (String _) async => null,
    );
    expect(result.hasFailures, isFalse);
    expect(result.localChanged, 1);
  });

  test('itemsThrough：含当前集的前缀；越界为空', () {
    final List<int> eps = <int>[1, 2, 3, 4];
    expect(itemsThrough(eps, 2), <int>[1, 2, 3]);
    expect(itemsThrough(eps, 0), <int>[1]);
    expect(itemsThrough(eps, 4), isEmpty);
    expect(itemsThrough(eps, -1), isEmpty);
  });
}

class _FakeMarker implements RemoteVideoPlayedMark {
  _FakeMarker({this.failOn = const <String>{}});

  final Set<String> failOn;
  final List<String> calls = <String>[];

  @override
  Future<void> setRemoteVideoPlayed(String id, {required bool played}) async {
    calls.add('$id:$played');
    if (failOn.contains(id)) throw StateError('server said no');
  }
}
