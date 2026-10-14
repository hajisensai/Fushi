import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/interconnect_playback_position_sync.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/playback_position_conflict_dialog.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart';
import 'package:fushi/src/sync/sync_conflict_prompter.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

/// BUG-3367：互联视频 / 有声书播放位置此前是纯「取较新时间戳」LWW——两台设备在
/// 两次同步之间各自看过同一条目，后同步的一端被静默盖掉，用户毫无察觉。现在按
/// 位置基线三方判定，真分叉进冲突弹窗；host 收位置时截断未来戳。
FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

PlaybackPosition _pos(int positionMs, int updatedAtMs) =>
    (positionMs: positionMs, updatedAtMs: updatedAtMs);

/// 只实现播放位置 live 端点的假互联后端；PUT 与真 host 同语义（截断未来戳后
/// 严格较新者胜）。
class _FakePositionBackend extends InterconnectSyncBackend {
  _FakePositionBackend()
    : super.withProbe((String url, String token) async => true);

  final Map<String, PlaybackPosition> video = <String, PlaybackPosition>{};
  final Map<String, PlaybackPosition> audiobook = <String, PlaybackPosition>{};
  final List<String> puts = <String>[];

  PlaybackPosition _put(
    Map<String, PlaybackPosition> store,
    String key,
    int positionMs,
    int updatedAtMs,
  ) {
    final PlaybackPosition current = store[key] ?? _pos(0, 0);
    return store[key] = resolvePositionLww(
      localPositionMs: current.positionMs,
      localUpdatedAtMs: current.updatedAtMs,
      remotePositionMs: positionMs,
      remoteUpdatedAtMs: updatedAtMs,
    );
  }

  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async => video[id] ?? _pos(0, 0);

  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {
    puts.add('video:$id@$positionMs/$updatedAtMs');
    _put(video, id, positionMs, updatedAtMs);
  }

  @override
  Future<({int positionMs, int updatedAtMs})> remoteAudiobookPosition(
    String bookKey,
  ) async => audiobook[bookKey] ?? _pos(0, 0);

  @override
  Future<void> putRemoteAudiobookPosition(
    String bookKey,
    int positionMs,
    int updatedAtMs,
  ) async {
    puts.add('audiobook:$bookKey@$positionMs/$updatedAtMs');
    _put(audiobook, bookKey, positionMs, updatedAtMs);
  }
}

Future<void> _seedLocalVideoRow(
  FushiDatabase db,
  String uid, {
  required int positionMs,
  required int atMs,
  int? playedAt,
}) async {
  await db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: uid,
      title: uid,
      videoPath: '/tmp/$uid.mp4',
      lastPositionMs: Value(positionMs),
      lastPlayedAt: Value(playedAt),
    ),
  );
  await db.setPrefTyped<int>(videoRemotePositionAtPrefKey(uid), atMs);
}

void main() {
  group('resolvePlaybackPositionThreeWay', () {
    BookProgressSyncAction resolve(
      PlaybackPosition local,
      PlaybackPosition remote, {
      int? base,
    }) => resolvePlaybackPositionThreeWay(
      local: local,
      remote: remote,
      basePositionMs: base,
    );

    test('一端无记录 → 另一端胜（不算分叉）', () {
      expect(
        resolve(_pos(500, 10), _pos(0, 0)),
        BookProgressSyncAction.pushLocal,
      );
      expect(
        resolve(_pos(0, 0), _pos(500, 10)),
        BookProgressSyncAction.applyRemote,
      );
    });

    test('两端都没时间戳（旧数据）→ 取较远位置，相同则已同步', () {
      expect(
        resolve(_pos(900, 0), _pos(100, 0)),
        BookProgressSyncAction.pushLocal,
      );
      expect(
        resolve(_pos(100, 0), _pos(900, 0)),
        BookProgressSyncAction.applyRemote,
      );
      expect(
        resolve(_pos(100, 0), _pos(100, 0)),
        BookProgressSyncAction.synced,
      );
    });

    test('位置相同、时间戳不同 → 已同步（只对齐时间戳）', () {
      expect(
        resolve(_pos(700, 10), _pos(700, 99), base: 100),
        BookProgressSyncAction.synced,
      );
    });

    test('有基线：只一端偏离 → 那端胜，与谁的时间戳更新无关', () {
      // 本端动了、host 停在基线——哪怕 host 时间戳更新（例如只是打开过）也是本端胜。
      expect(
        resolve(_pos(800, 10), _pos(100, 999), base: 100),
        BookProgressSyncAction.pushLocal,
      );
      expect(
        resolve(_pos(100, 999), _pos(800, 10), base: 100),
        BookProgressSyncAction.applyRemote,
      );
    });

    test('有基线：两端都偏离且不同 → 冲突（此前 LWW 会静默盖掉一端）', () {
      expect(
        resolve(_pos(800, 10), _pos(300, 20), base: 100),
        BookProgressSyncAction.conflict,
      );
    });

    test('无基线且两端位置不同 → 退回旧 LWW 一次（升级后首轮不批量弹冲突）', () {
      expect(
        resolve(_pos(800, 10), _pos(300, 20)),
        BookProgressSyncAction.applyRemote,
      );
      expect(
        resolve(_pos(800, 30), _pos(300, 20)),
        BookProgressSyncAction.pushLocal,
      );
      // 时间戳相等：取较远位置。
      expect(
        resolve(_pos(800, 20), _pos(300, 20)),
        BookProgressSyncAction.pushLocal,
      );
      expect(
        resolve(_pos(300, 20), _pos(800, 20)),
        BookProgressSyncAction.applyRemote,
      );
    });
  });

  group('未来时间戳截断', () {
    const int now = 1000000000;
    test('capFutureSyncStamp 只截超出余量的戳', () {
      expect(capFutureSyncStamp(now, nowMs: now), now);
      expect(
        capFutureSyncStamp(now + kSyncFutureStampToleranceMs, nowMs: now),
        now + kSyncFutureStampToleranceMs,
      );
      expect(
        capFutureSyncStamp(now + 86400000, nowMs: now),
        now + kSyncFutureStampToleranceMs,
      );
    });

    test('trustedStoredSyncStamp 把超限毒戳当作 0', () {
      expect(trustedStoredSyncStamp(now - 5, nowMs: now), now - 5);
      expect(trustedStoredSyncStamp(now + 86400000, nowMs: now), 0);
    });
  });

  group('host 收位置 PUT（LocalLibraryHostService）', () {
    late Directory work;
    late FushiDatabase hostDb;
    late LocalLibraryHostService host;

    setUp(() async {
      work = await Directory.systemTemp.createTemp('pos_conflict_host_');
      hostDb = _memDb();
      host = LocalLibraryHostService(
        db: hostDb,
        dictionaryResourceRoot: Directory(work.path),
        packages: SyncAssetPackageService(db: hostDb),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
      );
      final File f = File(p.join(work.path, 'v.mp4'))
        ..writeAsBytesSync(<int>[0, 1, 2, 3]);
      await hostDb.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/v',
          title: 'V',
          videoPath: f.path,
        ),
      );
      await hostDb.upsertAudiobook(
        AudiobooksCompanion.insert(
          bookKey: 'AB',
          alignmentFormat: 'srt',
          alignmentPath: '/tmp/AB.srt',
        ),
      );
    });

    tearDown(() async {
      await hostDb.close();
      if (work.existsSync()) await work.delete(recursive: true);
    });

    test('视频：上报的未来戳被截到 now + 余量，不能永久锁死后续写入', () async {
      final int now = DateTime.now().millisecondsSinceEpoch;
      await host.putVideoPosition('video/v', 600000, now + 86400000);
      final int storedAt = await hostDb.getPrefTyped<int>(
        videoRemotePositionAtPrefKey('video/v'),
        0,
      );
      expect(
        storedAt,
        lessThanOrEqualTo(
          DateTime.now().millisecondsSinceEpoch + kSyncFutureStampToleranceMs,
        ),
      );
      expect(storedAt, greaterThan(now));
    });

    test('视频：已存的超限毒戳被下一次正常上报覆盖', () async {
      final int now = DateTime.now().millisecondsSinceEpoch;
      await hostDb.setPrefTyped<int>(
        videoRemotePositionPrefKey('video/v'),
        100,
      );
      await hostDb.setPrefTyped<int>(
        videoRemotePositionAtPrefKey('video/v'),
        now + 86400000,
      );
      await host.putVideoPosition('video/v', 420000, now);
      expect(
        await hostDb.getPrefTyped<int>(
          videoRemotePositionPrefKey('video/v'),
          0,
        ),
        420000,
      );
      expect(
        await hostDb.getPrefTyped<int>(
          videoRemotePositionAtPrefKey('video/v'),
          0,
        ),
        now,
      );
    });

    test('有声书：同样截断未来戳、毒戳可自愈', () async {
      final int now = DateTime.now().millisecondsSinceEpoch;
      await hostDb.setPrefTyped<int>(audiobookPositionPrefKey('AB'), 100);
      await hostDb.setPrefTyped<int>(
        audiobookPositionAtPrefKey('AB'),
        now + 86400000,
      );
      await host.putAudiobookPosition('AB', 330000, now);
      expect(
        await hostDb.getPrefTyped<int>(audiobookPositionPrefKey('AB'), 0),
        330000,
      );
      await host.putAudiobookPosition('AB', 340000, now + 86400000);
      expect(
        await hostDb.getPrefTyped<int>(audiobookPositionAtPrefKey('AB'), 0),
        lessThanOrEqualTo(
          DateTime.now().millisecondsSinceEpoch + kSyncFutureStampToleranceMs,
        ),
      );
    });
  });

  group('InterconnectPlaybackPositionSync', () {
    test('视频 pushLocal：时间戳抬到 host+1，只改时间戳 pref、不碰 lastPlayedAt', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      await _seedLocalVideoRow(
        db,
        'v1',
        positionMs: 800000,
        atMs: 1000,
        playedAt: 1000,
      );
      final _FakePositionBackend backend = _FakePositionBackend()
        ..video['v1'] = _pos(100000, 5000);
      final InterconnectPlaybackPositionSync sync =
          InterconnectPlaybackPositionSync(
            db: db,
            backend: backend,
            kind: PlaybackPositionKind.video,
          );

      final PlaybackPosition local = await sync.localPosition('v1');
      expect(local, _pos(800000, 1000));
      // nowMs 落后于 host 戳（本机时钟慢）：抬戳只能取 host + 1。
      await sync.pushLocal(
        'v1',
        local: local,
        remote: _pos(100000, 5000),
        nowMs: 3000,
      );

      expect(
        backend.video['v1'],
        _pos(800000, 5001),
        reason: 'host 端严格较新者胜，戳不抬就会被丢弃',
      );
      expect(
        await db.getPrefTyped<int>(videoRemotePositionAtPrefKey('v1'), 0),
        5001,
      );
      final VideoBookRow row = (await db.getVideoBookByBookUid('v1'))!;
      expect(row.lastPlayedAt, 1000, reason: '抬戳不是一次观看，不能污染续播锚点（BUG-1542）');
      expect(await sync.baseline('v1'), 800000);
    });

    test('视频 pushLocal：host 存的是超限毒戳时不把「毒戳+1」写进本端，下一轮不再重复 PUT', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      const int now = 1700000000000;
      const int poison = now + 86400000;
      await db.setPrefTyped<int>(videoRemotePositionPrefKey('vp'), 800000);
      await db.setPrefTyped<int>(videoRemotePositionAtPrefKey('vp'), now - 10);
      final _FakePositionBackend backend = _FakePositionBackend()
        ..video['vp'] = _pos(100000, poison);
      final InterconnectPlaybackPositionSync sync =
          InterconnectPlaybackPositionSync(
            db: db,
            backend: backend,
            kind: PlaybackPositionKind.video,
          );

      final PlaybackPosition agreed = await sync.pushLocal(
        'vp',
        local: await sync.localPosition('vp'),
        remote: _pos(100000, poison),
        nowMs: now,
      );
      expect(
        agreed.updatedAtMs,
        lessThanOrEqualTo(now + kSyncFutureStampToleranceMs),
        reason: '毒戳 + 1 不能抬进本端 _at_ pref',
      );
      expect(
        await db.getPrefTyped<int>(videoRemotePositionAtPrefKey('vp'), 0),
        agreed.updatedAtMs,
      );

      // 真 host 会截断上报戳、把毒戳当 0 比较——这里把 host 存值换成截断后的结果，
      // 模拟下一轮 sweep：两端位置与时间戳都一致 → alignSynced 不再 PUT。
      backend.video['vp'] = (
        positionMs: 800000,
        updatedAtMs: capFutureSyncStamp(agreed.updatedAtMs, nowMs: now),
      );
      backend.puts.clear();
      final PlaybackPosition local = await sync.localPosition('vp');
      final PlaybackPosition remote = await sync.remotePosition('vp');
      expect(
        resolvePlaybackPositionThreeWay(
          local: local,
          remote: remote,
          basePositionMs: await sync.baseline('vp'),
        ),
        BookProgressSyncAction.synced,
      );
      await sync.alignSynced('vp', local: local, remote: remote);
      expect(backend.puts, isEmpty, reason: '对齐后每轮都 PUT 就是这个 bug');
    });

    test('顺序接力：A 实时上报推进基线 → B 接着看 → A 下轮 sweep 判拉取而不是冲突', () async {
      final FushiDatabase dbA = _memDb();
      addTearDown(dbA.close);
      final _FakePositionBackend host = _FakePositionBackend();
      final InterconnectPlaybackPositionSync syncA =
          InterconnectPlaybackPositionSync(
            db: dbA,
            backend: host,
            kind: PlaybackPositionKind.video,
          );
      // 起点：A 与 host 在 100 达成一致（基线 100）。
      await dbA.setPrefTyped<int>(videoRemotePositionPrefKey('relay'), 100);
      await dbA.setPrefTyped<int>(videoRemotePositionAtPrefKey('relay'), 1000);
      host.video['relay'] = _pos(100, 1000);
      await syncA.recordBaseline('relay', 100);

      // A 串流看到 600：播放页写本地 pref 后走 reportLive 上报（与
      // video_fushi_page._persistRemotePosition 同一入口）。
      await dbA.setPrefTyped<int>(videoRemotePositionPrefKey('relay'), 600);
      await dbA.setPrefTyped<int>(videoRemotePositionAtPrefKey('relay'), 2000);
      await syncA.reportLive('relay', _pos(600, 2000));
      expect(host.video['relay'], _pos(600, 2000));
      expect(await syncA.baseline('relay'), 600);

      // B 从 600 接着看到 900，上报 host。
      await host.putRemoteVideoPosition('relay', 900, 3000);

      // A 下轮 sweep。
      final PlaybackPosition local = await syncA.localPosition('relay');
      final PlaybackPosition remote = await syncA.remotePosition('relay');
      final BookProgressSyncAction action = resolvePlaybackPositionThreeWay(
        local: local,
        remote: remote,
        basePositionMs: await syncA.baseline('relay'),
      );
      expect(action, BookProgressSyncAction.applyRemote, reason: '顺序接力不是分叉');
      await syncA.applyRemote('relay', remote);
      expect(
        await dbA.getPrefTyped<int>(videoRemotePositionPrefKey('relay'), 0),
        900,
      );
      expect(await syncA.baseline('relay'), 900);
    });

    test('视频 applyRemote：写回行与 pref，playedAt 用对端时刻；流式视频不建行', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      await _seedLocalVideoRow(db, 'v2', positionMs: 1000, atMs: 10);
      final _FakePositionBackend backend = _FakePositionBackend();
      final InterconnectPlaybackPositionSync sync =
          InterconnectPlaybackPositionSync(
            db: db,
            backend: backend,
            kind: PlaybackPositionKind.video,
          );

      await sync.applyRemote('v2', _pos(250000, 7000));
      final VideoBookRow row = (await db.getVideoBookByBookUid('v2'))!;
      expect(row.lastPositionMs, 250000);
      expect(row.lastPlayedAt, 7000);
      expect(await sync.baseline('v2'), 250000);

      await sync.applyRemote('stream', _pos(90000, 8000));
      expect(await db.getVideoBookByBookUid('stream'), isNull);
      expect(
        await db.getPrefTyped<int>(videoRemotePositionPrefKey('stream'), 0),
        90000,
      );
    });

    test('有声书 alignSynced：同位置时把较新时间戳对齐到本端并记基线', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      await db.setPrefTyped<int>(audiobookPositionPrefKey('AB'), 5000);
      await db.setPrefTyped<int>(audiobookPositionAtPrefKey('AB'), 10);
      final _FakePositionBackend backend = _FakePositionBackend();
      final InterconnectPlaybackPositionSync sync =
          InterconnectPlaybackPositionSync(
            db: db,
            backend: backend,
            kind: PlaybackPositionKind.audiobook,
          );

      final bool changed = await sync.alignSynced(
        'AB',
        local: _pos(5000, 10),
        remote: _pos(5000, 20),
      );
      expect(changed, isTrue);
      expect(
        await db.getPrefTyped<int>(audiobookPositionAtPrefKey('AB'), 0),
        20,
      );
      expect(await sync.baseline('AB'), 5000);
      expect(backend.puts, isEmpty);
    });
  });

  group('loadPlaybackPositionConflicts（弹窗前复核）', () {
    test('只挑播放位置维度，并丢掉此刻已不再分叉的条目', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      // still：两端仍都偏离基线 → 进弹窗。
      await _seedLocalVideoRow(db, 'still', positionMs: 800, atMs: 10);
      await db.setSyncBaseline('still', kInterconnectVideoPositionDimension, 1);
      // healed：报告之后两端已对齐 → 不进弹窗。
      await _seedLocalVideoRow(db, 'healed', positionMs: 500, atMs: 10);
      final _FakePositionBackend backend = _FakePositionBackend()
        ..video['still'] = _pos(300, 20)
        ..video['healed'] = _pos(500, 30);

      final List<PlaybackPositionConflictView> views =
          await loadPlaybackPositionConflicts(
            db: db,
            backend: backend,
            conflicts: <SyncConflict>[
              SyncConflict(
                assetKey: 'still',
                dimension: kInterconnectVideoPositionDimension,
                title: 'Still',
              ),
              SyncConflict(
                assetKey: 'healed',
                dimension: kInterconnectVideoPositionDimension,
                title: 'Healed',
              ),
              SyncConflict(
                assetKey: 'BookA',
                dimension: 'progress',
                title: 'B',
              ),
            ],
          );
      expect(
        views.map((PlaybackPositionConflictView v) => v.conflict.assetKey),
        <String>['still'],
      );
      expect(views.single.local, _pos(800, 10));
      expect(views.single.remote, _pos(300, 20));
    });

    test('非互联后端 → 空（播放位置冲突只来自互联通道）', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      expect(
        await loadPlaybackPositionConflicts(
          db: db,
          backend: Object(),
          conflicts: <SyncConflict>[
            SyncConflict(
              assetKey: 'x',
              dimension: kInterconnectVideoPositionDimension,
              title: 'X',
            ),
          ],
        ),
        isEmpty,
      );
    });
  });

  group('SyncConflictPrompter 分流到播放进度冲突弹窗', () {
    setUp(() => LocaleSettings.setLocale(AppLocale.en));

    Future<(FushiDatabase, _FakePositionBackend)> seedForkedVideo() async {
      final FushiDatabase db = _memDb();
      await _seedLocalVideoRow(db, 'vid', positionMs: 90000, atMs: 100);
      await db.setSyncBaseline('vid', kInterconnectVideoPositionDimension, 0);
      final _FakePositionBackend backend = _FakePositionBackend()
        ..video['vid'] = _pos(300000, 200);
      return (db, backend);
    }

    List<SyncConflict> conflicts() => <SyncConflict>[
      SyncConflict(
        assetKey: 'vid',
        dimension: kInterconnectVideoPositionDimension,
        title: 'Episode 3',
        localVersion: 100,
        remoteVersion: 200,
      ),
    ];

    Future<void> pumpApp(
      WidgetTester tester,
      GlobalKey<NavigatorState> navKey,
    ) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            home: const Scaffold(body: Text('home')),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('弹的是播放进度冲突弹窗（不是只认书的对比弹窗），选对端后落回本机', (
      WidgetTester tester,
    ) async {
      final (FushiDatabase db, _FakePositionBackend backend) =
          await seedForkedVideo();
      addTearDown(db.close);
      final SyncConflictPrompter prompter = SyncConflictPrompter();
      final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
      await pumpApp(tester, navKey);

      final Future<void> presenting = prompter.present(
        navigatorKey: navKey,
        db: db,
        backend: backend,
        conflicts: conflicts(),
        source: ConflictSource.manual,
        inBook: false,
      );
      await tester.pumpAndSettle();

      expect(find.byType(PlaybackPositionConflictDialog), findsOneWidget);
      expect(find.byType(SyncCompareDialog), findsNothing);
      expect(find.text('Episode 3'), findsOneWidget);
      expect(find.text('${t.sync_compare_use_local} · 1:30'), findsOneWidget);
      final Finder remote = find.text('${t.sync_compare_use_remote} · 5:00');
      expect(remote, findsOneWidget);

      await tester.tap(remote);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.sync_compare_apply(count: 1)));
      await tester.pumpAndSettle();
      await presenting;

      expect(find.byType(PlaybackPositionConflictDialog), findsNothing);
      final VideoBookRow row = (await db.getVideoBookByBookUid('vid'))!;
      expect(row.lastPositionMs, 300000);
      expect(
        await db.getSyncBaseline('vid', kInterconnectVideoPositionDimension),
        300000,
      );
      expect(backend.puts, isEmpty, reason: '选对端只落回本机，不推 host');
    });

    testWidgets('取消 → 不写任何一端，本会话自动同步不再弹同一组', (WidgetTester tester) async {
      final (FushiDatabase db, _FakePositionBackend backend) =
          await seedForkedVideo();
      addTearDown(db.close);
      final SyncConflictPrompter prompter = SyncConflictPrompter();
      final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
      await pumpApp(tester, navKey);

      final Future<void> presenting = prompter.present(
        navigatorKey: navKey,
        db: db,
        backend: backend,
        conflicts: conflicts(),
        source: ConflictSource.auto,
        inBook: false,
      );
      await tester.pumpAndSettle();
      expect(find.byType(PlaybackPositionConflictDialog), findsOneWidget);
      await tester.tap(find.text(t.dialog_cancel));
      await tester.pumpAndSettle();
      await presenting;

      expect((await db.getVideoBookByBookUid('vid'))!.lastPositionMs, 90000);
      expect(backend.video['vid'], _pos(300000, 200));
      expect(backend.puts, isEmpty);
      expect(
        prompter.shouldPrompt(
          conflicts: conflicts(),
          source: ConflictSource.auto,
          inBook: false,
        ),
        isFalse,
      );
    });
  });
}
