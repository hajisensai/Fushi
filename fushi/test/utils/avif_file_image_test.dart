// 本地封面 / 页图缩略图的 AVIF 分支：Flutter 自带 codec 解不开 AVIF，`resizedFileImage`
// 对 `.avif` 交给原生内核解码的 [AvifFileImage]（只缩不放、按宽等比，同 ResizeImage）。
// 真实解码在 runAsync 里跑：fake-async 下 isolate / 引擎解码回调送不回来。
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/cover_image.dart';
import 'package:path/path.dart' as p;

File _fixture(String name) => File(
      p.join('..', 'packages', 'fushi_engine', 'test', 'media', 'image_kernels',
          'fixtures', 'avif', name),
    );

Future<ui.Image> _resolve(WidgetTester tester, ImageProvider provider) async {
  final ui.Image? image = await tester.runAsync(() {
    final Completer<ui.Image> done = Completer<ui.Image>();
    provider.resolve(ImageConfiguration.empty).addListener(
          ImageStreamListener(
            (ImageInfo info, bool _) => done.complete(info.image),
            onError: (Object error, StackTrace? stack) =>
                done.completeError(error, stack),
          ),
        );
    return done.future.timeout(const Duration(seconds: 30));
  });
  return image!;
}

void main() {
  test('.avif 路径交给 AvifFileImage，其余仍是 ResizeImage(FileImage)', () {
    expect(resizedFileImage(File('a/001.avif')), isA<AvifFileImage>());
    expect(resizedFileImage(File('a/002.AVIF')), isA<AvifFileImage>());
    final ImageProvider png = resizedFileImage(File('a/003.png'));
    expect(png, isA<ResizeImage>());
    expect((png as ResizeImage).imageProvider, isA<FileImage>());
    expect(
      resizedFileImage(File('x.avif'), width: 240),
      AvifFileImage(File('x.avif'), maxWidth: 240),
      reason: '缓存键按路径 + 宽度，evictLocalCoverCache 才驱逐得到',
    );
  });

  testWidgets('按宽度上限等比缩小', (WidgetTester tester) async {
    // rgb444：64×40。
    final ui.Image image = await _resolve(
      tester,
      resizedFileImage(_fixture('rgb444.avif'), width: 32),
    );
    expect((image.width, image.height), (32, 20));
  });

  testWidgets('不放大：上限大于原图时原尺寸', (WidgetTester tester) async {
    final ui.Image image =
        await _resolve(tester, resizedFileImage(_fixture('rgb444.avif')));
    expect((image.width, image.height), (64, 40));
  });

  testWidgets('irot 已应用，alpha 图照常出图', (WidgetTester tester) async {
    final ui.Image rotated =
        await _resolve(tester, resizedFileImage(_fixture('orient6.avif')));
    expect((rotated.width, rotated.height), (24, 40));
    final ui.Image alpha =
        await _resolve(tester, resizedFileImage(_fixture('rgba.avif')));
    expect((alpha.width, alpha.height), (48, 36));
  });

  testWidgets('坏文件报错而不是挂起', (WidgetTester tester) async {
    final Directory dir = Directory.systemTemp.createTempSync('avif_bad');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File bad = File(p.join(dir.path, 'bad.avif'))
      ..writeAsBytesSync(<int>[0, 0, 0, 12, ...'ftypavif'.codeUnits, 0, 0]);
    // runAsync 会自己截获闭包里的异常（报成测试错误、返回 null），所以在里面接住带出来。
    final Object? error = await tester.runAsync<Object?>(() {
      final Completer<Object?> done = Completer<Object?>();
      resizedFileImage(bad).resolve(ImageConfiguration.empty).addListener(
            ImageStreamListener(
              (ImageInfo _, bool __) => done.complete(null),
              onError: (Object error, StackTrace? _) => done.complete(error),
            ),
          );
      return done.future.timeout(const Duration(seconds: 30));
    });
    expect(error, isA<StateError>());
  });
}
