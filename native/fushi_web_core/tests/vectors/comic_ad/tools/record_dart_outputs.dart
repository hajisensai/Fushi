// 用旧 Dart 实现（web_comic_ad_filter.dart）给一组输入图记录输出，生成回归向量。
// 用法（在 fushi/ 下）：dart run tool/_wc_scratch/record_vectors.dart <vectors_dir>
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../lib/src/media/manga/web/web_comic_ad_filter.dart';

// ---- 现有测试里的合成图（与 test/media/manga/web/web_comic_ad_filter_test.dart 逐字相同）----
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
    final int lr = r >= 8 ? r - (modules - 7) : r;
    final int lc = c >= 8 ? c - (modules - 7) : c;
    if (lr > 6 || lc > 6 || lr < 0 || lc < 0) return false;
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

void _writeDartFixtures(Directory dir) {
  void png(String name, img.Image image) =>
      File('${dir.path}/$name').writeAsBytesSync(img.encodePng(image));
  final img.Image p1 = _colorfulPoster(600, 900);
  _drawQr(p1, left: 180, top: 520, module: 7);
  png('t_poster_qr_600x900.png', p1);
  final img.Image p2 = _colorfulPoster(1400, 2000);
  _drawQr(p2, left: 400, top: 1200, module: 16);
  png('t_poster_qr_1400x2000.png', p2);
  png('t_poster_noqr_600x900.png', _colorfulPoster(600, 900));
  final img.Image g = _grayPage(600, 900);
  _drawQr(g, left: 180, top: 520, module: 7);
  png('t_graypage_qr_600x900.png', g);
  File('${dir.path}/t_garbage_3bytes.bin').writeAsBytesSync(<int>[1, 2, 3]);
  final img.Image p3 = _colorfulPoster(600, 900);
  _drawQr(p3, left: 180, top: 520, module: 7);
  img.fillRect(
    p3,
    x1: 180 + 4 * 7,
    y1: 520 + (4 + 18) * 7,
    x2: 180 + (4 + 7) * 7,
    y2: 520 + (4 + 25) * 7,
    color: img.ColorRgb8(255, 255, 255),
  );
  png('t_poster_two_finders_600x900.png', p3);
}

/// isWebComicAdImage 的前半段（解码 + 缩放），只为记录彩色占比这一中间量。
double? _colorful(Uint8List bytes) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } on Object {
    return null;
  }
  if (decoded == null || decoded.width < 32 || decoded.height < 32) {
    return null;
  }
  final img.Image image = math.max(decoded.width, decoded.height) > 900
      ? img.copyResize(
          decoded,
          width: decoded.width >= decoded.height ? 900 : null,
          height: decoded.height > decoded.width ? 900 : null,
          interpolation: img.Interpolation.average,
        )
      : decoded;
  return webComicColorfulFraction(image);
}

void main(List<String> args) {
  final Directory dir = Directory(args.single);
  final Directory inputs = Directory('${dir.path}/inputs');
  _writeDartFixtures(inputs);
  final List<File> files = inputs.listSync().whereType<File>().toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));
  final List<Map<String, Object?>> cases = <Map<String, Object?>>[];
  for (final File f in files) {
    final Uint8List bytes = f.readAsBytesSync();
    final Stopwatch sw = Stopwatch()..start();
    final bool ad = isWebComicAdImage(bytes);
    sw.stop();
    final double? colorful = _colorful(bytes);
    cases.add(<String, Object?>{
      'file': f.uri.pathSegments.last,
      'bytes': bytes.length,
      'dartIsAd': ad,
      'dartColorful': colorful,
      'dartMicros': sw.elapsedMicroseconds,
    });
    stdout.writeln('${f.uri.pathSegments.last}: ad=$ad colorful=$colorful');
  }
  final Map<String, List<int>> candidates = <String, List<int>>{
    for (int n = 0; n <= 40; n++) '$n': webComicAdCandidateIndices(n),
  };
  final Map<String, Object?> out = <String, Object?>{
    'source':
        'fushi/lib/src/media/manga/web/web_comic_ad_filter.dart (Dart, package:image 4.3.0)',
    'rules': <String, Object?>{
      'tailWindow': kWebComicAdTailWindow,
      'protectedLeadingPages': kWebComicAdProtectedLeadingPages,
      'colorfulThreshold': kWebComicColorfulThreshold,
    },
    'cases': cases,
    'candidates': candidates,
  };
  File(
    '${dir.path}/dart_outputs.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
}
