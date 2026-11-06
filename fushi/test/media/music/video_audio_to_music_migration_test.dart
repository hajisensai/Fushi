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
    ),
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
          ({required String rootPath, required bool recursive}) async {
            registered.add((rootPath: rootPath, recursive: recursive));
            await track(ost, durationMs: 9000);
            return null;
          },
      importFile: (String path) async {
        imported.add(path);
        // 曲库不认 .m4b：扫描不出曲目，行必须留在视频库。
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

    // 第二次：搬过的行已删，只剩搬不动的 .m4b 再试一次，播放记录不重复。
    imported.clear();
    final VideoAudioMigrationReport second =
        await migrateAudioOnlyVideoBooksToMusic(
          db,
          intake: intake,
          fileExists: (String path) => !path.contains('Gone'),
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
      importFile: (String path) async {
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

  test('musicTrackAtFilePosition picks the track the position falls in', () {
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
    final List<MusicTrackRow> tracks = <MusicTrackRow>[t(0), t(1000), t(5000)];
    expect(musicTrackAtFilePosition(tracks, 0).track.trackUid, 't0');
    expect(musicTrackAtFilePosition(tracks, 999).relativeMs, 999);
    expect(musicTrackAtFilePosition(tracks, 1000).track.trackUid, 't1000');
    expect(musicTrackAtFilePosition(tracks, 1000).relativeMs, 0);
    expect(musicTrackAtFilePosition(tracks, 7000).track.trackUid, 't5000');
    expect(musicTrackAtFilePosition(tracks, 7000).relativeMs, 2000);
  });

  test('no legacy audio rows: nothing is scanned', () async {
    await video('v/ep01', at(<String>['Anime', 'ep01.mkv']));
    final VideoAudioMigrationReport r = await migrateAudioOnlyVideoBooksToMusic(
      db,
      intake: MusicAudioIntake(
        db,
        registerSource:
            ({required String rootPath, required bool recursive}) async =>
                fail('no audio'),
        importFile: (String path) async => fail('no audio'),
      ),
      fileExists: (_) => true,
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
        importFile: (String path) async => fail('covered, not imported once'),
      ),
      fileExists: (_) => true,
    );
    expect(rescanned, <int>[mid]);
    expect(r.migrated, 1);
    expect(await videoUids(), isEmpty);
  });
}
