import 'dart:typed_data';

import 'package:fushi_anki/fushi_anki_core.dart' show MiningMosaicRegion;
import 'package:fushi_engine/media/image_mosaic.dart';
import 'package:fushi_engine/media/manga/manga_page_crop.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// 高级制卡「打码」的纯函数：坐标换算、块平均、边界、多区域，以及出卡 / 漫画裁切
/// 两条落地路径。
void main() {
  /// 每个像素颜色都不同的 RGBA 缓冲（R = x、G = y、B = 常数、A = 255）。
  Uint8List gradient(int w, int h) {
    final Uint8List out = Uint8List(w * h * 4);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final int i = (y * w + x) * 4;
        out[i] = x % 256;
        out[i + 1] = y % 256;
        out[i + 2] = 77;
        out[i + 3] = 255;
      }
    }
    return out;
  }

  List<int> px(Uint8List rgba, int w, int x, int y) {
    final int i = (y * w + x) * 4;
    return <int>[rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]];
  }

  MiningMosaicRegion region(double l, double t, double r, double b) =>
      MiningMosaicRegion(left: l, top: t, right: r, bottom: b);

  group('mosaicBlockSizeFor', () {
    test('按长边比例取，下限 4px', () {
      expect(mosaicBlockSizeFor(1920, 1080), 40);
      expect(mosaicBlockSizeFor(1080, 1920), 40);
      expect(mosaicBlockSizeFor(960, 540), 20);
      expect(mosaicBlockSizeFor(40, 30), kMosaicMinBlockSize);
    });
  });

  group('mosaicPixelBounds', () {
    test('向外取整、夹进图像', () {
      final ({int x0, int y0, int x1, int y1}) b = mosaicPixelBounds(
        region(0.101, 0.2, 0.499, 0.8),
        100,
        50,
      )!;
      expect(b, (x0: 10, y0: 10, x1: 50, y1: 40));
    });

    test('越界坐标夹到 0..1；颠倒的矩形也认', () {
      expect(mosaicPixelBounds(region(1.2, 0.5, -0.3, -1), 10, 10), (
        x0: 0,
        y0: 0,
        x1: 10,
        y1: 5,
      ));
    });

    test('零宽 / 空图返回 null', () {
      expect(mosaicPixelBounds(region(0.5, 0.1, 0.5, 0.9), 10, 10), isNull);
      expect(mosaicPixelBounds(region(0, 0, 1, 1), 0, 10), isNull);
    });
  });

  group('applyMosaicRgba', () {
    test('区域内按块取平均，区域外一个像素都不动', () {
      const int w = 16, h = 16;
      final Uint8List original = gradient(w, h);
      final Uint8List rgba = Uint8List.fromList(original);
      // 区域 = 左上 8×8，块 4：四个整块。
      applyMosaicRgba(rgba, w, h, <MiningMosaicRegion>[
        region(0, 0, 0.5, 0.5),
      ], blockSize: 4);
      // 第一块 x,y ∈ [0,4)：R 平均 1.5 → 2，G 同。
      for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
          expect(px(rgba, w, x, y), <int>[2, 2, 77, 255]);
        }
      }
      // 第二块 x ∈ [4,8)：R 平均 5.5 → 6。
      expect(px(rgba, w, 5, 1), <int>[6, 2, 77, 255]);
      // 区域外原样。
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          if (x < 8 && y < 8) continue;
          expect(px(rgba, w, x, y), px(original, w, x, y));
        }
      }
    });

    test('网格锚定在图像原点：区域不对齐时整块取平均、只写区域内', () {
      const int w = 8, h = 8;
      final Uint8List original = gradient(w, h);
      final Uint8List rgba = Uint8List.fromList(original);
      // 像素 [2,6) × [0,4)：跨两个 4px 块的各一半。
      applyMosaicRgba(rgba, w, h, <MiningMosaicRegion>[
        region(0.25, 0, 0.75, 0.5),
      ], blockSize: 4);
      // 第一块（x 0..3）的平均 R = 1.5 → 2，只写到 x=2,3。
      expect(px(rgba, w, 2, 0), <int>[2, 2, 77, 255]);
      expect(px(rgba, w, 3, 3), <int>[2, 2, 77, 255]);
      expect(px(rgba, w, 1, 0), px(original, w, 1, 0), reason: '块内但区域外');
      // 第二块（x 4..7）平均 R = 5.5 → 6，写到 x=4,5。
      expect(px(rgba, w, 5, 2), <int>[6, 2, 77, 255]);
      expect(px(rgba, w, 6, 2), px(original, w, 6, 2));
    });

    test('图像边缘的残块只按图内像素平均', () {
      const int w = 6, h = 6;
      final Uint8List rgba = gradient(w, h);
      applyMosaicRgba(rgba, w, h, <MiningMosaicRegion>[
        region(0.5, 0.5, 1, 1),
      ], blockSize: 4);
      // 右下残块 x,y ∈ [4,6)：R 平均 4.5 → 5（round half away from zero）。
      expect(px(rgba, w, 5, 5), <int>[5, 5, 77, 255]);
      // 同一个 [0,4) 块里落在区域内的 x=3,y=3：整块 [0,4)² 平均 R = 1.5 → 2。
      expect(px(rgba, w, 3, 3), <int>[2, 2, 77, 255]);
    });

    test('多区域重叠：结果与顺序无关', () {
      const int w = 32, h = 24;
      final List<MiningMosaicRegion> regions = <MiningMosaicRegion>[
        region(0.1, 0.1, 0.6, 0.6),
        region(0.4, 0.3, 0.95, 0.9),
        region(0.0, 0.7, 0.2, 1.0),
      ];
      final Uint8List a = gradient(w, h);
      final Uint8List b = gradient(w, h);
      applyMosaicRgba(a, w, h, regions, blockSize: 5);
      applyMosaicRgba(b, w, h, regions.reversed.toList(), blockSize: 5);
      expect(a, b);
      // 对照：只打第一块的结果不同（确认上面不是空操作）。
      final Uint8List twice = gradient(w, h);
      applyMosaicRgba(twice, w, h, <MiningMosaicRegion>[
        regions[0],
      ], blockSize: 5);
      expect(twice, isNot(a));
    });

    test('无区域 / 退化区域：缓冲原样', () {
      final Uint8List original = gradient(8, 8);
      final Uint8List rgba = Uint8List.fromList(original);
      applyMosaicRgba(rgba, 8, 8, const <MiningMosaicRegion>[]);
      applyMosaicRgba(rgba, 8, 8, <MiningMosaicRegion>[
        region(0.5, 0.2, 0.5, 0.8),
      ]);
      expect(rgba, original);
    });

    test('缓冲长度与尺寸不符时抛错（不越界写）', () {
      expect(
        () => applyMosaicRgba(Uint8List(10), 4, 4, <MiningMosaicRegion>[
          region(0, 0, 1, 1),
        ]),
        throwsArgumentError,
      );
    });

    test('缩小的预览与全尺寸出卡：同一处块数一致（块按长边比例取）', () {
      // 全尺寸 960×480（块 20）与预览 480×240（块 10）在 0..0.5 宽打码：都是 24 块宽。
      int blocksAcross(int w, int h) {
        final Uint8List rgba = gradient(w, h);
        applyMosaicRgba(rgba, w, h, <MiningMosaicRegion>[
          region(0, 0, 0.5, 0.1),
        ]);
        int changes = 0;
        for (int x = 1; x < w ~/ 2; x++) {
          if (px(rgba, w, x, 0)[0] != px(rgba, w, x - 1, 0)[0]) changes++;
        }
        return changes + 1;
      }

      expect(blocksAcross(960, 480), blocksAcross(480, 240));
    });
  });

  group('mosaicEncodedImage', () {
    img.Image solidHalves() {
      final img.Image image = img.Image(width: 40, height: 20);
      for (int y = 0; y < 20; y++) {
        for (int x = 0; x < 40; x++) {
          image.setPixelRgb(x, y, x.isEven ? 255 : 0, 0, 0);
        }
      }
      return image;
    }

    test('PNG 进 PNG 出，区域内条纹被抹平、区域外不变', () {
      final Uint8List png = img.encodePng(solidHalves());
      final MosaicEncodedImage out = mosaicEncodedImage(
        png,
        <MiningMosaicRegion>[region(0, 0, 0.5, 1)],
      )!;
      expect(out.isPng, isTrue);
      expect(out.extension, 'png');
      final img.Image decoded = img.decodePng(out.bytes)!;
      expect(decoded.width, 40);
      // 块 4px：左半 2 列亮 2 列暗 → 平均 128。
      expect(decoded.getPixel(1, 1).r, closeTo(128, 1));
      expect(decoded.getPixel(2, 1).r, closeTo(128, 1));
      // 右半原样条纹。
      expect(decoded.getPixel(30, 1).r, 255);
      expect(decoded.getPixel(31, 1).r, 0);
    });

    test('JPEG 进 JPEG 出', () {
      final Uint8List jpg = img.encodeJpg(solidHalves());
      final MosaicEncodedImage out = mosaicEncodedImage(
        jpg,
        <MiningMosaicRegion>[region(0, 0, 1, 1)],
      )!;
      expect(out.isPng, isFalse);
      expect(out.extension, 'jpg');
      expect(img.decodeJpg(out.bytes), isNotNull);
    });

    test('解不开返回 null（调用方据此不要卡图）', () {
      expect(
        mosaicEncodedImage(
          Uint8List.fromList(<int>[1, 2, 3, 4]),
          <MiningMosaicRegion>[region(0, 0, 1, 1)],
        ),
        isNull,
      );
      expect(
        mosaicEncodedImage(Uint8List(0), <MiningMosaicRegion>[
          region(0, 0, 1, 1),
        ]),
        isNull,
      );
    });
  });

  test('漫画裁切：打码坐标相对整页、先打码再裁', () {
    // 40×20 页，左右各一半条纹；码打在左半，裁右半 → 裁出来是原样条纹；
    // 裁左半 → 裁出来是糊的。
    final img.Image page = img.Image(width: 40, height: 20);
    for (int y = 0; y < 20; y++) {
      for (int x = 0; x < 40; x++) {
        page.setPixelRgb(x, y, x.isEven ? 255 : 0, 0, 0);
      }
    }
    final Uint8List png = img.encodePng(page);
    final List<MiningMosaicRegion> mosaic = <MiningMosaicRegion>[
      region(0, 0, 0.5, 1),
    ];
    final MangaPageCropResult right = cropMangaPage(
      png,
      left: 0.5,
      top: 0,
      right: 1,
      bottom: 1,
      maxLongEdge: 0,
      quality: 90,
      mosaic: mosaic,
    )!;
    final img.Image r = img.decodePng(right.bytes)!;
    expect(r.width, 20);
    expect(r.getPixel(0, 0).r, 255);
    expect(r.getPixel(1, 0).r, 0);

    final MangaPageCropResult left = cropMangaPage(
      png,
      left: 0,
      top: 0,
      right: 0.5,
      bottom: 1,
      maxLongEdge: 0,
      quality: 90,
      mosaic: mosaic,
    )!;
    final img.Image l = img.decodePng(left.bytes)!;
    expect(l.getPixel(0, 0).r, closeTo(128, 1));
    expect(l.getPixel(1, 0).r, closeTo(128, 1));
  });
}
