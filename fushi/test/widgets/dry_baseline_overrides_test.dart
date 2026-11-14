import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart';
import 'package:fushi/src/utils/components/fushi_marquee.dart';
import 'package:material_ui/material_ui.dart';

/// 两处自写 `computeDryBaseline` 在 Flutter 3.50 语义下（proxy box 对「子节点无基线」
/// 如实回 null，flutter#189723 / #190269）必须与实际布局给出的基线一致：
/// `debugCheckIntrinsicSizes` 打开时框架逐条比对，不一致直接抛错。
void main() {
  Future<void> layOut(
    WidgetTester tester,
    Widget child, {
    required BoxConstraints constraints,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(constraints: constraints, child: child),
          ),
        ),
      ),
    );
  }

  /// 布局完成后像框架的 `_debugVerifyDryBaselines` 那样，在
  /// `debugCheckingIntrinsics` 下同时取实际基线与 dry 基线。
  (double?, double?) baselines(RenderBox box, TextBaseline baseline) {
    RenderObject.debugCheckingIntrinsics = true;
    try {
      return (
        box.getDryBaseline(box.constraints, baseline),
        box.getDistanceToBaseline(baseline, onlyReal: true),
      );
    } finally {
      RenderObject.debugCheckingIntrinsics = false;
    }
  }

  void expectDryMatchesActual(RenderBox box) {
    for (final TextBaseline baseline in TextBaseline.values) {
      final (double? dry, double? actual) = baselines(box, baseline);
      expect(dry, actual, reason: '$baseline');
    }
  }

  testWidgets('FushiMarquee：放得下 / 放不下 / 高于一行的紧约束，dry 基线与实际一致', (
    WidgetTester tester,
  ) async {
    debugCheckIntrinsicSizes = true;
    addTearDown(() => debugCheckIntrinsicSizes = false);
    const TextStyle style = TextStyle(fontSize: 16);
    final Map<String, (String, BoxConstraints)> cases =
        <String, (String, BoxConstraints)>{
          'fits': ('Short', const BoxConstraints(maxWidth: 300)),
          'overflows': (
            'A rather long title that cannot fit in the row',
            const BoxConstraints(maxWidth: 80),
          ),
          'taller tight': (
            'Short',
            const BoxConstraints.tightFor(width: 300, height: 60),
          ),
        };
    for (final MapEntry<String, (String, BoxConstraints)> c in cases.entries) {
      await layOut(
        tester,
        FushiMarquee(text: c.value.$1, style: style),
        constraints: c.value.$2,
      );
      expect(tester.takeException(), isNull, reason: c.key);
      final RenderBox box = tester.renderObject<RenderBox>(
        find.byType(FushiMarquee),
      );
      expectDryMatchesActual(box);
      if (c.key == 'overflows') {
        expect(baselines(box, TextBaseline.alphabetic).$2, null);
      } else {
        expect(baselines(box, TextBaseline.alphabetic).$2, isNotNull);
      }
    }
    // 滚动版 Marquee 的轮次定时器：拆树后走完，免得测试结束时仍有挂起的 Timer。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('SrsNoBaseline：子节点有基线也对外回 null（dry 与实际一致）', (
    WidgetTester tester,
  ) async {
    debugCheckIntrinsicSizes = true;
    addTearDown(() => debugCheckIntrinsicSizes = false);
    await layOut(
      tester,
      const SrsNoBaseline(child: Text('読み')),
      constraints: const BoxConstraints(maxWidth: 200),
    );
    expect(tester.takeException(), isNull);
    final RenderBox box = tester.renderObject<RenderBox>(
      find.byType(SrsNoBaseline),
    );
    expectDryMatchesActual(box);
    expect(baselines(box, TextBaseline.alphabetic).$1, null);
  });
}
