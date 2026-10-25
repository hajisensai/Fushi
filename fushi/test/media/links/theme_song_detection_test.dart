import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/links/theme_song/theme_song_detector.dart';
import 'package:fushi/src/media/links/theme_song/theme_song_plan.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';

/// 作品图谱 L2 的识别编排（docs/specs/2026-10-24-cross-media-links.md §2）。
///
/// 解码与声纹都换成替身（真 FFmpeg / 原生库的端到端在 packages/fushi_music 的测试与
/// 真机 BD 样本上验过），这里钉编排本身：
/// ① 连接 → 计划：合集按成员顺序 × 播放列表展开集号，`episode_range` 过滤，只认已确认
///    的音乐 → 视频主题曲连接；
/// ② 识别结果按集缓存：命中写起止，没出现写空行，二次运行不再解码；文件大小 / 修改
///    时刻 / 算法版本任一变了才重算；
/// ③ 解码失败不写缓存（下次再试），也不中断其它集；
/// ④ 专辑连接展开成多首，同一集只留置信度最高的那首；
/// ⑤ 视频页 / 音乐页的读回（段、出现在）与 MV 偏移。
void main() {
  late FushiDatabase db;
  late Directory work;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    work = Directory.systemTemp.createTempSync('theme_song_test_');
  });

  tearDown(() async {
    await db.close();
    if (work.existsSync()) work.deleteSync(recursive: true);
  });

  Future<void> addVideo(String uid, String path, {List<String>? playlist}) =>
      db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: uid,
          title: 'title-$uid',
          videoPath: path,
          playlistJson: Value<String?>(
            playlist == null
                ? null
                : jsonEncode(<Map<String, Object?>>[
                    for (final String p in playlist)
                      <String, Object?>{'title': p, 'path': p},
                  ]),
          ),
        ),
      );

  Future<void> addTrack(
    String uid, {
    String album = 'album-1',
    int durationMs = 90000,
    String? title,
  }) => db.writeMusicScanBatch(
    MusicScanBatchWrite(
      tracks: <MusicTracksCompanion>[
        MusicTracksCompanion.insert(
          trackUid: uid,
          path: '/music/$uid.flac',
          title: title ?? 'song-$uid',
          albumUid: Value<String?>(album),
          durationMs: Value<int?>(durationMs),
          fileMtimeAt: 1,
          fileSize: 1,
          addedAt: 1,
        ),
      ],
      albums: <MusicAlbumsCompanion>[
        MusicAlbumsCompanion.insert(
          albumUid: album,
          title: 'album $album',
          addedAt: 1,
          updatedAt: 1,
        ),
      ],
      artists: const <MusicArtistsCompanion>[],
      credits: const <MusicTrackCreditsCompanion>[],
    ),
  );

  /// 两集的合集 + 一首 OP，连接适用全部集。
  Future<int> seedCollection({String? range, String? role = 'op'}) async {
    await addVideo('ep1', '/anime/ep1.mkv');
    await addVideo('ep2', '/anime/ep2.mkv');
    final int c = await db.createMediaCollection('作品');
    await db.addToCollection(c, MediaKind.video, 'ep1');
    await db.addToCollection(c, MediaKind.video, 'ep2');
    await addTrack('op');
    await db.upsertManualMediaLink(
      relation: MediaLinkRelation.themeSong,
      from: (kind: MediaLinkKind.musicTrack, key: 'op'),
      to: (kind: MediaLinkKind.videoCollection, key: collectionTagEntryKey(c)),
      role: role,
      episodeRange: range,
    );
    return c;
  }

  group('纯函数', () {
    test('episode_range 解析与集号紧凑显示', () {
      expect(parseEpisodeRange(null), isNull);
      expect(parseEpisodeRange(' '), isNull);
      expect(parseEpisodeRange('1-3'), <int>{1, 2, 3});
      expect(parseEpisodeRange('1, 3, 5–6'), <int>{1, 3, 5, 6});
      expect(parseEpisodeRange('13〜14'), <int>{13, 14});
      expect(parseEpisodeRange('0-2'), isNull, reason: '集号从 1 起');
      expect(parseEpisodeRange('abc'), isNull);
      expect(formatEpisodeNumbers(<int>[1, 2, 3, 5, 7, 8]), '1–3, 5, 7–8');
      expect(formatEpisodeNumbers(<int>[12]), '12');
    });

    test('没写角色按位置推断', () {
      expect(
        inferThemeSongRole(startMs: 60000, episodeDurationMs: 1440000),
        ThemeSongRole.op,
      );
      expect(
        inferThemeSongRole(startMs: 1300000, episodeDurationMs: 1440000),
        ThemeSongRole.ed,
      );
      expect(
        inferThemeSongRole(startMs: 30000, episodeDurationMs: null),
        ThemeSongRole.op,
      );
    });

    test('FFmpeg 解码参数：单声道 11025 Hz s16le，CUE 曲目带 -ss / -t', () {
      expect(
        FfmpegThemeSongAudioDecoder.argsFor(
          input: 'in.flac',
          output: 'out.raw',
          startMs: 61500,
          durationMs: 90000,
        ),
        <String>[
          '-y', '-v', 'error', '-ss', '61.500', '-i', 'in.flac', //
          '-t', '90.000', '-map', '0:a:0', '-vn', '-sn', '-dn', //
          '-ac', '1', '-ar', '11025', '-f', 's16le', 'out.raw',
        ],
      );
      expect(
        FfmpegThemeSongAudioDecoder.argsFor(input: 'a', output: 'b'),
        isNot(contains('-ss')),
      );
    });
  });

  group('连接 → 计划', () {
    test('合集按成员 × 播放列表展开集号；episode_range 过滤', () async {
      await addVideo('a', '/anime/a.mkv');
      await addVideo(
        'b',
        '/anime/b1.mkv',
        playlist: <String>[
          '/anime/b1.mkv',
          'https://remote/b2',
          '/anime/b3.mkv',
        ],
      );
      final int c = await db.createMediaCollection('作品');
      await db.addToCollection(c, MediaKind.video, 'a');
      await db.addToCollection(c, MediaKind.video, 'b');
      await addTrack('op');
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.themeSong,
        from: (kind: MediaLinkKind.musicTrack, key: 'op'),
        to: (
          kind: MediaLinkKind.videoCollection,
          key: collectionTagEntryKey(c),
        ),
        role: 'op',
        episodeRange: '2-4',
      );
      final List<ThemeSongPlan> plans = await loadThemeSongPlans(db);
      expect(plans, hasLength(1));
      expect(plans.single.role, ThemeSongRole.op);
      // 集号：a=1, b#0=2, b#1（远端流，跳过但占号）=3, b#2=4；range 2-4。
      expect(
        <String>[
          for (final ThemeSongEpisode e in plans.single.episodes)
            '${e.episodeNumber}:${e.bookUid}#${e.episodeIndex}',
        ],
        <String>['2:b#0', '4:b#2'],
      );
    });

    test('建议态 / 墓碑 / 非音乐→视频的主题曲连接不参与', () async {
      final int c = await seedCollection();
      final MediaLinkEndpoint col = (
        kind: MediaLinkKind.videoCollection,
        key: collectionTagEntryKey(c),
      );
      await addTrack('ed');
      await db.proposeMediaLink(
        relation: MediaLinkRelation.themeSong,
        from: (kind: MediaLinkKind.musicTrack, key: 'ed'),
        to: col,
        source: MediaLinkSource.ai,
        confidence: 0.9,
      );
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.themeSong,
        from: (kind: MediaLinkKind.book, key: 'b'),
        to: col,
      );
      expect(
        <String>[
          for (final ThemeSongPlan p in await loadThemeSongPlans(db))
            p.songs.single.trackUid,
        ],
        <String>['op'],
      );
    });
  });

  group('识别与缓存', () {
    test('命中写起止、没出现写空行；二次运行全走缓存', () async {
      await seedCollection();
      final _FakeDecoder decoder = _FakeDecoder();
      final _FakeEngine engine = _FakeEngine(<String, Duration?>{
        '/anime/ep1.mkv': const Duration(seconds: 30),
        '/anime/ep2.mkv': null,
      });
      final ThemeSongDetector detector = ThemeSongDetector(
        database: db,
        decoder: decoder,
        engine: engine,
        workDirectory: work,
        fileStat: (String _) => (size: 100, modifiedAt: 7),
        clock: () => 42,
      );
      final ThemeSongDetectionReport first = await detector.detect();
      expect(first.episodesCompared, 2);
      expect(first.hits, 1);
      // 一首歌 + 两集 = 三次解码（歌只解一次）。
      expect(decoder.inputs, <String>[
        '/anime/ep1.mkv',
        '/music/op.flac',
        '/anime/ep2.mkv',
      ]);
      final List<VideoThemeSongSpanRow> ep1 = await db.themeSongSpansForEpisode(
        (bookUid: 'ep1', episodeIndex: 0),
      );
      expect(ep1.single.startMs, 30000);
      expect(ep1.single.endMs, 120000);
      expect(ep1.single.detectorVersion, _FakeEngine.kVersion);
      expect(ep1.single.detectedAt, 42);
      final List<VideoThemeSongSpanRow> ep2 = await db.themeSongSpansForEpisode(
        (bookUid: 'ep2', episodeIndex: 0),
      );
      expect(ep2.single.startMs, isNull, reason: '没出现也落一行');
      // 临时 raw 文件都删了。
      expect(work.listSync(), isEmpty);

      decoder.inputs.clear();
      final ThemeSongDetectionReport second = await detector.detect();
      expect(second.episodesFromCache, 2);
      expect(second.episodesCompared, 0);
      expect(decoder.inputs, isEmpty);
    });

    test('文件大小 / 修改时刻 / 算法版本变了才重算', () async {
      await seedCollection();
      int size = 100;
      final _FakeDecoder decoder = _FakeDecoder();
      final _FakeEngine engine = _FakeEngine(<String, Duration?>{
        '/anime/ep1.mkv': const Duration(seconds: 30),
        '/anime/ep2.mkv': const Duration(seconds: 40),
      });
      final ThemeSongDetector detector = ThemeSongDetector(
        database: db,
        decoder: decoder,
        engine: engine,
        workDirectory: work,
        fileStat: (String path) =>
            (size: path.endsWith('ep2.mkv') ? size : 100, modifiedAt: 7),
      );
      await detector.detect();
      decoder.inputs.clear();
      size = 101; // 换了片源
      final ThemeSongDetectionReport r = await detector.detect();
      expect(r.episodesCompared, 1);
      expect(r.episodesFromCache, 1);
      expect(decoder.inputs, <String>['/anime/ep2.mkv']);

      decoder.inputs.clear();
      engine.version = _FakeEngine.kVersion + 1;
      expect((await detector.detect()).episodesCompared, 2);
    });

    test('解码失败不写缓存、不中断其它集；文件不在跳过', () async {
      await seedCollection();
      await addVideo('ep3', '/anime/missing.mkv');
      final _FakeDecoder decoder = _FakeDecoder(
        fail: <String>{'/anime/ep1.mkv'},
      );
      final ThemeSongDetector detector = ThemeSongDetector(
        database: db,
        decoder: decoder,
        engine: _FakeEngine(<String, Duration?>{
          '/anime/ep2.mkv': const Duration(seconds: 5),
        }),
        workDirectory: work,
        fileStat: (String path) =>
            path.contains('missing') ? null : (size: 1, modifiedAt: 1),
      );
      final ThemeSongDetectionReport r = await detector.detect();
      expect(r.decodeFailures, 1);
      expect(r.episodesCompared, 1);
      expect(
        await db.themeSongSpansForEpisode((bookUid: 'ep1', episodeIndex: 0)),
        isEmpty,
      );
      expect(
        (await db.themeSongSpansForEpisode((
          bookUid: 'ep2',
          episodeIndex: 0,
        ))).single.startMs,
        5000,
      );
    });

    test('命中段太短 / 置信度太低按没出现', () async {
      await seedCollection();
      final ThemeSongDetector detector = ThemeSongDetector(
        database: db,
        decoder: _FakeDecoder(),
        engine: _FakeEngine(<String, Duration?>{
          '/anime/ep1.mkv': const Duration(seconds: 30),
          '/anime/ep2.mkv': const Duration(seconds: 30),
        }, spanLength: const Duration(seconds: 8)),
        workDirectory: work,
        fileStat: (String _) => (size: 1, modifiedAt: 1),
      );
      expect((await detector.detect()).hits, 0);
      expect(
        (await db.themeSongSpansForEpisode((
          bookUid: 'ep1',
          episodeIndex: 0,
        ))).single.startMs,
        isNull,
      );
    });
  });

  group('读回', () {
    test('视频页：本集的段（含角色 / 标题）；专辑连接同集只留最好的一首', () async {
      await addVideo('ep1', '/anime/ep1.mkv');
      await addTrack('tv', title: 'OP (TV size)');
      await addTrack('inst', title: 'OP (Instrumental)');
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.themeSong,
        from: (kind: MediaLinkKind.musicAlbum, key: 'album-1'),
        to: (kind: MediaLinkKind.videoEpisode, key: 'ep1'),
      );
      Future<void> row(String track, int start, double conf) =>
          db.upsertThemeSongSpan(
            VideoThemeSongSpansCompanion.insert(
              bookUid: 'ep1',
              episodeIndex: 0,
              trackUid: track,
              fileSizeBytes: 1,
              fileModifiedAt: 1,
              detectorVersion: 1,
              startMs: Value<int?>(start),
              endMs: Value<int?>(start + 90000),
              confidence: Value<double?>(conf),
              detectedAt: 1,
            ),
          );
      await row('tv', 1000, 0.95);
      await row('inst', 1000, 0.7);
      final List<ThemeSongSpan> spans = await loadThemeSongSpansForEpisode(
        db,
        bookUid: 'ep1',
        episodeIndex: 0,
        episodeDurationMs: 1440000,
      );
      expect(spans, hasLength(1));
      expect(spans.single.title, 'OP (TV size)');
      expect(spans.single.role, ThemeSongRole.op, reason: '没写角色按位置推断');
      expect(spans.single.contains(1000), isTrue);
      expect(spans.single.contains(91000), isFalse);
    });

    test('音乐页「出现在」：按集号列出命中的集与起点', () async {
      await seedCollection(role: 'ed');
      final ThemeSongDetector detector = ThemeSongDetector(
        database: db,
        decoder: _FakeDecoder(),
        engine: _FakeEngine(<String, Duration?>{
          '/anime/ep1.mkv': const Duration(minutes: 22),
          '/anime/ep2.mkv': const Duration(minutes: 21),
        }),
        workDirectory: work,
        fileStat: (String _) => (size: 1, modifiedAt: 1),
      );
      await detector.detect(onlyTrackUid: 'op');
      final List<ThemeSongAppearance> list = await loadThemeSongAppearances(
        db,
        'op',
      );
      expect(list, hasLength(1));
      expect(list.single.videoTitle, '作品');
      expect(list.single.role, ThemeSongRole.ed);
      expect(list.single.episodeLabel, '1–2');
      expect(
        <int>[
          for (final ({ThemeSongEpisode episode, int startMs}) e
              in list.single.episodes)
            e.startMs,
        ],
        <int>[22 * 60000, 21 * 60000],
      );
    });

    test('删视频同事务清掉缓存', () async {
      await seedCollection();
      await db.upsertThemeSongSpan(
        VideoThemeSongSpansCompanion.insert(
          bookUid: 'ep1',
          episodeIndex: 0,
          trackUid: 'op',
          fileSizeBytes: 1,
          fileModifiedAt: 1,
          detectorVersion: 1,
          detectedAt: 1,
        ),
      );
      await db.deleteVideoBooks(<String>['ep1']);
      expect(
        await db.themeSongSpansForEpisode((bookUid: 'ep1', episodeIndex: 0)),
        isEmpty,
      );
    });
  });

  test('MV 偏移 = 对齐偏移；没对上返回 null', () async {
    final ThemeSongDetector detector = ThemeSongDetector(
      database: db,
      decoder: _FakeDecoder(),
      engine: _FakeEngine(<String, Duration?>{
        '/mv/a.mp4': const Duration(milliseconds: 8120),
        '/mv/b.mp4': null,
      }),
      workDirectory: work,
    );
    const ThemeSongSong audio = ThemeSongSong(
      trackUid: 'op',
      title: 'op',
      path: '/music/op.flac',
    );
    expect(
      await detector.mvOffset(audio: audio, mvPath: '/mv/a.mp4'),
      const Duration(milliseconds: 8120),
    );
    expect(await detector.mvOffset(audio: audio, mvPath: '/mv/b.mp4'), isNull);
  });
}

/// 解码替身：把输入路径写进 raw 文件当「PCM」，声纹替身据此认出是哪个文件。
class _FakeDecoder implements ThemeSongAudioDecoder {
  _FakeDecoder({this.fail = const <String>{}});

  final Set<String> fail;
  final List<String> inputs = <String>[];

  @override
  Future<void> decodeToRawPcm({
    required String input,
    required String output,
    int? startMs,
    int? durationMs,
  }) async {
    inputs.add(input);
    if (fail.contains(input)) {
      throw ThemeSongDecodeException(input, 'boom');
    }
    File(output).writeAsStringSync(input);
  }
}

/// 声纹替身：声纹 = 文件内容（输入路径）的编码；对齐按 haystack 路径查表。
class _FakeEngine implements ThemeSongFingerprintEngine {
  _FakeEngine(
    this.startByHaystack, {
    this.spanLength = const Duration(seconds: 90),
  });

  static const int kVersion = 3;

  final Map<String, Duration?> startByHaystack;
  final Duration spanLength;

  @override
  int version = kVersion;

  final Map<int, String> _pathById = <int, String>{};

  @override
  Future<Uint32List> fingerprintRawPcm(String path) async {
    final String source = File(path).readAsStringSync();
    final int id = _pathById.length + 1;
    _pathById[id] = source;
    return Uint32List.fromList(<int>[id]);
  }

  @override
  Future<AudioFingerprintMatch?> align(
    Uint32List needle,
    Uint32List haystack,
  ) async {
    final Duration? start = startByHaystack[_pathById[haystack.single]];
    if (start == null) return null;
    return AudioFingerprintMatch(
      offset: start,
      haystackStart: start,
      haystackEnd: start + spanLength,
      needleStart: Duration.zero,
      needleEnd: spanLength,
      startAtNeedleEdge: true,
      endAtNeedleEdge: true,
      meanBitError: 2,
      confidence: 0.9,
      matchedItems: 700,
      runItems: 720,
    );
  }
}
