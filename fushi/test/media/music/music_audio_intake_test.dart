// 反馈 QAondMh4M5：视频侧收到的纯音频交给音乐库（登记来源 / 仅此一次导入 / 重扫覆盖来源）。
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

  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> addMusicSource(String rootPath, {bool recursive = true}) =>
      db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'Music',
          mediaKind: 'music',
          // 与生产一致：本地来源根按正斜杠归一（Windows 上与文件路径的反斜杠混用）。
          rootPath: normalizeSourceRootPath(rootPath, transport: 'local'),
          recursive: Value<bool>(recursive),
          createdAt: 1,
        ),
      );

  group('adoptVideoSourceAudio', () {
    test('registers the planned roots; already-covered folders are left '
        'to the existing music source', () async {
      await addMusicSource(at(<String>['Anime', 'Show', 'CDs']));
      final List<PlannedMusicRoot> registered = <PlannedMusicRoot>[];
      final MusicAudioIntake intake = MusicAudioIntake(
        db,
        registerSource:
            ({required String rootPath, required bool recursive}) async {
              registered.add((rootPath: rootPath, recursive: recursive));
              return null;
            },
      );

      final MusicAudioIntakeResult r = await intake.adoptVideoSourceAudio(
        videoRoot: at(<String>['Anime']),
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
    });

    test('scan errors are reported per root', () async {
      final MusicAudioIntake intake = MusicAudioIntake(
        db,
        registerSource:
            ({required String rootPath, required bool recursive}) async =>
                'unreadable',
      );
      final MusicAudioIntakeResult r = await intake.adoptVideoSourceAudio(
        videoRoot: at(<String>['Anime']),
        audioPaths: <String>[
          at(<String>['Anime', 'A', '01.flac']),
        ],
        videoMediaDirs: const <String>[],
      );
      expect(r.errors.single, contains('unreadable'));
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
        importFile: (String path) async {
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
        importFile: (String path) async {
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
