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
        );
    expect(second.candidates, 1);
    expect(second.migrated, 0);
    expect(imported, <String>[broken]);
    expect(await db.select(db.musicPlayEvents).get(), hasLength(2));
  });

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
            importFile: (String path) async => fail('already tracked'),
          ),
          fileExists: (String path) => File(path).existsSync(),
          lyrics: lyrics,
          subtitleJobsRoot: jobs,
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
