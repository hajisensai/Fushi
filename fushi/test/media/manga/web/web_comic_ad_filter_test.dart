import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:fushi/src/media/manga/web/web_comic_ad_filter.dart';

/// 画一个「像二维码」的块：25×25 模块、三个定位图形、其余模块伪随机，外加 4 模块
/// 白色静区。判广告只需要定位图形，不需要能解码。
void _drawQr(
  img.Image canvas, {
  required int left,
  required int top,
  required int module,
  int seed = 7,
}) {
  const int modules = 25;
  const int quiet = 4;
  final img.ColorRgb8 white = img.ColorRgb8(255, 255, 255);
  final img.ColorRgb8 black = img.ColorRgb8(0, 0, 0);
  img.fillRect(
    canvas,
    x1: left,
    y1: top,
    x2: left + (modules + quiet * 2) * module - 1,
    y2: top + (modules + quiet * 2) * module - 1,
    color: white,
  );
  final math.Random random = math.Random(seed);
  bool inFinderZone(int r, int c) =>
      (r < 8 && c < 8) ||
      (r < 8 && c >= modules - 8) ||
      (r >= modules - 8 && c < 8);
  bool finderDark(int r, int c) {
    // 定位图形占 7×7，外侧一圈白色分隔带。
    final int lr = r >= 8 ? r - (modules - 7) : r;
    final int lc = c >= 8 ? c - (modules - 7) : c;
    if (lr > 6 || lc > 6 || lr < 0 || lc < 0) return false; // 分隔带
    final int ring = math.min(math.min(lr, lc), math.min(6 - lr, 6 - lc));
    return ring != 1;
  }

  for (int r = 0; r < modules; r++) {
    for (int c = 0; c < modules; c++) {
      final bool dark = inFinderZone(r, c)
          ? finderDark(r, c)
          : random.nextBool();
      if (!dark) continue;
      final int x = left + (quiet + c) * module;
      final int y = top + (quiet + r) * module;
      img.fillRect(
        canvas,
        x1: x,
        y1: y,
        x2: x + module - 1,
        y2: y + module - 1,
        color: black,
      );
    }
  }
}

img.Image _colorfulPoster(int width, int height) {
  final img.Image image = img.Image(width: width, height: height);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      image.setPixelRgb(
        x,
        y,
        230,
        (x * 255 ~/ width),
        40 + (y * 120 ~/ height),
      );
    }
  }
  return image;
}

img.Image _grayPage(int width, int height) {
  final img.Image image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(245, 243, 238));
  // 几块「分镜框」与网点。
  img.drawRect(
    image,
    x1: 20,
    y1: 20,
    x2: width - 20,
    y2: height ~/ 2,
    color: img.ColorRgb8(0, 0, 0),
    thickness: 4,
  );
  for (int y = height ~/ 2 + 20; y < height - 20; y += 6) {
    for (int x = 30; x < width - 30; x += 6) {
      image.setPixelRgb(x, y, 60, 60, 60);
    }
  }
  return image;
}

Uint8List _png(img.Image image) => img.encodePng(image);

void main() {
  group('候选页', () {
    test('只判最后 10 张，前 3 张永不判', () {
      expect(webComicAdCandidateIndices(0), isEmpty);
      expect(webComicAdCandidateIndices(3), isEmpty);
      expect(webComicAdCandidateIndices(4), <int>[3]);
      expect(webComicAdCandidateIndices(12), <int>[
        for (int i = 3; i < 12; i++) i,
      ]);
      expect(webComicAdCandidateIndices(30), <int>[
        for (int i = 20; i < 30; i++) i,
      ]);
    });
  });

  group('广告判定', () {
    test('彩色海报 + 二维码 = 广告', () {
      final img.Image poster = _colorfulPoster(600, 900);
      _drawQr(poster, left: 180, top: 520, module: 7);
      expect(isWebComicAdImage(_png(poster)), isTrue);
    });

    test('大图会先缩小再判，仍能认出', () {
      final img.Image poster = _colorfulPoster(1400, 2000);
      _drawQr(poster, left: 400, top: 1200, module: 16);
      expect(isWebComicAdImage(_png(poster)), isTrue);
    });

    test('彩色但没有二维码不是广告（彩页）', () {
      expect(isWebComicAdImage(_png(_colorfulPoster(600, 900))), isFalse);
    });

    test('黑白漫画页即使印了二维码也不判（正文几乎都是灰度）', () {
      final img.Image page = _grayPage(600, 900);
      _drawQr(page, left: 180, top: 520, module: 7);
      expect(
        webComicColorfulFraction(page),
        lessThan(kWebComicColorfulThreshold),
      );
      expect(isWebComicAdImage(_png(page)), isFalse);
    });

    test('解码不了的字节一律不是广告', () {
      expect(isWebComicAdImage(Uint8List.fromList(<int>[1, 2, 3])), isFalse);
    });

    test('定位图形检测：只有两个定位图形不算二维码', () {
      final img.Image poster = _colorfulPoster(600, 900);
      _drawQr(poster, left: 180, top: 520, module: 7);
      // 用白块盖掉左下角的定位图形。
      img.fillRect(
        poster,
        x1: 180 + 4 * 7,
        y1: 520 + (4 + 18) * 7,
        x2: 180 + (4 + 7) * 7,
        y2: 520 + (4 + 25) * 7,
        color: img.ColorRgb8(255, 255, 255),
      );
      expect(isWebComicAdImage(_png(poster)), isFalse);
    });
  });
}
