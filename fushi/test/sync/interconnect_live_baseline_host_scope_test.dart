/// BUG-4434：互联 live 基线按 host 分槽（只对带 hostId 的 host），会话钉住 host。
///
/// 此前 live 基线键 `(assetKey, dimension)` 不带 host：client 配了两台 host（A、B）
/// 时，与 A 达成一致的基线在会话故障切到 B 之后被照搬去判 B 的值——本端停在基线、
/// B 不同，就被判成「对端单边改动」把 B 的值静默落到本机。这里用两台真 server 驱动
/// 真 client backend 钉住：基线落各自 host 的作用域、会话中途换 host 时 live 读写
/// 在发请求前抛出、升级前的无后缀旧行按候选形态领养 / 删除 / 保留。
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_book_progress_sync.dart';
import 'package:fushi/src/sync/interconnect_playback_position_sync.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_engine/sync/sync_channel_scope.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

const String _token = 'host-scope-token';

String _tagOf(String hostId) => syncRemoteTag('fushiServer\n$hostId');

String _scoped(String logical, String hostId) =>
    remoteScopedKey(logical, _tagOf(hostId));

Future<void> _seedBook(FushiDatabase db, String title) => db.insertEpubBook(
  EpubBooksCompanion.insert(
    bookKey: title,
    title: title,
    epubPath: '/tmp/$title.epub',
    extractDir: '/tmp/$title',
    chapterCount: 1,
    chaptersJson: '["ch1"]',
    importedAt: DateTime.now().millisecondsSinceEpoch,
  ),
);

Future<void> _seedPosition(
  FushiDatabase db,
  String bookKey, {
  required int section,
  required int norm,
  required int updatedAt,
}) async {
  final String bookUid = (await db.resolveEpubBookUid(bookKey))!;
  await db.upsertReaderPosition(
    ReaderPositionsCompanion(
      bookUid: Value(bookUid),
      sectionIndex: Value(section),
      normCharOffset: Value(norm),
      charOffset: const Value(0),
      updatedAt: Value(updatedAt),
    ),
  );
}

Future<ReaderPositionRow?> _positionOf(FushiDatabase db, String bookKey) async {
  final String? uid = await db.resolveEpubBookUid(bookKey);
  return uid == null ? null : db.getReaderPosition(uid);
}

Future<void> _seedHostVideo(FushiDatabase db, Directory dir, String uid) async {
  final File videoFile = File(p.join(dir.path, '${uid.hashCode}.mp4'))
    ..writeAsBytesSync(<int>[0, 1, 2, 3]);
  await db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: uid,
      title: uid,
      videoPath: videoFile.path,
    ),
  );
}

/// 一台真 host（server + 它自己的库）。
class _Host {
  _Host(this.db, this.server, this.base);

  final FushiDatabase db;
  final FushiSyncServer server;
  final String base;

  static Future<_Host> start(Directory work, String name) async {
    final FushiDatabase db = _memDb();
    final LocalLibraryHostService libSvc = LocalLibraryHostService(
      db: db,
      dictionaryResourceRoot: Directory(work.path),
      packages: SyncAssetPackageService(db: db),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
    );
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: p.join(work.path, 'server_$name'),
      port: 0,
      token: _token,
      allowLan: false,
      libraryService: libSvc,
    );
    await server.start();
    return _Host(db, server, 'http://127.0.0.1:${server.port}');
  }

  Future<void> stop() async {
    await server.stop();
    await db.close();
  }
}

/// 会话在第 [switchOnRead] 次 live 视频位置读取之前故障切换到 [switchTo]。
class _SwitchingBackend extends InterconnectSyncBackend {
  _SwitchingBackend(super.probe, {required this.switchOnRead, this.switchTo})
    : super.withProbe();

  final int switchOnRead;
  final String? switchTo;
  int reads = 0;

  @override
  Future<LivePosition> getLiveVideoPosition(
    String id, {
    int episodeIndex = 0,
    InterconnectHostPin? pin,
  }) {
    if (++reads == switchOnRead) debugSwitchHostScope(switchTo);
    return super.getLiveVideoPosition(id, episodeIndex: episodeIndex, pin: pin);
  }
}

/// 不可达地址集合（probe 对它们回 false）。
final Set<String> _down = <String>{};

Future<bool> _probe(String url, String token) async => !_down.contains(url);

Future<T> _buildBackend<T extends InterconnectSyncBackend>(
  List<FushiClientUrl> candidates, {
  T Function()? create,
}) async {
  final FushiDatabase db = _memDb();
  addTearDown(db.close);
  final SyncRepository repo = SyncRepository(db);
  await repo.setFushiClientUrls(candidates);
  await repo.setFushiClientToken(_token);
  final InterconnectSyncBackend backend =
      create?.call() ?? InterconnectSyncBackend.withProbe(_probe);
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend as T;
}

SyncOrchestrator _orchestrator(
  FushiDatabase db,
  InterconnectSyncBackend backend,
  Directory tmp,
) => SyncOrchestrator(
  db: db,
  backend: backend,
  dictionaryResourceRoot: tmp,
  audioDatabaseRoot: tmp,
  tempDir: tmp,
  syncStats: false,
  syncAudioBookPosition: false,
  syncContent: false,
  syncMangaContent: false,
  syncAudioBookFiles: false,
  syncDictionary: false,
);

void main() {
  late Directory work;
  late _Host hostA;
  late _Host hostB;

  setUp(() async {
    _down.clear();
    work = await Directory.systemTemp.createTemp('live_host_scope_');
    hostA = await _Host.start(work, 'a');
    hostB = await _Host.start(work, 'b');
  });

  tearDown(() async {
    await hostA.stop();
    await hostB.stop();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  List<FushiClientUrl> twoHosts() => <FushiClientUrl>[
    FushiClientUrl(url: hostA.base, hostId: 'a'),
    FushiClientUrl(url: hostB.base, hostId: 'b'),
  ];

  test('V-A1：与 A 达成一致后会话切到 B，B 的不同进度判冲突，不静默落到本机', () async {
    await _seedBook(hostA.db, 'BookV');
    await _seedBook(hostB.db, 'BookV');
    await _seedPosition(
      hostB.db,
      'BookV',
      section: 7,
      norm: 700,
      updatedAt: 3000,
    );
    final FushiDatabase localDb = _memDb();
    addTearDown(localDb.close);
    await _seedBook(localDb, 'BookV');
    await _seedPosition(
      localDb,
      'BookV',
      section: 2,
      norm: 200,
      updatedAt: 1000,
    );

    final InterconnectSyncBackend backend = await _buildBackend(twoHosts());
    final SyncOrchestrator orch = _orchestrator(
      localDb,
      backend,
      Directory(p.join(work.path, 't'))..createSync(),
    );
    final SyncRunReport first = SyncRunReport();
    await orch.syncBookProgressLiveForTest(first, backend);
    expect(first.errors, isEmpty, reason: '${first.errors}');
    expect(
      (await _positionOf(hostA.db, 'BookV'))!.sectionIndex,
      2,
      reason: '第一轮落在 A：本端推给 A',
    );
    final int? agreedWithA = await localDb.getSyncBaseline(
      'BookV',
      _scoped(kInterconnectBookProgressDimension, 'a'),
    );
    expect(agreedWithA, isNotNull);

    // A 掉线：会话复核后切到 B。
    _down.add(hostA.base);
    await backend.probeHostReachability();
    expect(backend.resolvedHostBaseUrl, hostB.base);

    final SyncRunReport second = SyncRunReport();
    await orch.syncBookProgressLiveForTest(second, backend);
    expect(second.errors, isEmpty, reason: '${second.errors}');
    final ReaderPositionRow local = (await _positionOf(localDb, 'BookV'))!;
    expect(local.sectionIndex, 2, reason: 'B 的进度不得静默覆盖本机');
    expect(local.normCharOffset, 200);
    expect(second.conflicts.map((SyncConflict c) => c.assetKey), <String>[
      'BookV',
    ]);
    expect(
      await localDb.getSyncBaseline(
        'BookV',
        _scoped(kInterconnectBookProgressDimension, 'a'),
      ),
      agreedWithA,
      reason: '与 A 的基线不动',
    );
    expect(
      await localDb.getSyncBaseline(
        'BookV',
        _scoped(kInterconnectBookProgressDimension, 'b'),
      ),
      isNull,
      reason: '与 B 没达成过一致',
    );
  });

  test('绑定后会话换 host：live 读写在发请求前抛出，不写 host、不留待确认行', () async {
    await _seedHostVideo(hostA.db, work, 'video/p');
    await hostA.db.setPrefTyped<int>(
      videoRemotePositionPrefKey('video/p'),
      100,
    );
    await hostA.db.setPrefTyped<int>(
      videoRemotePositionAtPrefKey('video/p'),
      1000,
    );
    final FushiDatabase localDb = _memDb();
    addTearDown(localDb.close);
    final InterconnectSyncBackend backend = await _buildBackend(twoHosts());
    final InterconnectPlaybackPositionSync sync =
        InterconnectPlaybackPositionSync(
          db: localDb,
          backend: backend,
          kind: PlaybackPositionKind.video,
        );
    await sync.bind();
    expect(sync.pin!.hostId, 'a');

    backend.debugSwitchHostScope('b');
    await expectLater(
      sync.remotePosition('video/p'),
      throwsA(isA<InterconnectHostChangedException>()),
    );
    await expectLater(
      sync.pushLocal(
        'video/p',
        local: (positionMs: 9000, updatedAtMs: 5000),
        remote: (positionMs: 100, updatedAtMs: 1000),
      ),
      throwsA(isA<InterconnectHostChangedException>()),
    );
    expect(
      await hostA.db.getPrefTyped<int>(
        videoRemotePositionPrefKey('video/p'),
        0,
      ),
      100,
      reason: 'host 没收到写入',
    );
    expect(
      await localDb.getSyncBaselinesForDimension(
        _scoped('${kInterconnectVideoPositionDimension}_pending', 'a'),
      ),
      isEmpty,
    );
  });

  test('sweep 第二条起会话换 host：报一条 host changed，之后不写，B 的作用域无行', () async {
    final FushiDatabase localDb = _memDb();
    addTearDown(localDb.close);
    for (final String uid in <String>['video/1', 'video/2']) {
      await _seedHostVideo(hostA.db, work, uid);
      await hostA.db.setPrefTyped<int>(videoRemotePositionPrefKey(uid), 0);
      await hostA.db.setPrefTyped<int>(videoRemotePositionAtPrefKey(uid), 1000);
      await localDb.setPrefTyped<int>(videoRemotePositionPrefKey(uid), 5000);
      await localDb.setPrefTyped<int>(videoRemotePositionAtPrefKey(uid), 2000);
      // 上次与 A 一致在 0，之后只有本机动了 → pushLocal。
      await localDb.setSyncBaseline(
        uid,
        _scoped(kInterconnectVideoPositionDimension, 'a'),
        0,
      );
    }
    final _SwitchingBackend backend = await _buildBackend<_SwitchingBackend>(
      twoHosts(),
      create: () => _SwitchingBackend(_probe, switchOnRead: 2, switchTo: 'b'),
    );
    final SyncRunReport report = SyncRunReport();
    await _orchestrator(
      localDb,
      backend,
      Directory(p.join(work.path, 't'))..createSync(),
    ).syncVideoProgressLiveForTest(report, backend);

    expect(report.errors, hasLength(1), reason: '${report.errors}');
    expect(report.errors.single, contains('host changed'));
    final List<int> hostPositions = <int>[
      for (final String uid in <String>['video/1', 'video/2'])
        await hostA.db.getPrefTyped<int>(videoRemotePositionPrefKey(uid), 0),
    ];
    expect(hostPositions..sort(), <int>[0, 5000], reason: '只有切换前那一条推了');
    for (final String dim in <String>[
      kInterconnectVideoPositionDimension,
      '${kInterconnectVideoPositionDimension}_pending',
    ]) {
      expect(
        await localDb.getSyncBaselinesForDimension(_scoped(dim, 'b')),
        isEmpty,
      );
    }
  });

  test('老条目多地址（都无 hostId）：换地址不算换 host，接着推进不冲突、用无后缀维度', () async {
    await _seedBook(hostA.db, 'BookL');
    final FushiDatabase localDb = _memDb();
    addTearDown(localDb.close);
    await _seedBook(localDb, 'BookL');
    await _seedPosition(
      localDb,
      'BookL',
      section: 1,
      norm: 100,
      updatedAt: 1000,
    );
    final String alt = 'http://localhost:${hostA.server.port}';
    final InterconnectSyncBackend backend = await _buildBackend(
      <FushiClientUrl>[
        FushiClientUrl(url: hostA.base),
        FushiClientUrl(url: alt),
      ],
    );
    final SyncOrchestrator orch = _orchestrator(
      localDb,
      backend,
      Directory(p.join(work.path, 't'))..createSync(),
    );
    final InterconnectBookProgressSync before = InterconnectBookProgressSync(
      db: localDb,
      backend: backend,
    );
    await before.bind();
    await orch.syncBookProgressLiveForTest(SyncRunReport(), backend);

    _down.add(hostA.base);
    await backend.probeHostReachability();
    expect(backend.resolvedHostBaseUrl, alt);
    final InterconnectBookProgressSync after = InterconnectBookProgressSync(
      db: localDb,
      backend: backend,
    );
    await after.bind();
    expect(after.pin, before.pin, reason: '老条目之间换地址不算换 host');
    expect(
      await after.storageDimensionForTest(),
      kInterconnectBookProgressDimension,
    );

    await _seedPosition(
      localDb,
      'BookL',
      section: 3,
      norm: 300,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final SyncRunReport report = SyncRunReport();
    await orch.syncBookProgressLiveForTest(report, backend);
    expect(report.errors, isEmpty, reason: '${report.errors}');
    expect(report.conflicts, isEmpty);
    expect((await _positionOf(hostA.db, 'BookL'))!.sectionIndex, 3);
    expect(
      BookProgressBaseline.decode(
        await localDb.getSyncBaseline(
          'BookL',
          kInterconnectBookProgressDimension,
        ),
      )!.sectionIndex,
      3,
    );
  });

  group('领养升级前的无后缀旧行', () {
    const String dim = kInterconnectVideoPositionDimension;
    const String pending = '${kInterconnectVideoPositionDimension}_pending';

    InterconnectPlaybackPositionSync videoSync(
      FushiDatabase db,
      InterconnectSyncBackend backend,
    ) => InterconnectPlaybackPositionSync(
      db: db,
      backend: backend,
      kind: PlaybackPositionKind.video,
    );

    test('单 host：旧行全部搬到该 host 名下，无后缀为空', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      await db.setSyncBaseline('v1', dim, 10);
      await db.setSyncBaseline('v2', dim, 20);
      await db.setSyncBaseline('v3', dim, 30);
      await db.setSyncBaseline('v1', pending, 11);
      final InterconnectSyncBackend backend = await _buildBackend(
        <FushiClientUrl>[FushiClientUrl(url: hostA.base, hostId: 'a')],
      );
      final InterconnectPlaybackPositionSync sync = videoSync(db, backend);
      await sync.bind();
      expect(await sync.storageDimensionForTest(), _scoped(dim, 'a'));
      expect(
        await db.getSyncBaselinesForDimension(_scoped(dim, 'a')),
        <String, int>{'v1': 10, 'v2': 20, 'v3': 30},
      );
      expect(
        await db.getSyncBaselinesForDimension(_scoped(pending, 'a')),
        <String, int>{'v1': 11},
      );
      expect(await db.getSyncBaselinesForDimension(dim), isEmpty);
      expect(await db.getSyncBaselinesForDimension(pending), isEmpty);
    });

    test('多 host：旧行来源不可考被删；首次绑在 B 上，两端不同的书判冲突', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      await db.setSyncBaseline('v1', dim, 10);
      await _seedBook(db, 'BookM');
      await _seedPosition(db, 'BookM', section: 2, norm: 200, updatedAt: 1000);
      await db.setSyncBaseline(
        'BookM',
        kInterconnectBookProgressDimension,
        const BookProgressBaseline(
          sectionIndex: 2,
          normCharOffset: 200,
        ).encode(),
      );
      await _seedBook(hostB.db, 'BookM');
      await _seedPosition(
        hostB.db,
        'BookM',
        section: 5,
        norm: 500,
        updatedAt: 3000,
      );
      _down.add(hostA.base); // A 离线时升级，首个 bind 落在 B。
      final InterconnectSyncBackend backend = await _buildBackend(twoHosts());

      final InterconnectPlaybackPositionSync sync = videoSync(db, backend);
      await sync.bind();
      expect(sync.pin!.hostId, 'b');
      expect(await db.getSyncBaselinesForDimension(dim), isEmpty);
      expect(await db.getSyncBaselinesForDimension(_scoped(dim, 'b')), isEmpty);

      final InterconnectBookProgressSync books = InterconnectBookProgressSync(
        db: db,
        backend: backend,
      );
      final EpubBookRow book = (await db.getEpubBook('BookM'))!;
      final BookProgressSyncStep step = await books.syncOne(
        book,
        remote: await books.remoteProgress(book),
      );
      expect(step.action, BookProgressSyncAction.conflict);
      expect((await _positionOf(db, 'BookM'))!.sectionIndex, 2);
    });

    test('混配（一台带 hostId + 一条认不出的老条目）：旧行保留给老条目，hostId 作用域为空', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      await db.setSyncBaseline('v1', dim, 10);
      // 老条目拿的是另一份凭据（另一台 host 签发的），认不出是 a。
      final InterconnectSyncBackend backend =
          await _buildBackend(<FushiClientUrl>[
            FushiClientUrl(url: hostA.base, hostId: 'a'),
            FushiClientUrl(url: hostB.base, token: 'issued-by-b'),
          ]);
      final InterconnectPlaybackPositionSync sync = videoSync(db, backend);
      await sync.bind();
      expect(sync.pin!.hostId, 'a');
      expect(await db.getSyncBaselinesForDimension(dim), <String, int>{
        'v1': 10,
      });
      expect(await db.getSyncBaselinesForDimension(_scoped(dim, 'a')), isEmpty);
    });

    // 评审 correctness-3：目标槽已有行时，无后缀旧行与它谁新不可考（降级期间写的
    // 更新，曾认不出 host 的老条目作用域写的可能更旧），不再拿旧行覆盖。
    test('目标槽已有不同的行：两行都删（首轮无基线），相同的行保留', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      await db.setSyncBaseline('v1', _scoped(dim, 'a'), 111);
      await db.setSyncBaseline('v1', dim, 222);
      await db.setSyncBaseline('v2', _scoped(dim, 'a'), 500);
      await db.setSyncBaseline('v2', dim, 500);
      await db.setSyncBaseline('v3', dim, 30);
      final InterconnectSyncBackend backend = await _buildBackend(
        <FushiClientUrl>[FushiClientUrl(url: hostA.base, hostId: 'a')],
      );
      final InterconnectPlaybackPositionSync sync = videoSync(db, backend);
      expect(await sync.baseline('v1'), isNull);
      expect(await sync.baseline('v2'), 500);
      expect(await sync.baseline('v3'), 30);
      expect(await db.getSyncBaselinesForDimension(dim), isEmpty);
    });

    // 评审 tests-1：领养读的是无后缀行，第一次跑完它就空了，之后重跑也读到空集，
    // 所以单看「并发绑定后基线没倒退」测不出按 (db, 存储维度) 只做一次的缓存。这里
    // 在第一次领养后再放一条无后缀行：缓存在时后续绑定不再领养，它原样留着、已推进
    // 的基线不受影响；缓存被拿掉（每次 bind 都领养）时这条会被搬动 / 冲掉基线 → 红。
    test('领养每个进程按存储维度只做一次：并发绑定共用一次，之后出现的无后缀行不再搬动', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      await db.setSyncBaseline('v1', dim, 10);
      final InterconnectSyncBackend backend = await _buildBackend(
        <FushiClientUrl>[FushiClientUrl(url: hostA.base, hostId: 'a')],
      );
      final InterconnectPlaybackPositionSync s1 = videoSync(db, backend);
      final InterconnectPlaybackPositionSync s2 = videoSync(db, backend);
      final Future<void> b1 = s1.bind();
      final Future<void> b2 = s2.bind();
      await b1;
      await s1.recordBaseline('v1', 30);
      await b2;
      expect(await s2.baseline('v1'), 30);
      expect(await db.getSyncBaselinesForDimension(dim), isEmpty);

      await db.setSyncBaseline('v1', dim, 10);
      final InterconnectPlaybackPositionSync s3 = videoSync(db, backend);
      await s3.bind();
      expect(await s3.baseline('v1'), 30);
      expect(
        await db.getSyncBaselinesForDimension(_scoped(dim, 'a')),
        <String, int>{'v1': 30},
      );
      expect(await db.getSyncBaselinesForDimension(dim), <String, int>{
        'v1': 10,
      });
    });

    // 评审 compat-1 / correctness-3：同一台 host 一条地址带 hostId、一条手输的老条目
    // （同一份配对凭据）。修复前老条目落无后缀槽：两条地址各用一份基线，故障切换
    // 被当成换 host；adoption 恒为 keep。
    test('同一台 host 的混配（老条目与带 hostId 的地址同一份凭据）：归入同一作用域并领养旧行', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      await db.setSyncBaseline('v1', dim, 10);
      final String alt = 'http://localhost:${hostA.server.port}';
      final InterconnectSyncBackend backend = await _buildBackend(
        <FushiClientUrl>[
          FushiClientUrl(url: hostA.base, hostId: 'a'),
          FushiClientUrl(url: alt),
        ],
      );
      final InterconnectPlaybackPositionSync before = videoSync(db, backend);
      await before.bind();
      expect(before.pin!.hostId, 'a');
      expect(await before.storageDimensionForTest(), _scoped(dim, 'a'));
      expect(await before.baseline('v1'), 10);
      expect(await db.getSyncBaselinesForDimension(dim), isEmpty);
      await before.recordBaseline('v1', 500);

      _down.add(hostA.base);
      await backend.probeHostReachability();
      expect(backend.resolvedHostBaseUrl, alt);
      final InterconnectPlaybackPositionSync after = videoSync(db, backend);
      await after.bind();
      expect(after.pin, before.pin, reason: '同一台 host 的两条地址之间切换不算换 host');
      expect(await after.storageDimensionForTest(), _scoped(dim, 'a'));
      expect(await after.baseline('v1'), 500);
    });
  });

  group('interconnectScopeHostIdOf', () {
    const String fpA = 'aa:bb:cc';
    const String fpB = 'dd:ee:ff';

    test('自带 hostId 的候选就用它', () {
      final FushiClientUrl c = FushiClientUrl(url: 'http://x', hostId: 'h');
      expect(
        interconnectScopeHostIdOf(c, <FushiClientUrl>[c], fallbackToken: 't'),
        'h',
      );
    });

    test('老条目回落全局凭据、与带 hostId 的地址同一份 → 认领那台', () {
      final FushiClientUrl a = FushiClientUrl(
        url: 'http://lan',
        hostId: 'a',
        token: 't',
      );
      final FushiClientUrl legacy = FushiClientUrl(url: 'http://ddns');
      expect(
        interconnectScopeHostIdOf(legacy, <FushiClientUrl>[
          a,
          legacy,
        ], fallbackToken: 't'),
        'a',
      );
    });

    test('凭据不同 → 认不出', () {
      final FushiClientUrl a = FushiClientUrl(
        url: 'http://lan',
        hostId: 'a',
        token: 't',
      );
      final FushiClientUrl legacy = FushiClientUrl(
        url: 'http://other',
        token: 'u',
      );
      expect(
        interconnectScopeHostIdOf(legacy, <FushiClientUrl>[
          a,
          legacy,
        ], fallbackToken: 't'),
        isNull,
      );
    });

    test('两边都钉了指纹：指纹不同即使凭据相同也不认，指纹相同即使凭据不同也认', () {
      final FushiClientUrl a = FushiClientUrl(
        url: 'https://lan',
        hostId: 'a',
        token: 't',
        fingerprintSha256: fpA,
      );
      final FushiClientUrl other = FushiClientUrl(
        url: 'https://other',
        fingerprintSha256: fpB,
      );
      final FushiClientUrl same = FushiClientUrl(
        url: 'https://ddns',
        token: 'stale',
        fingerprintSha256: fpA.toUpperCase(),
      );
      final List<FushiClientUrl> all = <FushiClientUrl>[a, other, same];
      expect(interconnectScopeHostIdOf(other, all, fallbackToken: 't'), isNull);
      expect(interconnectScopeHostIdOf(same, all, fallbackToken: 't'), 'a');
    });

    test('与两台 host 都对得上 → 来源不可考，认不出', () {
      final FushiClientUrl a = FushiClientUrl(url: 'http://a', hostId: 'a');
      final FushiClientUrl b = FushiClientUrl(url: 'http://b', hostId: 'b');
      final FushiClientUrl legacy = FushiClientUrl(url: 'http://c');
      expect(
        interconnectScopeHostIdOf(legacy, <FushiClientUrl>[
          a,
          b,
          legacy,
        ], fallbackToken: 't'),
        isNull,
      );
    });
  });
}
