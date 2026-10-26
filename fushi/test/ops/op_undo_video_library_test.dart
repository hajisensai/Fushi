import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/subtitle/video_subtitle_backfill.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/op_catalog_assembly.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';
import 'package:fushi/src/reader/reader_session_remote.dart';

import '../helpers/test_platform_services.dart';

/// 视频与书库域可撤销操作的往返测试（spec §11）：每种撤销形态「执行 → 撤销 →
/// 状态与执行前一致」，以及「执行后手动改过 → 撤销报 superseded、不覆盖」。
/// 全部经 `OpInvoker(buildAppOpCatalog(...))` 以模型身份调用，撤销载荷先过一遍
/// JSON（与持久化进 `ai_agent_actions` 后再撤销同一形态）。

class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._prefs) : super(testPlatformServices());

  final FushiDatabase _db;
  final PreferencesRepository _prefs;
  VideoSubtitleBackfillService? backfill;

  @override
  FushiDatabase get database => _db;

  @override
  PreferencesRepository get prefsRepo => _prefs;

  @override
  bool get isMigrationReadonly => false;

  @override
  VideoSubtitleBackfillService? get videoSubtitleBackfillService => backfill;

  @override
  String? seriesSubtitleLanguage(String seriesKey) => null;
}

/// 路由只用 `ref.read(appProvider)` 与刷新书架的 `invalidate`。
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

/// 可编排的阅读页：跳转真改快照。
class _FakeReader implements ReaderSessionRemote {
  _FakeReader(this.snap);

  ReaderSessionSnapshot snap;

  ReaderSessionSnapshot _with({int? chapter, double? progress}) =>
      ReaderSessionSnapshot(
        kind: snap.kind,
        bookKey: snap.bookKey,
        title: snap.title,
        chapterIndex: chapter ?? snap.chapterIndex,
        chapterCount: snap.chapterCount,
        chapterProgress: progress ?? snap.chapterProgress,
        currentChars: snap.currentChars,
        totalChars: snap.totalChars,
        contentReady: true,
      );

  @override
  ReaderSessionSnapshot? snapshot() => snap;

  @override
  Future<void> turnPage({required bool forward}) async {
    snap = _with(progress: (snap.chapterProgress ?? 0) + (forward ? .1 : -.1));
  }

  @override
  Future<bool> goToChapter(int chapterIndex, {double progress = 0}) async {
    snap = _with(chapter: chapterIndex, progress: progress);
    return true;
  }

  @override
  Future<bool> goToBookPercent(double percent) async => false;

  @override
  Future<bool> goToPage(int pageIndex) async => false;
}

/// 可编排的视频页遥控面：音量 / 音轨 / 主副字幕都是真状态。
class _FakePlayer implements VideoPlaybackRemote, VideoPlayerRemoteControl {
  double volume = 40;
  String audio = 'a1';
  String? primary = '/v/movie.ja.srt';
  String? secondary;

  static const List<String> _subs = <String>[
    '/v/movie.ja.srt',
    '/v/movie.en.srt',
  ];

  @override
  String get activeBookUid => 'video/movie';

  @override
  VideoPlaybackSnapshot? snapshot() => VideoPlaybackSnapshot(
    title: 'Movie',
    bookUid: activeBookUid,
    positionMs: 0,
    durationMs: 1000,
    playing: false,
    speed: 1,
    cue: null,
    volume: volume,
    audioTrackId: audio,
    subtitleSource: primary,
    secondarySubtitleSource: secondary,
  );

  @override
  Future<double> setVolume(double value) async => volume = value;

  @override
  Future<double> toggleMute() async => volume = volume == 0 ? 40 : 0;

  @override
  List<VideoRemoteAudioTrack> audioTracks() => <VideoRemoteAudioTrack>[
    for (final String id in <String>['a1', 'a2'])
      VideoRemoteAudioTrack(id: id, label: id, selected: id == audio),
  ];

  @override
  Future<void> selectAudioTrack(String id) async => audio = id;

  @override
  Future<VideoRemoteSubtitleState> subtitleState() async =>
      VideoRemoteSubtitleState(
        tracks: <VideoRemoteSubtitleTrack>[
          for (final String s in _subs)
            VideoRemoteSubtitleTrack(
              source: s,
              label: p.basename(s),
              kind: VideoRemoteSubtitleKind.external,
              primary: s == primary,
              secondary: s == secondary,
              ocrAvailable: false,
            ),
        ],
        primarySource: primary,
        secondarySource: secondary,
        remote: false,
        asrAvailable: false,
        alignAvailable: false,
      );

  @override
  Future<void> selectSubtitle(String source, {required bool secondary}) async {
    if (secondary) {
      this.secondary = source;
    } else {
      primary = source;
    }
  }

  @override
  Future<void> subtitleOff({required bool secondary}) async {
    if (secondary) {
      this.secondary = null;
    } else {
      primary = null;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试不该用到 ${invocation.memberName}');
}

class _Candidate extends VideoSubtitleCandidate {
  _Candidate()
    : super(
        providerId: 'fake',
        remoteId: '1',
        fileName: 'movie.ja.srt',
        language: 'ja',
        providerPriority: 0,
      );
}

class _FakeSubtitleProvider implements VideoSubtitleProvider {
  @override
  bool get allowsFreeProbeDownload => false;

  @override
  String get id => 'fake';

  @override
  int get priority => 0;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async => ProviderBatchResult<VideoSubtitleCandidate>.success(
    <VideoSubtitleCandidate>[_Candidate()],
  );

  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async => VideoSubtitleDownload(
    bytes: Uint8List.fromList(
      utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n'),
    ),
    fileName: 'movie.ja.srt',
    language: 'ja',
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试不该用到 ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late _TestAppModel model;
  late OpCatalog catalog;
  late OpInvoker invoker;
  late Directory work;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    model = _TestAppModel(db, prefs);
    final OpContext context = OpContext(ref: _Ref(model));
    catalog = buildAppOpCatalog(context, buildDomainOpRoutes(context));
    invoker = OpInvoker(catalog);
    work = await Directory.systemTemp.createTemp('fushi_op_undo_');
  });

  tearDown(() async {
    await db.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  /// 以模型身份执行（可逆操作的表态参数由运行时直接注入，与 AI 页同口径）。
  Future<OpInvocation> run(String id, Map<String, Object?> args) {
    final FushiOp op = catalog[id]!;
    return invoker.invoke(
      id,
      args,
      caller: OpCaller.model,
      captureUndo: true,
      grantedGates: <String>{
        for (final OpParam g in op.spec.gateParams) g.name,
      },
    );
  }

  /// 撤销（载荷先 JSON 往返，模拟持久化后再撤销）。
  Future<OpUndoStatus> undo(OpInvocation invocation) async {
    final Map<String, Object?> payload =
        jsonDecode(jsonEncode(invocation.undo!.payload))
            as Map<String, Object?>;
    return (await catalog[invocation.op.id]!.undo!.revert(payload)).status;
  }

  /// 直接调路由（模拟用户在别处手动改动）。
  Future<Object?> call(
    String method,
    String pattern, {
    Map<String, String> params = const <String, String>{},
    Map<String, Object?> body = const <String, Object?>{},
  }) {
    final FushiOp op = catalog.ops.firstWhere(
      (FushiOp o) => o.route.method == method && o.route.pattern == pattern,
    );
    String path = pattern;
    params.forEach((String k, String v) => path = path.replaceAll(':$k', v));
    return op.route.handler(
      CtlCall(method: method, path: path, params: params, body: body),
    );
  }

  Future<void> seedVideo(String uid, {String? title}) async {
    final File file = File(p.join(work.path, '${uid.split('/').last}.mkv'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: uid,
        title: title ?? uid,
        videoPath: file.path,
      ),
    );
  }

  Future<String> collectionName(int id) async =>
      (await db.getMediaCollectionById(id))!.name;

  Future<List<String>> memberKeys(int id) async => <String>[
    for (final MediaCollectionItemRow r in await db.getCollectionItems(id))
      r.entryKey,
  ];

  group('合集', () {
    test('新建 → 撤销删掉；之后加了成员 → superseded、合集保留', () async {
      final OpInvocation created = await run(
        'library.collection.create',
        <String, Object?>{'name': 'AI 合集'},
      );
      final int id = (created.result! as Map<String, Object?>)['id']! as int;
      expect(await db.getMediaCollectionById(id), isNotNull);
      expect(await undo(created), OpUndoStatus.done);
      expect(await db.getMediaCollectionById(id), isNull);

      await seedVideo('video/a');
      final OpInvocation again = await run(
        'library.collection.create',
        <String, Object?>{'name': 'AI 合集 2'},
      );
      final int id2 = (again.result! as Map<String, Object?>)['id']! as int;
      await call(
        'POST',
        '/api/admin/library/collections/:id/members',
        params: <String, String>{'id': '$id2'},
        body: <String, Object?>{
          'keys': <String>['video:video/a'],
        },
      );
      expect(await undo(again), OpUndoStatus.superseded);
      expect(await db.getMediaCollectionById(id2), isNotNull);
    });

    test('改名 → 撤销写回；手动又改过 → superseded、不覆盖', () async {
      final int id = await db.createMediaCollection('原名');
      final OpInvocation renamed = await run(
        'library.collection.rename',
        <String, Object?>{'id': '$id', 'name': 'AI 名'},
      );
      expect(await collectionName(id), 'AI 名');
      expect(await undo(renamed), OpUndoStatus.done);
      expect(await collectionName(id), '原名');

      final OpInvocation again = await run(
        'library.collection.rename',
        <String, Object?>{'id': '$id', 'name': 'AI 名'},
      );
      await db.renameMediaCollection(id, '用户名');
      expect(await undo(again), OpUndoStatus.superseded);
      expect(await collectionName(id), '用户名');
    });

    test('加成员 / 移成员 → 撤销反向（移成员撤销连手动顺序一起还原）', () async {
      for (final String uid in <String>['video/a', 'video/b', 'video/c']) {
        await seedVideo(uid);
      }
      final int id = await db.createMediaCollection('季');
      await db.addToCollection(id, MediaKind.video, 'video/a');
      await db.addToCollection(id, MediaKind.video, 'video/b');
      await db.addToCollection(id, MediaKind.video, 'video/c');
      await call(
        'PUT',
        '/api/admin/library/collections/:id/order',
        params: <String, String>{'id': '$id'},
        body: <String, Object?>{
          'keys': <String>['video:video/c', 'video:video/a', 'video:video/b'],
        },
      );
      final List<String> before = await memberKeys(id);
      expect(before, <String>['video/c', 'video/a', 'video/b']);

      final OpInvocation removed = await run(
        'library.collection.remove-members',
        <String, Object?>{
          'id': '$id',
          'keys': <String>['video:video/c'],
        },
      );
      expect(await memberKeys(id), <String>['video/a', 'video/b']);
      expect(await undo(removed), OpUndoStatus.done);
      expect(await memberKeys(id), before);

      await seedVideo('video/d');
      final OpInvocation added = await run(
        'library.collection.add',
        <String, Object?>{
          'id': '$id',
          'keys': <String>['video:video/d'],
        },
      );
      expect(await memberKeys(id), contains('video/d'));
      expect(await undo(added), OpUndoStatus.done);
      expect(await memberKeys(id), before);
    });

    test('手动定序 → 撤销还原旧顺序；之后又被重排 → superseded', () async {
      final int id = await db.createMediaCollection('季');
      for (final String uid in <String>['video/a', 'video/b', 'video/c']) {
        await seedVideo(uid);
        await db.addToCollection(id, MediaKind.video, uid);
      }
      final List<String> before = await memberKeys(id);
      final OpInvocation ordered = await run(
        'library.collection.order',
        <String, Object?>{
          'id': '$id',
          'keys': <String>['video:video/c', 'video:video/b', 'video:video/a'],
        },
      );
      expect(await memberKeys(id), <String>['video/c', 'video/b', 'video/a']);
      expect(await undo(ordered), OpUndoStatus.done);
      expect(await memberKeys(id), before);

      final OpInvocation again = await run(
        'library.collection.order',
        <String, Object?>{
          'id': '$id',
          'keys': <String>['video:video/c'],
        },
      );
      await call(
        'PUT',
        '/api/admin/library/collections/:id/order',
        params: <String, String>{'id': '$id'},
        body: <String, Object?>{
          'keys': <String>['video:video/b', 'video:video/a', 'video:video/c'],
        },
      );
      final List<String> manual = await memberKeys(id);
      expect(await undo(again), OpUndoStatus.superseded);
      expect(await memberKeys(id), manual);
    });
  });

  group('标签', () {
    test('打标签（顺手新建）→ 撤销摘掉并删掉新建的标签；摘标签 → 撤销打回', () async {
      await seedVideo('video/a');
      final int keep = await db.createTag('已有', 0xFF000000);
      final OpInvocation tagged = await run(
        'library.item.tag',
        <String, Object?>{
          'key': 'video:video/a',
          'tags': <String>['已有', '新标签'],
          'create': true,
        },
      );
      final Object? tagsNow = await call(
        'GET',
        '/api/admin/library/items/:key/tags',
        params: <String, String>{'key': 'video:video/a'},
      );
      expect(
        ((tagsNow! as Map<String, Object?>)['tags']! as List<Object?>).length,
        2,
      );
      expect(await undo(tagged), OpUndoStatus.done);
      final List<BookTagRow> all = await db.getAllTags();
      expect(all.map((BookTagRow t) => t.id), <int>[keep]);
      final Object? tagsAfter = await call(
        'GET',
        '/api/admin/library/items/:key/tags',
        params: <String, String>{'key': 'video:video/a'},
      );
      expect((tagsAfter! as Map<String, Object?>)['tags'], isEmpty);

      await call(
        'POST',
        '/api/admin/library/items/:key/tags',
        params: <String, String>{'key': 'video:video/a'},
        body: <String, Object?>{
          'tags': <String>['已有'],
        },
      );
      final OpInvocation untagged = await run(
        'library.item.untag',
        <String, Object?>{
          'key': 'video:video/a',
          'tags': <String>['已有'],
        },
      );
      expect(await undo(untagged), OpUndoStatus.done);
      final Object? restored = await call(
        'GET',
        '/api/admin/library/items/:key/tags',
        params: <String, String>{'key': 'video:video/a'},
      );
      expect(
        ((restored! as Map<String, Object?>)['tags']! as List<Object?>).length,
        1,
      );
    });

    test('改标签 → 撤销写回名字与颜色；之后手动改名 → superseded', () async {
      final int id = await db.createTag('旧', 0xFF112233);
      final OpInvocation edited = await run(
        'library.tag.edit',
        <String, Object?>{'id': '$id', 'name': '新', 'color': '#445566'},
      );
      expect(await undo(edited), OpUndoStatus.done);
      BookTagRow tag = (await db.getAllTags()).single;
      expect(tag.name, '旧');
      expect(tag.colorValue, 0xFF112233);

      final OpInvocation again = await run(
        'library.tag.edit',
        <String, Object?>{'id': '$id', 'name': '新'},
      );
      await db.updateTag(id, name: '用户改的');
      expect(await undo(again), OpUndoStatus.superseded);
      tag = (await db.getAllTags()).single;
      expect(tag.name, '用户改的');
    });

    test('新建标签 → 撤销删掉；被用上了 → superseded', () async {
      await seedVideo('video/a');
      final OpInvocation created = await run(
        'library.tag.create',
        <String, Object?>{'name': '临时'},
      );
      expect(await undo(created), OpUndoStatus.done);
      expect(await db.getAllTags(), isEmpty);

      final OpInvocation again = await run(
        'library.tag.create',
        <String, Object?>{'name': '临时'},
      );
      await call(
        'POST',
        '/api/admin/library/items/:key/tags',
        params: <String, String>{'key': 'video:video/a'},
        body: <String, Object?>{
          'tags': <String>['临时'],
        },
      );
      expect(await undo(again), OpUndoStatus.superseded);
      expect((await db.getAllTags()).single.name, '临时');
    });
  });

  group('条目与来源', () {
    test('视频改名 → 撤销写回；手动又改 → superseded', () async {
      await seedVideo('video/a', title: '原标题');
      Future<String> title() async =>
          (await db.getVideoBookByBookUid('video/a'))!.title;
      final OpInvocation renamed = await run(
        'library.item.rename',
        <String, Object?>{'key': 'video:video/a', 'title': 'AI 标题'},
      );
      expect(await title(), 'AI 标题');
      expect(await undo(renamed), OpUndoStatus.done);
      expect(await title(), '原标题');

      final OpInvocation again = await run(
        'library.item.rename',
        <String, Object?>{'key': 'video:video/a', 'title': 'AI 标题'},
      );
      await call(
        'PUT',
        '/api/admin/library/items/:key/title',
        params: <String, String>{'key': 'video:video/a'},
        body: <String, Object?>{'title': '用户标题'},
      );
      expect(await undo(again), OpUndoStatus.superseded);
      expect(await title(), '用户标题');
    });

    test('加来源 → 撤销移除来源；来源改名 → 撤销写回', () async {
      final Directory folder = Directory(p.join(work.path, 'shows'))
        ..createSync();
      final OpInvocation added = await run(
        'library.source.add',
        <String, Object?>{'path': folder.path, 'kind': 'video'},
      );
      final int id = (added.result! as Map<String, Object?>)['id']! as int;
      expect(await db.getMediaSourceById(id), isNotNull);

      final OpInvocation renamed = await run(
        'library.source.rename',
        <String, Object?>{'id': '$id', 'label': 'AI 来源'},
      );
      expect((await db.getMediaSourceById(id))!.label, 'AI 来源');
      expect(await undo(renamed), OpUndoStatus.done);
      expect((await db.getMediaSourceById(id))!.label, isNot('AI 来源'));

      expect(await undo(added), OpUndoStatus.done);
      expect(await db.getMediaSourceById(id), isNull);
      expect(await undo(added), OpUndoStatus.superseded);
    });
  });

  group('阅读器', () {
    late _FakeReader reader;

    setUp(() {
      reader = _FakeReader(
        const ReaderSessionSnapshot(
          kind: ReaderSessionKind.epub,
          bookKey: '猫',
          title: '猫',
          chapterIndex: 2,
          chapterCount: 10,
          chapterProgress: 0.25,
          currentChars: 250,
          totalChars: 1000,
          contentReady: true,
        ),
      );
      readerSessionRemotes.register(reader);
    });

    tearDown(() => readerSessionRemotes.unregister(reader));

    test('跳章 → 撤销跳回原位置；之后用户又翻过 → superseded、不跳', () async {
      final OpInvocation jumped = await run(
        'library.reader.goto',
        <String, Object?>{'chapter': 7, 'progress': 50},
      );
      expect(reader.snap.chapterIndex, 6);
      expect(await undo(jumped), OpUndoStatus.done);
      expect(reader.snap.chapterIndex, 2);
      expect(reader.snap.chapterProgress, closeTo(0.25, 1e-9));

      final OpInvocation again = await run(
        'library.reader.goto',
        <String, Object?>{'chapter': 7},
      );
      await reader.turnPage(forward: true);
      final int chapter = reader.snap.chapterIndex!;
      final double progress = reader.snap.chapterProgress!;
      expect(await undo(again), OpUndoStatus.superseded);
      expect(reader.snap.chapterIndex, chapter);
      expect(reader.snap.chapterProgress, progress);
    });
  });

  group('视频播放页', () {
    late _FakePlayer player;

    setUp(() {
      player = _FakePlayer();
      videoPlaybackRemotes.register(player);
    });

    tearDown(() => videoPlaybackRemotes.unregister(player));

    test('音量 → 撤销写回；之后手动调过 → superseded', () async {
      final OpInvocation set = await run(
        'video.player.volume',
        <String, Object?>{'volume': 90},
      );
      expect(player.volume, 90);
      expect(await undo(set), OpUndoStatus.done);
      expect(player.volume, 40);

      final OpInvocation again = await run(
        'video.player.volume',
        <String, Object?>{'volume': 90},
      );
      player.volume = 10;
      expect(await undo(again), OpUndoStatus.superseded);
      expect(player.volume, 10);
    });

    test('切音轨、切字幕（含关掉）→ 撤销写回原选择', () async {
      final OpInvocation audio = await run(
        'video.player.audio.select',
        <String, Object?>{'id': 'a2'},
      );
      expect(player.audio, 'a2');
      expect(await undo(audio), OpUndoStatus.done);
      expect(player.audio, 'a1');

      final OpInvocation sub = await run(
        'video.player.subtitle.select',
        <String, Object?>{'source': '2'},
      );
      expect(player.primary, '/v/movie.en.srt');
      expect(await undo(sub), OpUndoStatus.done);
      expect(player.primary, '/v/movie.ja.srt');

      final OpInvocation secondary = await run(
        'video.player.subtitle.select',
        <String, Object?>{'source': '2', 'secondary': true},
      );
      expect(player.secondary, '/v/movie.en.srt');
      expect(await undo(secondary), OpUndoStatus.done);
      expect(player.secondary, isNull, reason: '原本关着的副字幕撤销后仍关着');
      expect(player.primary, '/v/movie.ja.srt');
    });
  });

  group('在线字幕下载', () {
    late File video;

    setUp(() async {
      video = File(p.join(work.path, 'movie.mkv'))
        ..writeAsBytesSync(<int>[1, 2, 3]);
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/movie',
          title: 'Movie',
          videoPath: video.path,
        ),
      );
      final int workId = await db.upsertVideoMetadataWork(
        VideoMetadataWorksCompanion.insert(
          bookUid: const Value<String?>('video/movie'),
          mediaType: 'movie',
          title: 'リズと青い鳥',
          year: const Value<int?>(2018),
          runtimeMinutes: const Value<int?>(90),
          updatedAt: 1,
        ),
      );
      await db.replaceVideoMetadataProviderIdentities(
        workId: workId,
        identities: <VideoMetadataProviderIdentitiesCompanion>[
          VideoMetadataProviderIdentitiesCompanion.insert(
            identityKey: 'work:video/movie:tmdb',
            workId: Value<int?>(workId),
            provider: 'tmdb',
            externalId: '12345',
            isPrimary: const Value<bool>(true),
            updatedAt: 1,
          ),
        ],
      );
      model.backfill = VideoSubtitleBackfillService(
        registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[
          _FakeSubtitleProvider(),
        ]),
      );
    });

    Future<String> searchOne() async {
      final OpInvocation found = await run(
        'video.subtitle.search',
        <String, Object?>{'bookUid': 'video/movie'},
      );
      final List<Object?> candidates =
          (found.result! as Map<String, Object?>)['candidates']!
              as List<Object?>;
      return (candidates.first! as Map<String, Object?>)['id']! as String;
    }

    String sidecar() => p.join(work.path, 'movie.ja.srt');

    test('点名下载 → 撤销删掉刚下的那份字幕', () async {
      final OpInvocation got = await run(
        'video.subtitle.download',
        <String, Object?>{'id': await searchOne()},
      );
      expect((got.result! as Map<String, Object?>)['outcome'], 'installed');
      expect(File(sidecar()).existsSync(), isTrue);
      expect(await undo(got), OpUndoStatus.done);
      expect(File(sidecar()).existsSync(), isFalse);
    });

    test('已有同名字幕 → 路由不覆盖、撤销也不删它', () async {
      File(sidecar()).writeAsStringSync('用户自己的字幕');
      final OpInvocation got = await run(
        'video.subtitle.download',
        <String, Object?>{'id': await searchOne()},
      );
      expect(
        (got.result! as Map<String, Object?>)['outcome'],
        'alreadyHasSubtitle',
      );
      expect(await undo(got), OpUndoStatus.done);
      expect(File(sidecar()).readAsStringSync(), '用户自己的字幕');
    });

    test('下载后用户改过字幕文件 → 撤销报 superseded、不删', () async {
      final OpInvocation got = await run(
        'video.subtitle.download',
        <String, Object?>{'id': await searchOne()},
      );
      File(sidecar()).writeAsStringSync('用户改过的内容，长度也不一样了');
      expect(await undo(got), OpUndoStatus.superseded);
      expect(File(sidecar()).existsSync(), isTrue);
    });
  });
}
