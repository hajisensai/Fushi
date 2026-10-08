import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_stream_ocr.dart';
import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';
import 'package:fushi/src/media/video/graphic_subtitle_track_ocr.dart';
import 'package:fushi/src/media/video/pgs_subtitle_parser.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 记下 ffmpeg 参数；[writeSup] 时往输出路径（末参）写一份 `.sup`，否则写空壳。
class _RecordingFfmpegBackend implements FfmpegBackend {
  _RecordingFfmpegBackend({required this.returnCode, required this.writeSup});

  final int returnCode;
  final bool writeSup;
  List<String>? args;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    this.args = args;
    File(args.last).writeAsBytesSync(writeSup ? _sup() : <int>[]);
    return FfmpegRunResult(returnCode: returnCode, output: 'boom');
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      throw UnimplementedError();

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      run(args, timeout);
}

/// 直接起入库的精简 ffmpeg 进程。
class _BinaryFfmpegBackend implements FfmpegBackend {
  _BinaryFfmpegBackend(this.executable);

  final String executable;

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

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      throw UnimplementedError();

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

/// ODS：4x2 实心色 1。
_Segment _ods() {
  // 每行：色 1 连续 4 个（00 04 01 → flag 0x80|4 带颜色），再行尾 00 00。
  final List<int> rle = <int>[
    0x00, 0x84, 0x01, 0x00, 0x00, //
    0x00, 0x84, 0x01, 0x00, 0x00,
  ];
  return (
    type: 0x15,
    body: <int>[
      ..._u16(0), // object id
      0x00, // version
      0xC0, // first + last
      0x00, ..._u16(rle.length + 4), // data length（含宽高）
      ..._u16(4),
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
        backend: backend,
      );
      expect(ok, isTrue);
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
      ]);
    });

    test('失败：删掉空壳文件、交出失败摘要', () async {
      final String out = p.join(dir.path, 'track.sup');
      final List<String> failures = <String>[];
      final bool ok = await extractGraphicSubtitleTrackToSup(
        videoPath: video.path,
        streamIndex: 0,
        supPath: out,
        onFailure: failures.add,
        backend: _RecordingFfmpegBackend(returnCode: 1, writeSup: false),
      );
      expect(ok, isFalse);
      expect(File(out).existsSync(), isFalse);
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

    // 入库的桌面精简 ffmpeg 真跑一遍：缺 sup 封装器时这里报
    // "Requested output format 'sup' is not known"。夹具是一条 PGS 轨的 mkv
    // （单测里的 _sup() 由完整 ffmpeg 封装，mkv 把起点归零：1s/1.5s/3s → 0/0.5/2s）。
    final String windowsBinary = p.normalize(
      '../third_party/ffmpeg-min/windows/ffmpeg.exe',
    );
    test(
      '入库的精简 ffmpeg 能把 mkv 里的 PGS 轨抽成 .sup',
      () async {
        final String out = p.join(dir.path, 'track.sup');
        final List<String> failures = <String>[];
        final bool ok = await extractGraphicSubtitleTrackToSup(
          videoPath: 'test/fixtures/video/pgs_one_cue.mkv',
          streamIndex: 0,
          supPath: out,
          onFailure: failures.add,
          backend: _BinaryFfmpegBackend(windowsBinary),
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
      skip: Platform.isWindows && File(windowsBinary).existsSync()
          ? false
          : '只有 Windows 能跑入库的 ffmpeg-min/windows/ffmpeg.exe',
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

  group('recognizeGraphicSubtitleCues', () {
    test('逐条识别：块内行直接拼接、块间换行、报进度', () async {
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
      final List<(int, int)> progress = <(int, int)>[];
      final List<GraphicSubtitleTextCue>? out =
          await recognizeGraphicSubtitleCues(
            cues: PgsSubtitleParser.parse(_sup()),
            session: session,
            isCancelled: () => false,
            onProgress: (int done, int total) => progress.add((done, total)),
          );
      await session.close();
      expect(out, hasLength(1));
      expect(out!.single.text, 'こんにちは\n世界');
      expect(out.single.startMs, 1000);
      expect(out.single.endMs, 3000);
      expect(progress, <(int, int)>[(1, 1)]);
      expect(recognizer.closed, isTrue);
    });

    test('取消返回 null，不再识别', () async {
      final _FakeRecognizer recognizer = _FakeRecognizer(<MokuroImage>[]);
      final GraphicSubtitleOcrSession session = GraphicSubtitleOcrSession(
        prepare: (String _) async =>
            MangaStreamOcrReady(MangaOcrEngineId.localOnnx, recognizer),
      );
      final List<GraphicSubtitleTextCue>? out =
          await recognizeGraphicSubtitleCues(
            cues: PgsSubtitleParser.parse(_sup()),
            session: session,
            isCancelled: () => true,
          );
      await session.close();
      expect(out, isNull);
      expect(recognizer.calls, 0);
    });

    test('没有引擎抛 GraphicSubtitleOcrUnavailable(noEngine)', () async {
      final GraphicSubtitleOcrSession session = GraphicSubtitleOcrSession(
        prepare: (String _) async => const MangaStreamOcrNoEngine(),
      );
      await expectLater(
        recognizeGraphicSubtitleCues(
          cues: PgsSubtitleParser.parse(_sup()),
          session: session,
          isCancelled: () => false,
        ),
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
  });
}
