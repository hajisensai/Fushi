/// DVD titles reach FFmpeg only through the `dvdvideo` demuxer
/// (docs/specs/2026-10-24-dvd-original-menu.md): clip export, screenshots and
/// subtitle extraction name a title, never a `.VOB`.
library;

import 'dart:io';

import 'package:fushi_engine/media/video/dvd/dvd_ffmpeg_input.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:test/test.dart';

class _RecordingBackend implements FfmpegBackend {
  final List<List<String>> runs = <List<String>>[];
  final List<List<String>> probes = <List<String>>[];
  final List<List<String>> queries = <List<String>>[];

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    runs.add(args);
    return const FfmpegRunResult(returnCode: 0, output: '');
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async {
    probes.add(args);
    return const FfmpegRunResult(returnCode: 0, output: '');
  }

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) async {
    queries.add(args);
    return const FfmpegRunResult(returnCode: 0, output: '');
  }
}

void main() {
  const Duration timeout = Duration(seconds: 5);

  group('DVD title input', () {
    test('round-trips through its URI, including Windows paths', () {
      final DvdTitleInput input = DvdTitleInput(
        disc: r'D:\Discs\Movie & Co\VIDEO_TS',
        title: 3,
        chapterStart: 2,
        chapterEnd: 4,
        angle: 2,
      );
      final String encoded = encodeDvdTitleInput(input);
      expect(encoded, startsWith('$dvdTitleInputScheme:'));
      expect(parseDvdTitleInput(encoded), input);
    });

    test('ordinary paths and URLs are not DVD titles', () {
      for (final String value in <String>[
        '/media/movie.mkv',
        r'C:\video\clip.vob',
        'https://example.com/a.m3u8',
        'dvd://1/D:/disc',
      ]) {
        expect(parseDvdTitleInput(value), isNull, reason: value);
      }
    });

    test('a malformed DVD title input is loud, not ignored', () {
      for (final String value in <String>[
        '$dvdTitleInputScheme:?title=1',
        '$dvdTitleInputScheme:?disc=/d',
        '$dvdTitleInputScheme:?disc=/d&title=x',
        '$dvdTitleInputScheme:?disc=/d&title=0',
        '$dvdTitleInputScheme:?disc=/d&title=100',
        '$dvdTitleInputScheme:?disc=/d&title=1&chapter_start=3&chapter_end=2',
        '$dvdTitleInputScheme:?disc=/d&title=1&angle=10',
      ]) {
        expect(
          () => parseDvdTitleInput(value),
          throwsA(anyOf(isA<FormatException>(), isA<ArgumentError>())),
          reason: value,
        );
      }
    });

    test('the demuxer opens the folder that contains VIDEO_TS', () {
      expect(
        DvdTitleInput(disc: '/discs/a/VIDEO_TS', title: 1).demuxerPath,
        '/discs/a',
      );
      expect(DvdTitleInput(disc: '/discs/a', title: 1).demuxerPath, '/discs/a');
      expect(
        DvdTitleInput(disc: '/isos/a.iso', title: 1).demuxerPath,
        '/isos/a.iso',
      );
    });
  });

  group('argument rewrite', () {
    final String title = encodeDvdTitleInput(
      DvdTitleInput(disc: '/discs/a', title: 2, chapterStart: 3),
    );

    test('a title becomes dvdvideo options in front of its -i', () {
      expect(
        prepareDvdFfmpegArgs(<String>[
          '-y',
          '-ss',
          '12.5',
          '-t',
          '4',
          '-i',
          title,
          '-map',
          '0:v:0',
          'out.png',
        ]),
        <String>[
          '-y',
          '-ss',
          '12.5',
          '-t',
          '4',
          '-f',
          'dvdvideo',
          '-title',
          '2',
          '-chapter_start',
          '3',
          '-i',
          '/discs/a',
          '-map',
          '0:v:0',
          'out.png',
        ],
      );
    });

    test('only the DVD input of a multi-input command is rewritten', () {
      expect(
        prepareDvdFfmpegArgs(<String>['-i', title, '-i', 'subs.srt', 'o.mkv']),
        <String>[
          '-f',
          'dvdvideo',
          '-title',
          '2',
          '-chapter_start',
          '3',
          '-i',
          '/discs/a',
          '-i',
          'subs.srt',
          'o.mkv',
        ],
      );
    });

    test('ffprobe accepts the title as its bare last argument', () {
      expect(
        prepareDvdFfmpegArgs(<String>[
          '-show_chapters',
          '-of',
          'json',
          title,
        ], probe: true),
        <String>[
          '-show_chapters',
          '-of',
          'json',
          '-f',
          'dvdvideo',
          '-title',
          '2',
          '-chapter_start',
          '3',
          '-i',
          '/discs/a',
        ],
      );
    });

    test('commands without DVD inputs are returned as the same list', () {
      final List<String> args = <String>['-i', 'movie.mkv', 'out.mp4'];
      expect(identical(prepareDvdFfmpegArgs(args), args), isTrue);
      // A .vob outside VIDEO_TS is an ordinary MPEG-PS video.
      final List<String> loose = <String>['-i', '/videos/home.vob', 'o.mp4'];
      expect(identical(prepareDvdFfmpegArgs(loose), loose), isTrue);
    });

    test('a VIDEO_TS title set VOB is never read directly', () {
      for (final String vob in <String>[
        '/discs/a/VIDEO_TS/VTS_01_1.VOB',
        r'D:\discs\a\video_ts\vts_02_3.vob',
      ]) {
        expect(isDvdVideoTsVobPath(vob), isTrue, reason: vob);
        expect(
          () => prepareDvdFfmpegArgs(<String>['-i', vob, 'out.png']),
          throwsA(isA<DvdFfmpegInputException>()),
          reason: vob,
        );
        expect(
          () => prepareDvdFfmpegArgs(<String>[vob], probe: true),
          throwsA(isA<DvdFfmpegInputException>()),
          reason: vob,
        );
      }
    });
  });

  group('DvdFfmpegBackend', () {
    final String title = encodeDvdTitleInput(
      DvdTitleInput(disc: '/discs/a', title: 1),
    );

    test('run / runProbe rewrite; runQuery passes through', () async {
      final _RecordingBackend inner = _RecordingBackend();
      final DvdFfmpegBackend backend = DvdFfmpegBackend(inner);
      await backend.run(<String>['-i', title, 'o.png'], timeout);
      await backend.runProbe(<String>[title], timeout);
      await backend.runQuery(<String>['-h', 'demuxer=dvdvideo'], timeout);
      expect(inner.runs.single, <String>[
        '-f',
        'dvdvideo',
        '-title',
        '1',
        '-i',
        '/discs/a',
        'o.png',
      ]);
      expect(inner.probes.single.sublist(0, 4), <String>[
        '-f',
        'dvdvideo',
        '-title',
        '1',
      ]);
      expect(inner.queries.single, <String>['-h', 'demuxer=dvdvideo']);
    });

    test('a refused VOB input fails the future and never runs', () async {
      final _RecordingBackend inner = _RecordingBackend();
      final DvdFfmpegBackend backend = DvdFfmpegBackend(inner);
      await expectLater(
        backend.run(<String>['-i', '/d/VIDEO_TS/VTS_01_1.VOB', 'o'], timeout),
        throwsA(isA<DvdFfmpegInputException>()),
      );
      expect(inner.runs, isEmpty);
    });

    test('the process-wide backend carries the DVD rewrite', () {
      setFfmpegBackendForTesting(null);
      final FfmpegBackend resolved = resolveFfmpegBackend();
      expect(resolved, isA<BlurayFfmpegBackend>());
      expect(
        (resolved as BlurayFfmpegBackend).delegate,
        isA<DvdFfmpegBackend>(),
      );
      setFfmpegBackendForTesting(null);
    });
  });

  // Real unified FFmpeg against an authored disc (tool/dvd/make_test_dvd.py):
  // FUSHI_DVD_TEST_FFPROBE=<ffprobe with dvdvideo> FUSHI_DVD_TEST_DISC=<dir>.
  final String? ffprobe = Platform.environment['FUSHI_DVD_TEST_FFPROBE'];
  final String? disc = Platform.environment['FUSHI_DVD_TEST_DISC'];
  test(
    'real dvdvideo demuxer reads title 1 chapter 2 of the authored disc',
    () async {
      final List<String> args = prepareDvdFfmpegArgs(<String>[
        '-v',
        'error',
        '-show_entries',
        'format=duration',
        '-of',
        'default=nw=1:nk=1',
        encodeDvdTitleInput(
          DvdTitleInput(disc: disc!, title: 1, chapterStart: 2, chapterEnd: 2),
        ),
      ], probe: true);
      final ProcessResult result = await Process.run(ffprobe!, args);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final double duration = double.parse('${result.stdout}'.trim());
      // make_test_dvd.py: title 1 is 6 s with chapters at 0 / 2 / 4 s.
      expect(duration, inInclusiveRange(1.5, 3.0));
    },
    skip: ffprobe == null || disc == null
        ? 'set FUSHI_DVD_TEST_FFPROBE and FUSHI_DVD_TEST_DISC'
        : null,
  );
}
