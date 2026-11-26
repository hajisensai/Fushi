import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/cover_ui/cover_aspect_probe.dart';
import 'package:fushi/src/utils/cover_provider_epoch.dart';

/// 反馈 hmsIkQ9zIv：详情页背景带轮播换图时，[CoverAspectProbe] 在
/// `didUpdateWidget` 里把比例清空，背景带退回兜底高度、下方内容被抬上来，新图
/// 解码完才撑回去。按比例撑版面的槽位开 [CoverAspectProbe.holdsAspectAcrossImageChange]
/// 后，换图到新图解码之间必须沿用旧比例。
void main() {
  setUp(() {
    CoverProbeMemo.clear();
    CoverProviderEpoch.clear();
  });

  Future<ui.Image> image(int width, int height) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF3355FF),
    );
    return recorder.endRecording().toImage(width, height);
  }

  Future<List<double?>> run(WidgetTester tester, {required bool hold}) async {
    final List<double?> seen = <double?>[];
    final _GatedImageProvider first = _GatedImageProvider();
    final _GatedImageProvider second = _GatedImageProvider();
    Widget host(ImageProvider provider) => Directionality(
      textDirection: TextDirection.ltr,
      child: _Probe(image: provider, hold: hold, seen: seen),
    );
    final ui.Image wide = await tester.runAsync(() => image(16, 9)) as ui.Image;
    final ui.Image tall = await tester.runAsync(() => image(9, 16)) as ui.Image;
    await tester.pumpWidget(host(first));
    first.gate.complete(ImageInfo(image: wide));
    await tester.pump();
    await tester.pump();
    expect(seen.last, closeTo(16 / 9, 1e-9));

    seen.clear();
    await tester.pumpWidget(host(second));
    final List<double?> beforeDecode = List<double?>.of(seen);
    second.gate.complete(ImageInfo(image: tall));
    await tester.pump();
    await tester.pump();
    expect(seen.last, closeTo(9 / 16, 1e-9), reason: '新图解码后换成新比例');
    return beforeDecode;
  }

  testWidgets('开了 hold：换图到新图解码之前沿用旧比例，不塌回 null', (WidgetTester tester) async {
    final List<double?> beforeDecode = await run(tester, hold: true);
    expect(beforeDecode, isNotEmpty);
    expect(beforeDecode, everyElement(closeTo(16 / 9, 1e-9)));
  });

  testWidgets('默认（网格卡）：换图即清空比例，按尺寸未知渲染', (WidgetTester tester) async {
    final List<double?> beforeDecode = await run(tester, hold: false);
    expect(beforeDecode, isNotEmpty);
    expect(beforeDecode, everyElement(isNull));
  });
}

class _Probe extends StatefulWidget {
  const _Probe({required this.image, required this.hold, required this.seen});

  final ImageProvider image;
  final bool hold;
  final List<double?> seen;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with CoverAspectProbe<_Probe> {
  @override
  ImageProvider probedImageOf(_Probe widget) => widget.image;

  @override
  bool needsBackdropSeed(double aspect) => false;

  @override
  bool get holdsAspectAcrossImageChange => widget.hold;

  @override
  Widget build(BuildContext context) {
    widget.seen.add(coverFailed ? null : coverAspect);
    return const SizedBox.shrink();
  }
}

/// load 何时完成由测试掌控的 provider，按实例身份相等。
class _GatedImageProvider extends ImageProvider<_GatedImageProvider> {
  final Completer<ImageInfo> gate = Completer<ImageInfo>();

  @override
  Future<_GatedImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_GatedImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _GatedImageProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(gate.future);
}
