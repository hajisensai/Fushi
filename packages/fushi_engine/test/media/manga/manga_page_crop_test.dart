import 'dart:typed_data';

import 'package:fushi_engine/media/manga/manga_page_crop.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// 左半红、右半蓝的 [width]×[height] 页。
img.Image _halves(int width, int height) {
  final img.Image page = img.Image(width: width, height: height);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      page.setPixelRgb(
        x,
        y,
        x < width ~/ 2 ? 255 : 0,
        0,
        x < width ~/ 2 ? 0 : 255,
      );
    }
  }
  return page;
}

void main() {
  group('mangaCropPixelRect', () {
    test('向外取整并夹进页面', () {
      final ({int x, int y, int width, int height}) r = mangaCropPixelRect(
        pageWidth: 100,
        pageHeight: 200,
        left: -0.2,
        top: 0.101,
        right: 0.505,
        bottom: 1.4,
      );
      expect(r.x, 0);
      expect(r.y, 20); // floor(20.2)
      expect(r.width, 51); // ceil(50.5)
      expect(r.height, 180);
    });

    test('左右颠倒时自动交换，退化矩形至少 1×1', () {
      final ({int x, int y, int width, int height}) r = mangaCropPixelRect(
        pageWidth: 10,
        pageHeight: 10,
        left: 0.5,
        top: 0.5,
        right: 0.5,
        bottom: 0.5,
      );
      expect(r.width, 1);
      expect(r.height, 1);
      final ({int x, int y, int width, int height}) swapped =
          mangaCropPixelRect(
            pageWidth: 10,
            pageHeight: 10,
            left: 0.8,
            top: 0.9,
            right: 0.2,
            bottom: 0.1,
          );
      expect(swapped.x, 2);
      expect(swapped.y, 1);
      expect(swapped.width, 6);
      expect(swapped.height, 8);
    });
  });

  group('cropMangaPage', () {
    test('PNG 源保持 PNG，裁到右半页只剩蓝色', () {
      final Uint8List png = img.encodePng(_halves(40, 20));
      final MangaPageCropResult? out = cropMangaPage(
        png,
        left: 0.5,
        top: 0,
        right: 1,
        bottom: 1,
        maxLongEdge: 0,
        quality: 90,
      );
      expect(out, isNotNull);
      expect(out!.encoding, MangaCropEncoding.png);
      expect(out.extension, 'png');
      expect(out.width, 20);
      expect(out.height, 20);
      final img.Image decoded = img.decodePng(out.bytes)!;
      final img.Pixel p = decoded.getPixel(3, 3);
      expect(p.b, 255);
      expect(p.r, 0);
    });

    test('JPEG 源输出 JPEG，长边超过质量档上限时等比缩小（只缩不放）', () {
      final Uint8List jpg = img.encodeJpg(_halves(400, 200), quality: 95);
      final MangaPageCropResult? shrunk = cropMangaPage(
        jpg,
        left: 0,
        top: 0,
        right: 1,
        bottom: 1,
        maxLongEdge: 100,
        quality: 80,
      );
      expect(shrunk!.encoding, MangaCropEncoding.jpeg);
      expect(shrunk.extension, 'jpg');
      expect(shrunk.width, 100);
      expect(shrunk.height, 50);
      expect(img.findFormatForData(shrunk.bytes), img.ImageFormat.jpg);

      // 档 3（maxLongEdge = 0）只裁不缩；小图也不会被放大。
      final MangaPageCropResult? raw = cropMangaPage(
        jpg,
        left: 0,
        top: 0,
        right: 0.5,
        bottom: 1,
        maxLongEdge: 0,
        quality: 100,
      );
      expect(raw!.width, 200);
      expect(raw.height, 200);
      final MangaPageCropResult? notEnlarged = cropMangaPage(
        jpg,
        left: 0,
        top: 0,
        right: 0.1,
        bottom: 0.1,
        maxLongEdge: 1000,
        quality: 90,
      );
      expect(notEnlarged!.width, 40);
      expect(notEnlarged.height, 20);
    });

    test('EXIF 方向先 bake 再按归一化坐标裁', () {
      // 物理像素 40×20（左红右蓝），orientation 6 = 顺时针转 90°：显示为 20×40，
      // 原左半（红）转到上半。
      final img.Image page = _halves(40, 20);
      page.exif.imageIfd.orientation = 6;
      final Uint8List jpg = img.encodeJpg(page, quality: 100);

      expect(mangaPageOrientedSize(jpg), (width: 20, height: 40));

      final MangaPageCropResult? top = cropMangaPage(
        jpg,
        left: 0,
        top: 0,
        right: 1,
        bottom: 0.5,
        maxLongEdge: 0,
        quality: 100,
      );
      expect(top!.width, 20);
      expect(top.height, 20);
      final img.Pixel p = img.decodeJpg(top.bytes)!.getPixel(10, 5);
      expect(p.r, greaterThan(200));
      expect(p.b, lessThan(60));
    });

    test('解码失败返回 null（调用方退回整页原图）', () {
      final Uint8List junk = Uint8List.fromList(List<int>.filled(64, 7));
      expect(
        cropMangaPage(
          junk,
          left: 0,
          top: 0,
          right: 1,
          bottom: 1,
          maxLongEdge: 0,
          quality: 90,
        ),
        isNull,
      );
      expect(mangaPageOrientedSize(junk), isNull);
      expect(
        cropMangaPage(
          Uint8List(0),
          left: 0,
          top: 0,
          right: 1,
          bottom: 1,
          maxLongEdge: 0,
          quality: 90,
        ),
        isNull,
      );
    });

    test('后台 isolate 变体与同步版结果一致', () async {
      final Uint8List png = img.encodePng(_halves(40, 20));
      final MangaPageCropResult? out = await cropMangaPageAsync(
        png,
        left: 0,
        top: 0,
        right: 0.5,
        bottom: 1,
        maxLongEdge: 0,
        quality: 90,
      );
      expect(out!.width, 20);
      expect(await mangaPageOrientedSizeAsync(png), (width: 40, height: 20));
    });
  });
}
