// 反馈 QAondMh4M5：旧版按「无画面视频」入库的纯音频搬到音乐库（幂等、先入库后删行）。
import 'dart:convert';

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

  /// 音乐扫描替身：把路径写成在库曲目（Rust 拼法：正斜杠根 + 平台分隔符）。
  Future<void> track(String path, {int? durationMs}) => db
      .into(db.musicTracks)
      .insert(
        MusicTracksCompanion.insert(
          trackUid: 'uid:${p.canonicalize(path)}',
          path: normalizeSourceRootPath(path, transport: 'local'),
          title: p.basenameWithoutExtension(path),
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

    // 第二次：搬过的行已删，只剩搬不动的 .m4b 再试一次，播放记录不重复。
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
        importFile: (String path) async => fail('covered, not imported once'),
      ),
      fileExists: (_) => true,
      adoptSubtitle: noSubtitle,
    );
    expect(rescanned, <int>[mid]);
    expect(r.migrated, 1);
    expect(await videoUids(), isEmpty);
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
      importFile: (String path) async {
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

  group('network video sources (SFTP / WebDAV / AList)', () {
    Future<int> source(
      String kind,
      String transport,
      String rootPath, {
      Map<String, Object?> config = const <String, Object?>{},
    }) => db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: rootPath,
        mediaKind: kind,
        transport: Value<String>(transport),
        rootPath: rootPath,
        configJson: Value<String?>(jsonEncode(config)),
        createdAt: 1,
      ),
    );

    /// 远程音乐扫描替身：条目地址原样落库（网络来源曲目带 sourceId）。
    Future<void> remoteTrack(String url, int sourceId, {int? durationMs}) => db
        .into(db.musicTracks)
        .insert(
          MusicTracksCompanion.insert(
            trackUid: 'uid:$url',
            path: url,
            title: p.url.basenameWithoutExtension(url),
            sourceId: Value<int?>(sourceId),
            durationMs: Value<int?>(durationMs),
            fileMtimeAt: 1,
            fileSize: 1,
            addedAt: 1,
          ),
        );

    test('SFTP rows register a same-server music source; deleted only once '
        'the exact sftp:// address is a live track; play history carried; '
        'audio beside a video stays', () async {
      const String ns = 'sftp://nas:22';
      final int vid = await source(
        'video',
        'sftp',
        '/srv/v',
        config: <String, Object?>{'host': 'nas', 'port': 22, 'username': 'u'},
      );
      await video(
        'v/drama',
        '$ns/srv/v/Drama CD/Disc 1/01.flac',
        sourceId: vid,
        lastPlayedAt: 5000,
        lastPositionMs: 1234,
      );
      // 大小写不同的地址不是同一个文件：不能拿它当已入库。
      await video('v/case', '$ns/srv/v/Drama CD/Disc 1/02.flac', sourceId: vid);
      await video('v/ep', '$ns/srv/v/Show/ep01.mkv', sourceId: vid);
      await video('v/beside', '$ns/srv/v/Show/ep01.flac', sourceId: vid);
      final List<({String rootPath, bool recursive})> registered =
          <({String rootPath, bool recursive})>[];
      final VideoAudioMigrationReport r =
          await migrateAudioOnlyVideoBooksToMusic(
            db,
            intake: MusicAudioIntake(
              db,
              fileExists: (_) => fail('remote rows never touch the local disk'),
              registerRemoteSource:
                  ({
                    required SourceLibraryRow videoSource,
                    required String rootPath,
                    required bool recursive,
                  }) async {
                    expect(videoSource.id, vid);
                    registered.add((rootPath: rootPath, recursive: recursive));
                    final int mid = await source(
                      'music',
                      'sftp',
                      rootPath,
                      config: <String, Object?>{
                        'host': 'nas',
                        'port': 22,
                        'username': 'u',
                      },
                    );
                    await remoteTrack('$ns/srv/v/Drama CD/Disc 1/01.flac', mid);
                    await remoteTrack('$ns/srv/v/Drama CD/Disc 1/02.FLAC', mid);
                    return null;
                  },
              importFile: (String path) async =>
                  fail('no one-off remote import'),
            ),
            fileExists: (_) => false,
            adoptSubtitle: noSubtitle,
          );
      expect(registered, <({String rootPath, bool recursive})>[
        (rootPath: '/srv/v/Drama CD', recursive: true),
      ]);
      expect(r.candidates, 3);
      expect(r.migrated, 1);
      expect(r.playEventsWritten, 1);
      expect(await videoUids(), <String>['v/beside', 'v/case', 'v/ep']);
      final MusicPlayEventRow ev =
          (await db.select(db.musicPlayEvents).get()).single;
      expect(ev.trackUid, 'uid:$ns/srv/v/Drama CD/Disc 1/01.flac');
      expect(ev.startedAt, 5000);
      expect(ev.listenedMs, 1234);
    });

    test('WebDAV rows already covered by a same-server music source rescan '
        'that source, then move', () async {
      const String v = 'https://dav.test/v';
      final int vid = await source(
        'video',
        'webdav',
        v,
        config: <String, Object?>{'username': 'u'},
      );
      final int mid = await source(
        'music',
        'webdav',
        '$v/Music',
        config: <String, Object?>{'username': 'u'},
      );
      await video('v/song', '$v/Music/A/01.mp3', sourceId: vid);
      final List<int> rescanned = <int>[];
      final VideoAudioMigrationReport r =
          await migrateAudioOnlyVideoBooksToMusic(
            db,
            intake: MusicAudioIntake(
              db,
              rescanSource: (SourceLibraryRow s) async {
                rescanned.add(s.id);
                await remoteTrack('$v/Music/A/01.mp3', mid);
                return null;
              },
              registerRemoteSource:
                  ({
                    required SourceLibraryRow videoSource,
                    required String rootPath,
                    required bool recursive,
                  }) async => fail('covered, nothing registered'),
            ),
            fileExists: (_) => false,
            adoptSubtitle: noSubtitle,
          );
      expect(rescanned, <int>[mid]);
      expect(r.migrated, 1);
      expect(await videoUids(), isEmpty);
    });

    test('a failed remote scan keeps the rows (retried next launch)', () async {
      const String v = 'https://dav.test/v';
      final int vid = await source(
        'video',
        'webdav',
        v,
        config: <String, Object?>{'username': 'u'},
      );
      await video('v/song', '$v/OST/01.mp3', sourceId: vid);
      final VideoAudioMigrationReport r =
          await migrateAudioOnlyVideoBooksToMusic(
            db,
            intake: MusicAudioIntake(
              db,
              registerRemoteSource:
                  ({
                    required SourceLibraryRow videoSource,
                    required String rootPath,
                    required bool recursive,
                  }) async => 'connection refused',
            ),
            fileExists: (_) => false,
            adoptSubtitle: noSubtitle,
          );
      expect(r.migrated, 0);
      expect(r.errors.single, contains('connection refused'));
      expect(await videoUids(), <String>['v/song']);
    });
  });
}
