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
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';
import 'package:fushi_engine/utils/misc/safe_file_name.dart';
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

/// 不支持中止的后端：第 [cancelOnCall] 次编码进行中用户点了取消，但这次 `run`
/// 打断不了，照常编完。
class _CancelDuringRunFfmpeg extends _FakeFfmpeg {
  _CancelDuringRunFfmpeg(this.cancellation, {required this.cancelOnCall});

  final AudioCdRipCancellation cancellation;
  final int cancelOnCall;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) {
    if (calls.length + 1 == cancelOnCall) cancellation.cancel();
    return super.run(args, timeout);
  }
}

/// 支持中止的后端（桌面 CLI / ffmpeg-kit 的观察式运行）：第 [cancelOnCall] 次编码
/// 写下半截 `.part` 后用户取消，后端按 [FfmpegWatch.cancel] 强杀、回 `returnCode: null`。
class _KillableFfmpeg extends _FakeFfmpeg implements FfmpegWatchedRunner {
  _KillableFfmpeg(this.cancellation, {required this.cancelOnCall});

  final AudioCdRipCancellation cancellation;
  final int cancelOnCall;
  int watchedCalls = 0;

  @override
  Future<FfmpegRunResult> runWatched(
    List<String> args,
    FfmpegWatch watch,
  ) async {
    watchedCalls++;
    if (watchedCalls < cancelOnCall) return run(args, Duration.zero);
    File(args.last).writeAsBytesSync(const <int>[1]);
    cancellation.cancel();
    await watch.cancel;
    return const FfmpegRunResult(
      returnCode: null,
      output: kFfmpegCancelledMarker,
    );
  }
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

    List<String> leftNames() => Directory(out)
        .listSync(recursive: true)
        .whereType<File>()
        .map((File f) => p.basename(f.path))
        .toList();

    test('cancelling during the last track still hands back nothing, even when '
        'the backend cannot abort the encode', () async {
      // 旧实现：循环只在轨之间看取消，最后一轨编完循环自然结束，取消后的结果照常
      // 交出去导入。
      final AudioCdRipCancellation cancel = AudioCdRipCancellation();
      final _CancelDuringRunFfmpeg ffmpeg = _CancelDuringRunFfmpeg(
        cancel,
        cancelOnCall: 3,
      );
      expect(
        await ripAudioCd(
          discPath: mount.path,
          layout: AudioCdLayout.macCddafs,
          outputRoot: out,
          ffmpeg: ffmpeg,
          cancellation: cancel,
        ),
        isNull,
      );
      expect(ffmpeg.calls, hasLength(3));
    });

    test(
      'cancelling mid-encode kills the encoder and leaves no .part',
      () async {
        final AudioCdRipCancellation cancel = AudioCdRipCancellation();
        final _KillableFfmpeg ffmpeg = _KillableFfmpeg(cancel, cancelOnCall: 2);
        expect(
          await ripAudioCd(
            discPath: mount.path,
            layout: AudioCdLayout.macCddafs,
            outputRoot: out,
            ffmpeg: ffmpeg,
            cancellation: cancel,
          ),
          isNull,
        );
        // 第二轨被强杀：没走不可中止的 run、没留半截；第一轨已完成的 FLAC 留作缓存。
        expect(ffmpeg.watchedCalls, 2);
        expect(ffmpeg.calls, hasLength(1));
        expect(leftNames(), <String>['Track 01.flac']);
      },
    );

    test(
      'without a cancellation the encode keeps the fixed-budget run',
      () async {
        // 不传取消（有声书 AIFF 落盘同一个入口）时不改走观察式运行。
        final _KillableFfmpeg ffmpeg = _KillableFfmpeg(
          AudioCdRipCancellation(),
          cancelOnCall: 1,
        );
        expect(
          await ripAudioCd(
            discPath: mount.path,
            layout: AudioCdLayout.macCddafs,
            outputRoot: out,
            ffmpeg: ffmpeg,
          ),
          isNotNull,
        );
        expect(ffmpeg.watchedCalls, 0);
        expect(ffmpeg.calls, hasLength(3));
      },
    );
  });

  group('audioCdFolderName', () {
    test('keeps a plain label and appends the disc id', () {
      expect(audioCdFolderName('My Album', 'abc'), 'My Album (abc)');
    });

    test('replaces illegal characters through the shared helper', () {
      expect(audioCdFolderName('a:b*c?d', 'x'), 'a_b_c_d (x)');
      expect(audioCdFolderName('x\ty', 'x'), 'x_y (x)');
    });

    test('strips trailing dots / spaces and falls back on an empty label', () {
      expect(audioCdFolderName('Disc. ', 'x'), 'Disc (x)');
      expect(audioCdFolderName('   ', 'x'), 'Audio CD (x)');
      expect(audioCdFolderName('...', 'x'), 'Audio CD (x)');
    });

    test('never yields a Windows reserved device name', () {
      // `CON (…)` 本就不是设备名：原样保留，已抓的同名目录照常复用。
      expect(audioCdFolderName('CON', 'x'), 'CON (x)');
      expect(audioCdFolderName('AUX', 'x'), 'AUX (x)');
      // 第一个 `.` 之前是设备名才是：前缀 `_`。
      expect(audioCdFolderName('CON.disc', 'x'), '_CON.disc (x)');
      expect(audioCdFolderName('aux.1', 'x'), '_aux.1 (x)');
      expect(audioCdFolderName('NUL .x', 'x'), '_NUL .x (x)');
      for (final String label in <String>[
        'CON.a',
        'AUX.b',
        'COM1.c',
        'lpt9.d',
      ]) {
        expect(
          isWindowsReservedFileName(audioCdFolderName(label, 'x')),
          isFalse,
          reason: label,
        );
      }
    });
  });

  group('isWindowsReservedFileName', () {
    test('matches device names before the first dot, case-insensitively', () {
      for (final String name in <String>[
        'CON',
        'con',
        'Aux',
        'NUL.txt',
        'NUL.tar.gz',
        'PRN .x',
        'COM1',
        'COM0',
        'LPT9.log',
        'COM¹',
      ]) {
        expect(isWindowsReservedFileName(name), isTrue, reason: name);
      }
    });

    test('leaves ordinary names alone', () {
      for (final String name in <String>[
        'CON (abc)',
        'CONSOLE',
        'COM10',
        'LPT',
        'xCON',
        'My Album (abc)',
        '',
      ]) {
        expect(isWindowsReservedFileName(name), isFalse, reason: name);
      }
    });
  });

  test('the CD import lights the same busy state as a once-only import', () {
    // 抓轨对话框出栈后的扫描与「仅此一次」导入同一条管线：onScanning 必须从来源页一路
    // 接到 importLocalFolderOnceAt，否则扫描期间 isBusy 不亮、可重入导入 / 加来源。
    String callArgs(String source, String callee) {
      final int start = source.indexOf('$callee(');
      expect(start, isNot(-1), reason: '$callee( not found');
      int depth = 0;
      for (int i = start + callee.length; i < source.length; i++) {
        final String c = source[i];
        if (c == '(') depth++;
        if (c == ')' && --depth == 0) {
          return source.substring(start, i + 1);
        }
      }
      fail('unbalanced $callee(');
    }

    final String importer = File(
      'lib/src/media/audio_cd/audio_cd_import.dart',
    ).readAsStringSync();
    expect(
      callArgs(importer, 'await importLocalFolderOnceAt'),
      contains('onScanning: onScanning'),
    );
    final String view = File(
      'lib/src/pages/implementations/media_sources_view.dart',
    ).readAsStringSync();
    final String cdCall = callArgs(view, '_whileTempSourceScans');
    expect(cdCall, contains('importAudioCdIfPresent('));
    expect(cdCall, contains('onScanning: onScanning'));
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
