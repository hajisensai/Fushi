// 反馈 QAondMh4M5：视频侧收到的纯音频交给音乐库（登记来源 / 仅此一次导入 / 重扫覆盖来源），
// 自动登记的音乐来源记下 owner、按正面证据对账撤销、尊重「不再登记」。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_audio_intake.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/music_audio_roots.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:path/path.dart' as p;

void main() {
  late FushiDatabase db;
  final String root = p.join(p.rootPrefix(p.current), 'media');
  String at(List<String> parts) => p.joinAll(<String>[root, ...parts]);
  String norm(String path) => normalizeSourceRootPath(path, transport: 'local');

  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> addMusicSource(String rootPath, {bool recursive = true}) =>
      db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'Music',
          mediaKind: 'music',
          // 与生产一致：本地来源根按正斜杠归一（Windows 上与文件路径的反斜杠混用）。
          rootPath: norm(rootPath),
          recursive: Value<bool>(recursive),
          createdAt: 1,
        ),
      );

  Future<SourceLibraryRow> addVideoSource(String rootPath) async {
    final int id = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Anime',
        mediaKind: 'video',
        rootPath: norm(rootPath),
        createdAt: 1,
      ),
    );
    return (await db.getMediaSourceById(id))!;
  }

  /// 登记替身：像真 app 一样插一行带 owner 的音乐来源（不扫描）。
  MusicSourceRegistrar dbRegistrar(List<PlannedMusicRoot> log) =>
      ({
        required String rootPath,
        required bool recursive,
        required int ownerSourceId,
      }) async {
        log.add((rootPath: rootPath, recursive: recursive));
        await db.insertMediaSource(
          MediaSourcesCompanion.insert(
            label: 'auto',
            mediaKind: 'music',
            rootPath: norm(rootPath),
            recursive: Value<bool>(recursive),
            createdAt: 1,
            autoOwnerSourceId: Value<int?>(ownerSourceId),
          ),
        );
        return null;
      };

  group('adoptVideoSourceAudio', () {
    test('registers the planned roots with their owner; already-covered '
        'folders are left to the existing music source; a second scan does '
        'not register again', () async {
      await addMusicSource(at(<String>['Anime', 'Show', 'CDs']));
      final SourceLibraryRow owner = await addVideoSource(
        at(<String>['Anime']),
      );
      final List<PlannedMusicRoot> registered = <PlannedMusicRoot>[];
      final MusicAudioIntake intake = MusicAudioIntake(
        db,
        registerSource: dbRegistrar(registered),
        dirExists: (_) => true,
      );

      final MusicAudioIntakeResult r = await intake.adoptVideoSourceAudio(
        owner: owner,
        audioPaths: <String>[
          at(<String>['Anime', 'Show', 'CDs', 'OST', '01.flac']),
          at(<String>['Anime', 'Drama', 'Disc1', '01.mp3']),
          at(<String>['Anime', 'Show', 'ep01.flac']),
          at(<String>['Anime', 'Show', 'ep01.mkv']),
        ],
        videoMediaDirs: <String>[
          at(<String>['Anime', 'Show']),
        ],
      );

      expect(registered, <PlannedMusicRoot>[
        (rootPath: at(<String>['Anime', 'Drama']), recursive: true),
      ]);
      expect(r.skippedPaths, <String>[
        at(<String>['Anime', 'Show', 'ep01.flac']),
      ]);
      expect(r.errors, isEmpty);
      expect(
        (await db.listAutoMusicSourcesOf(owner.id)).single.rootPath,
        norm(at(<String>['Anime', 'Drama'])),
      );

      registered.clear();
      final MusicAudioIntakeResult again = await intake.adoptVideoSourceAudio(
        owner: owner,
        audioPaths: <String>[
          at(<String>['Anime', 'Drama', 'Disc1', '01.mp3']),
        ],
        videoMediaDirs: <String>[
          at(<String>['Anime', 'Show']),
        ],
        reconcile: true,
      );
      expect(registered, isEmpty);
      expect(again.retiredSourceIds, isEmpty);
      expect(await db.listAutoMusicSourcesOf(owner.id), hasLength(1));
    });

    test('scan errors are reported per root', () async {
      final SourceLibraryRow owner = await addVideoSource(
        at(<String>['Anime']),
      );
      final MusicAudioIntake intake = MusicAudioIntake(
        db,
        registerSource:
            ({
              required String rootPath,
              required bool recursive,
              required int ownerSourceId,
            }) async => 'unreadable',
      );
      final MusicAudioIntakeResult r = await intake.adoptVideoSourceAudio(
        owner: owner,
        audioPaths: <String>[
          at(<String>['Anime', 'A', '01.flac']),
        ],
        videoMediaDirs: const <String>[],
      );
      expect(r.errors.single, contains('unreadable'));
    });

    group('reconcile (complete scans only, positive evidence only)', () {
      late SourceLibraryRow owner;
      late Set<String> dirs;
      late List<Set<int>> retired;
      late MusicAudioIntake intake;
      final String drama = at(<String>['Anime', 'Drama']);
      final String dramaAudio = at(<String>[
        'Anime',
        'Drama',
        'Disc1',
        '01.mp3',
      ]);

      setUp(() async {
        owner = await addVideoSource(at(<String>['Anime']));
        dirs = <String>{drama};
        retired = <Set<int>>[];
        intake = MusicAudioIntake(
          db,
          registerSource: dbRegistrar(<PlannedMusicRoot>[]),
          dirExists: (String d) => dirs.any(
            (String x) =>
                p.equals(x, d) || p.isWithin(x, d) || p.isWithin(d, x),
          ),
          retireSources: (Set<int> ids) async {
            if (ids.isNotEmpty) retired.add(ids);
          },
        );
        await intake.adoptVideoSourceAudio(
          owner: owner,
          audioPaths: <String>[dramaAudio],
          videoMediaDirs: <String>[
            at(<String>['Anime', 'Show']),
          ],
          reconcile: true,
        );
        expect(
          (await db.listAutoMusicSourcesOf(owner.id)).single.rootPath,
          norm(drama),
        );
      });

      Future<int> autoId() async =>
          (await db.listAutoMusicSourcesOf(owner.id)).single.id;

      test('the last audio folder was deleted: retired even though this '
          'scan found no audio at all', () async {
        final int id = await autoId();
        dirs.clear();
        final MusicAudioIntakeResult r = await intake.adoptVideoSourceAudio(
          owner: owner,
          audioPaths: const <String>[],
          videoMediaDirs: const <String>[],
          reconcile: true,
        );
        expect(retired, <Set<int>>[
          <int>{id},
        ]);
        expect(r.retiredSourceIds, <int, OwnedMusicRootRetireReason>{
          id: OwnedMusicRootRetireReason.missing,
        });
      });

      test('a video now sits directly in the folder: retired', () async {
        final int id = await autoId();
        await intake.adoptVideoSourceAudio(
          owner: owner,
          audioPaths: <String>[dramaAudio],
          videoMediaDirs: <String>[drama],
          reconcile: true,
        );
        expect(retired, <Set<int>>[
          <int>{id},
        ]);
        // 视频旁的 Drama 撤掉，下层 Disc1 另行登记（不随 Drama 一起撤）。
        expect(
          (await db.listAutoMusicSourcesOf(
            owner.id,
          )).map((SourceLibraryRow s) => s.rootPath),
          contains(norm(at(<String>['Anime', 'Drama', 'Disc1']))),
        );
      });

      test('the user added a covering music source: retired', () async {
        final int id = await autoId();
        await addMusicSource(at(<String>['Anime']));
        await intake.adoptVideoSourceAudio(
          owner: owner,
          audioPaths: <String>[dramaAudio],
          videoMediaDirs: const <String>[],
          reconcile: true,
        );
        expect(retired, <Set<int>>[
          <int>{id},
        ]);
      });

      test('folder still there but missing from this listing: kept', () async {
        await intake.adoptVideoSourceAudio(
          owner: owner,
          audioPaths: const <String>[],
          videoMediaDirs: const <String>[],
          reconcile: true,
        );
        expect(retired, isEmpty);
        expect(await db.listAutoMusicSourcesOf(owner.id), hasLength(1));
      });

      test('partial scan (reconcile off): nothing retired even if the folder '
          'looks gone', () async {
        dirs.clear();
        await intake.adoptVideoSourceAudio(
          owner: owner,
          audioPaths: const <String>[],
          videoMediaDirs: const <String>[],
        );
        expect(retired, isEmpty);
      });
    });

    test('a folder the user dismissed is not registered again', () async {
      final SourceLibraryRow owner = await addVideoSource(
        at(<String>['Anime']),
      );
      await db.addMusicAutoSourceDismissal(
        owner.id,
        norm(at(<String>['Anime', 'Drama'])),
      );
      final List<PlannedMusicRoot> registered = <PlannedMusicRoot>[];
      await MusicAudioIntake(
        db,
        registerSource: dbRegistrar(registered),
        dirExists: (_) => true,
      ).adoptVideoSourceAudio(
        owner: owner,
        audioPaths: <String>[
          at(<String>['Anime', 'Drama', 'Disc1', '01.mp3']),
        ],
        videoMediaDirs: const <String>[],
        reconcile: true,
      );
      expect(registered, isEmpty);
    });

    test('one-shot video import: planned roots are imported once, no '
        'resident music source is left behind', () async {
      final SourceLibraryRow owner = await addVideoSource(
        at(<String>['Anime']),
      );
      final List<(String, bool)> imported = <(String, bool)>[];
      await MusicAudioIntake(
        db,
        registerSource:
            ({
              required String rootPath,
              required bool recursive,
              required int ownerSourceId,
            }) async => fail('one-shot must not register'),
        importFile: (String path, {bool recursive = false}) async {
          imported.add((path, recursive));
          return null;
        },
      ).adoptVideoSourceAudio(
        owner: owner,
        audioPaths: <String>[
          at(<String>['Anime', 'Drama', 'Disc1', '01.mp3']),
        ],
        // 视频根下另有视频：规划停在 Drama，不把整个视频根当音乐来源。
        videoMediaDirs: <String>[
          at(<String>['Anime', 'Show']),
        ],
        oneShot: true,
        reconcile: true,
      );
      expect(imported, <(String, bool)>[
        (at(<String>['Anime', 'Drama']), true),
      ]);
      expect(await db.listAutoMusicSourcesOf(owner.id), isEmpty);
    });
  });

  group('importAudioFiles', () {
    test('covered files rescan their music source once; the rest import '
        'one file at a time; non-audio / missing are skipped', () async {
      final int sid = await addMusicSource(at(<String>['Music']));
      final List<int> rescanned = <int>[];
      final List<String> imported = <String>[];
      final Set<String> existing = <String>{
        at(<String>['Music', 'A', '01.flac']),
        at(<String>['Music', 'A', '02.flac']),
        at(<String>['Downloads', 'drama.mp3']),
        at(<String>['Downloads', 'ep01.mkv']),
      };
      final MusicAudioIntake intake = MusicAudioIntake(
        db,
        fileExists: existing.contains,
        rescanSource: (SourceLibraryRow s) async {
          rescanned.add(s.id);
          return null;
        },
        importFile: (String path, {bool recursive = false}) async {
          imported.add(path);
          return null;
        },
      );

      final MusicAudioIntakeResult r = await intake.importAudioFiles(<String>[
        at(<String>['Music', 'A', '01.flac']),
        at(<String>['Music', 'A', '02.flac']),
        at(<String>['Downloads', 'drama.mp3']),
        at(<String>['Downloads', 'ep01.mkv']),
        at(<String>['Gone', 'x.flac']),
      ]);

      expect(rescanned, <int>[sid]);
      expect(imported, <String>[
        at(<String>['Downloads', 'drama.mp3']),
      ]);
      expect(r.skippedPaths, <String>[
        at(<String>['Downloads', 'ep01.mkv']),
        at(<String>['Gone', 'x.flac']),
      ]);
      expect(r.handedOver, isTrue);
    });

    test('a non-recursive music source covers only its own folder', () async {
      await addMusicSource(at(<String>['Music']), recursive: false);
      final List<String> imported = <String>[];
      final MusicAudioIntake intake = MusicAudioIntake(
        db,
        fileExists: (_) => true,
        rescanSource: (SourceLibraryRow s) async =>
            fail('subfolder is not covered'),
        importFile: (String path, {bool recursive = false}) async {
          imported.add(path);
          return null;
        },
      );
      await intake.importAudioFiles(<String>[
        at(<String>['Music', 'Sub', '01.flac']),
      ]);
      expect(imported, <String>[
        at(<String>['Music', 'Sub', '01.flac']),
      ]);
    });
  });
}
