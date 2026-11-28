import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi/src/media/links/theme_song/theme_song_detector.dart';
import 'package:fushi/src/media/links/theme_song/theme_song_plan.dart'
    show ThemeSongSong;
import 'package:fushi/src/media/music/metadata/music_video_auto_match.dart';
import 'package:fushi/src/media/music/metadata/music_video_service.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_mv_backdrop.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/metadata/music_release_videos.dart'
    show MusicReleaseVideoCandidate;
import 'package:fushi_engine/media/music/metadata/music_video_match.dart'
    show MusicVideoKind;
import 'package:fushi_music/fushi_music.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 本地 MV 后台自动匹配：一个视频只解码一次（声纹落库，重启后也不再解码）、一对（歌,
/// 视频版本）只对一次（没对上也记），文件换了才重对；已绑定的歌不再找；手动「找本地 MV」
/// 强制重对但不重解码视频。解码与声纹用替身。
void main() {
  late FushiDatabase db;
  late Directory root;
  late Directory work;
  late String cd;
  late String stream;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    root = Directory.systemTemp.createTempSync('fushi_mv_auto_');
    work = Directory.systemTemp.createTempSync('fushi_mv_auto_work_');
    // 专辑/CD/a.flac、b.flac 与 专辑/BD/BDMV/STREAM/00001.m2ts 并列。
    cd = p.join(root.path, 'CD');
    Directory(cd).createSync();
    for (final String n in <String>['a.flac', 'b.flac']) {
      File(p.join(cd, n)).writeAsStringSync('audio');
    }
    stream = p.join(root.path, 'BD', 'BDMV', 'STREAM', '00001.m2ts');
    File(stream)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('video-v1');
  });

  tearDown(() async {
    await db.close();
    root.deleteSync(recursive: true);
    work.deleteSync(recursive: true);
  });

  Future<void> addTrack(String uid, String path) => db.writeMusicScanBatch(
    MusicScanBatchWrite(
      tracks: <MusicTracksCompanion>[
        MusicTracksCompanion.insert(
          trackUid: uid,
          path: path,
          title: 'song-$uid',
          albumUid: const Value<String?>('album'),
          durationMs: const Value<int?>(90000),
          fileMtimeAt: 1,
          fileSize: 1,
          addedAt: 1,
        ),
      ],
      albums: <MusicAlbumsCompanion>[
        MusicAlbumsCompanion.insert(
          albumUid: 'album',
          title: 'album',
          addedAt: 1,
          updatedAt: 1,
        ),
      ],
      artists: const <MusicArtistsCompanion>[],
      credits: const <MusicTrackCreditsCompanion>[],
    ),
  );

  /// 每次新建识别器 = 模拟重启（进程内缓存清空，只剩落库缓存）。
  ({MusicVideoAutoMatcher matcher, _FakeDecoder decoder, MusicVideoService svc})
  fresh() {
    final _FakeDecoder decoder = _FakeDecoder();
    final ThemeSongDetector detector = ThemeSongDetector(
      database: db,
      decoder: decoder,
      // 只有 a 和这条流对得上。
      engine: _PairEngine(<(String, String)>{(p.join(cd, 'a.flac'), stream)}),
      workDirectory: work,
    );
    final MusicVideoService svc = MusicVideoService(
      database: db,
      detector: detector,
      nearby:
          (
            String d, {
            List<MusicReleaseVideoCandidate> release =
                const <MusicReleaseVideoCandidate>[],
          }) =>
              collectMusicVideoFilesNear(d, minDiscBytes: 1, release: release),
    );
    final MusicVideoAutoMatcher matcher = MusicVideoAutoMatcher(
      database: () => db,
      enabled: () => true,
      service: (_) => svc,
      collect: (Map<String, List<MusicReleaseVideoCandidate>> dirs) async =>
          <String, MusicVideoNearbyFiles>{
            for (final MapEntry<String, List<MusicReleaseVideoCandidate>> d
                in dirs.entries)
              d.key: collectMusicVideoFilesNear(
                d.key,
                minDiscBytes: 1,
                release: d.value,
              ),
          },
    );
    return (matcher: matcher, decoder: decoder, svc: svc);
  }

  int decodesOf(_FakeDecoder d, String path) =>
      d.inputs.where((String i) => i == path).length;

  test('首轮：流只解码一次，对上的歌绑定，没对上的也记成已对过', () async {
    await addTrack('a', p.join(cd, 'a.flac'));
    await addTrack('b', p.join(cd, 'b.flac'));
    final f = fresh();
    await f.matcher.schedule();

    expect(decodesOf(f.decoder, stream), 1, reason: '两首歌共用一份流声纹');
    final List<MusicVideoRow> a = await db.listMusicVideos('a');
    expect(a.single.ref, stream);
    expect(a.single.offsetMs, 5000);
    expect(await db.listMusicVideos('b'), isEmpty);
    final Map<(String, String), MusicVideoMatchCheckRow> checks = await db
        .allMusicVideoMatchChecks();
    expect(
      checks.keys,
      containsAll(<(String, String)>[('a', stream), ('b', stream)]),
    );
    expect(f.matcher.boundThisRun, 1);
  });

  test('重启后再扫：没换过的文件不解码也不再对', () async {
    await addTrack('a', p.join(cd, 'a.flac'));
    await addTrack('b', p.join(cd, 'b.flac'));
    await fresh().matcher.schedule();

    final f = fresh();
    await f.matcher.schedule();
    expect(f.decoder.inputs, isEmpty, reason: '已绑定的 a 跳过，b 对过这个版本');
  });

  test('视频文件换了（大小变）才重对；视频声纹从落库缓存读', () async {
    await addTrack('a', p.join(cd, 'a.flac'));
    await addTrack('b', p.join(cd, 'b.flac'));
    await fresh().matcher.schedule();

    File(stream).writeAsStringSync('video-v2-longer');
    final f = fresh();
    await f.matcher.schedule();
    expect(decodesOf(f.decoder, stream), 1, reason: '新版本重算一次声纹');
    expect(decodesOf(f.decoder, p.join(cd, 'b.flac')), 1, reason: 'b 重对');
    expect(decodesOf(f.decoder, p.join(cd, 'a.flac')), 0, reason: 'a 已绑定不找');
  });

  test('手动「找本地 MV」强制重对，但视频声纹走落库缓存不重解码', () async {
    await addTrack('a', p.join(cd, 'a.flac'));
    await addTrack('b', p.join(cd, 'b.flac'));
    await fresh().matcher.schedule();

    final f = fresh();
    final List<MusicLocalVideoMatch> found = await f.svc.matchLocal('b');
    expect(found.single.path, stream);
    expect(found.single.alignment, isNull);
    expect(decodesOf(f.decoder, stream), 0);
    expect(decodesOf(f.decoder, p.join(cd, 'b.flac')), 1);
  });

  test('绑定的本地文件已不在时重新找；用户确认过的绑定不动', () async {
    expect(
      musicVideoBindingsSatisfied(<MusicVideoRow>[
        _row(ref: p.join(root.path, 'gone.mkv')),
      ]),
      isFalse,
    );
    expect(
      musicVideoBindingsSatisfied(<MusicVideoRow>[_row(ref: stream)]),
      isTrue,
    );
    expect(
      musicVideoBindingsSatisfied(<MusicVideoRow>[
        _row(ref: p.join(root.path, 'gone.mkv'), userBound: true),
      ]),
      isTrue,
    );
  });

  test('歌曲声纹缓存有上限、按最近使用淘汰；歌曲文件换了重算', () async {
    final _FakeDecoder decoder = _FakeDecoder();
    final ThemeSongDetector detector = ThemeSongDetector(
      database: db,
      decoder: decoder,
      engine: _PairEngine(const <(String, String)>{}),
      workDirectory: work,
    );
    ThemeSongSong song(int i) => ThemeSongSong(
      trackUid: 's$i',
      title: 's$i',
      path: p.join(cd, 's$i.flac'),
    );
    Future<void> align(int i) =>
        detector.mvAlignment(audio: song(i), mvPath: stream);
    int decodes(int i) => decodesOf(decoder, song(i).path);

    const int cap = ThemeSongDetector.kSongPrintCacheSize;
    for (int i = 0; i < cap; i++) {
      await align(i);
    }
    await align(0); // 命中并挪到队尾
    await align(cap); // 挤掉最久没用的 s1
    await align(0);
    await align(1);
    expect(decodes(0), 1, reason: '最近用过的留着');
    expect(decodes(1), 2, reason: '超出上限被淘汰后重算');

    final File a = File(p.join(cd, 'a.flac'));
    final ThemeSongSong real = ThemeSongSong(
      trackUid: 'a',
      title: 'a',
      path: a.path,
    );
    await detector.mvAlignment(audio: real, mvPath: stream);
    await detector.mvAlignment(audio: real, mvPath: stream);
    a.writeAsStringSync('audio-retagged');
    await detector.mvAlignment(audio: real, mvPath: stream);
    expect(decodesOf(decoder, a.path), 2, reason: '同一文件只算一次，换了才重算');
  });

  test('歌词页 MV 背景跟着绑定变：绑上 / 改偏移 / 解绑都重发', () async {
    await addTrack('a', p.join(cd, 'a.flac'));
    final StreamIterator<MusicMvBackdropSource?> events =
        StreamIterator<MusicMvBackdropSource?>(
          watchMusicMvBackdropSource(db, 'a'),
        );
    Future<MusicMvBackdropSource?> next() async {
      expect(await events.moveNext(), isTrue);
      return events.current;
    }

    expect(await next(), isNull, reason: '还没有绑定');
    Future<void> bind(int offsetMs) => db.upsertMusicVideo(
      MusicVideosCompanion.insert(
        trackUid: 'a',
        kind: MusicVideoKind.local,
        ref: stream,
        offsetMs: Value<int>(offsetMs),
        updatedAt: offsetMs,
      ),
    );
    await bind(5000);
    expect(
      await next(),
      MusicMvBackdropSource(path: stream, offsetMs: 5000),
      reason: '后台匹配绑上后正开着的歌词页拿到 MV',
    );
    await bind(4200);
    expect(
      await next(),
      MusicMvBackdropSource(path: stream, offsetMs: 4200),
      reason: '偏移改了跟着改',
    );
    await db.deleteMusicVideo((await db.listMusicVideos('a')).single.id);
    expect(await next(), isNull, reason: '解绑后撤掉');
    await events.cancel();
  });

  test('同一下载发布里的特典（整理后不在 CD 附近）也是候选；来源搬家后照样找得到', () async {
    // 原发布目录 [Grp] Show/CDs/OP/op.flac，整理后的特典在 Show (2023)/Extras/SPs/，
    // 整个来源又从 root/old 搬到 root/new（任务记下的绝对路径全部过时）。
    const String relCd = '[Grp] Show/CDs/OP';
    const String relNcop = 'Show (2023)/Extras/SPs/[Grp] Show [NCOP].mkv';
    final String newRoot = p.join(root.path, 'new');
    final String song = p.join(newRoot, relCd, 'op.flac');
    final String ncop = p.joinAll(<String>[newRoot, ...relNcop.split('/')]);
    File(song)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('op-audio');
    File(ncop)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('ncop-video');
    await db.upsertVideoDownloadJob(
      VideoDownloadJobsCompanion.insert(
        jobId: 'job',
        resourceProvider: 'nyaa:test',
        selectedResourceId: 'r',
        mediaKind: 'tv',
        title: 'Show',
        backendKind: 'embedded',
        fingerprint: 'fp',
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    final String oldRoot = p.join(root.path, 'old');
    await db.replaceVideoDownloadJobFiles(
      'job',
      <VideoDownloadJobFilesCompanion>[
        VideoDownloadJobFilesCompanion.insert(
          jobId: 'job',
          originalRelativePath: '$relCd/op.flac',
          currentRelativePath: '$relCd/op.flac',
          createdAt: 1,
          updatedAt: 1,
        ),
        VideoDownloadJobFilesCompanion.insert(
          jobId: 'job',
          originalRelativePath: '[Grp] Show/SPs/[Grp] Show [NCOP].mkv',
          currentRelativePath: relNcop,
          kind: const Value<String>('extra'),
          finalAbsolutePath: Value<String?>(
            p.joinAll(<String>[oldRoot, ...relNcop.split('/')]),
          ),
          createdAt: 1,
          updatedAt: 1,
        ),
      ],
    );
    await addTrack('op', song);

    final _FakeDecoder decoder = _FakeDecoder();
    final ThemeSongDetector detector = ThemeSongDetector(
      database: db,
      decoder: decoder,
      engine: _PairEngine(<(String, String)>{(song, ncop)}),
      workDirectory: work,
    );
    final MusicVideoAutoMatcher matcher = MusicVideoAutoMatcher(
      database: () => db,
      enabled: () => true,
      service: (_) => MusicVideoService(database: db, detector: detector),
      collect: (Map<String, List<MusicReleaseVideoCandidate>> dirs) async =>
          <String, MusicVideoNearbyFiles>{
            for (final MapEntry<String, List<MusicReleaseVideoCandidate>> d
                in dirs.entries)
              d.key: collectMusicVideoFilesNear(d.key, release: d.value),
          },
    );
    await matcher.schedule();
    expect((await db.listMusicVideos('op')).single.ref, ncop);
  });

  test('一对出错只跳过这一对：同轮后面的歌照样对，出错的那对不记已对过、下一轮再试', () async {
    await addTrack('a', p.join(cd, 'a.flac'));
    await addTrack('b', p.join(cd, 'b.flac'));
    final f = fresh();
    final _ThrowingService svc = _ThrowingService(
      database: db,
      inner: f.svc,
      failing: <String>{'a'},
    );
    final MusicVideoAutoMatcher matcher = MusicVideoAutoMatcher(
      database: () => db,
      enabled: () => true,
      service: (_) => svc,
      collect: (Map<String, List<MusicReleaseVideoCandidate>> dirs) async =>
          <String, MusicVideoNearbyFiles>{
            for (final String d in dirs.keys)
              d: collectMusicVideoFilesNear(d, minDiscBytes: 1),
          },
    );
    await matcher.schedule();

    expect(svc.attempted, <String>['a', 'b'], reason: 'a 出错后接着对 b');
    final Map<(String, String), MusicVideoMatchCheckRow> checks = await db
        .allMusicVideoMatchChecks();
    expect(checks.keys, contains(('b', stream)));
    expect(checks.keys, isNot(contains(('a', stream))), reason: '出错不算对过');

    // 下一轮（例如启动补跑）：a 不再出错，补上绑定。
    svc.failing.clear();
    await matcher.schedule();
    expect((await db.listMusicVideos('a')).single.ref, stream);
  });

  test('声纹落库编码往返', () {
    final Uint32List print = Uint32List.fromList(<int>[0, 1, 0xFFFFFFFF, 42]);
    expect(decodeMusicVideoPrint(encodeMusicVideoPrint(print)), print);
  });
}

MusicVideoRow _row({required String ref, bool userBound = false}) =>
    MusicVideoRow(
      id: 1,
      trackUid: 't',
      kind: 'local',
      ref: ref,
      offsetMs: 0,
      confidence: null,
      isUserBound: userBound,
      updatedAt: 0,
    );

/// 解码替身：把输入路径写进 raw 文件当「PCM」，并记下解码过哪些输入。
class _FakeDecoder implements ThemeSongAudioDecoder {
  final List<String> inputs = <String>[];

  @override
  Future<void> decodeToRawPcm({
    required String input,
    required String output,
    int? startMs,
    int? durationMs,
  }) async {
    inputs.add(input);
    File(output).writeAsStringSync(input);
  }
}

/// 声纹替身：声纹 = 输入路径的稳定编号；对齐只认登记的（歌, 视频）对。
class _PairEngine implements ThemeSongFingerprintEngine {
  _PairEngine(this.pairs);

  final Set<(String, String)> pairs;

  /// 全测试共享：落库的声纹（编号）在「重启」后的新替身里也认得。
  static final Map<int, String> _pathById = <int, String>{};
  static final Map<String, int> _idByPath = <String, int>{};

  @override
  int version = 3;

  @override
  Future<Uint32List> fingerprintRawPcm(String path) async {
    final String source = File(path).readAsStringSync();
    final int id = _idByPath.putIfAbsent(source, () {
      final int next = _pathById.length + 1;
      _pathById[next] = source;
      return next;
    });
    return Uint32List.fromList(<int>[id]);
  }

  @override
  Future<AudioFingerprintMatch?> align(
    Uint32List needle,
    Uint32List haystack,
  ) async {
    final String? song = _pathById[needle.single];
    final String? video = _pathById[haystack.single];
    if (!pairs.contains((song, video))) return null;
    const Duration start = Duration(seconds: 5);
    const Duration span = Duration(seconds: 90);
    return const AudioFingerprintMatch(
      offset: start,
      haystackStart: start,
      haystackEnd: Duration(seconds: 95),
      needleStart: Duration.zero,
      needleEnd: span,
      startAtNeedleEdge: true,
      endAtNeedleEdge: true,
      meanBitError: 2,
      confidence: 0.9,
      matchedItems: 700,
      runItems: 720,
    );
  }
}

/// 对齐替身：[failing] 里的曲目抛错（模拟读不了的文件 / 解码失败），其余交给 [inner]。
class _ThrowingService extends MusicVideoService {
  _ThrowingService({
    required super.database,
    required this.inner,
    required this.failing,
  });

  final MusicVideoService inner;
  final Set<String> failing;
  final List<String> attempted = <String>[];

  @override
  Future<({AudioFingerprintMatch? match, bool bound})> alignLocal(
    MusicTrackRow track,
    MusicVideoFileStamp video,
  ) async {
    attempted.add(track.trackUid);
    if (failing.contains(track.trackUid)) {
      throw const FileSystemException('unreadable');
    }
    return inner.alignLocal(track, video);
  }
}
