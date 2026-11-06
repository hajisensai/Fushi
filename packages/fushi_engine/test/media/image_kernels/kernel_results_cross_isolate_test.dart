// 原生内核的输出跨 isolate 后仍完好：生产路径（字幕合成、漫画预处理、卡图裁切）都在
// `Isolate.run` 里调内核，结果经 `Isolate.exit` 移交。输出若是挂 finalizer 的原生内存，
// 工作 isolate 一退出就被释放，调用方读到的是野内存（曾表现为同一张字幕位图每次的内容
// 指纹都不同）。库找不到时失败，不 skip。
@TestOn('vm')
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/media/image_kernels.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_cue.dart';
import 'package:fushi_engine/ocr/text_detector.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import 'synthetic_images.dart';

BitmapSubtitleImage _compose() {
  final Uint8List idx = Uint8List(64 * 20);
  for (int i = 0; i < idx.length; i++) {
    idx[i] = i % 5;
  }
  return composeBitmapSubtitleRgba(
    bounds: (left: 100, top: 50, right: 164, bottom: 70),
    layers: <BitmapSubtitleLayer>[
      BitmapSubtitleLayer(
        x: 100,
        y: 50,
        width: 64,
        height: 20,
        indices: idx,
        stride: 64,
        palette: Uint32List.fromList(<int>[
          0,
          0xFF102030,
          0x80FFFFFF,
          0xFFFFFFFF,
          0x40FF0000,
        ]),
      ),
    ],
  );
}

String _sha(List<int> b) => sha256.convert(b).toString();

void main() {
  test('subtitle compose result survives Isolate.run', () async {
    final String here = _sha(_compose().rgba);
    for (int i = 0; i < 8; i++) {
      final BitmapSubtitleImage there = await Isolate.run(_compose);
      // 让工作 isolate 的善后有机会先跑，再读结果。
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(_sha(there.rgba), here, reason: 'run $i');
    }
  });

  test('resize / CHW results survive Isolate.run', () async {
    final img.Image src = synthImage(300, 200, 3, 4);
    final String resized = _sha(
      resizeImageExact(src, width: 97, height: 61).toUint8List(),
    );
    final Float32List chw = rtdetrPreprocess(src, computeLetterbox(300, 200));
    final String chwSha = _sha(chw.buffer.asUint8List());
    for (int i = 0; i < 4; i++) {
      final Uint8List r = await Isolate.run(
        () => resizeImageExact(src, width: 97, height: 61).toUint8List(),
      );
      final Float32List c = await Isolate.run(
        () => rtdetrPreprocess(src, computeLetterbox(300, 200)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(_sha(r), resized);
      expect(_sha(c.buffer.asUint8List()), chwSha);
    }
  });
}
