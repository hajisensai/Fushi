// 图像内核回归用例：每个用例在合成图上跑一次公开 API，产出字节，测试比对它的 SHA-256
// 与 image_kernel_vectors.dart 里钉住的值（由改用原生内核**之前**的纯 Dart 实现生成）。
//
// [ImageKernelResize] 抽出来，是因为「纯缩放」在旧实现里是 `img.copyResize`（加
// `img.copyCrop`），现在是 `resizeImageExact`；其余用例直接调同名公开函数。
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show MiningMosaicRegion;
import 'package:fushi_engine/leaderboard/cover_hash.dart';
import 'package:fushi_engine/media/image_mosaic.dart';
import 'package:fushi_engine/media/manga/manga_page_crop.dart';
import 'package:fushi_engine/media/manga/panel_detection.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';
import 'package:fushi_engine/ocr/text_detector.dart';
import 'package:image/image.dart' as img;

import 'synthetic_images.dart';

/// `copyResize(copyCrop(src, rect), width, height, interpolation)`；[crop] 为 null 时不裁。
typedef ImageKernelResize =
    img.Image Function(
      img.Image src, {
      ({int x, int y, int width, int height})? crop,
      required int width,
      required int height,
      required img.Interpolation interpolation,
    });

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

String _shaF32(Float32List v) =>
    _sha(v.buffer.asUint8List(v.offsetInBytes, v.lengthInBytes));

String _shaImage(img.Image i) =>
    _sha(<int>[i.width, i.height, i.numChannels, ...i.toUint8List()]);

String _shaLines(List<PpTextLine> lines) {
  final Float64List v = Float64List(lines.length * 9);
  for (int i = 0; i < lines.length; i++) {
    final PpTextLine l = lines[i];
    v.setAll(i * 9, <double>[
      l.rect.left,
      l.rect.top,
      l.rect.right,
      l.rect.bottom,
      l.score,
      l.axisAngle,
      l.elongation,
      l.pixelCount.toDouble(),
      l.tilt,
    ]);
  }
  return '${lines.length}:${_sha(v.buffer.asUint8List())}';
}

/// 用例名 → 产出摘要。
Map<String, String Function()> imageKernelCases(ImageKernelResize resize) {
  final Map<String, String Function()> cases = <String, String Function()>{};

  // ---- 纯缩放：四种通道数 × 三种插值 × 缩小 / 放大 / 同尺寸 / 裁切后缩放 ----
  const List<(int, int, int, int)> sizes = <(int, int, int, int)>[
    (97, 61, 40, 33),
    (40, 33, 97, 61),
    (301, 157, 64, 64),
    (64, 48, 64, 48),
    (5, 3, 1, 1),
  ];
  for (int ch = 1; ch <= 4; ch++) {
    for (final img.Interpolation interp in <img.Interpolation>[
      img.Interpolation.nearest,
      img.Interpolation.linear,
      img.Interpolation.average,
    ]) {
      for (final (int sw, int sh, int dw, int dh) in sizes) {
        cases['resize/${interp.name}/${ch}ch/${sw}x$sh->${dw}x$dh'] = () =>
            _shaImage(
              resize(
                synthImage(sw, sh, ch, sw * 31 + sh + ch),
                width: dw,
                height: dh,
                interpolation: interp,
              ),
            );
      }
      cases['resize/${interp.name}/${ch}ch/crop'] = () => _shaImage(
        resize(
          synthImage(120, 90, ch, 7 + ch),
          crop: (x: 13, y: 7, width: 50, height: 41),
          width: 31,
          height: 29,
          interpolation: interp,
        ),
      );
    }
  }
  cases['resize/average/3ch/page'] = () => _shaImage(
    resize(
      synthImage(1350, 1920, 3, 1),
      width: 703,
      height: 1000,
      interpolation: img.Interpolation.average,
    ),
  );

  // ---- RT-DETR 输入（squish / letterbox） ----
  for (final int ch in <int>[1, 3, 4]) {
    for (final (int w, int h) in <(int, int)>[(1350, 1920), (500, 300)]) {
      for (final bool keep in <bool>[false, true]) {
        cases['rtdetr/${ch}ch/${w}x$h/${keep ? 'letterbox' : 'squish'}'] = () {
          final img.Image page = synthImage(w, h, ch, w + h + ch);
          return _shaF32(
            rtdetrPreprocess(
              page,
              computeLetterbox(w, h, preserveAspect: keep),
            ),
          );
        };
      }
    }
  }
  cases['rtdetr/3ch/640x640/same'] = () => _shaF32(
    rtdetrPreprocess(synthImage(640, 640, 3, 640), computeLetterbox(640, 640)),
  );

  // ---- PP-OCR det / rec 输入 ----
  for (final int ch in <int>[1, 3, 4]) {
    for (final (int w, int h) in <(int, int)>[(420, 700), (64, 64), (30, 50)]) {
      cases['ppdet/${ch}ch/${w}x$h'] = () {
        final ({int width, int height}) s = ppDetInputSize(w, h);
        return _shaF32(
          ppDetPreprocess(synthImage(w, h, ch, w * h + ch), s.width, s.height),
        );
      };
    }
    for (final (int w, int h) in <(int, int)>[(520, 60), (33, 48), (12, 90)]) {
      cases['pprec/${ch}ch/${w}x$h'] = () {
        final ({Float32List data, int width}) r = ppRecPreprocess(
          synthImage(w, h, ch, w + 3 * h + ch),
        );
        return '${r.width}:${_shaF32(r.data)}';
      };
    }
  }

  // ---- DB 后处理 ----
  for (final (int w, int h) in <(int, int)>[
    (416, 704),
    (97, 61),
    (1000, 300),
  ]) {
    cases['dbpost/${w}x$h'] = () =>
        _shaLines(ppDetPostprocess(synthProbMap(w, h, w ^ h), w, h));
  }

  // ---- 马赛克 ----
  const List<List<MiningMosaicRegion>> regionSets = <List<MiningMosaicRegion>>[
    <MiningMosaicRegion>[
      MiningMosaicRegion(left: 0.1, top: 0.1, right: 0.6, bottom: 0.7),
    ],
    <MiningMosaicRegion>[
      MiningMosaicRegion(left: 0, top: 0, right: 0.33, bottom: 0.21),
      MiningMosaicRegion(left: 0.25, top: 0.15, right: 0.9, bottom: 0.5),
      MiningMosaicRegion(left: 0.7, top: 0.8, right: 1, bottom: 1),
    ],
  ];
  for (int r = 0; r < regionSets.length; r++) {
    cases['mosaic/rgba/$r'] = () {
      final Uint8List px = Uint8List.fromList(
        synthImage(333, 211, 4, 99 + r).toUint8List(),
      );
      applyMosaicRgba(px, 333, 211, regionSets[r]);
      return _sha(px);
    };
    cases['mosaic/rgba/$r/block7'] = () {
      final Uint8List px = Uint8List.fromList(
        synthImage(50, 41, 4, 5 + r).toUint8List(),
      );
      applyMosaicRgba(px, 50, 41, regionSets[r], blockSize: 7);
      return _sha(px);
    };
    for (final int ch in <int>[1, 3, 4]) {
      cases['mosaic/image/${ch}ch/$r'] = () => _shaImage(
        applyMosaicToImage(synthImage(400, 300, ch, 3 + ch + r), regionSets[r]),
      );
    }
  }

  // ---- dHash ----
  for (final (int w, int h, int ch) in <(int, int, int)>[
    (600, 853, 3),
    (600, 853, 4),
    (257, 199, 1),
    (31, 17, 2),
    (5, 4, 3),
    (9, 8, 3),
  ]) {
    cases['dhash/${ch}ch/${w}x$h'] = () =>
        coverDHashOfImage(synthImage(w, h, ch, w * 7 + h + ch));
  }

  // ---- 端到端：漫画卡图裁切（解码 / 编码仍是 package:image） ----
  final Uint8List jpg = img.encodeJpg(
    synthImage(900, 1300, 3, 42),
    quality: 90,
  );
  final Uint8List png = img.encodePng(synthImage(700, 500, 4, 43));
  cases['crop/jpg/panel'] = () => _sha(
    cropMangaPage(
      jpg,
      left: 0.2,
      top: 0.1,
      right: 0.9,
      bottom: 0.7,
      maxLongEdge: 500,
      quality: 90,
    )!.bytes,
  );
  cases['crop/jpg/full-nosize'] = () => _sha(
    cropMangaPage(
      jpg,
      left: 0,
      top: 0,
      right: 1,
      bottom: 1,
      maxLongEdge: 0,
      quality: 85,
    )!.bytes,
  );
  cases['crop/png/mosaic'] = () => _sha(
    cropMangaPage(
      png,
      left: 0.05,
      top: 0.05,
      right: 0.95,
      bottom: 0.95,
      maxLongEdge: 300,
      quality: 90,
      mosaic: regionSets[1],
    )!.bytes,
  );
  cases['mosaic/encoded/jpg'] = () =>
      _sha(mosaicEncodedImage(jpg, regionSets[0])!.bytes);
  cases['panel/bytes/jpg'] = () =>
      _shaF32(preprocessPanelPageBytes(jpg)!.input);

  return cases;
}
