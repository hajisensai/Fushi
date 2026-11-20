// PGS 边抽边识别的增量读取（路线图 #3722 c36 / video-32）：抽轨文件还在长时，每次快照只读、
// 只解析新写出的字节；任意切分喂进来的结果与一次整份解析逐条相同。
@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_cue.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/graphic_subtitle_track_extract.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/pgs_subtitle_parser.dart';
import 'package:test/test.dart';

void _segment(BytesBuilder out, int pts, int type, List<int> body) {
  out
    ..add(<int>[0x50, 0x47])
    ..add(<int>[pts >> 24 & 255, pts >> 16 & 255, pts >> 8 & 255, pts & 255])
    ..add(<int>[0, 0, 0, 0])
    ..add(<int>[type, body.length >> 8 & 255, body.length & 255])
    ..add(body);
}

List<int> _pcs({required int objects, int state = 0x80}) => <int>[
  0x07, 0x80, 0x04, 0x38, 0x10, 0, 0, state, 0, 0, objects, //
  if (objects > 0) ...<int>[0, 1, 0, 0, 0, 100, 3, 0xE8],
];

List<int> _pds(int alpha) => <int>[
  0,
  0,
  for (int e = 0; e < 4; e++) ...<int>[e, 235, 128, 128, alpha],
];

/// 一条带位图的显示集（ODS 按 [fragments] 片拆进多个段）+ 可选清屏。
/// [seed] 决定位图内容；同 seed 的相邻显示集应并成一条 cue。
void _displaySet(
  BytesBuilder out,
  int ms, {
  required int seed,
  int alpha = 255,
  int fragments = 1,
  int? clearAtMs,
}) {
  final int pts = ms * 90;
  _segment(out, pts, 0x16, _pcs(objects: 1));
  _segment(out, pts, 0x14, _pds(alpha));
  const int w = 40, h = 10;
  final Uint8List rle = Uint8List(300 + seed * 7);
  for (int k = 0; k < rle.length; k++) {
    rle[k] = (k * 31 + seed) & 255 | 1;
  }
  final int per = (rle.length / fragments).ceil();
  for (int f = 0; f < fragments; f++) {
    final bool first = f == 0;
    final bool last = f == fragments - 1;
    final int flags = (first ? 0x80 : 0) | (last ? 0x40 : 0);
    final int from = f * per;
    final int to = last ? rle.length : from + per;
    _segment(out, pts, 0x15, <int>[
      0, 1, 0, flags, //
      if (first) ...<int>[
        (rle.length + 4) >> 16 & 255,
        (rle.length + 4) >> 8 & 255,
        (rle.length + 4) & 255,
        0,
        w,
        0,
        h,
      ],
      ...rle.sublist(from, to),
    ]);
  }
  _segment(out, pts, 0x80, const <int>[]);
  if (clearAtMs != null) {
    final int clear = clearAtMs * 90;
    _segment(out, clear, 0x16, _pcs(objects: 0, state: 0));
    _segment(out, clear, 0x80, const <int>[]);
  }
}

/// 覆盖：清屏收尾、淡入（同内容不同透明度并成一条）、分片对象、不清屏直接换句、
/// 末条没收尾（兜底时长）。
Uint8List _track() {
  final BytesBuilder out = BytesBuilder(copy: false);
  _displaySet(out, 1000, seed: 1, clearAtMs: 2500);
  _displaySet(out, 3000, seed: 2, alpha: 40);
  _displaySet(out, 3100, seed: 2, clearAtMs: 4800);
  _displaySet(out, 5000, seed: 3, fragments: 3, clearAtMs: 6000);
  _displaySet(out, 7000, seed: 4);
  _displaySet(out, 8000, seed: 5, fragments: 2, clearAtMs: 9000);
  _displaySet(out, 10000, seed: 6);
  return out.toBytes();
}

/// cue 的可比形状：起止 + 每个摆放的位置 / 裁剪 / 位图字节 + 调色板。
List<Object> _shape(List<BitmapSubtitleCue> cues) => <Object>[
  for (final BitmapSubtitleCue c in cues)
    <Object>[
      c.startMs,
      c.endMs,
      for (final PgsPlacement p in (c as PgsCue).placements)
        <Object>[
          p.x,
          p.y,
          p.cropX,
          p.cropY,
          p.width,
          p.height,
          ...p.object.rle,
        ],
      ...c.palette,
    ],
];

void main() {
  final Uint8List track = _track();
  final List<Object> whole = _shape(PgsSubtitleParser.parse(track));

  test('整份解析的基线：6 条 cue，淡入并成一条、末条按兜底时长', () {
    final List<PgsCue> cues = PgsSubtitleParser.parse(track);
    expect(cues.map((PgsCue c) => (c.startMs, c.endMs)), <(int, int)>[
      (1000, 2500),
      (3000, 4800),
      (5000, 6000),
      (7000, 8000),
      (8000, 9000),
      (10000, 10000 + PgsSubtitleParser.openCueCapMs),
    ]);
  });

  test('任意切点分两段喂：结果与整份解析逐条相同', () {
    for (int cut = 0; cut <= track.length; cut++) {
      final PgsSubtitleParseSession session = PgsSubtitleParseSession()
        ..add(Uint8List.sublistView(track, 0, cut));
      // 没写完的尾段不算消费：下次从 offset 起重读。
      session.add(Uint8List.sublistView(track, session.offset));
      expect(session.offset, track.length, reason: 'cut $cut');
      expect(_shape(session.cues), whole, reason: 'cut $cut');
    }
  });

  test('小块逐段喂：就地与经 Isolate.run（状态机跨 isolate 拷贝）结果都相同', () async {
    for (final (int step, bool viaIsolate) in <(int, bool)>[
      (1, false),
      (7, false),
      (64, true),
      (333, true),
    ]) {
      final PgsSubtitleParseSession session = PgsSubtitleParseSession();
      int written = 0;
      while (written < track.length) {
        written = (written + step).clamp(0, track.length);
        // 模拟每次快照：只读 offset 之后到当前文件尾的字节。
        final Uint8List chunk = Uint8List.fromList(
          track.sublist(session.offset, written),
        );
        await session.addWith(
          chunk,
          viaIsolate
              ? Isolate.run<PgsParsedChunk>
              : (PgsParsedChunk Function() parse) async => parse(),
        );
      }
      expect(_shape(session.cues), whole, reason: 'step $step');
    }
  });

  group('readGraphicSubtitleTrackInBackground（PGS 增量读取）', () {
    late Directory dir;
    late String path;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('pgs_incremental_');
      path = '${dir.path}/track.bin';
    });

    tearDown(() async {
      debugRetireAllTsDemuxSessions();
      await dir.delete(recursive: true);
    });

    test('文件在长：只读新写出的字节，已解析的前段不再重读', () async {
      final int half = track.length ~/ 2;
      await File(path).writeAsBytes(track.sublist(0, half));
      final List<BitmapSubtitleCue> first =
          await readGraphicSubtitleTrackInBackground(path);
      expect(first, isNotEmpty);
      // 把已经解析过的前段（第 2 个段的段头魔数）改坏、再补齐后半：整文件重读会在坏段
      // 处停下只剩第一条 cue；增量读取不回头读前段，结果仍与原轨整份解析相同。
      final Uint8List grown = Uint8List.fromList(track);
      final int secondSegment = 13 + (track[11] << 8 | track[12]);
      grown[secondSegment] = 0;
      await File(path).writeAsBytes(grown);
      final List<BitmapSubtitleCue> all =
          await readGraphicSubtitleTrackInBackground(path, complete: true);
      expect(_shape(all), whole);
    });

    test('complete 读完即释放会话：之后同一路径从头重解', () async {
      await File(path).writeAsBytes(track);
      expect(
        _shape(
          await readGraphicSubtitleTrackInBackground(path, complete: true),
        ),
        whole,
      );
      final Uint8List broken = Uint8List.fromList(track);
      broken[13 + (track[11] << 8 | track[12])] = 0;
      await File(path).writeAsBytes(broken);
      expect(
        _shape(await readGraphicSubtitleTrackInBackground(path)),
        _shape(PgsSubtitleParser.parse(broken)),
      );
    });

    test('文件变短（抽轨重来）：换新会话从头解', () async {
      await File(path).writeAsBytes(track);
      await readGraphicSubtitleTrackInBackground(path);
      final int third = track.length ~/ 3;
      await File(path).writeAsBytes(track.sublist(0, third));
      expect(
        _shape(await readGraphicSubtitleTrackInBackground(path)),
        _shape(PgsSubtitleParser.parse(track.sublist(0, third))),
      );
    });
  });
}
