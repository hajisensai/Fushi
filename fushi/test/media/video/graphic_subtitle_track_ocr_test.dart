import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_stream_ocr.dart';
import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';
import 'package:fushi/src/media/video/graphic_subtitle_track_ocr.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_track.dart'
    show bitmapSubtitleTrackHeaderPath;
import 'package:fushi_engine/media/video/bitmap_subtitle/pgs_subtitle_parser.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart';
import 'package:fushi_engine/ocr/ocr_types.dart' show OcrRecognition, OcrRect;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../helpers/unified_ffmpeg.dart';

/// 记下 ffmpeg 参数；[writeSup] 时往输出路径（末参）写一份 `.sup`，否则写空壳。
class _RecordingFfmpegBackend implements FfmpegBackend {
  _RecordingFfmpegBackend({required this.returnCode, required this.writeSup});

  final int returnCode;
  final bool writeSup;
  List<String>? args;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    this.args = args;
    File(_supOutput(args)).writeAsBytesSync(writeSup ? _sup() : <int>[]);
    return FfmpegRunResult(returnCode: returnCode, output: 'boom');
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      throw UnimplementedError();

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      run(args, timeout);
}

/// 参数里 `-f sup` 后面那个就是 `.sup` 输出路径（其后还有进度用的 `-f null -` 输出）。
String _supOutput(List<String> args) => args[args.indexOf('sup') + 1];

/// 支持观察式运行的假后端：按脚本报进度、可被取消；记下收到的 [FfmpegWatch]。
class _WatchedFfmpegBackend extends _RecordingFfmpegBackend
    implements FfmpegWatchedRunner {
  _WatchedFfmpegBackend({required this.progress, this.waitForCancel = false})
    : super(returnCode: 0, writeSup: true);

  final List<Duration> progress;
  final bool waitForCancel;
  FfmpegWatch? watch;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) =>
      throw StateError('支持观察式运行的后端不该走固定超时的 run');

  @override
  Future<FfmpegRunResult> runWatched(
    List<String> args,
    FfmpegWatch watch,
  ) async {
    this.args = args;
    this.watch = watch;
    for (final Duration d in progress) {
      watch.onProgress?.call(d);
    }
    if (waitForCancel) {
      await watch.cancel;
      File(_supOutput(args)).writeAsBytesSync(<int>[1, 2, 3]);
      return const FfmpegRunResult(
        returnCode: null,
        output: kFfmpegCancelledMarker,
      );
    }
    File(_supOutput(args)).writeAsBytesSync(_sup());
    return const FfmpegRunResult(returnCode: 0, output: '');
  }
}

/// 直接起随包统一 FFmpeg 的 ffmpeg / ffprobe 进程。
class _BinaryFfmpegBackend implements FfmpegBackend {
  _BinaryFfmpegBackend(this.executable, this.ffprobe);

  final String executable;
  final String ffprobe;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    final ProcessResult r = await Process.run(executable, <String>[
      '-hide_banner',
      '-loglevel',
      'error',
      ...args,
    ]).timeout(timeout);
    return FfmpegRunResult(returnCode: r.exitCode, output: '${r.stderr}');
  }

  /// 同一份统一 FFmpeg 的 ffprobe（两者成对）。
  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async {
    final ProcessResult r = await Process.run(
      ffprobe,
      args,
    ).timeout(timeout);
    return FfmpegRunResult(returnCode: r.exitCode, output: '${r.stdout}');
  }

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      run(args, timeout);
}

/// 一个 PGS 段（不带 `PG` 头）：类型 + 长度 + 段体。
typedef _Segment = ({int type, List<int> body});

List<int> _u16(int v) => <int>[(v >> 8) & 0xFF, v & 0xFF];

/// PCS：1920x1080，[objects] 为 (id, x, y)，空即清屏。
_Segment _pcs(List<(int, int, int)> objects, {bool epochStart = false}) => (
  type: 0x16,
  body: <int>[
    ..._u16(1920),
    ..._u16(1080),
    0x10, // frame rate
    ..._u16(0), // composition number
    epochStart ? 0x80 : 0x00,
    0x00, // palette update flag
    0x00, // palette id
    objects.length,
    for (final (int id, int x, int y) in objects) ...<int>[
      ..._u16(id),
      0x00, // window id
      0x00, // not cropped
      ..._u16(x),
      ..._u16(y),
    ],
  ],
);

/// PDS：调色板 0，第 1 项白色、给定不透明度。
_Segment _pds(int alpha) =>
    (type: 0x14, body: <int>[0x00, 0x00, 0x01, 235, 128, 128, alpha]);

/// ODS：[width]x2 实心色 1（[width] < 64）。
_Segment _ods({int width = 4}) {
  // 每行：色 1 连续 width 个（00 (0x80|width) 01 带颜色），再行尾 00 00。
  final List<int> rle = <int>[
    0x00, 0x80 | width, 0x01, 0x00, 0x00, //
    0x00, 0x80 | width, 0x01, 0x00, 0x00,
  ];
  return (
    type: 0x15,
    body: <int>[
      ..._u16(0), // object id
      0x00, // version
      0xC0, // first + last
      0x00, ..._u16(rle.length + 4), // data length（含宽高）
      ..._u16(width),
      ..._u16(2),
      ...rle,
    ],
  );
}

const _Segment _end = (type: 0x80, body: <int>[]);

/// 测试素材：1s 出现 → 1.5s 只换调色板（淡入，不拆 cue）→ 3s 清屏。
const List<(int, List<_Segment> Function())> _displaySets =
    <(int, List<_Segment> Function())>[
      (90000, _set1),
      (135000, _set2),
      (270000, _set3),
    ];

List<_Segment> _set1() => <_Segment>[
  _pcs(<(int, int, int)>[(0, 100, 200)], epochStart: true),
  _pds(0x40),
  _ods(),
  _end,
];

List<_Segment> _set2() => <_Segment>[
  _pcs(<(int, int, int)>[(0, 100, 200)]),
  _pds(0xFF),
  _end,
];

List<_Segment> _set3() => <_Segment>[_pcs(const <(int, int, int)>[]), _end];

Uint8List _sup() {
  final BytesBuilder out = BytesBuilder();
  for (final (int pts, List<_Segment> Function() build) in _displaySets) {
    for (final _Segment s in build()) {
      out
        ..add(<int>[0x50, 0x47])
        ..add(<int>[
          (pts >> 24) & 0xFF,
          (pts >> 16) & 0xFF,
          (pts >> 8) & 0xFF,
          pts & 0xFF,
        ])
        ..add(<int>[0, 0, 0, 0])
        ..add(<int>[s.type, ..._u16(s.body.length)])
        ..add(s.body);
    }
  }
  return out.toBytes();
}

/// 多条 cue 的 `.sup`：每个起点出现 500ms 后清屏；[openLast] 时最后一条不清屏
/// （模拟抽轨进程还没写到它的收尾）。每条位图宽度不同（内容各异，不会被同图去重）；
/// [sameBitmap] 时全部同一张位图。
Uint8List _multiSup(
  List<int> startsMs, {
  bool openLast = false,
  bool sameBitmap = false,
}) {
  final BytesBuilder out = BytesBuilder();
  void put(int ms, List<_Segment> segments) {
    final int pts = ms * 90;
    for (final _Segment s in segments) {
      out
        ..add(<int>[0x50, 0x47])
        ..add(<int>[
          (pts >> 24) & 0xFF,
          (pts >> 16) & 0xFF,
          (pts >> 8) & 0xFF,
          pts & 0xFF,
        ])
        ..add(<int>[0, 0, 0, 0])
        ..add(<int>[s.type, ..._u16(s.body.length)])
        ..add(s.body);
    }
  }

  for (int i = 0; i < startsMs.length; i++) {
    put(startsMs[i], <_Segment>[
      _pcs(<(int, int, int)>[(0, 100, 200)], epochStart: true),
      _pds(0xFF),
      _ods(width: sameBitmap ? 4 : 4 + i),
      _end,
    ]);
    if (openLast && i == startsMs.length - 1) break;
    put(startsMs[i] + 500, _set3());
  }
  return out.toBytes();
}

MokuroImage _page(List<List<String>> blocks) => MokuroImage(
  url: 'x.png',
  size: const MokuroSize(100, 40),
  blocks: <MokuroBlock>[
    for (final List<String> lines in blocks)
      MokuroBlock(
        rectangle: const MokuroRect.fromLTRB(0, 0, 100, 40),
        isVertical: false,
        fontSize: 20,
        zIndex: 0,
        lines: lines,
      ),
  ],
);

class _FakeRecognizer implements MangaStreamPageRecognizer {
  _FakeRecognizer(this.pages);

  final List<MokuroImage> pages;
  int calls = 0;
  bool closed = false;

  @override
  Future<MokuroImage> recognize(File pageFile) async {
    expect(pageFile.existsSync(), isTrue);
    return pages[calls++];
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  test('整轨转文字支持 PGS / VobSub / DVB 三种位图字幕（图文电视不是位图）', () {
    expect(graphicSubtitleTrackOcrSupportsCodec('hdmv_pgs_subtitle'), isTrue);
    expect(graphicSubtitleTrackOcrSupportsCodec('dvd_subtitle'), isTrue);
    expect(graphicSubtitleTrackOcrSupportsCodec('dvb_subtitle'), isTrue);
    expect(graphicSubtitleTrackOcrSupportsCodec('S_VOBSUB'), isTrue);
    expect(graphicSubtitleTrackOcrSupportsCodec('dvb_teletext'), isFalse);
    expect(graphicSubtitleTrackOcrSupportsCodec('subrip'), isFalse);
    expect(graphicSubtitleTrackOcrSupportsCodec(null), isFalse);
  });

  group('PgsSubtitleParser', () {
    test('淡入只换调色板不拆 cue；清屏收尾；时间按 90kHz 换算', () {
      final List<PgsCue> cues = PgsSubtitleParser.parse(_sup());
      expect(cues, hasLength(1));
      expect(cues.single.startMs, 1000);
      expect(cues.single.endMs, 3000);
      expect(cues.single.bounds, (
        left: 100,
        top: 200,
        right: 104,
        bottom: 202,
      ));
      // PCS 声明的合成画布：位图坐标所在的坐标系（模糊遮蔽按它映射到画面）。
      expect(cues.single.canvasWidth, 1920);
      expect(cues.single.canvasHeight, 1080);
    });

    test('renderPng 取最不透明的调色板、按 padding 留边', () {
      final img.Image? png = img.decodePng(
        PgsSubtitleParser.parse(_sup()).single.renderPng(padding: 2),
      );
      expect(png, isNotNull);
      expect(png!.width, 8);
      expect(png.height, 6);
      expect(png.getPixel(0, 0).r, 0);
      // 白色（Y=235）且按最不透明那帧满亮度渲染。
      expect(png.getPixel(2, 2).r, greaterThan(250));
      expect(png.getPixel(5, 3).r, greaterThan(250));
      expect(png.getPixel(6, 2).r, 0);
    });

    test('截断的尾段被忽略，已解析部分照常返回', () {
      final Uint8List full = _sup();
      final List<PgsCue> cues = PgsSubtitleParser.parse(
        Uint8List.sublistView(full, 0, full.length - 3),
      );
      // 清屏段被截断：最后一条按兜底时长收尾。
      expect(cues, hasLength(1));
      expect(cues.single.endMs, 1000 + PgsSubtitleParser.openCueCapMs);
    });
  });

  group('extractGraphicSubtitleTrackToSup', () {
    late Directory dir;
    late File video;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('fushi_sup_extract_');
      video = File(p.join(dir.path, 'v.mkv'))..writeAsBytesSync(<int>[0]);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('按相对序号原样复制成 .sup', () async {
      final _RecordingFfmpegBackend backend = _RecordingFfmpegBackend(
        returnCode: 0,
        writeSup: true,
      );
      final String out = p.join(dir.path, 'track.sup');
      final bool ok = await extractGraphicSubtitleTrackToSup(
        videoPath: video.path,
        streamIndex: 2,
        supPath: out,
        codec: 'hdmv_pgs_subtitle',
        backend: backend,
      );
      expect(ok, isTrue);
      // PGS 不需要 extradata：不探测；头文件先于载荷写好。
      expect(
        File(bitmapSubtitleTrackHeaderPath(out)).readAsStringSync(),
        contains('hdmv_pgs_subtitle'),
      );
      expect(backend.args, <String>[
        '-y',
        '-i',
        video.path,
        '-map',
        '0:s:2',
        '-c',
        'copy',
        '-f',
        'sup',
        out,
        // 进度伴随输出：同一次读文件，视频包拷进 null，让已处理时间连续推进（BUG-3102）。
        '-map',
        '0:v:0?',
        '-map',
        '0:s:2',
        '-c',
        'copy',
        '-f',
        'null',
        '-',
      ]);
    });

    test('观察式后端：按进度判活、进度原样转给调用方（BUG-3102）', () async {
      final _WatchedFfmpegBackend backend = _WatchedFfmpegBackend(
        progress: const <Duration>[Duration(minutes: 1), Duration(minutes: 7)],
      );
      final List<Duration> seen = <Duration>[];
      final bool ok = await extractGraphicSubtitleTrackToSup(
        videoPath: video.path,
        streamIndex: 0,
        supPath: p.join(dir.path, 'track.sup'),
        codec: 'hdmv_pgs_subtitle',
        onProgress: seen.add,
        backend: backend,
      );
      expect(ok, isTrue);
      expect(seen, const <Duration>[
        Duration(minutes: 1),
        Duration(minutes: 7),
      ]);
      // 判活靠「多久没推进」，不是按体积估的总时长。
      expect(backend.watch!.stallTimeout, kGraphicSubtitleExtractStallTimeout);
    });

    test('取消：不算失败、不留半截 .sup', () async {
      final _WatchedFfmpegBackend backend = _WatchedFfmpegBackend(
        progress: const <Duration>[Duration(seconds: 3)],
        waitForCancel: true,
      );
      final Completer<void> cancel = Completer<void>();
      final List<String> failures = <String>[];
      final String out = p.join(dir.path, 'track.sup');
      final Future<bool> running = extractGraphicSubtitleTrackToSup(
        videoPath: video.path,
        streamIndex: 0,
        supPath: out,
        codec: 'hdmv_pgs_subtitle',
        onFailure: failures.add,
        cancel: cancel.future,
        backend: backend,
      );
      cancel.complete();
      expect(await running, isFalse);
      expect(File(out).existsSync(), isFalse);
      expect(File(bitmapSubtitleTrackHeaderPath(out)).existsSync(), isFalse);
      expect(failures, isEmpty);
    });

    test('失败：删掉空壳文件、交出失败摘要', () async {
      final String out = p.join(dir.path, 'track.sup');
      final List<String> failures = <String>[];
      final bool ok = await extractGraphicSubtitleTrackToSup(
        videoPath: video.path,
        streamIndex: 0,
        supPath: out,
        codec: 'hdmv_pgs_subtitle',
        onFailure: failures.add,
        backend: _RecordingFfmpegBackend(returnCode: 1, writeSup: false),
      );
      expect(ok, isFalse);
      expect(File(out).existsSync(), isFalse);
      expect(File(bitmapSubtitleTrackHeaderPath(out)).existsSync(), isFalse);
      expect(failures.single, contains('boom'));
    });

    test('输入不存在不调 ffmpeg', () async {
      final _RecordingFfmpegBackend backend = _RecordingFfmpegBackend(
        returnCode: 0,
        writeSup: true,
      );
      final List<String> failures = <String>[];
      final bool ok = await extractGraphicSubtitleTrackToSup(
        videoPath: p.join(dir.path, 'missing.mkv'),
        streamIndex: 0,
        supPath: p.join(dir.path, 'track.sup'),
        onFailure: failures.add,
        backend: backend,
      );
      expect(ok, isFalse);
      expect(backend.args, isNull);
      expect(failures, <String>['input missing']);
    });

    // 随包统一 FFmpeg 真跑一遍：缺 sup 封装器时这里报
    // "Requested output format 'sup' is not known"。夹具是一条 PGS 轨的 mkv
    // （单测里的 _sup() 由完整 ffmpeg 封装，mkv 把起点归零：1s/1.5s/3s → 0/0.5/2s）。
    final UnifiedFfmpegForTests? unified =
        resolveBundledUnifiedFfmpegForTests();
    test(
      '随包统一 FFmpeg 能把 mkv 里的 PGS 轨抽成 .sup',
      () async {
        final String out = p.join(dir.path, 'track.sup');
        final List<String> failures = <String>[];
        final bool ok = await extractGraphicSubtitleTrackToSup(
          videoPath: 'test/fixtures/video/pgs_one_cue.mkv',
          streamIndex: 0,
          supPath: out,
          onFailure: failures.add,
          backend: _BinaryFfmpegBackend(unified!.ffmpeg, unified.ffprobe),
        );
        expect(ok, isTrue, reason: failures.join('\n'));
        final List<PgsCue> cues = PgsSubtitleParser.parse(
          File(out).readAsBytesSync(),
        );
        expect(cues, hasLength(1));
        expect(cues.single.startMs, 0);
        expect(cues.single.endMs, 2000);
        expect(cues.single.bounds, (
          left: 100,
          top: 200,
          right: 104,
          bottom: 202,
        ));
      },
      skip: unified != null
          ? false
          : '找不到随包统一 FFmpeg（ffmpeg + ffprobe）',
    );
  });

  group('buildGraphicSubtitleSrt', () {
    test('相邻同文合并、跳过空文字与零时长、时间格式 HH:MM:SS,mmm', () {
      final String srt = buildGraphicSubtitleSrt(<GraphicSubtitleTextCue>[
        const GraphicSubtitleTextCue(startMs: 0, endMs: 1000, text: 'あ'),
        const GraphicSubtitleTextCue(startMs: 1030, endMs: 2000, text: 'あ'),
        const GraphicSubtitleTextCue(startMs: 2000, endMs: 2500, text: '  '),
        const GraphicSubtitleTextCue(startMs: 2600, endMs: 2600, text: 'い'),
        const GraphicSubtitleTextCue(
          startMs: 3661001,
          endMs: 3662000,
          text: 'う\nえ',
        ),
        // 间隔超过 joinGapMs：不合并。
        const GraphicSubtitleTextCue(
          startMs: 3662100,
          endMs: 3663000,
          text: 'う\nえ',
        ),
      ]);
      expect(
        srt,
        '1\n00:00:00,000 --> 00:00:02,000\nあ\n\n'
        '2\n01:01:01,001 --> 01:01:02,000\nう\nえ\n\n'
        '3\n01:01:02,100 --> 01:01:03,000\nう\nえ\n\n',
      );
    });

    test('全空返回空串', () {
      expect(
        buildGraphicSubtitleSrt(const <GraphicSubtitleTextCue>[
          GraphicSubtitleTextCue(startMs: 0, endMs: 10, text: ''),
        ]),
        isEmpty,
      );
    });
  });

  group('整轨识别会话（单条）', () {
    Future<List<GraphicSubtitleTextCue>?> runOne(
      GraphicSubtitleOcrSession session, {
      bool cancelled = false,
    }) => recognizeGraphicSubtitleCuesLive(
      snapshot: () async => PgsSubtitleParser.parse(_sup()),
      sourceComplete: () => true,
      sourceDone: Future<void>.value(),
      session: session,
      positionMs: () => 0,
      isCancelled: () => cancelled,
    );

    test('页级引擎：块内行直接拼接、块间换行', () async {
      final _FakeRecognizer recognizer = _FakeRecognizer(<MokuroImage>[
        _page(<List<String>>[
          <String>['こんにち', 'は'],
          <String>['世界'],
        ]),
      ]);
      final GraphicSubtitleOcrSession session = GraphicSubtitleOcrSession(
        prepare: (String _) async =>
            MangaStreamOcrReady(MangaOcrEngineId.localOnnx, recognizer),
      );
      final List<GraphicSubtitleTextCue>? out = await runOne(session);
      await session.close();
      expect(out, hasLength(1));
      expect(out!.single.text, 'こんにちは\n世界');
      expect(out.single.startMs, 1000);
      expect(out.single.endMs, 3000);
      expect(recognizer.closed, isTrue);
    });

    test('取消返回 null，不再识别', () async {
      final _FakeRecognizer recognizer = _FakeRecognizer(<MokuroImage>[]);
      final GraphicSubtitleOcrSession session = GraphicSubtitleOcrSession(
        prepare: (String _) async =>
            MangaStreamOcrReady(MangaOcrEngineId.localOnnx, recognizer),
      );
      expect(await runOne(session, cancelled: true), isNull);
      await session.close();
      expect(recognizer.calls, 0);
    });

    test('没有引擎抛 GraphicSubtitleOcrUnavailable(noEngine)', () async {
      final GraphicSubtitleOcrSession session = GraphicSubtitleOcrSession(
        prepare: (String _) async => const MangaStreamOcrNoEngine(),
      );
      await expectLater(
        runOne(session),
        throwsA(
          isA<GraphicSubtitleOcrUnavailable>().having(
            (GraphicSubtitleOcrUnavailable e) => e.reason,
            'reason',
            GraphicSubtitleOcrUnavailableReason.noEngine,
          ),
        ),
      );
      await session.close();
    });

    test('文字图引擎：像素直接交识别器（不落 PNG），并行开满会话池', () async {
      final _TextImageRecognizer recognizer = _TextImageRecognizer(
        parallelism: 3,
      );
      final GraphicSubtitleOcrSession session = GraphicSubtitleOcrSession(
        prepare: (String _) async =>
            MangaStreamOcrReady(MangaOcrEngineId.localOnnx, recognizer),
      );
      final List<GraphicSubtitleTextCue>? out =
          await recognizeGraphicSubtitleCuesLive(
            snapshot: () async => PgsSubtitleParser.parse(
              _multiSup(<int>[1000, 3000, 5000, 7000, 9000, 11000]),
            ),
            sourceComplete: () => true,
            sourceDone: Future<void>.value(),
            session: session,
            positionMs: () => 0,
            isCancelled: () => false,
          );
      await session.close();
      expect(recognizer.pageCalls, 0, reason: '文字图引擎不该走整页管线');
      expect(recognizer.textCalls, 6);
      expect(recognizer.maxConcurrent, 3);
      // 位图宽 4+i 像素，加 16px 边距 → 宽度各不相同，文字里带着宽度。
      expect(out!.map((GraphicSubtitleTextCue c) => c.text), <String>[
        for (int i = 0; i < 6; i++) 'w${4 + i + 32}',
      ]);
    });

    test('同一张位图只识别一次，所有出现它的 cue 都拿到文字', () async {
      final _TextImageRecognizer recognizer = _TextImageRecognizer(
        parallelism: 2,
      );
      final GraphicSubtitleOcrSession session = GraphicSubtitleOcrSession(
        prepare: (String _) async =>
            MangaStreamOcrReady(MangaOcrEngineId.localOnnx, recognizer),
      );
      final List<GraphicSubtitleTextCue>? out =
          await recognizeGraphicSubtitleCuesLive(
            snapshot: () async => PgsSubtitleParser.parse(
              _multiSup(<int>[1000, 3000, 5000, 7000], sameBitmap: true),
            ),
            sourceComplete: () => true,
            sourceDone: Future<void>.value(),
            session: session,
            positionMs: () => 0,
            isCancelled: () => false,
          );
      await session.close();
      expect(recognizer.textCalls, 1);
      expect(out, hasLength(4));
      expect(out!.every((GraphicSubtitleTextCue c) => c.text == 'w36'), isTrue);
    });

    test('大模型重读不挡本地识别：本地先出字，读回后热替换，收尾等重读回齐', () async {
      final _TextImageRecognizer recognizer = _TextImageRecognizer(
        parallelism: 2,
        confidence: 0.2,
      );
      final _GatedAiClient client = _GatedAiClient();
      final GraphicSubtitleOcrSession session = GraphicSubtitleOcrSession(
        prepare: (String dir) async => MangaStreamOcrReady(
          MangaOcrEngineId.localOnnx,
          recognizer,
          ai: MangaStreamAiRefinement(
            refiner: MangaAiOcrRefiner(
              provider: _aiProvider,
              mode: MangaAiOcrMode.lowConfidence,
              context: const MangaAiOcrContext(
                source: MangaAiOcrSource.subtitle,
              ),
              clientFactory: () => client,
            ),
          ),
        ),
      );
      final List<List<String>> published = <List<String>>[];
      final List<(int, int)> aiProgress = <(int, int)>[];
      final Future<List<GraphicSubtitleTextCue>?> running =
          recognizeGraphicSubtitleCuesLive(
            snapshot: () async =>
                PgsSubtitleParser.parse(_multiSup(<int>[1000, 3000])),
            sourceComplete: () => true,
            sourceDone: Future<void>.value(),
            session: session,
            positionMs: () => 0,
            isCancelled: () => false,
            onRecognized: (List<GraphicSubtitleTextCue> r) => published.add(
              <String>[for (final GraphicSubtitleTextCue c in r) c.text],
            ),
            onAiProgress: (int done, int total) =>
                aiProgress.add((done, total)),
          );
      // 本地两条都先出字，大模型请求还挂着。
      await client.started.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(published.last, <String>['w36', 'w37']);
      expect(recognizer.textCalls, 2);
      client.release();
      final List<GraphicSubtitleTextCue>? out = await running;
      await session.close();
      // 两条拼进同一次请求（跨条批量），读回后替换。
      expect(client.calls, 1);
      // 请求带字幕版提示词与每条的本地猜测（2026-10-13：低置信度带上下文）。
      final List<AiChatMessage> request = client.requests.single;
      expect(request.first.content, kSubtitleAiOcrSystemPrompt);
      expect(request.last.content, contains('subtitle lines'));
      expect(request.last.content, contains('"w36"'));
      expect(request.last.content, contains('"w37"'));
      expect(out!.map((GraphicSubtitleTextCue c) => c.text), <String>[
        '読み',
        '読み',
      ]);
      expect(published.last, <String>['読み', '読み']);
      expect(aiProgress.last, (2, 2));
    });
  });
  group('边看边识别', () {
    test('pickNextGraphicSubtitleCue：播放头之后的未识别 cue 优先，再回头补', () {
      final List<PgsCue> cues = PgsSubtitleParser.parse(
        _multiSup(<int>[1000, 3000, 5000]),
      );
      expect(cues.map((PgsCue c) => c.startMs), <int>[1000, 3000, 5000]);
      expect(pickNextGraphicSubtitleCue(cues, <int>{}, 3200), 1);
      expect(pickNextGraphicSubtitleCue(cues, <int>{3000}, 3200), 2);
      expect(pickNextGraphicSubtitleCue(cues, <int>{3000, 5000}, 3200), 0);
      expect(
        pickNextGraphicSubtitleCue(cues, <int>{1000, 3000, 5000}, 3200),
        isNull,
      );
    });

    test('从播放头附近开始识别，每条都实时交出已识别的全部 cue', () async {
      final _FakeRecognizer recognizer = _FakeRecognizer(<MokuroImage>[
        for (final String s in <String>['a', 'b', 'c'])
          _page(<List<String>>[
            <String>[s],
          ]),
      ]);
      final GraphicSubtitleOcrSession session = GraphicSubtitleOcrSession(
        prepare: (String _) async =>
            MangaStreamOcrReady(MangaOcrEngineId.localOnnx, recognizer),
      );
      final List<List<int>> published = <List<int>>[];
      final Uint8List sup = _multiSup(<int>[1000, 3000, 5000]);
      final List<GraphicSubtitleTextCue>? out =
          await recognizeGraphicSubtitleCuesLive(
            snapshot: () async => PgsSubtitleParser.parse(sup),
            sourceComplete: () => true,
            sourceDone: Future<void>.value(),
            session: session,
            positionMs: () => 4000,
            isCancelled: () => false,
            onRecognized: (List<GraphicSubtitleTextCue> r) => published.add(
              r.map((GraphicSubtitleTextCue c) => c.startMs).toList(),
            ),
          );
      await session.close();
      expect(published, <List<int>>[
        <int>[5000],
        <int>[1000, 5000],
        <int>[1000, 3000, 5000],
      ]);
      expect(
        out!.map((GraphicSubtitleTextCue c) => (c.startMs, c.text)),
        <(int, String)>[(1000, 'b'), (3000, 'c'), (5000, 'a')],
      );
    });

    test('抽轨未完成时不识别还没收尾的最后一条，完成后补上', () async {
      final _FakeRecognizer recognizer = _FakeRecognizer(<MokuroImage>[
        for (final String s in <String>['a', 'b', 'c'])
          _page(<List<String>>[
            <String>[s],
          ]),
      ]);
      final GraphicSubtitleOcrSession session = GraphicSubtitleOcrSession(
        prepare: (String _) async =>
            MangaStreamOcrReady(MangaOcrEngineId.localOnnx, recognizer),
      );
      int snapshots = 0;
      final List<List<int>> published = <List<int>>[];
      final List<GraphicSubtitleTextCue>? out =
          await recognizeGraphicSubtitleCuesLive(
            // 第一次读到的是半截文件：3000 那条还没清屏。
            snapshot: () async => PgsSubtitleParser.parse(
              snapshots++ == 0
                  ? _multiSup(<int>[1000, 3000], openLast: true)
                  : _multiSup(<int>[1000, 3000, 5000]),
            ),
            sourceComplete: () => snapshots > 0,
            sourceDone: Future<void>.value(),
            session: session,
            positionMs: () => 0,
            isCancelled: () => false,
            onRecognized: (List<GraphicSubtitleTextCue> r) =>
                published.add(<int>[
                  snapshots,
                  ...r.map((GraphicSubtitleTextCue c) => c.startMs),
                ]),
          );
      await session.close();
      // 第一轮（只读过一次半截文件）只识别了已收尾的 1000。
      expect(published.where((List<int> e) => e.first == 1), <List<int>>[
        <int>[1, 1000],
      ]);
      expect(recognizer.calls, 3);
      expect(
        out!.map((GraphicSubtitleTextCue c) => (c.startMs, c.endMs)),
        <(int, int)>[(1000, 1500), (3000, 3500), (5000, 5500)],
      );
    });

    test('取消立即返回 null', () async {
      final _FakeRecognizer recognizer = _FakeRecognizer(<MokuroImage>[]);
      final GraphicSubtitleOcrSession session = GraphicSubtitleOcrSession(
        prepare: (String _) async =>
            MangaStreamOcrReady(MangaOcrEngineId.localOnnx, recognizer),
      );
      final List<GraphicSubtitleTextCue>? out =
          await recognizeGraphicSubtitleCuesLive(
            snapshot: () async => PgsSubtitleParser.parse(_sup()),
            sourceComplete: () => true,
            sourceDone: Future<void>.value(),
            session: session,
            positionMs: () => 0,
            isCancelled: () => true,
          );
      await session.close();
      expect(out, isNull);
      expect(recognizer.calls, 0);
    });

    test('graphicSubtitleAudioCues：与 SRT 同一合并规则，按位置编号', () {
      final List<AudioCue> cues =
          graphicSubtitleAudioCues(const <GraphicSubtitleTextCue>[
            GraphicSubtitleTextCue(startMs: 0, endMs: 1000, text: 'あ'),
            GraphicSubtitleTextCue(startMs: 1020, endMs: 2000, text: 'あ'),
            GraphicSubtitleTextCue(startMs: 2500, endMs: 2600, text: ' '),
            GraphicSubtitleTextCue(startMs: 3000, endMs: 4000, text: 'い'),
          ]);
      expect(
        cues.map((AudioCue c) => (c.sentenceIndex, c.startMs, c.endMs, c.text)),
        <(int, int, int, String)>[(0, 0, 2000, 'あ'), (1, 3000, 4000, 'い')],
      );
    });
  });
}

final AiProviderConfig _aiProvider = AiProviderConfig(
  id: 'p',
  presetId: kAiCustomPresetId,
  name: 'p',
  baseUrl: Uri.parse('https://example.com/v1'),
  apiKey: 'k',
  model: 'vision',
);

/// 文字图引擎替身：文字 = `w{图宽}`，记调用数与最大并发。
class _TextImageRecognizer
    implements MangaStreamPageRecognizer, MangaStreamTextImageRecognizer {
  _TextImageRecognizer({required this.parallelism, this.confidence = 0.99});

  @override
  final int parallelism;
  final double confidence;
  int textCalls = 0;
  int pageCalls = 0;
  int _inFlight = 0;
  int maxConcurrent = 0;

  @override
  Future<OcrRecognition> recognizeTextImage(
    Uint8List rgba, {
    required int width,
    required int height,
  }) async {
    expect(rgba.length, width * height * 4);
    textCalls++;
    _inFlight++;
    if (_inFlight > maxConcurrent) maxConcurrent = _inFlight;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    _inFlight--;
    final String text = 'w$width';
    return OcrRecognition(
      text: text,
      vertical: false,
      lines: <String>[text],
      lineBoxes: <OcrRect>[
        OcrRect(left: 0, top: 0, right: width.toDouble(), bottom: 20),
      ],
      confidence: confidence,
    );
  }

  @override
  Future<MokuroImage> recognize(File pageFile) async {
    pageCalls++;
    throw StateError('page path must not be used');
  }

  @override
  Future<void> close() async {}
}

/// 大模型替身：第一个请求挂起到 [release]；每张图都读成「読み」。
class _GatedAiClient extends AiChatClient {
  final Completer<void> started = Completer<void>();
  final Completer<void> _gate = Completer<void>();
  int calls = 0;

  /// 每次请求的消息（断言请求里带了什么上下文）。
  final List<List<AiChatMessage>> requests = <List<AiChatMessage>>[];

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<String> complete({
    required AiProviderConfig provider,
    required List<AiChatMessage> messages,
    int maxTokens = 2048,
  }) async {
    calls++;
    requests.add(messages);
    if (!started.isCompleted) started.complete();
    await _gate.future;
    final int count = messages.last.images.length;
    return '{"blocks":[${<String>[for (int i = 1; i <= count; i++) '{"id":$i,"text":"読み"}'].join(',')}]}';
  }

  @override
  void close() {}
}
