import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audio_cd/audio_cd_import.dart';
import 'package:fushi/src/media/source_library/add_local_folder_source.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/audio_cd/audio_cd_disc.dart';
import 'package:fushi_engine/media/audio_cd/audio_cd_ripper.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

/// BUG-3312：音频 CD 在 Windows 上只露出 `TrackNN.cda` 快捷方式，在 macOS 上挂载成
/// 拔盘即消失的 `.aiff`。导入入口先经 [importAudioCdIfPresent] 认出它、抓成 FLAC。

/// 假 ffmpeg：把输入原样拷到最后一个参数（输出路径），记下每次调用的参数。
class _FakeFfmpeg implements FfmpegBackend {
  _FakeFfmpeg({this.exitCode = 0});

  final int exitCode;
  final List<List<String>> calls = <List<String>>[];

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    calls.add(args);
    if (exitCode == 0) {
      File(
        args.last,
      ).writeAsBytesSync(File(args[args.indexOf('-i') + 1]).readAsBytesSync());
    } else {
      File(args.last).writeAsBytesSync(const <int>[1]); // 失败也可能留下半截
    }
    return FfmpegRunResult(returnCode: exitCode, output: 'boom\nlast line');
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      throw UnimplementedError();

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      throw UnimplementedError();
}

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('audio_cd_import_'));
  tearDown(() => root.deleteSync(recursive: true));

  Directory dirWith(String name, List<String> files) {
    final Directory d = Directory(p.join(root.path, name))..createSync();
    for (final String f in files) {
      File(p.join(d.path, f)).writeAsBytesSync(const <int>[0]);
    }
    return d;
  }

  group('audioCdLayoutOfDirectory', () {
    test('Windows .cda shortcuts and the macOS cddafs mount are audio CDs', () {
      expect(
        audioCdLayoutOfDirectory(
          dirWith('cd', <String>['Track01.cda', 'Track02.cda']).path,
        ),
        AudioCdLayout.windowsCda,
      );
      expect(
        audioCdLayoutOfDirectory(
          dirWith('mac', <String>['.TOC.plist', '1 Audio Track.aiff']).path,
        ),
        AudioCdLayout.macCddafs,
      );
    });

    test('real media next to .cda keeps the normal import', () {
      expect(
        audioCdLayoutOfDirectory(
          dirWith('mixed', <String>['Track01.cda', '01.flac']).path,
        ),
        isNull,
      );
      expect(
        audioCdLayoutOfDirectory(dirWith('music', <String>['01.mp3']).path),
        isNull,
      );
      expect(
        audioCdLayoutOfDirectory(dirWith('empty', <String>[]).path),
        isNull,
      );
    });

    test('only direct children count, and unreadable paths are not a CD', () {
      final Directory outer = dirWith('outer', <String>[]);
      Directory(p.join(outer.path, 'inner')).createSync();
      File(
        p.join(outer.path, 'inner', 'Track01.cda'),
      ).writeAsBytesSync(<int>[0]);
      expect(audioCdLayoutOfDirectory(outer.path), isNull);
      expect(audioCdLayoutOfDirectory(p.join(root.path, 'missing')), isNull);
    });
  });

  group('ripAudioCd (macOS mount → FLAC)', () {
    late Directory mount;
    late String out;

    setUp(() {
      mount = dirWith('My Album', <String>['.TOC.plist']);
      for (final String n in <String>['1', '2', '10']) {
        File(
          p.join(mount.path, '$n Audio Track.aiff'),
        ).writeAsStringSync('pcm-$n');
      }
      out = p.join(root.path, 'out');
    });

    test(
      'encodes every track in track order with tags, then reuses them',
      () async {
        final _FakeFfmpeg ffmpeg = _FakeFfmpeg();
        final AudioCdRipResult? result = await ripAudioCd(
          discPath: mount.path,
          layout: AudioCdLayout.macCddafs,
          outputRoot: out,
          ffmpeg: ffmpeg,
        );
        expect(result, isNotNull);
        expect(p.basename(result!.directory), startsWith('My Album ('));
        expect(result.files.map(p.basename), <String>[
          'Track 01.flac',
          'Track 02.flac',
          'Track 10.flac',
        ]);
        expect(File(result.files.last).readAsStringSync(), 'pcm-10');
        expect(
          ffmpeg.calls.last,
          containsAllInOrder(<String>[
            '-c:a',
            'flac',
            '-metadata',
            'title=Track 10',
            '-metadata',
            'album=My Album',
            '-metadata',
            'track=10/3',
            '-f',
            'flac',
          ]),
        );
        expect(
          Directory(
            result.directory,
          ).listSync().map((FileSystemEntity e) => p.basename(e.path)),
          isNot(contains(endsWith('.part'))),
        );

        // 同一张盘再插：已抓的轨直接复用，不再编码。
        final _FakeFfmpeg again = _FakeFfmpeg();
        final AudioCdRipResult? reused = await ripAudioCd(
          discPath: mount.path,
          layout: AudioCdLayout.macCddafs,
          outputRoot: out,
          ffmpeg: again,
        );
        expect(reused!.files, result.files);
        expect(again.calls, isEmpty);
      },
    );

    test('a failed encode leaves neither .flac nor .part behind', () async {
      await expectLater(
        ripAudioCd(
          discPath: mount.path,
          layout: AudioCdLayout.macCddafs,
          outputRoot: out,
          ffmpeg: _FakeFfmpeg(exitCode: 1),
        ),
        throwsA(isA<AudioCdException>()),
      );
      final List<String> left = Directory(out)
          .listSync(recursive: true)
          .whereType<File>()
          .map((File f) => p.basename(f.path))
          .toList();
      expect(left, isEmpty);
    });

    test('a cancelled rip hands back nothing to import', () async {
      final AudioCdRipCancellation cancel = AudioCdRipCancellation()..cancel();
      expect(
        await ripAudioCd(
          discPath: mount.path,
          layout: AudioCdLayout.macCddafs,
          outputRoot: out,
          ffmpeg: _FakeFfmpeg(),
          cancellation: cancel,
        ),
        isNull,
      );
    });
  });

  group('importAudioCdIfPresent', () {
    late FushiDatabase db;

    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<BuildContext> pumpContext(WidgetTester tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      );
      return captured;
    }

    testWidgets('a normal folder is left to the caller', (
      WidgetTester t,
    ) async {
      final BuildContext context = await pumpContext(t);
      final String dir = dirWith('music', <String>['01.flac']).path;
      expect(await importAudioCdIfPresent(context, db: db, dir: dir), isFalse);
    });

    testWidgets(
      '.cda outside a CD drive is hinted but still scanned, no rip dialog',
      (WidgetTester t) async {
        // 从光盘拷出来的文件夹：根上只有 .cda，真媒体可能在子目录里，必须照常扫描。
        final BuildContext context = await pumpContext(t);
        final String dir = dirWith('copied', <String>['Track01.cda']).path;
        expect(
          await importAudioCdIfPresent(context, db: db, dir: dir),
          isFalse,
        );
        await t.pump();
        expect(find.byType(AudioCdRipDialog), findsNothing);
        expect(await db.getMediaSourcesByKind('video'), isEmpty);
      },
    );
  });

  test(
    'importLocalFolderOnceAt scans through a temp source and deletes it',
    () async {
      // 抓好的 CD 落在数据根内，只能「仅此一次」导入、不能留下常驻来源行。
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final int existing = await db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'keep',
          mediaKind: 'video',
          rootPath: dirWith('kept', <String>[]).path,
          createdAt: 0,
        ),
      );
      int? scanningId;
      final SourceScanSummary? summary = await importLocalFolderOnceAt(
        db: db,
        mediaKind: 'video',
        path: dirWith('ripped', <String>[]).path,
        videoGroupingMode: 'folder',
        onScanning: (int id) => scanningId = id,
      );
      expect(summary, isNotNull);
      expect(summary!.error, isNull);
      expect(scanningId, isNot(existing));
      expect(
        (await db.getMediaSourcesByKind(
          'video',
        )).map((MediaSourceRow r) => r.id),
        <int>[existing],
      );
    },
  );
}
