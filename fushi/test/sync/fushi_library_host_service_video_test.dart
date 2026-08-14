import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/ffmpeg_backend.dart';
import 'package:fushi/src/sync/app_model_library_host_service.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/sync_asset_package_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 最小 AppModelLibraryHostService 实例（不需要词典/书籍功能）。
AppModelLibraryHostService _makeService({
  required FushiDatabase db,
  required Directory tmp,
  String langCode = 'ja',
  Directory? uploadedVideoRoot,
  Future<String?> Function(
          {required String videoPath, required String bookUid})?
      extractVideoCover,
}) {
  final Directory dictRoot = Directory(p.join(tmp.path, 'dicts'))
    ..createSync(recursive: true);
  return AppModelLibraryHostService(
    db: db,
    dictionaryResourceRoot: dictRoot,
    packages: SyncAssetPackageService(db: db),
    refreshDictionaryCache: () async {},
    runExclusive: (Future<void> Function() body) => body(),
    videoSubtitleLangCode: langCode,
    uploadedVideoRoot: uploadedVideoRoot,
    extractVideoCover: extractVideoCover,
  );
}

void main() {
  late Directory tmp;
  late FushiDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hbk_video_svc_test');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    setFfmpegBackendForTesting(null);
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  // ── listVideos ────────────────────────────────────────────────────────────────

  group('listVideos', () {
    test('空库返回空列表', () async {
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final List<RemoteVideoInfo> list = await svc.listVideos();
      expect(list, isEmpty);
    });

    test('返回已插入的视频条目，字段正确', () async {
      // 建一个真实视频文件（内容任意）供 stat 拿大小
      final File videoFile = File(p.join(tmp.path, 'film.mp4'))
        ..writeAsBytesSync(List<int>.filled(1024, 0));

      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/film',
        title: 'Film Title',
        videoPath: videoFile.path,
      ));

      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final List<RemoteVideoInfo> list = await svc.listVideos();
      expect(list.length, 1);
      expect(list[0].id, 'video/film');
      expect(list[0].title, 'Film Title');
      expect(list[0].sizeBytes, 1024);
      expect(list[0].hasSubtitle, isFalse); // 无 sidecar
      expect(list[0].durationMs, isNull); // DB 无 duration 列
    });

    test('返回视频条目时标记已有本地封面可供对端展示', () async {
      final File videoFile = File(p.join(tmp.path, 'covered.mp4'))
        ..writeAsBytesSync(<int>[0]);
      final File coverFile = File(p.join(tmp.path, 'covered.png'))
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);

      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/covered',
        title: 'Covered Video',
        videoPath: videoFile.path,
        coverPath: Value<String?>(coverFile.path),
      ));

      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final List<RemoteVideoInfo> list = await svc.listVideos();

      expect(list.single.toJson()['hasCover'], isTrue);
    });

    test('视频文件不存在时 sizeBytes 为 null', () async {
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/ghost',
        title: 'Ghost',
        videoPath: p.join(tmp.path, 'nonexistent.mp4'),
      ));

      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final List<RemoteVideoInfo> list = await svc.listVideos();
      expect(list[0].sizeBytes, isNull);
    });

    test('有 sidecar 字幕时 hasSubtitle = true', () async {
      final String videoPath = p.join(tmp.path, 'show.mkv');
      File(videoPath).writeAsBytesSync(<int>[0]);
      // 创建 ja.srt sidecar
      File(p.join(tmp.path, 'show.ja.srt'))
          .writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nHello\n');

      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/show',
        title: 'Show',
        videoPath: videoPath,
      ));

      final AppModelLibraryHostService svc =
          _makeService(db: db, tmp: tmp, langCode: 'ja');
      final List<RemoteVideoInfo> list = await svc.listVideos();
      expect(list[0].hasSubtitle, isTrue);
    });

    test('sidecar 字幕文件名保留真实扩展名', () async {
      final String videoPath = p.join(tmp.path, 'show.mkv');
      File(videoPath).writeAsBytesSync(<int>[0]);
      File(p.join(tmp.path, 'show.ja.vtt')).writeAsStringSync(
        'WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHello\n',
      );

      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/show',
        title: 'Show',
        videoPath: videoPath,
      ));

      final AppModelLibraryHostService svc =
          _makeService(db: db, tmp: tmp, langCode: 'ja');
      final List<RemoteVideoInfo> list = await svc.listVideos();

      expect(list.single.hasSubtitle, isTrue);
      expect(list.single.subtitleFileName, 'show.ja.vtt');
      expect(list.single.toJson()['subtitleFileName'], 'show.ja.vtt');
    });

    test('BUG-814: listVideos 不做内嵌字幕 ffmpeg 探测（即便后端可返回轨也延迟到 /streamurl）',
        () async {
      // 注入一个「若被探测就会返回 3 轨」的 mock ffmpeg 后端——用来证明 listVideos
      // 根本没调用它（内嵌轨探测已延迟到播放时的 /streamurl 端点，BUG-814）。
      setFfmpegBackendForTesting(const _EmbeddedSubtitleProbeBackend());
      final String videoPath = p.join(tmp.path, 'embedded.mkv');
      File(videoPath).writeAsBytesSync(<int>[0, 1, 2, 3]);

      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/embedded',
        title: 'Embedded',
        videoPath: videoPath,
      ));

      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final List<RemoteVideoInfo> list = await svc.listVideos();

      // 列表端点是纯 DB/stat 读：内嵌轨恒空、hasSubtitle 只反映外挂 sidecar（此处无）。
      expect(list.single.embeddedSubtitleTracks, isEmpty,
          reason: 'listVideos 不再逐视频 spawn ffmpeg（避免大库互联视频列表超时变空）');
      expect(list.single.hasSubtitle, isFalse);
      expect(list.single.subtitleFileName, isNull);
    });

    test('BUG-996: listVideos 下发字幕时序偏移 delayMs（远端播放跟随桌面调轴）', () async {
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/delayed',
        title: 'Delayed',
        videoPath: '/tmp/delayed.mp4',
        delayMs: const Value(-1500),
      ));
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final List<RemoteVideoInfo> list = await svc.listVideos();
      expect(list.single.delayMs, -1500,
          reason: 'host 的 VideoBooks.delayMs 必须下发给远端');
      // toJson/fromJson 往返保真；delayMs==0 不写键的向后兼容。
      expect(RemoteVideoInfo.fromJson(list.single.toJson()).delayMs, -1500);
      const RemoteVideoInfo zero = RemoteVideoInfo(id: 'x', title: 'X');
      expect(zero.toJson().containsKey('delayMs'), isFalse);
      expect(RemoteVideoInfo.fromJson(zero.toJson()).delayMs, 0);
    });

    test('BUG-1620: 带戳 delay prefs 胜过旧 row.delayMs，清单带 delayUpdatedAtMs',
        () async {
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/delayed2',
        title: 'Delayed2',
        videoPath: '/tmp/delayed2.mp4',
        delayMs: const Value(-1500),
      ));
      // client 上报过带戳调轴（prefs 通道）→ 清单应下发 prefs 胜者而非旧行值。
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      await svc.putVideoDelay('video/delayed2', 2000, 1700000000000);
      final List<RemoteVideoInfo> list = await svc.listVideos();
      expect(list.single.delayMs, 2000, reason: '带戳 prefs 应胜过旧 row 值');
      expect(list.single.delayUpdatedAtMs, 1700000000000,
          reason: '清单必须带戳，client 才能做 LWW 决议');
      // json 向后兼容：无戳时不写 delayUpdatedAtMs 键。
      const RemoteVideoInfo zero = RemoteVideoInfo(id: 'x', title: 'X');
      expect(zero.toJson().containsKey('delayUpdatedAtMs'), isFalse);
      expect(RemoteVideoInfo.fromJson(zero.toJson()).delayUpdatedAtMs, 0);
    });

    test('toJson/fromJson 往返一致', () {
      const RemoteVideoInfo info = RemoteVideoInfo(
        id: 'video/test',
        title: 'Test',
        sizeBytes: 2048,
        hasSubtitle: true,
        subtitleFileName: 'test.ja.ass',
        embeddedSubtitleTracks: <RemoteVideoEmbeddedSubtitleTrack>[
          RemoteVideoEmbeddedSubtitleTrack(
            streamIndex: 0,
            codec: 'ass',
            language: 'jpn',
            isText: true,
          ),
        ],
        durationMs: null,
      );
      final Map<String, Object?> json = info.toJson();
      final RemoteVideoInfo restored = RemoteVideoInfo.fromJson(json);
      expect(restored.id, info.id);
      expect(restored.title, info.title);
      expect(restored.sizeBytes, info.sizeBytes);
      expect(restored.hasSubtitle, info.hasSubtitle);
      expect(restored.subtitleFileName, info.subtitleFileName);
      expect(restored.embeddedSubtitleTracks, hasLength(1));
      expect(restored.embeddedSubtitleTracks.single.codec, 'ass');
      expect(restored.durationMs, info.durationMs);
    });

    test('toJson 中 durationMs=null 不出现在 JSON', () {
      const RemoteVideoInfo info = RemoteVideoInfo(
        id: 'video/x',
        title: 'X',
      );
      final Map<String, Object?> json = info.toJson();
      expect(json.containsKey('durationMs'), isFalse);
    });
  });

  // TODO-885 remote episode list (four-layer wiring).
  // ── BUG-1620 字幕调轴跨设备同步（getVideoDelay / putVideoDelay）────────────────

  group('BUG-1620 video delay host sync', () {
    const String uid = 'video/delay-sync';

    Future<void> insertVideo({int delayMs = 0}) => db.upsertVideoBook(
          VideoBooksCompanion.insert(
            bookUid: uid,
            title: 'Delay Sync',
            videoPath: '/tmp/delay-sync.mp4',
            delayMs: Value(delayMs),
          ),
        );

    test('无带戳 prefs 时回退旧 row.delayMs（戳 0）；未知 id 返回 0/0', () async {
      await insertVideo(delayMs: -800);
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final ({int delayMs, int updatedAtMs}) d = await svc.getVideoDelay(uid);
      expect(d.delayMs, -800, reason: '旧数据（无 prefs）行为与此前直读 row 一致');
      expect(d.updatedAtMs, 0);
      final ({int delayMs, int updatedAtMs}) missing =
          await svc.getVideoDelay('video/none');
      expect(missing.delayMs, 0);
      expect(missing.updatedAtMs, 0);
    });

    test('putVideoDelay 落 prefs + 写穿 row；严格较新者胜', () async {
      await insertVideo();
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      await svc.putVideoDelay(uid, -1500, 1700000000000);
      ({int delayMs, int updatedAtMs}) d = await svc.getVideoDelay(uid);
      expect(d.delayMs, -1500);
      expect(d.updatedAtMs, 1700000000000);
      // 写穿行值：host 本机播放（读 row.delayMs）立即跟随。
      expect((await db.getVideoBookByBookUid(uid))!.delayMs, -1500);
      // 滞后设备旧戳不得回退。
      await svc.putVideoDelay(uid, 999, 1699999990000);
      d = await svc.getVideoDelay(uid);
      expect(d.delayMs, -1500, reason: '旧时间戳不应回退新调轴');
      expect((await db.getVideoBookByBookUid(uid))!.delayMs, -1500);
    });

    test('putVideoDelay 未知 id no-op（不写脏 prefs）', () async {
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      await svc.putVideoDelay('video/ghost', 1234, 1700000000000);
      expect(
          await db.getPrefTyped<int>(videoRemoteDelayPrefKey('video/ghost'), 0),
          0,
          reason: '存在性闸门：任意 id 上报不得写出孤儿 prefs');
      expect(
          await db.getPrefTyped<int>(
              videoRemoteDelayAtPrefKey('video/ghost'), 0),
          0);
    });

    test('putVideoDelay clamp ±600000；未来时间戳被上限截断', () async {
      await insertVideo();
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final int farFuture =
          DateTime.now().millisecondsSinceEpoch + 10 * 24 * 3600 * 1000;
      await svc.putVideoDelay(uid, -9999999, farFuture);
      final ({int delayMs, int updatedAtMs}) d = await svc.getVideoDelay(uid);
      expect(d.delayMs, -600000, reason: '越界调轴必须 clamp（±10 分钟）');
      expect(d.updatedAtMs,
          lessThan(DateTime.now().millisecondsSinceEpoch + 6 * 60 * 1000),
          reason: '未来戳必须截到 now+5min 内，否则 LWW 被永久锁死');
      // 截断后的戳仍然「较新」，正常设备随后的调轴还能覆盖。
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // 用比截断戳更新的 now+5min 边界再写一次，应可覆盖。
      final int newer = DateTime.now().millisecondsSinceEpoch + 5 * 60 * 1000;
      await svc.putVideoDelay(uid, 777, newer);
      expect((await svc.getVideoDelay(uid)).delayMs, 777,
          reason: '截断语义不得把正常设备永远锁在门外');
    });
  });

  group('TODO-885 remote episodes', () {
    test('playlistJson rows map to episodes (index+title, never host path)',
        () async {
      final Directory series = Directory(p.join(tmp.path, 'series'))
        ..createSync();
      final File ep0 = File(p.join(series.path, 'ep0.mp4'))
        ..writeAsBytesSync(<int>[0]);
      final File ep1 = File(p.join(series.path, 'ep1.mp4'))
        ..writeAsBytesSync(<int>[0]);
      final String playlistJson = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{
          'title': 'Episode 1',
          'path': ep0.path,
          'positionMs': 0
        },
        <String, dynamic>{
          'title': 'Episode 2',
          'path': ep1.path,
          'positionMs': 0
        },
      ]);

      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/series',
        title: 'My Series',
        videoPath: ep0.path,
        playlistJson: Value<String?>(playlistJson),
        currentEpisode: const Value<int>(1),
      ));

      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final List<RemoteVideoInfo> list = await svc.listVideos();
      expect(list.single.episodes, hasLength(2));
      expect(list.single.episodes[0].index, 0);
      expect(list.single.episodes[0].title, 'Episode 1');
      expect(list.single.episodes[1].index, 1);
      expect(list.single.episodes[1].title, 'Episode 2');
      expect(list.single.currentEpisode, 1,
          reason: 'currentEpisode picks the default start episode');

      final String dumped = jsonEncode(list.single.toJson());
      expect(dumped.contains(ep0.path), isFalse,
          reason: 'episode JSON must not leak host file path');
      expect(dumped.contains(ep1.path), isFalse);
      expect(dumped.contains(series.path), isFalse,
          reason: 'episode JSON must not leak host directory structure');
    });

    test('single video (no playlistJson) has empty episodes and omits the key',
        () async {
      final File f = File(p.join(tmp.path, 'single.mp4'))
        ..writeAsBytesSync(<int>[0]);
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/single',
        title: 'Single',
        videoPath: f.path,
      ));
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final List<RemoteVideoInfo> list = await svc.listVideos();
      expect(list.single.episodes, isEmpty);
      expect(list.single.toJson().containsKey('episodes'), isFalse,
          reason: 'single video stays backward compatible (no episodes key)');
    });

    test('episodes round-trip preserves index+title (only when length>1)', () {
      const RemoteVideoInfo info = RemoteVideoInfo(
        id: 'video/s',
        title: 'S',
        currentEpisode: 2,
        episodes: <RemoteVideoEpisode>[
          RemoteVideoEpisode(index: 0, title: 'A'),
          RemoteVideoEpisode(index: 1, title: 'B'),
          RemoteVideoEpisode(index: 2, title: 'C'),
        ],
      );
      final Map<String, Object?> json = info.toJson();
      expect(json['currentEpisode'], 2);
      final RemoteVideoInfo restored = RemoteVideoInfo.fromJson(json);
      expect(restored.episodes, hasLength(3));
      expect(restored.episodes[1].index, 1);
      expect(restored.episodes[1].title, 'B');
      expect(restored.currentEpisode, 2);
    });

    test('single-element episodes are not serialized (backward compat)', () {
      const RemoteVideoInfo info = RemoteVideoInfo(
        id: 'video/one',
        title: 'One',
        episodes: <RemoteVideoEpisode>[
          RemoteVideoEpisode(index: 0, title: 'A')
        ],
      );
      expect(info.toJson().containsKey('episodes'), isFalse);
    });
  });

  // TODO-885 per-episode DB-only resolution.
  group('TODO-885 per-episode DB-only resolution', () {
    Future<void> seedSeries() async {
      final Directory series = Directory(p.join(tmp.path, 'series2'))
        ..createSync();
      final File ep0 = File(p.join(series.path, 'ep0.mkv'))
        ..writeAsBytesSync(<int>[1]);
      final File ep1 = File(p.join(series.path, 'ep1.mkv'))
        ..writeAsBytesSync(<int>[2]);
      File(p.join(series.path, 'ep1.ja.srt')).writeAsStringSync('sub1');
      final String playlistJson = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{'title': 'E0', 'path': ep0.path, 'positionMs': 0},
        <String, dynamic>{'title': 'E1', 'path': ep1.path, 'positionMs': 0},
      ]);
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/series2',
        title: 'Series2',
        videoPath: ep0.path,
        playlistJson: Value<String?>(playlistJson),
      ));
    }

    test('resolveVideoFile(episodeIndex) looks up playlistJson[N].path',
        () async {
      await seedSeries();
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final File? f0 =
          await svc.resolveVideoFile('video/series2', episodeIndex: 0);
      final File? f1 =
          await svc.resolveVideoFile('video/series2', episodeIndex: 1);
      expect(f0, isNotNull);
      expect(f1, isNotNull);
      expect(p.basename(f0!.path), 'ep0.mkv');
      expect(p.basename(f1!.path), 'ep1.mkv');
    });

    test('out-of-range episodeIndex returns null (safe reject)', () async {
      await seedSeries();
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      expect(
          await svc.resolveVideoFile('video/series2', episodeIndex: 9), isNull);
      expect(await svc.resolveVideoFile('video/series2', episodeIndex: -1),
          isNull);
    });

    test('resolveVideoSubtitle(episodeIndex) per-episode sidecar', () async {
      await seedSeries();
      final AppModelLibraryHostService svc =
          _makeService(db: db, tmp: tmp, langCode: 'ja');
      final File? sub1 =
          await svc.resolveVideoSubtitle('video/series2', episodeIndex: 1);
      expect(sub1, isNotNull);
      expect(p.basename(sub1!.path), 'ep1.ja.srt');
      final File? sub0 =
          await svc.resolveVideoSubtitle('video/series2', episodeIndex: 0);
      expect(sub0, isNull);
    });

    test('episodeIndex=0 equals legacy single-video behavior (videoPath)',
        () async {
      final File f = File(p.join(tmp.path, 'plain.mp4'))
        ..writeAsBytesSync(<int>[0]);
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/plain',
        title: 'Plain',
        videoPath: f.path,
      ));
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final File? r =
          await svc.resolveVideoFile('video/plain', episodeIndex: 0);
      expect(r, isNotNull);
      expect(r!.path, f.path);
    });

    test('per-episode progress prefs keys are isolated by episode', () async {
      await seedSeries();
      await db.setPrefTyped<int>(
          videoRemotePositionEpisodePrefKey('video/series2', 1), 50000);
      await db.setPrefTyped<int>(
          videoRemotePositionEpisodeAtPrefKey('video/series2', 1), 9000);
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);

      final ({int positionMs, int updatedAtMs}) ep1 =
          await svc.getVideoPosition('video/series2', episodeIndex: 1);
      expect(ep1.positionMs, 50000);
      expect(ep1.updatedAtMs, 9000);
      final ({int positionMs, int updatedAtMs}) ep0 =
          await svc.getVideoPosition('video/series2', episodeIndex: 0);
      expect(ep0.positionMs, 0);
    });
  });

  // ── resolveVideoFile ──────────────────────────────────────────────────────────

  group('resolveVideoFile', () {
    test('已知 id + 文件存在 → 返回 File', () async {
      final File videoFile = File(p.join(tmp.path, 'clip.mp4'))
        ..writeAsBytesSync(<int>[1, 2, 3]);
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/clip',
        title: 'Clip',
        videoPath: videoFile.path,
      ));

      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final File? f = await svc.resolveVideoFile('video/clip');
      expect(f, isNotNull);
      expect(f!.path, videoFile.path);
    });

    test('未知 id → null', () async {
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final File? f = await svc.resolveVideoFile('video/does_not_exist');
      expect(f, isNull);
    });

    test('已知 id 但文件不存在 → null', () async {
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/vanished',
        title: 'Vanished',
        videoPath: p.join(tmp.path, 'vanished.mp4'), // 不创建文件
      ));

      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final File? f = await svc.resolveVideoFile('video/vanished');
      expect(f, isNull);
    });

    test('外部路径不能直接 resolve（必须先入库）', () async {
      // 文件确实存在，但 id 不在 DB → null（防路径穿越关键用例）
      final File sneaky = File(p.join(tmp.path, 'secret.mp4'))
        ..writeAsBytesSync(<int>[0xff]);

      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      // 传的是文件路径而非 bookUid，DB 中查不到 → null
      final File? f = await svc.resolveVideoFile(sneaky.path);
      expect(f, isNull);
    });
  });

  // ── resolveVideoSubtitle ──────────────────────────────────────────────────────

  group('resolveVideoSubtitle', () {
    test('有 sidecar → 返回字幕 File', () async {
      final String videoPath = p.join(tmp.path, 'ep01.mkv');
      File(videoPath).writeAsBytesSync(<int>[0]);
      final File subFile = File(p.join(tmp.path, 'ep01.ja.srt'))
        ..writeAsStringSync('sub');

      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/ep01',
        title: 'Ep01',
        videoPath: videoPath,
      ));

      final AppModelLibraryHostService svc =
          _makeService(db: db, tmp: tmp, langCode: 'ja');
      final File? f =
          await svc.resolveVideoSubtitle('video/ep01', langCode: 'ja');
      expect(f, isNotNull);
      expect(f!.path, subFile.path);
    });

    test('无 sidecar → null', () async {
      final String videoPath = p.join(tmp.path, 'nosub.mkv');
      File(videoPath).writeAsBytesSync(<int>[0]);

      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/nosub',
        title: 'NoSub',
        videoPath: videoPath,
      ));

      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final File? f = await svc.resolveVideoSubtitle('video/nosub');
      expect(f, isNull);
    });

    test('未知 id → null', () async {
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final File? f = await svc.resolveVideoSubtitle('video/unknown');
      expect(f, isNull);
    });
  });

  // ── getVideoPosition 向后兼容（TODO-816 断点②）─────────────────────────────────
  group('getVideoPosition host-local backward compat', () {
    test('falls back to VideoBooks.lastPositionMs when no prefs', () async {
      // host 本机播放只写 lastPositionMs（旧数据，无 video_remote_position prefs）。
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/local',
        title: 'Local',
        videoPath: '/tmp/local.mp4',
        lastPositionMs: const Value(360000),
      ));
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);

      final ({int positionMs, int updatedAtMs}) progress =
          await svc.getVideoPosition('video/local');
      expect(progress.positionMs, 360000,
          reason:
              'host self-play progress must be readable via getVideoPosition');
      // 无 importedAt 且无 prefs 戳：返回 0（该行未设 importedAt）。
      expect(progress.updatedAtMs, 0);
    });

    test('BUG-996: lastPositionMs 回退用 importedAt 作下界时间戳', () async {
      // host 本机播放只写 lastPositionMs（无 remote_position prefs），但行有 importedAt。
      const int importedMs = 1700000000000;
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/legacy',
        title: 'Legacy',
        videoPath: '/tmp/legacy.mp4',
        lastPositionMs: const Value(900746),
        importedAt: const Value(importedMs),
      ));
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);

      final ({int positionMs, int updatedAtMs}) progress =
          await svc.getVideoPosition('video/legacy');
      expect(progress.positionMs, 900746);
      // BUG-996：不再恒 0——用 importedAt 作下界戳，host 真进度不被无效本地断点吃掉。
      expect(progress.updatedAtMs, importedMs);
    });

    test('prefs progress wins over lastPositionMs', () async {
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/both',
        title: 'Both',
        videoPath: '/tmp/both.mp4',
        lastPositionMs: const Value(100000),
      ));
      await db.setPrefTyped<int>(
          videoRemotePositionPrefKey('video/both'), 800000);
      await db.setPrefTyped<int>(
          videoRemotePositionAtPrefKey('video/both'), 7000);
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);

      final ({int positionMs, int updatedAtMs}) progress =
          await svc.getVideoPosition('video/both');
      expect(progress.positionMs, 800000);
      expect(progress.updatedAtMs, 7000);
    });

    test('unknown id returns zero', () async {
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final ({int positionMs, int updatedAtMs}) progress =
          await svc.getVideoPosition('video/missing');
      expect(progress.positionMs, 0);
      expect(progress.updatedAtMs, 0);
    });
  });

  // ── importVideo / videoExists（client→host 上传落库）────────────────────────────
  group('importVideo / videoExists', () {
    test('上传视频落进 uploadedVideoRoot 并 upsert VideoBooks 行（保留扩展名）', () async {
      final Directory uploads = Directory(p.join(tmp.path, 'remote_videos'))
        ..createSync(recursive: true);
      final AppModelLibraryHostService svc =
          _makeService(db: db, tmp: tmp, uploadedVideoRoot: uploads);

      // client 上传的临时字节（模拟 server 落到临时目录的 body）。
      final File upload = File(p.join(tmp.path, 'upload.bin'))
        ..writeAsBytesSync(List<int>.filled(2048, 7));

      await svc.importVideo(
        upload,
        id: 'video/film',
        title: '映画タイトル',
        originalFileName: 'movie.mkv',
      );

      final VideoBookRow? row = await db.getVideoBookByBookUid('video/film');
      expect(row, isNotNull);
      expect(row!.title, '映画タイトル');
      // 落在 uploadedVideoRoot 下，保留上传原始扩展名（media_kit 依赖）。
      expect(p.isWithin(uploads.path, row.videoPath), isTrue);
      expect(p.extension(row.videoPath), '.mkv');
      expect(File(row.videoPath).existsSync(), isTrue);
      expect(File(row.videoPath).lengthSync(), 2048);
      // 上传临时源已被搬走（rename/move 语义），不留孤儿。
      expect(upload.existsSync(), isFalse);

      expect(await svc.videoExists('video/film'), isTrue);
      expect(await svc.videoExists('video/absent'), isFalse);
    });

    test('重复上传同一 bookUid 幂等覆盖同一行（不产生重复条目）', () async {
      final Directory uploads = Directory(p.join(tmp.path, 'remote_videos'))
        ..createSync(recursive: true);
      final AppModelLibraryHostService svc =
          _makeService(db: db, tmp: tmp, uploadedVideoRoot: uploads);

      await svc.importVideo(
        File(p.join(tmp.path, 'u1.bin'))
          ..writeAsBytesSync(List<int>.filled(100, 1)),
        id: 'video/dup',
        title: 'First',
        originalFileName: 'a.mp4',
      );
      await svc.importVideo(
        File(p.join(tmp.path, 'u2.bin'))
          ..writeAsBytesSync(List<int>.filled(200, 2)),
        id: 'video/dup',
        title: 'Second',
        originalFileName: 'a.mp4',
      );

      final List<VideoBookRow> all = await db.allVideoBooks();
      expect(all.where((VideoBookRow v) => v.bookUid == 'video/dup').length, 1);
      final VideoBookRow row =
          await db.getVideoBookByBookUid('video/dup') as VideoBookRow;
      expect(row.title, 'Second');
      expect(File(row.videoPath).lengthSync(), 200);
    });

    test('best-effort 抽取封面回写 coverPath', () async {
      final Directory uploads = Directory(p.join(tmp.path, 'remote_videos'))
        ..createSync(recursive: true);
      final File coverFile = File(p.join(tmp.path, 'cover.png'))
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final AppModelLibraryHostService svc = _makeService(
        db: db,
        tmp: tmp,
        uploadedVideoRoot: uploads,
        extractVideoCover: (
                {required String videoPath, required String bookUid}) async =>
            coverFile.path,
      );

      await svc.importVideo(
        File(p.join(tmp.path, 'u.bin'))..writeAsBytesSync(<int>[9]),
        id: 'video/withcover',
        title: 'Cover',
        originalFileName: 'c.mp4',
      );

      final VideoBookRow row =
          await db.getVideoBookByBookUid('video/withcover') as VideoBookRow;
      expect(row.coverPath, coverFile.path);
    });

    test('未注入 uploadedVideoRoot 时 importVideo 抛 UnsupportedError', () async {
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      expect(
        () => svc.importVideo(
          File(p.join(tmp.path, 'x.bin'))..writeAsBytesSync(<int>[0]),
          id: 'video/x',
          title: 'X',
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('videoExists 拒路径穿越 id', () async {
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      expect(() => svc.videoExists('../escape'), throwsA(isA<ArgumentError>()));
    });
  });
}

class _EmbeddedSubtitleProbeBackend implements FfmpegBackend {
  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(returnCode: 0, output: '{"format":{}}');

  const _EmbeddedSubtitleProbeBackend();

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    if (args.contains('-hide_banner')) {
      return const FfmpegRunResult(returnCode: 1, output: '''
  Stream #0:0: Video: h264
  Stream #0:1(jpn): Subtitle: subrip (srt) (default)
  Stream #0:2(eng): Subtitle: mov_text (tx3g)
  Stream #0:3(jpn): Subtitle: hdmv_pgs_subtitle
''');
    }
    return const FfmpegRunResult(returnCode: 0, output: '');
  }
}
