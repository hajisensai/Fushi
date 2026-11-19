import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show QueryRow, Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart'
    show VideoMetadataLookup;
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/metadata/video_scrape_runtime.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_video_support.dart';
import 'package:fushi/src/ops/op_catalog_assembly.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';

import '../helpers/test_platform_services.dart';

/// 视频刮削认领的撤销往返（`video.scrape.confirm` pick / identity / skip、
/// `video.work.identify`）：执行 → 撤销 → 认领涉及的全部表与 sidecar 文件与执行前
/// 逐项一致；认领后用户手改 → superseded 且不覆盖。不联网：刮削批次由假 runner 跑，
/// 它的「认领」走真实的 `VideoMetadataDatabaseStore.apply` 落库，再像协调器那样写
/// NFO / 海报 sidecar、登记所有权账本、换封面。

class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._prefs, this._thumbs)
    : super(testPlatformServices());

  final FushiDatabase _db;
  final PreferencesRepository _prefs;
  final Directory _thumbs;

  @override
  FushiDatabase get database => _db;

  @override
  PreferencesRepository get prefsRepo => _prefs;

  @override
  bool get isMigrationReadonly => false;

  @override
  Directory get thumbnailsDirectory => _thumbs;
}

class _Ref implements WidgetRef {
  _Ref(this.model);

  final AppModel model;

  @override
  T read<T>(ProviderListenable<T> provider) => model as T;

  @override
  void invalidate(ProviderOrFamily provider) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试不该用到 ${invocation.memberName}');
}

/// 只给路由用到的三样：控制器、当前控制器、观察任务。
class _FakeRuntime implements VideoScrapeRuntime {
  _FakeRuntime(this.controller);

  @override
  final VideoSourceScrapeTaskController controller;

  @override
  VideoSourceScrapeTaskController? get currentController => controller;

  @override
  Future<SourceScrapeReport> observe(Future<SourceScrapeReport> task) => task;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试不该用到 ${invocation.memberName}');
}

/// 假刮削：交互批次对 [pendingUnit] 发一次待确认；选中 / 指定身份就「认领」。
class _ClaimRunner
    implements VideoSourceScrapeRunner, VideoSourceScrapeManualBinding {
  _ClaimRunner(this.db);

  final FushiDatabase db;
  String? pendingUnit;

  static VideoSourceScrapeConfirmationCandidate candidate(
    VideoMetadataProviderKind provider,
    String id,
  ) => VideoSourceScrapeConfirmationCandidate(
    lookup: VideoMetadataLookup(
      provider: provider,
      externalId: id,
      mediaKind: VideoMetadataMediaKind.tv,
    ),
    work: VideoMetadataWork(
      provider: provider,
      kind: VideoMetadataMediaKind.tv,
      title: 'Candidate $id',
      ids: <VideoMetadataId>[VideoMetadataId(type: provider.name, value: id)],
    ),
  );

  Future<VideoSourceScrapeWork> _unit(String key) async {
    if (key.startsWith('collection:')) {
      final int id = int.parse(key.substring('collection:'.length));
      final List<VideoBookRow> members = <VideoBookRow>[
        for (final MediaCollectionItemRow item in await db.getCollectionItems(
          id,
        ))
          (await db.getVideoBookByBookUid(item.entryKey))!,
      ];
      final MediaCollectionRow collection = (await db.getMediaCollectionById(
        id,
      ))!;
      return VideoSourceScrapeWork(
        source: null,
        collection: collection,
        title: collection.name,
        members: members,
      );
    }
    final VideoBookRow book = (await db.getVideoBookByBookUid(
      key.substring('book:'.length),
    ))!;
    return VideoSourceScrapeWork(
      source: null,
      title: book.title,
      members: <VideoBookRow>[book],
    );
  }

  /// 认领：真实 apply + sidecar（NFO 新写、海报覆盖写）+ 账本 + 封面。
  Future<void> claim(String unitKey, VideoMetadataLookup lookup) async {
    final VideoSourceScrapeWork unit = await _unit(unitKey);
    final bool episodic = unit.collection != null;
    final String id = lookup.externalId;
    final VideoMetadataPerson seiyuu = VideoMetadataPerson(
      id: 'p$id',
      name: 'Seiyuu $id',
    );
    final VideoMetadataWork metadata = VideoMetadataWork(
      provider: lookup.provider,
      kind: episodic ? VideoMetadataMediaKind.tv : VideoMetadataMediaKind.movie,
      title: 'Work $id',
      plot: 'Plot $id',
      year: 2000 + int.parse(id) % 20,
      genres: <String>['Genre $id', 'Drama'],
      ids: <VideoMetadataId>[
        VideoMetadataId(type: lookup.provider.name, value: id),
      ],
      credits: <VideoMetadataCredit>[
        VideoMetadataCredit(
          kind: VideoMetadataCreditKind.voiceActor,
          person: seiyuu,
          character: VideoMetadataCharacter(id: 'c$id', name: 'Hero $id'),
        ),
      ],
      images: <VideoMetadataImage>[
        VideoMetadataImage(
          kind: VideoMetadataImageKind.cover,
          url: 'https://img.example/$id.jpg',
          provider: lookup.provider,
        ),
      ],
      seasons: episodic
          ? <VideoMetadataSeason>[
              VideoMetadataSeason(
                seasonNumber: 1,
                title: 'Season 1',
                episodes: <VideoMetadataEpisode>[
                  for (int e = 1; e <= unit.members.length; e++)
                    VideoMetadataEpisode(
                      seasonNumber: 1,
                      episodeNumber: e,
                      title: 'Episode $e of $id',
                      plot: 'Episode plot $e',
                    ),
                ],
              ),
            ]
          : const <VideoMetadataSeason>[],
    );
    final PersistedVideoMetadata persisted = await VideoMetadataDatabaseStore(
      db,
    ).apply(unit, metadata);
    final Directory dir = File(unit.members.first.videoPath).parent;
    final File nfo = File(p.join(dir.path, 'claim_$id.nfo'))
      ..writeAsStringSync('<id>$id</id>');
    final File poster = File(p.join(dir.path, 'poster.jpg'))
      ..writeAsStringSync('poster $id');
    await _ledger(nfo, persisted.workId, 'nfo');
    await _ledger(poster, persisted.workId, 'poster');
    if (unit.collection case final MediaCollectionRow c) {
      await db.customStatement(
        'UPDATE media_collections SET cover_path = ? WHERE id = ?',
        <Object?>[poster.path, c.id],
      );
    } else {
      await db.updateVideoBookCover(unit.members.single.bookUid, poster.path);
    }
  }

  Future<void> _ledger(File file, int workId, String kind) async {
    final String path = p.normalize(p.absolute(file.path));
    await db.customStatement(
      'DELETE FROM video_sidecar_artifacts WHERE path = ?',
      <Object?>[path],
    );
    await db
        .into(db.videoSidecarArtifacts)
        .insert(
          VideoSidecarArtifactsCompanion.insert(
            workId: Value<int?>(workId),
            artifactKind: kind,
            path: path,
            sha256: sha256.convert(file.readAsBytesSync()).toString(),
            generatorVersion: 'test',
            writePolicy: 'overwrite_own',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
  }

  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
    List<VideoSourceScrapeWork>? plannedWorks,
    String runScope = 'source',
  }) async {
    final String unit = pendingUnit!;
    final VideoSourceScrapeConfirmationCandidate? selected =
        await onConfirmation!(
          VideoSourceScrapeConfirmation(
            sourceId: source.id,
            sourceLabel: source.label,
            localWorkTitle: unit,
            workStableKey: unit,
            candidates: <VideoSourceScrapeConfirmationCandidate>[
              candidate(VideoMetadataProviderKind.anidb, '11'),
              candidate(VideoMetadataProviderKind.tmdb, '12'),
            ],
          ),
        );
    if (selected != null) await claim(unit, selected.lookup);
    return SourceScrapeReport(
      sourceIds: <int>[source.id],
      totalWorks: 1,
      succeededWorks: selected == null ? 0 : 1,
      pendingConfirmations: selected == null ? 1 : 0,
    );
  }

  @override
  Future<List<VideoSourceScrapeConfirmationCandidate>> searchManualCandidates({
    SourceLibraryRow? source,
    required String workTitle,
    String? workStableKey,
    required String query,
    VideoMetadataProviderKind? provider,
    VideoMetadataMediaKind? mediaKind,
  }) async {
    final List<String> parts = query.split(':');
    return <VideoSourceScrapeConfirmationCandidate>[
      candidate(
        VideoMetadataProviderKind.values.byName(parts.first),
        parts.last,
      ),
    ];
  }

  @override
  Future<VideoMetadataWork?> fetchWorkForLookup(VideoMetadataLookup lookup) =>
      throw UnimplementedError();

  @override
  Future<SourceScrapeReport> rescrapeWorkWithLookup({
    required SourceLibraryRow source,
    required String workTitle,
    String? workStableKey,
    required VideoMetadataLookup lookup,
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
  }) async {
    await claim(workStableKey!, lookup);
    return SourceScrapeReport(
      sourceIds: <int>[source.id],
      totalWorks: 1,
      succeededWorks: 1,
    );
  }
}

/// 认领会碰的全部表（整表，不按单元筛：撤销不该误伤单元外的行）。
const List<String> _kTables = <String>[
  'video_metadata_works',
  'video_metadata_seasons',
  'video_metadata_episodes',
  'video_metadata_provider_identities',
  'video_metadata_raw_snapshots',
  'video_metadata_work_terms',
  'video_metadata_credits',
  'video_metadata_images',
  'video_metadata_extras',
  'video_metadata_people',
  'video_metadata_characters',
  'video_metadata_terms',
  'video_scrape_meta',
  'collection_scrape_meta',
  'video_books',
  'media_collections',
  'media_collection_items',
  'media_images',
  'video_sidecar_artifacts',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late _TestAppModel model;
  late OpCatalog catalog;
  late OpInvoker invoker;
  late Directory root;
  late Directory media;
  late _ClaimRunner runner;
  late VideoSourceScrapeTaskController controller;
  late int sourceId;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi_claim_undo_');
    media = Directory(p.join(root.path, 'media'))..createSync();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    // 与生产连接同口径（`applyPragmas`）：外键开着，级联 / 约束都按真实行为走。
    await db.customStatement('PRAGMA foreign_keys = ON');
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    model = _TestAppModel(
      db,
      prefs,
      Directory(p.join(root.path, 'thumbs'))..createSync(),
    );
    runner = _ClaimRunner(db);
    controller = VideoSourceScrapeTaskController(runner);
    model.videoScrapeRuntime = _FakeRuntime(controller);
    final OpContext context = OpContext(ref: _Ref(model));
    catalog = buildAppOpCatalog(context, buildDomainOpRoutes(context));
    invoker = OpInvoker(catalog);
    sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Local',
        mediaKind: 'video',
        rootPath: media.path,
        createdAt: 1,
      ),
    );
  });

  tearDown(() async {
    controller.dispose();
    await db.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<OpInvocation> run(String id, Map<String, Object?> args) =>
      invoker.invoke(id, args, caller: OpCaller.model, captureUndo: true);

  Future<OpUndoOutcome> undo(OpInvocation invocation) {
    final Map<String, Object?> payload =
        jsonDecode(jsonEncode(invocation.undo!.payload))
            as Map<String, Object?>;
    return catalog[invocation.op.id]!.undo!.revert(payload);
  }

  /// 全部相关表 + 媒体目录文件内容（作品行的 `updated_at` 撤销时会盖成现在，单独比）。
  Future<Map<String, Object?>> state() async => <String, Object?>{
    for (final String table in _kTables)
      table: <Object?>[
        for (final QueryRow row
            in await db
                .customSelect('SELECT * FROM $table ORDER BY rowid')
                .get())
          <String, Object?>{
            for (final MapEntry<String, Object?> e in row.data.entries)
              if (!(table == 'video_metadata_works' && e.key == 'updated_at'))
                e.key: e.value,
          },
      ],
    'files': <String, String>{
      for (final FileSystemEntity f
          in media.listSync()..sort(
            (FileSystemEntity a, FileSystemEntity b) =>
                a.path.compareTo(b.path),
          ))
        if (f is File) p.basename(f.path): f.readAsStringSync(),
    },
  };

  Future<void> seedVideo(String uid) async {
    final File file = File(p.join(media.path, '$uid.mkv'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: Value<String>(uid),
        title: Value<String>(uid),
        videoPath: Value<String>(file.path),
        sourceId: Value<int?>(sourceId),
      ),
    );
  }

  Future<int> seedShow() async {
    await seedVideo('show-e1');
    await seedVideo('show-e2');
    final int id = await db.createMediaCollection('Show');
    await db.addToCollection(id, MediaKind.video, 'show-e1');
    await db.addToCollection(id, MediaKind.video, 'show-e2');
    return id;
  }

  Future<List<String>> primaries() async => <String>[
    for (final QueryRow row
        in await db
            .customSelect(
              'SELECT provider, external_id FROM '
              'video_metadata_provider_identities WHERE is_primary = 1 '
              'AND work_id IS NOT NULL ORDER BY provider',
            )
            .get())
      '${row.data['provider']}:${row.data['external_id']}',
  ];

  /// 起一个交互批次，停在 [unit] 的待确认上。
  Future<Future<SourceScrapeReport>> pauseOn(String unit) async {
    runner.pendingUnit = unit;
    final Future<SourceScrapeReport> task = controller.scrapeSource(
      (await db.getMediaSourceById(sourceId))!,
      interactive: true,
    );
    final VideoSourceScrapeConfirmation? pending =
        await waitForCtlVideoConfirmation(
          controller,
          const Duration(seconds: 5),
        );
    expect(pending?.workStableKey, unit);
    return task;
  }

  group('video.work.identify', () {
    test('认领前不在库里有身份（在待确认）→ 认领 → 撤销：逐项回到认领前、退回待确认', () async {
      await seedVideo('movie');
      final Map<String, Object?> before = await state();

      final OpInvocation done = await run(
        'video.work.identify',
        <String, Object?>{
          'id': 'book:movie',
          'provider': 'tmdb',
          'externalId': '42',
          'type': 'movie',
        },
      );
      expect((done.result! as Map<String, Object?>)['ok'], isTrue);
      expect(await primaries(), <String>['tmdb:42']);
      expect(await state(), isNot(before));
      expect(File(p.join(media.path, 'claim_42.nfo')).existsSync(), isTrue);

      expect((await undo(done)).status, OpUndoStatus.done);
      expect(await state(), before);
      expect(
        await db.getVideoMetadataWorkByBook('movie'),
        isNull,
        reason: '没有作品行 = 回到待确认队列',
      );
    });

    test('认领前已有身份（不在待确认）→ 改认 → 撤销：旧身份、旧资料、被覆盖的海报都回来，'
        '作品行盖新时间戳供互联客户端增量拉取', () async {
      await seedVideo('movie');
      await runner.claim(
        'book:movie',
        _ClaimRunner.candidate(VideoMetadataProviderKind.anidb, '7').lookup,
      );
      final Map<String, Object?> before = await state();
      final int beforeStamp = (await db.getVideoMetadataWorkByBook(
        'movie',
      ))!.updatedAt;

      final OpInvocation done = await run(
        'video.work.identify',
        <String, Object?>{
          'id': 'book:movie',
          'provider': 'mal',
          'externalId': '9',
        },
      );
      expect(await primaries(), <String>['mal:9']);
      expect(
        File(p.join(media.path, 'poster.jpg')).readAsStringSync(),
        'poster 9',
      );

      expect((await undo(done)).status, OpUndoStatus.done);
      expect(await state(), before);
      expect(await primaries(), <String>['anidb:7']);
      expect(
        (await db.getVideoMetadataWorkByBook('movie'))!.updatedAt,
        greaterThanOrEqualTo(beforeStamp),
      );
    });

    test('认领后用户手动改了资料（字段锁）→ 撤销报 superseded，不覆盖', () async {
      await seedVideo('movie');
      final OpInvocation done = await run(
        'video.work.identify',
        <String, Object?>{
          'id': 'book:movie',
          'provider': 'tmdb',
          'externalId': '42',
          'type': 'movie',
        },
      );
      final VideoMetadataWorkRow work = (await db.getVideoMetadataWorkByBook(
        'movie',
      ))!;
      await db.setVideoMetadataWorkLockedFields(work.id, 'title');
      final Map<String, Object?> edited = await state();

      expect((await undo(done)).status, OpUndoStatus.superseded);
      expect(await state(), edited);
    });

    test('认领后又被改认成别的身份 → superseded，不动', () async {
      await seedVideo('movie');
      final OpInvocation done = await run(
        'video.work.identify',
        <String, Object?>{
          'id': 'book:movie',
          'provider': 'tmdb',
          'externalId': '42',
          'type': 'movie',
        },
      );
      await runner.claim(
        'book:movie',
        _ClaimRunner.candidate(VideoMetadataProviderKind.anidb, '5').lookup,
      );
      final Map<String, Object?> edited = await state();

      expect((await undo(done)).status, OpUndoStatus.superseded);
      expect(await state(), edited);
    });
  });

  group('video.scrape.confirm', () {
    test('pick：合集作品选第 2 个候选 → 撤销逐项回到认领前、合集退回待确认', () async {
      final int show = await seedShow();
      final Map<String, Object?> before = await state();
      final Future<SourceScrapeReport> task = await pauseOn('collection:$show');

      final OpInvocation done = await run(
        'video.scrape.confirm',
        <String, Object?>{'action': 'pick', 'index': 2},
      );
      expect(
        (done.result! as Map<String, Object?>)['workId'],
        'collection:$show',
      );
      await task;
      expect(await primaries(), <String>['tmdb:12']);

      expect((await undo(done)).status, OpUndoStatus.done);
      expect(await state(), before);
      expect(await db.getVideoMetadataWorkByCollection(show), isNull);
    });

    test('identity：手动指定身份 → 撤销逐项回到认领前', () async {
      final int show = await seedShow();
      final Map<String, Object?> before = await state();
      final Future<SourceScrapeReport> task = await pauseOn('collection:$show');

      final OpInvocation done = await run(
        'video.scrape.confirm',
        <String, Object?>{
          'action': 'identity',
          'provider': 'anidb',
          'externalId': '777',
        },
      );
      await task;
      expect(await primaries(), <String>['anidb:777']);

      expect((await undo(done)).status, OpUndoStatus.done);
      expect(await state(), before);
    });

    test('skip：什么也没写，撤销即完成、状态不变', () async {
      final int show = await seedShow();
      final Map<String, Object?> before = await state();
      final Future<SourceScrapeReport> task = await pauseOn('collection:$show');

      final OpInvocation done = await run(
        'video.scrape.confirm',
        <String, Object?>{'action': 'skip'},
      );
      await task;
      expect(await state(), before);
      expect((await undo(done)).status, OpUndoStatus.done);
      expect(await state(), before);
    });

    test('批次还在跑时撤销 → failed，状态不变', () async {
      final int show = await seedShow();
      final Future<SourceScrapeReport> first = await pauseOn(
        'collection:$show',
      );
      final OpInvocation done = await run(
        'video.scrape.confirm',
        <String, Object?>{'action': 'pick', 'index': 1},
      );
      await first;
      // 再起一个批次停在待确认：控制器忙。
      await seedVideo('other');
      final Future<SourceScrapeReport> second = await pauseOn('book:other');
      final Map<String, Object?> busy = await state();

      expect((await undo(done)).status, OpUndoStatus.failed);
      expect(await state(), busy);
      controller.skipPendingConfirmation();
      await second;
      expect((await undo(done)).status, OpUndoStatus.done);
    });
  });
}
