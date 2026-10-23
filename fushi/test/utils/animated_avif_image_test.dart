// FushiAnimatedAvifImage：后台 isolate 里经原生内核逐帧解 AVIF 动图，按帧时长换帧。
//
// 样本 sequence.avif：64×36 四帧纯色（红 / 绿 / 蓝 / 白，80 / 160 / 240 / 40 ms，无限循环），
// 生成见 packages/fushi_engine/test/media/image_kernels/fixtures/avif/gen_avif_fixtures.py。
//
// isolate 往返与引擎图像解码是真异步：一律在 runAsync 里等，再 pump 冲刷 fake zone 的回调
// （testWidgets 的 fake zone 里直接 await 它们会挂死）。帧时长走 fake 时钟（pump(Duration)）。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart'
    show srsCardImageProvider;
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/utils/animated_avif_image.dart';
import 'package:fushi/src/utils/cover_image.dart';
import 'package:visibility_detector/visibility_detector.dart';

const String _fixtures =
    '../packages/fushi_engine/test/media/image_kernels/fixtures/avif';
final File _sequence = File('$_fixtures/sequence.avif');

const List<List<int>> _colors = <List<int>>[
  <int>[255, 0, 0],
  <int>[0, 255, 0],
  <int>[0, 0, 255],
  <int>[255, 255, 255],
];

ui.Image? _shown(WidgetTester tester) {
  final Finder raw = find.byType(RawImage);
  if (raw.evaluate().isEmpty) return null;
  return tester.widget<RawImage>(raw).image;
}

/// 让 isolate / 引擎回调跑起来：真时间等一小段、再 pump（不推进 fake 时钟）。
Future<void> _drain(WidgetTester tester, {int rounds = 20}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

Future<ui.Image> _waitFirstFrame(WidgetTester tester) async {
  for (int i = 0; i < 300 && _shown(tester) == null; i++) {
    await _drain(tester, rounds: 1);
  }
  final ui.Image? image = _shown(tester);
  expect(image, isNotNull, reason: 'first frame never arrived');
  return image!;
}

/// 中心像素 RGB 最接近哪一帧的颜色（下标）。
Future<int> _colorIndex(WidgetTester tester, ui.Image image) async {
  final ByteData data = (await tester.runAsync<ByteData?>(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final int at = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
  final List<int> px = <int>[
    data.getUint8(at),
    data.getUint8(at + 1),
    data.getUint8(at + 2),
  ];
  int best = -1;
  int bestDiff = 1 << 30;
  for (int i = 0; i < _colors.length; i++) {
    int d = 0;
    for (int c = 0; c < 3; c++) {
      d += (px[c] - _colors[i][c]).abs();
    }
    if (d < bestDiff) (best, bestDiff) = (i, d);
  }
  expect(bestDiff, lessThan(36), reason: 'pixel $px matches no frame color');
  return best;
}

Widget _host(
  Widget child, {
  bool disableAnimations = false,
  double devicePixelRatio = 1,
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: MediaQueryData(
      disableAnimations: disableAnimations,
      devicePixelRatio: devicePixelRatio,
    ),
    child: Center(child: child),
  ),
);

void main() {
  setUpAll(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  testWidgets('advances frames by their durations and loops', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(FushiAnimatedAvifImage(file: _sequence)));
    ui.Image image = await _waitFirstFrame(tester);
    expect(await _colorIndex(tester, image), 0);
    // 自然尺寸 = 源图像素（同 FileImage）。
    expect(tester.getSize(find.byType(RawImage)), const Size(64, 36));

    const List<int> durations = <int>[80, 160, 240, 40];
    for (int step = 0; step < 5; step++) {
      final int from = step % 4;
      // 先让预取的下一帧在真时间里就绪，再推 fake 时钟：没到时长不许换帧。
      await _drain(tester);
      await tester.pump(Duration(milliseconds: durations[from] - 10));
      expect(
        identical(_shown(tester), image),
        isTrue,
        reason: 'frame $from swapped before its ${durations[from]} ms',
      );
      await tester.pump(const Duration(milliseconds: 15));
      final ui.Image next = _shown(tester)!;
      expect(identical(next, image), isFalse, reason: 'frame $from never left');
      expect(await _colorIndex(tester, next), (from + 1) % 4);
      image = next;
    }

    await tester.pumpWidget(const SizedBox());
    await _drain(tester, rounds: 5);
  });

  testWidgets('reduced motion shows the first frame only', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(FushiAnimatedAvifImage(file: _sequence), disableAnimations: true),
    );
    final ui.Image image = await _waitFirstFrame(tester);
    await _drain(tester);
    await tester.pump(const Duration(seconds: 2));
    await _drain(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(identical(_shown(tester), image), isTrue);
    expect(await _colorIndex(tester, image), 0);
    await tester.pumpWidget(const SizedBox());
    await _drain(tester, rounds: 5);
  });

  testWidgets('TickerMode off pauses; back on resumes', (
    WidgetTester tester,
  ) async {
    Widget build(bool enabled) => _host(
      TickerMode(
        enabled: enabled,
        child: FushiAnimatedAvifImage(file: _sequence),
      ),
    );
    await tester.pumpWidget(build(false));
    final ui.Image image = await _waitFirstFrame(tester);
    await _drain(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(identical(_shown(tester), image), isTrue);

    await tester.pumpWidget(build(true));
    await _drain(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(await _colorIndex(tester, _shown(tester)!), 1);
    await tester.pumpWidget(const SizedBox());
    await _drain(tester, rounds: 5);
  });

  testWidgets('decode width follows layout constraints × devicePixelRatio', (
    WidgetTester tester,
  ) async {
    Widget build(double dpr) => _host(
      SizedBox(
        width: 20,
        child: FushiAnimatedAvifImage(file: _sequence, fit: BoxFit.contain),
      ),
      devicePixelRatio: dpr,
    );
    // 20 逻辑像素 × dpr 1 → 解 20 宽（只缩不放、等比：20×11）。
    await tester.pumpWidget(build(1));
    ui.Image image = await _waitFirstFrame(tester);
    expect((image.width, image.height), (20, 11));
    expect(tester.getSize(find.byType(RawImage)).width, 20);
    await tester.pumpWidget(const SizedBox());
    await _drain(tester, rounds: 5);
    // dpr 3 → 60 宽。
    await tester.pumpWidget(build(3));
    image = await _waitFirstFrame(tester);
    expect(image.width, 60);
    expect(tester.getSize(find.byType(RawImage)).width, 20);
    await tester.pumpWidget(const SizedBox());
    await _drain(tester, rounds: 5);
  });

  testWidgets('maxDecodeWidth caps the decoded width; layout is unchanged', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(FushiAnimatedAvifImage(file: _sequence, maxDecodeWidth: 16)),
    );
    final ui.Image image = await _waitFirstFrame(tester);
    expect((image.width, image.height), (16, 9));
    expect(tester.getSize(find.byType(RawImage)), const Size(64, 36));
    expect(await _colorIndex(tester, image), 0);
    await tester.pumpWidget(const SizedBox());
    await _drain(tester, rounds: 5);
  });

  testWidgets('still AVIF renders through the same widget', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(FushiAnimatedAvifImage(file: File('$_fixtures/rgb444.avif'))),
    );
    final ui.Image image = await _waitFirstFrame(tester);
    expect((image.width, image.height), (64, 40));
    await tester.pumpWidget(const SizedBox());
    await _drain(tester, rounds: 5);
  });

  testWidgets('undecodable file goes to errorBuilder', (
    WidgetTester tester,
  ) async {
    final Directory tmp = Directory.systemTemp.createTempSync('avif_bad');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final File bad = File('${tmp.path}/bad.avif')
      ..writeAsBytesSync(<int>[1, 2, 3, 4]);
    Object? reported;
    await tester.pumpWidget(
      _host(
        FushiAnimatedAvifImage(
          file: bad,
          errorBuilder: (BuildContext context, Object error, StackTrace? _) {
            reported = error;
            return const Text('broken');
          },
        ),
      ),
    );
    for (int i = 0; i < 200 && reported == null; i++) {
      await _drain(tester, rounds: 1);
    }
    expect(reported, isA<FushiAnimatedAvifException>());
    expect(find.text('broken'), findsOneWidget);
  });

  test('srsCardImageProvider sends .avif to the native AVIF provider', () {
    final SrsMediaStore store = SrsMediaStore(Directory.systemTemp);
    expect(srsCardImageProvider('clip.avif', store), isA<AvifFileImage>());
    expect(srsCardImageProvider('clip.AVIF', store), isA<AvifFileImage>());
    expect(srsCardImageProvider('frame.png', store), isA<FileImage>());
  });
}
