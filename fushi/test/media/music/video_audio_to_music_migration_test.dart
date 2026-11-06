// 反馈 QAondMh4M5：旧版按「无画面视频」入库的纯音频搬到音乐库（幂等、先入库后删行）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;
import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/lrclib_client.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_sources.dart';
import 'package:fushi/src/media/music/music_audio_intake.dart';
import 'package:fushi/src/media/music/video_audio_to_music_migration.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart'
    show videoSubtitleJobId;
import 'package:fushi_music/fushi_music.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:path/path.dart' as p;

void main() {
  late FushiDatabase db;
  late VideoBookRepository repo;
  late Directory scratch;
  late Directory jobsDir;
  late Directory importedDir;
  final String root = p.join(p.rootPrefix(p.current), 'media');
  String at(List<String> parts) => p.joinAll(<String>[root, ...parts]);

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = VideoBookRepository(db);
    scratch = Directory.systemTemp.createTempSync('va2m_');
    jobsDir = Directory(p.join(scratch.path, 'jobs'));
    importedDir = Directory(p.join(scratch.path, 'app', 'video_subtitles'));
  });
  tearDown(() async {
    await db.close();
    scratch.deleteSync(recursive: true);
  });

  Future<void> video(
    String uid,
    String path, {
    int? sourceId,
    int? lastPlayedAt,
    int lastPositionMs = 0,
    DateTime? completedAt,
    String? subtitleSource,
  }) => repo.saveVideoBook(
    VideoBooksCompanion(
      bookUid: Value<String>(uid),
      title: Value<String>(p.basenameWithoutExtension(path)),
      videoPath: Value<String>(path),
      importedAt: const Value<int>(1),
      sourceId: Value<int?>(sourceId),
      lastPlayedAt: Value<int?>(lastPlayedAt),
      lastPositionMs: Value<int>(lastPositionMs),
      completedAt: Value<DateTime?>(completedAt),
      subtitleSource: Value<String?>(subtitleSource),
    ),
  );

  MusicLyricsService lyricsService() => MusicLyricsService(
    database: () => db,
    lrclib: LrclibClient(transport: (Uri _) async => (status: 404, body: '')),
    onlineEnabled: () => false,
    readEmbedded: (String _, int? _) async => const <EmbeddedLyrics>[],
    parse: (List<int> b, String h, int? d) async =>
        FushiLyrics.parse(Uint8List.fromList(b), hint: h, durationMs: d),
  );

  /// 音乐扫描替身：把路径写成在库曲目（Rust 拼法：正斜杠根 + 平台分隔符）。[cueStartMs]
  /// 非空 = 整轨 + CUE 拆出的虚拟曲目（uid 带上起点）。
  Future<void> track(String path, {int? durationMs, int? cueStartMs}) => db
      .into(db.musicTracks)
      .insert(
        MusicTracksCompanion.insert(
          trackUid:
              'uid:${p.canonicalize(path)}'
              '${cueStartMs == null ? '' : '#$cueStartMs'}',
          path: normalizeSourceRootPath(path, transport: 'local'),
          title: p.basenameWithoutExtension(path),
          durationMs: Value<int?>(durationMs),
          cueStartMs: Value<int?>(cueStartMs),
          fileMtimeAt: 1,
          fileSize: 1,
          addedAt: 1,
        ),
      );

  /// 一个文件拆出的一段（M4B 章节 / CUE 虚拟曲目）。
  Future<void> segment(
    String path,
    String uid, {
    required int startMs,
    int? endMs,
    required int durationMs,
  }) => db
      .into(db.musicTracks)
      .insert(
        MusicTracksCompanion.insert(
          trackUid: uid,
          path: normalizeSourceRootPath(path, transport: 'local'),
          title: uid,
          cueStartMs: Value<int?>(startMs),
          cueEndMs: Value<int?>(endMs),
          durationMs: Value<int?>(durationMs),
          fileMtimeAt: 1,
          fileSize: 1,
          addedAt: 1,
        ),
      );

  Future<List<String>> videoUids() async =>
      <String>[for (final VideoBookRow r in await repo.listAll()) r.bookUid]
        ..sort();

  test('sourced and manual audio rows move to the music library; videos, '
      'remote audio and unreadable files stay; progress becomes a play '
      'event; second run is a no-op', () async {
    final int sid = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Anime',
        mediaKind: 'video',
        rootPath: normalizeSourceRootPath(
          at(<String>['Anime']),
          transport: 'local',
        ),
        createdAt: 1,
      ),
    );
    final String ost = at(<String>['Anime', 'Show', 'CDs', 'OST', '01.flac']);
    final String drama = at(<String>['Downloads', 'drama.mp3']);
    final String broken = at(<String>['Downloads', 'broken.m4b']);
    await video(
      'v/ep01',
      at(<String>['Anime', 'Show', 'ep01.mkv']),
      sourceId: sid,
    );
    await video(
      'v/ost',
      ost,
      sourceId: sid,
      lastPlayedAt: 5000,
      lastPositionMs: 1200,
      completedAt: DateTime.fromMillisecondsSinceEpoch(6000),
    );
    await video('v/drama', drama, lastPlayedAt: 7000, lastPositionMs: 3000);
    await video('v/broken', broken);
    await video('v/remote', 'https://h/x/a.flac');
    await video('v/missing', at(<String>['Gone', 'x.flac']));

    final List<({String rootPath, bool recursive})> registered =
        <({String rootPath, bool recursive})>[];
    final List<String> imported = <String>[];
    final MusicAudioIntake intake = MusicAudioIntake(
      db,
      fileExists: (String path) => !path.contains('Gone'),
      registerSource:
          ({
            required String rootPath,
            required bool recursive,
            required int ownerSourceId,
          }) async {
            registered.add((rootPath: rootPath, recursive: recursive));
            await track(ost, durationMs: 9000);
            return null;
          },
      importFile: (String path, {bool recursive = false}) async {
        imported.add(path);
        // 坏文件：扫描不出曲目，行必须留在视频库。
        if (path == drama) await track(drama);
        return null;
      },
      rescanSource: (SourceLibraryRow s) async => fail('nothing covered'),
    );

    final VideoAudioMigrationReport first =
        await migrateAudioOnlyVideoBooksToMusic(
          db,
          intake: intake,
          fileExists: (String path) => !path.contains('Gone'),
          lyrics: lyricsService(),
          subtitleJobsRoot: jobsDir,
          importedSubtitlesDir: importedDir,
        );

    expect(registered, <({String rootPath, bool recursive})>[
      (rootPath: at(<String>['Anime', 'Show', 'CDs']), recursive: true),
    ]);
    expect(imported, unorderedEquals(<String>[drama, broken]));
    expect(first.candidates, 3);
    expect(first.migrated, 2);
    expect(first.leftInVideoLibrary, 1);
    expect(first.playEventsWritten, 2);
    expect(await videoUids(), <String>[
      'v/broken',
      'v/ep01',
      'v/missing',
      'v/remote',
    ]);
    final List<MusicPlayEventRow> events =
        await (db.select(db.musicPlayEvents)
              ..orderBy(<OrderingTerm Function($MusicPlayEventsTable)>[
                ($MusicPlayEventsTable e) =>
                    OrderingTerm(expression: e.startedAt),
              ]))
            .get();
    expect(
      events
          .map(
            (MusicPlayEventRow e) => (e.startedAt, e.listenedMs, e.completed),
          )
          .toList(),
      <(int, int, bool)>[(5000, 9000, true), (7000, 3000, false)],
    );
    // 没看完的断点带进音乐逐曲断点；看完的（ost）不带。
    expect(first.resumePointsWritten, 1);
    final MusicResumePointRow? resume = await db.getMusicResumePoint(
      'uid:${p.canonicalize(drama)}',
    );
    expect(resume?.positionMs, 3000);
    expect(resume?.updatedAt, 7000);
    expect(await db.getMusicResumePoint('uid:${p.canonicalize(ost)}'), isNull);

    // 第二次：搬过的行已删，只剩搬不动的坏文件再试一次，播放记录不重复。
    imported.clear();
    final VideoAudioMigrationReport second =
        await migrateAudioOnlyVideoBooksToMusic(
          db,
          intake: intake,
          fileExists: (String path) => !path.contains('Gone'),
          lyrics: lyricsService(),
          subtitleJobsRoot: jobsDir,
          importedSubtitlesDir: importedDir,
        );
    expect(second.candidates, 1);
    expect(second.migrated, 0);
    expect(imported, <String>[broken]);
    expect(await db.select(db.musicPlayEvents).get(), hasLength(2));
    expect(await db.select(db.musicResumePoints).get(), hasLength(1));
  });

  test('flac + cue disc: the whole-file position lands on the track it falls '
      'in, stored relative to that track; a newer music position is not '
      'rolled back', () async {
    final String disc = at(<String>['Drama', 'disc1.flac']);
    final String other = at(<String>['Drama', 'disc2.flac']);
    // 第 2 轨从 20 分钟开始、长 30 分钟；断点在整盘 35 分钟 = 第 2 轨的 15 分钟。
    await video('v/disc', disc, lastPlayedAt: 9000, lastPositionMs: 2100000);
    await video('v/other', other, lastPlayedAt: 100, lastPositionMs: 60000);
    final MusicAudioIntake intake = MusicAudioIntake(
      db,
      fileExists: (_) => true,
      importFile: (String path, {bool recursive = false}) async {
        if (path == disc) {
          await track(disc, durationMs: 1200000, cueStartMs: 0);
          await track(disc, durationMs: 1800000, cueStartMs: 1200000);
          await track(disc, durationMs: 600000, cueStartMs: 3000000);
        } else {
          await track(other, durationMs: 600000);
        }
        return null;
      },
    );
    // 用户已在音乐库里把 disc2 听到更新的位置（迁移被打断后重跑的情形）。
    await db.upsertMusicResumePoint(
      'uid:${p.canonicalize(other)}',
      positionMs: 300000,
      updatedAt: 200,
    );

    final VideoAudioMigrationReport r = await migrateAudioOnlyVideoBooksToMusic(
      db,
      intake: intake,
      fileExists: (_) => true,
      lyrics: lyricsService(),
      subtitleJobsRoot: jobsDir,
      importedSubtitlesDir: importedDir,
    );

    expect(r.migrated, 2);
    expect(r.resumePointsWritten, 1);
    final String track2 = 'uid:${p.canonicalize(disc)}#1200000';
    expect((await db.getMusicResumePoint(track2))?.positionMs, 900000);
    expect(
      await db.getMusicResumePoint('uid:${p.canonicalize(disc)}#0'),
      isNull,
    );
    expect(
      (await db.getMusicResumePoint(
        'uid:${p.canonicalize(other)}',
      ))?.positionMs,
      300000,
      reason: '音乐库里更新的位置不被视频库的旧断点倒退',
    );
    final List<MusicPlayEventRow> events = await db
        .select(db.musicPlayEvents)
        .get();
    final MusicPlayEventRow discEvent = events.singleWhere(
      (MusicPlayEventRow e) => e.startedAt == 9000,
    );
    expect(discEvent.trackUid, track2);
    expect(discEvent.listenedMs, 900000);
  });

  test(
    'pickMigratedTrack: a CUE file position maps to the track it falls in',
    () {
      MusicTrackRow t(int start) => MusicTrackRow(
        trackUid: 't$start',
        path: '/a.flac',
        isLossless: true,
        title: 't',
        hasEmbeddedCover: false,
        fileMtimeAt: 1,
        fileSize: 1,
        addedAt: 1,
        cueStartMs: start,
      );
      final List<MusicTrackRow> tracks = <MusicTrackRow>[
        t(0),
        t(1000),
        t(5000),
      ];
      expect(
        pickMigratedTrack(
          tracks,
          positionMs: 0,
          completed: false,
        ).track.trackUid,
        't0',
      );
      expect(
        pickMigratedTrack(tracks, positionMs: 999, completed: false).relativeMs,
        999,
      );
      expect(
        pickMigratedTrack(
          tracks,
          positionMs: 1000,
          completed: false,
        ).track.trackUid,
        't1000',
      );
      expect(
        pickMigratedTrack(
          tracks,
          positionMs: 1000,
          completed: false,
        ).relativeMs,
        0,
      );
      expect(
        pickMigratedTrack(
          tracks,
          positionMs: 7000,
          completed: false,
        ).track.trackUid,
        't5000',
      );
      expect(
        pickMigratedTrack(
          tracks,
          positionMs: 7000,
          completed: false,
        ).relativeMs,
        2000,
      );
    },
  );

  test('generated subtitles travel by path (whole-season runs never set '
      'subtitleSource): own .ja.srt / .ja.asr.srt become asr rows, a picked '
      'imported subtitle becomes the user choice, a foreign .ja.srt stays a '
      'sidecar', () async {
    final Directory tmp = Directory.systemTemp.createTempSync('va2m_sub_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final Directory jobs = Directory(p.join(tmp.path, 'jobs'));
    const String srt =
        '1\n00:00:01,000 --> 00:00:03,000\nお便りを読みます\n\n'
        '2\n00:00:04,000 --> 00:00:06,000\n次のコーナー\n';
    String file(String rel, [String content = 'x']) {
      final File f = File(p.joinAll(<String>[tmp.path, ...rel.split('/')]))
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
      return f.path;
    }

    // ① 整季生成写在音频旁、state.json 记了哈希；行上没有选择。
    final String a1 = file('cd/drama1.mp3', 'audio-1');
    final String s1 = file('cd/drama1.ja.srt', srt);
    final File state = File(
      p.join(jobs.path, videoSubtitleJobId(a1), 'state.json'),
    )..createSync(recursive: true);
    state.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'exports': <String, String>{
          s1: sha1.convert(utf8.encode(srt)).toString(),
        },
      }),
    );
    // ② 只有本管线会写的 .ja.asr.srt 退路名（任务目录已清掉也认）。
    final String a2 = file('cd/drama2.mp3', 'audio-22');
    file('cd/drama2.ja.asr.srt', srt);
    // ③ 用户选过 app 文档目录里的导入字幕。
    final String a3 = file('cd/drama3.mp3', 'audio-333');
    final String imported = file('docs/subs/drama3.srt', srt);
    // ④ 音频旁的 .ja.srt 不是本管线写的：留给 sidecar 规则，不写行。
    final String a4 = file('cd/drama4.mp3', 'audio-4444');
    file('cd/drama4.ja.srt', srt);

    await video('v/1', a1);
    await video('v/2', a2);
    await repo.saveVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('v/3'),
        title: const Value<String>('drama3'),
        videoPath: Value<String>(a3),
        importedAt: const Value<int>(1),
        subtitleSource: Value<String?>(imported),
      ),
    );
    await video('v/4', a4);
    for (final String a in <String>[a1, a2, a3, a4]) {
      await track(a);
    }
    final MusicLyricsService lyrics = MusicLyricsService(
      database: () => db,
      lrclib: LrclibClient(transport: (Uri _) async => (status: 404, body: '')),
      onlineEnabled: () => false,
      readEmbedded: (String _, int? _) async => const <EmbeddedLyrics>[],
      parse: (List<int> b, String h, int? d) async =>
          FushiLyrics.parse(Uint8List.fromList(b), hint: h, durationMs: d),
    );
    Future<VideoAudioMigrationReport> run() =>
        migrateAudioOnlyVideoBooksToMusic(
          db,
          intake: MusicAudioIntake(
            db,
            fileExists: (_) => true,
            importFile: (String path, {bool recursive = false}) async =>
                fail('already tracked'),
          ),
          fileExists: (String path) => File(path).existsSync(),
          lyrics: lyrics,
          subtitleJobsRoot: jobs,
          importedSubtitlesDir: Directory(p.join(tmp.path, 'docs')),
        );

    final VideoAudioMigrationReport r = await run();
    expect(r.migrated, 4);
    expect(r.subtitlesCarried, 3, reason: '${r.errors}');
    expect(await videoUids(), isEmpty);
    Future<List<(String, bool)>> rowsOf(String audio) async => <(String, bool)>[
      for (final MusicLyricRow l
          in await (db.select(db.musicLyrics)..where(
                ($MusicLyricsTable t) =>
                    t.trackUid.equals('uid:${p.canonicalize(audio)}'),
              ))
              .get())
        (l.source, l.isUserEdited),
    ];
    expect(await rowsOf(a1), <(String, bool)>[(MusicLyricsSource.asr, false)]);
    expect(await rowsOf(a2), <(String, bool)>[(MusicLyricsSource.asr, false)]);
    expect(await rowsOf(a3), <(String, bool)>[(MusicLyricsSource.user, true)]);
    expect(await rowsOf(a4), isEmpty);
  });

  test('no legacy audio rows: nothing is scanned', () async {
    await video('v/ep01', at(<String>['Anime', 'ep01.mkv']));
    final VideoAudioMigrationReport r = await migrateAudioOnlyVideoBooksToMusic(
      db,
      intake: MusicAudioIntake(
        db,
        registerSource:
            ({
              required String rootPath,
              required bool recursive,
              required int ownerSourceId,
            }) async => fail('no audio'),
        importFile: (String path, {bool recursive = false}) async =>
            fail('no audio'),
      ),
      fileExists: (_) => true,
      lyrics: lyricsService(),
      subtitleJobsRoot: jobsDir,
      importedSubtitlesDir: importedDir,
    );
    expect(r.candidates, 0);
    expect(await videoUids(), <String>['v/ep01']);
  });

  test('already in the music library (covered folder): row is removed '
      'after the covering source is rescanned', () async {
    final String song = at(<String>['Music', 'A', '01.flac']);
    final int mid = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Music',
        mediaKind: 'music',
        rootPath: normalizeSourceRootPath(
          at(<String>['Music']),
          transport: 'local',
        ),
        createdAt: 1,
      ),
    );
    await video('v/song', song);
    final List<int> rescanned = <int>[];
    final VideoAudioMigrationReport r = await migrateAudioOnlyVideoBooksToMusic(
      db,
      intake: MusicAudioIntake(
        db,
        fileExists: (_) => true,
        rescanSource: (SourceLibraryRow s) async {
          rescanned.add(s.id);
          await track(song);
          return null;
        },
        importFile: (String path, {bool recursive = false}) async =>
            fail('covered, not imported once'),
      ),
      fileExists: (_) => true,
      lyrics: lyricsService(),
      subtitleJobsRoot: jobsDir,
      importedSubtitlesDir: importedDir,
    );
    expect(rescanned, <int>[mid]);
    expect(r.migrated, 1);
    expect(await videoUids(), isEmpty);
  });

  test('m4b split into chapters: the play event lands on the chapter holding '
      'the breakpoint; ac3 rows move too', () async {
    final String book = at(<String>['Books', 'novel.m4b']);
    final String surround = at(<String>['Books', 'drama.ac3']);
    final String done = at(<String>['Books', 'done.m4b']);
    await video('v/book', book, lastPlayedAt: 100, lastPositionMs: 75000);
    await video('v/ac3', surround, lastPlayedAt: 200, lastPositionMs: 4000);
    await video(
      'v/done',
      done,
      lastPlayedAt: 300,
      lastPositionMs: 0,
      completedAt: DateTime.fromMillisecondsSinceEpoch(400),
    );
    final MusicAudioIntake intake = MusicAudioIntake(
      db,
      fileExists: (_) => true,
      importFile: (String path, {bool recursive = false}) async {
        if (path == book || path == done) {
          final String tag = p.basenameWithoutExtension(path);
          await segment(
            path,
            '$tag-1',
            startMs: 0,
            endMs: 60000,
            durationMs: 60000,
          );
          await segment(
            path,
            '$tag-2',
            startMs: 60000,
            endMs: 90000,
            durationMs: 30000,
          );
          await segment(path, '$tag-3', startMs: 90000, durationMs: 10000);
        } else {
          await track(path, durationMs: 8000);
        }
        return null;
      },
      rescanSource: (SourceLibraryRow s) async => fail('nothing covered'),
    );
    final VideoAudioMigrationReport r = await migrateAudioOnlyVideoBooksToMusic(
      db,
      intake: intake,
      fileExists: (_) => true,
      lyrics: lyricsService(),
      subtitleJobsRoot: jobsDir,
      importedSubtitlesDir: importedDir,
    );
    expect(r.migrated, 3);
    expect(await videoUids(), isEmpty);
    final List<MusicPlayEventRow> events =
        await (db.select(db.musicPlayEvents)
              ..orderBy(<OrderingTerm Function($MusicPlayEventsTable)>[
                ($MusicPlayEventsTable e) =>
                    OrderingTerm(expression: e.startedAt),
              ]))
            .get();
    expect(
      events
          .map((MusicPlayEventRow e) => (e.trackUid, e.listenedMs, e.completed))
          .toList(),
      <(String, int, bool)>[
        // 75 s 落在第 2 章（60–90 s），章内听了 15 s。
        ('novel-2', 15000, false),
        ('uid:${p.canonicalize(surround)}', 4000, false),
        // 看完：最后一章、整章时长。
        ('done-3', 10000, true),
      ],
    );
  });

  test('a picked subtitle that cannot be carried keeps the row only when '
      'deleting it would reclaim the file (imported copy, BUG-4127)', () async {
    const String srt = '1\n00:00:01,000 --> 00:00:02,000\n沈むように\n';
    String file(String path, String content) {
      File(path)
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
      return path;
    }

    final String a = file(p.join(scratch.path, 'cd', 'a.mp3'), 'a');
    final String b = file(p.join(scratch.path, 'cd', 'b.mp3'), 'bb');
    final String c = file(p.join(scratch.path, 'cd', 'c.mp3'), 'ccc');
    // a：导入副本、能解析 → 手动指定，行照常删。
    final String subA = file(p.join(importedDir.path, 'speech-a.srt'), srt);
    // b：导入副本、解析不出 → 删行会回收它，这次不删。
    final String subB = file(p.join(importedDir.path, 'speech-b.srt'), '');
    // c：别处的文件、解析不出 → 删行不碰它，照常迁移、记一条错误。
    final String subC = file(p.join(scratch.path, 'mine', 'c.srt'), '');
    await video('v/a', a, subtitleSource: subA);
    await video('v/b', b, subtitleSource: subB);
    await video('v/c', c, subtitleSource: subC);
    for (final String x in <String>[a, b, c]) {
      await track(x);
    }
    final VideoAudioMigrationReport r = await migrateAudioOnlyVideoBooksToMusic(
      db,
      intake: MusicAudioIntake(
        db,
        fileExists: (_) => true,
        importFile: (String path, {bool recursive = false}) async =>
            fail('already tracked'),
      ),
      fileExists: (String path) => File(path).existsSync(),
      lyrics: lyricsService(),
      subtitleJobsRoot: jobsDir,
      importedSubtitlesDir: importedDir,
    );
    expect(r.migrated, 2);
    expect(r.subtitlesCarried, 1);
    expect(await videoUids(), <String>['v/b']);
    expect(r.errors, hasLength(2));
    expect(r.errors.where((String e) => e.contains(subB)), hasLength(1));
    expect(r.errors.where((String e) => e.contains(subC)), hasLength(1));
    final List<MusicLyricRow> rows = await db.select(db.musicLyrics).get();
    expect(
      rows.map((MusicLyricRow l) => (l.trackUid, l.source)).toList(),
      <(String, String)>[('uid:${p.canonicalize(a)}', MusicLyricsSource.user)],
    );
  });

  test('a picked whole-file subtitle on a flac + cue disc is sliced into '
      'each track (track-relative times); a track already chosen in the '
      'music library is not overwritten', () async {
    final String disc = p.join(scratch.path, 'cd', 'disc.flac');
    File(disc)
      ..createSync(recursive: true)
      ..writeAsStringSync('disc');
    final String sub = p.join(importedDir.path, 'disc.srt');
    File(sub)
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '1\n00:00:01,000 --> 00:00:02,000\n一曲目\n\n'
        '2\n00:01:05,000 --> 00:01:06,000\n二曲目\n\n'
        '3\n00:02:05,000 --> 00:02:06,000\n三曲目\n',
      );
    await video('v/disc', disc, subtitleSource: sub);
    Future<void> cue(String uid, int start, int? end) => db
        .into(db.musicTracks)
        .insert(
          MusicTracksCompanion.insert(
            trackUid: uid,
            path: normalizeSourceRootPath(disc, transport: 'local'),
            title: uid,
            cueStartMs: Value<int?>(start),
            cueEndMs: Value<int?>(end),
            fileMtimeAt: 1,
            fileSize: 1,
            addedAt: 1,
          ),
        );
    await cue('t1', 0, 60000);
    await cue('t2', 60000, 120000);
    await cue('t3', 120000, null);
    final MusicLyricsService lyrics = lyricsService();
    // t3 用户在音乐库里已经选过歌词。
    await lyrics.choose(
      't3',
      MusicLyricsCandidate(
        source: MusicLyricsSource.user,
        label: 'mine.lrc',
        format: 'lrc',
        raw: Uint8List.fromList(utf8.encode('[00:01.00]自分の')),
        timeline: FushiLyrics.parse(
          Uint8List.fromList(utf8.encode('[00:01.00]自分の')),
          hint: 'lrc',
        ),
      ),
    );
    final VideoAudioMigrationReport r = await migrateAudioOnlyVideoBooksToMusic(
      db,
      intake: MusicAudioIntake(
        db,
        fileExists: (_) => true,
        importFile: (String path, {bool recursive = false}) async =>
            fail('already tracked'),
      ),
      fileExists: (String path) => File(path).existsSync(),
      lyrics: lyrics,
      subtitleJobsRoot: jobsDir,
      importedSubtitlesDir: importedDir,
    );
    expect(r.migrated, 1, reason: '${r.errors}');
    expect(r.subtitlesCarried, 2);
    Future<List<(int, String)>> linesOf(String uid) async {
      final MusicLyricRow row =
          await (db.select(db.musicLyrics)
                ..where(($MusicLyricsTable l) => l.trackUid.equals(uid))
                ..where(
                  ($MusicLyricsTable l) =>
                      l.source.equals(MusicLyricsSource.user),
                ))
              .getSingle();
      return <(int, String)>[
        for (final LyricLine l in decodeLyricTimeline(row.timelineCache!).lines)
          (l.startMs, l.text),
      ];
    }

    expect(await linesOf('t1'), <(int, String)>[(1000, '一曲目')]);
    expect(await linesOf('t2'), <(int, String)>[(5000, '二曲目')]);
    expect(await linesOf('t3'), <(int, String)>[(1000, '自分の')]);
  });

  group('pickMigratedTrack', () {
    MusicTrackRow seg(String uid, int? start, int? duration) => MusicTrackRow(
      trackUid: uid,
      path: '/a.m4b',
      cueStartMs: start,
      durationMs: duration,
      title: uid,
      isLossless: false,
      fileMtimeAt: 1,
      fileSize: 1,
      hasEmbeddedCover: false,
      addedAt: 1,
    );
    final List<MusicTrackRow> book = <MusicTrackRow>[
      seg('c1', 0, 1000),
      seg('c2', 1000, 2000),
      seg('c3', 3000, null),
    ];

    test('breakpoint at a chapter boundary belongs to the later chapter', () {
      final MigratedTrack t = pickMigratedTrack(
        book,
        positionMs: 1000,
        completed: false,
      );
      expect((t.track.trackUid, t.listenedMs), ('c2', 0));
    });
    test('no breakpoint: first chapter, nothing listened', () {
      final MigratedTrack t = pickMigratedTrack(
        book,
        positionMs: 0,
        completed: false,
      );
      expect((t.track.trackUid, t.listenedMs), ('c1', 0));
    });
    test('breakpoint past the end clamps to the last known length', () {
      final MigratedTrack t = pickMigratedTrack(
        <MusicTrackRow>[seg('c1', 0, 1000), seg('c2', 1000, 500)],
        positionMs: 9000,
        completed: false,
      );
      expect((t.track.trackUid, t.listenedMs), ('c2', 500));
    });
    test('completed with unknown last length falls back to the breakpoint', () {
      final MigratedTrack t = pickMigratedTrack(
        book,
        positionMs: 3500,
        completed: true,
      );
      expect((t.track.trackUid, t.listenedMs), ('c3', 500));
    });
    test('a whole-file track (no cue start) is the only candidate', () {
      final MigratedTrack t = pickMigratedTrack(
        <MusicTrackRow>[seg('x', null, 4000)],
        positionMs: 2500,
        completed: false,
      );
      expect((t.track.trackUid, t.listenedMs), ('x', 2500));
    });
  });
}
