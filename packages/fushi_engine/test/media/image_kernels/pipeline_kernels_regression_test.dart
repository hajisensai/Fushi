// 封面比对 / 大模型裁图 / TS 字幕解复用回归：原生实现必须逐位复现旧纯 Dart 实现的输出摘要
// （pipeline_kernel_vectors.dart）；增量解复用必须与整段重解逐包相同。库找不到时失败，不 skip。
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/mpegts_subtitle_demuxer.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:test/test.dart';

import 'pipeline_kernel_cases.dart';
import 'pipeline_kernel_vectors.dart';

String _describe(List<BitmapSubtitlePacket> packets) => <String>[
  for (final BitmapSubtitlePacket p in packets)
    '${p.pts90k}:${p.data.length}:${p.data.fold<int>(0, (int a, int b) => (a * 31 + b) & 0x3fffffff)}',
].join(',');

void main() {
  test('native kernels are loadable', () {
    expect(FushiComputeImage.instance, isNotNull);
    expect(FushiComputeTs.instance, isNotNull);
  });

  final Map<String, String Function()> cases = pipelineKernelCases();

  test('every case has a pinned vector and vice versa', () {
    expect(cases.keys.toSet(), kPipelineKernelVectors.keys.toSet());
  });

  for (final MapEntry<String, String Function()> e in cases.entries) {
    test(e.key, () => expect(e.value(), kPipelineKernelVectors[e.key]));
  }

  group('incremental TS demux', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('fushi_ts_inc_'));
    tearDown(() => dir.deleteSync(recursive: true));

    for (final int seed in <int>[1, 2, 4]) {
      for (final int step in <int>[188, 1000, 4096, 188 * 37 + 5]) {
        test('seed $seed, grows by $step bytes', () async {
          final Uint8List ts = synthSubtitleTs(seed);
          final File file = File('${dir.path}/track.ts')
            ..writeAsBytesSync(<int>[]);
          final MpegTsSubtitleDemuxSession session =
              MpegTsSubtitleDemuxSession();
          try {
            int end = 0;
            while (end < ts.length) {
              end = end + step > ts.length ? ts.length : end + step;
              file.writeAsBytesSync(Uint8List.sublistView(ts, 0, end));
              await session.readMore(file.path, complete: false);
              expect(
                _describe(session.packets),
                _describe(
                  demuxMpegTsSubtitlePackets(
                    Uint8List.sublistView(ts, 0, end),
                    complete: false,
                  ),
                ),
                reason: 'growing at $end',
              );
            }
            await session.readMore(file.path, complete: true);
            expect(
              _describe(session.packets),
              _describe(demuxMpegTsSubtitlePackets(ts)),
            );
            expect(session.completed, isTrue);
          } finally {
            session.close();
          }
        });
      }
    }

    test('a shrunk file is reported instead of silently mis-parsed', () async {
      final Uint8List ts = synthSubtitleTs(3);
      final File file = File('${dir.path}/track.ts')..writeAsBytesSync(ts);
      final MpegTsSubtitleDemuxSession session = MpegTsSubtitleDemuxSession();
      try {
        await session.readMore(file.path, complete: false);
        file.writeAsBytesSync(Uint8List.sublistView(ts, 0, 188));
        await expectLater(
          session.readMore(file.path, complete: false),
          throwsA(isA<StateError>()),
        );
      } finally {
        session.close();
      }
    });
  });

  test('DB postprocess on a page without any text returns no lines', () {
    // 回归：没有连通域时原生交出的空缓冲按 1 字节对齐，按 Double 视图读会抛（实测整卷 OCR
    // 第一页就崩在补检的空小块上）。
    expect(ppDetPostprocess(Float32List(64 * 48), 64, 48), isEmpty);
  });
}
