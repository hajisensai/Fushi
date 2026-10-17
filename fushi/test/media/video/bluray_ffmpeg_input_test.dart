import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bluray/bluray_ffmpeg_input.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_clip_exporter.dart';
import 'package:fushi_engine/utils/misc/synchronized_video_exporter.dart';
import 'package:path/path.dart' as p;

import 'bluray_fixture.dart';

class _RecordingBackend implements FfmpegBackend {
  /// 查询类命令（BUG-2938 新增原语）：本假件不区分，交给 [run]。
  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      run(args, timeout);

  List<String>? args;
  bool fail = false;
  String? manifest;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    this.args = args;
    manifest = args.firstWhere((String a) => a.endsWith('.ffconcat'));
    expect(File(manifest!).existsSync(), isTrue);
    if (fail) throw StateError('Backend failed');
    return const FfmpegRunResult(returnCode: 0, output: '');
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      run(args, timeout);
}

void main() {
  late Directory disc;
  late String playlist;
  setUp(() async {
    disc = await Directory.systemTemp.createTemp("bluray test's-");
    final Directory list = await Directory(
      p.join(disc.path, 'BDMV', 'PLAYLIST'),
    ).create(recursive: true);
    final Directory streams = await Directory(
      p.join(disc.path, 'BDMV', 'STREAM'),
    ).create();
    for (final String id in <String>['00001', '00002']) {
      await File(p.join(streams.path, '$id.m2ts')).writeAsBytes(<int>[0]);
    }
    playlist = p.join(list.path, '00001.mpls');
    await File(playlist).writeAsBytes(
      buildMplsFixture(
        playItems: const <FixturePlayItem>[
          FixturePlayItem(
            clipId: '00001',
            inTimeTicks: 450000,
            outTimeTicks: 540000,
          ),
          FixturePlayItem(
            clipId: '00002',
            inTimeTicks: 900000,
            outTimeTicks: 1035000,
          ),
        ],
      ),
    );
  });
  tearDown(() async => disc.delete(recursive: true));

  test('ordinary inputs retain every argument', () async {
    final List<String> args = <String>[
      '-ss',
      '2',
      '-i',
      'movie.mkv',
      '-c',
      'copy',
      'out.mkv',
    ];
    final BlurayFfmpegInput prepared = await prepareBlurayFfmpegArgs(args);
    expect(identical(prepared.args, args), isTrue);
    await prepared.dispose();
  });

  test(
    'cross-seam seek clips absolute timestamps and keeps accurate duration',
    () async {
      final BlurayFfmpegInput prepared = await prepareBlurayFfmpegArgs(<String>[
        '-ss',
        '1.5',
        '-t',
        '1',
        '-i',
        playlist,
        '-an',
        '-vf',
        'scale=320:-2',
        'out.png',
      ]);
      final String manifest = prepared.args[prepared.args.indexOf('-i') + 1];
      final String text = await File(manifest).readAsString();
      expect(
        text,
        contains(
          'inpoint -8.500000000\noutpoint 12.000000000\nduration 0.500000000',
        ),
      );
      expect(
        text,
        contains(
          'inpoint 0.000000000\noutpoint 20.500000000\nduration 0.500000000',
        ),
      );
      expect(text, contains("'\\''"));
      expect(prepared.args, isNot(contains('-ss')));
      expect(prepared.args, isNot(contains('-t')));
      expect(
        prepared.args,
        contains(
          'select=concatdec_select,setpts=PTS-20.000000000/TB,scale=320:-2',
        ),
      );
      expect(prepared.args, isNot(contains('-af')));
      await prepared.dispose();
      expect(File(manifest).existsSync(), isFalse);
    },
  );

  test('dual input windows and filters use both playlist axes', () async {
    final BlurayFfmpegInput prepared = await prepareBlurayFfmpegArgs(<String>[
      '-ss',
      '0.5',
      '-t',
      '1',
      '-i',
      playlist,
      '-ss',
      '1.5',
      '-t',
      '2',
      '-i',
      playlist,
      '-map',
      '0:v:0',
      '-map',
      '1:a:1',
      '-af',
      'atempo=1.2',
      'out.mp4',
    ]);
    expect(
      prepared.args,
      contains(
        'aselect=concatdec_select,asetpts=PTS-20.000000000/TB,atempo=1.2',
      ),
    );
    final List<String> manifests = prepared.args
        .where((String arg) => arg.endsWith('.ffconcat'))
        .toList();
    expect(manifests, hasLength(2));
    expect(
      await File(manifests[0]).readAsString(),
      contains('file_packet_meta lavf.concatdec.start_time 10500000'),
    );
    expect(
      await File(manifests[1]).readAsString(),
      contains('file_packet_meta lavf.concatdec.start_time 20000000'),
    );
    await prepared.dispose();
  });

  test('GIF complex graph filters once before palette split', () async {
    final BlurayFfmpegInput prepared = await prepareBlurayFfmpegArgs(<String>[
      '-i',
      playlist,
      '-an',
      '-filter_complex',
      'fps=10,split[a][b];[a]palettegen[p];[b][p]paletteuse',
      'out.gif',
    ]);
    expect(
      prepared.args,
      contains(
        'select=concatdec_select,setpts=PTS-20.000000000/TB,fps=10,split[a][b];[a]palettegen[p];[b][p]paletteuse',
      ),
    );
    expect(prepared.args, isNot(contains('-vf')));
    await prepared.dispose();
  });

  test(
    'subtitle burn transforms video input but leaves PNG timestamps alone',
    () async {
      final BlurayFfmpegInput prepared = await prepareBlurayFfmpegArgs(<String>[
        '-i',
        playlist,
        '-i',
        'subtitle.png',
        '-filter_complex',
        '[0:v][1:v]overlay[out]',
        '-map',
        '[out]',
        '-map',
        '0:a?',
        'out.mp4',
      ]);
      final String graph =
          prepared.args[prepared.args.indexOf('-filter_complex') + 1];
      expect(
        graph,
        contains(
          '[0:v]select=concatdec_select,setpts=PTS-20.000000000/TB[bd_input_0]',
        ),
      );
      expect(graph, contains('[bd_input_0][1:v]overlay[out]'));
      expect(
        prepared.args,
        contains('aselect=concatdec_select,asetpts=PTS-20.000000000/TB'),
      );
      await prepared.dispose();
    },
  );

  test(
    'probing and subtitle-only extraction never attach A/V filters',
    () async {
      for (final bool probe in <bool>[false, true]) {
        final BlurayFfmpegInput prepared = await prepareBlurayFfmpegArgs(
          probe ? <String>['-show_format', playlist] : <String>['-i', playlist],
          probe: probe,
        );
        expect(prepared.args, isNot(contains('-vf')));
        expect(prepared.args, isNot(contains('-copyts')));
        await prepared.dispose();
      }
      final BlurayFfmpegInput prepared = await prepareBlurayFfmpegArgs(<String>[
        '-i',
        playlist,
        '-map',
        '0:s:0',
        '-c:s',
        'srt',
        'out.srt',
      ]);
      expect(prepared.args, isNot(contains('-af')));
      expect(prepared.args, isNot(contains('-vf')));
      await prepared.dispose();
    },
  );

  test('backend disposes manifests on return and exceptions', () async {
    final _RecordingBackend delegate = _RecordingBackend();
    final BlurayFfmpegBackend backend = BlurayFfmpegBackend(delegate);
    await backend.runProbe(<String>[playlist], const Duration(seconds: 1));
    expect(File(delegate.manifest!).existsSync(), isFalse);
    delegate.fail = true;
    await expectLater(
      backend.run(<String>['-i', playlist], const Duration(seconds: 1)),
      throwsStateError,
    );
    expect(File(delegate.manifest!).existsSync(), isFalse);
  });

  test(
    'mining combines playlist video with independently trimmed AAC',
    () async {
      final BlurayFfmpegInput prepared = await prepareBlurayFfmpegArgs(
        buildSynchronizedVideoClipArgs(
          videoPath: playlist,
          audioPath: 'sentence.aac',
          audioStartMs: 0,
          startMs: 1500,
          endMs: 2500,
          outputPath: 'card.mp4',
        ),
      );
      expect(
        prepared.args.where((String arg) => arg.endsWith('.ffconcat')),
        hasLength(1),
      );
      expect(prepared.args, contains('sentence.aac'));
      expect(
        prepared.args[prepared.args.indexOf('-af') + 1],
        'asetpts=PTS-STARTPTS,asetpts=PTS-STARTPTS',
      );
      expect(
        prepared.args[prepared.args.indexOf('-vf') + 1],
        startsWith('select=concatdec_select,setpts=PTS-20.000000000/TB,'),
      );
      await prepared.dispose();
    },
  );

  test(
    'missing segments and unsupported mixed media fail before execution',
    () async {
      await expectLater(
        prepareBlurayFfmpegArgs(<String>[
          '-i',
          playlist,
          '-i',
          'audio.wav',
          'out.mp4',
        ]),
        throwsUnsupportedError,
      );
      await File(p.join(disc.path, 'BDMV', 'STREAM', '00002.m2ts')).delete();
      await expectLater(
        prepareBlurayFfmpegArgs(<String>['-i', playlist]),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('playlist clip export always reencodes both streams for exact cuts', () {
    final List<String> args = buildFfmpegVideoClipExportArgs(
      inputPath: playlist,
      startMs: 0,
      endMs: 500,
      outputPath: 'out.mp4',
    );
    expect(args, isNot(contains('copy')));
    expect(args, contains('libx264'));
    expect(args, contains('aac'));
  });
}
