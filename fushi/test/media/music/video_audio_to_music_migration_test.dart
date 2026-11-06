// 反馈 QAondMh4M5：旧版按「无画面视频」入库的纯音频搬到音乐库（幂等、先入库后删行）。
import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_audio_intake.dart';
import 'package:fushi/src/media/music/video_audio_to_music_migration.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:path/path.dart' as p;

void main() {
  late FushiDatabase db;
  late VideoBookRepository repo;
  final String root = p.join(p.rootPrefix(p.current), 'media');
  String at(List<String> parts) => p.joinAll(<String>[root, ...parts]);

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = VideoBookRepository(db);
  });
  tearDown(() => db.close());

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

  Future<void> noSubtitle(MusicTrackRow t, String path) async =>
      fail('no subtitle expected: $path');

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
          adoptSubtitle: noSubtitle,
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
          adoptSubtitle: noSubtitle,
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
      adoptSubtitle: noSubtitle,
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

  test('a subtitle on a flac + cue disc goes to the first track (its '
      'timeline starts at the file head)', () async {
    final String disc = at(<String>['Drama', 'disc1.flac']);
    final String sub = at(<String>['app', 'video_subtitles', 'disc1.srt']);
    await video('v/disc', disc, subtitleSource: sub, lastPositionMs: 2100000);
    final List<String> adoptedUids = <String>[];
    final MusicAudioIntake intake = MusicAudioIntake(
      db,
      fileExists: (_) => true,
      importFile: (String path, {bool recursive = false}) async {
        // 故意倒序落库：挂哪一首不能依赖插入顺序。
        await track(disc, durationMs: 1800000, cueStartMs: 1200000);
        await track(disc, durationMs: 1200000, cueStartMs: 0);
        return null;
      },
    );
    final VideoAudioMigrationReport r = await migrateAudioOnlyVideoBooksToMusic(
      db,
      intake: intake,
      fileExists: (_) => true,
      adoptSubtitle: (MusicTrackRow t, String path) async =>
          adoptedUids.add(t.trackUid),
    );
    expect(r.migrated, 1);
    expect(adoptedUids, <String>['uid:${p.canonicalize(disc)}#0']);
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
      adoptSubtitle: noSubtitle,
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
      adoptSubtitle: noSubtitle,
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
      adoptSubtitle: noSubtitle,
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

  test('attached subtitle (ASR transcript) is carried to the music lyrics '
      'before the row is deleted; a subtitle that cannot be carried keeps '
      'the row', () async {
    final String a = at(<String>['Drama', 'a.mp3']);
    final String b = at(<String>['Drama', 'b.mp3']);
    final String subA = at(<String>['app', 'video_subtitles', 'speech-a.srt']);
    final String subB = at(<String>['app', 'video_subtitles', 'speech-b.srt']);
    await video('v/a', a, subtitleSource: subA);
    await video('v/b', b, subtitleSource: subB);
    final List<(String, String)> adopted = <(String, String)>[];
    Future<void> adopt(MusicTrackRow t, String path) async {
      if (path == subB) throw StateError('parse failed');
      adopted.add((t.path, path));
    }

    final MusicAudioIntake intake = MusicAudioIntake(
      db,
      fileExists: (_) => true,
      importFile: (String path, {bool recursive = false}) async {
        await track(path);
        return null;
      },
    );
    final VideoAudioMigrationReport r = await migrateAudioOnlyVideoBooksToMusic(
      db,
      intake: intake,
      fileExists: (_) => true,
      adoptSubtitle: adopt,
    );
    expect(adopted.map(((String, String) e) => e.$2), <String>[subA]);
    expect(r.migrated, 1);
    expect(r.errors.single, contains(subB));
    expect(await videoUids(), <String>['v/b']);
  });

  test('a subtitle on a file split into chapters goes to the first chapter '
      '(its timeline starts at the file head)', () async {
    final String book = at(<String>['Books', 'novel.m4b']);
    final String sub = at(<String>['app', 'video_subtitles', 'novel.srt']);
    await video('v/book', book, subtitleSource: sub, lastPositionMs: 75000);
    final List<String> adoptedUids = <String>[];
    final MusicAudioIntake intake = MusicAudioIntake(
      db,
      fileExists: (_) => true,
      importFile: (String path, {bool recursive = false}) async {
        // 故意倒序落库：挂哪一首不能依赖插入顺序。
        await segment(path, 'novel-2', startMs: 60000, durationMs: 30000);
        await segment(
          path,
          'novel-1',
          startMs: 0,
          endMs: 60000,
          durationMs: 60000,
        );
        return null;
      },
    );
    final VideoAudioMigrationReport r = await migrateAudioOnlyVideoBooksToMusic(
      db,
      intake: intake,
      fileExists: (_) => true,
      adoptSubtitle: (MusicTrackRow t, String path) async =>
          adoptedUids.add(t.trackUid),
    );
    expect(r.migrated, 1);
    expect(adoptedUids, <String>['novel-1']);
    expect(await videoUids(), isEmpty);
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
